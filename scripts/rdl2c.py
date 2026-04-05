#!/usr/bin/env python3
"""RDL-to-C Header Generator for TideLink.

Compiles SystemRDL 2.0 files and emits CMSIS-style C headers with:
  - Volatile register typedef structs
  - Bit-field position and mask #defines
  - Register offset #defines
  - Reset value #defines

Includes a preprocessor to handle the ->hw/->sw dynamic property
assignment syntax used in TideLink RDL files (not supported by
the strict systemrdl-compiler parser).

Usage:
    python3 scripts/rdl2c.py src/rdl/tidelink_regs.rdl -o src/sw/tidelink_regs.generated.h
    python3 scripts/rdl2c.py src/rdl/tidelink_regs.rdl src/rdl/tidelink_ptp_regs.rdl -o out.h

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import argparse
import os
import re
import sys
import tempfile
import textwrap
from io import StringIO

from systemrdl import RDLCompiler
from systemrdl.node import (
    AddrmapNode,
    FieldNode,
    RegfileNode,
    RegNode,
)


# ── RDL Preprocessor ──────────────────────────────────────────────────────
#
# Transforms non-standard dynamic property assignments into inline field
# properties that systemrdl-compiler accepts.
#
# Handles patterns like:
#   field {} enable[1] = 0;
#   enable->sw = rw;
#   enable->hw = r;
#   enable->desc = "...";
#   enable->singlepulse;
#
# Transforms into:
#   field { sw = rw; hw = r; singlepulse; } enable[1] = 0;
#   enable->desc = "...";     (desc is allowed as dynamic assignment)
#
# The properties 'hw', 'sw', 'singlepulse', 'rclr', 'woclr', 'woset'
# are moved into the field body. 'desc', 'name', and 'reset' are left
# as dynamic assignments (they're legal in systemrdl-compiler).

# Properties that must be inside the field definition
INLINE_PROPS = {'hw', 'sw', 'singlepulse', 'rclr', 'woclr', 'woset',
                'swmod', 'onread', 'onwrite'}

# Dynamic assignment with value:  name->prop = value;
RE_DYN_ASSIGN = re.compile(
    r'^(\s*)(\w+)\s*->\s*(\w+)\s*=\s*(.+?)\s*;\s*$'
)
# Dynamic assignment without value (boolean):  name->singlepulse;
RE_DYN_BOOL = re.compile(
    r'^(\s*)(\w+)\s*->\s*(\w+)\s*;\s*$'
)
# Field declaration:  field {} name[width] = reset;  or  field {} name[hi:lo] = reset;
RE_FIELD_DECL = re.compile(
    r'^(\s*)field\s*\{([^}]*)\}\s*(\w+)\s*(\[[^\]]+\])?\s*(=\s*.+?)?\s*;\s*$'
)


RE_DEFAULT_PROP = re.compile(
    r'^\s*default\s+(hw|sw)\s*=\s*\w+\s*;\s*$'
)


def preprocess_rdl(source: str) -> str:
    """Transform non-standard dynamic property assignments into inline
    field properties for systemrdl-compiler compatibility.

    Processes the file sequentially: for each field declaration, looks
    ahead at immediately following lines for dynamic property assignments
    on the same field name, avoiding cross-register name collisions.
    """

    lines = source.split('\n')
    out_lines = []
    has_inlined = False
    i = 0

    while i < len(lines):
        line = lines[i]

        # Check for field declaration
        m = RE_FIELD_DECL.match(line)
        if m:
            indent, existing_body, fname, width_part, reset_part = m.groups()
            existing_body = (existing_body or '').strip()
            width_part = width_part or ''
            reset_part = reset_part or ''

            # Look ahead for dynamic assignments on this field name.
            # Skip over non-inlinable props (desc, etc) — they stay in place.
            inline_props = []
            lines_to_skip = set()
            j = i + 1
            while j < len(lines):
                lj = lines[j]

                # Dynamic assign with value: fname->prop = val;
                md = RE_DYN_ASSIGN.match(lj)
                if md:
                    _, dname, prop, val = md.groups()
                    if dname == fname and prop in INLINE_PROPS:
                        inline_props.append((prop, val))
                        lines_to_skip.add(j)
                        j += 1
                        continue
                    elif dname == fname:
                        # Non-inlinable prop (desc etc) - skip over, keep scanning
                        j += 1
                        continue
                    else:
                        break

                # Dynamic assign boolean: fname->singlepulse;
                mb = RE_DYN_BOOL.match(lj)
                if mb:
                    _, dname, prop = mb.groups()
                    if dname == fname and prop in INLINE_PROPS:
                        inline_props.append((prop, None))
                        lines_to_skip.add(j)
                        j += 1
                        continue
                    elif dname == fname:
                        j += 1
                        continue
                    else:
                        break

                # Any other line - stop lookahead
                break

            if inline_props:
                has_inlined = True
                # Build the field with inlined properties
                props = []
                if existing_body:
                    props.append(existing_body.rstrip(';').strip())
                for prop, val in inline_props:
                    if val is not None:
                        props.append(f'{prop} = {val}')
                    else:
                        props.append(prop)
                body = '; '.join(props)
                if body:
                    body += ';'
                line = f'{indent}field {{ {body} }} {fname}{width_part}'
                if reset_part:
                    line += f' {reset_part}'
                line += ';'
                out_lines.append(line)
                # Emit lines between i+1 and j that weren't consumed (desc etc)
                for k in range(i + 1, j):
                    if k not in lines_to_skip:
                        out_lines.append(lines[k])
                i = j  # Skip past all scanned lines
                continue

        # Remove default hw/sw lines if any inlining happened
        # (done in a second pass below)
        out_lines.append(line)
        i += 1

    # Second pass: strip default hw/sw if we inlined properties
    if has_inlined:
        out_lines = [l for l in out_lines if not RE_DEFAULT_PROP.match(l)]

    return '\n'.join(out_lines)


# ── C Code Generation ─────────────────────────────────────────────────────

def c_name(s: str) -> str:
    """Convert a name to UPPER_SNAKE_CASE for C macros."""
    return re.sub(r'(?<=[a-z0-9])(?=[A-Z])', '_', s).upper()


def collect_registers(node, prefix='', base_offset=0):
    """Walk the register tree and collect register/field info.

    Returns a list of dicts:
        {
            'name': 'PAIR_BASE_ADDR',
            'offset': 0x000,
            'desc': '...',
            'fields': [
                {'name': 'PAIR_BASE', 'low': 0, 'width': 32,
                 'sw': 'rw', 'reset': 0, 'desc': '...'},
            ]
        }
    """
    regs = []

    for child in node.children():
        if isinstance(child, (AddrmapNode, RegfileNode)):
            child_prefix = prefix + c_name(child.inst_name) + '_'
            sub_regs = collect_registers(
                child,
                prefix=child_prefix,
                base_offset=base_offset + child.address_offset,
            )
            regs.extend(sub_regs)

        elif isinstance(child, RegNode):
            # Handle register arrays
            is_array = child.is_array
            if is_array:
                array_size = child.array_dimensions[0]
                array_stride = child.array_stride
                # For arrays, raw_address_offset is the base before indexing
                base_addr = base_offset + child.raw_address_offset
            else:
                array_size = 1
                array_stride = 0
                base_addr = base_offset + child.address_offset

            for arr_idx in range(array_size):
                reg_offset = base_addr
                if is_array:
                    reg_offset += arr_idx * array_stride

                reg_name = prefix + c_name(child.inst_name)
                if is_array:
                    reg_name += f'_{arr_idx}'

                reg_desc = child.get_property('desc') or ''

                fields = []
                for field in child.fields():
                    if isinstance(field, FieldNode):
                        sw_prop = field.get_property('sw')
                        sw_str = str(sw_prop).split('.')[-1] if sw_prop else 'r'

                        reset_val = field.get_property('reset')
                        if reset_val is None:
                            reset_val = 0

                        field_desc = field.get_property('desc') or ''

                        fields.append({
                            'name': c_name(field.inst_name),
                            'low': field.low,
                            'width': field.width,
                            'sw': sw_str,
                            'reset': int(reset_val),
                            'desc': field_desc,
                        })

                regs.append({
                    'name': reg_name,
                    'offset': reg_offset,
                    'desc': reg_desc,
                    'fields': sorted(fields, key=lambda f: f['low']),
                })

    return regs


def sw_to_qualifier(sw: str) -> str:
    """Map SystemRDL sw access to CMSIS qualifier."""
    sw = sw.lower()
    if sw in ('r', 'na'):
        return '__I '
    elif sw == 'w':
        return '__O '
    else:
        return '__IO'


def reg_qualifier(fields):
    """Determine the CMSIS qualifier for a full register based on its fields."""
    has_read = any(f['sw'] in ('r', 'rw', 'rw1', 'w1') for f in fields)
    has_write = any(f['sw'] in ('w', 'rw', 'rw1', 'w1') for f in fields)
    if has_read and has_write:
        return '__IO'
    elif has_read:
        return '__I '
    elif has_write:
        return '__O '
    return '__IO'


def generate_header(addrmap_name: str, regs: list, guard: str) -> str:
    """Generate a CMSIS-style C header string from collected registers."""

    out = StringIO()
    w = out.write

    # File header
    w(f'/*{"-" * 77}\n')
    w(f' * Auto-generated from SystemRDL — do not edit\n')
    w(f' *\n')
    w(f' * Source addrmap: {addrmap_name}\n')
    w(f' * Generator:     scripts/rdl2c.py\n')
    w(f' *{"-" * 77}*/\n\n')

    w(f'#ifndef {guard}\n')
    w(f'#define {guard}\n\n')
    w(f'#include <stdint.h>\n\n')
    w(f'#ifdef __cplusplus\nextern "C" {{\n#endif\n\n')

    # CMSIS qualifiers
    w('/* CMSIS-style access qualifiers */\n')
    w('#ifndef __IO\n#define __IO volatile\n#endif\n')
    w('#ifndef __I\n#define __I  volatile const\n#endif\n')
    w('#ifndef __O\n#define __O  volatile\n#endif\n\n')

    map_prefix = c_name(addrmap_name)
    struct_name = map_prefix + '_TypeDef'

    # Register offset defines
    w(f'/* {"=" * 73} */\n')
    w(f'/* Register Offsets\n')
    w(f' * {"=" * 73} */\n\n')
    for reg in regs:
        w(f'#define {map_prefix}_{reg["name"]}_OFFSET  0x{reg["offset"]:03X}U\n')
    w('\n')

    # Per-register field defines
    for reg in regs:
        reg_prefix = f'{map_prefix}_{reg["name"]}'

        # Skip pure reserved-only registers
        real_fields = [f for f in reg['fields']
                       if not f['name'].startswith('RSVD')]
        if not real_fields:
            continue

        w(f'/* {"─" * 73} */\n')
        short_desc = reg['desc'].split('\n')[0][:70] if reg['desc'] else ''
        w(f'/* {reg["name"]} (0x{reg["offset"]:03X}) — {short_desc}\n')
        w(f' * {"─" * 73} */\n\n')

        for f in reg['fields']:
            if f['name'].startswith('RSVD'):
                continue

            fname = f'{reg_prefix}_{f["name"]}'
            mask = ((1 << f['width']) - 1) << f['low']

            w(f'#define {fname}_Pos    {f["low"]}U\n')
            w(f'#define {fname}_Msk    (0x{mask:X}UL)\n')
            if f['width'] > 1:
                field_mask = (1 << f['width']) - 1
                w(f'#define {fname}_Wid    {f["width"]}U\n')
            if f['reset'] != 0:
                w(f'#define {fname}_Rst    0x{f["reset"]:X}U\n')
            w('\n')

    # Typedef struct
    w(f'/* {"=" * 73} */\n')
    w(f'/* Register Struct\n')
    w(f' * {"=" * 73} */\n\n')
    w(f'typedef struct {{\n')

    prev_end = 0  # Track byte offset for padding
    for i, reg in enumerate(regs):
        # Insert padding for gaps
        if reg['offset'] > prev_end:
            gap_words = (reg['offset'] - prev_end) // 4
            if gap_words > 0:
                w(f'         uint32_t RESERVED_{prev_end:03X}[{gap_words}];\n')

        qual = reg_qualifier(reg['fields'])
        real_fields = [f for f in reg['fields']
                       if not f['name'].startswith('RSVD')]
        short = real_fields[0]['name'] if len(real_fields) == 1 else ''

        w(f'    {qual} uint32_t {reg["name"]};')
        w(f'  /* 0x{reg["offset"]:03X} */\n')

        prev_end = reg['offset'] + 4

    w(f'}} {struct_name};\n\n')

    w(f'#ifdef __cplusplus\n}}\n#endif\n\n')
    w(f'#endif /* {guard} */\n')

    return out.getvalue()


# ── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Generate CMSIS-style C headers from SystemRDL files.'
    )
    parser.add_argument(
        'rdl_files', nargs='+',
        help='SystemRDL source files to compile.'
    )
    parser.add_argument(
        '-o', '--output', required=True,
        help='Output C header file path.'
    )
    parser.add_argument(
        '-t', '--top', default=None,
        help='Top-level addrmap name to elaborate (default: last compiled).'
    )
    parser.add_argument(
        '-g', '--guard', default=None,
        help='Include guard name (default: derived from output filename).'
    )
    parser.add_argument(
        '--no-preprocess', action='store_true',
        help='Skip the RDL preprocessor (for already-compliant files).'
    )
    parser.add_argument(
        '--python', default=None, metavar='PATH',
        help='Also generate a Python module with register metadata '
             '(offsets, access types) for HAL bridge testing.'
    )
    args = parser.parse_args()

    rdlc = RDLCompiler()

    temp_files = []
    try:
        for rdl_path in args.rdl_files:
            if not os.path.isfile(rdl_path):
                print(f'Error: {rdl_path} not found', file=sys.stderr)
                sys.exit(1)

            if not args.no_preprocess:
                with open(rdl_path) as f:
                    source = f.read()
                source = preprocess_rdl(source)
                # Write preprocessed source to a temp file
                tmp = tempfile.NamedTemporaryFile(
                    mode='w', suffix='.rdl', delete=False,
                    dir=os.path.dirname(rdl_path) or '.',
                )
                tmp.write(source)
                tmp.close()
                temp_files.append(tmp.name)
                rdlc.compile_file(tmp.name)
            else:
                rdlc.compile_file(rdl_path)

    finally:
        for tmp_path in temp_files:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    root = rdlc.elaborate(top_def_name=args.top)

    # When elaborated without -t, root is the anonymous $root wrapper.
    # Unwrap to the actual addrmap if there's exactly one child addrmap.
    addrmap_name = root.type_name or root.inst_name
    if addrmap_name == '$root':
        children = list(root.children())
        if len(children) == 1 and isinstance(children[0], AddrmapNode):
            root = children[0]
            addrmap_name = root.type_name or root.inst_name

    regs = collect_registers(root)
    if not regs:
        print(f'Warning: no registers found in {addrmap_name}', file=sys.stderr)

    guard = args.guard
    if guard is None:
        base = os.path.basename(args.output).upper()
        guard = re.sub(r'[^A-Z0-9]', '_', base)

    header = generate_header(addrmap_name, regs, guard)

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w') as f:
        f.write(header)

    print(f'Generated {args.output}: {len(regs)} registers from {addrmap_name}')

    # ── Optional Python metadata output ──────────────────────────────────
    if args.python:
        py_out = generate_python_meta(addrmap_name, regs)
        os.makedirs(os.path.dirname(args.python) or '.', exist_ok=True)
        with open(args.python, 'w') as f:
            f.write(py_out)
        print(f'Generated {args.python}: register metadata for HAL bridge')


def generate_python_meta(addrmap_name: str, regs: list) -> str:
    """Generate a Python module with register offset metadata for HAL bridge."""
    out = StringIO()
    w = out.write

    w(f'"""Auto-generated register metadata for {addrmap_name}.\n\n')
    w(f'Generated by scripts/rdl2c.py — do not edit.\n')
    w(f'Used by hal_bridge.py for shadow-buffer pre-population and replay.\n')
    w(f'"""\n\n')

    # Compute register space size (last register offset + 4)
    if regs:
        reg_space = max(r['offset'] for r in regs) + 4
    else:
        reg_space = 0

    w(f'ADDRMAP_NAME = "{addrmap_name}"\n')
    w(f'REG_SPACE_SIZE = 0x{reg_space:03X}\n\n')

    # Classify registers by access type
    rw_offsets = []
    ro_offsets = []
    wo_offsets = []
    trigger_offsets = []

    for reg in regs:
        fields = reg['fields']
        qual = reg_qualifier(fields)

        if qual == '__IO':
            rw_offsets.append(reg['offset'])
        elif qual == '__I ':
            ro_offsets.append(reg['offset'])
        elif qual == '__O ':
            wo_offsets.append(reg['offset'])

        # Detect trigger registers: any field with singlepulse/swmod semantics
        # Heuristic: register has a single-bit field AND is RW at offset < 0x020
        # More reliable: check for 'singlepulse' in field desc or name contains
        # 'CTRL' or 'COMMAND'
        reg_name_upper = reg['name'].upper()
        if any(kw in reg_name_upper for kw in ('CTRL', 'COMMAND', 'DOORBELL')):
            if qual in ('__IO', '__O '):
                trigger_offsets.append(reg['offset'])

    def _fmt_list(offsets):
        if not offsets:
            return '[]'
        items = ', '.join(f'0x{o:03X}' for o in sorted(offsets))
        return f'[{items}]'

    w(f'# Read-write registers (pre-populated for RMW, diffed for replay)\n')
    w(f'RW_OFFSETS = {_fmt_list(rw_offsets)}\n\n')
    w(f'# Read-only registers (pre-populated only, never replayed)\n')
    w(f'RO_OFFSETS = {_fmt_list(ro_offsets)}\n\n')
    w(f'# Write-only registers\n')
    w(f'WO_OFFSETS = {_fmt_list(wo_offsets)}\n\n')
    w(f'# Trigger registers (replayed last to preserve write ordering)\n')
    w(f'TRIGGER_OFFSETS = {_fmt_list(trigger_offsets)}\n\n')

    # Per-register detail dict
    w(f'# Per-register metadata: name, offset, access qualifier\n')
    w(f'REGISTERS = [\n')
    for reg in regs:
        qual = reg_qualifier(reg['fields']).strip()
        w(f'    {{"name": "{reg["name"]}", "offset": 0x{reg["offset"]:03X}, '
          f'"access": "{qual}"}},\n')
    w(f']\n')

    return out.getvalue()


if __name__ == '__main__':
    main()

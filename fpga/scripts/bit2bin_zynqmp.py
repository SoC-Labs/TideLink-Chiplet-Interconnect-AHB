#!/usr/bin/env python3
"""Convert a Vivado .bit to a raw .bin for the ZynqMP fpgautil PL-load path.

Strips the variable-length .bit ASCII field header and copies the raw
configuration payload **VERBATIM** — it does NOT byte-swap.

WHY A SECOND CONVERTER (this is the OPPOSITE of fpga/scripts/bit2bin.py)
-----------------------------------------------------------------------
`bit2bin.py` byte-swaps every 32-bit word for the Zynq-7000 `zynq-fpga`
driver (the /lib/firmware + /sys/class/fpga_manager/fpga0/firmware path).
That byte-swap is the *zynq-fpga* format. On ZynqMP (KR260 / Kria K26) the
PL is loaded with `fpgautil -b <bin> -f Full`, whose zynqmp-fpga backend
wants the payload in its NATIVE byte order. Feeding a KR260 a byte-swapped
`.bin` silently produces a bad PL load (the design loads but behaves wrong).
So KR260 must NEVER use bit2bin.py — it uses this converter instead.

.bit field-header layout (all field lengths big-endian):

    u16 len | <len-byte magic>            (0x0009 0f f0 0f f0 0f f0 0f f0)
    u16     | 0x0001
    'a' u16 len | <design-name string>
    'b' u16 len | <part string>
    'c' u16 len | <build-date string>
    'd' u16 len | <build-time string>
    'e' u32 len | <raw configuration payload ...>   <-- payload after the u32

The payload begins immediately after the 'e' field's 4-byte length, and the
'e' length equals the payload byte count. We parse the fields (robust to any
header size) and verify that invariant, rather than hard-coding an offset.
For the current KR260 builds the header is 127 bytes (payload = file - 127),
which is exactly what the KR260 board docs describe.

Usage:
    bit2bin_zynqmp.py <input.bit> <output.bin>
"""

import struct
import sys


def convert(bit_path, bin_path):
    with open(bit_path, "rb") as f:
        data = f.read()

    pos = 0
    try:
        # Leading magic block: u16 length, that many bytes, then a u16 (0x0001).
        (mlen,) = struct.unpack_from(">H", data, pos)
        pos += 2 + mlen
        (_flag,) = struct.unpack_from(">H", data, pos)
        pos += 2

        # String fields a/b/c/d (u16-length), in order.
        for tag in (b"a", b"b", b"c", b"d"):
            key = data[pos:pos + 1]
            pos += 1
            if key != tag:
                raise SystemExit(
                    f"ERROR: expected .bit field '{tag.decode()}' at offset "
                    f"{pos - 1}, found {key!r} in {bit_path} (not a Vivado .bit?)")
            (slen,) = struct.unpack_from(">H", data, pos)
            pos += 2 + slen

        # Payload field 'e' (u32-length).
        key = data[pos:pos + 1]
        pos += 1
        if key != b"e":
            raise SystemExit(
                f"ERROR: expected .bit field 'e' (payload) at offset {pos - 1}, "
                f"found {key!r} in {bit_path}")
        (plen,) = struct.unpack_from(">I", data, pos)
        pos += 4
    except struct.error as exc:
        raise SystemExit(f"ERROR: truncated .bit header in {bit_path}: {exc}")

    payload = data[pos:]
    if len(payload) != plen:
        raise SystemExit(
            f"ERROR: .bit field 'e' declares {plen} payload bytes but "
            f"{len(payload)} follow the {pos}-byte header in {bit_path} "
            f"(truncated / not a valid bitstream?)")

    # The configuration stream must contain the Xilinx sync word 0xAA995566
    # (big-endian, native order — a byte-swapped or non-bitstream payload
    # won't have it) within the leading dummy/bus-width-detect padding.
    if b"\xaa\x99\x55\x66" not in payload[:256]:
        raise SystemExit(
            f"ERROR: no 0xAA995566 sync word in the first 256 payload bytes of "
            f"{bit_path} — not a native-order configuration stream "
            f"(byte-swapped input, or not a bitstream). Refusing to write.")

    with open(bin_path, "wb") as f:
        f.write(payload)

    print(f"Wrote {bin_path}: {len(payload)} bytes "
          f"(stripped {pos}-byte header from {bit_path}; NO byte-swap — ZynqMP/fpgautil)")


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    convert(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()

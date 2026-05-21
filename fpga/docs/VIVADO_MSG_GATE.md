# TideLink FPGA — Vivado CRITICAL WARNING gate

## Why this exists

On 2026-05-21 we lost a day to a silent constraint failure. The Vivado
build emitted three classes of `CRITICAL WARNING` during synth / impl,
the run still reported "Implementation status: route_design Complete"
and "PASSED", a bitstream was written, deployed, and produced
**0/16 lane lock** on hardware versus 14/16 on the previous morning's
bitstream. The XDC constraints whose effects went missing were:

| ID                       | Symptom                                                                               |
|--------------------------|---------------------------------------------------------------------------------------|
| `[Constraints 18-359]`   | `create_generated_clock` matched > 1 master pin → derived clock silently NOT created  |
| `[Vivado 12-4739]`       | `set_input/output_delay … -clock pad_clk_tx_fwd` → no valid object → no-op constraint |
| `[Designutils 20-1307]`  | XDC `if` / `catch` / `file` / `info` / `get_files` not supported → block silently skipped |
| `[Common 17-55]`         | `set_property` selector returned empty → property never applied                       |
| `[Vivado 12-1411]`       | `get_pins` / `get_cells` filter empty → constraint becomes a no-op                    |

In every case the constraint was *parsed*, *complained about*, and
*silently dropped*. The build did not fail. That is the failure mode
this gate exists to prevent.

## What the gate does

There are two layers, both installed at the top of
`fpga/build_design.tcl` and mirrored in `fpga/vivado_ip/package_tidelink_ip.tcl`:

### Layer 1 — `set_msg_config -new_severity ERROR` (always on)

For each known-bad ID above, we promote it from `CRITICAL WARNING` to
`ERROR`. Vivado then hard-errors the moment the message is emitted —
the offending XDC line dies at the source, not silently 20 minutes
later in `runme.log`.

**This layer cannot be disabled by an env-var.** The IDs are surgical:
each one was observed to cause a real, ship-stopping regression. If you
think you have a legitimate reason to emit one of these, add a
`set_msg_config -id <ID> -suppress` *immediately after* the promotion
block with a justification comment, scoped narrowly. Do not remove the
promotion itself.

### Layer 2 — Post-phase `CRITICAL_WARNING` count check

After `synth_1` and after `impl_1`, the build calls
`tidelink_check_cw_count` which queries:

```tcl
set cw_count [get_msg_config -count -severity {CRITICAL WARNING}]
```

If `cw_count > 0`, the build dumps the message-rule table and
`exit 1`s. This is the generic backstop for CW classes we have not yet
enumerated in Layer 1.

This layer **is** bypassable, via:

```
export FPGA_ALLOW_CRITICAL_WARNINGS=1
```

intended for exploratory builds where you want to see what new CWs a
WIP constraint produces. **Layer 1 promotions are still active when
this env-var is set** — only the catch-all count check is skipped.

## When you hit a real CW

Decide:

1. **Bug in a constraint** → fix the XDC. Most of the time this is the
   answer.
2. **Constraint correct but Vivado mis-classifies it** → suppress that
   specific ID with `set_msg_config -id <ID> -suppress` and a comment
   explaining *why*. Do not suppress in the XDC — do it in the build
   script so it is reviewable in `git log`.
3. **New class of silent-failure CW** → promote it to ERROR by adding
   another line to the Layer 1 block in **both**
   `fpga/build_design.tcl` and `fpga/vivado_ip/package_tidelink_ip.tcl`,
   and add it to the table at the top of this doc.

## How to inspect what the gate caught

In the failing run's `runme.log` look for lines starting `ERROR:`
emitted in tandem with one of the promoted IDs. Example:

```
ERROR: [Designutils 20-1307] Command 'if' is not supported in the xdc
constraint file. [.../pynq_z2_tidelink_idelay.xdc:48]
```

The XDC path + line number is the fix site.

## Adding a new promotion (checklist)

- [ ] Confirm the message ID is `[Vendor ##-####]` (visible in `runme.log`)
- [ ] Confirm the failure mode is *silent constraint drop* (not e.g. a
      power-estimate warning)
- [ ] Add `set_msg_config -id "<ID>" -new_severity ERROR` to the
      Layer 1 block in **both** TCL files
- [ ] Add a one-line rationale comment above the new line
- [ ] Add a row to the table at the top of this doc
- [ ] Commit on a branch with the failing build's bitstream archived
      alongside the regression report, so the next person can find this
      doc by `git log --grep`

## File index

| File                                          | Role                                                  |
|-----------------------------------------------|-------------------------------------------------------|
| `fpga/build_design.tcl`                       | Layer 1 install + `tidelink_check_cw_count` + call sites |
| `fpga/vivado_ip/package_tidelink_ip.tcl`      | Layer 1 install for the OOC IP-packaging context      |
| `fpga/docs/VIVADO_MSG_GATE.md`                | This document                                         |

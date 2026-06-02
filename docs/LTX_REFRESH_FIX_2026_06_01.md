# LTX Refresh Fix Investigation — 2026-06-01

Status: **STEP 10b is NOT the bug** — content match proven. Root cause is
elsewhere. Recommend simplifying 10b to a `file copy` and looking outside
`build_design.tcl` for the HW Manager mismatch.

Target inspected: `pynq-z2-pair-mmcmbypass-oddr-all` (Build #11 artefacts on disk).

## 1. Where Vivado auto-emits the canonical .ltx

`imp/fpga/project/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_project.runs/impl_1/tidelink_design_wrapper.ltx`

(also a 100% duplicate at `…/impl_1/debug_nets.ltx`)

Both written by Vivado at the end of `impl_1` 1 second after the .bit:

```
1780311885   impl_1/tidelink_design_wrapper.bit
1780311886   impl_1/debug_nets.ltx
1780311886   impl_1/tidelink_design_wrapper.ltx
1780311932   output/tidelink_design_wrapper.ltx       <- STEP 10b refresh, +47 s later
```

Note: `impl_1/runme.log` contains **no explicit `write_debug_probes` call** —
Vivado emits the .ltx internally as part of route/finalisation, not via a
visible Tcl step.

## 2. Diff: STEP 10b output vs Vivado auto

| File | Size (B) | Lines | sha256 (prefix) |
|------|---------:|------:|-----------------|
| `output/.../tidelink_design_wrapper.ltx`      | 129 137 | 4053 | `39d5390258…` |
| `runs/impl_1/tidelink_design_wrapper.ltx`     | 129 137 | 4053 | `39d5390258…` |
| `runs/impl_1/debug_nets.ltx`                  | 129 137 | 4053 | `39d5390258…` |

**Byte-identical.** STEP 10b's `open_checkpoint <routed.dcp>` +
`write_debug_probes` reproduces Vivado's own output exactly. The hypothesis
that `open_checkpoint` loses synth-side port state is **falsified** for this
build.

Cross-target sanity: `pair-mmcmbypass-oddr-all`, `…-flip-all`, and the
legacy `pair-all` output all share the **same .ltx sha256** (UUID
`8C7A4108CECD5B949181BD3AEA6472BC`) — i.e. master and slave deploy the same
debug-core layout, and that UUID is exactly the one HW Manager reports.

## 3. Proposed `build_design.tcl` edit (do NOT apply yet)

Replace lines 324–348 of `fpga/build_design.tcl` with a plain copy:

```tcl
# STEP 10b: copy Vivado's auto-emitted impl_1 .ltx into the output dir.
# Vivado writes a fully-consistent probes file at the end of impl_1
# (sibling to the .bit, 1 s after it). It is byte-identical to what we
# get from open_checkpoint <routed.dcp> + write_debug_probes, so just
# copy it — no need to re-open the design.
if { [info exists env(FPGA_INSERT_DEBUG_CORE)] && $env(FPGA_INSERT_DEBUG_CORE) == "1" } {
    set runs_ltx [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_wrapper.ltx]
    if { [llength $runs_ltx] > 0 } {
        file copy -force [lindex $runs_ltx 0] [file join $output_dir tidelink_design_wrapper.ltx]
        puts "Copied auto .ltx from impl_1 to $output_dir/tidelink_design_wrapper.ltx"
    } else {
        puts "WARN: no impl_1/*.ltx found — output .ltx may be stale synth-stage copy"
    }
}
```

Benefits: avoids `close_design`/`open_checkpoint` (~30–60 s saved per build);
removes any future risk of `write_debug_probes` semantics drift; output
.ltx is guaranteed equal to what Vivado used internally.

## 4. Why `open_checkpoint` "looked" wrong (but actually wasn't)

The hypothesis in the brief — that `open_checkpoint` of a routed DCP loses
synth-stage port declarations — is incorrect for current Vivado. The routed
DCP fully captures debug-core port mapping (Vivado serialises it under the
`debug_core` netlist objects, not as a side-file). `write_debug_probes`
after `open_checkpoint` produces the same JSON as Vivado's own internal
emission — proven by sha256 above.

## 5. So why does HW Manager still report mismatch?

**The .ltx is consistent with the .bit on disk.** The 67-probe .ltx
describes 67 debug ports (indices 0–66, e.g. portIndex 45 = `hw_seq_num_r`
[15:0] in PTP). The HW Manager warning ("port index 45 … does not exist")
therefore implies one of:

a. **Wrong .bit on device.** A stale bit (e.g. previous build, before the
   debug-core change) is loaded on the FPGA — `tidelink_deploy/tidelink.bit`
   on mapstone-dev not refreshed in lockstep with `tidelink.ltx`. The .ltx
   was newly copied but the .bit is older; UUIDs happen to collide because
   the synth-stage core is stable across small RTL deltas (`u_dbg_int` UUID
   is generated from core name/structure, not full netlist hash).

b. **Probe drop between routed DCP and bitstream.** Possible but unlikely —
   `route_status.rpt` shows 0 nets with routing errors, 61 449 fully
   routed. `INSTRUMENT: debug core successfully implemented` for 67 probes.

c. **HW Manager loading an older .ltx from cache.** Unlikely if the deploy
   pipeline is freshly copied.

**Recommended next debug step (outside `build_design.tcl`):**
- On mapstone-dev (or wherever HW Manager runs), sha256 the deployed
  `/tmp/tidelink_deploy/tidelink.{bit,ltx}` and compare against the
  `imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink.{bit,
  tidelink_design_wrapper.ltx}` on the build host. Hypothesis (a) is by
  far the most likely.
- If they match, run `report_debug_core` on the routed DCP
  (`output/tidelink_design_wrapper_routed.dcp`) and compare probe count
  to the .ltx — confirms whether (b) ever happens.

## 6. Caveats

- The .ltx is **shared between master and slave** (same sha256 across
  `…-all`, `…-flip-all`, `…-pair-all`). One .ltx per pair is sufficient —
  no need to stage a different .ltx for each die.
- If a build is run with `FPGA_INSERT_DEBUG_CORE=0`, no .ltx is produced
  by impl_1 — the proposed code already gates on that env var.
- If Vivado moves `impl_1/*.ltx` to a different filename in a future
  release, the `glob` pattern keeps it robust (`*_wrapper.ltx`).

## 7. Bottom line

STEP 10b is benign-but-redundant. Simplifying it removes one moving part
and clarifies that the build-side .ltx is correct. Focus the actual
mismatch debug on the **deploy pipeline + device state**, not the build.

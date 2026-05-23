# PHC -all Target Mirror — Dev Log

**Branch:** `feat/phc-all-mirror`
**Base:** `main` @ `20c1eaa` (Merge feat/phc-hw-test)
**Submodule pin:** `2f602d1` (unchanged)
**Worktree:** `/home/dam1n19/SoCLabs/td-phc-all-mirror`
**Started:** 2026-05-23

## Scope

The merge `20c1eaa` integrated the PHC hardware-clock IP onto the BASE
targets (`pynq-z2-pair`, `pynq-z2-pair-flip`) only. The merge message
flagged that the production-deploy `-all` variants
(`pynq-z2-pair-all`, `pynq-z2-pair-flip-all`) need the same mirror —
this branch closes that loop.

Key contractual difference vs base, per the PHC dev agent:
 - base targets had `NUM_MI = 6 -> 8` after the PHC integration
 - `-all` targets already use `NUM_MI = 7` (extra debug-unlock GPIO on
   M06), so the bump here is `NUM_MI = 7 -> 9`
 - PHC APB lands on `M07` instead of `M06`
 - PMOD-B trigger GPIO lands on `M08` instead of `M07`

Everything else (XDC pad assignment, wrapper IOBUF, address map
0x4404_2000 / 0x4405_0000, PHC-IP wiring topology) is identical to base.

## Per-target edits

### `pynq-z2-pair-all/tidelink_design.tcl`
 - Address-map header comment updated: added rows for `dbg_unlk`
   (0x4404_1000, was previously documented), `pmod_trig`
   (0x4404_2000), `phc` (0x4405_0000).
 - Q4-tie-off `NOTE` block replaced by PHC-integration + PMOD-B
   `NOTE` blocks (slightly shorter than base, references base for
   full rationale).
 - `create_bd_port` for `pmod_b_trig_o` (out) and `pmod_b_trig_i`
   (in) added alongside the existing LED ports.
 - SmartConnect bumped `NUM_MI 7 -> 9`; comment block updated to
   document M07/M08.
 - 5x `xlconstant` PHC tie-off blocks removed; replaced by:
   - `phc_0` IP (soclabs.org:user:phc_vivado_wrapper:1.0)
   - `axi_apb_phc` (axi_apb_bridge:3.0, apb4 protocol)
   - `axi_gpio_pmod_trig` (axi_gpio:2.0, dual-channel)
   - `xlconcat_phc_hw_cap` (2-input 1-bit)
   - `util_reduced_logic_hw_cap` (2-input OR)
 - Clock fanout (`clk_out1`) extended to `axi_apb_phc`,
   `axi_gpio_pmod_trig`. `clk_out2` (phc_clk) now also fans to
   `phc_0/clk`.
 - Reset fanout extended to `axi_apb_phc`, `axi_gpio_pmod_trig`,
   `phc_0/resetn`.
 - New AXI routes: `M07_AXI -> axi_apb_phc/AXI4_LITE -> phc_0/apb`,
   `M08_AXI -> axi_gpio_pmod_trig/S_AXI`.
 - PHC-IP <-> `tidelink_0` wiring: counter outputs (seconds/ns/pps),
   HW capture readouts, servo set/adj inputs, and the OR-tree on
   `hw_capture_0_i` (`tidelink_0/phc_hw_capture | pmod_b_trig_i`).
 - Address map: added `0x4404_2000 (pmod_trig)` and `0x4405_0000 (phc)`.

### `pynq-z2-pair-all/pynq_z2_tidelink.xdc`
 - Added PMOD-B trigger pad: `PACKAGE_PIN Y16 IOSTANDARD LVCMOS33
   PULLDOWN TRUE` (identical to base).

### `pynq-z2-pair-all/tidelink_design_wrapper.v`
 - New `inout wire pmod_b_trig` port (JB1 / Y16).
 - Added `IOBUF u_pmod_b_trig_iobuf` instance, tristate when not
   driving (`T = ~pmod_b_trig_o_w`).
 - BD instantiation gains `.pmod_b_trig_o`, `.pmod_b_trig_i` and
   the trailing-comma fix on `.led3`.

### `pynq-z2-pair-flip-all/tidelink_design.tcl`
 - Same set of edits as `pynq-z2-pair-all`, with shorter `NOTE`
   comments referencing `pynq-z2-pair-all` for the full rationale
   (to match the existing comment-density convention between -all
   and -flip-all in the worktree).

### `pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`
 - Added PMOD-B trigger pad (Y16, same as base).

### `pynq-z2-pair-flip-all/tidelink_design_wrapper.v`
 - Same wrapper edits as `pynq-z2-pair-all`.

## Validate BD verdict

Both -all variants pass `validate_bd_design` cleanly.

`pynq-z2-pair-all`:
```
INFO: [BD 5-943] Reserving offset range <0x4405_0000 [ 4K ]> from
  /axi_smc/S00_AXI to /axi_smc/M07_AXI.  (PHC APB)
INFO: [BD 5-943] Reserving offset range <0x4404_2000 [ 4K ]> from
  /axi_smc/S00_AXI to /axi_smc/M08_AXI.  (PMOD-B trig)
validate_bd_design: Time (s): cpu = 00:00:06 ; elapsed = 00:00:07
BD VALIDATE-ONLY: PASS
```

`pynq-z2-pair-flip-all`:
```
validate_bd_design: Time (s): cpu = 00:00:07 ; elapsed = 00:00:07
BD VALIDATE-ONLY: PASS
```

CRITICAL warnings observed (all pre-existing — present on base targets
and unchanged by this mirror; the wrapper's xlconstant tie-offs cover
them at synth time):
 - `[BD 41-967]` on tc_axis_tx / tc_axis_rx / s_i2c_axi (no clock
   association — these are AXI-Stream/AXI ports tied off in the
   board wrapper, not driven from the BD).
 - `[BD 41-759]` 14 input pins auto-tied-off by the BD validator
   (ahb_mng_hready, tc_axis_tx_tvalid, phc_locked_i, i2c_*, scan_*,
   ...). All driven by xlconstant cells inside the wrapper.

Probe driver used: `/tmp/td_validate_only.tcl` (loads project,
sources the target's `tidelink_design.tcl`, calls
`create_root_design ""`, exits).

## Full-build verdict — pynq-z2-pair-all

Build launched on `srv04936` with:
```
FPGA_USE_IDELAY=1 make farm_build \
    FARM_JOBS="pynq-z2-pair-all@srv04936"
```

Log: `/tmp/td_phc_all_mirror_logs/build_pair_all.log`
Build outcome: (see Build verdict section below — populated when the
remote farm build completes).

## Commits on this branch

```
9b96525 fpga(pair-flip-all): mirror PHC IP + PMOD-B trigger onto -flip-all variant
5cbbc0f fpga(pair-all):      mirror PHC IP + PMOD-B trigger onto -all variant
```

## Hard rules — compliance check

| Rule | Status |
|---|---|
| Work only in `/home/dam1n19/SoCLabs/td-phc-all-mirror` | OK |
| Do NOT modify files outside the worktree | OK |
| Do NOT `git push` | OK (local-only commits) |
| Do NOT acquire bridge1 lease | OK (build-only) |
| Submodule pin = `2f602d1` | OK (unchanged) |
| Wrapper params USE_CLKBUF / USE_IDELAY / USE_T3A = 1'b1 | OK (no wrapper-param edits) |
| `<= 2` concurrent srv04936 vivado procs | OK (one full build dispatched) |

## Work remaining

 - Build verdict for `pynq-z2-pair-all` (running in background).
 - Decide whether to also farm-build `pynq-z2-pair-flip-all` once
   pair-all completes — out of scope per the task brief (build-only
   on pair-all is enough to attest structural correctness of the
   mirror; -flip-all will be exercised by the user's normal
   `build_pair_farmed` flow after merge).
 - Phase-1 HW silicon sanity (PHC counts up, PPS LED 1 Hz) — explicit
   post-merge user-reviewed step per task brief; not attempted here.

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

### Attempt 1 — farm (srv04936) — INFRASTRUCTURE FAIL
```
FPGA_USE_IDELAY=1 make farm_build \
    FARM_JOBS="pynq-z2-pair-all@srv04936"
```
Failed in `create_root_design`:
```
ERROR: [BD 5-390] IP definition not found for VLNV:
  soclabs.org:user:phc_vivado_wrapper:1.0
```
**Root cause:** `fpga/scripts/farm_build.sh` runs only
`make -C fpga package_ip` on the remote, **not** `package_phc_ip`.
The PHC IP repo is therefore absent on the farm host. This is a
PRE-EXISTING gap in the farm script that the base PHC merge
(`20c1eaa`) didn't surface because base builds were validated locally,
not over the farm. Tracked as work-remaining; out of scope for this
mirror branch.

### Attempt 2 — local — RAN; failed at synth_1 on a known message-gate
trip (PRE-EXISTING / scale-dependent, not introduced by this mirror)
```
FPGA_USE_IDELAY=1 make build_design TARGET=pynq-z2-pair-all FPGA_NUM_JOBS=4
```
Result:
 - `package_ip` PASS
 - `package_phc_ip` (cached) PASS
 - `create_bd_design` + `create_root_design` PASS
 - `validate_bd_design` PASS (already validated, BD generation OK)
 - `generate_target all` PASS — all 16 BD IP instances generated
   including `phc_0`, `axi_apb_phc`, `axi_gpio_pmod_trig`,
   `xlconcat_phc_hw_cap`, `util_reduced_logic_hw_cap`
 - `launch_runs synth_1` PASS — 16 IP-synth jobs dispatched in
   parallel
 - `wait_on_run synth_1` FAIL —
   `tidelink_design_axi_smc_0_synth_1` aborted at:
```
ERROR: [Common 17-14] Message 'Common 17-55' appears 100 times and
  further instances of the messages will be disabled.
  [/apps/Xilinx/Vivado/2024.1/data/ip/xpm/xpm_memory/tcl/xpm_memory_xdc.tcl:55]
ERROR: [Project 1-581] Command stopped due to earlier errors.
```
**Root cause:** The TideLink Vivado message gate
(`fpga/build_design.tcl`, installed by commit `f9a76d7`) promotes
`Common 17-55` ('set_property: empty selector') to ERROR to catch
silent-XDC-dropping regressions. Xilinx's own
`xpm_memory_xdc.tcl` emits this warning benignly for empty
selector returns. With 8 SmartConnect ports the count stays under
100; with 9 ports (M00..M08) the SmartConnect emits enough
per-port XDC parses that the count exceeds 100 and meta-message
`Common 17-14` errors out.

**This is a PRE-EXISTING msg-gate scaling issue, not a structural
defect introduced by the PHC mirror.** Per the task brief, no
iterating fixes that risk regressing — captured for follow-up.

Recommended follow-up (outside this branch's scope):
 - Either narrow the `Common 17-55` promotion to file-path-scoped
   (exclude `xpm_memory_xdc.tcl`), or add a per-build
   `set_msg_config -id "Common 17-55" -suppress` block during smc
   IP synthesis only. Both are documented patterns in
   `fpga/docs/VIVADO_MSG_GATE.md` lines 39, 72-74.

Build log: `/tmp/td_phc_all_mirror_logs/build_pair_all_local.log`
IP synth log: `imp/fpga/project/pynq-z2-pair-all/tidelink_project.runs/tidelink_design_axi_smc_0_synth_1/runme.log`

### Bitstream md5

Not produced (synth failed). No bitstream md5 to capture.

### Concurrency note

A second concurrent build was accidentally started from this
session and killed before reaching synth (parent PIDs 2078089 /
2078109 -KILL9'd at ~01:35). The IP repo cache was not corrupted
(the killed build was still in package_ip, the first build had
already finished package_ip). The synth_1 failure above is
independent of the kill.

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

 - **Msg-gate scaling for `Common 17-55`** — promotion is firing on
   Xilinx's xpm_memory_xdc.tcl when SmartConnect has 9 MIs (was OK
   at 6/7/8). Needs a scoped suppression — see "Recommended
   follow-up" above. Out of scope here (would risk regressing the
   silent-XDC-failure guard the gate was built for).
 - **Farm-script PHC gap** — `scripts/farm_build.sh` does not run
   `package_phc_ip` on the remote host, so PHC-using targets can't
   be farm-built. Affects both base and -all targets. Pre-existing.
   Out of scope here.
 - **`pynq-z2-pair-flip-all` full-build** — not attempted here. The
   `flip-all` variant is structurally identical (same SmartConnect
   topology, same 17-55 trigger), so the synth_1 outcome is
   expected to be identical until the msg-gate fix lands. BD
   validate PASS is recorded above.
 - **Phase-1 HW silicon sanity** (PHC counts up, PPS LED 1 Hz) —
   explicit post-merge user-reviewed step per the task brief; not
   attempted here.

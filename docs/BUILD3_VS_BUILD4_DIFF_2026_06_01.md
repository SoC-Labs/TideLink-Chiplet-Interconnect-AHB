# Build #3 → Build #4 diff archaeology — ILA-alone hypothesis test

**Date:** 2026-06-01
**Author:** archaeology agent
**Branch context:** `fix/build9-unified` (commits referenced are reachable from `feat/td-autonomy`, `main`, and current).

## 1. Summary

**HYPOTHESIS: WEAK / REFUTED.** Between Build #3 and Build #4 the source tree picked up substantive non-ILA logic changes — specifically the **autonomy Phase 1 (G1/G1b) and Phase 2 RTL** (POR-default `train_auto_en=1`, `local_swreset_pulse_w` OR-merged into `u_calibrator.swreset`, sticky `train_fail_irq_r` register), **plus a `tidelink-gpio-phy` submodule bump that re-gated `wire_status_o` / `dead_counter` from `vote_enable` to `training_mode_w_i` and added a `training_mode_rise` reset to `match_count`/`locked_pre`**. The ILA `mark_debug` attribute additions are present but they are pure annotation. Build #4 is therefore **not** an ILA-only delta over Build #3; it is an ILA + autonomy + lane-checker delta. The doorbell wedge cannot be attributed to ILA insertion in isolation, and the autonomy `train_auto_en=1` POR default is a far stronger regressor candidate (it changes the very `SWI_TRAINING_MODE` path that Build #5 later proved is the wedge trigger).

## 2. Source commits

| Build | Source commit | Date | Branch | Notes |
|---|---|---|---|---|
| #3 | `dda0a0e` "test+gui: comprehensive TideLink stress-test web app (stress_toolkit)" | 2026-05-29 12:07 BST | feat/td-gpio-phy-integration | Confirmed by `docs/archive/BUILD3_HW_VALIDATION_2026_05_29.md` line 4. Deploy 13:00 BST. |
| #4 | best estimate `f3d6dc0` "autonomy(0c+7a)" | 2026-05-29 17:38 BST | feat/td-autonomy | Range: at minimum `34a80d2` (17:32, Phase 2 RTL) and at most `0c77f92` (17:58); ≥50 min synth+impl wall before deploy at 18:40 BST puts Build #4 source between 17:30 and 17:50 BST. |

**Bitstream sanity:** `md5sum` differs (build3 `3ee2149d…`, build4 `9285846369…`); `.hwh.build4-bak` is **absent** on mapstone-dev whereas `.hwh.build3-bak` is present (453 143 B). `strings(1)` on either `.bin` returns no commit-like text; bitstream metadata cannot independently confirm the commit. The diff inventory is therefore reconstructed from the timing window plus the BUILD3 doc's explicit SHA pin.

## 3. Diff inventory (`dda0a0e..f3d6dc0`, design-impacting paths only)

| # | Path | Category | Lines | Causal? |
|---|---|---|---|---|
| 1 | `src/rtl/tidelink_fc_adapter.sv` | A — ILA mark_debug | +15/-... attrs only | No (decoration) |
| 2 | `src/rtl/tidelink_ptp.sv` | A — ILA mark_debug | +14/-... attrs only | No (decoration) |
| 3 | `src/rtl/tidelink_top.sv` (ILA portion of `ebbde0e`) | A — ILA mark_debug | ~16 lines | No (decoration) |
| 4 | `src/rtl/fifo/tidelink_apb_regs.sv` | A — ILA mark_debug | +7/-2 attrs only | No (decoration) |
| 5 | `deps/axi-chiplet-controller` sub bump `c0a69ff → 9ad2570` | A — ILA mark_debug | submodule diff = 4 attrs in `ShortPacketToWlink.v` | No (decoration) |
| 6 | `src/rtl/local_overrides/axi_chiplet_controller.sv` (Phase G1) | **B — RTL logic** | +95/-... | **Yes — wires `local_swreset_pulse_w` into `u_calibrator.swreset` via OR-merge** |
| 7 | `src/rtl/local_overrides/axi_chiplet_controller.sv` (Phase G1b) | **B — RTL logic** | within (6) | Yes — adds sticky `train_fail_irq_r` register + W1C path at Region 8 slot 3'h3 bit[16] |
| 8 | `src/rtl/local_overrides/axi_chiplet_controller.sv` (Phase 2) | **B — RTL logic** | within (6) | **Yes — `nego_train_cfg_r` POR default changed `16'h0` → `NEGO_TRAIN_CFG_RESET = 16'h0001` (`train_auto_en=1` out of reset)** |
| 9 | `src/rtl/tidelink_top.sv` (Phase 2 + G1b plumbing) | **B — RTL logic** | +22 | Yes — exposes `train_fail_irq` output port and threads `NEGO_TRAIN_CFG_RESET` param |
| 10 | `deps/tidelink-gpio-phy` sub bump `d23a8cd → 32e8d38` (Hamming reset + WIRE_STATUS gate) | **B — RTL logic** | submodule diff: +14 / -5 in `tidelink_lane_checker_single.sv` | **Yes — resets `match_count`/`locked_pre` on `training_mode_rise` and changes `dead_counter` + `wire_status_o` clear-gate from `vote_enable` to `training_mode_w_i`** |
| 11 | `fpga/targets/pynq-z2-pair-all/{pynq_z2_tidelink,*_drc,*_timing}.xdc` (`affc4f8`) | C — XDC | +209/-21 | No — split DRC waivers + Vivado `save_constraints` round-trip reformat; verified semantically equivalent for the `set_max_delay`/`set_input_delay`/`set_bus_skew` lines |
| 12 | `syn/asic/fusion-compiler/*` | E — ASIC build flow | +49/-... | No (ASIC-only) |
| 13 | `src/rtl/{asic,fpga,generic}/tidelink_sram.sv`, `tidelink_apb_regs.sv` (top), `tidelink_returner.sv`, `tidelink_fifo*.sv`, `tidelink_fcsm_debug.sv`, `tidelink_phy_align_regs.sv` deletions (`59e35e5`) | G — Dead-code cleanup | -968 RTL + -162 SRAM mirror + -18 unused flists | No — `59e35e5` commit message confirms each delete was unreferenced by any active flist, Makefile, syn flow, cocotb env, or UVM TB |
| 14 | `Makefile` (+26/-...) | E — Build flow | small | No (mostly farm/concurrency targets; FPGA_INSERT_DEBUG_CORE gate already lived at `fpga/build_design.tcl:289`) |
| 15 | docs / cocotb / xprop rename | G | bulk | No |

## 4. Causal analysis — non-A deltas vs the doorbell wedge

### Δ-8 (highest concern) — `NEGO_TRAIN_CFG_RESET = 16'h0001` at `axi_chiplet_controller.sv:60` (Phase 2 POR default)
At Build #3 the POR value of `nego_train_cfg_r` was `16'h0000` — `train_auto_en=0`, autoneg-FSM legacy-bypassed to `ST_NEGO_DONE`. At Build #4 it POR's to `16'h0001` — `train_auto_en=1`, the FSM enters the autonomous training arm immediately out of reset. The Build #5 finding ("Build #5 functionally delivers M→S doorbells when the test does NOT write `SWI_TRAINING_MODE=1`") implicates the training-mode write path as the wedge trigger. **This Phase 2 change makes the slave already-training at the moment SW writes `SWI_TRAINING_MODE=1`** — which on every observed Build ≥4 produces the FCSM-state-7 wedge. Mechanism is timing-plausible: a back-to-back POR-training + SW-arm transition runs the lane-checker through `training_mode_rise` twice and could break the consumer-side FCSM `socl_l9_first_data_seen_rx` one-shot that L9b later targeted.

### Δ-6 — `local_swreset_pulse_w` → `u_calibrator.swreset` OR-merge at `axi_chiplet_controller.sv:1472` (Phase G1)
The G1 commit (`fb4d70d`) replaces the previously-dead `_unused_phase3_a` tie-off with an active OR into the calibrator swreset. This makes the calibrator re-trigger every time the autoneg FSM finishes a training pass — which on Build #4 happens out of reset for the first time (because of Δ-8). Plausible second-order amplifier of Δ-8.

### Δ-10 — `tidelink-gpio-phy` lane_checker re-gate
The submodule diff changes `dead_counter` and `wire_status_o` clears from `vote_enable` (which requires PATTERN lock) to `training_mode_w_i` (raw training-mode level), and resets `match_count` / `locked_pre` on `training_mode_rise`. Effect on the FC-data path is indirect — these registers feed lane swap detection, not the FCSM. Unlikely to be the primary doorbell regressor, but it changes lane-checker state at the very `training_mode_rise` events that Δ-8 now generates at POR.

### Δ-7, Δ-9 — sticky `train_fail_irq_r` register
New register + output port. Drives a new top-level IRQ. No back-path into the FC/doorbell glue. Synthesis only adds gates; cannot wedge the doorbell on its own.

### Δ-11 — XDC reformat
`affc4f8` only re-pretty-prints `create_generated_clock`, `set_output_delay`, `set_max_delay -from -to … 8.000`, etc. Semantically identical. Splits the DRC waivers into a separate file but the same waivers are sourced. Not causal.

### Δ-1..5 — ILA `mark_debug`
Per `git show ebbde0e -- src/rtl/`, every change is `(* mark_debug = "true" *)` decoration with at most one declaration split per signal. No logic. `9ad2570` submodule bump = 4 attributes on `ShortPacketToWlink.v`. The expected route-pressure / placement-disturbance effect from `u_dbg_int` insertion at `FPGA_INSERT_DEBUG_CORE=1` IS real, but it cannot be isolated from Δ-6,8,9,10 in the Build #3 → Build #4 transition.

## 5. Bitstream-level sanity check

`ssh mapstone-dev "strings /tmp/tidelink_deploy/tidelink.bin.build{3,4}-bak | grep -iE '(commit|sha|tidelink|build)'"` returned nothing in either case — our flow does not embed a USERID/USR_ACCESS commit hash into the `.bit` user-string area. **MD5s differ** (`3ee2149d…` vs `9285846369…`, and `ab87ca05…` vs `d42aba02…` for the flip target), confirming distinct synthesis runs. The **absent `.hwh.build4-bak`** is suggestive — it means at backup time we kept the Build #3 hwh as the canonical-active hwh; the Build #4 hwh either matched Build #3 or was never staged for preservation. Either way: the bitstream evidence cannot pin Build #4's source commit any tighter than the git-log timing argument.

## 6. Recommendation — what to test next

1. **De-confound the autonomy from the ILA.** Build `dda0a0e + ebbde0e + 573e767` only (cherry-pick `ebbde0e` and `573e767` onto `dda0a0e`, drop the autonomy commits `fb4d70d`, `6daf2ba`, `34a80d2`, `f3d6dc0`, and the gpio-phy submodule bump to `32e8d38`). Deploy with `FPGA_INSERT_DEBUG_CORE=1`. If doorbells still bidirectional ⇒ ILA-only hypothesis CONFIRMED. If they wedge ⇒ ILA-only hypothesis fully REFUTED and ILA is at most additive.
2. **Independently revert Δ-8 only** on `fix/build9-unified`: change `axi_chiplet_controller.sv:60` parameter default back to `16'h0000` (and bump `tidelink_top.sv:101` to match) for one farm build with FPGA_INSERT_DEBUG_CORE=1. If doorbells return: Δ-8 is the regressor.
3. **Lab sanity check (cheapest first).** Restore `/tmp/tidelink_deploy/*.build3-bak` on bridge1 + z2_02/z2_03 and re-run `deploy_pair.sh`. If Build #3 doorbells now also fail, the lab hardware has drifted (ribbon, pad, PYNQ image) and the regression analysis must be re-scoped. If they still pass, the Build #4 wedge is genuinely a source-side regression — most likely Δ-8 per §4.

---

**Total: ~1310 words** (excluding tables and code paths).

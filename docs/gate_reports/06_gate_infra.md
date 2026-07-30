# Gate-infra / meta audit (agent #6) — 2026-07-30

NOTE: agent read the MAIN CHECKOUT (on fix/v2-sync-clock-gate @ac643c8, which
predates aab7f97), so F1 is ALREADY FIXED on main/integ (18491ef/b589c24).

Findings:
- F1 CRIT (fixed on main/integ; live on fix/v2-sync-clock-gate): v2_mask_hs_bilateral in tally but not invoked -> MISS -> exit1. = the aab7f97 bug.
- F2 HIGH: NO automated SoC-integration gate. Only harness = nanosoc-ethernet-chiplet g2_soc_pair (make elab + regress, two real nanosoc_multicore_soc->chiplet_d2d_decode->tidelink_top dies), MANUAL, submodule pinned 90fe6cc (freeze-2026-07-22), NO CI.
- F3 HIGH: green-but-blind unreachability. pair BFM pins io_link_tx_tx_en HIGH (idle link unreachable). Also unreachable: link-drop+re-bring-up w/o POR (F14-B); X-init (all suites COCOTB_RESOLVE_X=ZEROS); real clock ratios/skew in BLOCKING set (blocking=EPOCH_PROFILE=zero; skew only in epoch_silicon which force-arms unused corrector); multi-master AHB contention; real SoC bus backpressure.
- F4 HIGH: silicon-faithful checks advisory-only in CI (farm-gate-sim never sets FARM_GATE_STRESS=1 -> 40ns ratio + marginal-eye are WARN not RED).
- F5 HIGH: OOC/+define/stale-IP guard never runs in CI (Tier-0.a only hashes packaged IP if imp/fpga/tidelink_ip/src exists; fresh clone skips). Checked-in copy imp/fpga/tidelink_ip/src/WavD2DGpio_v2.v synthesised by build_design; farm_gate checks V2 source PRESENCE not that define reached OOC nor that copy==src/rtl.
- F6 MED: farm_gate run_sim_stage never rm -rf sim_build (stale-simv) + shares one results.xml across stages.
- F7 MED: ratchet keys are path:line:CODE (line-based) -> any edit re-ratchets; a new latch can be absorbed during human re-ratchet. No baseline-growth gate.
- F8 LOW/MED: fifo_rx_twin2 invoked but not in tally (uncounted); v2_sustained/v2_trunc_credit/fifo_rx_twin2_tree invoked twice; 7 sim_gate_* targets not in any .PHONY (asicelab, asicelab_v2, v2_lane_position, v2_mask_hs_bilateral, v2_oddlane, v2_oddlane_negctl, xhb).
- F9 LOW: CI sources set_env.sh through a pipe (subshell) -> exported vars may not reach job shell.

14 recs, ranked. CRITICAL: #1 gate-integrity self-test (tally<->invoked desync); #5 provenance/OOC guard in CI; #2 SoC-integration CI gate. HIGH: #7 idle+link-drop harness; #8 promote silicon-ratio/eye to blocking; #6 farm_gate stale-simv; #4 weak-oracle/mutation gate; #11 V1/V2 PHY parity diff gate. MED: #3 reachability manifest; #10 ratchet hardening; #9 X-pessimism gate; #14 consumer interface-contract gate. LOW: #12 dedupe/phony; #13 sentinel liveness.
SINGLE HIGHEST-LEVERAGE: #2 SoC-integration CI gate (wire eth-chiplet make elab + g2_soc_pair against the TideLink SHA). Prereq: fix F1 first (already done on main/integ).

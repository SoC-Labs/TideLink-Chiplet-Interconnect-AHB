# cocotb liveness-oracle audit (BONUS — concurrent session, not my fan-out) — 2026-07-30

Per-suite oracle classification: BYTE-EXACT (trustworthy) vs status-only (fcsm/cal/FSM) vs count/event vs vacuous.
Good news: the shared V2 helper send_and_check (pair_v2_common.py:546-577) + burst/b2b siblings are genuine byte-exact, all-4-words (old word1-skip bug FIXED :558-564). v2_pair_sustained, lane_mask_sweep, force_recal_pair, error_injection(link_healthy both-dirs), fifo/twin2 data-integrity, fc_adapter(27/34) are byte-exact. Delta/saturation handled (perf_ctrl deltas; crc_errors diffed; no suite reads a saturating ctr as absolute liveness).

WRONGLY-TRUSTED-LIVENESS set (assert bring-up/link-up via fcsm/cal ONLY, move 0 data -> a wedged fcsm=4 link passes):
1. test_zeropoke_por (top_pair, :247-254) — THE canonical zero-poke test; cal S_DONE + fcsm==4, no packet. (= agent #4 H3)
2. test_32_die_a_first_zombie_retry (:281-288) — fcsm==4 both + cal + train_ok, no data.
3. test_v2_mask_hs_bilateral::test_00 (:199-227) — fcsm==4 + mask_hs_match, no data.
4. test_v2_onchip_pair::test_01_zeropoke_autonomy (:296-333) — mask+gate+fcsm4+cal, no data.
5. test_v2_pair_data::test_01_bilateral_linkup (:35-50) — cal+lane_locked+cr/crack+fcsm4 (mitigated: test_02/03 move data).
6. test_30_autonomous_fc_handoff (:151-186) — cr/crack/fcsm>=4 + DOORBELL_ACC!=0 (event proxy, not content).
(FSM UNIT tests that are status-only BY DESIGN and correctly scoped: tidelink_autoneg, role_strap, train_fallback, honest_mask_hs, force_recal unit, fch_apb_watchdog, v2_autonomous_sync_detect, v2_winscan_fsm.)

DISTINCT green-but-blind DEFECTS (not merely status-only):
- test_v2_onchip_pair _skip() REGISTERS AS PASS not skip (cocotb 1.7.2) :98-118 — on main all 5 bail -> 5 false PASS @0ns; the file's banner says this is how the 07-23 slave sham-gate reached silicon.
- test_v2_mask_hs_bilateral::test_01 (:236-283) — NO assert anywhere; logs error on dead-stub but cannot fail.
- test_ei_full_sweep (:220-277) — computes BYTE-EXACT/COMMITTED-WRONG/SILENT-CORRUPTION vs write_ptr ground-truth but only log.info's it — NO assertion on the class -> silent-corruption exits green. (sibling ei_lane_dropout::test_01 DOES assert no-silent-corruption.)
- fc_adapter test_qos_priority_zero_default (:1547) — `assert pkt is not None` but monitor.get() raises TimeoutError -> tautology (vacuous).
- Historical/fixed: errinj classify_recovery verdicts were discarded pre-07-18 (hard wedges green); now _assert_recovery_ok raises (:190-219).

USE IN SYNTHESIS: this is the concrete weak-oracle inventory for gate-infra rec #4 (mutation/weak-oracle audit) and #1 (gate-integrity). Actionable fixes: add asserts to onchip_pair _skip (real skip or fail), mask_hs test_01, ei_full_sweep classification; kill the fc_adapter vacuous assert.

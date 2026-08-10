# Overnight autonomous bug-remediation — 2026-08-09

Mode: multi-agent, self-paced. Regression gate BETWEEN each resolved item = `make sim_gate_regressions`
(the HW-correctness proxy). NO hardware deploy / board ops unattended. NO commits/pushes (working-tree
only, for David). Netlist fixes are SIM-PROVEN + held-for-David, never landed. Revert-on-red. Non-vacuous.

## Baseline at start
- sim_gate: 46 PASS, TL-025 (tc_pair x2) FAIL = deferred to TideChart owner, TL-024/TL-029 XFAIL waivers.
- TL-030 epoch XCHG -> XFAIL RE-BASELINED + VERIFIED (gate's only non-deferred blocker cleared).
- HW: AUTO_ANCHOR_EN=1 built+deployed but delivery still all-zeros on bare-link (necessary-not-sufficient).

## In-flight at start
- Beacon workflow (wowsdopx2): root-cause+resolve bare-link SYNC-beacon/anchor bug.
- a2l dev-message agent: actioning DEV_MESSAGE_A2L_SELFLATCH_SILICON_2026_08_09.md (TL-027).
- TL-033 agent: reproduce-first credit-underflow white-box test.

## Queue (highest first)
1. TL-033 reproduce-first credit-underflow test [in-flight]
2. TL-032 wire test_calibrator_wrap into sim_gate
3. TL-027 wire a2l suites into sim_gate (after a2l agent) + confirm
4. TL-020 / TL-022 confirm sign-off readiness
5. SIM-PROVE (hold-for-David): TL-028 FPGA RX word-clock SDC, TL-021 obs subitems, TL-026 equivalence re-confirm
6. Fold in beacon-workflow + a2l fix candidates

## Log
- (start) seeded.
- TL-033 SIM-PROVEN (non-vacuous): added white-box `test_43_credit_underflow_saturates_whitebox` (cocotb/tidelink_fifo) — deposits credit_count_r=packet_delta-1 (9<10), fires write_complete, asserts credit saturates to 0 (not 0x1FFF wrap). Non-vacuity A/B via guard-disabled RTL copy (tidelink_fifo_ctrl_noguard.sv + tidelink_fifo_noguard.flist, `make noguard`/run_redgreen_tl033.sh): SAME test FAILS on no-guard (credit_count=8191) and PASSES on shipping RTL. Full fifo suite 43/43 PASS, no regressions. Not yet wired into sim_gate (orchestrator step); no commit.

## a2l dev-message (DONE, held-for-David) — 22:2x
- Read + actioned DEV_MESSAGE_A2L_SELFLATCH_SILICON_2026_08_09.md (TL-027 + a new watchdog defect).
- MUST-FIX #1 (FPGA flist _1/_3/_5 -> local_overrides): sim-PROVEN non-vacuous (deps FAIL a2l_full=1/app_ready=0;
  override PASS a2l_full=0/app_ready=1 on all 3 nodes AW/W/B). Already in working tree (uncommitted). HELD-FOR-DAVID.
- MUST-FIX #2 (ASIC flist _1/_3/_5 -> local_overrides): APPLIED to flists/tidelink_top_full_asic_v2.flist (working
  tree, uncommitted). Same override RTL => covered by the sim proof. ⚠ CAVEAT: tapeout consumes a GENERATED flist —
  inert until the tapeout owner regenerates. HELD-FOR-DAVID.
- Silicon (dev-reported, NOT re-verified here): once wired, T3 128/128 writes + T10 128/128 reads byte-exact, no
  wedge — rank-1 self-latch cleared for sustained traffic.
- NEW SECONDARY DEFECT (David-gated, diff provided, NOT applied): state-7 NACK watchdog dead after first CRC —
  sticky socl_l7_real_crc_seen pins wdog_cnt=0 (WlinkGenericFCSM_4.v:303-305/1013-1017/1024-1025). Part-A fix
  (drop sticky gate + forward-progress proxy) sim-proven by the dev; Part-B (§6 state-7-exit) needs an attended
  die_b AW-FCSM ILA before shipping. RECOMMEND registering as a new bug (TL-035 candidate).
- R1 errinject wedge = silicon-only (does NOT reproduce in sim, dev confirmed) — do NOT chase in sim.
- ⏳ REGRESSION GATE for this item (asic_v2_elab + a2l suites) DEFERRED to the batch gate after beacon+TL-033
  finish (avoid VCS compute contention / OOM false-fails with 2 sim tasks running).

## TL-033 (credit-underflow) — DONE, SIM-PROVEN
- New white-box reproduce-first test test_43_credit_underflow_saturates_whitebox (cocotb/tidelink_fifo).
- Deposits credit_count_r=packet_delta-1, fires write_complete -> asserts saturate-to-0 (not wrap 0x1FFF).
- NON-VACUOUS (strong): guard-disabled variant tidelink_fifo_ctrl_noguard.sv FAILs (8191); shipping RTL PASSes (0).
  run_redgreen_tl033.sh = one-command A/B proof. Full FIFO suite 43/43 PASS, no regression.
- Test-only (no shipping RTL touched) => zero sim_gate regression risk. Not yet wired into sim_gate (queued).
- Held-for-David: nothing committed.

## TL-035 REGISTERED (NEW, doc-only)
- State-7 NACK watchdog dead after first CRC (sticky socl_l7_real_crc_seen). Part-A diff ready (David-gated),
  Part-B ILA-gated. decision_needed = attended die_b AW-FCSM ILA.

## BEACON WORKFLOW (DONE) — RANK-1 DELIVERY ROOT CAUSE FOUND (9 agents, sim-reproduced)
ROOT CAUSE (high-confidence, adversarial-verify verdict[0] real+nonVacuous): on the dead-I2C bare-link,
autoneg NACK-parks to ST_NEGO_DONE WITHOUT pulsing local_train_set (tidelink_autoneg.sv), so
swi_training_mode_r never rises, so the controller SYNC-config one-shot (axi_chiplet_controller.sv:2283)
NEVER FIRES -> RX SYNC detector stays at POR (lane_mask 0xFF, tol 0, sync_insert_en 0) -> all_sync_seen
(deskew:1350) unsatisfiable on the marginal eye -> reanchored/anc never latches -> delivery all-zeros.
=> AUTO_ANCHOR_EN=1 CANNOT fix it: auto_anchor_pulse ORs only insert/force/robust, NOT the lane_mask/tol
config (those are the training-gated _r regs). This is WHY the AUTO_ANCHOR rebuild delivered all-zeros.
Eth-chiplet escapes because CM0 writes 0x2128 (mask=0xE4, tol=5) + R8 + defines TD_AUTO_LANE_MASK_E4.

REPRODUCED IN SIM (non-vacuous): NEW cocotb/tidelink_autoneg_deadi2c/test_deadi2c_beacon_dark.py — dead-I2C
NACK parks ST_NEGO_DONE, saw_train_set=False, max_state=5 < ST_TRAIN_ENTER(12) despite train_auto_en=1. FAIL.
(compiles the CURRENT local_overrides/tidelink_autoneg.sv, not the stale deps the old autoneg suite uses.)

FIX APPLIED (candidate 2, build-param, NO RTL, HELD-FOR-DAVID): CONFIG.TRAIN_ENTRY_FALLBACK {1'b1} on
fpga/targets/kr260-pair-nptp/tidelink_design.tcl:474 + kr260-pair-flip-nptp:461 -> dead-I2C NACK reroutes to
ST_TRAIN_ENTER, training-entry hook pulses local_train_set -> swi_training_mode_r rises -> one-shot fires.
PROVEN at the autoneg boundary (NEW cocotb/tidelink_autoneg_rolestrap: trainfb_on lights beacon / trainfb_off
dark = non-vacuous A/B; all 4 modes PASS on untouched RTL). NOT end-to-end sim-proven (pair tb has no dead-I2C
autoneg model). NOT HW-validated. simProven=false is HONEST (reproduce test conflicts with David's DECISION-#3
negative control test_train_fallback MODE=trainfb_off which asserts the beacon MUST stay dark when the param
is OFF — a deliberate opt-in; no RTL edit can flip one without regressing the other).

CAVEATS (skeptic verdict[1] real=False): (1) necessary-not-sufficient — even with the beacon+config firing,
lane_mask must be a REAL KR260 good-lane subset from a per-lane sync_seen/eye read; 0xFF is unsatisfiable and
0xE4 is bridge1/Z2-specific (do NOT assume for KR260); LANE_MASK_RESET POR-defaults 0xFF because the bare-link
build omits TD_AUTO_LANE_MASK_E4 (Wlink.v:2514). (2) TXSYNC/0x21F4 obs = UNRELIABLE instruments (instrument
Reliable=false) — disambiguate on HW by reading 0x440321E0 (0xAD marker): present=zeros real, absent=read-path
artifact. Add a 0x21F4[31:24] presence marker (candidate 5).

BETTER RTL FIX (candidate 1, high-conf, NOT applied — David decision vs candidate 2): decouple the SYNC-config
one-shot from the training rise — fire lane_mask<=subset / tol<=5 / insert_en<=1 on role_locked/link-up
(axi_chiplet_controller.sv:2281-2293) instead of on swi_training_mode_r. Fixes beacon+mask+tol in one change,
independent of the dead-I2C autoneg path; sim-provable at controller-unit + end-to-end in tidelink_top_pair_v2.

FOR DAVID: pick candidate 1 (robust RTL decouple) vs candidate 2 (TRAIN_ENTRY_FALLBACK build-param, applied) +
resolve the KR260 good-lane-subset lane_mask (candidate 3, needs a per-lane eye read) — then rebuild + HW-validate.

## BATCH REGRESSION GATE (make sim_gate) — GREEN modulo allowlist (00:57)
49 PASS / 3 XFAIL / 2 FAIL. The 3 XFAIL = expected sentinels/waivers: xfail_epoch_shipping_corrector
(=TL-030 re-baseline, now correctly XFAIL not XCHG — CONFIRMED in the full gate), v2_mask_hs_regress
(TL-024 waiver), xfail_f14b_datamode_wedge (TL-029 waiver). The 2 FAIL = tc_pair_smoke +
tc_pair_election_datamode = TL-025 (pre-existing TideChart-owner port skew, allowlisted/deferred). NO XCHG,
NO NEW regression. => ALL accumulated overnight changes (a2l FPGA+ASIC flist re-points, TL-030 sentinel,
additive TL-033/beacon tests) are regression-clean. TL-020 (asic_v1/v2/dft_wrapper elab) + TL-022
(fifo_rx_phantom_pop/randinit) CONFIRMED PASS in the gate => both sign-off-ready.

## TL-026 (pair_credit_next pipeline equivalence) — RE-CONFIRMED on current tree (0 mismatch)
- The pipeline edit IS in the current tree: commit 651a71b ("perf(asic): pipeline pair_credit_next
  critical path (TL-026, David-sign)") is in HEAD ancestry; src/rtl/fifo/tidelink_apb_regs.sv carries the
  pipelined inc_r/dec_r/update_r stage (:436-457). NOT re-applied — re-confirmed only.
- Harness = the dual-instance equivalence tb from the original proof (scratchpad tb_equiv.sv): two DUTs
  (tidelink_apb_regs_orig = git 651a71b^ pre-pipeline baseline; tidelink_apb_regs_pipe = current committed
  RTL), identical per-cycle random stimulus (concurrent APB inc/consume + real-valued hw_credit_consume,
  saturation, enable toggling). Theorem: pipe.pair_credit_counter(edge i) == orig.pair_credit_counter(edge
  i-1). Negative control = undelayed same-cycle compare (must differ often => non-vacuous).
- RE-BUILT FRESH from the CURRENT tree (regenerated pipe variant from src/rtl/fifo/tidelink_apb_regs.sv;
  orig from `git show 651a71b^`), NOT a replay of the Aug-8 simv. Verified: pipe variant == current RTL
  modulo the module-rename + one reworded comment; orig variant == pre-pipeline RTL byte-for-byte.
- COMMAND (VCS 2022.06-SP2, env sourced, TIDELINK_PHY_V2=1):
    vcs -full64 -sverilog -timescale=1ns/1ps apb_orig_fresh.sv apb_pipe_fresh.sv tb_equiv.sv -o simv_equiv
    ./simv_equiv
- RESULT: `EQUIV HARNESS: checks=40000  delayed_mismatches=0  undelayed_mismatches(neg-ctrl)=12465`
  => PASS. 0/40000 mismatch; negctl 12465 == the exact value recorded in BUG_REGISTRY.yaml (deterministic
  $urandom default seed) => faithful, non-vacuous reproduction. Netlist-affecting (67 flops) => still
  David-signs-to-land; nothing committed. (Harness lives in this session scratchpad, not the repo.)

## TL-032 + TL-027 WIRED INTO sim_gate (additive, non-vacuous, no commit) — 01:1x/01:3x
Queue items 2 + 3 DONE. Purely additive Makefile wiring — no existing suite definition or SIM_GATE_SENTINELS
touched; no RTL touched. Working-tree only, held-for-David.

TL-032 (calibrator circular run-tracker wrap-stitch):
- New target `sim_gate_calibrator_wrap` (suite name `calibrator_wrap`) added to SIM_GATE_ALL_SUITES + the
  aggregate `sim_gate` recipe + .PHONY. Runs test_calibrator_wrap.py on the DEPS-twin TB (tb_top_deps exposes
  min_lock_dwells_i + the eye-vis reads) with `CAL_RTL` pointed at the SHIPPING override
  src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv (the FPGA-V2 + ASIC-V2 RTL) — so the gate
  exercises the ACTUAL fix, not the pre-fix twin.
- HEAL (gate default) PASS: best_run=4, latched lane0 (slip=0, phase=15) — centred on the wrap (circular stitch OK).
- REPRODUCE (non-vacuous) FAIL confirmed against the true pristine pre-fix calibrator (git deps/tidelink-phy
  8c560c5~1, extracted to scratchpad, run via CAL_RTL): best_run=0, latched (slip=0, phase=0) = the (0,0) write-DROP
  fallback ("CIRCULAR RUN-TRACKER BUG REPRODUCED"). NB: the deps working-tree twin already carries the identical
  patch (submodule 8c560c5), so a bare DEPS=1 default now also passes — the pristine parent is the real red bench.
- Gate run: `[sim_gate] PASS calibrator_wrap (6s)`, .status stamped 3f037c04e725-dirty.

TL-027 (a2l replay-FIFO CDC false-FULL self-latch, data-plane trio):
- New targets `sim_gate_a2l_replay_cdc_1|_3|_5` (suites `a2l_replay_cdc_1|_3|_5`) added to SIM_GATE_ALL_SUITES +
  the aggregate + .PHONY. Each runs the local suite at NODE=1(AW 0x80)/3(W 0x81)/5(B 0x82) with a distinct
  SIM_BUILD; default DUT = the in-tree local_overrides/WlinkGenericFCReplayV2_N.v fix (dut_src_N.f picks override
  if present, else deps).
- HEAL (gate default) PASS all 3: after the lap-ahead ACK (=9 for depth-8 _1/_5, =33 for depth-32 _3) the first
  write sees a2l_full=0 app_ready=1 (winc fires). `[sim_gate] PASS a2l_replay_cdc_1/3/5 (6/7/7s)`.
- REPRODUCE (non-vacuous) FAIL all 3 via USE_DEPS_DUT=1 (pristine deps): a2l_full=1 app_ready=0 self-latch
  ("a2l false-FULL self-latch REPRODUCED") — winc never fires, the FCSM would never transmit.

Anti-vacuous wiring cross-checks (both green post-edit):
- `make sim_gate_inventory` wiring cross-check: "OK — every declared suite is invoked" (54 declared: 51 blocking +
  3 sentinels, incl. the 4 new). NOTE: this detector was PRE-EXISTING DEAD — its invoked-set regex
  `no-print-directory sim_gate_...` never matched because every aggregate line carries `SIM_GATE_NONFATAL=1`
  between the two, so it reported ALL 51+3 suites as orphans and always exit 1. Fixed the one-line regex to
  `SIM_GATE_NONFATAL=1 sim_gate_...`. This target is a standalone diagnostic (NOT a dependency of the real gate),
  so the fix is zero-risk to gate pass/fail; it now actually validates the wiring.
- `make sim_gate_registry_coverage`: RESULT COVERAGE OK, 0 HARD FAILURES, 0 wiring warnings, 16 in_sim_gate bugs
  covered. Flipped BUG_REGISTRY in_sim_gate false->true for TL-027 + TL-032 (now that they are gated) so the
  registry<->gate binding is consistent; both are recognized as wired. Remaining 2 FIXED-but-ungated GAPs are
  TL-007 + TL-026 (pre-existing, unrelated).

NO-REGRESSION (the two reference suites the new targets were patterned on, re-run on a clean v2 build):
`sim_gate_v2_winscan` PASS (558s) + `sim_gate_v2_syncdet` (v2_autonomous_sync_detect) PASS (289s), both stamped
3f037c04e725-dirty = the current tip. Additive Makefile-only wiring cannot alter their build/RTL; confirmed empirically.

Files changed (working tree, uncommitted): Makefile (+4 targets/comments, .PHONY, SIM_GATE_ALL_SUITES, 4 aggregate
invocation lines, 1 dead-regex fix), docs/BUG_REGISTRY.yaml (2 in_sim_gate flips only). No RTL, no HW, no commit.
(NB: the working tree already carried unrelated overnight edits — xfail_epoch_shipping sentinel refinement in the
Makefile, TL-035 registration in BUG_REGISTRY — which were NOT touched.)

## TL-028 (FPGA RX word-clock diagnostic SDC) — ADDED (structural-verify only; hold-for-David)
- ROOT: the /16 recovered D2D RX word clock (w_lnk_clk = BUFG(~count[3]) in WavD2DGpioRx, per lane
  gpiorx_0..7) had NO create_generated_clock on the integrated pair targets => STA-INVISIBLE. The pair
  timing XDC had ported ONLY [4b]'s TX twin (gpiotx0_word_clk); the 8 RX word clocks were never carried
  over from the PHY-BIST word_handoff.xdc. WavD2DGpioRx.v:365-366 documents the symptom (Vivado routed
  summary = "no_clock" on the BUFG'd ~count[3]).
- FILE EDITED (working tree, uncommitted): fpga/targets/kr260-pair-nptp/kr260_tidelink_timing.xdc.
  New section [4c]: 8x `create_generated_clock -name gpiorxN_word_clk -source {*gpiorx_N/*count_reg[3]/C}
  -divide_by 16 {*gpiorx_N/*count_reg[3]/Q}` (N=0..7) — the exact idiom proven in
  deps/tidelink-phy/.../pynq-z2-phy-bist-pair-flip/pynq_z2_tidelink_word_handoff.xdc on identical RTL and
  already used for the TX twin in this same file. Net targeted: per-lane gpiorx_N/count_reg[3] (the
  free-running ~count[3] word-clock root; /16 of pad_clk_rx 320ns = 5120ns ~195kHz on KR260 — matches the
  expected figure). Wildcard *count_reg[3]* is generate-scope-insensitive (g_t3a_passthru/g_t3a_realign).
- Also extended the existing set_clock_groups (4 -> 5 groups): the RX word clocks as their OWN async island
  (NOT folded into pad_clk_rx) so declaring them cannot introduce a new cross-domain violation on David's
  build — the skew-tolerant FIX-N handoff is excluded (async), not timed; all real crossings are 2-flop
  CDC'd in RTL; intra-RX-word-domain paths stay timed at the /16 rate (the visibility win).
- STRUCTURAL VERIFY (not sim-testable): Tcl parse OK (stubbed-Vivado source); cocotb/lint/xdc_lint.py
  clean (0 findings) on the file + the whole target dir (no #6.a procedural-Tcl, no #6.b dropped
  multi-pin); no double-constraint (each gpiorxN_word_clk name defined once; no pre-existing RX word clock).
- HELD-FOR-DAVID: only a routed Vivado build can confirm get_pins resolves non-empty on the impl netlist
  (pin existence is impl-time). Diagnostic / low functional leverage (us-scale slack). Applied to the
  primary KR260 pair target only; the flip-nptp + pynq-z2-pair-* siblings need the identical [4c] block if
  their B-return path is to be made STA-visible too. If David wants the FIX-N handoff VERIFIED rather than
  excluded, port PHY-BIST [2]: set_max_delay -datapath_only 100 -from *gpiorx_*/link_data_word_reg[*]
  -to *gpiorx_*/link_data_reg_reg[*]. Nothing committed.

## TL-021 first-silicon OBS subitems (2) + (3) — SIM-PROVEN, HELD-FOR-DAVID (netlist, uncommitted)
Scope: the two LOW-RISK subitems from docs/TL021_FIRST_SILICON_OBS_SPEC.md. Subitem (1) — the risky
4-site Region-D/F read-mux fold — DELIBERATELY SKIPPED (untouched).
- (2) i2c_slv_reset SW override @ SoC 0x2088[7] (default 0 = bit-identical). RTL: src/rtl/local_overrides/
  axi_chiplet_controller.sv — new `logic i2c_slv_dbg_force_reg` (decl :649, POR `<=1'b0` :760, decoded from
  I2C_SLV_ADDR[7] in BOTH write branches :926/:940, read-back region4 slot 2 [7] :1129), and the gate
  :3085 `i2c_slv_reset = ~hresetn | (role_is_master & ~i2c_slv_dbg_force_reg)`. Default force=0 folds to
  the original `role_is_master`, so every existing build is byte-behaviour-identical.
- (3) ext_stall_err_q -> obs 0x21F8[11] (V2-only, purely additive). RTL: src/rtl/tidelink_top.sv:1725 —
  `xhb_sub_obs_word` spare `13'h0` -> `12'h0, ext_stall_err_q` at bit[11] (was a constant 0). Path
  ext_stall_err_q -> xhb_sub_obs_word[11] -> .xhb_sub_obs_word_i -> controller Region-F slot 6 -> 0x21F8[11].
- REPRODUCE-FIRST + NON-VACUOUS (new test, no top Makefile touched): cocotb/tidelink_v2_smoke/test_tl021_obs.py
  (single real tidelink_top, V2 build, APB master). Run:
    cd cocotb/tidelink_v2_smoke; rm -rf sim_build*; make MODULE=test_tl021_obs
  UNPATCHED (bit absent): (2) after 0x2088[7]=1 i2c_slv_reset STAYS 1, read-back 0x0000005a (bit7 dropped) —
  assert FAILS; (3) after depositing ext_stall_err_q=1, 0x21F8 STAYS 0xb5000001 (bit11=0) — assert FAILS.
  PATCHED: (2) i2c_slv_reset -> 0, read-back 0x000000da (bit7=1, addr[6:0]=0x5A preserved), clear -> back to 1;
  (3) 0x21F8 0xb5000001 -> 0xb5000801 (only bit[11] flips), clear -> 0xb5000001. TESTS=2 PASS=2. (0xB5
  signature byte confirms the Region-F APB path is alive.)
- NO-REGRESSION (patched RTL): tidelink_v2_smoke default test_tidelink_v2_smoke PASS; sim_gate_axinode_obs
  PASS (13s); v2_autonomous_sync_detect (cocotb/tidelink_top_pair_v2, full V2 pair — compiles BOTH edited
  files twice) 4/4 PASS. Additive/default-0 confirmed: zero functional delta.
- HELD-FOR-DAVID: nothing committed. Edits in working tree only. David signs to land + rebuild the netlist.
  Proposed diff = the two files above (see `git diff`); the new test is test-only (zero shipping-RTL risk).

===================================================================================================
# ═══ FINAL MORNING SUMMARY (overnight run complete, 2026-08-10 ~02:1x) ═══
===================================================================================================

Branch: integ/tidelink-consolidated-2026-08-07. NOTHING committed/pushed/deployed — everything below is
in the WORKING TREE for selective review. Gate: batch `make sim_gate` = GREEN modulo allowlist (49 PASS /
3 XFAIL [TL-030 sentinel + TL-024 + TL-029 waivers] / 2 FAIL = tc_pair = TL-025 TideChart-owner, deferred).
Zero NEW regressions from any overnight change (each item re-confirmed its relevant suites green).

## Ledger
| Item | Sim-resolved? | Held-for-David (diff / decision) | Regression |
|------|---------------|----------------------------------|-----------|
| TL-030 epoch XCHG | YES — sentinel re-baselined PASS=1 FAIL=2 (test_01 bilateral now catches same s2m defect); XCHG->XFAIL verified in full gate | Makefile sentinel edit (sim-only) | clean |
| a2l flist re-points (FPGA+ASIC) | YES — deps FAIL / override PASS on _1/_3/_5 (AW/W/B) | flists/tidelink_fpga_v2.flist + tidelink_top_full_asic_v2.flist; ASIC needs tapeout-owner flist REGEN to take effect | clean (asic_v2_elab PASS) |
| TL-033 credit-underflow | YES — new test_43 white-box + noguard redgreen A/B (8191 vs 0); 43/43 FIFO suite | test-only (fix already committed ce2f2c9) | clean |
| TL-035 watchdog (NEW) | N/A (doc) | registered; Part-A unstick diff ready; Part-B (§6) ILA-gated — needs attended die_b AW-FCSM ILA | n/a |
| BEACON rank-1 delivery | root-caused + reproduced in sim | see DECISION below | clean |
| TL-020 ASIC-obs hygiene | YES (asic_v1/v2/dft elab PASS in gate) | commit the done obs-add/dedup | clean |
| TL-022 phantom-pop/randinit | YES (PASS in gate) | sign-off | clean |
| TL-026 pair_credit pipeline | YES re-confirmed 0/40000 mismatch (negctl 12465 exact) | pipeline already committed 651a71b — David signs to keep (67 flops) | clean |
| TL-028 RX word-clock SDC | structural (xdc_lint clean) | kr260-pair-nptp XDC [4c]; impl-time get_pins check + flip/z2 siblings pending | n/a (XDC) |
| TL-032 calibrator wrap | YES — wired into sim_gate, PASS non-vacuous | in_sim_gate:true | clean (winscan/syncdet PASS) |
| TL-027 a2l replay CDC | YES — _1/_3/_5 wired into sim_gate, PASS non-vacuous | in_sim_gate:true | clean |
| TL-021 first-silicon obs (subitems 2+3) | YES — sim-proven non-vacuous (unpatched FAIL->patched PASS); default-0/additive | axi_chiplet_controller.sv (i2c_slv_reset 0x2088[7]) + tidelink_top.sv (ext_stall_err_q->0x21F8[11]); subitem-1 4-site read-mux SKIPPED (risky) | clean (v2 pair 4/4, axinode_obs PASS) |

## KEY DAVID DECISIONS
1. **BEACON rank-1 delivery (the all-zeros / anc=0 blocker).** ROOT CAUSE (sim-reproduced): dead-I2C NEGO
   bare-link NACK-parks without pulsing local_train_set => swi_training_mode_r never rises => the SYNC-config
   one-shot (axi_chiplet_controller.sv:2283 sets lane_mask/tol/insert_en) NEVER FIRES => detector stays POR
   (mask 0xFF/tol 0) => all_sync_seen unsatisfiable on the marginal eye => anc=0 => all-zeros. AUTO_ANCHOR_EN=1
   CANNOT fix it (ORs only the beacon insert bits, not mask/tol) — this is why the AUTO_ANCHOR rebuild delivered
   all-zeros.  DECISION: **candidate 1** (RTL: decouple the one-shot to fire on role_locked/link-up — robust,
   sim-provable end-to-end) **vs candidate 2** (CONFIG.TRAIN_ENTRY_FALLBACK{1'b1} on both kr260-pair tcls —
   APPLIED + autoneg-A/B-proven, but re-enables a deliberately-reverted path and is NOT end-to-end/HW-proven).
   PLUS **the lane_mask must be a REAL KR260 good-lane subset** from a per-lane eye/sync_seen read (NOT 0xFF,
   NOT the bridge1/Z2-specific 0xE4) — LANE_MASK_RESET POR-defaults 0xFF because the bare-link build omits
   TD_AUTO_LANE_MASK_E4. Either candidate then needs a REBUILD + HW RE-VALIDATE. New sim proofs:
   cocotb/tidelink_autoneg_deadi2c (beacon-dark reproduce), cocotb/tidelink_autoneg_rolestrap (A/B),
   cocotb/tidelink_lane_deskew/test_mask_ff_wedge.py (0xFF-mask wedge). Instruments: TXSYNC/0x21F4 UNRELIABLE
   on the bare-link obs path — disambiguate on HW via 0x440321E0 (0xAD marker).
2. **TL-035 watchdog** — Part-A (unstick socl_l7 real_crc_seen, diff ready) can land; **Part-B (§6 state-7-exit)
   MUST NOT ship without the attended die_b AW-FCSM ILA**.
3. **a2l ASIC flist re-point** is inert until the **tapeout owner regenerates** the derived flist.
4. **AUTO_ANCHOR_EN=1** (earlier, in the tcls + wrapper) is CORRECT + harmless (closes a real gap) but
   necessary-not-sufficient — keep it; the beacon decision above is the actual fix.

## Working-tree inventory (git status) — review + commit selectively
TRACKED: Makefile (gate-wiring TL-032/TL-027 + TL-030 sentinel + sim_gate_inventory dead-regex fix*);
cocotb/tidelink_fifo/{Makefile,test} (TL-033); deps/tidelink-phy (submodule ptr = TL-032 calibrator deps
twin); docs/BUG_REGISTRY.yaml (TL-035 + in_sim_gate flips*); flists/{tidelink_fpga_v2, tidelink_top_full_asic_v2}
(a2l re-points); fpga/targets/kr260-pair-{nptp,flip-nptp}/tidelink_design.tcl (AUTO_ANCHOR_EN + TRAIN_ENTRY_FALLBACK);
fpga/targets/kr260-pair-nptp/kr260_tidelink_timing.xdc (TL-028); fpga/vivado_ip/tidelink_vivado_wrapper.v
(AUTO_ANCHOR_EN param); src/rtl/local_overrides/axi_chiplet_controller.sv + src/rtl/tidelink_top.sv (TL-021).
UNTRACKED: cocotb/tidelink_autoneg_deadi2c, cocotb/tidelink_autoneg_rolestrap (beacon proofs);
cocotb/tidelink_lane_deskew/test_mask_ff_wedge.py; cocotb/tidelink_fifo/{noguard.sv,noguard.flist,redgreen.sh}
(TL-033); cocotb/tidelink_v2_smoke/test_tl021_obs.py; cocotb/tidelink_axi_datanode_recovery/*.flist,
cocotb/tidelink_a2l_replay_cdc/dut_src_*.f (test scratch, Makefile-regenerated).
* = 2 gate-wiring changes slightly beyond pure additive (sim_gate_inventory dead-regex fix + in_sim_gate:true
flips for TL-027/TL-032) — trivially revertible. The beacon workflow's throwaway RTL experiment on
tidelink_autoneg.sv was REVERTED (file clean).

## final datanode check: PASS (axi_datanode_gaps 381s) — TL-021 default-0/additive edits regression-clean. OVERNIGHT RUN COMPLETE, gate green-modulo-allowlist.

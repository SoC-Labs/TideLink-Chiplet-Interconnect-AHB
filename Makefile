.PHONY: clean_all clean_uvm clean_cocotb clean_xprop clean_lint clean_syn \
        sim_robust sim_synth_mode xdc_lint xdc_lint_selftest \
        synth_lint_selftest robust_all sim-repro sim-repro-skid3 \
        sim-regression farm_gate farm_gate_fast

# =============================================================================
# Silicon-replication test gates (feat/cocotb-robust-silicon-replication)
# =============================================================================
#
# Targets that catch silicon-only failure modes BEFORE deploy:
#
#   xdc_lint           — Bug #6 (silently dropped XDC constraints).
#                        Static Python lint of fpga/targets/*.xdc.
#   xdc_lint_selftest  — Prove xdc_lint catches each of the 4 anti-patterns.
#   sim_synth_mode     — Bug #2/#7 (synth-interpretation defects).
#                        Verilator strict lint of first-party RTL.
#   synth_lint_selftest— Prove the Verilator gate catches CASEINCOMPLETE,
#                        WIDTH-truncate, BLKANDNBLK on seeded fixtures.
#   sim_robust         — Bug #1/#3/#7 fingerprints + reset/CDC stress.
#                        cocotb tests under cocotb/debug/sim_robust/.
#   robust_all         — meta-target: run every gate (lints + sim).
#
# All targets are pre-silicon — no farm builds, no HW dependency.
# =============================================================================

xdc_lint:
	@echo "========================================"
	@echo " XDC anti-pattern lint (Bug #6 gate)"
	@echo "========================================"
	python3 cocotb/lint/xdc_lint.py fpga/targets/

xdc_lint_selftest:
	@echo "========================================"
	@echo " XDC anti-pattern lint — selftest"
	@echo "========================================"
	python3 cocotb/lint/test_xdc_lint_selftest.py

sim_synth_mode:
	@echo "========================================"
	@echo " Synth-mode Verilator lint (Bug #2/#7 gate)"
	@echo "========================================"
	$(MAKE) -C cocotb/lint -f Makefile.synth lint

synth_lint_selftest:
	@echo "========================================"
	@echo " Synth-mode Verilator lint — selftest"
	@echo "========================================"
	$(MAKE) -C cocotb/lint -f Makefile.synth selftest_synth

sim_robust:
	@echo "========================================"
	@echo " sim_robust adversarial cocotb tests"
	@echo "========================================"
	$(MAKE) -C cocotb/debug/sim_robust sim_robust

robust_all: xdc_lint_selftest synth_lint_selftest xdc_lint sim_synth_mode sim_robust
	@echo "========================================"
	@echo " ALL ROBUST GATES PASSED"
	@echo "========================================"

# =============================================================================
# farm_gate — MANDATORY pre-farm-build gate (the highest-value verif-infra item)
# =============================================================================
# Runs the checks that turn the campaign's dominant SILICON-ONLY failure classes
# into RED at build time instead of days of debug:
#   Tier-0 (seconds): xdc_lint + sv_anti_pattern, RATCHETED against accepted
#                     baselines (green today, red on any NEW finding).
#   Tier-1 (minutes): the V2 pair sim at the SILICON epoch fingerprint +
#                     reduced-lane + marginal-eye + XHB bridge BFM.
# Exit non-zero => refuse to launch a farm build. build_farm.sh invokes this as
# a precondition. See fpga/farm_gate.sh for env knobs (FARM_GATE_FAST,
# FARM_GATE_ALLOW_NO_SIM, FARM_GATE_SIM_STAGES, FARM_GATE_STAMP).
farm_gate:
	@bash fpga/farm_gate.sh

# Lint-only pre-flight (Tier-0). Fast dev check; NOT a substitute for the build
# gate (does not run the silicon-config sim).
farm_gate_fast:
	@FARM_GATE_FAST=1 bash fpga/farm_gate.sh

# =============================================================================
# sim-repro — HW-bug regression gate (added 2026-05-24)
#
# Mandatory before any HW deploy in Phase 4 of the TideLink interface debug
# (see docs/TIDELINK_INTERFACE_DEBUG_PLAN.md §X). Runs the cocotb assertions
# that mirror the Phase 0 HW observations:
#   * cr_pkt_seen_rx latches on BOTH sides
#   * crack_pkt_seen_rx latches on BOTH sides
#   * FCSM reaches LINK_DATA (>=4) on BOTH sides
#   * fe_tx_credit_max_loaded on BOTH sides
#
# Today these PASS in sim (the bug is FPGA-only). If/when the sim model gets
# patched to reproduce the bug (e.g. random count phase in WavD2DGpioRx),
# these tests will START failing — that is the diagnostic signal we want.
#
# sim-repro-skid3 also runs with SKID_BITS=3 (FPGA-like 3-bit data shift).
# =============================================================================

sim-repro:
	@echo "========================================"
	@echo " sim-repro — HW regression gates (default SKID=0)"
	@echo "========================================"
	$(MAKE) -C cocotb/wlink_pair MODULE=test_hw_regression_gates
	$(MAKE) -C cocotb/wlink_pair MODULE=test_assert_bringup

sim-repro-skid3:
	@echo "========================================"
	@echo " sim-repro with SKID_BITS=3 (FPGA-like skew)"
	@echo "========================================"
	$(MAKE) -C cocotb/wlink_pair MODULE=test_hw_regression_gates SKID_BITS=3


# =============================================================================
# Paired tidelink_top regression — deterministic sim of the HW bringup chain.
#
# Two full tidelink_top instances cross-wired through GPIO PHY pads. Six tests
# walk the same sequence as deploy_pair.sh + bringup_pair_converge.sh, from
# role_lock through cr/crack exchange through doorbell crossing.
#
# Expected baseline outcome (matching tdif-13/15 HW state):
#   test_01 PASS  role_lock + cal_done assert on both sides
#   test_02 PASS  training_mode read-back
#   test_03 PASS  cr_pkt_seen + crack_pkt_seen symmetric (bilateral LINK_IDLE)
#   test_04 FAIL  PAIR_CREDIT_COUNTER stays 0 — the HW symptom locked in
#   test_05 FAIL  doorbell master→slave doesn't cross — same as HW
#   test_06 PASS  doorbell slave→master DOES cross (asymmetry, also HW-faithful)
#
# Any RTL fix that closes the credit-path bug should flip test_04 and test_05
# green. Runtime ~6 min wall-clock on a typical workstation (vs ~50 min for an
# FPGA build), so this is sim-gate viable per the project policy.
# =============================================================================

sim-regression:
	@echo "========================================"
	@echo " sim-regression — paired tidelink_top HW-symptom regression"
	@echo "========================================"
	$(MAKE) -C cocotb/tidelink_top_pair


# =============================================================================
# Paired V2 (TIDELINK_PHY_V2) regression — the v38 pre-silicon gate.
#
# Two V2-stack tidelink_top instances (flists/tidelink_fpga_v2.flist,
# deps/tidelink-phy @ c332722 epoch-deskew anchor) with per-lane WHOLE-WORD
# epoch skew between the dies — the v37 silicon defect class that no other
# integrated sim can see (docs/V37_FINAL_DIAGNOSIS_2026_06_12.md). Four
# stages, each a fresh compile (~2 min wall total):
#   1. EPOCH_PROFILE=zero       bilateral link-up + M<->S packet delivery
#   2. EPOCH_PROFILE=staircase  0..7 whole-word lane epochs, both directions
#   3. EPOCH_PROFILE=silicon    v37 fingerprint (3..7 words on master's RX)
#   4. negative control         EPOCH_ANCHOR_EN=0 -> asserts the v37
#                               directional data-loss signature is detected
# See cocotb/tidelink_top_pair_v2/README.md for the discrimination matrix.
# =============================================================================

sim-regression-v2:
	@echo "========================================"
	@echo " sim-regression-v2 — paired V2 epoch-skew gate (v38)"
	@echo "========================================"
	$(MAKE) -C cocotb/tidelink_top_pair_v2 v2_gate


# =============================================================================
# sim_gate — THE aggregate pre-deploy sim gate (L4 training-exit era, 2026-07)
#
# One command that runs every suite the debug loops have been re-deriving by
# hand. Exact proven incantations (see docs/TESTING.md).
#
# >>> FULL INVENTORY, per-suite rationale, verification-plan feature-ID mapping,
# >>> what remains UNGATED and why, and the expected wall-clock:
# >>>     docs/SIM_GATE_COVERAGE.md
#
# >>> TRAP: `make -n sim_gate` WRITES FAKE PASS FILES (the sim_gate_run recipe
# >>> body writes <suite>.status unconditionally and -n echoes it into
# >>> existence). NEVER use -n to validate the gate; run the target.
#
# The original eight:
#
#   tidelink_top_pair  (V2 flist, autonomy ON, short cal-hold, no dump):
#     t31_autonomous_training_exit   full zero-poke chain a-h incl. the real
#                                    fch bootstrap + bilateral data cross
#     t32_die_a_first_zombie_retry   die_a-first arm order + zombie-peer
#                                    trap auto-retry (R5)
#     t33_arm_stagger_episode_bind   FIX-1/2/3 arm-stagger episode binding:
#                                    private-episode rebind / mid-scan
#                                    kick-loss abort-restart / zero-stagger
#     t30_autonomous_fc_handoff      autoneg FSM drives the FC handoff
#   tidelink_top_pair_v2 (EPOCH_PROFILE=zero):
#     v2_pair_data                   bilateral link-up + M<->S packet delivery
#     v2_autonomous_sync_detect      autoneg SYNC config -> sync_det on silicon
#                                    register model
#     v2_winscan_fsm                 on-chip WINSCAN FSM centre + reanchor
#   V1 elaboration check:
#     v1_elab                        V1 flist (TIDELINK_PHY_V2=0) compiles +
#                                    elaborates clean (VCS elab of the
#                                    tidelink_top_pair tb, no test run) —
#                                    catches V2-only `ifdef breakage of V1
#
# Behaviour:
#   * fail-fast per suite, but ALL suites always run;
#   * per-suite log: imp/sim_gate/<suite>.log (+ <suite>.status one-liner);
#   * final PASS/FAIL summary table; non-zero exit if ANY suite failed.
#
# Requires the sim env:  source ./set_env.sh   (SIM=vcs)
#
#   make sim_gate         # all eight (~25-40 min: four fresh compiles)
#   make sim_gate_quick   # smoke: skips the two slowest (t31, t32)
# =============================================================================

SIM_GATE_DIR := imp/sim_gate

# Proven tidelink_top_pair autonomy-suite environment — copy EXACTLY (these
# are environment variables, matching the hand-run incantation
#   TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
#   EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" SIM_BUILD=sim_build_l4 \
#   COCOTB_RESOLVE_X=ZEROS make MODULE=<M>
# ). t31 + t30 share sim_build_l4 (one compile, two runs); t32 gets its own
# BYPASS_AUTONEG=1 build (SIM_GATE_TP32_ENV below).
SIM_GATE_TP_ENV := TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
	EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" SIM_BUILD=sim_build_l4 \
	COCOTB_RESOLVE_X=ZEROS

# Literal-comma helper for $(call ...) arguments: $(call ...) itself splits
# its argument list on unescaped commas, so a comma-separated value (e.g. a
# multi-TESTCASE cocotb list) embedded directly in a $(call sim_gate_run,...)
# argument gets silently truncated at the first comma -- $(comma) defers that
# comma's appearance until after argument splitting. See sim_gate_v2_auto_
# anchor's TESTCASE=...$(comma)... below for the one gate target that needs it
# (2026-08-18; caught by comparing the gate run's TESTS=1 log line against the
# TESTS=2 line from running the same two TESTCASE names directly, un-nested).
comma := ,

# $(call sim_gate_run,<suite-name>,<command>) — run one suite, tee-free log
# capture, never fail the make (the summary decides the exit code).
#
# Wave-0 fix #12a: the run/status line below contains $(MAKE) (inside $(2)), so
# GNU make EXECUTES it even under `make -n` — which meant a dry run silently ran
# each suite and wrote a fake-PASS .status, CLOBBERING real gate results. The
# recipe now detects dry-run from MAKEFLAGS (its first word is the single-letter
# option cluster; 'n' there == -n) and skips the run + the .status write
# entirely, leaving any real result on disk untouched. A real `make sim_gate`
# has no 'n' in that cluster (--no-print-directory sits in a later word), so it
# is unaffected.

# ── gate provenance stamp (anti-false-green) ─────────────────────────────────
# The 2026-08 audit reproduced a "Frankenstein cohort": sim_gate_summary scored
# .status files left on disk from DIFFERENT commits/branches/ad-hoc runs, so a
# green summary did not prove the CURRENT tip is green (this is exactly how the
# "freeze 46-blocking-0-FAIL / integ gate-green" claim was false). Fix: stamp
# every .status with <sha>-<dirty>; sim_gate_summary REFUSES to report PASS
# unless every scored status carries the CURRENT stamp.
GATE_SHA   := $(shell git -C $(TIDELINK_HOME) rev-parse --short=12 HEAD 2>/dev/null || echo nosha)
GATE_DIRTY := $(shell test -n "$$(git -C $(TIDELINK_HOME) status --porcelain 2>/dev/null)" && echo dirty || echo clean)
GATE_STAMP := $(GATE_SHA)-$(GATE_DIRTY)
define sim_gate_run
	@if echo "$(MAKEFLAGS)" | grep -qw -- n; then \
	  echo "[sim_gate] REFUSING to run under 'make -n' ($(1))."; \
	  echo "[sim_gate] sim_gate_run is NOT -n safe: the recipe below is a shell 'if'"; \
	  echo "[sim_gate] whose @-prefixed body make PRINTS but the recursive \$$(MAKE) -C"; \
	  echo "[sim_gate] inherits -n, so the sub-make does nothing, the 'if' succeeds, and"; \
	  echo "[sim_gate] a FABRICATED 'PASS' .status is written for a suite that never ran."; \
	  echo "[sim_gate] (Reproduced 2026-07-18: 'make -n sim_gate_nack_wedge' emitted"; \
	  echo "[sim_gate]  'nack_wedge_recovery PASS 4s' into $(SIM_GATE_DIR).)"; \
	  echo "[sim_gate] To inspect a recipe without side effects, read the Makefile."; \
	  exit 1; \
	fi
	@mkdir -p $(SIM_GATE_DIR)
	@echo "[sim_gate] RUN  $(1)  (log: $(SIM_GATE_DIR)/$(1).log)"
	@case "$${MAKEFLAGS%% *}" in \
	  *n*) echo "[sim_gate] DRY-RUN: would run $(1); NOT touching $(SIM_GATE_DIR)/$(1).status" ;; \
	  *) t0=$$(date +%s); \
	     if ( $(2) ) > $(SIM_GATE_DIR)/$(1).log 2>&1; then st=PASS; else st=FAIL; fi; \
	     dt=$$(( $$(date +%s) - t0 )); \
	     printf '%-28s %-4s %6ss %s\n' "$(1)" "$$st" "$$dt" "$(GATE_STAMP)" > $(SIM_GATE_DIR)/$(1).status; \
	     echo "[sim_gate] $$st $(1) ($${dt}s)"; \
	     if [ "$$st" = FAIL ] && [ -z "$(SIM_GATE_NONFATAL)" ]; then \
	       echo "[sim_gate] FAIL $(1) — exiting non-zero (set SIM_GATE_NONFATAL=1 to record-and-continue, as the aggregate does)"; \
	       exit 1; \
	     fi ;; \
	esac
endef

.PHONY: sim_gate sim_gate_quick sim_gate_env_check sim_gate_summary sim_gate_apb_preempt sim_gate_fch_wdog sim_gate_zeropoke \
	sim_gate_t31 sim_gate_t32 sim_gate_t33 sim_gate_t30 sim_gate_ptp_link_sync sim_gate_retire_plumb sim_gate_fifo_twin2_tree \
	sim_gate_v2_perf sim_gate_v2_reduced_lane sim_gate_v2_fc_contiguous sim_gate_epoch_silicon \
	sim_gate_epoch_anchor_plumb \
	sim_gate_v2_sustained sim_gate_v2_trunc_credit sim_gate_v2_trunc_aperture \
	sim_gate_v2_data sim_gate_v2_syncdet sim_gate_v2_winscan sim_gate_fifo sim_gate_fifo_randinit sim_gate_v1elab \
	sim_gate_force_recal sim_gate_dftelab \
	sim_gate_txgen_unit sim_gate_txgen_negctl sim_gate_v2_txgen sim_gate_txgen_ext_hijack \
	sim_gate_nack_wedge sim_gate_nack_wedge_recovery sim_gate_nack_wedge_sustained \
	sim_gate_axi_datanode_recovery sim_gate_axi_datanode_gaps \
	sim_gate_n1_read_backstop \
	sim_gate_axinode_obs \
	sim_gate_i1_selfarm sim_gate_i1_fixe_training_release sim_gate_v2_isolated_write \
	sim_gate_v2_mbox_writeprotect \
	sim_gate_calibrator_wrap \
	sim_gate_a2l_replay_cdc_1 sim_gate_a2l_replay_cdc_3 sim_gate_a2l_replay_cdc_5 \
	sim_gate_v2_auto_anchor

sim_gate_env_check:
	@command -v vcs >/dev/null 2>&1 || \
	  { echo "sim_gate: vcs not in PATH — run 'source ./set_env.sh' first"; exit 1; }
	@command -v cocotb-config >/dev/null 2>&1 || \
	  { echo "sim_gate: cocotb-config not in PATH — run 'source ./set_env.sh' first"; exit 1; }
	@# NOTE: the weekend-2026-07-18 suites additionally need three SIBLING repo
	@# checkouts (tidechart, nanosoc-ethernet-chiplet, ethernet-subsystem-ahb).
	@# Those are checked PER-SUITE (SIM_GATE_REQUIRE below), NOT here: a missing
	@# sibling must fail its own suites loudly while the other 15 still run —
	@# aborting the whole gate on one absent checkout would be worse than the
	@# gap it reports. See docs/SIM_GATE_COVERAGE.md §"CI prerequisite".

# --- tidelink_top_pair autonomy suites (V2 flist, shared sim_build_l4) ------
sim_gate_t31:
	$(call sim_gate_run,t31_autonomous_training_exit,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_31_autonomous_training_exit)

# t32 is the ONE autonomy test built with BYPASS_AUTONEG=1 (own sim_build_l5):
# the test arms autoneg ITSELF via register writes and asserts the FSM parks
# in ST_BYPASS pre-arm — a =0 build fails its precondition (verified against
# the Loop-5 fixers' run32_final.log: +define+TB_TOP_BYPASS_AUTONEG=1,
# sim_build_l5, SHORT_CAL_HOLD=64).
SIM_GATE_TP32_ENV := TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
	EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" SIM_BUILD=sim_build_l5 \
	COCOTB_RESOLVE_X=ZEROS

# --- F4 RETIRE_EN plumbing A/B (2026-07-15) ----------------------------------
# Runs the SAME test as sim_gate_t31, with the SAME stimulus, against a build
# that binds tidelink_top's RETIRE_EN to 0 from the tb. Identical stimulus, one
# parameter flipped, opposite outcome:
#   t31            (RETIRE_EN_EXPECT=1) → retire FIRES, autonomy_armed drops
#   retire_en_plumb(RETIRE_EN_EXPECT=0) → retire NEVER fires, armed == raw term
# That A/B is the proof the parameter genuinely reaches axi_chiplet_controller:
# if the tidelink_top→controller forwarding were dead (the NEGO_CFG_RESET
# failure mode — plumbed at the top, never forwarded, so every build silently
# took the module default), the =0 build would still retire and FAIL here.
# The test also asserts a hierarchical read-back of RETIRE_EN taken INSIDE the
# controller, so the value is checked at the DESTINATION, not at the tb.
# Own SIM_BUILD: the override is compile-time, so it needs its own elaboration.
SIM_GATE_TP_RETOFF_ENV := TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
	EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64 +define+TB_TOP_RETIRE_EN=0" \
	SIM_BUILD=sim_build_l4_retoff COCOTB_RESOLVE_X=ZEROS RETIRE_EN_EXPECT=0

sim_gate_retire_plumb:
	$(call sim_gate_run,retire_en_plumb,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_RETOFF_ENV) $(MAKE) MODULE=test_31_autonomous_training_exit)

sim_gate_t32:
	$(call sim_gate_run,t32_die_a_first_zombie_retry,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP32_ENV) $(MAKE) MODULE=test_32_die_a_first_zombie_retry)

# t33 (FIX-1/2/3 2026-07-03): arm-stagger episode-binding gate — three
# variants (seconds-stagger private episode / mid-scan kick-loss abort-restart
# / zero-stagger symmetric). Same BYPASS_AUTONEG=1 build as t32 (the test arms
# each die itself over APB), so it SHARES sim_build_l5 (one compile, two runs).
sim_gate_t33:
	$(call sim_gate_run,t33_arm_stagger_episode_bind,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP32_ENV) $(MAKE) MODULE=test_33_arm_stagger_episode_binding)

sim_gate_t30:
	$(call sim_gate_run,t30_autonomous_fc_handoff,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_30_autonomous_fc_handoff)

# --- Two-board PTP convergence (F13, 2026-08-17) -----------------------------
# A REAL two-PHC sync test: tb_phc_model.sv gives each die a free-running
# behavioural PHC (phc_locked_i is NOT tied — test_phc_locked_is_real_not_tied
# proves it tracks a live lock gate), master(GM)/slave(Sub) servos exchange
# SYNC/DELAY_REQ + FC SIDEBAND timestamps ACROSS THE LINK, and the numeric gate
# (SERVO_STEP_THRESH_NS = 12000 ns) asserts the servo offset converges and the
# two PHC counters actually align — not just that PTP registers exist.
# Existed on disk, invoked from nowhere (no Makefile, no CI, not even listed
# in docs/SIM_GATE_COVERAGE.md, which mischaracterised two-board PTP
# convergence as un-sim-able). Confirmed green standalone before wiring
# (both tests in the module PASS, ~46s real time). Same V2/autonomy build as
# t30/t31 (SIM_GATE_TP_ENV), so it shares the sim_build_l4 compile.
sim_gate_ptp_link_sync:
	$(call sim_gate_run,ptp_link_sync,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_ptp_link_sync)

# --- PS-facing APB safety (2026-07-09) ---------------------------------------
# Both of these lock a bug class that HANGS the Zynq PS: the CPU's M_AXI_GP has
# no transaction timeout, so any APB access that never gets pready wedges the
# processor permanently (Bus error on every later /dev/mem access) and costs a
# physical power cycle. They were written fail-first but were NOT in this list,
# so they gated nothing. They do now.
#   apb_fc_cfg_preempt — the fc_cfg priority mux must never preempt an in-flight
#     external PS transaction (tidelink_top.sv). Verified FAIL pre-fix / PASS post-fix.
#   fch_apb_watchdog   — the fch sequencer must release the Wlink APB on timeout
#     rather than pinning pready low for ever.
sim_gate_apb_preempt:
	$(call sim_gate_run,apb_fc_cfg_preempt,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_apb_fc_cfg_preempt)

sim_gate_fch_wdog:
	$(call sim_gate_run,fch_apb_watchdog,\
	  cd cocotb/tidelink_top_pair && $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_fch_apb_watchdog)

# TRUE zero-poke: BYPASS_AUTONEG=1 (the tb force block is dead) + the POR parameter
# NEGO_CFG_RESET=7'h61 (=97) via +define. Proves autonomy arms from POR with ZERO
# APB writes to NEGO_CFG/NEGO_TRAIN_CFG — the mandated deliverable. A passive
# monitor fails on any such write. Separate SIM_BUILD (BYPASS_AUTONEG differs from
# the gate default, so it must not reuse the l4 simv). The FAIL-FIRST 7'h00 case is
# deliberately NOT gated — it is meant to fail.
sim_gate_zeropoke:
	$(call sim_gate_run,zeropoke_por,\
	  cd cocotb/tidelink_top_pair && TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
	  COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_zeropoke \
	  EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64 +define+TB_TOP_NEGO_CFG_RESET=97" \
	  $(MAKE) MODULE=test_zeropoke_por)

# --- tidelink_top_pair_v2 suites (EPOCH_PROFILE=zero) ------------------------
sim_gate_v2_data:
	$(call sim_gate_run,v2_pair_data,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_pair_data)

# SUSTAINED / CONTINUAL data (2026-07-15). The v2_pair_data gate proves ONE
# 4-word packet on a quiescent link — "a packet works". These two prove "the
# CHANNEL works": burst-length sweep 2..126 payload words + back-to-back
# packets + bidirectional concurrent traffic, byte-checking EVERY word
# (v2_pair_data's oracle skips got[1] and only ever runs at payload_len=2).
sim_gate_v2_sustained:
	$(call sim_gate_run,v2_pair_sustained,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_pair_sustained)

# Truncated-packet credit ceiling — guards the 2026-07-15 fix (credit minted
# ABOVE MAX on a protocol-legal drain of a never-completed packet). Same defect
# family as fifo_rx_phantom_pop, which the f9b94b7 guard did NOT cover.
sim_gate_v2_trunc_credit:
	$(call sim_gate_run,v2_truncated_pkt_credit,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_truncated_pkt_credit)

# N3 / "Hazard 4" — read_ptr aperture drift (2026-08-17). Sibling of
# sim_gate_v2_trunc_credit, SAME truncated-packet stimulus: proves the
# read-pointer advance is now gated on the same credit-legitimacy clamp
# (read_would_overmint) the credit ceiling above already uses, so a
# never-committed (truncated) packet's phantom read_complete cannot drift
# read_ptr away from write_ptr. The credit test alone did NOT catch this --
# credit reads "numerically legal" while the pointer still silently moves --
# so this suite additionally asserts the very next legitimate packet comes
# back 100% byte-exact with a correct non-zero PKT_LEN, the actual observable
# consequence (pre-fix: all-zero words, PKT_LEN=0x0).
sim_gate_v2_trunc_aperture:
	$(call sim_gate_run,v2_truncated_pkt_aperture_offset,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_truncated_pkt_aperture_offset)

sim_gate_v2_syncdet:
	$(call sim_gate_run,v2_autonomous_sync_detect,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_autonomous_sync_detect)

# BILATERAL PEER-MASK HANDSHAKE — the SHAM-GATE catcher (2026-07-24).
# HONEST_STRAPS=1 drives apb_debug_unlock_i AND mask_hs_bypass_i to 0 on BOTH
# dies, so mask_hs_gate_open can only be opened by a GENUINE mask_hs_match.
# Guards the defect measured on kr260-pair-onchip 2026-07-23: slave
# mask_hs_match=0 while gate_open=1 (gate forced by a welded DEBUG_UNLOCK_DEFAULT),
# with the slave structurally unable to match at all (Wlink.v mask_hs_result_o
# tied 2'b00 + master-only mask FSM). Sim reproduced the slave's OBS_MASK_HS
# bit-identically to silicon (0x00100000) pre-fix and shows 0x00380000 post-fix.
# THIS IS THE ONLY EXECUTABLE TEST THAT CAN CATCH A SHAM GATE — the pre-existing
# test_v2_onchip_pair reports 5 PASS at 0.00 ns (it `return`s instead of skipping,
# so CI counts false passes) and cocotb/honest_mask_hs ASSERTS the defect.
# Do not remove without a replacement that asserts gate_open FOLLOWS match.
sim_gate_v2_mask_hs_bilateral:
	$(call sim_gate_run,v2_mask_hs_bilateral,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero BYPASS_AUTONEG=0 HONEST_STRAPS=1 MODULE=test_v2_mask_hs_bilateral)

# ODD / PARTIAL LANE-COUNT lock (2026-07-16). Before this, pair sim only ever
# ran popcount 8 (0xFF POR) and popcount 4 (test_v2_reduced_lane, M->S only) —
# BOTH powers of two. These two suites pin the link layer's popcount-GENERIC
# byte geometry (bytesPerCycle = 2*popcount(mask)) at an ODD, non-power-of-2,
# NON-CONTIGUOUS lane count in BOTH directions.
#
# Why this matters beyond the +25% payload: the vendor Chisel this RTL was
# generated from (axi-chiplet-controller .../LinkLayer.scala:577,758) still
# carries `validLaneSeq = Seq(true,true,false,true,false,false,false,true)` — a
# compile-time POWER-OF-2 lane-count whitelist ({1,2,4,8}) that gates the RX
# gather. It is NOT present in the shipping local_overrides Verilog (SoC Labs
# replaced it with the mask-aware rxLanePos prefix-popcount gather), but ANY
# regeneration from that Chisel would silently reinstate it and kill every
# non-power-of-2 mask — with the link still training. 0xE5 here is the tripwire.
#
# negctl is the instrument proof: it asserts a MISMATCHED tx/rx mask geometry
# is DETECTED as corrupt. Without it a green sweep proves nothing.
sim_gate_v2_oddlane:
	$(call sim_gate_run,v2_lane_mask_oddlane,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero \
	    MODULE=test_v2_lane_mask_sweep LANE_MASK=0xE5 SIM_BUILD=sim_build_oddlane)

# MASK-POSITION tripwire (2026-07-17). 0x65 = {0,2,5,6} has the SAME lane count
# (4) and the same bytesPerCycle (8) as the working silicon mask 0xE4 = {2,5,6,7},
# but differs in POSITION (it includes lane 0). Silicon: 0xE4 byte-exact, 0x65
# all-zeros. Sim: BOTH byte-exact -> the RTL is position-generic and the silicon
# split is NOT an RTL defect (it is winscan lane coverage; see the report).
# This suite pins that position-genericity so an RTL change can never introduce
# a real position dependence unnoticed.
sim_gate_v2_lane_position:
	$(call sim_gate_run,v2_lane_mask_position,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero \
	    MODULE=test_v2_lane_mask_sweep LANE_MASK=0x65 SIM_BUILD=sim_build_pos)

sim_gate_v2_oddlane_negctl:
	$(call sim_gate_run,v2_lane_mask_negctl,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero \
	    MODULE=test_v2_lane_mask_negctl SIM_BUILD=sim_build_oddlane)

# v1 PL-side TX traffic generator (docs/TXGEN_V1_DESIGN.md). Three arms:
#   txgen_unit    — generator + real fc_adapter in isolation: inert-when-disarmed,
#                   saturation, no-loss/no-dup under a gapped link, credit gate.
#   txgen_negctl  — the credit gate compiled OUT (+TXGEN_FORCE_CREDIT_GATE_DIS,
#                   distinct SIM_BUILD): proves the generator sends into ZERO
#                   credit without it. Without this arm the credit results are
#                   vacuous — the mandatory negative control (c3).
#   v2_txgen      — FULL PAIR: Region-E reachable through the real APB mux,
#                   BYTE-EXACT delivery into the peer RX FIFO, and credit-gated
#                   with no peer overrun. The count-only unit oracle is blind to
#                   the AHB-pipelining + header bugs this arm caught.
sim_gate_txgen_unit:
	$(call sim_gate_run,txgen_unit,\
	  $(MAKE) -C cocotb/tidelink_txgen)

sim_gate_txgen_negctl:
	$(call sim_gate_run,txgen_negctl,\
	  $(MAKE) -C cocotb/tidelink_txgen TXGEN_NEGCTL=1)

# TXGEN ownership hand-off vs an outstanding external data phase (audit A4,
# fixed 2026-07-30). tidelink_tx_gen used ext_idle = ~ext_htrans[1], but HTRANS
# is address-phase-only, so the 2:1 ownership mux could switch mid external
# data phase and commit {external ADDR, generator DATA} to the link — silent
# single-word corruption (F14-A class). Fixed by ext_data_pend_r. Positive
# regression; the 3 other txgen suites never overlap external traffic so they
# were structurally blind to it. Measured post-fix TESTS=2 PASS=2.
sim_gate_txgen_ext_hijack:
	$(call sim_gate_run,txgen_ext_hijack,\
	  $(MAKE) -C cocotb/tidelink_txgen MODULE=test_txgen_ext_hijack \
	      SIM_BUILD=sim_build_hijack \
	      COCOTB_RESULTS_FILE=sim_build_hijack/res_hijack.xml)

sim_gate_v2_txgen:
	$(call sim_gate_run,v2_txgen,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero \
	    MODULE=test_v2_txgen SIM_BUILD=sim_build_txgen)

sim_gate_v2_winscan:
	$(call sim_gate_run,v2_winscan_fsm,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_winscan_fsm)

# P1 FORCED-RECAL W1P (SWI_FORCE_RECAL, R8 slot0 bit[6]; 2026-07-19, lane B1).
# Guards the fix for docs/LINK_RECOVERY_MECHANISM.md §4 ("no firmware-reachable
# PHY retrain"). THREE arms, because the fix spans two RTL files and two flist
# families and the regression it must not cause (Bug-A) is behavioural:
#
#   RTL=v2  — src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv, the
#             copy built by tidelink_fpga_v2.flist AND tidelink_top_full_asic_v2
#             .flist (FPGA + TAPEOUT).
#   RTL=v1  — src/rtl/tidelink_phy_align_calibrator.sv (tidelink_fpga.flist +
#             tidelink_top_full_asic.flist). Same sticky, same fix.
#   pair    — FULL STACK: a real APB write to R8 slot0 bit[6] on the paired-die
#             TB, proving the W1P + stretcher + CDC reach the calibrator and that
#             the link still passes data BYTE-EXACT both ways afterwards.
#
# The baseline arms (SWI_RECAL / role_locked re-pulse must STAY no-ops after
# first lock) are the Bug-A regression: if calibrated_once_q is ever weakened,
# these go red.
sim_gate_force_recal:
	$(call sim_gate_run,force_recal_w1p,\
	  $(MAKE) -C cocotb/tidelink_force_recal RTL=v2 && \
	  $(MAKE) -C cocotb/tidelink_force_recal RTL=v1 && \
	  $(MAKE) -C cocotb/tidelink_force_recal pair)

# TL-032 CALIBRATOR CIRCULAR RUN-TRACKER WRAP-STITCH (reproduce+heal, 2026-08-08).
# The RX phase axis is CIRCULAR mod-16 (WavD2DGpioRx_v2.v:406) but the pristine
# calibrator eye-centre run-tracker scores it LINEAR and resets run_len at
# sweep_phase==15, so a width-4 eye STRADDLING the phase 15->0 wrap ({14,15,0,1})
# splits into two sub-runs; with MIN_LOCK_DWELLS=3 neither reaches the gate ->
# best_run never promotes -> the lane drops to the (0,0)/edge fallback = the
# peer-write DROP (a deterministic ~2-3/16 contributor to the TL-001 drop lottery).
# The SHIPPING calibrator_v2 (FPGA-V2 + ASIC-V2 flists) carries the head_run_len
# circular stitch. This suite compiles the DEPS-twin TB (tb_top_deps exposes
# min_lock_dwells_i + the eye-vis reads) with CAL_RTL pointed at that shipping v2
# override, so the gate exercises the ACTUAL fix RTL: best_run=4, centred phase 15.
#   reproduce (pristine deps twin):  DEPS=1 MODULE=test_calibrator_wrap -> FAIL best_run=0
sim_gate_calibrator_wrap:
	$(call sim_gate_run,calibrator_wrap,\
	  $(MAKE) -C cocotb/tidelink_phy_align_calibrator DEPS=1 TOPLEVEL=tb_top_deps \
	    CAL_RTL=$(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv \
	    MODULE=test_calibrator_wrap SIM_BUILD=sim_build_wrap \
	    COCOTB_RESULTS_FILE=sim_build_wrap/res_wrap.xml)

# TL-027 a2l REPLAY-FIFO CDC FALSE-FULL SELF-LATCH (reproduce+heal, 2026-08-08).
# Data-plane FC trio — _1 (AW 0x80), _3 (W 0x81), _5 (B 0x82). A pre-data link ACK
# a full FIFO-lap ahead (=9 for depth-8 _1/_5, =33 for depth-32 _3) must NOT leave
# the first app write false-FULL. Pristine deps node self-latches a2l_full=1 /
# app_ready=0 (winc never fires, the FCSM would never transmit = reproduce, FAIL
# via USE_DEPS_DUT=1). The in-tree local_overrides/WlinkGenericFCReplayV2_N.v fix —
# the DEFAULT DUT the flist picks (dut_src_N.f: local override if present, else
# deps) — self-heals to a2l_full=0 / app_ready=1. Distinct SIM_BUILD per node so
# the three flist geometries never share a stale simv.
sim_gate_a2l_replay_cdc_1:
	$(call sim_gate_run,a2l_replay_cdc_1,\
	  $(MAKE) -C cocotb/tidelink_a2l_replay_cdc NODE=1 \
	    SIM_BUILD=sim_build_a2l_1 COCOTB_RESULTS_FILE=sim_build_a2l_1/res_a2l_1.xml)

sim_gate_a2l_replay_cdc_3:
	$(call sim_gate_run,a2l_replay_cdc_3,\
	  $(MAKE) -C cocotb/tidelink_a2l_replay_cdc NODE=3 \
	    SIM_BUILD=sim_build_a2l_3 COCOTB_RESULTS_FILE=sim_build_a2l_3/res_a2l_3.xml)

sim_gate_a2l_replay_cdc_5:
	$(call sim_gate_run,a2l_replay_cdc_5,\
	  $(MAKE) -C cocotb/tidelink_a2l_replay_cdc NODE=5 \
	    SIM_BUILD=sim_build_a2l_5 COCOTB_RESULTS_FILE=sim_build_a2l_5/res_a2l_5.xml)

# ---------------------------------------------------------------------------
# Rescued from the link-survey line (analysis/link-survey-2026-08-01, folded
# 2026-08-10). These four suites had NO definition anywhere else on the trunk;
# their cocotb sources shipped, but the targets that run them did not, so the
# tests were unreachable.
#
# DELIBERATELY NOT registered in sim_gate / SIM_GATE_SUITES below. None has
# been run on this trunk, and adding a never-run suite to the aggregate gate
# either turns it red for reasons nobody has triaged, or -- worse, under
# SIM_GATE_NONFATAL=1 -- adds a line of green that was never earned. Run them
# by hand, triage, THEN register:
#     make sim_gate_fifo_concurrent_race
# ---------------------------------------------------------------------------
sim_gate_fc_adapter_rx_saturation:
	$(call sim_gate_run,fc_adapter_rx_saturation,\
	  rm -rf cocotb/tidelink_fc_adapter/sim_build* && \
	  $(MAKE) -C cocotb/tidelink_fc_adapter MODULE=test_rx_saturation_throughput)

sim_gate_fifo_concurrent_race:
	$(call sim_gate_run,fifo_concurrent_race,\
	  rm -rf cocotb/tidelink_fifo_concurrent_race/sim_build* && \
	  $(MAKE) -C cocotb/tidelink_fifo_concurrent_race)

sim_gate_txgen_deadtime:
	$(call sim_gate_run,txgen_deadtime,\
	  $(MAKE) -C cocotb/tidelink_txgen MODULE=test_txgen_deadtime \
	      SIM_BUILD=sim_build_deadtime \
	      COCOTB_RESULTS_FILE=sim_build_deadtime/res_deadtime.xml)

sim_gate_v2_lane_mask_throughput:
	$(call sim_gate_run,v2_lane_mask_throughput,\
	  TIDELINK_SIM_REF_PERIOD_NS=40.0 $(MAKE) -C cocotb/tidelink_top_pair_v2 \
	    EPOCH_PROFILE=zero MODULE=test_v2_lane_mask_throughput)

# --- Wave-0 #9: PERF_CTRL end-to-end (perf_reg_region = apb_region-5) --------
# Proves PERF_CTRL is writable and the perf counters ACTUALLY COUNT through the
# real APB->tidelink_apb_regs->tidelink_perf path in a brought-up pair. RED
# without the off-by-one fix (PERF_CTRL enable never sticks -> counters dead).
# Shares sim_build_zero with the other EPOCH_PROFILE=zero suites.
sim_gate_v2_perf:
	$(call sim_gate_run,v2_perf_ctrl,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_perf_ctrl)

# --- Wave-0 #12b: reduced-lane (0xE4 subset) end-to-end, previously UNGATED --
# Integrated 4-lane-subset bring-up + M->S byte-correct data + masked-lane
# quiet-TX proof. Real runnable suite (3 tests); now in the blocking gate.
sim_gate_v2_reduced_lane:
	$(call sim_gate_run,v2_reduced_lane,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_reduced_lane)

# --- Wave-0 #11: skew-faithful EPOCH_PROFILE=silicon coverage --------------
# The blocking v2 suites all run EPOCH_PROFILE=zero (no inter-lane skew), so
# there was ZERO skew-faithful sim coverage. This suite runs the v37 silicon
# fingerprint (scattered 3..7-word epochs on the master's RX, S->M path) with
# the whole-word EPOCH corrector ENGAGED (TB_TOP_EPOCH_ANCHOR_FORCE defparams
# the deskew EPOCH_ANCHOR_EN=1 / SYNC_REANCHOR_EN=0). Verified 3/3 byte-exact
# incl. S->M -> the corrector datapath survives the modelled skew.
#
# CHARACTERISED CAVEAT (Wave-0 #11, honest): DEFAULT EPOCH_PROFILE=silicon (no
# FORCE) FAILS test_03 S->M with the v37 all-zeros signature, because the
# SHIPPING integrated stack runs the OTHER corrector (SYNC_REANCHOR_EN=1), which
# only arms on a live SYNC beacon that the pair bring-up leaves off, AND Wlink
# does not forward EPOCH_ANCHOR_EN down to tidelink_lane_deskew. Engaging the
# EPOCH corrector (as here) is the datapath the RTL is designed around
# (test_v2_pair_data docstring). Wiring the shipping corrector to survive
# beacon-off skew is an RTL/bring-up item, OUT of Wave-0 (instruments-only)
# scope; this gate makes the skew-faithful path visible so it can't rot.
# Own SIM_BUILD (EXTRA_DEFINES not in the Makefile SIM_BUILD key).
sim_gate_epoch_silicon:
	$(call sim_gate_run,epoch_silicon,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon \
	    EXTRA_DEFINES="+define+TB_TOP_EPOCH_ANCHOR_FORCE" \
	    SIM_BUILD=sim_build_silicon_epoch MODULE=test_v2_pair_data)

# EPOCH_ANCHOR_EN plumbing gate (2026-07-31): drives the REAL top-level
# EPOCH_ANCHOR_EN=1 through the packaged param chain (EPOCH_ANCHOR=1, not the
# TB_TOP_EPOCH_ANCHOR_FORCE defparam shortcut above) and asserts s2m delivery
# — guards the end-to-end threading landed in f756ed8 so the Z2 data-plane fix
# can never silently stop reaching the deskew corrector.
sim_gate_epoch_anchor_plumb:
	$(call sim_gate_run,epoch_anchor_plumb,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon EPOCH_ANCHOR=1 \
	    SIM_BUILD=sim_build_anchor_param \
	    COCOTB_RESULTS_FILE=sim_build_anchor_param/res_plumb.xml \
	    MODULE=test_v2_pair_data)

# --- Wave-0 #12b: contiguous-a2l — NON-BLOCKING tracking target -------------
# The test needs an {m,s}_inj_* force injector in tb_top.sv that was never
# committed, so all four tests are marked skip=True (clean SKIP, never RED).
# NOT in SIM_GATE_ALL_SUITES; run standalone to track the missing hook. Promote
# into the gate by wiring the injector + flipping SKIP_NO_INJECTOR=False.
sim_gate_v2_fc_contiguous:
	$(call sim_gate_run,v2_fc_contiguous,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_fc_contiguous)

# RX-FIFO suite (42 tests) — carries the EMPTY-FIFO PHANTOM-POP regression
# (test_41/test_42, added 2026-07-14). That defect was SILICON-ONLY and
# tapeout-relevant: a read of an empty RX FIFO latched a zero length from the
# zeroed SRAM, popped a phantom packet, walked read_ptr by 2 words and minted
# credit ABOVE MAX_CREDITS — so any driver polling an empty FIFO corrupted the
# read pointer and every later aperture read came back shifted by two words.
# Sim was blind to it until tidelink_sram.sv began zero-initialising the SRAM to
# match FPGA BRAM power-up. Reverting the fix makes test_41/42 FAIL with the
# exact silicon signature (credit 4098 > 4096; payload starting at index 2).
sim_gate_fifo:
	$(call sim_gate_run,fifo_rx_phantom_pop,\
	  rm -rf cocotb/tidelink_fifo/sim_build && \
	  $(MAKE) -C cocotb/tidelink_fifo)

# TL-022: the SAME FIFO suite under an ADVERSARIAL non-zero SRAM power-up
# (TIDELINK_SRAM_RAND_INIT, default fill 0x2 => length 2 => read_target inside the
# read sweep). Locks the phantom-pop guard against ASIC random init: non-vacuous
# (removing the guard makes test_41 FAIL under this init, proven 2026-08-08). ~60s.
sim_gate_fifo_randinit:
	$(call sim_gate_run,fifo_rx_randinit,\
	  rm -rf cocotb/tidelink_fifo/sim_build_randinit && \
	  $(MAKE) -C cocotb/tidelink_fifo randinit)

# NACK-wedge / ACK-drop / state-7 recovery regression (2026-07-18).
#
# WHY THIS EXISTS: test_l7_wedge_repro, test_13_ack_drop_recovery and
# test_14_sustained_ack_drop_wedge are GENUINE, well-asserted regression tests
# covering the NACK-wedge and ACK-drop recovery paths -- silicon-proven failure
# modes that cost real bench time. They gated NOTHING, so the fixes they protect
# were one revert away from silently regressing. Verification-coverage audit.
#
# EXECUTED 2026-07-29 (no Vivado running, so no co-scheduling OOM artifact):
#   * test_l7_wedge_repro          2/2 PASS  (state-7 wedge appears + recovers)
#   * test_13_ack_drop_recovery    1/1 PASS  (ACK-drop recovery)
#   * test_14_sustained_ack_drop_wedge  FAIL  (post-wedge data delivery 0/8 --
#       the sustained-ACK-drop wedge does NOT auto-recover data. This is the
#       F14-B-class "no in-field recovery" gap, a REAL pre-existing RTL
#       limitation, NOT a recipe/env artifact and NOT introduced by any obs
#       change -- it asserts a recovery capability the datapath does not have.)
#
# PROMOTION (2026-07-29): the two PROVEN-PASSING recovery tests are promoted into
# the BLOCKING aggregate as `sim_gate_nack_wedge_recovery` (token
# nack_wedge_recovery, in SIM_GATE_ALL_SUITES). test_14 is kept OUT of the
# blocking aggregate as `sim_gate_nack_wedge_sustained` -- it is a real red, and
# welding a known pre-existing failure into a blocking gate (allow_failure:false)
# would break every merge for a defect this change does not own. It is NOT masked
# or forced green; fix the recovery datapath (or wrap it as an XFAIL sentinel like
# xfail_f14b) before folding it into the aggregate. Reuses SIM_GATE_TP_ENV /
# sim_build_l4 verbatim -- the same env as t31/t30.
sim_gate_nack_wedge_recovery:
	$(call sim_gate_run,nack_wedge_recovery,\
	  cd cocotb/tidelink_top_pair && \
	  $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_l7_wedge_repro && \
	  $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_13_ack_drop_recovery)

# test_14 only — currently FAILS on the pre-existing unrecovered-wedge gap.
# NON-blocking / tracked; NOT in SIM_GATE_ALL_SUITES. Run standalone to watch it.
sim_gate_nack_wedge_sustained:
	$(call sim_gate_run,nack_wedge_sustained,\
	  cd cocotb/tidelink_top_pair && \
	  $(SIM_GATE_TP_ENV) $(MAKE) MODULE=test_14_sustained_ack_drop_wedge)

# Convenience: run the whole 3-test recovery suite standalone (both split targets).
sim_gate_nack_wedge: sim_gate_nack_wedge_recovery sim_gate_nack_wedge_sustained

# AXI data-node observability (silicon-feedback item I4, 2026-07-29). Two cheap
# unit sims that together prove OBS_AXI_NODES (Region F @ 0x21E0) end-to-end:
#   * tidelink_axinode_obs — the sampler: an injected AXI-channel stall shows a
#     live-stall bit, latches the sticky wedge witness past the threshold, drops
#     data_nodes_healthy, and latches the sticky response-error bit.
#   * tidelink_apb_regs/test_region_f_decode — the APB decode: Region F routes to
#     the controller's ctrl_reg 2'b00 bank via ctrl_reg_rf WITHOUT aliasing
#     Region C, returns ctrl_reg_rdata, and is read-only (writes -> pslverr).
sim_gate_axinode_obs:
	$(call sim_gate_run,axinode_obs,\
	  rm -rf cocotb/tidelink_axinode_obs/sim_build \
	        cocotb/tidelink_apb_regs/sim_build && \
	  $(MAKE) -C cocotb/tidelink_axinode_obs && \
	  $(MAKE) -C cocotb/tidelink_apb_regs MODULE=test_region_f_decode)

# AXI data-node error-recovery (Fix G, 2026-07-31). Repro + fix for the on-silicon
# B-node write-response wedge (docs/AXI_DATANODE_RECOVERY_GAP): a mid-stream error
# on an AXI FC data node was DETECTED but never NACK'd because socl_l7_bringup_
# forgive never disarmed on a response-RECEIVE node (its TX FSM sits in LINK_IDLE,
# never LINK_DATA) -> response never returns -> initiator hard-wedges. Fix G also
# latches reached_link_data on LINK_IDLE. Four sims (own build each): recover with
# the fix; NOT-recover with the fix Force-disabled (the wedge repro / non-vacuity);
# CRC-on detects a payload error, CRC-off silently accepts it. 40ns silicon ratio.
sim_gate_axi_datanode_recovery:
	$(call sim_gate_run,axi_datanode_recovery,\
	  rm -rf cocotb/tidelink_axi_datanode_recovery/sim_build_axirec && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_error_recovers && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_error_wedges_no_fix && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_crc_on_detects_payload && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_crc_off_silent_payload && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_persistent_eye_bounded && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_bufferable_multi_outstanding && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_b_soak_multi_drain && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_bid_corrupt_wedges_no_fix && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_axirec TESTCASE=test_axi_bid_corrupt_recovers_fixk && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery writehold && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery wrhold_drain_guard)

# ── AXI data-node COVERAGE GAPS (2026-08-02) ─────────────────────────────────
# Closes two holes the B-node suite above left open, found reviewing the
# eth-chiplet silicon pushback
# (docs/VERIFICATION_REVIEW_AXI_DATANODE_PUSHBACK_2026_08_02.md):
#
#  GAP-1  the four AXI FC nodes that had NO error-injection test at all
#         (AW 0x80, W 0x81, AR 0x83, R 0x84 — everything above injects only on
#         B 0x82). This is the consumer's stated acceptance gate: "errinject per
#         node in {AW,W,B,AR,R}, expect recovery on every one". All five now
#         recover byte-exact via NACK->replay, with the R node carrying its own
#         Fix-G-off discriminator so the result is not vacuous.
#  GAP-2  I5 backstop SEMANTICS. Only the three PROVEN-passing properties are
#         blocking here (path restoration after a removable fault, bounded
#         traffic behind a stuck posted write, re-arm after abort). The two
#         that FAIL are registered as XFAIL sentinels below, NOT hidden.
#  GAP-3  TL-018 link-CRC A/B on the WRITE-DATA node (added 2026-08-14). The
#         five AXI FC nodes ship with `disable_crc=1` on the FPGA line
#         (src/rtl/local_overrides/WlinkGenericFCSM.v:747), so a payload
#         bit-flip is committed SILENTLY. `gaps_crc` pins BOTH arms of that:
#         CRC off -> wrong word in peer memory, master told SUCCESS, no counter,
#         no NACK; CRC on -> detected, NACK'd, replayed, byte-exact. The pair
#         differs ONLY in the crc_on argument, so it is its own non-vacuity
#         control. This is what makes TL-018's severity argument measured
#         rather than asserted — it must RUN, not merely exist.
#  GAP-4  TL-037 ahb_sub TERMINAL TIMEOUT (added 2026-08-17). Every recovery on
#         this port needs the stalled transfer already counted outstanding
#         (sub_rd_os_r / sub_wr_os_ctr); XHB500 can stall BEFORE that
#         acceptance — reachable the instant any earlier backstop (N1
#         included) rescues a transaction whose remote response never
#         returns — and the per-beat stall timer then expires into a dead gate
#         forever. `gaps_tl037` proves the CONTROL (first stuck read IS
#         bounded), the PRIMARY A/B for both read and write (second access
#         hangs pre-fix, bounded post-fix), and the escape-vs-safety bar
#         (fires, clears, normal path survives) against the fix in
#         imp/hw_gate/tl037/tl037_fix_ahb_sub_terminal_timeout.patch.
#
# Two sim_builds: the GAP-2 tests need the short (2^13) I5 outstanding timeout
# so the backstop fires inside a sim-able window; GAP-1/GAP-3 use the 2^16
# default (the CRC/NACK path must be what recovers, not a backstop masking it).
# GAP-4 needs its own sim_build/defines (short stall timeout too).
sim_gate_axi_datanode_gaps:
	$(call sim_gate_run,axi_datanode_gaps,\
	  rm -rf cocotb/tidelink_axi_datanode_recovery/sim_build_gaps_nodes \
	         cocotb/tidelink_axi_datanode_recovery/sim_build_gaps \
	         cocotb/tidelink_axi_datanode_recovery/sim_build_tl037 && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery gaps_nodes && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery gaps_backstop && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery gaps_ecc && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery gaps_crc && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery gaps_tl037)

# ── N1 (TAPEOUT BLOCKER, fixed @e008c58, 2026-08-14) regression ─────────────
# Both ahb_sub backstops shared ONE age timer (sub_osr_ctr_r) and ONE
# outstanding predicate, so a COINCIDENT stuck READ + stuck WRITE expired
# together: the write's synth_b_pending masked the read's 2-cycle AHB ERROR at
# :1898/:1906 while sub_rd_os_r was cleared UNCONDITIONALLY at :1675 — with
# both re-fire sites `if (sub_rd_os_r)`, the read could never error again and
# the PS hung with NO recovery. The fix (e008c58) defers the abandon: keep
# sub_rd_os_r SET when the ERROR would be masked, so a later timer window
# delivers it once the synth-B drain retires.
#
# Three tests landed by e393ad6 (8 test functions total; only these 4 HARD
# ASSERT a verdict — the other 4 are explicitly record-only adversarial probes
# or skip-by-default backup vehicles, so they are deliberately NOT wired here):
#   test_n1_read_backstop_defeat.py::
#     test_n1_control_stuck_read_alone_gets_error         CONTROL (non-vacuity):
#       a stuck read with NO coincident write must still get its ERROR.
#     test_n1_coincident_stuck_rd_wr_defeats_read_backstop PRIMARY repro: proves
#       the coincident state is reachable through XHB500 from ordinary posted
#       (EWR) traffic on a different 4KB page, then measures whether the read
#       ever completes/errors — this is the N1 finding itself.
#   test_n1_readbackstop_suppress.py::
#     test_n1_control_read_backstop_recovers    INDEPENDENT second-session
#       CONTROL (no exchange with the file above; forces s_axi_arvalid instead
#       of real AR routing) — same non-vacuity guarantee from an unrelated
#       construction.
#   test_n1_fix_recovery_dam.py::
#     test_n1_coincident_deferred_recovery      Proves the FIX recovers: on the
#       current (already-fixed) RTL, the coincident read is deferred at the
#       first expiry, the masking write drains, and HRESP=ERROR is delivered
#       in a STRICTLY LATER window (EXPECT=recover, the default).
#
# All three need the SHORT I5 window (2^13) so the shared timer's expiry is
# reachable in sim; the two pair_v2_common-based files also gate their own
# Python-side EXPIRY math on N1_TIMEOUT_LOG2, which MUST match the RTL define
# (see each file's own docstring). Each TESTCASE is its own sim — a second
# run_bringup_full() does not re-POR cleanly.
sim_gate_n1_read_backstop:
	$(call sim_gate_run,n1_read_backstop,\
	  rm -rf cocotb/tidelink_axi_datanode_recovery/sim_build_n1 \
	         cocotb/tidelink_axi_datanode_recovery/sim_build_n1_suppress \
	         cocotb/tidelink_axi_datanode_recovery/sim_build_n1_fixrecovery && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_n1 \
	    EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
	    MODULE=test_n1_read_backstop_defeat \
	    TESTCASE=test_n1_control_stuck_read_alone_gets_error && \
	  $(MAKE) -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_n1 \
	    EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
	    MODULE=test_n1_read_backstop_defeat \
	    TESTCASE=test_n1_coincident_stuck_rd_wr_defeats_read_backstop && \
	  N1_TIMEOUT_LOG2=13 $(MAKE) -C cocotb/tidelink_axi_datanode_recovery \
	    SIM_BUILD=sim_build_n1_suppress \
	    EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
	    MODULE=test_n1_readbackstop_suppress \
	    TESTCASE=test_n1_control_read_backstop_recovers && \
	  N1_TIMEOUT_LOG2=13 $(MAKE) -C cocotb/tidelink_axi_datanode_recovery \
	    SIM_BUILD=sim_build_n1_fixrecovery \
	    EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
	    MODULE=test_n1_fix_recovery_dam \
	    TESTCASE=test_n1_coincident_deferred_recovery)

# F-1 (KNOWN DEFECT, 2026-08-02): I5's AHB ERROR is driven with NO transfer in
# its data phase on the POSTED-write path. I5 is deliberately HREADYOUT-blind so
# it can catch a lost response for a bufferable write XHB500's early-write-
# response already retired at the AHB layer — so by construction its expiry can
# land on an idle bus. ahb_sub_hresp/hreadyout are overridden from sub_err{1,2}_r
# alone (tidelink_top.sv:1703-1710) with no active-transfer qualification.
# AHB-Lite permits ERROR only in the data phase of a selected transfer, so an
# upstream bridge may legitimately discard the pulse — a TideLink-side mechanism
# for the on-silicon "HRESP=ERROR is driven but the PS never sees a bus error".
# Signature: the backstop DID fire (err1_fires=1) and the pulse was 'outstanding'
# False. When this is fixed the sentinel flips XFAIL -> XCHG.
sim_gate_xfail_i5_ahb_legal:
	$(call sim_gate_sentinel,xfail_i5_ahb_legal,\
	  { $(MAKE) -C cocotb/tidelink_axi_datanode_recovery test_i5_error_is_ahb_legal; true; },\
	  grep -qF "'outstanding': False" $$L && \
	  grep -qF "AHB-ILLEGAL ERROR" $$L && \
	  grep -qF "err1_fires=1" $$L)

# F-2 (KNOWN DEFECT, 2026-08-02): the backstop reports an error but does not
# RESTORE the path. A byte-0 (data_id) corruption is a clean silent drop — the
# CRC comparison is gated on data_id === swi_data_id, so no CRC error, no NACK,
# no replay, and the response is gone forever. The wrapper fires its 2-cycle AHB
# ERROR and abandons the transfer, but XHB500 is left holding HREADYOUT low with
# nothing to unwedge it, so the NEXT clean access fails too. This is the first
# SIM REPRODUCTION of the captured on-silicon wedge: docs/ila_capA_i5_fires_
# 2026_08_02.csv shows dbg_xhb_hrdyout_raw at 0 for all 3839 samples after the
# ERROR, never once high, with dbg_i5_stall_ctr already ramping to the next
# 2^16 expiry. Prior rounds concluded the tb could not model this; it can — it
# just needed byte 0 instead of byte 4/5.
sim_gate_xfail_i5_clean_drop:
	$(call sim_gate_sentinel,xfail_i5_clean_drop,\
	  { $(MAKE) -C cocotb/tidelink_axi_datanode_recovery test_i5_clean_drop_leaves_path_usable; true; },\
	  grep -qF "PATH DEAD AFTER A SILENTLY-DROPPED RESPONSE" $$L && \
	  grep -qF "clean-drop write: ERROR" $$L)

# ---------------------------------------------------------------------------
# I1 eth-chiplet bring-up regressions (integ/i1-fix, silicon-proven 2026-07-31).
# Three suites guarding the two sequencing fixes (SELF_ARM + FIX-E) + the
# isolated-write datapath. See docs/I1_SELFARM_FIX.md, docs/I1_SELFARM_REGRESSION.md,
# cocotb/tidelink_i1_fixe_training_release/Makefile, docs/TIDELINK_ISOLATED_WRITE_ROOTCAUSE_FIX.md.
# ---------------------------------------------------------------------------

# T1 — I1 SELF_ARM_TRAIN_EN fix-logic regression (test/i1-selfarm-regression).
# UVM tidelink_top_system paired-die harness. Compiles die A with the fix ON
# (+define+TL_SELF_ARM_A_ON) and die B at the shipping-default OFF, drives the
# eth-chiplet control-plane condition (mask_hs gate ENGAGED, nego_en=0) and
# asserts, in ONE sim, that die A LATCHES role_lock on the SW ROLE_CFG[1] write
# (the fix) while die B does NOT (the built-in negative control). PASS requires
# the [I1_SELFARM_VERDICT] PASS token AND the [I1_SELFARM_DONE] marker AND the
# ABSENCE of any FAIL verdict. Own build dir (sim_build_selfarm), rm'd first so a
# stale simv can never false-PASS. DISCRIMINATION (by hand): recompiling WITHOUT
# the define makes die A also OFF and this suite FAILS — proving non-vacuity.
sim_gate_i1_selfarm:
	$(call sim_gate_run,i1_selfarm_rolelock,\
	  rm -rf uvm/tidelink_top_system/sim_build_selfarm && \
	  cd uvm/tidelink_top_system && \
	  $(MAKE) run TEST=test_top_i1_selfarm FCSM_SRC=local SIM_DIR=sim_build_selfarm \
	    EXTRA_VCS_FLAGS="+define+TL_SELF_ARM_A_ON" && \
	  grep -qF "[I1_SELFARM_VERDICT] PASS" sim_build_selfarm/test_top_i1_selfarm.log && \
	  grep -qF "[I1_SELFARM_DONE]" sim_build_selfarm/test_top_i1_selfarm.log && \
	  ! grep -qF "[I1_SELFARM_VERDICT] FAIL" sim_build_selfarm/test_top_i1_selfarm.log)

# I1 / FIX-E training-hold self-deadlock regression (test/i1-fixe-training-release).
# UNIT env: compiles ONLY the deployed FPGA calibrator override
# (tidelink_phy_align_calibrator_v2.sv) + tb_fixe.sv, shrunk timers. Phase (a)
# proves the S_HOLD self-deadlock + pins the :1499 !swi_training_mode_r gate;
# phase (b) proves the FIX-E release path reaches cal_done. Non-vacuity:
# FIXE_INVERT=1 skips the release ⇒ the suite FAILS. rm -rf sim_build*: the
# cocotb Makefile only tracks tb_fixe.sv as a compile dep, so a calibrator RTL
# edit would otherwise re-run a STALE simv (the tree-wide trap).
sim_gate_i1_fixe_training_release:
	$(call sim_gate_run,i1_fixe_training_release,\
	  rm -rf cocotb/tidelink_i1_fixe_training_release/sim_build* && \
	  $(MAKE) -C cocotb/tidelink_i1_fixe_training_release)

# V2 XHB500 isolated-write data-loss gate (fix/tidelink-isolated-write-dataloss).
# Guards the NanoSoC compute-chiplet handover regression (isolated D2D window
# write crossing with DATA=0) now fixed by cb33c9f. HREADY-aware far-ahb_mng
# monitor, distinct back-to-back data, non-compliant prompt-drop master. Reuses
# the shared tidelink_top_pair_v2 simv (compiled fresh by sim_gate_clean_builds).
sim_gate_v2_isolated_write:
	$(call sim_gate_run,v2_isolated_write_dataloss,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_isolated_write_dataloss)

# PTP mailbox APB write-protect guard (2026-07-31, verification audit). Proves an
# external APB write to Region 3 (0x060-0x07C) can no longer forge the PTP servo
# timestamp mailbox — tidelink_top.sv now ANDs mbox_reg_write with
# fc_cfg_apb_active before it reaches the servo (mbox_reg_write_fc_only). Reuses
# the shared tidelink_top_pair_v2 simv.
sim_gate_v2_mbox_writeprotect:
	$(call sim_gate_run,v2_mbox_writeprotect,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_mbox_apb_writeprotect)

# XHB500 transparent-window comb-loop test (2026-07-11). Standalone / NOT in the
# blocking aggregate yet — see the WIP note below.
#
# The RTL fix (dropping ahb_sub_hready from ext_addr_phase, cb33c9f) is
# byte-identical to the SILICON-PROVEN commit (project_xhb500_window_PROVEN_
# 2026_07_06) and is re-applied here. The bridge-accurate BFM
# (test_v2_xhb_window_bridge) drives the ahb_sub hready-in ring through the
# ports to model the wrapper loopback.
#
# WIP GAP: the refactored tidelink_top_pair_v2 tb does NOT model the PEER-side
# XHB500 target memory that a window write forwards into (_slave_bram_peek
# returns X; even the idealized control read returns 0). So the window
# round-trip cannot be exercised in THIS tb, and test_a (the health control)
# cannot pass until the slave XHB target is modelled — a tb task, not an RTL
# one. Until then the XHB CHANNEL is gated on SILICON via
# fpga/hw_regression/td_v2_channels.sh (--channels xhb), where the real XHB500
# + BRAM exist. Restoring the peer XHB target to the pair tb is the follow-up
# that lets sim_gate_xhb rejoin the aggregate.
sim_gate_xhb:
	$(call sim_gate_run,v2_xhb_window_bridge,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_xhb_window_bridge)

# =============================================================================
# WEEKEND-2026-07-18 SUITES — the seven benches produced that weekend, wired in.
#
# WHY THIS BLOCK EXISTS: this project's documented failure mode is that an
# ungated result rots out silently (the XHB channel fix vanished from three
# branches unnoticed; all four tapeout chip-killers existed because `sim_gate`
# was wired into no CI hook). A finding that is not gated becomes folklore.
# Every bench below is therefore either GATED, or explicitly parked with the
# one-line instruction that promotes it.
#
# Shared-build convention (mirrors t31/t30 sharing sim_build_l4): each bench
# gets ONE gate-owned SIM_BUILD, cleaned by sim_gate_clean_builds, reused by
# every module of that bench. SIM_BUILD is passed on the make COMMAND LINE
# because the benches set it with `:=` (a command-line assignment overrides
# `:=`; an environment variable would not).
#
# GATE-INTEGRITY (COCOTB_RESULTS_FILE): cocotb's execution rule is
#   $(COCOTB_RESULTS_FILE): $(SIM_BUILD)/simv
# and COCOTB_RESULTS_FILE defaults to ./results.xml IN THE BENCH DIRECTORY —
# shared by every module of that bench and by any hand-run. The `sim` target
# deletes it and re-enters make; if anything re-creates it in that window (a
# concurrent hand-run or a parallel agent in the same checkout — OBSERVED
# 2026-07-18), the sub-make prints "'results.xml' is up to date" and SKIPS THE
# SIMULATION ENTIRELY while exiting 0. A gate target would then report PASS
# having run nothing. Every target below therefore points COCOTB_RESULTS_FILE
# at its OWN file inside the gate-owned build dir — the same defence
# cocotb/fifo_rx_twin2/Makefile already applies to its A/B configs.
# (This is what caught it: the F14-B sentinel reported XCHG, not a false XFAIL.)
# =============================================================================
.PHONY: sim_gate_tc_smoke sim_gate_tc_election \
	sim_gate_eth_m0 sim_gate_eth_m1 sim_gate_eth_shape_a \
	sim_gate_errinj sim_gate_f14a_crc_catch sim_gate_xfail_f14b \
	sim_gate_fifo_twin2

# $(call SIM_GATE_REQUIRE,<file>,<what needs it>) — a per-suite dependency
# guard. Emits a one-line, actionable message into the suite's own log and
# returns non-zero, so the suite goes FAIL (never a silent skip — a suite that
# quietly disappears when its dependency is missing is precisely the rot this
# block exists to prevent) while every other suite still runs.
SIM_GATE_REQUIRE = test -e $(1) || { echo "sim_gate: MISSING DEPENDENCY $(1) — required by $(2). Clone the sibling repo next to tidelink/ (or set its *_HOME). See docs/SIM_GATE_COVERAGE.md."; exit 1; }

# --- F18 TideChart <-> TideLink co-sim ---------------------------------------
# The ONLY place TideChart meets a real TideLink pair. Per the verification
# plan (F18) TideChart is "entire IP unproven on hardware" and has no two-die
# on-silicon integration at all — so this co-sim is the ONLY integration
# evidence that exists for it. Gating it is what stops the tidechart_shim /
# tc_axis_* / link_active contract drifting away from
# nanosoc_eth_chiplet.sv while nobody is looking.
# Always a V2 build (TIDELINK_PHY_V2 rides in tidelink_fpga_v2.flist).
# Both modules share ONE compile (sim_build_gate_tc).
SIM_GATE_TC_ENV := TB_TOP_NO_DUMP=1 SIM_BUILD=sim_build_gate_tc

TIDECHART_HOME ?= $(realpath $(TIDELINK_HOME)/../tidechart)
# PROBE for the chiplet root by MARKER FILE rather than assuming a directory
# shape. tidelink is checked out two ways: as a SIBLING of the chiplet, and as a
# CHILD (submodule) of it. The old sibling-only default resolved to a NONEXISTENT
# nested path in the submodule layout; $(realpath) then returned EMPTY, the
# dep-check below saw a bare `/src/rtl/tidechart_shim.sv`, and tc_pair_smoke /
# tc_pair_election_datamode / eth_relay_m0 / eth_relay_m1 / eth_regs_shape_a all
# reported FALSE failures on `make sim_gate` — aborting at 0s BEFORE elaboration,
# so they cannot even reflect an RTL change. Measured 2026-08-14: all five PASS
# once the roots resolve. A STANDING FALSE-RED IS HOW A REAL RED GETS WAVED OFF.
# Sibling is probed first, so the historical layout keeps its exact behaviour.
CHIPLET_HOME   ?= $(realpath $(patsubst %/src/rtl/tidechart_shim.sv,%,$(firstword $(wildcard \
                    $(TIDELINK_HOME)/../nanosoc-ethernet-chiplet/src/rtl/tidechart_shim.sv \
                    $(TIDELINK_HOME)/../src/rtl/tidechart_shim.sv))))
# EXPORT is load-bearing: the tc_pair_*/eth_* suites run in a RECURSIVE
# `$(MAKE) -C cocotb/...`, which does NOT inherit a plain make variable. Without
# these exports the sub-make sees an EMPTY value and dies on a bare
# `/src/rtl/tidechart_shim.sv`, which looks identical to the missing-checkout
# case. Setting them as shell env vars used to mask this, because the environment
# propagates where a make variable does not.
export CHIPLET_HOME
export TIDECHART_HOME
SIM_GATE_TC_DEP = $(call SIM_GATE_REQUIRE,$(TIDECHART_HOME)/flist/tidechart.flist,tc_pair_* co-sim) && \
	$(call SIM_GATE_REQUIRE,$(CHIPLET_HOME)/src/rtl/tidechart_shim.sv,tc_pair_* co-sim)

sim_gate_tc_smoke:
	$(call sim_gate_run,tc_pair_smoke,\
	  $(SIM_GATE_TC_DEP) && \
	  $(MAKE) -C cocotb/tidechart_tidelink_pair $(SIM_GATE_TC_ENV) \
	    COCOTB_RESULTS_FILE=sim_build_gate_tc/res_smoke.xml \
	    MODULE=test_tc_pair_smoke)

sim_gate_tc_election:
	$(call sim_gate_run,tc_pair_election_datamode,\
	  $(SIM_GATE_TC_DEP) && \
	  $(MAKE) -C cocotb/tidechart_tidelink_pair $(SIM_GATE_TC_ENV) \
	    COCOTB_RESULTS_FILE=sim_build_gate_tc/res_election.xml \
	    MODULE=test_tc_pair_election_datamode)

# --- Ethernet-over-TideLink (M0 / M1 / shape-A) ------------------------------
# EPOCH_PROFILE=zero IS PINNED DELIBERATELY, AND IT IS NOT HIDING A DEFECT.
#
# The `silicon` profile injects a MODELLED whole-word S->M skew fingerprint.
# Under it, the peer-window round-trip hangs — and per
# docs/XHB_WINDOW_SKEW_ROOTCAUSE.md that hang is NOT a bug in any of these
# three benches: the V2 build hard-selects SYNC_REANCHOR_EN=1 /
# EPOCH_ANCHOR_EN=0 (local_overrides/WavD2DGpio_v2.v:790,827), there is no
# `ifdef TIDELINK_EPOCH_ANCHOR selector in the V2 override, so the Makefile
# EPOCH_ANCHOR knob is a DEAD NO-OP for V2 and no whole-word corrector is ever
# armed. Every V2 bench that crosses a skewed direction fails identically.
# That is ONE root cause in the PHY, and it is the SAME issue already tracked
# by sim_gate_xhb (which is likewise out of the aggregate).
#
# So the honest split is:
#   * gate these three at EPOCH_PROFILE=zero — that locks the thing they are
#     actually evidence FOR (the ethernet subsystem's AHB matrix / MAC / HA1588
#     register contract survives a link crossing);
#   * do NOT let them silently re-litigate the un-armed-corrector defect, which
#     belongs to ONE owner (XHB_WINDOW_SKEW_ROOTCAUSE.md) and would otherwise
#     paint three unrelated suites red for a fourth suite's root cause.
# Pinning is dishonest only when the pin is undocumented. It is documented here
# and cross-referenced there. If the corrector is ever armed, the promotion is
# to add EPOCH_PROFILE=silicon variants — NOT to edit these lines.
#
# M0: link-crossed frame into an ethernet-subsystem scratch RAM.
SIM_GATE_ETH_DEP = $(call SIM_GATE_REQUIRE,$(ETH_SS_HOME)/set_env.sh,the eth_* suites)

sim_gate_eth_m0:
	$(call sim_gate_run,eth_relay_m0,\
	  $(SIM_GATE_ETH_DEP) && \
	  $(MAKE) -C cocotb/eth_tidelink_pair EPOCH_PROFILE=zero \
	    SIM_BUILD=sim_build_gate_m0 \
	    COCOTB_RESULTS_FILE=sim_build_gate_m0/res.xml \
	    MODULE=test_eth_relay_smoke)

# M1 + shape-A additionally need the ETHERNET SUBSYSTEM's own env (ETH_SS_HOME,
# ETHMAC_AHB_HOME, SOCLABS_NANOSOC_ARCH_TECH_DIR, ARM_CORTEXM0PLUS_IP_PATH,
# ETHMAC_IP_DIR, HA1588_IP_DIR) — their flists reference the M0+ core, the
# OpenCores EthMAC and HA1588 under /research/AAA (READ-ONLY, flist-referenced,
# never modified). tidelink's own set_env.sh does not set those, so the gate
# sources the subsystem's set_env.sh in a SUBSHELL. SIM_GATE_ETH_DEP checks the
# checkout first, so a missing sibling is a one-line message in THIS suite's log
# rather than an unreadable VCS flist error 40 minutes in.
# Same two-layout probe as CHIPLET_HOME above: one level up for the SIBLING
# checkout, two for the SUBMODULE one. Sibling first, so existing setups are
# byte-identical in behaviour.
ETH_SS_HOME ?= $(realpath $(patsubst %/set_env.sh,%,$(firstword $(wildcard \
                 $(TIDELINK_HOME)/../nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh \
                 $(TIDELINK_HOME)/../../nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh))))
export ETH_SS_HOME
SIM_GATE_ETH_ENV := . $(ETH_SS_HOME)/set_env.sh >/dev/null 2>&1;

# M1: through the REAL ethernet_ss_ahb AHB matrix into eth_scratch_rx.
sim_gate_eth_m1:
	$(call sim_gate_run,eth_relay_m1,\
	  $(SIM_GATE_ETH_DEP) && \
	  $(SIM_GATE_ETH_ENV) \
	  $(MAKE) -C cocotb/eth_tidelink_pair_m1 EPOCH_PROFILE=zero \
	    SIM_BUILD=sim_build_gate_m1 \
	    COCOTB_RESULTS_FILE=sim_build_gate_m1/res.xml \
	    MODULE=test_eth_relay_m1)

# shape-A: real MAC / HA1588 REGISTERS driven across the link.
sim_gate_eth_shape_a:
	$(call sim_gate_run,eth_regs_shape_a,\
	  $(SIM_GATE_ETH_DEP) && \
	  $(SIM_GATE_ETH_ENV) \
	  $(MAKE) -C cocotb/eth_tidelink_pair_shape_a EPOCH_PROFILE=zero \
	    SIM_BUILD=sim_build_gate_sha \
	    COCOTB_RESULTS_FILE=sim_build_gate_sha/res.xml \
	    MODULE=test_eth_regs_shape_a)

# --- F14 error-injection: the VERIFIED-GOOD regressions ----------------------
# docs/ERROR_INJECTION_FINDINGS.md §4 "Non-findings (verified good — keep these
# as regressions)". These three modules assert real policy and pass against
# current RTL, so they gate normally:
#   S5 sync_collision — payload can never alias SYNC, confirmed both directions
#   S6 reset_storm    — N<=5 rapid LL swresets always recover (F-1 watchdog)
#   S4 credit_probe   — credit/a2l observability + the f9b94b7 phantom-pop fix
#                       STILL HOLDS (a second, independent lock on F10)
# One shared compile (sim_build_gate_ei), reused by the two sentinels below.
# NOTE the shape: TIDELINK_PHY_V2 is an ENV var (the flist reads it), but
# SIM_BUILD and COCOTB_RESULTS_FILE MUST be passed as make COMMAND-LINE
# variables. The bench sets `SIM_BUILD :=` and cocotb sets
# `COCOTB_RESULTS_FILE ?=`, and an environment value loses to `:=` — passing
# SIM_BUILD in the environment silently left every run in the bench's OWN
# sim_build_ei, i.e. sharing a build dir with any concurrent hand-run
# (OBSERVED 2026-07-18: that collision produced both a SIGKILLed simv and a
# skipped-but-green run). Command-line assignment beats both.
SIM_GATE_EI_ENV  := TIDELINK_PHY_V2=1
SIM_GATE_EI_ARGS := SIM_BUILD=sim_build_gate_ei

sim_gate_errinj:
	$(call sim_gate_run,errinj_regressions,\
	  cd cocotb/tidelink_error_injection && \
	  $(SIM_GATE_EI_ENV) $(MAKE) $(SIM_GATE_EI_ARGS) \
	    COCOTB_RESULTS_FILE=sim_build_gate_ei/res_sync.xml MODULE=test_ei_sync_collision && \
	  $(SIM_GATE_EI_ENV) $(MAKE) $(SIM_GATE_EI_ARGS) \
	    COCOTB_RESULTS_FILE=sim_build_gate_ei/res_storm.xml MODULE=test_ei_reset_storm && \
	  $(SIM_GATE_EI_ENV) $(MAKE) $(SIM_GATE_EI_ARGS) \
	    COCOTB_RESULTS_FILE=sim_build_gate_ei/res_credit.xml MODULE=test_ei_credit_probe)

# --- F14 KNOWN-DEFECT SENTINELS (XFAIL) --------------------------------------
# THE PROBLEM: the error-injection bench is written so that "a WEDGE or
# SILENT-CORRUPTION is recorded as a VERDICT[...] log line, NOT a test failure"
# (ERROR_INJECTION_FINDINGS.md §5). So `make MODULE=test_ei_lane7_repro` EXITS
# ZERO WHILE DEMONSTRATING A CRITICAL SILENT-CORRUPTION DEFECT. Gating those
# modules the normal way would print a green PASS next to a tapeout-gating
# finding — the worst possible outcome, strictly worse than not gating them.
#
# THE SENTINEL CONTRACT (a minimal xfail, consistent with the .status
# convention): run the module, then match the log against the EXACT verdict
# signature recorded on 2026-07-18. Three outcomes, and only one is quiet:
#   XFAIL — the defect is present, unchanged, exactly as documented.  Tolerated
#           by the summary, printed in its OWN section, NEVER as PASS.
#   XCHG  — the signature no longer matches. The behaviour CHANGED, in EITHER
#           direction: the defect may have been fixed (great — retire the
#           sentinel, promote a real assertion) or it may have WORSENED or
#           moved. Either way a human must look.  FAILS the gate.
#   XERR  — the module itself errored (precondition/harness broke).  FAILS.
# This is the only shape that satisfies "never green, but only red on news".
# A permanently-red gate gets ignored, which is the same rot by another route.

# $(call sim_gate_sentinel,<suite>,<command>,<shell predicate over $$L = the log>)
# The predicate is a shell expression, so a signature can AND several exact
# lines together — which is what makes it sensitive in BOTH directions (see the
# per-sentinel notes). Signatures use grep -F (fixed strings) deliberately: the
# recorded verdict lines contain {}, '' and / and an ERE would rot into a
# pattern that quietly matches nothing, i.e. a sentinel that cries XCHG forever.
define sim_gate_sentinel
	@mkdir -p $(SIM_GATE_DIR)
	@echo "[sim_gate] SENT $(1)  (log: $(SIM_GATE_DIR)/$(1).log)"
	@t0=$$(date +%s); \
	if ( $(2) ) > $(SIM_GATE_DIR)/$(1).log 2>&1; then rc=0; else rc=1; fi; \
	dt=$$(( $$(date +%s) - t0 )); \
	L=$(SIM_GATE_DIR)/$(1).log; \
	if [ $$rc -ne 0 ]; then st=XERR; \
	elif $(3); then st=XFAIL; \
	else st=XCHG; fi; \
	printf '%-28s %-5s %6ss %s\n' "$(1)" "$$st" "$$dt" "$(GATE_STAMP)" > $(SIM_GATE_DIR)/$(1).status; \
	echo "[sim_gate] $$st $(1) ($${dt}s)"; \
	if [ "$$st" != XFAIL ] && [ -z "$(SIM_GATE_NONFATAL)" ]; then \
	  echo "[sim_gate] $$st $(1) — sentinel not XFAIL; exiting non-zero (XCHG/XERR = investigate)"; \
	  exit 1; \
	fi
endef

# F14-A (was CRITICAL SILENT CORRUPTION — NOW CLOSED by the CRC re-enable,
# 2026-07-21): with the link-layer CRC on by POR default, corrupting lane 7 no
# longer commits a bad packet silently — the RX now REJECTS it (NOT-COMMITTED,
# crc_errors increments, rx_crc_err -> 1). This was a KNOWN-DEFECT XFAIL sentinel
# asserting the silent-corruption signature; it is PROMOTED to a positive PASS
# regression that guards the fix. Measured with CRC on (all 4 reps of lane7 flip
# are NOT-COMMITTED; stuck1/stuck0 are 3x NOT-COMMITTED + 1x BYTE-EXACT where the
# corruption is benign). The load-bearing invariant is that NOTHING is ever
# 'COMMITTED-WRONG/SILENT' again, and lane7-flip is fully rejected. If CRC ever
# regresses off, the silent-corruption class reappears -> this suite FAILS.
sim_gate_f14a_crc_catch:
	$(call sim_gate_run,f14a_crc_catch,\
	  cd cocotb/tidelink_error_injection && \
	  { $(SIM_GATE_EI_ENV) $(MAKE) $(SIM_GATE_EI_ARGS) \
	      COCOTB_RESULTS_FILE=sim_build_gate_ei/res_lane7.xml \
	      MODULE=test_ei_lane7_repro; } > f14a_run.log 2>&1; \
	  cat f14a_run.log; \
	  grep -qF "VERDICT[S3b_lane7_flip_x4]: histogram={'NOT-COMMITTED': 4}" f14a_run.log && \
	  ! grep -qF "COMMITTED-WRONG/SILENT" f14a_run.log && \
	  grep -qE "rx_crc_err 0->1" f14a_run.log)

# F14-B (HIGH, WEDGE): a transient data-mode disturbance leaves the link wedged
# in a way the standard SW re-bring-up (to_data_mode + CR/CRACK) CANNOT clear —
# only a full POR of BOTH dies recovers. Architectural: the SYNC beacon is off
# in data mode so a framing slip has no re-anchor, and to_data_mode never
# re-arms the deskew/calibrator. => no in-field recovery on silicon.
# Signature = BOTH S1 disturbance classes (all-lane flip, link-clock dropout)
# still classify as WEDGES, AND the S0 passthrough control still RECOVERS. That
# last clause is the instrument check this project keeps re-learning it needs
# (feedback_verify_instrument_before_dut): without it, a broken err_inject
# splice would wedge the link for a trivial reason and the sentinel would report
# a comfortable XFAIL for the WRONG cause. If a "retrain-lite" recovery path
# ever lands, the WEDGES clauses stop matching -> XCHG -> promote to a real
# asserting regression.
sim_gate_xfail_f14b:
	$(call sim_gate_sentinel,xfail_f14b_datamode_wedge,\
	  cd cocotb/tidelink_error_injection && \
	  $(SIM_GATE_EI_ENV) $(MAKE) $(SIM_GATE_EI_ARGS) \
	    COCOTB_RESULTS_FILE=sim_build_gate_ei/res_glitch.xml MODULE=test_ei_link_glitch,\
	  grep -qF "VERDICT[S1_s2m_data_flip]: WEDGES(unwedged only by full POR of BOTH dies)" $$L && \
	  grep -qF "VERDICT[S1_s2m_clock_kill]: WEDGES(unwedged only by full POR of BOTH dies)" $$L && \
	  grep -qF "VERDICT[S0_passthrough]: RECOVERS" $$L)

# EPOCH shipping-default corrector sentinel (2026-07-31). Captures the GENUINE
# still-open defect: with EPOCH_ANCHOR_EN at its shipping default (0), the
# SYNC_REANCHOR corrector never arms on beacon-off skew ⇒ s2m delivers
# all-zeros. On THIS base (I1 SELF_ARM+FIX-E + recovery FCSM) the link now
# reaches LINK_IDLE, so m2s (test_02) passes. Re-baselined 2026-08-09 (TL-030):
# after the FIX2/TL-024 calibrator update (2e6f8dc) the bilateral test_01 now
# ALSO exercises + fails on the SAME s2m all-zeros defect as test_03 (its m2s
# sub-check still delivers), so the signature is TESTS=3 PASS=1 FAIL=2 (test_01
# + test_03 s2m all-zeros, test_02 m2s pass). Core defect UNCHANGED — this is
# wider detection of the one beacon-starvation defect, not a regression; the
# rx=[0x00000000 check keeps it non-vacuous. Tolerated as XFAIL; the fix is
# EPOCH_ANCHOR_EN=1, gated by sim_gate_epoch_anchor_plumb. Flips to XCHG if s2m
# ever starts (or stops) delivering at the shipping default.
sim_gate_xfail_epoch_shipping:
	$(call sim_gate_sentinel,xfail_epoch_shipping_corrector,\
	  { $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon \
	      SIM_BUILD=sim_build_epoch_shipping \
	      COCOTB_RESULTS_FILE=sim_build_epoch_shipping/res_shipping.xml \
	      MODULE=test_v2_pair_data; true; },\
	  grep -qF "test_v2_pair_data.test_02_packet_master_to_slave passed" $$L && \
	  grep -qF "test_v2_pair_data.test_03_packet_slave_to_master failed" $$L && \
	  grep -qF "test_v2_pair_data.test_01_bilateral_linkup failed" $$L && \
	  grep -qF "rx=[0x00000000" $$L && \
	  grep -qF "TESTS=3 PASS=1 FAIL=2 SKIP=0" $$L)

# I5 XHB500 lost-response backstop (audit; wired 2026-07-31). Exercises the
# HREADYOUT-blind outstanding-response watchdog (tidelink_top.sv sub_osr_ctr_r)
# that fires an AHB ERROR on a lost peer R/B beat the per-beat stall timer
# cannot see. Needs the split-timeout build (per-beat parked at 2^20, the
# outstanding timer shrunk to 2^10) via +define+; own SIM_BUILD since
# EXTRA_DEFINES is not in the Makefile SIM_BUILD key.
sim_gate_v2_xhb_lostresp_pipe:
	$(call sim_gate_run,v2_xhb_lostresp_pipe,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero \
	    EXTRA_DEFINES="+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=20 +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10" \
	    SIM_BUILD=sim_build_lostresp \
	    COCOTB_RESULTS_FILE=sim_build_lostresp/res_lostresp.xml \
	    MODULE=test_v2_xhb_lostresp_pipe)

# HAZARD-3 / N2 fix (2026-08-18): the AUTO_ANCHOR recovery-beacon force term
# must respect the link layer's own io_link_tx_tx_idle before it can force a
# SYNC insertion. It used to ride swi_sync_force_always_in unconditionally,
# collapsing WavD2DGpio_v2.tx_sync_en_w to insert_en alone and dropping BOTH
# io_link_tx_tx_idle and the postcount==0 serialiser-drain guard -- a live app
# word mid-shift in the TX serializer could be corrupted. These two tests
# prove (1) tx_sync_en_w stays low while io_link_tx_tx_idle is hierarchically
# forced 0, with insertion able to resume once idle genuinely returns, and
# (2) a continuous hierarchical monitor across an end-to-end burst never
# samples tx_sync_en_w high while io_link_tx_tx_idle==0 on either die.
# AUTO_ANCHOR=1 is REQUIRED (the beacon must actually be able to go live);
# EPOCH_PROFILE=zero matches test_auto_anchor_no_word_loss_during_burst's
# existing config -- own SIM_BUILD (_autoanchor key, cocotb/tidelink_top_
# pair_v2/Makefile) so this never shares a compile with an AUTO_ANCHOR=0
# suite at the same EPOCH_PROFILE (this project has been bitten by exactly
# that class of sim_build collision before). NOT run under EPOCH_PROFILE=
# staircase here: test_v2_auto_anchor.py's module docstring documents a
# measured, disclosed regression in the PRE-EXISTING test_auto_anchor_
# delivers_under_skew under that profile (io_link_tx_tx_idle never reads 1
# under that specific severe-skew stress scenario, so the now-idle-qualified
# beacon cannot fire there) -- that test was not wired into sim_gate before
# this fix either, and fixing it is dedicated follow-up work + HW validation,
# out of scope here.
sim_gate_v2_auto_anchor:
	$(call sim_gate_run,v2_auto_anchor,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 AUTO_ANCHOR=1 EPOCH_PROFILE=zero \
	    SIM_BUILD=sim_build_zero_autoanchor \
	    COCOTB_RESULTS_FILE=sim_build_zero_autoanchor/res_auto_anchor.xml \
	    MODULE=test_v2_auto_anchor \
	    TESTCASE=test_auto_anchor_force_respects_tx_idle_forced$(comma)test_auto_anchor_no_corruption_word_boundary_forced)

# Anti-vacuous wiring cross-check (2026-07-30): fails if any suite in
# SIM_GATE_ALL_SUITES / SIM_GATE_SENTINELS is SCORED by the summary but never
# INVOKED by the sim_gate recipe (the "gate green on another branch's run"
# class). Run standalone (make sim_gate_inventory); not in the aggregate.
sim_gate_inventory:
	@echo "blocking suites ($(words $(SIM_GATE_ALL_SUITES))):"
	@for s in $(SIM_GATE_ALL_SUITES); do echo "  $$s"; done
	@echo "known-defect sentinels ($(words $(SIM_GATE_SENTINELS))):"
	@for s in $(SIM_GATE_SENTINELS); do echo "  $$s"; done
	@echo "--- wiring cross-check (declared vs invoked) ---"
	@mk=$(firstword $(MAKEFILE_LIST)); \
	inv=$$(mktemp); \
	sed -n '/^sim_gate: sim_gate_env_check/,/sim_gate_summary/p' $$mk \
	  | grep -oE 'SIM_GATE_NONFATAL=1 sim_gate_[a-z0-9_]+' \
	  | awk '{print $$2}' | sort -u > $$inv; \
	miss=0; \
	for s in $(SIM_GATE_ALL_SUITES) $(SIM_GATE_SENTINELS); do \
	  t=$$(grep -B40 -E "call sim_gate_(run|sentinel),$$s," $$mk \
	       | grep -oE '^sim_gate_[a-z0-9_]+:' | tail -1 | tr -d ':'); \
	  if [ -z "$$t" ]; then \
	    echo "  ORPHAN: $$s is scored but no target produces it"; miss=1; \
	  elif ! grep -qx "$$t" $$inv; then \
	    echo "  ORPHAN: $$s (target $$t) is SCORED but never INVOKED"; miss=1; \
	  fi; \
	done; \
	rm -f $$inv; \
	if [ $$miss -eq 0 ]; then echo "  OK — every declared suite is invoked"; \
	else echo "  ^^ the gate CANNOT PASS: the summary scores these MISS"; exit 1; fi

# --- RX-FIFO TWIN 2 — ACTIVE (in the aggregate since 2026-07-19) -------------
# F10's write-side twin (docs/RXFIFO_TWIN2_DISPOSITION.md): the unguarded
# write-side length-latch arm at src/rtl/fifo/tidelink_fifo_ctrl.sv:189 let any
# AHB write to offset 0 arm the packet-length latch, walking the write_ptr that
# the FC committer SHARES — worse than the shipped read-side phantom pop, which
# only corrupted the read pointer.
#
# PROMOTED 2026-07-19: docs/proposals/twin2_fix.patch is APPLIED to src/rtl
# (ENABLE_AHB_WRITE, default 1 = legacy behaviour, threaded ctrl -> mem -> fifo),
# and F10 is now CLOSED IN RTL — src/rtl/tidelink_top.sv instantiates the RX FIFO
# with .ENABLE_AHB_WRITE (0), so this suite gates a fix that actually ships.
#
# SUPERSEDED (2026-07-19) — DO NOT PROMOTE THIS TARGET. The TWIN-2 fix HAS now
# landed in src/rtl, but NOT as the patch this bench pins. David decided that
# AHB-CPU-write-to-RX IS a supported path, so the shipped fix QUALIFIES the
# write-side arm (tidelink_fifo_ctrl.sv `ahb_pkt_start_ok` + zero-length reject)
# instead of gating the path off, which is what cocotb/fifo_rx_twin2's
# *.PATCHED.sv copies do. Those copies are a FORK of the FIFO RTL and have
# already drifted (they predate the read-side saturate-at-MAX credit fix), so
# promoting this target would gate a stale fork, not what ships.
# The tree-truthful replacement is sim_gate_fifo_twin2_tree below.
sim_gate_fifo_twin2:
	$(call sim_gate_run,fifo_rx_twin2,\
	  rm -rf cocotb/fifo_rx_twin2/sim_build_tree && \
	  $(MAKE) -C cocotb/fifo_rx_twin2 sim)

# --- RX-FIFO TWIN 2 — GATED AGAINST THE TREE (promoted 2026-07-19) ----------
# cocotb/tidelink_fifo_twin2 compiles the SHIPPING flist (flists/tidelink_fifo.flist)
# with ENABLE_AHB_WRITE=1, the supported posture, and asserts BOTH halves of the
# decision: a stray clear/probe write pair is a no-op on write_ptr/credit AND a
# legitimate AHB-injected packet still commits byte-exact. Red/green across the
# RTL is cocotb/tidelink_fifo_twin2/run_redgreen.sh.
sim_gate_fifo_twin2_tree:
	$(call sim_gate_run,fifo_rx_twin2_tree,\
	  $(MAKE) -C cocotb/tidelink_fifo_twin2 SIM_BUILD=sim_build_gate_twin2 sim)

# --- xhb_window_skew_debug — NOT GATE MATERIAL (deliberate) ------------------
# cocotb/xhb_window_skew_debug/ has NO Makefile and NO testbench: it is a single
# instrumentation module (instr_xhb.py) that attaches to the pair_v2 bench to
# probe epoch_anchored_o / epoch_span_o. It has no pass criterion to assert —
# it is the MICROSCOPE that produced docs/XHB_WINDOW_SKEW_ROOTCAUSE.md, not a
# claim about the DUT. Gating a diagnostic would assert that its own
# measurements never change, which is not a property anyone wants locked.
# The finding it produced is already gated where it belongs: the un-armed
# whole-word corrector is what keeps sim_gate_xhb out of the aggregate, and is
# the documented reason the three eth suites above pin EPOCH_PROFILE=zero.

# --- V1 elaboration check (TIDELINK_PHY_V2=0, build-only, no test run) -------
# Fresh sim_build_v1elab each time so a stale simv can never false-PASS the
# gate; cocotb's $(SIM_BUILD)/simv target compiles + elaborates (Verdi KDB
# elaboration included) without launching a test — the Loop-4/6 fixers'
# run_v1elab_*.log recipe.
sim_gate_v1elab:
	$(call sim_gate_run,v1_elab,\
	  rm -rf cocotb/tidelink_top_pair/sim_build_v1elab \
	        cocotb/tidelink_top_pair/sim_build_zeropoke && \
	  cd cocotb/tidelink_top_pair && TIDELINK_PHY_V2=0 TB_TOP_NO_DUMP=1 \
	  SIM_BUILD=sim_build_v1elab $(MAKE) sim_build_v1elab/simv)

# --- ASIC (chip-build) flist elaboration check (from fix/integ-v1-elab) ------
# The v1_elab suite above elaborates only the cocotb *sim* flist. The a405809
# class of breakage (an obs_* port threaded into a src/rtl/local_overrides module
# while the ASIC flist still sources the deps/ submodule copy that lacks the port)
# breaks the *chip-build* flist — flists/tidelink_top_full_asic.flist, the DEFAULT
# of syn/asic/*/Makefile — but NOT the cocotb V2 sim, so a V2-only gate never sees
# it (tapeout chip-killer #4). Compiles the ASIC flist with plain VCS + a
# behavioural rf_16k SRAM stub. Any Error-/non-zero rc => FAIL. ~15 s.
sim_gate_asicelab:
	$(call sim_gate_run,asic_v1_elab,\
	  rm -rf cocotb/tidelink_top_pair/sim_build_asicelab && \
	  mkdir -p cocotb/tidelink_top_pair/sim_build_asicelab && \
	  cd cocotb/tidelink_top_pair/sim_build_asicelab && \
	  vcs -full64 -sverilog -timescale=1ns/1ps \
	    -f $(TIDELINK_HOME)/flists/tidelink_top_full_asic.flist \
	    $(TIDELINK_HOME)/syn/asic/sim_stubs/rf_16k_stub.v \
	    -top tidelink_top +define+TB_TOP_NO_DUMP -l vcs_asicelab.log)

# The V2 companion: the ASIC_PHY=_v2 DEFAULT chip-build flist (S3 PHY-swap, deps/
# tidelink-phy shared component, +define+TIDELINK_PHY_V2). This is the flist a real
# tape-out synth uses by default (syn/asic/fusion-compiler ASIC_PHY?=_v2), so a break
# here is a literal chip-killer. Fixed 2026-07-16: the flist now compiles
# tidelink_sync_word.svh up front so the deps deskew/sync files see the $unit params.
sim_gate_asicelab_v2:
	$(call sim_gate_run,asic_v2_elab,\
	  rm -rf cocotb/tidelink_top_pair/sim_build_asicelab_v2 && \
	  mkdir -p cocotb/tidelink_top_pair/sim_build_asicelab_v2 && \
	  cd cocotb/tidelink_top_pair/sim_build_asicelab_v2 && \
	  vcs -full64 -sverilog -timescale=1ns/1ps \
	    -f $(TIDELINK_HOME)/flists/tidelink_top_full_asic_v2.flist \
	    $(TIDELINK_HOME)/syn/asic/sim_stubs/rf_16k_stub.v \
	    -top tidelink_top +define+TB_TOP_NO_DUMP -l vcs_asicelab_v2.log)

# The ACTUAL TAPEOUT TOP: tidelink_dft_wrapper (adds the DFT/strap layer around
# tidelink_top and is where the silicon-param DEFAULTS live — HONEST_MASK_HS,
# ROLE_FROM_STRAP, NEGO_CFG_RESET, tl_data_mode_o). It was in NO flist and NO
# gate, which is EXACTLY why the dead-HONEST_MASK_HS strap (param omitted from the
# tidelink_top instantiation) went unseen: asic_v*_elab elaborate tidelink_top,
# not the wrapper. This gate elaborates the wrapper itself with -top so a dropped
# param connection / dead strap on the tapeout top FAILS here. Same flist as
# asic_v2 + the wrapper source; top = tidelink_dft_wrapper.
#
# STRUCTURAL TAPEOUT-CONTRACT ASSERTION (P1, 2026-07-30): the FPGA-only TX
# traffic generator (tidelink_tx_gen) MUST NOT be in the tapeout netlist
# (docs/TXGEN_V1_DESIGN.md). tidelink_top defaults TXGEN_PRESENT=1'b1, so the
# ASIC dft_wrapper must force it 1'b0 — WITHOUT that tie-off the generator +
# its ahb_tx 2:1 mux elaborate into silicon and a plain rc=0 elab gate stays
# GREEN (sim-invisible). Elaboration rc=0 is necessary but NOT sufficient, so
# we additionally assert the generator is absent from the ELABORATED module
# set. Note: tidelink_tx_gen.sv is in the flist and is always PARSED ("Parsing
# design file .../tidelink_tx_gen.sv"), so we must anchor on the elaborated
# instantiation line ("... module tidelink_tx_gen"), NOT the filename — the
# module-compiled-but-not-instantiated distinction. grep-hit => FAIL.
sim_gate_dftelab:
	$(call sim_gate_run,dft_wrapper_elab,\
	  rm -rf cocotb/tidelink_top_pair/sim_build_dftelab && \
	  mkdir -p cocotb/tidelink_top_pair/sim_build_dftelab && \
	  cd cocotb/tidelink_top_pair/sim_build_dftelab && \
	  vcs -full64 -sverilog -timescale=1ns/1ps \
	    -f $(TIDELINK_HOME)/flists/tidelink_top_full_asic_v2.flist \
	    $(TIDELINK_HOME)/src/rtl/asic/tidelink_dft_wrapper.sv \
	    $(TIDELINK_HOME)/syn/asic/sim_stubs/rf_16k_stub.v \
	    -top tidelink_dft_wrapper +define+TB_TOP_NO_DUMP -l vcs_dftelab.log && \
	  { if grep -qE 'module[[:space:]]+tidelink_tx_gen([^A-Za-z0-9_]|$$)' vcs_dftelab.log; then \
	      echo "FAIL: tidelink_tx_gen INSTANTIATED in ASIC tapeout netlist — TXGEN_PRESENT tie-off missing (docs/TXGEN_V1_DESIGN.md)"; exit 1; \
	    else echo "STRUCTURAL-OK: tidelink_tx_gen absent from ASIC tapeout elaborated netlist (TXGEN_PRESENT=0 tie-off holds)"; fi; })

# --- aggregate drivers -------------------------------------------------------
SIM_GATE_ALL_SUITES   := t31_autonomous_training_exit t32_die_a_first_zombie_retry \
	t30_autonomous_fc_handoff ptp_link_sync v2_pair_data v2_autonomous_sync_detect \
	v2_winscan_fsm v2_perf_ctrl v2_reduced_lane epoch_silicon epoch_anchor_plumb \
	v2_pair_sustained v2_truncated_pkt_credit v2_truncated_pkt_aperture_offset v2_xhb_lostresp_pipe \
	fifo_rx_phantom_pop fifo_rx_randinit v1_elab asic_v1_elab asic_v2_elab dft_wrapper_elab \
	apb_fc_cfg_preempt fch_apb_watchdog zeropoke_por retire_en_plumb \
	v2_lane_mask_oddlane v2_lane_mask_position v2_lane_mask_negctl \
	tc_pair_smoke tc_pair_election_datamode \
	eth_relay_m0 eth_relay_m1 eth_regs_shape_a errinj_regressions \
	fifo_rx_twin2_tree force_recal_w1p f14a_crc_catch \
	txgen_unit txgen_negctl v2_txgen txgen_ext_hijack nack_wedge_recovery axinode_obs \
	axi_datanode_recovery axi_datanode_gaps n1_read_backstop \
	i1_selfarm_rolelock i1_fixe_training_release v2_isolated_write_dataloss \
	v2_mbox_writeprotect \
	calibrator_wrap a2l_replay_cdc_1 a2l_replay_cdc_3 a2l_replay_cdc_5 \
	v2_auto_anchor
# KNOWN-DEFECT SENTINELS — reported in their OWN summary section. XFAIL (the
# documented defect, unchanged) is tolerated and is NEVER printed as PASS; XCHG
# (behaviour changed, either direction) and XERR fail the gate. See the sentinel
# contract above sim_gate_xfail_f14b (F14-A was promoted to sim_gate_f14a_crc_catch).
SIM_GATE_SENTINELS := xfail_f14b_datamode_wedge xfail_epoch_shipping_corrector v2_mask_hs_regress
# The two PS-hang locks are cheap (~1 min each) and guard a failure that costs a
# bench trip, so they run in the QUICK gate too.
SIM_GATE_QUICK_SUITES := t30_autonomous_fc_handoff v2_pair_data \
	v2_autonomous_sync_detect v2_winscan_fsm v2_perf_ctrl v2_reduced_lane \
	v2_truncated_pkt_credit v2_truncated_pkt_aperture_offset \
	fifo_rx_phantom_pop v1_elab asic_v1_elab asic_v2_elab \
	apb_fc_cfg_preempt fch_apb_watchdog zeropoke_por

# GATE-INTEGRITY: the cocotb Makefiles only track tb_top.sv/pad_skid.sv as
# compile deps — RTL/flist edits do NOT retrigger a VCS compile, so a cached
# simv silently tests STALE RTL (observed 2026-07-03: sim_build_l4 predating
# the 940b3c3 tb hooks failed t31/t32 with AttributeError on
# tb_syncoff_settle_short_q). The gate therefore always starts from clean
# build dirs; t31+t30 still share ONE fresh sim_build_l4 compile, t32 gets
# its own sim_build_l5, and the three v2 modules share ONE sim_build_zero.
.PHONY: sim_gate_clean_builds
sim_gate_clean_builds:
	@# GATE-INTEGRITY (2026-07-10): remove ALL sim_build dirs with a GLOB, not an
	@# enumerated subset. The old list rotted — sim_build_zero_auto and any new
	@# SIM_BUILD were left behind, so a suite reused a stale simv ("../simv up to
	@# date") and silently tested OLD RTL. cocotb only recompiles on
	@# tb_top.sv/pad_skid.sv changes, so an RTL/flist edit alone NEVER retriggers a
	@# compile — the cached simv is a false green. A glob cannot rot.
	@# The weekend-2026-07-18 benches get the SAME treatment — each has its own
	@# gate-owned SIM_BUILD (sim_build_gate_*), and each would otherwise reuse a
	@# simv that cocotb only rebuilds on tb_top.sv changes.
	@rm -rf cocotb/tidelink_top_pair/sim_build* \
	        cocotb/tidelink_top_pair_v2/sim_build* \
	        cocotb/tidechart_tidelink_pair/sim_build_gate* \
	        cocotb/eth_tidelink_pair/sim_build_gate* \
	        cocotb/eth_tidelink_pair_m1/sim_build_gate* \
	        cocotb/eth_tidelink_pair_shape_a/sim_build_gate* \
	        cocotb/tidelink_error_injection/sim_build_gate*

sim_gate: sim_gate_env_check sim_gate_clean_builds
	@rm -rf $(SIM_GATE_DIR) && mkdir -p $(SIM_GATE_DIR)
	@echo "========================================"
	@echo " sim_gate — full aggregate sim gate"
	@echo " blocking suites + 2 known-defect sentinels (~40-55 min)"
	@echo " inventory + what each suite protects: docs/SIM_GATE_COVERAGE.md"
	@echo "========================================"
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_t31
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_t32
	@# TL-024: t33_arm_stagger_episode_bind -> tracked-standalone known-defect (3.5h
	@# livelock budget; same FIX2 root cause as v2_mask_hs_regress). Nightly: make sim_gate_t33
	@#   (docs/WAIVER_TL024_FIX2_MASK_STAGGER.md)
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_t30
	@# Two-board PTP convergence (F13): real SYNC/DELAY_REQ exchange across the
	@# link, numeric servo-offset + PHC-skew convergence gate.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_ptp_link_sync
	@# NACK-wedge / ACK-drop / state-7 recovery — the two PROVEN-passing recovery
	@# tests, promoted into the blocking gate 2026-07-29 (test_14 stays out; see
	@# sim_gate_nack_wedge_sustained). Reuses the t31/t30 sim_build_l4 compile.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_nack_wedge_recovery
	@# AXI data-node observability (item I4): sampler unit test + Region F APB decode.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_axinode_obs
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_axi_datanode_recovery
	@# AXI data-node COVERAGE GAPS (2026-08-02 review of the eth-chiplet
	@# pushback): per-node injection on the four nodes only B ever covered,
	@# plus the I5 backstop-semantics properties that were never asserted.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_axi_datanode_gaps
	@# N1 (TAPEOUT BLOCKER, fix @e008c58): coincident stuck-read/stuck-write
	@# regression — the write backstop must no longer permanently mask the
	@# read backstop's AHB ERROR.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_n1_read_backstop
	@# I1 eth-chiplet bring-up regressions (SELF_ARM + FIX-E + isolated-write).
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_i1_selfarm
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_i1_fixe_training_release
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_isolated_write
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_mbox_writeprotect
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_xhb_lostresp_pipe
	@# HAZARD-3 / N2 fix: AUTO_ANCHOR beacon force must respect io_link_tx_tx_idle.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_auto_anchor
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_data
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_sustained
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_trunc_credit
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_trunc_aperture
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_syncdet
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_xfail_mask_hs
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_winscan
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_force_recal
	@# TL-032 calibrator wrap-stitch + TL-027 a2l replay-CDC data-plane trio (reproduce+heal).
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_calibrator_wrap
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_a2l_replay_cdc_1
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_a2l_replay_cdc_3
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_a2l_replay_cdc_5
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_perf
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_reduced_lane
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_epoch_silicon
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_epoch_anchor_plumb
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_sustained
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_trunc_credit
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo_twin2_tree
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo_randinit
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo_twin2
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v1elab
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_apb_preempt
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fch_wdog
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_zeropoke
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_asicelab
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_asicelab_v2
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_dftelab
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_retire_plumb
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_oddlane
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_lane_position
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_oddlane_negctl
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_txgen_unit
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_txgen_negctl
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_txgen_ext_hijack
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_txgen
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_tc_smoke
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_tc_election
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_eth_m0
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_eth_m1
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_eth_shape_a
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo_twin2_tree
	@# errinj FIRST: it owns the shared sim_build_gate_ei compile that the two
	@# sentinels then reuse (same pattern as t31 owning sim_build_l4 for t30).
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_errinj
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_f14a_crc_catch
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_xfail_f14b
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_xfail_epoch_shipping
	@# F-1/F-2 (AXI data-node review 2026-08-02) RESOLVED by the synth-B OKAY fix:
	@# test_i5_error_is_ahb_legal + test_i5_clean_drop_leaves_path_usable now run
	@# BLOCKING inside sim_gate_axi_datanode_gaps (gaps_backstop), not as XFAIL.
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_summary \
	  SIM_GATE_SUITES="$(SIM_GATE_ALL_SUITES)" \
	  SIM_GATE_SENTINELS="$(SIM_GATE_SENTINELS)"

sim_gate_quick: sim_gate_env_check sim_gate_clean_builds
	@rm -rf $(SIM_GATE_DIR) && mkdir -p $(SIM_GATE_DIR)
	@echo "========================================"
	@echo " sim_gate_quick — smoke gate (skips t31/t32)"
	@echo "========================================"
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_t30
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_data
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_trunc_credit
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_trunc_aperture
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_syncdet
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_winscan
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_perf
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v2_reduced_lane
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fifo
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_v1elab
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_apb_preempt
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_fch_wdog
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_zeropoke
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_asicelab
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_asicelab_v2
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 sim_gate_summary SIM_GATE_SUITES="$(SIM_GATE_QUICK_SUITES)"

sim_gate_summary:
	@echo "======================================================="
	@echo " sim_gate summary"
	@echo "======================================================="
	@echo "  gate stamp: $(GATE_STAMP)"; \
	fail=0; stale=0; \
	for s in $(SIM_GATE_SUITES); do \
	  if [ -f $(SIM_GATE_DIR)/$$s.status ]; then \
	    line=$$(cat $(SIM_GATE_DIR)/$$s.status); \
	  else \
	    line="$$s MISS - -"; \
	  fi; \
	  echo "  $$line"; \
	  set -- $$line; st=$$2; stamp=$$4; \
	  if [ "$$st" != PASS ]; then fail=1; fi; \
	  if [ "$$st" != MISS ] && [ "$$stamp" != "$(GATE_STAMP)" ]; then \
	    stale=1; echo "    ^ STALE/FOREIGN: status stamp '$$stamp' != current '$(GATE_STAMP)'"; fi; \
	done; \
	if [ -n "$(SIM_GATE_SENTINELS)" ]; then \
	  echo "-------------------------------------------------------"; \
	  echo "  KNOWN-DEFECT SENTINELS (XFAIL = defect present, UNCHANGED —"; \
	  echo "  this is NOT a pass; XCHG = behaviour changed, INVESTIGATE)"; \
	  for s in $(SIM_GATE_SENTINELS); do \
	    if [ -f $(SIM_GATE_DIR)/$$s.status ]; then \
	      line=$$(cat $(SIM_GATE_DIR)/$$s.status); \
	    else \
	      line="$$s MISS - -"; \
	    fi; \
	    echo "  $$line"; \
	    set -- $$line; st=$$2; stamp=$$4; \
	    if [ "$$st" != XFAIL ]; then fail=1; fi; \
	    if [ "$$st" != MISS ] && [ "$$stamp" != "$(GATE_STAMP)" ]; then \
	      stale=1; echo "    ^ STALE/FOREIGN: status stamp '$$stamp' != current '$(GATE_STAMP)'"; fi; \
	  done; \
	fi; \
	echo "-------------------------------------------------------"; \
	if [ $$stale -ne 0 ]; then \
	  echo "  RESULT: STALE / CROSS-BRANCH — one or more .status is not from $(GATE_STAMP)."; \
	  echo "          A green summary must belong to THIS commit; refusing to report PASS."; \
	  echo "          Re-run 'make sim_gate' on a clean checkout of the current tip."; \
	  exit 2; \
	fi; \
	if [ $$fail -eq 0 ]; then \
	  echo "  RESULT: ALL SUITES PASS @ $(GATE_STAMP)  (logs: $(SIM_GATE_DIR)/)"; \
	  if [ -n "$(SIM_GATE_SENTINELS)" ]; then \
	    echo "          (known defects still present as recorded — see docs/ERROR_INJECTION_FINDINGS.md)"; \
	  fi; \
	else \
	  echo "  RESULT: FAILURES DETECTED — see $(SIM_GATE_DIR)/<suite>.log"; \
	fi; \
	exit $$fail

# ── registry-driven regression harness (durable, "run for all bugs") ─────────
.PHONY: sim_gate_registry_coverage sim_gate_regressions sim_gate_one

# COVERAGE: every BUG_REGISTRY.yaml bug that claims verification.in_sim_gate:true
# must name a real, resolvable test; FIXED-but-ungated bugs are reported as gaps.
# Deterministic, no sim. REGCOV_ARGS=--strict also fails on fixed-but-ungated bugs.
sim_gate_registry_coverage:
	@python3 $(TIDELINK_HOME)/scripts/ci/registry_coverage.py $(REGCOV_ARGS)

# The single authoritative regression front-end: prove registry coverage, then run
# the tip-stamped, fail-loud, exit-on-FAIL aggregate. Use THIS in CI, not bare sim_gate.
sim_gate_regressions: sim_gate_registry_coverage sim_gate

# Sanctioned single-suite run that PROPAGATES failure (unlike bare `make sim_gate_<x>`,
# which records status and exits 0). Routes through the tip-stamped summary.
#   make sim_gate_one TOKEN=sim_gate_v2_data SUITE=v2_pair_data
sim_gate_one:
	@rm -rf $(SIM_GATE_DIR) && mkdir -p $(SIM_GATE_DIR)
	@$(MAKE) --no-print-directory SIM_GATE_NONFATAL=1 $(TOKEN)
	@$(MAKE) --no-print-directory sim_gate_summary SIM_GATE_SUITES="$(SUITE)" SIM_GATE_SENTINELS=""

# ── HARDWARE regression gate (durable, run-each-time; HW mirror of sim_gate) ──
# TL-024 (ratified 2026-08-08, keep-6): FIX 2 (lock thresh 5->6) is the ~10x peer-write
# soak lever but kills autonomous MASKED/STAGGERED bring-up (autoneg TRAIN_FAIL, FCSM
# never 4). Path-aware NOT viable (single lane_locked consumer; benefit+harm same
# decision). Tolerated as a known-defect XFAIL. docs/WAIVER_TL024_FIX2_MASK_STAGGER.md.
sim_gate_xfail_mask_hs:
	$(call sim_gate_sentinel,v2_mask_hs_regress,\
	  { $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero BYPASS_AUTONEG=0 HONEST_STRAPS=1 MODULE=test_v2_mask_hs_bilateral || true; },\
	  grep -qE "BLOCKING: role_lock (never latched|latched but the pair never reached bilateral FCSM)" $$L)

.PHONY: hwtest_registry_coverage hwtest_gate

# HW COVERAGE: every bug that claims verification.in_hw_gate:true must name a real
# HW test; HW-proven-but-ungated bugs are reported as gaps. Deterministic, no HW.
hwtest_registry_coverage:
	@python3 $(TIDELINK_HOME)/scripts/ci/hw_registry_coverage.py $(HWCOV_ARGS)

# The authoritative HW regression front-end: prove HW coverage, then run the
# provenance-stamped, POR-disciplined, byte-exact, fail-loud onchip gate.
# Never claim "HW green" from resident-bitstream logs — only from this.
hwtest_gate: hwtest_registry_coverage
	@bash $(TIDELINK_HOME)/pynq_host/scripts/hwtest_gate.sh


# ── ASIC PnR / GDSII flow ────────────────────────────────────────────────
# Exposes `make fc`, `make gdsii`, `make fc_lec`, `make fc_etm`, `make
# fc_all`, `make asic_stage`, `make asic_clean` at the project root.
# Override the partition cut with ASIC_MODULE=<name>; default is
# tidelink_top_full (full chiplet subsystem).
include flows/makefile.asic

# Clean all verification, lint, and synthesis directories
clean_all: clean_uvm clean_cocotb clean_xprop clean_lint clean_syn
	@echo "All clean targets completed"

# Clean UVM directories
clean_uvm:
	@echo "Cleaning UVM directories..."
	$(MAKE) -C uvm/tidelink clean
	$(MAKE) -C uvm/tidelink_fc_adapter clean
	$(MAKE) -C uvm/tidelink_integration clean
	$(MAKE) -C uvm/tidelink_top_system clean
	$(MAKE) -C uvm/tidelink_ptp_chain clean
	$(MAKE) -C uvm/tidelink_ptp_stress clean
	$(MAKE) -C uvm/tidelink_system clean
	@echo "UVM clean completed"

# Clean cocotb directories
clean_cocotb:
	@echo "Cleaning cocotb directories..."
	$(MAKE) -C cocotb/tidelink clean
	$(MAKE) -C cocotb/tidelink_ahb clean
	$(MAKE) -C cocotb/tidelink_fifo clean
	$(MAKE) -C cocotb/tidelink_returner clean
	$(MAKE) -C cocotb/tidelink_apb_regs clean
	$(MAKE) -C cocotb/tidelink_py_pair clean
	$(MAKE) -C cocotb/tidelink_fc_adapter clean
	$(MAKE) -C cocotb/tidelink_top clean
	$(MAKE) -C cocotb/tidelink_system clean
	$(MAKE) -C cocotb/tidelink_ptp clean
	@echo "cocotb clean completed"

# Clean xprop (X-propagation via VC Formal) directories
clean_xprop:
	@echo "Cleaning xprop directories..."
	$(MAKE) -C xprop/tidelink clean
	$(MAKE) -C xprop/tidelink_fifo clean
	$(MAKE) -C xprop/tidelink_fifo_ctrl clean
	$(MAKE) -C xprop/tidelink_apb_regs clean
	$(MAKE) -C xprop/tidelink_returner clean
	@echo "xprop clean completed"

# Clean lint directory
clean_lint:
	@echo "Cleaning lint directory..."
	$(MAKE) -C lint clean
	@echo "Lint clean completed"

# Clean synthesis directories
clean_syn:
	@echo "Cleaning synthesis directories..."
	$(MAKE) -C syn/asic/rtl-architect clean
	$(MAKE) -C syn/asic/design-compiler clean
	@echo "Synthesis clean completed"

# =============================================================================
# Publication guard — no vendor/foundry collateral  (added 2026-08-14)
# =============================================================================
#
# THIS REPOSITORY IS PUBLIC:
#   github.com/SoC-Labs/TideLink-Chiplet-Interconnect-AHB
#
# The scanner is the nanoSoC-ASIC-Toolkit's ci/check-vendor-collateral.sh. It is
# NOT copied here: it operates on `git ls-files` in whatever repository it is
# run from, so it works cross-repo by design, and one copy that gets maintained
# beats three that drift.
#
# It scans HEAD *and* the untracked-but-not-ignored files that the next
# `git add -A` would publish — the second corpus being the one that matters,
# since both of this estate's actual disclosures were files nobody had ignored.
# No EDA tool, no licence, no PDK; about a minute on this tree.
#
# WHERE THE TOOLKIT IS. The default below is the layout inside the
# nanosoc-ethernet-chiplet superproject, where this repository is a submodule
# and the toolkit is its sibling under ASIC/. A STANDALONE clone of TideLink has
# no toolkit beside it, and the targets say so and exit 2 rather than reporting
# a pass they did not measure:
#
#   make vendor-check ASIC_TOOLKIT_DIR=/path/to/nanoSoC-ASIC-Toolkit
#
# EVERY TARGET REPORTS THE SCANNER'S OWN EXIT CODE — no `|| true` anywhere. A
# guard that cannot fail the build is not a guard.
#
# MEASURED 2026-08-14, so nobody reads a red as a broken wiring: this tree does
# NOT pass. Both checkouts report absolute site paths and revision-coded vendor
# release names at HEAD, concentrated in cocotb/ flists and Makefiles. That is
# pre-existing debt the guard made visible, not damage the guard did.
# =============================================================================
.PHONY: vendor-check vendor-check-staged vendor-check-rev vendor-check-history \
        vendor-scan-guard install-git-hooks

ASIC_TOOLKIT_DIR ?= $(CURDIR)/../ASIC/asic-toolkit
VENDOR_SCAN      := $(ASIC_TOOLKIT_DIR)/ci/check-vendor-collateral.sh

## Fail with a sentence rather than "No such file or directory", because the
## standalone-clone case is normal and the fix is one variable.
vendor-scan-guard:
	@test -x "$(VENDOR_SCAN)" || { \
	    echo "vendor-check: scanner not found."; \
	    echo ""; \
	    echo "  Looked for: $(VENDOR_SCAN)"; \
	    echo ""; \
	    echo "  It lives in the nanoSoC-ASIC-Toolkit, a SEPARATE repository"; \
	    echo "  (git@github.com:SoC-Labs/nanoSoC-ASIC-Toolkit.git). Inside the"; \
	    echo "  nanosoc-ethernet-chiplet superproject it is at ASIC/asic-toolkit"; \
	    echo "  and the default above finds it. From a standalone TideLink clone,"; \
	    echo "  point at your checkout:"; \
	    echo ""; \
	    echo "      make $(MAKECMDGOALS) ASIC_TOOLKIT_DIR=/path/to/nanoSoC-ASIC-Toolkit"; \
	    echo ""; \
	    exit 2; }

## What publishing this working tree today would expose. The default mode.
vendor-check: vendor-scan-guard
	@$(VENDOR_SCAN)

## The INDEX rather than the working tree — what `git commit` is about to write.
## This is the mode the pre-commit hook runs.
vendor-check-staged: vendor-scan-guard
	@$(VENDOR_SCAN) --staged

## The tree at an arbitrary ref: what pushing THAT would publish, which is a
## different question from what your working tree holds. The mode the pre-push
## hook runs, once per ref.  e.g.  make vendor-check-rev REV=origin/main
REV ?= HEAD
vendor-check-rev: vendor-scan-guard
	@$(VENDOR_SCAN) --rev $(REV)

## Every blob reachable from every ref. Slow; the right thing before making a
## repository public or after rewriting history.
vendor-check-history: vendor-scan-guard
	@$(VENDOR_SCAN) --history

# ── Git hooks ────────────────────────────────────────────────────────────────
# The hooks are the toolkit's, installed by the toolkit's own installer. This
# target LOCATES it and runs it; it does not write a hook itself, because two
# implementations of a hook drift and the toolkit's is the maintained one.
#
# NOT run automatically and NOT run by CI: installing into .git changes a
# developer's own checkout, so it is a thing a person does once, knowingly.
HOOK_INSTALL_ARGS ?=
install-git-hooks:
	@set -e; \
	found=""; \
	for c in "$(ASIC_TOOLKIT_DIR)/hooks/install.sh" \
	         "$(ASIC_TOOLKIT_DIR)/hooks/install-hooks.sh" \
	         "$(ASIC_TOOLKIT_DIR)/scripts/install-git-hooks" \
	         "$(ASIC_TOOLKIT_DIR)/scripts/install-hooks.sh"; do \
	    [ -x "$$c" ] && { found="$$c"; break; }; \
	done; \
	if [ -z "$$found" ]; then \
	    echo "install-git-hooks: no toolkit hook installer found."; \
	    echo ""; \
	    echo "  Looked under ASIC_TOOLKIT_DIR = $(ASIC_TOOLKIT_DIR)"; \
	    echo "    hooks/install.sh  hooks/install-hooks.sh"; \
	    echo "    scripts/install-git-hooks  scripts/install-hooks.sh"; \
	    echo ""; \
	    if [ ! -d "$(ASIC_TOOLKIT_DIR)" ]; then \
	        echo "  That directory does not exist — pass ASIC_TOOLKIT_DIR=<toolkit checkout>."; \
	    else \
	        echo "  The toolkit is present but ships no installer at those paths yet."; \
	        echo "  Until it does, the gate is usable by hand and in CI:  make vendor-check"; \
	    fi; \
	    exit 2; \
	fi; \
	echo "install-git-hooks: running $$found"; \
	"$$found" $(HOOK_INSTALL_ARGS)

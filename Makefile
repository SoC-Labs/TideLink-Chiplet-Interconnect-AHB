.PHONY: clean_all clean_uvm clean_cocotb clean_xprop clean_lint clean_syn \
        sim_robust sim_synth_mode xdc_lint xdc_lint_selftest \
        synth_lint_selftest robust_all sim-repro sim-repro-skid3 \
        sim-regression

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
# hand. Eight gates, exact proven incantations (see docs/TESTING.md):
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

# $(call sim_gate_run,<suite-name>,<command>) — run one suite, tee-free log
# capture, never fail the make (the summary decides the exit code).
define sim_gate_run
	@mkdir -p $(SIM_GATE_DIR)
	@echo "[sim_gate] RUN  $(1)  (log: $(SIM_GATE_DIR)/$(1).log)"
	@t0=$$(date +%s); \
	if ( $(2) ) > $(SIM_GATE_DIR)/$(1).log 2>&1; then st=PASS; else st=FAIL; fi; \
	dt=$$(( $$(date +%s) - t0 )); \
	printf '%-28s %-4s %6ss\n' "$(1)" "$$st" "$$dt" > $(SIM_GATE_DIR)/$(1).status; \
	echo "[sim_gate] $$st $(1) ($${dt}s)"
endef

.PHONY: sim_gate sim_gate_quick sim_gate_env_check sim_gate_summary sim_gate_apb_preempt sim_gate_fch_wdog \
	sim_gate_t31 sim_gate_t32 sim_gate_t33 sim_gate_t30 \
	sim_gate_v2_data sim_gate_v2_syncdet sim_gate_v2_winscan sim_gate_v1elab

sim_gate_env_check:
	@command -v vcs >/dev/null 2>&1 || \
	  { echo "sim_gate: vcs not in PATH — run 'source ./set_env.sh' first"; exit 1; }
	@command -v cocotb-config >/dev/null 2>&1 || \
	  { echo "sim_gate: cocotb-config not in PATH — run 'source ./set_env.sh' first"; exit 1; }

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

# --- tidelink_top_pair_v2 suites (EPOCH_PROFILE=zero) ------------------------
sim_gate_v2_data:
	$(call sim_gate_run,v2_pair_data,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_pair_data)

sim_gate_v2_syncdet:
	$(call sim_gate_run,v2_autonomous_sync_detect,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_autonomous_sync_detect)

sim_gate_v2_winscan:
	$(call sim_gate_run,v2_winscan_fsm,\
	  $(MAKE) -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=zero MODULE=test_v2_winscan_fsm)

# --- V1 elaboration check (TIDELINK_PHY_V2=0, build-only, no test run) -------
# Fresh sim_build_v1elab each time so a stale simv can never false-PASS the
# gate; cocotb's $(SIM_BUILD)/simv target compiles + elaborates (Verdi KDB
# elaboration included) without launching a test — the Loop-4/6 fixers'
# run_v1elab_*.log recipe.
sim_gate_v1elab:
	$(call sim_gate_run,v1_elab,\
	  rm -rf cocotb/tidelink_top_pair/sim_build_v1elab && \
	  cd cocotb/tidelink_top_pair && TIDELINK_PHY_V2=0 TB_TOP_NO_DUMP=1 \
	  SIM_BUILD=sim_build_v1elab $(MAKE) sim_build_v1elab/simv)

# --- aggregate drivers -------------------------------------------------------
SIM_GATE_ALL_SUITES   := t31_autonomous_training_exit t32_die_a_first_zombie_retry \
	t33_arm_stagger_episode_bind \
	t30_autonomous_fc_handoff v2_pair_data v2_autonomous_sync_detect \
	v2_winscan_fsm v1_elab \
	apb_fc_cfg_preempt fch_apb_watchdog
# The two PS-hang locks are cheap (~1 min each) and guard a failure that costs a
# bench trip, so they run in the QUICK gate too.
SIM_GATE_QUICK_SUITES := t30_autonomous_fc_handoff v2_pair_data \
	v2_autonomous_sync_detect v2_winscan_fsm v1_elab \
	apb_fc_cfg_preempt fch_apb_watchdog

# GATE-INTEGRITY: the cocotb Makefiles only track tb_top.sv/pad_skid.sv as
# compile deps — RTL/flist edits do NOT retrigger a VCS compile, so a cached
# simv silently tests STALE RTL (observed 2026-07-03: sim_build_l4 predating
# the 940b3c3 tb hooks failed t31/t32 with AttributeError on
# tb_syncoff_settle_short_q). The gate therefore always starts from clean
# build dirs; t31+t30 still share ONE fresh sim_build_l4 compile, t32 gets
# its own sim_build_l5, and the three v2 modules share ONE sim_build_zero.
.PHONY: sim_gate_clean_builds
sim_gate_clean_builds:
	@rm -rf cocotb/tidelink_top_pair/sim_build_l4 \
	        cocotb/tidelink_top_pair/sim_build_l5 \
	        cocotb/tidelink_top_pair_v2/sim_build_zero \
	        cocotb/tidelink_top_pair/sim_build_v1elab

sim_gate: sim_gate_env_check sim_gate_clean_builds
	@rm -rf $(SIM_GATE_DIR) && mkdir -p $(SIM_GATE_DIR)
	@echo "========================================"
	@echo " sim_gate — full aggregate sim gate (10 suites)"
	@echo "========================================"
	@$(MAKE) --no-print-directory sim_gate_t31
	@$(MAKE) --no-print-directory sim_gate_t32
	@$(MAKE) --no-print-directory sim_gate_t33
	@$(MAKE) --no-print-directory sim_gate_t30
	@$(MAKE) --no-print-directory sim_gate_v2_data
	@$(MAKE) --no-print-directory sim_gate_v2_syncdet
	@$(MAKE) --no-print-directory sim_gate_v2_winscan
	@$(MAKE) --no-print-directory sim_gate_v1elab
	@$(MAKE) --no-print-directory sim_gate_apb_preempt
	@$(MAKE) --no-print-directory sim_gate_fch_wdog
	@$(MAKE) --no-print-directory sim_gate_summary SIM_GATE_SUITES="$(SIM_GATE_ALL_SUITES)"

sim_gate_quick: sim_gate_env_check sim_gate_clean_builds
	@rm -rf $(SIM_GATE_DIR) && mkdir -p $(SIM_GATE_DIR)
	@echo "========================================"
	@echo " sim_gate_quick — smoke gate (skips t31/t32)"
	@echo "========================================"
	@$(MAKE) --no-print-directory sim_gate_t30
	@$(MAKE) --no-print-directory sim_gate_v2_data
	@$(MAKE) --no-print-directory sim_gate_v2_syncdet
	@$(MAKE) --no-print-directory sim_gate_v2_winscan
	@$(MAKE) --no-print-directory sim_gate_v1elab
	@$(MAKE) --no-print-directory sim_gate_apb_preempt
	@$(MAKE) --no-print-directory sim_gate_fch_wdog
	@$(MAKE) --no-print-directory sim_gate_summary SIM_GATE_SUITES="$(SIM_GATE_QUICK_SUITES)"

sim_gate_summary:
	@echo "======================================================="
	@echo " sim_gate summary"
	@echo "======================================================="
	@fail=0; \
	for s in $(SIM_GATE_SUITES); do \
	  if [ -f $(SIM_GATE_DIR)/$$s.status ]; then \
	    line=$$(cat $(SIM_GATE_DIR)/$$s.status); \
	  else \
	    line=$$(printf '%-28s %-4s %6s' "$$s" MISS "-"); \
	  fi; \
	  echo "  $$line"; \
	  case "$$line" in *PASS*) ;; *) fail=1 ;; esac; \
	done; \
	echo "-------------------------------------------------------"; \
	if [ $$fail -eq 0 ]; then \
	  echo "  RESULT: ALL SUITES PASS  (logs: $(SIM_GATE_DIR)/)"; \
	else \
	  echo "  RESULT: FAILURES DETECTED — see $(SIM_GATE_DIR)/<suite>.log"; \
	fi; \
	exit $$fail


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

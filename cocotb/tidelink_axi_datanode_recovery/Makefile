# =============================================================================
# tidelink_axi_datanode_recovery -- AXI data-node error-recovery acceptance test.
#
# Sim repro of the on-silicon B-node (write-response) hard-wedge
# (docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md). Two TIDELINK_PHY_V2 dies at the
# ~40 ns silicon ratio, FCSM 0-4 re-pointed deps -> local_overrides (recovery
# present). Drives a real AXI write over the peer window, injects ONE single-bit
# error on the B beat via the Wlink built-in injector (data_id 0x82, the on-
# silicon 0x2E03_003C model), and classifies recover/wedge/error.
#
#   make repro   # AXI_CRC_MODE=off (RTL default) -> B error WEDGES (the bug)
#   make fixed   # AXI_CRC_MODE=on  (the fix)     -> B error RECOVERS byte-exact
#
# Root cause: the AXI FC nodes ship CRC-off (WlinkGenericFCSM_2.v:713), so the
# recovery FSM's only trigger (crc_corrupt) is dead. Enabling CRC arms it.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_axi_datanode_recovery

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# DUT flist: base v2 flist with the five AXI FC nodes re-pointed deps ->
# local_overrides (so the recovery FCSMs and the CRC path are compiled in).
BASE_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
# Default gaps config: FCSM_{,1-4} + WlinkEccSyndrome ALL re-pointed deps->local
# (recovery FSM present + ECC restored) = the FPGA-V2 flist config.
#
# TL-006 A3 COMBINED-CONFIG (ASIC_MIRROR=1): mirror the SHIPPING ASIC-V2 wlink
# error-path exactly -- WlinkEccSyndrome=local_override (the _T ECC-restore fix,
# ON) but WlinkGenericFCSM*=deps (recovery FSM ABSENT), CRC on at runtime. This is
# the tidelink_top_full_asic_v2.flist combination (Ecc :247 local, FCSM :284-288
# deps) that had never been co-simulated. The 5 FCSM modules are port-identical
# deps-vs-local (recovery is internal; verified), so the local->deps swap
# elaborates. Proves header-ECC correction is UPSTREAM of / independent from the
# recovery FCSM and co-exists with CRC-on.
ifeq ($(ASIC_MIRROR),1)
LOCAL_FLIST := $(CURDIR)/tidelink_fpga_v2_ecc_only_local.flist
_gen := $(shell sed -E 's@src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?)\.v@deps/axi-chiplet-controller/logical/wlink/\1.v@' $(BASE_FLIST) > $(LOCAL_FLIST))
else ifeq ($(ASIC_MIRROR),2)
# NON-VACUITY control: the PRE-A3 shipping ASIC (the 2026-05-05 blanket ECC bypass)
# = Ecc=deps AND FCSM=deps. Under this config the ECC header-correction tests MUST
# WEDGE (value_ok=False) -- proves the ASIC_MIRROR=1 pass is the _T fix, not the
# FCSM axis masking. Diagnostic only; not wired into any gate.
LOCAL_FLIST := $(CURDIR)/tidelink_fpga_v2_full_bypass.flist
_gen := $(shell sed -E 's@src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?|WlinkEccSyndrome)\.v@deps/axi-chiplet-controller/logical/wlink/\1.v@' $(BASE_FLIST) > $(LOCAL_FLIST))
else
LOCAL_FLIST := $(CURDIR)/tidelink_fpga_v2_fcsm_local.flist
_gen := $(shell sed -E 's@deps/axi-chiplet-controller/logical/wlink/(WlinkGenericFCSM(_[1-4])?|WlinkEccSyndrome)\.v@src/rtl/local_overrides/\1.v@' $(BASE_FLIST) > $(LOCAL_FLIST))
endif
COMPILE_ARGS += -f $(LOCAL_FLIST)

COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1

# Optional short I5 outstanding-response timeout so the persistent-eye repro
# (test_axi_b_persistent_eye_bounded) fires the backstop fast instead of at the
# 2^16 default. Passed only by the `persist` target (separate sim_build).
COMPILE_ARGS += $(EXTRA_DEFINES)

# Silicon clock ratio (ref_clk period ns). 40.0 = the ~40 ns silicon ratio.
REF_PERIOD_NS ?= 40.0
export TIDELINK_SIM_REF_PERIOD_NS = $(REF_PERIOD_NS)

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD ?= sim_build_axirec

include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(BASE_FLIST) $(LOCAL_FLIST) $(call flist_srcs,$(LOCAL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: repro fixed persist clean_builds

# Reproduce the silicon wedge: CRC at the shipping default (off) -> injected
# B-beat error is undetected -> mis-deliver -> B never returns -> WEDGE.
repro:
	$(MAKE) SIM_BUILD=sim_build_axirec MODULE=test_axi_datanode_recovery \
	        TESTCASE=test_axi_b_error_wedges_no_fix

# Prove the fix: CRC enabled on the AXI nodes -> injected B-beat error is
# detected -> NACK -> replay -> B returns byte-exact -> RECOVER.
fixed:
	$(MAKE) SIM_BUILD=sim_build_axirec MODULE=test_axi_datanode_recovery \
	        TESTCASE=test_axi_b_error_recovers

# Persistent-marginal-eye repro (the on-silicon hard-wedge condition): hold
# err_inj_smack high so EVERY B beat corrupts -> replay never converges. Proves
# the present-and-armed I5 bounds it to HRESP=ERROR (recoverable) rather than a
# silent hard-wedge. Short I5 timeout (2^13) so it fires fast; own sim_build.
persist:
	$(MAKE) SIM_BUILD=sim_build_axirec_persist MODULE=test_axi_datanode_recovery \
	        TESTCASE=test_axi_b_persistent_eye_bounded \
	        EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13

# Fix K — XHB500 hazard-list BID-correction (the N=1 same-address soak wedge).
# A returning B with a link-corrupted bid never matches its hazard entry, so the
# bufferable write is never freed and the next same-address write stalls => wedge,
# with NO synth-B (b_done keeps pulsing, the I5 timeout never fires). DEFAULT 2^16
# I5 timeout on purpose: the backstop must NOT mask a hazard-list stall. Own
# sim_build. Reproduce/fix pair (each its own bring-up).
BIDFIX_TESTS := test_axi_bid_corrupt_wedges_no_fix test_axi_bid_corrupt_recovers_fixk
.PHONY: bidfix $(BIDFIX_TESTS)
$(BIDFIX_TESTS):
	$(MAKE) SIM_BUILD=sim_build_bidfix MODULE=test_axi_datanode_recovery TESTCASE=$@
bidfix: ; @for t in $(BIDFIX_TESTS); do $(MAKE) $$t || exit 1; done

# Rank 1 — peer-WRITE data-phase drop (wr_hold_r, tidelink_top.sv). Own sim_build;
# default 2^16 I5 timeout (the fix is a hold, NOT a backstop).
#   #1 test_write_hold_hreadyout_waits_for_w_beat — white-box INVARIANT (primary):
#      ahb_sub_hreadyout must not complete before the W beat. PASS post-fix; FAIL
#      pre-fix (prove via `make writehold_prefix`, +define+TIDELINK_DISABLE_WR_HOLD).
#   #2 test_write_lands_under_w_backpressure — data-landing repro, marked skip=True
#      in the module (this tb cannot isolate land-vs-drop on the hreadyout axis; see
#      its docstring + the report). Deliberately NOT a make target: a skip=True test
#      is force-RUN when named via TESTCASE, so it stays out of `writehold` and is
#      skipped only when the whole module runs without a TESTCASE. Real data-landing
#      regression = the KR260 bench.
WRITEHOLD_TESTS := test_write_hold_hreadyout_waits_for_w_beat
.PHONY: writehold writehold_prefix $(WRITEHOLD_TESTS)
$(WRITEHOLD_TESTS):
	$(MAKE) SIM_BUILD=sim_build_writehold MODULE=test_axi_datanode_writehold TESTCASE=$@
writehold: ; @for t in $(WRITEHOLD_TESTS); do $(MAKE) $$t || exit 1; done

# Reproduce-first ISOLATION build (throwaway): +define+TIDELINK_DISABLE_WR_HOLD
# ties wr_hold_r=0 => the pre-fix RTL. Both writehold tests must FAIL here. Pick a
# case with T=..., default the #1 invariant.
T ?= test_write_hold_hreadyout_waits_for_w_beat
writehold_prefix:
	$(MAKE) SIM_BUILD=sim_build_writehold_prefix MODULE=test_axi_datanode_writehold \
	        EXTRA_DEFINES=+define+TIDELINK_DISABLE_WR_HOLD TESTCASE=$(T)

# TL-043 — synth_b_pending drain-guard LEVEL defeats wr_hold_r for ANY
# concurrent write, not just the stuck one the drain exists to rescue
# (test_tl002_wrhold_drain_guard.py). SHORT I5 outstanding-response timeout so
# the drain is sim-reachable (same 2^13 value as N1/gaps-backstop/TL-037); own
# sim_build. One test per sim (a second run_bringup_full does not re-POR
# cleanly, same as every other suite here).
#   test_second_write_survives_drain_guard — white-box INVARIANT (primary):
#      a second, unrelated peer write's wr_hold_r must latch and hold despite
#      a concurrent synth-B drain. FAILS pre-fix (or with
#      +define+TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT, which recreates the pre-fix
#      LEVEL guard) — the second write's wr_hold_r never latches.
#   test_second_write_data_landing — data-landing corroboration: measured
#      non-vacuous (unlike writehold's own #2, which stays skip=True), so it
#      is a REAL blocking test here, not force-run-only. Pre-fix the payload
#      lands 0x00000000 (dropped) at the far terminus; post-fix byte-exact.
WRHOLD_DRAIN_GUARD_LOG2  ?= 13
WRHOLD_DRAIN_GUARD_TESTS := test_second_write_survives_drain_guard \
                            test_second_write_data_landing
.PHONY: wrhold_drain_guard $(WRHOLD_DRAIN_GUARD_TESTS)
$(WRHOLD_DRAIN_GUARD_TESTS):
	$(MAKE) SIM_BUILD=sim_build_wrhold_drain_guard MODULE=test_tl002_wrhold_drain_guard \
	        EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=$(WRHOLD_DRAIN_GUARD_LOG2) \
	        TESTCASE=$@
wrhold_drain_guard: ; @for t in $(WRHOLD_DRAIN_GUARD_TESTS); do $(MAKE) $$t || exit 1; done

# TL-042 v2 — wr_hold_r starvation escape (the self-latch measured on die_a,
# imp/hw_gate/ila_tl035_run_round2/). SHORT backstop threshold so the 2**16 age
# fits in a sim; TL042_TIMEOUT_LOG2 must match the define. Own sim_build, one
# test per sim (a second run_bringup_full does not re-POR cleanly).
#   escape...  (a) hold escapes, (b) NOT via synth_b_pending and no synthetic B,
#              (c) a normal peer write still lands byte-exact afterwards.
#              FAILS on pre-TL-042-v2 RTL at (a) = the non-vacuity contract.
#   live_write safety: the escape is unreachable by a write whose AW was accepted
#              (constraint 1). Post-fix only; not an A/B discriminator.
TL042V2_LOG2  ?= 13
TL042V2_TESTS := test_tl042_v2_escape_is_clean_and_writes_still_land \
                 test_tl042_v2_live_write_is_never_released \
                 test_tl042_v2_escape_with_stalled_bridge
.PHONY: tl042v2 $(TL042V2_TESTS)
$(TL042V2_TESTS):
	TL042_TIMEOUT_LOG2=$(TL042V2_LOG2) $(MAKE) SIM_BUILD=sim_build_tl042v2 \
	        MODULE=test_axi_datanode_writehold \
	        EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=$(TL042V2_LOG2) \
	        TESTCASE=$@
tl042v2: ; @for t in $(TL042V2_TESTS); do $(MAKE) $$t || exit 1; done

clean_builds:
	rm -rf sim_build_axirec sim_build_axirec_* sim_build_bidfix sim_build_gaps* \
	       sim_build_writehold* sim_build_tl042v2* sim_build_wrhold_drain_guard* \
	       $(LOCAL_FLIST)

# =============================================================================
# COVERAGE-GAP suite (test_axi_datanode_gaps.py) — 2026-08-02 verification
# review of the eth-chiplet pushback. Two groups:
#
#   GAP-1  per-node error injection (AW/W/AR/R — only B was ever tested), which
#          is the consumer's stated acceptance gate.
#   GAP-2  I5 backstop SEMANTICS (AHB legality of its ERROR, timeout under
#          concurrent progress, path restoration, re-arm after abort).
#
# GAP-2 needs the SHORT I5 timeout (2^13) so the backstop fires inside a
# sim-able window; GAP-1 does not, so they use separate sim_builds.
# =============================================================================
#
# ONE TEST PER SIM — like the companion suite, a second run_bringup_full() in
# the same sim does not re-POR cleanly, so every test gets its own invocation.
# =============================================================================
GAPS_NODE_TESTS := test_axi_r_error_recovers test_axi_r_error_wedges_no_fix \
                   test_axi_ar_error_recovers test_axi_aw_error_recovers \
                   test_axi_w_error_recovers

GAPS_BACKSTOP_TESTS := test_i5_error_is_ahb_legal \
                       test_i5_read_stuck_errors_legally \
                       test_i5_traffic_behind_a_stuck_write_is_bounded \
                       test_i5_backstop_restores_the_path \
                       test_i5_clean_drop_leaves_path_usable \
                       test_i5_rearms_after_abort

# header-ECC RESTORE regression: a single-bit HEADER flip (byte 0 data_id, byte 1
# word_count) on each data node is corrected at the RX -> byte-exact. Non-vacuous:
# FAIL on the 2026-05-05 ECC bypass. Default 2^16 timeout (correction, not backstop).
GAPS_ECC_TESTS := test_ecc_corrects_w_byte0 test_ecc_corrects_aw_byte0 \
                  test_ecc_corrects_r_byte0 test_ecc_corrects_b_byte0 \
                  test_ecc_corrects_b_byte1_wordcount \
                  test_ecc_persistent_w_byte0_byte_exact

# TL-018 link-CRC A/B on the WRITE-DATA (W, 0x81) node. The two tests differ
# ONLY in `crc_on`, so the pair is its own non-vacuity control:
#   crc_off -> wrong word lands in peer memory, master sees SUCCESS, crc_errors=0
#   crc_on  -> detected, NACK'd, replayed, byte-exact
# Default 2^16 I5 timeout on purpose: this must be the CRC/NACK path recovering,
# not a backstop masking it. Shares the GAP-1 sim_build (same compile).
GAPS_CRC_TESTS := test_crc_off_silently_corrupts_write_data \
                  test_crc_on_detects_write_data_corruption

.PHONY: gaps gaps_nodes gaps_backstop gaps_ecc gaps_crc $(GAPS_NODE_TESTS) $(GAPS_BACKSTOP_TESTS) $(GAPS_ECC_TESTS) $(GAPS_CRC_TESTS)

$(GAPS_CRC_TESTS):
	$(MAKE) SIM_BUILD=sim_build_gaps_nodes MODULE=test_axi_datanode_gaps TESTCASE=$@

gaps_crc: ; @for t in $(GAPS_CRC_TESTS); do $(MAKE) $$t || exit 1; done

# Per-node injection (AW/W/AR/R). Default 2^16 I5 timeout — these must recover
# via NACK/replay long before any backstop is relevant.
$(GAPS_NODE_TESTS) $(GAPS_ECC_TESTS):
	$(MAKE) SIM_BUILD=sim_build_gaps_nodes MODULE=test_axi_datanode_gaps TESTCASE=$@

# I5 backstop semantics. Short outstanding-response timeout, own sim_build.
$(GAPS_BACKSTOP_TESTS):
	$(MAKE) SIM_BUILD=sim_build_gaps MODULE=test_axi_datanode_gaps \
	        EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 TESTCASE=$@

gaps_nodes:    ; @for t in $(GAPS_NODE_TESTS);     do $(MAKE) $$t || exit 1; done
gaps_backstop: ; @for t in $(GAPS_BACKSTOP_TESTS); do $(MAKE) $$t || exit 1; done
gaps_ecc:      ; @for t in $(GAPS_ECC_TESTS);      do $(MAKE) $$t || exit 1; done
# TL-006 A3 combined-config: the 6 ECC-restore tests under the SHIPPING ASIC wlink
# config (Ecc-local fix ON + FCSM-deps recovery ABSENT + CRC-on). Own sim_build.
gaps_ecc_asic: ; @for t in $(GAPS_ECC_TESTS); do \
	$(MAKE) ASIC_MIRROR=1 SIM_BUILD=sim_build_gaps_ecc_asic MODULE=test_axi_datanode_gaps TESTCASE=$$t || exit 1; done
gaps: gaps_nodes gaps_backstop gaps_ecc

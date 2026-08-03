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
LOCAL_FLIST := $(CURDIR)/tidelink_fpga_v2_fcsm_local.flist
_gen := $(shell sed -E 's@deps/axi-chiplet-controller/logical/wlink/(WlinkGenericFCSM(_[1-4])?)\.v@src/rtl/local_overrides/\1.v@' $(BASE_FLIST) > $(LOCAL_FLIST))
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

clean_builds:
	rm -rf sim_build_axirec sim_build_axirec_* sim_build_gaps* $(LOCAL_FLIST)

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

.PHONY: gaps gaps_nodes gaps_backstop $(GAPS_NODE_TESTS) $(GAPS_BACKSTOP_TESTS)

# Per-node injection (AW/W/AR/R). Default 2^16 I5 timeout — these must recover
# via NACK/replay long before any backstop is relevant.
$(GAPS_NODE_TESTS):
	$(MAKE) SIM_BUILD=sim_build_gaps_nodes MODULE=test_axi_datanode_gaps TESTCASE=$@

# I5 backstop semantics. Short outstanding-response timeout, own sim_build.
$(GAPS_BACKSTOP_TESTS):
	$(MAKE) SIM_BUILD=sim_build_gaps MODULE=test_axi_datanode_gaps \
	        EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 TESTCASE=$@

gaps_nodes:    ; @for t in $(GAPS_NODE_TESTS);     do $(MAKE) $$t || exit 1; done
gaps_backstop: ; @for t in $(GAPS_BACKSTOP_TESTS); do $(MAKE) $$t || exit 1; done
gaps: gaps_nodes gaps_backstop

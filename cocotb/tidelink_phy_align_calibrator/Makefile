# =============================================================================
# tidelink_phy_align_calibrator — CI unit env for the §9 RTL calibrator FSM.
#
# Scope (intentionally narrow — see docs/VPLAN.md §3.14):
#
#   * test_calibrator_t3            — T3 continuous re-sweep + T3.2 peer-aware
#                                     S_HOLD FSM transitions (commits 1e5f4e0,
#                                     50f7869). 4 @cocotb.test functions.
#   * test_calibrator_s_probe_skip  — S_PROBE → S_FINISH skip path (commit
#                                     f900e07). 3 @cocotb.test functions.
#
# Both tests share the single-DUT testbench tb_top.sv. The broader scenario-
# pinned tests (best-of-sweep policy comparator, eye-visibility wrappers,
# best-of-sweep placeholder) remain under cocotb/debug/ and are driven by
# hand — they exist for investigation, not regression.
#
# DWELL_CYCLES / HOLD_CYCLES are overridden via parameter knobs to keep
# wall-clock time bounded; RTL behaviour is unchanged.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# Default TOPLEVEL/wrapper. The cal_done-without-lock invariant test
# (test_calibrator.py) needs cr_pkt_seen_i / crack_pkt_seen_i as DRIVABLE
# ports and a small VALIDATION_TIMEOUT override — tb_top.sv ties cr_pkt_seen_i
# high and omits crack_pkt_seen_i, so it cannot reach the S_VALIDATE timeout.
# tb_calibrator.sv exposes both validation inputs + a VALIDATION_TIMEOUT knob.
#
# The legacy T3 / S_PROBE-skip envs still build against tb_top.sv via:
#   make TOPLEVEL=tb_top MODULE=test_calibrator_t3,test_calibrator_s_probe_skip
# -- Which calibrator RTL? ----------------------------------------------------
# DEPS=1 compiles the DEPLOYED deps/tidelink-phy calibrator (the one the FPGA
# flist actually builds — flists/tidelink_fpga_v2.flist) via the *_deps TB
# wrappers, so the unit env gates the actually-deployed RTL. Default (DEPS=0)
# compiles the src/ reference, preserving the historical behaviour.
DEPS ?= 0
ifeq ($(DEPS),1)
  CAL_RTL        = $(TIDELINK_HOME)/deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv
  TB_CALIBRATOR  = $(CURDIR)/tb_calibrator_deps.sv
  TB_TOP         = $(CURDIR)/tb_top_deps.sv
  TOP_CALIBRATOR = tb_calibrator_deps
  TOP_TOP        = tb_top_deps
else
  CAL_RTL        = $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv
  TB_CALIBRATOR  = $(CURDIR)/tb_calibrator.sv
  TB_TOP         = $(CURDIR)/tb_top.sv
  TOP_CALIBRATOR = tb_calibrator
  TOP_TOP        = tb_top
endif

TOPLEVEL ?= $(TOP_CALIBRATOR)
ifeq ($(TOPLEVEL),$(TOP_TOP))
VERILOG_SOURCES = $(TB_TOP) $(CAL_RTL)
MODULE  ?= test_calibrator_t3,test_calibrator_s_probe_skip
else
VERILOG_SOURCES = $(TB_CALIBRATOR) $(CAL_RTL)
MODULE  ?= test_calibrator
endif

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

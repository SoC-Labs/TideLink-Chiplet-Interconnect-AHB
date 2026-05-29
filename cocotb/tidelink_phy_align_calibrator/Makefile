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

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv

TOPLEVEL = tb_top
MODULE  ?= test_calibrator_t3,test_calibrator_s_probe_skip

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# -- Code coverage -----------------------------------------------------------
ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

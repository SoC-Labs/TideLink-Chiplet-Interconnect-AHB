SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_tidelink_autoneg

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv
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

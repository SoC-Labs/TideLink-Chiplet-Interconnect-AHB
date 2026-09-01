# XHB500 bridge-pair unit bench.
#
# Covers the INBOUND (AXI->AHB) bridge, which no other simulation in this
# repository reaches, and the error/exclusive response paths of BOTH bridges.
# See tb_top.sv for why the two DUTs are instantiated side by side rather than
# chained.

SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_xhb500_bridge

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# Duplicate module definitions are EXPECTED here and are not a bench defect:
# the mst and slv XHB500 deliverables each ship their own copy of the generic
# cells (xhb500_flop/or/sync/xor).  The shipping tapeout flist compiles both
# copies too -- this bench must not differ from it.
COMPILE_ARGS += +warn=noMDUPI
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/xhb500_bridge_unit.flist

SIM_ARGS     += +vcs+dumpvars+waves.vcd

# -- Code coverage (shared wiring; inert unless COVERAGE=1) ------------------
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

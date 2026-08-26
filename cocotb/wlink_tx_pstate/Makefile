# WlinkTxPstateCtrl unit bench -- the Wlink TX power-state controller, FSM
# 0.00% (0 of 4 transitions) in all 42 coverage databases that contain it.
# See tb_top.sv for why that matters: its output is the PHY TX enable.

SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_wlink_tx_pstate

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# The single shipping source, named by flists/tidelink_top_full_asic_v2.flist:325.
COMPILE_ARGS += $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/WlinkTxPstateCtrl.v

SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(CURDIR)/../coverage.mk
include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

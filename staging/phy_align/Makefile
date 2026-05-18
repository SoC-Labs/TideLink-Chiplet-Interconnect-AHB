# =============================================================================
# staging/phy_align — standalone cocotb test for wlink_phy_align_calibrator
# =============================================================================
#
# This sim builds ONLY the FSM under test; no Wlink stack, no chiplet
# controller. The lane-checker is mocked in Python (see test_autocal.py).
#
#   make                                 # run all @cocotb.test() in test_autocal
#   make MODULE=test_autocal             # explicit
#   make WAVES=1                         # dump waves.vcd (default off)
# =============================================================================

SIM            = vcs
TOPLEVEL_LANG  = verilog

# Calibrator now lives in src/rtl/ (renamed file, same module name).
# Pull it from there so the staging regression tracks the integrated copy.
TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
VERILOG_SOURCES = $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv \
                  $(CURDIR)/tb_autocal.sv

TOPLEVEL = tb_autocal
MODULE  ?= test_autocal

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: distclean
distclean:
	rm -rf sim_build results.xml waves.vcd ucli.key csrc *.daidir *.log

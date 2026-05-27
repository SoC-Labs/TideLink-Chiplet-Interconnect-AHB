# =============================================================================
# tidelink_lane_checker_prbs — cocotb unit sim for the PRBS-7 lock-detect
#                              path (feat/calibrator-prbs).
#
# Run:
#   cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter
#   source set_env.sh
#   rm -rf cocotb/tidelink_lane_checker_prbs/sim_build
#   make -C cocotb/tidelink_lane_checker_prbs
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_lane_checker.sv

TOPLEVEL = tb_top
MODULE  ?= test_lane_checker_prbs

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

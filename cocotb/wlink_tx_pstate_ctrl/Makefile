# =============================================================================
# wlink_tx_pstate_ctrl -- standalone cocotb unit sim for WlinkTxPstateCtrl.
#
# Tests whether the pstate FSM (states 0/1/2) can deadlock when io_tx_ready
# stays LOW post-bringup. Direct probes of state, req_pstate, io_tx_en.
#
# Run (always clean sim_build first -- VCS does NOT rebuild simv on RTL edits):
#
#   cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
#   source set_env.sh
#   rm -rf cocotb/wlink_tx_pstate_ctrl/sim_build
#   make -C cocotb/wlink_tx_pstate_ctrl
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

WLINK_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(WLINK_DIR)/WlinkTxPstateCtrl.v

TOPLEVEL = tb_top
MODULE  ?= test_wlink_tx_pstate_deadlock

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

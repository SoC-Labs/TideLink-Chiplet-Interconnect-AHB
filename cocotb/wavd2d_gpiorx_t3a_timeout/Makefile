# =============================================================================
# wavd2d_gpiorx_t3a_timeout — standalone cocotb unit sim for the T3a
#   MAX_HUNT timeout fallback (silent-peer graceful degradation).
# =============================================================================
#
# The T3a hunt FSM (USE_T3A=1) has a bounded MAX_HUNT cycle budget after
# S_SETTLE before falling through to S_LOCKED with NO slip applied — the
# "peer is silent" graceful-degradation path that prevents staggered
# bring-up from livelocking if the peer is in POR longer than MAX_HUNT
# pad_clk periods.
#
# This testbench instantiates a SINGLE WavD2DGpioRx (not the 8-lane array
# the realign test uses) so the cocotb hierarchical handle into
# u_dut.g_t3a_realign.align_state is a flat path (no flaky `g_lane[N]`
# array indexing in the VCS / cocotb 2.0 combination). Companion to:
#   * cocotb/wavd2d_gpiorx_t3a/      USE_T3A=1, slip-on-match (8 lanes)
#   * cocotb/wavd2d_gpiorx_t3a_off/  USE_T3A=0, legacy free-run
#
# Run (always clean sim_build first):
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/wavd2d_gpiorx_t3a_timeout/sim_build
#   make -C cocotb/wavd2d_gpiorx_t3a_timeout
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

WLINK_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(WLINK_DIR)/WavD2DGpioRx.v \
                  $(WLINK_DIR)/WavClockInv.v \
                  $(WLINK_DIR)/WavClockMux.v \
                  $(WLINK_DIR)/WavResetSync.v \
                  $(WLINK_DIR)/WavAnd.v \
                  $(WLINK_DIR)/WavDemetSet.v

TOPLEVEL = tb_top
MODULE  ?= test_t3a_timeout

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

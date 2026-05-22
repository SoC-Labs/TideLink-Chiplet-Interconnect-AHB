# =============================================================================
# wavd2d_gpiorx_t3a — standalone cocotb unit sim for the T3a comma-hunt path
# =============================================================================
#
# Elaborates EIGHT parallel WavD2DGpioRx instances (USE_T3A=1, USE_CLKBUF=0),
# one per lane with the lane-specific TRAINING_BYTE constants WavD2DGpio.v
# overrides at instantiation (0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D).
# Each DUT runs independently, sharing io_pad_clk + io_por_reset, with its
# own io_pad input and io_link_data output. One simv run therefore covers
# all 8 lanes at unit level.
#
# The cocotb test, for each lane × each of 4 random initial count-skew
# values, applies POR, drives the per-lane TRAINING_BYTE in a repeating
# stream on the lane's io_pad with the chosen starting bit offset, and
# samples io_link_data after the hunt FSM settles. The assertion is that
# the captured 16-bit value is INVARIANT across the 4 skews for that
# lane — T3a's contract: kill the per-deploy 16-cycle word-boundary
# lottery.
#
# Run (always clean sim_build first — VCS does NOT rebuild simv on RTL or
# +define+ edits, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/wavd2d_gpiorx_t3a/sim_build
#   make -C cocotb/wavd2d_gpiorx_t3a
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# DUT + helpers — WavD2DGpioRx pulls in WavClockInv, WavClockMux and
# WavResetSync from the same wlink directory.
WLINK_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(WLINK_DIR)/WavD2DGpioRx.v \
                  $(WLINK_DIR)/WavClockInv.v \
                  $(WLINK_DIR)/WavClockMux.v \
                  $(WLINK_DIR)/WavResetSync.v \
                  $(WLINK_DIR)/WavAnd.v \
                  $(WLINK_DIR)/WavDemetSet.v

TOPLEVEL = tb_top
MODULE  ?= test_t3a_realign

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

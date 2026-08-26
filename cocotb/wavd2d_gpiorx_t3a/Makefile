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
WLINK_DIR    := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink
OVERRIDE_DIR := $(TIDELINK_HOME)/src/rtl/local_overrides

# SoC Labs tdif-04 (2026-05-25): switch from the base dep RTL to the
# local override at src/rtl/local_overrides/WavD2DGpioRx.v which adds the
# T3A_CONTINUOUS parameter. Default T3A_CONTINUOUS=0 (one-shot terminal
# S_LOCKED, byte-identical base RTL) preserves the existing
# test_t3a_invariance pass. Setting T3A_CONT=1 from this Makefile threads
# a `+define+T3A_CONT=1` into VCS which the tb_top instantiates each DUT
# with — see comment in tb_top.sv.
T3A_CONT ?= 0
VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(OVERRIDE_DIR)/WavD2DGpioRx.v \
                  $(WLINK_DIR)/WavClockInv.v \
                  $(WLINK_DIR)/WavClockMux.v \
                  $(WLINK_DIR)/WavResetSync.v \
                  $(WLINK_DIR)/WavAnd.v \
                  $(WLINK_DIR)/WavDemetSet.v

TOPLEVEL = tb_top
MODULE  ?= test_t3a_realign

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
                +define+T3A_CONT=$(T3A_CONT)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience target: build+run the T3A_CONTINUOUS=1 variant in a separate
# sim_build dir so it doesn't collide with the default one-shot build.
.PHONY: sim_cont
sim_cont:
	$(MAKE) -C $(CURDIR) SIM_BUILD=sim_build_cont T3A_CONT=1 MODULE=test_t3a_realign

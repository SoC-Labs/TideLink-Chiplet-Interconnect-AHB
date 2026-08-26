# =============================================================================
# wavd2d_gpiorx_clkbuf — standalone cocotb unit sim for the in-PHY BUFG
#                       restructure (WavD2DGpioRx USE_CLKBUF parameter).
# =============================================================================
#
# The §9 clock fix (2026-05-19) added USE_CLKBUF to WavD2DGpioRx — a per-lane
# generate that either:
#   * USE_CLKBUF=0 (sim/ASIC/UVM default) → aliases the three derived clocks
#                   (w_cnt_clk, w_pad_clk, w_lnk_clk) to the original
#                   WavClockMux outputs. Bit-exact to the pre-restructure RTL.
#   * USE_CLKBUF=1 (FPGA) → BUFG-backs the two derived per-lane clocks
#                   (capture clock = io_pad_clk; divided word clock =
#                   ~adj_count[3]) so each lane's clock reaches its 16
#                   capture flops on the dedicated clock network. Kills
#                   the 7× Place 30-568 LUT-driving-clock warnings.
#
# This testbench instantiates ONE WavD2DGpioRx with USE_CLKBUF=0 + USE_T3A=0
# (the bit-exact legacy combination) and drives a known training-byte stream
# on io_pad. The test asserts that the deserialised io_link_data is
# functionally equivalent to what the pre-restructure RTL would have produced
# — i.e. the USE_CLKBUF=0 alias path is invisible at the lane outputs.
#
# We do NOT instantiate USE_CLKBUF=1 here: that branch elaborates real Xilinx
# BUFG primitives. The opt-OUT escape hatch (TIDELINK_RXCLK_NO_PRIMITIVE)
# inside that branch IS available, but the per-lane BUFG instance names
# would still need to exist — and they don't, the `else just `assigns the
# three w_* clocks back to the WavClockMux outputs. So opt-OUT USE_CLKBUF=1
# would be functionally identical to USE_CLKBUF=0 (same w_* sources), giving
# no new coverage. We leave that corner to the cocotb/tidelink_rxclk_buf
# boundary-BUFG test which already exercises an analogous opt-OUT branch.
#
# Run (always clean sim_build first — VCS does NOT rebuild simv on RTL edits
# or +define+ changes, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/wavd2d_gpiorx_clkbuf/sim_build
#   make -C cocotb/wavd2d_gpiorx_clkbuf
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
MODULE  ?= test_clkbuf_passthrough

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

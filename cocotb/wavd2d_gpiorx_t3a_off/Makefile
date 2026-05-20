# =============================================================================
# wavd2d_gpiorx_t3a_off — standalone cocotb unit sim for USE_T3A=0
#                        strict bit-exact passthrough of the legacy `count`.
# =============================================================================
#
# The T3a comma-hunt restructure (USE_T3A parameter) is gated by a generate
# block inside WavD2DGpioRx.v. With USE_T3A=0 (sim/ASIC/UVM default), the
# whole hunt-FSM + shifter + slip arithmetic is pruned — the generate-if
# selects the g_t3a_passthru arm which is the legacy free-running counter:
#
#     g_t3a_passthru:
#       always @(posedge w_cnt_clk or posedge io_por_reset) begin
#         if (io_por_reset) count <= 4'hf;
#         else              count <= count + 4'h1;
#       end
#
# This testbench pins that legacy passthrough so a future edit to the
# generate (or to TRAINING_BYTE handling) doesn't accidentally regress the
# sim/ASIC default. Companion to cocotb/wavd2d_gpiorx_t3a/ which exercises
# the USE_T3A=1 arm.
#
# Run (always clean sim_build first — VCS does NOT rebuild simv on RTL edits
# or +define+ changes, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/wavd2d_gpiorx_t3a_off/sim_build
#   make -C cocotb/wavd2d_gpiorx_t3a_off
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
MODULE  ?= test_t3a_off_bit_exact

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

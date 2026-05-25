# =============================================================================
# wav_d2d_gpio_tx — standalone cocotb unit sim for the WavD2DGpioTx training
#                   mux (line 43-45 of WavD2DGpioTx.v).
#
# Diagnostic, not assertive. Tests sample the io_pad output across the
# training_mode=1→0 transition, with and without FC data queued, to
# characterise the gap window that the slave RX sees when training drops.
#
# Run (always clean sim_build first — VCS does NOT rebuild simv on RTL edits):
#
#   cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
#   source /home/dam1n19/SoCLabs/tidelink/set_env.sh
#   rm -rf cocotb/wav_d2d_gpio_tx/sim_build
#   make -C cocotb/wav_d2d_gpio_tx
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

WLINK_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(WLINK_DIR)/WavD2DGpioTx.v \
                  $(WLINK_DIR)/WavClockGate.v \
                  $(WLINK_DIR)/WavClockInv.v \
                  $(WLINK_DIR)/WavClockMux.v \
                  $(WLINK_DIR)/WavResetSync.v \
                  $(WLINK_DIR)/WavAnd.v \
                  $(WLINK_DIR)/WavDemetSet.v \
                  $(WLINK_DIR)/wav_latch_model.sv

TOPLEVEL = tb_top
MODULE  ?= test_wav_tx_training_mux

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

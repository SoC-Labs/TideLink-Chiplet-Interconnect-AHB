# =============================================================================
# wav_d2d_gpio_tx_prbs — unit test for the LOCAL OVERRIDE WavD2DGpioTx with
#                       USE_PRBS_TRAINING=1 (feat/calibrator-prbs).
#
# Run:
#   cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter
#   source set_env.sh
#   rm -rf cocotb/wav_d2d_gpio_tx_prbs/sim_build
#   make -C cocotb/wav_d2d_gpio_tx_prbs
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

WLINK_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/src/rtl/local_overrides/WavD2DGpioTx.v \
                  $(WLINK_DIR)/WavClockGate.v \
                  $(WLINK_DIR)/WavClockInv.v \
                  $(WLINK_DIR)/WavClockMux.v \
                  $(WLINK_DIR)/WavResetSync.v \
                  $(WLINK_DIR)/WavAnd.v \
                  $(WLINK_DIR)/WavDemetSet.v \
                  $(WLINK_DIR)/wav_latch_model.sv

TOPLEVEL = tb_top
MODULE  ?= test_wav_tx_prbs_training

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

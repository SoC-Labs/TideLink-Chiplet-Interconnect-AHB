# PENDING-DECISION #1 — RX-FIFO TWIN 2 red/green gate.
#
#   make MODE=red     # ENABLE_AHB_WRITE=1 : reproduces the write_ptr corruption
#   make MODE=green   # ENABLE_AHB_WRITE=0 : corruption prevented, FC byte-exact
#
# Both modes run the SAME stimulus; expectations flip on MODE (exported to the
# test). SRAM is left X-init (+define+TIDELINK_SRAM_NO_ZERO_INIT) so the RED
# mis-framed FC read-back is visibly wrong rather than masked by a zeroed BRAM.
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

MODE ?= red
ifeq ($(MODE),green)
  TWIN2_DEF   = 0
  SIM_BUILD  ?= sim_build_green
else
  TWIN2_DEF   = 1
  SIM_BUILD  ?= sim_build_red
endif
export TWIN2_MODE = $(MODE)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_twin2

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +define+TWIN2_ENABLE_AHB_WRITE=$(TWIN2_DEF)
COMPILE_ARGS += +define+TIDELINK_SRAM_NO_ZERO_INIT
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist

include $(shell cocotb-config --makefiles)/Makefile.sim

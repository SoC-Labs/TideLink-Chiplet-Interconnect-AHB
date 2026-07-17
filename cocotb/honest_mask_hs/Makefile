# PENDING-DECISION #4 — HONEST_MASK_HS red/green gate.
#   make MODE=legacy  # HONEST_MASK_HS=0 : straps ignored, gate forced open (today)
#   make MODE=honest  # HONEST_MASK_HS=1 : straps honoured, handshake gates
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

MODE ?= legacy
ifeq ($(MODE),honest)
  HMH        = 1
  SIM_BUILD ?= sim_build_honest
else
  HMH        = 0
  SIM_BUILD ?= sim_build_legacy
endif
export HONEST_MODE = $(MODE)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_honest_mask_hs

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +define+HONEST_MASK_HS=$(HMH) +define+TIDELINK_PHY_V2 +define+TB_TOP_NO_DUMP
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_top_full_asic_v2.flist
COMPILE_ARGS += $(TIDELINK_HOME)/syn/asic/sim_stubs/rf_16k_stub.v

include $(shell cocotb-config --makefiles)/Makefile.sim

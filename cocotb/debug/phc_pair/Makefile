# =============================================================================
# phc_pair cocotb sim — two-Wlink + tidelink_ptp pair
#
# Reproduces the HW PHC slave-RX gap from
# docs/PHC_PHASE1_HW_REPORT.md (§"Build #9 retry").
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
# Project-local cmsdk_fpga_sram.v stub (Corstone-101 BP210 omission workaround).
export CMSDK_FPGA_SRAM_V ?= $(TIDELINK_HOME)/imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE  ?= test_phc_hw_sync_pair

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/tidelink_ptp.sv

# ---------------------------------------------------------------------------
# USE_FPGA_MODELS — when set to 1, enables USE_IDELAY=1 + USE_CLKBUF=1 on
# both axi_chiplet_controller instances (matches the pynq-z2-pair-all
# bitstream's structural config) and pulls in Vivado unisim primitive
# library + glbl.v so the IDELAYE2 / IDELAYCTRL / BUFG cells resolve.
#
# Goal: does inserting the FPGA-specific §9 RX cells make the sim
# reproduce the HW slave-RX symptom (HW_SYNC_STATUS=0x0 with PTP_CTRL=0x1)?
# See docs/SIM_HW_GAP_ANALYSIS.md.
#
#   make USE_FPGA_MODELS=1 MODULE=test_phc_hw_sync_pair
# ---------------------------------------------------------------------------
USE_FPGA_MODELS ?= 0
ifeq ($(USE_FPGA_MODELS),1)
  XILINX_VIVADO ?= /apps/Xilinx/Vivado/2024.1
  COMPILE_ARGS += +define+PHC_PAIR_USE_FPGA_MODELS
  COMPILE_ARGS += -y $(XILINX_VIVADO)/data/verilog/src/unisims +libext+.v
  COMPILE_ARGS += $(XILINX_VIVADO)/data/verilog/src/glbl.v
  # IDELAYCTRL and IDELAYE2 are referenced from the generate block under
  # USE_IDELAY=1; BUFG from USE_CLKBUF=1. The -y unisims search pulls them
  # in by module name. glbl is required for Xilinx primitive GSR/GTS nets:
  # VCS needs glbl elaborated as a top-level so the XMR `glbl.GSR` inside
  # IDELAYE2 / BUFG / IDELAYCTRL resolves.
  COMPILE_ARGS += -top glbl
endif
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

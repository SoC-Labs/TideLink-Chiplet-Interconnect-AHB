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
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/tidelink_ptp.sv
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

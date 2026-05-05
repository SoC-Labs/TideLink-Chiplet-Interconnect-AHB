# =============================================================================
# wlink_pair cocotb sim — two cross-wired axi_chiplet_controller instances
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE = test_link_bringup

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# =============================================================================
# wlink_pair_full cocotb sim — two tidelink_top instances
# (BD-wrapped chiplet with full APB → ctrl_reg conversion path)
#
# Agent #4 angle 1: includes the tidelink_apb_regs path between bench
# APB writes and the chiplet's ctrl_reg port. Used to expose any sim/HW
# divergence in that bridge layer.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
export CMSDK_FPGA_SRAM_V ?= /research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
# Default `make` runs the agent #4 BD-IP harness suite (3 tests). This is the
# slowest of the HW-mirror suites — full tidelink_top instances with the
# APB → ctrl_reg path through tidelink_apb_regs. It catches both bug class
# #1 (comb latch) and bug class #2 (collapsed case) at the chiplet-controller
# integration level, where the autoneg FSM has to traverse MASK_RD_ADDR.
MODULE ?= test_hw_full_mirror_via_apb

# Use the tidelink_top flist — it has tidelink_apb_regs, tidelink_fifo,
# axi_chiplet_controller, tidelink_autoneg, FC adapter, etc. Same set the
# UVM tidelink_top_system tb uses.
COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

SIM             = vcs
TOPLEVEL_LANG   = verilog

CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0/logical

VERILOG_SOURCES = \
    $(CMSDK_DIR)/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v \
    $(CMSDK_DIR)/models/memories/cmsdk_fpga_sram.v \
    $(PWD)/../../src/rtl/fpga/tidelink_sram.sv \
    $(PWD)/../../src/rtl/tidelink_fifo_ctrl.sv \
    $(PWD)/../../src/rtl/tidelink_fifo.sv \
    $(PWD)/../../src/rtl/tidelink_returner.sv \
    $(PWD)/../../src/rtl/tidelink_apb_regs.sv \
    $(PWD)/../../src/rtl/tidelink.sv \
    $(PWD)/tb_top.sv

TOPLEVEL = tb_top

# All test suites — cocotb loads each comma-separated module
MODULE = test_doorbell,test_token_flow,test_bug_regression,test_pair_token_counter

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

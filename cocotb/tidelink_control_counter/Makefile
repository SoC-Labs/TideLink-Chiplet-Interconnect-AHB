SIM             = vcs
TOPLEVEL_LANG   = verilog

VERILOG_SOURCES = \
    $(PWD)/../../src/rtl/tidelink_pkg.sv \
    $(PWD)/../../src/rtl/tidelink_control_counter.sv \
    $(PWD)/../../src/rtl/tidelink_sram_manager.sv \
    $(PWD)/../../src/tb/sram_model.sv \
    $(PWD)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_tidelink_control_counter

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

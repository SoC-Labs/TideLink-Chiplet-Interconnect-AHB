SIM             = vcs
TOPLEVEL_LANG   = verilog

VERILOG_SOURCES = \
    $(PWD)/../../src/rtl/tidelink_ahb_to_reg.sv \
    $(PWD)/tb_ahb_to_reg.sv

TOPLEVEL = tb_ahb_to_reg
MODULE   = test_tidelink_ahb_to_reg

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

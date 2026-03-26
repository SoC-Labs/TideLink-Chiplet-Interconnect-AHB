SIM ?= vcs
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = \
    $(PWD)/../../src/rtl/tidelink_pkg.sv \
    $(PWD)/../../src/rtl/tidelink_sram_manager.sv \
    $(PWD)/../../src/tb/sram_model.sv \
    $(PWD)/tb_top.sv

TOPLEVEL = tb_top
MODULE = test_tidelink_sram_manager

# VCS flags
COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps
SIM_ARGS += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

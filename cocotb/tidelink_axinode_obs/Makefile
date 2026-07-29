SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES  = $(TIDELINK_HOME)/src/rtl/tidelink_axinode_obs.sv
VERILOG_SOURCES += $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_axinode_obs

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

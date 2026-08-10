SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_deadi2c_beacon_dark

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# CURRENT SHIPPING autoneg RTL (the local override wired into the bare-link /
# eth-chiplet builds), NOT the stale deps/axi-chiplet-controller copy.
COMPILE_ARGS += $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_autoneg.sv
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

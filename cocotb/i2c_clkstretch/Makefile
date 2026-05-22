SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

I2C_RTL = $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/i2c/rtl

VERILOG_SOURCES  = $(CURDIR)/tb_top.sv
VERILOG_SOURCES += $(I2C_RTL)/i2c_master_axil.v
VERILOG_SOURCES += $(I2C_RTL)/i2c_master.v
VERILOG_SOURCES += $(I2C_RTL)/i2c_slave_axil_master.v
VERILOG_SOURCES += $(I2C_RTL)/i2c_slave.v
VERILOG_SOURCES += $(I2C_RTL)/axis_fifo.v

TOPLEVEL = tb_top
MODULE   = test_i2c_clkstretch

# SCL_STRETCH_PASS: 1 = fixed mux (default), 0 = old buggy mux (repro).
# Mirrors axi_chiplet_controller.sv I2C pin mux:
#   0 -> slave SCL forced 1'b1   (SHORTCOMINGS-14a bug: stretch discarded)
#   1 -> slave SCL = slv_scl_t   (the fix: slave open-drain SCL passed thru)
SCL_STRETCH_PASS ?= 1
export SCL_STRETCH_PASS

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd
SIM_ARGS     += +SCL_STRETCH_PASS=$(SCL_STRETCH_PASS)

include $(shell cocotb-config --makefiles)/Makefile.sim

# Negative control (must show the wedge) and positive control (must pass),
# in isolated build dirs so a single `make repro && make fix` proves both.
.PHONY: repro
repro:
	$(MAKE) SCL_STRETCH_PASS=0 SIM_BUILD=sim_build_repro

.PHONY: fix
fix:
	$(MAKE) SCL_STRETCH_PASS=1 SIM_BUILD=sim_build_fix

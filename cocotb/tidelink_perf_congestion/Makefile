SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# Reuse the standalone tb_top from the tidelink_perf env.
VERILOG_SOURCES = $(TIDELINK_HOME)/cocotb/tidelink_perf/tb_top.sv
VERILOG_SOURCES += $(TIDELINK_HOME)/src/rtl/tidelink_perf.sv

TOPLEVEL = tb_top
MODULE   = test_tidelink_perf_congestion

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

gui:
	$(MAKE) GUI=1

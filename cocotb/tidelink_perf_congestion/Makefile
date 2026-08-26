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

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

gui:
	$(MAKE) GUI=1

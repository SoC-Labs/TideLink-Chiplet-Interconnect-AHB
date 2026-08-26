# =============================================================================
# tidelink_deskew_bubble — UNIT testbench for tidelink_lane_deskew.
#
# Demonstrates the Bug A "bubble / duplicate-word" defect: under per-lane phase
# skew the deskew read side stalls (all_ready low) and HOLDS out_data, so the
# free-running framer (no flow control) re-consumes the held word as a duplicate.
#
# VERILOG_SOURCES is JUST the deskew module + this TB (no full flist).
# Modelled on cocotb/tidelink_top_pair_wordskew/Makefile.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

DESKEW_RTL = $(TIDELINK_HOME)/deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(DESKEW_RTL)

TOPLEVEL = tb_top
MODULE  ?= test_deskew_bubble

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

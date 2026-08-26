# =============================================================================
# tidelink_link_clk_div — unit gate for the D2D link-clock divider
#
# Unit-level, NOT an integration bench: the DUT is the divider module alone,
# with no tidelink_top, no PHY and no link partner. That is deliberate. The
# properties this module has to hold are MECHANISM properties (duty cycle, no
# runt pulse on handover, X-safe fallback to bypass), and an end-to-end pair
# test can pass while every one of them is violated. This project has been
# burned before by gates that only check outcomes.
#
# What is covered here:
#   * /1 is the reset configuration and is bit-transparent to clk_in
#   * /2 /4 /8 /16 each produce the right period
#   * every divided ratio is 50% duty (the property the forwarded pad clock
#     needs — see safety property 2 in the RTL header)
#   * NO RUNT PULSE on any live ratio change, in either direction
#   * an X / undriven ratio_i leaves the module in /1 bypass  <-- load-bearing:
#     this is what lets the ~20 existing tb_top.sv files stay untouched
#   * out-of-range ratio codes clamp to /16 rather than decoding undefined
#   * scan_mode forces bypass
#
# The eye-margin claim (a divided link tolerates more skew) is NOT made here.
# That belongs to cocotb/tidelink_top_pair_skewed, and even there it is a
# digital go/no-go signal — not a substitute for a bench eye/BER measurement.
#
# ~5 s wall. Style modeled on cocotb/tidelink_v2_smoke.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(TIDELINK_HOME)/src/rtl/tidelink_link_clk_div.sv

TOPLEVEL = tidelink_link_clk_div
MODULE  ?= test_tidelink_link_clk_div

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# No flist here (single self-contained source), so the flist-staleness guard
# used by the integration benches is not needed — but the same trap applies:
# VERILOG_SOURCES is the only dep make can see, and it IS the RTL, so an edit
# does force a rebuild.

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

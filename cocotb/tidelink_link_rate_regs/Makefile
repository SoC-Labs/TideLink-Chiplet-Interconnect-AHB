# =============================================================================
# tidelink_link_rate_regs — unit gate for the D2D link-rate register bank
#
# THIS BENCH EXISTS BECAUSE A FIX WAS UNGUARDED. The bank originally reset its
# rate-determining state on hresetn while tidelink_link_clk_div resets on
# poresetn. A warm (fabric) reset therefore RETIMED A LIVE LINK — measured
# 20 ns -> 5 ns, a 4x rate INCREASE with poresetn high throughout — and then
# bricked the knob, because role_locked was by then 1 and every repair write was
# refused. The fix moved that state into the POR domain.
#
# An independent reviewer then reverted the entire fix in a shadow copy and
# found that NOTHING IN THE REPO CAUGHT IT. That is what this gate closes. The
# property under test is not "the bank works", it is specifically:
#
#     a warm reset must not change the rate the divider is using.
#
# Unit-level and bank-only on purpose: the property is observable at ratio_o and
# src_sticky_o, so it needs no PHY, no link partner and no divider instance, and
# runs in seconds rather than minutes. That matters — a gate too slow to run is
# a gate that gets switched off.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(TIDELINK_HOME)/src/rtl/tidelink_link_rate_regs.sv

TOPLEVEL = tidelink_link_rate_regs
MODULE  ?= test_link_rate_regs_reset

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

include $(shell cocotb-config --makefiles)/Makefile.sim

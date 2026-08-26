# =============================================================================
# tidelink_force_recal — unit env for the P1 FORCED-RECAL W1P
# (SWI_FORCE_RECAL, R8 slot0 bit[6]; 2026-07-19, lane B1).
#
# Gates the fix for docs/LINK_RECOVERY_MECHANISM.md §4 ("there is no
# firmware-reachable PHY retrain in this design at all"). See the docstring in
# test_force_recal.py for what each test proves.
#
# WHICH CALIBRATOR?
#   RTL=v2 (default) — src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv
#                      the copy built by flists/tidelink_fpga_v2.flist AND
#                      flists/tidelink_top_full_asic_v2.flist (FPGA + TAPEOUT).
#   RTL=v1           — src/rtl/tidelink_phy_align_calibrator.sv, the copy built
#                      by flists/tidelink_fpga.flist AND
#                      flists/tidelink_top_full_asic.flist.
# Both carry the same calibrated_once_q sticky and both received the same fix,
# so both are gated.
#
# Usage:
#   source ./set_env.sh
#   make -C cocotb/tidelink_force_recal            # V2 (default)
#   make -C cocotb/tidelink_force_recal RTL=v1     # V1
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

RTL ?= v2
ifeq ($(RTL),v1)
  CAL_RTL  = $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv
  TB_SRC   = $(CURDIR)/tb_force_recal_v1.sv
  TOPLEVEL = tb_force_recal_v1
else
  CAL_RTL  = $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv
  TB_SRC   = $(CURDIR)/tb_force_recal_v2.sv
  TOPLEVEL = tb_force_recal_v2
endif

VERILOG_SOURCES = $(TB_SRC) $(CAL_RTL)
MODULE         ?= test_force_recal

# Private SIM_BUILD per RTL flavour so a v1 run never reuses a v2 build.
SIM_BUILD ?= sim_build_$(RTL)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

# -----------------------------------------------------------------------------
# FULL-STACK proof (test_force_recal_pair.py): drives the REAL APB write to
# R8 slot0 bit[6] on the paired-die TB and checks the link still passes data
# byte-exact both ways after the forced retrain.
#
# Hosted here but RUN against cocotb/tidelink_top_pair_v2 — that directory is
# NOT modified; this module is injected via PYTHONPATH. Uses a private
# SIM_BUILD because other lanes share that bench's default build dirs.
# -----------------------------------------------------------------------------
.PHONY: pair
pair:
	cd $(TIDELINK_HOME)/cocotb/tidelink_top_pair_v2 && \
	  PYTHONPATH=$(CURDIR):$$PYTHONPATH \
	  EPOCH_PROFILE=zero TB_TOP_NO_DUMP=1 \
	  SIM_BUILD=sim_build_b1_forcerecal \
	  $(MAKE) MODULE=test_force_recal_pair

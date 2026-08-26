# =============================================================================
# tidelink_error_injection — F14 error-injection / recovery matrix (V2 pair).
#
# Two cross-wired V2 (TIDELINK_PHY_V2) tidelink_top instances, EPOCH_PROFILE=zero
# (no skew — the clean-link baseline), with the F14 err_inject module on BOTH
# pad directions (stuck-0/1/X, bit-flip, link-clock kill) and the harness's
# per-die POR gate (m_por_gate/s_por_gate) for mid-burst die reset. Every
# fault is injected from the cocotb test (deposit on the injector's undriven
# control regs / the por_gate regs) — no shared RTL is touched.
#
#   make MODULE=test_ei_link_glitch      # S1 mid-burst link glitch
#   make MODULE=test_ei_die_reset        # S2 mid-burst die reset
#   make MODULE=test_ei_lane_dropout     # S3 single-lane 0/1/X/flip
#   make MODULE=test_ei_credit_probe     # S4 credit-counter reachability
#   make MODULE=test_ei_sync_collision   # S5 SYNC-word collision
#   make MODULE=test_ei_reset_storm      # S6 back-to-back reset storm
#   make MODULE=test_ei_lane7_repro      # S3b CRITICAL evidence (drained, x4,
#                                        #     + CRC-flag probe + lane-6 control)
#   make ei_matrix                       # all of the above, in order
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# My own bench SV (tb_top is a local copy of the v2 pair harness with the F14
# err_inject module spliced onto both pad directions; pad_skid is a verbatim
# copy; err_inject is new and mine).
VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_ei_link_glitch

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# V2 RTL flist (deps/tidelink-phy serdes + always-on calibrator + epoch deskew).
V2_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(V2_FLIST)

# Zero skew, SW bring-up (bit-identical defaults to the v2 pair's zero profile).
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1

# Wave dump OFF by default (full bring-up VCDs exceed 4 GB). Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD := sim_build_ei

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(V2_FLIST) $(call flist_srcs,$(V2_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: ei_matrix
ei_matrix:
	$(MAKE) MODULE=test_ei_link_glitch
	$(MAKE) MODULE=test_ei_die_reset
	$(MAKE) MODULE=test_ei_lane_dropout
	$(MAKE) MODULE=test_ei_credit_probe
	$(MAKE) MODULE=test_ei_sync_collision
	$(MAKE) MODULE=test_ei_reset_storm
	$(MAKE) MODULE=test_ei_lane7_repro

# ---------------------------------------------------------------------------
# S3c — the full 8-lane x 3-mode x 2-direction corruption sweep (F14-A scope).
#
# Each (direction, mode, lane) cell is its OWN cocotb test because the harness
# can only bring the link up ONCE per simulation (a second run_bringup_full
# comes back cal=IDLE / fcsm=0). Cells are therefore run as separate simv
# invocations, which is slower but is the only way a degraded cell cannot
# contaminate the next one.
#
#   make ei_sweep                 # all 48 cells, one simv run each
#   make MODULE=test_ei_full_sweep TESTCASE=test_s2m_flip_lane7    # one cell
# ---------------------------------------------------------------------------
SWEEP_DIRS  ?= s2m m2s
SWEEP_MODES ?= flip stuck1 stuck0
SWEEP_LANES ?= 0 1 2 3 4 5 6 7

.PHONY: ei_sweep
ei_sweep:
	@for d in $(SWEEP_DIRS); do for m in $(SWEEP_MODES); do for l in $(SWEEP_LANES); do \
	  echo "=== CELL $$d/$$m/lane$$l ==="; \
	  $(MAKE) --no-print-directory MODULE=test_ei_full_sweep \
	          TESTCASE=test_$${d}_$${m}_lane$${l} || true; \
	done; done; done

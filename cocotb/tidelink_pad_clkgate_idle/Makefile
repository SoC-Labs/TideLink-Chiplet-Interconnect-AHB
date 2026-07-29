# =============================================================================
# tidelink_pad_clkgate_idle — GUARD for the V2 pad clock-gate SYNC regression.
#
# Owed work item docs/HANDOVER_SYNC_CLOCK_GATE_2026_07_29.md §7.1: the coverage
# hole that let the regression ship. The V2 fork dropped the `| sync_insert`
# term from the eight pad clock-gate enables (gpiotx_N_io_clk_en) in
# src/rtl/local_overrides/WavD2DGpio_v2.v. On an IDLE link in DATA mode
# (training=0, tx_en=0) the master inserts an idle-gated SYNC beacon: the
# logical tx_sync_ins_cnt climbs, but the pad serialiser is UNCLOCKED, so
# pad_clk_tx (the forwarded clock = the peer's pad_clk_rx) stays gated off, the
# beacon never reaches the wire, and the peer's SYNC-detect never rises.
#
# The blind suites v2_syncdet / v2_data / v2_sustained PASS with AND without the
# fix — they never drive the idle-link case. This bench does exactly that and
# asserts the two §7.1 conditions: pad_clk_tx keeps toggling AND the peer's
# SYNC-detect count rises.
#
# EXPECTED-FAIL on `main` (the fix is not merged). It flips to PASS once
# `| tx_sync_inserting_w` is restored (fix/v2-sync-clock-gate @ c8d0e5f). It is
# therefore wired into the root Makefile as a SENTINEL (sim_gate_pad_clkgate_idle),
# NOT into the blocking aggregate — it PROMOTES to a blocking PASS when the fix
# lands on main.
#
# This bench OWNS no RTL/tb: it reuses the paired-V2 harness verbatim from
# ../tidelink_top_pair_v2 (tb_top.sv + pad_skid.sv + eye_fault.sv +
# pair_v2_common.py on PYTHONPATH) and compiles flists/tidelink_fpga_v2.flist.
#
#   source ./set_env.sh; export PATH=$VCS_HOME/bin:$PATH TIDELINK_PHY_V2=1
#   make -C cocotb/tidelink_pad_clkgate_idle          # runs the guard test
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Reuse the paired-V2 tb verbatim (do NOT fork it).
PAIR_V2_DIR := $(TIDELINK_HOME)/cocotb/tidelink_top_pair_v2
VERILOG_SOURCES = $(PAIR_V2_DIR)/tb_top.sv $(PAIR_V2_DIR)/pad_skid.sv $(PAIR_V2_DIR)/eye_fault.sv

TOPLEVEL = tb_top
MODULE  ?= test_pad_clkgate_idle

# pair_v2_common.py (harness helpers) + the tidelink python package (packet enc).
export PYTHONPATH := $(CURDIR):$(PAIR_V2_DIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# V2 (TIDELINK_PHY_V2) flist — the define rides in the per-file v2shims.
V2_FLIST  := $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(V2_FLIST)

# Zero bit-skew, zero epoch skew (clean pair). SW bring-up (BYPASS_AUTONEG=1 =
# autoneg parks in ST_BYPASS; role-lock via APB W1S — the run_bringup_full path).
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
COMPILE_ARGS += +define+TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS=0

# Wave dump OFF by default (bring-up VCDs are huge). Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD ?= sim_build

# Build-staleness guard: the DUT RTL arrives via `-f $(V2_FLIST)` (invisible to
# make), so without this an RTL-only edit (e.g. the WavD2DGpio_v2.v clock-gate
# fix) re-runs the STALE simv. Depend on the flist file + every bare source it
# lists. (Still `rm -rf sim_build*` after any RTL edit — belt and braces.)
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(V2_FLIST) $(call flist_srcs,$(V2_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

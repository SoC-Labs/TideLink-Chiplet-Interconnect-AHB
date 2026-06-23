# =============================================================================
# tidelink_lane_deskew cocotb UNIT TEST
#   Standalone test of src/rtl/local_overrides/tidelink_lane_deskew.sv — the
#   8-lane cross-lane deskew FIFO. The module is self-contained (`default_nettype
#   none`, no external deps), so we compile JUST that one file. Same simulator
#   (VCS) + flags style as cocotb/tidelink_top_pair.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# 2026-06-17: target the V2 deskew (deps/tidelink-phy) — the file the V2 stack
# (pair_v2 sim + FPGA/ASIC builds) actually compiles, and the one carrying the
# REDUCED-LANE lane_mask fix. It needs the SYNC/training-pattern $unit includes
# and tidelink_popcount16 (used by the EPOCH_ANCHOR_EN=1 matcher). The +incdir
# resolves the `include "tidelink_sync_word.svh" / "..._training_patterns.svh".
PHY_RTL = $(TIDELINK_HOME)/deps/tidelink-phy/rtl
VERILOG_SOURCES = $(PHY_RTL)/tidelink_popcount16.sv \
                  $(PHY_RTL)/tidelink_lane_deskew.sv \
                  $(CURDIR)/tb_deskew.sv

TOPLEVEL = tb_deskew
MODULE  ?= test_lane_deskew_mask

# Exercise the mask-aware EPOCH anchor too (the V2 default in the real build).
TB_EPOCH_ANCHOR_EN ?= 1
COMPILE_ARGS += -pvalue+tb_deskew/EPOCH_ANCHOR_EN=$(TB_EPOCH_ANCHOR_EN)

# Self-gating periodic-confirm depth (sticky-poison PRIMARY fix). Default 2 =
# the DUT default (one periodic re-confirm). The K=1 NEGATIVE-CONTROL run sets
# SYNC_CONFIRM=1 to prove the degenerate first-arrival latch still breaks under
# poison. Forwarded BOTH as the DUT elab param AND as a Python env var so the
# poison tests assert the right direction (COHERE for K>=2, BREAK for K=1).
SYNC_CONFIRM ?= 2
COMPILE_ARGS += -pvalue+tb_deskew/SYNC_CONFIRM=$(SYNC_CONFIRM)
export SYNC_CONFIRM

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +incdir+$(PHY_RTL)

# Wave dump (gated; off by default — keeps the run light).
TB_NO_DUMP ?= 1
ifneq ($(TB_NO_DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

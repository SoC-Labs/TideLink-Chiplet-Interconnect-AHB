# RX-FIFO TWIN 2 — chip-killer fix gate (DECISION #1, David 2026-07-19).
#
#   make                     # ENABLE_AHB_WRITE=1 (SUPPORTED posture, the default)
#   make TWIN2_ENABLE_AHB_WRITE=0   # optional FC-write-only knob
#
# AHB-CPU-write-to-RX IS a supported path, so the default build leaves it
# ENABLED and the test asserts BOTH halves: the stray clear/probe pair is a
# no-op AND a legitimate AHB-injected packet still commits byte-exact.
#
# RED/GREEN is taken across the RTL, not across this parameter: run
# ./run_redgreen.sh, which runs this same test against the pre-fix
# tidelink_fifo_ctrl.sv (fails) and the fixed one (passes).
#
# SRAM is left X-init (+define+TIDELINK_SRAM_NO_ZERO_INIT) so a mis-framed
# read-back is visibly wrong rather than masked by a zeroed BRAM.
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Supported posture by default: the AHB CPU-write-into-RX path is FUNCTIONAL.
TWIN2_DEF  ?= 1
SIM_BUILD  ?= sim_build

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_twin2

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += +define+TWIN2_ENABLE_AHB_WRITE=$(TWIN2_DEF)
COMPILE_ARGS += +define+TIDELINK_SRAM_NO_ZERO_INIT
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

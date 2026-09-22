# Diagnostic bench — link-survey campaign, 2026-08-01.
# Isolates the RX-FIFO shared-metadata race between the FC direct-write
# (inbound packet arrival) path and the AHB read (local drain) path, both of
# which land on the same tidelink_fifo_ctrl packet_active_r/
# packet_word_length_r/*_target_addr_r registers in production. See
# test_concurrent_race.py for the mechanism and cycle-accurate trace.
#
# Modeled on cocotb/tidelink_fifo/Makefile (same DUT, same flist) — this is a
# read-only diagnostic bench, no RTL changes, new files only.
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
# Site configuration: per-machine tool + IP roots, with NO default path.
# mk/site.mk reads site.env and names anything missing. site.env.example
# says what each variable locates.
SITE_VARS_REQUIRED += CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_concurrent_race

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# --- Build-staleness guard: recompile on flist-sourced RTL edits. ---
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink_fifo.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

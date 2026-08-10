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
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_concurrent_race

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage ───────────────────────────────────────────────────────
ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

# --- Build-staleness guard: recompile on flist-sourced RTL edits. ---
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink_fifo.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

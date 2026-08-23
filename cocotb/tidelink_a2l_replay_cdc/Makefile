SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# ── NODE selection ──────────────────────────────────────────────────────
# NODE=13 (default): the TideLink sideband a2l node (48/5/depth-16).
# NODE=5           : the B (write-response 0x82) data-plane a2l node
#                    (14/4/depth-8) — TL-027 reproduce-first (lap-ahead ACK = 9).
# NODE=7  : the AR (read-address 0x83) node (101/4/depth-8) — TL-043-ARR.
# NODE=9  : the R  (read-data    0x84) node (47/6/depth-32) — TL-043-ARR.
#           Neither has a local_overrides copy, so the DUT selection below
#           resolves them to the RAW deps source. That is the point: these two
#           are what SHIPS, and they are expected to FAIL the self-heal test
#           until an override is written.
NODE ?= 13
ifeq ($(NODE),7)
  TB_FILE   := tb_top_7.sv
  NODE_MOD  := WlinkGenericFCReplayV2_7
  A2L_FLIST := tidelink_a2l_replay_cdc_7.flist
  DUT_SRC_F := $(CURDIR)/dut_src_7.f
  MODULE   ?= test_a2l_replay_cdc_7
else ifeq ($(NODE),9)
  TB_FILE   := tb_top_9.sv
  NODE_MOD  := WlinkGenericFCReplayV2_9
  A2L_FLIST := tidelink_a2l_replay_cdc_9.flist
  DUT_SRC_F := $(CURDIR)/dut_src_9.f
  MODULE   ?= test_a2l_replay_cdc_9
else ifeq ($(NODE),5)
  TB_FILE   := tb_top_5.sv
  NODE_MOD  := WlinkGenericFCReplayV2_5
  A2L_FLIST := tidelink_a2l_replay_cdc_5.flist
  DUT_SRC_F := $(CURDIR)/dut_src_5.f
  MODULE   ?= test_a2l_replay_cdc_5
else ifeq ($(NODE),3)
  TB_FILE   := tb_top_3.sv
  NODE_MOD  := WlinkGenericFCReplayV2_3
  A2L_FLIST := tidelink_a2l_replay_cdc_3.flist
  DUT_SRC_F := $(CURDIR)/dut_src_3.f
  MODULE   ?= test_a2l_replay_cdc_3
else ifeq ($(NODE),1)
  TB_FILE   := tb_top_1.sv
  NODE_MOD  := WlinkGenericFCReplayV2_1
  A2L_FLIST := tidelink_a2l_replay_cdc_1.flist
  DUT_SRC_F := $(CURDIR)/dut_src_1.f
  MODULE   ?= test_a2l_replay_cdc_1
else
  TB_FILE   := tb_top.sv
  NODE_MOD  := WlinkGenericFCReplayV2_13
  A2L_FLIST := tidelink_a2l_replay_cdc.flist
  DUT_SRC_F := $(CURDIR)/dut_src.f
  MODULE   ?= test_a2l_replay_cdc
endif

VERILOG_SOURCES = $(CURDIR)/$(TB_FILE)

TOPLEVEL = tb_top

# ── DUT source selection ────────────────────────────────────────────────
# Default: use the local-override DUT if it exists (so the in-tree CDC fix is
# what gets simulated), else fall back to the deps (pre-fix) source.
# Force the pristine pre-fix deps source with: make USE_DEPS_DUT=1
#
# TL-032 reproduce-first "before" baseline: make USE_PREFIX_DUT=1 selects the
# TL-027 override WITHOUT the revert-aware a2l_link_addr rewind (captured from the
# override's git HEAD as tl027only_<NODE_MOD>.v). This is the correct A/B for the
# revert-wedge residual R1 — the pristine deps has NO ACK-window guard at all, so
# the guard-lockout residual can only be shown against the TL-027-guarded baseline:
#   USE_PREFIX_DUT=1 (TL-027 guard, NOT revert-aware) -> revert test FAILS.
#   default (local override, revert-aware TL-032)     -> revert test PASSES.
LOCAL_DUT  := $(TIDELINK_HOME)/src/rtl/local_overrides/$(NODE_MOD).v
DEPS_DUT   := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/$(NODE_MOD).v
PREFIX_DUT := $(CURDIR)/tl027only_$(NODE_MOD).v

ifeq ($(USE_DEPS_DUT),1)
  DUT_SRC := $(DEPS_DUT)
else ifeq ($(USE_PREFIX_DUT),1)
  DUT_SRC := $(PREFIX_DUT)
else
  DUT_SRC := $(if $(wildcard $(LOCAL_DUT)),$(LOCAL_DUT),$(DEPS_DUT))
endif

# Regenerate the tiny DUT-source include file every invocation.
$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/$(A2L_FLIST)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage ───────────────────────────────────────────────────────
ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/$(A2L_FLIST)
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

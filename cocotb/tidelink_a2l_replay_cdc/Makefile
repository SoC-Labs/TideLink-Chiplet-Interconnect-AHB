SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# ── NODE selection ──────────────────────────────────────────────────────
# NODE=13 (default): the TideLink sideband a2l node (48/5/depth-16).
# NODE=5           : the B (write-response 0x82) data-plane a2l node
#                    (14/4/depth-8) — TL-027 reproduce-first (lap-ahead ACK = 9).
NODE ?= 13
ifeq ($(NODE),5)
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
LOCAL_DUT  := $(TIDELINK_HOME)/src/rtl/local_overrides/$(NODE_MOD).v
DEPS_DUT   := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/$(NODE_MOD).v

ifeq ($(USE_DEPS_DUT),1)
  DUT_SRC := $(DEPS_DUT)
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

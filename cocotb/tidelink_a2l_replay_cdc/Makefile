SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# Site configuration: per-machine tool roots, with NO default path.
# Provides $(SITE_REQUIRE); see mk/site.mk and site.env.example.
include $(TIDELINK_HOME)/mk/site.mk

# ── NODE selection ──────────────────────────────────────────────────────
# NODE=13 (default): the TideLink sideband a2l node (48/5/depth-16).
# NODE=5           : the B (write-response 0x82) data-plane a2l node
#                    (14/4/depth-8) — TL-027 reproduce-first (lap-ahead ACK = 9).
# NODE=7  : the AR (read-address 0x83) node (101/4/depth-8) — TL-043-ARR.
# NODE=9  : the R  (read-data    0x84) node (47/6/depth-32) — TL-043-ARR.
#           STALE COMMENT CORRECTED 2026-09-11: this used to say neither node
#           has a local_overrides copy and both are expected to FAIL. e88ff7be
#           added src/rtl/local_overrides/WlinkGenericFCReplayV2_{7,9}.v, the DUT
#           selection below therefore resolves both to the OVERRIDE, and
#           sim_gate_a2l_replay_cdc_7 / _9 are blocking, passing suites.
#           What is still true, and is a different thing: the TAPEOUT flist
#           (flists/tidelink_top_full_asic_v2.flist) still sources _7/_9 from
#           deps/. Re-pointing it is an open ASIC-recovery decision.
NODE ?= 13
ifeq ($(NODE),7)
  TB_FILE   := tb_top_7.sv
  NODE_MOD  := WlinkGenericFCReplayV2_7
  A2L_FLIST := tidelink_a2l_replay_cdc_7.flist
  DUT_SRC_TAG := _7
  MODULE   ?= test_a2l_replay_cdc_7
else ifeq ($(NODE),9)
  TB_FILE   := tb_top_9.sv
  NODE_MOD  := WlinkGenericFCReplayV2_9
  A2L_FLIST := tidelink_a2l_replay_cdc_9.flist
  DUT_SRC_TAG := _9
  MODULE   ?= test_a2l_replay_cdc_9
else ifeq ($(NODE),5)
  TB_FILE   := tb_top_5.sv
  NODE_MOD  := WlinkGenericFCReplayV2_5
  A2L_FLIST := tidelink_a2l_replay_cdc_5.flist
  DUT_SRC_TAG := _5
  MODULE   ?= test_a2l_replay_cdc_5
else ifeq ($(NODE),3)
  TB_FILE   := tb_top_3.sv
  NODE_MOD  := WlinkGenericFCReplayV2_3
  A2L_FLIST := tidelink_a2l_replay_cdc_3.flist
  DUT_SRC_TAG := _3
  MODULE   ?= test_a2l_replay_cdc_3
else ifeq ($(NODE),1)
  TB_FILE   := tb_top_1.sv
  NODE_MOD  := WlinkGenericFCReplayV2_1
  A2L_FLIST := tidelink_a2l_replay_cdc_1.flist
  DUT_SRC_TAG := _1
  MODULE   ?= test_a2l_replay_cdc_1
else
  TB_FILE   := tb_top.sv
  NODE_MOD  := WlinkGenericFCReplayV2_13
  A2L_FLIST := tidelink_a2l_replay_cdc.flist
  DUT_SRC_TAG :=
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
# Spelled RELATIVE to TIDELINK_HOME: the generated .f below must carry a
# ${TIDELINK_HOME}-rooted path, not this worktree's absolute path, or the file
# becomes worktree-specific (see the generation note below).
LOCAL_DUT_REL  := src/rtl/local_overrides/$(NODE_MOD).v
DEPS_DUT_REL   := deps/axi-chiplet-controller/logical/wlink/$(NODE_MOD).v
PREFIX_DUT_REL := cocotb/tidelink_a2l_replay_cdc/tl027only_$(NODE_MOD).v

LOCAL_DUT  := $(TIDELINK_HOME)/$(LOCAL_DUT_REL)
DEPS_DUT   := $(TIDELINK_HOME)/$(DEPS_DUT_REL)
PREFIX_DUT := $(TIDELINK_HOME)/$(PREFIX_DUT_REL)

ifeq ($(USE_DEPS_DUT),1)
  DUT_SRC     := $(DEPS_DUT)
  DUT_SRC_REL := $(DEPS_DUT_REL)
else ifeq ($(USE_PREFIX_DUT),1)
  DUT_SRC     := $(PREFIX_DUT)
  DUT_SRC_REL := $(PREFIX_DUT_REL)
else
  DUT_SRC     := $(if $(wildcard $(LOCAL_DUT)),$(LOCAL_DUT),$(DEPS_DUT))
  DUT_SRC_REL := $(if $(wildcard $(LOCAL_DUT)),$(LOCAL_DUT_REL),$(DEPS_DUT_REL))
endif

# ── Generated DUT-source include file — NEVER inside the tracked tree ────────
# HISTORY (fixed 2026-09-11). This used to be $(CURDIR)/dut_src$(DUT_SRC_TAG).f,
# and those four files were TRACKED. The $(shell ...) below runs at Makefile
# PARSE time, so ANY invocation of this bench -- `make`, `make clean`, even
# `make -n` -- rewrote four tracked files with this worktree's ABSOLUTE path.
# `make sim_gate` therefore dirtied its own tree mid-run: GATE_STAMP (root
# Makefile) flipped from <sha>-clean to <sha>-dirty partway through, and
# sim_gate_summary then refused to report PASS because the early suites'
# .status stamps no longer matched the late ones. Measured 2026-09-09 on
# cba9774d: a genuine 68 PASS / 3 FAIL / 3 XFAIL run produced 38 clean + 36
# dirty stamps and exited 2 with "STALE / CROSS-BRANCH -- refusing to report
# PASS". The standing workaround was `git update-index --assume-unchanged`,
# which is per-clone and so recurred in every fresh worktree.
#
# TWO changes make the write harmless:
#   1. it lands under imp/ (gitignored build scratch), not in the tracked tree;
#   2. the content is ${TIDELINK_HOME}-rooted and is only rewritten when it
#      would actually CHANGE, so the file's mtime does not churn either.
# Keep BOTH. Moving it back into the bench directory re-arms the self-dirtying
# gate even if the file is gitignored, because a churning mtime still defeats
# content-addressed staleness checks. Control: scripts/ci/tests/test_gate_selfclean.py
DUT_SRC_GEN_DIR := $(TIDELINK_HOME)/imp/gen/a2l_replay_cdc
DUT_SRC_F       := $(DUT_SRC_GEN_DIR)/dut_src$(DUT_SRC_TAG).f
$(shell mkdir -p $(DUT_SRC_GEN_DIR); \
	_new='$${TIDELINK_HOME}/$(DUT_SRC_REL)'; \
	[ "$$(cat $(DUT_SRC_F) 2>/dev/null)" = "$$_new" ] || \
	  printf '%s\n' "$$_new" > $(DUT_SRC_F))

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/$(A2L_FLIST)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/$(A2L_FLIST)
# $(DUT_SRC) is added EXPLICITLY: flist_srcs drops `-f` lines, and the DUT now
# arrives only via the generated dut_src.f `-f` include, so without this an
# edit to the local-override DUT would re-run the STALE simv.
_flist_deps := $(_TL_FLIST) $(DUT_SRC) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: gui
gui: $(SIM_BUILD)/simv
	@$(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

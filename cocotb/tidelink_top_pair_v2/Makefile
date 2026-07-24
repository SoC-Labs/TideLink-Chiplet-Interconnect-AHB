# =============================================================================
# tidelink_top_pair_v2 cocotb sim — two cross-wired V2 (TIDELINK_PHY_V2)
# tidelink_top instances with per-lane WHOLE-WORD EPOCH skew injection.
#
# The integrated pre-silicon gate for the v37 defect class (see
# docs/V37_FINAL_DIAGNOSIS_2026_06_12.md): cross-lane word-EPOCH incoherence
# on a skewed RX. Compiles flists/tidelink_fpga_v2.flist (deps/tidelink-phy
# serdes + always-on calibrator + epoch-anchored deskew, submodule c332722).
# The define rides in the v2shims listed by the flist — never co-compile with
# the V1 flist.
#
# Profiles (compile-time — pad_skid depths are parameters):
#   make EPOCH_PROFILE=zero        # default: zero skew. First-ever V2 pair
#                                  # bring-up coverage (bilateral link-up +
#                                  # M->S / S->M packet delivery).
#   make EPOCH_PROFILE=staircase   # lanes at 0..7 whole words, BOTH
#                                  # directions (component-test profile).
#   make EPOCH_PROFILE=silicon     # v37 silicon fingerprint: 3..7 words on
#                                  # the MASTER's RX only (S->M path — z2_02
#                                  # was the skewed side), zero M->S.
#
# Negative control (step 3 of the gate — proves the suite detects the
# defect):
#   make EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl
# forces WlinkGPIOPHY.EPOCH_ANCHOR_EN=0 on both dies (occupancy-only deskew,
# the pre-fix V2 baseline). test_v2_pair_data under that compile FAILS with
# the v37 signature; test_v2_pair_epoch_negctl asserts the signature itself
# (training green + CR undecodable on the skewed RX) so the make run PASSES
# when the defect is correctly detected.
#
# Convenience aggregate (used by the root Makefile sim gate):
#   make v2_gate     # zero -> staircase -> silicon -> negctl, fresh build each
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/eye_fault.sv

TOPLEVEL = tb_top
MODULE  ?= test_v2_pair_data

# tidelink python package (packet encoding helpers)
export PYTHONPATH := $(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# ── Pre-fix fc_adapter swap (sim-only, wip/txoveradvance-simrepro) ──────────
# PREFIX_FC=1 compiles the fc_adapter from BEFORE the tx_xfer_lock fix
# (git 963d19d^, staged verbatim at prefix_fc_adapter.sv) so the SILICON x5 a2l
# TX over-advance reproduces end-to-end. It swaps ONLY the one fc_adapter line
# of tidelink_fpga_v2.flist into a generated flist; no tracked RTL is touched.
# Default (PREFIX_FC=0) uses the in-tree fixed fc_adapter (clamps to 1:1).
#   make EPOCH_PROFILE=zero MODULE=test_v2_multipkt_pktnum PREFIX_FC=1
V2_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
PREFIX_FC ?= 0
ifeq ($(PREFIX_FC),1)
GEN_V2_FLIST := $(CURDIR)/tidelink_fpga_v2_prefixfc.flist
$(shell sed 's#^.*tidelink_fc_adapter\.sv$$#$(CURDIR)/prefix_fc_adapter.sv#' $(V2_FLIST) > $(GEN_V2_FLIST))
V2_FLIST := $(GEN_V2_FLIST)
endif
COMPILE_ARGS += -f $(V2_FLIST)

# Legacy uniform bit-skid (kept for parity with the V1 pair env).
SKID_BITS ?= 0
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)

# ── HONEST_STRAPS (2026-07-24) — production-silicon gate posture ─────────────
# 0 (default) : legacy tb — m/s_apb_debug_unlock = m/s_mask_hs_bypass = 1'b1 AND
#               tidelink_top DEBUG_UNLOCK_DEFAULT=1, so mask_hs_gate_open is
#               FORCE-OPEN on both dies (axi_chiplet_controller.sv:687) and any
#               autonomy claim from this env is vacuous.
# 1           : both straps 0 AND DEBUG_UNLOCK_DEFAULT=0, so the ONLY opener is
#               a genuine mask_hs_match. This is the posture that actually tests
#               the peer-mask handshake.
#   make EPOCH_PROFILE=zero BYPASS_AUTONEG=0 HONEST_STRAPS=1 MODULE=...
HONEST_STRAPS ?= 0
ifeq ($(HONEST_STRAPS),1)
COMPILE_ARGS += +define+TB_TOP_HONEST_STRAPS
endif

# ── Autonomy engagement (parity with cocotb/tidelink_top_pair/Makefile) ──────
# BYPASS_AUTONEG (Phase 0c autonomy plan)
#   1 = legacy: the autoneg FSM parks in ST_BYPASS at POR; role-lock is
#       SW/APB-driven. Default for the SW-bring-up tests (incl. the
#       test_v2_pair_data 3/3 gate) — bit-identical to before this line existed.
#   0 = autonomy: tb_top forces nego_cfg_reg + nego_train_cfg_r at time 0 so the
#       FSM walks ST_NEGO_INIT -> ST_TRAIN_DONE with NO SW writes. Required by
#       test_v2_autonomous_fc_handoff / _sync_detect.
# WHY THIS BLOCK EXISTS (the real "HARNESS GAP"): the V2 Makefile previously had
# NO BYPASS_AUTONEG plumbing, so `BYPASS_AUTONEG=0 make ...` was silently
# ignored — the tb_top parameter kept its `else 1` default, the
# `if (BYPASS_AUTONEG==0)` force block never ran, and the autoneg FSM parked in
# ST_BYPASS (state 6). That, NOT the `#5000; release` the skip-note blamed, is
# why the autonomous force "did not engage" (both tb_tops release identically).
BYPASS_AUTONEG ?= 1
export BYPASS_AUTONEG   # consolidation 2026-07-15: the handoff test's os.environ["BYPASS_AUTONEG"] skip needs it exported
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)
# (CMSDK_FPGA_SRAM_V is exported by set_env.sh from CMSDK_DIR — source that before `make`.)

# RELY_ON_RTL_PRIO_DEFAULTS (Bug N7 regression parity)
#   0 = tb forces nego_priority_reg master:0x0001 / slave:0x0002 (legacy).
#   1 = leave nego_priority_reg to the RTL POR default.
RELY_ON_RTL_PRIO_DEFAULTS ?= 0
COMPILE_ARGS += +define+TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS=$(RELY_ON_RTL_PRIO_DEFAULTS)

# ── Whole-word cross-lane corrector select (2026-07-09, from kr260-pblock) ───
# tidelink_lane_deskew has two MUTUALLY EXCLUSIVE whole-word correctors. As
# built (EPOCH_ANCHOR=0) it runs SYNC_REANCHOR — which never arms in this env,
# because the bring-up leaves the SYNC beacon off (pair_v2_common.do_to_data_mode
# writes R8_SLOT0=0). So the default build has NO active whole-word corrector,
# and EPOCH_PROFILE=zero passes only because there is nothing to correct.
#
#   make EPOCH_PROFILE=staircase                 -> FAILS (no corrector)
#   make EPOCH_PROFILE=staircase EPOCH_ANCHOR=1  -> PASSES (EPOCH anchor engaged)
#
# Keep the default at 0: it matches the silicon build bit-for-bit.
#
# 2026-07-17 PLUMBING FIX: the OLD `+define+TIDELINK_EPOCH_ANCHOR` was DEAD in the
# V2 build — it selected the TL_EPOCH_ANCHOR_EN ifdef in the deps
# deps/tidelink-phy/rtl/wav/WavD2DGpio.v, but the V2 flist compiles the LOCAL
# OVERRIDE src/rtl/local_overrides/WavD2DGpio_v2.v (no such ifdef), so EPOCH_ANCHOR=1
# engaged NOTHING (the "PASSES" claim above was never true in V2). It now drives
# +define+TB_TOP_EPOCH_ANCHOR_EN, which defparams phy.EPOCH_ANCHOR_EN=1 and
# propagates through the fixed WlinkGPIOPHY_v2 -> WavD2DGpio_v2 -> u_deskew param
# path (banner "master=1 (deskew: m=1)"). SYNC_REANCHOR_EN becomes its complement.
EPOCH_ANCHOR ?= 0
ifeq ($(EPOCH_ANCHOR),1)
COMPILE_ARGS += +define+TB_TOP_EPOCH_ANCHOR_EN
endif

# ── Whole-word epoch-skew profile ───────────────────────────────────────────
EPOCH_PROFILE ?= zero
ifeq ($(EPOCH_PROFILE),zero)
EPOCH_DEFINES =
else ifeq ($(EPOCH_PROFILE),staircase)
# Pure whole-word staircase 0..7, both directions — zero clock-phase
# signature, the decoupled v37 failure mode (component-test profile).
EPOCH_DEFINES = \
	+define+TB_TOP_EPOCH_M2S_L0=0 +define+TB_TOP_EPOCH_M2S_L1=1 \
	+define+TB_TOP_EPOCH_M2S_L2=2 +define+TB_TOP_EPOCH_M2S_L3=3 \
	+define+TB_TOP_EPOCH_M2S_L4=4 +define+TB_TOP_EPOCH_M2S_L5=5 \
	+define+TB_TOP_EPOCH_M2S_L6=6 +define+TB_TOP_EPOCH_M2S_L7=7 \
	+define+TB_TOP_EPOCH_S2M_L0=0 +define+TB_TOP_EPOCH_S2M_L1=1 \
	+define+TB_TOP_EPOCH_S2M_L2=2 +define+TB_TOP_EPOCH_S2M_L3=3 \
	+define+TB_TOP_EPOCH_S2M_L4=4 +define+TB_TOP_EPOCH_S2M_L5=5 \
	+define+TB_TOP_EPOCH_S2M_L6=6 +define+TB_TOP_EPOCH_S2M_L7=7
else ifeq ($(EPOCH_PROFILE),silicon)
# v37 fingerprint: scattered 3..7 word epochs on the master's RX only
# (slave->master wires; z2_02 = master was the skewed side; deskew DEPTH_LOG=4
# usable spread is 13 so 3..7 sits inside capacity). M->S clean.
EPOCH_DEFINES = \
	+define+TB_TOP_EPOCH_S2M_L0=3 +define+TB_TOP_EPOCH_S2M_L1=7 \
	+define+TB_TOP_EPOCH_S2M_L2=5 +define+TB_TOP_EPOCH_S2M_L3=4 \
	+define+TB_TOP_EPOCH_S2M_L4=6 +define+TB_TOP_EPOCH_S2M_L5=3 \
	+define+TB_TOP_EPOCH_S2M_L6=7 +define+TB_TOP_EPOCH_S2M_L7=5
else
$(error EPOCH_PROFILE must be zero|staircase|silicon)
endif
COMPILE_ARGS += $(EPOCH_DEFINES)

# ── Negative control: force EPOCH_ANCHOR_EN=0 on both dies ─────────────────
EPOCH_ANCHOR_DIS ?= 0
ifeq ($(EPOCH_ANCHOR_DIS),1)
COMPILE_ARGS += +define+TB_TOP_EPOCH_ANCHOR_DIS
endif

# ── Marginal-eye fault injector on the S->M path (anchor-ON repro) ──────────
# EYE_FAULT=1 inserts eye_fault between u_skid_s2m and the master RX so cocotb
# can corrupt the training-exit content edge / sustained data with the anchor
# STILL ENABLED (EPOCH_ANCHOR_EN=1). Default OFF (bit-identical otherwise).
EYE_FAULT ?= 0
ifeq ($(EYE_FAULT),1)
COMPILE_ARGS += +define+TB_TOP_EYE_FAULT
endif

# Extra ad-hoc defines (e.g. per-lane overrides) — passthrough.
EXTRA_DEFINES ?=
COMPILE_ARGS += $(EXTRA_DEFINES)

# Keep each profile's objects separate so profile switches always recompile.
# MUST be := (not ?=): cocotb's Makefile.inc exports SIM_BUILD, so under the
# v2_gate recursion the parent make's value (sim_build_zero) arrives in the
# sub-make's ENVIRONMENT and a ?= would silently keep it — every stage would
# rerun the zero-skew binary (observed 2026-06-12; the tb's EPOCH_ANCHOR_EN
# banner is the canary). A plain := beats the environment; an explicit
# SIM_BUILD=... on the command line still wins.
# SIM_BUILD key — every knob that changes COMPILE_ARGS must appear here, because
# cocotb recompiles on SOURCE timestamps, not COMPILE_ARGS, so two configs sharing
# one sim_build silently rerun whichever binary built first (canary: the tb's
# EPOCH_ANCHOR_EN / `deskew: m=? s=?` banner). Consolidation 2026-07-16 UNION of:
#   _noanchor (EPOCH_ANCHOR_DIS), _anchor (EPOCH_ANCHOR — kr260-pblock),
#   _eye (EYE_FAULT), _prefixfc (PREFIX_FC — integ), _auto (BYPASS_AUTONEG!=1 — phase2).
SIM_BUILD := sim_build_$(EPOCH_PROFILE)$(if $(filter 1,$(EPOCH_ANCHOR_DIS)),_noanchor,)$(if $(filter 1,$(EPOCH_ANCHOR)),_anchor,)$(if $(filter 1,$(EYE_FAULT)),_eye,)$(if $(filter 1,$(PREFIX_FC)),_prefixfc,)$(if $(filter-out 1,$(BYPASS_AUTONEG)),_auto,)$(if $(filter 1,$(HONEST_STRAPS)),_honest,)

# Wave dump OFF by default — full bring-up VCDs exceed 4 GB. Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f $(V2_FLIST)` (invisible to make),
#     so without this an RTL-only edit re-runs the STALE simv. Track the STABLE
#     source flist file (NOT the PREFIX_FC-generated one, whose mtime churns every
#     invocation) plus the bare RTL paths of whichever flist is actually selected
#     (the generated one lists prefix_fc_adapter.sv when PREFIX_FC=1).
#     See docs/SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist $(call flist_srcs,$(V2_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

# ── Aggregate gate: all four stages, in order ───────────────────────────────
.PHONY: v2_gate
v2_gate:
	$(MAKE) EPOCH_PROFILE=zero      MODULE=test_v2_pair_data
	$(MAKE) EPOCH_PROFILE=staircase MODULE=test_v2_pair_data
	$(MAKE) EPOCH_PROFILE=silicon   MODULE=test_v2_pair_data
	$(MAKE) EPOCH_PROFILE=silicon   EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

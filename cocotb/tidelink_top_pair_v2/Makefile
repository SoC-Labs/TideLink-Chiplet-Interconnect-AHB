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

# Autonomous-training bypass (2026-07-11): the v1 pair Makefile plumbs this; the v2 one
# never did, so `make BYPASS_AUTONEG=0` left TB_TOP_BYPASS_AUTONEG unset -> tb defaulted to
# BYPASS_AUTONEG=1 -> the autonomous-handoff test parked in ST_BYPASS (the stale "harness
# gap"). Default 1 preserves every existing test; run the zero-poke autonomous handoff test
# with `make BYPASS_AUTONEG=0 MODULE=test_v2_autonomous_fc_handoff`. Exported so the test's
# conditional skip (os.environ["BYPASS_AUTONEG"]) sees it.
BYPASS_AUTONEG ?= 1
export BYPASS_AUTONEG
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)
# (CMSDK_FPGA_SRAM_V is exported by set_env.sh from CMSDK_DIR — source that before `make`.)

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
SIM_BUILD := sim_build_$(EPOCH_PROFILE)$(if $(filter 1,$(EPOCH_ANCHOR_DIS)),_noanchor,)$(if $(filter 1,$(EYE_FAULT)),_eye,)$(if $(filter 1,$(PREFIX_FC)),_prefixfc,)

# Wave dump OFF by default — full bring-up VCDs exceed 4 GB. Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

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

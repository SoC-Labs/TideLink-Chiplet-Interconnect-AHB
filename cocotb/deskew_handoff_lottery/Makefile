# =============================================================================
# deskew_handoff_lottery — cocotb sim mirror of the KR260 intermittent-delivery
# bug (2026-07-22): both dies fcsm=4/cal=1 in data mode, the FIRST packet
# crosses byte-exact but subsequent packets read back all-zero; and WHICH
# direction / whether-it-delivers is a per-PL-reload lottery.
#
# Two cross-wired V2 (TIDELINK_PHY_V2) tidelink_top dies, joined by the RUNTIME
# whole-word skew injector epoch_skew_rt.sv (this bench's replacement for the
# sibling tidelink_top_pair_v2 compile-time pad_skid) so ONE binary can model
# several PL-reload realizations and change alignment mid-bring-up.
#
# Requires:  source ../../set_env.sh ; export TIDELINK_PHY_V2=1   (V2 rides in
# via the flist v2shims; EPOCH_PROFILE=zero — this bench injects skew at runtime,
# not via the EPOCH_PROFILE compile defines).
#
# KNOBS (parametric for Phase-3 fix exploration):
#   EPOCH_ANCHOR=0 | 1     shipping vs candidate fix. 0 (default) => WlinkGPIOPHY
#                          EPOCH_ANCHOR_EN=0 (SYNC_REANCHOR inert in data mode,
#                          occupancy-only) => shears under skew. 1 => defparam
#                          phy.EPOCH_ANCHOR_EN=1 => training-exit EPOCH anchor.
#   LANE_MASK=0xNN         deskew RX lane_mask the test Force-drives on BOTH
#                          dies' u_deskew (default 0xFF = all lanes active). Set
#                          e.g. 0xFE to mask the deterministically-wrong lane 0.
#   MODULE=<test>          default test_deskew_handoff_lottery
#
# STALE-simv TRAP: DUT RTL arrives via `-f <flist>` (invisible to make). The
# flist_deps.mk block below adds every flist-sourced RTL path to
# CUSTOM_COMPILE_DEPS so an RTL edit forces a rebuild. SIM_BUILD is ALSO keyed on
# EPOCH_ANCHOR so the anchor-on / anchor-off binaries never share a build dir.
# After ANY edit to tb_top.sv / epoch_skew_rt.sv / a flist RTL file, if in doubt
# `rm -rf sim_build_*` before trusting a result.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/epoch_skew_rt.sv $(CURDIR)/eye_fault.sv

TOPLEVEL = tb_top
MODULE  ?= test_deskew_handoff_lottery

# tidelink python package (packet encoding helpers used by pair_v2_common).
export PYTHONPATH := $(TIDELINK_HOME)/python:$(PYTHONPATH)

# LANE_MASK is consumed by the test (cocotb reads os.environ), not the compile.
LANE_MASK ?= 0xFF
export LANE_MASK

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist

# ── Candidate-fix knob: training-exit EPOCH anchor ON (both dies) ────────────
# Drives the WlinkGPIOPHY EPOCH_ANCHOR_EN param (propagates to u_deskew;
# SYNC_REANCHOR_EN becomes its complement). Default OFF = the shipping build.
EPOCH_ANCHOR ?= 0
export EPOCH_ANCHOR
ifeq ($(EPOCH_ANCHOR),1)
COMPILE_ARGS += +define+TB_TOP_EPOCH_ANCHOR_EN
endif

# Wave dump OFF by default — full bring-up VCDs are multi-GB (tb_top dumps
# unless TB_TOP_NO_DUMP is defined). Enable with DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

# Keep anchor-on / anchor-off objects separate: cocotb recompiles on SOURCE
# timestamps, not COMPILE_ARGS, so two configs sharing one sim_build silently
# rerun whichever binary built first. MUST be := (Makefile.inc exports SIM_BUILD).
SIM_BUILD := sim_build$(if $(filter 1,$(EPOCH_ANCHOR)),_anchor,_shipping)

# --- Build-staleness guard (flist_deps.mk): recompile on flist-sourced RTL
#     edits. VERILOG_SOURCES lists only the tb + injectors; DUT RTL arrives via
#     `-f <flist>`. See docs/SIM_GATE_COVERAGE.md and the memory
#     project_cocotb_stale_simv_flist_rtl.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

# ── Aggregate: the whole story in one transcript ────────────────────────────
#   1. shipping build  -> intermittent-delivery lottery + zero-skew control
#   2. fix build       -> same lottery, EPOCH anchor ON (deliveries recovered)
.PHONY: lottery
lottery:
	$(MAKE) EPOCH_ANCHOR=0 MODULE=test_deskew_handoff_lottery
	$(MAKE) EPOCH_ANCHOR=1 MODULE=test_deskew_handoff_lottery

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

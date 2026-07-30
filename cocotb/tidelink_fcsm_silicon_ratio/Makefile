# =============================================================================
# tidelink_fcsm_silicon_ratio -- I1 silicon-feedback regression (P1 blocker).
#
# Reproduces, then proves the fix for, the FCSM state-2 stall the silicon
# feedback cites: with the local_overrides recovery FCSM compiled into the AXI
# data path (FCSM 0-4) and the CRACK-emit gate at its ORIGINAL 8'd32, a MARGINAL
# link at the ~40 ns silicon link:app ratio (modelled by a periodic LL
# re-bring-up) never lets the state-2 emit count reach 32 -> the five AXI FC
# nodes stall in state 2 -> never reach LINK_IDLE -> all-zeros both directions.
# Lowering the gate lets the count reach it in the same window -> state 2 clears.
# (A CLEAN link clears state 2 even at gate=32 -- the `clean` control target --
# so the gate only binds under marginal conditions; see the test docstring.)
#
# Harness: a verbatim copy of the maintained cocotb/tidelink_error_injection
# V2 paired-die environment (two TIDELINK_PHY_V2 tidelink_top instances). The
# ONLY delta is the DUT flist: FCSM 0-4 are re-pointed from the deps
# recovery-STRIPPED copies to src/rtl/local_overrides (the recovery copies) so
# the socl_l7 gate is actually compiled in and observable.
#
# Two targets, identical except for the compile-time CRACK-emit threshold:
#   make repro   # +define+SOCL_L7_MIN_CRACK_EMITS_VAL=32  -> EXPECT FAIL (stall)
#   make fixed   # RTL default (tuned)                     -> EXPECT PASS
#
# The silicon clock ratio is TIDELINK_SIM_REF_PERIOD_NS=40.0 (hclk=20 ns app,
# ref_clk=40 ns PHY beat -- the "32-hclk/beat" silicon ratio documented in
# pair_v2_common.py). Override REF_PERIOD_NS to sweep.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Local copies of the maintained EI harness (repo convention: per-dir copies).
VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_fcsm_silicon_ratio

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# --- DUT flist: base tidelink_fpga_v2.flist. NOTE the shipping base flist
#     ALREADY points the five AXI FC nodes (WlinkGenericFCSM{,_1..4}) at
#     src/rtl/local_overrides (the I1 re-point b98b944), so "override" is the
#     base flist verbatim. FCSM_SRC (I1 async/cold repro) selects which copy of
#     the 5 AXI nodes is compiled — see gen_flist.sh:
#       override : shipping local_overrides recovery FCSM (L6/L7 HOLD armed from
#                  reset) — the silicon I1 config.            [RED candidate]
#       deps     : recovery-STRIPPED deps FCSM (no gate/footprint). [GREEN control]
#       emitfix  : the REFUTED emit-gate fix (e79a5b8) — HOLD held open until
#                  LINK_IDLE. Must stay RED (silicon says it doesn't work).
#     FCSM_5 (deps) and FCSM_6 (always local_overrides) are untouched in all.
FCSM_SRC    ?= override
BASE_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
LOCAL_FLIST := $(CURDIR)/tidelink_fpga_v2_fcsm_$(FCSM_SRC).flist
# Generate at parse time so flist_srcs (below) can see it, and so a clean
# checkout builds it before the simv rule runs.
_gen := $(shell bash $(CURDIR)/gen_flist.sh $(FCSM_SRC) $(BASE_FLIST) $(LOCAL_FLIST))
COMPILE_ARGS += -f $(LOCAL_FLIST)

# Bit-level pad skew (RX capture-phase knob). Default 0 = passthrough.
SKID ?= 0
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID)
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1

# CRACK-emit gate override. Empty = RTL default (the tuned/shipping value).
# `make repro` sets it to 32 (the failing silicon value).
CRACK_EMITS ?=
ifneq ($(strip $(CRACK_EMITS)),)
COMPILE_ARGS += +define+SOCL_L7_MIN_CRACK_EMITS_VAL=$(CRACK_EMITS)
endif

# ── I1 async/cold repro knobs (sim/i1-repro-silicon-ratio) ──────────────────
# SPLIT_REFCLK=1 gives the slave die its own PHY reference (ref_clk_s), driven
# by cocotb with a ppm/phase offset -> the two dies' io_tx_clk / forwarded pad
# clocks become asynchronous (silicon's two-oscillator condition). Default 0
# keeps the legacy shared-clock behaviour so repro/fixed/control are unchanged.
SPLIT_REFCLK ?= 0
ifeq ($(SPLIT_REFCLK),1)
COMPILE_ARGS += +define+TB_TOP_SPLIT_REFCLK
endif
# CAL_FAST=1 shrinks the calibrator S_HOLD/S_VALIDATE windows via defparam so a
# genuine COLD bring-up (no tb_early_exit bypass) is sim-feasible while keeping
# the cr_pkt_seen S_VALIDATE gate fully armed. Off for the legacy targets.
CAL_FAST ?= 0
ifeq ($(CAL_FAST),1)
COMPILE_ARGS += +define+TB_TOP_CAL_FAST
endif
# EMITFIX_HOLD_ALWAYS=1 forces the emitfix FCSM files back to pre-fix behaviour
# (emit HOLD armed from reset) — the controlled A/B RED partner for FCSM_SRC=emitfix.
EMITFIX_HOLD_ALWAYS ?= 0
ifeq ($(EMITFIX_HOLD_ALWAYS),1)
COMPILE_ARGS += +define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS
endif
# Slave PHY ref ppm offset + POR-release stagger are RUNTIME (cocotb reads env).
I1_REF_PPM ?= 0
export I1_REF_PPM
I1_POR_STAGGER_HCLK ?= 0
export I1_POR_STAGGER_HCLK
I1_REF_PHASE_PS ?= 0
export I1_REF_PHASE_PS

# Whether THIS config is expected to reach cr_seen=1 (GREEN). The test asserts
# on it; a RED config still runs EXPECT_CR=1 so the stuck-0 shows as a FAIL.
EXPECT_CR ?= 1
export EXPECT_CR
OBS_CHUNKS ?= 800
export OBS_CHUNKS
# Export the flist/async selectors so the cocotb python + logs can read them.
export FCSM_SRC
export SPLIT_REFCLK
export SKID

# Silicon clock ratio (ref_clk period ns). 40.0 = the ~40 ns silicon ratio.
REF_PERIOD_NS ?= 40.0
export TIDELINK_SIM_REF_PERIOD_NS = $(REF_PERIOD_NS)

# Wave dump OFF by default (full bring-up VCDs are huge). Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

# Separate build dirs so repro (32) and fixed (default) never share a stale simv.
SIM_BUILD ?= sim_build_fixed

# --- Build-staleness guard: recompile on flist-sourced RTL edits (the DUT
#     arrives via -f <flist>, invisible to make). Depend on the base flist, the
#     generated flist, and every bare source path the generated flist lists
#     (which now includes the local_overrides FCSM copies).
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(BASE_FLIST) $(LOCAL_FLIST) $(call flist_srcs,$(LOCAL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

# --- Convenience targets ----------------------------------------------------
.PHONY: repro fixed control clean_builds

# Reproduce the silicon wedge: CRACK gate at the original 32 -> under a marginal
# link the state-2 emit count never reaches 32 -> all AXI nodes stall at state 2.
# EXPECT FAIL.
repro:
	$(MAKE) CRACK_EMITS=32 SIM_BUILD=sim_build_repro \
	        MODULE=test_fcsm_silicon_ratio \
	        TESTCASE=test_axi_fcsm_state2_clears_under_marginal_link

# Prove the fix: RTL default (tuned) gate -> state 2 clears under the same
# marginal link -> all AXI nodes reach LINK_IDLE. EXPECT PASS.
fixed:
	$(MAKE) SIM_BUILD=sim_build_fixed \
	        MODULE=test_fcsm_silicon_ratio \
	        TESTCASE=test_axi_fcsm_state2_clears_under_marginal_link

# Control: a CLEAN link-up clears state 2 at the tuned gate (fix does not break
# link-up). Runs at gate default; also passes at gate=32 (see repro comment).
control:
	$(MAKE) SIM_BUILD=sim_build_control \
	        MODULE=test_fcsm_silicon_ratio \
	        TESTCASE=test_axi_fcsm_clean_bringup_at_silicon_ratio

clean_builds:
	rm -rf sim_build_repro sim_build_fixed sim_build_control sim_build_fixed_* \
	       sim_build_i1_* tidelink_fpga_v2_fcsm_*.flist $(LOCAL_FLIST)

# ── I1 async/cold INSTRUMENT-TRUST GATE (sim/i1-repro-silicon-ratio) ─────────
# All four configs run the SAME test body (test_i1_async_cold.py) with the SAME
# async operating point; only FCSM_SRC / SPLIT_REFCLK differ. Sweep the point
# from the command line, e.g.  make i1_override I1_PPM=800 I1_STAGGER=600 I1_SKID=2
I1_PPM     ?= 400
I1_STAGGER ?= 300
I1_SKID    ?= 0

.PHONY: i1_deps i1_override i1_emitfix i1_poscontrol

_I1_COMMON = MODULE=test_i1_async_cold TESTCASE=test_i1_cold_bringup_cr_seen \
             CAL_FAST=1 REF_PERIOD_NS=$(REF_PERIOD_NS) \
             I1_REF_PPM=$(I1_PPM) I1_POR_STAGGER_HCLK=$(I1_STAGGER) SKID=$(I1_SKID)

# (a) deps FCSM, async  -> EXPECT GREEN (cr=1 both dies)
i1_deps:
	$(MAKE) $(_I1_COMMON) FCSM_SRC=deps SPLIT_REFCLK=1 EXPECT_CR=1 \
	        SIM_BUILD=sim_build_i1_deps

# (b) override FCSM (shipping I1), async -> RED candidate (a FAIL == RED repro)
i1_override:
	$(MAKE) $(_I1_COMMON) FCSM_SRC=override SPLIT_REFCLK=1 EXPECT_CR=1 \
	        SIM_BUILD=sim_build_i1_override

# (c) refuted emit-gate fix (e79a5b8), async -> must ALSO stay RED
i1_emitfix:
	$(MAKE) $(_I1_COMMON) FCSM_SRC=emitfix SPLIT_REFCLK=1 EXPECT_CR=1 \
	        SIM_BUILD=sim_build_i1_emitfix

# (d) positive control: override FCSM, SYNChronous -> EXPECT GREEN (TB reads cr=1)
i1_poscontrol:
	$(MAKE) $(_I1_COMMON) FCSM_SRC=override SPLIT_REFCLK=0 EXPECT_CR=1 \
	        I1_REF_PPM=0 I1_POR_STAGGER_HCLK=0 \
	        SIM_BUILD=sim_build_i1_poscontrol

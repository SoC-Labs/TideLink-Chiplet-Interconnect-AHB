# =============================================================================
# tidelink_fcsm_cr_seen0 -- FAITHFUL cr_seen=0 repro (I1 bring-up blocker).
#
# See docs/I1_SIM_REPRO_PLAN.md. Fork of the proven 2-die tidelink_top pair DUT
# (real WlinkTxRouter round-robin + broadcast RX + local_overrides FCSM 0-4),
# with the BLIND stimulus replaced by a COLD, UN-BYPASSED, ASYNC bring-up whose
# oracle is the silicon 4-tuple (cr_seen/crack_seen/cal_done/fcsm), NOT state==4.
#
# The DUT (tb_top.sv/pad_skid.sv/err_inject.sv) and the harness (pair_v2_common)
# are reused from ../tidelink_fcsm_silicon_ratio (repo per-dir-copy convention is
# relaxed here to keep the delta reviewable). Rungs 0-1 run on that shared-clock
# tb; rung 2+ (per-die clocks) needs the split-clock tb variant -- see TODO(F6).
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

SILRATIO := $(TIDELINK_HOME)/cocotb/tidelink_fcsm_silicon_ratio
# Local tb_top.sv variant: adds the F4 CAL_HOLD_CYCLES / VAL_TIMEOUT defparam
# knobs and (guarded) the F6 split-clock option. pad_skid/err_inject are copied
# verbatim. pair_v2_common.py still comes from SILRATIO via PYTHONPATH.
VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_cr_seen0

# pair_v2_common lives in the silicon_ratio env; this dir holds test_cr_seen0.py.
export PYTHONPATH := $(CURDIR):$(SILRATIO):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# -----------------------------------------------------------------------------
# F1: DUT flist -- FCSM_SRC selects the five AXI FC nodes' source.
#     local (default, RED lever) -> src/rtl/local_overrides recovery copies
#     deps                        -> deps/axi-chiplet-controller baseline (GREEN)
# -----------------------------------------------------------------------------
BASE_FLIST ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
FCSM_SRC   ?= local
DUT_FLIST  := $(CURDIR)/dut_$(FCSM_SRC).flist
export FCSM_SRC        # the cocotb oracle reads this to expect RED vs GREEN

# -----------------------------------------------------------------------------
# F9: SOCL_L6_MIN_CR_EMITS is HARDCODED 8'd32 in the shipping RTL (unlike L7).
#     To sweep it WITHOUT editing shipping RTL, sed-copy the 5 FCSM files into
#     gen_fcsm/ with an `ifndef` guard, and point the flist at the copies.
#     Set SOCL_L6=<n> to activate; empty = use shipping files unchanged.
# -----------------------------------------------------------------------------
SOCL_L6 ?=
GEN_FCSM := $(CURDIR)/gen_fcsm

ifeq ($(FCSM_SRC),deps)
  # deps baseline: re-point FCSM{,_1..4} local_overrides -> deps (recovery-stripped).
  _gen := $(shell sed -E 's@\$$\{TIDELINK_HOME\}/src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?)\.v@$${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/\1.v@' $(BASE_FLIST) > $(DUT_FLIST))
else ifneq ($(strip $(SOCL_L6)),)
  # local + L6 override: copy the 5 FCSM files, insert the ifndef guard, re-point.
  _mk  := $(shell mkdir -p $(GEN_FCSM))
  _cp  := $(shell for f in WlinkGenericFCSM WlinkGenericFCSM_1 WlinkGenericFCSM_2 WlinkGenericFCSM_3 WlinkGenericFCSM_4; do \
                    sed -E "s@localparam \[7:0\][[:space:]]+SOCL_L6_MIN_CR_EMITS[[:space:]]*=[[:space:]]*8'd32;@\`ifndef SOCL_L6_MIN_CR_EMITS_VAL\n \`define SOCL_L6_MIN_CR_EMITS_VAL 32\n\`endif\n  localparam [7:0] SOCL_L6_MIN_CR_EMITS = \`SOCL_L6_MIN_CR_EMITS_VAL;@" \
                        $(TIDELINK_HOME)/src/rtl/local_overrides/$$f.v > $(GEN_FCSM)/$$f.v; done)
  _gen := $(shell sed -E 's@\$$\{TIDELINK_HOME\}/src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?)\.v@$(GEN_FCSM)/\1.v@' $(BASE_FLIST) > $(DUT_FLIST))
  COMPILE_ARGS += +define+SOCL_L6_MIN_CR_EMITS_VAL=$(SOCL_L6)
else
  # local, shipping files unchanged.
  _gen := $(shell cp $(BASE_FLIST) $(DUT_FLIST))
endif
COMPILE_ARGS += -f $(DUT_FLIST)

# -----------------------------------------------------------------------------
# Stimulus / clocking knobs (see plan §4.1). Passed to the cocotb test via env,
# and (where structural) to the DUT via +define.
# -----------------------------------------------------------------------------
# F7: link:app ratio. 8=fast (rungs 0-1), 40=silicon (rungs 3-4).
REF_PERIOD_NS ?= 8.0
export TIDELINK_SIM_REF_PERIOD_NS = $(REF_PERIOD_NS)

# F4: shrink the S_HOLD dwell via hierarchical defparam (tb_top.sv) so a COLD
#     un-bypassed bring-up is feasible: HOLD_CYCLES default 65536 link-word-clocks
#     ~= 8.4 ms sim (link word clk ~128 ns), far past any feasible poll window.
#     S_VALIDATE still gates on the real sideband cr_pkt_seen (NOT a bypass).
#     Empty = leave the RTL default untouched.
CAL_HOLD_CYCLES ?= 1024
ifneq ($(strip $(CAL_HOLD_CYCLES)),)
COMPILE_ARGS += +define+TB_CAL_HOLD_CYCLES=$(CAL_HOLD_CYCLES)
endif
export TIDELINK_CAL_HOLD_CYCLES = $(CAL_HOLD_CYCLES)

# F4b: S_VALIDATE window (link cycles). Default RTL 4096. The sideband CR must
#      cross within this window or S_VALIDATE times out. Empty = RTL default.
CAL_VAL_TIMEOUT ?=
ifneq ($(strip $(CAL_VAL_TIMEOUT)),)
COMPILE_ARGS += +define+TB_CAL_VAL_TIMEOUT=$(CAL_VAL_TIMEOUT)
endif

# F4c: override VAL_TIMEOUT_TO_DONE (V2 default 1 = give up to S_DONE on
#      S_VALIDATE timeout, asserting cal_done). Set 0 to make a starved
#      S_VALIDATE hold cal_done=0 (closer to the FPGA `else calibrator + the
#      silicon 4-tuple). Empty = RTL default (1 under TIDELINK_PHY_V2).
CAL_VAL_TIMEOUT_TO_DONE ?=
ifneq ($(strip $(CAL_VAL_TIMEOUT_TO_DONE)),)
COMPILE_ARGS += +define+TB_CAL_VAL_TIMEOUT_TO_DONE=$(CAL_VAL_TIMEOUT_TO_DONE)
endif

# F4: whether the test forces the calibrator bypass. rung0=1 (baseline), else 0.
CAL_BYPASS ?= 0
export TIDELINK_CAL_BYPASS = $(CAL_BYPASS)

# F6: async 2-die clocking. SPLIT_CLK=1 compiles the split-clock tb_top variant
#     (slave die on independent s_hclk/s_ref_clk) and tells the cocotb harness to
#     drive them at a DIE_CLK_PPM offset with RESET_SKEW_NS POR skew.
SPLIT_CLK    ?= 0
DIE_CLK_PPM  ?= 0
RESET_SKEW_NS ?= 0
ifeq ($(SPLIT_CLK),1)
COMPILE_ARGS += +define+TB_SPLIT_CLK
export TIDELINK_SPLIT_CLK = 1
endif
export TIDELINK_DIE_CLK_PPM  = $(DIE_CLK_PPM)
export TIDELINK_RESET_SKEW_NS = $(RESET_SKEW_NS)

# F6b: stagger between the two dies' role_lock (calibrator auto-arm). A stagger
# >= the S_HOLD dwell forces the two S_VALIDATE windows apart (staggered deploy).
ROLE_STAGGER_NS ?= 0
export TIDELINK_ROLE_STAGGER_NS = $(ROLE_STAGGER_NS)

# F6: wire skew (non-ideal serial link). 0 = passthrough.
SKID_BITS ?= 0
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1

# The refuted emit-gate fix control (plan §5.5). Set HOLD_ALWAYS=1 to restore the
# pre-fix I1 emit HOLD (RED control); default = shipping "fixed" behaviour, which
# MUST NOT green a faithful cr_seen=0 RED.
HOLD_ALWAYS ?=
ifneq ($(strip $(HOLD_ALWAYS)),)
COMPILE_ARGS += +define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS
endif

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD ?= sim_build_$(FCSM_SRC)

include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(BASE_FLIST) $(DUT_FLIST) $(call flist_srcs,$(DUT_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

# -----------------------------------------------------------------------------
# Ladder targets. See docs/I1_REPRO_ASYNC_LADDER.md for the FULL results and the
# structural finding (no FCSM-keyed cr_seen=0 RED exists; every cr_seen=0 state
# is deps==local bit-identical). These targets reproduce the documented runs.
# -----------------------------------------------------------------------------
.PHONY: rung0 green_deps green_split stag_local stag_deps clean_builds

# Rung 0 -- GREEN baseline + instrument trust (calibrator bypassed, fast, deps).
# PASS: cr=1 cal=1, pkt_is_cr_pkt pulses, clean-hex status (no X).
rung0:
	$(MAKE) FCSM_SRC=deps CAL_BYPASS=1 REF_PERIOD_NS=8.0 \
	        MODULE=test_cr_seen0 TESTCASE=test_rung0_green_baseline \
	        SIM_BUILD=sim_build_rung0

# UN-BYPASSED GREEN oracle -- deps, cold, real CR-handshake validation (fcsm->4).
# The load-bearing positive control: cr=1 via S_VALIDATE confirm, NOT the bypass.
green_deps:
	$(MAKE) FCSM_SRC=deps CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 REF_PERIOD_NS=8.0 \
	        POLL_CHUNKS=200 MODULE=test_cr_seen0 TESTCASE=test_cold_bringup_cr_seen \
	        SIM_BUILD=sim_build_green

# Un-bypassed GREEN under the async split clock (deps stays GREEN with ppm+skew).
green_split:
	$(MAKE) FCSM_SRC=deps CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 SPLIT_CLK=1 \
	        DIE_CLK_PPM=1000 RESET_SKEW_NS=3000 REF_PERIOD_NS=8.0 POLL_CHUNKS=250 \
	        MODULE=test_cr_seen0 TESTCASE=test_diag SIM_BUILD=sim_build_green_split

# FCSM-INDEPENDENCE demo (NOT a valid RED): staggered role_lock + churn drives a
# sustained cr_seen=0 that is a CALIBRATOR rendezvous failure. Run stag_local AND
# stag_deps -- the two are bit-identical (same grant counts) => cr_seen=0 is NOT
# FCSM-keyed. This is the evidence, not a repro of the silicon bug.
stag_local:
	$(MAKE) FCSM_SRC=local CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 CAL_VAL_TIMEOUT=256 \
	        CAL_VAL_TIMEOUT_TO_DONE=0 SPLIT_CLK=1 DIE_CLK_PPM=1000 \
	        ROLE_STAGGER_NS=200000 REF_PERIOD_NS=8.0 POLL_CHUNKS=500 \
	        MODULE=test_cr_seen0 TESTCASE=test_diag SIM_BUILD=sim_build_stag_local

stag_deps:
	$(MAKE) FCSM_SRC=deps CAL_BYPASS=0 CAL_HOLD_CYCLES=1024 CAL_VAL_TIMEOUT=256 \
	        CAL_VAL_TIMEOUT_TO_DONE=0 SPLIT_CLK=1 DIE_CLK_PPM=1000 \
	        ROLE_STAGGER_NS=200000 REF_PERIOD_NS=8.0 POLL_CHUNKS=500 \
	        MODULE=test_cr_seen0 TESTCASE=test_diag SIM_BUILD=sim_build_stag_deps

clean_builds:
	rm -rf sim_build* dut_local.flist dut_deps.flist gen_fcsm

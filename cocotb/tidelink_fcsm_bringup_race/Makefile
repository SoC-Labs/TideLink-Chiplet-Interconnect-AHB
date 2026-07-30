# =============================================================================
# tidelink_fcsm_bringup_race -- the REAL I1 KR260 bring-up regression.
#
# Reproduces the silicon failure (SWI_LANE_STATUS cr_seen=0/fcsm stuck 0/1, both
# dies) and proves the fix. Root cause: the local_overrides AXI FC nodes hold
# state 1 until they have emitted SOCL_L6_MIN_CR_EMITS(=32) of their OWN CR
# packets; at the ~40 ns silicon link:app ratio, on a marginal/retrying link
# (periodic LL re-bring-up), a node cannot accrue 32 own emits before the count
# resets -- throttled ~6-7x by the shared fair round-robin WlinkTxRouter that
# ALSO carries the sideband node SWI_LANE_STATUS reports -> every node livelocks
# at state 1 -> cr_seen=0. deps has no such gate and always converges.
#
#   make repro   # +define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS (pre-fix I1) -> EXPECT FAIL
#   make fixed   # shipping default (HOLD off until first LINK_IDLE)  -> EXPECT PASS
#   make deps    # deps FCSMs (recovery-stripped, no gate)            -> EXPECT PASS
#   make control # clean link, shipping default                       -> EXPECT PASS
#
# Silicon clock ratio: TIDELINK_SIM_REF_PERIOD_NS=40.0 (hclk=20 ns app,
# ref_clk=40 ns PHY beat). Marginal cadence: HOLD_HCLK (default 800).
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_fcsm_bringup_race

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# --- DUT flist. FCSM_SRC selects the five AXI FC nodes' source:
#       local (default) -> src/rtl/local_overrides  (the shipping recovery copies)
#       deps            -> deps/axi-chiplet-controller (recovery-stripped baseline)
#     FCSM_5 and FCSM_6 (sideband) are left exactly as the base flist has them.
BASE_FLIST ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
FCSM_SRC   ?= local
DUT_FLIST  := $(CURDIR)/dut_$(FCSM_SRC).flist
ifeq ($(FCSM_SRC),deps)
_gen := $(shell sed -E 's@\$$\{TIDELINK_HOME\}/src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?)\.v@$${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/\1.v@' $(BASE_FLIST) > $(DUT_FLIST))
else
_gen := $(shell cp $(BASE_FLIST) $(DUT_FLIST))
endif
COMPILE_ARGS += -f $(DUT_FLIST)

# Zero skew, SW bring-up (bit-identical to the EI zero profile).
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1

# RED control: restore the pre-fix I1 emit HOLD (armed from reset).
HOLD_ALWAYS ?=
ifneq ($(strip $(HOLD_ALWAYS)),)
COMPILE_ARGS += +define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS
export SOCL_FCSM_HOLD_MODE = HOLD-ALWAYS-from-reset (pre-fix I1, RED)
endif

# Silicon clock ratio (ref_clk period ns).
REF_PERIOD_NS ?= 40.0
export TIDELINK_SIM_REF_PERIOD_NS = $(REF_PERIOD_NS)

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD ?= sim_build

# Build-staleness guard: recompile on flist-sourced RTL edits (DUT arrives via
# -f <flist>, invisible to make).
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(BASE_FLIST) $(DUT_FLIST) $(call flist_srcs,$(DUT_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: repro fixed deps control clean_builds

# RED: pre-fix I1 emit HOLD armed from reset -> marginal-link livelock.
repro:
	$(MAKE) HOLD_ALWAYS=1 FCSM_SRC=local SIM_BUILD=sim_build_repro \
	        MODULE=test_fcsm_bringup_race \
	        TESTCASE=test_bringup_reaches_link_idle_under_marginal_link

# GREEN: shipping default fix (HOLD off until first LINK_IDLE).
fixed:
	$(MAKE) FCSM_SRC=local SIM_BUILD=sim_build_fixed \
	        MODULE=test_fcsm_bringup_race \
	        TESTCASE=test_bringup_reaches_link_idle_under_marginal_link

# GREEN baseline: deps (recovery-stripped, no gate) -- the proven-working path.
deps:
	$(MAKE) FCSM_SRC=deps SIM_BUILD=sim_build_deps \
	        MODULE=test_fcsm_bringup_race \
	        TESTCASE=test_bringup_reaches_link_idle_under_marginal_link

# Control: clean link reaches LINK_IDLE with the shipping default (fix intact).
control:
	$(MAKE) FCSM_SRC=local SIM_BUILD=sim_build_control \
	        MODULE=test_fcsm_bringup_race \
	        TESTCASE=test_clean_bringup

clean_builds:
	rm -rf sim_build sim_build_repro sim_build_fixed sim_build_deps \
	       sim_build_control dut_local.flist dut_deps.flist

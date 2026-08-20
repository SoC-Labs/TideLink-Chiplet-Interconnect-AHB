# =============================================================================
# tidelink_link_rate_regs_inert — the OFF-arm gate for the D2D link-rate bank
#
# WHAT THIS GATE IS FOR
#   src/rtl/tidelink_top.sv instantiates tidelink_link_rate_regs under
#       if (LINK_RATE_REGS_PRESENT) begin : g_link_rate_regs
#       ...
#       end else begin : g_link_rate_absent
#   and that parameter DEFAULTS TO 1'b0. Every shipping wrapper — the ethernet
#   chiplet included — elaborates the ELSE arm. The claim the feature rests on
#   is therefore not "the register bank works" (cocotb/tidelink_top_pair/
#   test_link_rate_regs.py covers that, with the bank forced on); it is
#
#       AT LINK_RATE_REGS_PRESENT=0, tidelink_top BEHAVES EXACTLY AS IT DID
#       BEFORE THE FEATURE EXISTED.
#
#   This directory is that claim, made falsifiable and put where the regression
#   re-runs it.
#
# WHY IT IS NOT THE PAIR SUITE RE-RUN
#   The evidence originally offered for inertness was that tidelink_top_pair
#   produced an identical 2011520.01 ns / 11-tests-per-run signature before and
#   after the change. That signature is BLIND to the OFF arm: no test in that
#   directory ever addresses APB quadrant 11, so breaking `assign rate_pready =
#   1'b1;` to 1'b0 leaves the signature bit-identical. An indiscriminate check
#   is worse than no check, because it is quoted as though it discriminated.
#   Everything below is chosen so that a mutation of the ELSE arm FAILS it —
#   see MUTATIONS at the top of test_link_rate_inert.py for the table that was
#   actually run.
#
# SHAPE
#   One tidelink_top at default parameters (tb_inert.sv), no link partner, no
#   bring-up. ~7 us of simulation. The compile dominates; the run is seconds.
#
# RUN
#   make                     # all four tests
#   make MODULE=test_link_rate_inert TESTCASE=test_inert_02_quadrant11_reads_zero
#
# CMSDK_FPGA_SRAM_V is resolved here rather than being required from the
# environment (same firstword/wildcard form as cocotb/tidechart_tidelink_pair),
# so `make` in this directory works from a bare shell.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
export CMSDK_FPGA_SRAM_V ?= $(firstword \
    $(wildcard $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v) \
    $(TIDELINK_HOME)/imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v)

VERILOG_SOURCES = $(CURDIR)/tb_inert.sv

TOPLEVEL = tb_inert
MODULE  ?= test_link_rate_inert

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# V1 flist, matching cocotb/tidelink_top_pair's default build. The property
# under test is in tidelink_top.sv itself, which both flists compile
# identically, so the PHY choice is not load-bearing here.
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist

# The harness drives 99 inputs and reads 3 hierarchical taps; nothing floats.
# Unconnected-output and hierarchical-reference notes from VCS are expected.
COMPILE_ARGS += +define+TB_INERT_NO_DUMP

# Waves off by default: this gate runs in the regression and a VCD of a whole
# tidelink_top is pointless for a check whose entire output is four asserts.
# Re-enable with:  make TB_INERT_DUMP=1
TB_INERT_DUMP ?= 0
ifeq ($(TB_INERT_DUMP),1)
COMPILE_ARGS := $(filter-out +define+TB_INERT_NO_DUMP,$(COMPILE_ARGS))
endif

# -- Code coverage -----------------------------------------------------------
ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

# --- Build-staleness guard ---------------------------------------------------
# VERILOG_SOURCES lists only the harness; the DUT arrives via `-f <flist>`,
# which make cannot see. Without this a mutation of tidelink_top.sv would re-run
# the STALE simv and the gate would report PASS on mutated RTL — precisely the
# failure mode this directory exists to prevent, so the guard is load-bearing
# here rather than hygiene. See docs/SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink_fpga.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

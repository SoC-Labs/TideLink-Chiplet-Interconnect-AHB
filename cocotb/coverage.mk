# ─────────────────────────────────────────────────────────────────────────────
# coverage.mk — SHARED VCS code-coverage wiring for every cocotb bench.
#
# WHY THIS FILE EXISTS (2026-08-26)
#   Before this, 23 of 62 cocotb benches carried a hand-copied `ifdef COVERAGE`
#   block and 39 carried NONE.  `make coverage` in cocotb/Makefile therefore
#   produced a confident-looking number over a partial corpus: the three benches
#   that exercise the FULL tidelink_top + XHB500 bridge + Wlink datapath
#   (tidelink_top_pair, tidelink_top_pair_v2, tidelink_axi_datanode_recovery)
#   were among the 39 with no instrumentation at all.  A coverage run that
#   silently skips the suites that carry the data path is worse than no coverage
#   run, because the resulting number is believed.
#
#   One include, every bench, or the number is not trustworthy.
#
# USAGE (bench Makefile, immediately BEFORE the cocotb Makefile.sim include, so
# that MODULE / TESTCASE / SIM_BUILD are already final):
#
#     include $(dir $(lastword $(MAKEFILE_LIST)))../coverage.mk
#     include $(shell cocotb-config --makefiles)/Makefile.sim
#
# Inert unless COVERAGE is set, so the normal gate is byte-for-byte unchanged.
#
#     COVERAGE=1 make sim_gate          # whole gate, merged database
#     COVERAGE=1 make -C cocotb/tidelink_fifo
#
# DATABASE LAYOUT — one .vdb per COMPILE, one -cm_name per RUN
#   A VCS coverage database is bound to ONE elaborated design, so the vdb is
#   keyed on (bench, SIM_BUILD): SIM_BUILD is already this project's canonical
#   compile key ("every knob that changes COMPILE_ARGS must appear here", see
#   cocotb/tidelink_top_pair_v2/Makefile), and two different compiles sharing a
#   SIM_BUILD is a pre-existing stale-simv bug, not a coverage bug.
#   Within one vdb each RUN gets a distinct -cm_name derived from
#   MODULE/TESTCASE, so suites that legitimately share a compile (t31 + t30 on
#   sim_build_l4; the five axirec testcases) do not overwrite each other's test
#   data.
#
# ABSOLUTE -cm_dir IS MANDATORY, NOT STYLE
#   cocotb's Makefile.vcs COMPILES with `cd $(SIM_BUILD) && vcs ...` but RUNS
#   `$(SIM_BUILD)/simv` from the BENCH directory.  A relative -cm_dir therefore
#   resolves to two DIFFERENT places for the compile and the run, which is
#   exactly why the pre-existing per-bench blocks had to be merged from two
#   separate dirs (`-dir $env/sim_build/simv.vdb -dir $env/coverage.vdb`) in
#   cocotb/Makefile's coverage_merge.  Absolute for both, one dir, no seam.
#
# NOT INSTRUMENTED, DELIBERATELY: the elaboration-only gate suites (v1_elab,
#   asic_v1_elab, asic_v2_elab, dft_wrapper_elab).  They compile and never
#   simulate, so they would contribute a design database with ZERO executed
#   tests — which does not measure anything, and would DILUTE the merged report
#   with V1-only files that the V2 shipping build does not contain.
# ─────────────────────────────────────────────────────────────────────────────

ifdef COVERAGE

# Repo root, captured before any later include perturbs MAKEFILE_LIST.
TL_COV_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
TIDELINK_HOME ?= $(abspath $(TL_COV_MK_DIR)/..)

# All five metrics.  CM_METRICS is the name the pre-existing per-bench blocks
# used; keep it as the override knob so anything that set it still works.
CM_METRICS  ?= line+cond+fsm+tgl+branch

TL_COV_ROOT ?= $(TIDELINK_HOME)/imp/coverage

# VCS test names and directory names must not carry ',' '/' '.' or ':'.
tl_cov_comma := ,
tl_cov_sane   = $(subst $(tl_cov_comma),_,$(subst /,_,$(subst .,_,$(subst :,_,$(subst $() ,_,$(1))))))

# Deferred (`=`, not `:=`): SIM_BUILD is set by cocotb's Makefile.inc, and
# MODULE/TESTCASE may be set on the sub-make command line — all of which happen
# AFTER this file is read.  Late binding is what makes one include work for
# every bench.
TL_CM_KEY   = $(call tl_cov_sane,$(notdir $(CURDIR))__$(notdir $(SIM_BUILD)))
TL_CM_DIR   = $(TL_COV_ROOT)/$(TL_CM_KEY).vdb
TL_CM_NAME  = $(call tl_cov_sane,$(TL_CM_KEY)__$(if $(MODULE),$(MODULE),dflt)$(if $(TESTCASE),__$(TESTCASE),))

COMPILE_ARGS += -cm $(CM_METRICS) -cm_dir $(TL_CM_DIR)
SIM_ARGS     += -cm $(CM_METRICS) -cm_dir $(TL_CM_DIR) -cm_name $(TL_CM_NAME)

endif

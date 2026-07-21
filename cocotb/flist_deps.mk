# =============================================================================
# flist_deps.mk — shared build-staleness guard for the per-bench cocotb envs.
#
# THE HAZARD (memory: project_cocotb_stale_simv_flist_rtl): cocotb's VCS rule is
#     $(SIM_BUILD)/simv: $(VERILOG_SOURCES) $(CUSTOM_COMPILE_DEPS)
# In ~30 of 33 benches VERILOG_SOURCES lists ONLY the tb .sv files; ALL of the
# DUT RTL arrives via `COMPILE_ARGS += -f <flist>`, which make cannot see. With
# CUSTOM_COMPILE_DEPS unset and a persistent SIM_BUILD, an RTL-only edit changes
# no prerequisite make knows about, so make RE-RUNS THE OLD simv — silently
# testing stale RTL (this already produced a false "hazard refuted" result).
# `make sim_gate` is immune (it cleans build dirs); ad-hoc/lane-private runs are
# NOT. This file closes that gap for the ad-hoc runs.
#
# USAGE (place AFTER TIDELINK_HOME and the flist vars are set, and BEFORE the
# `include .../Makefile.sim` — CUSTOM_COMPILE_DEPS must be final when the simv
# rule is read):
#     include $(TIDELINK_HOME)/cocotb/flist_deps.mk
#     _flist_deps := $(MY_FLIST) $(call flist_srcs,$(MY_FLIST))
#     CUSTOM_COMPILE_DEPS += $(_flist_deps)
# Depend on the flist FILE (catches flist edits) plus every bare source path it
# lists (catches RTL-only edits). Use `:=` for _flist_deps so the parse runs once.
#
# flist_srcs(flist) -> the bare source paths a flist lists. It:
#   * drops comments (// or #), +incdir/+define, and -options, keeping bare paths;
#   * expands ${VAR} references via envsubst — GNU make does NOT export make-set
#     vars to a parse-time $(shell), and it does not re-scan $(shell) output for
#     ${VAR}, so the vars the flists use are injected into envsubst's env here;
#   * drops any path that does not resolve to an existing file, so a bench with
#     an unset var (e.g. CMSDK_DIR) still runs standalone instead of dying on a
#     "No rule to make target" for a half-expanded prerequisite.
# Read-only: this only ADDS prerequisites; it never changes what/how VCS compiles.
# =============================================================================
flist_srcs = $(shell grep -vhE '^[[:space:]]*(//|\#|[+-])' $(1) 2>/dev/null | \
	TIDELINK_HOME='$(TIDELINK_HOME)' \
	CMSDK_DIR='$(CMSDK_DIR)' \
	CMSDK_FPGA_SRAM_V='$(CMSDK_FPGA_SRAM_V)' \
	MEM_PATH='$(MEM_PATH)' \
	STDCELL_VERILOG='$(STDCELL_VERILOG)' \
	TIDECHART_HOME='$(TIDECHART_HOME)' \
	ETH_SS_HOME='$(ETH_SS_HOME)' \
	envsubst | while read -r f; do [ -f "$$f" ] && printf '%s ' "$$f"; done)

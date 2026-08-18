# =============================================================================
# TL-042 Option-1 recovery PROTOTYPE — cocotb A/B bench.
#
# Scratch prototype (NOT a landing). Proves, on the SAME two-die V2 harness the
# recovery suite uses, that:
#   * CONTROL (unpatched tidelink_top): an AW presented on u_xhb_sub s_axi with
#     the downstream awready held LOW wedges xhb_sub_hreadyout_raw forever.
#   * FIX (Option-1 patched copy): the wrapper synthesises the AW/W accept at the
#     stall timeout, the existing synth-B drains, and ahb_sub_hreadyout recovers.
#
# ISOLATION: the shared tidelink/src/rtl/tidelink_top.sv is NEVER compiled. A
# build shim (shim_orig.sv / shim_fix.sv) `include`s a LOCAL copy by absolute
# path; the base flist's v2_tidelink_top.sv shim line is sed-swapped for ours.
#
#   make control   # unpatched copy  -> write WEDGES (no recovery)  [the bug]
#   make fix       # patched copy    -> write RECOVERS + double-accept edge case
#   make both      # control + fix
#
# NOTE: the aggregate target is `both`, NOT `all`. cocotb's Makefile.sim defines
# `all: sim` as the default goal; a user `all:` here would MERGE into it
# (`all: sim control fix`), so every no-target `$(MAKE)` the control/fix recipes
# issue would recurse into control/fix. Keeping our own name avoids that.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
# CMSDK_FPGA_SRAM_V: canonical (read-only) ARM BRAM model, matching tidelink/set_env.sh.
export CMSDK_FPGA_SRAM_V ?= $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v

# My tb harness (copy of the recovery tb_top + a guarded wedge injector).
VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/err_inject.sv

TOPLEVEL = tb_top
MODULE  ?= test_tl042_awwedge

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# ---- DUT flist: base V2 flist with the tidelink_top shim swapped for OURS -----
BASE_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
SHIM        ?= shim_fix.sv
LOCAL_FLIST := $(CURDIR)/_gen_$(basename $(notdir $(SHIM))).flist
# Regenerate ONLY when content changes, so an unchanged flist keeps its mtime and
# does not needlessly re-trigger the VCS compile (CUSTOM_COMPILE_DEPS below).
_gen := $(shell _t=$$(mktemp); sed -E 's@.*v2shims/v2_tidelink_top\.sv@$(CURDIR)/$(SHIM)@' $(BASE_FLIST) > $$_t; \
                if cmp -s $$_t $(LOCAL_FLIST) 2>/dev/null; then rm -f $$_t; else mv $$_t $(LOCAL_FLIST); fi)
COMPILE_ARGS += -f $(LOCAL_FLIST)

# Same tb config the recovery suite compiles with.
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
# Enable the prototype wedge injector in the tb copy.
COMPILE_ARGS += +define+TB042_WEDGE_HOOK
# Short stall timeout so the wedge trips in ~2^STALL_LOG2 hclk (sim-able window).
STALL_LOG2  ?= 10
COMPILE_ARGS += +define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=$(STALL_LOG2)
COMPILE_ARGS += $(EXTRA_DEFINES)

SIM_BUILD ?= sim_build_fix

include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(BASE_FLIST) $(LOCAL_FLIST) $(call flist_srcs,$(LOCAL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: control fix both clean_builds

# CONTROL — unpatched copy: the write must WEDGE (hreadyout stuck 0).
control:
	rm -rf $(CURDIR)/sim_build_ctrl
	$(MAKE) SHIM=shim_orig.sv SIM_BUILD=sim_build_ctrl \
	        MODULE=test_tl042_awwedge \
	        TESTCASE=test_control_write_wedges_no_recovery

# FIX — patched copy: recovery + double-accept edge case (own fresh sim each).
fix:
	rm -rf $(CURDIR)/sim_build_fix
	$(MAKE) SHIM=shim_fix.sv SIM_BUILD=sim_build_fix \
	        MODULE=test_tl042_awwedge \
	        TESTCASE=test_fix_write_recovers
	$(MAKE) SHIM=shim_fix.sv SIM_BUILD=sim_build_fix \
	        MODULE=test_tl042_awwedge \
	        TESTCASE=test_fix_double_accept_masked

both: control fix

clean_builds:
	rm -rf $(CURDIR)/sim_build_ctrl $(CURDIR)/sim_build_fix $(CURDIR)/_gen_*.flist

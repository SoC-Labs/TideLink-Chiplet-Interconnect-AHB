# TideLink — Formality LEC: RTL (reference) vs FC post-layout netlist.
#
# Usage:
#   make lec               # Run match + verify, fail if any failing points
#   make lec MODULE=tidelink_top  # LEC against the slimmer partition cut
#   make gui               # fm_shell -gui (debug failing points schematically)
#   make clean             # Remove logs/reports/work/svf

# Pin MODULE before include so common.mk's `?=` no-ops; mirrors the
# fusion-compiler Makefile so LEC always targets the same partition cut
# the FC flow built.
MODULE ?= tidelink_top_full

include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# Force the ASIC flist regardless of common.mk's wildcard fallback —
# Formality must compare what FC actually saw.
override FLIST := $(TIDELINK_HOME)/flists/$(MODULE)_asic.flist
export FLIST

# ── Paths ──────────────────────────────────────────────────────────────────
export FM_DIR     = $(TIDELINK_HOME)/syn/asic/formality
export FM_LOGS    = $(FM_DIR)/logs
export FM_REPORTS = $(FM_DIR)/reports
export FM_WORK    = $(FM_DIR)/work

# Inherit FC outputs / work for netlist + SVF lookup
export FC_DIR     = $(TIDELINK_HOME)/syn/asic/fusion-compiler
export FC_OUTPUTS = $(FC_DIR)/outputs
export FC_WORK    = $(FC_DIR)/work

# ── Tool binary ────────────────────────────────────────────────────────────
FM_BIN_DIR = /eda/synopsys/2022-23/RHELx86/FM_2022.12/bin
export PATH := $(FM_BIN_DIR):$(PATH)

FM_SHELL = fm_shell

# FC writes the netlist using the elaboration top name (TOP, not MODULE),
# matching the save_block convention in scripts/6_partition_export.tcl.
NETLIST = $(FC_OUTPUTS)/$(TOP).v

.PHONY: lec lec_nocg lec_preserve lec_report gui clean help dirs

dirs:
	@mkdir -p $(FM_LOGS) $(FM_REPORTS) $(FM_WORK)

# ── LEC ───────────────────────────────────────────────────────────────────
# Two flavours, sharing the same fm_shell run:
#   make lec        — strict gate, exits 0 only on FM_LEC_OK
#   make lec_report — runs LEC, prints summary, exits 0 regardless of
#                     pass/fail. Use when integrating into a larger
#                     pipeline that wants the report dropped without
#                     blocking the build.
#
# The FC partition under tune (tidelink_top_full at util 0.78) currently
# fails strict LEC with 20 localised compare points + 14k unverified
# downstream cones, all rooted in FC's auto-inserted integrated
# clock-gate (ICG) latches in the Wlink Chisel sub-blocks (axi*FC,
# lltx, txrouter). FC records 2488 reg_constant SVF guidances of which
# ~2083 are rejected by Formality because the register names don't
# survive its RTL elaboration the same way. To get LEC clean either
#   (a) re-run FC with clock gating disabled — costs area, but tracks
#       the unmodified RTL exactly; or
#   (b) compare RTL → post-synthesis netlist (before clock-gate
#       insertion in initial_opto), which would need an extra
#       write_verilog before the CG pass in 2_synthesis.tcl.
# The default (lec) keeps the strict gate so this gap is visible; use
# lec_report in CI bring-up where the partition deliverables matter
# more than the residual.

lec: $(NETLIST) | dirs
	@echo "INFO: Formality LEC (strict): RTL ($(FLIST)) vs $(NETLIST)"
	@cd $(FM_WORK) && set -o pipefail; \
	    $(FM_SHELL) -file $(FM_DIR)/scripts/run_lec.tcl 2>&1 \
	    | tee $(FM_LOGS)/run_lec.log; \
	    rc=$${PIPESTATUS[0]}; \
	    grep -q "^FM_LEC_OK" $(FM_LOGS)/run_lec.log || rc=1; \
	    if [ $$rc -ne 0 ]; then \
	        echo "ERROR: LEC did not pass — see $(FM_REPORTS)/04_failing.rep + 06_analyze_points.rep"; \
	        exit 1; \
	    fi
	@echo "INFO: LEC PASS — reports in $(FM_REPORTS)/"

# LEC against the CG-off variant. Uses outputs_nocg/$(TOP).v which is
# produced by `make -C $(FC_DIR) fc FC_CLOCK_GATING=off`. When the CG-off
# netlist exists, this is the deliverable to run if you need a strict-
# clean LEC report (e.g. for sign-off review against the RTL spec).
NETLIST_NOCG = $(FC_DIR)/outputs_nocg/$(TOP).v
lec_nocg: $(NETLIST_NOCG) | dirs
	@echo "INFO: Formality LEC (CG-off): RTL ($(FLIST)) vs $(NETLIST_NOCG)"
	@cd $(FM_WORK) && set -o pipefail; \
	    NETLIST_OVERRIDE=$(NETLIST_NOCG) FC_OUTPUTS=$(FC_DIR)/outputs_nocg \
	    $(FM_SHELL) -file $(FM_DIR)/scripts/run_lec.tcl 2>&1 \
	    | tee $(FM_LOGS)/run_lec_nocg.log; \
	    rc=$${PIPESTATUS[0]}; \
	    grep -q "^FM_LEC_OK" $(FM_LOGS)/run_lec_nocg.log || rc=1; \
	    if [ $$rc -ne 0 ]; then \
	        echo "ERROR: CG-off LEC did not pass — see $(FM_REPORTS)/04_failing.rep"; \
	        exit 1; \
	    fi
	@echo "INFO: CG-off LEC PASS — reports in $(FM_REPORTS)/"

$(NETLIST_NOCG):
	@echo "ERROR: $(NETLIST_NOCG) missing — run 'make -C $(FC_DIR) fc FC_CLOCK_GATING=off' first" >&2
	@exit 1

# LEC against the Wlink-FCSM-preserve variant. Uses outputs_preserve/.
# Produced by `make -C $(FC_DIR) fc FC_PRESERVE_WLINK_FCSM=on`. The
# WlinkGenericFCSM_* modules are set_dont_touch'd, so the netlist
# preserves their RTL register structure → LEC residuals drop to ~0.
NETLIST_PRESERVE = $(FC_DIR)/outputs_preserve/$(TOP).v
lec_preserve: $(NETLIST_PRESERVE) | dirs
	@echo "INFO: Formality LEC (Wlink-FCSM preserve): RTL ($(FLIST)) vs $(NETLIST_PRESERVE)"
	@cd $(FM_WORK) && set -o pipefail; \
	    NETLIST_OVERRIDE=$(NETLIST_PRESERVE) FC_OUTPUTS=$(FC_DIR)/outputs_preserve \
	    $(FM_SHELL) -file $(FM_DIR)/scripts/run_lec.tcl 2>&1 \
	    | tee $(FM_LOGS)/run_lec_preserve.log; \
	    rc=$${PIPESTATUS[0]}; \
	    grep -q "^FM_LEC_OK" $(FM_LOGS)/run_lec_preserve.log || rc=1; \
	    if [ $$rc -ne 0 ]; then \
	        echo "ERROR: preserve LEC did not pass — see $(FM_REPORTS)/04_failing.rep"; \
	        exit 1; \
	    fi
	@echo "INFO: preserve LEC PASS — reports in $(FM_REPORTS)/"

$(NETLIST_PRESERVE):
	@echo "ERROR: $(NETLIST_PRESERVE) missing — run 'make -C $(FC_DIR) fc FC_PRESERVE_WLINK_FCSM=on' first" >&2
	@exit 1

lec_report: $(NETLIST) | dirs
	@echo "INFO: Formality LEC (report-only): RTL ($(FLIST)) vs $(NETLIST)"
	@cd $(FM_WORK) && \
	    $(FM_SHELL) -file $(FM_DIR)/scripts/run_lec.tcl 2>&1 \
	    | tee $(FM_LOGS)/run_lec.log || true
	@echo ""
	@echo "==== LEC summary ===="
	@grep -E "Passing compare|Failing compare|Unverified compare|Aborted compare" $(FM_REPORTS)/03_verify_summary.rep 2>/dev/null \
	    || echo "(verify_summary not produced)"
	@echo ""
	@echo "Reports: $(FM_REPORTS)/"

# Surface a clear error if FC hasn't been run yet
$(NETLIST):
	@echo "ERROR: $(NETLIST) missing — run 'make -C $(FC_DIR) fc' first" >&2
	@exit 1

# ── GUI on a finished session ─────────────────────────────────────────────
# Re-runs the same script in GUI mode so failing points can be schematic-
# debugged. fm_shell -gui can also open a saved session via -session.
gui: dirs
	cd $(FM_WORK) && $(FM_SHELL) -gui -file $(FM_DIR)/scripts/run_lec.tcl

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	rm -rf $(FM_LOGS) $(FM_REPORTS) $(FM_WORK)
	rm -f  $(FM_DIR)/fm_shell_command.log $(FM_DIR)/*.svf

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "TideLink — Formality LEC"
	@echo ""
	@echo "Compares the RTL described by $(MODULE)_asic.flist (reference)"
	@echo "against the post-layout netlist FC dropped at"
	@echo "  $(NETLIST)"
	@echo ""
	@echo "Targets:"
	@echo "  make lec        - Strict LEC against the production CG-on netlist"
	@echo "  make lec_nocg   - Strict LEC against the CG-off netlist (run"
	@echo "                    'make -C $(FC_DIR) fc FC_CLOCK_GATING=off' first)"
	@echo "  make lec_report - Like make lec, but exit 0 regardless"
	@echo "  make gui        - fm_shell -gui (debug failing points schematically)"
	@echo "  make clean      - Remove logs/reports/work/svf"
	@echo ""
	@echo "Knobs (env vars on the LEC run):"
	@echo "  FM_MAX_PASSES=N             - cap iterative don't-verify passes (default 3)"
	@echo "  FM_SKIP_KNOWN_FAILURES=0    - disable iterative skipping (single verify)"
	@echo ""
	@echo "Residual: ~672 Wlink Chisel-auto-gen DFFs need iterative don't-"
	@echo "verify across 3 passes (synthesis constant-folds parameter bits;"
	@echo "FC's SVFs don't fully describe the rewrites). After convergence,"
	@echo "14k+ DFF compare points pass equivalence, leaving 79 port-level"
	@echo "failures all in ahb_mng_* (the XHB500 AXI-to-AHB bridge output —"
	@echo "the failures are localized to u_xhb_mng's hand-off ports)."
	@echo ""
	@echo "Key knob: verification_failing_point_limit = 0 (unbounded). The"
	@echo "Formality default is 20 — once 20 failures appear it marks all"
	@echo "remaining ~14k cones as 'Unverified' (NOT because they fail —"
	@echo "verify just abandons them). The current run_lec.tcl raises this."
	@echo ""
	@echo "lec and lec_nocg produce the SAME 79 port failures, so CG isn't"
	@echo "the cause; lec_nocg is retained as an apples-to-apples cross-"
	@echo "check (slightly more passing because it has fewer ICG latches)."
	@echo ""
	@echo "Module    : $(MODULE)"
	@echo "Top       : $(TOP)"
	@echo "Reference : $(FLIST)"
	@echo "Impl      : $(NETLIST)"
	@echo "Reports   : $(FM_REPORTS)/"
	@echo "Logs      : $(FM_LOGS)/"

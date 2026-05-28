# =============================================================================
# TideLink — DFT flow Makefile (SCAFFOLD)
#
# Entry points to the scan-insertion, MBIST-insertion, and ATPG flows.
# All real tool invocations are gated behind licence checks (see the .tcl
# wrappers); without licences these targets print a clear
# "license required" message and exit non-zero.
#
# See docs/DFT_PLAN_2026_05_28.md for the strategy and closure tasks.
# =============================================================================

TIDELINK_HOME ?= $(realpath $(CURDIR)/../../..)
OUT_DIR       ?= $(CURDIR)/out

# DESIGN must default to the test-mode wrapper. We use `override` so a
# stale shell `DESIGN` env var (common in SoC Labs login envs) does not
# silently break the flow. Override on the command line with
# `make DESIGN=foo` to change it.
ifeq ($(origin DESIGN),environment)
override DESIGN := tidelink_dft_wrapper
else
DESIGN        ?= tidelink_dft_wrapper
endif

# Tool selectors (override on the command line, e.g. `make insert_scan DFT_TOOL=tessent`)
DFT_TOOL      ?= testmax
MBIST_FLOW    ?= tessent
SCAN_STYLE    ?= muxd
SCAN_CHAINS   ?= 8

# Synth netlist input (caller supplies)
NETLIST       ?=

# Tool binaries — overridden by environment or wrapper script
DC_SHELL      ?= dc_shell
TESSENT       ?= tessent
SPYGLASS      ?= spyglass

# Export so the Tcl scripts see them
export TIDELINK_HOME OUT_DIR DESIGN DFT_TOOL MBIST_FLOW SCAN_STYLE SCAN_CHAINS NETLIST

# -----------------------------------------------------------------------------

.PHONY: help
help:
	@echo ""
	@echo "TideLink DFT flow — SCAFFOLD"
	@echo ""
	@echo "Targets:"
	@echo "  insert_scan       Run scan-insertion (DFT_TOOL=$(DFT_TOOL))"
	@echo "  insert_mbist      Wire MBIST controller (MBIST_FLOW=$(MBIST_FLOW))"
	@echo "  run_atpg          Run ATPG (LICENCE-GATED placeholder)"
	@echo "  drc_only          Run SpyGlass-DFT DRC without insertion"
	@echo "  show              Print current configuration"
	@echo "  clean             Remove $(OUT_DIR)"
	@echo ""
	@echo "Configuration (override on command line):"
	@echo "  DFT_TOOL    = $(DFT_TOOL)    [testmax|tessent|spyglass]"
	@echo "  MBIST_FLOW  = $(MBIST_FLOW)  [tessent|custom]"
	@echo "  SCAN_STYLE  = $(SCAN_STYLE)  [muxd|lssd]"
	@echo "  SCAN_CHAINS = $(SCAN_CHAINS)"
	@echo "  DESIGN      = $(DESIGN)"
	@echo "  NETLIST     = $(NETLIST)     (required for real runs)"
	@echo "  OUT_DIR     = $(OUT_DIR)"
	@echo ""
	@echo "Status: SCAFFOLD ONLY — see docs/DFT_PLAN_2026_05_28.md §7."
	@echo ""

.PHONY: show
show:
	@echo "DFT_TOOL=$(DFT_TOOL) MBIST_FLOW=$(MBIST_FLOW) SCAN_STYLE=$(SCAN_STYLE)"
	@echo "SCAN_CHAINS=$(SCAN_CHAINS) DESIGN=$(DESIGN)"
	@echo "OUT_DIR=$(OUT_DIR)"
	@echo "NETLIST=$(NETLIST)"

$(OUT_DIR):
	@mkdir -p $@

# -----------------------------------------------------------------------------
# Scan insertion
# -----------------------------------------------------------------------------

.PHONY: insert_scan
insert_scan: | $(OUT_DIR)
	@echo "==> insert_scan: tool=$(DFT_TOOL) style=$(SCAN_STYLE) chains=$(SCAN_CHAINS)"
	@if [ -z "$$SNPSLMD_LICENSE_FILE" ] && [ -z "$$SYNOPSYS_LICENSE_FILE" ] \
	    && [ "$(DFT_TOOL)" = "testmax" ]; then \
	    echo "INFO: TestMAX licence env not set — running in scaffold mode."; \
	fi
	@if [ "$(DFT_TOOL)" = "testmax" ]; then \
	    $(DC_SHELL) -no_gui -f $(CURDIR)/insert_scan.tcl 2>&1 | tee $(OUT_DIR)/insert_scan.log; \
	elif [ "$(DFT_TOOL)" = "tessent" ]; then \
	    $(TESSENT) -shell -dofile $(CURDIR)/insert_scan.tcl 2>&1 | tee $(OUT_DIR)/insert_scan.log; \
	elif [ "$(DFT_TOOL)" = "spyglass" ]; then \
	    echo "ERROR: spyglass mode does not insert — use 'make drc_only'."; \
	    exit 1; \
	else \
	    echo "ERROR: unknown DFT_TOOL=$(DFT_TOOL)"; exit 1; \
	fi

# -----------------------------------------------------------------------------
# MBIST insertion
# -----------------------------------------------------------------------------

.PHONY: insert_mbist
insert_mbist: | $(OUT_DIR)
	@echo "==> insert_mbist: flow=$(MBIST_FLOW)"
	@if [ "$(MBIST_FLOW)" = "tessent" ] \
	    && [ -z "$$MGLS_LICENSE_FILE" ] && [ -z "$$LM_LICENSE_FILE" ]; then \
	    echo "INFO: Mentor Tessent licence env not set — running in scaffold mode."; \
	fi
	@if [ "$(MBIST_FLOW)" = "tessent" ]; then \
	    $(TESSENT) -shell -dofile $(CURDIR)/insert_mbist.tcl 2>&1 | tee $(OUT_DIR)/insert_mbist.log; \
	elif [ "$(MBIST_FLOW)" = "custom" ]; then \
	    echo "WARN: custom-MBIST RTL not yet authored — see insert_mbist.tcl TODO list."; \
	    tclsh $(CURDIR)/insert_mbist.tcl 2>&1 | tee $(OUT_DIR)/insert_mbist.log; \
	else \
	    echo "ERROR: unknown MBIST_FLOW=$(MBIST_FLOW)"; exit 1; \
	fi

# -----------------------------------------------------------------------------
# ATPG (licence-gated placeholder)
# -----------------------------------------------------------------------------

.PHONY: run_atpg
run_atpg: | $(OUT_DIR)
	@echo "==> run_atpg: PLACEHOLDER"
	@if [ -z "$$SNPSLMD_LICENSE_FILE" ] && [ -z "$$SYNOPSYS_LICENSE_FILE" ] \
	    && [ -z "$$MGLS_LICENSE_FILE" ]; then \
	    echo ""; \
	    echo "ERROR: ATPG licence required (TestMAX-DSM, Tessent FastScan, or"; \
	    echo "       Cadence Modus). None detected in environment."; \
	    echo ""; \
	    echo "       Action: configure SNPSLMD_LICENSE_FILE or MGLS_LICENSE_FILE,"; \
	    echo "       then run 'make run_atpg'."; \
	    echo ""; \
	    echo "       See docs/DFT_PLAN_2026_05_28.md §7.4 for the licence list."; \
	    exit 1; \
	fi
	@echo "INFO: ATPG closure flow not yet authored — see DFT_PLAN §7 follow-on tasks."
	@exit 1

# -----------------------------------------------------------------------------
# DRC-only (SpyGlass DFT)
# -----------------------------------------------------------------------------

.PHONY: drc_only
drc_only: | $(OUT_DIR)
	@echo "==> drc_only: SpyGlass DFT pre-scan DRC"
	@if [ -z "$$SPYGLASS_HOME" ]; then \
	    echo "ERROR: SPYGLASS_HOME not set — cannot run SpyGlass DFT DRC."; \
	    echo "       (SpyGlass for CDC is already in CI — see .gitlab-ci.yml)"; \
	    exit 1; \
	fi
	@echo "INFO: spyglass DRC scaffold — see insert_scan.tcl stage 3 + DFT_PLAN §6.2"
	@exit 1

# -----------------------------------------------------------------------------

.PHONY: clean
clean:
	rm -rf $(OUT_DIR)

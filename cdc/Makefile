export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)
export CMSDK_DIR     ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# ── SpyGlass tool ────────────────────────────────────────────────────────────
SPYGLASS_HOME ?= /eda/synopsys/2022-23/RHELx86/SPYGLASS_2022.06-SP2/SPYGLASS_HOME
SPYGLASS      := $(SPYGLASS_HOME)/bin/spyglass

# ── Target module (override: make cdc MODULE=tidelink_fifo) ──────────────────
MODULE ?= tidelink_top

# ── Module-to-top mapping (reuse lint convention) ────────────────────────────
TOP_tidelink      = tidelink_fifo
TOP_tidelink_fifo = tidelink_fifo_mem
TOP ?= $(or $(TOP_$(MODULE)),$(MODULE))

# ── Paths ────────────────────────────────────────────────────────────────────
export FLIST  := $(TIDELINK_HOME)/flist/$(MODULE).flist
export SGDC   := $(TIDELINK_HOME)/cdc/tidelink_top.sgdc
export SWL    := $(TIDELINK_HOME)/cdc/waiver.swl
export SG_TOP := $(TOP)
PRJ           := $(TIDELINK_HOME)/cdc/tidelink_top.prj

# SpyGlass output directory
SG_WORK := $(MODULE)_spyglass
RPTDIR  := $(SG_WORK)/cdc_verify/spyglass_reports

# Report files
RPT_SUMMARY := $(MODULE)_cdc_summary.rpt
RPT_DETAIL  := $(MODULE)_cdc_detail.rpt

# ── SpyGlass flags ───────────────────────────────────────────────────────────
SG_FLAGS := -batch \
            -project $(PRJ) \
            -goals "cdc/cdc_verify"

.PHONY: cdc cdc-report clean help

# ── Default target: run CDC analysis ─────────────────────────────────────────
cdc:
	@echo "══════════════════════════════════════════════════════════"
	@echo "  SpyGlass CDC: $(MODULE)  (top = $(TOP))"
	@echo "══════════════════════════════════════════════════════════"
	$(SPYGLASS) $(SG_FLAGS)
	@echo ""
	@echo "CDC analysis complete. Results in $(RPTDIR)/"
	@$(MAKE) --no-print-directory cdc-report

# ── Extract summary report ───────────────────────────────────────────────────
cdc-report:
	@{ \
	echo "══════════════════════════════════════════════════════════"; \
	echo "  SpyGlass CDC Report: $(MODULE)"; \
	echo "══════════════════════════════════════════════════════════"; \
	echo ""; \
	echo "── Violation Summary ─────────────────────────────────────"; \
	if ls $(RPTDIR)/*summary* 1>/dev/null 2>&1; then \
		cat $(RPTDIR)/*summary*; \
	elif ls $(RPTDIR)/*.rpt 1>/dev/null 2>&1; then \
		grep -h -E '(Error|Warning|Info|Total)' $(RPTDIR)/*.rpt 2>/dev/null || echo "  (no summary lines found)"; \
	else \
		echo "  (no report files found — run 'make cdc' first)"; \
	fi; \
	echo ""; \
	echo "── CDC Crossings (TideLink RTL) ──────────────────────────"; \
	if ls $(RPTDIR)/*.rpt 1>/dev/null 2>&1; then \
		grep -h 'tidelink_' $(RPTDIR)/*.rpt 2>/dev/null | head -50 || echo "  (none found)"; \
	else \
		echo "  (no report files)"; \
	fi; \
	echo ""; \
	} | tee $(RPT_SUMMARY)
	@echo "Report saved to: $(RPT_SUMMARY)"

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	rm -rf *_spyglass *_cdc_summary.rpt *_cdc_detail.rpt \
	       spyglass_output spyglass.log sg_shell.log

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo "TideLink SpyGlass CDC Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make cdc                       - Run CDC analysis (default: $(MODULE))"
	@echo "  make cdc MODULE=<name>         - Run CDC for a specific module"
	@echo "  make cdc-report                - Re-extract summary from last run"
	@echo "  make clean                     - Remove SpyGlass work directories"
	@echo ""
	@echo "Prerequisites:"
	@echo "  SPYGLASS_HOME: $(SPYGLASS_HOME)"
	@echo "  CMSDK_DIR:     $(CMSDK_DIR)"
	@echo ""
	@echo "Examples:"
	@echo "  make cdc                       - CDC lint tidelink_top"
	@echo "  make cdc MODULE=tidelink_fifo  - CDC lint FIFO subsystem only"

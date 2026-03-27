export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)
export CMSDK_DIR    ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0

# ── Target module (override on command line: make MODULE=tidelink_ahb_returner) ──
MODULE ?= tidelink

# ── All lintable modules ─────────────────────────────────────────
# Standalone modules (no external IP dependencies)
STANDALONE_MODULES = tidelink_ahb_fifo_ctrl tidelink_ahb_returner

# Modules requiring CMSDK IP (cmsdk_ahb_to_sram, cmsdk_fpga_sram)
CMSDK_MODULES = tidelink_ahb tidelink

# ── Paths ─────────────────────────────────────────────────────────
FLIST   = $(TIDELINK_HOME)/flist/$(MODULE).flist
LOGFILE = $(MODULE)_hal.log
XMLFILE = $(MODULE)_hal.xml
RPTFILE = $(MODULE)_hal_report.txt

# ── HAL flags ─────────────────────────────────────────────────────
HAL       = hal
HAL_FLAGS = -64bit \
            -sv \
            -top $(MODULE) \
            -check ALL_RTL \
            -logfile $(LOGFILE) \
            -xmlfile $(XMLFILE) \
            -messages \
            -stats \
            -lintpragma

# Add any waivers from the rule file
HAL_FLAGS += -file $(TIDELINK_HOME)/lint/hal.tcl

.PHONY: lint lint-synth lint-all lint-standalone lint-each report gui clean help

# Default target: RTL lint checks for a single module
lint:
	$(HAL) $(HAL_FLAGS) -f $(FLIST)

# Synthesizability-focused checks only
lint-synth:
	$(HAL) $(HAL_FLAGS) -nohalcheck -f $(FLIST)

# All checks (RTL + structural + synthesizability) for a single module
lint-all:
	$(HAL) $(HAL_FLAGS) -check ALL -f $(FLIST)

# Lint all standalone modules (no CMSDK dependency)
lint-standalone:
	@for mod in $(STANDALONE_MODULES); do \
		echo "══════════════════════════════════════════════════════════"; \
		echo "  Linting: $$mod"; \
		echo "══════════════════════════════════════════════════════════"; \
		$(MAKE) lint MODULE=$$mod || exit 1; \
	done

# Lint every module individually (standalone + CMSDK-dependent)
lint-each:
	@for mod in $(STANDALONE_MODULES) $(CMSDK_MODULES); do \
		echo "══════════════════════════════════════════════════════════"; \
		echo "  Linting: $$mod"; \
		echo "══════════════════════════════════════════════════════════"; \
		$(MAKE) lint MODULE=$$mod || exit 1; \
	done

# Generate a warnings/errors report from the lint log
report: $(LOGFILE)
	@{ \
	echo "══════════════════════════════════════════════════════════"; \
	echo "  HAL Lint Report: $(MODULE)"; \
	echo "  Source: $(LOGFILE)"; \
	echo "══════════════════════════════════════════════════════════"; \
	echo ""; \
	echo "── Summary ─────────────────────────────────────────────"; \
	grep -E 'Total (errors|warnings)' $(LOGFILE) || true; \
	echo ""; \
	echo "── Errors (TideLink RTL) ─────────────────────────────────"; \
	grep '\*E' $(LOGFILE) | grep -v 'BP210' || echo "  (none)"; \
	echo ""; \
	echo "── Warnings (TideLink RTL) ───────────────────────────────"; \
	grep '\*W' $(LOGFILE) | grep -v 'BP210' | grep -v 'xmelab' || echo "  (none)"; \
	echo ""; \
	echo "── Warning Breakdown (TideLink RTL) ──────────────────────"; \
	grep '\*W' $(LOGFILE) | grep -v 'BP210' | grep -v 'xmelab' \
	  | sed 's/.*\*W,\([A-Z]*\).*/\1/' | sort | uniq -c | sort -rn || true; \
	echo ""; \
	echo "── Errors (CMSDK IP) ─────────────────────────────────────"; \
	grep '\*E' $(LOGFILE) | grep 'BP210' || echo "  (none)"; \
	echo ""; \
	echo "── Warnings (CMSDK IP) ───────────────────────────────────"; \
	cmsdk_count=$$(grep '\*W' $(LOGFILE) | grep -c 'BP210' 2>/dev/null || echo 0); \
	echo "  $$cmsdk_count warnings (suppressed — third-party IP)"; \
	echo ""; \
	} | tee $(RPTFILE)
	@echo "Report saved to: $(RPTFILE)"

# Open results in Cadence report browser
gui:
	$(HAL) $(HAL_FLAGS) -gui -f $(FLIST)

clean:
	rm -rf *_hal.log *_hal.xml *_hal_report.txt hal.design_facts hal.log INCA_libs xcelium.d *.log.bak .hal-irun.history

help:
	@echo "TideLink HAL Lint Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make lint                      - Lint single module (default: $(MODULE))"
	@echo "  make lint MODULE=<name>        - Lint a specific module"
	@echo "  make lint-synth                - Synthesizability checks only"
	@echo "  make lint-all                  - All checks (RTL + structural + synth)"
	@echo "  make lint-standalone           - Lint all standalone modules"
	@echo "  make lint-each                 - Lint every module (needs CMSDK for some)"
	@echo "  make report                    - Extract warnings/errors from lint log"
	@echo "  make gui                       - Open report browser"
	@echo "  make clean                     - Remove generated files"
	@echo ""
	@echo "Standalone modules (no external deps):"
	@echo "  $(STANDALONE_MODULES)"
	@echo ""
	@echo "CMSDK-dependent modules:"
	@echo "  $(CMSDK_MODULES)"
	@echo ""
	@echo "CMSDK_DIR: $(CMSDK_DIR)"
	@echo ""
	@echo "Examples:"
	@echo "  make lint MODULE=tidelink_ahb_returner"
	@echo "  make lint-standalone"
	@echo "  make lint report               - Lint then show warnings/errors"

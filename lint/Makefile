export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# ── Target module (override on command line: make MODULE=tidelink_sram_manager) ──
MODULE ?= tidelink_ahb_to_reg

# ── Paths ─────────────────────────────────────────────────────────
FLIST   = $(TIDELINK_HOME)/flist/$(MODULE).flist
LOGFILE = $(MODULE)_hal.log
XMLFILE = $(MODULE)_hal.xml

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

.PHONY: lint lint-synth lint-all gui clean help

# Default target: RTL lint checks
lint:
	$(HAL) $(HAL_FLAGS) -f $(FLIST)

# Synthesizability-focused checks only
lint-synth:
	$(HAL) $(HAL_FLAGS) -nohalcheck -f $(FLIST)

# All checks (RTL + structural + synthesizability)
lint-all:
	$(HAL) $(HAL_FLAGS) -check ALL -f $(FLIST)

# Open results in Cadence report browser
gui:
	$(HAL) $(HAL_FLAGS) -gui -f $(FLIST)

clean:
	rm -rf *_hal.log *_hal.xml hal.design_facts hal.log INCA_libs xcelium.d *.log.bak

help:
	@echo "TideLink HAL Lint Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make lint              - Run RTL lint checks (default)"
	@echo "  make lint-synth        - Run synthesizability checks only"
	@echo "  make lint-all          - Run all checks (RTL + structural + synth)"
	@echo "  make gui               - Run lint and open report browser"
	@echo "  make clean             - Remove generated files"
	@echo ""
	@echo "Override module:"
	@echo "  make MODULE=tidelink_sram_manager lint"

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/..)
export CMSDK_DIR    ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# cmsdk_fpga_sram.v is missing from the Corstone-101 BP210 install used in CI
# (/research/AAA/.../Corstone-101/BP210-r1p1-00rel0/.../models/memories/), so
# fall back to the standalone BP210 install when needed. Override with
# CMSDK_FPGA_SRAM_V=<path> if your install differs.
CMSDK_FPGA_SRAM_V ?= $(if $(wildcard $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v),\
                       $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v,\
                       $(ARM_IP_LIBRARY_PATH)/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v)
export CMSDK_FPGA_SRAM_V

# ── Target module (override on command line: make MODULE=tidelink_ahb_returner) ──
MODULE ?= tidelink

# ── All lintable modules ─────────────────────────────────────────
# Standalone modules — no CMSDK; deps submodule (axi-chiplet-controller)
# is always present via git submodule, so apb4_if-dependent modules live here.
STANDALONE_MODULES = \
  tidelink_fifo_ctrl \
  tidelink_returner \
  tidelink_apb_regs \
  tidelink_fc_adapter \
  tidelink_apb_addr_ctrl \
  tidelink_clkfreq_check \
  tidelink_idelay_rx \
  tidelink_lane_checker \
  tidelink_mul_iter \
  tidelink_perf \
  tidelink_phc_cdc \
  tidelink_phy_align_calibrator \
  tidelink_ptp \
  tidelink_ptp_servo \
  tidelink_rxclk_buf \
  tidelink_addr_translation \
  tl_addr_trans_cam \
  tl_addr_trans_regs \
  tidelink_addr_translator

# Modules requiring CMSDK IP (cmsdk_ahb_to_sram / cmsdk_ahb_to_apb)
#
# NOTE (2026-05-29): tidelink_ahb re-enabled. The legacy src/rtl/tidelink.sv
# wrapper was modernised to instantiate the active tidelink_fifo (which now
# subsumes the FIFO memory, APB register block and Returner) and tie off the
# new pass-through ports (PTP / servo / mbox / ctrl / perf / fc_wr / puf).
# tidelink.sv is now added to flist/tidelink_ahb.flist so HAL can resolve
# the u_tidelink instance inside tidelink_ahb. HAL: 0 errors.
#
# NOTE (2026-05-29): tidelink_fifo_ahb re-enabled. The wrapper had 4 UNCONI
# errors on inputs added to tidelink_fifo after the wrapper was last touched
# (ctrl_reg_rdata, perf_reg_rdata, puf_addr, puf_req). Those peers live in
# tidelink_top (regfile / PUF), not in this AHB-only wrapper, so they are
# tied to 0 at the u_tidelink_fifo instance. A dedicated flist now lives at
# flist/tidelink_fifo_ahb.flist. HAL: 0 errors.
CMSDK_MODULES = tidelink_fifo tidelink tidelink_ahb tidelink_fifo_ahb

# ── Module-to-top mapping ────────────────────────────────────────
# Flist basenames and SV module names diverge after the FIFO rename.
# MODULE selects the flist; TOP selects the elaboration top.
TOP_tidelink          = tidelink_fifo
TOP_tidelink_fifo     = tidelink_fifo_mem
TOP ?= $(or $(TOP_$(MODULE)),$(MODULE))

# ── Paths ─────────────────────────────────────────────────────────
FLIST   = $(TIDELINK_HOME)/flist/$(MODULE).flist
LOGFILE = $(MODULE)_hal.log
XMLFILE = $(MODULE)_hal.xml
RPTFILE = $(MODULE)_hal_report.txt

# ── HAL flags ─────────────────────────────────────────────────────
HAL       = hal
HAL_FLAGS = -64bit \
            -sv \
            -top $(TOP) \
            -check ALL_RTL \
            -logfile $(LOGFILE) \
            -xmlfile $(XMLFILE) \
            -messages \
            -stats \
            -lintpragma

# Add any waivers from the rule file
HAL_FLAGS += -file $(TIDELINK_HOME)/lint/hal.tcl

# ── Per-module extra include directories ─────────────────────────
# HAL's `-f <flist>` does NOT honour `+incdir+` directives embedded in the
# flist (verified locally 2026-05-28 against HAL bundled with Xcelium 23.x).
# Any module whose RTL contains `\`include "..."` against a non-default
# search path needs an explicit -incdir on the HAL command line.
#
# tidelink_lane_checker (sourced from the tidelink-gpio-phy submodule)
# `includes tidelink_training_patterns.svh from the same directory; add the
# submodule's rtl/ to the HAL include path so the parse can find it.
EXTRA_INCDIRS_tidelink_lane_checker = $(TIDELINK_HOME)/deps/tidelink-gpio-phy/rtl
EXTRA_INCDIRS = $(EXTRA_INCDIRS_$(MODULE))
# Translate to HAL syntax: one `-incdir <dir>` per directory.
HAL_INCDIR_FLAGS = $(foreach d,$(EXTRA_INCDIRS),-incdir $(d))

.PHONY: lint lint-synth lint-all lint-standalone lint-each report gui clean help

# Default target: RTL lint checks for a single module
lint:
	$(HAL) $(HAL_FLAGS) $(HAL_INCDIR_FLAGS) -f $(FLIST)

# Synthesizability-focused checks only
lint-synth:
	$(HAL) $(HAL_FLAGS) $(HAL_INCDIR_FLAGS) -nohalcheck -f $(FLIST)

# All checks (RTL + structural + synthesizability) for a single module
lint-all:
	$(HAL) $(HAL_FLAGS) $(HAL_INCDIR_FLAGS) -check ALL -f $(FLIST)

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
	@echo "Standalone modules (no CMSDK; deps submodule required for apb4_if):"
	@printf '  %s\n' $(STANDALONE_MODULES)
	@echo ""
	@echo "CMSDK-dependent modules:"
	@printf '  %s\n' $(CMSDK_MODULES)
	@echo ""
	@echo "CMSDK_DIR: $(CMSDK_DIR)"
	@echo ""
	@echo "Examples:"
	@echo "  make lint MODULE=tidelink_returner"
	@echo "  make lint-standalone"
	@echo "  make lint report               - Lint then show warnings/errors"

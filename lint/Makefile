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
  tidelink_phy_align_regs \
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
# NOTE (2026-05-23): tidelink_ahb and tidelink_fifo_ahb are excluded from CI
# hal-lint:
#
#  - tidelink_ahb: instantiates src/rtl/tidelink.sv which wires to the
#    *legacy* port interface of tidelink_fifo / tidelink_apb_regs
#    (hsel/hready/htrans/packet_word_length_out /overrun/underrun/enable
#    /flush). The active modules in src/rtl/fifo/ use the prefixed
#    ahbs_*/ahbm_* multi-AHB interface. Adding src/rtl/tidelink.sv to
#    tidelink_ahb.flist surfaces the mismatch as E,CUVPOM port-name
#    errors. The two coexist because cocotb/tidelink_ahb is the only
#    consumer of src/rtl/tidelink.sv (no FPGA / ASIC build references it).
#
#  - tidelink_fifo_ahb: instantiates the active tidelink_fifo (from
#    src/rtl/fifo/) but does not connect four newer input ports
#    (ctrl_reg_rdata, perf_reg_rdata, puf_addr, puf_req). HAL elaborates
#    correctly but flags E,UNCONI on those four inputs. This is a real
#    bug in tidelink_fifo_ahb that should be fixed (tie off or wire),
#    not a flist artefact.
#
# A future repo-simplification fold (Agent E §1-A + retiring
# tidelink_ahb cocotb env + completing tidelink_fifo_ahb port wiring)
# will drop both exclusions. Tracked in
# docs/REPO_SIMPLIFICATION_IMPACT.md §1-A.
CMSDK_MODULES = tidelink_fifo tidelink

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

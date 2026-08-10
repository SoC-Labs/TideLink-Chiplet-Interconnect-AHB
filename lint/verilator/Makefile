# =============================================================================
# lint/verilator/Makefile — Verilator strict-lint gate for TideLink
# =============================================================================
# Adds a third lint gate alongside HAL (Cadence Xcelium) at lint/ and the
# Python SV anti-pattern lint at cocotb/lint/sv_anti_pattern_lint.py.
#
# Catches synth-class defects that have bit us in silicon:
#   • WIDTH       — width-mismatch (the calibrator ULRELE / perf 33-vs-32-bit class)
#   • CASEINCOMPLETE / CASEOVERLAP — incomplete or overlapping case arms
#   • IMPLICIT    — implicit net declarations (typos in port names)
#   • UNDRIVEN    — undriven signals (logic that synth will optimise to const)
#   • UNUSED      — dangling outputs (often a sign of unfinished hookup)
#   • PINMISSING  — instance pin omitted (the silent-broken case)
#   • ALWCOMBORDER — always_comb evaluation-order hazards (latch-precursor)
#   • CMPCONST    — constant-compare (always-true / always-false predicate)
#
# NOTE on Verilator 4.028 (the version installed on this host):
#   This Verilator predates the explicit LATCH and MULTIDRIVEN warning classes
#   (added in Verilator 4.2xx). Latch detection here is implicit via
#   ALWCOMBORDER + UNDRIVEN + WIDTH; multi-driver via BLKANDNBLK. When the host
#   is upgraded to Verilator >=5.x, add -Wwarn-LATCH -Wwarn-MULTIDRIVEN to
#   VERILATOR_STRICT below.
#
# Usage:
#   make -C lint/verilator lint-all          # lint every targeted module
#   make -C lint/verilator lint-calibrator   # lint just the calibrator
#   make -C lint/verilator clean             # remove logs
#
# Each per-module target writes its findings to <module>.log in this dir, and
# returns non-zero if any warning is raised (because -Werror is in flags).
# =============================================================================

# ── Paths (resolved without sourcing set_env.sh) ─────────────────────────────
TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR       := $(TIDELINK_HOME)/src/rtl
FIFO_DIR      := $(RTL_DIR)/fifo
TOP_DIR       := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/top

# ── Common Verilator flags ───────────────────────────────────────────────────
# -Wall enables the lint+style warning set. -Werror promotes them to non-zero
# exit (otherwise --lint-only always returns 0). -Wno-DECLFILENAME silences
# the "module name should match filename" style nit — TideLink intentionally
# uses sub-module-per-file packaging that violates this.
VERILATOR        := verilator
# -Wno-fatal stops Verilator from exiting non-zero on every warning; the
# strict-class -Werror-* flags below then re-promote ONLY the synth-class
# warnings to fatal. This keeps UNUSED / UNDRIVEN visible-but-non-blocking.
VERILATOR_FLAGS  := --lint-only -sv -Wall -Wno-fatal -Wno-DECLFILENAME -DSYNTHESIS

# Strict warning classes — promoted to errors. Each one corresponds to a
# silicon-class defect we've hit or could plausibly hit:
VERILATOR_STRICT := \
    -Werror-CASEINCOMPLETE -Werror-CASEOVERLAP \
    -Werror-WIDTH -Werror-IMPLICIT \
    -Werror-PINMISSING -Werror-ALWCOMBORDER \
    -Werror-CMPCONST

# UNUSED / UNDRIVEN are noisy on APB register banks (paddr top bits etc).
# We keep them as WARNINGS (not errors) so reviewers see them in the log but
# CI doesn't block on every legitimate APB-spec dangling bit. Promote them
# per-module by setting STRICT_UNUSED=1 on the make command line.
ifeq ($(STRICT_UNUSED),1)
  VERILATOR_STRICT += -Werror-UNUSED -Werror-UNDRIVEN
endif

# Default include dirs reused across most targets
INC_RTL  := -I$(RTL_DIR) -I$(FIFO_DIR)
INC_TOP  := -I$(TOP_DIR) -I$(RTL_DIR)

# Helper: run a per-module lint and tee output to <name>.log
# $(1) = top module, $(2) = source file, $(3) = extra flags
define VERILATE
	@echo "===== lint: $(1) ====="
	@$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_STRICT) $(3) \
	  --top-module $(1) $(2) 2>&1 | tee $(1).log; \
	  exit $${PIPESTATUS[0]}
endef

# ─────────────────────────────────────────────────────────────────────────────
# Per-module strict-lint targets
# ─────────────────────────────────────────────────────────────────────────────

# Calibrator — HAL flagged HASUPC (unique-case) and ULRELE (17v32-bit relop)
# on a prior revision. Today's restored simple FSM is clean under -Wall.
lint-calibrator:
	$(call VERILATE,tidelink_phy_align_calibrator,\
	  $(RTL_DIR)/tidelink_phy_align_calibrator.sv,\
	  $(INC_RTL))

# Per-lane checker — symbol/comma framing detector.
#
# BROKEN TARGET, left in place deliberately and REMOVED from LINT_TARGETS
# (2026-08-09). $(RTL_DIR)/tidelink_lane_checker.sv was deleted from src/rtl/
# in d043909; the module now lives at
#   deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv
# and needs tidelink_lane_checker_single.sv alongside it (see the note in
# flists/tidelink_top.flist). deps/ is the deferred third-party tier and is
# out of this gate's scope, so pointing the target there would make lint-all
# depend on a tree this repo does not own.
#
# The consequence is worth stating plainly: `make lint-all` has been RED since
# that move — this target and lint-calibrator both failed — and a red gate is
# a gate nobody reads. Re-scope or delete; do not leave it half-wired.
lint-lane-checker:
	$(call VERILATE,tidelink_lane_checker,\
	  $(RTL_DIR)/tidelink_lane_checker.sv,\
	  $(INC_RTL))

# Performance counters
lint-perf:
	$(call VERILATE,tidelink_perf,\
	  $(RTL_DIR)/tidelink_perf.sv,\
	  $(INC_RTL))

# FIFO APB register bank (note: this file lives at src/rtl/fifo/, not src/rtl/)
lint-apb-regs:
	$(call VERILATE,tidelink_apb_regs,\
	  $(FIFO_DIR)/tidelink_apb_regs.sv,\
	  $(INC_RTL))

# FIFO controller — flow-control state machine
lint-fifo-ctrl:
	$(call VERILATE,tidelink_fifo_ctrl,\
	  $(FIFO_DIR)/tidelink_fifo_ctrl.sv,\
	  $(INC_RTL))

# Returner — write-side return path
lint-returner:
	$(call VERILATE,tidelink_returner,\
	  $(FIFO_DIR)/tidelink_returner.sv,\
	  $(INC_RTL))

# Auto-negotiation FSM — silicon-class bugs #1 (decouple nego_driving) and
# #2 (default txn_step_nxt) already fixed on feat/td-combined; should be clean.
lint-tidelink-autoneg:
	$(call VERILATE,tidelink_autoneg,\
	  $(TOP_DIR)/tidelink_autoneg.sv,\
	  $(INC_TOP))

# ─────────────────────────────────────────────────────────────────────────────
# Added 2026-08-09 after the full-chiplet lint pass.
#
# WHY THESE, AND WHY NOW. Every authored TideLink finding the full-design pass
# turned up was in a module OUTSIDE this gate. Two of them mattered:
#   * tidelink_ptp_servo — the lock compare used $unsigned() as if it were an
#     absolute value, so servo_locked could never latch on a negative offset.
#   * tidelink_fifo_ahb  — two floating INPUT pins (hw_credit_consume_vld/_val)
#     silently omitted from a port map.
# Neither module was reachable from any target above, which is precisely why
# both survived. A gate that does not cover a file is not a gate.
#
# If you add a module to src/rtl/, add it here in the same commit.
# ─────────────────────────────────────────────────────────────────────────────

# PTP servo + its iterative multiplier (the servo instantiates u_mul).
lint-ptp-servo:
	$(call VERILATE,tidelink_ptp_servo,\
	  $(RTL_DIR)/tidelink_ptp_servo.sv $(RTL_DIR)/tidelink_mul_iter.sv,\
	  $(INC_RTL))

lint-mul-iter:
	$(call VERILATE,tidelink_mul_iter,\
	  $(RTL_DIR)/tidelink_mul_iter.sv,\
	  $(INC_RTL))

# PTP short-packet TX/RX + HW-sync FSM
lint-ptp:
	$(call VERILATE,tidelink_ptp,\
	  $(RTL_DIR)/tidelink_ptp.sv,\
	  $(INC_RTL))

# FC adapter — AHB<->FC aperture, PUF and RX FSMs
lint-fc-adapter:
	$(call VERILATE,tidelink_fc_adapter,\
	  $(RTL_DIR)/tidelink_fc_adapter.sv,\
	  $(INC_RTL))

# AXI node observability (TL-009 wedge witness)
lint-axinode-obs:
	$(call VERILATE,tidelink_axinode_obs,\
	  $(RTL_DIR)/tidelink_axinode_obs.sv,\
	  $(INC_RTL))

# Per-lane RX IDELAY wrapper. Linted in its DEFAULT (USE_IDELAY=0) form, which
# is the ASIC/sim configuration; the USE_IDELAY=1 arm needs a unisim library.
lint-idelay-rx:
	$(call VERILATE,tidelink_idelay_rx,\
	  $(RTL_DIR)/tidelink_idelay_rx.sv,\
	  $(INC_RTL))

# CAM address translator + its APB register bank and CAM. Needs the apb4_if
# SystemVerilog interface from the chiplet-controller dep.
IFACE_DIR := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/interfaces

lint-addr-translator:
	$(call VERILATE,tidelink_addr_translator,\
	  $(IFACE_DIR)/apb4_if.sv $(RTL_DIR)/tidelink_addr_translator.sv \
	  $(RTL_DIR)/tl_addr_trans_regs.sv $(RTL_DIR)/tl_addr_trans_cam.sv,\
	  $(INC_RTL) -I$(IFACE_DIR))

# AHB-only FIFO wrapper. Uses the tidelink_ahb flist because it pulls in CMSDK
# bridges and the SRAM model; $(1).flist.expanded is the envsubst'd copy (the
# same trick lint-fpga-top uses). Needs set_env.sh for CMSDK_DIR /
# CMSDK_FPGA_SRAM_V, hence the `. set_env.sh` in the recipe.
AHB_FLIST := $(TIDELINK_HOME)/flists/tidelink_ahb.flist

lint-fifo-ahb:
	@echo "===== lint: tidelink_fifo_ahb ====="
	@. $(TIDELINK_HOME)/set_env.sh >/dev/null 2>&1 && \
	  envsubst < $(AHB_FLIST) > tidelink_ahb.flist.expanded && \
	  $(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_STRICT) \
	    -f tidelink_ahb.flist.expanded \
	    --top-module tidelink_fifo_ahb 2>&1 | tee tidelink_fifo_ahb.log; \
	  exit $${PIPESTATUS[0]}

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate targets
# ─────────────────────────────────────────────────────────────────────────────

LINT_TARGETS = lint-calibrator \
               lint-perf \
               lint-apb-regs \
               lint-fifo-ctrl \
               lint-returner \
               lint-tidelink-autoneg \
               lint-ptp-servo \
               lint-mul-iter \
               lint-ptp \
               lint-fc-adapter \
               lint-axinode-obs \
               lint-idelay-rx \
               lint-addr-translator \
               lint-fifo-ahb

# Run every module and keep going past failures; the aggregate target then
# inspects exit statuses and reports.
lint-all:
	@fail=0; \
	for t in $(LINT_TARGETS); do \
	  $(MAKE) --no-print-directory $$t || fail=1; \
	  echo ""; \
	done; \
	if [ $$fail -ne 0 ]; then \
	  echo "verilator lint: ONE OR MORE MODULES FAILED — see <module>.log"; \
	  exit 1; \
	else \
	  echo "verilator lint: ALL MODULES CLEAN"; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Full-design lint (best-effort; requires the FPGA filelist to elaborate)
# ─────────────────────────────────────────────────────────────────────────────
# This linting target uses the FPGA flist to give Verilator the full module
# graph. It surfaces inter-module issues (pin width mismatches, unused
# outputs at the chip top) that per-module lint misses. Slow (~10–30 s) and
# noisier — currently best-effort, not in lint-all.

FPGA_FLIST := $(TIDELINK_HOME)/flists/tidelink_fpga.flist
FLIST_OUT  := tidelink_fpga.flist.expanded

lint-fpga-top: $(FLIST_OUT)
	@echo "===== lint: tidelink_top (FPGA full design) ====="
	@. $(TIDELINK_HOME)/set_env.sh >/dev/null 2>&1 && \
	  $(VERILATOR) $(VERILATOR_FLAGS) \
	    -Wno-UNUSED -Wno-UNDRIVEN -Wno-WIDTH \
	    -f $(FLIST_OUT) \
	    --top-module tidelink_top 2>&1 | tee tidelink_top.log

# Expand $VARS in the flist into absolute paths (Verilator -f doesn't run
# shell variable expansion).
$(FLIST_OUT): $(FPGA_FLIST)
	@. $(TIDELINK_HOME)/set_env.sh >/dev/null 2>&1 && \
	  envsubst < $(FPGA_FLIST) > $@

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────

clean:
	rm -f *.log *.expanded
	rm -rf obj_dir

.PHONY: lint-all lint-calibrator \
        lint-lane-checker lint-perf lint-apb-regs lint-fifo-ctrl \
        lint-returner lint-tidelink-autoneg lint-fpga-top clean \
        lint-ptp-servo lint-mul-iter lint-ptp lint-fc-adapter \
        lint-axinode-obs lint-idelay-rx lint-addr-translator lint-fifo-ahb

.PHONY: clean_all clean_uvm clean_cocotb clean_formal clean_lint clean_syn \
        sim_robust sim_synth_mode xdc_lint xdc_lint_selftest \
        synth_lint_selftest robust_all

# =============================================================================
# Silicon-replication test gates (feat/cocotb-robust-silicon-replication)
# =============================================================================
#
# Targets that catch silicon-only failure modes BEFORE deploy:
#
#   xdc_lint           — Bug #6 (silently dropped XDC constraints).
#                        Static Python lint of fpga/targets/*.xdc.
#   xdc_lint_selftest  — Prove xdc_lint catches each of the 4 anti-patterns.
#   sim_synth_mode     — Bug #2/#7 (synth-interpretation defects).
#                        Verilator strict lint of first-party RTL.
#   synth_lint_selftest— Prove the Verilator gate catches CASEINCOMPLETE,
#                        WIDTH-truncate, BLKANDNBLK on seeded fixtures.
#   sim_robust         — Bug #1/#3/#7 fingerprints + reset/CDC stress.
#                        cocotb tests under cocotb/sim_robust/.
#   robust_all         — meta-target: run every gate (lints + sim).
#
# All targets are pre-silicon — no farm builds, no HW dependency.
# =============================================================================

xdc_lint:
	@echo "========================================"
	@echo " XDC anti-pattern lint (Bug #6 gate)"
	@echo "========================================"
	python3 cocotb/lint/xdc_lint.py fpga/targets/

xdc_lint_selftest:
	@echo "========================================"
	@echo " XDC anti-pattern lint — selftest"
	@echo "========================================"
	python3 cocotb/lint/test_xdc_lint_selftest.py

sim_synth_mode:
	@echo "========================================"
	@echo " Synth-mode Verilator lint (Bug #2/#7 gate)"
	@echo "========================================"
	$(MAKE) -C cocotb/lint -f Makefile.synth lint

synth_lint_selftest:
	@echo "========================================"
	@echo " Synth-mode Verilator lint — selftest"
	@echo "========================================"
	$(MAKE) -C cocotb/lint -f Makefile.synth selftest_synth

sim_robust:
	@echo "========================================"
	@echo " sim_robust adversarial cocotb tests"
	@echo "========================================"
	$(MAKE) -C cocotb/sim_robust sim_robust

robust_all: xdc_lint_selftest synth_lint_selftest xdc_lint sim_synth_mode sim_robust
	@echo "========================================"
	@echo " ALL ROBUST GATES PASSED"
	@echo "========================================"


# ── ASIC PnR / GDSII flow ────────────────────────────────────────────────
# Exposes `make fc`, `make gdsii`, `make fc_lec`, `make fc_etm`, `make
# fc_all`, `make asic_stage`, `make asic_clean` at the project root.
# Override the partition cut with ASIC_MODULE=<name>; default is
# tidelink_top_full (full chiplet subsystem).
include flows/makefile.asic

# Clean all verification, lint, and synthesis directories
clean_all: clean_uvm clean_cocotb clean_formal clean_lint clean_syn
	@echo "All clean targets completed"

# Clean UVM directories
clean_uvm:
	@echo "Cleaning UVM directories..."
	$(MAKE) -C uvm/tidelink clean
	$(MAKE) -C uvm/tidelink_fc_adapter clean
	$(MAKE) -C uvm/tidelink_integration clean
	$(MAKE) -C uvm/tidelink_top_system clean
	$(MAKE) -C uvm/tidelink_ptp_chain clean
	$(MAKE) -C uvm/tidelink_ptp_stress clean
	$(MAKE) -C uvm/tidelink_system clean
	@echo "UVM clean completed"

# Clean cocotb directories
clean_cocotb:
	@echo "Cleaning cocotb directories..."
	$(MAKE) -C cocotb/tidelink clean
	$(MAKE) -C cocotb/tidelink_ahb clean
	$(MAKE) -C cocotb/tidelink_fifo clean
	$(MAKE) -C cocotb/tidelink_returner clean
	$(MAKE) -C cocotb/tidelink_apb_regs clean
	$(MAKE) -C cocotb/tidelink_py_pair clean
	$(MAKE) -C cocotb/tidelink_fc_adapter clean
	$(MAKE) -C cocotb/tidelink_top clean
	$(MAKE) -C cocotb/tidelink_system clean
	$(MAKE) -C cocotb/tidelink_ptp clean
	@echo "cocotb clean completed"

# Clean formal verification directories
clean_formal:
	@echo "Cleaning formal verification directories..."
	$(MAKE) -C formal/tidelink clean
	$(MAKE) -C formal/tidelink_fifo clean
	$(MAKE) -C formal/tidelink_fifo_ctrl clean
	$(MAKE) -C formal/tidelink_apb_regs clean
	$(MAKE) -C formal/tidelink_returner clean
	@echo "Formal verification clean completed"

# Clean lint directory
clean_lint:
	@echo "Cleaning lint directory..."
	$(MAKE) -C lint clean
	@echo "Lint clean completed"

# Clean synthesis directories
clean_syn:
	@echo "Cleaning synthesis directories..."
	$(MAKE) -C syn/asic/rtl-architect clean
	$(MAKE) -C syn/asic/design-compiler clean
	@echo "Synthesis clean completed"

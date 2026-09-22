###############################################################################
# Makefile for TideLink UVM Testbench
###############################################################################
# Uses Synopsys VCS with VC VIP AMBA suite for AHB interfaces and a
# custom APB master agent for register access.
#
# Targets:
#   RTL simulation:   make run / run_all / coverage
#   Gate-level sim:   make run_gate / run_all_gate / coverage_gate
###############################################################################

# ── Site configuration ──────────────────────────────────────────────────────
# Tool installs and IP roots are per-machine facts with NO default: see
# mk/site.mk and site.env.example. `source set_env.sh` sets them too.
TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
SITE_VARS_REQUIRED += VCS_HOME VIP_HOME CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk

# The gate-level run needs the physical-IP root as well. An RTL run must not
# require a PDK, so it is checked in the compile_gate recipe rather than at
# parse time. PHYS_IP_PATH has no default; the library subdirectory below
# carries a release code, so set STDCELL_SIM whole in site.env if it differs.
STDCELL_SIM  ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/verilog/sc12_cln65lp_base_rvt.v
AMBA_HOME    = $(VIP_HOME)/vip/svt/amba_svt/latest
SVT_HOME     = $(VIP_HOME)/vip/svt/common/latest

# Project paths
PROJ_HOME   ?= $(realpath ../..)
RTL_DIR      = $(PROJ_HOME)/src/rtl
FLIST_DIR    = $(PROJ_HOME)/flist
TB_DIR       = $(CURDIR)/tb
ENV_DIR      = $(CURDIR)/env
AGENT_DIR    = $(CURDIR)/agents/apb_master_agent
SEQ_DIR      = $(CURDIR)/sequences
TEST_DIR     = $(CURDIR)/tests

# Synthesis / gate-level paths
SYN_DIR      = $(PROJ_HOME)/syn/asic/design-compiler
NETLIST      = $(SYN_DIR)/tidelink_dc_output/tidelink.mapped.v
SDF_FILE     = $(SYN_DIR)/tidelink_dc_output/tidelink.sdf

# Simulation output
SIM_DIR      = sim_build
SIM_DIR_GATE = sim_build_gate
COV_DIR      = coverage_report
COV_DIR_GATE = coverage_report_gate

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= tidelink_single_packet_test
SEED        ?= random
VERBOSITY   ?= UVM_MEDIUM

# ---------------------------------------------------------------
# Common VCS compile flags (shared between RTL and gate-level)
# ---------------------------------------------------------------
VCS  = $(VCS_HOME)/bin/vcs

VCS_COMMON  = -full64 -sverilog
VCS_COMMON += -ntb_opts uvm-1.2
VCS_COMMON += -timescale=1ns/1ps
VCS_COMMON += -xprop=tmerge

# VIP defines
VCS_COMMON += +define+DESIGNWARE_INCDIR=$(VIP_HOME)
VCS_COMMON += +define+UVM_DISABLE_AUTO_ITEM_RECORDING
VCS_COMMON += +define+SVT_AHB_DISABLE_IMPLICIT_BUS_CONNECTION

# Code coverage — scoped to DUT hierarchy only
VCS_COMMON += -cm line+cond+tgl+fsm+branch
VCS_COMMON += -cm_hier $(TB_DIR)/cov_hier.cfg

# UVM include path
UVM_HOME     = $(VCS_HOME)/etc/uvm-1.2
VCS_COMMON += +incdir+$(UVM_HOME)

# Include paths (SVT common must come before AMBA)
VCS_COMMON += +incdir+$(SVT_HOME)/sverilog/include
VCS_COMMON += +incdir+$(AMBA_HOME)/sverilog/include
VCS_COMMON += +incdir+$(RTL_DIR)
VCS_COMMON += +incdir+$(RTL_DIR)/fifo
VCS_COMMON += +incdir+$(TB_DIR)
VCS_COMMON += +incdir+$(ENV_DIR)
VCS_COMMON += +incdir+$(AGENT_DIR)
VCS_COMMON += +incdir+$(SEQ_DIR)
VCS_COMMON += +incdir+$(TEST_DIR)

# VIP source search paths
VCS_COMMON += -y $(SVT_HOME)/sverilog/src/vcs
VCS_COMMON += -y $(SVT_HOME)/sverilog/src/com
VCS_COMMON += -y $(AMBA_HOME)/sverilog/src/vcs
VCS_COMMON += -y $(AMBA_HOME)/sverilog/src/com
VCS_COMMON += +libext+.svp+.sv+.svi+.svh

# Top-level testbench (always included)
VCS_COMMON += $(TB_DIR)/top.sv

# ---------------------------------------------------------------
# RTL-specific compile flags
# ---------------------------------------------------------------
VCS_RTL_FLAGS  = $(VCS_COMMON)
VCS_RTL_FLAGS += -l $(SIM_DIR)/compile.log
VCS_RTL_FLAGS += -o $(SIM_DIR)/simv
VCS_RTL_FLAGS += -cm_dir $(SIM_DIR)/simv.vdb

# DUT source (generic SRAM variant for simulation)
VCS_RTL_FLAGS += +incdir+$(CMSDK_DIR)/logical/cmsdk_ahb_to_sram/verilog
VCS_RTL_FLAGS += $(CMSDK_DIR)/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/generic/tidelink_sram.sv
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo_ctrl.sv
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo_mem.sv
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/tidelink_returner.sv
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/tidelink_apb_regs.sv
VCS_RTL_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo.sv

# ---------------------------------------------------------------
# Gate-level-specific compile flags
# ---------------------------------------------------------------
VCS_GATE_FLAGS  = $(VCS_COMMON)
VCS_GATE_FLAGS += -l $(SIM_DIR_GATE)/compile.log
VCS_GATE_FLAGS += -o $(SIM_DIR_GATE)/simv
VCS_GATE_FLAGS += -cm_dir $(SIM_DIR_GATE)/simv.vdb
VCS_GATE_FLAGS += +define+GATE_SIM

# Suppress timing warnings for zero-delay functional gate-level sim
VCS_GATE_FLAGS += +notimingcheck +nospecify +delay_mode_zero

# Synthesised netlist + standard cell simulation models
VCS_GATE_FLAGS += $(NETLIST)
VCS_GATE_FLAGS += $(STDCELL_SIM)

# Optional: back-annotated timing (uncomment for timing-accurate sim)
# VCS_GATE_FLAGS += -sdf max:test_top.u_dut:$(SDF_FILE)
# VCS_GATE_FLAGS += +neg_tchk

# ---------------------------------------------------------------
# Simulation run flags
# ---------------------------------------------------------------
SIM_FLAGS  = +UVM_TESTNAME=$(TEST)
SIM_FLAGS += +UVM_VERBOSITY=$(VERBOSITY)
SIM_FLAGS += -cm line+cond+tgl+fsm+branch
SIM_FLAGS += -l $(TEST).log

ifneq ($(SEED),random)
  SIM_FLAGS += +ntb_random_seed=$(SEED)
else
  SIM_FLAGS += +ntb_random_seed_automatic
endif

# ---------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------
TESTS = tidelink_register_test \
        tidelink_single_packet_test \
        tidelink_random_test \
        tidelink_stall_test \
        tidelink_scoreboard_loss_selftest

# ---------------------------------------------------------------
# RTL targets
# ---------------------------------------------------------------
.PHONY: compile run clean coverage run_all help waves \
        compile_gate run_gate run_all_gate coverage_gate clean_gate

help:
	@echo "Usage:"
	@echo ""
	@echo "  RTL simulation:"
	@echo "    make compile                    - Compile RTL testbench"
	@echo "    make run TEST=<test_name>       - Compile and run a specific test"
	@echo "    make run_all                    - Run all tests"
	@echo "    make coverage                   - Generate merged coverage report"
	@echo "    make waves                      - Compile with waveform dumping"
	@echo ""
	@echo "  Gate-level simulation:"
	@echo "    make compile_gate               - Compile with synthesised netlist"
	@echo "    make run_gate TEST=<test_name>  - Compile and run gate-level test"
	@echo "    make run_all_gate               - Run all tests on gate-level netlist"
	@echo "    make coverage_gate              - Generate gate-level coverage report"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean                      - Remove all build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  tidelink_register_test            - APB register read/write tests"
	@echo "  tidelink_single_packet_test       - Single packet write/read with integrity check"
	@echo "  tidelink_random_test              - Constrained-random multi-packet test"
	@echo "  tidelink_stall_test               - Gapped/stalled packet transfers"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                       - Test to run (default: tidelink_single_packet_test)"
	@echo "  SEED=<value|random>               - Random seed (default: random)"
	@echo "  VERBOSITY=<UVM_NONE|...|UVM_DEBUG>- UVM verbosity (default: UVM_MEDIUM)"
	@echo "  STDCELL_SIM=<path>                - Standard cell Verilog models for gate-level sim"

compile: | $(SIM_DIR)
	$(VCS) $(VCS_RTL_FLAGS)

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

run: compile
	cd $(SIM_DIR) && ./simv $(SIM_FLAGS) -cm_dir simv.vdb

waves: VCS_RTL_FLAGS += +define+WAVES_VCD
waves: run

run_all: compile
	@pass=0; fail=0; \
	for test in $(TESTS); do \
		echo "======== Running $$test ========"; \
		if cd $(SIM_DIR) && ./simv +UVM_TESTNAME=$$test +UVM_VERBOSITY=$(VERBOSITY) \
			-cm line+cond+tgl+fsm+branch -cm_dir simv.vdb \
			+ntb_random_seed_automatic -l $$test.log; then \
			echo "  PASSED: $$test"; \
			pass=$$((pass + 1)); \
		else \
			echo "  FAILED: $$test"; \
			fail=$$((fail + 1)); \
		fi; \
		cd ..; \
	done; \
	echo "======== All tests complete: $$pass passed, $$fail failed ========"; \
	exit $$fail

coverage:
	$(VCS_HOME)/bin/urg -dir $(SIM_DIR)/simv.vdb -report $(COV_DIR) -format both

# ---------------------------------------------------------------
# Gate-level targets
# ---------------------------------------------------------------
compile_gate: | $(SIM_DIR_GATE)
	@$(SITE_REQUIRE) PHYS_IP_PATH "the Arm physical-IP root (gate-level cell models)"
	@$(SITE_REQUIRE) STDCELL_SIM "the standard-cell Verilog model file"
	$(VCS) $(VCS_GATE_FLAGS)

$(SIM_DIR_GATE):
	mkdir -p $(SIM_DIR_GATE)

run_gate: compile_gate
	cd $(SIM_DIR_GATE) && ./simv $(SIM_FLAGS) -cm_dir simv.vdb

run_all_gate: compile_gate
	@pass=0; fail=0; \
	for test in $(TESTS); do \
		echo "======== [GATE] Running $$test ========"; \
		if cd $(SIM_DIR_GATE) && ./simv +UVM_TESTNAME=$$test +UVM_VERBOSITY=$(VERBOSITY) \
			-cm line+cond+tgl+fsm+branch -cm_dir simv.vdb \
			+ntb_random_seed_automatic -l $$test.log; then \
			echo "  PASSED: $$test"; \
			pass=$$((pass + 1)); \
		else \
			echo "  FAILED: $$test"; \
			fail=$$((fail + 1)); \
		fi; \
		cd ..; \
	done; \
	echo "======== [GATE] All tests complete: $$pass passed, $$fail failed ========"; \
	exit $$fail

coverage_gate:
	$(VCS_HOME)/bin/urg -dir $(SIM_DIR_GATE)/simv.vdb -report $(COV_DIR_GATE) -format both

# ---------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------
clean:
	rm -rf $(SIM_DIR) $(SIM_DIR_GATE) $(COV_DIR) $(COV_DIR_GATE) \
	       csrc *.log ucli.key vc_hdrs.h

# ===========================================================================
# SCOREBOARD PACKET-LOSS SELF-TEST, GATE-GRADED (false-green register B1)
# ---------------------------------------------------------------------------
# `tidelink_scoreboard_loss_selftest` has been in TESTS since 24cb2cba,
# and NOTHING has ever run it in a gate. Worse, wiring it in through `make run`
# or `make run_all` would have been a FALSE GREEN: both decide on simv's exit
# code, and simv EXITS 0 when the run raised UVM_ERRORs. MEASURED 2026-09-11 in
# this very directory:
#     ./simv +UVM_TESTNAME=no_such_test_at_all  ->  exit 0, "UVM_FATAL :    1"
# A control that cannot report failure is decoration; a control wired in through
# a target that cannot report failure is worse, because it looks wired in.
#
# This target decides on the LOG (scripts/ci/grade_uvm_selftest_log.sh), the
# same rule uvm/tidelink_top_system/Makefile's sb_selftest already applies:
# missing log, no UVM report summary, or no [SB_SELFTEST] output at all are all
# COULD-NOT-EVALUATE (exit 2), never PASS.
#
#   make sb_loss_selftest        - compile, run, grade; nonzero on any UVM_ERROR
# ===========================================================================
SB_LOSS_TEST  = tidelink_scoreboard_loss_selftest
SB_LOSS_LOG   = $(SIM_DIR)/$(SB_LOSS_TEST).log
SB_LOSS_GRADE = $(PROJ_HOME)/scripts/ci/grade_uvm_selftest_log.sh

.PHONY: sb_loss_selftest
sb_loss_selftest: compile
	@rm -f $(SB_LOSS_LOG)
	@cd $(SIM_DIR) && ./simv +UVM_TESTNAME=$(SB_LOSS_TEST) +UVM_VERBOSITY=UVM_LOW \
	    -l $(SB_LOSS_TEST).log
	@bash $(SB_LOSS_GRADE) $(SB_LOSS_LOG) "SB_LOSS_SELFTEST(tidelink)" SB_SELFTEST

###############################################################################
# Makefile for TideLink Integration UVM Testbench
###############################################################################
# Tests the FC adapter + FIFO integration path with FC TX→RX loopback.
# Same functional coverage as the cocotb tidelink_top tests, but without
# external IP dependencies (XHB500, chiplet controller).
#
# Targets:
#   make run TEST=<test_name>   - Compile and run a specific test
#   make run_all                - Run all tests
#   make coverage               - Generate merged coverage report
###############################################################################

# Tool paths
VCS_HOME    ?= /eda/synopsys/2022-23/RHELx86/VCS_2022.06-SP2
VERDI_HOME  ?= /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2
VIP_HOME    ?= /eda/synopsys/2022-23/RHELx86/VC-VIP-SOC_2022.12
AMBA_HOME    = $(VIP_HOME)/vip/svt/amba_svt/latest
SVT_HOME     = $(VIP_HOME)/vip/svt/common/latest

# Project paths
PROJ_HOME   ?= $(realpath ../..)
RTL_DIR      = $(PROJ_HOME)/src/rtl
FLIST_DIR    = $(PROJ_HOME)/flist
TB_DIR       = $(CURDIR)/tb
ENV_DIR      = $(CURDIR)/env
SEQ_DIR      = $(CURDIR)/sequences
TEST_DIR     = $(CURDIR)/tests

# Shared agents from the unit-level testbench
UNIT_UVM_DIR = $(PROJ_HOME)/uvm/tidelink
AGENT_DIR    = $(UNIT_UVM_DIR)/agents/apb_master_agent
UNIT_SEQ_DIR = $(UNIT_UVM_DIR)/sequences

# CMSDK path (for cmsdk_ahb_to_sram and cmsdk_ahb_to_apb). Convention:
# CMSDK_DIR is the package root (parent of `logical/`), matching cocotb/lint.
CMSDK_DIR   ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= tidelink_integration_loopback_test
SEED        ?= random
VERBOSITY   ?= UVM_MEDIUM

# ---------------------------------------------------------------
# VCS compile flags
# ---------------------------------------------------------------
VCS  = $(VCS_HOME)/bin/vcs

VCS_FLAGS  = -full64 -sverilog
VCS_FLAGS += -ntb_opts uvm-1.2
VCS_FLAGS += -timescale=1ns/1ps
VCS_FLAGS += -xprop=tmerge

# VIP defines
VCS_FLAGS += +define+DESIGNWARE_INCDIR=$(VIP_HOME)
VCS_FLAGS += +define+UVM_DISABLE_AUTO_ITEM_RECORDING
VCS_FLAGS += +define+SVT_AHB_DISABLE_IMPLICIT_BUS_CONNECTION

# Code coverage
VCS_FLAGS += -cm line+cond+tgl+fsm+branch

# UVM include path
UVM_HOME     = $(VCS_HOME)/etc/uvm-1.2
VCS_FLAGS += +incdir+$(UVM_HOME)

# Include paths (SVT common must come before AMBA)
VCS_FLAGS += +incdir+$(SVT_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(AMBA_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(RTL_DIR)
VCS_FLAGS += +incdir+$(RTL_DIR)/fifo
VCS_FLAGS += +incdir+$(TB_DIR)
VCS_FLAGS += +incdir+$(ENV_DIR)
VCS_FLAGS += +incdir+$(AGENT_DIR)
VCS_FLAGS += +incdir+$(SEQ_DIR)
VCS_FLAGS += +incdir+$(UNIT_SEQ_DIR)
VCS_FLAGS += +incdir+$(TEST_DIR)

# VIP source search paths
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/com
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/com
VCS_FLAGS += +libext+.svp+.sv+.svi+.svh

# Top-level testbench
VCS_FLAGS += $(TB_DIR)/top.sv

# Compile outputs
VCS_FLAGS += -l $(SIM_DIR)/compile.log
VCS_FLAGS += -o $(SIM_DIR)/simv
VCS_FLAGS += -cm_dir $(SIM_DIR)/simv.vdb

# ---------------------------------------------------------------
# DUT RTL sources
# ---------------------------------------------------------------
# CMSDK components
VCS_FLAGS += +incdir+$(CMSDK_DIR)/logical/cmsdk_ahb_to_sram/verilog
VCS_FLAGS += $(CMSDK_DIR)/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
VCS_FLAGS += +incdir+$(CMSDK_DIR)/logical/cmsdk_ahb_to_apb/verilog
VCS_FLAGS += $(CMSDK_DIR)/logical/cmsdk_ahb_to_apb/verilog/cmsdk_ahb_to_apb.v

# TideLink FIFO RTL
VCS_FLAGS += $(RTL_DIR)/fifo/generic/tidelink_sram.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo_ctrl.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo_mem.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_returner.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_apb_regs.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo.sv
VCS_FLAGS += $(RTL_DIR)/fifo/tidelink_fifo_ahb.sv

# TideLink FC Adapter RTL
VCS_FLAGS += $(RTL_DIR)/tidelink_fc_adapter.sv

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
TESTS = tidelink_integration_loopback_test \
        tidelink_integration_credit_test \
        tidelink_integration_stress_test \
        tidelink_integration_scoreboard_loss_selftest

# ---------------------------------------------------------------
# Targets
# ---------------------------------------------------------------
.PHONY: compile run clean coverage run_all help waves

help:
	@echo "Usage:"
	@echo ""
	@echo "  make compile                    - Compile testbench"
	@echo "  make run TEST=<test_name>       - Compile and run a specific test"
	@echo "  make run_all                    - Run all tests"
	@echo "  make coverage                   - Generate merged coverage report"
	@echo "  make waves                      - Compile with waveform dumping"
	@echo "  make clean                      - Remove all build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  tidelink_integration_loopback_test  - Single packet loopback write/read"
	@echo "  tidelink_integration_credit_test    - Credit sideband loopback verification"
	@echo "  tidelink_integration_stress_test    - Rapid multi-packet stress test"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                       - Test to run (default: tidelink_integration_loopback_test)"
	@echo "  SEED=<value|random>               - Random seed (default: random)"
	@echo "  VERBOSITY=<UVM_NONE|...|UVM_DEBUG>- UVM verbosity (default: UVM_MEDIUM)"

compile: | $(SIM_DIR)
	$(VCS) $(VCS_FLAGS)

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

run: compile
	cd $(SIM_DIR) && ./simv $(SIM_FLAGS) -cm_dir simv.vdb

waves: VCS_FLAGS += +define+WAVES_VCD
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

clean:
	rm -rf $(SIM_DIR) $(COV_DIR) csrc *.log ucli.key vc_hdrs.h

# ===========================================================================
# SCOREBOARD PACKET-LOSS SELF-TEST, GATE-GRADED (false-green register B1)
# ---------------------------------------------------------------------------
# `tidelink_integration_scoreboard_loss_selftest` has been in TESTS since 24cb2cba,
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
SB_LOSS_TEST  = tidelink_integration_scoreboard_loss_selftest
SB_LOSS_LOG   = $(SIM_DIR)/$(SB_LOSS_TEST).log
SB_LOSS_GRADE = $(PROJ_HOME)/scripts/ci/grade_uvm_selftest_log.sh

.PHONY: sb_loss_selftest
sb_loss_selftest: compile
	@rm -f $(SB_LOSS_LOG)
	@cd $(SIM_DIR) && ./simv +UVM_TESTNAME=$(SB_LOSS_TEST) +UVM_VERBOSITY=UVM_LOW \
	    -l $(SB_LOSS_TEST).log
	@bash $(SB_LOSS_GRADE) $(SB_LOSS_LOG) "SB_LOSS_SELFTEST(tidelink_integration)" SB_SELFTEST

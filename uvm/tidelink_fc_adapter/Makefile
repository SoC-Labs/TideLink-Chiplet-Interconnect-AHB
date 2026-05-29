###############################################################################
# Makefile for TideLink FC Adapter UVM Testbench
###############################################################################
# Uses Synopsys VCS with custom FC and AHB agents for verifying the
# tidelink_fc_adapter module.
#
# Targets:
#   RTL simulation:   make run / run_all / coverage
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
FC_AGENT_DIR = $(CURDIR)/env/fc_agent
TEST_DIR     = $(CURDIR)/tests

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= tidelink_fc_adapter_tx_test
SEED        ?= random
VERBOSITY   ?= UVM_MEDIUM

# ---------------------------------------------------------------
# Common VCS compile flags
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
VCS_COMMON += +incdir+$(TB_DIR)
VCS_COMMON += +incdir+$(ENV_DIR)
VCS_COMMON += +incdir+$(FC_AGENT_DIR)
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

# DUT source
VCS_RTL_FLAGS += $(RTL_DIR)/tidelink_fc_adapter.sv

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
# Default test suite. Override with TESTS=<list> on the command line.
# All four tests (tx, sideband, rx, full) are in CI as of 2026-05-29
# after the AHB-driver settle-gap fix landed in env/{rtn,ahb_tx}_driver.sv
# — see docs/VPLAN.md §3.6 and cocotb/README.md "Known-excluded-from-CI"
# for the full diagnosis (DUT pending_r/skid sample race vs the master
# clocking-block hwdata `output #1` skew under backpressure).
TESTS ?= tidelink_fc_adapter_tx_test \
        tidelink_fc_adapter_sideband_test \
        tidelink_fc_adapter_rx_test \
        tidelink_fc_adapter_full_test

# ---------------------------------------------------------------
# RTL targets
# ---------------------------------------------------------------
.PHONY: compile run clean coverage run_all help waves

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
	@echo "  Cleanup:"
	@echo "    make clean                      - Remove all build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  tidelink_fc_adapter_tx_test       - TX aperture AHB-to-FC test"
	@echo "  tidelink_fc_adapter_sideband_test - Returner sideband AHB-to-FC test"
	@echo "  tidelink_fc_adapter_rx_test       - FC-to-AHB RX path test"
	@echo "  tidelink_fc_adapter_full_test     - Mixed traffic stress test"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                       - Test to run (default: tidelink_fc_adapter_tx_test)"
	@echo "  SEED=<value|random>               - Random seed (default: random)"
	@echo "  VERBOSITY=<UVM_NONE|...|UVM_DEBUG>- UVM verbosity (default: UVM_MEDIUM)"

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
# Cleanup
# ---------------------------------------------------------------
clean:
	rm -rf $(SIM_DIR) $(COV_DIR) csrc *.log ucli.key vc_hdrs.h

###############################################################################
# Makefile for TideLink UVM Testbench
###############################################################################
# Uses Synopsys VCS with VC VIP AMBA suite for AHB interfaces and a
# custom APB master agent for register access.
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
AGENT_DIR    = $(CURDIR)/agents/apb_master_agent
SEQ_DIR      = $(CURDIR)/sequences
TEST_DIR     = $(CURDIR)/tests

# CMSDK path (for cmsdk_ahb_to_sram)
CMSDK_DIR   ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0/logical

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= tidelink_single_packet_test
SEED        ?= random
VERBOSITY   ?= UVM_MEDIUM

# ---------------------------------------------------------------
# VCS compile flags
# ---------------------------------------------------------------
VCS  = $(VCS_HOME)/bin/vcs

VCS_FLAGS  = -full64 -sverilog
VCS_FLAGS += -ntb_opts uvm-1.2
VCS_FLAGS += -timescale=1ns/1ps
VCS_FLAGS += -l $(SIM_DIR)/compile.log
VCS_FLAGS += -o $(SIM_DIR)/simv

# VIP defines
VCS_FLAGS += +define+DESIGNWARE_INCDIR=$(VIP_HOME)
VCS_FLAGS += +define+UVM_DISABLE_AUTO_ITEM_RECORDING
VCS_FLAGS += +define+SVT_AHB_DISABLE_IMPLICIT_BUS_CONNECTION

# Coverage
VCS_FLAGS += -cm line+cond+tgl+fsm+branch
VCS_FLAGS += -cm_dir $(SIM_DIR)/simv.vdb

# UVM include path
UVM_HOME     = $(VCS_HOME)/etc/uvm-1.2
VCS_FLAGS += +incdir+$(UVM_HOME)

# Include paths (SVT common must come before AMBA)
VCS_FLAGS += +incdir+$(SVT_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(AMBA_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(RTL_DIR)
VCS_FLAGS += +incdir+$(TB_DIR)
VCS_FLAGS += +incdir+$(ENV_DIR)
VCS_FLAGS += +incdir+$(AGENT_DIR)
VCS_FLAGS += +incdir+$(SEQ_DIR)
VCS_FLAGS += +incdir+$(TEST_DIR)

# VIP source search paths
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/com
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/com
VCS_FLAGS += +libext+.svp+.sv+.svi+.svh

# DUT source (generic SRAM variant for simulation)
VCS_FLAGS += +incdir+$(CMSDK_DIR)/cmsdk_ahb_to_sram/verilog
VCS_FLAGS += $(CMSDK_DIR)/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
VCS_FLAGS += $(RTL_DIR)/generic/tidelink_sram.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_fifo_ctrl.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_fifo.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_returner.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_apb_regs.sv
VCS_FLAGS += $(RTL_DIR)/tidelink.sv

# Top-level testbench
VCS_FLAGS += $(TB_DIR)/top.sv

# ---------------------------------------------------------------
# Simulation run flags
# ---------------------------------------------------------------
SIM_FLAGS  = +UVM_TESTNAME=$(TEST)
SIM_FLAGS += +UVM_VERBOSITY=$(VERBOSITY)
SIM_FLAGS += -cm line+cond+tgl+fsm+branch
SIM_FLAGS += -cm_dir $(SIM_DIR)/simv.vdb
SIM_FLAGS += -l $(TEST).log

ifneq ($(SEED),random)
  SIM_FLAGS += +ntb_random_seed=$(SEED)
else
  SIM_FLAGS += +ntb_random_seed_automatic
endif

# ---------------------------------------------------------------
# Targets
# ---------------------------------------------------------------
.PHONY: compile run clean coverage run_all help waves

help:
	@echo "Usage:"
	@echo "  make compile                    - Compile the testbench"
	@echo "  make run TEST=<test_name>       - Compile and run a specific test"
	@echo "  make run_all                    - Run all tests"
	@echo "  make coverage                   - Generate coverage report"
	@echo "  make waves                      - Compile with waveform dumping"
	@echo "  make clean                      - Clean build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  tidelink_register_test          - APB register read/write tests"
	@echo "  tidelink_single_packet_test     - Single packet write/read with integrity check"
	@echo "  tidelink_random_test            - Constrained-random multi-packet test"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                     - Test to run (default: tidelink_single_packet_test)"
	@echo "  SEED=<value|random>             - Random seed (default: random)"
	@echo "  VERBOSITY=<UVM_NONE|...|UVM_DEBUG> - UVM verbosity (default: UVM_MEDIUM)"

compile: | $(SIM_DIR)
	$(VCS) $(VCS_FLAGS)

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

run: compile
	cd $(SIM_DIR) && ./simv $(SIM_FLAGS)

waves: VCS_FLAGS += +define+WAVES_VCD
waves: run

coverage:
	$(VCS_HOME)/bin/urg -dir $(SIM_DIR)/simv.vdb -report $(COV_DIR) -format text

TESTS = tidelink_register_test \
        tidelink_single_packet_test \
        tidelink_random_test

run_all: compile
	@fail=0; \
	for test in $(TESTS); do \
		echo "======== Running $$test ========"; \
		if cd $(SIM_DIR) && ./simv +UVM_TESTNAME=$$test +UVM_VERBOSITY=$(VERBOSITY) \
			-cm line+cond+tgl+fsm+branch -cm_dir simv.vdb \
			+ntb_random_seed_automatic -l $$test.log; then \
			echo "  PASSED: $$test"; \
		else \
			echo "  FAILED: $$test"; \
			fail=$$((fail + 1)); \
		fi; \
		cd ..; \
	done; \
	echo "======== All tests complete ($$fail failure(s)) ========"; \
	exit $$fail

clean:
	rm -rf $(SIM_DIR) $(COV_DIR) csrc *.log ucli.key vc_hdrs.h

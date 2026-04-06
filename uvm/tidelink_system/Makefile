###############################################################################
# Makefile for TideLink System (Paired) UVM Testbench
###############################################################################
# Tests two FC adapter + FIFO subsystems connected back-to-back via FC
# crossover, simulating two chiplets communicating over a loopback link.
#
# Architecture:
#   Chiplet A (FC adapter + FIFO) <-- FC crossover --> Chiplet B (FC adapter + FIFO)
#   A's FC TX -> B's FC RX, B's FC TX -> A's FC RX
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

# Shared agents and sequences from the unit-level and integration testbenches
UNIT_UVM_DIR = $(PROJ_HOME)/uvm/tidelink
INT_UVM_DIR  = $(PROJ_HOME)/uvm/tidelink_integration
AGENT_DIR    = $(UNIT_UVM_DIR)/agents/apb_master_agent
UNIT_SEQ_DIR = $(UNIT_UVM_DIR)/sequences
INT_SEQ_DIR  = $(INT_UVM_DIR)/sequences

# CMSDK path (for cmsdk_ahb_to_sram and cmsdk_ahb_to_apb)
CMSDK_DIR   ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0/logical

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= test_single_packet
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
VCS_FLAGS += +incdir+$(INT_SEQ_DIR)
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
VCS_FLAGS += +incdir+$(CMSDK_DIR)/cmsdk_ahb_to_sram/verilog
VCS_FLAGS += $(CMSDK_DIR)/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
VCS_FLAGS += +incdir+$(CMSDK_DIR)/cmsdk_ahb_to_apb/verilog
VCS_FLAGS += $(CMSDK_DIR)/cmsdk_ahb_to_apb/verilog/cmsdk_ahb_to_apb.v

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
TESTS = test_single_packet \
        test_bidirectional \
        test_back_to_back \
        test_max_packet \
        test_credit_exhaustion \
        test_credit_threshold \
        test_sideband_stress \
        test_interleaved_types \
        test_error_injection \
        test_reset_recovery \
        test_long_running \
        test_pair_credit_underflow \
        test_partial_packet_abandon \
        test_error_recovery \
        test_throughput_latency

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
	@echo "  test_single_packet         - Single packet A->B, verify delivery and credits"
	@echo "  test_bidirectional         - Simultaneous A->B and B->A packets"
	@echo "  test_back_to_back          - Rapid-fire packets with no gap"
	@echo "  test_max_packet            - Maximum size packet (fill entire FIFO)"
	@echo "  test_credit_exhaustion     - Send until credits exhausted, verify flow control"
	@echo "  test_credit_threshold      - Test different release threshold values"
	@echo "  test_sideband_stress       - Rapid credit returns mixed with data traffic"
	@echo "  test_interleaved_types     - Mix RD_REQ, WR_REQ, RD_RSP, WR_RSP descriptors"
	@echo "  test_error_injection       - Invalid data, overflow attempts, underrun reads"
	@echo "  test_reset_recovery        - Assert reset mid-transfer, verify clean recovery"
	@echo "  test_long_running          - 1000+ packets in both directions"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                       - Test to run (default: test_single_packet)"
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

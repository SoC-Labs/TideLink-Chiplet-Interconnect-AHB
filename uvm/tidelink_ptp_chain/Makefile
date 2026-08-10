###############################################################################
# Makefile for TideLink PTP Chain UVM Testbench
###############################################################################
# Tests 3-chiplet PTP chain: A(GM) <-> B(Sub->GM) <-> C(Sub)
# 4 tidelink_top instances, 3 PHC instances (PHC_B shared)
# Verifies cascaded clock synchronisation with lock gating.
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
DEPS_DIR     = $(PROJ_HOME)/deps/axi-chiplet-controller
TB_DIR       = $(CURDIR)/tb
ENV_DIR      = $(CURDIR)/env
SEQ_DIR      = $(CURDIR)/sequences
TEST_DIR     = $(CURDIR)/tests

# PHC (PTP Hardware Clock) RTL
PHC_DIR     ?= $(HOME)/SoCLabs/ptp-hardware-clock-ahb/src/rtl

# Shared agents and sequences from existing testbenches
UNIT_UVM_DIR = $(PROJ_HOME)/uvm/tidelink
INT_UVM_DIR  = $(PROJ_HOME)/uvm/tidelink_integration
TOP_SYS_DIR  = $(PROJ_HOME)/uvm/tidelink_top_system
AGENT_DIR    = $(UNIT_UVM_DIR)/agents/apb_master_agent
INT_SEQ_DIR  = $(INT_UVM_DIR)/sequences
TOP_SEQ_DIR  = $(TOP_SYS_DIR)/sequences

# CMSDK path. Convention: CMSDK_DIR is the package root (parent of
# `logical/`), matching cocotb/lint.
CMSDK_DIR   ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0

# XHB500 generated bridge directories
XHB500_GEN_DIR ?= $(PROJ_HOME)/deps/xhb500/generated
XHB500_SLV_DIR ?= $(XHB500_GEN_DIR)/xhb_chiplet_slv
XHB500_MST_DIR ?= $(XHB500_GEN_DIR)/xhb_chiplet_mst

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

export DESIGNWARE_HOME := $(VIP_HOME)

# Defaults
TEST        ?= test_chain_convergence
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

VCS_FLAGS += +define+DESIGNWARE_INCDIR=$(VIP_HOME)
VCS_FLAGS += +define+UVM_DISABLE_AUTO_ITEM_RECORDING
VCS_FLAGS += +define+SVT_AHB_DISABLE_IMPLICIT_BUS_CONNECTION

VCS_FLAGS += -cm line+cond+tgl+fsm+branch
VCS_FLAGS += -top test_top

UVM_HOME     = $(VCS_HOME)/etc/uvm-1.2
VCS_FLAGS += +incdir+$(UVM_HOME)

VCS_FLAGS += +incdir+$(SVT_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(AMBA_HOME)/sverilog/include
VCS_FLAGS += +incdir+$(RTL_DIR)
VCS_FLAGS += +incdir+$(RTL_DIR)/fifo
VCS_FLAGS += +incdir+$(TB_DIR)
VCS_FLAGS += +incdir+$(ENV_DIR)
VCS_FLAGS += +incdir+$(AGENT_DIR)
VCS_FLAGS += +incdir+$(SEQ_DIR)
VCS_FLAGS += +incdir+$(INT_SEQ_DIR)
VCS_FLAGS += +incdir+$(TOP_SEQ_DIR)
VCS_FLAGS += +incdir+$(TEST_DIR)

VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/com
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/com
VCS_FLAGS += +libext+.svp+.sv+.svi+.svh

# Top-level testbench
VCS_FLAGS += $(TB_DIR)/top.sv

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

# TideLink FC Adapter
VCS_FLAGS += $(RTL_DIR)/tidelink_fc_adapter.sv

# TideLink PTP + Servo + CDC + Multiplier
VCS_FLAGS += $(RTL_DIR)/tidelink_ptp.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_mul_iter.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_ptp_servo.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_phc_cdc.sv

# TideLink Address Translator (and its sub-modules)
VCS_FLAGS += $(RTL_DIR)/tl_addr_trans_regs.sv
VCS_FLAGS += $(RTL_DIR)/tl_addr_trans_cam.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_addr_translator.sv

# PHC (PTP Hardware Clock) RTL
VCS_FLAGS += $(PHC_DIR)/phc_clock_core.sv
VCS_FLAGS += $(PHC_DIR)/phc_apb_regs.sv
VCS_FLAGS += $(PHC_DIR)/phc.sv

# XHB500 AHB-to-AXI bridge (subordinate path)
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/shared/verilog/xhb500_regd_slice/verilog/xhb500_bypass_regd_slice.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/shared/verilog/xhb500_regd_slice/verilog/xhb500_reverse_regd_slice_rst_empty.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_pkg.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_hazard_list.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_strb.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_core_addr.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_core_wdata.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_core_resp.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv_core.sv
VCS_FLAGS += $(XHB500_SLV_DIR)/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/xhb500_ahb_to_axi_bridge_chiplet_slv.sv

# XHB500 AXI-to-AHB bridge (manager path)
VCS_FLAGS += $(XHB500_MST_DIR)/logical/models/cells/generic/xhb500_or.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/models/cells/generic/xhb500_xor.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/models/cells/generic/xhb500_flop.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/models/cells/generic/xhb500_sync.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/shared/verilog/xhb500_regd_slice/verilog/xhb500_bypass_regd_slice_empty.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/shared/verilog/xhb500_regd_slice/verilog/xhb500_forward_regd_slice.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/shared/verilog/xhb500_regd_slice/verilog/xhb500_forward_regd_slice_empty.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_pkg.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_core.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_core_xin.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_core_h_xout.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_xreg.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_hreg.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_respreg_r.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_respreg_b.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_lpi.sv
VCS_FLAGS += $(XHB500_MST_DIR)/logical/xhb500_axi_to_ahb_bridge_chiplet_mst/verilog/xhb500_axi_to_ahb_bridge_chiplet_mst_strbgen.sv

# Wlink chiplet controller.
# 2026-07 un-rot: dropped the stale `-y wav-wlink-hw/output_tidelink_gpio`
# search dir — its sbt-regenerated WlinkRxLinkLayer lacks the io_obs_* ports
# that the committed logical/wlink set drives (shadowed logical/wlink, broke
# elaboration). See the QUARANTINE note near TESTS for the remaining blocker.
VCS_FLAGS += +libext+.v

# Wlink PHY (GPIO behavioural model)
VCS_FLAGS += -y $(DEPS_DIR)/logical/PHY/generic
VCS_FLAGS += -y $(DEPS_DIR)/logical/wlink
VCS_FLAGS += +libext+.v

# 2026-07-30 (verification audit, docs/VERIFICATION_AUDIT_2026_07_30.md §A5):
# same de-quarantine re-point as uvm/tidelink_top_system — this env explicitly
# compiled 5 of the 17 files flists/tidelink_fpga.flist takes from
# src/rtl/local_overrides/ instead of $(DEPS_DIR); the other 12 (incl.
# axi_chiplet_controller.sv / tidelink_autoneg.sv, the actual UPIMI cause —
# tidelink_top.sv instantiates them with obs_*/apb_ctrl_reg_* ports that exist
# only in the local_overrides copies) were never listed, so `-y` silently
# resolved them to stale deps/ originals. Order mirrors the flist.
VCS_FLAGS += $(RTL_DIR)/local_overrides/ShortPacketToWlink.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/TideLinkToWlink.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/tidelink_lane_deskew.sv
VCS_FLAGS += $(RTL_DIR)/local_overrides/WavD2DGpio.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WavD2DGpioTx.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WavD2DGpioRx.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WavMultibitSync_18.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WlinkGPIOPHY.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WlinkGenericFCReplayV2_12.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WlinkGenericFCReplayV2_13.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WlinkGenericFCSM_6.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/WlinkRxLinkLayer.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/Wlink.v

# Address translator dependencies
VCS_FLAGS += $(DEPS_DIR)/logical/interfaces/apb4_if.sv
VCS_FLAGS += $(DEPS_DIR)/logical/apb_control/apb_control.sv
VCS_FLAGS += $(DEPS_DIR)/logical/address_translation/address_translation.sv
VCS_FLAGS += $(CMSDK_DIR)/logical/cmsdk_apb_slave_mux/verilog/cmsdk_apb_slave_mux.v

# Bridge dependencies
VCS_FLAGS += -y $(DEPS_DIR)/logical/bridges
VCS_FLAGS += +libext+.v

# I2C master/slave (used by axi_chiplet_controller)
VCS_FLAGS += -y $(DEPS_DIR)/logical/i2c/rtl
VCS_FLAGS += +libext+.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/i2c_master_axil.v
VCS_FLAGS += $(RTL_DIR)/local_overrides/i2c_master.v

# Autonegotiation and chiplet controller top (Wlink wrapper) — THE UPIMI FIX.
VCS_FLAGS += $(RTL_DIR)/local_overrides/tidelink_autoneg.sv
VCS_FLAGS += $(RTL_DIR)/local_overrides/axi_chiplet_controller.sv

# Performance counter
VCS_FLAGS += $(RTL_DIR)/tidelink_perf.sv
# Lane checker moved out of src/rtl into the tidelink-gpio-phy submodule
# (commit d043909: "stage3: replace tidelink_lane_checker.sv with
# tidelink-gpio-phy submodule"). Repoint to the submodule's self-contained
# set — matches flists/tidelink_lane_checker.flist: popcount16 + single-lane
# matcher + 8-lane wrapper, with the incdir for tidelink_training_patterns.svh.
VCS_FLAGS += +incdir+$(PROJ_HOME)/deps/tidelink-gpio-phy/rtl
VCS_FLAGS += $(PROJ_HOME)/deps/tidelink-gpio-phy/rtl/tidelink_popcount16.sv
VCS_FLAGS += $(PROJ_HOME)/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker_single.sv
VCS_FLAGS += $(PROJ_HOME)/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv
VCS_FLAGS += $(PROJ_HOME)/deps/tidelink-gpio-phy/rtl/tidelink_gpio_phy_apb_regs.sv
# PHY RX helper cells wired into axi_chiplet_controller during the June
# eye-visibility-v2 work (post-dated the spring UVM freeze — u_rxclk_buf /
# u_idelay_rx / u_eye_regs instances in axi_chiplet_controller.sv).
VCS_FLAGS += $(RTL_DIR)/tidelink_idelay_rx.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_rxclk_buf.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_eye_regs.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_phy_align_calibrator.sv

# TideLink top module
# v1 PL-side TX traffic generator - instantiated by tidelink_top.sv:990 in
# g_txgen. Added 2026-07-24 (docs/TXGEN_V1_DESIGN.md) and NOT added here, which
# made this env fail with a NEW error (CFCILFBI "Cell 'tidelink_tx_gen' cannot
# be found in liblist") ON TOP of the documented UPIMI blocker below. Because
# the CI job is allow_failure the extra rot layer was invisible. Restored
# 2026-07-30 so the remaining failure is the ONE blocker the note describes.
VCS_FLAGS += $(RTL_DIR)/tidelink_tx_gen.sv

VCS_FLAGS += $(RTL_DIR)/tidelink_top.sv

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

# ===========================================================================
# QUARANTINED 2026-07-07 (infra/uvm-ci-reactivation) — DOES NOT ELABORATE
# ---------------------------------------------------------------------------
# UVM froze ~2026-05; RTL churned through Jun/Jul. Two rot layers were fixed
# here (lane_checker -> tidelink-gpio-phy submodule; new PHY helper cells
# idelay_rx/rxclk_buf/eye_regs/gpio_phy_apb_regs; stale sbt output_tidelink_gpio
# -y dropped). REMAINING blocker needs real UVM-build work:
#   current src/rtl/tidelink_top.sv instantiates axi_chiplet_controller with
#   ports that exist ONLY in src/rtl/local_overrides/axi_chiplet_controller.sv
#   (obs_a2l_replay_{app,link}_valid_o, obs_fe_rx_{is_full,credit_max}_o,
#   train_fail_irq_o, apb_ctrl_reg_{write,addr,wdata}), but this Makefile
#   compiles the PINNED submodule copy deps/axi-chiplet-controller/logical/top/
#   axi_chiplet_controller.sv which predates those ports -> VCS UPIMI.
# TODO: re-point the top/wlink source list to the src/rtl/local_overrides set
#   that flists/tidelink_fpga.flist uses (14 overrides incl. axi_chiplet_controller,
#   tidelink_autoneg, Wlink, WlinkRxLinkLayer, WlinkGenericFCSM_6, WavD2DGpio{,Rx,Tx}).
#   The cocotb tidelink_top_pair env already tracks that flist. The CI job is
#   honestly allow_failure with this reason (not fake-green) — see .gitlab-ci.yml.
# ===========================================================================
# ---------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------
TESTS = test_chain_convergence \
        test_chain_lock_propagation \
        test_chain_step_recovery \
        test_chain_b_unlock_c_holds \
        test_chain_stress \
        test_chain_force_enable \
        test_chain_gate_functional

# ---------------------------------------------------------------
# Targets
# ---------------------------------------------------------------
.PHONY: compile run clean coverage run_all help waves

help:
	@echo "TideLink PTP Chain Testbench"
	@echo ""
	@echo "  make compile                    - Compile testbench"
	@echo "  make run TEST=<test_name>       - Compile and run a specific test"
	@echo "  make run_all                    - Run all tests"
	@echo "  make coverage                   - Generate merged coverage report"
	@echo "  make clean                      - Remove all build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  test_chain_convergence          - A->B->C cascaded lock convergence"
	@echo "  test_chain_lock_propagation     - Measure B-lock to C-lock delay"
	@echo "  test_chain_step_recovery        - Phase step on A, verify chain recovery"
	@echo "  test_chain_b_unlock_c_holds     - Disrupt A-B, verify C pauses"
	@echo "  test_chain_stress               - PTP + background FIFO traffic"
	@echo "  test_chain_force_enable         - hw_sync_force_en bypasses lock gate"

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

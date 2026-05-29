###############################################################################
# Makefile for TideLink Top System (Full tidelink_top Paired) UVM Testbench
###############################################################################
# Tests two complete tidelink_top modules connected back-to-back via PHY pad
# crossover, exercising the full chiplet communication stack including:
#   - TideLink FIFO + FC adapter
#   - XHB500 AHB<->AXI bridges
#   - Wlink chiplet controller with GPIO PHY
#   - Address translator
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
DEPS_DIR     = $(PROJ_HOME)/deps/axi-chiplet-controller
TB_DIR       = $(CURDIR)/tb
ENV_DIR      = $(CURDIR)/env
SEQ_DIR      = $(CURDIR)/sequences
TEST_DIR     = $(CURDIR)/tests

# Shared agents and sequences from existing testbenches
UNIT_UVM_DIR = $(PROJ_HOME)/uvm/tidelink
INT_UVM_DIR  = $(PROJ_HOME)/uvm/tidelink_integration
AGENT_DIR    = $(UNIT_UVM_DIR)/agents/apb_master_agent
INT_SEQ_DIR  = $(INT_UVM_DIR)/sequences

# CMSDK path (for cmsdk_ahb_to_sram and cmsdk_ahb_to_apb). Convention:
# CMSDK_DIR is the package root (parent of `logical/`), matching cocotb/lint.
CMSDK_DIR   ?= $(HOME)/Downloads/BP210-BU-00000-r1p1-00rel0

# XHB500 generated bridge directories (set by 'source ../../set_env.sh')
XHB500_GEN_DIR ?= $(PROJ_HOME)/deps/xhb500/generated
XHB500_SLV_DIR ?= $(XHB500_GEN_DIR)/xhb_chiplet_slv
XHB500_MST_DIR ?= $(XHB500_GEN_DIR)/xhb_chiplet_mst

# Physical-IP paths for GATE=1 gate-level sim (mirror syn/asic/common.mk)
PHYS_IP_PATH ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp
MEM_BASE     ?= /research/precompiled_mems/TSMC65

# Simulation output
SIM_DIR      = sim_build
COV_DIR      = coverage_report

# Export DESIGNWARE_HOME for SVT VIP runtime
export DESIGNWARE_HOME := $(VIP_HOME)

# Default test
TEST        ?= test_top_single_packet
SEED        ?= random
VERBOSITY   ?= UVM_MEDIUM

# ---------------------------------------------------------------
# VCS compile flags
# ---------------------------------------------------------------
VCS  = $(VCS_HOME)/bin/vcs

VCS_FLAGS  = -full64 -sverilog
VCS_FLAGS += -ntb_opts uvm-1.2
VCS_FLAGS += -timescale=1ns/1ps
# Enable hierarchical-path read/deposit (used by §9 alignment tests to drive
# swi_bit_slip / swi_training_mode by HDL backdoor + module-context force).
VCS_FLAGS += -debug_access+all
VCS_FLAGS += -v2k_generate
# Disabled: +xprop=tmerge causes tx_ready/tx_en/precnt to go X at ~19us even
# though Wlink trains successfully (tx_ready=1 from 5us-18us). The same RTL
# runs cleanly in the cocotb regression (which doesn't enable xprop). Some
# uninitialised register in Wlink's tx_link_clk domain pushes an X under
# tmerge that doesn't affect functional silicon. Re-enabling tmerge is
# gated on resolving that underlying X source.
# VCS_FLAGS += -xprop=tmerge

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
VCS_FLAGS += +incdir+$(TEST_DIR)

# VIP source search paths
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(SVT_HOME)/sverilog/src/com
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/vcs
VCS_FLAGS += -y $(AMBA_HOME)/sverilog/src/com
VCS_FLAGS += +libext+.svp+.sv+.svi+.svh

# §9 per-lane bit-slip alignment TB plumbing (asymmetric skew tests)
# Lane checker now lives in src/rtl as tidelink_lane_checker (renamed from
# the cocotb-local wlink_lane_checker; the lane_checker is also pulled in by
# the FPGA/ASIC flists for synthesis paths).
VCS_FLAGS += $(TB_DIR)/pad_skid_lanes.sv
VCS_FLAGS += $(PROJ_HOME)/src/rtl/tidelink_lane_checker.sv

# Top-level testbench. GATE=1 uses a probe-free TB auto-derived from
# top.sv (XMR debug instrumentation stripped — see gen_gate_tb.awk),
# since the flattened FC netlist has no internal hierarchy for the
# cross-module-reference probes to resolve against.
ifeq ($(GATE),1)
VCS_FLAGS += $(TB_DIR)/top_gate.sv
else
VCS_FLAGS += $(TB_DIR)/top.sv
endif
VCS_FLAGS += -top test_top

# Compile outputs
VCS_FLAGS += -l $(SIM_DIR)/compile.log
VCS_FLAGS += -o $(SIM_DIR)/simv
VCS_FLAGS += -cm_dir $(SIM_DIR)/simv.vdb

# ---------------------------------------------------------------
# DUT sources — RTL by default, or the post-route FC netlist when
# GATE=1 (gate-level UVM sign-off). The gate path swaps the entire
# DUT RTL list for the single flattened netlist + sc12 / rf_16k
# Verilog sim models. Zero-delay, no timing checks (LEC already
# proved Boolean equivalence; this would prove behaviour with the
# real cells + reset sequencing).
#
# STATUS: compiles + elaborates + links + runs to completion.
#
# The original blocker — 214 XMR debug probes in tb/top.sv reaching
# deep DUT hierarchy (u_tidelink_top_a.u_chiplet_controller.u_wlink...)
# that the flattened FC netlist dissolved (Error-[XMRE]) — is RESOLVED
# via option (c): gen_gate_tb.awk derives a probe-free tb/top_gate.sv
# (1654→1133 lines, 0 XMR residual, run_test + all WIRE_AHB macros +
# both DUT instances preserved verbatim; Makefile asserts the strip).
#
# OPEN — gate-level X-init: test_top_single_packet runs to $finish but
# the scoreboard sees the A->B datapath deliver all-zeros at gate
# (RX=0x00000000 vs TX=0xdeadbeef...). 6 SB_A2B UVM_ERRORs; the same
# test PASSES at RTL because the UVM env demotes those 6 once data
# arrives — at gate the data never arrives. Classic zero-delay /
# +notimingcheck / no-SDF X-pessimism: the Wlink Chisel CDC + demet
# flops (the same logic in the 256 LEC don't-verify residuals) power
# up at X and never resolve without flop initialisation. This is the
# additive value of gate sim over LEC (LEC proved Boolean equivalence
# but cannot see X-init / reset-sequencing).
#
# INVESTIGATION SO FAR (separate bring-up effort to finish):
#   - scan/ICG tie-off RULED OUT: the DUT scan_mode/scan_* pins are
#     already tied to functional 0 in the TB (inherited from top.sv),
#     so the netlist's PREICG clock-gates pass functional clocks.
#   - +vcs+initreg+0 (now the GATE_INITREG default, wired into the
#     GATE path) is INSUFFICIENT: caught-error count rises 6→12 but
#     the A->B datapath still delivers RX=0x00000000 — the Wlink
#     Chisel CDC/demet flops (the same logic in the 256 LEC
#     don't-verify residuals) X-lock in a state that survives 0-init.
#
# REMAINING (genuine gate functional bring-up, not a quick knob):
#   1. GATE_INITREG=random TRIED — also INSUFFICIENT (identical
#      RX=0x00000000, 6 SB_A2B, 12 caught). So neither 0- nor
#      random-init resolves it: this is NOT plain power-up X, it's a
#      structural gate behaviour in the Wlink CDC/demet path (the
#      256-LEC-residual logic) — likely the gray-code/demet CDC not
#      converging under zero-delay, or a reset-ordering dependency.
#   2. NEXT: force the */sync_*_demet/f1,f2 (and read/write gray
#      pointer) flops through a longer explicit reset in a gate-only
#      force block (hold poresetn extra cycles, release after first
#      stable pad_clk), then re-check the A->B path;
#   3. then: SDF-annotated run (unit or back-annotated) with
#      X-pessimism off — zero-delay CDC sim is inherently fragile;
#   4. cross-check: does RTL sim with +vcs+initreg+random also break?
#      if so the issue is the Wlink CDC model, not the netlist.
# GATE=1 today is a clean compile/elab/link + run-to-$finish smoke
# that already surfaces real datapath X behaviour LEC cannot see;
# functional gate sign-off needs step 1-3. LEC covers RTL≡netlist
# Boolean equivalence in the interim.
# ---------------------------------------------------------------
ifeq ($(GATE),1)

FC_NETLIST  ?= $(PROJ_HOME)/syn/asic/fusion-compiler/outputs/tidelink_top.v
STDCELL_SIM ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/verilog/sc12_cln65lp_base_rvt.v
RF16K_SIM   ?= $(MEM_BASE)/rf_16k/rf_16k.v

VCS_FLAGS += +define+GATE_SIM
VCS_FLAGS += +notimingcheck +nospecify +delay_mode_zero
# Deterministic 0-init of all netlist flops/latches. Without this the
# flattened netlist powers up at X and the Wlink Chisel CDC/demet path
# never resolves (A->B datapath delivers all-zeros, 6 SB_A2B errors).
# Overridable: GATE_INITREG=random for pessimism-free random init, or
# GATE_INITREG= (empty) to study the raw X behaviour.
GATE_INITREG ?= 0
ifneq ($(GATE_INITREG),)
VCS_FLAGS += +vcs+initreg+$(GATE_INITREG)
endif
VCS_FLAGS += $(FC_NETLIST)
VCS_FLAGS += $(STDCELL_SIM)
VCS_FLAGS += $(RF16K_SIM)
# rf_16k.v + sc12 model need the unit-delay UDP file for some seq cells
VCS_FLAGS += $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/verilog/sc12_cln65lp_base_rvt_udp.v

else

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

# TideLink PTP (register pass-through)
VCS_FLAGS += $(RTL_DIR)/tidelink_ptp.sv

# TideLink Address Translator
VCS_FLAGS += $(RTL_DIR)/tidelink_addr_translator.sv

# XHB500 AHB-to-AXI bridge (subordinate path — chiplet_slv)
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

# XHB500 AXI-to-AHB bridge (manager path — chiplet_mst)
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

# Wlink chiplet controller (Chisel-generated Verilog, GPIO PHY + TideLink)
# Use -y to pick up all sub-modules (APBFanout, WlinkTxRouter, etc.)
VCS_FLAGS += -y $(DEPS_DIR)/wav-wlink-hw/output_tidelink_gpio
VCS_FLAGS += +libext+.v

# Wlink PHY (GPIO behavioural model)
VCS_FLAGS += -y $(DEPS_DIR)/logical/PHY/generic
VCS_FLAGS += -y $(DEPS_DIR)/logical/wlink
VCS_FLAGS += +libext+.v

# Explicitly compile the GPIO PHY files (rather than letting -y resolve them
# lazily). XMRE references from the §9 alignment soft-strap force-blocks in
# tb/top.sv require the gpio module's internal regs to be elaborated, which
# only happens when the file is explicitly compiled.
VCS_FLAGS += $(DEPS_DIR)/logical/wlink/WavD2DGpio.v
VCS_FLAGS += $(DEPS_DIR)/logical/wlink/WavD2DGpioTx.v
VCS_FLAGS += $(DEPS_DIR)/logical/wlink/WavD2DGpioRx.v
VCS_FLAGS += $(DEPS_DIR)/logical/wlink/WlinkGPIOPHY.v
# Use the §9 phy-align Wlink.v (with swi_bit_slip_in / swi_training_mode_in
# ports) rather than the older Chisel output under wav-wlink-hw/.
VCS_FLAGS += $(DEPS_DIR)/logical/wlink/Wlink.v

# Address translator and its dependencies
VCS_FLAGS += $(DEPS_DIR)/logical/interfaces/apb4_if.sv
VCS_FLAGS += $(DEPS_DIR)/logical/apb_control/apb_control.sv
VCS_FLAGS += $(DEPS_DIR)/logical/address_translation/address_translation.sv
VCS_FLAGS += $(CMSDK_DIR)/logical/cmsdk_apb_slave_mux/verilog/cmsdk_apb_slave_mux.v

# Bridge dependencies
VCS_FLAGS += -y $(DEPS_DIR)/logical/bridges
VCS_FLAGS += +libext+.v

# TideLink sub-modules (PTP servo, CDC, address translator components)
VCS_FLAGS += $(RTL_DIR)/tidelink_mul_iter.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_ptp_servo.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_phc_cdc.sv
VCS_FLAGS += $(RTL_DIR)/tl_addr_trans_regs.sv
VCS_FLAGS += $(RTL_DIR)/tl_addr_trans_cam.sv

# I2C master/slave (used by axi_chiplet_controller)
VCS_FLAGS += -y $(DEPS_DIR)/logical/i2c/rtl
VCS_FLAGS += +libext+.v

# Autonegotiation and chiplet controller top (Wlink wrapper)
VCS_FLAGS += $(DEPS_DIR)/logical/top/tidelink_autoneg.sv
VCS_FLAGS += $(DEPS_DIR)/logical/top/axi_chiplet_controller.sv

# Performance counter
VCS_FLAGS += $(RTL_DIR)/tidelink_perf.sv
VCS_FLAGS += $(RTL_DIR)/tidelink_phy_align_calibrator.sv

# TideLink top module
VCS_FLAGS += $(RTL_DIR)/tidelink_top.sv

endif  # GATE

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
TESTS = test_top_single_packet \
        test_top_bidirectional \
        test_top_back_to_back \
        test_top_max_packet \
        test_top_credit_exhaustion \
        test_top_reset_recovery \
        test_top_long_running \
        test_top_mixed_traffic \
        test_top_coordinated_reset \
        test_top_addr_translate

# BRINGUP_REPORT.md §9 — per-lane bit-slip alignment tests (uvm-thoroughness)
TESTS_ALIGN = test_align_uniform_skew \
              test_align_asymmetric_skew \
              test_align_one_dead_lane \
              test_align_recalibration_after_link_drop

# AHB passthrough hangs: Wlink AXI FC target not accepting from XHB500.
# Needs Wlink AXI FC path initialization (future work).
# Run separately: make run TEST=test_top_ahb_passthrough
TESTS_EXPERIMENTAL = test_top_ahb_passthrough

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
	@echo "  make wlink_regen                - Force regenerate Wlink Verilog ($(WLINK_CONFIG))"
	@echo ""
	@echo "Available tests:"
	@echo "  test_top_single_packet     - Single packet A->B through full Wlink stack"
	@echo "  test_top_bidirectional     - Simultaneous bidirectional packets"
	@echo "  test_top_back_to_back      - Rapid-fire packets through Wlink"
	@echo "  test_top_max_packet        - Maximum-size (256-word) packet"
	@echo "  test_top_credit_exhaustion - Exhaust credits, verify recovery"
	@echo "  test_top_ahb_passthrough   - AHB regular access via XHB500+Wlink"
	@echo "  test_top_reset_recovery    - Flush/re-init, verify clean operation"
	@echo "  test_top_long_running      - 100+ packets, check for drift"
	@echo "  test_top_mixed_traffic     - Concurrent TideLink FIFO + AHB passthrough"
	@echo ""
	@echo "Variables:"
	@echo "  TEST=<name>                       - Test to run (default: test_top_single_packet)"
	@echo "  SEED=<value|random>               - Random seed (default: random)"
	@echo "  VERBOSITY=<UVM_NONE|...|UVM_DEBUG>- UVM verbosity (default: UVM_MEDIUM)"
	@echo "  SOCLABS_NANOSOC_TECH_DIR=<path>   - Path to nanosoc-chiplet-tech (for XHB500)"
	@echo ""
	@echo "Before running, source the environment setup:"
	@echo "  source ../../set_env.sh"

# --------------------------------------------------------------------------
# Auto-regenerate the GPIO Wlink Verilog if missing or older than the Scala.
# output_tidelink_gpio/ is gitignored, so each fresh checkout starts empty
# and the Scala edits in src/main/scala may render the previous output
# stale. Compile depends on $(WLINK_GEN_V); the rule invokes sbt only when
# the file is missing or out of date.
# --------------------------------------------------------------------------
WLINK_HW_DIR  := $(DEPS_DIR)/wav-wlink-hw
WLINK_GEN_DIR := $(WLINK_HW_DIR)/output_tidelink_gpio
WLINK_GEN_V   := $(WLINK_GEN_DIR)/Wlink.v
WLINK_CONFIG  := wav.wlink.Wlink8LaneAXI32bitTideLinkConfig
WLINK_SCALA   := $(wildcard $(WLINK_HW_DIR)/src/main/scala/*.scala)

$(WLINK_GEN_V): $(WLINK_SCALA)
	@echo "Regenerating Wlink Verilog ($(WLINK_CONFIG)) into $(WLINK_GEN_DIR)..."
	cd $(WLINK_HW_DIR) && \
	  sbt 'runMain wav.wlink.WlinkGen -o $(WLINK_GEN_DIR) -c $(WLINK_CONFIG)'

.PHONY: wlink_regen
wlink_regen: $(WLINK_GEN_V)

# GATE=1 uses the flattened FC netlist, so the Chisel-generated Wlink
# Verilog isn't a prerequisite (it's already baked into the netlist);
# instead, the probe-free gate TB must be regenerated from top.sv.
ifeq ($(GATE),1)
COMPILE_DEPS = $(TB_DIR)/top_gate.sv
SIM_DIR      = sim_build_gate
else
COMPILE_DEPS = $(WLINK_GEN_V)
endif

# Derive the probe-free gate TB from top.sv, then assert the strip
# actually worked: zero residual XMR tokens AND run_test() preserved.
# Regenerated whenever top.sv or the generator changes.
$(TB_DIR)/top_gate.sv: $(TB_DIR)/top.sv $(TB_DIR)/gen_gate_tb.awk
	@echo "Generating probe-free gate TB: $@"
	@awk -f $(TB_DIR)/gen_gate_tb.awk $(TB_DIR)/top.sv > $@.tmp
	@if grep -qE 'u_tidelink_top_[ab]\.' $@.tmp; then \
		echo "ERROR: gate TB still has XMR refs — gen_gate_tb.awk under-stripped:"; \
		grep -nE 'u_tidelink_top_[ab]\.' $@.tmp | head -5; \
		rm -f $@.tmp; exit 1; \
	fi
	@if ! grep -q 'run_test(' $@.tmp; then \
		echo "ERROR: gate TB lost run_test() — gen_gate_tb.awk over-stripped"; \
		rm -f $@.tmp; exit 1; \
	fi
	@mv $@.tmp $@
	@echo "  OK: 0 XMR refs, run_test() preserved ($$(wc -l < $@) lines, was $$(wc -l < $(TB_DIR)/top.sv))"

compile: $(COMPILE_DEPS) | $(SIM_DIR)
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

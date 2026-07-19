# =============================================================================
# eth_tidelink_pair_m1 — Ethernet-over-TideLink M1 bench (real subsystem).
#
# M1 first substep of docs/ETHERNET_CHIPLET_INTEGRATION.md: replace the M0
# scratch-RAM attach with the WHOLE `ethernet_ss_ahb` subsystem behind die_b's
# `ahb_mng`, via the subsystem's external AHB slave port `eth_ss_0`. The
# link-crossed write now transits the subsystem's OWN AHB matrix into
# eth_scratch_rx (0x3000_0000) — surfacing the real matrix hready / hprot /
# burst bus contract.
#
# Compile set = tidelink V2 pair flist  +  the ethernet_ss_ahb subsystem's OWN
# recipe (mirrored from nanoSoC-refactor/ethernet-subsystem-ahb/cocotb/
# ethernet_ss_ahb/Makefile, which already builds a clean VCS simv). The 4
# cmsdk models common to both flists (cmsdk_ahb_to_sram/_fpga_sram/_ahb_to_apb/
# _apb_slave_mux) resolve to IDENTICAL absolute paths under a single CMSDK_DIR,
# so VCS dedups them — no manual collision surgery. HEAVYWEIGHT deps pulled in
# by the subsystem (read-only, flist-referenced, never modified):
#   * Cortex-M0+ core     ARM_CORTEXM0PLUS_IP_PATH (/research/AAA)
#   * OpenCores EthMAC     ETHMAC_IP_DIR  (/research/AAA)  + HA1588 HA1588_IP_DIR
#   * eth_ss bootrom .sv   $(ETH_SS_HOME)/build/firmware/bootloader/out
#
# Run:
#   cd cocotb/eth_tidelink_pair_m1
#   source ../../set_env.sh                       # tidelink env (CMSDK_DIR etc.)
#   source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh  # eth env
#   export TIDELINK_PHY_V2=1
#   make                                          # EPOCH_PROFILE=zero -> THE M1 GATE
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Ethernet subsystem repo (read-only reference). The subsystem's set_env.sh must
# be sourced first (sets ETH_SS_HOME, ETHMAC_AHB_HOME, SOCLABS_*, ARM_CORTEXM0PLUS
# _IP_PATH, ETHMAC_IP_DIR, HA1588_IP_DIR, AHB_BRIDGES_HOME). Fall back to the
# known checkout path if unset.
ETH_SS_HOME     ?= $(realpath $(TIDELINK_HOME)/../nanoSoC-refactor/ethernet-subsystem-ahb)
export ETH_SS_HOME
ETH_SS_COCOTB   := $(ETH_SS_HOME)/cocotb/ethernet_ss_ahb
ETHMAC_AHB_HOME ?= $(ETH_SS_HOME)/ethernet-mac-ahb
export ETHMAC_AHB_HOME

PAIR_V2_DIR = $(TIDELINK_HOME)/cocotb/tidelink_top_pair_v2

# EPOCH_PROFILE / SIM_BUILD defined early — the eth flist-generation rules below
# reference $(SIM_BUILD) at rule-read time.
EPOCH_PROFILE ?= zero
SIM_BUILD := sim_build_$(EPOCH_PROFILE)

TOPLEVEL = tb_top
MODULE  ?= test_eth_relay_m1

# Import PairV2TB / AHBSubMaster from the pair_v2 bench + the tidelink python pkg
# + this dir (eth_pair_common).
export PYTHONPATH := $(CURDIR):$(PAIR_V2_DIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# ---- tb sources (fork of the M0 bench) -------------------------------------
VERILOG_SOURCES  = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/eye_fault.sv

# ---- TideLink V2 pair flist (carries +define+TIDELINK_PHY_V2 via v2shims; also
#      compiles the shared cmsdk models) --------------------------------------
V2_FLIST ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(V2_FLIST)

# =============================================================================
# ethernet_ss_ahb subsystem compile recipe (mirrored from the subsystem's own
# proven cocotb Makefile).  Expanded flists are regenerated into sim_build.
# =============================================================================
EXPANDED_FLIST         = $(CURDIR)/$(SIM_BUILD)/eth_expanded.flist
ETHMAC_SUBSYSTEM_FLIST = $(CURDIR)/$(SIM_BUILD)/ethmac_subsystem_apb_expanded.flist
EXPAND = $(ETH_SS_COCOTB)/expand_flist.sh

CUSTOM_COMPILE_DEPS += $(EXPANDED_FLIST) $(ETHMAC_SUBSYSTEM_FLIST)

COMPILE_ARGS += -f $(EXPANDED_FLIST)
COMPILE_ARGS += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/src/regions/dmem/nanosoc_region_dmem.v
COMPILE_ARGS += $(ETH_SS_HOME)/src/rtl/ethmac_subsystem_ahb.v
COMPILE_ARGS += -f $(ETHMAC_SUBSYSTEM_FLIST)
COMPILE_ARGS += $(ETH_SS_HOME)/src/rtl/apb_subsystem/eth_ss_apb_subsystem.v
COMPILE_ARGS += $(ETH_SS_HOME)/src/rtl/apb_subsystem/eth_ss_sysctrl.v
COMPILE_ARGS += $(CMSDK_DIR)/logical/cmsdk_apb_timer/verilog/cmsdk_apb_timer.v
COMPILE_ARGS += $(CMSDK_DIR)/logical/cmsdk_apb_uart/verilog/cmsdk_apb_uart.v
COMPILE_ARGS += $(ETH_SS_HOME)/build/firmware/bootloader/out/eth_ss_bootrom.sv
COMPILE_ARGS += $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_rom.v
COMPILE_ARGS += $(ETH_SS_HOME)/src/rtl/fpga_lib/rom/sl_fpga_rom_word.v

# subsystem compile defines / incdirs (from the subsystem Makefile)
COMPILE_ARGS += +define+CPU_M0PLUS
COMPILE_ARGS += +define+ETH_WISHBONE_B3
COMPILE_ARGS += +define+RAM_PRELOAD
COMPILE_ARGS += +incdir+$(ETH_SS_HOME)/src/rtl
# IMEM spin image (park the CPU) — absolute path so $readmemh resolves anywhere.
COMPILE_ARGS += +define+ETH_IMEM_HEX=\"$(CURDIR)/image_spin.hex\"

# =============================================================================
# Autoneg / epoch knobs — identical to the M0 bench.
# =============================================================================
BYPASS_AUTONEG ?= 1
export BYPASS_AUTONEG
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)
RELY_ON_RTL_PRIO_DEFAULTS ?= 0
COMPILE_ARGS += +define+TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS=$(RELY_ON_RTL_PRIO_DEFAULTS)

ifeq ($(EPOCH_PROFILE),zero)
EPOCH_DEFINES =
else ifeq ($(EPOCH_PROFILE),silicon)
EPOCH_DEFINES = \
	+define+TB_TOP_EPOCH_S2M_L0=3 +define+TB_TOP_EPOCH_S2M_L1=7 \
	+define+TB_TOP_EPOCH_S2M_L2=5 +define+TB_TOP_EPOCH_S2M_L3=4 \
	+define+TB_TOP_EPOCH_S2M_L4=6 +define+TB_TOP_EPOCH_S2M_L5=3 \
	+define+TB_TOP_EPOCH_S2M_L6=7 +define+TB_TOP_EPOCH_S2M_L7=5
EPOCH_ANCHOR := 1
else
$(error EPOCH_PROFILE must be zero|silicon)
endif
COMPILE_ARGS += $(EPOCH_DEFINES)

EPOCH_ANCHOR ?= 0
ifeq ($(EPOCH_ANCHOR),1)
COMPILE_ARGS += +define+TIDELINK_EPOCH_ANCHOR
endif

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# ── eth flist-expansion recipes (AFTER the include so the cocotb `sim` target
#    stays the default goal — mirrors the subsystem's own Makefile) ──────────
$(EXPANDED_FLIST):
	@mkdir -p $(dir $@)
	bash $(EXPAND) $(ETH_SS_HOME)/flist/ethernet_ss_ahb.flist > $@

$(ETHMAC_SUBSYSTEM_FLIST):
	@mkdir -p $(dir $@)
	bash $(EXPAND) $(ETHMAC_AHB_HOME)/flist/ethmac_subsystem_apb.flist > $@

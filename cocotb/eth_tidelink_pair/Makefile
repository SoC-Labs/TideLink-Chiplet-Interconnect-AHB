# =============================================================================
# eth_tidelink_pair — Ethernet-over-TideLink M0 integration smoke (weekend W4).
#
# Forks cocotb/tidelink_top_pair_v2 (two cross-wired V2 `tidelink_top` dies,
# GPIO-PHY skew injection, per-die APB, and the EXPOSED master `ahb_sub` peer
# window). The ONE change: each die's `ahb_mng` terminus is a REAL
# ethernet-subsystem scratch RAM (`nanosoc_region_sram` -> `sl_ahb_sram`)
# instead of the throwaway `tb_ahb_bram_slave`. See docs/ETHERNET_CHIPLET_
# INTEGRATION.md (M0) + docs/W4_ETHERNET_SCAFFOLD_NOTES.md §3.
#
# The two cmsdk deps of sl_ahb_sram (cmsdk_ahb_to_sram + cmsdk_fpga_sram) are
# ALREADY compiled by flists/tidelink_fpga_v2.flist, so the only NEW RTL added
# here is the two SoC Labs wrapper files. Always a V2 build (TIDELINK_PHY_V2
# rides in tidelink_fpga_v2.flist). Simulator = VCS.
#
# Run:
#   source ../../set_env.sh ; export TIDELINK_PHY_V2=1
#   make                       # EPOCH_PROFILE=zero, test_eth_relay_smoke
#   make EPOCH_PROFILE=silicon # v37 skew fingerprint on the S->M path
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Ethernet subsystem repo (read-only reference — only two RTL wrapper files are
# compiled from it; the MAC/HA1588/matrix are NOT pulled in for this M0 smoke).
ETH_SS_HOME  ?= $(realpath $(TIDELINK_HOME)/../nanoSoC-refactor/ethernet-subsystem-ahb)
export ETH_SS_HOME

PAIR_V2_DIR = $(TIDELINK_HOME)/cocotb/tidelink_top_pair_v2

# tb + harness cells (pad_skid/eye_fault copied verbatim from the pair_v2 bench)
# + the ethernet-subsystem scratch-RAM terminus RTL.
VERILOG_SOURCES  = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv $(CURDIR)/eye_fault.sv
VERILOG_SOURCES += $(ETH_SS_HOME)/nanosoc_arch_tech/rtl/src/regions/sram/nanosoc_region_sram.v
VERILOG_SOURCES += $(ETH_SS_HOME)/src/rtl/fpga_lib/sram/sl_ahb_sram.v

TOPLEVEL = tb_top
MODULE  ?= test_eth_relay_smoke

# Import PairV2TB / AHBSubMaster from the pair_v2 bench + the tidelink python pkg.
export PYTHONPATH := $(CURDIR):$(PAIR_V2_DIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# TideLink V2 flist (carries +define+TIDELINK_PHY_V2 via the per-file shims,
# and compiles cmsdk_ahb_to_sram + cmsdk_fpga_sram — DO NOT re-add those here).
V2_FLIST ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(V2_FLIST)

# Autoneg parity with the pair_v2 harness (SW role-lock bring-up).
BYPASS_AUTONEG ?= 1
export BYPASS_AUTONEG
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)
RELY_ON_RTL_PRIO_DEFAULTS ?= 0
COMPILE_ARGS += +define+TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS=$(RELY_ON_RTL_PRIO_DEFAULTS)

# Whole-word epoch-skew profile (same knob as pair_v2). zero = clean skew.
EPOCH_PROFILE ?= zero
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

# EPOCH anchor (needed once any whole-word skew is injected).
EPOCH_ANCHOR ?= 0
ifeq ($(EPOCH_ANCHOR),1)
COMPILE_ARGS += +define+TIDELINK_EPOCH_ANCHOR
endif

# Wave dump OFF by default — full bring-up VCDs are huge. Enable: DUMP=1.
DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD := sim_build_$(EPOCH_PROFILE)

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(V2_FLIST) $(call flist_srcs,$(V2_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

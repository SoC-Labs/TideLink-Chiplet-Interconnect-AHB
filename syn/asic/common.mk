# Common ASIC synthesis definitions
# Included by all flow Makefiles under syn/asic/

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

# ── CMSDK path ─────────────────��─────────────────────────���─────────────────
# ARM Cortex-M System Design Kit (required for cmsdk_ahb_to_sram)
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/BP210/BP210-BU-00000-r1p1-00rel0

# ── Target module ──────────────────────────────────���───────────────────────
export MODULE ?= tidelink_top

# ── Module-to-top mapping ──────────────────────────────────────────────────
# Flist basenames and SV module names diverge after the FIFO rename.
# MODULE selects the flist; TOP selects the elaboration top.
TOP_tidelink          = tidelink_fifo
TOP_tidelink_fifo     = tidelink_fifo_mem
TOP_tidelink_top      = tidelink_top
TOP_tidelink_top_full = tidelink_top
TOP_tidelink_fc_adapter = tidelink_fc_adapter
export TOP := $(or $(TOP_$(MODULE)),$(MODULE))

# ── File lists ───────────────────────────────────────────────────────────
# Use ASIC-specific flist if it exists (swaps FPGA SRAM for compiled macro),
# otherwise fall back to the default flist.
ASIC_FLIST_PATH := $(TIDELINK_HOME)/flist/$(MODULE)_asic.flist
export FLIST := $(if $(wildcard $(ASIC_FLIST_PATH)),$(ASIC_FLIST_PATH),$(TIDELINK_HOME)/flist/$(MODULE).flist)
export ASIC_FLIST := $(TIDELINK_HOME)/flist/tidelink_asic.flist

# ── Cell libraries (update paths to match your PDK installation) ───────��───
# Target library (.db) — used for mapping and optimization
# export TARGET_LIB     ?= /eda/pdk/example/std_cell.db
# Defaultly using the 65nm Library
export TARGET_LIB     ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp/sc12_base_rvt/r0p0/db/sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c.db

# ── Memory macro libraries (compiled register file) ─────────────────────
export MEM_PATH       ?= /research/precompiled_mems/TSMC65/rf_16k
export MEM_DB_SS      ?= $(MEM_PATH)/rf_16k_ss_1p08v_1p08v_125c.db
export MEM_DB_FF      ?= $(MEM_PATH)/rf_16k_ff_1p32v_1p32v_m40c.db

# Link libraries — target + any additional macro/IP libs
export LINK_LIBS      ?= $(TARGET_LIB) $(MEM_DB_SS)

# TF/Milkyway — physical reference for floorplan estimation (TSMC 65nm, 1p9m_6x2z)
export PHYS_IP_PATH   ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp

# Standard cell Verilog simulation models (for gate-level simulation)
export STDCELL_VERILOG ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0
export TF_FILE        ?= $(PHYS_IP_PATH)/arm_tech/r2p0/milkyway/1p9m_6x2z/sc12_tech.tf
export MW_REF_LIB     ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/milkyway/1p9m_6x2z/sc12_cln65lp_base_rvt

# ── RTLA Reference Methodology ──────���─────────────────���───────────────────
export RTLA_RM_PATH   ?= /research/synopsys/RTLA-RM_U-2022.12

# ── Multi-corner .db libraries (for RTLA CLIB on-the-fly creation) ────────
export DB_PATH        ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/db
export DB_SS          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c.db
export DB_FF          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ff_typical_min_1p32v_m40c.db

# ── TLU+ parasitic extraction models ─────────────────────────────────────
export TLUPLUS_PATH   ?= $(PHYS_IP_PATH)/arm_tech/r2p0/synopsys_tluplus/1p9m_6x2z
export TLUPLUS_MAP    ?= $(TLUPLUS_PATH)/tluplus.map

# ── Design constraints ─────────────────────────��───────────────────────────
export CLK_NAME        ?= hclk
export CLK_PERIOD      ?= 4.0
export CLK_UNCERTAINTY ?= 0.35
export RST_NAME        ?= hresetn

# ── Available modules ───────────��──────────────────────────────────────────
MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs tidelink_fc_adapter tidelink_top tidelink_top_full

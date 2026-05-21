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
# tidelink_top instantiates a single rf_16k (FIFO mem). MEM_BASE is the
# precompiled-mems root so the FC fusion-lib can pick up additional macro
# LEFs by name if the partition ever grows. MEM_PATH/MEM_DB_SS/MEM_DB_FF
# remain as backwards-compat aliases for the DC + RTLA flows.
export MEM_BASE       ?= /research/precompiled_mems/TSMC65
export RF_16K_DB_SS   ?= $(MEM_BASE)/rf_16k/rf_16k_ss_1p08v_1p08v_125c.db
export RF_16K_DB_TT   ?= $(MEM_BASE)/rf_16k/rf_16k_tt_1p20v_1p20v_25c.db
export RF_16K_DB_FF   ?= $(MEM_BASE)/rf_16k/rf_16k_ff_1p32v_1p32v_m40c.db

# Aggregate slow/typical/fast macro library lists for link_library
export MEM_DBS_SS     := $(RF_16K_DB_SS)
export MEM_DBS_TT     := $(RF_16K_DB_TT)
export MEM_DBS_FF     := $(RF_16K_DB_FF)

# Backwards-compat aliases (DC + RTLA flow + FC.read_design.tcl)
export MEM_PATH       ?= $(MEM_BASE)/rf_16k
export MEM_DB_SS      ?= $(RF_16K_DB_SS)
export MEM_DB_FF      ?= $(RF_16K_DB_FF)

# Link libraries — target + every macro corner present
export LINK_LIBS      ?= $(TARGET_LIB) $(MEM_DBS_SS)

# TF/Milkyway — physical reference (TSMC 65nm, 1p9m_6x2z).
# PHYS_IP_PATH is the legacy /research/AAA root. STANDARD_CELL_BASE_PATH
# is the SoC-Labs project-wide canonical name and resolves to the same
# location; both are exported so downstream scripts can use either.
export PHYS_IP_PATH            ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp
export STANDARD_CELL_BASE_PATH ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0
export IO_BASE_PATH            ?= /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/IO2.5V/iolib/linear/tpdn65lpnv2od3_200a_FE/TSMCHOME/digital
export CLN65LP_TECH_PATH       ?= /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/stclib/12-track/tcbn65lpbwp12t-set/tcbn65lpbwp12t_200b_FE/TSMCHOME/digital/Back_End
export PMK_BASE_PATH           ?= /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_pmk_svt_c24/r2p0
export RET_BASE_PATH           ?= /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_rklo_lvt_svt_c20_c24/r1p0

# Standard cell Verilog simulation models (for gate-level simulation)
export STDCELL_VERILOG ?= $(STANDARD_CELL_BASE_PATH)
# Arm-vendor TF for fc_shell (the cln65lp_tech_file from TSMCHOME is
# also defined in scripts/tech_paths.tcl as the canonical TCL var; this
# Makefile-side TF_FILE remains the Arm-vendor TF since the foundry
# TSMCHOME install isn't on every dev box).
export TF_FILE        ?= $(PHYS_IP_PATH)/arm_tech/r2p0/milkyway/1p9m_6x2z/sc12_tech.tf
export MW_REF_LIB     ?= $(STANDARD_CELL_BASE_PATH)/milkyway/1p9m_6x2z/sc12_cln65lp_base_rvt

# ── RTLA Reference Methodology ──────���─────────────────���───────────────────
export RTLA_RM_PATH   ?= /research/synopsys/RTLA-RM_U-2022.12

# ── Multi-corner .db libraries (SS = max-delay, TT = typical, FF = min-delay)
# Three corners are now stocked. SS feeds the existing sc12 link_library
# (TARGET_LIB above is the SS .db); TT and FF are available for MCMM
# scenario closure. Variable names retain the SoC-Labs project-wide
# operating-point convention (0p72/0p80/0p88V labels) even though the
# .db files at this library cut are 1p08/1p20/1p32V — the labels track
# the foundry voltage of a sibling node, kept consistent so chip-top
# scripts can pick a corner set with a single switch.
export DB_PATH        ?= $(STANDARD_CELL_BASE_PATH)/db
export DB_SS          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c.db
export DB_TT          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_tt_typical_max_1p20v_25c.db
export DB_FF          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ff_typical_min_1p32v_m40c.db

# SoC-Labs-style aliases (mirror tech_paths.tcl var names exactly so any
# downstream make snippet can read either spelling).
export STANDARD_CELL_DB_FILE_SS_0P72V_125C ?= $(DB_SS)
export STANDARD_CELL_DB_FILE_TT_0P80V_25C  ?= $(DB_TT)
export STANDARD_CELL_DB_FILE_FF_0P88V_M40C ?= $(DB_FF)
export STANDARD_CELL_LEF_FILE              ?= $(STANDARD_CELL_BASE_PATH)/lef/sc12_cln65lp_base_rvt.lef
export STANDARD_CELL_GDS_FILE              ?= $(STANDARD_CELL_BASE_PATH)/gds2/sc12_cln65lp_base_rvt.gds2

# ── TLU+ parasitic extraction models ─────────────────────────────────────
export TLUPLUS_PATH   ?= $(PHYS_IP_PATH)/arm_tech/r2p0/synopsys_tluplus/1p9m_6x2z
export TLUPLUS_MAP    ?= $(TLUPLUS_PATH)/tluplus.map

# ── FC GDS stream-out — layer map + macro/stdcell GDS to merge ─────────────
# write_gds in 6_partition_export.tcl needs (a) a Synopsys-format layer
# map and (b) the GDS of every reference cell (std cells + rf_16k macro)
# so the emitted stream-out is self-contained for chip-finish DRC/LVS.
# Without -merge_files the partition GDS contains only the metal/via
# shapes the FC flow created — chip-top would have to merge the
# std-cell + rf_16k GDS itself at LVS time.
export GDS_LAYER_MAP   ?= $(PHYS_IP_PATH)/arm_tech/r2p0/milkyway/1p9m_6x2z/stream_out_layer_map
export GDS_STDCELL     ?= $(STANDARD_CELL_GDS_FILE)
export GDS_MEM_RF16K   ?= $(MEM_BASE)/rf_16k/rf_16k.gds2
export GDS_MERGE_FILES ?= $(GDS_STDCELL) $(GDS_MEM_RF16K)

# ── Design constraints ─────────────────────────��───────────────────────────
# TideLink top has two boundary clocks (hclk + phc_clk) plus a Wlink
# user_ref_clk and a DFT scan_clk. The shared FC.read_design.tcl creates
# the primary clock (hclk @ 4 ns); the FC inputs/constraints.sdc overlay
# adds phc_clk, the Wlink ref clock, the scan clock and async clock-group
# definitions so each domain has its own setup window.
export CLK_NAME        ?= hclk
export CLK_PERIOD      ?= 4.0
export CLK_UNCERTAINTY ?= 0.35
export RST_NAME        ?= hresetn

# ── Available modules ───────────��──────────────────────────────────────────
MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs tidelink_fc_adapter tidelink_top tidelink_top_full

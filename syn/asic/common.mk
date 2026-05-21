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

# ── Cell libraries — TSMC tcbn65lp 9-track 9lm_T2 stack ────────────────────
# Switched from Arm sc12_base_rvt (12-track) to TSMC tcbn65lp_220a (9-track)
# on 2026-05-21. The user-canonical TSMCHOME install lives under
# /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/. Three corners now stocked:
#   tcbn65lpwc — worst case (max-delay) = SS corner equivalent
#   tcbn65lptc — typical case            = TT corner
#   tcbn65lpbc — best  case (min-delay)  = FF corner equivalent
export TARGET_LIB     ?= /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn65lp_220a/tcbn65lpwc.db

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

# TF/Milkyway — physical reference (TSMC65 LP, 9-layer T2 stack).
# Canonical SoC-Labs paths under /home/dwn1c21/.../TSMC/65/CMOS/LP/ —
# 9-track tcbn65lp_220a. Override on a per-system basis via the env
# var of the same name (e.g. STANDARD_CELL_BASE_PATH=…).
export STANDARD_CELL_BASE_PATH ?= /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital
export IO_BASE_PATH            ?= /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/IO2.5V/iolib/linear/tpdn65lpnv2od3_200a_FE/TSMCHOME/digital
export CLN65LP_TECH_PATH       ?= $(STANDARD_CELL_BASE_PATH)/Back_End
export PMK_BASE_PATH           ?= /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_pmk_svt_c24/r2p0
export RET_BASE_PATH           ?= /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_rklo_lvt_svt_c20_c24/r1p0

# Legacy alias (some downstream scripts still grep PHYS_IP_PATH).
export PHYS_IP_PATH            ?= $(STANDARD_CELL_BASE_PATH)

# Standard cell Verilog simulation models (for gate-level simulation)
export STDCELL_VERILOG ?= $(STANDARD_CELL_BASE_PATH)/Front_End/verilog/tcbn65lp_200a
# Foundry Milkyway TF (9-layer T2 stack) and LEF for fc_shell.
export TF_FILE        ?= $(STANDARD_CELL_BASE_PATH)/Back_End/milkyway/tcbn65lp_200a/techfiles/tsmcn65_9lmT2.tf
export MW_REF_LIB     ?= $(STANDARD_CELL_BASE_PATH)/Back_End/milkyway/tcbn65lp_200a/frame_only/tcbn65lp

# ── RTLA Reference Methodology ──────���─────────────────���───────────────────
export RTLA_RM_PATH   ?= /research/synopsys/RTLA-RM_U-2022.12

# ── Multi-corner .db libraries (tcbn65lp 220a NLDM) ────────────────────────
# Mapping TSMC corner labels → SoC-Labs SS/TT/FF nomenclature:
#   tcbn65lpwc — worst case (V_LO, T_HI, slow)  ↔ SS (max-delay)
#   tcbn65lptc — typical case                    ↔ TT
#   tcbn65lpbc — best  case (V_HI, T_LO, fast)  ↔ FF (min-delay)
# Variable names keep the SoC-Labs project-wide 0p72/0p80/0p88V label
# convention; the actual tcbn65lp .db operating points are the foundry
# canonical values (BCCOM/NCCOM/WCCOM — see lib_file headers).
export DB_PATH        ?= $(STANDARD_CELL_BASE_PATH)/Front_End/timing_power_noise/NLDM/tcbn65lp_220a
export DB_SS          ?= $(DB_PATH)/tcbn65lpwc.db
export DB_TT          ?= $(DB_PATH)/tcbn65lptc.db
export DB_FF          ?= $(DB_PATH)/tcbn65lpbc.db

# SoC-Labs-style aliases (mirror tech_paths.tcl var names exactly so any
# downstream make snippet can read either spelling).
export STANDARD_CELL_DB_FILE_SS_0P72V_125C ?= $(DB_SS)
export STANDARD_CELL_DB_FILE_TT_0P80V_25C  ?= $(DB_TT)
export STANDARD_CELL_DB_FILE_FF_0P88V_M40C ?= $(DB_FF)
export STANDARD_CELL_LEF_FILE              ?= $(STANDARD_CELL_BASE_PATH)/Back_End/lef/tcbn65lp_200a/lef/tcbn65lp_9lmT2.lef
# No .gds2 file ships in TSMCHOME — chip-top is expected to merge the
# library GDS at LVS time from the foundry's signoff package. Leave empty
# so write_gds in 6_partition_export.tcl skips the std-cell merge.
export STANDARD_CELL_GDS_FILE              ?=

# ── TLU+ parasitic extraction models (cln65lp 1p09m+alrdl, top2 = 9lm_T2)
# The tcbn65lp tluplus directory ships top1/top2 variants for each
# operating-point combination (cbest/cworst/rcbest/rcworst/typical).
# top2 matches the 1p09m+alrdl 9lm_T2 stack we picked for TF_FILE.
# The star.map_9M layer-mapping file is the canonical map for the 9-metal
# stack — provides the Star-RC / TLU+ layer name → number translation.
export TLUPLUS_PATH   ?= $(STANDARD_CELL_BASE_PATH)/Back_End/milkyway/tcbn65lp_200a/techfiles/tluplus
export TLUPLUS_MAP    ?= $(TLUPLUS_PATH)/star.map_9M

# ── FC GDS stream-out — layer map + macro/stdcell GDS to merge ─────────────
# write_gds in 6_partition_export.tcl needs (a) a Synopsys-format layer
# map and (b) the GDS of every reference cell (std cells + rf_16k macro)
# so the emitted stream-out is self-contained for chip-finish DRC/LVS.
# Without -merge_files the partition GDS contains only the metal/via
# shapes the FC flow created — chip-top would have to merge the
# std-cell + rf_16k GDS itself at LVS time.
export GDS_LAYER_MAP   ?= $(STANDARD_CELL_BASE_PATH)/Back_End/milkyway/tcbn65lp_200a/gdsout_3X2Z.map
export GDS_STDCELL     ?= $(STANDARD_CELL_GDS_FILE)
export GDS_MEM_RF16K   ?= $(MEM_BASE)/rf_16k/rf_16k.gds2
# write_gds with -merge_files expects only files that exist on disk —
# strip the empty GDS_STDCELL out of the merge list when it isn't set.
export GDS_MERGE_FILES ?= $(strip $(if $(GDS_STDCELL),$(GDS_STDCELL))) $(GDS_MEM_RF16K)

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

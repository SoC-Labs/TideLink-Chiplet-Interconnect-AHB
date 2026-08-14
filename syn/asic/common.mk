# Common ASIC synthesis definitions
# Included by all flow Makefiles under syn/asic/

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

# ── Site configuration ─────────────────────────────────────────────────────
# Per-machine paths — tool installs, IP roots, foundry collateral — live in
# <repo>/site.env, which is NOT tracked. Copy site.env.example to site.env and
# edit it, or export the same names from your login profile / site module file.
#
# NOTHING BELOW CARRIES A DEFAULT VALUE. A default pointing at one lab's mount
# produces a run that looks configured and is not: it resolves on exactly one
# machine and fails everywhere else in a way that reads as a missing file
# rather than as a missing setting. See `make site-check`.
#
# site.env is written in the Make/shell syntax intersection (`export N=v`, no
# spaces, ${N} references) so set_env.sh can source the same file.
SITE_ENV ?= $(TIDELINK_HOME)/site.env
-include $(SITE_ENV)

# ── CMSDK path ─────────────────────────────────────────────────────────────
# ARM Cortex-M System Design Kit (required for cmsdk_ahb_to_sram). The package
# directory name carries a release code, so it is set per site, not derived.
export CMSDK_DIR

# ── Target module ──────────────────────────────────────────────────────────
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
ASIC_FLIST_PATH := $(TIDELINK_HOME)/flists/$(MODULE)_asic.flist
export FLIST := $(if $(wildcard $(ASIC_FLIST_PATH)),$(ASIC_FLIST_PATH),$(TIDELINK_HOME)/flists/$(MODULE).flist)
export ASIC_FLIST := $(TIDELINK_HOME)/flists/tidelink_asic.flist

# ── Cell libraries — 12-track standard cells, 9-layer stack ────────────────
# Switched on 2026-06-02 from the 9-track library to the 12-track one. The
# three corners the flow stocks, in SoC-Labs nomenclature:
#   DB_SS — worst case (max-delay)
#   DB_TT — typical case
#   DB_FF — best  case (min-delay)
# Which foundry release supplies them, and the PVT corner each .db was
# characterised at, is a per-site fact: set DB_SS/DB_TT/DB_FF in site.env.
export TARGET_LIB     ?= $(DB_SS)

# ── Memory macro libraries (compiled register file) ─────────────────────
# tidelink_top instantiates a single rf_16k (FIFO mem). MEM_BASE is the
# precompiled-mems root so the FC fusion-lib can pick up additional macro
# LEFs by name if the partition ever grows. MEM_PATH/MEM_DB_SS/MEM_DB_FF
# remain as backwards-compat aliases for the DC + RTLA flows.
export MEM_BASE
export MEM_PATH       ?= $(if $(MEM_BASE),$(MEM_BASE)/rf_16k)
export RF_16K_DB_SS   ?= $(if $(MEM_PATH),$(MEM_PATH)/rf_16k_ss_1p08v_1p08v_125c.db)
export RF_16K_DB_TT   ?= $(if $(MEM_PATH),$(MEM_PATH)/rf_16k_tt_1p20v_1p20v_25c.db)
export RF_16K_DB_FF   ?= $(if $(MEM_PATH),$(MEM_PATH)/rf_16k_ff_1p32v_1p32v_m40c.db)

# Aggregate slow/typical/fast macro library lists for link_library
export MEM_DBS_SS     := $(RF_16K_DB_SS)
export MEM_DBS_TT     := $(RF_16K_DB_TT)
export MEM_DBS_FF     := $(RF_16K_DB_FF)

# Backwards-compat aliases (DC + RTLA flow + FC.read_design.tcl)
export MEM_DB_SS      ?= $(RF_16K_DB_SS)
export MEM_DB_FF      ?= $(RF_16K_DB_FF)

# Link libraries — target + every macro corner present
export LINK_LIBS      ?= $(TARGET_LIB) $(MEM_DBS_SS)

# ── Physical reference ─────────────────────────────────────────────────────
# STANDARD_CELL_BASE_PATH is the library install root (the directory holding
# Front_End/ and Back_End/). The files under it are named INDIVIDUALLY in
# site.env rather than assembled from it, because each of those subdirectory
# and file names encodes a foundry release code, a metal-stack option code or
# a PVT characterisation corner.
export STANDARD_CELL_BASE_PATH
export IO_BASE_PATH
export CLN65LP_TECH_PATH       ?= $(if $(STANDARD_CELL_BASE_PATH),$(STANDARD_CELL_BASE_PATH)/Back_End)
export PMK_BASE_PATH
export RET_BASE_PATH

# Legacy alias (some downstream scripts still grep PHYS_IP_PATH).
export PHYS_IP_PATH            ?= $(STANDARD_CELL_BASE_PATH)

# Standard cell Verilog simulation models (for gate-level simulation) — the
# release directory under Front_End/verilog/.
export STDCELL_VERILOG

# Milkyway TF and LEF for fc_shell. These two MUST describe the same metal
# stack; a mismatch is not diagnosed by the tools, it just routes wrong.
export TF_FILE
export MW_REF_LIB

# ── RTLA Reference Methodology ─────────────────────────────────────────────
export RTLA_RM_PATH

# ── Multi-corner .db libraries ─────────────────────────────────────────────
# DB_PATH is the NLDM directory; DB_SS/DB_TT/DB_FF are the three corner files
# inside it. Set all four in site.env — the stems encode the PVT corner and
# the directory encodes the release, neither of which belongs in a tracked
# file. The operating point each .db was characterised at is stated in that
# file's own Liberty header, which is the one place it cannot go stale.
export DB_PATH
export DB_SS
export DB_TT
export DB_FF

# SoC-Labs-style aliases (mirror tech_paths.tcl var names exactly so any
# downstream make snippet can read either spelling).
export STANDARD_CELL_DB_FILE_SS_0P72V_125C ?= $(DB_SS)
export STANDARD_CELL_DB_FILE_TT_0P80V_25C  ?= $(DB_TT)
export STANDARD_CELL_DB_FILE_FF_0P88V_M40C ?= $(DB_FF)
export STANDARD_CELL_LEF_FILE
# Optional. Many installs ship no std-cell .gds2 — chip-top then merges the
# library GDS at LVS time from the foundry's signoff package. Left empty,
# write_gds in 6_partition_export.tcl skips the std-cell merge.
export STANDARD_CELL_GDS_FILE              ?=

# ── TLU+ parasitic extraction models ───────────────────────────────────────
# TLUPLUS_PATH is the tluplus directory for the metal stack picked in TF_FILE;
# it ships one file per operating-point combination (cbest/cworst/rcbest/
# rcworst/typical) and per stack variant. TLUPLUS_MAP is the Star-RC layer
# name -> number map for that stack; its filename encodes the metal count, so
# it is named in site.env rather than derived.
export TLUPLUS_PATH
export TLUPLUS_MAP

# ── FC GDS stream-out — layer map + macro/stdcell GDS to merge ─────────────
# write_gds in 6_partition_export.tcl needs (a) a Synopsys-format layer
# map and (b) the GDS of every reference cell (std cells + rf_16k macro)
# so the emitted stream-out is self-contained for chip-finish DRC/LVS.
# Without -merge_files the partition GDS contains only the metal/via
# shapes the FC flow created — chip-top would have to merge the
# std-cell + rf_16k GDS itself at LVS time.
# GDS_LAYER_MAP's filename encodes the metal-stack option: set it in site.env.
export GDS_LAYER_MAP
export GDS_STDCELL     ?= $(STANDARD_CELL_GDS_FILE)
export GDS_MEM_RF16K   ?= $(if $(MEM_PATH),$(MEM_PATH)/rf_16k.gds2)
# write_gds with -merge_files expects only files that exist on disk —
# strip the empty GDS_STDCELL out of the merge list when it isn't set.
export GDS_MERGE_FILES ?= $(strip $(if $(GDS_STDCELL),$(GDS_STDCELL))) $(GDS_MEM_RF16K)

# ── Design constraints ─────────────────────────────────────────────────────
# TideLink top has two boundary clocks (hclk + phc_clk) plus a Wlink
# user_ref_clk and a DFT scan_clk. The shared FC.read_design.tcl creates
# the primary clock (hclk @ 4 ns); the FC inputs/constraints.sdc overlay
# adds phc_clk, the Wlink ref clock, the scan clock and async clock-group
# definitions so each domain has its own setup window.
export CLK_NAME        ?= hclk
export CLK_PERIOD      ?= 4.0
export CLK_UNCERTAINTY ?= 0.35
export RST_NAME        ?= hresetn

# ── Available modules ──────────────────────────────────────────────────────
MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs tidelink_fc_adapter tidelink_top tidelink_top_full

#-----------------------------------------------------------------------------
# Site check — fail loudly, naming EVERY missing variable, before a tool runs
#
# A flow Makefile adds to SITE_VARS_REQUIRED *before* including this file when
# it needs more than the core set (see calibre/Makefile for the pattern), and
# adds to SITE_SOFT_GOALS for any target that legitimately needs nothing.
#-----------------------------------------------------------------------------
SITE_VARS_REQUIRED += STANDARD_CELL_BASE_PATH TF_FILE STANDARD_CELL_LEF_FILE \
                      DB_SS DB_TT DB_FF MEM_PATH
SITE_SOFT_GOALS    += help clean distclean site-check dirs

SITE_VARS_MISSING := $(strip $(foreach v,$(SITE_VARS_REQUIRED),$(if $(strip $($(v))),,$(v))))
SITE_HARD_GOALS   := $(filter-out $(SITE_SOFT_GOALS),$(if $(MAKECMDGOALS),$(MAKECMDGOALS),_default))

.PHONY: site-check
site-check:
	@if [ -n "$(SITE_VARS_MISSING)" ]; then \
	    echo "ERROR: [site] unset, with no default:"; \
	    for v in $(SITE_VARS_MISSING); do echo "         $$v"; done; \
	    echo "       Copy site.env.example to $(SITE_ENV) and set them there,"; \
	    echo "       or export them in your environment. site.env.example says"; \
	    echo "       what each one locates. There is no default: this flow will"; \
	    echo "       not guess one site's filesystem layout."; \
	    exit 1; \
	fi
	@echo "INFO: [site] all required variables set (SITE_ENV=$(SITE_ENV))"

ifneq ($(SITE_VARS_MISSING),)
ifneq ($(SITE_HARD_GOALS),)
$(warning ERROR: [site] unset, with no default: $(SITE_VARS_MISSING))
$(warning        Copy site.env.example to $(SITE_ENV) and set them there, or export)
$(warning        them in your environment. site.env.example says what each locates.)
$(error   [site] refusing to run $(SITE_HARD_GOALS) with an unconfigured site)
endif
endif

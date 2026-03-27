# Common ASIC synthesis definitions
# Included by all flow Makefiles under syn/asic/

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

# ── CMSDK path ─────────────────────────────────────────────────────────────
# ARM Cortex-M System Design Kit (required for cmsdk_ahb_to_sram)
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/BP210/BP210-BU-00000-r1p1-00rel0

# ── Target module ──────────────────────────────────────────────────────────
export MODULE ?= tidelink

# ── File lists ─────────────────────────────────────────────────────────────
export FLIST := $(TIDELINK_HOME)/flist/$(MODULE).flist

# ── Cell libraries (update paths to match your PDK installation) ───────────
# Target library (.db) — used for mapping and optimization
# export TARGET_LIB     ?= /eda/pdk/example/std_cell.db
# Defaultly using the 65nm Library
export TARGET_LIB     ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp/sc12_base_rvt/r0p0/db/sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c.db

# Link libraries — target + any additional macro/IP libs
export LINK_LIBS      ?= $(TARGET_LIB)

# TF/Milkyway — physical reference for floorplan estimation (TSMC 65nm, 1p9m_6x2z)
export PHYS_IP_PATH   ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp
export TF_FILE        ?= $(PHYS_IP_PATH)/arm_tech/r2p0/milkyway/1p9m_6x2z/sc12_tech.tf
export MW_REF_LIB     ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/milkyway/1p9m_6x2z/sc12_cln65lp_base_rvt

# ── RTLA Reference Methodology ────────────────────────────────────────────
export RTLA_RM_PATH   ?= /research/synopsys/RTLA-RM_U-2022.12

# ── Multi-corner .db libraries (for RTLA CLIB on-the-fly creation) ────────
export DB_PATH        ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/db
export DB_SS          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c.db
export DB_FF          ?= $(DB_PATH)/sc12_cln65lp_base_rvt_ff_typical_min_1p32v_m40c.db

# ── TLU+ parasitic extraction models ─────────────────────────────────────
export TLUPLUS_PATH   ?= $(PHYS_IP_PATH)/arm_tech/r2p0/synopsys_tluplus/1p9m_6x2z
export TLUPLUS_MAP    ?= $(TLUPLUS_PATH)/tluplus.map

# ── Design constraints ─────────────────────────────────────────────────────
export CLK_NAME       ?= hclk
export CLK_PERIOD     ?= 10.0
export CLK_UNCERTAINTY ?= 0.35
export RST_NAME       ?= hresetn

# ── Available modules ──────────────────────────────────────────────────────
MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs

# Common ASIC synthesis definitions
# Included by all flow Makefiles under syn/asic/

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

# ── Target module ──────────────────────────────────────────────────────────
export MODULE ?= tidelink

# ── File lists ─────────────────────────────────────────────────────────────
export FLIST := $(TIDELINK_HOME)/flist/$(MODULE).flist

# ── Cell libraries (update paths to match your PDK installation) ───────────
# Target library (.db) — used for mapping and optimization
export TARGET_LIB     ?= /eda/pdk/example/std_cell.db

# Link libraries — target + any additional macro/IP libs
export LINK_LIBS      ?= $(TARGET_LIB)

# TF/Milkyway — physical reference for floorplan estimation
export TF_FILE        ?= /eda/pdk/example/std_cell.tf
export MW_REF_LIB     ?= /eda/pdk/example/std_cell_mw

# ── Design constraints ─────────────────────────────────────────────────────
export CLK_NAME       ?= hclk
export CLK_PERIOD     ?= 10.0
export RST_NAME       ?= hresetn

# ── Available modules ──────────────────────────────────────────────────────
MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs

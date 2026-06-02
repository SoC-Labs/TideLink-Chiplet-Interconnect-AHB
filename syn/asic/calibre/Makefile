# Pin MODULE before include so common.mk's `?=` no-ops.
MODULE ?= tidelink_top_full
include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# Force the ASIC flist (same convention as the FC + Formality + PrimeTime
# siblings) so the .v / .gds we DRC against match what FC built.
override FLIST := $(TIDELINK_HOME)/flist/$(MODULE)_asic.flist
export FLIST

# ── Paths ─────────────────────────────────────────────────────────────────
export CAL_DIR     = $(TIDELINK_HOME)/syn/asic/calibre
export CAL_LOGS    = $(CAL_DIR)/logs
export CAL_REPORTS = $(CAL_DIR)/reports
export CAL_WORK    = $(CAL_DIR)/work
export CAL_OUTPUTS = $(CAL_DIR)/outputs
export CAL_RUNSETS = $(CAL_DIR)/runsets

# Inherit FC outputs — GDS comes from there, Verilog netlist too.
export FC_DIR      = $(TIDELINK_HOME)/syn/asic/fusion-compiler
export FC_OUTPUTS  = $(FC_DIR)/outputs

# ── Foundry decks (override via env on a per-system basis) ────────────────
# DRC: TSMC MAIN_DECK CALIBRE_FLOW, nonUTM, 9m metal (matches our 9lm_T2
# stack in TF_FILE). Comprehensive DFM/LVS/RC + DRC combined deck.
# Decks now sourced from /tsmc65pdk consistent with the 12-track lib
# switch; same deck files as the legacy /home/dwn1c21 paths.
export CALIBRE_DRC_DECK ?= /tsmc65pdk/65/CMOS/util/MAIN_DECK/CALIBRE_FLOW/nonUTM/DFM_LVS_RC_CAL_N65_ALRDL_noU_v16a.9m

# LVS: PDK-bundled calibre.lvs (the simpler stand-alone LVS deck).
export CALIBRE_LVS_DECK ?= /tsmc65pdk/65/CMOS/LP/pdk/Calibre/lvs/calibre.lvs

# ── Tool binary ───────────────────────────────────────────────────────────
CAL_BIN     ?= /eda/mentor/calibre/bin/calibre
export PATH := $(dir $(CAL_BIN)):$(PATH)

# GDS + netlist roles (FC writes them under outputs/<TOP>.*)
GDS_GZ      = $(FC_OUTPUTS)/$(TOP).gds.gz
GDS         = $(FC_OUTPUTS)/$(TOP).gds
NETLIST_PG  = $(FC_OUTPUTS)/$(TOP).pg.v

.PHONY: drc lvs runsets help dirs clean

dirs:
	@mkdir -p $(CAL_LOGS) $(CAL_REPORTS) $(CAL_WORK) $(CAL_OUTPUTS) $(CAL_RUNSETS)

# ── DRC ───────────────────────────────────────────────────────────────────
# Generate a tidelink-specific runset by template-substitution against the
# canonical SoC-Labs runset format, then invoke calibre. .err DB is parsed
# into reports/09_calibre_drc.rep.
drc: | dirs
	@if [ ! -f "$(CALIBRE_DRC_DECK)" ]; then \
	    echo "ERROR: DRC deck not found at $(CALIBRE_DRC_DECK)"; \
	    echo "       set CALIBRE_DRC_DECK=<path> or install the foundry deck"; exit 1; \
	fi
	@if [ ! -f "$(GDS)" ] && [ ! -f "$(GDS_GZ)" ]; then \
	    echo "ERROR: no GDS at $(GDS)(.gz) — run 'make -C ../fusion-compiler gdsii' first"; exit 1; \
	fi
	@if [ ! -f "$(GDS)" ]; then \
	    echo "INFO: decompressing $(GDS_GZ) → $(CAL_WORK)/$(TOP).gds"; \
	    gunzip -c "$(GDS_GZ)" > "$(CAL_WORK)/$(TOP).gds"; \
	    export TIDELINK_DRC_GDS="$(CAL_WORK)/$(TOP).gds"; \
	else \
	    export TIDELINK_DRC_GDS="$(GDS)"; \
	fi; \
	bash $(CAL_DIR)/scripts/run_calibre_drc.sh \
	    "$(CALIBRE_DRC_DECK)" "$$TIDELINK_DRC_GDS" "$(TOP)" \
	    "$(CAL_WORK)" "$(CAL_REPORTS)" "$(CAL_LOGS)" "$(CAL_RUNSETS)"

# ── LVS ───────────────────────────────────────────────────────────────────
# Layout = partition GDS (same path as DRC).
# Source = FC-emitted Verilog netlist (.v) — Calibre extracts the source
# via the v2lvs flow.
lvs: | dirs
	@if [ ! -f "$(CALIBRE_LVS_DECK)" ]; then \
	    echo "ERROR: LVS deck not found at $(CALIBRE_LVS_DECK)"; exit 1; \
	fi
	@if [ ! -f "$(NETLIST_PG)" ]; then \
	    echo "ERROR: $(NETLIST_PG) missing — run 'make -C ../fusion-compiler fc_abstract' first"; exit 1; \
	fi
	@if [ ! -f "$(GDS)" ] && [ ! -f "$(GDS_GZ)" ]; then \
	    echo "ERROR: no GDS at $(GDS)(.gz)"; exit 1; \
	fi
	@if [ ! -f "$(GDS)" ]; then \
	    gunzip -c "$(GDS_GZ)" > "$(CAL_WORK)/$(TOP).gds"; \
	    export TIDELINK_LVS_GDS="$(CAL_WORK)/$(TOP).gds"; \
	else \
	    export TIDELINK_LVS_GDS="$(GDS)"; \
	fi; \
	bash $(CAL_DIR)/scripts/run_calibre_lvs.sh \
	    "$(CALIBRE_LVS_DECK)" "$$TIDELINK_LVS_GDS" "$(NETLIST_PG)" "$(TOP)" \
	    "$(CAL_WORK)" "$(CAL_REPORTS)" "$(CAL_LOGS)" "$(CAL_RUNSETS)"

# Emit (without running) the tidelink-specific DRC + LVS runsets so a
# Calibre GUI session can pick them up via File > Load Runset.
runsets: | dirs
	@TOP=$(TOP) GDS_PATH="$(GDS)" NETLIST_PATH="$(NETLIST_PG)" \
	    DRC_DECK="$(CALIBRE_DRC_DECK)" LVS_DECK="$(CALIBRE_LVS_DECK)" \
	    bash $(CAL_DIR)/scripts/emit_runsets.sh "$(CAL_RUNSETS)" \
	        "$(CAL_DIR)" "$(TOP)" "$(GDS)" "$(NETLIST_PG)"
	@echo "INFO: runsets in $(CAL_RUNSETS)/"

clean:
	rm -rf $(CAL_LOGS) $(CAL_REPORTS) $(CAL_WORK) $(CAL_OUTPUTS) $(CAL_RUNSETS)

help:
	@echo "TideLink — Calibre DRC / LVS"
	@echo ""
	@echo "Targets:"
	@echo "  make drc      - Run Calibre DRC against the FC partition GDS"
	@echo "                   (deck: \$$CALIBRE_DRC_DECK, default:"
	@echo "                    $(CALIBRE_DRC_DECK))"
	@echo "  make lvs      - Run Calibre LVS (layout GDS vs gate netlist)"
	@echo "  make runsets  - Emit tidelink-specific .runset files (no execution;"
	@echo "                   for opening in calibrewb)"
	@echo "  make clean    - Remove logs/reports/work/outputs/runsets"
	@echo ""
	@echo "Module     : $(MODULE)"
	@echo "Top        : $(TOP)"
	@echo "GDS        : $(GDS)(.gz)"
	@echo "Netlist    : $(NETLIST_PG)"
	@echo "DRC deck   : $(CALIBRE_DRC_DECK)"
	@echo "LVS deck   : $(CALIBRE_LVS_DECK)"
	@echo "Reports    : $(CAL_REPORTS)/"

# TideLink delivers as a partition block — we always want the ASIC flist
# (compiled rf_16k macro, not FPGA cmsdk_fpga_sram). MODULE defaults to
# tidelink_top_full so PTP + addr translator + performance counters are
# all present in the deliverable; override on the command line for a
# smaller cut, e.g.  make fc MODULE=tidelink_top
#
# Set MODULE BEFORE including common.mk so common.mk's `MODULE ?=
# tidelink_top` no-ops (?= only assigns when unset). common.mk also
# resolves TOP and FLIST from MODULE — we re-pin FLIST below to the
# _asic flist explicitly so the FPGA SRAM wrapper is never picked up.
MODULE ?= tidelink_top_full

include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# Force the ASIC flist regardless of common.mk's wildcard fallback.
override FLIST := $(TIDELINK_HOME)/flist/$(MODULE)_asic.flist
export FLIST

# ── Paths ──────────────────────────────────────────────────────────────────
# Switch work / outputs / etc to a parallel tree for non-production variants
# so the production checkpoints + deliverables aren't clobbered:
#   FC_CLOCK_GATING=off         → work_nocg/    (ICG-free netlist)
#   FC_PRESERVE_WLINK_FCSM=on   → work_preserve/ (Wlink FCSMs set_dont_touch'd)
ifeq ($(FC_CLOCK_GATING),off)
WORK_SUFFIX = _nocg
else ifeq ($(FC_PRESERVE_WLINK_FCSM),on)
WORK_SUFFIX = _preserve
else
WORK_SUFFIX =
endif

export FC_DIR         = $(TIDELINK_HOME)/syn/asic/fusion-compiler
export SHARED_SCRIPTS = $(TIDELINK_HOME)/syn/asic/scripts
export FC_WORK        = $(FC_DIR)/work$(WORK_SUFFIX)
export FC_LIBS        = $(FC_DIR)/libs
export FC_LOGS        = $(FC_DIR)/logs$(WORK_SUFFIX)
export FC_REPORTS     = $(FC_DIR)/reports$(WORK_SUFFIX)
export FC_OUTPUTS     = $(FC_DIR)/outputs$(WORK_SUFFIX)

# Per-module sub-tree (so multiple MODULEs can coexist on disk)
export FC_BLOCK_DIR   = $(FC_WORK)/$(MODULE).dlib

# ── Floorplan target ───────────────────────────────────────────────────────
# Area-first partition: a single rf_16k macro (~312 × 285 μm) tucked into
# one corner, std cells densely packed in the remainder.
#
# 0.85 was the first attempt and hit congestion-induced timing failure
# at route_opt (setup -1.08ns / hold -0.39ns / 95 DRC violations). 0.78
# is the relaxation that closed timing while still being noticeably
# tighter than the ethernet partition's 0.70 — it gives route_auto the
# tracks it needs without giving back the area win. Override at
# make-time, e.g. FC_CORE_UTILIZATION=0.82 to pack harder once timing
# margin allows.
# Historical safe value: 0.70. Earlier builds without the explicit PG
# mesh worked at 0.78 because FC's auto-generated PG was sparser; the
# 50 μm M5/M6 init mesh + macro long-pin straps eat enough placement
# area that 0.78 hits PLACE-006 over-utilization at compile_fusion's
# logic_opto pre-placement. 0.70 gives the placer the headroom to
# absorb the PG-mesh blockages and keeps the partition timing-clean.
export FC_ASPECT_RATIO     ?= 1.0
export FC_CORE_UTILIZATION ?= 0.70
export FC_CORE_OFFSET      ?= 8

# Clock-gate insertion on/off. Default ON for production builds (the
# 430k μm² area-tight deliverable depends on it). Override to off when
# bringing up Formality LEC: FC inserts ~12k integrated clock-gate
# (PREICG_*) cells during compile_fusion's initial_opto, and the
# resulting netlist hits 20 localised LEC failures + 14k unverified
# downstream cones because (a) FC's SVF doesn't emit guide_clock_gate
# entries for the inserted ICGs and (b) sequential reg-constant opto
# folds Wlink Chisel demet flops by names Formality can't reconcile
# (~2083 SVF guide_reg_constant rejected).
#   make fc                       # production, CG on (default)
#   make fc FC_CLOCK_GATING=off   # LEC-clean, larger area
# A separate work tree (work_nocg, dlib named *_nocg) is used so the
# production checkpoints aren't clobbered.
export FC_CLOCK_GATING     ?= on

# ── EDA tool binaries ─────────────────────────────────────────────────────
FC_BIN_DIR   = /eda/synopsys/2022-23/RHELx86/FS-COMPILER_2022.12/bin
ICC2_BIN_DIR = /eda/synopsys/2022-23/RHELx86/ICC2_2022.12/bin
LC_BIN_DIR   = /eda/synopsys/2022-23/RHELx86/LC_2022.12/bin
export PATH := $(FC_BIN_DIR):$(ICC2_BIN_DIR):$(LC_BIN_DIR):$(PATH)

# ── Library / fusion-lib ──────────────────────────────────────────────────
LEF_FILE     = $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/lef/sc12_cln65lp_base_rvt.lef
export LEF_FILE
export FUSION_LIB := $(FC_DIR)/libs/sc12_lib

# Stage checkpoint blocks (FC save_block aliases inside the design library)
INIT_BLOCK     = init.design
SYNTH_BLOCK    = compile.design
CTS_BLOCK      = cts.design
ROUTE_BLOCK    = route.design
PG_BLOCK       = pg.design
SIGNOFF_BLOCK  = signoff.design
DRC_BLOCK      = drc.design

# Sentinels
INIT_DONE      = $(FC_WORK)/.init.done
SYNTH_DONE     = $(FC_WORK)/.synth.done
CTS_DONE       = $(FC_WORK)/.cts.done
ROUTE_DONE     = $(FC_WORK)/.route.done
PG_DONE        = $(FC_WORK)/.pg.done
SIGNOFF_DONE   = $(FC_WORK)/.signoff.done
DRC_DONE       = $(FC_WORK)/.drc.done
ABSTRACT_DONE  = $(FC_WORK)/.abstract.done
LEC_DONE       = $(FC_WORK)/.lec.done
ETM_DONE       = $(FC_WORK)/.etm.done

FC_SHELL = fc_shell

# Sibling Formality + PrimeTime trees — fc_lec / fc_etm delegate here.
FM_FLOW_DIR = $(TIDELINK_HOME)/syn/asic/formality
PT_FLOW_DIR = $(TIDELINK_HOME)/syn/asic/primetime

# Memory FF .db dir for build_mem_ff_db.tcl (no-op on the precompiled
# rf_16k macro — FF .db's are already shipped — but kept as the
# canonical hook for future rf_*k flavours without an FF .db).
export MEM_FF_DB_DIR  ?= $(TIDELINK_HOME)/syn/asic/libs/mem_ff

.PHONY: fc fc_all fc_init fc_synth fc_cts fc_route fc_pg fc_signoff \
        fc_drc fc_abstract fc_lec fc_etm fc_pg_deepdive drc_summary \
        mem_ff_db gdsii synth_netlist gui clean help dirs fusion_lib

# ── Workspace setup ───────────────────────────────────────────────────────
dirs:
	@mkdir -p $(FC_WORK) $(FC_LIBS) $(FC_LOGS) $(FC_REPORTS) $(FC_OUTPUTS)

# ── Fusion reference library (shared with rtl-architect) ─────────────────
$(FUSION_LIB): | dirs
	@echo "INFO: Creating fusion reference library from LEF + .db..."
	cd $(FC_LIBS)/.. && lm_shell -f $(SHARED_SCRIPTS)/create_fusion_lib.tcl 2>&1 \
	    | tee $(FC_LOGS)/create_fusion_lib.log
	@test -d $@ || (echo "ERROR: Fusion library creation failed"; exit 1)

fusion_lib: $(FUSION_LIB)

# ── Stage targets ────────────────────────────────────────────────────────
# Each stage cd's into $(FC_WORK), opens (or creates) the design library,
# saves a named block alias, then touches its sentinel.
#
# fc_shell exits 0 even on Tcl errors, so each stage greps the log for an
# FC_STAGE_OK marker emitted at the very end of the script before touching
# its sentinel — that marker is the only reliable signal that the stage
# actually completed.

$(INIT_DONE): $(FUSION_LIB) | dirs
	@echo "INFO: [Phase 1] init_design + analyze + elaborate + MCMM + floorplan"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/1_init_design.tcl 2>&1 \
	    | tee $(FC_LOGS)/1_init_design.log
	@grep -q "^FC_STAGE_OK: init" $(FC_LOGS)/1_init_design.log \
	    || (echo "ERROR: fc_init did not reach FC_STAGE_OK marker — see $(FC_LOGS)/1_init_design.log"; exit 1)
	@touch $@

fc_init: $(INIT_DONE)

$(SYNTH_DONE): $(INIT_DONE)
	@echo "INFO: [Phase 2] compile_fusion (synthesis + initial place + final place)"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/2_synthesis.tcl 2>&1 \
	    | tee $(FC_LOGS)/2_synthesis.log
	@grep -q "^FC_STAGE_OK: synth" $(FC_LOGS)/2_synthesis.log \
	    || (echo "ERROR: fc_synth did not reach FC_STAGE_OK marker — see $(FC_LOGS)/2_synthesis.log"; exit 1)
	@touch $@

fc_synth: $(SYNTH_DONE)

$(CTS_DONE): $(SYNTH_DONE)
	@echo "INFO: [Phase 3] clock_opt (build / route / final)"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/3_clock.tcl 2>&1 \
	    | tee $(FC_LOGS)/3_clock.log
	@grep -q "^FC_STAGE_OK: cts" $(FC_LOGS)/3_clock.log \
	    || (echo "ERROR: fc_cts did not reach FC_STAGE_OK marker — see $(FC_LOGS)/3_clock.log"; exit 1)
	@touch $@

fc_cts: $(CTS_DONE)

$(ROUTE_DONE): $(CTS_DONE)
	@echo "INFO: [Phase 4] route_auto + route_opt + fillers"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/4_route.tcl 2>&1 \
	    | tee $(FC_LOGS)/4_route.log
	@grep -q "^FC_STAGE_OK: route" $(FC_LOGS)/4_route.log \
	    || (echo "ERROR: fc_route did not reach FC_STAGE_OK marker — see $(FC_LOGS)/4_route.log"; exit 1)
	@touch $@

fc_route: $(ROUTE_DONE)

# Phase 4a — post-route PG rail rebind. The std-cell M1 rail pattern is
# rebuilt against the final routed layout (init-stage patterns don't
# persist across save/open). pg.design — NOT route.design — is what
# 5_signoff.tcl opens.
$(PG_DONE): $(ROUTE_DONE)
	@echo "INFO: [Phase 4a] post-route PG rail rebind"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/pg_rails.tcl 2>&1 \
	    | tee $(FC_LOGS)/pg_rails.log
	@grep -q "^FC_STAGE_OK: pg" $(FC_LOGS)/pg_rails.log \
	    || (echo "ERROR: fc_pg did not reach FC_STAGE_OK marker — see $(FC_LOGS)/pg_rails.log"; exit 1)
	@touch $@

fc_pg: $(PG_DONE)

$(SIGNOFF_DONE): $(PG_DONE)
	@echo "INFO: [Phase 4b] signoff (RC extract, per-scenario QoR)"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/5_signoff.tcl 2>&1 \
	    | tee $(FC_LOGS)/5_signoff.log
	@grep -q "^FC_STAGE_OK: signoff" $(FC_LOGS)/5_signoff.log \
	    || (echo "ERROR: fc_signoff did not reach FC_STAGE_OK marker — see $(FC_LOGS)/5_signoff.log"; exit 1)
	@touch $@

fc_signoff: $(SIGNOFF_DONE)

$(DRC_DONE): $(SIGNOFF_DONE)
	@echo "INFO: [Phase 5] DRC (in-design tier 0/1/1b + optional ICV)"
	@rm -f $(FC_REPORTS)/07_*.rep
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/7_drc.tcl 2>&1 \
	    | tee $(FC_LOGS)/7_drc.log
	@grep -q "^FC_STAGE_OK: drc" $(FC_LOGS)/7_drc.log \
	    || (echo "ERROR: fc_drc did not reach FC_STAGE_OK marker — see $(FC_LOGS)/7_drc.log"; exit 1)
	@touch $@

fc_drc: $(DRC_DONE)

drc_summary:
	@if [ ! -f "$(FC_REPORTS)/07_summary.rep" ]; then \
	    echo "ERROR: $(FC_REPORTS)/07_summary.rep not found — run 'make fc_drc' first"; \
	    exit 1; \
	fi
	@cat $(FC_REPORTS)/07_summary.rep

# fc_pg_deepdive — independent net-centric audit of check_pg_connectivity's
# floating-cell count. Opens drc.design (or signoff/pg fallback) and
# proves the count is wire-stub-fragment artefact, not real logical
# floating. Drops 08_pg_deepdive.rep next to the DRC reports.
fc_pg_deepdive: $(DRC_DONE)
	@echo "INFO: PG floating-cell deep-dive (net-centric audit)"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/pg_deepdive.tcl 2>&1 \
	    | tee $(FC_LOGS)/pg_deepdive.log
	@grep -q "^PG_DEEPDIVE_OK" $(FC_LOGS)/pg_deepdive.log \
	    || (echo "ERROR: pg_deepdive did not reach PG_DEEPDIVE_OK marker"; exit 1)
	@cat $(FC_REPORTS)/08_pg_deepdive.rep

$(ABSTRACT_DONE): $(DRC_DONE)
	@echo "INFO: [Phase 6] partition export (LEF, DEF, GDS, NDM, Verilog, SDC, UPF, SPEF, SDF)"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/6_partition_export.tcl 2>&1 \
	    | tee $(FC_LOGS)/6_partition_export.log
	@grep -q "^FC_STAGE_OK: abstract" $(FC_LOGS)/6_partition_export.log \
	    || (echo "ERROR: fc_abstract did not reach FC_STAGE_OK marker — see $(FC_LOGS)/6_partition_export.log"; exit 1)
	@touch $@

fc_abstract: $(ABSTRACT_DONE)

# Friendly alias — the deliverable the chip-top integrator cares about
# is the GDSII hard macro. fc_abstract emits it under outputs/.
gdsii: fc_abstract
	@gds="$(FC_OUTPUTS)/$(TOP).gds"; \
	if [ -f "$$gds" ]; then \
	    echo "INFO: GDSII hard macro at $$gds"; \
	    ls -lh "$$gds"; \
	elif [ -f "$$gds.gz" ]; then \
	    echo "INFO: GDSII hard macro at $$gds.gz"; \
	    ls -lh "$$gds.gz"; \
	else \
	    echo "ERROR: GDS not found — check $(FC_LOGS)/6_partition_export.log"; exit 1; \
	fi

# ── Formality LEC (post-export) ───────────────────────────────────────────
$(LEC_DONE): $(ABSTRACT_DONE)
	@echo "INFO: [Phase 7] Formality LEC — RTL vs post-layout netlist"
	$(MAKE) -C $(FM_FLOW_DIR) lec
	@touch $@

fc_lec: $(LEC_DONE)

# ── PrimeTime ETM (post-export) ───────────────────────────────────────────
$(ETM_DONE): $(ABSTRACT_DONE)
	@echo "INFO: [Phase 7b] PrimeTime ETM — boundary timing model"
	$(MAKE) -C $(PT_FLOW_DIR) etm
	@touch $@

fc_etm: $(ETM_DONE)

# Memory FF .db build hook (no-op for the shipped rf_16k macro).
LC_SHELL = lc_shell
mem_ff_db: | dirs
	@mkdir -p $(MEM_FF_DB_DIR)
	@echo "INFO: scanning rf_*k macros for missing FF .db files"
	cd $(MEM_FF_DB_DIR) && $(LC_BIN_DIR)/$(LC_SHELL) -f $(SHARED_SCRIPTS)/build_mem_ff_db.tcl 2>&1 \
	    | tee $(MEM_FF_DB_DIR)/build_mem_ff_db.log
	@echo "INFO: FF .db scan finished — see $(MEM_FF_DB_DIR)/build_mem_ff_db.log"

# fc_all = full PnR + LEC sign-off (CI / tape-in)
fc_all: fc fc_lec
	@echo ""
	@echo "INFO: Fusion Compiler flow + Formality LEC complete for $(MODULE)"
	@echo "INFO: LEC reports : $(FM_FLOW_DIR)/reports/"

# ── synth_netlist: LEC-friendly intermediate ─────────────────────────────
# Open the compile.design checkpoint and write a post-synthesis Verilog
# netlist. Used by the formality lec_synth target — comparing RTL against
# this netlist avoids the sequential-opto transformations FC layers on
# during CTS + route_opt that cause LEC failures with auto-gen Chisel
# code (the "20 failures + 14k unverified" bring-up residual). Together
# with FC's internal block-to-block consistency checking, this gives a
# transitive RTL → post-route equivalence proof.
SYNTH_NETLIST = $(FC_OUTPUTS)/$(TOP).synth.v
synth_netlist: $(SYNTH_NETLIST)

$(SYNTH_NETLIST): $(SYNTH_DONE)
	@echo "INFO: writing post-synthesis netlist for LEC ($(SYNTH_NETLIST))"
	cd $(FC_WORK) && $(FC_SHELL) -f $(FC_DIR)/scripts/write_synth_netlist.tcl 2>&1 \
	    | tee $(FC_LOGS)/write_synth_netlist.log
	@grep -q "^FC_STAGE_OK: synth_netlist" $(FC_LOGS)/write_synth_netlist.log \
	    || (echo "ERROR: write_synth_netlist did not reach FC_STAGE_OK"; exit 1)

# Full flow
fc: fc_abstract
	@echo ""
	@echo "INFO: Fusion Compiler partition flow complete for $(MODULE)"
	@echo "INFO: Reports : $(FC_REPORTS)/"
	@echo "INFO: Outputs : $(FC_OUTPUTS)/"
	@echo "INFO: Logs    : $(FC_LOGS)/"

# ── GUI on the most recently saved block ─────────────────────────────────
BLOCK ?= signoff.design

gui: $(FUSION_LIB)
	@b="$(BLOCK)"; \
	for cand in $$b signoff.design route.design cts.design compile.design init.design; do \
	    if [ -d "$(FC_BLOCK_DIR)/$(TOP)/$$cand" ]; then b="$$cand"; break; fi; \
	done; \
	echo "INFO: opening $(MODULE).dlib:$(TOP)/$$b"; \
	cd $(FC_WORK) && $(FC_SHELL) -x "open_lib $(MODULE).dlib; open_block $(MODULE).dlib:$(TOP)/$$b; gui_start"

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	rm -rf $(FC_WORK) $(FC_LIBS) $(FC_LOGS) $(FC_REPORTS) $(FC_OUTPUTS)
	rm -rf $(FC_DIR)/*.svf $(FC_DIR)/alib-* $(FC_DIR)/.synopsys*

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "TideLink — Fusion Compiler Partition Flow (TSMC 65 LP)"
	@echo ""
	@echo "Stages run in order; each depends on the previous stage's"
	@echo "save_block sentinel."
	@echo ""
	@echo "Usage:"
	@echo "  make fc                 - Run the full flow (through export)"
	@echo "  make gdsii              - fc + report the GDSII deliverable"
	@echo "  make fc_all             - fc + Formality LEC (CI / tape-in)"
	@echo "  make fc_init            - Phase 1: init_design + floorplan + PG mesh"
	@echo "  make fc_synth           - Phase 2: compile_fusion"
	@echo "  make fc_cts             - Phase 3: clock_opt"
	@echo "  make fc_route           - Phase 4: route_auto + route_opt"
	@echo "  make fc_pg              - Phase 4a: post-route PG rail rebind"
	@echo "  make fc_signoff         - Phase 4b: RC extract + per-scenario QoR"
	@echo "  make fc_drc             - Phase 5: DRC tier 0/1/1b (+ ICV opt-in)"
	@echo "  make drc_summary        - Re-display the DRC summary table"
	@echo "  make fc_abstract        - Phase 6: write LEF/DEF/GDS/NDM/Verilog/"
	@echo "                              SDC/UPF + per-scenario SPEF/SDF + manifest"
	@echo "  make fc_lec             - Formality LEC (delegates to ../formality)"
	@echo "  make fc_etm             - PrimeTime ETM (delegates to ../primetime)"
	@echo "  make fusion_lib         - Build fusion ref lib only"
	@echo "  make mem_ff_db          - Rebuild any missing FF mem .db's"
	@echo "  make gui                - fc_shell -gui"
	@echo "  make clean              - Remove all generated files"
	@echo ""
	@echo "Opt-in vars / files:"
	@echo "  ICV_DRC_RUNSET=<path>   - foundry .rs runset; enables ICV"
	@echo "                            signoff DRC at fc_drc"
	@echo "  GDS_LAYER_MAP=<path>    - enables GDS stream-out at fc_abstract"
	@echo "                            (default in common.mk)"
	@echo "  FC_PG_PITCH=<μm>        - PG mesh pitch (default 50)"
	@echo "  inputs/routing_rules.tcl"
	@echo "                          - NDR/antenna rules at fc_route"
	@echo "                            (copy .template; off by default)"
	@echo ""
	@echo "Knobs (override at make-time):"
	@echo "  MODULE                  - default $(MODULE)"
	@echo "  FC_CORE_UTILIZATION     - default $(FC_CORE_UTILIZATION) (area-first)"
	@echo "  FC_ASPECT_RATIO         - default $(FC_ASPECT_RATIO)"
	@echo "  FC_CLOCK_GATING         - default $(FC_CLOCK_GATING) (on/off)"
	@echo ""
	@echo "Module    : $(MODULE)"
	@echo "Top       : $(TOP)"
	@echo "Flist     : $(FLIST)"
	@echo "Work dir  : $(FC_WORK)"
	@echo "Reports   : $(FC_REPORTS)/"
	@echo "Outputs   : $(FC_OUTPUTS)/"

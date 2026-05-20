# TideLink ASIC implementation drop — chip-top staging area.
#
# The FC partition flow under syn/asic/fusion-compiler is the source of
# truth for every deliverable. This Makefile copies / symlinks the
# fc_abstract products under outputs/ into a single per-MODULE drop
# directory at the project's canonical `imp/ASIC/<module>/` location,
# so chip-top integrators always pick up a self-contained snapshot.

MODULE ?= tidelink_top_full
TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

FC_DIR        := $(TIDELINK_HOME)/syn/asic/fusion-compiler
FC_OUTPUTS    := $(FC_DIR)/outputs

PT_DIR        := $(TIDELINK_HOME)/syn/asic/primetime
PT_OUTPUTS    := $(PT_DIR)/outputs

# Resolve TOP from MODULE (mirrors common.mk's mapping).
TOP_tidelink_top_full = tidelink_top
TOP_tidelink_top      = tidelink_top
TOP := $(or $(TOP_$(MODULE)),$(MODULE))

STAGE_DIR     := $(TIDELINK_HOME)/imp/ASIC/$(MODULE)

.PHONY: stage clean help fc gdsii

# Build the GDSII upstream then stage it into imp/ASIC/$(MODULE)/.
gdsii: fc stage

fc:
	$(MAKE) -C $(FC_DIR) gdsii MODULE=$(MODULE)

stage:
	@if [ ! -f "$(FC_OUTPUTS)/$(TOP).gds" ] && [ ! -f "$(FC_OUTPUTS)/$(TOP).gds.gz" ]; then \
	    echo "ERROR: no GDS at $(FC_OUTPUTS)/$(TOP).gds(.gz) — run 'make gdsii' first"; \
	    exit 1; \
	fi
	@mkdir -p $(STAGE_DIR)
	@echo "INFO: staging partition deliverables from $(FC_OUTPUTS)/ -> $(STAGE_DIR)/"
	@# Single-file deliverables (logic netlist, abstracts, manifest).
	@for f in $(FC_OUTPUTS)/$(TOP).v \
	          $(FC_OUTPUTS)/$(TOP).pg.v \
	          $(FC_OUTPUTS)/$(TOP).sdc \
	          $(FC_OUTPUTS)/$(TOP).def \
	          $(FC_OUTPUTS)/$(TOP).lef \
	          $(FC_OUTPUTS)/$(TOP).upf \
	          $(FC_OUTPUTS)/$(TOP).gds \
	          $(FC_OUTPUTS)/$(TOP).gds.gz \
	          $(FC_OUTPUTS)/$(TOP).sdf \
	          $(FC_OUTPUTS)/MANIFEST.md; do \
	    if [ -f "$$f" ]; then \
	        cp -L "$$f" $(STAGE_DIR)/; \
	    fi; \
	done
	@# Sign-off + audit reports — drop into reports/ subdir so the chip-top
	@# integrator can see DRC summary, PG deep-dive, signoff QoR alongside
	@# the hard-macro itself.
	@FC_REPORTS=$(TIDELINK_HOME)/syn/asic/fusion-compiler/reports; \
	    if [ -d "$$FC_REPORTS" ]; then \
	        mkdir -p $(STAGE_DIR)/reports; \
	        for r in 07_summary.rep 08_pg_deepdive.rep 04h_pg_stitch.rep \
	                 05_signoff.qor.rep 05_signoff.scen_slow.setup.rep \
	                 05_signoff.scen_fast.setup.rep \
	                 05_signoff.scen_slow.hold.rep \
	                 05_signoff.scen_fast.hold.rep \
	                 05_signoff.area.rep 05_signoff.power.rep \
	                 06_abstract_manifest.txt; do \
	            if [ -f "$$FC_REPORTS/$$r" ]; then cp -L "$$FC_REPORTS/$$r" $(STAGE_DIR)/reports/; fi; \
	        done; \
	    fi
	@# Per-scenario SDF + per-corner SPEF — pull in by glob so the
	@# rcbest/rcworst × temperature variants (e.g. .scen_slow.spef.rcbest_-40.spef
	@# .scen_slow.spef.rcbest_125.spef etc.) all land in the drop. Also
	@# picks up the .spef_scenario index files alongside.
	@for pat in $(TOP).scen_slow.sdf $(TOP).scen_fast.sdf \
	            $(TOP).scen_slow.spef* $(TOP).scen_fast.spef* \
	            $(TOP).scen_slow.svf $(TOP).scen_fast.svf; do \
	    for f in $(FC_OUTPUTS)/$$pat; do \
	        if [ -f "$$f" ]; then cp -L "$$f" $(STAGE_DIR)/; fi; \
	    done; \
	done
	@# Stage SVF guidance so chip-top LEC can re-verify if needed.
	@if [ -d "$(FC_OUTPUTS)/svf" ]; then \
	    mkdir -p $(STAGE_DIR)/svf; \
	    cp -L $(FC_OUTPUTS)/svf/*.svf $(STAGE_DIR)/svf/ 2>/dev/null || true; \
	fi
	@if [ -d "$(PT_OUTPUTS)" ]; then \
	    echo "INFO: also staging PrimeTime ETM models"; \
	    cp -rL $(PT_OUTPUTS)/. $(STAGE_DIR)/etm/ 2>/dev/null || true; \
	fi
	@echo "INFO: drop ready at $(STAGE_DIR)/"
	@ls -lh $(STAGE_DIR)/

clean:
	rm -rf $(STAGE_DIR)

help:
	@echo "TideLink — ASIC drop staging"
	@echo ""
	@echo "Targets:"
	@echo "  make gdsii      - Build (FC) + stage the partition drop"
	@echo "                    (calls 'make -C ../syn/asic/fusion-compiler gdsii'"
	@echo "                     then copies outputs into imp/ASIC/\$(MODULE)/)"
	@echo "  make stage      - Stage only (assumes fc_abstract already run)"
	@echo "  make clean      - Remove the staging directory"
	@echo ""
	@echo "Module    : $(MODULE)"
	@echo "Top       : $(TOP)"
	@echo "Source    : $(FC_OUTPUTS)/"
	@echo "Drop      : $(STAGE_DIR)/"

include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# ── Paths ──────────────────────────────────────────────────────────────────
RTLA_DIR     = $(TIDELINK_HOME)/syn/asic/rtl-architect
RTLA_WORK    = $(RTLA_DIR)/RTLA_WORK
LOGFILE      = $(MODULE)_ra.log
RPT_DIR      = $(MODULE)_ra_reports

# ── RTL Architect (from RM kit) ───────────────────────────────────────────
RA = rtl_shell

.PHONY: ra init_design rtl_opt metrics gui clean setup help

# Default: run full flow (init_design -> rtl_opt -> metrics)
ra: metrics
	@echo "INFO: RTL Architect flow complete for $(MODULE)"
	@echo "INFO: Reports in $(RTLA_WORK)/rpts/"
	@echo "INFO: Logs in $(RTLA_WORK)/logs_rtl/"

# ── Set up RM working directory ──────────────────────────────────────────
# Copies the Synopsys RTLA-RM kit and overlays TideLink customisations
$(RTLA_WORK)/setup:
	@echo "INFO: Setting up RTLA RM working directory..."
	rm -rf $(RTLA_WORK)
	mkdir -p $(RTLA_WORK)
	cp -Rp $(RTLA_RM_PATH)/rm_rtl_flat_scripts   $(RTLA_WORK)/
	cp -Rp $(RTLA_RM_PATH)/rm_rtl_hier_scripts    $(RTLA_WORK)/
	cp -Rp $(RTLA_RM_PATH)/rm_rtl_explore_scripts $(RTLA_WORK)/
	cp -Rp $(RTLA_RM_PATH)/rm_setup               $(RTLA_WORK)/
	cp -Rp $(RTLA_RM_PATH)/rm_user_plugin_scripts $(RTLA_WORK)/
	cp -Rp $(RTLA_RM_PATH)/rm_utilities           $(RTLA_WORK)/
	@echo "INFO: Overlaying TideLink customisations..."
	cp $(RTLA_DIR)/rm_setup/design_setup.tcl  $(RTLA_WORK)/rm_setup/design_setup.tcl
	cp $(RTLA_DIR)/$(MODULE).FC.read_design.tcl $(RTLA_WORK)/
	touch $@

setup: $(RTLA_WORK)/setup

# ── RM flow stages ───────────────────────────────────────────────────────
init_design: $(RTLA_WORK)/setup
	cd $(RTLA_WORK) && $(RA) -f ./rm_rtl_flat_scripts/init_design.tcl 2>&1 | tee $(RTLA_DIR)/$(LOGFILE)
	@echo "INFO: init_design complete"

rtl_opt: init_design
	cd $(RTLA_WORK) && $(RA) -f ./rm_rtl_flat_scripts/rtl_opt.tcl 2>&1 | tee -a $(RTLA_DIR)/$(LOGFILE)
	@echo "INFO: rtl_opt complete"

metrics: rtl_opt
	cd $(RTLA_WORK) && $(RA) -f ./rm_rtl_flat_scripts/metrics.tcl 2>&1 | tee -a $(RTLA_DIR)/$(LOGFILE)
	@echo "INFO: metrics complete"
	@# Copy reports back to project tree
	mkdir -p $(RTLA_DIR)/$(RPT_DIR)
	cp -r $(RTLA_WORK)/rpts/* $(RTLA_DIR)/$(RPT_DIR)/ 2>/dev/null || true

# ── GUI mode ─────────────────────────────────────────────────────────────
gui: $(RTLA_WORK)/setup
	cd $(RTLA_WORK) && $(RA) -gui

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	rm -rf $(RTLA_WORK)
	rm -rf *_ra_reports *_ra.log
	rm -rf HDL_LIBRARIES rtl_output.txt rtl_command.log
	rm -rf *.pvl *.syn *.mr *.svf alib-52 work default.svf
	rm -rf ARCH RA_work WORK.nlib *_work *_ra_design
	rm -rf presto_gensys_json_file_location

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "TideLink RTL Architect Flow (Synopsys RM-based)"
	@echo ""
	@echo "Usage:"
	@echo "  make ra                        - Run full RTLA flow (default: $(MODULE))"
	@echo "  make ra MODULE=<name>          - Run for a specific module"
	@echo "  make init_design               - Run init_design stage only"
	@echo "  make rtl_opt                   - Run up to rtl_opt stage"
	@echo "  make metrics                   - Run up to metrics stage"
	@echo "  make gui                       - Open RTL Architect GUI"
	@echo "  make setup                     - Set up RM working directory only"
	@echo "  make clean                     - Remove all generated files"
	@echo ""
	@echo "Available modules:"
	@$(foreach mod,$(MODULES),echo "  $(mod)";)
	@echo ""
	@echo "RM Kit:    $(RTLA_RM_PATH)"
	@echo "Work Dir:  $(RTLA_WORK)"
	@echo "Reports:   $(RPT_DIR)/"

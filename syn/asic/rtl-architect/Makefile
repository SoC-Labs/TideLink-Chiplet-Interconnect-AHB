# The RM tarball and the Artisan LEF are site facts; declare them as required
# before the include so `make site-check` names them too.
SITE_VARS_REQUIRED += RTLA_RM_PATH RTLA_LEF_FILE
include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# ── Paths ──────────────────────────────────────────────────────────────────
RTLA_DIR     = $(TIDELINK_HOME)/syn/asic/rtl-architect
RTLA_WORK    = $(RTLA_DIR)/RTLA_WORK
LOGFILE      = $(MODULE)_ra.log
RPT_DIR      = $(MODULE)_ra_reports

# ── EDA tool binaries ───────────────────────────────────────────────────
# Set in <repo>/site.env, or leave unset with the tools already on PATH from a
# site module file. An install path with its exact version is a per-machine
# fact, so it is not committed here.
export PATH := $(if $(RTLA_BIN_DIR),$(RTLA_BIN_DIR):)$(if $(ICC2_BIN_DIR),$(ICC2_BIN_DIR):)$(PATH)

# ── LEF file for fusion library creation ─────────────────────────────────
# The Arm Artisan std-cell LEF. Its path carries the library variant and the
# drop revision, so it is named whole in site.env (RTLA_LEF_FILE) rather than
# assembled from PHYS_IP_PATH here.
LEF_FILE     = $(RTLA_LEF_FILE)
export LEF_FILE

.PHONY: ra gui clean setup fusion_lib help

# Default: run full flow (fusion_lib -> init_design -> rtl_opt -> metrics)
ra: $(RTLA_WORK)/setup $(RTLA_WORK)/fusion_lib/sc12_lib
	cd $(RTLA_WORK) && $(MAKE) -f rm_setup/Makefile_rtla_flat all 2>&1 | tee $(RTLA_DIR)/$(LOGFILE)
	@# Copy reports back to project tree
	mkdir -p $(RTLA_DIR)/$(RPT_DIR)
	cp -r $(RTLA_WORK)/rpts_fc/* $(RTLA_DIR)/$(RPT_DIR)/ 2>/dev/null || true
	@echo ""
	@echo "INFO: RTL Architect flow complete for $(MODULE)"
	@echo "INFO: Reports in $(RTLA_DIR)/$(RPT_DIR)/"
	@echo "INFO: Log at $(RTLA_DIR)/$(LOGFILE)"

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
	mkdir -p $(RTLA_WORK)/logs_rtl
	touch $@

setup: $(RTLA_WORK)/setup

# ── Create fusion reference library from LEF + db ────────────────────────
# This is a one-time preparation step; the resulting NDM library is used
# by RTL Architect as a physical reference for area/congestion estimation.
$(RTLA_WORK)/fusion_lib/sc12_lib: $(RTLA_WORK)/setup
	@echo "INFO: Creating fusion reference library from LEF + db..."
	cd $(RTLA_WORK) && lm_shell -f $(RTLA_DIR)/create_fusion_lib.tcl 2>&1 | tee $(RTLA_WORK)/logs_rtl/create_fusion_lib.log
	@test -d $@ || (echo "ERROR: Fusion library creation failed"; exit 1)
	@echo "INFO: Fusion reference library created"

fusion_lib: $(RTLA_WORK)/fusion_lib/sc12_lib

# ── GUI mode ─────────────────────────────────────────────────────────────
gui: $(RTLA_WORK)/setup $(RTLA_WORK)/fusion_lib/sc12_lib
	cd $(RTLA_WORK) && rtl_shell -gui

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
	@echo "  make fusion_lib                - Create fusion reference library only"
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

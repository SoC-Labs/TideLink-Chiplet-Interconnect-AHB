# Pin MODULE to the same partition cut the FC flow built so the netlist
# / SPEF / SDC paths resolve consistently. Override on the command line
# for a smaller cut (e.g. `make etm MODULE=tidelink_top`).
MODULE ?= tidelink_top_full
include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# Force the ASIC flist for the netlist roles in extract_etm.tcl
override FLIST := $(TIDELINK_HOME)/flists/$(MODULE)_asic.flist
export FLIST

# ── Paths ──────────────────────────────────────────────────────────────────
export PT_DIR     = $(TIDELINK_HOME)/syn/asic/primetime
export PT_LOGS    = $(PT_DIR)/logs
export PT_REPORTS = $(PT_DIR)/reports
export PT_WORK    = $(PT_DIR)/work
export PT_OUTPUTS = $(PT_DIR)/outputs

# Inherit FC outputs for the gate netlist + per-scenario SPEF/SDC lookup
export FC_DIR     = $(TIDELINK_HOME)/syn/asic/fusion-compiler
export FC_OUTPUTS = $(FC_DIR)/outputs

# ── Tool binary ────────────────────────────────────────────────────────────
# PT_BIN_DIR is set in <repo>/site.env, or left unset with pt_shell already on
# PATH from a site module file. An install path with its exact version is a
# per-machine fact, so it is not committed here.
export PATH := $(if $(PT_BIN_DIR),$(PT_BIN_DIR):)$(PATH)

PT_SHELL = pt_shell

# FC writes the netlist using the elaboration top name (TOP), not MODULE.
NETLIST = $(FC_OUTPUTS)/$(TOP).v

.PHONY: etm gui clean help dirs

dirs:
	@mkdir -p $(PT_LOGS) $(PT_REPORTS) $(PT_WORK) $(PT_OUTPUTS)

# ── ETM extraction ────────────────────────────────────────────────────────
# Depends on the FC gate netlist (written by 6_partition_export.tcl) and
# its per-scenario SPEF (written after 5_signoff.tcl's update_timing -full).
# pt_shell exits 0 even on Tcl errors, so — like the FC + FM flows — the
# PT_ETM_OK marker grep is the real success signal.
etm: $(NETLIST) | dirs
	@echo "INFO: PrimeTime ETM extraction for $(MODULE) (TOP=$(TOP))"
	@cd $(PT_WORK) && set -o pipefail; \
	    $(PT_SHELL) -f $(PT_DIR)/scripts/extract_etm.tcl 2>&1 \
	    | tee $(PT_LOGS)/extract_etm.log; \
	    rc=$${PIPESTATUS[0]}; \
	    grep -q "^PT_ETM_OK" $(PT_LOGS)/extract_etm.log || rc=1; \
	    if [ $$rc -ne 0 ]; then \
	        echo "ERROR: ETM extraction did not pass — see $(PT_LOGS)/extract_etm.log"; \
	        exit 1; \
	    fi
	@echo "INFO: ETM PASS — models in $(PT_OUTPUTS)/  reports in $(PT_REPORTS)/"

# Surface a clear error if FC hasn't produced the netlist yet
$(NETLIST):
	@echo "ERROR: $(NETLIST) missing — run \`make -C $(FC_DIR) fc_abstract\` first" >&2
	@exit 1

# ── GUI on the extraction session ─────────────────────────────────────────
gui: dirs
	cd $(PT_WORK) && $(PT_SHELL) -gui -f $(PT_DIR)/scripts/extract_etm.tcl

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	rm -rf $(PT_LOGS) $(PT_REPORTS) $(PT_WORK) $(PT_OUTPUTS)
	rm -f  $(PT_DIR)/pt_shell_command.log $(PT_DIR)/*.svf

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo "TideLink — PrimeTime ETM extraction (TSMC 65 LP)"
	@echo ""
	@echo "Builds the boundary timing model fc_shell U-2022.12 cannot"
	@echo "(no write_lib_model -format etm). One ETM per corner whose"
	@echo "SPEF the FC flow delivered (slow + fast scenarios)."
	@echo ""
	@echo "Targets:"
	@echo "  make etm     - extract_model -> .db/.lib per corner"
	@echo "  make gui     - pt_shell -gui (debug the session)"
	@echo "  make clean   - Remove logs/reports/work/outputs"
	@echo ""
	@echo "Module    : $(MODULE)"
	@echo "Top       : $(TOP)"
	@echo "Netlist   : $(NETLIST)"
	@echo "ETM out   : $(PT_OUTPUTS)/"
	@echo "Reports   : $(PT_REPORTS)/"

include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# ── Paths ──────────────────────────────────────────────────────────────────
TCL_SCRIPT = $(TIDELINK_HOME)/syn/asic/design-compiler/dc.tcl
RPT_DIR    = $(MODULE)_dc_reports
OUT_DIR    = $(MODULE)_dc_output
LOGFILE    = $(MODULE)_dc.log

# ── Design Compiler ───────────────────────────────────────────────────────
DC = dc_shell

.PHONY: syn syn_asic syn_saif gui clean help

syn:
	$(DC) -f $(TCL_SCRIPT) 2>&1 | tee $(LOGFILE)

syn_asic:
	FLIST=$(ASIC_FLIST) $(DC) -f $(TCL_SCRIPT) 2>&1 | tee $(LOGFILE)

syn_saif:
	FLIST=$(ASIC_FLIST) SAIF_FILE=$(SAIF_FILE) $(DC) -f $(TCL_SCRIPT) 2>&1 | tee $(LOGFILE)

gui:
	DC_GUI=1 design_vision -f $(TCL_SCRIPT)

clean:
	rm -rf *_dc_reports *_dc_output *_dc.log *.pvl *.syn *.mr *.svf \
	       alib-52 work default.svf design_lib \
	       command.log *.log.bak

help:
	@echo "TideLink Design Compiler Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make syn                       - Run DC synthesis (default: $(MODULE))"
	@echo "  make syn MODULE=<name>         - Synthesise a specific module"
	@echo "  make syn_asic                  - Run DC synthesis with ASIC SRAM (rf_16k)"
	@echo "  make syn_saif SAIF_FILE=<path> - Run DC synthesis with SAIF-based power"
	@echo "  make gui                       - Run in Design Vision GUI"
	@echo "  make gui MODULE=<name>         - GUI for a specific module"
	@echo "  make clean                     - Remove generated files"
	@echo ""
	@echo "Available modules:"
	@$(foreach mod,$(MODULES),echo "  $(mod)";)
	@echo ""
	@echo "Libraries: $(TARGET_LIB)"
	@echo "Reports:   <module>_dc_reports/"
	@echo "Netlists:  <module>_dc_output/"

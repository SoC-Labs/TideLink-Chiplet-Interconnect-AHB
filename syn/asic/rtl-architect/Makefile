include $(dir $(lastword $(MAKEFILE_LIST)))/../common.mk

# ── Paths ──────────────────────────────────────────────────────────────────
TCL_SCRIPT = $(TIDELINK_HOME)/syn/asic/rtl-architect/rtl_architect.tcl
RPT_DIR    = $(MODULE)_ra_reports
LOGFILE    = $(MODULE)_ra.log

# ── RTL Architect ──────────────────────────────────────────────────────────
RA = /eda/synopsys/2022-23/RHELx86/RTL-ARCH_2022.12/bin/rtl_shell

.PHONY: ra gui clean help

ra:
	$(RA) -f $(TCL_SCRIPT) 2>&1 | tee $(LOGFILE)

gui:
	RA_GUI=1 $(RA) -gui -f $(TCL_SCRIPT)

clean:
	rm -rf *_ra_reports *_ra_design *_ra.log *.pvl *.syn *.mr *.svf \
	       alib-52 work default.svf design_lib ARCH RA_work \
	       HDL_LIBRARIES rtl_output.txt rtl_command.log

help:
	@echo "TideLink RTL Architect Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make ra                        - Run RTL Architect (default: $(MODULE))"
	@echo "  make ra MODULE=<name>          - Run for a specific module"
	@echo "  make gui                       - Run in GUI mode (default: $(MODULE))"
	@echo "  make gui MODULE=<name>         - Run in GUI mode for a specific module"
	@echo "  make clean                     - Remove generated files"
	@echo ""
	@echo "Available modules:"
	@$(foreach mod,$(MODULES),echo "  $(mod)";)
	@echo ""
	@echo "Libraries: $(TARGET_LIB)"
	@echo "Reports:   <module>_ra_reports/"

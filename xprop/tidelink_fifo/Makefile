# VC Formal X-propagation flow for tidelink_fifo (requires CMSDK)

export TIDELINK_HOME := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
export CMSDK_DIR     ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

MODULE  = tidelink_fifo
SCRIPT  = xprop.tcl
WORKDIR = work
LOGFILE = xprop.log

VC_FORMAL      = vc_formal
VC_FORMAL_FLAGS = -f $(TIDELINK_HOME)/flist/$(MODULE).flist

.PHONY: xprop clean gui help

xprop:
	$(VC_FORMAL) -sverilog $(VC_FORMAL_FLAGS) \
		-tcl $(SCRIPT) \
		-work $(WORKDIR) \
		-l $(LOGFILE)
	@if grep -q "FAIL\|ERROR" $(LOGFILE) 2>/dev/null; then \
		echo "  >> $(MODULE): FAIL"; \
	else \
		echo "  >> $(MODULE): PASS"; \
	fi

gui:
	$(VC_FORMAL) -sverilog $(VC_FORMAL_FLAGS) \
		-work $(WORKDIR) \
		-gui

clean:
	rm -rf $(WORKDIR) $(LOGFILE) xprop_results.rpt xprop_summary.rpt \
		vc_formal.fsdb vc_formal.log novas.* verdi* *.vpd
	@echo "$(MODULE) formal cleaned"

help:
	@echo "VC Formal X-propagation: $(MODULE)"
	@echo ""
	@echo "  make xprop       - Run X-propagation checks"
	@echo "  make gui         - Open VC Formal GUI"
	@echo "  make clean       - Remove generated files"
	@echo ""
	@echo "  CMSDK_DIR: $(CMSDK_DIR)"

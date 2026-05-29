# =============================================================================
# calibrator_force_bisect cocotb sim — paired tidelink_top with hierarchical
# forces neutralising one calibrator output per test, to isolate which output
# is causing the AUTOCAL=1 M→S asymmetry.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
# MODULE selects which test_variant_*.py to run (default = baseline = no force,
# matches tidelink_top_pair behaviour for reference).
MODULE  ?= test_variant_0_baseline

# Each variant gets its own sim_build directory so we can run several in
# parallel.
SIM_BUILD ?= sim_build_$(MODULE)

# SKID_BITS exposed for future skid sweeps; default 0 = passthrough so the
# protocol path is exercised without alignment artefacts.
SKID_BITS ?= 0
export SKID_BITS

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
# Suppress VCD dump in the bisect tests (state read via APB / log lines).
# Set TB_NO_DUMP=0 on the make line to re-enable for a single debug run.
TB_NO_DUMP ?= 1
ifeq ($(TB_NO_DUMP),1)
COMPILE_ARGS += +define+TB_NO_DUMP
endif
# SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

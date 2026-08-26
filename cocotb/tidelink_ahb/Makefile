SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
# Both modules run in one simv invocation (cocotb comma-separated list) so the
# drain/credit-return regression gates in CI alongside the AHB write-path tests.
MODULE   = test_tidelink_ahb,test_tidelink_drain_credit

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_ahb.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── C Driver Shared Library (for driver-in-the-loop testing) ────────────
TL_SW        := $(TIDELINK_HOME)/src/sw
CC_HOST      := gcc
CFLAGS_HOST  := -shared -fPIC -DHAL_TEST_MODE -O0 -g -Wall -Wextra

# Default target: build C driver then run cocotb simulation
all: libtidelink_driver.so sim

# Ensure generated headers exist (from RDL sources) before compiling
.PHONY: generate-headers
generate-headers:
	$(MAKE) -C $(TL_SW) generate

libtidelink_driver.so: generate-headers $(TL_SW)/tidelink.c tidelink_test_wrappers.c \
                       $(TL_SW)/tidelink.h $(TL_SW)/hal_io.h
	$(CC_HOST) $(CFLAGS_HOST) -I$(TL_SW) -include $(TL_SW)/hal_io.h \
	    $(TL_SW)/tidelink.c tidelink_test_wrappers.c -o $@

.PHONY: driver-so clean-driver
driver-so: libtidelink_driver.so

clean-driver:
	rm -f libtidelink_driver.so

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink_ahb.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

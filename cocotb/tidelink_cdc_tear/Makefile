SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

MODULE  ?= test_cdc_tear

# ── DUT KIND ────────────────────────────────────────────────────────────
# DUT_KIND=a2l (default): WlinkGenericFCReplayV2_13 (a2l replay, has an override)
# DUT_KIND=l2a          : WlinkGenericFCReplayV2_12 (die_b RX replay -- the real
#                         A->B offender; deps-only, no override on this branch)
DUT_KIND ?= a2l
export DUT_KIND

ifeq ($(DUT_KIND),l2a)
  TOPLEVEL        = tb_cdc_tear_l2a
  VERILOG_SOURCES = $(CURDIR)/tb_cdc_tear_l2a.sv
  FLIST           = $(TIDELINK_HOME)/flists/tidelink_cdc_tear_l2a.flist
  LOCAL_DUT       := $(TIDELINK_HOME)/src/rtl/local_overrides/WlinkGenericFCReplayV2_12.v
  DEPS_DUT        := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_12.v
else
  TOPLEVEL        = tb_cdc_tear
  VERILOG_SOURCES = $(CURDIR)/tb_cdc_tear.sv
  FLIST           = $(TIDELINK_HOME)/flists/tidelink_cdc_tear.flist
  LOCAL_DUT       := $(TIDELINK_HOME)/src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v
  DEPS_DUT        := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v
endif

# ── DUT source selection ────────────────────────────────────────────────
# Default: use the local-override DUT if it exists (the in-tree production
# module), else fall back to the pristine deps source.
# Force the pristine pre-fix deps source with: make USE_DEPS_DUT=1
DUT_SRC_F  := $(CURDIR)/dut_src.f
ifeq ($(USE_DEPS_DUT),1)
  DUT_SRC := $(DEPS_DUT)
else
  DUT_SRC := $(if $(wildcard $(LOCAL_DUT)),$(LOCAL_DUT),$(DEPS_DUT))
endif

# Regenerate the tiny DUT-source include file every invocation.
$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))

# ── Fix-model / provenance knobs passed through to the cocotb test ──────────
# TEAR_FIX=1  -> the test drives winc_force1=1 (models the w_inc=1 self-heal
#               fix) and EXPECTS the tear to heal (PASS).
# TEAR_FIX=0  -> the test leaves the real RTL's edge-triggered w_inc in place
#               and the injected tear is expected to WEDGE (FAIL) -- this is the
#               red gate that only goes green once the RTL ships w_inc=1.
TEAR_FIX     ?= 0
export TEAR_FIX
export USE_DEPS_DUT

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(FLIST)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# ── Code coverage ───────────────────────────────────────────────────────
ifdef COVERAGE
  CM_METRICS    ?= line+cond+fsm+tgl+branch
  COMPILE_ARGS  += -cm $(CM_METRICS)
  SIM_ARGS      += -cm $(CM_METRICS) -cm_dir $(CURDIR)/coverage.vdb
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

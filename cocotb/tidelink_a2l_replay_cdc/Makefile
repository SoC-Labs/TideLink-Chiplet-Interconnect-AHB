SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE  ?= test_a2l_replay_cdc

# ── DUT source selection ────────────────────────────────────────────────
# Default: use the local-override DUT if it exists (so the in-tree CDC fix is
# what gets simulated), else fall back to the deps (pre-fix) source.
# Force the pristine pre-fix deps source with: make USE_DEPS_DUT=1
LOCAL_DUT  := $(TIDELINK_HOME)/src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v
DEPS_DUT   := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v
DUT_SRC_F  := $(CURDIR)/dut_src.f

ifeq ($(USE_DEPS_DUT),1)
  DUT_SRC := $(DEPS_DUT)
else
  DUT_SRC := $(if $(wildcard $(LOCAL_DUT)),$(LOCAL_DUT),$(DEPS_DUT))
endif

# Regenerate the tiny DUT-source include file every invocation.
$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_a2l_replay_cdc.flist
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

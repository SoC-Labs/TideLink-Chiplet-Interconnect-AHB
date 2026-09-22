# =============================================================================
# tidelink_chiplet_pair_autocal cocotb sim
#
# Two cross-wired axi_chiplet_controller instances, both with AUTOCAL_ENABLE=1
# (the chiplet controller's in-RTL calibrator FSM enabled — the same setting
# tidelink_top imposes on the chiplet from above). Used to isolate the
# calibrator-PHY interaction that is suspected of causing the M→S asymmetric
# corruption seen in cocotb/tidelink_top_pair.
#
# Reference envs (do not modify):
#   cocotb/wlink_pair/        — same pair, AUTOCAL_ENABLE=0, PASSES.
#   cocotb/tidelink_top_pair/ — full TideLink wrapper, AUTOCAL_ENABLE=1, FAILS.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../../..)
export TIDELINK_HOME
# Site configuration: per-machine tool + IP roots, with NO default path.
# mk/site.mk reads site.env and names anything missing. site.env.example
# says what each variable locates.
SITE_VARS_REQUIRED += CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
# Default to the passive state probe — fastest iteration loop (no traffic).
# Run the doorbell-style sideband test explicitly:
#   make MODULE=test_chiplet_pair_doorbell
MODULE  ?= test_calibrator_state_probe

SKID_BITS ?= 0
export SKID_BITS

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: gui
gui: $(SIM_BUILD)/simv
	@$(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

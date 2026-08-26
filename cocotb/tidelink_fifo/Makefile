SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_tidelink_fifo

# TL-033: the DUT flist is overridable so `make noguard` can swap in the
# guard-DISABLED FIFO-control variant (non-vacuity A/B). Default = shipping flist.
TL_FIFO_FLIST ?= $(TIDELINK_HOME)/flists/tidelink_fifo.flist

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TL_FIFO_FLIST)
COMPILE_ARGS += $(EXTRA_COMPILE_ARGS)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TL_FIFO_FLIST)
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

# TL-022: run the whole FIFO suite against a silicon-faithful RANDOM/adversarial
# SRAM power-up (the ASIC rf_16k register-file inits to random LEGAL values, NOT
# the FPGA all-zero). The phantom-pop guard (tidelink_fifo_ctrl.sv rx_fifo_empty
# + FC-write-path arm) MUST hold: no phantom pop, credit_count never exceeds
# MAX_CREDITS after reset. Default 0xFF fill (SRAM[0]=0xFFFF_FFFF => clamp_length
# maximal, the worst case); `make randinit SEEDARG=+TL_SRAM_SEED=7` sweeps a
# seeded $random pattern. Separate sim_build (different +define).
# Default 0xFF fill (worst case). Seed sweep: `make randinit PLUSARGS=+TL_SRAM_SEED=7`.
.PHONY: randinit
randinit:
	$(MAKE) SIM_BUILD=sim_build_randinit \
	        EXTRA_COMPILE_ARGS=+define+TIDELINK_SRAM_RAND_INIT

# TL-033 non-vacuity A/B: recompile the SAME suite against the guard-DISABLED
# FIFO-control variant (BUG-002 saturate guard removed => credit consume WRAPS).
# test_43_credit_underflow_saturates_whitebox MUST FAIL here (credit_count=0x1FFF)
# while it PASSES against the shipping RTL — that FAIL-vs-PASS is the non-vacuity
# proof. Runs only the underflow test by default; `make noguard TESTCASE=` for all.
.PHONY: noguard
noguard:
	$(MAKE) SIM_BUILD=sim_build_noguard \
	        TL_FIFO_FLIST=$(CURDIR)/tidelink_fifo_noguard.flist \
	        TESTCASE=test_43_credit_underflow_saturates_whitebox

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

.PHONY: gui
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

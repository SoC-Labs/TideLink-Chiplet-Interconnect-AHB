SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv

TOPLEVEL = tb_top
MODULE   = test_tidelink

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# --- Build-staleness guard: recompile on flist-sourced RTL edits. VERILOG_SOURCES
#     lists only the tb; DUT RTL arrives via `-f <flist>` (invisible to make), so
#     without this an RTL-only edit re-runs the STALE simv. See SIM_GATE_COVERAGE.md.
#     (The gate-level sim_asic/sim_saif targets run `clean` first, so they rebuild
#     unconditionally and need no guard here.)
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_TL_FLIST   := $(TIDELINK_HOME)/flists/tidelink.flist
_flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

# ── Code coverage (shared wiring; inert unless COVERAGE=1) ──────────────
#     One include for all 62 benches. See cocotb/coverage.mk for why the
#     per-bench copies were replaced and why -cm_dir must be absolute.
include $(CURDIR)/../coverage.mk

include $(shell cocotb-config --makefiles)/Makefile.sim

VERDI_HOME = /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2

# ── Gate-level netlist simulation ────────────────────────────────────────
# Standard cell and memory macro Verilog models
export PHYS_IP_PATH   ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp
export STDCELL_VERILOG ?= $(PHYS_IP_PATH)/sc12_base_rvt/r0p0/verilog
export MEM_PATH       ?= /research/precompiled_mems/TSMC65/rf_16k

NETLIST_FLIST = $(TIDELINK_HOME)/flists/tidelink_netlist.flist

.PHONY: gui sim_rtl_saif sim_asic sim_saif
gui: $(SIM_BUILD)/simv
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

sim_rtl_saif: clean
	$(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		SIM_ARGS="+vcs+dumpvars+waves.vcd +saif_enable"
	@echo "RTL SAIF file generated: switching_activity.saif"

sim_asic: clean
	COCOTB_RESOLVE_X=ZEROS $(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		VERILOG_SOURCES="$(CURDIR)/tb_top.sv" \
		COMPILE_ARGS="-full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
		-f $(NETLIST_FLIST) +nospecify +notimingcheck" \
		SIM_ARGS="+vcs+dumpvars+waves.vcd"

sim_saif: clean
	COCOTB_RESOLVE_X=ZEROS $(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		VERILOG_SOURCES="$(CURDIR)/tb_top.sv" \
		COMPILE_ARGS="-full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
		-f $(NETLIST_FLIST) +nospecify +notimingcheck" \
		SIM_ARGS="+vcs+dumpvars+waves.vcd +saif_enable"
	@echo "SAIF file generated: switching_activity.saif"

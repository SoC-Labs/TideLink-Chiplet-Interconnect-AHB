SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
# Site configuration: per-machine tool + IP roots, with NO default path.
# mk/site.mk reads site.env and names anything missing. site.env.example
# says what each variable locates.
SITE_VARS_REQUIRED += CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk

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

# ── Gate-level netlist simulation ────────────────────────────────────────
# Standard-cell and memory-macro Verilog models. PHYS_IP_PATH and MEM_PATH are
# site facts with NO default — the library subdirectory name below is a release
# code, so STDCELL_VERILOG is set WHOLE in site.env when it does not match.
# Only the sim_asic / sim_saif targets read them, so they are checked in those
# recipes rather than in SITE_VARS_REQUIRED: an RTL run must not need a PDK.
export STDCELL_VERILOG
export PHYS_IP_PATH
export MEM_PATH

# Every gate-level target starts with this.
SITE_REQUIRE_GATE = \
	@$(SITE_REQUIRE) PHYS_IP_PATH "the Arm physical-IP root (gate-level cell models)"; \
	$(SITE_REQUIRE) STDCELL_VERILOG "the standard-cell Verilog model directory"; \
	$(SITE_REQUIRE) MEM_PATH "the compiled memory-macro directory (rf_16k)"

NETLIST_FLIST = $(TIDELINK_HOME)/flists/tidelink_netlist.flist

.PHONY: gui sim_rtl_saif sim_asic sim_saif
gui: $(SIM_BUILD)/simv
	@$(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
	unset NOVAS_HOME; VERDI_HOME=$(VERDI_HOME) MODULE=$(MODULE) \
	TESTCASE=$(TESTCASE) COCOTB_RESOLVE_X=ZEROS \
	$(SIM_BUILD)/simv -l sim.log -gui $(SIM_ARGS)

sim_rtl_saif: clean
	$(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		SIM_ARGS="+vcs+dumpvars+waves.vcd +saif_enable"
	@echo "RTL SAIF file generated: switching_activity.saif"

sim_asic: clean
	$(SITE_REQUIRE_GATE)
	COCOTB_RESOLVE_X=ZEROS $(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		VERILOG_SOURCES="$(CURDIR)/tb_top.sv" \
		COMPILE_ARGS="-full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
		-f $(NETLIST_FLIST) +nospecify +notimingcheck" \
		SIM_ARGS="+vcs+dumpvars+waves.vcd"

sim_saif: clean
	$(SITE_REQUIRE_GATE)
	COCOTB_RESOLVE_X=ZEROS $(MAKE) SIM=vcs TOPLEVEL=tb_top MODULE=$(MODULE) \
		VERILOG_SOURCES="$(CURDIR)/tb_top.sv" \
		COMPILE_ARGS="-full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
		-f $(NETLIST_FLIST) +nospecify +notimingcheck" \
		SIM_ARGS="+vcs+dumpvars+waves.vcd +saif_enable"
	@echo "SAIF file generated: switching_activity.saif"

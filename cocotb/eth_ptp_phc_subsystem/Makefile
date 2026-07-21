# =============================================================================
# eth_ptp_phc_subsystem — first functional sim of ethernet_ss_ahb_phc.
#
# Drives the subsystem's external AHB slave (eth_ss_0) directly from cocotb
# (no TideLink link, no CPU firmware). Proves the HA1588 RTC -> ha1588_servo ->
# PHC discipline loop THROUGH the real subsystem AHB matrix, and reproduces the
# real MII PTP capture in the same sim.
#
# Run:
#   cd cocotb/eth_ptp_phc_subsystem
#   source ../../set_env.sh
#   source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
#   export TIDELINK_PHY_V2=1
#   make
#
# NB: after ANY RTL edit in the sibling repos, `make clean` (or rm -rf
# sim_build) before trusting a result — the DUT RTL arrives via -f <flist>
# which make cannot see (stale-simv trap, memory project_cocotb_stale_simv...).
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Ethernet subsystem repo (read-only reference). Its set_env.sh must be sourced
# first (sets ETH_SS_HOME, ETHMAC_AHB_HOME, PHC_HOME, SOCLABS_*, etc.).
ETH_SS_HOME     ?= $(realpath $(TIDELINK_HOME)/../nanoSoC-refactor/ethernet-subsystem-ahb)
export ETH_SS_HOME
ETH_SS_COCOTB   := $(ETH_SS_HOME)/cocotb/ethernet_ss_ahb

TOPLEVEL = tb_top
MODULE  ?= test_phc_chain

export PYTHONPATH := $(CURDIR):$(PYTHONPATH)

SIM_BUILD ?= sim_build

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# ---- tb sources -------------------------------------------------------------
VERILOG_SOURCES = $(CURDIR)/tb_top.sv

# ---- Expanded PHC-variant subsystem flist -----------------------------------
# The whole ethernet_ss_ahb_phc.flist recursively expanded (env vars resolved,
# -f includes inlined) into ONE flat flist by the subsystem's own expander.
EXPANDED_FLIST = $(CURDIR)/$(SIM_BUILD)/eth_phc_expanded.flist
EXPAND         = $(ETH_SS_COCOTB)/expand_flist.sh

COMPILE_ARGS += -f $(EXPANDED_FLIST)

# ---- Files the PHC flist omits (present in the base bench's Makefile, not in
#      any flist): APB slave mux, FPGA ROM word cell + model, DMEM region. ----
COMPILE_ARGS += $(CMSDK_DIR)/logical/cmsdk_apb_slave_mux/verilog/cmsdk_apb_slave_mux.v
COMPILE_ARGS += $(ETH_SS_HOME)/src/rtl/fpga_lib/rom/sl_fpga_rom_word.v
COMPILE_ARGS += $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_rom.v
COMPILE_ARGS += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/src/regions/dmem/nanosoc_region_dmem.v

# subsystem compile defines / incdirs
COMPILE_ARGS += +define+CPU_M0PLUS
COMPILE_ARGS += +define+ETH_WISHBONE_B3
COMPILE_ARGS += +define+RAM_PRELOAD
COMPILE_ARGS += +incdir+$(ETH_SS_HOME)/src/rtl
COMPILE_ARGS += +define+ETH_IMEM_HEX=\"$(CURDIR)/image_spin.hex\"

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

# ---- Build-staleness guard (stale-simv trap) --------------------------------
# The expanded flist is regenerated every build (see rule below), and every
# bare source path it lists becomes a simv prerequisite, so an RTL-only edit in
# any sibling repo forces a recompile.
CUSTOM_COMPILE_DEPS += $(EXPANDED_FLIST)
include $(TIDELINK_HOME)/cocotb/flist_deps.mk
_flist_deps := $(call flist_srcs,$(EXPANDED_FLIST))
CUSTOM_COMPILE_DEPS += $(_flist_deps)

include $(shell cocotb-config --makefiles)/Makefile.sim

# ---- flist expansion (AFTER the include so `sim` stays the default goal) -----
# Generated once; RTL staleness is caught by the per-source-path deps
# (_flist_deps) added to CUSTOM_COMPILE_DEPS above. `make clean` removes it.
$(EXPANDED_FLIST): $(ETH_SS_HOME)/flist/ethernet_ss_ahb_phc.flist
	@mkdir -p $(dir $@)
	bash $(EXPAND) $(ETH_SS_HOME)/flist/ethernet_ss_ahb_phc.flist > $@

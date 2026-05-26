# =============================================================================
# wlink_rx_link_layer -- standalone cocotb unit sim for WlinkRxLinkLayer
# =============================================================================
#
# Pins the byte-align FSM "state==1 stuck on training filler" bug at unit
# level. The slow pair sim (cocotb/wlink_pair/test_paired_recal_to_link_data.py)
# catches the same bug in ~60 s; this unit harness covers it in ~5 s/case.
#
# Two compile flavours:
#   make                  -> compile vs src/rtl/local_overrides/WlinkRxLinkLayer.v
#                            (current L4 v3 first_short_pkt_seen gate). Tests
#                            test_01..test_05 should ALL PASS here.
#   make sim_base         -> compile vs the base submodule RTL
#                            deps/axi-chiplet-controller/logical/wlink/...
#                            (no gate, stock Wlink RTL). test_01 + test_05
#                            SHOULD FAIL here, proving the test catches the
#                            real bug at unit level.
#
# Run (always clean sim_build first -- VCS does NOT rebuild simv on RTL
# edits, so a stale simv would give a false PASS):
#
#   cd /home/dam1n19/SoCLabs/tidelink
#   source set_env.sh
#   export CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v
#   rm -rf cocotb/wlink_rx_link_layer/sim_build cocotb/wlink_rx_link_layer/sim_build_base
#   make -C cocotb/wlink_rx_link_layer
#   make -C cocotb/wlink_rx_link_layer sim_base
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
# license.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

WLINK_DIR    := $(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/wlink
OVERRIDE_DIR := $(TIDELINK_HOME)/src/rtl/local_overrides

# Switch the DUT source. Default = local override (L4 v3 gate active).
# `make sim_base` sets USE_BASE_RTL=1 to compile the stock submodule RTL,
# which proves the unit test reproduces the bug.
USE_BASE_RTL ?= 0

ifeq ($(USE_BASE_RTL),1)
    DUT_SRC := $(WLINK_DIR)/WlinkRxLinkLayer.v
else
    DUT_SRC := $(OVERRIDE_DIR)/WlinkRxLinkLayer.v
endif

# WlinkRxLinkLayer pulls in WlinkEccSyndrome (header ECC) and WavDemetReset
# (io_enable 2-flop sync). No other submodules.
VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(DUT_SRC) \
                  $(WLINK_DIR)/WlinkEccSyndrome.v \
                  $(WLINK_DIR)/WavDemetReset.v

TOPLEVEL = tb_top
MODULE  ?= test_wlink_rx_link_layer

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience target: build+run against base (unfixed) RTL in a separate
# sim_build dir so it doesn't collide with the default override build.
.PHONY: sim_base
sim_base:
	$(MAKE) -C $(CURDIR) SIM_BUILD=sim_build_base USE_BASE_RTL=1 MODULE=test_wlink_rx_link_layer

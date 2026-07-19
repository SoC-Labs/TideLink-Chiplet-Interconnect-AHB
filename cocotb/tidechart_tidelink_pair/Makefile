# =============================================================================
# tidechart_tidelink_pair — TideChart <-> TideLink pair integration smoke (F18)
#
# Compiles the TideLink V2 pair (two tidelink_top, cross-wired GPIO PHY) PLUS a
# tidechart_shim/tidechart_controller on each die, wired to the tc_axis_* /
# link_active / congestion-sideband ports exactly as the ASIC integration
# (nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv) does.
#
# Reuses, READ-ONLY, from the sibling benches:
#   - cocotb/tidelink_top_pair/{pad_skid.sv, tb_phc_model.sv}  (harness cells)
#   - cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py  (PairTB bring-up,
#     imported by the test — see test_tc_pair_smoke.py)
#   - nanosoc-ethernet-chiplet/src/rtl/tidechart_shim.sv       (the flatten shim)
#
# Always a V2 build (TIDELINK_PHY_V2=1 rides in tidelink_fpga_v2.flist), matching
# the shipping bitstream. Run:
#     make            # runs test_tc_pair_smoke
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME  ?= $(realpath $(CURDIR)/../..)
TIDECHART_HOME ?= $(realpath $(TIDELINK_HOME)/../tidechart)
CHIPLET_HOME   ?= $(realpath $(TIDELINK_HOME)/../nanosoc-ethernet-chiplet)
export TIDELINK_HOME
export TIDECHART_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0
# CMSDK fpga_sram model — mirrors set_env.sh (prefer the vendor path under
# CMSDK_DIR, else the in-repo stub). Referenced by flists/tidelink_top.flist.
export CMSDK_FPGA_SRAM_V ?= $(firstword \
    $(wildcard $(CMSDK_DIR)/logical/models/memories/cmsdk_fpga_sram.v) \
    $(TIDELINK_HOME)/imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v)

PAIR_DIR = $(TIDELINK_HOME)/cocotb/tidelink_top_pair

# Harness cells reused from the pair bench + the chiplet's flatten shim.
VERILOG_SOURCES  = $(CURDIR)/tb_tc_pair.sv
VERILOG_SOURCES += $(PAIR_DIR)/pad_skid.sv
VERILOG_SOURCES += $(PAIR_DIR)/tb_phc_model.sv
VERILOG_SOURCES += $(CHIPLET_HOME)/src/rtl/tidechart_shim.sv

TOPLEVEL = tb_tc_pair
MODULE  ?= test_tc_pair_smoke

# Make the pair bench importable (PairTB bring-up harness reuse).
export PYTHONPATH := $(PAIR_DIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
# TideLink V2 flist (carries +define+TIDELINK_PHY_V2) + TideChart RTL flist.
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(TIDECHART_HOME)/flist/tidechart.flist

TB_TOP_NO_DUMP ?= 0
ifeq ($(TB_TOP_NO_DUMP),1)
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
else
SIM_ARGS     += +vcs+dumpvars+waves.vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

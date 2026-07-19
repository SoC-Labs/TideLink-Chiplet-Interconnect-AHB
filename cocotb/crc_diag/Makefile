# =============================================================================
# cocotb/crc_diag — link-layer header-CRC root-cause bench (V2 pair).
#
# Two cross-wired V2 (TIDELINK_PHY_V2) tidelink_top instances, EPOCH_PROFILE=zero
# (no skew — the clean-link baseline). Identical harness to
# cocotb/tidelink_top_pair_v2 (tb_top.sv / pad_skid.sv / pair_v2_common.py are
# verbatim copies); nothing in src/rtl is touched. The CRC is re-ENABLED from
# the test (APB write to SM Control bit[16], or a cocotb Force when the APB
# write does not take) so that the check which ships disabled can be observed.
#
#   make MODULE=test_crc_enable_probe   # can SW clear disable_crc on each die?
#   make MODULE=test_crc_length_ladder  # length threshold where crc_errors ticks
#   make MODULE=test_crc_lane_width     # 8-lane (1 beat) vs 4-lane (2 beats)
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
MODULE  ?= test_crc_enable_probe

export PYTHONPATH := $(CURDIR):$(TIDELINK_HOME)/python:$(PYTHONPATH)

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

V2_FLIST  ?= $(TIDELINK_HOME)/flists/tidelink_fpga_v2.flist
COMPILE_ARGS += -f $(V2_FLIST)

COMPILE_ARGS += +define+TB_TOP_SKID_BITS=0
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=1
export BYPASS_AUTONEG = 1
export EPOCH_PROFILE ?= zero

DUMP ?= 0
ifeq ($(DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
else
COMPILE_ARGS += +define+TB_TOP_NO_DUMP
endif

SIM_BUILD := sim_build_crcdiag

include $(shell cocotb-config --makefiles)/Makefile.sim

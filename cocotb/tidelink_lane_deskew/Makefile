# =============================================================================
# tidelink_lane_deskew cocotb UNIT TEST
#   Standalone test of src/rtl/local_overrides/tidelink_lane_deskew.sv — the
#   8-lane cross-lane deskew FIFO. The module is self-contained (`default_nettype
#   none`, no external deps), so we compile JUST that one file. Same simulator
#   (VCS) + flags style as cocotb/tidelink_top_pair.
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_lane_deskew.sv \
                  $(CURDIR)/tb_deskew.sv

TOPLEVEL = tb_deskew
MODULE  ?= test_lane_deskew

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb

# Wave dump (gated; off by default — keeps the run light).
TB_NO_DUMP ?= 1
ifneq ($(TB_NO_DUMP),1)
SIM_ARGS     += +vcs+dumpvars+waves.vcd
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

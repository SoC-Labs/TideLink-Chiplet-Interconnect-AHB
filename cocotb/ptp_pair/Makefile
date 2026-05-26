# =============================================================================
# ptp_pair cocotb sim — two paired chiplet controllers + cocotb-driven PTP SP
#
# Sibling of cocotb/wlink_pair. Same Wlink RTL flist, but the tb top is
# tb_ptp_pair (cocotb drives ptp_in and observes ptp_out on both sides).
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

# Reuse pad_skid.sv from wlink_pair — it is the same hardware model.
WLINK_PAIR_DIR ?= $(realpath $(CURDIR)/../wlink_pair)

VERILOG_SOURCES = $(CURDIR)/tb_ptp_pair.sv $(WLINK_PAIR_DIR)/pad_skid.sv
TOPLEVEL        = tb_ptp_pair

# Default to ALL four PTP tests. Each test guards with an
# automatic `link_reached_link_data` check and reports SKIP if the
# underlying link layer never reaches LINK_DATA (state 5).
MODULE ?= test_01_ptp_sync_crosses_after_bringup,test_02_ptp_followup_pairing,test_03_ptp_bidirectional,test_04_ptp_with_recal_disruption

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flist/tidelink_fpga.flist
SIM_ARGS     += +vcs+dumpvars+waves.vcd

# Make the wlink_pair test_link_bringup helpers importable for setup/lock.
export PYTHONPATH := $(WLINK_PAIR_DIR):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

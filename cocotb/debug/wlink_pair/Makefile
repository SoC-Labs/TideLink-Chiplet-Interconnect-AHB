# =============================================================================
# wlink_pair cocotb sim — two cross-wired axi_chiplet_controller instances
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME
export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0

PHY_ALIGN_DIR ?= $(realpath $(CURDIR)/../phy_align)
# Lane checker now lives in src/rtl as tidelink_lane_checker.sv but the module
# name `wlink_lane_checker` is preserved for backward compatibility with the
# existing testbench instantiations. The calibrator (tidelink_phy_align_calibrator
# / module wlink_phy_align_calibrator) is also picked up via the flist.
VERILOG_SOURCES = $(CURDIR)/tb_top.sv $(CURDIR)/pad_skid.sv

TOPLEVEL = tb_top
# Run both the original (informational) bring-up tests and the assertive
# regression tests added 2026-05-08 (test_07-09 cover per-channel handshake
# completion + cr_pkt_seen_rx latching, asserting rather than just logging).
# Default: existing tests. To run the skid-sweep test, override MODULE on the
# command line:  `make MODULE=test_pair_skid SKID_BITS=3`.
MODULE ?= test_link_bringup,test_assert_bringup

# ---------------------------------------------------------------------------
# SKID_BITS — bit-level skid inserted between TX and RX pads in tb_top to
# reproduce the FPGA serial-to-parallel boundary misalignment. Default 0 is
# a passthrough so all pre-existing tests keep their behaviour.
#   make SKID_BITS=3 MODULE=test_pair_skid          # uniform mode (legacy)
# ---------------------------------------------------------------------------
SKID_BITS ?= 0
export SKID_BITS

# ---------------------------------------------------------------------------
# Per-lane skid overrides (2026-05-14). If any SKID_LANE<n> is supplied on
# the command line, that lane's master→slave skid is set to that value;
# otherwise it falls back to the uniform SKID_BITS in the RTL. Likewise
# SKID_S_LANE<n> overrides the slave→master direction for lane <n>; if
# unset, slave→master mirrors master→slave (also driven via SKID_LANE<n>).
#
# Example: asymmetric per-lane skew, identical on both directions:
#   make MODULE=test_pair_align_asymmetric \
#        SKID_LANE0=3 SKID_LANE1=5 SKID_LANE2=0 SKID_LANE3=2 \
#        SKID_LANE4=7 SKID_LANE5=1 SKID_LANE6=4 SKID_LANE7=6
#
# Example: different patterns in each direction:
#   make MODULE=test_pair_align_asymmetric_master_slave \
#        SKID_LANE0=3 SKID_LANE1=5 ... \
#        SKID_S_LANE0=1 SKID_S_LANE1=2 ...
# ---------------------------------------------------------------------------
# Master→slave per-lane (used by m2s pad_skid; also default for s2m).
SKID_LANE0 ?=
SKID_LANE1 ?=
SKID_LANE2 ?=
SKID_LANE3 ?=
SKID_LANE4 ?=
SKID_LANE5 ?=
SKID_LANE6 ?=
SKID_LANE7 ?=
# Slave→master per-lane (independent override of s2m pad_skid).
SKID_S_LANE0 ?=
SKID_S_LANE1 ?=
SKID_S_LANE2 ?=
SKID_S_LANE3 ?=
SKID_S_LANE4 ?=
SKID_S_LANE5 ?=
SKID_S_LANE6 ?=
SKID_S_LANE7 ?=
export SKID_LANE0 SKID_LANE1 SKID_LANE2 SKID_LANE3
export SKID_LANE4 SKID_LANE5 SKID_LANE6 SKID_LANE7
export SKID_S_LANE0 SKID_S_LANE1 SKID_S_LANE2 SKID_S_LANE3
export SKID_S_LANE4 SKID_S_LANE5 SKID_S_LANE6 SKID_S_LANE7

# ---------------------------------------------------------------------------
# STUCK_LANES_MASK — 8-bit per-lane mask. Each set bit pins the
# corresponding lane to constant 0 in the m2s pad_skid (and, by default,
# the s2m pad_skid). Used to model a permanently un-calibratable lane.
# STUCK_LANES_MASK_S overrides s2m independently. Example: force lane 4
# stuck on master→slave only:  STUCK_LANES_MASK=0x10 STUCK_LANES_MASK_S=0x00
# ---------------------------------------------------------------------------
STUCK_LANES_MASK   ?=
STUCK_LANES_MASK_S ?=
export STUCK_LANES_MASK STUCK_LANES_MASK_S

# Build the per-lane +define+ list only for lanes that have been set.
SKID_PER_LANE_DEFINES :=
$(foreach n,0 1 2 3 4 5 6 7, \
  $(if $(SKID_LANE$(n)), \
    $(eval SKID_PER_LANE_DEFINES += +define+TB_TOP_SKID_LANE$(n)=$(SKID_LANE$(n)))))
$(foreach n,0 1 2 3 4 5 6 7, \
  $(if $(SKID_S_LANE$(n)), \
    $(eval SKID_PER_LANE_DEFINES += +define+TB_TOP_SKID_S_LANE$(n)=$(SKID_S_LANE$(n)))))
# STUCK_LANES_MASK is decimal/hex per-bit (e.g. 16 = 0x10 = lane 4 stuck).
# We pass it as a plain Verilog integer constant; the parameter declaration
# in tb_top.sv truncates/extends it to 8 bits as needed.
ifneq ($(strip $(STUCK_LANES_MASK)),)
SKID_PER_LANE_DEFINES += +define+TB_TOP_STUCK_LANES_MASK=$(STUCK_LANES_MASK)
endif
ifneq ($(strip $(STUCK_LANES_MASK_S)),)
SKID_PER_LANE_DEFINES += +define+TB_TOP_STUCK_LANES_MASK_S=$(STUCK_LANES_MASK_S)
endif

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fpga.flist
COMPILE_ARGS += +define+TB_TOP_SKID_BITS=$(SKID_BITS)
COMPILE_ARGS += $(SKID_PER_LANE_DEFINES)
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

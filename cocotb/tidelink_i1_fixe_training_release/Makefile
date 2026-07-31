# =============================================================================
# tidelink_i1_fixe_training_release — I1 / FIX-E training-hold self-deadlock
# regression (silicon-proven on the KR260 eth-chiplet recovery FCSM, 2026-07-30).
#
# UNIT env: compiles ONLY the DEPLOYED FPGA calibrator override
#   src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv
# (the exact RTL flists/tidelink_fpga_v2.flist builds) plus the thin wrapper
# tb_fixe.sv, with shrunk dwell/hold/validation timers.  Self-contained module,
# no submodules / no vendor IP, so no flist / no ARM_IP_LIBRARY_PATH needed.
#
# The test drives swi_training_hold_i (SWI_TRAINING_MODE, CTRL[6]) to model the
# bring-up recipe that held training HIGH while polling cal_done, and proves:
#   (a) DEADLOCK — with training HELD, the FSM parks in S_HOLD (state=6) past
#       HOLD_MAX with calibration_done=0 forever (reproduces the bug + pins the
#       :1499 !swi_training_mode_r gate);
#   (b) RELEASE  — dropping training drives S_HOLD -> S_VALIDATE -> S_DONE and
#       calibration_done asserts within a bounded window (proves the fix).
#
# Non-vacuity discriminator (see the test): FIXE_INVERT=1 SKIPS the release, so
# phase (b) must FAIL/time-out.  A vacuous test would pass either way.
#
# Invocation:
#   source ./set_env.sh
#   rm -rf cocotb/tidelink_i1_fixe_training_release/sim_build*
#   make -C cocotb/tidelink_i1_fixe_training_release
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# The DEPLOYED FPGA/ASIC calibrator override (NOT deps/, NOT src/rtl reference).
CAL_RTL = $(TIDELINK_HOME)/src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv

TOPLEVEL ?= tb_fixe
MODULE   ?= test_fixe_training_release

VERILOG_SOURCES = $(CURDIR)/tb_fixe.sv $(CAL_RTL)

# -debug_access+all/-kdb: needed for the hierarchical probes (u_dut.hold_ctr,
# u_dut.swi_training_mode_r) the test uses to assert the hold-timer saturated.
COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

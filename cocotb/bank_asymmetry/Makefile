# =============================================================================
# bank_asymmetry — behavioural reproducer for the bank-35/bank-13 IDELAYCTRL
#                  asymmetry on TideLink (§9 FPGA bring-up).
# =============================================================================
#
# This cocotb test stands the calibrator (best-of-sweep + first-match
# instances) up next to a SYNTHETIC per-lane eye-shape driver that paints
# narrow / skewed eyes on a configurable subset of lanes. It replays the
# bringup_health_probe.log oscillation pattern (master 0xf5/0xfd/0xd5/0xd7,
# slave 0xce/0x7f/0xee) at the RTL boundary, without instantiating Wav PHY.
#
# Test scenarios (see test_bank_asymmetry.py):
#   * UNIFORM            — all 8 lanes wide-eye; sanity
#   * BANK35             — master pattern: lanes 1,3 narrow (EYE_WIDTH=0)
#                          + 1-2-point centre shift vs lanes 0,2,4,5,6,7
#   * BANK35_FLIP        — slave pattern: lanes 0,4 narrow (mirrors HW)
#   * MARGINAL_BOUNCE    — eye-edge bounce on the narrow lanes (~18-cycle
#                          run-length, just clears LOCK_THRESH=16). Pins
#                          the first-match-wins failure mode.
#   * FIRST_VS_BEST_STAT — multi-seed Monte-Carlo over UNIFORM + BANK35
#                          eye centres; statistics on first-match vs
#                          best-of-sweep convergence rate.
#
# Run (always clean sim_build first):
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/bank_asymmetry/sim_build
#   make -C cocotb/bank_asymmetry
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv

TOPLEVEL = tb_top
MODULE  ?= test_bank_asymmetry

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# =============================================================================
# sim_robust — adversarial cocotb tests targeting silicon-only failure modes
# =============================================================================
#
# This directory holds tests that REPLICATE the silicon failure fingerprint
# we observed during the PYNQ-Z2 pair bring-up:
#
#    cal_done=0, fault byte=0x00, lk=0x00, fs=0, cr=0
#
# The default cocotb tests run the sim's BEHAVIOURAL interpretation, which is
# permissive. These tests use cocotb hierarchical refs + force/deposit to
# replicate the synth-interpretation defects that bit silicon:
#
#   test_fingerprint_calibrator         — Category 6: force cur_state stuck →
#                                         verify cal_done=0, lane_fault=0x00
#                                         (the EXACT silicon fingerprint).
#   test_adversarial_state              — Category 3: force cur_state to an
#                                         out-of-enum value (unique case +
#                                         out-of-enum). Verify FSM either
#                                         recovers or hits S_IDLE — does NOT
#                                         silently freeze.
#   test_reset_glitch                   — Category 2: deassert rst on cycle N
#                                         vs cycle N+5 between two calibrator
#                                         instances. Verify both converge.
#   test_drift_retrain                  — Category 4: 100-iteration retrain
#                                         loop; verify no state accumulates X
#                                         and lane_done resets cleanly each
#                                         pass.
#
# Run (always clean sim_build first):
#   cd /home/dam1n19/SoCLabs/td-bisect/sim-robust && source set_env.sh
#   rm -rf cocotb/sim_robust/sim_build
#   make -C cocotb/sim_robust                        # default: fingerprint
#   make -C cocotb/sim_robust MODULE=test_adversarial_state
#   make -C cocotb/sim_robust MODULE=test_reset_glitch
#   make -C cocotb/sim_robust MODULE=test_drift_retrain
#   make -C cocotb/sim_robust all                    # run all 4 modules
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME  ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

VERILOG_SOURCES = $(CURDIR)/tb_calibrator_robust.sv \
                  $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv

TOPLEVEL = tb_calibrator_robust
MODULE  ?= test_fingerprint_calibrator

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience meta-target: run every robustness test in sequence (each in its
# own sim_build so they don't share state). Failure of any one fails this
# target.
#
# NOTE: we call the cocotb-provided `sim` target explicitly (NOT a recursive
# `make` with no target) — otherwise the default goal would be this very
# meta-target and we'd loop forever.
.PHONY: sim_robust
sim_robust:
	@set -e ; \
	for m in test_fingerprint_calibrator test_adversarial_state \
	         test_reset_glitch test_drift_retrain ; do \
	  rm -rf $(CURDIR)/sim_build ; \
	  echo "=== running $$m ===" ; \
	  $(MAKE) -C $(CURDIR) sim MODULE=$$m ; \
	done

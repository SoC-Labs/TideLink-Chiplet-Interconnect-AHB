# =============================================================================
# tidelink_phy_align_calibrator — standalone cocotb unit sim for the §9 RTL
#   calibrator FSM: T3 continuous re-sweep + T3.2 peer-aware S_HOLD.
# =============================================================================
#
# This testbench instantiates ONE tidelink_phy_align_calibrator with NO PHY
# wrapper around it — lane_locked is driven directly by cocotb to script
# specific FSM transitions:
#
#   * T3 (continuous re-sweep): a sweep that ends with at least one lane
#     faulted (sweep_success=0) and role_locked=1 must NOT release to
#     S_DONE. The FSM must auto-re-arm (S_FINISH→S_ARM) and run a fresh
#     sweep with training_mode held HIGH. Commit 1e5f4e0.
#
#   * T3.2 (peer-aware S_HOLD): a sweep that ends with ALL lanes locked
#     (sweep_success=1) must NOT go S_FINISH→S_DONE — it must go
#     S_FINISH→S_HOLD, hold training_mode HIGH for HOLD_CYCLES (one full
#     cocotb-fast HOLD_CYCLES is exercised; we override DWELL_CYCLES /
#     HOLD_CYCLES via parameter knobs to keep the test under a second of
#     wall-clock time), THEN release to S_DONE. Commit 50f7869.
#
# We override DWELL_CYCLES (and therefore HOLD_CYCLES=8*128*DWELL_CYCLES via
# the calibrator's parameter default) to small values for sim speed. The
# RTL behaviour is unchanged — only the magnitudes shrink.
#
# Run (always clean sim_build first):
#   cd /home/dam1n19/td_idelay_wt && source set_env.sh
#   rm -rf cocotb/tidelink_phy_align_calibrator/sim_build
#   make -C cocotb/tidelink_phy_align_calibrator
# =============================================================================
SIM             = vcs
TOPLEVEL_LANG   = verilog

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
export TIDELINK_HOME

# ---------------------------------------------------------------------------
# TB_VARIANT selects which standalone TB and test set to run.
#
#   single   (default) — tb_top.sv: ONE calibrator DUT, used by the T3/T3.2
#                        FSM tests and the best-of-sweep placeholder.
#
#   compare  — tb_top_compare.sv: TWO calibrator DUTs (best-of-sweep silicon
#              default vs first-match-wins compat) driven from the SAME
#              cocotb-painted lane_locked trajectory. Used by
#              test_best_of_sweep_compare to prove that the two policies
#              select DIFFERENT (slip,phase) on an eye-edge-marginal input.
#
# Examples:
#   make                                # single-DUT default (T3/T3.2 + placeholder)
#   make TB_VARIANT=compare             # two-DUT best-of-sweep comparator
#   make TB_VARIANT=single MODULE=test_calibrator_t3   # T3/T3.2 only
# ---------------------------------------------------------------------------
TB_VARIANT ?= single

ifeq ($(TB_VARIANT),compare)
  VERILOG_SOURCES = $(CURDIR)/tb_top_compare.sv \
                    $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv
  TOPLEVEL = tb_top
  MODULE  ?= test_best_of_sweep_compare
else
  VERILOG_SOURCES = $(CURDIR)/tb_top.sv \
                    $(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv
  TOPLEVEL = tb_top
  # T3/T3.2 transitions are pinned by test_calibrator_t3; the best-of-sweep
  # placeholder pins the silicon-default policy. Run a subset by overriding
  # MODULE on the command line, e.g.
  #   make MODULE=test_calibrator_t3
  MODULE  ?= test_calibrator_t3,test_best_of_sweep_placeholder
endif

COMPILE_ARGS += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
SIM_ARGS     += +vcs+dumpvars+waves.vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

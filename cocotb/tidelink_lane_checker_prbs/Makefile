# =============================================================================
# DEPRECATED — tidelink_lane_checker_prbs
# =============================================================================
# This environment exercised the PRBS-7 sync-by-prediction lock-detect path
# in the pre-integration `tidelink_lane_checker` (feat/calibrator-prbs).
#
# The lane checker has been REPLACED by `deps/tidelink-gpio-phy` which uses
# constant 0x12EB / 0xED14 training patterns (no PRBS predictor) and a
# Hamming-distance matcher (TRAINING_MODULE_SPEC §2.3, §4). The old
# `src/rtl/tidelink_lane_checker.sv` was deleted in stage3 of the
# tidelink-gpio-phy integration; the testbench `tb_top.sv` instantiates a
# module that no longer exists with parameters/ports that no longer exist.
#
# Coverage of the new lane_checker lives in:
#   - deps/tidelink-gpio-phy/cocotb/lane_checker_single/
#   - deps/tidelink-gpio-phy/cocotb/lane_checker_8lane/
#
# To intentionally bring this environment back, rewrite tb_top.sv against the
# new `tidelink_lane_checker` ports (lane_data_i / lock_thresh_i /
# training_mode_w_i / sweep_active_i / clear_noise_i / lane_locked_o /
# wire_status_o / dwell_min_dist_o / noise_*_o) and replace PRBS expectations
# with constant-pattern (0x12EB / 0xED14) expectations.
# =============================================================================

.PHONY: all clean
all:
	@echo "============================================================"
	@echo " SKIP: tidelink_lane_checker_prbs DEPRECATED"
	@echo "       PRBS predictor replaced by Hamming-distance matcher in"
	@echo "       deps/tidelink-gpio-phy. See Makefile header for context."
	@echo "============================================================"

clean:
	rm -rf sim_build results.xml __pycache__ *.vcd *.fst

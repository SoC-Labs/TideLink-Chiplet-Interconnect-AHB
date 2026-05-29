# =============================================================================
# phy_align — cocotb tests for the per-lane PHY alignment / training mechanism
# =============================================================================
#
# This Makefile delegates to ../wlink_pair/ because the alignment test (currently
# `test_pair_align.py`) needs the full Wlink + axi_chiplet_controller testbench
# top to exercise master+slave bring-up. Once the PHY is extracted into its own
# repo, this directory becomes the cocotb entry point for PHY-only tests
# (driving a pad bundle, observing the Link2PHY bundle) and `test_pair_align.py`
# moves out of here into the TideLink-side integration suite.
#
# Until then: invoke this Makefile to run the §9 calibration test.
#
#   make SKID_BITS=3                # default test_pair_align with skid 3
#   make SKID_BITS=5 MODULE=test_pair_align
# =============================================================================

PHY_ALIGN_TEST_DIR := $(realpath $(CURDIR))
WLINK_PAIR_DIR     := $(realpath $(CURDIR)/../wlink_pair)

# Override the test-module location and default test name. cocotb resolves the
# Python module path via MODULE; we put PHY_ALIGN_TEST_DIR on PYTHONPATH so
# test_pair_align.py is importable.
export PYTHONPATH := $(PHY_ALIGN_TEST_DIR):$(PYTHONPATH)

MODULE    ?= test_pair_align
SKID_BITS ?= 3

# Per-module defaults for tb_top.sv stimulus parameters. The
# test_pair_align_partial_failure test asserts that lane 4 is stuck (via
# STUCK_LANES_MASK=0x10) — without this default a bare `make MODULE=...`
# invocation fails on the test's own setup-sanity check. Override on the
# command line as needed (e.g. STUCK_LANES_MASK=0x03 for lanes 0+1).
ifeq ($(MODULE),test_pair_align_partial_failure)
  STUCK_LANES_MASK ?= 16
endif
STUCK_LANES_MASK   ?=
STUCK_LANES_MASK_S ?=
export STUCK_LANES_MASK STUCK_LANES_MASK_S

# Delegate to the wlink_pair Makefile — it owns the testbench top compilation.
%:
	$(MAKE) -C $(WLINK_PAIR_DIR) MODULE=$(MODULE) SKID_BITS=$(SKID_BITS) STUCK_LANES_MASK=$(STUCK_LANES_MASK) STUCK_LANES_MASK_S=$(STUCK_LANES_MASK_S) $@

# Default goal: run the test
.PHONY: sim
sim:
	$(MAKE) -C $(WLINK_PAIR_DIR) MODULE=$(MODULE) SKID_BITS=$(SKID_BITS) STUCK_LANES_MASK=$(STUCK_LANES_MASK) STUCK_LANES_MASK_S=$(STUCK_LANES_MASK_S)

.DEFAULT_GOAL := sim

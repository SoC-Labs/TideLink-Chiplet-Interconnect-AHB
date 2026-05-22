# =============================================================================
# TideLink SystemVerilog anti-pattern lint
# =============================================================================
# Guards against two synth bug classes that bit autoneg on silicon but were
# sim-tolerant — bug #1 (latch from missing comb default) and bug #2
# (collapsed case from missing default). See sv_anti_pattern_lint.py
# docstring for context and the bug commits to mirror against.
#
# Targets:
#   make            -- lint chiplet controller + src/rtl (the default; fails
#                      with non-zero exit on findings, so works in CI)
#   make selftest   -- run the unit tests against synthetic bad/good fixtures
#                      to verify the linter still detects both bug classes
#   make all        -- selftest + lint
#   make clean      -- nothing to do (the linter writes no artefacts)
# =============================================================================

TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)
LINTER        := python3 $(CURDIR)/sv_anti_pattern_lint.py
SELFTEST      := python3 $(CURDIR)/test_lint_selftest.py

# Default lint scope: first-party RTL only (NOT BD-generated wlink, NOT the
# wav_latch_model behavioural placeholder). The linter walks these dirs.
LINT_PATHS := \
	$(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/top \
	$(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/address_translation \
	$(TIDELINK_HOME)/deps/axi-chiplet-controller/logical/apb_control \
	$(TIDELINK_HOME)/src/rtl

.PHONY: all lint selftest clean
all: selftest lint

lint:
	@echo "========================================"
	@echo " sv_anti_pattern_lint over first-party RTL"
	@echo "========================================"
	$(LINTER) $(LINT_PATHS)

selftest:
	@echo "========================================"
	@echo " sv_anti_pattern_lint selftest"
	@echo "========================================"
	$(SELFTEST)

clean:
	@:

# Top-level cocotb regression Makefile
# Usage:
#   make regression          Run all test environments
#   make tidelink_fifo       Run a single environment
#   make clean               Clean all environments

# ── Environment list ─────────────────────────────────────────────────────────
# tidelink_link_rate_regs_inert is the OFF-arm gate for the D2D link-rate
# feature: it certifies that tidelink_top at LINK_RATE_REGS_PRESENT=0 — the
# default, and what every shipping wrapper elaborates — still behaves exactly
# as it did before the feature existed. It belongs in ENVS rather than beside
# the link_rate_* targets below because it is ~17 s including compile, needs no
# link bring-up, and is a claim about the SHIPPING build, not about the divided
# modes. Its mutation table (8 edits to the OFF path, all caught) is in
# the header of tidelink_link_rate_regs_inert/test_link_rate_inert.py.
ENVS = tidelink_fifo tidelink_returner tidelink_apb_regs tidelink_apb_addr_ctrl tidelink tidelink_ahb tidelink_py_pair tidelink_fc_adapter tidelink_top tidelink_system tidelink_perf tidelink_perf_congestion \
       tidelink_addr_translator tidelink_autoneg tidelink_mul_iter tidelink_phc_cdc tidelink_ptp tidelink_ptp_servo \
       tidelink_idelay_rx tidelink_rxclk_buf tidelink_clkfreq_check tidelink_link_clk_div tidelink_link_rate_regs tidelink_link_rate_regs_inert tidelink_eye_regs tidelink_phy_align_calibrator \
       wav_d2d_gpio_tx wavd2d_gpiorx_clkbuf wavd2d_gpiorx_t3a wavd2d_gpiorx_t3a_off wavd2d_gpiorx_t3a_timeout

# ── Per-environment targets ──────────────────────────────────────────────────
# Each target runs make inside the subdirectory, collecting the result.

# DRY-RUN GUARD — the same hazard, and the same fix, as the root Makefile's
# sim_gate_run macro (root Makefile "Wave-0 fix #12a"). The body below is a
# @-prefixed shell block containing $(MAKE); GNU make EXECUTES any recipe line
# containing $(MAKE) even under -n/-q/-t. The sub-make inherits the flag and
# does nothing, so no run.log is produced, `grep -q 'FAIL=0'` fails, and the
# "dry" run WRITES "FAIL" into <env>/.result and truncates <env>/run.log --
# destroying a real result for a run that never happened.
#
# REPRODUCED 2026-09-11 while fixing this file: a single `make -C cocotb -p -q
# regression`, run only to read make's database, overwrote all 31 <env>/.result
# files with FAIL and truncated all 31 run.logs. Nothing simulated.
#
# The guard reads MAKEFLAGS' first word (the single-letter option cluster) and
# covers ALL THREE no-op modes, not just -n: q == --question and t == --touch
# carry the identical $(MAKE) exemption. The root Makefile's own guard covered
# only 'n' until this commit; it is widened to match.
define run_env
.PHONY: $(1)
$(1):
	@case "$$$${MAKEFLAGS%% *}" in \
	  *[nqt]*) echo "[regression] DRY-RUN (-n/-q/-t): would run $(1); NOT touching $(1)/.result or $(1)/run.log"; \
	       exit 0 ;; \
	esac; \
	echo "========================================"; \
	echo " Running: $(1)"; \
	echo "========================================"; \
	$$(MAKE) -C $(1) clean > /dev/null 2>&1; \
	$$(MAKE) -C $(1) 2>&1 | tee $(1)/run.log | grep -E '^\*\*|regression'; \
	if grep -q 'FAIL=0' $(1)/run.log 2>/dev/null; then \
	  echo "  >> $(1): PASS"; \
	  echo "PASS" > $(1)/.result; \
	else \
	  echo "  >> $(1): FAIL"; \
	  echo "FAIL" > $(1)/.result; \
	fi; \
	echo ""
endef

$(foreach env,$(ENVS),$(eval $(call run_env,$(env))))

# ── Regression target ────────────────────────────────────────────────────────
# THE SUMMARY RECIPE BELONGS TO THIS TARGET. Between 2ffc21a5 (2026-08-18) and
# 2026-09-11 it was tab-indented directly under the `.PHONY: link_rate_quick
# link_rate_full` line further down, which made it the recipe of `.PHONY` -- a
# target nothing ever builds. `regression: $(ENVS)` was left with NO recipe, so
# it exited 0 no matter how many environments wrote FAIL into their .result.
# `make regression` -- the CI job and the recipe in the README -- has reported
# success unconditionally for that whole period. Confirmed from make's own
# database: "recipe to execute (from 'cocotb/Makefile', line 79)" appeared under
# .PHONY, and the `regression:` entry had none.
#
# If you move this recipe, move it to a REAL target and re-run
# scripts/ci/tests/test_regression_exit_code.py, which fails if `regression`
# stops propagating a FAIL.
.PHONY: regression
regression: $(ENVS)
	@echo "========================================"
	@echo " Regression Summary"
	@echo "========================================"
	@pass=0; fail=0; \
	for env in $(ENVS); do \
	  result=$$(cat $$env/.result 2>/dev/null || echo "FAIL"); \
	  printf "  %-30s %s\n" "$$env" "$$result"; \
	  if [ "$$result" = "PASS" ]; then pass=$$((pass + 1)); else fail=$$((fail + 1)); fi; \
	done; \
	echo "----------------------------------------"; \
	echo "  PASS=$$pass  FAIL=$$fail  TOTAL=$$(( pass + fail ))"; \
	echo "========================================"; \
	[ "$$fail" -eq 0 ]

# ── D2D link-rate gates ──────────────────────────────────────────────────────
# The divider lets the D2D bit rate be lowered without moving the SoC clock.
# These run the EXISTING tidelink_top_pair bring-up suite at divided ratios via
# +LINK_DIV_RATIO — deliberately not a bespoke test, because the strongest
# evidence a divided link works is the suite the project already trusts passing
# unmodified.
#
# TWO TIERS, because the full sweep is ~18 min and an 18-minute default gate
# gets switched off:
#   link_rate_quick  /1 + /4    ~3.5 min   /1 is the control that proves the tb
#                                          hook is inert; /4 proves a divided
#                                          link trains and carries traffic.
#   link_rate_full   /1../16    ~18 min    complete coverage, for the non-quick
#                                          tier alongside the other long poles.
#
# NOT in ENVS on purpose: tidelink_top_pair is not in ENVS either, and whether
# the pair suite should be gated at all is a policy question for the regression
# owner, not something to change as a side effect of adding a rate check.
link_rate_quick:
	@for r in 0 2; do \
	  echo "== tidelink_top_pair @ /$$((1<<$$r)) =="; \
	  $(MAKE) -C tidelink_top_pair PLUSARGS=+LINK_DIV_RATIO=$$r || exit 1; \
	done

link_rate_full:
	@for r in 0 1 2 3 4; do \
	  echo "== tidelink_top_pair @ /$$((1<<$$r)) =="; \
	  $(MAKE) -C tidelink_top_pair PLUSARGS=+LINK_DIV_RATIO=$$r || exit 1; \
	done

.PHONY: link_rate_quick link_rate_full

# ── Coverage regression ──────────────────────────────────────────────────────
# Run the full regression with VCS code coverage enabled, then merge results.
#   make coverage
# Override metrics with: make coverage CM_METRICS=line+cond
CM_METRICS ?= line+cond+fsm+tgl+branch
COV_REPORT  = coverage_report

.PHONY: coverage coverage_merge
coverage: export COVERAGE=1
coverage: export CM_METRICS:=$(CM_METRICS)
coverage: regression coverage_merge

coverage_merge:
	@echo "========================================"
	@echo " Merging coverage databases"
	@echo "========================================"
	@echo "── Per-environment reports ──"
	@for env in $(ENVS); do \
	  urg -full64 -dir $$env/sim_build/simv.vdb -dir $$env/coverage.vdb \
	    -report $(COV_REPORT)/$$env -format both 2>&1 \
	    | grep -E 'Note|Error' || true; \
	done
	@echo ""
	@echo "── Per-environment coverage summary ──"
	@printf "  %-25s %6s %6s %6s %6s %6s %6s\n" "ENVIRONMENT" "SCORE" "LINE" "COND" "TOGGLE" "FSM" "BRANCH"
	@printf "  %-25s %6s %6s %6s %6s %6s %6s\n" "-------------------------" "------" "------" "------" "------" "------" "------"
	@for env in $(ENVS); do \
	  scores=$$(grep -A2 'Total Coverage Summary' $(COV_REPORT)/$$env/dashboard.txt 2>/dev/null \
	    | tail -1 | sed 's/--/  N\/A /g'); \
	  printf "  %-25s %s\n" "$$env" "$$scores"; \
	done
	@echo ""
	@echo "Coverage reports: $(COV_REPORT)/<env>/dashboard.html"

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@for env in $(ENVS); do \
	  $(MAKE) -C $$env clean > /dev/null 2>&1; \
	  rm -f $$env/run.log $$env/.result $$env/coverage.vdb; \
	done
	rm -rf merged_coverage.vdb $(COV_REPORT)
	@echo "All environments cleaned"

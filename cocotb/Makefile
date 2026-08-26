TIDELINK_HOME ?= $(realpath $(CURDIR)/..)
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

define run_env
.PHONY: $(1)
$(1):
	@echo "========================================"
	@echo " Running: $(1)"
	@echo "========================================"
	@$$(MAKE) -C $(1) clean > /dev/null 2>&1; \
	 $$(MAKE) -C $(1) 2>&1 | tee $(1)/run.log | grep -E '^\*\*|regression'; \
	 if grep -q 'FAIL=0' $(1)/run.log 2>/dev/null; then \
	   echo "  >> $(1): PASS"; \
	   echo "PASS" > $(1)/.result; \
	 else \
	   echo "  >> $(1): FAIL"; \
	   echo "FAIL" > $(1)/.result; \
	 fi
	@echo ""
endef

$(foreach env,$(ENVS),$(eval $(call run_env,$(env))))

# ── Regression target ────────────────────────────────────────────────────────
.PHONY: regression
regression: $(ENVS)

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

# ── Coverage regression ──────────────────────────────────────────────────────
# ⚠ THIS IS THE UNIT-TEST CORPUS ONLY, NOT THE GATE.  ENVS above is a 31-bench
# list that deliberately excludes tidelink_top_pair, tidelink_top_pair_v2,
# tidelink_axi_datanode_recovery, tidelink_error_injection and the eth_* relays
# -- i.e. every bench that exercises the full tidelink_top + XHB500 + Wlink DATA
# PATH.  Running coverage here and quoting the score is how you get a confident
# number over a partial corpus.
#
# For a coverage database over the WHOLE aggregate gate, use the project root:
#
#     make coverage_gate     # runs sim_gate with COVERAGE=1, merges, reports
#
# Both routes share cocotb/coverage.mk, so per-bench flags cannot drift.
#   make coverage                       # this (partial) corpus
#   make coverage CM_METRICS=line+cond  # fewer metrics
CM_METRICS ?= line+cond+fsm+tgl+branch
COV_ROOT    = $(TIDELINK_HOME)/imp/coverage
COV_REPORT  = $(TIDELINK_HOME)/imp/coverage_report_envs

.PHONY: coverage coverage_merge
coverage: export COVERAGE=1
coverage: export CM_METRICS:=$(CM_METRICS)
coverage: regression coverage_merge

# One vdb per (bench, SIM_BUILD) under the shared root -- see cocotb/coverage.mk.
# The old two-directory merge (`-dir $env/sim_build/simv.vdb -dir
# $env/coverage.vdb`) existed only because compile and run wrote to different
# places under a RELATIVE -cm_dir; that seam is gone.
coverage_merge:
	@echo "========================================"
	@echo " Merging coverage databases"
	@echo "========================================"
	@dirs=$$(ls -d $(COV_ROOT)/*.vdb 2>/dev/null | grep -v '/merged\.vdb$$'); \
	 test -n "$$dirs" || { echo " NO databases under $(COV_ROOT) — did COVERAGE=1 reach the benches?"; exit 1; }; \
	 args=""; for d in $$dirs; do args="$$args -dir $$d"; done; \
	 urg -full64 $$args -format both -report $(COV_REPORT) 2>&1 | grep -E 'Note|Error' || true
	@echo ""
	@echo "Coverage report: $(COV_REPORT)/dashboard.html (+ dashboard.txt)"
	@sed -n '/Total Coverage Summary/,+3p' $(COV_REPORT)/dashboard.txt 2>/dev/null || true

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@for env in $(ENVS); do \
	  $(MAKE) -C $$env clean > /dev/null 2>&1; \
	  rm -f $$env/run.log $$env/.result $$env/coverage.vdb; \
	done
	rm -rf merged_coverage.vdb $(COV_REPORT)
	@echo "All environments cleaned"

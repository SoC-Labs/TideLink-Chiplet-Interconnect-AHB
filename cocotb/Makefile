# Top-level cocotb regression Makefile
# Usage:
#   make regression          Run all test environments
#   make tidelink_fifo       Run a single environment
#   make clean               Clean all environments

ENVS = tidelink_fifo tidelink_returner tidelink_apb_regs tidelink_apb_addr_ctrl tidelink tidelink_ahb tidelink_py_pair tidelink_fc_adapter tidelink_top tidelink_system tidelink_perf tidelink_perf_congestion \
       tidelink_addr_translator tidelink_autoneg tidelink_mul_iter tidelink_phc_cdc tidelink_ptp_servo

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

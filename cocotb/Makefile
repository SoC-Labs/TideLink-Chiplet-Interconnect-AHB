# Top-level cocotb regression Makefile
# Usage:
#   make regression          Run all test environments
#   make tidelink_ahb        Run a single environment
#   make clean               Clean all environments

ENVS = tidelink_ahb tidelink_ahb_returner tidelink tidelink_pair

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

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@for env in $(ENVS); do \
	  $(MAKE) -C $$env clean > /dev/null 2>&1; \
	  rm -f $$env/run.log $$env/.result; \
	done
	@echo "All environments cleaned"

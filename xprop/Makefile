# Top-level VC Formal X-propagation regression Makefile
# Usage:
#   make regression              Run xprop on all modules
#   make tidelink_fifo_ctrl      Run xprop on a single module
#   make standalone              Run only standalone modules (no CMSDK)
#   make clean                   Clean all modules

# Standalone modules (no CMSDK dependency)
STANDALONE_ENVS = tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs \
                  tidelink_phc_cdc tidelink_perf tidelink_mul_iter \
                  tidelink_apb_addr_ctrl tl_addr_trans_cam tl_addr_trans_regs \
                  tidelink_idelay_rx tidelink_rxclk_buf tidelink_clkfreq_check

# CMSDK-dependent modules
CMSDK_ENVS = tidelink_fifo tidelink

ENVS = $(STANDALONE_ENVS) $(CMSDK_ENVS)

# ── Per-module targets ─────────────────────────────────────────────────────
define run_env
.PHONY: $(1)
$(1):
	@echo "========================================"
	@echo " VC Formal xprop: $(1)"
	@echo "========================================"
	@$$(MAKE) -C $(1) clean > /dev/null 2>&1; \
	 $$(MAKE) -C $(1) xprop 2>&1 | tee $(1)/run.log; \
	 if grep -q "FAIL\|ERROR" $(1)/run.log 2>/dev/null; then \
	   echo "  >> $(1): FAIL"; \
	   echo "FAIL" > $(1)/.result; \
	 else \
	   echo "  >> $(1): PASS"; \
	   echo "PASS" > $(1)/.result; \
	 fi
	@echo ""
endef

$(foreach env,$(ENVS),$(eval $(call run_env,$(env))))

# ── Regression targets ─────────────────────────────────────────────────────
.PHONY: regression standalone regression-summary

regression: $(ENVS) regression-summary

standalone: $(STANDALONE_ENVS) regression-summary-standalone

regression-summary:
	@echo "========================================"
	@echo " Formal Regression Summary"
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

regression-summary-standalone:
	@echo "========================================"
	@echo " Formal Regression Summary (standalone)"
	@echo "========================================"
	@pass=0; fail=0; \
	for env in $(STANDALONE_ENVS); do \
	  result=$$(cat $$env/.result 2>/dev/null || echo "FAIL"); \
	  printf "  %-30s %s\n" "$$env" "$$result"; \
	  if [ "$$result" = "PASS" ]; then pass=$$((pass + 1)); else fail=$$((fail + 1)); fi; \
	done; \
	echo "----------------------------------------"; \
	echo "  PASS=$$pass  FAIL=$$fail  TOTAL=$$(( pass + fail ))"; \
	echo "========================================"; \
	[ "$$fail" -eq 0 ]

# ── Clean ──────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@for env in $(ENVS); do \
	  $(MAKE) -C $$env clean > /dev/null 2>&1; \
	  rm -f $$env/run.log $$env/.result; \
	done
	@echo "All formal environments cleaned"

# ── Help ───────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "TideLink VC Formal X-propagation Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make regression              Run xprop on all modules"
	@echo "  make standalone              Run standalone modules only (no CMSDK)"
	@echo "  make tidelink_fifo_ctrl      Run xprop on a single module"
	@echo "  make clean                   Remove all generated files"
	@echo ""
	@echo "Standalone modules (no CMSDK dependency):"
	@echo "  $(STANDALONE_ENVS)"
	@echo ""
	@echo "CMSDK-dependent modules:"
	@echo "  $(CMSDK_ENVS)"

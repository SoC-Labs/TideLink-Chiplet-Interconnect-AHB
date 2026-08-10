#!/usr/bin/env bash
# TL-033 (BUG-002) credit-underflow — non-vacuity red/green proof.
#
# Runs test_43_credit_underflow_saturates_whitebox TWICE against DIFFERENT RTL,
# swapping ONLY the credit saturate guard via a separate flist (no edit to the
# shipping RTL — the a2l deps-vs-override pattern):
#
#   GREEN : shipping src/rtl/fifo/tidelink_fifo_ctrl.sv (:386-389 guard present)
#           => the underflow consume SATURATES: credit_count == 0            PASS
#   RED   : tidelink_fifo_ctrl_noguard.sv (guard removed, `make noguard`)
#           => the underflow consume WRAPS:     credit_count == 0x1FFF(8191) FAIL
#
# GREEN pass + RED fail == the test has teeth (it distinguishes guarded from
# unguarded RTL), so TL-033's shipping-RTL PASS is non-vacuous.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TC=test_43_credit_underflow_saturates_whitebox

cd "$ROOT"
set +u; source ./set_env.sh >/dev/null 2>&1 || true; set -u
export TIDELINK_PHY_V2=1

echo "=== GREEN: shipping RTL (saturate guard present) — expect PASS ==="
( cd "$HERE" && rm -rf sim_build_green && \
  make SIM_BUILD=sim_build_green TESTCASE=$TC ) > /tmp/tl033_green.log 2>&1
GREEN_RC=$?
grep -E "$TC|credit_count|SATURATED|WRAP" /tmp/tl033_green.log | tail -6
echo "GREEN exit=$GREEN_RC"

echo
echo "=== RED: guard-DISABLED variant (make noguard) — expect FAIL ==="
( cd "$HERE" && rm -rf sim_build_noguard && make noguard ) > /tmp/tl033_red.log 2>&1
RED_RC=$?
grep -E "$TC|credit_count|WRAP|BUG-002" /tmp/tl033_red.log | tail -8
echo "RED exit=$RED_RC"

echo
if [ "$GREEN_RC" -eq 0 ] && [ "$RED_RC" -ne 0 ]; then
    echo "NON-VACUITY PROVEN: GREEN pass + RED fail (test distinguishes guard vs no-guard)."
    exit 0
fi
echo "NON-VACUITY NOT PROVEN: GREEN_RC=$GREEN_RC (want 0), RED_RC=$RED_RC (want !=0)."
exit 1

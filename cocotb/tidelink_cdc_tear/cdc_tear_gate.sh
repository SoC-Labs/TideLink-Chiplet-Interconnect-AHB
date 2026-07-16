#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cdc_tear_gate.sh -- pre-build gate for the ACK-pointer CDC-tear / false-FULL
# self-heal bug class (the campaign's biggest sim fidelity gap).
#
# It runs the silicon-faithful tear-injection test (cocotb/tidelink_cdc_tear)
# against the REAL production DUTs -- WlinkGenericFCReplayV2_13 (a2l) and _12
# (l2a / die_b RX) -- with the fix-model OFF, so the test only passes if the
# RTL itself self-heals a torn synced-ACK capture, i.e. only if it ships
#     assign link_addr_to_app_clk_w_inc = 1'b1;
# The gate is therefore RED until that fix lands and GREEN afterwards: it turns
# the whole "build, deploy, pray, read silicon" bug class into a red check.
#
# USAGE
#   cocotb/tidelink_cdc_tear/cdc_tear_gate.sh            # gate the real RTL
#   cocotb/tidelink_cdc_tear/cdc_tear_gate.sh --selftest # prove the harness
#                                                        # (fix-model ON -> green)
#
# WIRING INTO fpga/farm_gate.sh (owned elsewhere; do NOT edit from here):
#   Add one Tier-1 line, e.g. after the SIM stage loop:
#       say "Tier-1  sim[cdc_tear]: cocotb/tidelink_cdc_tear/cdc_tear_gate.sh"
#       if bash cocotb/tidelink_cdc_tear/cdc_tear_gate.sh >"$LOG_DIR/cdc_tear.log" 2>&1
#           then pass "sim[cdc_tear] — a2l+l2a self-heal a CDC tear"
#           else fail "sim[cdc_tear] — replay ACK-ptr does NOT self-heal (needs w_inc=1'b1)"; fi
#   Gate it behind FARM_GATE_ALLOW_NO_SIM the same way the pair sim is, and (if
#   you don't want it blocking builds before the RTL fix lands) start it OPT-IN
#   under a FARM_GATE_CDC_TEAR=1 flag, exactly like FARM_GATE_STRESS.
# ---------------------------------------------------------------------------
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# fix-model OFF => gate the real RTL; ON => prove the harness detects the fix.
FIXARG=""
MODE="real RTL (fix-model OFF: green only if RTL self-heals)"
if [ "$SELFTEST" = 1 ]; then
    FIXARG="TEAR_FIX=1"
    MODE="SELFTEST (fix-model ON: must be green -> harness sane)"
fi

echo "[cdc_tear_gate] mode: $MODE"
RED=0
for kind in a2l l2a; do
    rxml="$HERE/results.xml"
    log="$HERE/gate_${kind}.log"
    rm -f "$rxml"
    make -C "$HERE" DUT_KIND="$kind" $FIXARG clean >/dev/null 2>&1
    mk_rc=0
    make -C "$HERE" DUT_KIND="$kind" $FIXARG >"$log" 2>&1 || mk_rc=$?
    if [ ! -f "$rxml" ]; then
        echo "[cdc_tear_gate] FAIL: $kind — no results.xml (compile/harness error, rc=$mk_rc); see $log"
        RED=1; continue
    fi
    # grep -c always prints a count; do NOT append `|| echo 0` (would double-print).
    n_tc="$(grep -c '<testcase' "$rxml" 2>/dev/null)";       n_tc="${n_tc:-0}"
    n_fail="$(grep -cE '<failure|<error' "$rxml" 2>/dev/null)"; n_fail="${n_fail:-0}"
    if [ "$n_tc" -eq 0 ]; then
        echo "[cdc_tear_gate] FAIL: $kind — 0 testcases (harness/compile issue, rc=$mk_rc); see $log"
        RED=1
    elif [ "$n_fail" -ne 0 ]; then
        echo "[cdc_tear_gate] FAIL: $kind — $n_fail/$n_tc testcase(s) FAILED (ACK-ptr does NOT self-heal a CDC tear; needs w_inc=1'b1); see $log"
        RED=1
    else
        echo "[cdc_tear_gate] ok:   $kind — $n_tc/$n_tc testcase(s) passed"
    fi
done

if [ "$RED" -ne 0 ]; then
    echo "[cdc_tear_gate] RESULT: RED"
    exit 1
fi
echo "[cdc_tear_gate] RESULT: GREEN"

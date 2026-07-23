#!/usr/bin/env bash
# RX-FIFO TWIN 2 — red/green proof ACROSS THE RTL (DECISION #1, 2026-07-21).
#
# The robust fix is a RUNTIME ARM (swi_ahb_inject_arm, POR-disarmed) that gates
# the AHB CPU-write-into-RX path. The SAME test_twin2.py is run twice against the
# working-tree RTL, toggling ONLY the arm gating in tidelink_fifo_ctrl.sv:
#
#   RED   : the arm is NEUTRALISED (ahb_write_en = ENABLE_AHB_WRITE, ignoring the
#           arm) — i.e. the pre-fix "always live" AHB write path. The two
#           DISARMED tests FAIL: a stray clear/probe pair walks the FC-shared
#           write_ptr and the next FC packet mis-frames.
#   GREEN : the working-tree (fixed) RTL — the arm honours POR-disarm — all five
#           tests PASS.
#
# The legitimate-AHB-inject tests (test_legit_ahb_inject_still_works,
# test_legit_ahb_inject_len0_rd_req) pass in BOTH runs: they ARM the path, so
# they must never regress. A whole-file git-swap to the pre-arm RTL is NOT used
# because that RTL lacks the swi_ahb_inject_arm PORT and would fail to compile
# against the current fifo_mem — the port mismatch, not a test assertion, would
# be what "fails", proving nothing about the test's teeth.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="src/rtl/fifo/tidelink_fifo_ctrl.sv"

cd "$ROOT"
# set_env.sh references unbound vars; `set -u` would kill this shell on source.
set +u
# shellcheck disable=SC1091
source ./set_env.sh >/dev/null 2>&1 || true
set -u

BAK="$(mktemp)"
cp "$ROOT/$RTL" "$BAK"
restore() { cp "$BAK" "$ROOT/$RTL"; rm -f "$BAK"; }
trap restore EXIT

GOOD='wire ahb_write_en = ENABLE_AHB_WRITE && swi_ahb_inject_arm;'
RED='wire ahb_write_en = ENABLE_AHB_WRITE; \/\/ RED: arm neutralised'

run() {  # $1 = label
    ( cd "$HERE" && rm -rf sim_build && make ) > "/tmp/twin2_$1.log" 2>&1
    local rc=$?
    echo "--- $1 (exit $rc) ---"
    grep -E "test_twin2\.(test_stray|test_fc_packet|test_legit|test_twin1)" "/tmp/twin2_$1.log" \
        | grep -E "PASS|FAIL" || tail -5 "/tmp/twin2_$1.log"
    return $rc
}

echo "=== RED: arm gating NEUTRALISED (pre-fix behaviour) ==="
if ! grep -qF "$GOOD" "$ROOT/$RTL"; then
    echo "cannot find the arm-gate line to neutralise"; exit 2
fi
sed -i "s|$GOOD|$RED|" "$ROOT/$RTL"
run red; RED_RC=$?

echo
echo "=== GREEN: fixed RTL (working tree, arm honoured) ==="
restore; trap - EXIT
run green; GREEN_RC=$?

echo
if [ $RED_RC -ne 0 ] && [ $GREEN_RC -eq 0 ]; then
    echo "RED/GREEN OK: DISARMED tests FAIL with the arm neutralised and PASS with the fix."
    exit 0
fi
echo "RED/GREEN BROKEN: red_rc=$RED_RC (want non-zero) green_rc=$GREEN_RC (want 0)"
exit 1

#!/usr/bin/env bash
# RX-FIFO TWIN 2 — red/green proof ACROSS THE RTL (DECISION #1, 2026-07-19).
#
# The same test_twin2.py is run twice:
#   RED   : against the PRE-FIX tidelink_fifo_ctrl.sv (the arm was unqualified)
#           -> the two TWIN-2 tests FAIL (write_ptr walks, FC packet mis-frames)
#   GREEN : against the working-tree (fixed) RTL -> all four tests PASS
#
# ENABLE_AHB_WRITE is 1'b1 (the SUPPORTED posture) in BOTH runs — the fix is in
# the arm qualification, not in gating the AHB write path off. That is why the
# legitimate-AHB-inject test passes in both runs: it must never regress.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="src/rtl/fifo/tidelink_fifo_ctrl.sv"

# Commit holding the PRE-FIX tidelink_fifo_ctrl.sv (tip of the consolidated
# branch immediately before the TWIN-2 redesign).
PREFIX_REF="${PREFIX_REF:-1094efe}"

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

run() {  # $1 = label
    ( cd "$HERE" && rm -rf sim_build && make ) > "/tmp/twin2_$1.log" 2>&1
    local rc=$?
    echo "--- $1 (exit $rc) ---"
    grep -E "^\s+\*\* (test_twin2|TESTS=)" "/tmp/twin2_$1.log" || tail -5 "/tmp/twin2_$1.log"
    return $rc
}

echo "=== RED: pre-fix RTL ($PREFIX_REF) ==="
git show "$PREFIX_REF:$RTL" > "$ROOT/$RTL" || { echo "cannot fetch pre-fix RTL"; exit 2; }
run red; RED_RC=$?

echo
echo "=== GREEN: fixed RTL (working tree) ==="
restore; trap - EXIT
run green; GREEN_RC=$?

echo
if [ $RED_RC -ne 0 ] && [ $GREEN_RC -eq 0 ]; then
    echo "RED/GREEN OK: the test FAILS on pre-fix RTL and PASSES on fixed RTL."
    exit 0
fi
echo "RED/GREEN BROKEN: red_rc=$RED_RC (want non-zero) green_rc=$GREEN_RC (want 0)"
exit 1

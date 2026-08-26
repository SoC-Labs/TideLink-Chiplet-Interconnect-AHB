#!/bin/bash
# =============================================================================
# MUST-FAIL CONTROL — farm_gate lint ratchet: a CRASHED lint must not pass
#
#   ci/checker_controls/control_farm_gate_ratchet.sh
#   RATCHET_LIB=<path> ...   grade an alternative copy (used to prove the
#                            pre-fix ratchet goes RED)
#
# Pre-fix, ratchet_lint took no exit code at all: `|| true` in farm_gate.sh
# swallowed 2 / 127 / a crash, extract_keys parsed a traceback-only log into
# zero keys, and the gate printed "ok: no new findings". This control feeds it
# exactly those logs.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
LIB="${RATCHET_LIB:-$root/fpga/lint_ratchet.sh}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export LOG_DIR="$WORK/logs"; mkdir -p "$LOG_DIR"
export STAMP=control
rc_overall=0

echo "==============================================================="
echo " CONTROL: farm_gate lint ratchet — crash must not grade clean"
echo " lib under test: $LIB"
echo "==============================================================="

# farm_gate's reporting helpers, instrumented so the control can read verdicts
GATE_VERDICT=""
say()  { printf '        %s\n' "$*"; }
pass() { GATE_VERDICT="PASS"; printf '        ok:   %s\n' "$1"; }
fail() { GATE_VERDICT="FAIL"; printf '        FAIL: %s\n' "$1"; }
warn() { printf '        WARN: %s\n' "$1"; }

# shellcheck disable=SC1090
. "$LIB"

BASE="$WORK/baseline.txt"
cat > "$BASE" <<'EOF'
src/rtl/tidelink_top.sv:1667: LATCH_INFERRED  known accepted debt
src/rtl/tidelink_top.sv:1102: BLOCKING_IN_SEQ known accepted debt
EOF

mk_log(){ # $1=kind -> writes $WORK/lint.log, echoes the rc to use
    local k="$1" L="$WORK/lint.log"
    case "$k" in
      clean)      printf 'scanned 12 XDC file(s)\nOK — no XDC anti-patterns detected\n' > "$L"; echo 0 ;;
      known)      { cat "$BASE"; printf 'FAIL — 2 first-party finding(s) across 9 file(s)\n'; } > "$L"; echo 1 ;;
      newfind)    { cat "$BASE"
                    printf 'src/rtl/tidelink_d2d.sv:412: LATCH_INFERRED brand new finding\n'
                    printf 'FAIL — 3 first-party finding(s) across 9 file(s)\n'; } > "$L"; echo 1 ;;
      crash1)     printf 'Traceback (most recent call last):\n  File "cocotb/lint/xdc_lint.py", line 88, in scan_xdc\n    for tok in line.split():\nAttributeError: NoneType has no attribute split\n' > "$L"; echo 1 ;;
      argerr)     printf 'usage: xdc_lint.py [-h] paths [paths ...]\nxdc_lint.py: error: unrecognized arguments: --nope\n' > "$L"; echo 2 ;;
      notfound)   printf '/usr/bin/env: python3: No such file or directory\n' > "$L"; echo 127 ;;
      killed)     printf 'scanned 4 XDC file(s)\n' > "$L"; echo 137 ;;
      empty)      : > "$L"; echo 1 ;;
      drift)      printf 'scanned 9 file(s)\n<<<lint v3 json output>>>\nFAIL — 3 first-party finding(s) across 9 file(s)\n' > "$L"; echo 1 ;;
    esac
}

run_case(){ # <label> <log-kind> <expected PASS|FAIL>
    local label="$1" kind="$2" want="$3" rc
    rc="$(mk_log "$kind")"
    GATE_VERDICT=""
    printf '   %-18s (exit %-3s) ' "$label" "$rc"
    if [ "${RATCHET_LEGACY:-0}" = 1 ]; then
        ratchet_lint "$label" "$WORK/lint.log" "$BASE"          >/dev/null 2>&1
    else
        ratchet_lint "$label" "$WORK/lint.log" "$BASE" "$rc"    >/dev/null 2>&1
    fi
    [ -z "$GATE_VERDICT" ] && GATE_VERDICT="PASS"
    if [ "$GATE_VERDICT" = "$want" ]; then
        printf 'got %-4s  want %-4s  PASS\n' "$GATE_VERDICT" "$want"
    else
        printf 'got %-4s  want %-4s  <<< CONTROL FAILURE\n' "$GATE_VERDICT" "$want"
        rc_overall=1
    fi
}

echo "-- a lint that RAN (these must keep working) --"
run_case clean-run    clean    PASS
run_case known-debt   known    PASS
run_case new-finding  newfind  FAIL
echo "-- a lint that DID NOT RUN (these are the defect) --"
run_case crash-exit1  crash1   FAIL
run_case argparse-err argerr   FAIL
run_case not-found    notfound FAIL
run_case oom-killed   killed   FAIL
run_case empty-log    empty    FAIL
run_case format-drift drift    FAIL

echo
if [ $rc_overall -eq 0 ]; then echo "CONTROL_RATCHET: PASS"; else echo "CONTROL_RATCHET: FAIL"; fi
exit $rc_overall

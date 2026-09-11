#!/bin/bash
# =============================================================================
# grade_uvm_selftest_log.sh <log> <label> [required-report-id]
#
# Decide a UVM self-test's verdict from its LOG, never from simv's exit code.
#
# WHY: simv exits 0 even when the run raised UVM_ERRORs -- MEASURED 2026-09-11 in
# this repo, uvm/tidelink/sim_build/simv +UVM_TESTNAME=no_such_test_at_all exited
# 0 with "UVM_FATAL :    1" in its log. Every `make run` / `make run_all` target
# in uvm/*/Makefile decides on that exit code, so a UVM self-test wired into a
# gate through them could never have reported failure. uvm/tidelink_top_system's
# sb_selftest already grades its log for exactly this reason; this is that rule,
# factored out so the other self-tests can be gated the same way.
#
# Exit: 0 PASS, 1 FAIL, 2 COULD-NOT-EVALUATE.
# COULD-NOT-EVALUATE is never collapsed into PASS: a missing log, a log with no
# UVM report summary, or a log with no output at all from the self-test's own
# report id means the verdict was not read, which is not a pass.
# =============================================================================
set -u
log="${1:?usage: grade_uvm_selftest_log.sh <log> <label> [report-id]}"
label="${2:?}"
id="${3:-SB_SELFTEST}"

if [ ! -s "$log" ]; then
    echo "$label: COULD-NOT-EVALUATE (no log at $log)"; exit 2
fi
if ! grep -q '^UVM_ERROR *:' "$log"; then
    echo "$label: COULD-NOT-EVALUATE (no UVM report summary in $log — the run did"
    echo "$label: not reach report_phase, so nothing graded it)"; exit 2
fi
if ! grep -qE "^UVM_(INFO|ERROR).*\[$id\]" "$log"; then
    echo "$label: COULD-NOT-EVALUATE (the run produced no [$id] output at all, so"
    echo "$label: the self-test body never executed — a silent log is not a pass)"; exit 2
fi

n=$(sed -n 's/^UVM_ERROR *: *\([0-9][0-9]*\).*/\1/p' "$log" | tail -1)
f=$(sed -n 's/^UVM_FATAL *: *\([0-9][0-9]*\).*/\1/p' "$log" | tail -1)
grep -E "^UVM_(INFO|ERROR).*\[$id\]" "$log" | sed "s/^.*\[$id\] //"
if [ "${n:-}" = "0" ] && [ "${f:-}" = "0" ]; then
    echo "$label: PASS"; exit 0
fi
echo "$label: FAIL (UVM_ERROR=${n:-?} UVM_FATAL=${f:-?})  log: $log"
exit 1

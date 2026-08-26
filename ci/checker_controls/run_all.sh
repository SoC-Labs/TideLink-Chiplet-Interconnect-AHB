#!/bin/bash
# =============================================================================
# Run every sign-off checker control. Exit non-zero if any goes red.
#
#   ci/checker_controls/run_all.sh
#
# Each control demonstrates a checker that could not report failure, and is
# built to go RED against the pre-fix code and GREEN against the fixed code.
# Every one distinguishes PASS / FAIL / COULD-NOT-EVALUATE — collapsing the
# third into PASS is the defect class these exist to prevent.
#
# None of these run EDA tools, touch a design, or write inside the flow. They
# grade fabricated reports and logs in a temp directory.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
declare -a RED=()
for c in control_lvs.sh control_fc_drc.sh control_farm_gate_ratchet.sh \
         control_msg_gate.sh control_verify_build.sh; do
    echo
    if ! "$here/$c"; then rc=1; RED+=("$c"); fi
done
echo
echo "==============================================================="
if [ $rc -eq 0 ]; then
    echo " ALL CHECKER CONTROLS PASS"
else
    echo " CHECKER CONTROLS RED: ${RED[*]}"
fi
echo "==============================================================="
exit $rc

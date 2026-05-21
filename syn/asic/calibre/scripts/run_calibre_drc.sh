#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Calibre DRC wrapper for the TideLink partition.
#
# Usage: run_calibre_drc.sh <deck> <gds> <top> <work> <reports> <logs> <runsets>
#
# Generates a calibre.runset in <runsets>/drc.runset with the tidelink
# paths substituted in, then runs `calibre -drc -hier -64` in batch mode.
# Parses the .err DB header into <reports>/09_calibre_drc.rep.
#
# Exit: 0 if Calibre completes (regardless of violation count — the
#       summary report is the truth). Non-zero only if Calibre itself
#       crashed (missing input, deck syntax error).
#-----------------------------------------------------------------------------
set -euo pipefail

deck="$1"
gds="$2"
top="$3"
work="$4"
reports="$5"
logs="$6"
runsets="$7"

mkdir -p "$work" "$reports" "$logs" "$runsets"

runset="$runsets/drc.runset"
err_db="$work/${top}_drc.err"
summary="$work/${top}_drc.sum"
log="$logs/calibre_drc.log"

cat > "$runset" <<EOF
*drcRulesFile: ${deck}
*drcRunDir: ${work}
*drcLayoutPaths: ${gds}
*drcLayoutPrimary: ${top}
*drcResultsFile: ${err_db}
*drcResultsCheckText: 1
*drcResultsCheckTextValue: ALL
*drcCellName: 0
*drcDRCMaxResultsAll: 1
*drcSummaryFile: ${summary}
*drcActiveRecipe: Checks selected in the rules file
*drcUserRecipes: {{Checks selected in the rules file}}
*cmnResolution: 5
EOF

echo "INFO: [calibre_drc] runset → $runset"
echo "INFO: [calibre_drc] deck   = $deck"
echo "INFO: [calibre_drc] GDS    = $gds"
echo "INFO: [calibre_drc] top    = $top"
echo "INFO: [calibre_drc] work   = $work"

# Run Calibre in batch mode against the runset. -64 forces 64-bit;
# -drc selects the DRC engine; -hier runs hierarchical mode.
cd "$work"
set +e
/eda/mentor/calibre/bin/calibre -drc -hier -64 "$runset" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

# Parse the summary into reports/. The .sum file Calibre writes carries
# per-rule counts; the report Just summarises totals + the top
# violations.
{
    echo "================================================================="
    echo " Calibre DRC summary — ${top}"
    echo " deck    : ${deck}"
    echo " GDS     : ${gds}"
    echo " runset  : ${runset}"
    echo " err DB  : ${err_db}"
    echo " log     : ${log}"
    echo " calibre exit: $rc"
    echo "================================================================="
    echo ""
    if [ -f "$summary" ]; then
        # Calibre's summary file lists per-rule violation counts; grep
        # the totals line + flag any rule with >0 violations.
        echo " --- Per-rule summary (from $summary) ---"
        awk '/TOTAL.*RESULTS.*:/,/^$/' "$summary" | head -50 || true
        echo ""
        echo " --- Rules with > 0 violations ---"
        awk '/^Rule/ || / [1-9][0-9]* / {print}' "$summary" | head -30 || true
    else
        echo " (no .sum produced — Calibre may not have run a check pass)"
    fi
    echo ""
    if [ -f "$err_db" ]; then
        total=$(grep -c '^Rule:' "$err_db" 2>/dev/null || echo 0)
        echo " TOTAL VIOLATING RULES IN ERR DB: $total"
    fi
    echo "================================================================="
} > "$reports/09_calibre_drc.rep"

cat "$reports/09_calibre_drc.rep"

if [ $rc -ne 0 ]; then
    echo "ERROR: Calibre DRC exited non-zero ($rc) — see $log"
    exit $rc
fi
echo "CALIBRE_DRC_OK: $top"

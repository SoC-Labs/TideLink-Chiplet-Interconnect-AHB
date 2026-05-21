#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Calibre LVS wrapper for the TideLink partition.
#
# Usage: run_calibre_lvs.sh <deck> <gds> <netlist> <top> <work> <reports> <logs> <runsets>
#
# Generates a calibre.runset in <runsets>/lvs.runset with the tidelink
# paths substituted in, then runs `calibre -lvs -hier -64` in batch mode.
# Source for LVS = Verilog netlist; Calibre's v2lvs flow extracts a SPICE
# source from the gate-level .v.
#-----------------------------------------------------------------------------
set -euo pipefail

deck="$1"
gds="$2"
netlist="$3"
top="$4"
work="$5"
reports="$6"
logs="$7"
runsets="$8"

mkdir -p "$work" "$reports" "$logs" "$runsets"

runset="$runsets/lvs.runset"
report="$work/${top}_lvs.rep"
log="$logs/calibre_lvs.log"

cat > "$runset" <<EOF
*lvsRulesFile: ${deck}
*lvsRunDir: ${work}
*lvsLayoutPaths: ${gds}
*lvsLayoutPrimary: ${top}
*lvsSourcePath: ${netlist}
*lvsSourceSystem: VERILOG
*lvsSourcePrimary: ${top}
*lvsReportFile: ${report}
*cmnResolution: 5
EOF

echo "INFO: [calibre_lvs] runset  → $runset"
echo "INFO: [calibre_lvs] deck    = $deck"
echo "INFO: [calibre_lvs] layout  = $gds"
echo "INFO: [calibre_lvs] source  = $netlist"
echo "INFO: [calibre_lvs] top     = $top"

cd "$work"
set +e
/eda/mentor/calibre/bin/calibre -lvs -hier -64 "$runset" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

# Calibre LVS writes a "Comparison Results" section to $report — grep
# the canonical pass / fail signature into the summary.
{
    echo "================================================================="
    echo " Calibre LVS summary — ${top}"
    echo " deck    : ${deck}"
    echo " layout  : ${gds}"
    echo " source  : ${netlist}"
    echo " runset  : ${runset}"
    echo " report  : ${report}"
    echo " log     : ${log}"
    echo " calibre exit: $rc"
    echo "================================================================="
    if [ -f "$report" ]; then
        echo ""
        echo " --- Comparison Results ---"
        sed -n '/COMPARISON RESULTS/,/^[[:space:]]*$/p' "$report" | head -40 || true
        echo ""
        if grep -q "CORRECT" "$report" 2>/dev/null; then
            echo " RESULT: LVS CORRECT (extracted source ↔ layout match)"
        elif grep -q "INCORRECT" "$report" 2>/dev/null; then
            echo " RESULT: LVS INCORRECT — see $report"
        else
            echo " RESULT: indeterminate — Calibre may not have completed comparison"
        fi
    else
        echo " (no LVS .rep produced — Calibre may not have run a compare pass)"
    fi
    echo "================================================================="
} > "$reports/10_calibre_lvs.rep"

cat "$reports/10_calibre_lvs.rep"

if [ $rc -ne 0 ]; then
    echo "ERROR: Calibre LVS exited non-zero ($rc) — see $log"
    exit $rc
fi
echo "CALIBRE_LVS_OK: $top"

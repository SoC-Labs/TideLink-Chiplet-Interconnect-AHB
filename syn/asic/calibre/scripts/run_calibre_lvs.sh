#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Calibre LVS wrapper for the TideLink partition.
#
# Usage: run_calibre_lvs.sh <deck> <gds> <netlist> <top> <work> <reports> <logs> <runsets>
#
# Copies the foundry LVS deck to a writable location, sed-substitutes
# the placeholder LAYOUT / SOURCE / LVS REPORT lines with the tidelink
# values, then runs `calibre -lvs -hier -64` against the rewritten deck.
# Source for LVS = the gate-level Verilog netlist; Calibre's v2lvs flow
# extracts a SPICE source from the .v.
#
# Why sed-substitute and not INCLUDE+override: Calibre rejects duplicate
# LAYOUT PRIMARY / SOURCE PRIMARY statements with "Error SPC1 superfluous
# specification statement". See run_calibre_drc.sh header for details.
#-----------------------------------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

deck="$1"
gds="$2"
netlist="$3"
top="$4"
work="$5"
reports="$6"
logs="$7"
runsets="$8"

mkdir -p "$work" "$reports" "$logs" "$runsets"

local_deck="$work/$(basename "$deck").tidelink"
report="$work/${top}_lvs.rep"
svdb_dir="$work/svdb"
log="$logs/calibre_lvs.log"
spice_netlist="$work/${top}.cdl"

# Tool + PDK locations are per-machine facts and come from site.env via the
# Makefile (CAL_BIN, CALIBRE_LVS_SOURCE_ADDED). No defaults: see site.env.example.
cal_bin="${CAL_BIN:-}"
if [ -z "$cal_bin" ]; then
    echo "ERROR: CAL_BIN is not set — it locates the calibre executable."
    echo "       Set it in <repo>/site.env (see site.env.example)."
    exit 1
fi
cal_dir_bin="$(dirname "$cal_bin")"
source_added="${CALIBRE_LVS_SOURCE_ADDED:-}"
if [ -z "$source_added" ]; then
    echo "ERROR: CALIBRE_LVS_SOURCE_ADDED is not set — it locates the PDK's"
    echo "       v2lvs device/pin declaration file (source.added), normally"
    echo "       alongside the LVS deck. Set it in <repo>/site.env."
    exit 1
fi

# SVRF does not support SOURCE SYSTEM VERILOG — the deck's LVS engine
# expects a SPICE/CDL source. Pre-convert the gate-level Verilog netlist
# with Calibre's v2lvs utility (ships with the install). Standard
# v2lvs invocation: -v <netlist.v> -o <out.cdl> -lsp <source.added>.
echo "INFO: [calibre_lvs] running v2lvs $netlist -> $spice_netlist"
"$cal_dir_bin/v2lvs" \
    -v "$netlist" \
    -o "$spice_netlist" \
    -lsp "$source_added" \
    2>&1 | tail -20 || true
if [ ! -s "$spice_netlist" ]; then
    echo "ERROR: v2lvs produced empty/missing $spice_netlist"
    exit 1
fi

# Make a writable copy of the deck and substitute the placeholders.
# The TSMC LVS deck (calibre.lvs) carries the same lvs_top placeholders
# in its top-level LAYOUT / SOURCE / LVS REPORT statements as the DRC
# deck does. Rewrite each to point at tidelink_top + this build's GDS
# + the v2lvs-extracted SPICE/CDL source.
cp "$deck" "$local_deck"
perl -i -pe '
    s|^LAYOUT PRIMARY "lvs_top"|LAYOUT PRIMARY "'"$top"'"|;
    s|^LAYOUT PATH "lvs_top\.gds"|LAYOUT PATH "'"$gds"'"|;
    s|^SOURCE PRIMARY "lvs_top"|SOURCE PRIMARY "'"$top"'"|;
    s|^SOURCE PATH "lvs_top\.cdl"|SOURCE PATH "'"$spice_netlist"'"|;
    s|^LVS REPORT "lvs\.rep"|LVS REPORT "'"$report"'"|;
    s|^PRECISION 1000$|PRECISION 10000|;
' "$local_deck"

if ! grep -q "LAYOUT PRIMARY \"$top\"" "$local_deck"; then
    echo "ERROR: LAYOUT PRIMARY substitution missed — check deck format"
    echo "       deck = $deck"
    grep -n "^LAYOUT PRIMARY" "$local_deck" | head -3
    exit 1
fi

# Calibre LVS also needs MASK SVDB DIRECTORY to be writable — add it if
# the deck doesn't already define one (most foundry decks omit this so
# the user sets it per-run).
if ! grep -q "^MASK SVDB DIRECTORY" "$local_deck"; then
    echo "" >> "$local_deck"
    echo "// TideLink wrapper: SVDB output target" >> "$local_deck"
    echo "MASK SVDB DIRECTORY \"$svdb_dir\" QUERY" >> "$local_deck"
fi

echo "INFO: [calibre_lvs] local deck → $local_deck"
echo "INFO: [calibre_lvs] layout     = $gds"
echo "INFO: [calibre_lvs] source     = $netlist"
echo "INFO: [calibre_lvs] top        = $top"

cd "$work"
set +e
"$cal_bin" -lvs -hier -64 "$local_deck" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

# Grade the report. NOT with grep -q "CORRECT": "INCORRECT" CONTAINS
# "CORRECT", so that test matched every failing report and the INCORRECT
# branch was unreachable — every mismatch was announced as a match. The
# verdict is now decided by lvs_verdict.sh, which anchors on Calibre's
# verdict banner and distinguishes three outcomes:
#   0 CORRECT   1 INCORRECT   2 COULD-NOT-EVALUATE
set +e
lvs_verdict_out="$("$script_dir/lvs_verdict.sh" "$report" 2>&1)"
LVS_VERDICT_RC=$?
set -e

# Calibre LVS writes a "Comparison Results" section to $report — quote
# it into the summary alongside the graded verdict.
{
    echo "================================================================="
    echo " Calibre LVS summary — ${top}"
    echo " deck     : ${deck}"
    echo " layout   : ${gds}"
    echo " source   : ${netlist}"
    echo " local    : ${local_deck}"
    echo " report   : ${report}"
    echo " log      : ${log}"
    echo " calibre exit: $rc"
    echo "================================================================="
    if [ -f "$report" ]; then
        echo ""
        echo " --- Comparison Results ---"
        sed -n '/COMPARISON RESULTS/,/^[[:space:]]*$/p' "$report" | head -40 || true
        echo ""
    fi
    echo " RESULT: $lvs_verdict_out"
    echo "================================================================="
} > "$reports/10_calibre_lvs.rep"

cat "$reports/10_calibre_lvs.rep"

if [ $rc -ne 0 ]; then
    echo "ERROR: Calibre LVS exited non-zero ($rc) — see $log"
    exit $rc
fi

# Calibre's exit status says whether the TOOL ran, NOT whether the layout
# MATCHES — it exits 0 on a clean run that reported INCORRECT. The script
# used to echo CALIBRE_LVS_OK unconditionally here, so a graded mismatch
# still left "make lvs" green. Three outcomes, and only one of them is OK.
case "$LVS_VERDICT_RC" in
    0)
        echo "CALIBRE_LVS_OK: $top"
        ;;
    1)
        echo "ERROR: LVS INCORRECT for $top — layout does not match source."
        echo "       $lvs_verdict_out"
        echo "       report: $report"
        exit 1
        ;;
    *)
        echo "ERROR: LVS COULD-NOT-EVALUATE for $top — no usable verdict."
        echo "       $lvs_verdict_out"
        echo "       report: $report"
        echo "       An unevaluable LVS run is NOT a pass. Investigate before signing off."
        exit 2
        ;;
esac

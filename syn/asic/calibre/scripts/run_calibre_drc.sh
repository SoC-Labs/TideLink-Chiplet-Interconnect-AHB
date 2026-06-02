#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Calibre DRC wrapper for the TideLink partition.
#
# Usage: run_calibre_drc.sh <deck> <gds> <top> <work> <reports> <logs> <runsets>
#
# Copies the foundry deck to a writable location, sed-substitutes the
# placeholder LAYOUT PRIMARY / PATH / SYSTEM and DRC RESULTS DATABASE /
# SUMMARY REPORT lines with the tidelink values, then runs
# `calibre -drc -hier -64` against the rewritten deck.
#
# Why sed-substitute and not INCLUDE+override: Calibre rejects duplicate
# LAYOUT PRIMARY statements with "Error SPC1 superfluous specification
# statement" regardless of which one comes first. The deck has explicit
#   LAYOUT PRIMARY "lvs_top"
#   LAYOUT PATH "lvs_top.gds"
#   LAYOUT SYSTEM GDSII
# at the top of its tvf::VERBATIM block, so any wrapper that tries to
# add a second LAYOUT PRIMARY trips the duplicate check. Editing a COPY
# of the deck in our work tree is the documented batch-mode pattern.
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

local_deck="$work/$(basename "$deck").tidelink"
err_db="$work/${top}_drc.err"
summary="$work/${top}_drc.sum"
log="$logs/calibre_drc.log"

# Make a writable copy of the deck and substitute the placeholders.
# The deck's verbatim block hard-codes:
#   LAYOUT PRIMARY "lvs_top"
#   LAYOUT PATH "lvs_top.gds"
#   LAYOUT SYSTEM GDSII
#   DRC RESULTS DATABASE "calibre_drc.db" ASCII
#   DRC SUMMARY REPORT "calibre_drc.sum"
# Rewrite each to point at tidelink_top + the build's GDS + work-dir
# outputs. Use perl rather than sed-i to handle the quoting reliably.
cp "$deck" "$local_deck"
perl -i -pe '
    s|^LAYOUT PRIMARY "lvs_top"|LAYOUT PRIMARY "'"$top"'"|;
    s|^LAYOUT PATH "lvs_top\.gds"|LAYOUT PATH "'"$gds"'"|;
    s|^DRC RESULTS DATABASE "calibre_drc\.db" ASCII.*|DRC RESULTS DATABASE "'"$err_db"'" ASCII|;
    s|^DRC SUMMARY REPORT "calibre_drc\.sum"|DRC SUMMARY REPORT "'"$summary"'"|;
' "$local_deck"

# Sanity-check the substitutions actually landed (the deck file may
# evolve and the placeholders may rename — fail loudly if so).
if ! grep -q "LAYOUT PRIMARY \"$top\"" "$local_deck"; then
    echo "ERROR: LAYOUT PRIMARY substitution missed — check deck format"
    echo "       deck = $deck"
    grep -n "^LAYOUT PRIMARY" "$local_deck" | head -3
    exit 1
fi

echo "INFO: [calibre_drc] local deck → $local_deck"
echo "INFO: [calibre_drc] GDS        = $gds"
echo "INFO: [calibre_drc] top        = $top"
echo "INFO: [calibre_drc] work       = $work"

# Run Calibre in batch mode against the rewritten local deck. -64 forces
# 64-bit; -drc selects the DRC engine; -hier runs hierarchical mode.
cd "$work"
set +e
/eda/mentor/calibre/bin/calibre -drc -hier -64 "$local_deck" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

# Parse the summary into reports/. The .sum file Calibre writes carries
# per-rule counts; the report Just summarises totals + the top
# violations.
{
    echo "================================================================="
    echo " Calibre DRC summary — ${top}"
    echo " deck     : ${deck}"
    echo " GDS      : ${gds}"
    echo " local    : ${local_deck}"
    echo " err DB   : ${err_db}"
    echo " log      : ${log}"
    echo " calibre exit: $rc"
    echo "================================================================="
    echo ""
    if [ -f "$summary" ]; then
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

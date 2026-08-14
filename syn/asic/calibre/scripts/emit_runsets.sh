#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# Emit tidelink-specific Calibre runsets for opening in calibrewb (GUI).
# Same template the batch wrappers build but written to a stable path
# under runsets/ so the user can load them in the Calibre tool without
# running anything from the command line.
#
# Usage: emit_runsets.sh <runsets_dir> <cal_dir> <top> <gds> <netlist>
#-----------------------------------------------------------------------------
set -euo pipefail

runsets_dir="$1"
cal_dir="$2"
top="$3"
gds="$4"
netlist="$5"

# Deck paths come from the caller (the Makefile passes CALIBRE_*_DECK through
# as DRC_DECK / LVS_DECK, which come from site.env). No defaults: a deck
# filename encodes the signoff release this site holds, and a runset written
# against someone else's mount is worse than no runset — Calibre opens it and
# reports against the wrong rules.
_require_deck() {
    if [ -z "${2:-}" ]; then
        echo "ERROR: $1 is not set — it locates the foundry $3 deck." >&2
        echo "       Set CALIBRE_$1 in <repo>/site.env (see site.env.example)." >&2
        exit 1
    fi
}
drc_deck="${DRC_DECK:-}"
lvs_deck="${LVS_DECK:-}"
_require_deck DRC_DECK "$drc_deck" DRC
_require_deck LVS_DECK "$lvs_deck" LVS

mkdir -p "$runsets_dir"

cat > "$runsets_dir/drc.runset" <<EOF
*drcRulesFile: ${drc_deck}
*drcRunDir: ${cal_dir}/work
*drcLayoutPaths: ${gds}
*drcLayoutPrimary: ${top}
*drcResultsFile: DRC_RES.db
*drcResultsCheckText: 1
*drcResultsCheckTextValue: ALL
*drcCellName: 0
*drcDRCMaxResultsAll: 1
*drcSummaryFile: DRC.rep
*drcActiveRecipe: Checks selected in the rules file
*drcUserRecipes: {{Checks selected in the rules file}}
*cmnResolution: 5
EOF

cat > "$runsets_dir/lvs.runset" <<EOF
*lvsRulesFile: ${lvs_deck}
*lvsRunDir: ${cal_dir}/work
*lvsLayoutPaths: ${gds}
*lvsLayoutPrimary: ${top}
*lvsSourcePath: ${netlist}
*lvsSourceSystem: VERILOG
*lvsSourcePrimary: ${top}
*lvsReportFile: LVS.rep
*cmnResolution: 5
EOF

echo "Wrote:"
echo "  $runsets_dir/drc.runset"
echo "  $runsets_dir/lvs.runset"

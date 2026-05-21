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

drc_deck="${DRC_DECK:-/home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/util/MAIN_DECK/CALIBRE_FLOW/nonUTM/DFM_LVS_RC_CAL_N65_ALRDL_noU_v16a.9m}"
lvs_deck="${LVS_DECK:-/home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/pdk/Calibre/lvs/calibre.lvs}"

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

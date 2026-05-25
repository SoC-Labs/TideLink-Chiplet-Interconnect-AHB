#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# phc_ila_capture.sh — one-shot ILA capture for the PHC debug bitstream.
#
# Designed to run on mapstone-dev (which has Vivado 2025.2 + hw_server on
# tcp::3121 + FT2232H JTAG cables to z2_01..z2_04). PYNQ Linux on the board
# loads the ILA-instrumented bitstream via fpga_manager FIRST; this script
# then attaches over JTAG and captures.
#
# Usage:
#   phc_ila_capture.sh [-b slave|master|z2_NN] [-l <probes.ltx>]
#                      [-p <probe_glob>] [-t <timeout_s>] [-o <out_dir>]
#
# Defaults:
#   board     = slave  (z2_03)
#   ltx       = $TIDELINK_LTX or skip with NONE
#   probe     = AUTO   (script picks *slave_ll_rx_valid_sop* / *sop* etc.)
#   timeout   = 60
#   out_dir   = ~/td_milestone_stage
#
# Map (board -> JTAG target glob), edit if the cable mapping changes:
#   master -> *Z2_02*
#   slave  -> *Z2_03*
#   spare1 -> *Z2_01*
#   spare2 -> *Z2_04*
#-----------------------------------------------------------------------------
set -euo pipefail

BOARD="slave"
LTX="${TIDELINK_LTX:-NONE}"
PROBE="AUTO"
TIMEOUT="60"
OUT_DIR="$HOME/td_milestone_stage"
HW_URL="${TIDELINK_HW_URL:-localhost:3121}"
VIVADO_BIN="${VIVADO_BIN:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"

while getopts "b:l:p:t:o:u:h" opt; do
    case "$opt" in
        b) BOARD="$OPTARG" ;;
        l) LTX="$OPTARG" ;;
        p) PROBE="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        u) HW_URL="$OPTARG" ;;
        h|*)
            sed -n '2,30p' "$0"
            exit 0
            ;;
    esac
done

case "$BOARD" in
    master)        TARGET_GLOB="*Z2_02*" ;;
    slave)         TARGET_GLOB="*Z2_03*" ;;
    spare1|z2_01)  TARGET_GLOB="*Z2_01*" ;;
    spare2|z2_04)  TARGET_GLOB="*Z2_04*" ;;
    z2_0[1-4])     TARGET_GLOB="*${BOARD^^}*" ;;
    *)             TARGET_GLOB="*${BOARD}*" ;;
esac

if [ ! -x "$VIVADO_BIN" ]; then
    echo "ERROR: vivado not found at $VIVADO_BIN — set VIVADO_BIN." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL="$SCRIPT_DIR/phc_ila_capture.tcl"
if [ ! -f "$TCL" ]; then
    echo "ERROR: missing $TCL" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_PREFIX="$OUT_DIR/phc_ila_${BOARD}_${TS}"
LOG="$OUT_DIR/phc_ila_${BOARD}_${TS}.log"

echo "----------------------------------------------------------"
echo " phc_ila_capture: board=$BOARD  target=$TARGET_GLOB"
echo "                  ltx=$LTX  probe=$PROBE  timeout=${TIMEOUT}s"
echo "                  out=$OUT_PREFIX"
echo "                  hw_server=$HW_URL  vivado=$VIVADO_BIN"
echo "----------------------------------------------------------"

cd "$OUT_DIR"
"$VIVADO_BIN" -mode batch -nojournal -nolog \
    -source "$TCL" \
    -tclargs "$HW_URL" "$TARGET_GLOB" "$LTX" "$OUT_PREFIX" "$PROBE" "$TIMEOUT" \
    2>&1 | tee "$LOG"

echo "----------------------------------------------------------"
echo " Done. Artifacts:"
ls -la "$OUT_PREFIX".* 2>/dev/null || echo "  (no artifacts produced — see $LOG)"
echo "----------------------------------------------------------"

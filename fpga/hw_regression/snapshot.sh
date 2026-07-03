#!/bin/bash
# =============================================================================
# snapshot.sh — one-command FULL debug-register dump from BOTH dies
#
# The uniform evidence capture every debug loop has needed: reads the whole
# standard TideLink V2 debug register set from die_a AND die_b, decodes the
# key fields, and writes everything to a timestamped file (also echoed to
# stdout). Read-only — safe at any point in any bring-up (never touches
# 0x21B0/0x21B4 or any writable register).
#
# USAGE:  ./snapshot.sh <tag>
#   <tag> is a short label baked into the filename, e.g. post-h-fail.
#   Output: ${TD_SNAP_DIR:-$HOME/td_snapshots}/<UTC-stamp>_<tag>.txt
#
# Reads are throttled (TD_THROTTLE) — dense mmap loops wedge the PYNQ PS.
# First-use validation pending (no boards attached at authoring time).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>"; exit 2; }
case "$TAG" in *[!A-Za-z0-9._-]*) echo "tag must be [A-Za-z0-9._-]"; exit 2;; esac

OUTDIR="${TD_SNAP_DIR:-$HOME/td_snapshots}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/$(date -u +%Y%m%d_%H%M%SZ)_${TAG}.txt"

boards_up || { echo "### ABORT: a board is unreachable ($A_IP / $B_IP)"; exit 3; }

# The standard set: "name addr" pairs, in read order. All RO or RW-readback.
# (0x21B0/0x21B4 appear as READS only — their readback carries markers
# 0x5A/0x1B; NEVER write them, the winscan FSM owns them.)
REGS=(
  "ROLE_CFG          $R_ROLE_CFG"
  "ROLE_STATUS       $R_ROLE_STATUS"
  "NEGO_CFG          $R_NEGO_CFG"
  "NEGO_STATUS       $R_NEGO_STATUS"
  "NEGO_TRAIN_CFG    $R_NEGO_TRAIN_CFG"
  "NEGO_TRAIN_STATUS $R_NEGO_TRAIN_STATUS"
  "R_R8              $R_R8"
  "SLIPLO            $R_SLIPLO"
  "LANE_STATUS_OBS   $R_OBS"
  "SYNCCNT           $R_SYNCCNT"
  "PHASE_TAPS        $R_PHASE"
  "TXSYNC            $R_TXSYNC"
  "RXDET2            $R_RXDET2"
  "SYNCTOL           $R_SYNCTOL"
  "RAWWORD0          $R_RAW0"
  "RAWWORD1          $R_RAW1"
  "RAWWORD2          $R_RAW2"
  "RAWWORD3          $R_RAW3"
  "EPOCH_REANCHORED  $R_REANCHORED"
  "LIVEMATCH         $R_LIVEMATCH"
  "SYNC_SEEN         $R_SYNCSEEN"
  "OBSCAL            $R_OBSCAL"
  "OBS_FC_CREDIT     $R_FCCRED"
  "RXCAP0            $R_RXCAP0"
  "RXCAP1            $R_RXCAP1"
  "FCSMCAP           $R_FCSMCAP"
  "SYNC_DIST_OBS     $R_DIST"
  "SYNC_DIST_SEL_RB  $R_DIST_SEL"
  "PHASE_LSB_RB      $R_PHASE_LSB"
  "WINSCAN_OBS       $R_WINSCAN_OBS"
  "PKTLEN            $R_PKTLEN"
  "CREDIT_COUNT      $R_CREDIT_COUNT"
  "FIFO_STATUS       $R_FIFO_STATUS"
  "FCCTRL            $R_FCCTRL"
  "LANEMASK          $R_LANEMASK"
)

{
  echo "# tidelink snapshot tag=$TAG date=$(date -u +%FT%TZ)"
  echo "# die_a=$A_IP($A_BOARD) die_b=$B_IP($B_BOARD)"
  printf '%-18s %-12s %-12s %-12s\n' "NAME" "ADDR" "DIE_A" "DIE_B"
  for entry in "${REGS[@]}"; do
    read -r name addr <<< "$entry"
    va=$(rdx a "$addr"); sleep "$TD_THROTTLE"
    vb=$(rdx b "$addr"); sleep "$TD_THROTTLE"
    printf '%-18s %-12s %-12s %-12s\n' "$name" "$addr" "$va" "$vb"
  done
  # decoded one-liners for the fields every loop greps for
  oa=$(( $(rd_d a $R_OBS) )); ob=$(( $(rd_d b $R_OBS) ))
  wa=$(( $(rd_d a $R_WINSCAN_OBS) )); wb=$(( $(rd_d b $R_WINSCAN_OBS) ))
  ka=$(( $(rd_d a $R_FCCRED) )); kb=$(( $(rd_d b $R_FCCRED) ))
  echo "# decode die_a: lk=0x$(printf '%02x' $(( oa & 0xff ))) cal=$(( (oa>>16)&1 )) fcsm=$(( (oa>>17)&7 )) cr=$(( (oa>>23)&1 )) crack=$(( (oa>>24)&1 )) fe_full=$(( (oa>>31)&1 )) credit_max=$(( ka & 0xff )) ws_done=$(( wa & 1 )) ws_degen=$(( (wa>>1)&1 )) ws_anch_to=$(( (wa>>2)&1 )) reanchored=$(reanchored_d a)"
  echo "# decode die_b: lk=0x$(printf '%02x' $(( ob & 0xff ))) cal=$(( (ob>>16)&1 )) fcsm=$(( (ob>>17)&7 )) cr=$(( (ob>>23)&1 )) crack=$(( (ob>>24)&1 )) fe_full=$(( (ob>>31)&1 )) credit_max=$(( kb & 0xff )) ws_done=$(( wb & 1 )) ws_degen=$(( (wb>>1)&1 )) ws_anch_to=$(( (wb>>2)&1 )) reanchored=$(reanchored_d b)"
} | tee "$OUT"

echo "snapshot written: $OUT"

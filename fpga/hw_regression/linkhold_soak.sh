#!/bin/bash
# =============================================================================
# linkhold_soak.sh — held-link TIME-STABILITY soak (the test we've NEVER run)
#
# All current data proofs are fresh-bringup snapshots; the V1 saga had a
# 20-minute time-correlated death (link good ~20 min, then dead). This script
# takes an ALREADY-BROUGHT-UP link (manual recipe or autonomous zero-poke —
# say which with a flag, it's recorded in the log) and holds it: every
# INTERVAL seconds it re-sends the standard A->B txburst and scores byte-
# exactness, for MIN minutes. Per-burst one-liners + link-health fields so a
# time-correlated death shows up with its onset time and its register
# signature. Exit 0 iff EVERY burst was byte-exact.
#
# USAGE (lab host with board SSH; link must already be up, fcsm=4 both):
#   ./linkhold_soak.sh MIN <--manual|--autonomous> [--interval SEC] [--no-lease]
#     MIN          soak length in minutes
#     --manual     link was brought up with the manual recipe (rcp/winscan/...)
#     --autonomous link came up via the zero-poke autoneg chain
#     --interval   seconds between bursts (default 30)
#     --no-lease   caller already holds the lease
#
# A->B only (die_a sends) — the SAFE direction per td_v2_hwlib.sh (die_b
# sending without credit risks wedging die_b's PS). Reads throttled.
# First-use validation pending (no boards attached at authoring time).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

MIN=""; MODE=""; INTERVAL=30; DO_LEASE=1
while [ $# -gt 0 ]; do case "$1" in
  --manual) MODE=manual;;
  --autonomous) MODE=autonomous;;
  --interval) INTERVAL=$2; shift;;
  --no-lease) DO_LEASE=0;;
  -h|--help) sed -n '2,27p' "$0"; exit 0;;
  *) if [ -z "$MIN" ]; then MIN=$1; else echo "unknown arg: $1"; exit 2; fi;;
esac; shift; done
case "$MIN" in ''|*[!0-9]*) echo "usage: $0 MIN <--manual|--autonomous>"; exit 2;; esac
[ -n "$MODE" ] || { echo "state the bring-up mode: --manual or --autonomous"; exit 2; }

boards_up || { echo "### ABORT: a board is unreachable ($A_IP / $B_IP)"; exit 3; }
if [ "$DO_LEASE" = 1 ]; then
  lease_acquire $(( MIN * 60 + 600 )) || { echo "### ABORT: no $LEASE_NAME lease"; exit 3; }
  trap 'lease_release' EXIT
fi

# precondition: the link is UP (this script does NOT bring it up)
fa=$(fcsm a); fb=$(fcsm b)
if [ "$fa" != 4 ] || [ "$fb" != 4 ]; then
  echo "### ABORT: link not up (fcsm a=$fa b=$fb, need 4/4) — bring it up first"
  exit 3
fi

T0=$(date +%s)
DEADLINE=$(( T0 + MIN * 60 ))
echo "======== linkhold_soak ${MIN}min interval=${INTERVAL}s mode=$MODE ($(date)) ========"
echo "  die_a=$A_IP($A_BOARD) -> die_b=$B_IP($B_BOARD)  packet: ${ZP_TX_WORDS[*]}"

N=0; PASS=0; FIRST_FAIL_T=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  N=$((N+1)); t=$(( $(date +%s) - T0 ))
  # drain stale GP1 words (pops on read), send, settle, read back 3 words
  for i in 0 1 2 3; do gp1_rx_d b "$i" >/dev/null; done
  sleep "$TD_THROTTLE"
  zp_txburst a; sleep 1
  got=()
  for i in 0 1 2; do
    got+=("$(printf '0x%08x' "$(( $(gp1_rx_d b "$i") ))")"); sleep "$TD_THROTTLE"
  done
  ok=1
  for i in 0 1 2; do
    [ "${got[$i]}" = "$(printf '0x%08x' "$(( ${ZP_TX_WORDS[$i]} ))")" ] || ok=0
  done
  # link-health fields alongside every burst — the death signature we're hunting
  ob=$(( $(rd_d b $R_OBS) )); kb=$(( $(rd_d b $R_FCCRED) ))
  health="fcsm_a=$(fcsm a) fcsm_b=$(( (ob>>17)&7 )) credit_b=$(( kb & 0xff )) reanchored_b=$(reanchored_d b)"
  if [ $ok -eq 1 ]; then
    PASS=$((PASS+1)); printf 'HOLD_BURST %d t=+%ds PASS rx=%s %s\n' "$N" "$t" "${got[*]}" "$health"
  else
    [ -n "$FIRST_FAIL_T" ] || FIRST_FAIL_T=$t
    printf 'HOLD_BURST %d t=+%ds FAIL rx=%s %s\n' "$N" "$t" "${got[*]}" "$health"
  fi
  # sleep out the remainder of the interval (the burst itself takes ~10s of SSH)
  now=$(( $(date +%s) - T0 )); next=$(( N * INTERVAL ))
  [ "$next" -gt "$now" ] && sleep $(( next - now ))
done

echo "========================================================"
echo "  HOLD_RESULT ${PASS}/${N} bursts byte-exact over ${MIN}min (mode=$MODE)"
[ -n "$FIRST_FAIL_T" ] && echo "  first failure at t=+${FIRST_FAIL_T}s (time-correlated-death onset candidate)"
echo "========================================================"
[ "$PASS" -eq "$N" ] && [ "$N" -gt 0 ]

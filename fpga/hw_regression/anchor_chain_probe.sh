#!/bin/bash
# =============================================================================
# anchor_chain_probe.sh — settle WHY a die fails to re-anchor, in one shot.
#
# THE QUESTION. After a soak, a die sits FAILOPEN: winscan_done=1 but
# reanchored=0 and the anchor-retry budget is exhausted. Two causes are possible
# and they demand OPPOSITE fixes:
#
#   (A) SYNC COVERAGE. The deskew's `reanchored` latch requires all_sync_seen on
#       every active lane. If a lane never sees SYNC, the anchor can never latch,
#       no matter how many retries. => `feat/epoch-anchor-ab` (an EPOCH anchor
#       that does NOT need all_sync_seen) is the right lever.
#
#   (B) ANCHOR LATCH / CDC. Every active lane DOES see SYNC (sync_seen_vec ==
#       0xE4) yet `reanchored` still reads 0. Then SYNC coverage is fine and the
#       fault is in the latch or its clear path. => EPOCH would change NOTHING,
#       and the retry budget is being burned against a broken latch.
#
# PRE-REGISTERED PREDICTION (2026-07-10, before running): the preflight record
# says die_a reads sync_seen_vec == 0xE4 with full lane-7 coarse margin. So I
# expect (B): sync_seen == 0xE4 AND reanchored == 0 => epoch-anchor-ab is the
# WRONG lever, despite being the obvious one. If instead sync_seen != 0xE4, my
# prediction is wrong and EPOCH is worth building. Either way we learn.
#
# Read-mostly. The only writes are to R8 (0x2100): disarm autonomy first (so the
# winscan FSM is not fighting us for the taps), clear the sticky SYNC observers,
# force SYNC, sample, restore. Never touches 0x21B0/0x21B4 (FSM-owned taps).
#
# USAGE: ./anchor_chain_probe.sh          (acquires + releases its own lease)
#        NO_LEASE=1 ./anchor_chain_probe.sh   (caller already holds it)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

GOLDEN=0xe4          # active lane mask 0xE4 -> lanes {2,5,6,7}
R8=0x44032100
R8_FORCE=0x1C        # [2]=SYNC_EN [3]=force_always [4]=robust
R8_FORCE_CLR=0x3C    # + [5]=sync_obs_clr (W1P; single ctypes store => fires once)

boards_up || { echo "ABORT: a board is unreachable"; exit 3; }
if [ "${NO_LEASE:-0}" != 1 ]; then
  lease_acquire 900 || { echo "ABORT: no lease"; exit 3; }
  trap 'lease_release' EXIT
fi

hex(){ printf "0x%08x" "$1"; }
# R_SYNCSEEN carries a 0x5F presence marker at [31:24]. Check it: a clobbered PL
# (base.bit) or a stale package_ip both read 0 there, and 0x00 would otherwise be
# silently interpreted as "no lane sees SYNC" -- i.e. a fake (A) verdict.
syncseen(){ local d="$1" v mk
  v=$(( $($d rd $R_SYNCSEEN) ))
  mk=$(( (v >> 24) & 0xff ))
  if [ "$mk" -ne $(( 0x5f )) ]; then
    echo "ABORT: die_$d SYNCSEEN marker=0x$(printf %02x $mk), expected 0x5F." >&2
    echo "       The PL is clobbered or the IP is stale -- any verdict here is fiction." >&2
    exit 4
  fi
  echo $(( v & 0xff )); }

echo "======== anchor-chain probe $(date -u +%FT%TZ) ========"
echo
echo "--- BEFORE (as the soak left the dies) ---"
declare -A REA0 SS0 WS0 R8SAVE
for d in a b; do
  REA0[$d]=$(( $($d rd $R_REANCHORED) & 1 ))
  SS0[$d]=$(syncseen "$d")
  WS0[$d]=$((  $($d rd $R_WINSCAN_OBS) ))
  R8SAVE[$d]=$(( $($d rd $R8) ))
  printf "  die_%s  reanchored=%d  sync_seen=0x%02x  winscan_obs=%s  R8=%s\n" \
     "$d" "${REA0[$d]}" "${SS0[$d]}" "$(hex ${WS0[$d]})" "$(hex ${R8SAVE[$d]})"
done

echo
echo "--- disarm autonomy (stop the winscan FSM owning the taps), force SYNC, clear stickies ---"
for d in a b; do
  $d wr $R_NEGO_TRAIN_CFG 0x0 >/dev/null 2>&1 || true   # LOOP-9 escape hatch: beacons stop in a cycle
  $d wr $R_NEGO_CFG       0x0 >/dev/null 2>&1 || true
done
sleep 0.3
for d in a b; do $d wr $R8 $R8_FORCE_CLR >/dev/null; done   # force + one-shot clear
sleep 0.2
for d in a b; do $d wr $R8 $R8_FORCE     >/dev/null; done   # hold force, stop clearing
echo "  both dies now driving periodic SYNC beacons; accumulating sync_seen for 3 s"
sleep 3

echo
echo "--- AFTER (fresh SYNC-detect measurement, both dies forcing) ---"
rc=0
for d in a b; do
  ss=$(syncseen "$d")
  rea=$(( $($d rd $R_REANCHORED) & 1 ))
  printf "  die_%s  sync_seen=0x%02x (golden %s)  reanchored=%d  " "$d" "$ss" "$GOLDEN" "$rea"
  if [ "$ss" -ne $(( GOLDEN )) ]; then
    miss=$(( (GOLDEN) & ~ss & 0xff ))
    echo "=> (A) SYNC COVERAGE FAILURE. lanes missing mask=0x$(printf %02x $miss)"
    echo "         all_sync_seen unreachable => the anchor CAN NEVER latch, retries are futile."
    echo "         feat/epoch-anchor-ab (EPOCH anchor, no all_sync_seen) IS the right lever."
    rc=1
  elif [ "${REA0[$d]}" -eq 0 ]; then
    echo "=> (B) ANCHOR LATCH/CDC FAULT."
    echo "         every active lane sees SYNC, yet the soak left reanchored=0."
    echo "         SYNC coverage is FINE => epoch-anchor-ab would change NOTHING."
    echo "         Look at the reanchor latch + its sync_obs_clr / F3 clear path."
    rc=2
  else
    echo "=> this die had already re-anchored; not the failing one."
  fi
done

echo
echo "--- restore R8 ---"
for d in a b; do $d wr $R8 "$(hex ${R8SAVE[$d]})" >/dev/null; done
echo "  (autonomy left DISARMED on purpose: a disarm-park leaves ws_kicked_q set,"
echo "   so the next real run must start from a POR / fresh deploy, not a re-arm.)"
echo
echo "PREDICTION WAS (B). rc=$rc  (1=A/coverage, 2=B/latch, 0=neither die was failing)"
exit $rc

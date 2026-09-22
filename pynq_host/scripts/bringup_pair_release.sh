#!/usr/bin/env bash
# bringup_pair_release.sh — bilateral eth-chiplet TideLink bring-up with
# COORDINATED training release (I1 self-arm + FIX-E). Runs on the dev host.
#
# Sequence:
#   1. arm both dies (ROLE_CFG + SWI_TRAINING_MODE=1)
#   2. BARRIER: wait until BOTH dies reach S_HOLD (WINSCAN_STAT[6]=in_hold).
#      Neither die drops training until the peer is also holding — otherwise the
#      first to release stops sending the training pattern the peer still needs.
#   3. release both (SWI_TRAINING_MODE=0) near-simultaneously -> S_HOLD->S_VALIDATE
#      (hold_ctr already expired) -> VAL_TIMEOUT_TO_DONE=1 -> S_DONE -> cal_done.
#   4. poll both for cal_done=1 & fcsm=4.
set -u
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
A=${DIE_A:-ubuntu@10.22.24.159}; B=${DIE_B:-ubuntu@10.22.24.153}
STEP="scripts/tl_pair_step.py"
S(){ local host=$1; shift; sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$host" \
        "cd td && echo $PW | sudo -S python3 $STEP $* 2>/dev/null"; }

echo "== 1. ARM both =="
a=$(S "$A" arm die_a); b=$(S "$B" arm die_b); echo "  die_a: $a"; echo "  die_b: $b"

echo "== 2. BARRIER: wait BOTH in S_HOLD =="
# run both waits concurrently via temp files so both dies keep sending training
ta=$(mktemp); tb=$(mktemp)
S "$A" wait_hold 25 >"$ta" & pa=$!
S "$B" wait_hold 25 >"$tb" & pb=$!
wait $pa; wait $pb
ra=$(cat "$ta"); rb=$(cat "$tb"); rm -f "$ta" "$tb"
echo "  die_a: $ra"; echo "  die_b: $rb"
case "$ra$rb" in *NOHOLD*|"") echo "  ABORT: not both in S_HOLD"; exit 2;; esac

echo "== 3. RELEASE both (bilateral) =="
S "$A" release & S "$B" release & wait

echo "== 4. poll UP both =="
ua=$(mktemp); ub=$(mktemp)
S "$A" poll_up 10 >"$ua" & pa=$!
S "$B" poll_up 10 >"$ub" & pb=$!
wait $pa; wait $pb
la=$(cat "$ua"); lb=$(cat "$ub"); rm -f "$ua" "$ub"
echo "  die_a: $la"; echo "  die_b: $lb"
case "$la" in UP*) case "$lb" in UP*) echo "== RESULT: LINK UP fcsm=4 BOTH DIES =="; exit 0;; esac;; esac
echo "== RESULT: NOT both up =="; exit 3

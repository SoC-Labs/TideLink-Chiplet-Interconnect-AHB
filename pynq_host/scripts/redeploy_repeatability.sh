#!/bin/bash
# =============================================================================
# redeploy_repeatability.sh — T1 of the HW/runtime-sync investigation.
#
# THE QUESTION
#   The determinism campaign proved the FPGA build is bit-exact deterministic
#   (3 rebuilds byte-identical) yet two phase sweeps of that identical
#   bitstream diverged at 17/20 points. Theory (see
#   /tmp/hw_runtime_sync_investigation_brief.md §2): the slave RX deserialiser
#   word-boundary counter (WavD2DGpioRx.count) starts free-running at the
#   slave's role_lock edge, the master TX framing at the master's role_lock
#   edge, and phase_recal_sweep.sh writes those two role_locks from TWO
#   INDEPENDENT concurrent SSH sessions — so their skew is uniformly random
#   mod 16 EVERY deploy, making the static swept swi_phase_offset a per-deploy
#   1-in-16 lottery.
#
# WHAT THIS DOES (no rebuild, no phase sweep)
#   Re-deploys the SAME fixed (mp,sp) N times back-to-back on whatever bins
#   are staged in /tmp/tidelink_deploy, using the EXACT same plumbing as
#   phase_recal_sweep.sh (parallel deploy_pair.sh + recal_cycle + read_lock),
#   and reports the per-deploy lane-lock popcount.
#
# VERDICT
#   * LOTTERY  — popcount is an uncorrelated spread draw-to-draw on identical
#                bits ⇒ runtime nondeterminism CONFIRMED; the fix must be a
#                deterministic role_lock release (T2) or a HW counter re-sync
#                (T3), NOT a rebuild / XDC / phase tweak.
#   * STABLE   — popcount repeats within ±1 across all N ⇒ theory REFUTED;
#                the per-deploy role_lock-skew model is wrong; pivot.
#
# This is the cheapest decisive test in the whole bring-up (~1 min/deploy,
# no Vivado, no rebuild). Run it FIRST, before any T4 rebuild-bisection —
# a rebuild-bisection of a per-deploy lottery is meaningless.
#
# USAGE
#   MP=2 SP=6 N=10 [RECAL=1] [SETTLE=3] redeploy_repeatability.sh
#     MP,SP : the fixed phase point to hammer (default 2,6 = campaign best)
#     N     : number of independent deploys (default 10)
#     RECAL : 1 (default) run the SWI_RECAL cycle each deploy (matches
#             phase_recal_sweep.sh exactly so numbers are comparable);
#             0 = deploy only (isolates role_lock-skew from recal effects)
#
# Run on a host with board-network routes (mapstone-dev). Operator must hold
# the bridge1 lease. scp is broken on these hosts (see deploy_pair.sh).
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
# license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac

MASTER_IP=192.168.4.101
SLAVE_IP=192.168.6.101
PASS=xilinx
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SC=/tmp/tidelink_scripts

MP="${MP:-2}"
SP="${SP:-6}"
N="${N:-10}"
RECAL="${RECAL:-1}"
SETTLE="${SETTLE:-3}"

# --- identical helpers to phase_recal_sweep.sh (keep in lock-step) ----------
set_slot0() {   # VAL into Region 8 0x44032100 (+ debug_unlock GPIO)
    local IP=$1 VAL=$2
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
g,go=mm(0x44041000); struct.pack_into(\"<I\",g,go,1)
r,ro=mm(0x44032000,0x400); struct.pack_into(\"<I\",r,ro+0x100,$VAL)'" 2>/dev/null
}

read_lock() {   # returns "locked_hex fault_hex popcount"
    local IP=$1
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,o=mm(0x44032000,0x400); st=struct.unpack_from(\"<I\",r,o+0x108)[0]
lk=st&0xff; ft=(st>>8)&0xff; print(\"0x%02x 0x%02x %d\"%(lk,ft,bin(lk).count(\"1\")))'" 2>/dev/null
}

recal_cycle() {   # {train=1,recal=1} hold, {train=1,recal=0}, settle
    set_slot0 $MASTER_IP 0x3 & set_slot0 $SLAVE_IP 0x3 & wait
    sleep 0.25
    set_slot0 $MASTER_IP 0x1 & set_slot0 $SLAVE_IP 0x1 & wait
    sleep "$SETTLE"
}

MPV=$(( MP << 17 )); SPV=$(( SP << 17 ))
echo "redeploy repeatability start $(date)"
echo "fixed point: mp=$MP sp=$SP   N=$N   RECAL=$RECAL   (bins: /tmp/tidelink_deploy)"
printf '%-4s | %-22s | %-22s | %s\n' IT "MASTER lk/ft/#" "SLAVE lk/ft/#" "total"

tmin=99; tmax=-1; tsum=0
declare -A mseen sseen
for i in $(seq 1 "$N"); do
    PHASE_OVERRIDE=$MPV $SC/deploy_pair.sh $MASTER_IP z2_02 die_a /tmp/tidelink_deploy >/dev/null 2>&1 &
    PHASE_OVERRIDE=$SPV $SC/deploy_pair.sh $SLAVE_IP  z2_03 die_b /tmp/tidelink_deploy >/dev/null 2>&1 &
    wait
    sleep 1
    [ "$RECAL" = "1" ] && recal_cycle
    MR=$(read_lock $MASTER_IP); SR=$(read_lock $SLAVE_IP)
    mn=$(echo "$MR" | awk '{print $3}'); sn=$(echo "$SR" | awk '{print $3}')
    mn=${mn:-0}; sn=${sn:-0}
    tot=$(( mn + sn ))
    printf '%-4s | %-22s | %-22s | %s\n' "$i" "$MR" "$SR" "$tot"
    [ "$tot" -lt "$tmin" ] && tmin=$tot
    [ "$tot" -gt "$tmax" ] && tmax=$tot
    tsum=$(( tsum + tot ))
    mseen[$mn]=1; sseen[$sn]=1
done

mean=$(awk -v s="$tsum" -v n="$N" 'BEGIN{printf "%.1f", (n? s/n:0)}')
spread=$(( tmax - tmin ))
mdist=${#mseen[@]}; sdist=${#sseen[@]}
echo "redeploy repeatability done $(date)"
echo "TOTAL: min=$tmin max=$tmax mean=$mean spread=$spread  | distinct master#=$mdist distinct slave#=$sdist"

# Verdict heuristic: identical bits should give identical lock if the link
# were runtime-deterministic. A spread >=3 in total, or master/slave
# popcount taking >=3 distinct values across N deploys, is the per-deploy
# lottery signature. Tight (<=1) is a refutation of the skew model.
if [ "$spread" -ge 3 ] || [ "$mdist" -ge 3 ] || [ "$sdist" -ge 3 ]; then
    echo "VERDICT: LOTTERY — runtime nondeterminism CONFIRMED on byte-identical"
    echo "         bits. Build/XDC/phase are NOT the lever. Pursue T2"
    echo "         (deterministic coordinated role_lock release) / T3 (HW"
    echo "         word-boundary re-sync). See hw_runtime_sync brief."
    exit 2
elif [ "$spread" -le 1 ] && [ "$mdist" -le 2 ] && [ "$sdist" -le 2 ]; then
    echo "VERDICT: STABLE — per-deploy role_lock-skew model REFUTED at this"
    echo "         point. Repeatable on identical bits ⇒ the residual is a"
    echo "         fixed deficit (now a valid T4 rebuild-bisection target)."
    exit 0
else
    echo "VERDICT: INCONCLUSIVE — borderline spread; raise N (e.g. N=20) and"
    echo "         re-run, and try RECAL=0 to isolate role_lock-skew from"
    echo "         the SWI_RECAL cycle."
    exit 1
fi

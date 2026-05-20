#!/bin/bash
# =============================================================================
# bringup_health_probe.sh — time-series SW probe of SWI_LANE_STATUS
#
# Tests the audit's measurement-artifact theory: lane_locked has NO sticky
# bit, and the bring-up SW reads it 2 s AFTER recal — long after both peers
# have exited S_HOLD (≈21 ms) and TX has switched from training byte to
# Wlink credit frames. lane_checker drops `locked` within ONE 16-bit word
# of training stopping, so SW reads junk.
#
# This probe deploys b_inphy ONCE, then in a loop: pulses recal_cycle, and
# reads SWI_LANE_STATUS at a series of short delays (10/50/200/500/1000/2000
# ms) to capture the TRAJECTORY of lane_locked vs time-after-recal. We also
# capture cal_done / lane_fault / FCSM / cr_pkt_seen / crack — these have
# sticky semantics (or are slow enough that 2-FF CDC works) so they tell
# the truth even at 2 s.
#
# Expected outcomes:
#  - lane_locked HIGH at T+10-100 ms, DROPS by T+2000 ms, cal_done=1
#    throughout → AUDIT CONFIRMED: link converges every recal; bring-up
#    needs a sticky-OR latch (5-line RTL change), nothing more.
#  - lane_locked LOW at all times → real lock problem; pre-T3a thinking
#    was wrong; needs further investigation.
#  - lane_locked DROPS faster than 10 ms → S_HOLD shorter than the model;
#    re-tune HOLD_CYCLES.
#
# SAFE-OPS ONLY: APB reads + Region-8 slot0 train/recal bit + strap/
# debug_unlock. NO AHB_TX, no doorbell. Cannot wedge a board.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_PAIR="${DEPLOY_PAIR:-$SCRIPT_DIR/deploy_pair.sh}"
ARTEFACTS="${ARTEFACTS:-/tmp/tidelink_deploy}"

N_ITER="${N_ITER:-3}"   # how many recal-cycle + readback iterations
RECAL_HOLD="${RECAL_HOLD:-0.25}"

# Delays (ms) after recal release before each readback. Captures TRAJECTORY.
DELAYS_MS=( 10 30 80 200 500 1000 2000 )

# ---------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 2; }

# Read SWI_LANE_STATUS at 0x44032000+0x108. Packed:
#   [7:0]   locked
#   [15:8]  fault
#   [16]    cal_done
#   [20:17] FCSM state
#   [22:21] LL_RX
#   [23]    cr_pkt_seen
#   [24]    crack_pkt_seen
# Emits one line: "lkHex ftHex pop calDone fcsm llrx cr crack"
read_status() {
    local IP=$1
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,o=mm(0x44032000,0x400); s=struct.unpack_from(\"<I\",r,o+0x108)[0]
lk=s&0xff; ft=(s>>8)&0xff
print(\"0x%02x 0x%02x %d %d %d %d %d %d\"%(lk,ft,bin(lk).count(\"1\"),(s>>16)&1,(s>>17)&0xf,(s>>21)&0x3,(s>>23)&1,(s>>24)&1))'" 2>/dev/null
}

set_slot0() {   # IP VAL  — Region 8 slot0 + debug_unlock
    local IP=$1 VAL=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
g,go=mm(0x44041000); struct.pack_into(\"<I\",g,go,1)
r,ro=mm(0x44032000,0x400); struct.pack_into(\"<I\",r,ro+0x100,$VAL)'" 2>/dev/null
}

recal_cycle() {  # parallel re-arm both calibrators
    set_slot0 "$MASTER_IP" 0x3 & set_slot0 "$SLAVE_IP" 0x3 & wait
    sleep "$RECAL_HOLD"
    set_slot0 "$MASTER_IP" 0x1 & set_slot0 "$SLAVE_IP" 0x1 & wait
}

# ---------------------------------------------------------------------------
[ -f "$ARTEFACTS/tidelink.bin" ] || fail "no tidelink.bin staged in $ARTEFACTS"

echo "============================================================="
echo " TideLink lane-locked TRAJECTORY probe  $(date)"
echo "  bins=$ARTEFACTS  N_ITER=$N_ITER  delays(ms)=${DELAYS_MS[*]}"
echo "  Read fields: lk/ft pop cal# fcsm llrx cr crack"
echo "============================================================="

# Pre-flight
for ip in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" true 2>/dev/null \
        || fail "board $ip unreachable"
done

echo "--- Phase 1: parallel deploy (sets phase=0 both sides) ---"
PHASE_OVERRIDE=0x00000000 bash "$DEPLOY_PAIR" "$MASTER_IP" z2_master die_a "$ARTEFACTS" >/dev/null 2>&1 &
mpid=$!
PHASE_OVERRIDE=0x00000000 bash "$DEPLOY_PAIR" "$SLAVE_IP"  z2_slave  die_b "$ARTEFACTS" >/dev/null 2>&1 &
spid=$!
wait $mpid; wait $spid
sleep 1

for it in $(seq 1 "$N_ITER"); do
    echo
    echo "===== iter $it: recal_cycle, then read trajectory ====="
    recal_cycle
    # Take the t=0 reading immediately (this is also right after the second
    # set_slot0 release wait, so effectively a few ms post recal release).
    for ms in "${DELAYS_MS[@]}"; do
        # Sleep up to the target delay, then read both boards in parallel.
        sleep "$(awk -v m=$ms 'BEGIN{print m/1000.0}')"
        MR=$(read_status "$MASTER_IP")
        SR=$(read_status "$SLAVE_IP")
        printf '  T+%4dms  M[%s]  S[%s]\n' "$ms" "${MR:-?}" "${SR:-?}"
    done
done

echo
echo "============================================================="
echo " Probe complete. Interpretation:"
echo "  - lane_locked HIGH at small T then DROPS by T+2000ms,"
echo "    cal_done=1 throughout, fault=0x00 → AUDIT CONFIRMED:"
echo "    link converges every recal; sticky-OR latch is all that"
echo "    remains for the bring-up."
echo "  - lane_locked LOW at all T → real lock problem; theory wrong."
echo "  - lane_locked stays HIGH at T+2000ms too → previous reads"
echo "    were always meaningful; pivot needed."
echo "============================================================="

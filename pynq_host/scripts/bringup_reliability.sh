#!/bin/bash
# =============================================================================
# bringup_reliability.sh — statistical reliability characterisation
#
# Runs N independent deploys (re-rolling role_lock/count skew each time) and
# records per-deploy lock counts WITHOUT early-exit. Gives an empirical
# distribution of how reliably the link converges in a single deploy.
#
# Output: per-iteration lock vector + summary statistics:
#   N total deploys
#   # converged (both 8/8)
#   # near-converged (combined ≥ 14)
#   # FCSM-running on at least one side (cal_done=1 + crack_pkt_seen)
#   mean / min / max / spread per side
#   mean / min / max combined
#
# Distinct from bringup_pair_converge.sh which EXITS on first 16/16.
# This script intentionally completes ALL N deploys to gather statistics.
#
# Usage:
#   N_DEPLOYS=30 MASTER_IP=192.168.4.101 SLAVE_IP=192.168.6.101 \
#   bringup_reliability.sh
#
# Safe-ops only (no AHB_TX, no doorbell). Cannot wedge boards.
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
N_DEPLOYS="${N_DEPLOYS:-30}"
SETTLE="${SETTLE:-2}"
RECAL_HOLD="${RECAL_HOLD:-0.25}"

fail() { echo "ERROR: $*" >&2; exit 2; }

set_slot0() {
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

recal_cycle() {
    set_slot0 "$MASTER_IP" 0x3 & set_slot0 "$SLAVE_IP" 0x3 & wait
    sleep "$RECAL_HOLD"
    set_slot0 "$MASTER_IP" 0x1 & set_slot0 "$SLAVE_IP" 0x1 & wait
    sleep "$SETTLE"
}

[ -f "$ARTEFACTS/tidelink.bin" ] || fail "no tidelink.bin staged in $ARTEFACTS"

echo "============================================================="
echo " TideLink RELIABILITY characterisation  $(date)"
echo "  N=$N_DEPLOYS  master=$MASTER_IP  slave=$SLAVE_IP"
echo "  Each row: 1 fresh re-deploy + 1 recal_cycle + 1 settled read."
echo "============================================================="
printf '%-4s | %-30s | %-30s | %s\n' DEP "die_a@.4 lk/ft pop cal# fs cr crk" "die_b@.6 lk/ft pop cal# fs cr crk" "tot"

a_lk_arr=()
b_lk_arr=()
tot_arr=()
conv_count=0
near_count=0
fcsm_running_count=0

for it in $(seq 1 "$N_DEPLOYS"); do
    bash "$DEPLOY_PAIR" "$MASTER_IP" z2_master die_a "$ARTEFACTS" >/dev/null 2>&1 &
    bash "$DEPLOY_PAIR" "$SLAVE_IP"  z2_slave  die_b "$ARTEFACTS" >/dev/null 2>&1 &
    wait
    sleep 1
    recal_cycle
    MR=$(read_status "$MASTER_IP")
    SR=$(read_status "$SLAVE_IP")
    mlk=$(echo "$MR" | awk '{print $1}'); mft=$(echo "$MR" | awk '{print $2}')
    mpc=$(echo "$MR" | awk '{print $3}'); mcd=$(echo "$MR" | awk '{print $4}')
    mfs=$(echo "$MR" | awk '{print $5}'); mcr=$(echo "$MR" | awk '{print $6}'); mck=$(echo "$MR" | awk '{print $7}')
    slk=$(echo "$SR" | awk '{print $1}'); sft=$(echo "$SR" | awk '{print $2}')
    spc=$(echo "$SR" | awk '{print $3}'); scd=$(echo "$SR" | awk '{print $4}')
    sfs=$(echo "$SR" | awk '{print $5}'); scr=$(echo "$SR" | awk '{print $6}'); sck=$(echo "$SR" | awk '{print $7}')
    mpc=${mpc:-0}; spc=${spc:-0}; mfs=${mfs:-0}; sfs=${sfs:-0}
    tot=$((mpc + spc))
    a_lk_arr+=("$mpc"); b_lk_arr+=("$spc"); tot_arr+=("$tot")
    [ "$tot" -eq 16 ] && conv_count=$((conv_count+1))
    [ "$tot" -ge 14 ] && near_count=$((near_count+1))
    if [ "$mfs" -ge 2 ] && [ "$sfs" -ge 2 ]; then fcsm_running_count=$((fcsm_running_count+1)); fi
    printf '%-4s | %-30s | %-30s | %s\n' "$it" \
        "${mlk}/${mft} ${mpc} ${mcd} fs${mfs} cr${mcr} ck${mck}" \
        "${slk}/${sft} ${spc} ${scd} fs${sfs} cr${scr} ck${sck}" \
        "$tot"
done

# Summary statistics
amin=99; amax=0; asum=0
bmin=99; bmax=0; bsum=0
tmin=99; tmax=0; tsum=0
for v in "${a_lk_arr[@]}"; do
    [ "$v" -lt "$amin" ] && amin=$v
    [ "$v" -gt "$amax" ] && amax=$v
    asum=$((asum + v))
done
for v in "${b_lk_arr[@]}"; do
    [ "$v" -lt "$bmin" ] && bmin=$v
    [ "$v" -gt "$bmax" ] && bmax=$v
    bsum=$((bsum + v))
done
for v in "${tot_arr[@]}"; do
    [ "$v" -lt "$tmin" ] && tmin=$v
    [ "$v" -gt "$tmax" ] && tmax=$v
    tsum=$((tsum + v))
done

echo "============================================================="
echo "SUMMARY (N=$N_DEPLOYS deploys, one shot each, no retries)"
echo "============================================================="
amean=$(awk -v s="$asum" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", s/n}')
bmean=$(awk -v s="$bsum" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", s/n}')
tmean=$(awk -v s="$tsum" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", s/n}')
echo "die_a (master RX of slave TX, non-flip):"
echo "  min=$amin max=$amax mean=$amean"
echo "die_b (slave RX of master TX, flip):"
echo "  min=$bmin max=$bmax mean=$bmean"
echo "Combined (out of 16):"
echo "  min=$tmin max=$tmax mean=$tmean"
echo
conv_pct=$(awk -v c="$conv_count" -v n="$N_DEPLOYS" 'BEGIN{printf "%.1f%%", 100*c/n}')
near_pct=$(awk -v c="$near_count" -v n="$N_DEPLOYS" 'BEGIN{printf "%.1f%%", 100*c/n}')
fcsm_pct=$(awk -v c="$fcsm_running_count" -v n="$N_DEPLOYS" 'BEGIN{printf "%.1f%%", 100*c/n}')
echo "Convergence rates (one-shot, no retry):"
echo "  16/16 perfect      : $conv_count / $N_DEPLOYS  ($conv_pct)"
echo "  14+/16 near        : $near_count / $N_DEPLOYS  ($near_pct)"
echo "  FCSM both ≥ 2      : $fcsm_running_count / $N_DEPLOYS  ($fcsm_pct)"
echo
echo "Lock vectors (sampled at SETTLE=${SETTLE}s post-recal):"
for ((i=0; i<${#a_lk_arr[@]}; i++)); do
    printf "  dep%2d: a=%d b=%d t=%d\n" "$((i+1))" "${a_lk_arr[i]}" "${b_lk_arr[i]}" "${tot_arr[i]}"
done
echo "============================================================="

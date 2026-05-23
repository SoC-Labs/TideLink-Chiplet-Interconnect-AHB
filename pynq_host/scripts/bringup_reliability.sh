#!/bin/bash
# =============================================================================
# bringup_reliability.sh — N=20 reliability sweep of the closed-loop bring-up.
#
# WHAT THIS DOES
#   Runs bringup_pair_converge.sh N independent times back-to-back on the
#   staged bitstreams. Each iteration is a complete redeploy + closed-loop
#   converge attempt (re-rolls the role_lock/count skew lottery), so this is
#   a *system-level* reliability characteriser, not a per-deploy snapshot.
#
#   For each iteration it records the BEST popcount and cal_done state from
#   the converge log (i.e. the value the converge loop committed to as its
#   "best seen"), and a per-side cal_done bit. After N runs it emits a
#   SUMMARY block:
#     N, #full-16/16, #>=14, mean, min, max, cal_done rate (per side)
#
# WHY
#   The fold-loop closeout milestone needs to demonstrate the byte-identical
#   fresh-clone bitstream is not just "lockable" but "reliably lockable" —
#   i.e. >=N/N at 16/16 across independent power-on style redeploys.
#
# USAGE
#   N_DEPLOYS=20 ARTEFACTS=$HOME/td_milestone_stage \
#   MASTER_IP=192.168.4.101 SLAVE_IP=192.168.6.101 \
#   TIDELINK_BOARD_PASS=xilinx \
#   bash scripts/bringup_reliability.sh
#
#   Designed to be launched detached (setsid + nohup + </dev/null) so it
#   survives the operator's SSH session ending.
#
# SAFETY
#   Only invokes bringup_pair_converge.sh — same safe-op set (no AHB_TX,
#   no doorbell). Each iteration is bounded by MAX_RETRIES inside converge.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONV="${CONV:-$SCRIPT_DIR/bringup_pair_converge.sh}"

N_DEPLOYS="${N_DEPLOYS:-20}"
ARTEFACTS="${ARTEFACTS:-$HOME/td_milestone_stage}"
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
MAX_RETRIES="${MAX_RETRIES:-20}"
STABLE="${STABLE:-3}"

export ARTEFACTS MASTER_IP SLAVE_IP MAX_RETRIES STABLE
export TIDELINK_BOARD_PASS="$PASS"

LOGDIR="${LOGDIR:-$ARTEFACTS/reliability_runs}"
mkdir -p "$LOGDIR"

echo "=============================================================="
echo " TideLink reliability sweep  $(date)"
echo "  N_DEPLOYS=$N_DEPLOYS  ARTEFACTS=$ARTEFACTS"
echo "  MASTER_IP=$MASTER_IP  SLAVE_IP=$SLAVE_IP"
echo "  CONV=$CONV"
echo "  per-iter MAX_RETRIES=$MAX_RETRIES  STABLE=$STABLE"
echo "=============================================================="

# Per-iteration result extraction. We greatly prefer the converge script's
# own RESULT lines, but fall back to parsing the per-iteration table if no
# RESULT line is found.
parse_iter_log() {  # LOG -> "best_total acd bcd conv_flag"
    local L="$1"
    local conv=0 best=0 acd=0 bcd=0
    # CONVERGED case — pull tot from last data row (= 16 typically), cal_done
    # bits from the same row.
    if grep -q "RESULT: CONVERGED" "$L"; then
        conv=1
    fi
    # Find the final data row of the bring-up table (lines that start with
    # an integer iteration number followed by '|').
    local last
    last=$(grep -E "^[0-9]+[[:space:]]*\|" "$L" | tail -1)
    if [ -n "$last" ]; then
        # Format from converge:
        #  IT | die_a... lk/ft pc cd fsX crY | die_b... lk/ft pc cd fsX crY | tot
        # Use awk with '|' separator to grab the three RHS cells.
        local acell bcell tcell
        acell=$(echo "$last" | awk -F'|' '{print $2}')
        bcell=$(echo "$last" | awk -F'|' '{print $3}')
        tcell=$(echo "$last" | awk -F'|' '{print $4}')
        # die_a cell = "lk/ft pc cd fsX crY" -> field 3 is cd
        acd=$(echo "$acell" | awk '{print $3+0}')
        bcd=$(echo "$bcell" | awk '{print $3+0}')
        best=$(echo "$tcell" | awk '{print $1+0}')
    fi
    # Also try to take a higher "best seen" from the NOT-CONVERGED footer.
    local bs
    bs=$(grep -Eo "Best seen: [0-9]+/16" "$L" | head -1 | awk '{print $3}' | awk -F/ '{print $1}')
    if [ -n "$bs" ] && [ "$bs" -gt "$best" ] 2>/dev/null; then best=$bs; fi
    # If converged, total is by construction 16.
    if [ "$conv" = "1" ]; then best=16; fi
    echo "$best $acd $bcd $conv"
}

declare -a TOTALS=()
declare -a ACDS=()
declare -a BCDS=()
n_16=0
n_ge14=0
min=99
max=-1
sum=0
acd_n=0
bcd_n=0
conv_n=0

for i in $(seq 1 "$N_DEPLOYS"); do
    LOG="$LOGDIR/iter_$(printf '%02d' "$i").log"
    echo "----- iter $i / $N_DEPLOYS  $(date)  -> $LOG"
    bash "$CONV" >"$LOG" 2>&1
    rc=$?
    read -r best acd bcd conv < <(parse_iter_log "$LOG")
    : "${best:=0}"; : "${acd:=0}"; : "${bcd:=0}"; : "${conv:=0}"
    TOTALS+=("$best"); ACDS+=("$acd"); BCDS+=("$bcd")
    echo "  iter $i: tot=$best acd=$acd bcd=$bcd conv=$conv rc=$rc"
    [ "$best" -ge 16 ] 2>/dev/null && n_16=$((n_16+1))
    [ "$best" -ge 14 ] 2>/dev/null && n_ge14=$((n_ge14+1))
    [ "$best" -lt "$min" ] 2>/dev/null && min=$best
    [ "$best" -gt "$max" ] 2>/dev/null && max=$best
    sum=$((sum + best))
    [ "$acd" = "1" ] && acd_n=$((acd_n+1))
    [ "$bcd" = "1" ] && bcd_n=$((bcd_n+1))
    [ "$conv" = "1" ] && conv_n=$((conv_n+1))
done

mean=$(awk -v s="$sum" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", (n? s/n:0)}')
acd_rate=$(awk -v a="$acd_n" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", (n? 100.0*a/n:0)}')
bcd_rate=$(awk -v b="$bcd_n" -v n="$N_DEPLOYS" 'BEGIN{printf "%.2f", (n? 100.0*b/n:0)}')

echo "=============================================================="
echo " SUMMARY  $(date)"
echo "  N_DEPLOYS    = $N_DEPLOYS"
echo "  #full 16/16  = $n_16"
echo "  #>=14        = $n_ge14"
echo "  #CONVERGED   = $conv_n   (converge.sh RESULT: CONVERGED)"
echo "  total/16     min=$min max=$max mean=$mean"
echo "  cal_done rate die_a=$acd_n/$N_DEPLOYS (${acd_rate}%)  die_b=$bcd_n/$N_DEPLOYS (${bcd_rate}%)"
echo "  per-iter totals: ${TOTALS[*]}"
echo "=============================================================="
if [ "$n_16" -eq "$N_DEPLOYS" ]; then
    echo "RESULT: PASS — $n_16/$N_DEPLOYS at full 16/16 (100%)"
    exit 0
elif [ "$n_16" -gt 0 ]; then
    echo "RESULT: PARTIAL — $n_16/$N_DEPLOYS at 16/16; $n_ge14/$N_DEPLOYS >=14"
    exit 1
else
    echo "RESULT: FAIL — 0/$N_DEPLOYS reached 16/16 (best=$max)"
    exit 2
fi

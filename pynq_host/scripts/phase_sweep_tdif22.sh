#!/bin/bash
# =============================================================================
# phase_sweep_tdif22.sh — full 4×4 (M_PHASE, S_PHASE) sweep on the tdif-22
# bitstream.
#
# Background (2026-05-27): with the BRINGUP_SAFETY_TIMEOUT_SWEEPS=16 watchdog
# both calibrators always reach cal_done=1, but the per-direction (phase,slip)
# lottery persists — only ~1/12 deploys lands both FCSMs at LINK_IDLE with
# doorbells crossing M→S. The current deploy_pair.sh hard-codes master phase=0
# and slave phase=3 (empirical). This harness sweeps the full {0..3}×{0..3}
# space, doing one recal cycle per combination, then samples FCSM state +
# cal_done + doorbell crossing.
#
# Hypothesis: there exists at least one (M_PHASE, S_PHASE) pair that lands
# both FCSMs at LINK_IDLE (state 4) and reliably crosses doorbells M→S.
#
# What this script does NOT do:
#   * does NOT rebuild the bitstream — it uses whatever is staged at
#     ARTEFACTS_DIR (default /tmp/tidelink_deploy/tdif-22 on mapstone-dev)
#   * does NOT modify RTL or anything in deps/
#   * does NOT write AHB_TX before link is verified up (wedge hazard)
#
# Lease: caller is responsible for `fpgahub pair lease acquire bridge1`
# BEFORE running this harness; harness honours an existing lease via SSH.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
# license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

# ---------- Tunables -------------------------------------------------------
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
ARTEFACTS="${ARTEFACTS:-/tmp/tidelink_deploy/tdif-22}"
# Where deploy_pair.sh lives on the mapstone-dev side (may differ from this
# repo path because we run this harness from there).
DEPLOY_SH="${DEPLOY_SH:-$(dirname "$0")/deploy_pair.sh}"
LIB_HWTEST="${LIB_HWTEST:-$(dirname "$0")/hwtest/lib/lib_hwtest.sh}"
N_DBELL="${N_DBELL:-4}"            # doorbells to fire per combo
SETTLE_AFTER_DEPLOY="${SETTLE_AFTER_DEPLOY:-2.0}"
SETTLE_AFTER_RECAL="${SETTLE_AFTER_RECAL:-0.5}"
SETTLE_AFTER_DBELL="${SETTLE_AFTER_DBELL:-0.5}"
MP_LIST="${MP_LIST:-0 1 2 3}"
SP_LIST="${SP_LIST:-0 1 2 3}"

# Output log directory
TS="$(date +%Y%m%d_%H%M%S)"
LOGDIR="${LOGDIR:-/tmp/tidelink_phase_sweep_$TS}"
mkdir -p "$LOGDIR"

# ---------- Lib import (for tt_devmem_read/write) --------------------------
# shellcheck disable=SC1090
if [ -f "$LIB_HWTEST" ]; then
    source "$LIB_HWTEST"
else
    echo "ERROR: cannot find lib_hwtest.sh at $LIB_HWTEST" >&2
    exit 2
fi

# ---------- Local helpers --------------------------------------------------
# Re-publish the lib's debug_unlock as a safety net in case the slave bitstream
# clamped it during reload.
unlock_both() {
    tt_devmem_write "$MASTER_IP" 0x44041000 1 >/dev/null 2>&1
    tt_devmem_write "$SLAVE_IP"  0x44041000 1 >/dev/null 2>&1
}

# Decode lane status word 0x44032108 into "lk=0x?? ft=0x?? cal=? pop=? fcsm=?"
# (matches tt_read_lane_status formatting but as a single string for logs).
decode_status() {
    local IP=$1
    local raw
    raw=$(tt_read_lane_status "$IP")
    if [ -z "$raw" ]; then
        echo "lk=?? ft=?? cal=? pop=0 fcsm=?"
        return
    fi
    local lk ft cal pop fcsm
    lk=$(echo "$raw"  | awk '{print $1}')
    ft=$(echo "$raw"  | awk '{print $2}')
    cal=$(echo "$raw" | awk '{print $3}')
    pop=$(echo "$raw" | awk '{print $4}')
    fcsm=$(echo "$raw"| awk '{print $5}')
    printf "lk=%s ft=%s cal=%s pop=%s fcsm=%s" "$lk" "$ft" "$cal" "$pop" "$fcsm"
}

# One coordinated recal cycle, matching phase_recal_sweep.sh + manual scripts:
#   slot0 = 0x3 (train+recal), sleep, 0x1 (train only), sleep, 0x0 (release)
recal_cycle() {
    set_slot0 "$MASTER_IP" 0x3 &
    set_slot0 "$SLAVE_IP"  0x3 &
    wait
    sleep 0.3
    set_slot0 "$MASTER_IP" 0x1 &
    set_slot0 "$SLAVE_IP"  0x1 &
    wait
    sleep 0.3
    set_slot0 "$MASTER_IP" 0x0 &
    set_slot0 "$SLAVE_IP"  0x0 &
    wait
    sleep "$SETTLE_AFTER_RECAL"
}

# slot0 write helper — matches phase_recal_sweep.sh
set_slot0() {
    local IP=$1 VAL=$2
    tt_devmem_write "$IP" 0x44041000 1 >/dev/null 2>&1
    tt_devmem_write "$IP" 0x44032100 "$VAL"
}

# Deploy both bitstreams in parallel with PHASE_OVERRIDE.
# Aborts the COMBO (not the harness) on deploy fail.
deploy_phase() {
    local mp=$1 sp=$2
    local MPV SPV
    MPV=$(( mp << 17 ))
    SPV=$(( sp << 17 ))
    PHASE_OVERRIDE="$MPV" "$DEPLOY_SH" "$MASTER_IP" z2_02 die_a "$ARTEFACTS" \
        > "$LOGDIR/deploy_master_mp${mp}_sp${sp}.log" 2>&1 &
    local pidM=$!
    PHASE_OVERRIDE="$SPV" "$DEPLOY_SH" "$SLAVE_IP"  z2_03 die_b "$ARTEFACTS" \
        > "$LOGDIR/deploy_slave_mp${mp}_sp${sp}.log"  2>&1 &
    local pidS=$!
    wait "$pidM"; local rcM=$?
    wait "$pidS"; local rcS=$?
    if [ "$rcM" -ne 0 ] || [ "$rcS" -ne 0 ]; then
        return 1
    fi
    return 0
}

# Ring N master-side doorbells. Reads S DOORBELL_RESP_ACC before/after.
# Sets globals: DRA_BEFORE, DRA_AFTER, DRA_DELTA (decimal counts).
ring_doorbells() {
    local n=$1
    DRA_BEFORE=$(tt_devmem_read "$SLAVE_IP" 0x44032024)
    local i=0
    while [ "$i" -lt "$n" ]; do
        tt_devmem_write "$MASTER_IP" 0x44032014 0x1 >/dev/null 2>&1
        sleep 0.05
        i=$((i+1))
    done
    sleep "$SETTLE_AFTER_DBELL"
    DRA_AFTER=$(tt_devmem_read "$SLAVE_IP" 0x44032024)
    local b_dec a_dec
    b_dec=$(( ${DRA_BEFORE:-0} ))
    a_dec=$(( ${DRA_AFTER:-0} ))
    # DOORBELL_RESP_ACC is read-clear, so DRA_AFTER is the count since the
    # pre-read. DRA_BEFORE is the count since the previous combo's read-clear.
    DRA_DELTA="$a_dec"
}

# ---------- Header / matrix init -------------------------------------------
START_TS=$(date +%s)
echo "================================================================"
echo " phase_sweep_tdif22.sh — 4x4 (M_PHASE, S_PHASE) sweep"
echo " starting $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " MASTER=$MASTER_IP  SLAVE=$SLAVE_IP"
echo " artefacts=$ARTEFACTS"
echo " logdir=$LOGDIR"
echo " sweep MP={${MP_LIST}} × SP={${SP_LIST}}"
echo "================================================================"

# Matrix data structures.  Use a flat associative array indexed "mp,sp".
declare -A MAT_M_FCSM MAT_S_FCSM MAT_M_POP MAT_S_POP MAT_M_CAL MAT_S_CAL
declare -A MAT_DBELL MAT_VERDICT

# CSV ledger (one line per combo).
CSV="$LOGDIR/sweep_results.csv"
echo "mp,sp,m_fcsm,m_cal,m_pop,m_lk,m_ft,s_fcsm,s_cal,s_pop,s_lk,s_ft,dbell_delta,verdict" > "$CSV"

# ---------- Main sweep -----------------------------------------------------
COMBOS=0
WINS=0
LINK_IDLE_BOTH=0

for mp in $MP_LIST; do
  for sp in $SP_LIST; do
    COMBOS=$((COMBOS+1))
    tag="mp=${mp} sp=${sp}"
    t0=$(date +%s)
    echo
    echo "---- [$COMBOS] $tag --------------------------------------------"

    # Step 1: deploy with the chosen phases
    if ! deploy_phase "$mp" "$sp"; then
        echo "  DEPLOY FAILED — see $LOGDIR/deploy_*_mp${mp}_sp${sp}.log"
        MAT_M_FCSM[$mp,$sp]="X"; MAT_S_FCSM[$mp,$sp]="X"
        MAT_M_POP[$mp,$sp]=0;    MAT_S_POP[$mp,$sp]=0
        MAT_M_CAL[$mp,$sp]=0;    MAT_S_CAL[$mp,$sp]=0
        MAT_DBELL[$mp,$sp]=0;    MAT_VERDICT[$mp,$sp]="DEPLOY_FAIL"
        echo "$mp,$sp,X,0,0,0,0,X,0,0,0,0,0,DEPLOY_FAIL" >> "$CSV"
        continue
    fi

    # Step 2: let calibrator settle (BRINGUP_SAFETY_TIMEOUT_SWEEPS watchdog
    # forces cal_done within ~16 sweeps)
    sleep "$SETTLE_AFTER_DEPLOY"

    # Step 3: one recal cycle (slot0=3->1->0) to re-roll the (phase, slip)
    unlock_both
    recal_cycle

    # Step 4: read lane status both sides
    MR_RAW=$(tt_read_lane_status "$MASTER_IP")
    SR_RAW=$(tt_read_lane_status "$SLAVE_IP")
    if [ -z "$MR_RAW" ] || [ -z "$SR_RAW" ]; then
        echo "  STATUS READ FAILED — master='$MR_RAW' slave='$SR_RAW'"
        MAT_M_FCSM[$mp,$sp]="X"; MAT_S_FCSM[$mp,$sp]="X"
        MAT_M_POP[$mp,$sp]=0;    MAT_S_POP[$mp,$sp]=0
        MAT_M_CAL[$mp,$sp]=0;    MAT_S_CAL[$mp,$sp]=0
        MAT_DBELL[$mp,$sp]=0;    MAT_VERDICT[$mp,$sp]="STATUS_FAIL"
        echo "$mp,$sp,X,0,0,0,0,X,0,0,0,0,0,STATUS_FAIL" >> "$CSV"
        continue
    fi
    M_LK=$(echo "$MR_RAW" | awk '{print $1}'); M_FT=$(echo "$MR_RAW" | awk '{print $2}')
    M_CAL=$(echo "$MR_RAW"| awk '{print $3}'); M_POP=$(echo "$MR_RAW"| awk '{print $4}')
    M_FCSM=$(echo "$MR_RAW"|awk '{print $5}')
    S_LK=$(echo "$SR_RAW" | awk '{print $1}'); S_FT=$(echo "$SR_RAW" | awk '{print $2}')
    S_CAL=$(echo "$SR_RAW"| awk '{print $3}'); S_POP=$(echo "$SR_RAW"| awk '{print $4}')
    S_FCSM=$(echo "$SR_RAW"|awk '{print $5}')

    echo "  M: $(decode_status $MASTER_IP)"
    echo "  S: $(decode_status $SLAVE_IP)"

    # Step 5: doorbells from master, observe slave DOORBELL_RESP_ACC
    DRA_BEFORE=""; DRA_AFTER=""; DRA_DELTA=0
    ring_doorbells "$N_DBELL"
    echo "  doorbells: rang $N_DBELL on master; S DOORBELL_RESP_ACC before=${DRA_BEFORE} after=${DRA_AFTER} delta_dec=${DRA_DELTA}"

    # Step 6: classify
    VERDICT="MISC"
    if [ "${M_FCSM:-X}" = "4" ] && [ "${S_FCSM:-X}" = "4" ]; then
        LINK_IDLE_BOTH=$((LINK_IDLE_BOTH+1))
        if [ "${DRA_DELTA:-0}" -ge "$N_DBELL" ]; then
            VERDICT="WIN"
            WINS=$((WINS+1))
        else
            VERDICT="LINK_IDLE_NO_DBELL"
        fi
    elif [ "${M_CAL:-0}" = "1" ] && [ "${S_CAL:-0}" = "1" ]; then
        VERDICT="CAL_OK_FCSM_${M_FCSM}_${S_FCSM}"
    else
        VERDICT="CAL_FAIL_${M_CAL}_${S_CAL}"
    fi

    MAT_M_FCSM[$mp,$sp]=$M_FCSM; MAT_S_FCSM[$mp,$sp]=$S_FCSM
    MAT_M_POP[$mp,$sp]=$M_POP;   MAT_S_POP[$mp,$sp]=$S_POP
    MAT_M_CAL[$mp,$sp]=$M_CAL;   MAT_S_CAL[$mp,$sp]=$S_CAL
    MAT_DBELL[$mp,$sp]=$DRA_DELTA; MAT_VERDICT[$mp,$sp]=$VERDICT
    echo "$mp,$sp,$M_FCSM,$M_CAL,$M_POP,$M_LK,$M_FT,$S_FCSM,$S_CAL,$S_POP,$S_LK,$S_FT,$DRA_DELTA,$VERDICT" >> "$CSV"

    t1=$(date +%s)
    echo "  verdict=$VERDICT  (combo took $((t1-t0))s)"
  done
done

# ---------- Reports --------------------------------------------------------
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo
echo "================================================================"
echo " 4x4 MATRIX — FCSM (M/S) | dbell_delta"
echo "                  S_PHASE"
printf "  M_PHASE   "
for sp in $SP_LIST; do printf " %-10s" "sp=$sp"; done
echo
for mp in $MP_LIST; do
    printf "  mp=%-7s" "$mp"
    for sp in $SP_LIST; do
        mf=${MAT_M_FCSM[$mp,$sp]:-?}
        sf=${MAT_S_FCSM[$mp,$sp]:-?}
        db=${MAT_DBELL[$mp,$sp]:-?}
        printf " %-10s" "${mf}/${sf}|${db}"
    done
    echo
done

echo
echo " 4x4 MATRIX — verdict"
printf "  M_PHASE   "
for sp in $SP_LIST; do printf " %-22s" "sp=$sp"; done
echo
for mp in $MP_LIST; do
    printf "  mp=%-7s" "$mp"
    for sp in $SP_LIST; do
        printf " %-22s" "${MAT_VERDICT[$mp,$sp]:-?}"
    done
    echo
done

echo
echo " SUMMARY:"
echo "   combos run         : $COMBOS"
echo "   both FCSM=4 idle   : $LINK_IDLE_BOTH"
echo "   doorbells crossed  : $WINS"
echo "   elapsed            : ${ELAPSED}s"
echo "   csv                : $CSV"
echo "   logdir             : $LOGDIR"
echo "================================================================"

# Non-zero exit only if zero wins — caller can `if ./phase_sweep…; then …`.
if [ "$WINS" -gt 0 ]; then exit 0; else exit 1; fi

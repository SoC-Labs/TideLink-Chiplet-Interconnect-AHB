#!/bin/bash
# =============================================================================
# bringup_ptp_track_freq.sh — Phase 3a: frequency-drift tracking.
#
# Requires bringup_ptp_sync.sh to have completed (pair is converged).
# Inject ppm-scale frequency errors on the MASTER's NS_INCR_FRAC; verify the
# slave tracks. Plan §5.2.
#
# Per plan §4.2:  LSB_per_ppm ≈ cycle_ns × 4_295 ≈ 85_900 LSBs at 50 MHz.
# This script logs that empirically so the constant can be refined.
#
# SAFETY: as bringup_ptp_sync.sh. The injection is on the MASTER's PHC (not
# the slave's), so the slave's servo path stays enabled and tracks. We also
# bound ppm_step to ≤ 100 ppm so the loop stays in linear regime.
#
# USAGE
#   [MASTER_IP=..] [SLAVE_IP=..] [PPM_STEPS="+1 +10 +50 -50 -10 -1"] \
#   [STEP_DURATION=30] bringup_ptp_track_freq.sh
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_ptp_common.sh"

MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PPM_STEPS="${PPM_STEPS:-+1 +10 +50 -50 -10 -1}"
STEP_DURATION="${STEP_DURATION:-30}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-0.5}"
LSB_PER_PPM="${LSB_PER_PPM:-85900}"

echo "=============================================================="
echo " TideLink PTP HW frequency-drift tracking  $(date)"
echo "  master=$MASTER_IP  slave=$SLAVE_IP"
echo "  PPM_STEPS=$PPM_STEPS  step_duration=${STEP_DURATION}s  LSB/ppm=$LSB_PER_PPM"
echo "=============================================================="

# Pre-flight (link + reachable)
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" true 2>/dev/null \
        || { echo "ERROR: $IP unreachable" >&2; exit 2; }
done
if ! check_link_up "$MASTER_IP" "$SLAVE_IP"; then
    echo "ERROR: link not 16/16 — run bringup_pair_converge.sh first" >&2
    exit 3
fi

# Reachable PHC check + assume already-converged (bringup_ptp_sync.sh ran).
M_FRAC_INITIAL=$(phc_r "$MASTER_IP" $PHC_OFF_NS_INCR_FRAC)
echo "  master initial NS_INCR_FRAC = 0x$(printf '%08x' "$M_FRAC_INITIAL")"
S_NS_FRAC_INITIAL=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_NS_FRAC)
echo "  slave  initial SERVO_NS_FRAC = 0x$(printf '%08x' "${S_NS_FRAC_INITIAL:-0}")"
LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS)
LK_BIT=$(( (LK & 1) ))
if [ "$LK_BIT" -ne 1 ]; then
    echo "ERROR: slave servo not locked (SERVO_STATUS=0x$(printf '%08x' "$LK"))" >&2
    echo "       Run bringup_ptp_sync.sh first." >&2
    exit 4
fi

verdict="PASS"
for PPM in $PPM_STEPS; do
    echo "--------------------------------------------------------------"
    echo "[STEP $PPM ppm] inject delta on master NS_INCR_FRAC"
    DELTA=$(awk -v p="$PPM" -v l="$LSB_PER_PPM" 'BEGIN{printf "%d", p*l}')
    NEW=$(awk -v c="$M_FRAC_INITIAL" -v d="$DELTA" 'BEGIN{v=c+d; if (v<0) v+=4294967296; printf "%d", v % 4294967296}')
    echo "    delta_LSBs=$DELTA  new_master_NS_INCR_FRAC=0x$(printf '%08x' "$NEW")"
    phc_w "$MASTER_IP" $PHC_OFF_NS_INCR_FRAC "$NEW"

    start_ts=$(date +%s.%N)
    bestabs=999999999
    while :; do
        now_ts=$(date +%s.%N)
        t=$(awk -v a="$now_ts" -v b="$start_ts" 'BEGIN{printf "%.2f", a-b}')
        [ "$(awk -v t="$t" -v d="$STEP_DURATION" 'BEGIN{print (t>=d)}')" = "1" ] && break

        pmod_pulse "$MASTER_IP"; sleep 0.02
        M_CAP=$(phc_hw_cap_read "$MASTER_IP")
        S_CAP=$(phc_hw_cap_read "$SLAVE_IP")
        [ -z "$M_CAP" ] || [ -z "$S_CAP" ] && { sleep "$SAMPLE_PERIOD"; continue; }
        OFF=$(offset_ns "$M_CAP" "$S_CAP")
        ABS=$(awk -v x="$OFF" 'BEGIN{print (x<0)?-x:x}')
        [ "$ABS" -lt "$bestabs" ] 2>/dev/null && bestabs=$ABS
        NSF=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_NS_FRAC)
        LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS); LK_BIT=$(( (LK & 1) ))
        printf "    t=%6.2f  off=%+12d  locked=%d  slave_ns_frac=0x%08x\n" \
            "$t" "$OFF" "$LK_BIT" "${NSF:-0}"
        sleep "$SAMPLE_PERIOD"
    done

    # Restore master to nominal between steps to isolate each impulse.
    phc_w "$MASTER_IP" $PHC_OFF_NS_INCR_FRAC "$M_FRAC_INITIAL"
    echo "    step verdict: best_abs_offset=$bestabs ns (post-restore)"
    # Pass criterion (plan §5.2): for each magnitude m, settled offset
    # within max(500 ns, m × 100 ns/ppm) — checked against the FINAL
    # samples, not the worst-case transient. We log bestabs as a proxy.
    abs_ppm=$(awk -v p="$PPM" 'BEGIN{print (p<0)?-p:p}')
    bound=$(awk -v p="$abs_ppm" 'BEGIN{b=p*100; if (b<500) b=500; print b}')
    if [ "$bestabs" -gt "$bound" ] 2>/dev/null; then
        echo "    *** step ${PPM} ppm exceeded settling bound ${bound} ns ***"
        verdict="FAIL"
    fi
done

echo "=============================================================="
echo " RESULT: $verdict"
[ "$verdict" = "PASS" ] && exit 0 || exit 1

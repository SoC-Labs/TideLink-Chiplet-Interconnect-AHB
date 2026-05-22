#!/bin/bash
# =============================================================================
# bringup_ptp_track_offset.sh — Phase 3b: offset-step recovery.
#
# Requires bringup_ptp_sync.sh to have completed (pair is converged).
# Inject offset steps on the SLAVE's PHC; verify the servo recovers either
# via a phase step (|step| > STEP_THRESH=1 ms → SET_TIME) or freq-steer.
# Plan §5.3.
#
# Sequence per step (plan §4.3 safety):
#   1. Disable slave servo (apb_w SERVO_CTRL=0).
#   2. Read current PHC time on slave (CAPTURE pulse + CAP_* read).
#   3. Compute target = current + offset; write SET_*; pulse SET_TIME.
#   4. Re-enable slave servo (SERVO_CTRL = 0x3 = enable + Sub).
#   5. Sample HW_CAP diff every SAMPLE_PERIOD; pass when |off| < 200 ns.
#
# USAGE
#   [MASTER_IP=..] [SLAVE_IP=..] [STEPS="+1000 +1000000 -1000000 +500000000"] \
#   [RECOVERY_TIMEOUT=10] bringup_ptp_track_offset.sh
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
STEPS="${STEPS:-+1000 +1000000 -1000000 +500000000}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-10}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-0.25}"
PASS_OFFSET_NS="${PASS_OFFSET_NS:-200}"
STEP_THRESH_NS=1000000   # mirrors APB_OFF_SERVO_STEP_THRESH default

echo "=============================================================="
echo " TideLink PTP HW offset-step recovery  $(date)"
echo "  master=$MASTER_IP  slave=$SLAVE_IP"
echo "  STEPS=$STEPS  recovery_timeout=${RECOVERY_TIMEOUT}s"
echo "=============================================================="

# Pre-flight
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" true 2>/dev/null \
        || { echo "ERROR: $IP unreachable" >&2; exit 2; }
done
if ! check_link_up "$MASTER_IP" "$SLAVE_IP"; then
    echo "ERROR: link not 16/16 — run bringup_pair_converge.sh first" >&2
    exit 3
fi
LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS); LK_BIT=$(( (LK & 1) ))
if [ "$LK_BIT" -ne 1 ]; then
    echo "ERROR: slave servo not locked; run bringup_ptp_sync.sh first" >&2
    exit 4
fi

verdict="PASS"
for STEP in $STEPS; do
    echo "--------------------------------------------------------------"
    ABS_STEP=$(awk -v s="$STEP" 'BEGIN{print (s<0)?-s:s}')
    expected_path="freq_steer"
    [ "$ABS_STEP" -gt "$STEP_THRESH_NS" ] && expected_path="phase_step"
    bound=10
    if [ "$expected_path" = "phase_step" ]; then bound=1; fi
    echo "[STEP $STEP ns] expected recovery via $expected_path, bound ${bound}s"

    # Quiesce slave servo for the inject
    apb_w "$SLAVE_IP" $APB_OFF_SERVO_CTRL 0 >/dev/null

    # Snapshot current slave time
    SCAP=$(phc_sw_capture "$SLAVE_IP")
    cur_sec=$(echo "$SCAP" | awk '{print $1}')
    cur_ns=$(echo "$SCAP" | awk '{print $2}')
    echo "    current slave time: sec=$cur_sec ns=$cur_ns"

    # Compute target seconds + nanoseconds with rollover
    NS_PER_SEC=1000000000
    target_ns=$(awk -v c="$cur_ns" -v s="$STEP" -v n="$NS_PER_SEC" \
        'BEGIN{t=c+s; while (t<0) t+=n; print t%n}')
    target_sec=$(awk -v c="$cur_sec" -v cn="$cur_ns" -v s="$STEP" -v n="$NS_PER_SEC" \
        'BEGIN{t=cn+s; d=int(t/n); if (t<0 && t%n!=0) d-=1; print c+d}')
    target_sec_lo=$(( target_sec & 0xffffffff ))
    target_sec_hi=$(( (target_sec >> 32) & 0xffff ))
    echo "    target slave time: sec=$target_sec ns=$target_ns"

    # Inject the offset
    phc_w "$SLAVE_IP" $PHC_OFF_SET_SECONDS_LO  "$target_sec_lo" >/dev/null
    phc_w "$SLAVE_IP" $PHC_OFF_SET_SECONDS_HI  "$target_sec_hi" >/dev/null
    phc_w "$SLAVE_IP" $PHC_OFF_SET_NANOSECONDS "$target_ns"     >/dev/null
    # CTRL.SET_TIME single-pulse; keep CTRL.EN asserted
    phc_w "$SLAVE_IP" $PHC_OFF_CTRL $(( PHC_CTRL_EN | PHC_CTRL_SET_TIME )) >/dev/null
    phc_w "$SLAVE_IP" $PHC_OFF_CTRL $PHC_CTRL_EN >/dev/null

    # Re-arm slave servo
    apb_w "$SLAVE_IP" $APB_OFF_SERVO_CTRL 3 >/dev/null  # enable + Sub mode

    # Sample recovery
    start_ts=$(date +%s.%N)
    recovered="NO"
    while :; do
        now_ts=$(date +%s.%N)
        t=$(awk -v a="$now_ts" -v b="$start_ts" 'BEGIN{printf "%.2f", a-b}')
        [ "$(awk -v t="$t" -v d="$RECOVERY_TIMEOUT" 'BEGIN{print (t>=d)}')" = "1" ] && break

        pmod_pulse "$MASTER_IP"; sleep 0.02
        M_CAP=$(phc_hw_cap_read "$MASTER_IP")
        S_CAP=$(phc_hw_cap_read "$SLAVE_IP")
        [ -z "$M_CAP" ] || [ -z "$S_CAP" ] && { sleep "$SAMPLE_PERIOD"; continue; }
        OFF=$(offset_ns "$M_CAP" "$S_CAP")
        ABS=$(awk -v x="$OFF" 'BEGIN{print (x<0)?-x:x}')
        LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS); LK_BIT=$(( (LK & 1) )); PSA=$(( (LK >> 1) & 1 ))
        printf "    t=%6.2f  off=%+12d  locked=%d  phase_step_active=%d\n" \
            "$t" "$OFF" "$LK_BIT" "$PSA"
        if [ "$LK_BIT" -eq 1 ] && [ "$ABS" -lt "$PASS_OFFSET_NS" ] 2>/dev/null; then
            recovered="YES"
            break
        fi
        sleep "$SAMPLE_PERIOD"
    done
    settle_t=$t
    echo "    step $STEP ns: recovered=$recovered settle_t=${settle_t}s expected_bound=${bound}s"
    if [ "$recovered" != "YES" ]; then
        echo "    *** step did NOT recover within ${RECOVERY_TIMEOUT}s ***"
        verdict="FAIL"
    fi
done

echo "=============================================================="
echo " RESULT: $verdict"
[ "$verdict" = "PASS" ] && exit 0 || exit 1

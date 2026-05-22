#!/bin/bash
# =============================================================================
# bringup_ptp_soak.sh — Phase 4: multi-hour soak + recovery characterisation.
#
# Logs offset / locked / lane_status every SAMPLE_INTERVAL seconds to a CSV.
# Optionally injects random perturbations (offset steps or freq drifts) at
# rate INJECT_PROB. After completion summarises mean / 99th-%ile / lock
# stability.
#
# Pass criteria (plan §6):
#   * Mean |offset| over the soak < 300 ns
#   * 99th-%ile |offset| < 2 µs
#   * No lane_locked degradation during the run
#
# SAFETY: never writes AHB_TX. Each iteration verifies the SSH session is
# still up before sampling; on failure the script aborts gracefully.
#
# USAGE
#   [MASTER_IP=..] [SLAVE_IP=..] [SOAK_HOURS=4] [SAMPLE_INTERVAL=5] \
#   [INJECT_PROB=0] [CSV_PATH=/tmp/ptp_soak.csv] bringup_ptp_soak.sh
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
SOAK_HOURS="${SOAK_HOURS:-4}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
INJECT_PROB="${INJECT_PROB:-0}"
CSV_PATH="${CSV_PATH:-/tmp/ptp_soak_$(date +%Y%m%d_%H%M%S).csv}"
PASS_MEAN_NS="${PASS_MEAN_NS:-300}"
PASS_P99_NS="${PASS_P99_NS:-2000}"

DURATION_S=$(( SOAK_HOURS * 3600 ))

echo "=============================================================="
echo " TideLink PTP HW soak  $(date)"
echo "  master=$MASTER_IP  slave=$SLAVE_IP"
echo "  soak=${SOAK_HOURS}h  sample_interval=${SAMPLE_INTERVAL}s"
echo "  inject_prob=$INJECT_PROB  csv=$CSV_PATH"
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

echo "ts_unix,offset_ns,locked,phase_step_active,lane_locked_m,lane_locked_s,inject_event" > "$CSV_PATH"

start_ts=$(date +%s)
inject_count=0
last_ssh_ok_ts=$start_ts
while :; do
    now_ts=$(date +%s)
    elapsed=$(( now_ts - start_ts ))
    [ "$elapsed" -ge "$DURATION_S" ] && break

    # SSH health check every iteration — abort if either side dies
    if ! sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$MASTER_IP" true 2>/dev/null \
       || ! sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$SLAVE_IP" true 2>/dev/null; then
        echo "ABORT: lost SSH to one of the boards at t=${elapsed}s" >&2
        break
    fi
    last_ssh_ok_ts=$now_ts

    pmod_pulse "$MASTER_IP"; sleep 0.02
    M_CAP=$(phc_hw_cap_read "$MASTER_IP")
    S_CAP=$(phc_hw_cap_read "$SLAVE_IP")
    if [ -z "$M_CAP" ] || [ -z "$S_CAP" ]; then
        sleep "$SAMPLE_INTERVAL"; continue
    fi
    OFF=$(offset_ns "$M_CAP" "$S_CAP")
    LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS); LK_BIT=$(( (LK & 1) )); PSA=$(( (LK >> 1) & 1 ))
    M_LANE=$(remote_r "$MASTER_IP" "$(( APB_BASE + 0x2000 + SWI_LANE_STATUS_OFF ))")
    S_LANE=$(remote_r "$SLAVE_IP"  "$(( APB_BASE + 0x2000 + SWI_LANE_STATUS_OFF ))")
    M_LK=$(( (M_LANE & 0xff) ))
    S_LK=$(( (S_LANE & 0xff) ))

    # Optional injection (probability per sample)
    event=""
    if [ "$INJECT_PROB" != "0" ]; then
        R=$(awk -v p="$INJECT_PROB" 'BEGIN{srand(); print (rand()<p)?1:0}')
        if [ "$R" = "1" ]; then
            CHOICE=$(awk 'BEGIN{srand(); print int(rand()*2)}')
            if [ "$CHOICE" = "0" ]; then
                # Offset step on slave: random in ±50 ms
                STEP=$(awk 'BEGIN{srand(); s=int(rand()*100000000)-50000000; print s}')
                event="off_step_${STEP}ns"
                # Disable servo, inject, re-enable (mirrors track_offset)
                apb_w "$SLAVE_IP" $APB_OFF_SERVO_CTRL 0 >/dev/null
                SCAP=$(phc_sw_capture "$SLAVE_IP")
                cur_sec=$(echo "$SCAP" | awk '{print $1}')
                cur_ns=$(echo "$SCAP" | awk '{print $2}')
                NS_PER_SEC=1000000000
                target_ns=$(awk -v c="$cur_ns" -v s="$STEP" -v n="$NS_PER_SEC" \
                    'BEGIN{t=c+s; while (t<0) t+=n; print t%n}')
                target_sec=$(awk -v c="$cur_sec" -v cn="$cur_ns" -v s="$STEP" -v n="$NS_PER_SEC" \
                    'BEGIN{t=cn+s; d=int(t/n); if (t<0 && t%n!=0) d-=1; print c+d}')
                phc_w "$SLAVE_IP" $PHC_OFF_SET_SECONDS_LO  "$(( target_sec & 0xffffffff ))" >/dev/null
                phc_w "$SLAVE_IP" $PHC_OFF_SET_SECONDS_HI  "$(( (target_sec>>32) & 0xffff ))" >/dev/null
                phc_w "$SLAVE_IP" $PHC_OFF_SET_NANOSECONDS "$target_ns" >/dev/null
                phc_w "$SLAVE_IP" $PHC_OFF_CTRL $(( PHC_CTRL_EN | PHC_CTRL_SET_TIME )) >/dev/null
                phc_w "$SLAVE_IP" $PHC_OFF_CTRL $PHC_CTRL_EN >/dev/null
                apb_w "$SLAVE_IP" $APB_OFF_SERVO_CTRL 3 >/dev/null
            else
                # Freq drift on master: random in ±20 ppm
                PPM=$(awk 'BEGIN{srand(); print int(rand()*40)-20}')
                event="freq_${PPM}ppm"
                DELTA=$(awk -v p="$PPM" 'BEGIN{printf "%d", p*85900}')
                CUR=$(phc_r "$MASTER_IP" $PHC_OFF_NS_INCR_FRAC)
                NEW=$(awk -v c="$CUR" -v d="$DELTA" 'BEGIN{v=c+d; if (v<0) v+=4294967296; print v%4294967296}')
                phc_w "$MASTER_IP" $PHC_OFF_NS_INCR_FRAC "$NEW" >/dev/null
            fi
            inject_count=$(( inject_count + 1 ))
        fi
    fi

    printf "%d,%s,%d,%d,0x%02x,0x%02x,%s\n" "$now_ts" "$OFF" "$LK_BIT" "$PSA" "$M_LK" "$S_LK" "$event" \
        >> "$CSV_PATH"

    # Progress every minute
    if [ $(( elapsed % 60 )) -lt "$SAMPLE_INTERVAL" ]; then
        echo "  [${elapsed}s / ${DURATION_S}s] last_off=$OFF ns  locked=$LK_BIT  injects=$inject_count"
    fi
    sleep "$SAMPLE_INTERVAL"
done

echo "=============================================================="
echo " Soak complete. Analysing $CSV_PATH …"

# Summary statistics
SUMMARY=$(awk -F',' 'NR>1 {
    abs = ($2<0)?-$2:$2;
    sum += abs; n++; arr[NR-1] = abs;
    if (!$3) locked0++;
    if (last_m != "" && last_m != $5) lane_evt++;
    if (last_s != "" && last_s != $6) lane_evt++;
    last_m = $5; last_s = $6;
}
END {
    if (n == 0) { print "no_samples"; exit }
    mean = sum / n;
    # Sort for 99th percentile
    asort(arr);
    p99_idx = int(0.99 * n); if (p99_idx < 1) p99_idx = 1;
    p99 = arr[p99_idx];
    printf "%d %.0f %d %d %d", n, mean, p99, locked0+0, lane_evt+0;
}' "$CSV_PATH")

N=$(echo "$SUMMARY" | awk '{print $1}')
MEAN=$(echo "$SUMMARY" | awk '{print $2}')
P99=$(echo "$SUMMARY" | awk '{print $3}')
LOCK0=$(echo "$SUMMARY" | awk '{print $4}')
LANE_EVT=$(echo "$SUMMARY" | awk '{print $5}')

echo "  samples = $N"
echo "  mean |offset|   = $MEAN ns  (target < $PASS_MEAN_NS)"
echo "  99th-%ile |off|= $P99 ns  (target < $PASS_P99_NS)"
echo "  locked=0 count = $LOCK0"
echo "  lane_locked change events = $LANE_EVT"

verdict="PASS"
[ "${MEAN:-99999}" -gt "$PASS_MEAN_NS" ] 2>/dev/null && verdict="FAIL"
[ "${P99:-99999}"  -gt "$PASS_P99_NS"  ] 2>/dev/null && verdict="FAIL"
[ "${LANE_EVT:-0}" -gt 0 ]               2>/dev/null && verdict="FAIL"

echo " RESULT: $verdict"
[ "$verdict" = "PASS" ] && exit 0 || exit 1

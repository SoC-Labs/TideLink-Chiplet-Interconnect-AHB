#!/bin/bash
# =============================================================================
# bringup_ptp_sync.sh — Phase 2: initial PHC sync + convergence measurement.
#
# WHAT IT DOES
#   1. Pre-flight: verify both boards reachable; verify link 16/16 + cal_done.
#   2. Quiesce: disable autonomous servo on both sides.
#   3. Programme each PHC: NS_INCR=20 (50 MHz), distinct initial sec values
#      (master=100, slave=200 → 100 s skew).
#   4. Baseline pulse on PMOD-B trigger, read both PHCs' HW_CAP, log delta.
#   5. Enable PTP RX on both, configure HW_SYNC_INTERVAL=128 Hz for fast
#      acquisition, configure servo (master=GM, slave=Sub) with the chain-
#      test gains, enable HW_SYNC initiator on master only.
#   6. Convergence loop: every 250 ms pulse trigger, read both PHCs, compute
#      offset, read SERVO_STATUS.locked. Pass when locked==1 AND
#      |offset| < 100 ns for 10 consecutive samples.
#
# PASS / FAIL — set by §6 of docs/PTP_HW_TEST_PLAN.md:
#   PASS: SERVO_STATUS.locked asserts within 5 s of enable; sustained
#         |offset| < 500 ns; residual 1-σ < 200 ns over 100 samples.
#
# SAFETY
#   Never writes AHB_TX (0x4400_0000). Gates on link-up-first (check_link_up).
#   PTP TX (0x4402_0000) is intentionally NOT used by this script — the
#   autonomous HW sync initiator at 0x4040 originates SYNC from the FC
#   adapter directly, no AHB write involved.
#
# USAGE
#   [MASTER_IP=192.168.4.101] [SLAVE_IP=192.168.6.101] \
#   [DURATION=60] [SAMPLE_PERIOD=0.25] \
#   bringup_ptp_sync.sh
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
DURATION="${DURATION:-60}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-0.25}"

# Convergence gates (plan §6)
OFFSET_OK_NS="${OFFSET_OK_NS:-500}"
LOCK_HOLD="${LOCK_HOLD:-10}"

echo "=============================================================="
echo " TideLink PTP HW sync — initial convergence  $(date)"
echo "  master=$MASTER_IP  slave=$SLAVE_IP"
echo "  PHC_BASE=$PHC_BASE  APB_BASE=$APB_BASE  PMOD_TRIG_BASE=$PMOD_TRIG_BASE"
echo "  duration=${DURATION}s sample_period=${SAMPLE_PERIOD}s"
echo "=============================================================="

# Pre-flight 1: SSH reach
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" true 2>/dev/null \
        || { echo "ERROR: $IP unreachable" >&2; exit 2; }
done

# Pre-flight 2: link 16/16 + cal_done (link-up-first)
if ! check_link_up "$MASTER_IP" "$SLAVE_IP"; then
    echo "ERROR: link is not 16/16 + cal_done both sides — run bringup_pair_converge.sh first" >&2
    exit 3
fi

# 1. Quiesce
echo "[1] Quiescing autonomous servo + HW_SYNC on both boards"
quiesce_servo "$MASTER_IP"
quiesce_servo "$SLAVE_IP"

# 2. Programme PHCs with distinct initial times
echo "[2] Programming PHCs (NS_INCR=20, master=100 s, slave=200 s)"
phc_init_50mhz "$MASTER_IP" 100
phc_init_50mhz "$SLAVE_IP"  200

# 3. Baseline trigger + read
echo "[3] Baseline trigger + PHC HW_CAP read"
pmod_pulse "$MASTER_IP"
sleep 0.1
M_CAP=$(phc_hw_cap_read "$MASTER_IP")
S_CAP=$(phc_hw_cap_read "$SLAVE_IP")
echo "    master HW_CAP: $M_CAP"
echo "    slave  HW_CAP: $S_CAP"
OFF=$(offset_ns "$M_CAP" "$S_CAP")
echo "    baseline offset (slave - master) = $OFF ns  (expect ~+100 s)"

# 4. Enable PTP + configure servo
echo "[4] Enable PTP, configure servo (GM/Sub), set sync interval 128 Hz"
apb_w "$MASTER_IP" $APB_OFF_PTP_CTRL          1            >/dev/null  # PTP RX enable
apb_w "$SLAVE_IP"  $APB_OFF_PTP_CTRL          1            >/dev/null
apb_w "$MASTER_IP" $APB_OFF_HW_SYNC_INTERVAL  7812500      >/dev/null  # 128 Hz
apb_w "$SLAVE_IP"  $APB_OFF_HW_SYNC_INTERVAL  7812500      >/dev/null

# Master servo: GM mode (mode=0) + enable
apb_w "$MASTER_IP" $APB_OFF_SERVO_CTRL        1            >/dev/null
# Slave servo: Sub mode (mode=1) + enable
apb_w "$SLAVE_IP"  $APB_OFF_SERVO_CTRL        3            >/dev/null
apb_w "$SLAVE_IP"  $APB_OFF_SERVO_KP          134217728    >/dev/null  # 0x0800_0000
apb_w "$SLAVE_IP"  $APB_OFF_SERVO_KI          8388608      >/dev/null  # 0x0080_0000
apb_w "$SLAVE_IP"  $APB_OFF_SERVO_STEP_THRESH 1000000      >/dev/null  # 1 ms

# 5. Start HW sync initiator on master
echo "[5] Starting HW_SYNC initiator on master"
apb_w "$MASTER_IP" $APB_OFF_HW_SYNC_CTRL      1            >/dev/null

# 6. Convergence loop
echo "[6] Convergence loop (up to ${DURATION}s)"
echo "    t=time(s) off=|slave-master| ns  locked  delay(ns)  ns_frac(slave)"
locked_streak=0
verdict="FAIL"
start_ts=$(date +%s.%N)
last_log_ts=$start_ts
while :; do
    now_ts=$(date +%s.%N)
    t=$(awk -v a="$now_ts" -v b="$start_ts" 'BEGIN{printf "%.2f", a-b}')
    [ "$(awk -v t="$t" -v d="$DURATION" 'BEGIN{print (t>=d)}')" = "1" ] && break

    pmod_pulse "$MASTER_IP"
    sleep 0.02
    M_CAP=$(phc_hw_cap_read "$MASTER_IP")
    S_CAP=$(phc_hw_cap_read "$SLAVE_IP")
    [ -z "$M_CAP" ] || [ -z "$S_CAP" ] && { sleep "$SAMPLE_PERIOD"; continue; }
    OFF=$(offset_ns "$M_CAP" "$S_CAP")
    ABS=$(awk -v x="$OFF" 'BEGIN{print (x<0)?-x:x}')
    LK=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_STATUS)
    LK_BIT=$(( (LK & 1) ))
    DLY=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_DELAY)
    NSF=$(apb_r "$SLAVE_IP" $APB_OFF_SERVO_NS_FRAC)

    printf "    t=%6.2f  off=%+12d  locked=%d  delay=%s  ns_frac=%s\n" \
        "$t" "$OFF" "$LK_BIT" "${DLY:-?}" "${NSF:-?}"

    if [ "$LK_BIT" -eq 1 ] && [ "$(awk -v a="$ABS" -v t="$OFFSET_OK_NS" 'BEGIN{print (a<t)}')" = "1" ]; then
        locked_streak=$(( locked_streak + 1 ))
        if [ "$locked_streak" -ge "$LOCK_HOLD" ]; then
            verdict="PASS"
            break
        fi
    else
        locked_streak=0
    fi
    sleep "$SAMPLE_PERIOD"
done

echo "=============================================================="
echo " RESULT: $verdict  (locked_streak=$locked_streak / required $LOCK_HOLD)"
if [ "$verdict" = "PASS" ]; then
    echo "  Converged: |slave-master| < ${OFFSET_OK_NS} ns for $LOCK_HOLD consecutive samples"
    exit 0
fi
echo "  Did NOT converge within ${DURATION}s."
echo "  Diagnostics:"
echo "    HW_SYNC_STATUS (master): 0x$(printf '%08x' "$(apb_r "$MASTER_IP" $APB_OFF_HW_SYNC_STATUS)")"
echo "    HW_SYNC_STATUS (slave):  0x$(printf '%08x' "$(apb_r "$SLAVE_IP"  $APB_OFF_HW_SYNC_STATUS)")"
echo "    SERVO_STATUS   (slave):  0x$(printf '%08x' "$(apb_r "$SLAVE_IP"  $APB_OFF_SERVO_STATUS)")"
exit 1

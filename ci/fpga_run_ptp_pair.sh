#!/usr/bin/env bash
# =============================================================================
# fpga_run_ptp_pair.sh — Run the four bringup_ptp_*.sh scripts on the bridge1
# pair via an fpgahub background lease. Mirrors fpga_run_pair.sh's lease /
# revoke / retry machinery so the PTP campaign can preempt cleanly when an
# interactive developer acquires the chassis.
#
# Pre-conditions enforced before running the scripts:
#   1. Lease GRANTED on $FPGAHUB_PAIR_CHASSIS (default pynq_z2_02).
#   2. bringup_pair_converge.sh succeeds (16/16 + cal_done both sides).
#   3. PHC-in-BD bitstream is deployed (operator's responsibility —
#      this script does NOT acquire the build/deploy lease).
#
# The four scripts run sequentially; a failure in any aborts the rest
# (the chain depends on convergence of the previous step). All output is
# captured under $LOG_DIR ($PWD/fpga/ci_logs/ptp).
#
# SAFETY: never writes AHB_TX. Each script gates on link-up-first.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -euo pipefail

CHASSIS="${FPGAHUB_PAIR_CHASSIS:-pynq_z2_02}"
TTL_S="${FPGAHUB_LEASE_TTL_S:-10800}"
WAIT_S="${FPGAHUB_LEASE_WAIT_S:-10800}"
MAX_REVOKES="${FPGAHUB_MAX_REVOKES:-3}"
FPGAHUB="${FPGAHUB_BIN:-fpgahub}"
PIPELINE_ID="${CI_PIPELINE_ID:-local}"
JOB_ID="${CI_JOB_ID:-$$}"
HOLDER="gitlab-ci-ptp-${PIPELINE_ID}-${JOB_ID}"

LOG_DIR="${FPGA_CI_LOG_DIR:-fpga/ci_logs/ptp}"
mkdir -p "$LOG_DIR"

# Script overrides exposed to the GitLab variables UI
PTP_SOAK_HOURS="${PTP_SOAK_HOURS:-1}"
PTP_DURATION="${PTP_DURATION:-60}"

# Board IPs — defaults match the bridge1 chassis.
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"

log() { printf '[fpga-ci-ptp %(%H:%M:%S)T] %s\n' -1 "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || { log "missing dependency: $1"; exit 2; }
}
require "$FPGAHUB"
require jq
require sshpass

TOKEN=""
release_lease() {
    if [ -n "${TOKEN:-}" ]; then
        log "releasing chassis lease"
        "$FPGAHUB" chassis lease release "$CHASSIS" \
            --token "$TOKEN" --holder "$HOLDER" \
            >/dev/null 2>&1 || true
    fi
}
trap release_lease EXIT INT TERM

log "acquiring chassis $CHASSIS as holder=$HOLDER tier=background (ttl=${TTL_S}s)"
RAW=$("$FPGAHUB" chassis lease acquire "$CHASSIS" \
        --tier background --requeue-on-revoke \
        --holder "$HOLDER" --user gitlab-ci \
        --ttl "$TTL_S" --json)
KIND=$(jq -r '.kind // "unknown"' <<<"$RAW")
case "$KIND" in
    granted)
        TOKEN=$(jq -r .token <<<"$RAW")
        log "lease granted token=${TOKEN:0:8}…"
        ;;
    queued)
        log "queued at bg position $(jq -r .position <<<"$RAW")"
        deadline=$(( $(date +%s) + WAIT_S ))
        while :; do
            sleep 15
            if [ "$(date +%s)" -ge "$deadline" ]; then
                log "gave up after ${WAIT_S}s waiting for grant"
                "$FPGAHUB" chassis lease cancel "$CHASSIS" --holder "$HOLDER" \
                    >/dev/null 2>&1 || true
                exit 75
            fi
            RAW=$("$FPGAHUB" chassis lease acquire "$CHASSIS" \
                    --tier background --requeue-on-revoke \
                    --holder "$HOLDER" --user gitlab-ci \
                    --ttl "$TTL_S" --json)
            if [ "$(jq -r '.kind // "unknown"' <<<"$RAW")" = "granted" ]; then
                TOKEN=$(jq -r .token <<<"$RAW")
                log "lease granted token=${TOKEN:0:8}…"
                break
            fi
        done
        ;;
    *)
        log "unexpected acquire response: $RAW"; exit 1 ;;
esac

# Heartbeat (same pattern as fpga_run_pair.sh)
heartbeat_loop() {
    interval=$(( TTL_S / 3 ))
    [ "$interval" -lt 60 ] && interval=60
    while sleep "$interval"; do
        "$FPGAHUB" chassis lease heartbeat "$CHASSIS" \
            --token "$TOKEN" --holder "$HOLDER" --ttl "$TTL_S" \
            >/dev/null 2>&1 || true
    done
}
heartbeat_loop &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true; release_lease' EXIT INT TERM

# Wait for token to actually hold the chassis.
log "waiting for lease wait to confirm grant"
"$FPGAHUB" chassis lease wait "$CHASSIS" --token "$TOKEN" --timeout 600 >/dev/null \
    || { log "lease wait timed out"; exit 75; }

# ------------------------------------------------------------------------
# Run the four scripts in order. Each gates on link-up-first internally.
# ------------------------------------------------------------------------
PHC_SCRIPTS_DIR="$(dirname "$0")/../pynq_host/scripts"
overall_rc=0
runs=("bringup_ptp_sync.sh" "bringup_ptp_track_freq.sh" "bringup_ptp_track_offset.sh" "bringup_ptp_soak.sh")

export MASTER_IP SLAVE_IP

for SCRIPT in "${runs[@]}"; do
    case "$SCRIPT" in
        bringup_ptp_soak.sh)
            export SOAK_HOURS="$PTP_SOAK_HOURS"
            ;;
        bringup_ptp_sync.sh)
            export DURATION="$PTP_DURATION"
            ;;
    esac
    log "running $SCRIPT"
    set +e
    bash "$PHC_SCRIPTS_DIR/$SCRIPT" > "$LOG_DIR/${SCRIPT%.sh}.log" 2>&1
    rc=$?
    set -e
    log "  $SCRIPT rc=$rc"
    if [ "$rc" -ne 0 ]; then
        overall_rc=$rc
        log "ABORT chain at $SCRIPT (subsequent scripts depend on prior convergence)"
        break
    fi
done

# Summary
{
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    echo "<testsuites>"
    for SCRIPT in "${runs[@]}"; do
        name="${SCRIPT%.sh}"
        if [ -f "$LOG_DIR/${name}.log" ]; then
            # Pull the final RESULT line if present
            verdict=$(grep -E "^ RESULT:" "$LOG_DIR/${name}.log" | tail -1 | awk '{print $2}')
            if [ "$verdict" = "PASS" ]; then
                echo "  <testsuite name=\"$name\" tests=\"1\" failures=\"0\"><testcase name=\"$name\"/></testsuite>"
            else
                echo "  <testsuite name=\"$name\" tests=\"1\" failures=\"1\"><testcase name=\"$name\"><failure message=\"verdict=${verdict:-?}\"/></testcase></testsuite>"
            fi
        fi
    done
    echo "</testsuites>"
} > "$LOG_DIR/results.xml"

exit "$overall_rc"

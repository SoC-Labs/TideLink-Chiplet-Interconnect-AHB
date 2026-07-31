#!/usr/bin/env bash
# =============================================================================
# por_recover.sh — recover ONE KR260 board via JTAG-POR, flock-serialised,
#                  bounded retries, PARK after MAX_POR (never infinite-spin).
#
# Recovery on the eth-chiplet is **JTAG-POR ONLY** — a wedged PS AXI bus (100%
# packet loss, no software timeout) is only cleared by a JTAG power-on-reset
# issued through the fpgahub kr260_jtag_por plugin. NEVER `sudo reboot` (the PS
# is unreachable when wedged, and a reboot does not re-init the PL config TAP).
#
# The JTAG POR is a shared, one-at-a-time resource (single cable/daemon), so the
# actual POR issue is serialised behind a global flock; the (longer) ping/ssh
# wait afterwards runs unlocked so both boards can re-home their networking in
# parallel. On the transient "cable-not-found" skew we retry the issue CABLE_RETRY
# times. After MAX_POR failed full cycles the board is PARKED: an ALERT_<target>.txt
# marker is written into OUT/ and we exit non-zero. The outer driver aborts the
# whole campaign only when BOTH boards are parked.
#
#   usage:  por_recover.sh <kr260_01|kr260_02>
#
# Env:
#   OUT           campaign output dir for ALERT_/PARK markers (default: cwd)
#   POR_SSH       host that owns /run/fpgahub/fpgahub.sock (default mapstone-dev;
#                 set empty to curl the local socket directly when run ON that host)
#   POR_LOCK      global flock path (default /tmp/kr260_eth_por.lock)
#   MAX_POR       full POR cycles before PARK (default 3)
#   CABLE_RETRY   retries of a single POR issue on "cable-not-found" (default 3)
#   PING_WAIT     seconds to wait for ping after a POR (default 150)
#   SSH_WAIT      seconds to wait for ssh-up after ping (default 120)
#   KR260_PASSWORD board ssh password (default soclabs2026)
#   KR260_USER    board login user (default ubuntu)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

TARGET=${1:-}
case "$TARGET" in
    kr260_01|kr260_02) ;;
    *) echo "por_recover: usage: $0 <kr260_01|kr260_02>" >&2; exit 2 ;;
esac

OUT=${OUT:-$(pwd)}
POR_SSH=${POR_SSH-mapstone-dev}
POR_LOCK=${POR_LOCK:-/tmp/kr260_eth_por.lock}
MAX_POR=${MAX_POR:-3}
CABLE_RETRY=${CABLE_RETRY:-3}
PING_WAIT=${PING_WAIT:-150}
SSH_WAIT=${SSH_WAIT:-120}
PW=${KR260_PASSWORD:-soclabs2026}
KR260_USER=${KR260_USER:-ubuntu}

# physical board <-> IP (fixed; POR always operates on the physical board)
case "$TARGET" in
    kr260_01) IP=10.22.24.159 ;;
    kr260_02) IP=10.22.24.153 ;;
esac

log() { echo "[por_recover $TARGET $(date +%H:%M:%S)] $*"; }

# --- issue one JTAG POR (flock-serialised, cable-not-found retried) ----------
por_issue() {
    # returns 0 if the daemon reported the POR issued, 1 otherwise
    local body='{"method":"default","confirm":true}'
    local url="http://localhost/api/v1/targets/$TARGET/reset"
    local curl_cmd="curl -s --max-time 30 --unix-socket /run/fpgahub/fpgahub.sock -X POST $url -H 'Content-Type: application/json' -d '$body'"
    local attempt out
    for attempt in $(seq 1 "$CABLE_RETRY"); do
        # serialise the JTAG operation itself behind the global lock
        out=$(
            flock 9
            if [ -n "$POR_SSH" ]; then
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$POR_SSH" "$curl_cmd" 2>&1
            else
                bash -c "$curl_cmd" 2>&1
            fi
        ) 9>"$POR_LOCK"
        if printf '%s' "$out" | grep -qi "POR issued\|\"ok\"[: ]*true\|\"status\"[: ]*\"ok\""; then
            log "POR issued (attempt $attempt): $(printf '%s' "$out" | head -c160)"
            return 0
        fi
        if printf '%s' "$out" | grep -qi "cable.*not.*found\|no cable\|cable_not_found"; then
            log "transient cable-not-found (attempt $attempt/$CABLE_RETRY); retrying"
            sleep 5
            continue
        fi
        log "POR issue unexpected response (attempt $attempt): $(printf '%s' "$out" | head -c200)"
        sleep 3
    done
    return 1
}

# --- bounded wait for the board to come back --------------------------------
wait_ping() {
    local t0 now
    t0=$(date +%s)
    while :; do
        if ping -c1 -W2 "$IP" >/dev/null 2>&1; then return 0; fi
        now=$(date +%s)
        [ $((now - t0)) -ge "$PING_WAIT" ] && return 1
        sleep 3
    done
}

wait_ssh() {
    local t0 now
    t0=$(date +%s)
    while :; do
        if sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
                "$KR260_USER@$IP" true >/dev/null 2>&1; then
            return 0
        fi
        now=$(date +%s)
        [ $((now - t0)) -ge "$SSH_WAIT" ] && return 1
        sleep 4
    done
}

park() {
    local alert="$OUT/ALERT_${TARGET}.txt"
    {
        echo "PARKED $TARGET ($IP) at $(date -Iseconds)"
        echo "Reason: JTAG-POR recovery failed after MAX_POR=$MAX_POR cycles."
        echo "Board left powered but marked bad. Manual bench attention required:"
        echo "  1. Check the fpgahub JTAG cable / kr260_jtag_por plugin on $POR_SSH."
        echo "  2. Manual POR: ssh $POR_SSH 'fpgahub board reset $TARGET --yes'"
        echo "  3. Remove this file once the board is healthy to un-park."
    } > "$alert"
    touch "$OUT/PARK_${TARGET}"
    log "PARKED — wrote $alert"
}

# --- main POR cycle ---------------------------------------------------------
# Clear any stale park marker for this target; we are actively recovering it.
rm -f "$OUT/PARK_${TARGET}" "$OUT/ALERT_${TARGET}.txt" 2>/dev/null || true

cycle=0
while [ "$cycle" -lt "$MAX_POR" ]; do
    cycle=$((cycle + 1))
    log "POR cycle $cycle/$MAX_POR"
    if ! por_issue; then
        log "POR issue failed this cycle"
        continue
    fi
    if ! wait_ping; then
        log "no ping within ${PING_WAIT}s after POR"
        continue
    fi
    log "ping OK; waiting for ssh"
    if ! wait_ssh; then
        log "no ssh within ${SSH_WAIT}s after ping"
        continue
    fi
    log "RECOVERED (ping+ssh up)"
    exit 0
done

park
exit 3

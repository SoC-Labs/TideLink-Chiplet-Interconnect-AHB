#!/usr/bin/env bash
# =============================================================================
# weekend_campaign.sh — autonomous weekend soak-CI driver for the KR260
#                       eth-chiplet two-board pair. Detached outer loop.
#
# Meant to be launched detached on mapstone-dev (the host that owns the fpgahub
# socket + reaches both boards):
#
#     setsid nohup env BUDGET_H=58 KR260_PASSWORD=<board-password> \
#         bash weekend_campaign.sh > weekend.boot.log 2>&1 &
#
# Per iteration (seed = BASE_SEED + iter, fully reproducible):
#   POR both dies  ->  deploy per role_map  ->  bringup_pair_release.sh (fcsm=4
#   both, else NOCONVERGE + POR + continue)  ->  campaign_iter.py (appends its
#   JSONL result line)  ->  dashboard.py rewrite.
#
# SAFETY (baked in):
#   - Bring-up ONLY on freshly-POR'd + reflashed dies (never re-bring-up a live
#     link — that desyncs it and wedges the sender).
#   - Teardown between iterations = JTAG-POR (por_recover.sh), never sudo reboot.
#   - Every peer/data access is inside campaign_iter.py, subprocess-timeout-wrapped
#     (a hang == wedge).  The driver's own board calls (deploy/bringup) are
#     `timeout`-wrapped too.
#   - Leases acquired up front + kept alive; released on exit.
#   - Clean stop:  touch OUT/STOP  (finishes the current iter, then exits).
#   - Hard abort ONLY when BOTH boards are PARKED (por_recover exhausted MAX_POR).
#
# Env:
#   BUDGET_H        wall budget in hours (default 58)
#   BASE_SEED       first seed (default 1); iteration N uses BASE_SEED+N
#   OUT             output dir (default runs/weekend_<ts> under this script dir)
#   KR260_PASSWORD  board password (REQUIRED; no default)
#   KR260_DIEA_IP / KR260_DIEB_IP   board IPs (default .159 / .153)
#   KEEPALIVE_S     lease re-acquire interval (default 1800 = TTL/2 assuming ~1h)
#   LEASE_A / LEASE_B   fpgahub lease names (default kr260_01 / kr260_02)
#   POR_SSH         fpgahub-socket host for por_recover.sh (default mapstone-dev)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TL_FPGA_DIR="$(cd "$SCRIPT_DIR/../../../fpga" && pwd)"
ITER_PY="$SCRIPT_DIR/campaign_iter.py"
DASH_PY="$SCRIPT_DIR/dashboard.py"
POR_SH="$SCRIPT_DIR/por_recover.sh"
BRINGUP_SH="$SCRIPTS_DIR/bringup_pair_release.sh"

BUDGET_H=${BUDGET_H:-58}
BASE_SEED=${BASE_SEED:-1}
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
DIEA_IP=${KR260_DIEA_IP:-10.22.24.159}
DIEB_IP=${KR260_DIEB_IP:-10.22.24.153}
KEEPALIVE_S=${KEEPALIVE_S:-1800}
LEASE_A=${LEASE_A:-kr260_01}
LEASE_B=${LEASE_B:-kr260_02}
export POR_SSH=${POR_SSH-mapstone-dev}
export KR260_PASSWORD="$PW"
export KR260_DIEA_IP="$DIEA_IP"
export KR260_DIEB_IP="$DIEB_IP"

DEPLOY_TIMEOUT=${DEPLOY_TIMEOUT:-420}
BRINGUP_TIMEOUT=${BRINGUP_TIMEOUT:-240}

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$SCRIPT_DIR/runs/weekend_$TS}
mkdir -p "$OUT/failures" "$OUT/recorder" "$OUT/logs"
export OUT

DEADLINE=$(( $(date +%s) + BUDGET_H * 3600 ))

log() { echo "[weekend $(date +%H:%M:%S)] $*" | tee -a "$OUT/logs/driver.log"; }

set_current() { echo "$*" > "$OUT/CURRENT"; }

# --- lease management --------------------------------------------------------
acquire_leases() {
    fpgahub lease acquire "$LEASE_A" >>"$OUT/logs/lease.log" 2>&1 || true
    fpgahub lease acquire "$LEASE_B" >>"$OUT/logs/lease.log" 2>&1 || true
}
release_leases() {
    fpgahub lease release "$LEASE_A" >>"$OUT/logs/lease.log" 2>&1 || true
    fpgahub lease release "$LEASE_B" >>"$OUT/logs/lease.log" 2>&1 || true
}

KEEPALIVE_PID=""
start_keepalive() {
    (
        while :; do
            sleep "$KEEPALIVE_S"
            # No documented `lease renew` verb -> re-acquire at TTL/2 (hourly-ish).
            echo "[keepalive $(date +%H:%M:%S)] re-acquire" >>"$OUT/logs/lease.log"
            acquire_leases
        done
    ) &
    KEEPALIVE_PID=$!
    log "keepalive pid=$KEEPALIVE_PID (every ${KEEPALIVE_S}s)"
}

cleanup() {
    log "cleanup: stopping keepalive + releasing leases + final dashboard"
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    release_leases
    rm -f "$OUT/CURRENT" 2>/dev/null || true
    python3 "$DASH_PY" "$OUT" >/dev/null 2>&1 || true
    log "done. artifacts in $OUT"
}
trap cleanup EXIT
trap 'log "signal -> requesting clean stop"; touch "$OUT/STOP"' INT TERM

# --- POR both dies (JTAG-POR, flock-serialised). Returns 99 if BOTH parked. --
por_both() {
    log "POR both dies (fresh)"
    OUT="$OUT" bash "$POR_SH" "$LEASE_A" >>"$OUT/logs/por.log" 2>&1 || true
    OUT="$OUT" bash "$POR_SH" "$LEASE_B" >>"$OUT/logs/por.log" 2>&1 || true
    if [ -f "$OUT/PARK_${LEASE_A}" ] && [ -f "$OUT/PARK_${LEASE_B}" ]; then
        return 99
    fi
    return 0
}

deploy_die() {
    # $1=TARGET  $2=die_ip
    local target=$1 ip=$2
    timeout "$DEPLOY_TIMEOUT" make -C "$TL_FPGA_DIR" deploy_kr260 \
        TARGET="$target" KR260_HOST="ubuntu@$ip" KR260_PASSWORD="$PW" \
        >>"$OUT/logs/deploy_seed${SEED}.log" 2>&1
}

# =============================================================================
log "START budget=${BUDGET_H}h base_seed=$BASE_SEED deadline=$(date -d @"$DEADLINE" 2>/dev/null || echo "$DEADLINE")"
log "boards: die_a=$DIEA_IP ($LEASE_A)  die_b=$DIEB_IP ($LEASE_B)   OUT=$OUT"
acquire_leases
start_keepalive
python3 "$DASH_PY" "$OUT" >/dev/null 2>&1 || true

iter=0
while :; do
    now=$(date +%s)
    if [ "$now" -ge "$DEADLINE" ]; then
        log "deadline reached — stopping"; break
    fi
    if [ -f "$OUT/STOP" ]; then
        log "STOP sentinel present — clean stop"; break
    fi

    SEED=$(( BASE_SEED + iter ))
    export SEED
    log "==== iter $iter  seed $SEED ===="

    # role map (which physical board plays die_a this iter; encoded in print-env)
    if ! ENVOUT=$(python3 "$ITER_PY" --seed "$SEED" --print-env 2>>"$OUT/logs/driver.log") \
       || [ -z "$ENVOUT" ]; then
        log "print-env failed for seed $SEED — skipping"; iter=$((iter+1)); continue
    fi
    eval "$ENVOUT"
    set_current "iter=$iter seed=$SEED phase=POR dir=${DIRECTION:-?} workload=${WORKLOAD:-?} soak_len=${SOAK_LEN:-?} role_swap=${ROLE_SWAP:-?} t=$(date +%H:%M:%S)"

    # --- POR both (fresh dies) ---
    if por_both; then :; else
        log "ABORT: BOTH boards PARKED — cannot continue"; break
    fi

    # --- deploy per role_map ---
    set_current "iter=$iter seed=$SEED phase=DEPLOY die_a->$DIE_A_IP die_b->$DIE_B_IP t=$(date +%H:%M:%S)"
    log "deploy: kr260-eth-chiplet -> $DIE_A_IP ; kr260-eth-chiplet-flip -> $DIE_B_IP"
    dep_ok=1
    deploy_die kr260-eth-chiplet       "$DIE_A_IP" || dep_ok=0
    deploy_die kr260-eth-chiplet-flip  "$DIE_B_IP" || dep_ok=0
    if [ "$dep_ok" -ne 1 ]; then
        log "deploy FAILED (seed $SEED) — record NOCONVERGE, POR, continue"
        python3 "$ITER_PY" --seed "$SEED" --iter "$iter" --out "$OUT" --record-noconverge \
            >>"$OUT/logs/driver.log" 2>&1 || true
        por_both || { log "ABORT: BOTH boards PARKED"; break; }
        python3 "$DASH_PY" "$OUT" >/dev/null 2>&1 || true
        iter=$((iter+1)); continue
    fi

    # --- bring the link up (FIX-E bilateral release) ---
    set_current "iter=$iter seed=$SEED phase=BRINGUP t=$(date +%H:%M:%S)"
    bring_out=$(DIE_A="ubuntu@$DIE_A_IP" DIE_B="ubuntu@$DIE_B_IP" KR260_PASSWORD="$PW" \
        timeout "$BRINGUP_TIMEOUT" bash "$BRINGUP_SH" 2>&1)
    echo "$bring_out" >>"$OUT/logs/bringup_seed${SEED}.log"
    if ! echo "$bring_out" | grep -q "LINK UP fcsm=4 BOTH DIES"; then
        log "NOCONVERGE (seed $SEED): link not fcsm=4 both — record, POR, continue"
        python3 "$ITER_PY" --seed "$SEED" --iter "$iter" --out "$OUT" --record-noconverge \
            >>"$OUT/logs/driver.log" 2>&1 || true
        por_both || { log "ABORT: BOTH boards PARKED"; break; }
        python3 "$DASH_PY" "$OUT" >/dev/null 2>&1 || true
        iter=$((iter+1)); continue
    fi
    log "link UP (fcsm=4 both) — running iteration soak"

    # --- run the iteration (soak, wedge-safe; appends its own JSONL line) ---
    set_current "iter=$iter seed=$SEED phase=SOAK dir=${DIRECTION} workload=${WORKLOAD} soak_len=${SOAK_LEN} t=$(date +%H:%M:%S)"
    python3 "$ITER_PY" --seed "$SEED" --iter "$iter" --out "$OUT" \
        >>"$OUT/logs/driver.log" 2>&1 || true

    # --- refresh dashboard ---
    python3 "$DASH_PY" "$OUT" >/dev/null 2>&1 || true
    set_current "iter=$iter seed=$SEED phase=DONE t=$(date +%H:%M:%S)"
    iter=$((iter+1))
done

log "campaign loop ended after $iter iterations"
# cleanup() runs on EXIT (releases leases, final dashboard)
exit 0

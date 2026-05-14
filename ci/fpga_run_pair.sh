#!/usr/bin/env bash
# Run TideLink ci_pair_role_aware on the real Pynq-Z2 pair via fpgahub.
#
# Uses fpgahub's background-tier lease + revoke-on-interactive-acquire:
#
#   * acquire with --tier=background --requeue-on-revoke so a developer
#     who needs the chassis *now* can preempt this run without queueing;
#   * loop on `actions run` + `lease wait`: if the manifest action is
#     killed by a revoke (exit 130), we re-queue automatically and re-
#     run the composite from scratch when the chassis frees up.
#
# This is the script the v1 fpga_run_pair.sh's comment promised — see
# also the equivalent reference flow in fpgahub's
# ``docs/PROPOSAL_BACKGROUND_TIER.md`` §8.
#
# Required env (defaulted if unset):
#   FPGAHUB_PAIR_CHASSIS    chassis id of the TideLink pair          (default: pynq_z2_02)
#   FPGAHUB_LEASE_TTL_S     initial lease TTL in seconds             (default: 3600)
#   FPGAHUB_LEASE_WAIT_S    max time to wait in queue                (default: 10800 = 3h)
#   FPGAHUB_MAX_REVOKES     cap on revoke→retry attempts             (default: 5)
#   FPGAHUB_BIN             path to fpgahub binary                   (default: fpgahub)
#   CI_PIPELINE_ID          GitLab pipeline id (used in holder name)
#   CI_JOB_ID               GitLab job id (used in holder name)
#
# Exit codes:
#   0    ci_pair_role_aware passed
#   1    ci_pair_role_aware failed
#   3    fpgahub rejected the action (manifest/permissions)
#   75   gave up waiting for the lease (EX_TEMPFAIL — pipeline can retry)
#   124  ci_pair_role_aware timed out
#   130  revoked too many times — gave up

set -euo pipefail

CHASSIS="${FPGAHUB_PAIR_CHASSIS:-pynq_z2_02}"
TTL_S="${FPGAHUB_LEASE_TTL_S:-3600}"
WAIT_S="${FPGAHUB_LEASE_WAIT_S:-10800}"
MAX_REVOKES="${FPGAHUB_MAX_REVOKES:-5}"
FPGAHUB="${FPGAHUB_BIN:-fpgahub}"
PIPELINE_ID="${CI_PIPELINE_ID:-local}"
JOB_ID="${CI_JOB_ID:-$$}"
HOLDER="gitlab-ci-${PIPELINE_ID}-${JOB_ID}"

LOG_DIR="${FPGA_CI_LOG_DIR:-fpga/ci_logs}"
mkdir -p "$LOG_DIR"
META_JSON="$LOG_DIR/run.json"

log() { printf '[fpga-ci %(%H:%M:%S)T] %s\n' -1 "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || { log "missing dependency: $1"; exit 2; }
}
require "$FPGAHUB"
require jq

# Always try to release on the way out so a crash doesn't leak the lease.
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

# Acquire as background. On a free chassis this returns granted
# immediately. If a different holder already holds, we get queued and
# fall back to the wait loop below.
log "acquiring chassis $CHASSIS as holder=$HOLDER tier=background (ttl=${TTL_S}s)"
RAW=$("$FPGAHUB" chassis lease acquire "$CHASSIS" \
        --tier background --requeue-on-revoke \
        --holder "$HOLDER" --user gitlab-ci \
        --ttl "$TTL_S" --json)
KIND=$(jq -r '.kind // "unknown"' <<<"$RAW")
case "$KIND" in
    granted)
        TOKEN=$(jq -r .token <<<"$RAW")
        log "lease granted (background) token=${TOKEN:0:8}…"
        ;;
    queued)
        log "queued at bg position $(jq -r .position <<<"$RAW")"
        # We don't have a token yet. Loop polling acquire until we get
        # one — same idempotency contract as the v1 script.
        deadline=$(( $(date +%s) + WAIT_S ))
        while :; do
            sleep 15
            if [ "$(date +%s)" -ge "$deadline" ]; then
                log "gave up after ${WAIT_S}s waiting for initial grant"
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
                log "lease granted (background) token=${TOKEN:0:8}…"
                break
            fi
        done
        ;;
    *)
        log "unexpected acquire response: $RAW"
        exit 1
        ;;
esac

# Heartbeat in the background so a long composite (~hour for the
# TideLink build under Vivado) doesn't TTL out. The heartbeat uses
# the same token across revoke→regrant (preserved by --requeue-on-revoke).
heartbeat_loop() {
    interval=$(( TTL_S / 3 ))
    [ "$interval" -lt 60 ] && interval=60
    while sleep "$interval"; do
        "$FPGAHUB" chassis lease heartbeat "$CHASSIS" \
            --token "$TOKEN" --holder "$HOLDER" --ttl "$TTL_S" \
            >/dev/null 2>&1 || true
        # Don't break on failure: a brief race during revoke→regrant
        # may make the heartbeat return 403 transiently. We rely on
        # `lease wait` (below) to converge after a revoke.
    done
}
heartbeat_loop &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true; release_lease' EXIT INT TERM

# Main retry loop: wait until our token holds the chassis, run the
# composite, and re-loop on revoke. Caps at MAX_REVOKES retries to
# avoid pathological revoke spam.
attempts=0
rc=1
state="unknown"
while :; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt "$MAX_REVOKES" ]; then
        log "exceeded MAX_REVOKES=$MAX_REVOKES — giving up"
        rc=130
        break
    fi

    # Block until our token holds the chassis. Returns immediately if
    # already held; resumes after a revoke→regrant with the same token
    # because we acquired with --requeue-on-revoke.
    remain=$(( WAIT_S ))   # generous: the server caps at 600 per call
    log "waiting for lease (attempt $attempts/$MAX_REVOKES)"
    if ! "$FPGAHUB" chassis lease wait "$CHASSIS" \
            --token "$TOKEN" --timeout 600 >/dev/null; then
        # `lease wait` exit 75 = timeout. Loop and try again; the
        # heartbeat above is keeping our queue entry alive.
        log "lease wait returned timeout — re-polling"
        continue
    fi

    log "running ci_pair_role_aware (attempt $attempts)"
    set +e
    "$FPGAHUB" actions run "$CHASSIS" ci_pair_role_aware --json --no-stream \
        > "$LOG_DIR/run-${attempts}.json"
    rc=$?
    set -e
    state=$(jq -r '.state // "unknown"' "$LOG_DIR/run-${attempts}.json" 2>/dev/null || echo "unknown")
    log "ci_pair_role_aware attempt=$attempts rc=$rc state=$state"

    case "$rc" in
        0)   break ;;                        # PASS
        130) log "revoked mid-run — retrying"; continue ;;
        *)   break ;;                        # any other failure: surface
    esac
done

# Stash the *last* attempt as run.json for downstream tooling that
# expects a single canonical file (preserves v1 script's interface).
if [ -f "$LOG_DIR/run-${attempts}.json" ]; then
    cp "$LOG_DIR/run-${attempts}.json" "$META_JSON"
fi

# Per-step status snapshots for the artefact bundle + JUnit converter.
mkdir -p "$LOG_DIR/steps"
jq -r '.child_run_ids[]? // empty' "$META_JSON" 2>/dev/null | while read -r step_run_id; do
    [ -z "$step_run_id" ] && continue
    "$FPGAHUB" actions status "$CHASSIS" "$step_run_id" --json \
        > "$LOG_DIR/steps/${step_run_id}.json" 2>/dev/null || true
done

python3 "$(dirname "$0")/fpga_runs_to_junit.py" "$LOG_DIR" \
    > "$LOG_DIR/results.xml" || log "JUnit conversion failed (non-fatal)"

exit "$rc"

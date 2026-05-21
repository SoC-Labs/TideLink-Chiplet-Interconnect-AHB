#!/usr/bin/env bash
###############################################################################
# /tmp/td-bisect-watcher.sh
#
# Auto-test daemon for the in-flight TideLink 3-way bisect.
#
# Polls /tmp/td-bisect-{A,B,C}/imp/fpga/output/pynq-z2-pair{,-flip}-all/tidelink.bit.
# As soon as an experiment's BOTH bitstreams have landed and are >= QUIESCE_S
# old (write-complete heuristic), the watcher will:
#   1. Convert .bit -> .bin locally (bit2bin.py).
#   2. Stage .bin + .hwh to mapstone-dev:/tmp/tidelink_deploy/   (cat | ssh cat)
#      naming: tidelink.{bin,hwh}  +  tidelink-flip.{bin,hwh}
#   3. Acquire pair lease bridge1 (synchronous; GRANTED on this hub).
#   4. Run bringup_pair_converge.sh on mapstone-dev, capture output.
#   5. Release the lease (always — both success and failure path).
#   6. Log lane-lock summary to /tmp/td-bisect-<X>/hwtest.log.
#
# Experiments are tested in arrival order. Hardware tests serialise — only one
# experiment runs on the board pair at a time. Building is fully parallel and
# does not block on testing.
#
# Stop conditions:
#   * All 3 tested -> exit 0 with one summary line per experiment.
#   * Ctrl+C       -> release any held lease, exit.
#   * Timeout > 4h -> exit 1 (failsafe).
#
# Logs to /tmp/td-bisect-watcher.log.
###############################################################################
set -u

LOG=/tmp/td-bisect-watcher.log
# Layered builder lands experiments by name: original 3-way bisect = A/B/C;
# Phase-D synth-mode candidates = D2/D3; freshness reroll = D2-fresh/D3-fresh;
# F = fix-candidate; L<n> = stacked-layer rebuilds (L1, L2, ...). The set is
# open-ended; watcher discovers new names at startup AND on each poll.
EXPS=(A B C D2 D3 D2-fresh D3-fresh F L1 L2 L3 L4 L5)
POLL_S=30
QUIESCE_S=30
LEASE_WAIT_TIMEOUT=300       # 5 minutes per the safety rails
MAX_RUNTIME_S=$(( 4 * 3600 ))
PAIR_ID=bridge1
MAPSTONE=mapstone-dev
REMOTE_STAGE=/tmp/tidelink_deploy
BIT2BIN=/home/dam1n19/SoCLabs/tidelink/fpga/scripts/bit2bin.py
CONVERGE_SCRIPT=/home/dam1n19/td_idelay_wt/pynq_host/scripts/bringup_pair_converge.sh
DEPLOY_PAIR=/home/dam1n19/td_idelay_wt/pynq_host/scripts/deploy_pair.sh
# bringup_pair_converge.sh re-deploys per iteration; cap retries.
MAX_RETRIES=10

# Bug #14 TESTED-state restoration paths. A restarted watcher must NOT
# re-acquire the lease for experiments that already have a verdict on
# disk (would clobber a manual run / waste a board-pair slot). We scan
# ALL of:
#   * Layered-builder results tree (canonical for L<n>/D2/D3/F since
#     ~2026-05-21): /home/dam1n19/SoCLabs/td-bisect/results/<exp>/RESULT.txt
#   * Per-exp source trees (legacy 3-way A/B/C path):
#     /home/dam1n19/SoCLabs/td-bisect-<exp>/hwtest.log
#   * Cache layer (sometimes only here mid-promote):
#     /home/dam1n19/.cache/td-bisect-<exp>/RESULT.txt
# The watcher treats ANY of these as "TESTED" if it contains a RESULT/
# manual marker line. Bisect source dirs may have moved (gone away),
# so the layered-builder path is the load-of-record going forward.
RESULTS_ROOT=/home/dam1n19/SoCLabs/td-bisect/results
LEGACY_ROOT=/tmp                                # /tmp/td-bisect-<exp>
CACHE_ROOT=/home/dam1n19/.cache                 # /home/dam1n19/.cache/td-bisect-<exp>

# Held lease state, for SIGINT cleanup.
HELD_TOKEN=""
HELD_PAIR=""

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }

cleanup() {
    if [ -n "$HELD_TOKEN" ]; then
        log "SIGINT/exit: releasing held lease $HELD_PAIR token=$HELD_TOKEN"
        ssh -o BatchMode=yes "$MAPSTONE" \
            "/opt/fpgahub/bin/fpgahub pair lease release '$HELD_PAIR' --token '$HELD_TOKEN'" \
            >> "$LOG" 2>&1 || true
        HELD_TOKEN=""
    fi
    exit 0
}
trap cleanup INT TERM

# Bug #24 — multi-root path resolver. The build farm now lands artefacts
# under the canonical /home/dam1n19/SoCLabs/td-bisect/<exp>/imp/fpga/output/
# tree, but older runs (and the watcher's original implementation) still
# expect /tmp/td-bisect-<exp>/... or the legacy ~/.cache/td-bisect-<exp>/...
# cache mirror. We probe all three in priority order (canonical > cache >
# /tmp) and emit the first existing match. If none match, fall through
# to the canonical path so a "file not found" error surfaces in the most
# useful location for users following the live builds.
#
# CANONICAL: /home/dam1n19/SoCLabs/td-bisect/<exp>/imp/fpga/output/<target>/<file>
# CACHE    : /home/dam1n19/.cache/td-bisect-<exp>/imp/fpga/output/<target>/<file>
# LEGACY   : /tmp/td-bisect-<exp>/imp/fpga/output/<target>/<file>
BUILD_ROOTS=(
    "/home/dam1n19/SoCLabs/td-bisect"   # canonical (separator: /<exp>/...)
    "/home/dam1n19/.cache"               # cache mirror (separator: /td-bisect-<exp>/...)
    "/tmp"                               # legacy /tmp (separator: /td-bisect-<exp>/...)
)

# Compose the experiment root segment for a given build-root. The canonical
# tree uses "td-bisect/<exp>" while the cache and /tmp trees use the older
# "td-bisect-<exp>" basename.
_exp_segment_for_root() {  # $1=root  $2=exp
    case "$1" in
        /home/dam1n19/SoCLabs/td-bisect) echo "$2" ;;
        *)                               echo "td-bisect-$2" ;;
    esac
}

# Resolve <root>/<exp>/imp/fpga/output/<target>/<file>, returning the FIRST
# existing path across BUILD_ROOTS. If none exists, emit the canonical-root
# path so error messages reference the path the user is most likely to be
# tailing.
_resolve_artefact() {  # $1=exp  $2=target  $3=file (e.g. tidelink.bit)
    local exp=$1 tgt=$2 file=$3 root seg path
    local canonical_path=""
    for root in "${BUILD_ROOTS[@]}"; do
        seg=$(_exp_segment_for_root "$root" "$exp")
        path="$root/$seg/imp/fpga/output/$tgt/$file"
        if [ -z "$canonical_path" ]; then
            canonical_path="$path"
        fi
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    echo "$canonical_path"
}

bit_for() {  # $1=exp  $2=target
    _resolve_artefact "$1" "$2" "tidelink.bit"
}
hwh_for() {  # $1=exp  $2=target
    _resolve_artefact "$1" "$2" "tidelink.hwh"
}

# Both pair-all and pair-flip-all .bit files present and quiesced?
ready_for_test() {  # $1=exp
    local exp=$1 b1 b2 h1 h2 now=$(date +%s) mt
    b1=$(bit_for "$exp" pynq-z2-pair-all)
    b2=$(bit_for "$exp" pynq-z2-pair-flip-all)
    h1=$(hwh_for "$exp" pynq-z2-pair-all)
    h2=$(hwh_for "$exp" pynq-z2-pair-flip-all)
    [ -f "$b1" ] && [ -f "$b2" ] && [ -f "$h1" ] && [ -f "$h2" ] || return 1
    for f in "$b1" "$b2" "$h1" "$h2"; do
        mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ $(( now - mt )) -ge $QUIESCE_S ] || return 1
    done
    return 0
}

# Convert .bit -> .bin alongside each .bit. Resolves the .bit location
# across canonical / cache / legacy roots (see _resolve_artefact) and
# writes the .bin adjacent to its .bit (whichever root that turns out to
# be — so future make_bins runs of the same root find the cached .bin).
make_bins() {  # $1=exp
    local exp=$1 t bit bin
    for t in pynq-z2-pair-all pynq-z2-pair-flip-all; do
        bit=$(_resolve_artefact "$exp" "$t" "tidelink.bit")
        # bin is co-located with bit -- substitute the extension on the
        # resolved path so make_bins is root-agnostic.
        bin="${bit%.bit}.bin"
        if [ ! -f "$bin" ] || [ "$bit" -nt "$bin" ]; then
            log "EXP=$exp bit2bin $t  (src=$bit)"
            python3 "$BIT2BIN" "$bit" "$bin" >> "$LOG" 2>&1 \
                || { log "EXP=$exp bit2bin FAILED for $t"; return 1; }
        fi
    done
    return 0
}

# Stage files to mapstone-dev's /tmp/tidelink_deploy. Never uses scp.
stage_to_mapstone() {  # $1=exp
    local exp=$1 src dst pair_bin pair_hwh flip_bin flip_hwh
    log "EXP=$exp stage -> $MAPSTONE:$REMOTE_STAGE/"
    ssh -o BatchMode=yes "$MAPSTONE" "mkdir -p $REMOTE_STAGE" >> "$LOG" 2>&1 || return 1
    pair_bin=$(_resolve_artefact "$exp" pynq-z2-pair-all      tidelink.bin)
    pair_hwh=$(_resolve_artefact "$exp" pynq-z2-pair-all      tidelink.hwh)
    flip_bin=$(_resolve_artefact "$exp" pynq-z2-pair-flip-all tidelink.bin)
    flip_hwh=$(_resolve_artefact "$exp" pynq-z2-pair-flip-all tidelink.hwh)
    declare -A pairs=(
        ["$pair_bin"]="$REMOTE_STAGE/tidelink.bin"
        ["$pair_hwh"]="$REMOTE_STAGE/tidelink.hwh"
        ["$flip_bin"]="$REMOTE_STAGE/tidelink-flip.bin"
        ["$flip_hwh"]="$REMOTE_STAGE/tidelink-flip.hwh"
    )
    for src in "${!pairs[@]}"; do
        dst=${pairs[$src]}
        if ! cat "$src" | ssh -o BatchMode=yes "$MAPSTONE" "cat > '$dst'"; then
            log "EXP=$exp stage FAILED for $src -> $dst"
            return 1
        fi
        # Sanity: remote size matches local.
        # NOTE: remote ~/.bashrc echoes "Agent pid N" to STDOUT when ssh-agent
        # auto-starts; that leaks INTO the command substitution along with the
        # stat output. We filter stdout for the trailing numeric line only.
        # (The prior 2>/dev/null on the remote shell was insufficient — the
        # leak is stdout, not stderr, from ssh-agent's eval string.)
        local lsz rsz
        lsz=$(stat -c %s "$src")
        rsz=$(ssh -o BatchMode=yes "$MAPSTONE" "stat -c %s '$dst' 2>/dev/null" 2>/dev/null \
              | grep -oE '^[0-9]+$' | tail -1)
        if [ "$lsz" != "$rsz" ]; then
            log "EXP=$exp stage SIZE MISMATCH $src ($lsz) vs $dst ($rsz)"
            return 1
        fi
    done
    return 0
}

# Acquire lease — returns 0 + sets HELD_TOKEN on success.
acquire_lease() {  # $1=exp
    local exp=$1 t0=$(date +%s) elapsed json token state
    log "EXP=$exp acquire lease pair=$PAIR_ID"
    while :; do
        elapsed=$(( $(date +%s) - t0 ))
        if [ $elapsed -gt $LEASE_WAIT_TIMEOUT ]; then
            log "EXP=$exp LEASE WAIT > ${LEASE_WAIT_TIMEOUT}s -- skipping"
            return 1
        fi
        # Use --ttl big enough for full bringup loop (max 10 retries * ~30s)
        json=$(ssh -o BatchMode=yes "$MAPSTONE" \
            "/opt/fpgahub/bin/fpgahub pair lease acquire '$PAIR_ID' --user dam1n19 --ttl 1800 --tier interactive --json" 2>>"$LOG")
        token=$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token","") or "")' 2>/dev/null || true)
        if [ -n "$token" ]; then
            HELD_TOKEN="$token"
            HELD_PAIR="$PAIR_ID"
            log "EXP=$exp lease GRANTED token=$token"
            return 0
        fi
        # If acquire didn't print a token, it's queued/busy; pause and retry.
        log "EXP=$exp acquire returned no token (board busy?); retry in 15s — alert: run \`fpgahub pair lease show $PAIR_ID\` if this loops"
        sleep 15
    done
}

release_lease() {
    if [ -n "$HELD_TOKEN" ]; then
        log "release lease pair=$HELD_PAIR token=$HELD_TOKEN"
        ssh -o BatchMode=yes "$MAPSTONE" \
            "/opt/fpgahub/bin/fpgahub pair lease release '$HELD_PAIR' --token '$HELD_TOKEN'" \
            >> "$LOG" 2>&1 || log "WARN: release call returned non-zero"
        HELD_TOKEN=""
        HELD_PAIR=""
    fi
}

# Run the canonical converge test on mapstone-dev. Capture to a per-exp file
# AND parse the summary line.
run_hwtest() {  # $1=exp
    local exp=$1 out_local=/tmp/td-bisect-$exp/hwtest.log rc
    log "EXP=$exp run bringup_pair_converge.sh on $MAPSTONE (MAX_RETRIES=$MAX_RETRIES)"
    {
        echo "==== watcher: experiment $exp $(ts) ===="
        echo "==== bit2bin + stage done; lease=$HELD_TOKEN ===="
    } > "$out_local"
    # Stream output back; capture rc.
    ssh -o BatchMode=yes "$MAPSTONE" \
        "MAX_RETRIES=$MAX_RETRIES DEPLOY_PAIR='$DEPLOY_PAIR' ARTEFACTS='$REMOTE_STAGE' bash '$CONVERGE_SCRIPT'" \
        >> "$out_local" 2>&1
    rc=$?
    {
        echo "==== watcher: hwtest rc=$rc $(ts) ===="
    } >> "$out_local"
    # Extract the verdict for the master log.
    local verdict
    verdict=$(grep -E '^RESULT:' "$out_local" | tail -1)
    [ -n "$verdict" ] || verdict="(no RESULT line — rc=$rc — see $out_local)"
    log "EXP=$exp DONE  rc=$rc  $verdict"
    return $rc
}

log "===== watcher start (pid=$$) ====="
log "exps=${EXPS[*]}  poll=${POLL_S}s  quiesce=${QUIESCE_S}s  pair=$PAIR_ID"

declare -A TESTED
# Bug #14 TESTED-state restoration. If an experiment already has a verdict
# in ANY of the three result locations, treat it as TESTED so a restarted
# watcher does not re-acquire the lease and clobber an in-flight manual
# run or duplicate-test a converged experiment. Markers we accept:
#   * RESULT.txt exists and is non-empty               (layered builder)
#   * hwtest.log line matching ^RESULT: or ^==== Manual (any source)
# We scan in priority order: results/ (canonical) > /tmp (legacy) > cache.
restore_tested() {
    local exp=$1 verdict=""
    # 1. Layered-builder canonical RESULT.txt
    if [ -s "$RESULTS_ROOT/$exp/RESULT.txt" ]; then
        verdict=$(head -1 "$RESULTS_ROOT/$exp/RESULT.txt")
        TESTED[$exp]=1
        log "EXP=$exp pre-marked TESTED (results/$exp/RESULT.txt: ${verdict:0:80})"
        return 0
    fi
    # 2. Layered-builder hwtest.log
    if [ -f "$RESULTS_ROOT/$exp/hwtest.log" ] && \
       grep -qE '^(RESULT:|==== Manual hwtest|===== Manual hwtest)' \
            "$RESULTS_ROOT/$exp/hwtest.log" 2>/dev/null; then
        TESTED[$exp]=1
        log "EXP=$exp pre-marked TESTED (results/$exp/hwtest.log has RESULT/manual)"
        return 0
    fi
    # 3. Legacy /tmp/td-bisect-<exp>/hwtest.log
    if [ -f "$LEGACY_ROOT/td-bisect-$exp/hwtest.log" ] && \
       grep -qE '^(RESULT:|==== Manual hwtest|===== Manual hwtest)' \
            "$LEGACY_ROOT/td-bisect-$exp/hwtest.log" 2>/dev/null; then
        TESTED[$exp]=1
        log "EXP=$exp pre-marked TESTED (legacy /tmp/td-bisect-$exp/hwtest.log)"
        return 0
    fi
    # 4. Cache mirror RESULT.txt
    if [ -s "$CACHE_ROOT/td-bisect-$exp/RESULT.txt" ]; then
        TESTED[$exp]=1
        log "EXP=$exp pre-marked TESTED (cache/td-bisect-$exp/RESULT.txt)"
        return 0
    fi
    return 1
}
for exp in "${EXPS[@]}"; do
    restore_tested "$exp" || true
done
T0=$(date +%s)

while :; do
    all_done=1
    for exp in "${EXPS[@]}"; do
        [ -n "${TESTED[$exp]:-}" ] && continue
        all_done=0
        if ready_for_test "$exp"; then
            log "EXP=$exp BITSTREAMS READY -- starting hwtest pipeline"
            if make_bins "$exp" && stage_to_mapstone "$exp"; then
                if acquire_lease "$exp"; then
                    run_hwtest "$exp" || true
                    release_lease
                else
                    log "EXP=$exp SKIPPED (lease never granted within ${LEASE_WAIT_TIMEOUT}s)"
                fi
            else
                log "EXP=$exp staging FAILED -- skipping"
            fi
            TESTED[$exp]=1
        fi
    done
    if [ $all_done -eq 1 ]; then
        log "===== all experiments tested ====="
        for exp in "${EXPS[@]}"; do
            verdict=$(grep -E '^RESULT:' /tmp/td-bisect-$exp/hwtest.log 2>/dev/null | tail -1)
            [ -n "$verdict" ] || verdict="(no hwtest.log or no RESULT — see /tmp/td-bisect-$exp/hwtest.log)"
            log "SUMMARY EXP=$exp  $verdict"
        done
        exit 0
    fi
    if [ $(( $(date +%s) - T0 )) -gt $MAX_RUNTIME_S ]; then
        log "===== max runtime exceeded -- exiting ====="
        exit 1
    fi
    sleep $POLL_S
done

#!/usr/bin/env bash
# =============================================================================
# char_session.sh — one-button characterization session for the bridge1 pair,
# orchestrating tests T1/T4/T5/T6b from docs/HW_CHARACTERIZATION_PLAN_2026_06_12.md
# via the on-board pynq_host/scripts/tlchar.py measurement helper.
#
# SEQUENCE
#   gate  link_delivery_proof.sh — the only honest "link is usable" check
#   seed  tlchar seed — the SW pair-credit counter MUST be seeded with the
#         peer's FIFO size before ANY credit-gated stream/fill (stream and
#         fill spin on PAIR_CREDIT_COUNTER; unseeded it reads 0 and the test
#         reports credit_stall instead of measuring anything)
#   T4    doorbell RTT: ping 1000 @10ms on master, responder on slave
#   T1    M->S throughput: burst sweep {1,4,16,64,256} x 10 s, slave drains
#   T5    credit-return latency: RELEASE_THRESHOLD {0,20,64} x fill 75% +
#         10 kHz-class credsample CSV on the master while the slave drains
#   T6b   APB read latency (apblat) idle vs under a B=16 stream
#
# All timed loops run ON the PYNQ ARM (tlchar.py mmap loops); this script only
# orchestrates (HW plan §3.1: never run measurement loops over ssh).
#
# RESILIENCE: a board command returning nothing (SIGBUS/hang/ssh-dead) marks
# that test leg failed, classifies the board via the unjam_fc_node.sh
# signature matrix, attempts its recovery path (reflash EXECUTED for exit-2
# classes), logs to test_failures.log and CONTINUES with the next test.
# Only the delivery gate (after one recover+retry) aborts the session.
#
# RESULTS: $RESULTS_ROOT/char_<UTCstamp>/ — per-leg JSON, per-threshold
# credsample CSVs, meta.json, session.log, and a rendered summary.md
# (char_summary.py). Stage results off mapstone-dev with the tar-over-ssh
# pipe (plain scp/rsync between dev hosts is broken — runbook §3).
#
# RUNS ON mapstone-dev. Boards via sshpass -p xilinx + "echo xilinx | sudo -S";
# tlchar.py + tl_poke.py are STAGED over scp (NO inline python through
# nested ssh quoting).
#
# USAGE
#   char_session.sh [--dry-run]
#   --dry-run : zero board/network access — every board response is faked
#               (plausible numbers) so flow, files and summary are testable
#               off-rig. DRY_SEED=<n> for reproducibility.
#
# ENV
#   MASTER_IP=192.168.4.101  SLAVE_IP=192.168.6.101
#   TIDELINK_BOARD_PASS=xilinx
#   GP1=0|1                  1 => data apertures on the GP1-split addresses
#                            (TX 0x84000000 / RXFIFO 0x84010000 — REQUIRED
#                            for images built from the 2026-06-12 BDs);
#                            TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE override
#   RESULTS_ROOT=~/tidelink_artefacts/char
#   TESTS="t4 t1 t5 t6b"     subset/reorder to taste
#   T4_N=1000 T4_GAP_MS=10
#   T1_BURSTS="1 4 16 64 256"  T1_DUR=10
#   T5_THRESHOLDS="0 20 64"  T5_FILL_PCT=75  T5_SAMPLE_S=10  T5_HZ=1000
#   T6B_N=2000  T6B_BURST=16  T6B_DUR=10
#   DELIVERY_SH / UNJAM_SH / DEPLOY_PAIR / ARTEFACTS  recovery-path tooling
#
# Exit: 0 = session completed, all legs OK; 1 = completed with failed legs
#       (see test_failures.log); 2 = setup error / delivery gate failed.
# =============================================================================
set -u

DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "char_session.sh: unknown option '$a' (only --dry-run)" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Data-aperture bases. GP1-split images (2026-06-12 BDs) relocate the data
# plane: aperture = old + 0x4000_0000 (BD header, tidelink_design.tcl).
if [ "${GP1:-0}" = "1" ]; then
    TXB="${TIDELINK_TX_BASE:-0x84000000}"
    RXB="${TIDELINK_RXFIFO_BASE:-0x84010000}"
else
    TXB="${TIDELINK_TX_BASE:-0x44000000}"
    RXB="${TIDELINK_RXFIFO_BASE:-0x44010000}"
fi

TLCHAR_PY="$SCRIPT_DIR/tlchar.py"
POKE_PY="$SCRIPT_DIR/tl_poke.py"
SUMMARY_PY="$SCRIPT_DIR/char_summary.py"
DELIVERY_SH="${DELIVERY_SH:-$SCRIPT_DIR/link_delivery_proof.sh}"
UNJAM_SH="${UNJAM_SH:-$SCRIPT_DIR/unjam_fc_node.sh}"
DEPLOY_PAIR="${DEPLOY_PAIR:-$SCRIPT_DIR/deploy_pair.sh}"
ARTEFACTS="${ARTEFACTS:-/tmp/tidelink_deploy}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/tidelink_artefacts/char}"

TESTS="${TESTS:-t4 t1 t5 t6b}"
T4_N="${T4_N:-1000}";            T4_GAP_MS="${T4_GAP_MS:-10}"
T1_BURSTS="${T1_BURSTS:-1 4 16 64 256}"; T1_DUR="${T1_DUR:-10}"
T5_THRESHOLDS="${T5_THRESHOLDS:-0 20 64}"
T5_FILL_PCT="${T5_FILL_PCT:-75}"; T5_SAMPLE_S="${T5_SAMPLE_S:-10}"
T5_HZ="${T5_HZ:-1000}";          T5_DRAIN_WPS="${T5_DRAIN_WPS:-0}"
T6B_N="${T6B_N:-2000}";          T6B_BURST="${T6B_BURST:-16}"
T6B_DUR="${T6B_DUR:-10}"
R_REL_THRESH=0x44032004           # RELEASE_THRESHOLD (RW, default 20)
MAX_CREDITS=4096

[ -n "${DRY_SEED:-}" ] && RANDOM=$((DRY_SEED))
UNDER_STREAM=0                    # dry-run apblat flavour flag

fail() { echo "SETUP-ERROR: $*" >&2; exit 2; }
if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$TLCHAR_PY" ]   || fail "tlchar.py not found next to this script: $TLCHAR_PY"
    [ -f "$POKE_PY" ]     || fail "tl_poke.py not found next to this script: $POKE_PY"
    [ -f "$DELIVERY_SH" ] || fail "delivery proof not found: $DELIVERY_SH"
    [ -f "$UNJAM_SH" ]    || fail "unjam tool not found: $UNJAM_SH"
    command -v sshpass >/dev/null || fail "sshpass not installed on this host"
fi
[ -f "$SUMMARY_PY" ] || fail "char_summary.py not found next to this script: $SUMMARY_PY"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$RESULTS_ROOT/char_${STAMP}$([ "$DRY_RUN" -eq 1 ] && echo _dry)"
mkdir -p "$RUN_DIR" || fail "cannot create $RUN_DIR"
LOG="$RUN_DIR/session.log"
FAILLOG="$RUN_DIR/test_failures.log"
: > "$FAILLOG"

log()  { echo "$*" | tee -a "$LOG"; }
zzz()  { [ "$DRY_RUN" -eq 1 ] || sleep "$1"; }
jget() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" <<< "$1" 2>/dev/null; }

# --- dry-run fakes -----------------------------------------------------------
fake_tlchar() {  # CMD [ARGS...]
    case "$1" in
        probe)
            printf '{"credit_count": 4096, "pair_credits": %d, "status": 16, "lane_status": "0x00090000", "fcsm": 4, "cal_done": 1, "fe_rx_is_full": 0}\n' \
                $((4090 + RANDOM % 7)) ;;
        seed)
            printf '{"test": "seed", "pair_credits": 4096}\n' ;;
        ping)
            local n=$2 p50=$((105 + RANDOM % 30))
            printf '{"test": "T4_ping", "gap_ms": %s, "lost": 0, "amplification": %d.%d, "rtt_us": {"n": %d, "min": %d.2, "p50": %d.4, "p90": %d.1, "p99": %d.7, "max": %d.0, "mean": %d.9}}\n' \
                "$3" $((3 + RANDOM % 2)) $((RANDOM % 10)) "$n" \
                $((p50 - 25)) "$p50" $((p50 + 40)) $((p50 + 250)) $((p50 + 1500)) $((p50 + 12)) ;;
        respond)
            printf '{"test": "respond", "echoed": %d, "drained_words": %d}\n' \
                $((3000 + RANDOM % 2000)) $((100000 + RANDOM % 50000)) ;;
        stream)
            local b=$2 d=$3 rate pkts words
            rate=$(( b * 140000 / (b + 2) + RANDOM % 1000 ))   # payload words/s
            pkts=$(( rate * d / b ))
            words=$(( pkts * (b + 2) ))
            printf '{"test": "T1_stream", "burst": %d, "elapsed_s": %d.01, "pkts": %d, "words_total": %d, "payload_words": %d, "words_per_s": %d.0, "payload_words_per_s": %d.0, "payload_MBps": %d.%04d, "starve_pct": %d.%02d, "end_pair_credits": %d, "end_status": 16}\n' \
                "$b" "$d" "$pkts" "$words" $((pkts * b)) $((words / d)) "$rate" \
                $((rate * 4 / 1000000)) $((rate * 4 % 1000000 / 100)) \
                0 $((RANDOM % 80)) $((4090 + RANDOM % 7)) ;;
        drain)
            printf '{"test": "drain", "drained_words": %d, "end_credit_count": 4096, "end_status": 16}\n' \
                $((100000 + RANDOM % 400000)) ;;
        fill)
            printf '{"test": "T5_fill", "baseline": 4096, "target": %d, "pushed_words": %d, "pair_credits": %d}\n' \
                $((4096 * (100 - $2) / 100)) $((4096 * $2 / 100 / 18 * 18)) \
                $((4096 * (100 - $2) / 100 + RANDOM % 18)) ;;
        credsample)
            # staircase: drain frees credits in ~threshold-sized release steps
            echo "t_ns,pair_credits,released_acc"
            local i c=1024 t=1000000000
            for i in $(seq 1 40); do
                printf '%d,%d,%d\n' "$t" "$c" $(( (i % 4 == 0) ? 75 : 0 ))
                t=$((t + 1000000 * ${4:-10}))
                [ $((i % 4)) -eq 0 ] && c=$((c + 75))
                [ "$c" -gt 4096 ] && c=4096
            done ;;
        apblat)
            local p50d p99d
            if [ "$UNDER_STREAM" -eq 1 ]; then p50d=$((29 + RANDOM % 8)); p99d=$((140 + RANDOM % 60))
            else p50d=$((21 + RANDOM % 4)); p99d=$((60 + RANDOM % 20)); fi
            printf '{"test": "T6b_apblat", "lat_us": {"n": %s, "min": 1.8, "p50": %d.%d, "p90": %d.1, "p99": %d.%d, "max": %d.0, "mean": %d.5}}\n' \
                "$2" $((p50d / 10)) $((p50d % 10)) $((p50d / 10 + 2)) \
                $((p99d / 10)) $((p99d % 10)) $((p99d * 3 / 10)) $((p50d / 10)) ;;
        *)  printf '{"error": "fake_tlchar: unknown cmd %s"}\n' "$1" ;;
    esac
}

# --- board plumbing ----------------------------------------------------------
stage_helpers() {
    [ "$DRY_RUN" -eq 1 ] && { log "  (dry-run: helper staging skipped)"; return 0; }
    local ip
    for ip in "$MASTER_IP" "$SLAVE_IP"; do
        sshpass -p "$PASS" scp $SSHC "$TLCHAR_PY" "xilinx@$ip:/home/xilinx/tlchar.py" \
            || fail "staging tlchar.py to $ip failed (board down / lease not granted?)"
        sshpass -p "$PASS" scp $SSHC "$POKE_PY" "xilinx@$ip:/tmp/tl_poke.py" \
            || fail "staging tl_poke.py to $ip failed"
    done
    log "  staged tlchar.py + tl_poke.py on both boards"
}

bd() {  # IP TIMEOUT_S CMD [ARGS...] -> stdout (empty on failure)
    local ip="$1" tmo="$2"; shift 2
    if [ "$DRY_RUN" -eq 1 ]; then fake_tlchar "$@"; return 0; fi
    sshpass -p "$PASS" ssh -n $SSHC "xilinx@$ip" \
        "echo '$PASS' | sudo -S TIDELINK_TX_BASE=$TXB TIDELINK_RXFIFO_BASE=$RXB \
         timeout $tmo python3 /home/xilinx/tlchar.py $*" 2>/dev/null
}

BG_PID=""
bd_bg() {  # OUTFILE IP TIMEOUT_S CMD [ARGS...] -> sets BG_PID ("" in dry-run)
    local out="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then
        local ip="$1"; shift 2     # drop IP + TIMEOUT
        fake_tlchar "$@" > "$out"
        BG_PID=""
        return 0
    fi
    bd "$@" > "$out" &
    BG_PID=$!
}

poke() {  # IP CMD ARGS... -> stdout (tl_poke.py rd/wr)
    local ip="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then
        case "$1" in
            rd) echo "0x00000014" ;;
            wr) echo "wrote $2 = $3" ;;
        esac
        return 0
    fi
    sshpass -p "$PASS" ssh -n $SSHC "xilinx@$ip" \
        "echo '$PASS' | sudo -S timeout 8 python3 /tmp/tl_poke.py $*" 2>/dev/null
}

stop_tlchar() {  # IP — kill any lingering on-board tlchar loop (responder etc.)
    [ "$DRY_RUN" -eq 1 ] && return 0
    sshpass -p "$PASS" ssh -n $SSHC "xilinx@$1" \
        "echo '$PASS' | sudo -S pkill -f 'python3 /home/xilinx/tlchar.py'" 2>/dev/null
    return 0
}

SESSION_FAILS=0
test_fail() {  # TEST DETAIL — log a failed leg + classify/recover, continue
    local test="$1" detail="$2"
    SESSION_FAILS=$((SESSION_FAILS + 1))
    log "  $test FAILED: $detail"
    echo "$(date -u +%H:%M:%SZ) $test: $detail" >> "$FAILLOG"
    recover_pair "$test"
}

reflash_board() {  # IP
    local ip="$1" label role bin mflag=""
    case "$ip" in
        "$MASTER_IP") label="z2_02"; role="die_a"; bin="tidelink.bin" ;;
        *)            label="z2_03"; role="die_b"; bin="tidelink-flip.bin" ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    DRY: would execute reflash: $DEPLOY_PAIR $ip $label $role $ARTEFACTS"
        return 0
    fi
    if [ -f "$ARTEFACTS/$bin.manifest.json" ]; then
        mflag="--manifest $ARTEFACTS/$bin.manifest.json"
    elif [ "${DEPLOY_PAIR_NOVERIFY:-0}" = "1" ]; then
        mflag="--no-verify"
    fi
    bash "$DEPLOY_PAIR" "$ip" "$label" "$role" "$ARTEFACTS" $mflag \
        >> "$RUN_DIR/reflash_$ip.log" 2>&1
}

recover_pair() {  # CONTEXT — unjam signature matrix on both boards
    local ctx="$1" ip rc out sig
    for ip in "$MASTER_IP" "$SLAVE_IP"; do
        if [ "$DRY_RUN" -eq 1 ]; then
            log "    DRY: unjam classify $ip — simulated CLASSIC, recovered"
            echo "$ctx: $ip dry-unjam CLASSIC recovered" >> "$FAILLOG"
            continue
        fi
        out=$(TIDELINK_BOARD_PASS="$PASS" bash "$UNJAM_SH" "$ip" 2>&1); rc=$?
        echo "$out" >> "$RUN_DIR/unjam_$ip.log"
        sig=$(echo "$out" | grep -o 'SIGNATURE: [A-Z-]*' | head -n1 | awk '{print $2}')
        case "$rc" in
            0) log "    $ip: unjam ${sig:-CLASSIC} — recovered"
               echo "$ctx: $ip unjam ${sig:-CLASSIC} recovered" >> "$FAILLOG" ;;
            1) log "    $ip: no jam signature"
               echo "$ctx: $ip no jam signature" >> "$FAILLOG" ;;
            2) log "    $ip: ${sig:-BUS-ERROR} class — executing reflash"
               echo "$ctx: $ip ${sig:-BUS-ERROR} -> reflash" >> "$FAILLOG"
               if reflash_board "$ip"; then log "    $ip: reflash OK"
               else log "    $ip: reflash FAILED (see reflash_$ip.log)"; fi ;;
            *) log "    $ip: unjam incomplete (rc=$rc)"
               echo "$ctx: $ip unjam incomplete rc=$rc" >> "$FAILLOG" ;;
        esac
    done
}

# =============================================================================
log "=============================================================="
log " char_session  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "  mode    : $([ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN (all board responses faked)' || echo LIVE)"
log "  master  : $MASTER_IP   slave: $SLAVE_IP"
log "  bases   : TX=$TXB RXFIFO=$RXB $([ "${GP1:-0}" = "1" ] && echo '(GP1 split)')"
log "  tests   : $TESTS"
log "  results : $RUN_DIR"
log "=============================================================="

cat > "$RUN_DIR/meta.json" <<EOF
{"timestamp": "$STAMP", "dry_run": $DRY_RUN, "master_ip": "$MASTER_IP",
 "slave_ip": "$SLAVE_IP", "tx_base": "$TXB", "rxfifo_base": "$RXB",
 "tests": "$TESTS", "t1_bursts": "$T1_BURSTS", "t1_dur_s": $T1_DUR,
 "t4_n": $T4_N, "t4_gap_ms": $T4_GAP_MS, "t5_thresholds": "$T5_THRESHOLDS",
 "t5_fill_pct": $T5_FILL_PCT, "t6b_n": $T6B_N, "t6b_burst": $T6B_BURST}
EOF

stage_helpers

# --- GATE: one-packet delivery proof ----------------------------------------
gate_delivery() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "  DRY: delivery proof PASS (simulated)"
        echo "DRY delivery proof PASS" > "$RUN_DIR/gate_delivery.log"
        return 0
    fi
    TIDELINK_TX_BASE="$TXB" TIDELINK_RXFIFO_BASE="$RXB" \
        bash "$DELIVERY_SH" "$MASTER_IP" "$SLAVE_IP" > "$RUN_DIR/gate_delivery.log" 2>&1
}
log ""
log "== GATE: link_delivery_proof =="
if ! gate_delivery; then
    log "  delivery proof FAILED — attempting unjam recovery, then one retry"
    recover_pair "gate"
    if ! gate_delivery; then
        log "  delivery proof FAILED after recovery — link cannot carry traffic;"
        log "  aborting session (no test below is meaningful on a dead link)."
        log "  evidence: $RUN_DIR/gate_delivery.log"
        exit 2
    fi
fi
log "  delivery proof PASS: $(tail -n1 "$RUN_DIR/gate_delivery.log")"

# --- SEED: pair-credit counters (both directions) ----------------------------
# stream/fill spin on PAIR_CREDIT_COUNTER; the SW-maintained counter must be
# seeded with the peer's free FIFO credits first (tlchar.py cmd_seed).
log ""
log "== SEED: pair-credit counters =="
seed_one() {  # SENDER_IP RECEIVER_IP LABEL
    local s_ip="$1" r_ip="$2" lbl="$3" rj sj cc pc delta
    rj=$(bd "$r_ip" 15 probe); sj=$(bd "$s_ip" 15 probe)
    if [ -z "$rj" ] || [ -z "$sj" ]; then
        test_fail "seed($lbl)" "probe returned nothing (s=$s_ip r=$r_ip)"
        return 1
    fi
    cc=$(jget "$rj" credit_count); pc=$(jget "$sj" pair_credits)
    delta=$(( ${cc:-0} - ${pc:-0} ))
    if [ "$delta" -gt 0 ]; then
        bd "$s_ip" 15 seed "$delta" > "$RUN_DIR/seed_$lbl.json"
        log "  $lbl: peer credit_count=$cc, pair_credits=$pc -> seeded +$delta ($(jget "$(cat "$RUN_DIR/seed_$lbl.json")" pair_credits) now)"
    else
        log "  $lbl: pair_credits=$pc already >= peer credit_count=$cc — no seed needed"
    fi
}
seed_one "$MASTER_IP" "$SLAVE_IP" "m2s"
seed_one "$SLAVE_IP" "$MASTER_IP" "s2m"

# --- T4: doorbell RTT ---------------------------------------------------------
run_t4() {
    log ""
    log "== T4: doorbell RTT (ping $T4_N @ ${T4_GAP_MS}ms, responder on slave) =="
    bd_bg "$RUN_DIR/t4_respond.json" "$SLAVE_IP" 700 respond 600
    local resp_pid="$BG_PID"
    zzz 1
    local est=$(( T4_N * T4_GAP_MS / 1000 + 120 ))
    bd "$MASTER_IP" "$est" ping "$T4_N" "$T4_GAP_MS" > "$RUN_DIR/t4_ping.json"
    stop_tlchar "$SLAVE_IP"        # responder runs 600 s — cut it loose now
    [ -n "$resp_pid" ] && wait "$resp_pid" 2>/dev/null
    if [ ! -s "$RUN_DIR/t4_ping.json" ]; then
        test_fail "T4" "ping leg returned nothing (master $MASTER_IP)"
        return
    fi
    log "  $(cat "$RUN_DIR/t4_ping.json")"
}

# --- T1: M->S throughput burst sweep -----------------------------------------
run_t1() {
    log ""
    log "== T1: M->S streaming throughput, bursts {$T1_BURSTS} x ${T1_DUR}s =="
    local b drain_dur
    for b in $T1_BURSTS; do
        drain_dur=$(( T1_DUR + 4 ))
        bd_bg "$RUN_DIR/t1_drain_B$b.json" "$SLAVE_IP" $(( drain_dur + 60 )) drain "$drain_dur" 0
        local drain_pid="$BG_PID"
        zzz 0.5
        bd "$MASTER_IP" $(( T1_DUR + 60 )) stream "$b" "$T1_DUR" > "$RUN_DIR/t1_stream_B$b.json"
        [ -n "$drain_pid" ] && wait "$drain_pid" 2>/dev/null
        if [ ! -s "$RUN_DIR/t1_stream_B$b.json" ]; then
            test_fail "T1(B=$b)" "stream leg returned nothing"
            continue
        fi
        log "  B=$b: $(cat "$RUN_DIR/t1_stream_B$b.json")"
        # settle + post-state sanity between sweep points (quiesce rule)
        zzz 2
        bd "$MASTER_IP" 15 probe > "$RUN_DIR/t1_probe_B${b}_m.json"
        bd "$SLAVE_IP"  15 probe > "$RUN_DIR/t1_probe_B${b}_s.json"
    done
}

# --- T5: credit-return latency vs RELEASE_THRESHOLD ---------------------------
run_t5() {
    log ""
    log "== T5: credit-return latency, thresholds {$T5_THRESHOLDS}, fill ${T5_FILL_PCT}% =="
    local th
    for th in $T5_THRESHOLDS; do
        log "  threshold=$th"
        poke "$SLAVE_IP" wr $R_REL_THRESH "$th" >/dev/null
        local rb; rb=$(poke "$SLAVE_IP" rd $R_REL_THRESH)
        log "    slave RELEASE_THRESHOLD readback: ${rb:-<none>}"
        # fill the slave's FIFO to ~T5_FILL_PCT% (credit-gated, never past full)
        bd "$MASTER_IP" 60 fill "$T5_FILL_PCT" > "$RUN_DIR/t5_fill_th$th.json"
        if [ ! -s "$RUN_DIR/t5_fill_th$th.json" ]; then
            test_fail "T5(th=$th)" "fill leg returned nothing"
            continue
        fi
        log "    fill: $(cat "$RUN_DIR/t5_fill_th$th.json")"
        # master samples its PAIR_CREDIT recovery while the slave drains
        bd_bg "$RUN_DIR/t5_credsample_th$th.csv" "$MASTER_IP" $(( T5_SAMPLE_S + 60 )) \
            credsample "$T5_SAMPLE_S" "$T5_HZ"
        local cs_pid="$BG_PID"
        zzz 0.3
        bd "$SLAVE_IP" $(( T5_SAMPLE_S + 60 )) drain "$T5_SAMPLE_S" "$T5_DRAIN_WPS" \
            > "$RUN_DIR/t5_drain_th$th.json"
        [ -n "$cs_pid" ] && wait "$cs_pid" 2>/dev/null
        log "    drain: $(cat "$RUN_DIR/t5_drain_th$th.json" 2>/dev/null || echo '<none>')"
        log "    credsample rows: $(wc -l < "$RUN_DIR/t5_credsample_th$th.csv" 2>/dev/null || echo 0)"
        zzz 1
    done
    # restore the default threshold (HW plan T5 hazard note)
    poke "$SLAVE_IP" wr $R_REL_THRESH 20 >/dev/null
    log "  slave RELEASE_THRESHOLD restored to 20"
}

# --- T6b: APB read latency idle vs under stream -------------------------------
run_t6b() {
    log ""
    log "== T6b: APB read latency (apblat $T6B_N), idle vs under B=$T6B_BURST stream =="
    UNDER_STREAM=0
    bd "$MASTER_IP" 120 apblat "$T6B_N" > "$RUN_DIR/t6b_apblat_idle.json"
    if [ ! -s "$RUN_DIR/t6b_apblat_idle.json" ]; then
        test_fail "T6b" "idle apblat returned nothing"
        return
    fi
    log "  idle  : $(cat "$RUN_DIR/t6b_apblat_idle.json")"
    UNDER_STREAM=1
    bd_bg "$RUN_DIR/t6b_drain_bg.json" "$SLAVE_IP" $(( T6B_DUR + 60 )) drain $(( T6B_DUR + 4 )) 0
    local drain_pid="$BG_PID"
    bd_bg "$RUN_DIR/t6b_stream_bg.json" "$MASTER_IP" $(( T6B_DUR + 60 )) stream "$T6B_BURST" "$T6B_DUR"
    local stream_pid="$BG_PID"
    zzz 1
    bd "$MASTER_IP" 120 apblat "$T6B_N" > "$RUN_DIR/t6b_apblat_stream.json"
    [ -n "$stream_pid" ] && wait "$stream_pid" 2>/dev/null
    [ -n "$drain_pid" ]  && wait "$drain_pid" 2>/dev/null
    UNDER_STREAM=0
    if [ ! -s "$RUN_DIR/t6b_apblat_stream.json" ]; then
        test_fail "T6b" "under-stream apblat returned nothing"
        return
    fi
    log "  stream: $(cat "$RUN_DIR/t6b_apblat_stream.json")"
}

for t in $TESTS; do
    case "$t" in
        t4)  run_t4 ;;
        t1)  run_t1 ;;
        t5)  run_t5 ;;
        t6b) run_t6b ;;
        *)   log "WARN: unknown test '$t' in TESTS — skipped" ;;
    esac
done

# --- summary -------------------------------------------------------------------
log ""
log "== summary =="
if python3 "$SUMMARY_PY" "$RUN_DIR" > "$RUN_DIR/summary.md" 2>>"$LOG"; then
    tee -a "$LOG" < "$RUN_DIR/summary.md"
else
    log "WARN: summary rendering failed — raw results remain in $RUN_DIR"
fi
log ""
log "results dir: $RUN_DIR"
if [ "$SESSION_FAILS" -gt 0 ]; then
    log "session completed with $SESSION_FAILS failed leg(s) — see $FAILLOG"
    exit 1
fi
log "session completed clean"
exit 0

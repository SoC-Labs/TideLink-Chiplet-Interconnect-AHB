#!/usr/bin/env bash
# =============================================================================
# build5_capture.sh — autonomous Build #5 deploy + dual-bug ILA capture
#
# Wraps deploy_pair.sh + phc_ila_capture.sh into a single ready-to-run
# sequence for Build #5 (Bug A + Bug B mark_debug probes added 2026-05-29).
#
# This script does FOUR things, in order:
#   1. Lease bridge1 from mapstone-dev fpgahub (skipped if already granted).
#   2. Deploy both bitstreams (tidelink + tidelink-flip) onto z2_02 / z2_03.
#   3. Live-state pre-trigger check: master+slave LANE_STATUS, FCSM state,
#      ROLE_CFG, returner_busy etc. — fail-fast if master FCSM==7 (Build #4
#      regression signature).
#   4. Two ILA capture passes per board pair:
#        A. Bug A — trigger on rising edge of tl_fc_a2l_valid (master AND
#           slave captures). SW perturbation: 100 doorbell writes + 10 AHB
#           packets (master-side only, slave is observer).
#        B. Bug B — trigger on hw_sync_state_r == HW_SYNC_FIRE (2'b10).
#           SW perturbation: program HW_SYNC_INTERVAL=0x100000 and
#           HW_SYNC_CTRL=0x05 on master. Expected: trigger DOESN'T fire
#           within 60 s (Bug B confirmed), capture shows the wedge probes
#           (target_ns_r / hw_sync_interval_r / phc_time_reached).
#
# All artefacts land in imp/fpga/output/build5_captures/<timestamp>/
# (per-bug subdir per board).
#
# DOES NOT touch /research/AAA/ip_library/**. DOES NOT touch RTL.
#
# Usage:
#   build5_capture.sh [--no-lease] [--keep-lease] [--out-dir <abs>]
#                     [--master-ip <ip>] [--slave-ip <ip>]
#                     [--artefacts <dir>]
#                     [--manifest <f>] [--manifest-flip <f>]
#                     [--skip-deploy] [--skip-bug-a] [--skip-bug-b]
#                     [--bug-a-timeout <s>] [--bug-b-timeout <s>]
#
# Env (overrides flags):
#   TIDELINK_LTX_PAIR_ALL      path to pair-all .ltx on mapstone-dev
#   TIDELINK_LTX_PAIR_FLIP_ALL path to pair-flip-all .ltx on mapstone-dev
#   TIDELINK_BOARD_PASS        PYNQ board password (default xilinx)
#
# Designed for autonomous (operator-offline) execution. Stops loudly on:
#   * lease not granted (queued != granted)
#   * deploy_pair.sh non-zero
#   * fpga_manager state != operating
#   * master FCSM stuck at 7
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_PAIR="$SCRIPT_DIR/deploy_pair.sh"
PHC_ILA="$SCRIPT_DIR/phc_ila_capture.sh"
WLINK_PROBE="$SCRIPT_DIR/wlink_probe.sh"

# Defaults
MASTER_IP="192.168.4.101"
SLAVE_IP="192.168.6.101"
ARTEFACTS_DIR="/tmp/tidelink_deploy"
DO_LEASE=1
KEEP_LEASE=1
SKIP_DEPLOY=0
SKIP_BUG_A=0
SKIP_BUG_B=0
BUG_A_TIMEOUT=30
BUG_B_TIMEOUT=60          # Bug B: expected to TIME OUT (no fire) per the spec
MANIFEST=""
MANIFEST_FLIP=""

# Build #5 expected output locations
BUILD5_PAIR_ALL_DIR="$REPO_ROOT/imp/fpga/output/pynq-z2-pair-all"
BUILD5_PAIR_FLIP_DIR="$REPO_ROOT/imp/fpga/output/pynq-z2-pair-flip-all"

# Default .ltx staging convention: ~/td_milestone_stage/build5/
DEFAULT_LTX_STAGE="$HOME/td_milestone_stage/build5"
TIDELINK_LTX_PAIR_ALL="${TIDELINK_LTX_PAIR_ALL:-$DEFAULT_LTX_STAGE/tidelink.ltx}"
TIDELINK_LTX_PAIR_FLIP_ALL="${TIDELINK_LTX_PAIR_FLIP_ALL:-$DEFAULT_LTX_STAGE/tidelink-flip.ltx}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_BASE="$REPO_ROOT/imp/fpga/output/build5_captures/$TS"

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-lease)        DO_LEASE=0; shift ;;
        --release-lease)   KEEP_LEASE=0; shift ;;
        --keep-lease)      KEEP_LEASE=1; shift ;;
        --out-dir)         OUT_BASE="$2"; shift 2 ;;
        --master-ip)       MASTER_IP="$2"; shift 2 ;;
        --slave-ip)        SLAVE_IP="$2"; shift 2 ;;
        --artefacts)       ARTEFACTS_DIR="$2"; shift 2 ;;
        --manifest)        MANIFEST="$2"; shift 2 ;;
        --manifest-flip)   MANIFEST_FLIP="$2"; shift 2 ;;
        --skip-deploy)     SKIP_DEPLOY=1; shift ;;
        --skip-bug-a)      SKIP_BUG_A=1; shift ;;
        --skip-bug-b)      SKIP_BUG_B=1; shift ;;
        --bug-a-timeout)   BUG_A_TIMEOUT="$2"; shift 2 ;;
        --bug-b-timeout)   BUG_B_TIMEOUT="$2"; shift 2 ;;
        -h|--help)         sed -n '4,55p' "$0" | sed 's/^# *//'; exit 0 ;;
        *) echo "build5_capture.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

mkdir -p "$OUT_BASE"
REPORT="$REPO_ROOT/docs/BUILD5_CAPTURE_REPORT_${TS}.md"
LOG="$OUT_BASE/run.log"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail()  { echo "[$(date +%H:%M:%S)] FAIL: $*" | tee -a "$LOG" >&2; finish_report "FAILED"; exit 1; }
warn()  { echo "[$(date +%H:%M:%S)] WARN: $*" | tee -a "$LOG" >&2; }
section() { log ""; log "================================================================"; log " $*"; log "================================================================"; }

# Report skeleton + finisher
RESULT_BUG_A_MASTER="not run"
RESULT_BUG_A_SLAVE="not run"
RESULT_BUG_B_MASTER="not run"
PRE_TRIGGER_OK="unchecked"

finish_report() {
    local status="$1"
    cat > "$REPORT" <<EOF
# Build #5 capture report — $TS

**Status**: $status
**Out dir**: $OUT_BASE
**Run log**: $LOG

## Inputs
- Master IP: $MASTER_IP
- Slave IP:  $SLAVE_IP
- Artefacts staging: $ARTEFACTS_DIR
- pair-all .ltx:      $TIDELINK_LTX_PAIR_ALL
- pair-flip-all .ltx: $TIDELINK_LTX_PAIR_FLIP_ALL

## Pre-trigger live-state check
$PRE_TRIGGER_OK

## Bug A capture (tl_fc_a2l_valid rising)
- master capture: $RESULT_BUG_A_MASTER
- slave  capture: $RESULT_BUG_A_SLAVE

## Bug B capture (hw_sync_state_r == HW_SYNC_FIRE)
- master capture: $RESULT_BUG_B_MASTER
- expected: TIMEOUT (Bug B = trigger never fires)

## New mark_debug probes (Build #5)
- tx_state_r           (2 bits)
- hw_sync_interval_r   (30 bits)
- target_seconds_r     (48 bits)
- target_ns_r          (30 bits)
- hw_sync_state_r      (2 bits)  <-- Bug B trigger probe
- phc_time_reached     (1 bit)

Removed: pair_credit_counter mark_debug.

## Artefacts on disk
\`\`\`
$(ls -la "$OUT_BASE" 2>/dev/null)
\`\`\`

See docs/BUILD5_CAPTURE_RECIPE_2026_05_29.md for the design rationale.
EOF
    log "Report written: $REPORT"
}
trap 'finish_report "INTERRUPTED"' INT TERM

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
section "0. Pre-flight checks"
[ -x "$DEPLOY_PAIR" ] || fail "deploy_pair.sh not executable: $DEPLOY_PAIR"
[ -x "$PHC_ILA" ]     || fail "phc_ila_capture.sh not executable: $PHC_ILA"

log "Build #5 expected dirs:"
log "  $BUILD5_PAIR_ALL_DIR"
log "  $BUILD5_PAIR_FLIP_DIR"
for d in "$BUILD5_PAIR_ALL_DIR" "$BUILD5_PAIR_FLIP_DIR"; do
    if [ ! -d "$d" ]; then
        warn "Build #5 dir missing: $d (Build #5 may still be in flight — abort here if so)"
    fi
done

# Sanity: confirm the script is being run from mapstone-dev (where hw_server lives).
if [ "$(hostname -s 2>/dev/null)" != "mapstone-dev" ]; then
    warn "Not on mapstone-dev (hostname=$(hostname -s)) — phc_ila_capture.sh expects hw_server on localhost:3121."
    warn "Continue anyway if you've port-forwarded; abort otherwise."
fi

# ---------------------------------------------------------------------------
# 1. Lease handling (best-effort; do not double-acquire)
# ---------------------------------------------------------------------------
LEASE_ACQUIRED_HERE=0
section "1. fpgahub bridge1 lease"
if [ "$DO_LEASE" -eq 1 ]; then
    log "Checking current lease state..."
    STATUS_OUT=$(ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair status bridge1" 2>&1 || true)
    log "Lease status: $STATUS_OUT"
    if echo "$STATUS_OUT" | grep -qi "granted.*$(whoami)"; then
        log "Lease already granted to $(whoami) — re-using."
    else
        log "Acquiring lease (TTL 7200 s)..."
        ACQ_OUT=$(ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease acquire bridge1 --user \$(whoami) --ttl 7200" 2>&1 || true)
        log "$ACQ_OUT"
        if ! echo "$ACQ_OUT" | grep -qi "granted"; then
            fail "Lease not granted (queued != granted — abort per policy)"
        fi
        LEASE_ACQUIRED_HERE=1
    fi
else
    log "Lease step skipped (--no-lease)."
fi

# Always-release trap if WE acquired the lease and KEEP_LEASE=0.
release_lease_if_acquired() {
    if [ "$LEASE_ACQUIRED_HERE" -eq 1 ] && [ "$KEEP_LEASE" -eq 0 ]; then
        log "Releasing bridge1 lease..."
        ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease release bridge1" >/dev/null 2>&1 \
            || warn "lease release failed"
    fi
}
trap 'finish_report "INTERRUPTED"; release_lease_if_acquired' INT TERM

# ---------------------------------------------------------------------------
# 2. Deploy both bitstreams
# ---------------------------------------------------------------------------
section "2. Deploy bitstreams"
if [ "$SKIP_DEPLOY" -eq 1 ]; then
    log "Deploy skipped (--skip-deploy)."
else
    mkdir -p "$ARTEFACTS_DIR"
    log "Staging Build #5 artefacts into $ARTEFACTS_DIR ..."
    # pair-all -> tidelink.{bin,hwh}; pair-flip-all -> tidelink-flip.{bin,hwh}
    cp -v "$BUILD5_PAIR_ALL_DIR/tidelink.bin"  "$ARTEFACTS_DIR/tidelink.bin"  | tee -a "$LOG" \
        || fail "missing $BUILD5_PAIR_ALL_DIR/tidelink.bin (Build #5 finished?)"
    cp -v "$BUILD5_PAIR_ALL_DIR/tidelink.hwh"  "$ARTEFACTS_DIR/tidelink.hwh"  | tee -a "$LOG" \
        || fail "missing $BUILD5_PAIR_ALL_DIR/tidelink.hwh"
    cp -v "$BUILD5_PAIR_FLIP_DIR/tidelink.bin" "$ARTEFACTS_DIR/tidelink-flip.bin" | tee -a "$LOG" \
        || fail "missing $BUILD5_PAIR_FLIP_DIR/tidelink.bin"
    cp -v "$BUILD5_PAIR_FLIP_DIR/tidelink.hwh" "$ARTEFACTS_DIR/tidelink-flip.hwh" | tee -a "$LOG" \
        || fail "missing $BUILD5_PAIR_FLIP_DIR/tidelink.hwh"

    # Build #5 manifests (Bug #32 guard) — auto-discover if not provided.
    A_FLAGS=()
    if [ -n "$MANIFEST" ]; then A_FLAGS+=(--manifest "$MANIFEST"); fi
    B_FLAGS=()
    if [ -n "$MANIFEST_FLIP" ]; then B_FLAGS+=(--manifest "$MANIFEST_FLIP"); fi
    if [ -z "$MANIFEST" ] && [ ! -f "$ARTEFACTS_DIR/tidelink.bin.manifest.json" ]; then
        warn "No manifest for pair-all and none auto-discoverable — deploy will require --no-verify."
        A_FLAGS+=(--no-verify)
    fi
    if [ -z "$MANIFEST_FLIP" ] && [ ! -f "$ARTEFACTS_DIR/tidelink-flip.bin.manifest.json" ]; then
        warn "No manifest for pair-flip-all and none auto-discoverable — deploy will require --no-verify."
        B_FLAGS+=(--no-verify)
    fi

    log "Deploying die_a (pair-all) onto master $MASTER_IP ..."
    bash "$DEPLOY_PAIR" "$MASTER_IP" z2_master die_a "$ARTEFACTS_DIR" "${A_FLAGS[@]}" 2>&1 | tee -a "$LOG" \
        || fail "deploy_pair.sh master returned non-zero"

    log "Deploying die_b (pair-flip-all) onto slave $SLAVE_IP ..."
    bash "$DEPLOY_PAIR" "$SLAVE_IP" z2_slave die_b "$ARTEFACTS_DIR" "${B_FLAGS[@]}" 2>&1 | tee -a "$LOG" \
        || fail "deploy_pair.sh slave returned non-zero"

    log "Sleeping 5 s for FCSM / calibrator to settle ..."
    sleep 5
fi

# ---------------------------------------------------------------------------
# 3. Live-state pre-trigger check
#    Build #5 SUCCESS criterion: master FCSM != 7 (not the Build #4 regression),
#    returner_busy = 0, lane_locked = 0xFF both sides.
# ---------------------------------------------------------------------------
section "3. Live-state check (pre-trigger)"
read_swi_lane_status() {  # IP -> hex value of APB+0x2108
    sshpass -p "${TIDELINK_BOARD_PASS:-xilinx}" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 \
        "xilinx@$1" "echo '${TIDELINK_BOARD_PASS:-xilinx}' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
a=0x44032108; b=a&~(P-1); o=a-b
m=mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
print(\"0x{:08x}\".format(struct.unpack_from(\"<I\",m,o)[0]))'" 2>/dev/null
}

M_STATUS=$(read_swi_lane_status "$MASTER_IP" || echo "0xUNREACH")
S_STATUS=$(read_swi_lane_status "$SLAVE_IP"  || echo "0xUNREACH")
log "master SWI_LANE_STATUS (0x44032108) = $M_STATUS"
log "slave  SWI_LANE_STATUS (0x44032108) = $S_STATUS"

# Decode FCSM state (bits [20:17]) and lane_locked (bits [7:0]) from each
decode_status() {  # HEXVAL -> "lk=0xNN fcsm=N llrx=N cr=N crack=N llrx_valid=N"
    local hv=${1#0x}
    local v=$((16#${hv}))
    local lk=$((v & 0xFF))
    local fcsm=$(( (v >> 17) & 0xF ))
    local llrx=$(( (v >> 21) & 0x3 ))
    local cr=$(( (v >> 23) & 0x1 ))
    local crack=$(( (v >> 24) & 0x1 ))
    local llv=$(( (v >> 29) & 0x1 ))
    printf "lk=0x%02x fcsm=%d llrx=%d cr=%d crack=%d llrx_valid=%d" \
        "$lk" "$fcsm" "$llrx" "$cr" "$crack" "$llv"
}
M_DEC=$(decode_status "$M_STATUS")
S_DEC=$(decode_status "$S_STATUS")
log "master decoded: $M_DEC"
log "slave  decoded: $S_DEC"

# Build #5 success criterion: master FCSM != 7
M_FCSM=$(echo "$M_DEC" | sed -n 's/.*fcsm=\([0-9]*\).*/\1/p')
S_FCSM=$(echo "$S_DEC" | sed -n 's/.*fcsm=\([0-9]*\).*/\1/p')
PRE_TRIGGER_OK=""
if [ "$M_FCSM" = "7" ]; then
    PRE_TRIGGER_OK="FAIL: master FCSM=7 (Build #4 regression signature)"
    warn "Master FCSM stuck at 7 — Build #5 has NOT cleared the regression. Continuing capture anyway (data still useful)."
else
    PRE_TRIGGER_OK="OK: master FCSM=$M_FCSM (!=7), slave FCSM=$S_FCSM"
    log "$PRE_TRIGGER_OK"
fi

# Wlink probe snapshot (informational) — best effort.
log "Wlink probe snapshot (master) ..."
bash "$WLINK_PROBE" "$MASTER_IP" 2>&1 | tee -a "$LOG" || warn "wlink_probe master failed"
log "Wlink probe snapshot (slave) ..."
bash "$WLINK_PROBE" "$SLAVE_IP" 2>&1 | tee -a "$LOG" || warn "wlink_probe slave failed"

# ---------------------------------------------------------------------------
# Helper: SW perturbation thread (run in background while ILA is armed).
# Bug A perturbation: 100 doorbell writes + 10 AHB packet writes
# Bug B perturbation: program HW_SYNC_INTERVAL + HW_SYNC_CTRL
# ---------------------------------------------------------------------------
perturb_bug_a() {
    local IP="$1"
    log "Bug A perturbation: 100 doorbell writes + 10 AHB packets on $IP"
    sshpass -p "${TIDELINK_BOARD_PASS:-xilinx}" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 \
        "xilinx@$IP" "echo '${TIDELINK_BOARD_PASS:-xilinx}' | sudo -S python3 -c '
import mmap,struct,os,time
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
r,ro=mm(0x44032000)   # TideLink APB
# 100 doorbell writes (W1C @0x14)
for _ in range(100):
    struct.pack_into(\"<I\",r,ro+0x14,1)
# 10 AHB packets via local 0x4400_0000 — HAZARDOUS if link wedged.
# Only do this if FCSM != 7 (we already checked master-side FCSM in pre-trigger).
ahb,ao=mm(0x44000000)
for i in range(10):
    struct.pack_into(\"<I\",ahb,ao + (i*4), 0xCAFE0000 | i)
    time.sleep(0.002)
print(\"perturb_bug_a: done\")
'" 2>&1 | tee -a "$LOG" || warn "perturb_bug_a SSH failed (board may have wedged)"
}

perturb_bug_b() {
    local IP="$1"
    log "Bug B perturbation: HW_SYNC_INTERVAL=0x100000, HW_SYNC_CTRL=0x05 on $IP"
    sshpass -p "${TIDELINK_BOARD_PASS:-xilinx}" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 \
        "xilinx@$IP" "echo '${TIDELINK_BOARD_PASS:-xilinx}' | sudo -S python3 -c '
import mmap,struct,os,time
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
r,ro=mm(0x44032000)
# HW_SYNC_INTERVAL at APB+0x2044 -> absolute 0x44032044
struct.pack_into(\"<I\",r,ro+0x2044 - 0x2000, 0x00100000)
time.sleep(0.005)
# HW_SYNC_CTRL = 0x5 (force_en | enable) at APB+0x2040
struct.pack_into(\"<I\",r,ro+0x2040 - 0x2000, 0x00000005)
print(\"perturb_bug_b: HW_SYNC armed, waiting for hw_sync_state_r transition (expected: NEVER on Bug B)\")
'" 2>&1 | tee -a "$LOG" || warn "perturb_bug_b SSH failed"
}

# ---------------------------------------------------------------------------
# 4a. Bug A capture
# ---------------------------------------------------------------------------
section "4a. Bug A capture (tl_fc_a2l_valid rising)"
BUG_A_DIR="$OUT_BASE/bug_a"
mkdir -p "$BUG_A_DIR"
if [ "$SKIP_BUG_A" -eq 1 ]; then
    log "Bug A skipped (--skip-bug-a)."
else
    if [ ! -f "$TIDELINK_LTX_PAIR_ALL" ];     then warn "missing pair-all .ltx: $TIDELINK_LTX_PAIR_ALL"; fi
    if [ ! -f "$TIDELINK_LTX_PAIR_FLIP_ALL" ]; then warn "missing pair-flip-all .ltx: $TIDELINK_LTX_PAIR_FLIP_ALL"; fi

    # Arm master ILA in background — trigger on tl_fc_a2l_valid rising edge.
    log "Arming master ILA (z2_02) on tl_fc_a2l_valid rising ..."
    (
        TIDELINK_LTX="$TIDELINK_LTX_PAIR_ALL" \
        "$PHC_ILA" -b master -p '*tl_fc_a2l_valid*' \
            -t "$BUG_A_TIMEOUT" -o "$BUG_A_DIR" 2>&1 | tee -a "$LOG"
    ) &
    A_MASTER_PID=$!

    # Arm slave ILA in background — trigger on tl_fc_l2a_valid (slave-side
    # receive of master's FC frame).
    log "Arming slave ILA (z2_03) on tl_fc_l2a_valid rising ..."
    (
        TIDELINK_LTX="$TIDELINK_LTX_PAIR_FLIP_ALL" \
        "$PHC_ILA" -b slave -p '*tl_fc_l2a_valid*' \
            -t "$BUG_A_TIMEOUT" -o "$BUG_A_DIR" 2>&1 | tee -a "$LOG"
    ) &
    A_SLAVE_PID=$!

    log "Sleeping 3 s for ILAs to arm before perturbing ..."
    sleep 3

    perturb_bug_a "$MASTER_IP"

    log "Waiting for ILA captures to finish (timeout ${BUG_A_TIMEOUT}s + slack) ..."
    if wait "$A_MASTER_PID"; then RESULT_BUG_A_MASTER="captured ($BUG_A_DIR)"; else RESULT_BUG_A_MASTER="capture script returned non-zero"; fi
    if wait "$A_SLAVE_PID";  then RESULT_BUG_A_SLAVE="captured ($BUG_A_DIR)";  else RESULT_BUG_A_SLAVE="capture script returned non-zero"; fi
fi

# ---------------------------------------------------------------------------
# 4b. Bug B capture
# ---------------------------------------------------------------------------
section "4b. Bug B capture (hw_sync_state_r == HW_SYNC_FIRE = 2'b10)"
BUG_B_DIR="$OUT_BASE/bug_b"
mkdir -p "$BUG_B_DIR"
if [ "$SKIP_BUG_B" -eq 1 ]; then
    log "Bug B skipped (--skip-bug-b)."
else
    log "Arming master ILA (z2_02) on hw_sync_state_r == 2 (HW_SYNC_FIRE) ..."
    log "Expected outcome: TIMEOUT (Bug B = trigger never fires)."
    (
        TIDELINK_LTX="$TIDELINK_LTX_PAIR_ALL" \
        TIDELINK_TRIGGER_VALUE=0x2 \
        "$PHC_ILA" -b master -p '*hw_sync_state_r*' \
            -t "$BUG_B_TIMEOUT" -o "$BUG_B_DIR" 2>&1 | tee -a "$LOG"
    ) &
    B_PID=$!

    log "Sleeping 3 s for ILA to arm before perturbing ..."
    sleep 3

    perturb_bug_b "$MASTER_IP"

    log "Waiting for Bug B capture (expected timeout after ${BUG_B_TIMEOUT}s) ..."
    if wait "$B_PID"; then RESULT_BUG_B_MASTER="captured ($BUG_B_DIR)"; else RESULT_BUG_B_MASTER="capture script returned non-zero (expected on timeout — upload of partial buffer should still produce a .csv)"; fi
fi

# ---------------------------------------------------------------------------
# 5. Lease release (optional)
# ---------------------------------------------------------------------------
section "5. Wrap up"
release_lease_if_acquired

finish_report "OK"
log "Done. Recipe: docs/BUILD5_CAPTURE_RECIPE_2026_05_29.md"
log "Report:    $REPORT"
log "Out dir:   $OUT_BASE"
exit 0

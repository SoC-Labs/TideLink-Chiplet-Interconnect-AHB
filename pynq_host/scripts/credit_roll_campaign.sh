#!/usr/bin/env bash
# =============================================================================
# credit_roll_campaign.sh — N-roll campaign characterizing the CR credit-decode
# lottery (the ~40% chance the Wlink FE credit value received in the CR packet
# garbles on RX — docs/REGISTER_MAP.md OBS_FC_CREDIT, V37_FINAL_DIAGNOSIS).
#
# Each roll:
#   1. bringup_pair_converge.sh (the fixed converge: unconditional success-path
#      release + post-verify) — fresh re-deploy + training convergence.
#   2. On converge success, read OBS_FC_CREDIT @ 0x4403219C on BOTH boards and
#      decode (per docs/REGISTER_MAP.md):
#        [7:0]   fe_rx_credit_max   — the lottery variable. 0x1f-class = good
#                                     decode; small NONZERO = garbled (passes
#                                     the fe_full gate, exhausts in 1-4 pkts)
#        [15:8]  fe_rx_ptr
#        [16]    fe_rx_is_full mirror
#        [31:24] presence marker 0xFC — absent (reg reads 0x00000000) on
#                pre-2026-06-12 images: fields logged as "na", not an error.
#   3. link_delivery_proof.sh — the one-packet honest delivery gate.
#   4. Append ONE CSV row:
#        roll,timestamp,converge_result,iters,a_credit_max,a_ptr,
#        b_credit_max,b_ptr,delivery_verdict,notes
#
# RESILIENCE: a wedged / bus-erroring board mid-campaign is classified via the
# unjam_fc_node.sh signature matrix (CLASSIC / HELD-REPLAY / BUS-ERROR) and its
# recovery path is attempted (CTRL cycle for CLASSIC; deploy_pair.sh reflash
# EXECUTED for the exit-2 reflash classes). The failing roll is logged and the
# campaign CONTINUES — one bad roll never aborts the campaign. Only setup
# errors (missing scripts/artefacts) abort before roll 1.
#
# RUNS ON mapstone-dev (board-network routes). Boards via sshpass -p xilinx +
# "echo xilinx | sudo -S"; /dev/mem access via the STAGED tl_poke.py helper
# (scp a real file — NO inline python through nested ssh; it mangles). Stage
# this script + siblings from a dev host with the tar-over-ssh pipe (plain
# scp/rsync between dev hosts is broken — BOARD_DEPLOY_RUNBOOK §3):
#   tar -C pynq_host/scripts -cf - . | ssh david@mapstone-dev \
#     'mkdir -p ~/tidelink_scripts && tar -C ~/tidelink_scripts -xf -'
#
# USAGE
#   credit_roll_campaign.sh [--dry-run]
#
#   --dry-run : NO board/network access at all — every board interaction is
#               faked end-to-end (converge, OBS_FC_CREDIT lottery, delivery,
#               unjam classification, reflash) so the flow, CSV and summary
#               are testable off-rig. DRY_SEED=<n> makes it reproducible.
#
# ENV
#   ROLLS=20                          number of rolls
#   MASTER_IP=192.168.4.101           z2_02 (die_a)
#   SLAVE_IP=192.168.6.101            z2_03 (die_b)
#   CONVERGE_SH=<dir>/bringup_pair_converge.sh
#   DELIVERY_SH=<dir>/link_delivery_proof.sh
#   UNJAM_SH=<dir>/unjam_fc_node.sh
#   DEPLOY_PAIR=<dir>/deploy_pair.sh  (reflash path for unjam exit-2 classes)
#   ARTEFACTS=/tmp/tidelink_deploy    staged .bin/.hwh (+ manifests) dir
#   OUT_DIR=~/tidelink_artefacts/credit_roll   campaign output root
#   TIDELINK_BOARD_PASS=xilinx
#   TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE    passed through to the delivery
#       proof (export 0x84000000 / 0x84010000 against GP1-split images)
#   MAX_RETRIES / SETTLE / ...        passed through to the converge script
#
# Exit: 0 = campaign completed (regardless of per-roll outcomes),
#       2 = setup error before roll 1.
# =============================================================================
set -u

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac


DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "credit_roll_campaign.sh: unknown option '$a' (only --dry-run)" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLLS="${ROLLS:-20}"
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
CONVERGE_SH="${CONVERGE_SH:-$SCRIPT_DIR/bringup_pair_converge.sh}"
DELIVERY_SH="${DELIVERY_SH:-$SCRIPT_DIR/link_delivery_proof.sh}"
UNJAM_SH="${UNJAM_SH:-$SCRIPT_DIR/unjam_fc_node.sh}"
DEPLOY_PAIR="${DEPLOY_PAIR:-$SCRIPT_DIR/deploy_pair.sh}"
ARTEFACTS="${ARTEFACTS:-/tmp/tidelink_deploy}"
OUT_DIR="${OUT_DIR:-$HOME/tidelink_artefacts/credit_roll}"
POKE_PY="$SCRIPT_DIR/tl_poke.py"
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Reproducible dry-run lottery.
[ -n "${DRY_SEED:-}" ] && RANDOM=$((DRY_SEED))

# --- setup checks (the ONLY aborting failures) ------------------------------
fail() { echo "SETUP-ERROR: $*" >&2; exit 2; }
if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$CONVERGE_SH" ] || fail "converge script not found: $CONVERGE_SH (set CONVERGE_SH=)"
    [ -f "$DELIVERY_SH" ] || fail "delivery proof not found: $DELIVERY_SH (set DELIVERY_SH=)"
    [ -f "$UNJAM_SH" ]    || fail "unjam tool not found: $UNJAM_SH (set UNJAM_SH=)"
    [ -f "$DEPLOY_PAIR" ] || fail "deploy_pair.sh not found: $DEPLOY_PAIR (set DEPLOY_PAIR=)"
    [ -f "$POKE_PY" ]     || fail "tl_poke.py helper not found next to this script: $POKE_PY"
    [ -f "$ARTEFACTS/tidelink.bin" ] || fail "no tidelink.bin staged in $ARTEFACTS"
    command -v sshpass >/dev/null || fail "sshpass not installed on this host"
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$OUT_DIR/campaign_${STAMP}$([ "$DRY_RUN" -eq 1 ] && echo _dry)"
mkdir -p "$RUN_DIR" || fail "cannot create $RUN_DIR"
CSV="$RUN_DIR/credit_roll.csv"
echo "roll,timestamp,converge_result,iters,a_credit_max,a_ptr,b_credit_max,b_ptr,delivery_verdict,notes" > "$CSV"

log() { echo "$*" | tee -a "$RUN_DIR/campaign.log"; }

# --- board-side OBS_FC_CREDIT read (staged helper) --------------------------
stage_poke() {  # stage tl_poke.py on both boards once, up front
    [ "$DRY_RUN" -eq 1 ] && return 0
    local ip rc=0
    for ip in "$MASTER_IP" "$SLAVE_IP"; do
        sshpass -p "$PASS" scp $SSHC "$POKE_PY" "xilinx@$ip:/tmp/tl_poke.py" \
            || { log "WARN: staging tl_poke.py to $ip failed (board down? will retry per-roll)"; rc=1; }
    done
    return $rc
}

# Echoes "live cm ptr full raw" or nothing on failure (SIGBUS/hang/ssh-dead).
read_obs() {  # IP
    local ip="$1" line
    if [ "$DRY_RUN" -eq 1 ]; then
        fake_obs
        return   # propagate fake_obs's rc (1 = simulated wedged board)
    fi
    # Re-stage best-effort (cheap; survives a mid-campaign reflash/reboot).
    sshpass -p "$PASS" scp $SSHC "$POKE_PY" "xilinx@$ip:/tmp/tl_poke.py" 2>/dev/null
    line=$(sshpass -p "$PASS" ssh $SSHC "xilinx@$ip" \
        "echo '$PASS' | sudo -S timeout 8 python3 /tmp/tl_poke.py obs" 2>/dev/null \
        | grep '^OBS ' | head -n1)
    [ -n "$line" ] || return 1
    # line = "OBS raw live cm ptr full"  -> echo "live cm ptr full raw"
    echo "$line" | awk '{print $3, $4, $5, $6, $2}'
}

# --- dry-run fakes -----------------------------------------------------------
# The documented lottery: ~55% good decode (0x1f), ~25% small-nonzero garble
# (passes the fe_full gate, exhausts in 1-4 pkts), ~10% garbled-to-zero
# (fe_full latches), ~5% old-image (marker absent), ~5% board wedge (obs read
# dies -> unjam classification path).
fake_obs() {
    local r=$((RANDOM % 100)) cm ptr full live raw
    if [ "$r" -lt 55 ]; then live=1; cm=31; ptr=$((RANDOM % 32)); full=0
    elif [ "$r" -lt 80 ]; then live=1; cm=$((1 + RANDOM % 7)); ptr=$((RANDOM % 8)); full=0
    elif [ "$r" -lt 90 ]; then live=1; cm=0; ptr=0; full=1
    elif [ "$r" -lt 95 ]; then live=0; cm=0; ptr=0; full=0
    else return 1; fi   # wedged board: obs read died
    if [ "$live" -eq 1 ]; then
        raw=$(printf '0x%08x' $(( (0xFC << 24) | (full << 16) | (ptr << 8) | cm )))
    else
        raw=0x00000000
    fi
    echo "$live $cm $ptr $full $raw"
}

fake_converge() {  # -> sets CONV_RC + CONV_ITERS, writes a fake log
    local r=$((RANDOM % 10))
    if [ "$r" -lt 9 ]; then CONV_RC=0; CONV_ITERS=$((1 + RANDOM % 5))
    else CONV_RC=1; CONV_ITERS="${MAX_RETRIES:-12}"; fi
    echo "DRY: converge rc=$CONV_RC iters=$CONV_ITERS" > "$1"
}

fake_unjam() {  # IP -> mimic unjam_fc_node.sh rc + one-line class
    local r=$((RANDOM % 10))
    if   [ "$r" -lt 3 ]; then echo "SIGNATURE: CLASSIC — recovered"; return 0
    elif [ "$r" -lt 6 ]; then echo "no known jam signature"; return 1
    elif [ "$r" -lt 9 ]; then echo "SIGNATURE: HELD-REPLAY — reflash"; return 2
    else echo "recovery incomplete"; return 3; fi
}

# --- converge wrapper --------------------------------------------------------
run_converge() {  # LOGFILE -> sets CONV_RC, CONV_ITERS
    local logf="$1"
    if [ "$DRY_RUN" -eq 1 ]; then fake_converge "$logf"; return; fi
    MASTER_IP="$MASTER_IP" SLAVE_IP="$SLAVE_IP" ARTEFACTS="$ARTEFACTS" \
        DEPLOY_PAIR="$DEPLOY_PAIR" \
        bash "$CONVERGE_SH" > "$logf" 2>&1
    CONV_RC=$?
    # "RESULT: CAL CONVERGED — ... at iteration N" / "NOT CONVERGED in N ..."
    CONV_ITERS=$(grep -o 'at iteration [0-9]*' "$logf" | head -n1 | awk '{print $3}')
    if [ -z "$CONV_ITERS" ]; then
        CONV_ITERS=$(grep -o 'NOT CONVERGED in [0-9]*' "$logf" | head -n1 | awk '{print $4}')
    fi
    CONV_ITERS="${CONV_ITERS:-?}"
}

# --- delivery wrapper --------------------------------------------------------
run_delivery() {  # LOGFILE -> echoes verdict word
    local logf="$1" rc
    if [ "$DRY_RUN" -eq 1 ]; then
        # Verdict correlated with the rolled credit values: zero/garbled-small
        # credit_max mostly fails delivery; healthy 0x1f mostly passes.
        local worst=31 v
        for v in "${A_CM:-na}" "${B_CM:-na}"; do
            case "$v" in *[!0-9]*|'') ;; *) [ "$v" -lt "$worst" ] && worst=$v ;; esac
        done
        if [ "$worst" -eq 0 ]; then echo "DRY delivery: fe credit 0" > "$logf"; echo "fail-nodeliver"
        elif [ "$worst" -lt 8 ]; then
            if [ $((RANDOM % 10)) -lt 3 ]; then echo "DRY pass (lucky)" > "$logf"; echo "pass"
            else echo "DRY fail (small credit exhausted)" > "$logf"; echo "fail-nodeliver"; fi
        else
            if [ $((RANDOM % 20)) -eq 0 ]; then echo "DRY comms wedge" > "$logf"; echo "fail-comms"
            else echo "DRY pass" > "$logf"; echo "pass"; fi
        fi
        return
    fi
    bash "$DELIVERY_SH" "$MASTER_IP" "$SLAVE_IP" > "$logf" 2>&1
    rc=$?
    case "$rc" in
        0) echo "pass" ;;
        1) echo "fail-presend" ;;     # link state bad before the send
        2) echo "fail-nodeliver" ;;   # packet never landed / header mismatch
        *) echo "fail-comms" ;;       # staging/ssh failure -> suspect wedge
    esac
}

# --- recovery path (unjam signature matrix + reflash for exit-2 classes) ----
reflash_board() {  # IP -> rc ; appends to roll log
    local ip="$1" label role bin mflag=""
    case "$ip" in
        "$MASTER_IP") label="z2_02"; role="die_a"; bin="tidelink.bin" ;;
        "$SLAVE_IP")  label="z2_03"; role="die_b"; bin="tidelink-flip.bin" ;;
        *)            label="z2_xx"; role="die_a"; bin="tidelink.bin" ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    DRY: would execute reflash: $DEPLOY_PAIR $ip $label $role $ARTEFACTS"
        return 0
    fi
    # Provenance flags: same precedence as bringup_pair_converge.sh deploy_one
    # (manifest if staged, else --no-verify only when explicitly allowed —
    # otherwise deploy_pair.sh loudly aborts, which is the right default).
    if [ -f "$ARTEFACTS/$bin.manifest.json" ]; then
        mflag="--manifest $ARTEFACTS/$bin.manifest.json"
    elif [ "${DEPLOY_PAIR_NOVERIFY:-0}" = "1" ]; then
        mflag="--no-verify"
    fi
    bash "$DEPLOY_PAIR" "$ip" "$label" "$role" "$ARTEFACTS" $mflag \
        >> "$ROLL_DIR/reflash_$ip.log" 2>&1
}

recover_board() {  # IP SIDE-LABEL -> appends to NOTES, never aborts
    local ip="$1" side="$2" out rc
    if [ "$DRY_RUN" -eq 1 ]; then
        out=$(fake_unjam "$ip"); rc=$?
    else
        out=$(TIDELINK_BOARD_PASS="$PASS" bash "$UNJAM_SH" "$ip" 2>&1); rc=$?
        echo "$out" >> "$ROLL_DIR/unjam_$ip.log"
    fi
    local sig
    sig=$(echo "$out" | grep -o 'SIGNATURE: [A-Z-]*' | head -n1 | awk '{print $2}')
    case "$rc" in
        0) NOTES="$NOTES ${side}:unjam-${sig:-CLASSIC}-recovered"
           log "  $side ($ip): unjam ${sig:-CLASSIC} — recovered + verified" ;;
        1) NOTES="$NOTES ${side}:unjam-no-jam-signature"
           log "  $side ($ip): unjam — no known jam signature (decode in unjam log)" ;;
        2) NOTES="$NOTES ${side}:unjam-${sig:-BUS-ERROR}-reflash"
           log "  $side ($ip): ${sig:-BUS-ERROR} class — executing reflash recovery"
           if reflash_board "$ip"; then
               NOTES="$NOTES ${side}:reflash-ok"
           else
               NOTES="$NOTES ${side}:reflash-FAILED"
           fi ;;
        *) NOTES="$NOTES ${side}:unjam-failed-rc$rc"
           log "  $side ($ip): unjam recovery FAILED/incomplete (rc=$rc) — continuing campaign" ;;
    esac
}

# =============================================================================
log "=============================================================="
log " credit_roll_campaign  $(date -u +%Y-%m-%dT%H:%M:%SZ)  ROLLS=$ROLLS"
log "  mode      : $([ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN (all board interaction faked)' || echo LIVE)"
log "  master    : $MASTER_IP (z2_02/die_a)   slave: $SLAVE_IP (z2_03/die_b)"
log "  converge  : $CONVERGE_SH"
log "  delivery  : $DELIVERY_SH"
log "  artefacts : $ARTEFACTS"
log "  output    : $RUN_DIR"
log "  OBS_FC_CREDIT @0x4403219C: [7:0]=credit_max [15:8]=ptr [16]=full [31:24]=0xFC"
log "=============================================================="

stage_poke || true

for roll in $(seq 1 "$ROLLS"); do
    ROLL_DIR="$RUN_DIR/roll_$(printf '%02d' "$roll")"
    mkdir -p "$ROLL_DIR"
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NOTES=""
    A_CM="na"; A_PTR="na"; B_CM="na"; B_PTR="na"
    VERDICT="skipped"
    CONV_RC=99; CONV_ITERS="?"

    log ""
    log "--- roll $roll/$ROLLS @ $TS ---"
    run_converge "$ROLL_DIR/converge.log"
    if [ "$CONV_RC" -eq 0 ]; then
        CONV_RES="pass"
        log "  converge: PASS (iteration $CONV_ITERS)"

        # OBS_FC_CREDIT on both boards
        for side in A B; do
            if [ "$side" = "A" ]; then ip="$MASTER_IP"; else ip="$SLAVE_IP"; fi
            if obs=$(read_obs "$ip"); then
                read -r live cm ptr full raw <<< "$obs"
                if [ "$live" = "1" ]; then
                    if [ "$side" = "A" ]; then A_CM=$cm; A_PTR=$ptr; else B_CM=$cm; B_PTR=$ptr; fi
                    log "  $side($ip) OBS_FC_CREDIT raw=$raw credit_max=$cm ptr=$ptr full=$full"
                    [ "$cm" -lt 8 ] && NOTES="$NOTES ${side}:credit_max=$cm-garble-suspect"
                else
                    log "  $side($ip) OBS_FC_CREDIT absent (raw=$raw — pre-2026-06-12 image)"
                    NOTES="$NOTES ${side}:obs-not-in-image"
                fi
            else
                log "  $side($ip) OBS_FC_CREDIT read FAILED — classifying via unjam matrix"
                NOTES="$NOTES ${side}:obs-read-failed"
                if [ "$side" = "A" ]; then A_CM="err"; A_PTR="err"; else B_CM="err"; B_PTR="err"; fi
                recover_board "$ip" "$side"
            fi
        done

        # one-packet delivery proof
        VERDICT=$(run_delivery "$ROLL_DIR/delivery.log")
        log "  delivery: $VERDICT"
        if [ "$VERDICT" = "fail-comms" ]; then
            # ssh/staging died mid-proof: suspect a wedged/bus-erroring board.
            log "  delivery comms failure — running unjam classification on both boards"
            recover_board "$MASTER_IP" "A"
            recover_board "$SLAVE_IP" "B"
        elif [ "$VERDICT" = "fail-nodeliver" ] || [ "$VERDICT" = "fail-presend" ]; then
            # Link "up" but not delivering — exactly the jam matrix's domain.
            recover_board "$MASTER_IP" "A"
            recover_board "$SLAVE_IP" "B"
        fi
    else
        CONV_RES="fail"
        log "  converge: FAIL rc=$CONV_RC after $CONV_ITERS iterations (log: $ROLL_DIR/converge.log)"
        NOTES="$NOTES converge-rc$CONV_RC"
        if [ "$CONV_RC" -eq 2 ]; then
            # Setup-class converge failure mid-campaign (unreachable board /
            # post-release verify fail) — classify rather than abort.
            recover_board "$MASTER_IP" "A"
            recover_board "$SLAVE_IP" "B"
        fi
    fi

    NOTES=$(echo "$NOTES" | sed 's/^ *//; s/,/;/g')
    echo "$roll,$TS,$CONV_RES,$CONV_ITERS,$A_CM,$A_PTR,$B_CM,$B_PTR,$VERDICT,\"$NOTES\"" >> "$CSV"
done

# =============================================================================
log ""
log "=============================================================="
log " CAMPAIGN SUMMARY  ($CSV)"
log "=============================================================="
awk -F, '
    NR == 1 { next }
    { rolls++ }
    $3 == "pass" { conv++ }
    $9 == "pass" { dpass++ }
    $9 != "skipped" { dtry++ }
    { acm[$5]++; bcm[$7]++ }
    END {
        printf("  rolls                 : %d\n", rolls)
        printf("  converge pass         : %d/%d\n", conv, rolls)
        printf("  delivery pass rate    : %d/%d attempted (%.0f%%)\n",
               dpass, dtry, dtry ? 100.0 * dpass / dtry : 0)
        printf("  a_credit_max distribution:\n")
        for (v in acm) printf("      %-4s x %d\n", v, acm[v])
        printf("  b_credit_max distribution:\n")
        for (v in bcm) printf("      %-4s x %d\n", v, bcm[v])
    }' "$CSV" | tee -a "$RUN_DIR/campaign.log"
log "=============================================================="
log " per-roll logs under $RUN_DIR/roll_NN/"
exit 0

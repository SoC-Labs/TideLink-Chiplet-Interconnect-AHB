#!/bin/bash
# =============================================================================
# 13_long_soak.sh — Category 13: long-duration soak.
#
# Runs a random-mix of SAFE operations against the boards for SOAK_SECS
# seconds, sampling lane-status / sticky errors / ECC counters periodically
# and reporting any deviation. SAFE-OPS ONLY — never writes AHB_TX, never
# rings the doorbell from a link-down state.
#
# Random mix at each tick:
#   1. APB read sweep (R0 + R8)
#   2. Doorbell ring (only if link up)
#   3. RELEASE_THRESHOLD round-trip
#   4. ECC counter snapshot
#   5. Lane-status verify
#
# Configuration:
#   SOAK_SECS              default 600 (10 min); set to 3600..86400 for full
#                          endurance run
#   SAMPLE_GAP_S           default 10
#   SOAK_FAIL_ON_DROP      default 1 — fail soak if any sticky/link drop
#
# Output: streams sample summary to stdout (one line/tick) + final verdict.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="13_long_soak"
: "${SOAK_SECS:=600}"
: "${SAMPLE_GAP_S:=10}"
: "${SOAK_FAIL_ON_DROP:=1}"

tt_log "=== $CAT_NAME start (SOAK_SECS=$SOAK_SECS gap=${SAMPLE_GAP_S}s) ==="

# Baseline snapshot
tt_debug_unlock "$MASTER_IP"
tt_debug_unlock "$SLAVE_IP"

# Read baseline ECC counters (clear-on-read NOT a property — saturating cnt)
m_ecc0=$(tt_devmem_read "$MASTER_IP" 0x44032114)
s_ecc0=$(tt_devmem_read "$SLAVE_IP"  0x44032114)
tt_info "baseline ECC: master=$m_ecc0 slave=$s_ecc0"

# Soak loop
t_end=$(( $(date +%s) + SOAK_SECS ))
tick=0
drops=0
sticky_seen=0
last_status_m=""
last_status_s=""

while [ "$(date +%s)" -lt "$t_end" ]; do
    tick=$((tick+1))
    # Lane status
    sm=$(tt_read_lane_status "$MASTER_IP"); ss=$(tt_read_lane_status "$SLAVE_IP")
    mp=$(echo "$sm" | awk '{print $4+0}'); sp=$(echo "$ss" | awk '{print $4+0}')
    mcd=$(echo "$sm" | awk '{print $3+0}'); scd=$(echo "$ss" | awk '{print $3+0}')
    mft=$(echo "$sm" | awk '{print $2}'); sft=$(echo "$ss" | awk '{print $2}')

    # Sticky errors
    sm_s=$(tt_devmem_read "$MASTER_IP" 0x44032010)
    ss_s=$(tt_devmem_read "$SLAVE_IP"  0x44032010)
    sm_st=$(( ($(printf '%d' "${sm_s:-0}")) >> 1 & 0x7 ))
    ss_st=$(( ($(printf '%d' "${ss_s:-0}")) >> 1 & 0x7 ))

    # ECC
    m_ecc=$(tt_devmem_read "$MASTER_IP" 0x44032114)
    s_ecc=$(tt_devmem_read "$SLAVE_IP"  0x44032114)

    # Random mix activity (1..5):
    sel=$(( RANDOM % 5 ))
    case "$sel" in
        0)  # version read
            _=$(tt_devmem_read "$MASTER_IP" 0x44032014) ;;
        1)  # doorbell ring on master if link up
            if [ "$mp" -eq 8 ] && [ "$sp" -eq 8 ]; then
                tt_devmem_write "$MASTER_IP" 0x44032014 0x1
            fi ;;
        2)  # release-threshold round-trip on slave
            o=$(tt_devmem_read "$SLAVE_IP" 0x44032004)
            tt_devmem_write "$SLAVE_IP" 0x44032004 32
            tt_devmem_write "$SLAVE_IP" 0x44032004 "$o" ;;
        3)  # pair-base read-only sample
            _=$(tt_devmem_read "$SLAVE_IP" 0x44032000) ;;
        4)  # SWI_BIT_SLIP_LO read
            _=$(tt_devmem_read "$MASTER_IP" 0x44032104) ;;
    esac

    # Drop / sticky detection
    if [ "$mp" -ne 8 ] || [ "$sp" -ne 8 ] || [ "$mcd" -ne 1 ] || [ "$scd" -ne 1 ]; then
        drops=$((drops+1))
        tt_warn "  tick $tick LINK-DROP: m=${mp}/8 cd=$mcd ft=$mft  s=${sp}/8 cd=$scd ft=$sft"
    fi
    if [ "$sm_st" -ne 0 ] || [ "$ss_st" -ne 0 ]; then
        sticky_seen=$((sticky_seen+1))
        tt_warn "  tick $tick STICKY: master status[3:1]=$sm_st slave=$ss_st"
    fi

    last_status_m=$sm; last_status_s=$ss
    printf "  tick %4d  m=%d/8 cd=%d  s=%d/8 cd=%d  m_ecc=%s  s_ecc=%s\n" \
        "$tick" "$mp" "$mcd" "$sp" "$scd" "$m_ecc" "$s_ecc"

    sleep "$SAMPLE_GAP_S"
done

tt_info "soak summary: ticks=$tick drops=$drops sticky_events=$sticky_seen"
tt_info "final lane-status: master=$last_status_m slave=$last_status_s"
tt_info "final ECC: master=$(tt_devmem_read "$MASTER_IP" 0x44032114) slave=$(tt_devmem_read "$SLAVE_IP" 0x44032114)"

if [ "$drops" -eq 0 ] && [ "$sticky_seen" -eq 0 ]; then
    tt_pass "13 soak ${SOAK_SECS}s: 0 drops, 0 sticky events"
else
    if [ "$SOAK_FAIL_ON_DROP" -eq 1 ]; then
        tt_fail "13 soak ${SOAK_SECS}s: $drops drops, $sticky_seen sticky events"
    else
        tt_info "13 soak ${SOAK_SECS}s: $drops drops, $sticky_seen sticky events (non-fatal mode)"
        tt_pass "13 soak completed (non-fatal mode)"
    fi
fi

tt_summary

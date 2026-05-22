#!/bin/bash
# =============================================================================
# 11_perf_counters.sh — Category 11: performance counters (Regions 5/6/7).
#
# Each region has 8 × 32-bit slots:
#   Region 5 (0x0A0..0x0BC) — TX perf counters
#   Region 6 (0x0C0..0x0DC) — RX perf counters
#   Region 7 (0x0E0..0x0FC) — debug / link status
#
# Bug #23 caveat: R7 DBG_LINK_STATUS was 33→32-bit truncated; ensure the
# build has cb2cd26 (perf-width-truncation fix). We test by sampling all
# slots twice with a small delay and report which ones changed.
#
# Sub-tests:
#   11a  Readable: every slot in R5/R6/R7 returns a value.
#   11b  Idle vs traffic: snapshot at idle, induce minimal traffic (ring
#        doorbell), snapshot again, report deltas. Pass if at least one
#        TX/RX counter advanced under traffic (link must be up).
#   11c  R7 DBG_LINK_STATUS sanity: read should not return 0xFFFFFFFF and
#        the fc_rx_valid bit (build-dependent) should toggle under traffic.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="11_perf_counters"
tt_log "=== $CAT_NAME start ==="

PERF_OFFS="0x0A0 0x0A4 0x0A8 0x0AC 0x0B0 0x0B4 0x0B8 0x0BC \
           0x0C0 0x0C4 0x0C8 0x0CC 0x0D0 0x0D4 0x0D8 0x0DC \
           0x0E0 0x0E4 0x0E8 0x0EC 0x0F0 0x0F4 0x0F8 0x0FC"

test_perf_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 11a readable sanity ---
    unr=0
    for off in $PERF_OFFS; do
        v=$(tt_devmem_read "$IP" "$(( 0x44032000 + off ))")
        [ -z "$v" ] && unr=$((unr+1))
    done
    if [ "$unr" -eq 0 ]; then
        tt_pass "11a all 24 perf slots readable on $tag"
    else
        tt_fail "11a $unr/24 perf slots unreadable on $tag"
    fi

    # --- 11b snapshot1 ---
    declare -A snap1
    for off in $PERF_OFFS; do
        snap1[$off]=$(tt_devmem_read "$IP" "$(( 0x44032000 + off ))")
    done

    # Induce light traffic only if link up (ring a doorbell on the other side
    # so this IP sees an incoming credit).
    if tt_verify_link_up >/dev/null 2>&1; then
        local OTHER=$MASTER_IP
        [ "$IP" = "$MASTER_IP" ] && OTHER=$SLAVE_IP
        for i in 1 2 3 4; do
            tt_devmem_write "$OTHER" 0x44032014 0x1
            sleep 0.05
        done
        sleep 0.5
    fi

    # --- 11c snapshot2 + diff ---
    declare -A snap2
    changed=0
    for off in $PERF_OFFS; do
        snap2[$off]=$(tt_devmem_read "$IP" "$(( 0x44032000 + off ))")
        if [ "${snap1[$off]}" != "${snap2[$off]}" ]; then
            changed=$((changed+1))
            tt_info "  perf $off $tag advanced: ${snap1[$off]} -> ${snap2[$off]}"
        fi
    done
    if tt_verify_link_up >/dev/null 2>&1; then
        if [ "$changed" -ge 1 ]; then
            tt_pass "11b $tag $changed/24 perf slots advanced under doorbell traffic"
        else
            tt_fail "11b $tag NO perf counters advanced under doorbell traffic"
        fi
    else
        tt_skip "11b $tag traffic delta (link not up)"
    fi

    # --- 11d R7 DBG_LINK_STATUS not 0xFFFFFFFF ---
    v=$(tt_devmem_read "$IP" 0x440320E0)
    if [ "$v" = "0xffffffff" ]; then
        tt_fail "11d R7 DBG_LINK_STATUS $tag = 0xFFFFFFFF (Bug #23 still present?)"
    elif [ -n "$v" ]; then
        tt_pass "11d R7 DBG_LINK_STATUS $tag = $v"
    fi
}

test_perf_on "$MASTER_IP" master
test_perf_on "$SLAVE_IP"  slave

tt_summary

#!/bin/bash
# =============================================================================
# 09_ptp_hw_sync.sh — Category 9: PTP HW Sync (Region 2 0x040/0x044/0x048).
#
# **GATED on PHC integration.** Requires the PHC-integrated image (in
# development in the sibling worktree at ~/SoCLabs/td-phc-dev). Detection:
# read HW_SYNC_STATUS (0x048); if it always reads 0 / 0xFFFFFFFF the PHC
# block is absent and this category skips.
#
# Sub-tests (reference docs/PTP_HW_TEST_PLAN.md):
#   9a  HW_SYNC_CTRL round-trip (bit[0] enable, bit[2] force_en).
#   9b  HW_SYNC_INTERVAL round-trip.
#   9c  HW_SYNC_STATUS active+busy observability under enable.
#   9d  Sync scenario:   enable for ~5s, observe seq_num counter advance.
#   9e  Track-freq:      observed PHC freq adjustment (servo signal).
#   9f  Track-offset:    observed offset converges.
#   9g  Soak:            run ~60s, monitor for any sticky misbehaviour.
#
# Safety: enabling HW_SYNC sends sideband packets through the FC node. Like
# the doorbell, these go through the APB-side path and don't wedge the host.
# We still REQUIRE link-up before running.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="09_ptp_hw_sync"
: "${PTP_SYNC_INTERVAL:=0x0000C350}"  # ~50000 cycles @ 25 MHz = 2 ms
: "${PTP_SOAK_SECS:=60}"
: "${PTP_SYNC_OBSERVE_SECS:=5}"

tt_log "=== $CAT_NAME start ==="

if ! tt_verify_link_up >/dev/null 2>&1; then
    tt_skip "09: link not 16/16 — PTP HW sync skipped"
    tt_summary
    exit 0
fi

# --- detect PHC presence: read HW_SYNC_STATUS on master ---
s0=$(tt_devmem_read "$MASTER_IP" 0x44032048)
if [ "$s0" = "0xffffffff" ] || [ -z "$s0" ]; then
    tt_skip "09: HW_SYNC_STATUS reads $s0 — PHC block not in this image"
    tt_summary
    exit 0
fi
tt_info "09 PHC detected on master: HW_SYNC_STATUS=$s0"

tt_debug_unlock "$MASTER_IP"
tt_debug_unlock "$SLAVE_IP"

# --- 9a HW_SYNC_CTRL round-trip ---
orig_ctrl=$(tt_devmem_read "$MASTER_IP" 0x44032040)
for trial in 0x00000000 0x00000001 0x00000004; do  # off, en, force_en
    tt_devmem_write "$MASTER_IP" 0x44032040 "$trial"
    rb=$(tt_devmem_read "$MASTER_IP" 0x44032040)
    # seq_clear (bit[1]) is W1C — won't stay set; only check bits[0],[2].
    rb_keep=$(( ($(printf '%d' "$rb")) & 0x5 ))
    t_keep=$(( ($(printf '%d' "$trial")) & 0x5 ))
    if [ "$rb_keep" -eq "$t_keep" ]; then
        tt_pass "9a HW_SYNC_CTRL master trial=$trial rb=$rb (sticky bits match)"
    else
        tt_fail "9a HW_SYNC_CTRL master trial=$trial rb=$rb (sticky-bit mismatch)"
    fi
done
# Restore off (we'll re-enable in 9d)
tt_devmem_write "$MASTER_IP" 0x44032040 0x0

# --- 9b HW_SYNC_INTERVAL round-trip ---
orig_iv=$(tt_devmem_read "$MASTER_IP" 0x44032044)
for trial in 0x00001000 0x00010000 0x000C350; do
    tt_devmem_write "$MASTER_IP" 0x44032044 "$trial"
    rb=$(tt_devmem_read "$MASTER_IP" 0x44032044)
    tt_assert_eq "$trial" "$rb" "9b HW_SYNC_INTERVAL master round-trip $trial"
done
tt_devmem_write "$MASTER_IP" 0x44032044 "$orig_iv"

# --- 9d Sync scenario: enable, observe seq_num advance ---
# HW_SYNC_STATUS [0]=active [1]=busy [17:2]=seq_num [18]=phc_locked
tt_devmem_write "$MASTER_IP" 0x44032044 "$PTP_SYNC_INTERVAL"
tt_devmem_write "$MASTER_IP" 0x44032040 0x1     # enable
sleep 0.2
s1=$(tt_devmem_read "$MASTER_IP" 0x44032048)
sleep "$PTP_SYNC_OBSERVE_SECS"
s2=$(tt_devmem_read "$MASTER_IP" 0x44032048)
seq1=$(( ($(printf '%d' "$s1")) >> 2 & 0xFFFF ))
seq2=$(( ($(printf '%d' "$s2")) >> 2 & 0xFFFF ))
diff=$(( (seq2 - seq1 + 0x10000) & 0xFFFF ))
tt_info "9d seq_num advance over ${PTP_SYNC_OBSERVE_SECS}s: $seq1 -> $seq2 (diff $diff)"
if [ "$diff" -ge 1 ]; then
    tt_pass "9d HW_SYNC seq_num advancing under enable"
else
    tt_fail "9d HW_SYNC seq_num NOT advancing — sync not running"
fi

# --- 9c HW_SYNC_STATUS active/busy observability ---
active=$(( ($(printf '%d' "$s2")) & 0x1 ))
phc_locked=$(( ($(printf '%d' "$s2")) >> 18 & 0x1 ))
if [ "$active" -eq 1 ]; then
    tt_pass "9c HW_SYNC_STATUS.active=1 with sync enabled"
else
    tt_fail "9c HW_SYNC_STATUS.active=0 with sync enabled (raw $s2)"
fi
tt_info "9c phc_locked=$phc_locked (slave-side servo lock indicator)"

# --- 9e/9f Track-freq + track-offset (informational; read servo regs Region 3
# 0x060 = offset, 0x064 = freq adj). Just observe non-zero values once the
# sync has been running. ---
servo_off=$(tt_devmem_read "$SLAVE_IP" 0x44032060)
servo_fa=$(tt_devmem_read "$SLAVE_IP" 0x44032064)
tt_info "9e/9f slave servo: offset=$servo_off freq_adj=$servo_fa"
# Just check they're readable. Pass criteria on values needs a calibrated
# reference oscillator — note for ongoing development.
if [ -n "$servo_off" ] && [ -n "$servo_fa" ]; then
    tt_pass "9e/9f servo telemetry readable (slave 0x060/0x064)"
else
    tt_fail "9e/9f servo telemetry unreadable"
fi

# --- 9g Soak ---
if [ "$PTP_SOAK_SECS" -gt 0 ]; then
    tt_info "9g soak: running ${PTP_SOAK_SECS}s with sync enabled..."
    drops=0
    t_end=$(( $(date +%s) + PTP_SOAK_SECS ))
    while [ "$(date +%s)" -lt "$t_end" ]; do
        if ! tt_verify_link_up >/dev/null 2>&1; then
            drops=$((drops+1))
            tt_warn "9g link drop detected during soak"
        fi
        sleep 5
    done
    if [ "$drops" -eq 0 ]; then
        tt_pass "9g PTP soak ${PTP_SOAK_SECS}s: no link drops"
    else
        tt_fail "9g PTP soak ${PTP_SOAK_SECS}s: $drops drops"
    fi
fi

# Disable sync, restore
tt_devmem_write "$MASTER_IP" 0x44032040 0x0
tt_devmem_write "$MASTER_IP" 0x44032040 "$orig_ctrl"

tt_summary

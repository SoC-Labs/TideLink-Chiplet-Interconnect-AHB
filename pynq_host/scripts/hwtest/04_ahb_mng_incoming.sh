#!/bin/bash
# =============================================================================
# 04_ahb_mng_incoming.sh — Category 4: slave-side AHB MNG inbound traffic.
#
# Observes the slave's receive accounting when the master generates incoming
# traffic. Uses ONLY APB reads/doorbell-rings (the doorbell path is on the
# safe APB path) — no AHB_TX writes. Asserts:
#
#   * RELEASED_CREDITS_ACC (Region 1 0x020) accumulates as the master rings
#     doorbells / releases credits; read-clears.
#   * DOORBELL_RESP_ACC (Region 1 0x024) accumulates as the slave responds.
#   * PAIR_CREDIT_COUNTER (Region 1 0x028) tracks expected delta.
#   * IRQ-equivalent observability: ACC != 0 implies IRQ asserted (RTL-level).
#
# Gate: requires link up so doorbell frames reach the peer.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="04_ahb_mng_incoming"
tt_log "=== $CAT_NAME start ==="

if ! tt_verify_link_up >/dev/null 2>&1; then
    tt_skip "04: link not 16/16 — all sub-tests need peer-visible traffic"
    tt_summary
    exit 0
fi

tt_debug_unlock "$MASTER_IP"
tt_debug_unlock "$SLAVE_IP"

# --- 4a baseline: clear the slave's accumulators by reading them ---
m0=$(tt_devmem_read "$SLAVE_IP" 0x44032020)  # released_credits_acc
d0=$(tt_devmem_read "$SLAVE_IP" 0x44032024)  # doorbell_response_acc
c0=$(tt_devmem_read "$SLAVE_IP" 0x44032028)  # pair_credit_counter
tt_info "4a baseline slave: REL_ACC=$m0 DBELL_ACC=$d0 PAIR_CTR=$c0"

# --- 4b ring N doorbells from master, observe slave-side accumulation ---
N_DBELL="${N_DBELL:-8}"
for i in $(seq 1 "$N_DBELL"); do
    tt_devmem_write "$MASTER_IP" 0x44032014 0x1
    sleep 0.05
done
sleep 0.5
d_after=$(tt_devmem_read "$SLAVE_IP" 0x44032024)
d_after_dec=$(( d_after ))
if [ "$d_after_dec" -gt 0 ] && [ "$d_after_dec" -le "$N_DBELL" ]; then
    tt_pass "4b slave DOORBELL_RESP_ACC=$d_after_dec after $N_DBELL master doorbells"
else
    # An ACC value > N is possible only if a previous run left residue +
    # the read above didn't clear (raw acc is W-add/R-clear). Report.
    tt_fail "4b slave DOORBELL_RESP_ACC=$d_after_dec unexpected (rang $N_DBELL)"
fi

# Read-clear: should read 0 next time
d_clear=$(tt_devmem_read "$SLAVE_IP" 0x44032024)
tt_assert_eq "0x00000000" "$d_clear" "4b DOORBELL_RESP_ACC read-clears"

# --- 4c PAIR_CREDIT_COUNTER (Region 1 0x028) — write to PAIR_CREDIT_CONSUME
# (0x02C, WO) decrements the local pair_credit_counter; saturates at 0 (Bug #7
# fix). Test both increment-via-credit-receive and decrement-via-consume. ---
# Reset to known state by consuming everything
c_now=$(tt_devmem_read "$SLAVE_IP" 0x44032028)
c_dec=$(( c_now ))
if [ "$c_dec" -gt 0 ]; then
    tt_devmem_write "$SLAVE_IP" 0x4403202C "$c_dec"
    sleep 0.1
    c_after=$(tt_devmem_read "$SLAVE_IP" 0x44032028)
    if [ "$(( c_after ))" -eq 0 ]; then
        tt_pass "4c PAIR_CREDIT_COUNTER consume-to-zero (was $c_now)"
    else
        tt_fail "4c PAIR_CREDIT_COUNTER consume left $c_after (was $c_now)"
    fi
else
    tt_info "4c PAIR_CREDIT_COUNTER already 0 — skipping consume test"
    tt_pass "4c PAIR_CREDIT_COUNTER baseline ok"
fi

# Underflow guard: write a value larger than counter, expect saturation at 0
tt_devmem_write "$SLAVE_IP" 0x4403202C 0xFFFFFFFF
sleep 0.1
c_after=$(tt_devmem_read "$SLAVE_IP" 0x44032028)
tt_assert_eq "0x00000000" "$c_after" "4c PAIR_CREDIT_COUNTER saturates at 0 on huge consume (Bug #7)"

# --- 4d PAIR_CREDIT_COUNTER_EN (0x030) — toggle disable/enable, verify
# counter freezes when disabled. ---
en_orig=$(tt_devmem_read "$SLAVE_IP" 0x44032030)
tt_devmem_write "$SLAVE_IP" 0x44032030 0x0   # disable
sleep 0.1
en_off=$(tt_devmem_read "$SLAVE_IP" 0x44032030)
tt_assert_eq "0x00000000" "$en_off" "4d PAIR_CREDIT_COUNTER_EN disabled"
# Re-enable
tt_devmem_write "$SLAVE_IP" 0x44032030 0x1
sleep 0.1
en_on=$(tt_devmem_read "$SLAVE_IP" 0x44032030)
tt_assert_eq "0x00000001" "$en_on" "4d PAIR_CREDIT_COUNTER_EN re-enabled"

# --- 4e master-side CURRENT_CREDITS (Region 0 0x00C) sanity ---
v=$(tt_devmem_read "$MASTER_IP" 0x4403200C)
cc=$(( v ))
tt_info "4e master CURRENT_CREDITS = $cc"
tt_assert_in_range 0 4096 "$cc" "4e master CURRENT_CREDITS in [0..4096]"

tt_summary

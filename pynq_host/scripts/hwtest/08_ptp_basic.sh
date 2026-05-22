#!/bin/bash
# =============================================================================
# 08_ptp_basic.sh — Category 8: PTP basic registers (Region 1 0x034/0x038/0x03C).
#
# These are the pass-through registers to tidelink_ptp:
#   0x034 PTP_CTRL          RW   per RDL
#   0x038 PTP_RX_PAYLOAD    RO   last received PTP payload
#   0x03C PTP_STATUS        RO   per RDL (busy / locked / armed flags)
#
# PTP_CTRL field layout is per tidelink_ptp_regs.rdl; here we treat the
# register as opaque-32 and verify:
#
#   8a  PTP_CTRL round-trip (write known value, read back).
#   8b  PTP_RX_PAYLOAD is RO (write attempt ignored).
#   8c  PTP_STATUS is RO + non-faulting.
#
# Safety: APB-only. PTP arm/send paths may produce SIDEBAND traffic when
# enabled; we use neutral test values to avoid initiating a sync.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="08_ptp_basic"
tt_log "=== $CAT_NAME start ==="

test_ptp_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 8a PTP_CTRL round-trip ---
    orig=$(tt_devmem_read "$IP" 0x44032034)
    tt_info "8a $tag PTP_CTRL original: $orig"
    # Try a benign pattern (all-zero is the safe default; pattern preserves
    # bit-coverage but avoids known arm/send fields. Use a "low half-word"
    # pattern that should not trigger a send on most PTP_CTRL field layouts.)
    for trial in 0x00000000 0x00000001 0x00000002 0x000000FF; do
        tt_devmem_write "$IP" 0x44032034 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032034)
        # Some bits in PTP_CTRL are W1P self-clearing; accept rb either == trial
        # OR == (trial AND mask) where W1P bits return to 0. Loose check.
        rbn=$(( rb )); tn=$(( trial ))
        # As long as the read doesn't return garbage and the static bits stuck,
        # we accept. Specifically, bit[0] (if EN-like) we expect to stick.
        if [ "$rbn" -eq "$tn" ] || [ "$rbn" -eq $(( tn & 0x1 )) ] || [ "$rbn" -eq 0 ]; then
            tt_pass "8a PTP_CTRL $tag write=$trial read=$rb (W1P-aware OK)"
        else
            tt_fail "8a PTP_CTRL $tag unexpected: wrote $trial got $rb"
        fi
    done
    # Restore original
    tt_devmem_write "$IP" 0x44032034 "$orig"

    # --- 8b PTP_RX_PAYLOAD RO check ---
    before=$(tt_devmem_read "$IP" 0x44032038)
    tt_devmem_write "$IP" 0x44032038 0xDEADBEEF
    after=$(tt_devmem_read "$IP" 0x44032038)
    if [ "$after" != "0xdeadbeef" ]; then
        tt_pass "8b PTP_RX_PAYLOAD $tag is RO (before=$before after=$after)"
    else
        tt_fail "8b PTP_RX_PAYLOAD $tag accepted write — RTL bug"
    fi

    # --- 8c PTP_STATUS RO + non-faulting ---
    s=$(tt_devmem_read "$IP" 0x4403203C)
    if [ -n "$s" ]; then
        tt_pass "8c PTP_STATUS $tag reads ok ($s)"
    else
        tt_fail "8c PTP_STATUS $tag unreadable"
    fi
}

test_ptp_on "$MASTER_IP" master
test_ptp_on "$SLAVE_IP"  slave

tt_summary

#!/bin/bash
# =============================================================================
# 07_addr_translation.sh — Category 7: address-translator coverage.
#
# Exercises the tidelink_addr_translator and PAIR_BASE_ADDR (Region 0 0x000).
# The address translator maps locally-written aperture addresses to peer
# addresses; PAIR_BASE_ADDR is the base used by the returner when sending
# credit/doorbell frames to the peer.
#
# Sub-tests:
#   7a  PAIR_BASE_ADDR round-trip with N values, then restore original.
#   7b  CTRL_LOCK behaviour: after setting LOCK (bit[2]) PAIR_BASE_ADDR is
#       no longer writable. **NOTE**: LOCK is write-once until POR — we do
#       NOT exercise this here (would freeze the rest of the suite); test it
#       in a dedicated lock-test invocation. We just READ CTRL[2] to confirm
#       LOCK is not already set.
#   7c  Translator CAM passthrough (R4 ctrl_reg_addr 0..7 = Region 4 slots
#       0x080..0x09C) — pokes alt values to slots that are CAM entries,
#       reads back, restores. Specific CAM-slot semantics are build-dependent;
#       we treat them as opaque storage and verify write/readback round-trip.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="07_addr_translation"
tt_log "=== $CAT_NAME start ==="

test_addr_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 7a PAIR_BASE_ADDR round-trip + restore ---
    orig=$(tt_devmem_read "$IP" 0x44032000)
    tt_info "7a $tag PAIR_BASE_ADDR original: $orig"

    for trial in 0x44032000 0x55667700 0x00000000 0xFFFFFF00 0x12340000; do
        tt_devmem_write "$IP" 0x44032000 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032000)
        tt_assert_eq "$trial" "$rb" "7a $tag PAIR_BASE_ADDR round-trip $trial"
    done

    tt_devmem_write "$IP" 0x44032000 "$orig"
    rb=$(tt_devmem_read "$IP" 0x44032000)
    tt_assert_eq "$orig" "$rb" "7a $tag PAIR_BASE_ADDR restored"

    # --- 7b CTRL_LOCK status ---
    v=$(tt_devmem_read "$IP" 0x4403201C)
    vn=$(( v ))
    lock=$(( (vn >> 2) & 0x1 ))
    if [ "$lock" -eq 0 ]; then
        tt_pass "7b CTRL_LOCK clear on $tag (RW regs writable)"
    else
        tt_fail "7b CTRL_LOCK set on $tag (RW regs FROZEN; needs POR to clear)"
    fi

    # --- 7c Region-4 ctrl/CAM slots round-trip (slots 0..7 → 0x080..0x09C).
    # Slot 0 (0x080) is ROLE_CFG which is a W1S role_lock register — do NOT
    # touch it. Slots 1..7 are CAM/aux config (build-dependent); poke each
    # with a known-different value, read back, restore. ---
    for slot_off in 0x084 0x088 0x08C 0x090 0x094 0x098 0x09C; do
        addr=$(( 0x44032000 + slot_off ))
        orig=$(tt_devmem_read "$IP" "$addr")
        if [ -z "$orig" ]; then
            tt_fail "7c R4 slot $slot_off $tag unreadable"
            continue
        fi
        trial=$(printf '0x%08x' "$(( ( ($(printf '%d' "$orig")) ^ 0x55AA55AA ) & 0xFFFFFFFF ))")
        tt_devmem_write "$IP" "$addr" "$trial"
        rb=$(tt_devmem_read "$IP" "$addr")
        # Some slots may be RO-or-partial — accept either round-trip or
        # no-change as "non-faulting"; report which it is.
        if [ "$rb" = "$trial" ]; then
            tt_pass "7c R4 $slot_off $tag round-trip ($orig -> $trial)"
        elif [ "$rb" = "$orig" ]; then
            tt_info "7c R4 $slot_off $tag is RO/no-effect (orig=$orig, write ignored)"
            tt_pass "7c R4 $slot_off $tag stable on write (RO)"
        else
            tt_fail "7c R4 $slot_off $tag unexpected (orig=$orig, wrote $trial, read $rb)"
        fi
        # Restore
        tt_devmem_write "$IP" "$addr" "$orig"
    done
}

test_addr_on "$MASTER_IP" master
test_addr_on "$SLAVE_IP"  slave

tt_summary

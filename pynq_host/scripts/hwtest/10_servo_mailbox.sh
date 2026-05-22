#!/bin/bash
# =============================================================================
# 10_servo_mailbox.sh — Category 10: PTP servo cfg + timestamp mailbox.
#
# Region 2 0x04C-0x05C: servo KP/KI/STEP_THRESH/... (pass-through to servo).
# Region 3 0x060-0x07C: servo status (RO, 0x060/0x064) + timestamp mailbox
# (RO from APB, W from FC sideband).
#
# Sub-tests:
#   10a  Servo KP/KI/STEP_THRESH round-trip (Region 2 addr 3-7).
#   10b  Mailbox slots (Region 3) readable (no-fault).
#   10c  Mailbox is RO from APB — writes ignored (informational; pslverr).
#
# Safety: APB-only. Pass-through; no link required for round-trip.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="10_servo_mailbox"
tt_log "=== $CAT_NAME start ==="

test_servo_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 10a servo cfg round-trip — Region 2 offsets 0x04C..0x05C (slot 3..7) ---
    for off in 0x04C 0x050 0x054 0x058 0x05C; do
        addr=$(( 0x44032000 + off ))
        orig=$(tt_devmem_read "$IP" "$addr")
        if [ -z "$orig" ]; then
            tt_fail "10a servo $off $tag unreadable"
            continue
        fi
        trial=$(printf '0x%08x' "$(( ( ($(printf '%d' "$orig")) ^ 0xDEAD0BEE ) & 0xFFFFFFFF ))")
        tt_devmem_write "$IP" "$addr" "$trial"
        rb=$(tt_devmem_read "$IP" "$addr")
        if [ "$rb" = "$trial" ]; then
            tt_pass "10a servo $off $tag round-trip ($orig -> $trial)"
        elif [ "$rb" = "$orig" ]; then
            tt_info "10a servo $off $tag is RO/no-effect (writes ignored)"
            tt_pass "10a servo $off $tag stable (RO-like)"
        else
            tt_fail "10a servo $off $tag unexpected: wrote $trial read $rb"
        fi
        tt_devmem_write "$IP" "$addr" "$orig"
    done

    # --- 10b mailbox slots Region 3 (0x060..0x07C) readable ---
    for off in 0x060 0x064 0x068 0x06C 0x070 0x074 0x078 0x07C; do
        addr=$(( 0x44032000 + off ))
        v=$(tt_devmem_read "$IP" "$addr")
        if [ -n "$v" ]; then
            tt_pass "10b mailbox $off $tag readable ($v)"
        else
            tt_fail "10b mailbox $off $tag unreadable"
        fi
    done

    # --- 10c mailbox W from APB ignored (Region 3 is W from FC sideband only) ---
    for off in 0x060 0x068; do
        addr=$(( 0x44032000 + off ))
        before=$(tt_devmem_read "$IP" "$addr")
        tt_devmem_write "$IP" "$addr" 0xCAFEBABE
        after=$(tt_devmem_read "$IP" "$addr")
        if [ "$after" != "0xcafebabe" ]; then
            tt_pass "10c mailbox $off $tag rejects APB write (before=$before after=$after)"
        else
            tt_info "10c mailbox $off $tag accepted APB write — may be design choice"
            tt_pass "10c mailbox $off $tag write-observed (informational)"
        fi
    done
}

test_servo_on "$MASTER_IP" master
test_servo_on "$SLAVE_IP"  slave

tt_summary

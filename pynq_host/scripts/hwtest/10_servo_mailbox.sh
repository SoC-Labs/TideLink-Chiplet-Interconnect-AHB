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
    #
    # FIXED 2026-07-30 (verification audit): this was a vacuous check — tt_pass
    # fired whether the write was rejected OR accepted, so a genuine RO-contract
    # violation could never fail this test. Traced the RTL before fixing:
    # mbox_reg_write (src/rtl/fifo/tidelink_apb_regs.sv:527) is
    # `apb_write && (apb_region == 4'b0011)`, and apb_write itself
    # (:212) is `psel && penable && pwrite` — the RAW external APB bus, with NO
    # source discrimination. It gates a write directly into the PTP servo's
    # mailbox timestamp registers (src/rtl/tidelink_ptp_servo.sv:220,
    # mbox_sec_lo_r/mbox_sec_hi_r/mbox_ns_r) with no separate qualifier
    # distinguishing "genuine FC sideband" from "external APB poke". Offset
    # 0x068 -> mbox_reg_addr=2 -> mbox_sec_lo_r: CONFIRMED an external APB
    # write there corrupts the servo's assembled mailbox timestamp. This has
    # ZERO existing sim coverage (cocotb/tidelink_ptp_servo drives
    # mbox_reg_write by hand as a DUT input, bypassing the APB decode this bug
    # lives in entirely) — this hwtest sub-test was the only thing that could
    # have caught it, and it was silently disabled. See
    # docs/VERIFICATION_AUDIT_2026_07_30.md §A11 for full detail; NOT fixed at
    # the RTL level here — needs an owner's review of the intended FC-sideband
    # write path before a fix is applied.
    for off in 0x060 0x068; do
        addr=$(( 0x44032000 + off ))
        before=$(tt_devmem_read "$IP" "$addr")
        tt_devmem_write "$IP" "$addr" 0xCAFEBABE
        after=$(tt_devmem_read "$IP" "$addr")
        if [ "$after" != "0xcafebabe" ]; then
            tt_pass "10c mailbox $off $tag rejects APB write (before=$before after=$after)"
        else
            tt_fail "10c mailbox $off $tag ACCEPTED an APB write (before=$before after=$after) — RO-from-APB contract violated, see src/rtl/fifo/tidelink_apb_regs.sv:527 / tidelink_ptp_servo.sv:220"
        fi
    done
}

test_servo_on "$MASTER_IP" master
test_servo_on "$SLAVE_IP"  slave

tt_summary

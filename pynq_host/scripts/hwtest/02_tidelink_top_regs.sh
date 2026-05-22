#!/bin/bash
# =============================================================================
# 02_tidelink_top_regs.sh — Category 2: Region-0 TideLink top-system registers.
#
# Sweeps every Region 0 register (0x000-0x01C): read-only sanity for RO regs,
# round-trip on RW regs, FLUSH self-clearing verification, RELEASE_THRESHOLD
# behaviour. Does NOT set the LOCK bit (CTRL[2]) — that's permanent until POR.
#
# Safety: APB-only. No AHB_TX. Pair-base-addr is RESTORED on exit.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="02_tidelink_top_regs"
tt_log "=== $CAT_NAME start ==="

# Per-IP test: drives the same battery against master then slave.
test_top_regs_on() {
    local IP=$1 tag=$2

    tt_debug_unlock "$IP"

    # --- 2a Version ID (0x014 R) ---
    v=$(tt_devmem_read "$IP" 0x44032014)
    tt_assert_eq "0x544c0100" "${v:-<unreadable>}" "2a TIDELINK_VERSION @ $tag"

    # --- 2b CTRL_LOCK read (0x01C) — should be 0 at start ---
    v=$(tt_devmem_read "$IP" 0x4403201C)
    if [ -n "$v" ]; then
        lock=$(( v & 0x4 ))   # bit[2]
        if [ "$lock" -eq 0 ]; then tt_pass "2b CTRL_LOCK clear @ $tag (raw $v)"
        else tt_fail "2b CTRL_LOCK set @ $tag — RW regs will be frozen (raw $v)"; fi
    else
        tt_fail "2b CTRL @ $tag unreadable"
    fi

    # If lock is set, skip the round-trip writes (they'd be silently ignored).
    if [ "${lock:-0}" -ne 0 ]; then
        tt_skip "2c-2e round-trip tests on $tag (CTRL_LOCK is set)"
        return
    fi

    # --- 2c PAIR_BASE_ADDR (0x000) round-trip ---
    orig=$(tt_devmem_read "$IP" 0x44032000)
    tt_info "2c $tag PAIR_BASE_ADDR original: $orig"
    for trial in 0x44032000 0x12345670 0xDEADBE00 0xCAFE0000; do
        tt_devmem_write "$IP" 0x44032000 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032000)
        tt_assert_eq "$trial" "$rb" "2c PAIR_BASE_ADDR round-trip $tag trial=$trial"
    done
    # Restore
    tt_devmem_write "$IP" 0x44032000 "$orig"
    rb=$(tt_devmem_read "$IP" 0x44032000)
    tt_assert_eq "$orig" "$rb" "2c PAIR_BASE_ADDR restored $tag"

    # --- 2d RELEASE_THRESHOLD (0x004) round-trip ---
    orig=$(tt_devmem_read "$IP" 0x44032004)
    for trial in 0 1 20 64 255; do
        tt_devmem_write "$IP" 0x44032004 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032004)
        # Hex/decimal normalisation
        rbn=$(( rb ))
        if [ "$rbn" -eq "$trial" ]; then
            tt_pass "2d RELEASE_THRESHOLD round-trip $tag trial=$trial (got $rb)"
        else
            tt_fail "2d RELEASE_THRESHOLD $tag trial=$trial got $rb"
        fi
    done
    tt_devmem_write "$IP" 0x44032004 "$orig"

    # --- 2e RO registers reject writes (pslverr expected; we just check the
    # read value is unchanged after attempting a write). ---
    # 0x008 PACKET_WORD_LENGTH, 0x00C CURRENT_CREDITS, 0x010 STATUS, 0x018 REL_ACC
    for ro_off in 0x008 0x00C 0x010 0x018; do
        before=$(tt_devmem_read "$IP" "$(( 0x44032000 + ro_off ))")
        # Attempt to write garbage — should be silently ignored by RTL (pslverr
        # is asserted on the bus but doesn't change reg state).
        tt_devmem_write "$IP" "$(( 0x44032000 + ro_off ))" 0xDEADBEEF
        after=$(tt_devmem_read "$IP" "$(( 0x44032000 + ro_off ))")
        # NOTE: for 0x010 STATUS the value can move (e.g. packet_committed
        # bit), but the attempted DEADBEEF should NOT take effect. Just
        # check the result is not exactly 0xDEADBEEF.
        if [ "$after" != "0xdeadbeef" ]; then
            tt_pass "2e RO $ro_off $tag rejected write (before=$before after=$after)"
        else
            tt_fail "2e RO $ro_off $tag accepted write — RTL bug"
        fi
    done

    # --- 2f CTRL.FLUSH self-clear (CTRL bit[1] = W1P) ---
    # Write 0x2 (FLUSH); read back; bit[1] should be clear (it self-clears
    # next cycle, the mmap read latency >> 1 hclk so it should always read 0).
    tt_devmem_write "$IP" 0x4403201C 0x2
    sleep 0.05
    v=$(tt_devmem_read "$IP" 0x4403201C)
    flush_bit=$(( (v) & 0x2 ))
    if [ "$flush_bit" -eq 0 ]; then
        tt_pass "2f CTRL.FLUSH self-cleared $tag (raw $v)"
    else
        tt_fail "2f CTRL.FLUSH still set $tag (raw $v)"
    fi

    # --- 2g STATUS sticky-error inspection (informational) ---
    v=$(tt_devmem_read "$IP" 0x44032010)
    if [ -n "$v" ]; then
        rb_b=$(( v & 0x1 ))
        ovr=$(( (v >> 1) & 0x1 ))
        und=$(( (v >> 2) & 0x1 ))
        merr=$(( (v >> 3) & 0x1 ))
        pcmt=$(( (v >> 4) & 0x1 ))
        tt_info "2g STATUS $tag: returner_busy=$rb_b overrun=$ovr underrun=$und master_err=$merr pkt_committed=$pcmt"
        if [ "$ovr" -eq 0 ] && [ "$und" -eq 0 ] && [ "$merr" -eq 0 ]; then
            tt_pass "2g STATUS sticky errors clear @ $tag"
        else
            tt_fail "2g STATUS has sticky errors @ $tag (overrun=$ovr underrun=$und master_err=$merr)"
        fi
    fi

    # --- 2h Doorbell address (0x014 W1C) — write should not break read of
    # version (the write triggers doorbell pulse; read returns version ID).
    # Caveat: this rings the doorbell. If link is down, the doorbell still
    # SAFE (it's an APB write into a local reg + a credit-path event; the
    # WEDGE hazard is AHB_TX only). But on slave side ringing the doorbell
    # generates a returner txn to the peer — let's only do this if link is up.
    if tt_verify_link_up >/dev/null 2>&1; then
        tt_devmem_write "$IP" 0x44032014 0x1
        sleep 0.05
        v=$(tt_devmem_read "$IP" 0x44032014)
        tt_assert_eq "0x544c0100" "$v" "2h doorbell ring on $tag (version still readable)"
    else
        tt_skip "2h doorbell ring on $tag (link not up)"
    fi
}

test_top_regs_on "$MASTER_IP" master
test_top_regs_on "$SLAVE_IP"  slave

tt_summary

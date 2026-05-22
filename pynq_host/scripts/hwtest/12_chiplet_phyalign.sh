#!/bin/bash
# =============================================================================
# 12_chiplet_phyalign.sh — Category 12: Region 8 chiplet-ext PHY-align + I2C.
#
# Region 8 (0x100..0x11C) — PHY alignment + I2C training register block:
#   0x100 SWI_TRAINING_MODE   RW  [0] train, [1] recal
#   0x104 SWI_BIT_SLIP_LO     RW  [23:0] per-lane bit-slip
#   0x108 SWI_LANE_STATUS     RO  lane locks/faults + cal_done + FCSM/ECC etc
#   0x10C NEGO_TRAIN_CFG      RW  training handshake config
#   0x110 NEGO_TRAIN_STATUS   RO  FSM status
#   0x114 NEGO_TRAIN_STEP     RW  W1P single-pulse (aliased with ECC RO counters)
#   0x118 SWI_PHASE_OFFSET    RW  8x4-bit per-lane phase (latched at role_lock)
#   0x11C PHY_ALIGN_ID        RO  0x5041_0100 ("PA01" v1.0)
#
# Sub-tests:
#   12a  PHY_ALIGN_ID identity (each side reads 0x5041_0100).
#   12b  SWI_BIT_SLIP_LO round-trip (poke alt values; restore).
#   12c  SWI_LANE_STATUS RO behaviour (write ignored).
#   12d  NEGO_TRAIN_CFG round-trip.
#   12e  NEGO_TRAIN_STEP single-pulse (write then read returns 0).
#   12f  SWI_PHASE_OFFSET readable (do NOT modify — latched at role_lock).
#   12g  SWI_TRAINING_MODE round-trip (bits[1:0]).
#
# Safety: APB-only. Region 8 is the same path the bringup scripts use for
# recal coordination, so this is fully exercised already.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="12_chiplet_phyalign"
tt_log "=== $CAT_NAME start ==="

test_r8_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 12a PHY_ALIGN_ID identity ---
    v=$(tt_devmem_read "$IP" 0x4403211C)
    tt_assert_eq "0x50410100" "$v" "12a PHY_ALIGN_ID $tag"

    # --- 12b SWI_BIT_SLIP_LO round-trip ---
    orig=$(tt_devmem_read "$IP" 0x44032104)
    tt_info "12b $tag SWI_BIT_SLIP_LO original: $orig"
    for trial in 0x00000000 0x00000001 0x00FF00FF 0x00FFFFFF; do
        tt_devmem_write "$IP" 0x44032104 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032104)
        # bits [23:0] only — mask
        rb_low=$(( ($(printf '%d' "$rb")) & 0xFFFFFF ))
        t_low=$(( ($(printf '%d' "$trial")) & 0xFFFFFF ))
        if [ "$rb_low" -eq "$t_low" ]; then
            tt_pass "12b SWI_BIT_SLIP_LO $tag round-trip $trial (raw rb $rb)"
        else
            tt_fail "12b SWI_BIT_SLIP_LO $tag wrote $trial read $rb (low mismatch)"
        fi
    done
    tt_devmem_write "$IP" 0x44032104 "$orig"

    # --- 12c SWI_LANE_STATUS RO ---
    before=$(tt_devmem_read "$IP" 0x44032108)
    tt_devmem_write "$IP" 0x44032108 0xDEADBEEF
    after=$(tt_devmem_read "$IP" 0x44032108)
    if [ "$after" != "0xdeadbeef" ]; then
        tt_pass "12c SWI_LANE_STATUS $tag is RO (before=$before after=$after)"
    else
        tt_fail "12c SWI_LANE_STATUS $tag accepted write"
    fi

    # --- 12d NEGO_TRAIN_CFG round-trip (handle with care) ---
    orig=$(tt_devmem_read "$IP" 0x4403210C)
    for trial in 0x00000000 0x00000001 0x000000A5; do
        tt_devmem_write "$IP" 0x4403210C "$trial"
        rb=$(tt_devmem_read "$IP" 0x4403210C)
        tt_assert_eq "$trial" "$rb" "12d NEGO_TRAIN_CFG $tag round-trip $trial"
    done
    tt_devmem_write "$IP" 0x4403210C "$orig"

    # --- 12e NEGO_TRAIN_STEP W1P (writes pulse; reads return 0 or ECC count) ---
    # Read at idle should give ECC counters; pulse it, re-read; either accept
    # ECC view or 0 (build-dependent).
    before=$(tt_devmem_read "$IP" 0x44032114)
    tt_devmem_write "$IP" 0x44032114 0x1
    sleep 0.05
    after=$(tt_devmem_read "$IP" 0x44032114)
    # We just confirm the value didn't latch as exactly 0x1
    if [ "$after" != "0x00000001" ]; then
        tt_pass "12e NEGO_TRAIN_STEP $tag pulse did not latch as 0x1 (before=$before after=$after)"
    else
        tt_fail "12e NEGO_TRAIN_STEP $tag latched as 0x1 — RTL bug (should be W1P)"
    fi

    # --- 12f SWI_PHASE_OFFSET read-only sanity (do NOT write) ---
    v=$(tt_devmem_read "$IP" 0x44032118)
    if [ -n "$v" ]; then
        tt_pass "12f SWI_PHASE_OFFSET $tag readable ($v)"
    else
        tt_fail "12f SWI_PHASE_OFFSET $tag unreadable"
    fi

    # --- 12g SWI_TRAINING_MODE round-trip ---
    orig=$(tt_devmem_read "$IP" 0x44032100)
    for trial in 0x00000000 0x00000001 0x00000003; do
        tt_devmem_write "$IP" 0x44032100 "$trial"
        rb=$(tt_devmem_read "$IP" 0x44032100)
        # bits[1:0]; bit[1] may auto-clear after the recal sweep starts (W1P-ish)
        rb_low=$(( ($(printf '%d' "$rb")) & 0x3 ))
        t_low=$(( ($(printf '%d' "$trial")) & 0x3 ))
        # Accept exact match OR (training-mode bit[0] retained, recal bit[1] cleared).
        if [ "$rb_low" -eq "$t_low" ] || [ "$rb_low" -eq "$(( t_low & 0x1 ))" ]; then
            tt_pass "12g SWI_TRAINING_MODE $tag $trial -> $rb (W1P-aware OK)"
        else
            tt_fail "12g SWI_TRAINING_MODE $tag wrote $trial got $rb (low $rb_low vs $t_low)"
        fi
    done
    # Restore
    tt_devmem_write "$IP" 0x44032100 "$orig"
}

test_r8_on "$MASTER_IP" master
test_r8_on "$SLAVE_IP"  slave

tt_summary

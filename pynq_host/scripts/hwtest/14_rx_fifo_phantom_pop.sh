#!/bin/bash
# =============================================================================
# 14_rx_fifo_phantom_pop.sh — Category 14: RX-FIFO empty-read PHANTOM-POP guard.
#
# HARDWARE regression for the f9b94b7 phantom-pop fix (TL-022 / the silicon defect
# root-caused 2026-07-14 in tidelink_fifo_ctrl.sv: the `&& !rx_fifo_empty` guard).
#
# THE BUG: reading an EMPTY RX FIFO must be a NO-OP. Pre-fix, an empty-FIFO read of
# word0 armed the per-packet length latch from stale SRAM (read_target_addr =
# (len+1)<<2), and the very next sweep read fired read_complete and popped a
# PHANTOM packet: read_ptr WALKED (shifting every later aperture read) AND credit
# was minted ABOVE MAX (the exact silicon signature: CURRENT_CREDITS 4098 > 4096).
#
# THE SIM MIRROR: cocotb fifo_rx_phantom_pop (test_41/42) + fifo_rx_randinit
# (TL-022, adversarial SRAM init). This is the BOARD gate for the same contract:
# a regression that drops the guard re-mints phantom credit here too.
#
# CONTRACT (per die): after FLUSH (FIFO empty) + an empty-FIFO word0..word7 read
# sweep (the exact "drain" pattern a host driver uses), CURRENT_CREDITS must stay
# <= MAX and must NOT grow above the post-FLUSH baseline. A phantom pop mints
# credit above MAX; the guard makes the empty read inert.
#
# NON-VACUITY: the read sweep hits the real RX-FIFO data aperture (word0 is the
# arming read), so it reaches the same fifo_ctrl path the guard protects; if the
# guard is removed the credit assertion fails (mirrors the sim non-vacuity where
# removing the guard makes test_41 pop). Overrun sticky must NOT set.
#
# SAFETY: RX FIFO aperture READS only — never writes the FIFO window (that is the
# TX wedge hazard). APB observe otherwise. Board-validation: pending a rig run
# (rig = kr260-01 onchip / eth-chiplet pair); wire into run_all.sh once green.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="14_rx_fifo_phantom_pop"
tt_log "=== $CAT_NAME start ==="

CRED=0x4403200C      # Region0 CURRENT_CREDITS (13-bit; MAX ~4096)
STATUS=0x44032010    # Region0 STATUS (sticky errors [1..3])
FLUSH=0x4403201C     # write bit1 = FLUSH
MAXC=4096

test_phantom_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- empty the FIFO, snapshot the empty-state baseline ---
    tt_devmem_write "$IP" "$FLUSH" 0x2
    sleep 0.1
    base=$(( $(tt_devmem_read "$IP" "$CRED") ))
    s0=$(( $(tt_devmem_read "$IP" "$STATUS") ))
    tt_info "14 $tag post-FLUSH CURRENT_CREDITS=$base STATUS=$(printf 0x%08x "$s0") (empty baseline)"
    tt_assert_in_range 4090 4096 "$base" "14 $tag FIFO empty (credit at-max) at baseline"

    # --- phantom-pop trigger: empty-FIFO read sweep over the RX FIFO aperture ---
    # word0 (offset 0) arms the length latch; the following sequential reads are
    # the sweep that, PRE-fix, landed on read_target and popped a phantom packet.
    for off in 0 4 8 12 16 20 24 28; do
        addr=$(printf '0x%X' $(( TIDELINK_RXFIFO_BASE + off )))
        _=$(tt_devmem_read "$IP" "$addr")
    done
    sleep 0.1
    after=$(( $(tt_devmem_read "$IP" "$CRED") ))
    s1=$(( $(tt_devmem_read "$IP" "$STATUS") ))
    tt_info "14 $tag post-empty-sweep CURRENT_CREDITS=$after STATUS=$(printf 0x%08x "$s1")"

    # (1) credit must NOT exceed MAX — a phantom pop mints 4098 > 4096
    if [ "$after" -le "$MAXC" ]; then
        tt_pass "14 $tag credit <= MAX after empty-FIFO sweep ($after <= $MAXC)"
    else
        tt_fail "14 $tag PHANTOM POP: credit $after > MAX $MAXC (guard regressed)"
    fi
    # (2) credit must NOT grow above the empty baseline — a pop returns credit
    if [ "$after" -le "$base" ]; then
        tt_pass "14 $tag credit did not grow on empty read ($after <= $base)"
    else
        tt_fail "14 $tag PHANTOM POP: credit grew $base -> $after on an empty read"
    fi
    # (3) overrun sticky (bit2) must NOT have set from the empty read
    over=$(( (s1 >> 2) & 0x1 ))
    if [ "$over" -eq 0 ]; then
        tt_pass "14 $tag no overrun sticky after empty sweep"
    else
        tt_fail "14 $tag overrun sticky set by an empty-FIFO read (raw $(printf 0x%08x "$s1"))"
    fi
}

test_phantom_on "$MASTER_IP" master
test_phantom_on "$SLAVE_IP"  slave

tt_summary

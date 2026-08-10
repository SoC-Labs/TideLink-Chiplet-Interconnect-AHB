#!/bin/bash
# =============================================================================
# 03_ahb_sub_e2e.sh — Category 3: AHB SUB end-to-end through XHB500+Wlink+FC.
#
# The "SAFE" AHB datapath: writes here go through the FC adapter as ordinary
# sideband traffic and the receiving side ACKs locally. This is NOT the AHB_TX
# wedge-hazard path; HREADY is always asserted by the local AHB slave plumbing
# regardless of link state, so the host PS never stalls.
#
# However, the test is only MEANINGFUL when the link is up — otherwise the
# data never reaches the peer. We RUN it regardless (it won't wedge) but emit
# tt_skip for the peer-readback portion if the link is down.
#
# AHB SUB aperture (per address-translator): peer's AHB_SUB lives within
# pair_base_addr + offset. For this script we use APB registers as the proxy
# for "peer-visible side-effects" because they are RO-side-effect free; if a
# build exposes a dedicated AHB_SUB aperture for r/w of SRAM, replace POKE_OFF
# below with that aperture.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="03_ahb_sub_e2e"
tt_log "=== $CAT_NAME start ==="

# AHB SUB aperture address — TIDELINK_AHB_SUB_BASE per address map. Bridge1
# build exposes it at 0x4401_0000 (32 KB) per the chiplet-extended sys_desc.
: "${AHB_SUB_BASE:=0x44010000}"
: "${AHB_SUB_NWORDS:=64}"

# Pattern generator: deterministic, easy to spot wrong-data in dumps.
mk_pat() { printf '0x%08x' "$(( ($1 * 0x01010101) ^ 0xA5A5A5A5 ))"; }

run_storm_on() {
    local IP=$1 tag=$2
    tt_debug_unlock "$IP"

    # --- 3a single-word AHB SUB write/read on each side (LOCAL — must always
    # work; HREADY is locally returned) ---
    addr="$AHB_SUB_BASE"
    pat=$(mk_pat 1)
    tt_devmem_write "$IP" "$addr" "$pat"
    rb=$(tt_devmem_read "$IP" "$addr")
    if [ "$rb" = "$pat" ]; then
        tt_pass "3a AHB_SUB single-word write/read @ $tag ($addr=$pat)"
    else
        tt_fail "3a AHB_SUB single-word @ $tag (wrote $pat, read $rb)"
    fi

    # --- 3b AHB_SUB N-word storm with verification on the SAME side ---
    fails=0
    for i in $(seq 0 $(( AHB_SUB_NWORDS - 1 ))); do
        a=$(( AHB_SUB_BASE + i*4 )); p=$(mk_pat "$i")
        tt_devmem_write "$IP" "$a" "$p"
    done
    for i in $(seq 0 $(( AHB_SUB_NWORDS - 1 ))); do
        a=$(( AHB_SUB_BASE + i*4 )); p=$(mk_pat "$i")
        rb=$(tt_devmem_read "$IP" "$a")
        [ "$rb" != "$p" ] && fails=$((fails+1))
    done
    if [ "$fails" -eq 0 ]; then
        tt_pass "3b AHB_SUB $AHB_SUB_NWORDS-word storm $tag (all matched)"
    else
        tt_fail "3b AHB_SUB storm $tag — $fails/$AHB_SUB_NWORDS mismatches"
    fi
}

run_storm_on "$MASTER_IP" master
run_storm_on "$SLAVE_IP"  slave

# --- 3c sustained throughput indication. mmap-via-ssh is single-word, so this
# is a rough timing only (the slow path is ssh-RTT, not the AHB itself). We
# measure wall-clock per N-word burst and report — AND (added 2026-07-30,
# verification audit: the previous version called tt_pass unconditionally
# with no assertion at all, not even the vacuous-branch kind, so a burst that
# silently dropped writes would go unnoticed) read back a sample of the
# written words to confirm the burst itself didn't corrupt data, not just
# time it. ---
T0=$(date +%s.%N)
for i in $(seq 0 31); do
    a=$(( AHB_SUB_BASE + i*4 ))
    tt_devmem_write "$MASTER_IP" "$a" "0xCAFE$(printf '%04x' $i)"
done
T1=$(date +%s.%N)
elapsed=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.2f", b-a}')
tt_info "3c 32-word write burst on master: ${elapsed}s (ssh-RTT bound, indicative only)"
burst_ok=1
for i in 0 15 31; do
    a=$(( AHB_SUB_BASE + i*4 ))
    exp=$(printf '0xcafe%04x' "$i")
    rb=$(tt_devmem_read "$MASTER_IP" "$a")
    if [ "$rb" != "$exp" ]; then
        tt_fail "3c burst word $i corrupted: wrote $exp, read back $rb"
        burst_ok=0
    fi
done
[ "$burst_ok" -eq 1 ] && tt_pass "3c sustained-burst telemetry + sample readback OK (${elapsed}s)"

# --- 3d peer-visible side-effect: requires link up. Write to master's
# AHB_SUB and verify the *peer*'s AHB_SUB aperture took the same value
# (the AHB SUB cycle propagates through the FC node and lands at the
# remote AHB SUB slave). ---
if tt_verify_link_up >/dev/null 2>&1; then
    a=$AHB_SUB_BASE
    p=$(mk_pat 99)
    tt_devmem_write "$MASTER_IP" "$a" "$p"
    sleep 0.2
    rb=$(tt_devmem_read "$SLAVE_IP" "$a")
    if [ "$rb" = "$p" ]; then
        tt_pass "3d AHB_SUB peer-visible: master wrote $p, slave reads $rb"
    else
        # NOTE: this is the integration test that is hardest to get right;
        # depending on address-translator config it may legitimately not
        # propagate. Treat as info+fail so it surfaces, but log clearly.
        tt_fail "3d AHB_SUB peer-visible: master wrote $p, slave reads $rb (mapping or link issue)"
    fi
else
    tt_skip "3d AHB_SUB peer-visible (link not 16/16)"
fi

tt_summary

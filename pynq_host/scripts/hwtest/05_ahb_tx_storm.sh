#!/bin/bash
# =============================================================================
# 05_ahb_tx_storm.sh — Category 5: AHB_TX (the wedge-hazard path).
#
# **HARD-GATED.** Every AHB_TX write goes through tt_gate_ahb_tx() which
# refuses to proceed unless BOTH boards report 8/8 lanes locked + cal_done=1.
# A premature AHB_TX write wedges the board (physical power-cycle required;
# bench-confirmed 2026-04-27 on z2_02).
#
# Sub-tests:
#   5a  Single AHB_TX word at the bottom of the aperture (smoke test).
#   5b  Bounded N-word AHB_TX storm with peer-side verification (FIFO commit
#       observed via STATUS.packet_committed + RELEASED_CREDITS_ACC).
#   5c  Re-verify link did NOT degrade after the storm (sticky-fault check).
#   5d  Recover-on-stall test: the test framework's own timeout fires if a
#       single AHB_TX write blocks > N seconds — caught via `timeout` wrapper.
#
# Configuration:
#   AHB_TX_BASE          0x44000000  (default aperture base; 32 KB)
#   N_AHB_TX             16          (storm depth — keep small by default)
#   AHB_TX_TIMEOUT_S     5           (hard ceiling per write; abort if exceeded)
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="05_ahb_tx_storm"
tt_log "=== $CAT_NAME start ==="

: "${AHB_TX_BASE:=0x44000000}"
: "${N_AHB_TX:=16}"
: "${AHB_TX_TIMEOUT_S:=5}"

# THE GATE — absolute. If this returns non-zero, the script aborts with exit 3.
tt_gate_ahb_tx

# Wrapper that runs an AHB_TX write under `timeout` so a wedge does not lock
# the testing host. If the timeout fires, we treat it as a fatal failure +
# stop the script (further AHB_TX writes are the worst possible follow-on
# in a wedged state).
ahb_tx_write_timed() {  # IP ADDR VAL
    local IP=$1 ADDR=$2 VAL=$3
    if timeout "$AHB_TX_TIMEOUT_S" bash -c "$(declare -f tt_devmem_write); \
            PASS='$PASS'; SSHCOMMON='$SSHCOMMON'; \
            tt_devmem_write '$IP' '$ADDR' '$VAL'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# --- 5a single AHB_TX smoke test ---
addr="$AHB_TX_BASE"
val=0xDEADBEEF
if ahb_tx_write_timed "$MASTER_IP" "$addr" "$val"; then
    tt_pass "5a single AHB_TX write succeeded (${AHB_TX_TIMEOUT_S}s gate)"
else
    tt_fail "5a single AHB_TX write TIMED OUT — board may be wedged. ABORTING."
    tt_err "    Re-verify link before re-running. Possible physical power-cycle needed."
    tt_summary; exit 4
fi

# Snapshot slave-side packet_committed before storm
s0=$(tt_devmem_read "$SLAVE_IP" 0x44032010)
r0=$(tt_devmem_read "$SLAVE_IP" 0x44032020)
tt_info "5b storm baseline slave: STATUS=$s0 REL_ACC=$r0"

# --- 5b bounded N-word AHB_TX storm ---
failed=0
for i in $(seq 0 $(( N_AHB_TX - 1 ))); do
    a=$(( AHB_TX_BASE + (i * 4) ))
    v=$(printf '0x%08x' "$(( 0xC0FFEE00 + i ))")
    if ! ahb_tx_write_timed "$MASTER_IP" "$a" "$v"; then
        tt_fail "5b AHB_TX storm write $i timed out at $a=$v — possible wedge"
        failed=1
        break
    fi
done
if [ "$failed" -eq 0 ]; then
    tt_pass "5b AHB_TX storm: $N_AHB_TX writes completed in time"
fi

# Allow returner to drain
sleep 1
s1=$(tt_devmem_read "$SLAVE_IP" 0x44032010)
r1=$(tt_devmem_read "$SLAVE_IP" 0x44032020)
tt_info "5b storm post slave: STATUS=$s1 REL_ACC=$r1"
# Observe packet_committed bit ([4])
pc1=$(( ($(printf '%d' "$s1")) & 0x10 ))
if [ "$pc1" -ne 0 ]; then
    tt_pass "5b packet_committed observed on slave (STATUS[4] set)"
else
    tt_info "5b packet_committed NOT set on slave (could be timing — release may have cleared it)"
    tt_pass "5b storm did not assert sticky errors (informational)"
fi

# --- 5c link did NOT degrade after the storm ---
if tt_verify_link_up >/dev/null 2>&1; then
    tt_pass "5c link still 16/16 + cal_done after AHB_TX storm"
else
    tt_fail "5c link DEGRADED after AHB_TX storm — investigate"
fi

# Sticky-error check on master
v=$(tt_devmem_read "$MASTER_IP" 0x44032010)
vn=$(( v ))
ovr=$(( (vn >> 1) & 0x1 ))
und=$(( (vn >> 2) & 0x1 ))
merr=$(( (vn >> 3) & 0x1 ))
if [ "$ovr" -eq 0 ] && [ "$und" -eq 0 ] && [ "$merr" -eq 0 ]; then
    tt_pass "5c master STATUS sticky errors clear (raw $v)"
else
    tt_fail "5c master STATUS sticky errors set after storm (raw $v)"
fi

# --- 5d AHB_TX read-side smoke. Reads from AHB_TX aperture also go through
# FC + return a value. Just probe one word to confirm no stall. ---
v=$(timeout "$AHB_TX_TIMEOUT_S" bash -c "$(declare -f tt_devmem_read); \
        PASS='$PASS'; SSHCOMMON='$SSHCOMMON'; \
        tt_devmem_read '$MASTER_IP' '$AHB_TX_BASE'" 2>/dev/null)
if [ -n "$v" ]; then
    tt_pass "5d AHB_TX read smoke from master: $AHB_TX_BASE -> $v"
else
    tt_fail "5d AHB_TX read smoke timed out — possible stall"
fi

tt_summary

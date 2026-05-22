#!/bin/bash
# =============================================================================
# 01_wlink_layer.sh — Category 1: Wlink-layer HW tests.
#
# Exercises the per-lane PHY/byte-align/FC plumbing of Wlink on a paired
# bridge1 PYNQ-Z2. SAFE: this script only reads APB regs, toggles the
# debug_unlock GPIO, mucks with LaneMask (and restores), and rings the Region-8
# slot0 recal. It NEVER writes AHB_TX, so it is safe to run regardless of link
# state — though most assertions only PASS once the link is up.
#
# Sub-tests:
#   1a  PHY_ALIGN_ID identity              (Region 8 0x11C == 0x5041_0100)
#   1b  Lane-status snapshot               (R8 0x108, FCSM, cr_pkt, ECC)
#   1c  Wlink FC channel header sanity     (0x44030000+ regions per probe map)
#   1d  ECC corrupted/corrected counters   (R8 0x114) at idle vs under load
#   1e  Convergence reliability mini-sweep (N short re-deploys, distribution)
#   1f  Lane-mask fault injection          (mask one lane at a time, observe)
#   1g  Re-train cycle robustness          (recal_cycle N times, observe lock)
#
# Safety: no AHB_TX, no doorbell. Lane mask is restored on exit.
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

CAT_NAME="01_wlink_layer"
MINI_SWEEP_N="${MINI_SWEEP_N:-5}"   # default cheap; raise via env for full reliability sweep
RETRAIN_N="${RETRAIN_N:-5}"
DEPLOY_PAIR="${DEPLOY_PAIR:-$(dirname "$SCRIPT_DIR")/bringup_pair_converge.sh}"

tt_log "=== $CAT_NAME start ==="

# ---------------------------------------------------------------------------
# 1a — PHY_ALIGN_ID identity
# ---------------------------------------------------------------------------
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    tt_debug_unlock "$IP"
    v=$(tt_devmem_read "$IP" 0x4403211C)
    tt_assert_eq "0x50410100" "${v:-<unreadable>}" "1a PHY_ALIGN_ID @ $IP"
done

# ---------------------------------------------------------------------------
# 1b — Lane-status snapshot (informational + cal_done assertion if up)
# ---------------------------------------------------------------------------
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    s=$(tt_read_lane_status "$IP")
    tt_info "1b lane-status $IP: $s"
    pc=$(echo "$s" | awk '{print $4+0}')
    cd=$(echo "$s" | awk '{print $3+0}')
    if [ "$pc" -eq 8 ] && [ "$cd" -eq 1 ]; then
        tt_pass "1b $IP: 8/8 lanes locked, cal_done=1"
    else
        tt_skip "1b $IP: not at 8/8 ($pc/8 cal_done=$cd) — sub-tests requiring link will skip"
    fi
done

LINK_UP=1; tt_verify_link_up || LINK_UP=0

# ---------------------------------------------------------------------------
# 1c — Wlink FC channel header sanity
# Each FC region 0x1000+0x100*k has [0x00] byte-pattern, [0x04] channel-id,
# [0x10] cfg, [0x14] params. Just confirm no all-FF (= unmapped) returns.
# ---------------------------------------------------------------------------
FC_BASES="0x1000 0x1100 0x1200 0x1300 0x1400 0x1600 0x1700"
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    bad=0
    for base in $FC_BASES; do
        v=$(tt_devmem_read "$IP" "$(( 0x44030000 + base ))")
        case "$v" in
            "0xffffffff"|""|"0x00000000") bad=$((bad+1)) ;;
        esac
    done
    if [ "$bad" -eq 0 ]; then tt_pass "1c FC header sanity $IP (all 7 channels respond)"
    else tt_fail "1c FC header sanity $IP ($bad/7 channels look unmapped)"; fi
done

# ---------------------------------------------------------------------------
# 1d — ECC counters at idle (should be small and stable)
# R8 0x114: [15:0] corrupted, [31:16] corrected
# ---------------------------------------------------------------------------
for IP in "$MASTER_IP" "$SLAVE_IP"; do
    v=$(tt_devmem_read "$IP" 0x44032114)
    if [ -z "$v" ]; then tt_fail "1d ECC counters $IP unreadable"; continue; fi
    corrupted=$(( v & 0xFFFF ))
    corrected=$(( (v >> 16) & 0xFFFF ))
    tt_info "1d ECC $IP: corrupted=$corrupted corrected=$corrected (raw $v)"
    # Saturating at 0xFFFF means the PHY isn't delivering clean packets — fail
    if [ "$corrupted" -eq 65535 ]; then
        tt_fail "1d ECC corrupted SATURATED on $IP (PHY/byte-align is failing)"
    else
        tt_pass "1d ECC counters $IP not saturated"
    fi
done

# ---------------------------------------------------------------------------
# 1e — Convergence reliability mini-sweep (skip by default; opt-in via env)
# Heavy: deploys both boards N times. Only runs if RUN_RELIABILITY=1 or N>0
# AND DEPLOY_PAIR is executable.
# ---------------------------------------------------------------------------
if [ "${RUN_RELIABILITY:-0}" = "1" ] && [ -x "$DEPLOY_PAIR" ] && [ "$MINI_SWEEP_N" -ge 1 ]; then
    tt_info "1e reliability mini-sweep: N=$MINI_SWEEP_N (DEPLOY_PAIR=$DEPLOY_PAIR)"
    converged=0
    for i in $(seq 1 "$MINI_SWEEP_N"); do
        if MAX_RETRIES=4 BESTOF=3 "$DEPLOY_PAIR" >/dev/null 2>&1; then
            converged=$((converged+1))
        fi
        tt_info "  iter $i/$MINI_SWEEP_N: converged so far = $converged"
    done
    rate_x10=$(( converged * 10 / MINI_SWEEP_N ))
    tt_info "1e converged $converged/$MINI_SWEEP_N (~$((converged*100/MINI_SWEEP_N))%)"
    if [ "$converged" -ge "$(( (MINI_SWEEP_N * 8) / 10 ))" ]; then
        tt_pass "1e reliability >=80% convergence"
    else
        tt_fail "1e reliability <80% convergence ($converged/$MINI_SWEEP_N)"
    fi
else
    tt_skip "1e reliability mini-sweep (RUN_RELIABILITY!=1 or DEPLOY_PAIR missing)"
fi

# ---------------------------------------------------------------------------
# 1f — Lane-mask fault injection (skip unless link is up)
# Wlink LaneMask at 0x4403_0214: tx=[15:0], rx=[31:16]. Mask one lane at a time
# on the master TX side; observe slave's locked byte. Restore on exit.
# Trap ensures restore even on SIGINT.
# ---------------------------------------------------------------------------
ORIG_MASK_M=""; ORIG_MASK_S=""
restore_mask() {
    [ -n "$ORIG_MASK_M" ] && tt_devmem_write "$MASTER_IP" 0x44030214 "$ORIG_MASK_M"
    [ -n "$ORIG_MASK_S" ] && tt_devmem_write "$SLAVE_IP"  0x44030214 "$ORIG_MASK_S"
}
trap restore_mask EXIT

if [ "$LINK_UP" -eq 1 ]; then
    ORIG_MASK_M=$(tt_devmem_read "$MASTER_IP" 0x44030214)
    ORIG_MASK_S=$(tt_devmem_read "$SLAVE_IP"  0x44030214)
    tt_info "1f orig LaneMask: master=$ORIG_MASK_M slave=$ORIG_MASK_S"
    # Mask each of lanes 0..7 on master TX side, observe slave RX popcount.
    for lane in 0 1 2 3 4 5 6 7; do
        # Clear bit `lane` of tx-mask [15:0]; keep rx-mask [31:16] intact.
        mask_word=$(( (${ORIG_MASK_M:-0xFFFFFFFF}) & ~(1 << lane) ))
        tt_devmem_write "$MASTER_IP" 0x44030214 "$mask_word"
        sleep 0.3
        spc=$(tt_link_popcount "$SLAVE_IP")
        if [ "${spc:-9}" -le 7 ]; then
            tt_pass "1f mask-lane $lane on master: slave popcount degraded to $spc"
        else
            tt_fail "1f mask-lane $lane on master: slave still reports $spc (mask not effective)"
        fi
        # Restore between iterations
        tt_devmem_write "$MASTER_IP" 0x44030214 "$ORIG_MASK_M"
        sleep 0.2
    done
else
    tt_skip "1f lane-mask fault injection (link not 16/16)"
fi

# ---------------------------------------------------------------------------
# 1g — Re-train cycle robustness: drive Region-8 slot0 recal N times,
# observe popcount each time. Identical pattern to phase_recal_sweep.sh's
# recal_cycle.
# ---------------------------------------------------------------------------
if [ "$LINK_UP" -eq 1 ]; then
    drops=0
    for i in $(seq 1 "$RETRAIN_N"); do
        # Coordinated recal: slot0=0x3 (train+recal) both sides, settle,
        # slot0=0x1 (recal release).
        tt_devmem_write "$MASTER_IP" 0x44032100 0x3 &
        tt_devmem_write "$SLAVE_IP"  0x44032100 0x3 &
        wait
        sleep 0.3
        tt_devmem_write "$MASTER_IP" 0x44032100 0x1 &
        tt_devmem_write "$SLAVE_IP"  0x44032100 0x1 &
        wait
        sleep 2
        mpc=$(tt_link_popcount "$MASTER_IP"); spc=$(tt_link_popcount "$SLAVE_IP")
        tt_info "1g retrain $i/$RETRAIN_N: master=$mpc/8 slave=$spc/8"
        if [ "${mpc:-0}" -lt 8 ] || [ "${spc:-0}" -lt 8 ]; then
            drops=$((drops+1))
        fi
    done
    if [ "$drops" -eq 0 ]; then
        tt_pass "1g retrain robustness: 0 drops in $RETRAIN_N cycles"
    else
        tt_fail "1g retrain robustness: $drops/$RETRAIN_N cycles failed to relock"
    fi
else
    tt_skip "1g retrain robustness (link not 16/16)"
fi

tt_summary

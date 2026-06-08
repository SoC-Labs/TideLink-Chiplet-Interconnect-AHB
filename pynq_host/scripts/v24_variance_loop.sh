#!/usr/bin/env bash
# =============================================================================
# v24_variance_loop.sh — 10-attempt bilateral bring-up variance test for v24
# (M6+M8 calibrator + SYNC framing-recovery + credit-recovery + deskew + S→M fix)
# fix/build9-unified branch.
# Target: >=9/10 bilateral (match v23 baseline at 10/10).
#
# M6+M8 recap: slave's calibrator keeps training_mode=1 throughout S_VALIDATE
# (2M-cycle window at 6.25MHz link_clk = 320ms). Master sweeps during that
# window, locks, enters S_VALIDATE itself. Slave's timer fires → S_DONE →
# slave FCSM active → CR sent → master cr_pkt_seen fires → master S_DONE.
#
# SYNC fix: TX inserts F1E2_D3C4...1F00 every 32 idle words; RX detects and
# resets byte-align FSM → self-heals after training→data mux flip.
#
# Run ON mapstone-dev after staging artefacts to /tmp/td_v24_priv/:
#   chmod +x /tmp/td_v24_priv/v24_variance_loop.sh
#   nohup /tmp/td_v24_priv/v24_variance_loop.sh > /tmp/v24_variance.log 2>&1 &
#   tail -f /tmp/v24_variance.log
# =============================================================================
set -u

ARTEFACTS="/tmp/td_v24_priv"
DEPLOY="$ARTEFACTS/deploy_pair.sh"
PROBE="$ARTEFACTS/probe_autoneg_obs.sh"

BOARD_A="192.168.4.101"   # z2_02 master (non-flip)
BOARD_B="192.168.6.101"   # z2_03 slave  (flip)

ATTEMPTS="${ATTEMPTS:-10}"
COOLDOWN="${COOLDOWN:-30}"   # seconds between attempts
SETTLE="${SETTLE:-90}"       # 90s — M8 S_VALIDATE timer is 320ms (<<90s),
                             # but autoneg + I2C coordination adds seconds

both=0 master_only=0 slave_only=0 neither=0

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "=== attempt $attempt / $ATTEMPTS ($(date -u +%H:%M:%SZ)) ==="

    # Deploy both boards concurrently (non-flip to A, flip to B)
    bash "$DEPLOY" "$BOARD_A" z2_02 die_a "$ARTEFACTS" &
    PID_A=$!
    bash "$DEPLOY" "$BOARD_B" z2_03 die_b "$ARTEFACTS" &
    PID_B=$!
    wait "$PID_A" || true
    wait "$PID_B" || true

    echo "  [deployed — settling ${SETTLE}s]"
    sleep "$SETTLE"

    # Probe both boards
    m_out=$(bash "$PROBE" "$BOARD_A" z2_02_master 2>/dev/null || echo "PROBE_ERR")
    s_out=$(bash "$PROBE" "$BOARD_B" z2_03_slave  2>/dev/null || echo "PROBE_ERR")

    # Parse cal_done
    m_caldone=$(echo "$m_out" | grep -oP '(?<=cal_done=)[01]' | head -1)
    s_caldone=$(echo "$s_out" | grep -oP '(?<=cal_done=)[01]' | head -1)

    # Parse cal_state
    m_state=$(echo "$m_out" | grep -oP 'cal_state=\d+ \(\K[^)]+' | head -1 || echo "?")
    s_state=$(echo "$s_out" | grep -oP 'cal_state=\d+ \(\K[^)]+' | head -1 || echo "?")

    # Parse resweep counter
    m_rsw=$(echo "$m_out" | grep -oP '(?<=resweep_ctr=)\d+' | head -1 || echo "0")
    s_rsw=$(echo "$s_out" | grep -oP '(?<=resweep_ctr=)\d+' | head -1 || echo "0")

    # Parse lane_locked
    m_locked=$(echo "$m_out" | grep -oP '(?<=lane_locked=)0x[0-9a-f]+' | head -1 || echo "?")
    s_locked=$(echo "$s_out" | grep -oP '(?<=lane_locked=)0x[0-9a-f]+' | head -1 || echo "?")

    # Parse FCSM state
    m_fcsm=$(echo "$m_out" | grep -oP '(?<=fcsm_state=)\d+' | head -1 || echo "?")
    s_fcsm=$(echo "$s_out" | grep -oP '(?<=fcsm_state=)\d+' | head -1 || echo "?")

    printf "  attempt %2d: M=%s [locked=%s state=%s rsw=%s fcsm=%s]  S=%s [locked=%s state=%s rsw=%s fcsm=%s]\n" \
        "$attempt" \
        "${m_caldone:-?}" "${m_locked:-?}" "${m_state:-?}" "${m_rsw:-?}" "${m_fcsm:-?}" \
        "${s_caldone:-?}" "${s_locked:-?}" "${s_state:-?}" "${s_rsw:-?}" "${s_fcsm:-?}"

    m_caldone="${m_caldone:-0}"; m_caldone="${m_caldone//[^01]/0}"
    s_caldone="${s_caldone:-0}"; s_caldone="${s_caldone//[^01]/0}"
    if   [[ "$m_caldone" -eq 1 && "$s_caldone" -eq 1 ]]; then both=$((both+1))
    elif [[ "$m_caldone" -eq 1 && "$s_caldone" -eq 0 ]]; then master_only=$((master_only+1))
    elif [[ "$m_caldone" -eq 0 && "$s_caldone" -eq 1 ]]; then slave_only=$((slave_only+1))
    else                                                       neither=$((neither+1))
    fi

    if [[ "$attempt" -lt "$ATTEMPTS" ]]; then
        echo "  [cooling down ${COOLDOWN}s]"
        sleep "$COOLDOWN"
    fi
done

echo ""
echo "=== v24 SUMMARY (M6+M8 + SYNC + credit-recovery + deskew + S→M fix) ==="
echo "  both=$both master_only=$master_only slave_only=$slave_only neither=$neither  (target: both>=9)"
echo "=== v23 baseline was: both=10 master_only=0 slave_only=0 neither=0 ==="

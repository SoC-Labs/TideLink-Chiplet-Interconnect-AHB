#!/usr/bin/env bash
# =============================================================================
# v21_variance_loop.sh — 10-attempt bilateral bring-up variance test for v21
# (M1+M2+M7+M4b+M4e+M5 leaky-decrement calibrator scoring).
#
# Run ON mapstone-dev after staging artefacts to /tmp/td_v21_priv/:
#   chmod +x /tmp/td_v21_priv/v21_variance_loop.sh
#   nohup /tmp/td_v21_priv/v21_variance_loop.sh > /tmp/v21_variance.log 2>&1 &
# =============================================================================
set -u

ARTEFACTS="/tmp/td_v21_priv"
DEPLOY="$ARTEFACTS/deploy_pair.sh"
PROBE="$ARTEFACTS/probe_autoneg_obs.sh"

BOARD_A="192.168.4.101"   # z2_02 master (non-flip)
BOARD_B="192.168.6.101"   # z2_03 slave  (flip)

ATTEMPTS="${ATTEMPTS:-10}"
COOLDOWN="${COOLDOWN:-30}"   # seconds between attempts
SETTLE="${SETTLE:-50}"       # seconds after deploy before probing

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

    # Probe both boards using the standard probe script
    m_out=$(bash "$PROBE" "$BOARD_A" z2_02_master 2>/dev/null || echo "PROBE_ERR")
    s_out=$(bash "$PROBE" "$BOARD_B" z2_03_slave  2>/dev/null || echo "PROBE_ERR")

    # Parse cal_done from "cal_done=N" in probe output (from swi_lane_status line)
    m_caldone=$(echo "$m_out" | grep -oP '(?<=cal_done=)[01]' | head -1)
    s_caldone=$(echo "$s_out" | grep -oP '(?<=cal_done=)[01]' | head -1)

    # Parse cal_state from OBS_CAL: "cal_state=N (NAME)"
    m_state=$(echo "$m_out" | grep -oP '(?<=cal_state=)\d+ \(\K[^)]+' | head -1 || echo "?")
    s_state=$(echo "$s_out" | grep -oP '(?<=cal_state=)\d+ \(\K[^)]+' | head -1 || echo "?")

    # Parse resweep counter from "resweep_ctr=N"
    m_rsw=$(echo "$m_out" | grep -oP '(?<=resweep_ctr=)\d+' | head -1 || echo "0")
    s_rsw=$(echo "$s_out" | grep -oP '(?<=resweep_ctr=)\d+' | head -1 || echo "0")

    # Parse lane_locked from "lane_locked=0xNN"
    m_locked=$(echo "$m_out" | grep -oP '(?<=lane_locked=)0x[0-9a-f]+' | head -1 || echo "?")
    s_locked=$(echo "$s_out" | grep -oP '(?<=lane_locked=)0x[0-9a-f]+' | head -1 || echo "?")

    printf "  attempt %2d: M=%s [locked=%s state=%s rsw=%s]  S=%s [locked=%s state=%s rsw=%s]\n" \
        "$attempt" \
        "${m_caldone:-?}" "${m_locked:-?}" "${m_state:-?}" "${m_rsw:-?}" \
        "${s_caldone:-?}" "${s_locked:-?}" "${s_state:-?}" "${s_rsw:-?}"

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

echo "=== v21 SUMMARY: both=$both master_only=$master_only slave_only=$slave_only neither=$neither ==="

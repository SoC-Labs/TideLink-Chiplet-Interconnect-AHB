#!/usr/bin/env bash
# kr260_eth_bringup_pair.sh — turnkey eth-chiplet PAIR bring-up with a bounded
#                             ANCHOR-PAIR RETRY GATE.
#
# The AUTO_ANCHOR beacon (RTL) latches the deskew re-anchor autonomously at
# bring-up, but WHETHER it latches is a marginal-eye lottery per bring-up (the
# same lottery as reaching FCSM=4). This orchestrator runs BOTH dies' bring-up
# concurrently (they self-synchronise on cal_done) and RETRIES the whole pair
# bring-up — each retry re-runs winscan = a fresh eye — until the pair passes
# the gate, or MAX_TRIES is exhausted.
#
# WHAT CHANGED (2026-08-14) AND WHY
# ---------------------------------
# The accept test used to be "BOTH dies report RE-ANCHORED". The n=20 overnight
# campaign (imp/hw_gate/overnight/) showed that is the wrong bar in both
# directions:
#
#   * TOO STRICT — NO/NO (8 runs) and NO/YES (4 runs) ALL delivered 16/16
#     byte-exact. Requiring YES/YES throws away 15/20 perfectly good bring-ups,
#     and at the measured p(YES/YES)=0.25 an 8-try budget still fails ~10% of
#     the time.
#   * TOO BLUNT — the 3 delivery failures were EXACTLY the YES/NO pairs (die_a
#     re-anchored, die_b did not), 3/3 at 0/16. `fcsm=4` was true in all 20 runs,
#     so no pre-existing health check could see this.
#
# So the accept test is now: reject the YES/NO pair, accept the other three.
# The predicate itself lives in ONE place — anchor_pair_gate.py — which is the
# same code the retrospective validator replays over the 20 known-outcome runs
# (imp/hw_gate/anchor_gate/). Do not re-implement it here.
#
# HONESTY: n=3 on the failing arm. Three-for-three is suggestive, not settled,
# and the campaign cannot separate predictor from symptom (the live hypothesis
# is anchor-as-WITNESS). This gate is a CHEAP MITIGATION, not a proven mechanism.
# That is why every attempt is logged and the final attempt count is printed:
# any "works ~100%" claim built on this must carry its retry cost with it.
#
#   DIE_A=ubuntu@10.22.24.159 DIE_B=ubuntu@10.22.24.153 KR260_PASSWORD=... \
#       [MAX_TRIES=8] [ANCHOR_GATE_MODE=pair|both|off] bash kr260_eth_bringup_pair.sh
#
# Knobs:
#   MAX_TRIES         retry budget                              (default 8)
#   ANCHOR_GATE_MODE  pair (measured gate) | both (legacy)
#                     | off (link-up only, baseline-comparable) (default pair)
#   PAIR_LOG_DIR      where per-attempt logs land                (default /tmp)
#   BU_LOG_A/BU_LOG_B canonical final-attempt log paths
#                     (default $PAIR_LOG_DIR/bu_{a,b}.log)
#   PAIR_BU_TIMEOUT   per-die bring-up timeout, seconds          (default 300)
#   PAIR_DELIVERY_PROBE  optional command run after the gate ACCEPTs; non-zero
#                     exit re-rolls the bring-up. Default unset (see NOTE below).
#
# Exit 0 = gate ACCEPTed; 1 = retry budget exhausted; 2 = staging fail.
set -u
A=${DIE_A:-ubuntu@10.22.24.159}; B=${DIE_B:-ubuntu@10.22.24.153}
PW=${KR260_PASSWORD:-soclabs2026}
MAX_TRIES=${MAX_TRIES:-8}
ANCHOR_GATE_MODE=${ANCHOR_GATE_MODE:-pair}
PAIR_BU_TIMEOUT=${PAIR_BU_TIMEOUT:-300}
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/kr260_eth_run.sh"
GATE="$HERE/anchor_pair_gate.py"

PAIR_LOG_DIR=${PAIR_LOG_DIR:-/tmp}
mkdir -p "$PAIR_LOG_DIR" 2>/dev/null
BU_LOG_A=${BU_LOG_A:-$PAIR_LOG_DIR/bu_a.log}
BU_LOG_B=${BU_LOG_B:-$PAIR_LOG_DIR/bu_b.log}
TRAIL="$PAIR_LOG_DIR/anchor_gate_trail.log"
: > "$TRAIL"

log(){ echo "$*" | tee -a "$TRAIL"; }

# Refresh the DEPLOYED bring-up recipe on both boards (kr260_eth_run.sh runs
# ~/td/scripts/kr260_eth_bringup.py; the copy from `deploy` may predate the
# EPOCH_STATUS re-anchor poll this orchestrator keys on).
DEST_DIR=${KR260_DEST:-td}/scripts
for h in "$A" "$B"; do
  sshpass -p "$PW" scp -q -o StrictHostKeyChecking=no "$HERE/kr260_eth_bringup.py" \
      "$h:$DEST_DIR/kr260_eth_bringup.py" 2>/dev/null \
    || { echo "stage recipe to $h:$DEST_DIR FAILED"; exit 2; }
done

[ -r "$GATE" ] || { echo "anchor_pair_gate.py not found at $GATE"; exit 2; }

_bu(){ KR260_HOST="$1" KR260_ETH_ROLE="$2" KR260_PASSWORD="$PW" \
       timeout "$PAIR_BU_TIMEOUT" bash "$RUN" bringup 2>&1; }

log "=== anchor-pair gate: mode=$ANCHOR_GATE_MODE budget=$MAX_TRIES tries ==="

verdict=EXHAUSTED
used=0
for t in $(seq 1 "$MAX_TRIES"); do
  used=$t
  la="$PAIR_LOG_DIR/bu_a.try${t}.log"
  lb="$PAIR_LOG_DIR/bu_b.try${t}.log"
  _bu "$A" die_a > "$la" 2>&1 &
  pa=$!
  _bu "$B" die_b > "$lb" 2>&1 &
  pb=$!
  wait $pa; wait $pb

  # The canonical names always hold the MOST RECENT attempt, so every downstream
  # consumer that parses 04_bringup_{a,b}.log keeps working unchanged — while the
  # per-try logs preserve the full retry history for audit.
  cp -f "$la" "$BU_LOG_A" 2>/dev/null
  cp -f "$lb" "$BU_LOG_B" 2>/dev/null

  log "-- try $t/$MAX_TRIES --"
  python3 "$GATE" --log-a "$la" --log-b "$lb" --mode "$ANCHOR_GATE_MODE" \
      2>&1 | tee -a "$TRAIL"
  rc=${PIPESTATUS[0]}

  case "$rc" in
    0)  # Gate ACCEPTed the pair. Optional extra qualification before we commit.
        # NOTE: default UNSET on purpose. MVP_SCOPE M2(b) wants the accept test
        # extended with a byte-exact delivery probe (reanchored=1 + FCSM=4 do NOT
        # imply a good eye — TL-031). That probe is real work on the rig and has
        # NOT been validated here, so it is a hook, not a default: wiring an
        # unvalidated cross-die write into every bring-up is exactly how you turn
        # a precondition into a new wedge source.
        if [ -n "${PAIR_DELIVERY_PROBE:-}" ]; then
          log "   gate ACCEPT — running PAIR_DELIVERY_PROBE"
          if ! eval "$PAIR_DELIVERY_PROBE" >> "$TRAIL" 2>&1; then
            log "   delivery probe FAILED — treating as a bad eye, re-rolling"
            continue
          fi
          log "   delivery probe OK"
        fi
        verdict=ACCEPT
        break ;;
    10) log "   -> re-rolling the bring-up (fresh winscan = fresh eye)" ;;
    11) log "   -> UNKNOWN pair state (fail-closed): re-rolling. Check $la / $lb" ;;
    *)  log "   -> gate tool error rc=$rc; treating as re-roll" ;;
  esac
done

# --- machine-readable summary ------------------------------------------------
# Retry cost is part of the result, never a footnote: a reliability claim built
# on this gate is only honest when quoted together with attempts_used.
# NB: `grep -c` exits 1 on zero matches, so it must NOT be chained with `|| echo`
# (that emits two lines and corrupts the arithmetic test below).
ga=0; [ -r "$BU_LOG_A" ] && ga=$(grep -c "^RESULT: RE-ANCHORED" "$BU_LOG_A" 2>/dev/null)
gb=0; [ -r "$BU_LOG_B" ] && gb=$(grep -c "^RESULT: RE-ANCHORED" "$BU_LOG_B" 2>/dev/null)
[ -n "$ga" ] || ga=0; [ -n "$gb" ] || gb=0
pair_str="$([ "$ga" -ge 1 ] && echo YES || echo NO)/$([ "$gb" -ge 1 ] && echo YES || echo NO)"
log "ANCHOR_GATE_SUMMARY verdict=$verdict mode=$ANCHOR_GATE_MODE attempts_used=$used budget=$MAX_TRIES final_pair=$pair_str"

if [ "$verdict" = ACCEPT ]; then
  log "PAIR ACCEPTED on try $used/$MAX_TRIES (anchor pair $pair_str, gate mode $ANCHOR_GATE_MODE)."
  exit 0
fi
log "PAIR did NOT pass the anchor gate in $MAX_TRIES tries (marginal rig; characterise eye)."
exit 1

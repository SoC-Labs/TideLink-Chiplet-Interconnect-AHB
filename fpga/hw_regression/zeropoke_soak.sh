#!/bin/bash
# =============================================================================
# zeropoke_soak.sh — N consecutive fresh-POR zero-poke cycles, arm-order swept
#
# Runs zeropoke_proof.sh N times, each a genuine fresh POR (reflash), with the
# arm order ALTERNATING a,b,a,b,... and the FINAL cycle armed near-
# simultaneously (both) — so a single soak covers every arm-order class the
# silicon has shown order-sensitivity on. One machine-parseable scorecard line
# per cycle + a final N/M summary split by arm order. Exit 0 iff every cycle's
# (h) data gate passed.
#
# USAGE (lab host with board SSH, e.g. mapstone-dev):
#   ./zeropoke_soak.sh N [--stagger SEC] [--budget SEC] [--no-lease]
#     N           number of cycles (>=1). Cycle i arm order: a (odd), b (even),
#                 both (last cycle when N>=2).
#     --stagger   passed through to zeropoke_proof.sh (default 0)
#     --budget    per-cycle watch budget seconds (default 240)
#     --no-lease  caller already holds the lease (acquired once for the whole
#                 soak either way — never per-cycle)
#
# STATISTICS MODE (FIX-4 2026-07-04):
#   ./zeropoke_soak.sh --stats N [--stagger SEC] [--budget SEC] [--no-lease]
#     N fresh-POR cycles scored ONLY through step (f): per die per roll the
#     WS_FINALIZE anchor outcome (winscan_done / anchor-timeout sticky
#     0x21B8[2] / reanchored 0x2140[0]) + the FIX-4 ATTEMPT COUNTER
#     (0x21B8[13:11] — how many clear-retries the episode burned). NO (g)/(h)
#     data gating, fast cadence (arm -> poll winscan_done both dies -> score
#     -> next POR). Output: one ZP_STATS_CYCLE line per roll, a CSV, and a
#     final per-die convergence-rate + attempt-histogram table — this turns
#     the ~coin-flip per-die re-latch lottery (8 rolls / 4 builds) into a
#     measurable RATE. The histogram is the compounding-model validator:
#     independent ~50% windows predict attempts distributed geometrically
#     (~50% att=0, ~25% att=1, ...) and >90% convergence within the budget
#     of 5; correlated retries (the pre-FIX-4 constant-hold pathology) show
#     bimodal att=0-or-exhausted. Per-die outcome classes:
#       OK       done=1, 0x21B8[2]=0, reanchored=1  (clean re-latch)
#       LATE     done=1, [2]=1 but reanchored=1     (failed open, healed late)
#       FAILOPEN done=1, [2]=1, reanchored=0        (the lottery loser)
#       NODONE   winscan_done never rose in budget  (chain stalled pre-(f))
#       STALEIP  0x21B8[31:24] != 0x57              (stale package_ip build)
#
# Logs: each cycle's full proof output lands in
#   ${TD_SOAK_DIR:-$HOME/td_zeropoke_soak}/<UTC-stamp>/cycle_<i>_<order>.log
#   (stats mode: stats.csv + per-cycle lines on stdout, same directory)
# First-use validation pending (no boards attached at authoring time).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

N=""; STAGGER=0; BUDGET=240; DO_LEASE=1; STATS=0
while [ $# -gt 0 ]; do case "$1" in
  --stats)   STATS=1; N=$2; shift;;
  --stagger) STAGGER=$2; shift;;
  --budget)  BUDGET=$2; shift;;
  --no-lease) DO_LEASE=0;;
  -h|--help) sed -n '2,52p' "$0"; exit 0;;
  *) if [ -z "$N" ]; then N=$1; else echo "unknown arg: $1"; exit 2; fi;;
esac; shift; done
case "$N" in ''|*[!0-9]*) echo "usage: $0 N [--stagger SEC]  |  $0 --stats N"; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1"; exit 2; }

OUTDIR="${TD_SOAK_DIR:-$HOME/td_zeropoke_soak}/$(date -u +%Y%m%d_%H%M%SZ)"
mkdir -p "$OUTDIR"

boards_up || { echo "### ABORT: a board is unreachable ($A_IP / $B_IP)"; exit 3; }
if [ "$DO_LEASE" = 1 ]; then
  # one lease for the whole soak (~N * budget), never per-cycle
  lease_acquire $(( N * (BUDGET + 180) + 300 )) || { echo "### ABORT: no $LEASE_NAME lease"; exit 3; }
  trap 'lease_release' EXIT
fi

# ===== --stats N: anchor-statistics mode (FIX-4 2026-07-04) ====================
# Scores each fresh-POR roll ONLY through step (f). Reads per poll: ONE
# WINSCAN_OBS word per die (throttled rd_d); reanchored read once at terminal
# — fast cadence, PS-safe. Never writes anything but the two zp_arm words.
zps_order(){ # cycle index -> arm order (the soak's proven rotation)
  if [ "$N" -ge 2 ] && [ "$1" -eq "$N" ]; then echo both
  elif [ $(( $1 % 2 )) -eq 1 ]; then echo a
  else echo b; fi; }

# Arm, VERIFYING each die actually took the arm. zp_arm returns 1 if NEGO_CFG
# reads back with nego_en=0 (its POR value is 0x00) or the bus is dead. A cycle
# in which either die failed to arm is a NON-TEST and must be scored VOID, never
# NODONE — the two are indistinguishable at 0x21B8 (both read 0x57000000) and
# conflating them is what produced the bogus "die_a 42%" statistic.
# Bounded retry (ZP_ARM_TRIES, default 3) then continue. An UNARMED cycle is a
# NON-TEST: it is EXCLUDED from the autonomy denominator rather than scored as a
# failure. The UNARMED count is itself the evidence if the arm path is broken.
ZPS_ARM_OK=1
zps_arm(){ ZPS_ARM_OK=1
  case "$1" in
  a)    zp_arm_retry a || ZPS_ARM_OK=0; [ "$STAGGER" -gt 0 ] && sleep "$STAGGER"; zp_arm_retry b || ZPS_ARM_OK=0;;
  b)    zp_arm_retry b || ZPS_ARM_OK=0; [ "$STAGGER" -gt 0 ] && sleep "$STAGGER"; zp_arm_retry a || ZPS_ARM_OK=0;;
  both) zp_arm_retry a || ZPS_ARM_OK=0; zp_arm_retry b || ZPS_ARM_OK=0;;
esac; }

# classify one die's terminal state: $1=ws(0x21B8) $2=rea $3=done-ever $4=armed(0/1)
# `armed` is autonomy_armed = nego_en & role_locked & train_auto_en. With armed=0
# the winscan FSM is gated off entirely (it gates ws_kick_evt AND the FIX-1
# catchup), so ws reads 0x57000000 with every per-episode counter at 0. That is
# NOT a winscan failure and must never be scored as one.
zps_classify(){ local ws=$1 rea=$2 done_ever=$3 armed=${4:-1}
  if [ $(( (ws>>24)&0xff )) -ne $(( 0x57 )) ]; then echo STALEIP
  elif [ "$armed" -eq 0 ]; then echo UNARMED
  elif [ "$done_ever" -eq 0 ]; then echo NODONE
  elif [ $(( (ws>>2)&1 )) -eq 0 ] && [ "$rea" -eq 1 ]; then echo OK
  elif [ "$rea" -eq 1 ]; then echo LATE
  else echo FAILOPEN; fi; }

if [ "$STATS" = 1 ]; then
  CSV="$OUTDIR/stats.csv"
  echo "cycle,order,die,outcome,attempts,winscan_obs,reanchored,t_done_s,autonomy_armed,obs_mask_hs" > "$CSV"
  echo "======== zeropoke_soak STATS mode N=$N stagger=${STAGGER}s budget=${BUDGET}s ($(date)) ========"
  echo "  scoring through step (f) only; csv: $CSV"
  declare -A HIST_A HIST_B OUT_CNT_A OUT_CNT_B
  A_OK=0; B_OK=0; BOTH_OK=0
  A_N=0; B_N=0; A_UNARMED=0; B_UNARMED=0   # armed-only denominators + non-test counts
  for i in $(seq 1 "$N"); do
    order=$(zps_order "$i")
    echo "-- stats cycle $i/$N (first=$order): fresh POR --"
    zp_quiesce            # never reload the PL on a live link (see td_v2_hwlib.sh)
    deploy_pair; sleep 2
    zps_arm "$order"
    cT0=$(date +%s)
    da=0; db=0; ta="."; tb="."; wsa=0; wsb=0
    while :; do
      el=$(( $(date +%s) - cT0 ))
      [ "$el" -lt "$BUDGET" ] || break
      wsa=$(( $(rd_d a $R_WINSCAN_OBS) )); wsb=$(( $(rd_d b $R_WINSCAN_OBS) ))
      [ "$da" -eq 0 ] && [ $(( wsa&1 )) -eq 1 ] && { da=1; ta=$el; }
      [ "$db" -eq 0 ] && [ $(( wsb&1 )) -eq 1 ] && { db=1; tb=$el; }
      [ "$da" -eq 1 ] && [ "$db" -eq 1 ] && break
      sleep 3
    done
    # terminal snapshot (attempts settle with done; re-read for the late case)
    wsa=$(( $(rd_d a $R_WINSCAN_OBS) )); wsb=$(( $(rd_d b $R_WINSCAN_OBS) ))
    ra=$(reanchored_d a); rb=$(reanchored_d b)
    aa=$(( (wsa>>11)&7 )); ab=$(( (wsb>>11)&7 ))
    # autonomy_armed + the autoneg role-lock chain. Without these, a 0x57000000
    # obs word is uninterpretable: an unarmed die and a genuinely stuck winscan
    # look identical. Capture them BEFORE classifying.
    arma=$(armed_d a); armb=$(armed_d b)
    mha=$(( $(maskhs_d a) )); mhb=$(( $(maskhs_d b) ))
    oa=$(zps_classify "$wsa" "$ra" "$da" "$arma"); ob=$(zps_classify "$wsb" "$rb" "$db" "$armb")
    printf 'ZP_STATS_CYCLE i=%d/%d order=%s a=%s att_a=%d b=%s att_b=%d ws_a=0x%08x ws_b=0x%08x rea_a=%d rea_b=%d armed_a=%d armed_b=%d lockpend_a=%d lockpend_b=%d t_a=%ss t_b=%ss\n' \
      "$i" "$N" "$order" "$oa" "$aa" "$ob" "$ab" "$wsa" "$wsb" "$ra" "$rb" \
      "$arma" "$armb" $(( (mha>>18)&1 )) $(( (mhb>>18)&1 )) "$ta" "$tb"
    echo "$i,$order,a,$oa,$aa,$(printf 0x%08x "$wsa"),$ra,$ta,$arma,$(printf 0x%08x "$mha")" >> "$CSV"
    echo "$i,$order,b,$ob,$ab,$(printf 0x%08x "$wsb"),$rb,$tb,$armb,$(printf 0x%08x "$mhb")" >> "$CSV"
    HIST_A[$aa]=$(( ${HIST_A[$aa]:-0} + 1 )); HIST_B[$ab]=$(( ${HIST_B[$ab]:-0} + 1 ))
    OUT_CNT_A[$oa]=$(( ${OUT_CNT_A[$oa]:-0} + 1 )); OUT_CNT_B[$ob]=$(( ${OUT_CNT_B[$ob]:-0} + 1 ))
    [ "$oa" = OK ] && A_OK=$((A_OK+1)); [ "$ob" = OK ] && B_OK=$((B_OK+1))
    [ "$oa" = OK ] && [ "$ob" = OK ] && BOTH_OK=$((BOTH_OK+1))
    # DENOMINATOR: only cycles in which the die was genuinely armed are a test of
    # autonomy. An UNARMED cycle means training never started; counting it as a
    # failure is what manufactured the bogus "die_a 42%".
    [ "$oa" != UNARMED ] && A_N=$((A_N+1)); [ "$ob" != UNARMED ] && B_N=$((B_N+1))
    [ "$oa" = UNARMED ] && A_UNARMED=$((A_UNARMED+1)); [ "$ob" = UNARMED ] && B_UNARMED=$((B_UNARMED+1))
  done
  echo "========================================================"
  echo "  per-die (f)-convergence rate + FIX-4 attempt histogram (0x21B8[13:11])"
  printf '  %-5s %-10s' die conv-rate; for k in 0 1 2 3 4 5 6 7; do printf ' att%d' "$k"; done
  printf '  outcomes\n'
  hist_row(){ # $1=die-label $2=ok-count, then reads HIST_/OUT_CNT_ via $3 (a|b)
    local d=$3 k o cnt out="" den
    if [ "$d" = a ]; then den=$A_N; else den=$B_N; fi
    [ "$den" -eq 0 ] && den="0(NO VALID CYCLES)"
    printf '  %-5s %-10s' "$1" "$2/$den"
    for k in 0 1 2 3 4 5 6 7; do
      if [ "$d" = a ]; then cnt=${HIST_A[$k]:-0}; else cnt=${HIST_B[$k]:-0}; fi
      printf ' %4s' "$cnt"
    done
    if [ "$d" = a ]; then
      for o in "${!OUT_CNT_A[@]}"; do out="$out$o=${OUT_CNT_A[$o]} "; done
    else
      for o in "${!OUT_CNT_B[@]}"; do out="$out$o=${OUT_CNT_B[$o]} "; done
    fi
    printf '  %s\n' "${out% }"; }
  [ "${#OUT_CNT_A[@]}" -gt 0 ] && hist_row a "$A_OK" a
  [ "${#OUT_CNT_B[@]}" -gt 0 ] && hist_row b "$B_OK" b
  if [ $(( A_UNARMED + B_UNARMED )) -gt 0 ]; then
    echo "  !! NON-TESTS EXCLUDED: die_a UNARMED=$A_UNARMED  die_b UNARMED=$B_UNARMED  (of $N cycles each)"
    echo "     UNARMED = NEGO_CFG read back with nego_en=0 after ${ZP_ARM_TRIES:-3} arm attempts."
    echo "     autonomy_armed=0 gates the winscan entirely; those cycles test NOTHING."
  fi
  ha=""; hb=""
  for k in 0 1 2 3 4 5 6 7; do
    ha="$ha${HIST_A[$k]:-0},"; hb="$hb${HIST_B[$k]:-0},"
  done
  echo "ZP_STATS_RESULT n=$N a_ok=$A_OK/$N b_ok=$B_OK/$N both_ok=$BOTH_OK/$N hist_a=${ha%,} hist_b=${hb%,}"
  echo "  csv: $CSV"
  echo "========================================================"
  [ "$BOTH_OK" -eq "$N" ]; exit $?
fi
# ===== end --stats mode ========================================================

echo "======== zeropoke_soak N=$N stagger=${STAGGER}s budget=${BUDGET}s ($(date)) ========"
echo "  logs: $OUTDIR"

PASS_TOT=0; declare -A ORD_RUN ORD_PASS
for i in $(seq 1 "$N"); do
  if [ "$N" -ge 2 ] && [ "$i" -eq "$N" ]; then order=both
  elif [ $(( i % 2 )) -eq 1 ]; then order=a
  else order=b; fi
  log="$OUTDIR/cycle_${i}_${order}.log"
  echo "-- cycle $i/$N (first=$order) --"
  if "$HERE/zeropoke_proof.sh" "$order" --stagger "$STAGGER" --budget "$BUDGET" --no-lease \
        > "$log" 2>&1; then rc=PASS; PASS_TOT=$((PASS_TOT+1)); else rc=FAIL; fi
  ORD_RUN[$order]=$(( ${ORD_RUN[$order]:-0} + 1 ))
  [ "$rc" = PASS ] && ORD_PASS[$order]=$(( ${ORD_PASS[$order]:-0} + 1 ))
  # per-cycle one-liner = the proof's own scorecard line, prefixed
  sc=$(grep -m1 '^ZP_SCORECARD' "$log" || echo "ZP_SCORECARD <missing — see $log>")
  printf 'SOAK_CYCLE %d/%d %s %s\n' "$i" "$N" "$rc" "$sc"
done

echo "========================================================"
summary="SOAK_RESULT ${PASS_TOT}/${N} h-pass"
for o in a b both; do
  [ -n "${ORD_RUN[$o]:-}" ] && summary="$summary ${o}=${ORD_PASS[$o]:-0}/${ORD_RUN[$o]}"
done
echo "  $summary"
echo "  logs: $OUTDIR"
echo "========================================================"
[ "$PASS_TOT" -eq "$N" ]

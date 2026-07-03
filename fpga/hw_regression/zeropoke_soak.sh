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
# Logs: each cycle's full proof output lands in
#   ${TD_SOAK_DIR:-$HOME/td_zeropoke_soak}/<UTC-stamp>/cycle_<i>_<order>.log
# First-use validation pending (no boards attached at authoring time).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

N=""; STAGGER=0; BUDGET=240; DO_LEASE=1
while [ $# -gt 0 ]; do case "$1" in
  --stagger) STAGGER=$2; shift;;
  --budget)  BUDGET=$2; shift;;
  --no-lease) DO_LEASE=0;;
  -h|--help) sed -n '2,26p' "$0"; exit 0;;
  *) if [ -z "$N" ]; then N=$1; else echo "unknown arg: $1"; exit 2; fi;;
esac; shift; done
case "$N" in ''|*[!0-9]*) echo "usage: $0 N [--stagger SEC]"; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1"; exit 2; }

OUTDIR="${TD_SOAK_DIR:-$HOME/td_zeropoke_soak}/$(date -u +%Y%m%d_%H%M%SZ)"
mkdir -p "$OUTDIR"

boards_up || { echo "### ABORT: a board is unreachable ($A_IP / $B_IP)"; exit 3; }
if [ "$DO_LEASE" = 1 ]; then
  # one lease for the whole soak (~N * budget), never per-cycle
  lease_acquire $(( N * (BUDGET + 180) + 300 )) || { echo "### ABORT: no $LEASE_NAME lease"; exit 3; }
  trap 'lease_release' EXIT
fi

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

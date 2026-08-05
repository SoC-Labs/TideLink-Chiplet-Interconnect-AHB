#!/usr/bin/env bash
# kr260_eth_bringup_pair.sh — turnkey eth-chiplet PAIR bring-up with re-anchor retry.
#
# The AUTO_ANCHOR beacon (RTL) latches the deskew re-anchor autonomously at
# bring-up, but WHETHER it latches is a marginal-eye lottery per bring-up (the
# same lottery as reaching FCSM=4). This orchestrator runs BOTH dies' bring-up
# concurrently (they self-synchronise on cal_done) and RETRIES the whole pair
# bring-up — each retry re-runs winscan = a fresh eye — until BOTH dies report
# RE-ANCHORED (EPOCH_STATUS bit0=1), or MAX_TRIES is exhausted.
#
#   DIE_A=ubuntu@10.22.24.159 DIE_B=ubuntu@10.22.24.153 KR260_PASSWORD=... \
#       [MAX_TRIES=8] bash kr260_eth_bringup_pair.sh
#
# Exit 0 = both dies FCSM=4 + reanchored; 1 = exhausted retries; 2 = staging fail.
set -u
A=${DIE_A:-ubuntu@10.22.24.159}; B=${DIE_B:-ubuntu@10.22.24.153}
PW=${KR260_PASSWORD:-soclabs2026}
MAX_TRIES=${MAX_TRIES:-8}
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/kr260_eth_run.sh"

# Refresh the DEPLOYED bring-up recipe on both boards (kr260_eth_run.sh runs
# ~/td/scripts/kr260_eth_bringup.py; the copy from `deploy` may predate the
# EPOCH_STATUS re-anchor poll this orchestrator keys on).
DEST_DIR=${KR260_DEST:-td}/scripts
for h in "$A" "$B"; do
  sshpass -p "$PW" scp -q -o StrictHostKeyChecking=no "$HERE/kr260_eth_bringup.py" \
      "$h:$DEST_DIR/kr260_eth_bringup.py" 2>/dev/null \
    || { echo "stage recipe to $h:$DEST_DIR FAILED"; exit 2; }
done

_bu(){ KR260_HOST="$1" KR260_ETH_ROLE="$2" KR260_PASSWORD="$PW" bash "$RUN" bringup 2>&1; }

for t in $(seq 1 "$MAX_TRIES"); do
  _bu "$A" die_a > /tmp/bu_a.log 2>&1 &
  pa=$!
  _bu "$B" die_b > /tmp/bu_b.log 2>&1 &
  pb=$!
  wait $pa; wait $pb
  ea=$(grep -c "RESULT: RE-ANCHORED" /tmp/bu_a.log)
  eb=$(grep -c "RESULT: RE-ANCHORED" /tmp/bu_b.log)
  ua=$(grep -c "LINK UP" /tmp/bu_a.log); ub=$(grep -c "LINK UP" /tmp/bu_b.log)
  echo "try $t/$MAX_TRIES: die_a[linkup=$ua reanchored=$ea] die_b[linkup=$ub reanchored=$eb]"
  if [ "$ea" -ge 1 ] && [ "$eb" -ge 1 ]; then
    echo "PAIR RE-ANCHORED on try $t — both dies FCSM=4 + deskew locked (autonomous)."
    exit 0
  fi
done
echo "PAIR did NOT both re-anchor in $MAX_TRIES tries (marginal rig; characterise eye)."
exit 1

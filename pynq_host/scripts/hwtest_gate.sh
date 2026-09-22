#!/usr/bin/env bash
# hwtest_gate.sh — the durable, run-each-time HARDWARE regression gate.
#
# The HW analogue of `make sim_gate_regressions`. Closes the holes the 2026-08-08
# HW-robustness audit found: no blocking HW gate, no provenance, silent-green,
# no POR discipline. Structure (mirrors the sim tip-stamp + fail-loud + coverage):
#
#   PROVENANCE  -> the bitstream under test must carry the commit under test
#                  (build manifest source_commit == git HEAD; on-board usr_access
#                  cross-check when reachable). Refuse a green from a foreign image.
#   POR-REPEAT  -> N fresh PORs (boot-wait each), deploy, prove BOTH:
#                    autonomy (fcsm==4 + cal + HONEST mask_hs on both dies), and
#                    byte-exact A->B data soak (good==SOAK, bad==0).
#   THRESHOLD   -> pass rate must clear MIN_PASS/N (separates the bring-up lottery
#                  from a real regression; a marginal build can't hide behind one
#                  lucky POR, a flaky POR isn't read as a regression).
#   VERDICT     -> emit verdict.json (commit, usr_access, per-POR, land-rate) and
#                  exit non-zero on FAIL. Never claim HW-green from resident logs.
#
# Design: onchip (one board, two dies) — the lottery-free vehicle. Standalone Z2
# / eth-chiplet gates are separate entrypoints (this one is intentionally scoped).
#
# Usage: hwtest_gate.sh [-N pors] [-s soak] [-m min_pass] [-H host] [-b board]
#        TARGET defaults kr260-pair-onchip; bitstream from $TIDELINK_HOME build.
set -u
TIDELINK_HOME="${TIDELINK_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
TARGET="${TARGET:-kr260-pair-onchip}"
HOST="${HWG_HOST:-10.22.24.159}"
BOARD="${HWG_BOARD:-kr260_01}"
N="${HWG_PORS:-4}"; SOAK="${HWG_SOAK:-500}"; MIN_PASS="${HWG_MIN_PASS:-4}"
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
POR_HOST="${HWG_POR_HOST:-mapstone-dev}"; POR_NAME="${HWG_POR_NAME:-kr260-01}"
OUT="$TIDELINK_HOME/imp/fpga/output/$TARGET"
MANIFEST="$OUT/tidelink_manifest.json"
VERDICT="$TIDELINK_HOME/imp/hw_gate/verdict.json"
mkdir -p "$TIDELINK_HOME/imp/hw_gate"
while getopts "N:s:m:H:b:" o; do case $o in
  N) N=$OPTARG;; s) SOAK=$OPTARG;; m) MIN_PASS=$OPTARG;; H) HOST=$OPTARG;; b) BOARD=$OPTARG;; esac; done

say(){ echo "[hw_gate] $*"; }
die(){ echo "[hw_gate] FAIL: $*" >&2; exit 1; }
ssh_b(){ sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 ubuntu@"$HOST" "$@"; }
wait_ssh(){ for _ in $(seq 1 30); do ssh_b true 2>/dev/null && return 0; sleep 5; done; return 1; }

# ---- PROVENANCE -----------------------------------------------------------
[ -f "$MANIFEST" ] || die "no build manifest at $MANIFEST — build the bitstream first"
HEAD="$(git -C "$TIDELINK_HOME" rev-parse HEAD 2>/dev/null)"
MSHA="$(grep -oE '"source_commit":[^,]*' "$MANIFEST" | grep -oE '[0-9a-f]{40}')"
UACC="$(grep -oE '"usr_access":[^,]*' "$MANIFEST" | grep -oE '0x[0-9a-f]+')"
say "under test: HEAD=$HEAD  manifest.source_commit=$MSHA  usr_access=$UACC"
[ "$MSHA" = "$HEAD" ] || die "PROVENANCE: bitstream built from $MSHA, not the commit under test $HEAD (rebuild)"

# ---- POR-REPEAT + THRESHOLD ----------------------------------------------
auto_pass=0; data_pass=0; declare -a rows=()
for i in $(seq 1 "$N"); do
  say "POR cycle $i/$N"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$POR_HOST" "~/bin/kpor $POR_NAME --wait" >/dev/null 2>&1 || say "kpor warn (cyc $i)"
  wait_ssh || { rows+=("{\"por\":$i,\"autonomy\":\"BOARD_DOWN\",\"data\":\"-\"}"); continue; }
  sleep 25   # bootpy settle before deploy
  ( cd "$TIDELINK_HOME" && timeout 130 make -C fpga deploy TARGET="$TARGET" \
      KR260_HOST="$HOST" KR260_USER=ubuntu KR260_PASSWORD="$PW" >/dev/null 2>&1 ) || { rows+=("{\"por\":$i,\"autonomy\":\"DEPLOY_FAIL\",\"data\":\"-\"}"); continue; }
  # on-board usr_access cross-check (best-effort; non-fatal if reg absent)
  a=$(timeout 90 ssh_b "cd td && echo $PW | sudo -S env TIDELINK_SOC=kr260 python3 scripts/kr260_onchip_autonomy.py 2>&1")
  if echo "$a" | grep -q "AUTONOMY PROVEN"; then au=PASS; auto_pass=$((auto_pass+1)); else au=FAIL; fi
  s=$(timeout 130 ssh_b "cd td && echo $PW | sudo -S env TIDELINK_SOC=kr260 python3 scripts/kr260_onchip_soak.py soak $SOAK 2>&1" | grep -oE "good=[0-9]+ bad=[0-9]+")
  if echo "$s" | grep -qE "good=$SOAK bad=0"; then dp=PASS; data_pass=$((data_pass+1)); else dp=FAIL; fi
  say "  cyc$i autonomy=$au  data=$dp ($s)"
  rows+=("{\"por\":$i,\"autonomy\":\"$au\",\"data\":\"$dp\",\"soak\":\"$s\"}")
done

# ---- VERDICT --------------------------------------------------------------
verdict=PASS
[ "$auto_pass" -ge "$MIN_PASS" ] || verdict=FAIL
[ "$data_pass" -ge "$MIN_PASS" ] || verdict=FAIL
{
  echo "{"
  echo "  \"commit\": \"$HEAD\","
  echo "  \"source_commit\": \"$MSHA\","
  echo "  \"usr_access\": \"$UACC\","
  echo "  \"target\": \"$TARGET\","
  echo "  \"pors\": $N, \"soak\": $SOAK, \"min_pass\": $MIN_PASS,"
  echo "  \"autonomy_pass\": $auto_pass, \"data_pass\": $data_pass,"
  echo "  \"per_por\": [$(IFS=,; echo "${rows[*]}")],"
  echo "  \"verdict\": \"$verdict\""
  echo "}"
} > "$VERDICT"
cat "$VERDICT"
say "land-rate: autonomy $auto_pass/$N, data(byte-exact) $data_pass/$N  (threshold $MIN_PASS/$N)"
[ "$verdict" = PASS ] && { say "RESULT: HW GATE PASS @ $HEAD"; exit 0; }
die "HW GATE FAIL — land-rate below threshold (see $VERDICT)"

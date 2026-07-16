#!/bin/bash
# =============================================================================
# run_fake_zeropoke.sh — validate zeropoke_proof.sh (incl. --trace) against
# the tl39-emulating fake-board harness. NO hardware, NO lease, NO network:
# fake sshpass/ping/deploy are PATH-prepended and the register timeline is
# modeled in fake_board_model.sh.
#
# Scenarios:
#   s1  non-trace happy path  — a-h all PASS, exit 0, NO ZP_TRACE output
#       (guards "non-trace path unchanged")
#   s2  --trace happy path    — CSV populated from BOTH dies with the full
#       register set; discriminator reports die_a first (model: a@8s, b@10s)
#   s3  --trace failure path  — FAKE_WS_NEVER=die_b: f/g FAIL, exit!=0,
#       discriminator reports die_b never rose
#
# Usage: fpga/hw_regression/tests/run_fake_zeropoke.sh   (exit 0 = all ok)
# =============================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HW=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zp_fake.XXXXXX")
export FAKE_STATE="$WORK/state"; mkdir -p "$FAKE_STATE"
export PATH="$HERE/fake_bin:$PATH"
export TD_DEPLOY_SH="$HERE/fake_bin/fake_deploy.sh"
export TD_THROTTLE=0.02          # no PS to wedge here — speed the polls up
export TD_TRACE_PERIOD=0.3
trap 'rm -rf "$WORK"' EXIT

FAILS=0
chk(){ local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ok   $label"
  else echo "  FAIL $label"; FAILS=$((FAILS+1)); fi; }
# shellcheck disable=SC2329  # invoked indirectly through chk "$@"
has(){ printf '%s\n' "$2" | grep -q "$1"; }   # has <pattern> <text>

echo "== s1: non-trace happy path (a-h PASS, no ZP_TRACE lines) =="
OUT1=$("$HW/zeropoke_proof.sh" a --no-lease --budget 60 2>&1); RC1=$?
chk "s1 exit code 0"            test "$RC1" -eq 0
chk "s1 scorecard h=PASS"       has 'ZP_SCORECARD .* h=PASS' "$OUT1"
chk "s1 a2b=3/3 b2a=PASS"       has 'a2b=3/3 b2a=PASS' "$OUT1"
chk "s1 NO trace output"        test "$(printf '%s\n' "$OUT1" | grep -c ZP_TRACE)" -eq 0

echo "== s2: --trace happy path (CSV + discriminator die_a first) =="
CSV="$WORK/trace_s2.csv"
OUT2=$("$HW/zeropoke_proof.sh" both --no-lease --budget 60 --trace --trace-file "$CSV" 2>&1); RC2=$?
chk "s2 exit code 0"            test "$RC2" -eq 0
chk "s2 scorecard h=PASS"       has 'ZP_SCORECARD .* h=PASS' "$OUT2"
chk "s2 csv exists"             test -s "$CSV"
chk "s2 csv header"             has '^timestamp,die,reg,name,value$' "$(head -1 "$CSV")"
chk "s2 csv >=20 samples"       test "$(wc -l < "$CSV")" -ge 20
chk "s2 csv has die_a rows"     grep -q ',die_a,' "$CSV"
chk "s2 csv has die_b rows"     grep -q ',die_b,' "$CSV"
for r in R8 SWI_LANE_STATUS NEGO_TRAIN_STATUS OBSCAL WINSCAN_OBS REANCHORED SYNC_SEEN SYNCCNT FCCRED; do
  chk "s2 csv samples $r"       grep -q ",$r," "$CSV"
done
chk "s2 ZP_TRACE summary line"  has 'ZP_TRACE csv=' "$OUT2"
chk "s2 discriminator a first"  has 'ZP_TRACE_DISCRIMINATOR .* first=die_a second=die_b delta=' "$OUT2"
chk "s2 scorecard cites trace"  has "ZP_SCORECARD .* trace=$CSV" "$OUT2"
chk "s2 no orphan samplers"     test -z "$(pgrep -f td_trace.py || true)"

echo "== s3: --trace failure path (die_b winscan never finishes) =="
CSV3="$WORK/trace_s3.csv"
export FAKE_WS_NEVER=die_b
OUT3=$("$HW/zeropoke_proof.sh" a --no-lease --budget 25 --trace --trace-file "$CSV3" 2>&1); RC3=$?
unset FAKE_WS_NEVER
chk "s3 exit code != 0"         test "$RC3" -ne 0
chk "s3 step f FAIL"            has 'ZP_STEP f FAIL' "$OUT3"
chk "s3 scorecard h=FAIL"       has 'ZP_SCORECARD .* h=FAIL' "$OUT3"
chk "s3 discriminator b never"  has 'ZP_TRACE_DISCRIMINATOR .* first=die_a second=none(die_b_never_rose)' "$OUT3"

echo "-------------------------------------------------"
if [ "$FAILS" -eq 0 ]; then echo "FAKE-HARNESS VALIDATION: ALL OK"; exit 0
else echo "FAKE-HARNESS VALIDATION: $FAILS check(s) FAILED"; exit 1; fi

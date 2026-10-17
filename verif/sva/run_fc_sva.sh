#!/usr/bin/env bash
# Run the FC-node CRC-replay contract SVA (verif/sva/) inside existing cocotb pair benches.
#
#   verif/sva/run_fc_sva.sh [quick|full]      (default quick;  `make fc_sva` / `make fc_sva_full`)
#
# MAIN ARM    (must be clean): sideband_crc_replay cases (+ crc_matrix_quick in `full`) with
#             TL_FC_SVA=1.  PASS = zero `TL_FC_SVA FAIL` lines AND the checker was alive
#             (some node saw a CRC error, a follower and an accepted replay).
# MUST-FAIL   (must fire):  the pre-TL-059 sideband RTL (+define+SOCL_L9_ALWAYS) with the same SVA.
#             PASS = C1 and C2c fire.  A silent mutant means the checker is hollow => exit 1.
# Needs set_env.sh sourced and CHIPLET_HOME / TIDECHART_HOME pinned (see docs/CI_RUNNER.md).
# One sim at a time (the host is shared).  Exit 0 only if every arm behaves as required.
set -u
MODE=${1:-quick}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BENCH=$ROOT/cocotb/tidelink_axi_datanode_recovery
OUT=${FC_SVA_OUT:-$ROOT/imp/fc_sva}
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/summary.txt
export TL_FC_SVA=1
fail=0
note() { echo "[fc_sva] $*" | tee -a "$OUT/summary.txt"; }
: > "$OUT/summary.txt"

clean_builds() { rm -rf "$BENCH"/sim_build_fcsva* "$BENCH"/sim_build_cm_* "$BENCH"/crc_matrix_out; }

run_case() {   # name testcase [extra make args...]
  local name=$1 tc=$2; shift 2
  note "RUN  $name ($tc) $*"
  ( cd "$BENCH" && timeout "${FC_SVA_TIMEOUT:-1500}" make SIM_BUILD=sim_build_fcsva_$name MODULE=test_sideband_crc_replay TESTCASE=$tc "$@" ) \
      > "$OUT/$name.log" 2>&1
  echo $? > "$OUT/$name.rc"
}
nfail()  { cat "$@" 2>/dev/null | grep -c 'TL_FC_SVA FAIL'; }
# alive = at least one bound instance saw crc>0, follower>0 and replay>0
alive()  { cat "$@" 2>/dev/null | grep 'TL_FC_SVA SUMMARY' | grep -Ec ' crc=[1-9][0-9]* follower=[1-9][0-9]* replay=[1-9][0-9]* '; }

clean_builds
MAIN_CASES="test_sideband_crc_replay test_sideband_crc_position_ab test_sideband_two_hits_in_flight test_sideband_hit_first_after_bringup test_axi_w_crc_replay_control"
[ "$MODE" = full ] || MAIN_CASES="test_sideband_crc_replay test_sideband_crc_position_ab"
for tc in $MAIN_CASES; do
  run_case "main_$tc" "$tc"
  rc=$(cat "$OUT/main_$tc.rc"); nf=$(nfail "$OUT/main_$tc.log")
  note "main  $tc  bench_rc=$rc  sva_fails=$nf  alive_instances=$(alive "$OUT/main_$tc.log")"
  [ "$rc" = 0 ] && [ "$nf" = 0 ] || fail=1
done
alive_main=$(alive "$OUT"/main_*.log)
[ "$alive_main" -ge 1 ] || { note "VACUOUS: no bound instance saw crc+follower+replay in the main arm"; fail=1; }

if [ "$MODE" = full ]; then
  note "RUN  crc_matrix_quick (TL_FC_SVA=1)"
  ( cd "$BENCH" && timeout "${FC_SVA_TIMEOUT_MATRIX:-2400}" make crc_matrix_quick ) > "$OUT/main_crc_matrix_quick.log" 2>&1
  rc=$?
  # per-case logs: the `_l9` cases are the matrix's OWN mutant arm and are EXPECTED to trip the SVA
  cp "$BENCH"/crc_matrix_out/quick/*.log "$OUT"/ 2>/dev/null
  nf=0; for f in "$BENCH"/crc_matrix_out/quick/*.log; do
    case $f in *_l9.log) continue;; esac; n=$(nfail "$f"); nf=$((nf+n)); done
  nm=$(cat "$BENCH"/crc_matrix_out/quick/*_l9.log 2>/dev/null | grep -c 'TL_FC_SVA FAIL C1')
  note "main  crc_matrix_quick  bench_rc=$rc  sva_fails_non_mutant=$nf  sva_C1_in_matrix_l9_mutant=$nm"
  [ "$rc" = 0 ] && [ "$nf" = 0 ] && [ "$nm" -ge 1 ] || fail=1
fi

# ---- must-fail arm: pre-fix sideband RTL, SVA must catch it -------------------------
clean_builds
run_case mutant_l9 test_sideband_crc_position_ab EXTRA_DEFINES=+define+SOCL_L9_ALWAYS
rc=$(cat "$OUT/mutant_l9.rc")
c1=$(grep -c 'TL_FC_SVA FAIL C1'  "$OUT/mutant_l9.log")
c2=$(grep -c 'TL_FC_SVA FAIL C2c' "$OUT/mutant_l9.log")
c3=$(grep -c 'TL_FC_SVA FAIL C3'  "$OUT/mutant_l9.log")
note "mutant SOCL_L9_ALWAYS  bench_rc=$rc (nonzero expected)  C1=$c1 C2c=$c2 C3=$c3"
if [ "$c1" -ge 1 ] && [ "$c2" -ge 1 ]; then note "mutant KILLED by SVA (required)"; else note "MUTANT ESCAPED the SVA: checker is hollow"; fail=1; fi
clean_builds

if [ $fail = 0 ]; then note "RESULT PASS"; else note "RESULT FAIL"; fi
exit $fail

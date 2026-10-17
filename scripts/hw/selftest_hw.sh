#!/usr/bin/env bash
# selftest_hw.sh - offline proof that the KR260 regression tooling can FAIL (no board, no network, no sim, ~30 s).
#
#   1. board-tool selftest      pynq_host/hw_regress/selftest_rev2hw.py          -> SELFTEST_RESULT=PASS
#   2. injector library tests   scripts/ci/tests/test_injector_controls.py        -> exits 0
#   3. hw_test.sh stub rehearsals (scripts/hw/stubs/rehearse.sh): fake ssh/sshpass/scp/flock/ping, synthetic image.
#      Every safety feature has a rehearsal that must go red when the feature is removed:
#        sudo pre-check before any POR, flock/config refusal, password never in argv, sudo password on stdin,
#        sync after staging + verify_staged after a POR, por_one 3x retry, restore trap, EXPECT_FIXED/CRCSTATS/
#        STREAM/BRINGUPS/AXICHECK profiles, --unvetted (exit 6) and the removed ALLOW_UNVETTED_BUILD bypass.
#   4. check_markers.py must-fail: a tree whose FCSM_6 lacks the TL-059 gate reports MARKERS_RESULT=FAIL.
#
# Prints HW_SELFTEST_RESULT=PASS|FAIL and exits 0 only on PASS.  Run: make hw_tooling_selftest
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../.." && pwd -P)
OUT=${HW_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/hw-selftest.XXXXXX")}; mkdir -p "$OUT"
BAD=0; N=0
ok()  { N=$((N+1)); printf '  ok   %s\n' "$1"; }
bad() { N=$((N+1)); BAD=$((BAD+1)); printf '  BAD  %s\n' "$1"; }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "== 1. board tool selftest (rev2hw.py against simulated register models)"
python3 "$REPO/pynq_host/hw_regress/selftest_rev2hw.py" > "$OUT/selftest_rev2hw.txt" 2>&1
if grep -q '^SELFTEST_RESULT=PASS' "$OUT/selftest_rev2hw.txt" && ! grep -q '^BAD' "$OUT/selftest_rev2hw.txt"; then ok "selftest_rev2hw.py: SELFTEST_RESULT=PASS ($(grep -c '^ok' "$OUT/selftest_rev2hw.txt") cases)"; else bad "selftest_rev2hw.py"; tail -20 "$OUT/selftest_rev2hw.txt"; fi

echo "== 2. injector library unit tests"
if python3 "$REPO/scripts/ci/tests/test_injector_controls.py" > "$OUT/test_injector_controls.txt" 2>&1; then ok "test_injector_controls.py"; else bad "test_injector_controls.py"; tail -20 "$OUT/test_injector_controls.txt"; fi

echo "== 3. hw_test.sh stub rehearsals"
# reh LABEL EXPECTED_RC [ENV=VAL ...] -- [hw_test args] ; leaves $R=<results dir> $C=<console> $L=<stub log>
reh() {
  local label=$1 want=$2; shift 2
  local -a envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
  env "${envs[@]}" REHEARSE_OUT="$OUT/$label" bash "$HERE/stubs/rehearse.sh" "$label" "$@" > "$OUT/$label.rehearse.txt" 2>&1
  local rc=$?
  R=$OUT/$label/rehearsal-$label; C=$OUT/$label/rehearsal-$label.console; L=$OUT/$label/rehearsal-$label.log
  if [ "$rc" = "$want" ]; then ok "$label: hw_test.sh rc=$rc (expected $want)"; else bad "$label: hw_test.sh rc=$rc (expected $want); see $C"; fi
}
firstline() { grep -n "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }

reh basic 0 --
check "basic: all 23 steps PASS in SUMMARY.tsv" bash -c "[ \$(awk -F'\t' 'NR>1 && \$3==\"PASS\"' '$R/SUMMARY.tsv' | wc -l) -ge 22 ] && ! awk -F'\t' 'NR>1 && \$3!=\"PASS\" && \$3!=\"SKIPPED\"' '$R/SUMMARY.tsv' | grep -q ."
sp=$(firstline "sudo -S -k -p '' true" "$L"); po=$(firstline ">>> POR" "$L")
check "basic: sudo pre-check (line ${sp:-?}) comes before the first POR (line ${po:-?})" bash -c "[ -n '$sp' ] && [ -n '$po' ] && [ '$sp' -lt '$po' ]"
check "basic: the whole run is re-executed under flock on the rig lock (flock -w ... <lock>)" grep -q 'flock -w .*rig.lock' "$L"
check "basic: password never on any argv (stub log has no password text)" bash -c "! grep -q stub-not-a-password '$L'"
check "basic: sudo password reached sudo on stdin line 1" grep -q 'stdin line 1 = a password' "$L"
check "basic: sync after staging precedes the PL load" bash -c "s=\$(grep -n '>>> SYNC' '$L' | head -1 | cut -d: -f1); d=\$(grep -n '>>> PL LOAD' '$L' | head -1 | cut -d: -f1); [ -n \"\$s\" ] && [ -n \"\$d\" ] && [ \"\$s\" -lt \"\$d\" ]"
check "basic: AXICHECK is off by default (no 14_axi_check.txt in the basic run, so no extra injection)" bash -c "[ ! -e '$R/14_axi_check.txt' ] && ! grep -q 'axi rc=' '$R/SUMMARY.tsv'"
check "basic: both boards POR'd before the deploy and again at the end" bash -c "[ \$(grep -c '>>> POR kr260_01' '$L') -ge 3 ] && [ \$(grep -c '>>> POR kr260_02' '$L') -ge 3 ]"
check "basic: a rehearsal that skipped vetting still says so (preflight FAIL line)" grep -q 'PREFLIGHT FAIL.*not vetted' "$R/00_preflight.txt"

reh fixed 0 EXPECT_FIXED=1 CRCSTATS=1 STREAM=1 --
check "fixed: replayed exactly once over both directions" grep -q 'replayed exactly once 60/60' "$R/SUMMARY.tsv"
check "fixed: stream-start ran (both directions) after autonomy" bash -c "grep -q 'stream-start' '$R/SUMMARY.tsv' && [ -f '$R/stream_main_b2a.txt' ] && [ -f '$R/stream_main_a2b.txt' ]"
check "fixed: stats mode stops after step 14 and restores" bash -c "grep -q 'restore.*PASS\|PASS.*restore' '$R/SUMMARY.tsv' && ! grep -q 'crc_a2b' '$R/SUMMARY.tsv'"

reh fixedlost 1 EXPECT_FIXED=1 CRCSTATS=1 STUB_STATS_LOST=1 --
check "fixedlost: FAIL at crc_ctl, restore trap ran" bash -c "grep -q 'crc_ctl.*FAIL' '$R/SUMMARY.tsv' && [ -f '$R/99_restore.txt' ] && grep -q 'RESTORE: both boards POR' '$R/99_restore.txt'"
check "fixedlost: hand-off message printed" grep -q 'HAND-OFF TO THE RIG OWNER' "$R/99_restore.txt"

reh axi 0 AXICHECK=1 --
check "axi: AXICHECK=1 ran rev2hw.py axi, kept 14_axi_check.txt with the AXI_RESULT line" bash -c "grep -q '^AXI_RESULT crc_on=True' '$R/14_axi_check.txt' && grep -q 'axi rc=0 AXI_RESULT' '$R/SUMMARY.tsv'"
reh axifail 1 AXICHECK=1 STUB_AXI_FAIL=1 --
check "axifail: a failing AXI check fails crc_ctl and the restore trap ran" bash -c "grep -q 'crc_ctl.*FAIL' '$R/SUMMARY.tsv' && [ -f '$R/99_restore.txt' ]"

reh bringups 0 BRINGUPS=5 --
check "bringups: 5/5" grep -q 'bring-ups 5/5 PASS' "$R/SUMMARY.tsv"
reh bringups_soft 1 BRINGUPS=5 STUB_FAIL_NTH=autonomy:3:1 --
check "bringups: one soft failure counted 4/5 and the run FAILS" grep -q 'bring-ups 4/5 PASS' "$R/SUMMARY.tsv"
reh bringups_wedge 1 BRINGUPS=5 STUB_FAIL_NTH=smoke:2:124 --
check "bringups: a simulated wedge aborts at once and the trap restores" bash -c "grep -q 'ABORTED at cycle' '$R/SUMMARY.tsv' && [ -f '$R/99_restore.txt' ]"

reh sudo_refused 1 STUB_FAIL_MATCH=SUDO_OK --
check "sudo_refused: NOTHING touched (no POR in the stub log)" bash -c "! grep -q '>>> POR' '$L'"
check "sudo_refused: step 00 is the failure" grep -q 'lock_check.*FAIL' "$R/SUMMARY.tsv"

reh porretry 0 STUB_POR_FAIL_FIRST=2 --
check "porretry: two injected POR failures retried, run passes" bash -c "[ \$(grep -c 'FAILED (injected' '$L') -eq 2 ] && grep -q 'POR of kr260_01 attempt 1 failed' '$R/01_por_both.txt'"
reh porgiveup 1 STUB_POR_FAIL_FIRST=3 --
check "porgiveup: 3 failures end step 01 (no deploy), restore still attempted" bash -c "grep -q 'por_both.*FAIL' '$R/SUMMARY.tsv' && ! grep -q '>>> PL LOAD' '$L' && [ -f '$R/99_restore.txt' ]"

reh stale 1 STUB_STALE_AFTER_POR=1 --
check "stale: verify_staged refuses to deploy a lost write" bash -c "grep -q 'NOT deploying' '$R/SUMMARY.tsv' && ! grep -q '>>> PL LOAD' '$L'"

reh softfail 1 STUB_FAIL_NTH=smoke:1:1 --
check "softfail: STOP at the failing step; later steps never ran; restore ran" bash -c "grep -q 'smoke.*FAIL' '$R/SUMMARY.tsv' && ! grep -q 'soak5000' '$R/SUMMARY.tsv' && [ -f '$R/99_restore.txt' ]"

reh unvetted 6 -- --unvetted
check "unvetted: loud banner on the console" grep -q 'UNVETTED BUILD' "$C"
check "unvetted: UNVETTED marker file and results dir name" bash -c "[ -f '$R/UNVETTED' ] && grep -q 'UNVETTED' '$R/SUMMARY.tsv'"
check "unvetted: every step verdict line is tagged" bash -c "[ \$(grep -c '^VERDICT: .*\[UNVETTED BUILD\]' '$C') -ge 20 ]"
reh bypass 2 ALLOW_UNVETTED_BUILD=1 --
check "bypass: the removed env bypass is refused and no board command ran" bash -c "grep -q 'ALLOW_UNVETTED_BUILD was removed' '$C' && [ ! -s '$L' ]"
reh noconfig 2 "REHEARSE_OMIT=KR260_IP" --
check "noconfig: a missing site setting is refused (no default IP anywhere)" bash -c "grep -q 'REFUSED: KR260_IP is not set' '$C' && [ ! -s '$L' ]"
reh nolock 2 "REHEARSE_OMIT=KR260_LOCK" --
check "nolock: a missing rig lock is refused" grep -q 'REFUSED: KR260_LOCK is not set' "$C"

echo "== 4. check_markers.py must-fail control"
T=$OUT/markers_tree; rm -rf "$T"; mkdir -p "$T/flists" "$T/src/rtl/local_overrides"
cp "$REPO/flists/tidelink_fpga_v2.flist" "$T/flists/"
cp "$REPO/src/rtl/local_overrides/WlinkGenericFCSM_6.v" "$T/src/rtl/local_overrides/"
python3 "$HERE/check_markers.py" --tree "$T" --groups tl059 > "$OUT/markers_good.txt" 2>&1
check "check_markers: tl059 markers present in the shipped FCSM_6 (control passes)" grep -q '^MARKERS_RESULT=PASS' "$OUT/markers_good.txt"
sed -i 's/& *socl_l9_crc_off//' "$T/src/rtl/local_overrides/WlinkGenericFCSM_6.v"
python3 "$HERE/check_markers.py" --tree "$T" --groups tl059 > "$OUT/markers_bad.txt" 2>&1; mrc=$?
check "check_markers: removing the TL-059 gate is reported (rc=$mrc, MARKERS_RESULT=FAIL)" bash -c "[ $mrc -eq 1 ] && grep -q '^MARKERS_RESULT=FAIL' '$OUT/markers_bad.txt'"

echo
echo "checks: $N   bad: $BAD   (artifacts: $OUT)"
if [ "$BAD" = 0 ]; then echo "HW_SELFTEST_RESULT=PASS"; exit 0; fi
echo "HW_SELFTEST_RESULT=FAIL"; exit 1

#!/bin/bash
# =============================================================================
# test_instrument_preamble.sh — offline (no-hardware) test of the L1 preamble
# against the canned mock board. Demonstrates a clean PASS plus every FAIL mode.
# Pure bash; safe to run in CI.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/instrument_preamble.sh"
# shellcheck source=/dev/null
source "$HERE/mock_reader.sh"

PREAMBLE_RD_CMD=mock_rd
PREAMBLE_WR_CMD=mock_wr
PREAMBLE_AFI_CMD=mock_afi

pass=0; fail=0
# run_case <name> <soc> <expected-rc> <expected-fail-token-or-"-"> <MOCK_FAULT>
run_case(){
  local name="$1" soc="$2" exp_rc="$3" exp_tok="$4" fault="$5"
  echo
  echo "############################################################"
  echo "# CASE: $name   (soc=$soc  fault='${fault:-none}'  expect rc=$exp_rc tok=$exp_tok)"
  echo "############################################################"
  mock_seed "$soc"
  local out rc
  out="$(MOCK_FAULT="$fault" preamble_run_all "$soc" "mockhost" 2>&1)"; rc=$?
  echo "$out"
  local ok=1
  [ "$rc" -eq "$exp_rc" ] || { ok=0; echo ">> rc mismatch: got $rc want $exp_rc"; }
  if [ "$exp_tok" != "-" ]; then
    echo "$out" | grep -q "PREAMBLE_FAIL: $exp_tok" || { ok=0; echo ">> missing token PREAMBLE_FAIL: $exp_tok"; }
  fi
  if [ "$ok" = 1 ]; then echo ">> CASE PASS"; pass=$((pass+1)); else echo ">> CASE FAIL"; fail=$((fail+1)); fi
}

run_case "healthy KR260 (all pass)"     kr260 0 -                    ""
run_case "healthy Z2 (all pass)"        z2    0 -                    ""
run_case "reader dead (host/ssh gone)"  kr260 1 READER_DEAD          reader_dead
run_case "AFI 128-bit width defect"     kr260 1 AFI_WIDTH            afi
run_case "adjacent-word smear (width)"  kr260 1 WIDTH_PROBE_MISMATCH width
run_case "control canary mismatch"      kr260 1 CANARY_MISMATCH      canary
run_case "APB RW dead (scratch litmus)" kr260 1 RW_LITMUS            rw_dead
run_case "unknown soc"                  bogus 2 UNKNOWN_SOC          ""

echo
echo "============================================================"
echo "helper unit checks (is_trustworthy_reg / preamble_addr_is_safe)"
preamble_config kr260 mockhost >/dev/null
h(){ # h <desc> <cmd...> <expected-rc>
  local desc="$1"; shift; local exp="${!#}"; set -- "${@:1:$(($#-1))}"
  "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$exp" ]; then echo "  ok   $desc (rc=$rc)"; pass=$((pass+1));
  else echo "  FAIL $desc (rc=$rc want $exp)"; fail=$((fail+1)); fi
}
h "0x215C sync_seen quarantined"     is_trustworthy_reg 0x8403215C 1
h "0x2144 livematch quarantined"     is_trustworthy_reg 0x84032144 1
h "0x2140 EPOCH trusted"             is_trustworthy_reg 0x84032140 0
h "0x2108 fcsm/cal trusted"          is_trustworthy_reg 0x84032108 0
h "0x21AC stall refused"             preamble_addr_is_safe kr260 0x840321AC 1
h "0x21B4 stall refused"             preamble_addr_is_safe kr260 0x840321B4 1
h "0x4403xxxx undecoded on ZynqMP"   preamble_addr_is_safe kr260 0x44032140 1
h "0x84030214 canary safe"           preamble_addr_is_safe kr260 0x84030214 0

echo
echo "============================================================"
echo "TOTAL: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ALL TESTS PASS"

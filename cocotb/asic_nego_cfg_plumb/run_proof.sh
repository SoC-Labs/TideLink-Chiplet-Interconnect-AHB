#!/bin/bash
# PENDING-DECISION #6 — prove NEGO_CFG_RESET REACHES the controller through the
# DFT wrapper, in BOTH settings, and that the wrapper param is genuinely
# targetable (NO-GENERIC-MATCH / PCWM discriminator).
#
# Usage:  source ../../set_env.sh && ./run_proof.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TIDELINK_HOME:=$(cd "$HERE/../.." && pwd)}"
FLIST="$TIDELINK_HOME/flists/tidelink_top_full_asic_v2.flist"
STUB="$TIDELINK_HOME/syn/asic/sim_stubs/rf_16k_stub.v"
WRAP="$TIDELINK_HOME/src/rtl/asic/tidelink_dft_wrapper.sv"
TB="$HERE/tb_nego_plumb.sv"
WORK="$HERE/sim_build"
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

FAIL=0
run() {   # $1=label  $2=NCR-define  $3..=extra vcs args
  local label="$1" ncr="$2"; shift 2
  echo "=================================================================="
  echo "[$label] NCR=$ncr  extra=$*"
  vcs -full64 -sverilog -timescale=1ns/1ps \
      +define+TB_TOP_NO_DUMP +define+TIDELINK_PHY_V2 \
      "+define+NCR=$ncr" \
      -f "$FLIST" "$STUB" "$WRAP" "$TB" \
      -top tb_nego_plumb -l "vcs_${label}.log" "$@" >/dev/null 2>&1
  ./simv -l "run_${label}.log" >/dev/null 2>&1
  grep "PROOF " "run_${label}.log" || echo "  (no PROOF line — elaboration failed, see $WORK/vcs_${label}.log)"
}

# --- A: default 7'h00 must reach the controller as 0 ------------------------
run default "7'h00"
A_CTRL=$(grep "NEGO_CFG_RESET_at_controller" "run_default.log" | awk '{print $NF}')
[ "$A_CTRL" = "0" ] || { echo "FAIL: default did not reach controller as 0 (got '$A_CTRL')"; FAIL=1; }

# --- B: strapped 7'h61 (=97) must reach the controller as 97 ----------------
run strap97 "7'h61"
B_CTRL=$(grep "NEGO_CFG_RESET_at_controller" "run_strap97.log" | awk '{print $NF}')
[ "$B_CTRL" = "97" ] || { echo "FAIL: strap 7'h61 did not reach controller as 97 (got '$B_CTRL')"; FAIL=1; }

# --- C: discriminator — a REAL -pvalue override binds silently; a BOGUS name
#         emits a no-generic-match / PCWM warning. VCS exits 0 either way, so
#         the WARNING is the only honest signal that the param name is real. ---
echo "=================================================================="
echo "[discriminator] -pvalue on REAL vs BOGUS wrapper param name"
vcs -full64 -sverilog -timescale=1ns/1ps +define+TB_TOP_NO_DUMP +define+TIDELINK_PHY_V2 \
    "+define+NCR=7'h00" -f "$FLIST" "$STUB" "$WRAP" "$TB" -top tb_nego_plumb \
    -pvalue+tb_nego_plumb.u_wrap.NEGO_CFG_RESET=97 \
    -l vcs_real_pvalue.log >/dev/null 2>&1
vcs -full64 -sverilog -timescale=1ns/1ps +define+TB_TOP_NO_DUMP +define+TIDELINK_PHY_V2 \
    "+define+NCR=7'h00" -f "$FLIST" "$STUB" "$WRAP" "$TB" -top tb_nego_plumb \
    -pvalue+tb_nego_plumb.u_wrap.NEGO_CFG_RESET_TYPO=97 \
    -l vcs_bogus_pvalue.log >/dev/null 2>&1
# NO-GENERIC-MATCH is the exact VCS diagnostic for a -pvalue target that does
# not resolve to a real parameter. It is param-specific (unlike PCWM width
# warnings, which appear in both logs), so it is the honest discriminator.
REAL_W=$(grep -c "NO-GENERIC-MATCH" vcs_real_pvalue.log)
BOGUS_W=$(grep -c "NO-GENERIC-MATCH" vcs_bogus_pvalue.log)
echo "  REAL  param override warnings : $REAL_W  (expect 0)"
echo "  BOGUS param override warnings : $BOGUS_W  (expect >=1)"
[ "$BOGUS_W" -ge 1 ] || { echo "FAIL: bogus override did NOT warn — discriminator blind"; FAIL=1; }
[ "$REAL_W" -eq 0 ] || { echo "FAIL: real override warned — param name not actually bound"; FAIL=1; }

echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "PENDING-DECISION #6 PROOF: PASS — NEGO_CFG_RESET reaches the controller"
  echo "  default 7'h00 -> controller 0 ; strap 7'h61 -> controller 97 ;"
  echo "  wrapper param is genuinely targetable (bogus name warns, real does not)."
else
  echo "PENDING-DECISION #6 PROOF: FAIL"
fi
exit $FAIL

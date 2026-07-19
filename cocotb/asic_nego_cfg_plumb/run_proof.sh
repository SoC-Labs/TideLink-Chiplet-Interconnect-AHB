#!/bin/bash
# DECISION #4 — prove NEGO_CFG_RESET REACHES the controller through the
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
run() {   # $1=label  $2=extra-define  $3..=extra vcs args
  local label="$1" def="$2"; shift 2
  echo "=================================================================="
  echo "[$label] $def  extra=$*"
  vcs -full64 -sverilog -timescale=1ns/1ps \
      +define+TB_TOP_NO_DUMP +define+TIDELINK_PHY_V2 \
      "$def" \
      -f "$FLIST" "$STUB" "$WRAP" "$TB" \
      -top tb_nego_plumb -l "vcs_${label}.log" "$@" >/dev/null 2>&1
  ./simv -l "run_${label}.log" >/dev/null 2>&1
  grep "PROOF " "run_${label}.log" || echo "  (no PROOF line — elaboration failed, see $WORK/vcs_${label}.log)"
}

# --- A: THE SHIPPED ASIC VALUE. No override at all, so the wrapper takes its
#        OWN default, which DECISION #4 sets to 7'h61 (=97). This is the case
#        that proves the ASIC actually gets zero-poke autonomy. -------------
run default "+define+NCR_DEFAULT"
A_CTRL=$(grep "NEGO_CFG_RESET_at_controller" "run_default.log" | awk '{print $NF}')
[ "$A_CTRL" = "97" ] || { echo "FAIL: wrapper DEFAULT did not reach controller as 97 (got '$A_CTRL') — DECISION #4 did not land"; FAIL=1; }
# RETIRE_EN must remain 1 at the destination (DECISION #4 keeps it on).
A_RET=$(grep "RETIRE_EN_at_controller" "run_default.log" | awk '{print $NF}')
[ "$A_RET" = "1" ] || { echo "FAIL: RETIRE_EN did not reach controller as 1 (got '$A_RET')"; FAIL=1; }

# --- B: explicit 7'h00 must still reach the controller as 0 (plumbing is a
#        live pass-through, not a constant) -------------------------------
run off "+define+NCR=7'h00"
B_CTRL=$(grep "NEGO_CFG_RESET_at_controller" "run_off.log" | awk '{print $NF}')
[ "$B_CTRL" = "0" ] || { echo "FAIL: explicit 7'h00 did not reach controller as 0 (got '$B_CTRL')"; FAIL=1; }

# --- C: explicit 7'h61 (=97) must reach the controller as 97 ----------------
run strap97 "+define+NCR=7'h61"
C_CTRL=$(grep "NEGO_CFG_RESET_at_controller" "run_strap97.log" | awk '{print $NF}')
[ "$C_CTRL" = "97" ] || { echo "FAIL: strap 7'h61 did not reach controller as 97 (got '$C_CTRL')"; FAIL=1; }

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
  echo "DECISION #4 PROOF: PASS — NEGO_CFG_RESET reaches the controller"
  echo "  wrapper DEFAULT -> controller 97 (7'h61, zero-poke autonomy ON) ; RETIRE_EN -> 1 ;"
  echo "  explicit 7'h00 -> 0 ; explicit 7'h61 -> 97 ; param genuinely targetable."
else
  echo "DECISION #4 PROOF: FAIL"
fi
exit $FAIL

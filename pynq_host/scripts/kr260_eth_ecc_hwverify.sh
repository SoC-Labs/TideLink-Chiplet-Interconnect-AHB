#!/usr/bin/env bash
# kr260_eth_ecc_hwverify.sh — HW verification of the header-ECC restore + a
# CORRECTED directional error-injection sweep on the eth-chiplet KR260 pair.
#
# Corrected methodology (2026-08-04, from the axirec reconciliation):
#  * The Wlink error injector corrupts a die's OUTGOING packets on a data_id.
#    Forward FC nodes are transmitted by the INITIATOR, return nodes by the TARGET:
#       AW 0x80, W 0x81, AR 0x83  -> initiator (die_a) TX -> inject on die_a
#       B  0x82, R  0x84          -> target   (die_b) TX -> inject on die_b
#    Injecting a return node (B/R) on die_a is a NO-OP (die_a never sends it) and
#    reads as a vacuous "survive" — the trap this sweep exists to avoid.
#  * `reanchored` (EPOCH_STATUS 0x2140 bit0) is read up front — cross-die data
#    delivery can be anchor-gated (Z2 §3 / R1); a plain write is checked to LAND
#    at die_b (not merely to not-wedge die_a).
#  * With the header-ECC restore (WlinkEccSyndrome local override), a single-bit
#    header flip (byte 0 data_id / byte 1 word_count) is CORRECTED at the RX, so
#    each node's byte-0 injection should leave die_a ALIVE and data byte-exact.
#  * W byte-0 SOAK measures the residual intermittent wedge rate (the open
#    marginal item the ECC logic-fix does not fully eliminate on silicon).
#
# Prereqs: both dies deployed + brought up (fcsm=4); KR260_PASSWORD set.
# Requires eth_tlapb_poke.py (same dir) staged to /tmp on each die.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
A=${DIE_A:-ubuntu@10.22.24.159}; B=${DIE_B:-ubuntu@10.22.24.153}
PW=${KR260_PASSWORD:-soclabs2026}
SOAK=${SOAK:-10}
RUN="$HERE/kr260_eth_run.sh"
ssh_(){ sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$1" "${@:2}"; }
poke(){ ssh_ "$1" "echo '$PW' | sudo -S python3 /tmp/eth_tlapb_poke.py ${*:2} 2>/dev/null"; }
alive(){ ping -c1 -W2 "${1#*@}" >/dev/null 2>&1 && timeout 8 ssh_ "$1" true 2>/dev/null; }
stage(){ for h in "$A" "$B"; do sshpass -p "$PW" scp -q -o StrictHostKeyChecking=no "$HERE/eth_tlapb_poke.py" "$h:/tmp/" 2>/dev/null; done; }

FAIL=0
echo "=== eth-chiplet header-ECC HW verify (die_a=$A die_b=$B) ==="
stage

echo "--- [0] anchor state (reanchored) ---"
echo "  die_a: $(poke "$A" epoch)"
echo "  die_b: $(poke "$B" epoch)"
echo "--- [0b] AUTO_ANCHOR FSM diagnostic (0x21F4) — why reanchored did/didn't latch ---"
echo "  die_a: $(poke "$A" anchorobs)"
echo "  die_b: $(poke "$B" anchorobs)"

echo "--- [1] R1: plain cross-die write must LAND at die_b ---"
KR260_HOST="$A" KR260_XFER_SEED=0xC0FFEE01 timeout 90 bash "$RUN" xfer_send >/dev/null 2>&1
r1=$(KR260_HOST="$B" timeout 90 bash "$RUN" xfer_recv 2>&1 | grep -c "\[PASS\]")
if [ "$r1" -ge 1 ] && alive "$A"; then echo "  R1 PASS (payload landed, die_a alive)"; else echo "  R1 FAIL"; FAIL=1; fi

echo "--- [2] directional byte-0 injection sweep (die_a survives each) ---"
# node:data_id:injdie(A|B):op(w|r)
for spec in AW:0x80:A:w W:0x81:A:w AR:0x83:A:r B:0x82:B:w R:0x84:B:r; do
  IFS=: read -r nm did idie op <<<"$spec"
  ihost=$A; [ "$idie" = B ] && ihost=$B
  poke "$ihost" inject "$did" 0 0 >/dev/null 2>&1
  if [ "$op" = w ]; then KR260_HOST="$A" KR260_XFER_SEED=0xBEEF timeout 60 bash "$RUN" xfer_send >/dev/null 2>&1
  else KR260_HOST="$A" timeout 60 bash "$RUN" xfer_readback >/dev/null 2>&1; fi
  poke "$ihost" injectoff >/dev/null 2>&1
  if alive "$A"; then echo "  $nm byte-0 (inject on ${idie}): die_a ALIVE"; else echo "  $nm byte-0 (inject on ${idie}): die_a WEDGED"; FAIL=1; break; fi
done

echo "--- [3] W byte-0 SOAK ($SOAK trials, inject on die_a) — residual wedge rate ---"
ok=0; wed=0
if alive "$A"; then
  for i in $(seq 1 "$SOAK"); do
    poke "$A" inject 0x81 0 0 >/dev/null 2>&1
    KR260_HOST="$A" KR260_XFER_SEED=0xB0$i timeout 60 bash "$RUN" xfer_send >/dev/null 2>&1
    poke "$A" injectoff >/dev/null 2>&1
    if alive "$A"; then ok=$((ok+1)); else wed=$((wed+1)); echo "  W#$i WEDGED (POR needed to continue)"; break; fi
  done
  echo "  W byte-0 soak: ALIVE=$ok WEDGED=$wed of $SOAK"
else echo "  (die_a already wedged — skip soak)"; fi

echo "=== RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo 'FAIL/attention') (soak wedge>0 = known marginal residual) ==="
exit $FAIL

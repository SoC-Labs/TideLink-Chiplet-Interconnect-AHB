#!/bin/bash
# Canned bringup_pair_converge.sh stand-in for tests. Emits the same
# per-iter table + RESULT line the real script does.
#
# Env: FAKE_CONVERGE_OK=1 (default) -> emit "CONVERGED — full 16/16"
#      FAKE_CONVERGE_OK=0           -> emit "NOT CONVERGED" + best-seen
echo "=============================================================="
echo " TideLink coordinated closed-loop bring-up $(date)"
echo "=============================================================="
printf '%-4s | %-30s | %-30s | %s\n' IT \
  "die_a@A lk/ft cal# fs cr" "die_b@B lk/ft cal# fs cr" "tot/16"
printf '%-4s | %-30s | %-30s | %s\n' "1" \
  "0xff/0x00 8 1 fs0 cr1" "0xff/0x00 8 1 fs0 cr1" "16"
echo "=============================================================="
if [ "${FAKE_CONVERGE_OK:-1}" = "1" ]; then
  echo "RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1"
  echo "  die_a@A[ok] die_b@B[ok]"
  exit 0
else
  echo "RESULT: NOT CONVERGED in 3 re-deploys (NORMAL)."
  echo "  Best seen: 7/16 at iteration 2"
  echo "  die_a@A[...] die_b@B[...]"
  exit 1
fi

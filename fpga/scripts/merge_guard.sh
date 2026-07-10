#!/bin/bash
# =============================================================================
# merge_guard.sh — assert that a merge has not silently REVERTED a fix that is
# proven on silicon. Run AFTER any merge/rebase, BEFORE any build or tapeout.
#
# WHY. Two long-lived trunks disagree, and the "obvious" conflict resolution on
# each of these files reverts a fix that was proven on silicon:
#
#   1. WlinkGenericFCSM_6.v `fe_tx_credit_max_eff`
#      integ has it (6 hits); the die_b trunk has ZERO. This is THE A->B root
#      cause fix: with fe_tx_credit_max==0 there is no pktnum wrap and ring_mod=1,
#      so the receiver silently stops committing. Resolving toward die_b = dead
#      A->B link, silently, with every sim still green.
#
#   2. tidelink_top.sv `ext_lock_q` / `EXT_STALL_LIMIT`
#      The fc_cfg APB arbiter. Without it an in-flight PS/AHB access can be
#      preempted mid-ACCESS and never get PREADY. On the FPGA the Zynq M_AXI_GP
#      has no timeout; on the ASIC the hang surface is `cmsdk_ahb_to_apb` waiting
#      on PREADY forever. Either way: CPU hangs, unrecoverable.
#
# Add new entries here the moment a fix is proven on silicon. A grep is cheap;
# a respin is not.
# =============================================================================
set -u
fail=0
check(){ # $1=file  $2=token  $3=min-hits  $4=why
  local n; n=$(grep -c -- "$2" "$1" 2>/dev/null || echo 0)
  if [ "$n" -lt "$3" ]; then
    echo "FAIL: $1 has $n x '$2' (need >= $3)"
    echo "      $4"
    fail=1
  else
    echo "ok:   $1  '$2' x$n"
  fi; }

echo "=== merge_guard: silicon-proven fixes must survive the merge ==="
check src/rtl/local_overrides/WlinkGenericFCSM_6.v fe_tx_credit_max_eff 1 \
  "A->B credit fix REVERTED. Resolving FCSM_6.v toward the die_b trunk drops it."
check src/rtl/tidelink_top.sv ext_lock_q 1 \
  "fc_cfg APB arbiter REVERTED. An in-flight PS access can be preempted -> PREADY never returns -> CPU hang."
check src/rtl/tidelink_top.sv EXT_STALL_LIMIT 1 \
  "Bounded external APB stall REVERTED. The PS bus must be structurally unable to hang."

if [ "$fail" -ne 0 ]; then
  echo; echo "MERGE GUARD FAILED — do NOT build or tape out this tree."
  exit 1
fi
echo; echo "merge_guard: all silicon-proven fixes present."

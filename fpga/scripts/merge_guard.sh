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
#
# BUGFIX 2026-07-10 (ci-zeropoke-gate): the original count capture
#     n=$(grep -c -- "$2" "$1" 2>/dev/null || echo 0)
# was BROKEN. `grep -c` prints "0" AND exits 1 on a zero-count match, so the
# `|| echo 0` fired too and $n became the two-line string "0\n0". The arithmetic
# test then errored ("integer expression expected", exit 2 = non-zero), fell
# through to the else branch, and reported "ok" for a MISSING token. Measured:
# the old script exited 0 on feat/dieb-clock-fix-wip with fe_tx_credit_max_eff=0
# AND ext_lock_q=0 AND EXT_STALL_LIMIT=0 — i.e. it green-lit a tree with all
# three silicon-proven fixes reverted. The guard could never fail. Fixed below:
# capture the count without the spurious `|| echo`, default only a MISSING file
# to 0.
#
# NOTE 2026-07-17 (W2a): the TIDELINK_FPGA_VERIFICATION_PLAN §5-P5 gap item
# ("`n=$(grep -c -- "$2" "$1" || echo 0)` reports any zero-hit token as PASS")
# is STALE — it quotes the pre-fix line. The current `check()` correctly FAILs a
# zero-hit token (n=0 < min-hits). Verified: a zero-hit token and a missing file
# both drive n=0 -> FAIL. Two residual SILENT-false-pass edges are closed here:
#   (i)  a MISSING FILE now reports the real cause ("file not found") instead of
#        the misleading "has 0 x 'token'" — a missing override file is exactly
#        the class-J "missing looks like a legit zero" trap.
#   (ii) if the `flists/` dir is absent (moved/renamed), the FCSM 0-4 grep used to
#        return empty -> "ok" (silent pass). It is now a hard FAIL.
# A `--self-test` mode proves present->ok / absent->FAIL / missing-file->FAIL /
# flist-regression->FAIL without touching the repo.
# =============================================================================
set -u
fail=0
check(){ # $1=file  $2=token  $3=min-hits  $4=why
  if [ ! -f "$1" ]; then
    echo "FAIL: $1 NOT FOUND (cannot verify token '$2' — a missing file is not a pass)"
    echo "      ${4:-}"
    fail=1
    return
  fi
  local n; n=$(grep -c -- "$2" "$1" 2>/dev/null); n=${n:-0}
  if [ "$n" -lt "$3" ]; then
    echo "FAIL: $1 has $n x '$2' (need >= $3)"
    echo "      ${4:-}"
    fail=1
  else
    echo "ok:   $1  '$2' x$n"
  fi; }

# ---------------------------------------------------------------------------
# --self-test : prove the guard actually FAILS when it must, with no repo I/O.
#   present-token -> ok ; absent-token -> FAIL ; missing-file -> FAIL.
#   Exits 0 iff every expectation holds. This is the regression test the plan
#   asked for so the "grep-c false-pass" can never silently return.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ] || [ "${1:-}" = "--selftest" ]; then
  td=$(mktemp -d)
  trap 'rm -rf "$td"' EXIT
  printf 'alpha\nBETA present here\nBETA again\n' > "$td/have.txt"
  st_pass=0; st_fail=0
  st(){ # st <desc> <expected-fail 0|1> <check-args...>
    local desc="$1" want="$2"; shift 2
    fail=0; check "$@" >/dev/null 2>&1
    if [ "$fail" -eq "$want" ]; then echo "  ok   $desc (fail=$fail)"; st_pass=$((st_pass+1));
    else echo "  FAIL $desc (fail=$fail want $want)"; st_fail=$((st_fail+1)); fi
  }
  echo "=== merge_guard --self-test ==="
  st "present token -> ok"        0 "$td/have.txt" BETA 1
  st "present, need 2 -> ok"      0 "$td/have.txt" BETA 2
  st "absent token -> FAIL"       1 "$td/have.txt" MISSINGTOK 1
  st "too-few hits -> FAIL"       1 "$td/have.txt" BETA 3
  st "missing file -> FAIL"       1 "$td/nope.txt" BETA 1
  fail=0
  echo "self-test: pass=$st_pass fail=$st_fail"
  [ "$st_fail" -eq 0 ] && { echo "SELF-TEST PASS"; exit 0; } || { echo "SELF-TEST FAIL"; exit 1; }
fi

echo "=== merge_guard: silicon-proven fixes must survive the merge ==="
check src/rtl/local_overrides/WlinkGenericFCSM_6.v fe_tx_credit_max_eff 1 \
  "A->B credit fix REVERTED. Resolving FCSM_6.v toward the die_b trunk drops it."
check src/rtl/tidelink_top.sv ext_lock_q 1 \
  "fc_cfg APB arbiter REVERTED. An in-flight PS access can be preempted -> PREADY never returns -> CPU hang."
check src/rtl/tidelink_top.sv EXT_STALL_LIMIT 1 \
  "Bounded external APB stall REVERTED. The PS bus must be structurally unable to hang."

# --- FLIST FCSM 0-4 resolution (added 2026-07-11) --------------------------------------
# The RTL-token checks above are NOT enough: the merge can keep the RTL *files* correct
# yet swap the FLISTS to point FCSM 0-4 at src/rtl/local_overrides/ (the dieb copies with
# the L7 min-CRACK gate that stalls the FCSM at the silicon ratio => taped-out link-up
# stall). integ resolves FCSM 0-4 to deps/; that is the silicon-proven resolution. Any
# flist that compiles a local_overrides copy of FCSM 0-4 is the regression (commits
# 74d0d52/ce58c1b). FCSM_5 (deps) and FCSM_6 (local_overrides, the L6 producer fix) are
# BOTH correct and are deliberately not matched here.
echo "--- flist FCSM 0-4 must resolve to deps, not local_overrides ---"
if [ ! -d flists/ ]; then
  echo "FAIL: flists/ directory not found (run from the repo root). Cannot verify"
  echo "      FCSM 0-4 resolution — refusing to pass a check I could not run."
  fail=1
else
  bad=$(grep -rlE "local_overrides/WlinkGenericFCSM(\.|_[0-4]\.)v" flists/ 2>/dev/null)
  if [ -n "$bad" ]; then
    echo "FAIL: these flists point FCSM 0-4 at local_overrides (L7 min-CRACK stall — would tape out):"
    echo "$bad" | sed 's/^/        /'
    echo "      Re-resolve FCSM 0-4 to deps/axi-chiplet-controller/logical/wlink/ (matches integ)."
    fail=1
  else
    echo "ok:   no flist compiles a local_overrides FCSM 0-4"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo; echo "MERGE GUARD FAILED — do NOT build or tape out this tree."
  exit 1
fi
echo; echo "merge_guard: all silicon-proven fixes present."

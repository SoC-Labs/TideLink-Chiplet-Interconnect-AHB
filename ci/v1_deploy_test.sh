#!/usr/bin/env bash
#=============================================================================
# ci/v1_deploy_test.sh  —  CI wrapper: stage the V1 bitstream artefacts to
#   mapstone-dev and run the bilateral regression gate against the bridge1
#   PYNQ-Z2 pair, ALWAYS releasing the fpgahub lease on exit.
#
# Runs on the HW runner (tag: tidelink-hw). That runner needs ONLY an SSH
# alias `mapstone-dev` (key-based, user `david`) — it does NOT need board
# routes itself. mapstone-dev is the single host that can reach the boards'
# PS-management network (192.168.4.101 / 192.168.2.101) and holds the fpgahub
# CLI; td_v1_b2a_proof.sh + td_bilateral_regression.sh use sshpass into the
# boards, so they execute THERE, proxied via ssh from this runner.
#
# Flow:
#   1. Stage the artefact bitstreams (from the build stage, or a pinned
#      ~/td_v1_deploy/ on mapstone-dev) into REMOTE_DEPLOY_DIR on mapstone-dev,
#      named tidelink.bit (die_a) + tidelink-flip.bit (die_b) as the proof
#      script's BIT_A/BIT_B expect. Uses tar-over-ssh (rsync/scp are flaky
#      between the dev hosts — see docs/BOARD_DEPLOY_RUNBOOK.md §3).
#   2. Sync THIS repo's pynq_host/scripts to mapstone-dev so the regression
#      script run there matches the commit under test.
#   3. Run td_bilateral_regression.sh on mapstone-dev (PROOF=program so it
#      loads both dies + captures the lease), with the documented env.
#   4. Pull back the JUnit summary + the run log as CI artefacts.
#   5. ALWAYS release the bridge1 lease (the regression script's own EXIT trap
#      does this; we add a belt-and-braces release here too).
#
# The exit code of the remote regression script is propagated verbatim, so the
# CI job is red iff BILATERAL REGRESSED.
#
# Required / defaulted env:
#   MAPSTONE_SSH        ssh alias/target for mapstone-dev   [default: mapstone-dev]
#   ARTIFACT_DIR        local dir from the build stage with
#                       <target>/tidelink.bit               [default: $PWD/ci_artifacts/fpga]
#   BIT_A_SRC           local die_a .bit                    [default:
#                         $ARTIFACT_DIR/pynq-z2-pair-all/tidelink.bit]
#   BIT_B_SRC           local die_b flip .bit               [default:
#                         $ARTIFACT_DIR/pynq-z2-pair-flip-all/tidelink.bit]
#   USE_PINNED_BITS     if 1, SKIP staging and use whatever .bit already sit in
#                       REMOTE_DEPLOY_DIR on mapstone-dev    [default: 0]
#   REMOTE_DEPLOY_DIR   non-/tmp staging dir on mapstone-dev [default:
#                         /home/david/td_v1_deploy] (fpgahubd has PrivateTmp,
#                         so /tmp is invisible to the overlay — must be non-/tmp)
#   REMOTE_REPO_DIR     mapstone-dev checkout to drop scripts into [default:
#                         /home/david/SoCLabs/tidelink]
#   PROOF               proof mode                           [default: program]
#   ATOB_MIN            min A->B passes (=1 baseline, ~12 post-fix) [default: 1]
#   ATOB_RUNS / ROLLS / BTOA_TRIES   forwarded to the gate   [defaults 15/15/2]
#   RESULT_DIR          local dir for fetched artefacts       [default: $PWD/ci_artifacts/regression]
#
# Exit codes:
#   0    BILATERAL OK
#   1    BILATERAL REGRESSED (gate failed)
#   2    setup error (ssh alias unreachable / no bitstreams to stage)
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

MAPSTONE_SSH="${MAPSTONE_SSH:-mapstone-dev}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PWD/ci_artifacts/fpga}"
BIT_A_SRC="${BIT_A_SRC:-$ARTIFACT_DIR/pynq-z2-pair-all/tidelink.bit}"
BIT_B_SRC="${BIT_B_SRC:-$ARTIFACT_DIR/pynq-z2-pair-flip-all/tidelink.bit}"
USE_PINNED_BITS="${USE_PINNED_BITS:-0}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-/home/david/td_v1_deploy}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/home/david/SoCLabs/tidelink}"
PROOF="${PROOF:-program}"
ATOB_MIN="${ATOB_MIN:-1}"
ATOB_RUNS="${ATOB_RUNS:-15}"
ROLLS="${ROLLS:-15}"
BTOA_TRIES="${BTOA_TRIES:-2}"
RESULT_DIR="${RESULT_DIR:-$PWD/ci_artifacts/regression}"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
REMOTE_SCRIPTS_DIR="$REMOTE_REPO_DIR/pynq_host/scripts"
REMOTE_JUNIT="$REMOTE_DEPLOY_DIR/bilateral_junit.xml"
REMOTE_LOG="$REMOTE_DEPLOY_DIR/bilateral_run.log"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ printf '[v1-deploy %s] %s\n' "$(ts)" "$*"; }
die(){ log "FATAL: $*"; exit "${2:-2}"; }

mssh(){ ssh $SSH_OPTS "$MAPSTONE_SSH" "$@"; }

mkdir -p "$RESULT_DIR"

# Belt-and-braces lease release: the regression gate releases its own lease,
# but if THIS wrapper dies before/around the remote run we still free bridge1.
remote_release(){
  log "ensuring bridge1 lease released on mapstone-dev"
  mssh "/opt/fpgahub/bin/fpgahub pair lease release bridge1 >/dev/null 2>&1 || true; \
        cd '$REMOTE_SCRIPTS_DIR' 2>/dev/null && PAIR=bridge1 ./td_v1_b2a_proof.sh --release >/dev/null 2>&1 || true" \
        >/dev/null 2>&1 || true
}
trap remote_release EXIT INT TERM

# ---- 0: reach mapstone-dev --------------------------------------------------
log "checking ssh alias '$MAPSTONE_SSH'"
mssh "echo reachable: \$(hostname); /opt/fpgahub/bin/fpgahub --version 2>/dev/null || echo 'WARN fpgahub not found'" \
  || die "cannot ssh '$MAPSTONE_SSH' (the tidelink-hw runner needs a key-based SSH alias to mapstone-dev, user david)" 2

# ---- 1: stage bitstreams (unless pinned) ------------------------------------
if [ "$USE_PINNED_BITS" = 1 ]; then
  log "USE_PINNED_BITS=1 — using existing bitstreams in $REMOTE_DEPLOY_DIR on mapstone-dev"
  mssh "ls -l '$REMOTE_DEPLOY_DIR'/tidelink.bit '$REMOTE_DEPLOY_DIR'/tidelink-flip.bit" \
    || die "pinned bitstreams not found in $REMOTE_DEPLOY_DIR (need tidelink.bit + tidelink-flip.bit)" 2
else
  [ -f "$BIT_A_SRC" ] || die "die_a bitstream not found: $BIT_A_SRC (run the build stage first, or set USE_PINNED_BITS=1)" 2
  [ -f "$BIT_B_SRC" ] || die "die_b flip bitstream not found: $BIT_B_SRC" 2
  log "staging bitstreams to $MAPSTONE_SSH:$REMOTE_DEPLOY_DIR via tar-over-ssh"
  # Lay out a flat staging dir locally with the names the proof script wants,
  # plus the bit2bin'd .bin and .hwh (for re-POR rolls + deploy_pair fallback).
  STAGE="$(mktemp -d)"
  cp "$BIT_A_SRC" "$STAGE/tidelink.bit"
  cp "$BIT_B_SRC" "$STAGE/tidelink-flip.bit"
  python3 "$TIDELINK_HOME/fpga/scripts/bit2bin.py" "$BIT_A_SRC" "$STAGE/tidelink.bin" 2>/dev/null || true
  python3 "$TIDELINK_HOME/fpga/scripts/bit2bin.py" "$BIT_B_SRC" "$STAGE/tidelink-flip.bin" 2>/dev/null || true
  cp "$(dirname "$BIT_A_SRC")/tidelink.hwh" "$STAGE/tidelink.hwh"           2>/dev/null || true
  cp "$(dirname "$BIT_B_SRC")/tidelink.hwh" "$STAGE/tidelink-flip.hwh"      2>/dev/null || true
  tar -C "$STAGE" -cf - . | mssh "mkdir -p '$REMOTE_DEPLOY_DIR' && tar -C '$REMOTE_DEPLOY_DIR' -xf - && \
        echo '-- staged --' && sha256sum '$REMOTE_DEPLOY_DIR'/tidelink.bit '$REMOTE_DEPLOY_DIR'/tidelink-flip.bit" \
    || { rm -rf "$STAGE"; die "staging bitstreams to mapstone-dev failed" 2; }
  rm -rf "$STAGE"
fi

# ---- 2: sync the regression + proof scripts under test ----------------------
# Keep the script-under-test in lockstep with this commit (the proof/gate logic
# may change between baselines). tar just the two scripts into the remote repo.
log "syncing regression scripts to $MAPSTONE_SSH:$REMOTE_SCRIPTS_DIR"
tar -C "$TIDELINK_HOME/pynq_host/scripts" -cf - td_bilateral_regression.sh td_v1_b2a_proof.sh \
  | mssh "mkdir -p '$REMOTE_SCRIPTS_DIR' && tar -C '$REMOTE_SCRIPTS_DIR' -xf - && \
          chmod +x '$REMOTE_SCRIPTS_DIR'/td_bilateral_regression.sh '$REMOTE_SCRIPTS_DIR'/td_v1_b2a_proof.sh" \
  || die "syncing regression scripts to mapstone-dev failed" 2

# ---- 3: run the gate on mapstone-dev ----------------------------------------
log "running td_bilateral_regression.sh on mapstone-dev"
log "  PROOF=$PROOF ATOB_MIN=$ATOB_MIN ATOB_RUNS=$ATOB_RUNS ROLLS=$ROLLS BTOA_TRIES=$BTOA_TRIES"
# BIT_A/BIT_B point the proof's --program at the staged bitstreams. RELEASE=1
# so the gate frees the lease itself; JUNIT_OUT writes the per-direction suite.
# This script runs without `set -e`, so a non-zero remote rc does NOT abort —
# we capture it, fetch artefacts, and propagate it as the job's exit code.
rc=0
mssh "cd '$REMOTE_SCRIPTS_DIR' && \
      PROOF='$PROOF' ATOB_MIN='$ATOB_MIN' ATOB_RUNS='$ATOB_RUNS' ROLLS='$ROLLS' \
      BTOA_TRIES='$BTOA_TRIES' RELEASE=1 PAIR=bridge1 \
      BIT_A='$REMOTE_DEPLOY_DIR/tidelink.bit' BIT_B='$REMOTE_DEPLOY_DIR/tidelink-flip.bit' \
      JUNIT_OUT='$REMOTE_JUNIT' \
      ./td_bilateral_regression.sh 2>&1 | tee '$REMOTE_LOG'; exit \${PIPESTATUS[0]}" || rc=$?

# ---- 4: pull back artefacts -------------------------------------------------
log "fetching JUnit + run log to $RESULT_DIR"
mssh "cat '$REMOTE_JUNIT' 2>/dev/null" > "$RESULT_DIR/bilateral_junit.xml" 2>/dev/null || true
mssh "cat '$REMOTE_LOG'   2>/dev/null" > "$RESULT_DIR/bilateral_run.log"   2>/dev/null || true
# If the gate never wrote JUnit (e.g. setup error), synthesise an error suite
# so the CI report still shows something red rather than empty.
if [ ! -s "$RESULT_DIR/bilateral_junit.xml" ]; then
  log "no JUnit from remote — synthesising an error suite (rc=$rc)"
  cat > "$RESULT_DIR/bilateral_junit.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="td_bilateral_regression (no remote JUnit)">
  <testsuite name="tidelink.v1_silicon_bilateral" tests="1" errors="1">
    <testcase classname="tidelink.bilateral" name="harness">
      <error type="no_junit" message="remote gate produced no JUnit (rc=$rc); see bilateral_run.log"/>
    </testcase>
  </testsuite>
</testsuites>
EOF
fi

log "remote bilateral gate exited rc=$rc"
if [ "$rc" -eq 0 ]; then
  log "RESULT: BILATERAL OK"
else
  log "RESULT: BILATERAL REGRESSED (rc=$rc) — see $RESULT_DIR/bilateral_run.log"
fi
exit "$rc"

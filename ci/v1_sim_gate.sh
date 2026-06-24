#!/usr/bin/env bash
#=============================================================================
# ci/v1_sim_gate.sh  —  cheap RTL sim gate for the V1 bilateral flow.
#
# Runs the integrated paired-die cocotb sim (two cross-wired tidelink_top
# instances, the closest pre-silicon analogue of the bridge1 B<->A link) so an
# RTL regression is caught WITHOUT touching the boards. This is the "sim-gate
# before HW deploy" policy: it runs on every push/MR (tag: vcs), and the heavy
# build/deploy_test stages are gated behind it.
#
# Default gate = cocotb/tidelink_top_pair MODULE=test_tidelink_pair_doorbell
# (the AHB->Wlink FC/credit->PHY->RX delivery path). Override SIM_ENVS /
# SIM_MODULE to widen or narrow.
#
# cocotb writes results.xml (JUnit) natively in each env dir; we collect them
# under $RESULT_DIR for the CI `reports: junit:` block.
#
# Required / defaulted env:
#   SIM_ENVS     space-separated cocotb env dirs   [default: tidelink_top_pair]
#   SIM_MODULE   cocotb MODULE for single-env runs [default: test_tidelink_pair_doorbell]
#   SIM          simulator                          [default: from env / Makefile (vcs)]
#   RESULT_DIR   where to collect results.xml       [default: $PWD/ci_artifacts/sim]
#
# Exit codes:
#   0   all selected sim envs passed
#   1   a sim env failed (or produced no results.xml)
#   2   environment problem (CMSDK / set_env)
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

SIM_ENVS="${SIM_ENVS:-tidelink_top_pair}"
SIM_MODULE="${SIM_MODULE:-test_tidelink_pair_doorbell}"
RESULT_DIR="${RESULT_DIR:-$PWD/ci_artifacts/sim}"

ts(){ date '+%H:%M:%S'; }
log(){ printf '[v1-sim %s] %s\n' "$(ts)" "$*"; }

export TIDELINK_HOME
# CMSDK is needed by the pair flist; derive it the same way the cocotb Makefiles
# do (from ARM_IP_LIBRARY_PATH) if not already set.
if [ -z "${CMSDK_DIR:-}" ] && [ -n "${ARM_IP_LIBRARY_PATH:-}" ]; then
  export CMSDK_DIR="$ARM_IP_LIBRARY_PATH/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0"
fi
# set_env.sh generates XHB500 IP + sets paths (the pair RTL needs the bridges).
# shellcheck disable=SC1091
source "$TIDELINK_HOME/set_env.sh" >/dev/null 2>&1 || log "WARN set_env.sh non-zero (XHB500 may already be generated)"

mkdir -p "$RESULT_DIR"
fail=0
for env in $SIM_ENVS; do
  envdir="$TIDELINK_HOME/cocotb/$env"
  [ -d "$envdir" ] || { log "ERROR: cocotb env not found: $envdir"; fail=1; continue; }
  log "running cocotb env=$env MODULE=$SIM_MODULE"
  ( cd "$envdir" && make clean >/dev/null 2>&1; make MODULE="$SIM_MODULE" ) 2>&1 | tee "$RESULT_DIR/${env}.run.log" | grep -E '^\*\*|regression|TESTS=|FAIL' || true
  rxml="$envdir/results.xml"
  if [ -f "$rxml" ]; then
    cp "$rxml" "$RESULT_DIR/${env}.results.xml"
    # cocotb encodes failures in <failure> elements; grep is enough for a gate.
    if grep -q "<failure" "$rxml"; then
      log "  $env: FAIL (see $RESULT_DIR/${env}.run.log)"
      fail=1
    else
      log "  $env: PASS"
    fi
  else
    log "  $env: NO results.xml — treating as FAIL"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  log "RESULT: SIM GATE FAILED"
  exit 1
fi
log "RESULT: SIM GATE PASSED"
exit 0

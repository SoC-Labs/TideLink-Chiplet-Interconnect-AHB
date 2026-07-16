#!/bin/bash
# =============================================================================
# stage_and_run.sh — convenience wrapper: push the HW regression suite to the
# lab host (which can SSH the PYNQ pair) and run it there.
#
# Run from the repo on a machine that can SSH the lab host. All args after the
# host are forwarded to td_v2_regress.sh.
#
#   ./stage_and_run.sh [LAB_HOST]                 # default LAB_HOST=mapstone-dev
#   ./stage_and_run.sh mapstone-dev --no-deploy
#
# Assumes the bitstream-under-test bins are already staged on the lab host at
# $TD_DEPLOY_DIR (default /tmp/tidelink_deploy_l7): tidelink.bin (die_a) and
# tidelink-flip.bin (die_b). Build + bit2bin + scp those before running.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB_HOST="${1:-mapstone-dev}"; [ $# -gt 0 ] && shift || true
REMOTE_DIR="${TD_REMOTE_DIR:-\$HOME/td_hw_regression}"

echo "-- staging suite to $LAB_HOST:$REMOTE_DIR --"
ssh "$LAB_HOST" "mkdir -p $REMOTE_DIR"
rsync -az --delete "$HERE/" "$LAB_HOST:$REMOTE_DIR/"
echo "-- running td_v2_regress.sh $* --"
ssh -t "$LAB_HOST" "cd $REMOTE_DIR && ./td_v2_regress.sh $*"

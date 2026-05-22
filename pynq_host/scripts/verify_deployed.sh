#!/bin/bash
# =============================================================================
# verify_deployed.sh — confirm what bitstream is ACTUALLY loaded on each board
# (Bug #32 — wrong-bitstream guard, Layer 4).  Read-only: NEVER flashes.
#
# For each board it reads back the MD5 of /lib/firmware/tidelink.bin and
# compares it to the MD5 of the staged .bin (whose sha256 is in turn checked
# against the manifest). So an operator can answer "is the right bitstream
# loaded right now?" at any time without redeploying.
#
# This is the cross-check that would have caught the May-6 phase-v2 mixup
# (MD5 188ebdd8) immediately instead of after hours: the staged .bin's sha256
# would not have matched the morning-v1 manifest, and/or the on-board MD5
# would not have matched the intended bitstream.
#
# Usage:
#   verify_deployed.sh [options]
#     --master <ip>     master board IP   (default 192.168.4.101)
#     --slave  <ip>     slave  board IP   (default 192.168.6.101)
#     --artefacts <dir> staging dir       (default /tmp/tidelink_deploy)
#     --manifest <f>    manifest for the die_a (non-flip) bitstream
#                       (default: auto <artefacts>/tidelink.bin.manifest.json)
#     --manifest-flip <f> manifest for the die_b (flip) bitstream
#
# Exit 0 = both boards verified MATCH manifest. Non-zero = a mismatch or a
# board could not be read (loud — same DEPLOY-ABORT markers as deploy_pair).
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

MASTER_IP="192.168.4.101"
SLAVE_IP="192.168.6.101"
ARTEFACTS="/tmp/tidelink_deploy"
MANIFEST=""
MANIFEST_FLIP=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --master)         MASTER_IP="$2"; shift 2 ;;
        --slave)          SLAVE_IP="$2"; shift 2 ;;
        --artefacts)      ARTEFACTS="$2"; shift 2 ;;
        --manifest)       MANIFEST="$2"; shift 2 ;;
        --manifest-flip)  MANIFEST_FLIP="$2"; shift 2 ;;
        *) echo "verify_deployed.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_PAIR="${DEPLOY_PAIR:-$SCRIPT_DIR/deploy_pair.sh}"
[ -f "$DEPLOY_PAIR" ] || { echo "verify_deployed.sh: deploy_pair.sh not found at $DEPLOY_PAIR" >&2; exit 2; }

rc=0
echo "=============================================================="
echo " TideLink deployment provenance verify  $(date)"
echo "  artefacts=$ARTEFACTS"
echo "=============================================================="

# die_a (non-flip) on master IP.
A_ARGS=("$MASTER_IP" z2_master die_a "$ARTEFACTS" --check-only)
[ -n "$MANIFEST" ] && A_ARGS+=(--manifest "$MANIFEST")
bash "$DEPLOY_PAIR" "${A_ARGS[@]}" || rc=1

# die_b (flip) on slave IP.
B_ARGS=("$SLAVE_IP" z2_slave die_b "$ARTEFACTS" --check-only)
[ -n "$MANIFEST_FLIP" ] && B_ARGS+=(--manifest "$MANIFEST_FLIP")
bash "$DEPLOY_PAIR" "${B_ARGS[@]}" || rc=1

echo "=============================================================="
if [ "$rc" -eq 0 ]; then
    echo "RESULT: provenance VERIFIED on both boards"
else
    echo "RESULT: provenance MISMATCH or unreadable — see DEPLOY-ABORT above" >&2
fi
exit "$rc"

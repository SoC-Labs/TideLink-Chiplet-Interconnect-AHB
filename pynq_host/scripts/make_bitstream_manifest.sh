#!/bin/bash
# =============================================================================
# make_bitstream_manifest.sh — emit a provenance manifest for a TideLink
# bitstream (Bug #32 — wrong-bitstream guard, Layer 2).
#
# Given a .bin (+ optional metadata), writes "<bitstream>.manifest.json" next
# to it with the sha256 computed at build time. deploy_pair.sh / verify_
# deployed.sh read this manifest and REFUSE to flash anything whose staged
# .bin does not match the recorded sha256 — so a stale/wrong bitstream left
# in the shared volatile staging dir (/tmp/tidelink_deploy) can never again
# be deployed blindly the way the May-6 phase-v2 (MD5 188ebdd8) build was.
#
# Manifest schema (small JSON, no jq needed to read):
#   {
#     "sha256":            "<64 hex>",      # of the .bin, computed here
#     "source_commit":     "<git sha|->",   # commit the bitstream was built from
#     "build_host":        "<hostname>",
#     "build_date":        "<ISO-8601 UTC>",
#     "target":            "<board/target>",# e.g. pynq-z2-pair / pynq-z2-pair-flip
#     "expected_lock_min":  <int>,          # min lane-lock this build should hit
#     "label":             "<human label>"  # e.g. morning-v1
#   }
#
# Usage:
#   make_bitstream_manifest.sh <bitstream.bin> [options]
#     --label <s>          human label (default: basename)
#     --commit <sha>       source commit (default: `git rev-parse HEAD` if in repo)
#     --target <s>         target name (default: derived from filename)
#     --lock-min <n>       expected minimum lane lock (default: 0)
#     --build-host <s>     build host (default: $(hostname))
#     --build-date <iso>   build date (default: now, UTC)
#     --out <path>         output path (default: <bitstream>.manifest.json)
#
# Build-flow hook (documented, not wired inline into build_design.tcl):
#   After the .bit -> .bin step (or in the farm_build artefact-staging step),
#   call e.g.:
#     make_bitstream_manifest.sh output/pynq-z2-pair-all/tidelink.bin \
#         --label "v1.1-fixes" --commit "$(git rev-parse HEAD)" \
#         --target pynq-z2-pair --lock-min 12
#   then stage tidelink.bin AND tidelink.bin.manifest.json together. Any Make
#   target that copies bitstreams into /tmp/tidelink_deploy should copy the
#   sibling .manifest.json too.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -e

BIN="$1"; shift || true
if [ -z "$BIN" ]; then
    sed -n '28,40p' "$0" | sed 's/^# *//'; exit 2
fi
if [ ! -f "$BIN" ]; then
    echo "make_bitstream_manifest.sh: bitstream not found: $BIN" >&2; exit 2
fi

LABEL="$(basename "$BIN")"
COMMIT=""
TARGET=""
LOCKMIN=0
BUILD_HOST="$(hostname 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)      LABEL="$2"; shift 2 ;;
        --commit)     COMMIT="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --lock-min)   LOCKMIN="$2"; shift 2 ;;
        --build-host) BUILD_HOST="$2"; shift 2 ;;
        --build-date) BUILD_DATE="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        *) echo "make_bitstream_manifest.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# Default commit: current repo HEAD if we are inside a git tree.
if [ -z "$COMMIT" ]; then
    COMMIT="$(git -C "$(dirname "$BIN")" rev-parse HEAD 2>/dev/null || echo '-')"
fi
# Default target: derive flip/non-flip from the filename.
if [ -z "$TARGET" ]; then
    case "$(basename "$BIN")" in
        *-flip.bin) TARGET="pynq-z2-pair-flip" ;;
        *)          TARGET="pynq-z2-pair" ;;
    esac
fi

SHA=$(sha256sum "$BIN" | awk '{print $1}')
[ -z "$OUT" ] && OUT="${BIN}.manifest.json"

cat > "$OUT" <<EOF
{
  "sha256": "$SHA",
  "source_commit": "$COMMIT",
  "build_host": "$BUILD_HOST",
  "build_date": "$BUILD_DATE",
  "target": "$TARGET",
  "expected_lock_min": $LOCKMIN,
  "label": "$LABEL"
}
EOF

echo "wrote $OUT"
echo "  sha256=$SHA label=$LABEL target=$TARGET commit=$COMMIT lock_min=$LOCKMIN"

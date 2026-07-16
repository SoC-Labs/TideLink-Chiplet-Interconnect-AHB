#!/bin/bash
# =============================================================================
# stage_rung.sh — bit2bin + stage ONE rung's pair to mapstone-dev, with md5s
#
# A rate number without a named bitstream md5 is meaningless (this project has
# shipped "refuted" fixes that were never in the bitstream). So this script
# prints, and stages alongside the artefacts, the md5 of exactly what goes to
# each board.
#
# Usage: ./stage_rung.sh <rung-label> [stage-dir]
#   e.g. ./stage_rung.sh rung2-6p25MHz /tmp/td_rate_ladder
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${1:?usage: stage_rung.sh <rung-label> [stage-dir]}"
STAGE="${2:-/tmp/td_rate_ladder}"
IMP="$ROOT/imp/fpga/output"

say(){ echo "[stage $(date -u +%H:%M:%SZ)] $*"; }
die(){ echo "[stage ABORT] $*" >&2; exit 1; }

ssh mapstone-dev "mkdir -p $STAGE" || die "cannot mkdir $STAGE on mapstone-dev"

stage_one(){ # $1=target dir  $2=staged basename
  local d="$IMP/$1" bit bin
  bit="$d/tidelink.bit"; bin="$d/tidelink.bin"
  [ -f "$bit" ] || die "$1: no tidelink.bit — did the build finish?"
  rm -f "$bin" "$d/tidelink.bit.bin"                 # never ship a stale .bin
  python3 "$ROOT/fpga/scripts/bit2bin.py" "$bit" "$bin" >/dev/null 2>&1 \
    || die "$1: bit2bin failed"
  [ -s "$bin" ] || die "$1: bit2bin produced an empty .bin"
  [ "$bin" -nt "$bit" ] || die "$1: regenerated .bin is not newer than .bit (stale trap)"
  local m; m=$(md5sum "$bin" | cut -d' ' -f1)
  say "$1 -> $2.bin  md5=$m  ($(stat -c%s "$bin") bytes, bit dated $(date -r "$bit" '+%b%d %H:%M'))"
  echo "$LABEL $2 $m $(date -u +%FT%TZ)" >> "$STAGE.md5.local"
  scp -q "$bin"            "mapstone-dev:$STAGE/$2.bin"  || die "scp $2.bin"
  scp -q "$d/tidelink.hwh" "mapstone-dev:$STAGE/$2.hwh"  || die "scp $2.hwh"
}

: > "$STAGE.md5.local"
stage_one pynq-z2-pair-all      tidelink        # die_a (master, z2_02)
stage_one pynq-z2-pair-flip-all tidelink-flip   # die_b (slave,  z2_01)

# harness (hwlib + the rung scripts + the channels data test they call)
scp -q "$ROOT"/fpga/hw_regression/{td_v2_hwlib.sh,td_v2_channels.sh,rate_lane_census.sh,mask_ab_rung.sh} \
       "mapstone-dev:$STAGE/" || die "scp harness"
scp -q "$STAGE.md5.local" "mapstone-dev:$STAGE/BITSTREAM_MD5.txt" || die "scp md5 manifest"
ssh mapstone-dev "chmod +x $STAGE/*.sh"
say "staged $LABEL -> mapstone-dev:$STAGE"
say "md5 manifest:"; cat "$STAGE.md5.local"

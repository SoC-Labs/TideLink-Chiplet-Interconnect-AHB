#!/usr/bin/env bash
# run_arm.sh <baseline|tl035> — run one TL-035 A/B arm with pinned provenance.
#
# The md5s below are the SOURCE-OF-TRUTH images from
#   tidelink/imp/fpga/output/kr260-eth-chiplet{,-flip}.<label>/tidelink.bin
# pinned here so a mis-staged or silently-replaced board image ABORTS the run
# instead of producing a result nobody can attribute. (The rig was found running
# an unlabelled ILA build with a foreign .hwh — provenance is not assumable.)
#
#   baseline = a2lonly-28409f5, built 2026-08-09, source 5d58c2a3
#              the "known-delivering" build (128/128 byte-exact on 08-09)
#   tl035    = .tl033,          built 2026-08-11, source d317c98...-dirty
#              Part-A + Part-B state-7 watchdog fix (TL033_LEGACY_WDOG undefined)
set -eu
ARM="${1:?usage: run_arm.sh <baseline|tl035>}"
case "$ARM" in
  baseline) MD5_A=9eadebb80470ace022eb2bad769f888b; MD5_B=13573e46c3b27bb6b03b41b2ce730aa8 ;;
  tl035)    MD5_A=8947a50d814475bafd20a836c6f4dd43; MD5_B=5979d88cacf1586525bd896f99352184 ;;
  *) echo "unknown arm '$ARM' (expected baseline|tl035)" >&2; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
export MD5_A MD5_B
exec "$HERE/tl035_ab.sh" "$ARM"

#!/bin/bash
# gen_flist.sh <FCSM_SRC> <BASE_FLIST> <OUT_FLIST>
# Generate the DUT flist for the I1 async/cold repro, selecting which copy of
# the five AXI FC nodes (WlinkGenericFCSM{,_1..4}) is compiled.
#
# NOTE: flists/tidelink_fpga_v2.flist ALREADY points FCSM 0-4 at
# src/rtl/local_overrides (the I1 re-point b98b944 is in the shipping flist),
# so "override" == base flist verbatim, and "deps" must re-point the OTHER way.
#
#   override : shipping local_overrides FCSM (recovery + L6/L7 HOLD armed from
#              reset). This is the silicon-shipping I1 configuration. RED cand.
#   deps     : recovery-STRIPPED deps FCSM (no L6/L7 gate, no extra footprint).
#              GREEN control.
#   emitfix  : the REFUTED emit-gate fix (e79a5b8) — local_overrides recovery
#              with socl_reached_link_idle holding the L6/L7 gate OPEN until
#              LINK_IDLE. Must stay RED (silicon says it does not work).
set -e
SRC="$1"; BASE="$2"; OUT="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOV='\$\{TIDELINK_HOME\}/src/rtl/local_overrides/(WlinkGenericFCSM(_[1-4])?)\.v'
case "$SRC" in
  override)
    cp "$BASE" "$OUT" ;;
  deps)
    sed -E "s@${LOV}@\$\{TIDELINK_HOME\}/deps/axi-chiplet-controller/logical/wlink/\1.v@" \
        "$BASE" > "$OUT" ;;
  emitfix)
    sed -E "s@${LOV}@${HERE}/emitfix_fcsm/\1.v@" "$BASE" > "$OUT" ;;
  *)
    echo "gen_flist.sh: unknown FCSM_SRC='$SRC'" >&2; exit 1 ;;
esac

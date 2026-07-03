#!/bin/bash
# =============================================================================
# verify_build.sh — post-build PROVENANCE GATE for the V2 pair bitstreams
#
# Run after every farm build, BEFORE staging anything to a board. Codifies the
# checks that three separate silent-V1 / stale-artifact incidents proved we
# must never skip (silent V1 fallback = dead link; stale IP = instrument
# missing from silicon; stale .bin = flashing yesterday's image).
#
# Checks (each prints PASS/FAIL/WARN + an evidence line):
#   (a) V2 banner "TIDELINK filelist: V2" in the NEWEST package_ip log
#       (imp/fpga/run/package_ip*.log + imp/fpga/run/*/package_ip*.log)
#   (b) imp/fpga/gen_v2/Wlink.v carries the V2 defines + E4 reset mask
#   (c) key autonomy signals survive into imp/fpga/gen_v2/axi_chiplet_controller.sv
#       (list parameterized below — extend it as loops add signals)
#   (d) both target tidelink.bit files exist, are NEWER than the newest run's
#       start, and have DIFFERENT md5s (identical = one half not rebuilt)
#   (e) WINSCAN_CELLS: prints the ready-to-run Vivado one-liner per target;
#       with --with-dcp (and vivado on PATH) actually runs it and requires >0
#   (f) WARN on any tidelink.bin OLDER than its tidelink.bit (stale bit2bin
#       trap — boards flash the .bin, not the .bit)
#
# USAGE:  fpga/scripts/verify_build.sh [--worktree DIR] [--with-dcp]
#   --worktree DIR  repo root to check (default: this script's repo)
#   --with-dcp      open each routed DCP in Vivado and count winscan cells
#                   (slow, ~minutes per target)
#
# Exit: 0 = all checks PASS (warnings allowed), non-zero otherwise.
# Read-only: never writes inside the worktree (safe alongside a running build).
# =============================================================================
set -u

# ----- parameterized expectations (EXTEND HERE in future loops) ---------------
V2_BANNER='TIDELINK filelist: V2'
WLINK_MUSTS=(
  '`define TIDELINK_PHY_V2'
  '`define TD_AUTO_LANE_MASK_E4'
  "LANE_MASK_RESET = 8'hE4;"
)
AUTONOMY_SIGNALS=(
  ws_kick_pending_q       # FIX-1 episode-bound winscan kick
  sync_cfg_hold_q         # L3 autonomous SYNC-config hold
  ws_anchor_timeout_q     # F4/FIX-3 FINALIZE anchor-gate timeout
  cal_in_hold             # L4 training-exit rendezvous (calibrator S_HOLD)
)
TARGETS=( pynq-z2-pair-all pynq-z2-pair-flip-all )
WINSCAN_FILTER='NAME =~ *winscan* || NAME =~ */ws_*'

# ----- args --------------------------------------------------------------------
WT=""
WITH_DCP=0
while [ $# -gt 0 ]; do case "$1" in
  --worktree) WT=$2; shift;;
  --with-dcp) WITH_DCP=1;;
  -h|--help)  sed -n '2,32p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (usage: $0 [--worktree DIR] [--with-dcp])"; exit 2;;
esac; shift; done
if [ -z "$WT" ]; then WT="$(cd "$(dirname "$0")/../.." && pwd)"; fi
IMP="$WT/imp/fpga"
GEN="$IMP/gen_v2"
[ -d "$IMP" ] || { echo "FAIL  setup    no build tree at $IMP"; exit 1; }

NFAIL=0; NWARN=0
pass(){ printf 'PASS  (%s) %s\n      %s\n' "$1" "$2" "$3"; }
fail(){ printf 'FAIL  (%s) %s\n      %s\n' "$1" "$2" "$3"; NFAIL=$((NFAIL+1)); }
warn(){ printf 'WARN  (%s) %s\n      %s\n' "$1" "$2" "$3"; NWARN=$((NWARN+1)); }
mtime(){ stat -c %Y "$1" 2>/dev/null || echo 0; }
tstr(){ date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$1"; }

echo "======== verify_build: provenance gate  worktree=$WT  ($(date)) ========"

# ----- (a) V2 banner in the newest package_ip log --------------------------------
PKG_LOG=$(find "$IMP/run" -maxdepth 2 -name 'package_ip*.log' -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$PKG_LOG" ]; then
  fail a "V2 banner in newest package_ip log" "no package_ip*.log under $IMP/run/"
elif LINE=$(grep -F -m1 "$V2_BANNER" "$PKG_LOG"); then
  pass a "V2 banner in newest package_ip log" \
       "$PKG_LOG ($(tstr "$(mtime "$PKG_LOG")")): ${LINE#"${LINE%%[![:space:]]*}"}"
else
  fail a "V2 banner in newest package_ip log" \
       "'$V2_BANNER' NOT in $PKG_LOG — SILENT V1 FALLBACK (TIDELINK_PHY_V2 not in the build env?)"
fi

# ----- (b) gen_v2/Wlink.v V2 defines + E4 reset mask ------------------------------
if [ ! -f "$GEN/Wlink.v" ]; then
  fail b "gen_v2/Wlink.v V2 defines" "missing $GEN/Wlink.v"
else
  B_OK=1; B_EV=""
  for pat in "${WLINK_MUSTS[@]}"; do
    ln=$(grep -nF -m1 "$pat" "$GEN/Wlink.v" | cut -d: -f1)
    if [ -n "$ln" ]; then B_EV="${B_EV}[$pat @L$ln] "
    else B_OK=0; B_EV="${B_EV}[$pat MISSING] "; fi
  done
  if [ $B_OK -eq 1 ]; then pass b "gen_v2/Wlink.v V2 defines + E4 mask" "$B_EV"
  else fail b "gen_v2/Wlink.v V2 defines + E4 mask" "$B_EV"; fi
fi

# ----- (c) autonomy signals present in gen_v2/axi_chiplet_controller.sv -----------
ACC="$GEN/axi_chiplet_controller.sv"
if [ ! -f "$ACC" ]; then
  fail c "autonomy signals in gen_v2/axi_chiplet_controller.sv" "missing $ACC"
else
  C_OK=1; C_EV=""
  for sig in "${AUTONOMY_SIGNALS[@]}"; do
    n=$(grep -c "$sig" "$ACC")
    C_EV="$C_EV$sig=$n "
    [ "$n" -gt 0 ] || C_OK=0
  done
  if [ $C_OK -eq 1 ]; then pass c "autonomy signals in axi_chiplet_controller.sv" "ref counts: $C_EV"
  else fail c "autonomy signals in axi_chiplet_controller.sv" "ref counts: $C_EV(0 = optimised/edited out — STALE IP?)"; fi
fi

# ----- (d) both .bit files: exist, newer than run start, different md5s -----------
# Run start: the farm log names embed the kick-off stamp (package_ip.YYYYMMDD-HHMMSS.log);
# fall back to the log's mtime (package_ip is the first, fast phase of a run).
RUN_START=0
if [ -n "$PKG_LOG" ]; then
  bn=$(basename "$PKG_LOG")
  st=$(echo "$bn" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
  if [ -n "$st" ]; then
    RUN_START=$(date -d "${st:0:4}-${st:4:2}-${st:6:2} ${st:9:2}:${st:11:2}:${st:13:2}" +%s 2>/dev/null || echo 0)
  fi
  [ "$RUN_START" -gt 0 ] || RUN_START=$(mtime "$PKG_LOG")
fi
declare -A BIT_MD5
D_OK=1; D_EV=""
for t in "${TARGETS[@]}"; do
  bit="$IMP/output/$t/tidelink.bit"
  if [ ! -f "$bit" ]; then D_OK=0; D_EV="${D_EV}[$t: tidelink.bit MISSING] "; continue; fi
  bm=$(mtime "$bit")
  BIT_MD5[$t]=$(md5sum "$bit" | cut -d' ' -f1)
  if [ "$RUN_START" -gt 0 ] && [ "$bm" -lt "$RUN_START" ]; then
    D_OK=0; D_EV="${D_EV}[$t: bit $(tstr "$bm") OLDER than run start $(tstr "$RUN_START") — stale/half-finished build] "
  else
    D_EV="${D_EV}[$t: bit $(tstr "$bm") md5=${BIT_MD5[$t]:0:8}] "
  fi
done
if [ "${#BIT_MD5[@]}" -eq "${#TARGETS[@]}" ] && \
   [ "${BIT_MD5[${TARGETS[0]}]}" = "${BIT_MD5[${TARGETS[1]}]}" ]; then
  D_OK=0; D_EV="${D_EV}[md5s IDENTICAL — flip/non-flip halves are the same image] "
fi
if [ $D_OK -eq 1 ]; then pass d "pair .bit files fresh + distinct" "$D_EV"
else fail d "pair .bit files fresh + distinct" "$D_EV"; fi

# ----- (e) WINSCAN_CELLS (winscan FSM survived synthesis) -------------------------
for t in "${TARGETS[@]}"; do
  dcp="$IMP/output/$t/tidelink_design_wrapper_routed.dcp"
  TCL="open_checkpoint $dcp; puts \"WINSCAN_CELLS=[llength [get_cells -hierarchical -quiet -filter {$WINSCAN_FILTER}]]\"; exit"
  if [ $WITH_DCP -eq 1 ] && command -v vivado >/dev/null 2>&1; then
    if [ ! -f "$dcp" ]; then fail e "WINSCAN_CELLS ($t)" "missing $dcp"; continue; fi
    tdir=$(mktemp -d)
    n=$( (cd "$tdir" && echo "$TCL" | vivado -mode tcl -nolog -nojournal 2>/dev/null) \
         | grep -oE 'WINSCAN_CELLS=[0-9]+' | cut -d= -f2 )
    rm -rf "$tdir"
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then
      pass e "WINSCAN_CELLS ($t)" "WINSCAN_CELLS=$n (known-good 555-561 @2026-07-03; >0 required)"
    else
      fail e "WINSCAN_CELLS ($t)" "WINSCAN_CELLS=${n:-query-failed} — winscan FSM optimised out (V2 define not in package_ip?)"
    fi
  else
    echo "INFO  (e) WINSCAN_CELLS ($t): needs Vivado — run by hand (or re-run with --with-dcp):"
    echo "      echo 'open_checkpoint $dcp; puts \"WINSCAN_CELLS=[llength [get_cells -hierarchical -quiet -filter {$WINSCAN_FILTER}]]\"; exit' | vivado -mode tcl -nolog -nojournal | grep WINSCAN_CELLS"
    echo "      REQUIRE the count > 0 (known-good 555-561 @2026-07-03; 0 = optimised out = silent V1 in the IP)"
  fi
done

# ----- (f) stale .bin trap (boards flash the .bin, not the .bit) ------------------
for t in "${TARGETS[@]}"; do
  bit="$IMP/output/$t/tidelink.bit"
  for bin in "$IMP/output/$t/"*.bin; do
    [ -f "$bin" ] || continue
    if [ -f "$bit" ] && [ "$(mtime "$bin")" -lt "$(mtime "$bit")" ]; then
      warn f "stale .bin ($t)" \
        "$(basename "$bin") ($(tstr "$(mtime "$bin")")) OLDER than tidelink.bit ($(tstr "$(mtime "$bit")")) — re-run bit2bin before flashing"
    fi
  done
done

# ----- verdict --------------------------------------------------------------------
echo "-------------------------------------------------------------------"
if [ $NFAIL -eq 0 ]; then
  echo "VERIFY_BUILD: PASS (warnings=$NWARN) — provenance gate clean"
  exit 0
else
  echo "VERIFY_BUILD: FAIL ($NFAIL check(s) failed, warnings=$NWARN) — DO NOT STAGE THIS BUILD"
  exit 1
fi

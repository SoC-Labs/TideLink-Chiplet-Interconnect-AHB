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
#   (d) every target's tidelink.bit exists, is NEWER than the newest run's
#       start, and no two targets share an md5 (identical = one half not rebuilt)
#   (e) V2-SURVIVED-SYNTHESIS: prints the ready-to-run Vivado one-liner per
#       target; with --with-dcp (and vivado on PATH) actually runs it. The
#       required marker is PLATFORM-DEPENDENT — see the (e) block below.
#   (f) WARN on any tidelink.bin OLDER than its tidelink.bit (stale bit2bin
#       trap — boards flash the .bin, not the .bit)
#
# USAGE:  fpga/scripts/verify_build.sh [--worktree DIR] [--with-dcp]
#                                      [--targets "T1 T2 ..."]
#   --worktree DIR  repo root to check (default: this script's repo)
#   --with-dcp      open each routed DCP in Vivado and count winscan cells
#                   (slow, ~minutes per target)
#   --targets "..." space-separated list of targets to verify. Each name is an
#                   OUTPUT DIRECTORY name under imp/fpga/output/, i.e. it must
#                   include any ANCHOR_SUFFIX the build applied (Makefile builds
#                   to output/$(TARGET)$(ANCHOR_SUFFIX), so an EXTREFCLK=1 build
#                   of kr260-pair-nptp lands in kr260-pair-nptp-extref).
#                   May also be given as the TARGETS env var. Two or more
#                   targets are treated as halves of one link and must not share
#                   an md5; a single target skips that cross-check.
#                   DEFAULT (unchanged): the Pynq-Z2 pair, so every existing
#                   invocation behaves exactly as before.
#                   e.g. --targets "kr260-pair-ptp kr260-pair-flip-ptp"
#
# Exit: 0 = all checks PASS (warnings allowed), non-zero otherwise.
# Read-only: never writes inside the worktree (safe alongside a running build).
# =============================================================================
set -u

# ----- parameterized expectations (EXTEND HERE in future loops) ---------------
V2_BANNER='TIDELINK filelist: V2'
WLINK_MUSTS=(
  '`define TIDELINK_PHY_V2'
)
# Lane-mask POR expectation. The 0xE4 (4-lane) default is gated by the
# TD_AUTO_LANE_MASK_E4 env var in fpga/filelist.tcl; =0 builds the 8-lane
# (0xFF) config. Mirror that here so the verifier checks what was ASKED for.
#
# NOTE (2026-07-17): the old expectation list also grepped for
#   "LANE_MASK_RESET = 8'hE4;"
# which was VACUOUS — filelist.tcl only PREPENDS the define to the file body,
# it does not preprocess it, so BOTH `ifdef branches (8'hE4 and 8'hFF) are
# present in the generated text unconditionally and that grep passed either
# way. The `define line is the only load-bearing evidence, so we assert on its
# presence/ABSENCE instead.
LANE_MASK_E4=1
if [ "${TD_AUTO_LANE_MASK_E4:-1}" = "0" ]; then LANE_MASK_E4=0; fi
if [ "$LANE_MASK_E4" = "1" ]; then
  WLINK_MUSTS+=( '`define TD_AUTO_LANE_MASK_E4' )
  WLINK_MUSTNOTS=()
  LANE_MASK_EXPECT="8'hE4 (4 lanes, bytesPerCycle=8)"
else
  WLINK_MUSTNOTS=( '`define TD_AUTO_LANE_MASK_E4' )
  LANE_MASK_EXPECT="8'hFF (8 lanes, bytesPerCycle=16)"
fi
AUTONOMY_SIGNALS=(
  ws_kick_pending_q       # FIX-1 episode-bound winscan kick
  sync_cfg_hold_q         # L3 autonomous SYNC-config hold
  ws_anchor_timeout_q     # F4/FIX-3 FINALIZE anchor-gate timeout
  cal_in_hold             # L4 training-exit rendezvous (calibrator S_HOLD)
)
# Targets to verify = output-dir names under imp/fpga/output/. Overridable via
# the TARGETS env var or --targets; the default is the Z2 pair, so pre-existing
# callers are byte-for-byte unchanged.
TARGETS_DEFAULT='pynq-z2-pair-all pynq-z2-pair-flip-all'
WINSCAN_FILTER='NAME =~ *winscan* || NAME =~ */ws_*'
# IDELAY-INDEPENDENT V2 markers — see the (e) block for why these exist.
# Verified present on the 2026-07-16 routed kr260-pair-{,flip-}ptp DCPs
# (RETIRE=3, SYNCDET=103, REANCHOR=373, IDELAY=0, ~95k cells per die).
V2MARK_FILTER='NAME =~ *sync_detect* || NAME =~ *reanchor* || NAME =~ *autonomy_retire*'
# Presence of ANY IDELAY primitive => this platform sweeps taps => winscan lives.
IDELAY_FILTER='REF_NAME =~ IDELAY*'

# ----- args --------------------------------------------------------------------
WT=""
WITH_DCP=0
TARGETS_STR="${TARGETS:-$TARGETS_DEFAULT}"
usage(){ sed -n '2,/^# =\+$/p' "$0" | sed -n '2,$p'; }
while [ $# -gt 0 ]; do case "$1" in
  --worktree) WT=$2; shift;;
  --with-dcp) WITH_DCP=1;;
  --targets)  TARGETS_STR=$2; shift;;
  -h|--help)  usage; exit 0;;
  *) echo "unknown arg: $1 (usage: $0 [--worktree DIR] [--with-dcp] [--targets \"T1 T2 ...\"])"; exit 2;;
esac; shift; done
# shellcheck disable=SC2206
TARGETS=( $TARGETS_STR )
[ "${#TARGETS[@]}" -ge 1 ] || { echo "FAIL  setup    --targets/TARGETS is empty"; exit 2; }
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
echo "targets: ${TARGETS[*]}"

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

# ----- (b) gen_v2/Wlink.v V2 defines + lane-mask POR ------------------------------
if [ ! -f "$GEN/Wlink.v" ]; then
  fail b "gen_v2/Wlink.v V2 defines" "missing $GEN/Wlink.v"
else
  B_OK=1; B_EV=""
  for pat in "${WLINK_MUSTS[@]}"; do
    ln=$(grep -nF -m1 "$pat" "$GEN/Wlink.v" | cut -d: -f1)
    if [ -n "$ln" ]; then B_EV="${B_EV}[$pat @L$ln] "
    else B_OK=0; B_EV="${B_EV}[$pat MISSING] "; fi
  done
  for pat in ${WLINK_MUSTNOTS+"${WLINK_MUSTNOTS[@]}"}; do
    ln=$(grep -nF -m1 "$pat" "$GEN/Wlink.v" | cut -d: -f1)
    if [ -n "$ln" ]; then B_OK=0; B_EV="${B_EV}[$pat PRESENT@L$ln but must be ABSENT] "
    else B_EV="${B_EV}[$pat correctly absent] "; fi
  done
  B_EV="${B_EV}[expect LANE_MASK_RESET=$LANE_MASK_EXPECT] "
  if [ $B_OK -eq 1 ]; then pass b "gen_v2/Wlink.v V2 defines + lane-mask POR" "$B_EV"
  else fail b "gen_v2/Wlink.v V2 defines + lane-mask POR" "$B_EV"; fi
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
# Distinctness: compare EVERY pair, not just [0] vs [1]. The old hard-indexed
# compare silently checked only the first two entries, so a >2-target list (e.g.
# the kr260 ptp/nptp x straight/flip set) could ship duplicate halves unnoticed.
# With a single target there is nothing to cross-check — skip, don't fail.
if [ "${#TARGETS[@]}" -ge 2 ]; then
  for i in "${!TARGETS[@]}"; do
    for j in "${!TARGETS[@]}"; do
      [ "$i" -lt "$j" ] || continue
      ti=${TARGETS[$i]}; tj=${TARGETS[$j]}
      [ -n "${BIT_MD5[$ti]:-}" ] && [ -n "${BIT_MD5[$tj]:-}" ] || continue
      if [ "${BIT_MD5[$ti]}" = "${BIT_MD5[$tj]}" ]; then
        D_OK=0
        D_EV="${D_EV}[md5s IDENTICAL: $ti == $tj (${BIT_MD5[$ti]:0:8}) — those halves are the same image] "
      fi
    done
  done
fi
if [ $D_OK -eq 1 ]; then pass d "target .bit files fresh + distinct" "$D_EV"
else fail d "target .bit files fresh + distinct" "$D_EV"; fi

# ----- (e) V2 SURVIVED SYNTHESIS — marker is PLATFORM-DEPENDENT --------------------
#
# WHY THIS IS NOT JUST "WINSCAN_CELLS > 0" ANY MORE. DO NOT "SIMPLIFY" IT BACK.
#
# The winscan FSM exists to sweep per-lane IDELAY TAPS. It is therefore only
# instantiated where there ARE IDELAYs. On the Pynq-Z2 (USE_IDELAY defaults to 1)
# it is present, and a count of 0 genuinely means the V2 define never reached the
# packaged IP's OOC synth = silent V1 = dead link. That is the incident this check
# was born from, and on Z2 it still holds exactly as before.
#
# On the KR260 it is the OPPOSITE. HDIO bank 44 physically cannot host an IDELAY
# primitive, so every kr260 target hard-sets `CONFIG.USE_IDELAY {0}` — mandatory,
# not a tuning choice (see fpga/targets/kr260-pair-ptp/tidelink_design.tcl:421).
# With no IDELAYs to sweep, synthesis CORRECTLY prunes the winscan FSM, and
# WINSCAN_CELLS=0 is the EXPECTED, HEALTHY result. Requiring >0 there would fail
# every KR260 build forever — a gate that cries wolf gets switched off, and then
# it is not guarding the Z2 either.
#
# So: assert V2 with markers that DO NOT depend on IDELAY (`*sync_detect*`,
# `*reanchor*`, `*autonomy_retire*` — all V2-only, all IDELAY-independent).
# Measured on the 2026-07-16 routed KR260 pair: RETIRE=3, SYNCDET=103,
# REANCHOR=373, IDELAY=0, ~95k cells/die. A silent-V1 KR260 build has none.
#
# IDELAY-ness is derived FROM THE DCP (count of IDELAY* primitives), not from
# the target's tcl, for two reasons:
#   1. The TARGETS list holds OUTPUT-DIR names, which carry ANCHOR_SUFFIX
#      (kr260-pair-nptp-extref); output-dir -> target-dir is not injective, so a
#      tcl lookup would need fragile suffix-stripping to even find the file.
#   2. The DCP *is* the artefact under gate. Grepping the tcl asks what the build
#      was SUPPOSED to do; counting cells asks what it ACTUALLY did. Every
#      silent-V1 incident so far came from exactly that gap (a define that never
#      reached OOC synth while the config said it had).
#
# Decision rule (fail-safe toward the old behaviour):
#   IDELAY_CELLS > 0  -> IDELAY platform (Z2)     -> require WINSCAN_CELLS > 0
#   IDELAY_CELLS == 0 -> no-IDELAY platform (KR)  -> require V2MARK_CELLS  > 0
#   IDELAY query failed/unparseable               -> fall back to the WINSCAN rule
# The last line matters: if the query breaks we must not silently downgrade a Z2
# build onto the weaker marker path.
E_TCL_FOR(){ # $1 = dcp path
  printf 'open_checkpoint %s; ' "$1"
  printf 'puts "IDELAY_CELLS=[llength [get_cells -hierarchical -quiet -filter {%s}]]"; ' "$IDELAY_FILTER"
  printf 'puts "WINSCAN_CELLS=[llength [get_cells -hierarchical -quiet -filter {%s}]]"; ' "$WINSCAN_FILTER"
  printf 'puts "V2MARK_CELLS=[llength [get_cells -hierarchical -quiet -filter {%s}]]"; ' "$V2MARK_FILTER"
  printf 'exit'
}
for t in "${TARGETS[@]}"; do
  dcp="$IMP/output/$t/tidelink_design_wrapper_routed.dcp"
  TCL=$(E_TCL_FOR "$dcp")
  if [ $WITH_DCP -eq 1 ] && command -v vivado >/dev/null 2>&1; then
    if [ ! -f "$dcp" ]; then fail e "WINSCAN_CELLS ($t)" "missing $dcp"; continue; fi
    tdir=$(mktemp -d)
    out=$( (cd "$tdir" && echo "$TCL" | vivado -mode tcl -nolog -nojournal 2>/dev/null) )
    rm -rf "$tdir"
    n=$(  echo "$out" | grep -oE 'WINSCAN_CELLS=[0-9]+' | cut -d= -f2 )
    nid=$(echo "$out" | grep -oE 'IDELAY_CELLS=[0-9]+'  | cut -d= -f2 )
    nv2=$(echo "$out" | grep -oE 'V2MARK_CELLS=[0-9]+'  | cut -d= -f2 )
    if [ -n "$nid" ] && [ "$nid" -eq 0 ]; then
      # ---- no-IDELAY platform (KR260): winscan is CORRECTLY absent ----
      if [ -n "$nv2" ] && [ "$nv2" -gt 0 ]; then
        pass e "V2 markers ($t)" \
             "IDELAY_CELLS=0 (no-IDELAY platform: winscan pruned by design, WINSCAN_CELLS=${n:-?} is EXPECTED) V2MARK_CELLS=$nv2 (>0 required; known-good ~479 @2026-07-16)"
      else
        fail e "V2 markers ($t)" \
             "IDELAY_CELLS=0 and V2MARK_CELLS=${nv2:-query-failed} — no sync_detect/reanchor/autonomy_retire cells: SILENT V1 in the IP"
      fi
    else
      # ---- IDELAY platform (Z2), or query failed: original rule, unchanged ----
      if [ -n "$n" ] && [ "$n" -gt 0 ]; then
        pass e "WINSCAN_CELLS ($t)" "WINSCAN_CELLS=$n (known-good 555-561 @2026-07-03; >0 required)"
      else
        fail e "WINSCAN_CELLS ($t)" "WINSCAN_CELLS=${n:-query-failed} — winscan FSM optimised out (V2 define not in package_ip?)"
      fi
    fi
  else
    echo "INFO  (e) WINSCAN_CELLS ($t): needs Vivado — run by hand (or re-run with --with-dcp):"
    echo "      echo '$TCL' | vivado -mode tcl -nolog -nojournal | grep -E 'IDELAY_CELLS|WINSCAN_CELLS|V2MARK_CELLS'"
    echo "      IF IDELAY_CELLS>0 (Pynq-Z2): REQUIRE WINSCAN_CELLS>0 (known-good 555-561 @2026-07-03; 0 = optimised out = silent V1 in the IP)"
    echo "      IF IDELAY_CELLS=0 (KR260):   WINSCAN_CELLS=0 is EXPECTED (nothing to sweep) — REQUIRE V2MARK_CELLS>0 instead (known-good ~479 @2026-07-16)"
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

# ----- (g) NO SILENTLY-DROPPED XDC CONSTRAINTS -------------------------------------
# Vivado emits a CRITICAL WARNING (not an error) when a constraint matches nothing or
# is handed an unsupported object type, then carries on and builds a bitstream WITHOUT
# it. That is exactly how the key inter-lane-skew constraint stayed dead for months:
#
#   set_bus_skew -from [get_ports {pad_rx[*]}] ...
#     -> [Constraints 18-612] ... does not contain any object of type(s)
#        '(pin,cell,clock)' ... The constraint will not be applied.
#
# set_bus_skew accepts only (pin,cell,clock); the set_max_delay on the adjacent line
# DOES accept ports, so the two looked symmetric and nobody noticed. Inter-lane RX skew
# was therefore UNBOUNDED in every bitstream — the precise per-lane variance that
# constraint existed to remove, and consistent with the build-to-build autonomy lottery.
#
# A dropped constraint must never be silent again. This is a FAIL, not a warning.
# Match EVERY way Vivado can quietly neuter a constraint, not just one:
#   18-611/18-612  unsupported object type / matched nothing  -> constraint dropped
#   18-402         "'X' is not a valid startpoint"            -> no valid endpoints,
#                  so the constraint applies to NOTHING. This is only a WARNING (not
#                  CRITICAL), and it is EXACTLY how the 2026-07-14 "fix" of the dead
#                  set_bus_skew produced a FALSE GREEN: swapping get_ports for the
#                  IBUF output pins silenced 18-612 but raised 18-402 instead, and an
#                  18-611/612-only check passed a build whose skew constraint was
#                  still dead. A constraint that binds to nothing must FAIL, however
#                  Vivado chooses to phrase it.
#   18-4?? generic "no valid object"/"empty" phrasings
DROP_RE='Constraints 18-61[12]|Constraints 18-402|constraint will not be applied|is not a valid startpoint|is not a valid endpoint|No valid object\(s\) found'
for t in "${TARGETS[@]}"; do
  # ONLY the single NEWEST log for this target. Using the newest N would drag in the
  # PREVIOUS build's log and report its (already-fixed) drops against the current
  # build — a false FAIL. Observed 2026-07-14: head -2 pulled the 07-11 pre-fix farm
  # log alongside the clean 07-14 one and failed a build that was actually correct.
  log=$(ls -t "$IMP"/run/farm/"$t"@*.log \
               "$IMP"/project/"$t"/*.runs/impl_1/runme.log 2>/dev/null | head -1)
  [ -z "$log" ] && { warn "g" "no impl log for $t" "cannot check for dropped constraints"; continue; }
  hits=$(grep -cE "$DROP_RE" "$log" 2>/dev/null)
  if [ "$hits" -gt 0 ]; then
    ev=$(grep -hE "$DROP_RE" "$log" 2>/dev/null | head -1 | cut -c1-140)
    fail "g" "$t: $hits SILENTLY-DROPPED constraint line(s)" "$ev  [$(basename "$log")]"
  else
    nskew=$(grep -cE "set_bus_skew" "$log" 2>/dev/null)
    pass "g" "$t: no dropped XDC constraints" "clean impl log ($(basename "$log")); set_bus_skew refs=$nskew"
  fi
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

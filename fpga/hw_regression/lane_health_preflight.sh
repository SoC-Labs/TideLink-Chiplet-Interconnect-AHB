#!/bin/bash
# =============================================================================
# lane_health_preflight.sh — per-lane RX eye / commit health check for BOTH dies
#
# WHY THIS EXISTS (the blind spot it closes)
# ------------------------------------------------------------------------------
# A per-lane IDELAY eye sweep already lived in td_v2_hwlib.sh:winscan() — but it
# only EVER ran on die_b ($SSH $BOARD_USER@$B_IP, ~line 136). die_a's RX eye had never
# been measured on silicon. The cost of that blind spot:
#
#   die_a pad_rx[7] was remapped to a spare pin (V7) after its primary B19/F20
#   conductor proved bad. On silicon that lane sits at Hamming-6 at ALL 32 IDELAY
#   taps — i.e. ABOVE the tol-5 commit threshold at every sample point, a
#   physically marginal RX conductor. Because nothing ever swept die_a's RX, this
#   silently broke autonomous bring-up ~40% of the time for WEEKS. A one-second
#   commit check (Phase 1) or a ~30s sweep (Phase 2) catches it immediately and
#   names the offending lane.
#
# This script sweeps BOTH dies (the fix), classifies each active lane
# DEAD/MARGINAL/PASS, emits a human table + machine JSON/CSV, and exits non-zero
# so it can gate the regression suite (see td_v2_regress.sh) before minutes are
# sunk into bring-up rolls / the eye + data tests.
#
# PURE SOFTWARE. Touches no RTL. Reuses td_v2_hwlib.sh helpers + register map.
# The dense per-tap reads run as an on-board /dev/mem mmap program (like
# winscan) so we never wedge the PYNQ PS with a storm of one-hop SSH reads.
#
# USAGE (run on the lab host that can SSH the PYNQ pair, e.g. mapstone-dev):
#   ./lane_health_preflight.sh [--quick] [--die a|b|both] [--out <path>]
#                              [--fail-on-marginal] [--tol <n>] [--selftest]
#     --quick             Phase 0+1 only (~2s): config sanity + commit verdict
#     --die a|b|both      which die(s) to sweep in Phase 2 (default both)
#     --out <path>        JSON path (CSV written alongside as *.csv)
#                         default /tmp/lane_health_<timestamp>.json
#     --fail-on-marginal  exit 1 if any active lane is MARGINAL (else warn only)
#     --tol <n>           override the SYNC tolerance used for classification
#                         (default: READ it from 0x44032128[12:8], expect 5)
#     --selftest          run the classifier unit-check with fake values and
#                         exit — no hardware access at all
#   Env: FAIL_ON_MARGINAL=1 same as --fail-on-marginal.
#        Boards/paths come from TD_* (see td_v2_hwlib.sh).
#
# EXIT CODES
#   0  healthy
#   1  a lane is MARGINAL and (--fail-on-marginal | FAIL_ON_MARGINAL=1)
#   2  a lane is DEAD (full) or missing-under-flood (quick) — hard stop
#   3  config sanity failed (wrong build / wrong lane-mask) — Phase 0 abort
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

# ----- extra register map (SoC APB @ 0x44032000 base) ------------------------
R_SYNC_LIVE=0x44032144      # [7:0] SYNC_LANE_LIVE — per-lane currently matching
# These two are read via the on-board mmap sweep at offsets 0x150/0x154; named
# here as the register map (unused as shell vars — the docs are the point).
# shellcheck disable=SC2034
R_CAL_EYE=0x44032150        # RO per-lane calibrator eye: [5:0]best_run [9:6]start_phase [12:10]slip [13]lane_passed
# shellcheck disable=SC2034
R_CAL_SEL=0x44032154        # [2:0] calibrator lane select
# (R_R8, R_SYNCSEEN, R_LANEMASK, R_SYNCTOL, R_DIST, R_DIST_SEL, R_PHASE_NIB,
#  R_PHASE_LSB, GP1_RX, EXP_SLICE come from td_v2_hwlib.sh)

# ----- golden / classification constants -------------------------------------
# CONSOLIDATION 2026-07-19: these four "golden" constants were the LAST place
# that still hardcoded the 4-lane 0xE4 assumption. They now derive from the ONE
# mask mechanism — TD_MASK, defined in td_v2_hwlib.sh (sourced above) and
# defaulting to 0xe4. With the default this composes to EXACTLY the historical
# literals (GOLD_MASK32=0x0000e4e4, GOLD_MASK8=0xe4, GOLD_ACTIVE="2 5 6 7",
# SWEEP_LANES="2,5,6,7"), so the default path is bit-identical. An 8-lane run
# passes TD_MASK=0xff and the phase0 build-expectation ABORTs below then check
# the RIGHT mask instead of failing a correct 8-lane build.
GOLD_MASK32=$TD_LANEMASK32  # 0x44030214 lane mask (rx|tx) — must match
GOLD_MASK8=$(printf '0x%02x' $((TD_MASK)))   # 0x44032128[7:0] SYNC mask
GOLD_SEEN=$GOLD_MASK8      # 0x4403215C[7:0] all active lanes committed
# NOTE (Wave-0 fix #12c): GOLD_SEEN is RETIRED as a comparison reference. The
# commit expectation now derives from the live SYNC mask (EXP_SEEN, set in
# phase0 from the hardware read-back m8). Kept only as documentation of the
# nominal value; no longer used in any pass/fail decision.
GOLD_ACTIVE="$MASK_ACTIVE_LANES"   # NEVER report masked-out lanes
SWEEP_LANES="${MASK_ACTIVE_LANES// /,}"   # Phase 2 sweep order (per-lane independent)
MARGIN_FLOOR=2            # PASS needs min_dist <= TOL-MARGIN_FLOOR
EYE_FLOOR=4              # PASS needs eye_width >= EYE_FLOOR

# ----- CLI defaults ----------------------------------------------------------
QUICK=0
DIE_SEL=both
OUT=""
FAIL_ON_MARGINAL=${FAIL_ON_MARGINAL:-0}
TOL_OVERRIDE=""
SELFTEST=0

while [ $# -gt 0 ]; do case "$1" in
  --quick)            QUICK=1;;
  --die)              DIE_SEL=$2; shift;;
  --out)              OUT=$2; shift;;
  --fail-on-marginal) FAIL_ON_MARGINAL=1;;
  --tol)              TOL_OVERRIDE=$2; shift;;
  --selftest)         SELFTEST=1;;
  -h|--help)          sed -n '2,60p' "$0"; exit 0;;
  *) echo "unknown arg: $1"; exit 3;;
esac; shift; done

TS=$(date +%Y%m%d_%H%M%S)
[ -n "$OUT" ] || OUT="/tmp/lane_health_${TS}.json"
CSV="${OUT%.json}.csv"

case "$DIE_SEL" in
  a)    DIES=(a);;
  b)    DIES=(b);;
  both) DIES=(a b);;
  *) echo "bad --die '$DIE_SEL' (want a|b|both)"; exit 3;;
esac

# =============================================================================
# CLASSIFIER — pure logic, no hardware. Unit-tested by --selftest.
#   DEAD     : min_dist > TOL          OR eye_width == 0
#   MARGINAL : min_dist in {TOL-1,TOL} OR eye_width < EYE_FLOOR
#   PASS     : min_dist <= TOL-MARGIN_FLOOR AND eye_width >= EYE_FLOOR
# (checked in order; the three are exhaustive & disjoint for md<=31, ew>=0)
# =============================================================================
classify(){ # min_dist eye_width tol -> echoes DEAD|MARGINAL|PASS
  local md=$1 ew=$2 tol=$3
  if [ "$md" -gt "$tol" ] || [ "$ew" -eq 0 ]; then echo DEAD; return; fi
  if [ "$md" -le $((tol - MARGIN_FLOOR)) ] && [ "$ew" -ge "$EYE_FLOOR" ]; then echo PASS; return; fi
  echo MARGINAL   # min_dist in {TOL-1,TOL}, or eye_width < EYE_FLOOR
}

selftest(){
  echo "== classifier self-test (injected fake register values — NO hardware) =="
  local fails=0
  chk(){ # md eye tol expect
    local got; got=$(classify "$1" "$2" "$3")
    if [ "$got" = "$4" ]; then printf "  ok   md=%-2s eye=%-2s tol=%s -> %-8s\n" "$1" "$2" "$3" "$got"
    else printf "  FAIL md=%-2s eye=%-2s tol=%s -> %-8s (want %s)\n" "$1" "$2" "$3" "$got" "$4"; fails=$((fails + 1)); fi
  }
  echo "  -- the real die_a lane-7 defect: Hamming-6 at every tap, TOL=5 --"
  chk 6 0  5 DEAD        # min_dist=6 > TOL=5, eye 0 -> DEAD  (our lane 7)
  chk 6 10 5 DEAD        # dist>TOL even with a wide count -> DEAD
  chk 3 0  5 DEAD        # eye_width 0 -> DEAD regardless of dist
  echo "  -- marginal band --"
  chk 5 10 5 MARGINAL    # min_dist == TOL
  chk 4 10 5 MARGINAL    # min_dist == TOL-1
  chk 3 3  5 MARGINAL    # eye_width < EYE_FLOOR
  echo "  -- healthy --"
  chk 3 4  5 PASS        # min_dist <= TOL-2 AND eye >= 4
  chk 0 32 5 PASS        # perfect
  chk 2 16 5 PASS
  echo "  -- TOL override (tol=4) --"
  chk 5 10 4 DEAD        # dist>tol
  chk 4 10 4 MARGINAL    # dist==tol
  chk 3 10 4 MARGINAL    # dist==tol-1
  chk 2 10 4 PASS        # dist<=tol-2 AND eye>=4
  echo "  --- $([ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED") ---"
  return "$fails"
}

# --selftest short-circuits before any board access
if [ "$SELFTEST" = 1 ]; then selftest; exit $?; fi

# ----- per-die tl39 read/write shims (reuse a()/b() from hwlib) --------------
die_ip(){ case "$1" in a) echo "$A_IP";; b) echo "$B_IP";; esac; }
rd_die(){ case "$1" in a) a rd "$2";; b) b rd "$2";; esac; }
wr_die(){ case "$1" in a) a wr "$2" "$3" >/dev/null;; b) b wr "$2" "$3" >/dev/null;; esac; }

# =============================================================================
# On-board sweep program (mmap /dev/mem). Mirrors winscan()'s settap/dist but
# ALSO records eye_width, the calibrator per-lane eye, and the raw RX slice, and
# runs on WHICHEVER die we point it at (die_a included — that is the fix).
# Emits: "LANE <L> <min_dist> <best_tap> <eye_width> <lane_passed> <best_run> <rx_slice>"
# =============================================================================
sweep_py(){ # tol lanes_csv
  local tol=$1 lanes=$2
  cat <<PYEOF
import mmap,struct,os,time,ctypes
P=4096;fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
bb=0x44032000&~(P-1);o=0x44032000-bb
m=mmap.mmap(fd,((0x400+o+P-1)//P)*P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=bb)
# SoC Labs 2026-07-09: rd/wr MUST be single aligned 32-bit bus accesses.
# struct.pack_into/unpack_from did NOT compile to one access on this target
# (measured: 5 AHB beats per logical poke) -- the "TX 5x over-advance phantom".
# Here it is a MEASUREMENT hazard: this preflight loops rd(0x1AC)/rd(0x150) and
# writes W1x taps per lane, so a 5x fan-out perturbs the eye it is measuring.
# ctypes.c_uint32.from_buffer(m,o) is exactly one aligned load/store. (see tl39.py)
def _u32(off):return ctypes.c_uint32.from_buffer(m,o+off)
def rd(x):return _u32(x).value
def wr(x,v):_u32(x).value=v&0xffffffff
import signal
# FAULT-TOLERANT SWEEP (2026-07-10): the SYNC-dist read path (write 0x1B0 select,
# read 0x1AC) and the fine-tap write 0x1B4 are winscan-FSM-owned and BUS-ERROR on
# some builds — killing the whole sweep so it yields "lanes": {}. Survive each
# access, probe once at startup, and DEGRADE GRACEFULLY:
#   0x1AC usable  -> real SYNC Hamming distance (the metric we want).
#   0x1AC faults  -> proxy: the calibrator per-lane eye (0x150 via 0x154, a
#                    DIFFERENT region); dist unavailable, eye_width from cal pass.
#   0x1B4 faults  -> coarse taps only (0x118 nibble): 16 even taps, half res.
# A MODE line reports which path each die used so the output is never a silent lie.
class BusErr(Exception):pass
signal.signal(signal.SIGBUS, lambda s,f:(_ for _ in ()).throw(BusErr()))
def try_wr(off,v):
 try: wr(off,v); return True
 except BusErr: return False
def try_rd(off):
 try: return rd(off)
 except BusErr: return None
# --- probe register usability once (run DISARMED: a surviving fault is structural) ---
# HARD-DISABLED 2026-07-10: 0x1AC/0x1B0/0x1B4 do NOT bus-error — they HARD-STALL
# the CPU thread on an uninterruptible hung AXI read (proven: RC=124 twice, only
# an external SIGKILL stops it; no in-process SIGBUS/SIGALRM handler helps). So we
# NEVER probe or touch them. Eye must come from the calibrator path (0x150/0x154,
# Region 10), and only AFTER the calibrator has locked (a bare deploy + force-SYNC
# does NOT lock the RX: sync_seen low byte reads 0x00). See memory
# project_first_valid_autonomy_measurement_2026_07_10.
LSB_OK=False   # never touch 0x1B4
DIST_OK=False  # never touch 0x1B0/0x1AC — they hard-stall the PS
NTAPS = 32 if LSB_OK else 16
print("MODE dist=%s fine_tap=%s ntaps=%d"%("0x1AC" if DIST_OK else "cal_proxy(0x150)", "on" if LSB_OK else "coarse_only", NTAPS),flush=True)
def settap(L,t):
 tap = t if LSB_OK else (t*2)          # coarse-only: even taps 0,2,..30
 n=(tap>>1)&0xf;lb=tap&1
 c=rd(0x118);c&=~(0xf<<(4*L));c|=n<<(4*L);wr(0x118,c)
 if LSB_OK:
  c=try_rd(0x1B4)
  if c is not None: c&=~(1<<L);c|=lb<<L;try_wr(0x1B4,c)
def cal_eye(L):                         # proxy: (lane_passed, bit_err) at current tap
 if try_wr(0x154,L) is False: return (0,63)
 time.sleep(0.003);cal=try_rd(0x150)
 if cal is None: return (0,63)
 return ((cal>>13)&1, cal&0x3f)
def measure(L):
 if DIST_OK:
  try_wr(0x1B0,L);time.sleep(0.003)
  ds=[try_rd(0x1AC) for _ in range(5)]; ds=[d&0x1f for d in ds if d is not None]
  return min(ds) if ds else 99
 lp,br=cal_eye(L)                        # proxy distance: 0 if passing, else ~br
 return 0 if lp else max(1,br>>1)
def slice_of(L):
 reg={0:0x12C,1:0x12C,2:0x130,3:0x130,4:0x134,5:0x134,6:0x138,7:0x138}[L]
 sh=0 if (L%2)==0 else 16
 v=try_rd(reg); return (v>>sh)&0xffff if v is not None else 0
TOL=$tol
for L in [$lanes]:
 best=(99,0);eye=0
 for t in range(NTAPS):
  settap(L,t);time.sleep(0.05)
  d=measure(L)
  if d<=TOL:eye+=1
  if d<best[0]:best=(d,t)
  time.sleep(0.008)
 settap(L,best[1])
 lp,br=cal_eye(L)
 print("LANE %d %d %d %d %d %d 0x%04X"%(L,best[0],best[1],eye,lp,br,slice_of(L)),flush=True)
print("SWEEP_DONE",flush=True)
PYEOF
}
sweep_die(){ # ip tol lanes_csv -> prints LANE lines + SWEEP_DONE (stdout); traceback (stderr)
  local ip=$1 tol=$2 lanes=$3 py b64
  py=$(sweep_py "$tol" "$lanes")
  b64=$(printf '%s' "$py" | base64 -w0)
  # Three output-integrity fixes for the "did not report SWEEP_DONE on BOTH dies"
  # blind spot (the failure was in OUTPUT HANDLING, not the link):
  #   python3 -u  : unbuffered stdout. Over the ssh pipe python block-buffers
  #                 stdout; if the program is killed before a normal exit the
  #                 buffered LANE lines + SWEEP_DONE are lost wholesale — which
  #                 looks exactly like "no SWEEP_DONE". -u (belt: flush=True in
  #                 the program) makes each line land immediately so a partial
  #                 sweep still yields the lanes it did measure.
  #   sudo -S -p '': read the password from stdin but emit an EMPTY prompt, so
  #                 sudo's stderr does not add noise now that stderr is shown.
  #   NO 2>/dev/null: the old redirect SWALLOWED any python traceback (e.g.
  #                 /dev/mem EACCES, a bad register offset) — an identical-on-
  #                 both-dies PROGRAM error was thus invisible and misread as a
  #                 "link/PS issue". stderr now flows to the console; stdout
  #                 (the LANE lines) is still captured clean by the caller's $().
  $SSH "$BOARD_USER@$ip" "echo $b64 | base64 -d > /tmp/td_lhp.py && echo ${TD_BOARD_PW:-xilinx}|sudo -S -p '' python3 -u /tmp/td_lhp.py"
}

# ----- collected state -------------------------------------------------------
# EXP_SEEN[d] = per-die EXPECTED committed-lane vector. Wave-0 fix #12c:
# de-circularization — this is DERIVED from the live SYNC mask read back from
# hardware (m8) in phase0, NOT from the standalone GOLD_SEEN constant. Because
# GOLD_SEEN was hardcoded == GOLD_MASK8, comparing seen against it validated its
# own premise and could never fail when the mask itself was wrong. Deriving the
# commit expectation from the live mask lets the preflight FAIL when a lane the
# mask says is active never commits.
declare -A EFF_TOL SEEN_VEC LIVE_VEC MISSING EXP_SEEN
ROWS=()   # "die lane min_dist best_tap eye_width margin seen lane_passed best_run rx_slice class"

# =============================================================================
# PHASE 0 — config sanity (both dies, <1s). Kills wrong-build / wrong-mask fast.
# =============================================================================
phase0(){
  local d lm st tol m8 bad=0
  echo "== PHASE 0: config sanity =="
  for d in a b; do
    lm=$(( $(rd_die "$d" "$R_LANEMASK") ))
    st=$(( $(rd_die "$d" "$R_SYNCTOL") ))
    tol=$(( (st >> 8) & 0x1f )); m8=$(( st & 0xff ))
    printf "  [cfg] die_%s lanemask=0x%08x  sync_tol_reg=0x%08x -> mask=0x%02x TOL=%d\n" "$d" "$lm" "$st" "$m8" "$tol"
    if [ "$lm" -ne $((GOLD_MASK32)) ]; then
      printf "  ABORT: die_%s lane mask 0x%08x != golden 0x%08x (wrong build / wrong mask?)\n" "$d" "$lm" $((GOLD_MASK32)); bad=1; fi
    if [ "$m8" -ne $((GOLD_MASK8)) ]; then
      printf "  ABORT: die_%s SYNC mask 0x%02x != golden 0x%02x\n" "$d" "$m8" $((GOLD_MASK8)); bad=1; fi
    # Wave-0 fix #12c: the COMMIT expectation derives from the LIVE mask (m8),
    # not the hardcoded GOLD_SEEN. The ABORT above is the (legitimate) build
    # sanity check; here we record "all active lanes committed" == the mask HW
    # actually reports, so a missing active lane is detectable downstream.
    EXP_SEEN[$d]=$m8
    # effective TOL for classification: CLI override wins, else the read value
    if [ -n "$TOL_OVERRIDE" ]; then EFF_TOL[$d]=$TOL_OVERRIDE
    else
      EFF_TOL[$d]=$tol
      if [ "$tol" -lt 1 ] || [ "$tol" -gt 15 ]; then
        printf "  ABORT: die_%s TOL=%d is implausible (expect ~5) — pass --tol to override\n" "$d" "$tol"; bad=1; fi
    fi
  done
  [ "$bad" = 0 ]
}

# =============================================================================
# PHASE 1 — one-shot commit verdict (both dies, ~1s, NO sweep). Guarantee the
# peer beacon by flooding SYNC on BOTH dies, clear stale observation, then read
# the COMMITTED anchor vector. A set bit in `missing` = an active lane that never
# commits even with the beacon present ⇒ suspect.
# =============================================================================
phase1(){
  local d
  echo "== PHASE 1: commit verdict (R8=0x1C flood on both dies) =="
  wr_die a "$R_R8" 0x1C; wr_die b "$R_R8" 0x1C     # both flood -> peer beacon guaranteed
  sleep 0.6
  for d in a b; do                                  # pulse obs_clr (bit5 W1P): R8|0x20 then R8
    wr_die "$d" "$R_R8" 0x3C; wr_die "$d" "$R_R8" 0x1C
  done
  sleep 0.4
  for d in a b; do
    local seen live miss
    seen=$(( $(rd_die "$d" "$R_SYNCSEEN") & 0xff ))
    live=$(( $(rd_die "$d" "$R_SYNC_LIVE") & 0xff ))
    # Wave-0 fix #12c: expected-commit derives from the live mask (EXP_SEEN,
    # set in phase0 from m8), not the hardcoded GOLD_MASK8 constant.
    local exp=${EXP_SEEN[$d]:-$((GOLD_MASK8))}
    miss=$(( exp & ~seen & 0xff ))
    SEEN_VEC[$d]=$seen; LIVE_VEC[$d]=$live; MISSING[$d]=$miss
    printf "  [commit] die_%s sync_seen=0x%02x live=0x%02x  missing=0x%02x %s\n" \
      "$d" "$seen" "$live" "$miss" "$([ "$miss" = 0 ] && echo "(all active lanes commit)" || echo "<-- lane(s) never commit")"
  done
}

# =============================================================================
# PHASE 2 — per-lane eye sweep on BOTH selected dies (the fix). ~30s/die.
# =============================================================================
phase2(){
  local d
  echo "== PHASE 2: per-lane eye sweep (both dies) =="
  for d in "${DIES[@]}"; do
    local tol=${EFF_TOL[$d]} out
    echo "  [sweep] die_${d}: lanes {${GOLD_ACTIVE// /,}} x 32 IDELAY taps (min-of-5 reads/tap)..."
    out=$(sweep_die "$(die_ip "$d")" "$tol" "$SWEEP_LANES")
    if ! printf '%s\n' "$out" | grep -q SWEEP_DONE; then
      echo "  WARN: die_${d} sweep did not report SWEEP_DONE — results may be partial."
      echo "        (any python traceback printed on stderr above; raw sweep stdout follows)"
      printf '%s\n' "$out" | sed 's/^/          | /'
    fi
    local tag L md bt ew lp br sl
    while read -r tag L md bt ew lp br sl; do
      [ "$tag" = LANE ] || continue
      local margin cls seenbit
      margin=$(( tol - md ))
      cls=$(classify "$md" "$ew" "$tol")
      seenbit=$(( ( ${SEEN_VEC[$d]:-0} >> L ) & 1 ))
      ROWS+=("$d $L $md $bt $ew $margin $seenbit $lp $br $sl $cls")
      printf "    lane %s: min_dist=%s best_tap=%s eye_width=%s margin=%s seen=%s lane_passed=%s -> %s\n" \
        "$L" "$md" "$bt" "$ew" "$margin" "$seenbit" "$lp" "$cls"
    done < <(printf '%s\n' "$out")
  done
}

# =============================================================================
# PHASE 3 — restore R8=0x14 (idle-gated) on both dies so reanchored can latch,
# then report (human table + JSON/CSV + verdict + disambiguation).
# =============================================================================
phase3_restore(){
  echo "== PHASE 3: restore idle-gated R8=0x14 on both dies =="
  wr_die a "$R_R8" 0x14; wr_die b "$R_R8" 0x14
}

# ----- interpretation / disambiguation lines ---------------------------------
# row helpers (operate on the ROWS array)
row_field(){ # die lane field-index(1based within "die lane md bt ew margin seen lp br sl cls") -> value or empty
  local d=$1 L=$2 idx=$3 r
  for r in "${ROWS[@]}"; do
    set -- $r
    if [ "$1" = "$d" ] && [ "$2" = "$L" ]; then eval "echo \${$idx}"; return; fi
  done
}
lane_class(){ row_field "$1" "$2" 11; }
lane_eye(){   row_field "$1" "$2" 5; }
lane_slice(){ row_field "$1" "$2" 10; }

disambiguation(){
  [ ${#ROWS[@]} -gt 0 ] || return 0
  echo "-- interpretation --"
  local d L
  # (1) ALL active lanes dead/absent on a die => peer beacon or RX clock dead
  for d in "${DIES[@]}"; do
    local nbad=0
    for L in $GOLD_ACTIVE; do
      local c; c=$(lane_class "$d" "$L")
      local sb=$(( ( ${SEEN_VEC[$d]:-0} >> L ) & 1 ))
      { [ "$c" = DEAD ] || [ "$sb" = 0 ]; } && nbad=$((nbad + 1))
    done
    [ "$nbad" = 4 ] && echo "  [interp] die_${d}: ALL active lanes high/absent => peer beacon or RX clock dead (not a single conductor)"
  done
  # (2) same lane fails on BOTH dies => config/SYNC_WORD/mask problem
  if [ ${#DIES[@]} = 2 ]; then
    for L in $GOLD_ACTIVE; do
      local ca cb; ca=$(lane_class a "$L"); cb=$(lane_class b "$L")
      if { [ "$ca" = DEAD ] || [ "$ca" = MARGINAL ]; } && { [ "$cb" = DEAD ] || [ "$cb" = MARGINAL ]; }; then
        echo "  [interp] lane ${L} fails on BOTH dies => config/SYNC_WORD/mask problem (not a conductor)"
        local sa sb exp; sa=$(lane_slice a "$L"); sb=$(lane_slice b "$L"); exp=${EXP_SLICE[$L]:-?}
        echo "           cross-check rx_slice: die_a=$sa die_b=$sb  vs golden EXP_SLICE[$L]=$exp"
      fi
    done
  fi
  # (3) ONE lane dead at every tap on ONE die, peer same-lane healthy => conductor
  for d in "${DIES[@]}"; do
    local other; [ "$d" = a ] && other=b || other=a
    for L in $GOLD_ACTIVE; do
      local c e; c=$(lane_class "$d" "$L"); e=$(lane_eye "$d" "$L")
      if [ "$c" = DEAD ] && [ "${e:-1}" = 0 ]; then
        local co; co=$(lane_class "$other" "$L")
        if [ ${#DIES[@]} = 2 ] && [ "$co" = PASS ]; then
          echo "  [interp] die_${d} lane ${L} DEAD at every tap while die_${other} lane ${L} is healthy => physical single-lane RX conductor defect (e.g. die_a pad_rx[7]->V7 remap)"
        elif [ ${#DIES[@]} != 2 ]; then
          echo "  [interp] die_${d} lane ${L} DEAD at every tap => likely a physical single-lane RX conductor defect (sweep the peer to confirm)"
        fi
      fi
    done
  done
}

# ----- verdict + exit code ---------------------------------------------------
VERDICT=""
RC=0
compute_verdict(){
  local dead_msg="" marg_msg="" r d L md ew margin cls tol seen exp
  if [ ${#ROWS[@]} -gt 0 ]; then
    for r in "${ROWS[@]}"; do
      set -- $r; d=$1; L=$2; md=$3; ew=$5; cls=${11}
      tol=${EFF_TOL[$d]}; seen=${SEEN_VEC[$d]:-0}
      # Wave-0 fix #12c: compare committed vector against the live-mask-derived
      # expectation (EXP_SEEN), not the hardcoded GOLD_SEEN constant.
      exp=${EXP_SEEN[$d]:-$((GOLD_MASK8))}
      if [ "$cls" = DEAD ]; then
        [ -z "$dead_msg" ] && dead_msg="die_${d} lane ${L} DEAD (min_dist=${md} > TOL=${tol}$([ "$ew" = 0 ] && echo " at all 32 taps"); sync_seen 0x$(printf %02x "$seen") $([ "$seen" = "$exp" ] && echo "== live mask 0x$(printf %02x "$exp")" || echo "!= live mask 0x$(printf %02x "$exp")"))"
      elif [ "$cls" = MARGINAL ]; then
        [ -z "$marg_msg" ] && marg_msg="die_${d} lane ${L} MARGINAL (min_dist=${md}, eye_width=${ew}, TOL=${tol})"
      fi
    done
  else
    # quick mode: verdict from Phase-1 missing bits
    for d in a b; do
      local miss=${MISSING[$d]:-0}
      [ "$miss" = 0 ] && continue
      # Wave-0 fix #12c: 'missing' derives from the live mask (EXP_SEEN), so the
      # reference we cite is the live mask, not a hardcoded golden constant.
      exp=${EXP_SEEN[$d]:-$((GOLD_MASK8))}
      for L in $GOLD_ACTIVE; do
        if [ $(( (miss >> L) & 1 )) = 1 ] && [ -z "$dead_msg" ]; then
          dead_msg="die_${d} lane ${L} SUSPECT (never commits under beacon flood; missing=0x$(printf %02x "$miss") vs live mask 0x$(printf %02x "$exp")) — run full preflight to confirm DEAD"
        fi
      done
    done
  fi
  if [ -n "$dead_msg" ]; then VERDICT="VERDICT: $dead_msg"; RC=2
  elif [ -n "$marg_msg" ]; then VERDICT="VERDICT: $marg_msg"; RC=$([ "$FAIL_ON_MARGINAL" = 1 ] && echo 1 || echo 0)
  else VERDICT="VERDICT: all active lanes {${GOLD_ACTIVE// /,}} healthy on die(s) ${DIES[*]}"; RC=0; fi
}

# ----- report: human table -----------------------------------------------------
report_table(){
  echo "========================================================================"
  echo "  LANE HEALTH REPORT  ($TS)   golden active lanes = {${GOLD_ACTIVE// /,}}"
  local d
  for d in a b; do
    [ -n "${SEEN_VEC[$d]:-}" ] || continue
    printf "  die_%s: sync_seen=0x%02x live=0x%02x missing=0x%02x  TOL=%s\n" \
      "$d" "${SEEN_VEC[$d]}" "${LIVE_VEC[$d]}" "${MISSING[$d]}" "${EFF_TOL[$d]:-?}"
  done
  if [ ${#ROWS[@]} -gt 0 ]; then
    printf "  %-4s %-4s %-9s %-9s %-10s %-7s %-5s %-12s %-9s\n" \
      die lane min_dist best_tap eye_width margin seen lane_passed class
    printf "  %s\n" "----------------------------------------------------------------------"
    local r
    for r in "${ROWS[@]}"; do
      set -- $r
      printf "  %-4s %-4s %-9s %-9s %-10s %-7s %-5s %-12s %-9s\n" \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${11}"
    done
  else
    echo "  (quick mode: Phase 0+1 only — no eye sweep; verdict from commit vector)"
  fi
  echo "========================================================================"
}

# ----- report: JSON + CSV ------------------------------------------------------
write_machine(){
  local rowsfile; rowsfile=$(mktemp)
  if [ ${#ROWS[@]} -gt 0 ]; then printf '%s\n' "${ROWS[@]}" > "$rowsfile"; fi
  # CSV
  {
    echo "die,lane,min_dist,best_tap,eye_width,margin,seen,lane_passed,best_run,rx_slice,class"
    if [ ${#ROWS[@]} -gt 0 ]; then printf '%s\n' "${ROWS[@]}" | sed 's/ /,/g'; fi
  } > "$CSV"
  # JSON (built by python to stay well-formed; rows via file, metadata via env)
  LHP_TS="$TS" LHP_MODE="$([ "$QUICK" = 1 ] && echo quick || echo full)" \
  LHP_LANEMASK="$(printf 0x%08x $((GOLD_MASK32)))" \
  LHP_DIES="${DIES[*]}" LHP_VERDICT="$VERDICT" LHP_RC="$RC" \
  LHP_TOL_a="${EFF_TOL[a]:-0}" LHP_TOL_b="${EFF_TOL[b]:-0}" \
  LHP_SEEN_a="$(printf 0x%02x "$(( ${SEEN_VEC[a]:-0} ))")" LHP_SEEN_b="$(printf 0x%02x "$(( ${SEEN_VEC[b]:-0} ))")" \
  LHP_LIVE_a="$(printf 0x%02x "$(( ${LIVE_VEC[a]:-0} ))")" LHP_LIVE_b="$(printf 0x%02x "$(( ${LIVE_VEC[b]:-0} ))")" \
  LHP_MISS_a="$(printf 0x%02x "$(( ${MISSING[a]:-0} ))")" LHP_MISS_b="$(printf 0x%02x "$(( ${MISSING[b]:-0} ))")" \
  python3 - "$OUT" "$rowsfile" <<'PYJSON'
import sys,os,json
jpath=sys.argv[1]
rows=[l.split() for l in open(sys.argv[2])] if os.path.getsize(sys.argv[2]) else []
dies={}
for d in os.environ.get("LHP_DIES","").split():
    dies[d]={"sync_seen":os.environ.get("LHP_SEEN_"+d,""),
             "live":os.environ.get("LHP_LIVE_"+d,""),
             "missing":os.environ.get("LHP_MISS_"+d,""),
             "tol":int(os.environ.get("LHP_TOL_"+d,"0")),
             "lanes":{}}
for r in rows:
    d,lane,md,bt,ew,margin,seen,lp,br,sl,cls=r
    dies.setdefault(d,{"lanes":{}})
    dies[d].setdefault("lanes",{})
    dies[d]["lanes"][lane]={"min_dist":int(md),"best_tap":int(bt),"eye_width":int(ew),
        "margin":int(margin),"seen":int(seen),"lane_passed":int(lp),"best_run":int(br),
        "rx_slice":sl,"class":cls}
obj={"timestamp":os.environ.get("LHP_TS",""),
     "mode":os.environ.get("LHP_MODE","full"),
     "lane_mask":os.environ.get("LHP_LANEMASK",""),
     "golden_active_lanes":[2,5,6,7],
     "dies":dies,
     "verdict":os.environ.get("LHP_VERDICT",""),
     "exit_code":int(os.environ.get("LHP_RC","0"))}
json.dump(obj,open(jpath,"w"),indent=2)
print("  wrote JSON: "+jpath)
PYJSON
  echo "  wrote CSV:  $CSV"
  rm -f "$rowsfile"
}

# =============================================================================
# MAIN
# =============================================================================
echo "======== TideLink lane-health preflight ($(date)) ========"
echo "  die_a=$A_IP  die_b=$B_IP  mode=$([ "$QUICK" = 1 ] && echo quick || echo full)  dies=${DIES[*]}  out=$OUT"

boards_up || { echo "### a board is unreachable ($A_IP / $B_IP) — power-cycle?"; exit 3; }

phase0 || { echo "### PHASE 0 FAILED — config sanity"; exit 3; }
phase1

if [ "$QUICK" = 1 ]; then
  phase3_restore                 # we flooded R8 in phase1; restore idle-gated
  compute_verdict
  report_table
  write_machine
  echo "$VERDICT"
  exit "$RC"
fi

phase2
phase3_restore
compute_verdict
report_table
write_machine
disambiguation
echo "$VERDICT"
exit "$RC"

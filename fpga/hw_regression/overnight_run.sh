#!/bin/bash
# =============================================================================
# overnight_run.sh — the unattended chain: GATE -> BUILD -> VERIFY -> STAGE -> RUN
#
# Runs on the dev host. The silicon phase is executed ON mapstone-dev, because the
# board management IPs are only reachable from there (and fpgahub + sshpass live
# there too).
#
# Every step is fail-closed. In particular:
#   * a red sim_gate NEVER reaches a build (project policy)
#   * a build whose PACKAGED IP does not contain the fix NEVER reaches a board
#     (the `package_ip` stale-IP trap has silently shipped un-fixed RTL before:
#      the .bit is fresh, the IP inside it is old, and the silicon "refutes" a
#      fix that was never in the bitstream)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCR=${SCR:-/tmp}
STAGE=${STAGE:-/tmp/td_iter5}
LOG="$ROOT/overnight_run.log"
say(){ echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }
die(){ say "ABORT: $*"; exit 1; }

# ---------------- 1. wait for the gate, and demand it be GREEN ----------------
say "waiting for iter-5 sim_gate"
while [ ! -f "$SCR/iter5_gate.done" ]; do sleep 30; done
tot=$(ls "$ROOT"/imp/sim_gate/*.status 2>/dev/null | wc -l)
pass=$(grep -l PASS "$ROOT"/imp/sim_gate/*.status 2>/dev/null | wc -l)
say "sim_gate: $pass/$tot PASS"
cat "$ROOT"/imp/sim_gate/*.status 2>/dev/null | sort | tee -a "$LOG"
[ "$tot" -ge 10 ] || die "expected 10 suites, saw $tot"
[ "$pass" -eq "$tot" ] || die "sim_gate RED ($pass/$tot). No build, no deploy."

# ---------------- 2. build both targets ---------------------------------------
# SKIP_BUILD=1 resumes an already-built tree. The integrity check in step 3 is
# NOT skipped -- it is what proves the bitstreams on disk contain the fix, and a
# resume is exactly when a stale tree would slip through.
cd "$ROOT" || die "no root"
if [ "${SKIP_BUILD:-0}" = 1 ]; then
  say "SKIP_BUILD=1 — reusing the bitstreams already on disk (integrity still enforced)"
else
  say "building iter-5 (TIDELINK_PHY_V2=1 TD_AUTO_LANE_MASK_E4=1)"
  export TIDELINK_PHY_V2=1 TD_AUTO_LANE_MASK_E4=1
  ./fpga/scripts/build_farm.sh pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936 \
     >>"$ROOT/farm_build_iter5.log" 2>&1 || die "build_farm failed (see farm_build_iter5.log)"
  say "build finished"
fi

# ---------------- 3. BUILD INTEGRITY: is the fix actually IN the IP? ----------
# The bitstream being newer than the RTL proves nothing -- package_ip can ship a
# stale IP. Check the packaged source directly, and check the bitstream is newer
# than the packaged source.
PKG=$(find "$ROOT/imp" -path "*tidelink_ip/src*" -name tidelink_top.sv | head -1)
[ -n "$PKG" ] || die "no packaged tidelink_top.sv found -- package_ip did not run"
grep -q "ext_lock_q"       "$PKG" || die "PACKAGED IP LACKS the fc_cfg preempt fix (ext_lock_q). STALE IP."
grep -q "EXT_STALL_LIMIT"  "$PKG" || die "PACKAGED IP LACKS the bounded stall. STALE IP."
say "packaged IP contains the preempt fix: OK ($PKG)"

for t in pynq-z2-pair-all pynq-z2-pair-flip-all; do
  BIT="$ROOT/imp/fpga/output/$t/tidelink.bit"
  [ -f "$BIT" ] || die "$t: no tidelink.bit"
  [ "$BIT" -nt "$PKG" ] || die "$t: bitstream is OLDER than the packaged IP -> stale build"
done
say "both bitstreams are newer than the packaged IP: OK"

# ---------------- 4. stage to mapstone-dev ------------------------------------
say "staging to mapstone-dev:$STAGE"
ssh mapstone-dev "mkdir -p $STAGE" || die "cannot mkdir $STAGE"
# ALWAYS regenerate the .bin from the freshly built .bit. NEVER reuse one found
# on disk: the flip target carried a `tidelink.bit.bin` from Jun 28 next to a
# Jul 10 `.bit`. Preferring it would have deployed a two-week-old bitstream to
# die_b against a fresh die_a -- a silently mixed pair, and every conclusion from
# it worthless. Regenerate, then assert the .bin is newer than the .bit.
stage_one(){ # $1=target dir  $2=dest basename
  # NOTE: separate `local` statements. Bash expands every word on a `local` line
  # BEFORE performing any assignment, so `local d=... bit="$d/x"` leaves $d unbound
  # -- fatal under `set -u`, and invisible if stderr is redirected away.
  local d bit bin
  d="$ROOT/imp/fpga/output/$1"
  bit="$d/tidelink.bit"
  bin="$d/tidelink.bin"
  [ -f "$bit" ] || die "$1: no tidelink.bit"
  rm -f "$bin" "$d/tidelink.bit.bin"          # kill any stale artefact outright
  python3 "$ROOT/fpga/scripts/bit2bin.py" "$bit" "$bin" >>"$LOG" 2>&1 \
    || die "$1: bit2bin failed"
  [ -s "$bin" ] || die "$1: bit2bin produced an empty .bin"
  [ "$bin" -nt "$bit" ] || [ "$bin" -ef "$bit" ] || die "$1: regenerated .bin is not newer than .bit"
  say "  $1: .bin regenerated from $(date -r "$bit" '+%b%d %H:%M') bitstream ($(stat -c%s "$bin") bytes)"
  scp -q "$bin"            "mapstone-dev:$STAGE/$2.bin" || die "scp $2.bin"
  scp -q "$d/tidelink.hwh" "mapstone-dev:$STAGE/$2.hwh" || die "scp $2.hwh"; }
stage_one pynq-z2-pair-all      tidelink
stage_one pynq-z2-pair-flip-all tidelink-flip
scp -q "$ROOT"/fpga/hw_regression/{td_v2_hwlib.sh,zeropoke_soak.sh,overnight_autonomy.sh} \
       "mapstone-dev:$STAGE/" || die "scp harness"
ssh mapstone-dev "chmod +x $STAGE/*.sh"
say "staged"

# ---------------- 5. hand off to the silicon driver ---------------------------
say "launching overnight_autonomy.sh on mapstone-dev (it waits for the bridge1 lease)"
ssh mapstone-dev "cd $STAGE && \
  TD_DEPLOY_DIR=$STAGE SOAK_N=${SOAK_N:-20} MAX_RECOVERIES=3 DEADLINE_MIN=420 \
  RUNDIR=$STAGE/run \
  nohup ./overnight_autonomy.sh > $STAGE/driver.log 2>&1 &
  echo launched pid \$!"
say "handed off. verdict will be at mapstone-dev:$STAGE/run/verdict.txt"

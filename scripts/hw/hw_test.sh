#!/usr/bin/env bash
# hw_test.sh <bitdir> [--worktree DIR] [--results DIR] [--from N] [--to N] [--only N] [--dry-run] [--rehearse] [--unvetted] [--list]
#
# KR260 hardware test of a built kr260-pair-onchip image (both TideLink dies on ONE board, "board 1"): the proven
# Wave C sequence (b08145a) plus the TL-059 / compute-port acceptance checks.  <bitdir> =
# <worktree>/imp/fpga/output/kr260-pair-onchip.  See scripts/hw/RUNBOOK.md; every site-specific value comes from the
# environment (scripts/hw/hw_rig.env.example documents all of it; nothing site-specific is in this file).
#
# SHARED-RIG CONVENTIONS:
#  * The WHOLE run holds  flock -w $LOCK_WAIT $KR260_LOCK  (the rig lock; path from the environment, no default), taken
#    before anything else, so two sessions can never drive the same boards at once.
#  * Auth is password only: KR260_PASSWORD (ssh login, via sshpass -e with SSHPASS exported from it) and KR260_SUDO_PASSWORD
#    (sudo; falls back to KR260_PASSWORD).  Both are read from the environment ONLY.  sudo is `sudo -S -k -p ''` with the
#    password as the FIRST STDIN line, so it never appears on a command line (local or remote), in a log, or in a file.
#    ssh uses ControlMaster.
#  * A sudo pre-check (step 00) runs BEFORE any POR: a refused sudo is found while the boards are still untouched.
#  * Before any deploy BOTH boards get a remote JTAG POR (`ssh $POR_HOST "$POR_REMOTE_CMD"`), cold and quiesced; only then
#    is the onchip image loaded on board 1 (never a PL reload over a live link).  Board 2 stays POR'd and unprogrammed.
#    After every POR the staged files are re-verified by md5 (verify_staged) and the bitstream is reloaded before any PS/PL
#    access.  por_one retries up to 3 times (a JTAG cable can drop off the hw_server for a minute).
#  * On exit, success OR failure (trap), both boards are POR'd again and a hand-off message says the rig owner must
#    restore the standard images ($RIG_RESTORE_NOTE).
#  * Vetting: the image must have a passing built-source marker report (scripts/hw/build.sh writes it; if it is absent
#    hw_test.sh re-runs check_markers.py --mode built on the worktree itself).  An image that cannot be vetted is refused.
#    The only way past is the explicit  --unvetted  flag: it prints a loud banner, marks every result line and the
#    results directory UNVETTED, and the run can never exit 0 (exit 6).  There is no environment-variable bypass.
#
# One step per command, a STOP after the first failing step, one log per step in the results directory.
# Resume after a failure with  --results <dir> --from N  (the run re-takes the flock and re-POR's at step 01).
# --dry-run   : print the plan, execute nothing.   --rehearse : execute everything, but ONLY against stubs of ssh/sshpass/scp/flock/ping
#               found first on PATH (STUBDIR=<dir>, see scripts/hw/stubs/rehearse.sh); refuses to run if any of them resolves outside STUBDIR.
#
# FIXED-IMAGE ACCEPTANCE (TL-059 design E; see RUNBOOK.md section 5), all env knobs, defaults keep the old behaviour:
#   EXPECT_FIXED=1  crc stats runs with --expect-fixed: PASS only if every detected shot was replayed exactly once (0 lost/stray/dup);
#                   with CRCSTATS=1 also requires the two directions together to be >= CRCSTATS_MIN_DETECTED (default 2*CRCSTATS_N) detected and all exact.
#   STREAM=1        right after step 06 autonomy (the first sideband traffic after link-up) run `rev2hw.py stream` b2a then a2b (STREAM_N starts of STREAM_LEN words).
#   BRINGUPS=N      replaces steps 04-21 by N x [POR both -> deploy -> AFI -> autonomy -> (stream) -> smoke -> health], reports k/N (step 23); steps 00-03 and 22 still run.
#                   BRINGUP_CYCLE_MAX (900 s) bounds one cycle; a wedge (timeout, ssh/POR lost) aborts at once and the exit trap restores; BRINGUP_STOP_ON_FAIL=1 stops at the first soft failure.
#
# Exit status: 0 every step passed, 1 a step failed (STOP), 2 refused/precheck, 4 all passed but a step was INCONCLUSIVE,
#              6 all passed but the build was UNVETTED (--unvetted): not evidence.
set +x   # never trace: the password is in the environment
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd -P)                 # the repository this tooling lives in (board tools are staged from HERE's repo)
BOARD_SRC=$REPO/pynq_host/hw_regress              # rev2hw.py, b19_dip.py, injector_controls.py  (run ON the board)
BOARD_FILES="rev2hw.py b19_dip.py injector_controls.py"
TARGET=kr260-pair-onchip
SELF=$HERE/$(basename "${BASH_SOURCE[0]}")

STEPS=(
  "00 lock_check" "01 por_both" "02 bit2bin" "03 stage" "23 bringups" "04 deploy"
  "05 afi_a7obs" "06 autonomy" "07 smoke" "08 regs" "09 soak5000" "10 smoke1"
  "11 b19_dip" "12 postdip_soak5000" "13 postdip_smoke1"
  "14 crc_ctl" "15 crc_a2b" "16 crc_b2a" "17 post_crc_health"
  "18 por2" "19 deploy2" "20 afi_a7window" "21 post_a7_health" "22 restore"
)
PART2_FIRST=18; PART2_LAST=21

ORIG_ARGS=("$@")
BITDIR=""; WT=""; RES=""; FROM=0; TO=99; ONLY=""; DRY=0; LIST=0; REH=0; UNVETTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT=$2; shift 2 ;;  --results) RES=$2; shift 2 ;;
    --from) FROM=$((10#$2)); shift 2 ;;  --to) TO=$((10#$2)); shift 2 ;;  --only) ONLY=$((10#$2)); shift 2 ;;
    --dry-run) DRY=1; shift ;;  --rehearse) REH=1; shift ;;  --list) LIST=1; shift ;;  --unvetted) UNVETTED=1; shift ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    -*) echo "unknown option $1"; exit 2 ;;
    *) [ -z "$BITDIR" ] && BITDIR=$1 || { echo "unexpected argument $1"; exit 2; }; shift ;;
  esac
done
if [ "$LIST" = 1 ]; then printf '%s\n' "${STEPS[@]}"; exit 0; fi
[ -n "$BITDIR" ] || { echo "usage: hw_test.sh <bitdir> [options]   (bitdir = <worktree>/imp/fpga/output/$TARGET)"; exit 2; }
[ -n "$ONLY" ] && { FROM=$ONLY; TO=$ONLY; }

# ---- configuration: ALL site facts come from the environment (see hw_rig.env.example) --------------
# An optional env file is sourced first: $HW_ENV_FILE, else scripts/hw/hw_rig.env (gitignored).  It may export the
# variables below; it must NOT contain passwords (KR260_PASSWORD / KR260_SUDO_PASSWORD are environment-only).
HW_ENV_FILE=${HW_ENV_FILE:-$HERE/hw_rig.env}
if [ -f "$HW_ENV_FILE" ]; then set +u; . "$HW_ENV_FILE"; set -u; fi
if [ -n "${ALLOW_UNVETTED_BUILD:-}" ]; then
  echo "REFUSED: ALLOW_UNVETTED_BUILD was removed (it let an unvetted image run silently). Build with scripts/hw/build.sh, or pass --unvetted (loud, exit 6, marked UNVETTED)."; exit 2
fi
need() {  # need VAR "what it is"
  local v; v=$(printenv "$1" 2>/dev/null || true)
  [ -n "$v" ] && [[ "$v" != \<*\> ]] || { echo "REFUSED: $1 is not set ($2). Set it in the environment or in $HW_ENV_FILE (see scripts/hw/hw_rig.env.example)."; exit 2; }
}
need KR260_LOCK "path of the rig lock file shared by everyone who drives these boards"
need KR260_IP "address of board 1, which hosts BOTH onchip dies; user@ form accepted"
need KR260_IP2 "address of board 2 (POR only, stays unprogrammed)"
need POR_HOST "ssh host that can run the remote JTAG POR"
LOCK_WAIT=${LOCK_WAIT:-3600}
IP1=${KR260_IP#*@}                              # board 1 (hosts BOTH onchip dies)
IP2=${KR260_IP2#*@}                             # board 2 (POR only; stays unprogrammed)
BUSER=${KR260_USER:-ubuntu}                     # the board image's login user
HOST=$BUSER@$IP1; HOST2=$BUSER@$IP2
POR_REMOTE_CMD=${POR_REMOTE_CMD:-fpgahub target reset @TARGET@ --yes}   # run on $POR_HOST; @TARGET@ is replaced
TGT1=${TGT1:-kr260_01}; TGT2=${TGT2:-kr260_02}  # the POR tool's names for board 1 / board 2
RIG_RESTORE_NOTE=${RIG_RESTORE_NOTE:-the standard images the rig owner keeps on these boards}
BACK_TIMEOUT=${BACK_TIMEOUT:-240}              # s to wait for each board to answer after POR
CRC_N=${CRC_N:-7}                              # effective single-bit shots per direction (each arm then disarm; bounded)
CRCSTATS=${CRCSTATS:-0}                       # 1: after step 14 run `crc stats` a2b + b2a, then restore and stop (steps 15-21 not run)
CRCSTATS_N=${CRCSTATS_N:-30}                   # single shots per direction (rev2hw caps at 64)
EXPECT_FIXED=${EXPECT_FIXED:-0}                # 1: acceptance semantics for a TL-059 fixed image (crc stats --expect-fixed)
CRCSTATS_MIN_DETECTED=${CRCSTATS_MIN_DETECTED:-$((2 * CRCSTATS_N))}   # EXPECT_FIXED aggregate: detected shots needed over both directions
STREAM=${STREAM:-0}; STREAM_N=${STREAM_N:-4}; STREAM_LEN=${STREAM_LEN:-28}   # stream-start observation (rev2hw.py stream)
BRINGUPS=${BRINGUPS:-0}; BRINGUP_CYCLE_MAX=${BRINGUP_CYCLE_MAX:-900}; BRINGUP_STOP_ON_FAIL=${BRINGUP_STOP_ON_FAIL:-0}
RUN_PART2=${RUN_PART2:-1}                      # 0 skips the second POR + A7 window cycle (steps 18-21)
HW_OUT=${HW_OUT:-$REPO/imp/hw_regress}         # results/ and builds/ live here (imp/ is untracked)
NAP=1; [ "$REH" = 1 ] && NAP=0                 # rehearsal does not really wait
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
          -o ControlMaster=auto -o "ControlPath=/tmp/kr260-mux-%C" -o ControlPersist=120)   # the boards' sshd resets rapid reconnects
nap() { [ "$NAP" = 1 ] && sleep "$1"; return 0; }

for v in CRCSTATS_N CRCSTATS_MIN_DETECTED STREAM_N STREAM_LEN BRINGUPS BRINGUP_CYCLE_MAX; do
  case "${!v}" in ''|*[!0-9]*) echo "REFUSED: $v must be a non-negative integer (got '${!v}')"; exit 2 ;; esac
done
[ "$BRINGUPS" -le 60 ] || { echo "REFUSED: BRINGUPS=$BRINGUPS > 60 (bounded)"; exit 2; }

# ---- rehearsal guard: stubs only -------------------------------------------------------------
if [ "$REH" = 1 ]; then
  [ -n "${STUBDIR:-}" ] || { echo "REFUSED: --rehearse needs STUBDIR=<dir with stub ssh sshpass scp flock ping>"; exit 2; }
  for t in ssh sshpass scp flock ping; do
    case "$(command -v $t 2>/dev/null)" in "$STUBDIR"/*) ;; *) echo "REFUSED: --rehearse: $t does not resolve to $STUBDIR (is it first on PATH?)"; exit 2 ;; esac
  done
fi

# ---- the flock: taken FIRST, held for the whole run (re-exec under it) ----------------------------
if [ "$DRY" != 1 ] && [ -z "${HWT_LOCKED:-}" ]; then
  echo "waiting for $KR260_LOCK (up to ${LOCK_WAIT}s; whoever else drives these boards holds it during their own runs)"
  exec flock -w "$LOCK_WAIT" -E 75 "$KR260_LOCK" env HWT_LOCKED=1 bash "$SELF" "${ORIG_ARGS[@]}"
fi

# ---- worktree / results ------------------------------------------------------------------------
[ -d "$BITDIR" ] && BITDIR=$(cd "$BITDIR" && pwd -P)
if [ -z "$WT" ]; then
  case "$BITDIR" in */imp/fpga/output/$TARGET) WT=${BITDIR%/imp/fpga/output/$TARGET} ;; *) echo "cannot derive the worktree from $BITDIR; pass --worktree"; exit 2 ;; esac
fi
BIT=$BITDIR/tidelink.bit; HWH=$BITDIR/tidelink.hwh; MAN=$BITDIR/tidelink_manifest.json
HEAD_FULL=$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo unknown); H8=${HEAD_FULL:0:8}
[ -n "$RES" ] || RES=$HW_OUT/results/$(date +%Y%m%d-%H%M%S)-$H8$([ "$DRY" = 1 ] && echo -dryrun)$([ "$REH" = 1 ] && echo -rehearse)$([ "$UNVETTED" = 1 ] && echo -UNVETTED)
mkdir -p "$RES"; chmod 700 "$RES"
BIN=$RES/tidelink.bin        # the converted image lives in the results dir; the build output dir is never written
LOG=$RES/00_header.txt; CAPF=$RES/.cap
SUMMARY=$RES/SUMMARY.tsv

emit() { printf '%s\n' "$*" | tee -a "$LOG"; }

# ---- passwords (env only) ------------------------------------------------------------------------
check_password() {
  local pw; pw=$(printenv KR260_PASSWORD 2>/dev/null || true)
  if [ -z "$pw" ]; then
    emit "REFUSED: KR260_PASSWORD is not set (or not exported). In your own shell run:  read -s KR260_PASSWORD && export KR260_PASSWORD"
    return 1
  fi
  if [[ "$pw" == \<*\> ]]; then
    emit "REFUSED: KR260_PASSWORD still holds placeholder text. Export the real board password."
    return 1
  fi
  return 0
}
SUDOPW() { printenv KR260_SUDO_PASSWORD 2>/dev/null || printenv KR260_PASSWORD; }   # only ever piped, never an argument
scrub() {  # remove either password from a file if a tool echoed it (reads it from the environment, never argv)
  [ "$DRY" = 1 ] && return 0
  python3 - "$@" <<'PYEOF'
import os, sys
for var in ("KR260_PASSWORD", "KR260_SUDO_PASSWORD"):
    pw = os.environ.get(var, "")
    if len(pw) >= 4:
        for p in sys.argv[1:]:
            try:
                t = open(p, errors="replace").read()
                if pw in t:
                    open(p, "w").write(t.replace(pw, "***"))
                    sys.stderr.write("WARNING: the board password appeared in %s and was scrubbed\n" % p)
            except OSError:
                pass
PYEOF
}
if [ "$DRY" != 1 ]; then export SSHPASS; SSHPASS=$(printenv KR260_PASSWORD 2>/dev/null || true); fi   # sshpass -e reads it from here

# ---- command helpers (NO output filter anywhere: indented result lines must survive) -------------
# cap TIMEOUT cmd...        run locally (TIMEOUT 0 = none); output -> $CAPF and $LOG
cap() {
  local t=$1; shift
  : > "$CAPF"
  emit "\$ $(printf '%q ' "$@")"
  if [ "$DRY" = 1 ]; then emit "  [dry-run: not executed]"; CAPRC=0; return 0; fi
  if [ "$t" = 0 ]; then "$@" > "$CAPF" 2>&1 < /dev/null; CAPRC=$?; else timeout "$t" "$@" > "$CAPF" 2>&1 < /dev/null; CAPRC=$?; fi
  tee -a "$LOG" < "$CAPF"; scrub "$CAPF" "$LOG"
  [ "$CAPRC" = 124 ] && emit "  !! TIMEOUT after ${t}s"
  return "$CAPRC"
}
# capssh TIMEOUT 'remote command as the board user on board 1'   (login by sshpass -e; no sudo)
capssh() {
  local t=$1; shift
  : > "$CAPF"
  emit "\$ sshpass -e ssh $HOST $*"
  if [ "$DRY" = 1 ]; then emit "  [dry-run: not executed]"; CAPRC=0; return 0; fi
  timeout "$t" sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" "$@" > "$CAPF" 2>&1 < /dev/null; CAPRC=$?
  tee -a "$LOG" < "$CAPF"; scrub "$CAPF" "$LOG"
  [ "$CAPRC" = 124 ] && emit "  !! TIMEOUT after ${t}s (ssh hung: probable PS wedge)"
  return "$CAPRC"
}
# capsudo TIMEOUT 'shell string'   run as root on board 1 in ~/td.  psctl pattern: `sudo -S -k -p ''`, password = FIRST STDIN LINE.
capsudo() {
  local t=$1 inner; shift
  inner=$(printf '%q' "cd td && $1")
  : > "$CAPF"
  emit "\$ [sudo password on stdin] sshpass -e ssh $HOST sudo -S -k -p '' sh -c $inner"
  if [ "$DRY" = 1 ]; then emit "  [dry-run: not executed]"; CAPRC=0; return 0; fi
  { SUDOPW; } | timeout "$t" sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" "sudo -S -k -p '' sh -c $inner" > "$CAPF" 2>&1
  CAPRC=${PIPESTATUS[1]}
  tee -a "$LOG" < "$CAPF"; scrub "$CAPF" "$LOG"
  [ "$CAPRC" = 124 ] && emit "  !! TIMEOUT after ${t}s (ssh hung: probable PS wedge, needs JTAG POR)"
  return "$CAPRC"
}
has() { [ "$DRY" = 1 ] && return 0; grep -Eq -- "$1" "$CAPF"; }
mux_close() { local h; for h in "$HOST" "$HOST2"; do sshpass -e ssh "${SSH_OPTS[@]}" -O exit "$h" > /dev/null 2>&1 < /dev/null || true; done; }
alive() { timeout 6 ping -c 2 -W 2 "$1" > /dev/null 2>&1; }
wait_back() {  # wait_back IP NAME : poll ping up to BACK_TIMEOUT s
  local i n=$((BACK_TIMEOUT / 5))
  for i in $(seq 1 "$n"); do alive "$1" && { emit "  $2 ($1) answers ping after about $((i * 5)) s"; return 0; }; nap 5; done
  emit "  !! $2 ($1) did not answer ping within ${BACK_TIMEOUT}s"; return 1
}
ssh_ready() {  # ssh_ready HOSTSPEC : password login works (retries: sshd resets rapid reconnects)
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    timeout 40 sshpass -e ssh "${SSH_OPTS[@]}" "$1" true < /dev/null > /dev/null 2>&1 && { emit "  ssh login to $1 works (sshpass -e)"; return 0; }
    nap 6
  done
  emit "  ssh to $1 failed (sshpass -e)"; return 1
}
por_one() {  # por_one TARGET : remote JTAG POR through $POR_HOST, no sudo
  # 2026-10-14: a board's JTAG cable intermittently drops off the hw_server ("target-select failed ...
  # no targets"); it is back within a minute. Retry up to 3 times, 20 s apart, before calling it a failure.
  local i
  for i in 1 2 3; do
    cap 90 ssh -o BatchMode=yes "$POR_HOST" "${POR_REMOTE_CMD//@TARGET@/$1}"
    [ "$CAPRC" = 0 ] && return 0
    [ "$DRY" = 1 ] && return 0
    [ "$i" -lt 3 ] && { emit "  POR of $1 attempt $i failed (rc $CAPRC); retrying in 20 s"; nap 20; }
  done
  return "$CAPRC"
}
por_both() {  # POR kr260_01 and kr260_02, wait for both
  mux_close
  por_one "$TGT1"; local r1=$CAPRC
  por_one "$TGT2"; local r2=$CAPRC
  [ "$DRY" = 1 ] && return 0
  [ "$r1" = 0 ] && [ "$r2" = 0 ] || { emit "  !! POR command rc: $TGT1=$r1 $TGT2=$r2"; return 1; }
  nap 20   # let the SoMs drop before polling (a still-up board would answer ping at once)
  wait_back "$IP1" "$TGT1" && wait_back "$IP2" "$TGT2" || return 1
  nap 20; mux_close
}

# ---- steps: return 0 PASS, 1 FAIL, 3 SKIP, 4 INCONCLUSIVE; set DETAIL --------------------------
DETAIL=""
fail() { DETAIL=$*; return 1; }
BOARD_TOUCHED=0; RESTORED=0

step_lock_check() {
  if [ "$DRY" = 1 ]; then DETAIL="(dry-run) a real run re-execs under: flock -w $LOCK_WAIT $KR260_LOCK"; emit "  [dry-run: would hold $KR260_LOCK]"; return 0; fi
  [ "${HWT_LOCKED:-}" = 1 ] || { fail "not running under the rig flock"; return 1; }
  emit "  running under flock $KR260_LOCK (held for the whole run, released when this script exits)"
  # Prove sudo works BEFORE any POR (2026-10-11: a refused sudo was only found after both boards were POR'd).
  # Read-only: `sudo -S -k true` changes nothing on the board.
  emit "\$ [sudo password on stdin] sshpass -e ssh $HOST sudo -S -k -p '' true  (sudo pre-check, nothing touched)"
  local out rc
  out=$({ SUDOPW; } | timeout 30 sshpass -e ssh "${SSH_OPTS[@]}" "$HOST" "sudo -S -k -p '' true && echo SUDO_OK" 2>&1); rc=$?
  emit "$out"
  [[ "$out" == *SUDO_OK* ]] || { fail "sudo pre-check failed on $HOST (rc $rc): the sudo password (KR260_SUDO_PASSWORD, else KR260_PASSWORD) is wrong or ssh failed. NOTHING was touched; boards untouched."; return 1; }
  DETAIL="flock held: $KR260_LOCK; sudo pre-check OK on $HOST"
}

step_por_both() {
  BOARD_TOUCHED=1
  emit "  cold POR of BOTH boards before any deploy (house rule: never reload a PL on a live link; the rig may carry another session's live link)"
  por_both || { fail "POR of $TGT1/$TGT2 failed or a board did not come back"; return 1; }
  [ "$DRY" = 1 ] && { DETAIL="(dry-run)"; return 0; }
  ssh_ready "$HOST" || { fail "cannot ssh to $HOST after POR"; return 1; }
  ssh_ready "$HOST2" || { fail "cannot ssh to $HOST2 after POR"; return 1; }
  capssh 40 'grep CmaTotal /proc/meminfo'
  local kb; kb=$(awk '/CmaTotal/{print $2}' "$CAPF")
  [ "${kb:-0}" -ge 500000 ] || { fail "CmaTotal ${kb:-?} kB < 512 MB: the PL load will fail with ENOMEM (cma=512M must persist)"; return 1; }
  DETAIL="$TGT1 + $TGT2 POR'd and back (ping + ssh), CmaTotal ok; PL EMPTY on both until step 04"
}

step_bit2bin() {
  cap 120 python3 "$WT/fpga/scripts/bit2bin_zynqmp.py" "$BIT" "$BIN" || { fail "bit2bin_zynqmp.py rc $CAPRC"; return 1; }
  has 'Wrote .*tidelink\.bin' || { fail "no 'Wrote ...tidelink.bin' line"; return 1; }
  [ "$DRY" = 1 ] || { cap 20 md5sum "$BIN"; DETAIL="bin md5 $(cut -c1-8 "$CAPF") ($BIN)"; }
}

step_stage() {
  # replaces upstream kr260_deploy.sh (which put the password on the remote sudo command line).  Same ~/td mirrored layout.
  capssh 60 'mkdir -p td/scripts td/rev2hw' || { fail "mkdir rc $CAPRC"; return 1; }
  cap 180 sshpass -e scp "${SSH_OPTS[@]}" "$BIN" "$HOST:td/tidelink.bin" || { fail "scp bin rc $CAPRC"; return 1; }
  [ -f "$HWH" ] && { cap 60 sshpass -e scp "${SSH_OPTS[@]}" "$HWH" "$HOST:td/tidelink.hwh" || { fail "scp hwh rc $CAPRC"; return 1; }; }
  cap 60 sshpass -e scp "${SSH_OPTS[@]}" "$WT/pynq_host/tl_socmap.py" "$HOST:td/tl_socmap.py" || { fail "scp tl_socmap rc $CAPRC"; return 1; }
  local f; local -a scr=()
  for f in "$WT"/pynq_host/scripts/*; do scr+=("$f"); done
  cap 300 sshpass -e scp -r "${SSH_OPTS[@]}" "${scr[@]}" "$HOST:td/scripts/" || { fail "scp scripts rc $CAPRC"; return 1; }
  local bf; local -a bfs=()
  for bf in $BOARD_FILES; do bfs+=("$BOARD_SRC/$bf"); done
  cap 120 sshpass -e scp "${SSH_OPTS[@]}" "${bfs[@]}" "$HOST:td/rev2hw/" || { fail "scp rev2hw rc $CAPRC"; return 1; }
  [ "$DRY" = 1 ] && { DETAIL="(dry-run)"; return 0; }
  local l r lb rb
  l=$(cd "$BOARD_SRC" && md5sum $BOARD_FILES)
  capssh 40 "cd td/rev2hw && md5sum $BOARD_FILES"; r=$(cat "$CAPF")
  [ "$l" = "$r" ] || { fail "md5 of rev2hw tools differs after scp"; return 1; }
  lb=$(md5sum "$BIN" | cut -d' ' -f1); capssh 40 'md5sum td/tidelink.bin'; rb=$(cut -d' ' -f1 "$CAPF")
  [ "$lb" = "$rb" ] || { fail "bin md5 local $lb != board $rb"; return 1; }
  # 2026-10-14: a JTAG POR right after scp lost the writes (page cache never reached the SD card): the
  # next cycle ran the PREVIOUS run's rev2hw.py. Flush to the card before anything can POR the board.
  capssh 60 'sync' || { fail "sync rc $CAPRC"; return 1; }
  DETAIL="staged bin (md5 ${lb:0:8}), pynq_host scripts, rev2hw tools + injector_controls; md5 equal on the board; synced to SD"
}

# verify_staged : after any POR, prove the board still holds THIS run's bitstream and tools (by md5) before
# loading anything. Without it a lost write silently deploys an older image.
verify_staged() {
  [ "$DRY" = 1 ] && return 0
  local lb rb l r
  lb=$(md5sum "$BIN" | cut -d' ' -f1); capssh 40 'md5sum td/tidelink.bin'; rb=$(cut -d' ' -f1 "$CAPF")
  l=$(cd "$BOARD_SRC" && md5sum $BOARD_FILES)
  capssh 40 "cd td/rev2hw && md5sum $BOARD_FILES"; r=$(cat "$CAPF")
  if [ "$lb" != "$rb" ] || [ "$l" != "$r" ]; then
    emit "  !! staged files on the board are not this run's (bin board ${rb:0:8} vs ${lb:0:8}; tools differ: $([ "$l" = "$r" ] && echo no || echo yes))"
    return 1
  fi
  emit "  staged files verified after POR: bin ${lb:0:8}, rev2hw tools match"
}

deploy_image() {
  verify_staged || { fail "staged bitstream/tools on the board do not match this run (lost after a POR?): NOT deploying"; return 1; }
  # PL load only (the old kr260_deploy.sh recipe, minus its remote-command-line password).  The AFI width re-poke + canaries
  # run in the next afi step.  Preceded by a POR of both boards (step 01 / 18) so the PL being replaced is empty and no link is live.
  capsudo 240 "fpgautil -b tidelink.bin -f Full" ; local rc=$CAPRC
  [ "$rc" = 124 ] && { fail "fpgautil timed out"; return 1; }
  # fpga0 reads 'operating' even with an EMPTY PL after a POR (2026-10-11: sudo was refused, fpgautil rc 1,
  # yet this step passed). The state file cannot prove a load; fpgautil's own rc must.
  [ "$DRY" = 1 ] || [ "$rc" = 0 ] || { fail "fpgautil failed (rc $rc) - PL NOT loaded (sudo refused? see log)"; return 1; }
  capssh 30 'cat /sys/class/fpga_manager/fpga0/state'
  has '^operating' || { fail "fpga_manager state is not 'operating' (fpgautil rc $rc)"; return 1; }
  [ "$DRY" = 1 ] && { DETAIL="(dry-run)"; return 0; }
  ssh_ready "$HOST" || { fail "ssh lost after the PL load"; return 1; }
  DETAIL="PL loaded (fpga0 operating), fpgautil rc $rc"
}
step_deploy() { deploy_image; }
step_deploy2() { deploy_image; }
step_afi_a7obs() {
  # AFI width fix + canaries (KR260_AFI_TARGET=pair-onchip runs the bare-link canaries), then, in the SAME
  # root shell to lose no time, a read-only sample of AUTO_ANCHOR_OBS: is the beacon still running?
  capsudo 120 "env KR260_AFI_TARGET=pair-onchip sh scripts/kr260_afi.sh fix && python3 rev2hw/rev2hw.py a7obs"
  has 'AFI: FIX OK' || { fail "AFI fix/canaries did not report FIX OK"; return 1; }
  has '\[PASS\] 0x84030204 = 0x00000001' || { fail "canary 0x84030204 != 1"; return 1; }
  has '\[PASS\] 0x84030214 = 0x0000E4E4' || { fail "canary 0x84030214 != 0xE4E4"; return 1; }
  # kr260-pair-onchip builds with the wrapper default AUTO_ANCHOR_EN=1'b0 (only the kr260-pair-*nptp two-board
  # targets set 1), so the beacon FSM constant-folds away and A7 cannot be exercised on this image (2026-10-12).
  # That is NOT TESTABLE, never a pass: record it, skip the A7-only part 2, and run everything else.
  if has 'A7OBS_STATE die_a=OFF die_b=OFF'; then
    RUN_PART2=0; A7_NA=1
    DETAIL="AFI+canaries PASS; A7 NOT TESTABLE on this image (AUTO_ANCHOR_EN=0 in kr260-pair-onchip; beacon FSM absent). Steps 18-21 skipped. A7 HW evidence must come from a build that enables it."
    return 0
  fi
  has 'VERDICT: PASS' || { fail "rev2hw a7obs failed"; return 1; }
  DETAIL="AFI+canaries PASS; $(grep -o 'A7OBS_STATE.*' "$CAPF" 2>/dev/null | tail -1) (info: running means the A7 window test can still fire at step 20)"
}

step_autonomy() {
  capsudo 240 "python3 scripts/kr260_onchip_autonomy.py"
  [ "$CAPRC" = 0 ] && has 'AUTONOMY PROVEN' || { fail "autonomy not proven (rc $CAPRC; 1=timeout 2=wedged 3=debug_unlock red flag)"; return 1; }
  DETAIL="autonomy proven, zero host writes"
  if [ "$STREAM" = 1 ]; then   # first sideband traffic after link-up = the genuine cold stream start (b2a = s2m, the July storm path, first)
    stream_run b2a main || { fail "$DETAIL; stream-start: $STREAM_DETAIL"; return 1; }
    DETAIL="$DETAIL; stream-start: $STREAM_DETAIL"
  fi
}
# stream_run FIRST_DIR TAG : rev2hw.py stream on both directions (FIRST_DIR first); sets STREAM_DETAIL; rc 1 on the first non-clean direction
STREAM_DETAIL=""
stream_run() {
  local first=$1 tag=$2 second d rc ok=0 sr
  [ "$first" = b2a ] && second=a2b || second=b2a
  STREAM_DETAIL=""
  for d in $first $second; do
    capsudo 300 "python3 rev2hw/rev2hw.py stream --dir $d --n $STREAM_N --len $STREAM_LEN"; rc=$CAPRC
    [ "$DRY" = 1 ] || cp "$CAPF" "$RES/stream_${tag}_$d.txt"
    sr="$(grep -o 'STREAM_RESULT=[A-Z_]*' "$CAPF" 2>/dev/null | tail -1)"
    STREAM_DETAIL="$STREAM_DETAIL${STREAM_DETAIL:+ ; }$d rc=$rc ${sr:-(no STREAM_RESULT)}"
    if [ "$DRY" != 1 ]; then
      [ "$rc" = 0 ] && has 'STREAM_RESULT=NO_STORM_OBSERVED' && has '^VERDICT: PASS' || { ok=1; break; }
    fi
  done
  return $ok
}
step_smoke() {
  capsudo 180 "python3 scripts/kr260_onchip_smoke.py"
  [ "$CAPRC" = 0 ] || { fail "kr260_onchip_smoke.py rc $CAPRC (1=check failed 2=wedged 3=bus error)"; return 1; }
  DETAIL="plumbing smoke PASS (no --unlock)"
}
step_regs() {
  capsudo 150 "python3 rev2hw/rev2hw.py regs"
  [ "$CAPRC" = 0 ] && has 'VERDICT: PASS' || { fail "register preflight failed (rc $CAPRC); the last 'read ...' line names a register if it hung"; return 1; }
  DETAIL="new registers read OK: 0x23C==0 on both dies, sideband DataID 0xA1, sideband CRC check ON"
  if [ "${ERRPROBE:-0}" = 1 ]; then   # 2026-10-14 diagnostic: die_b 0x23C write path (information only)
    capsudo 60 "python3 rev2hw/rev2hw.py errprobe"
    DETAIL="$DETAIL; $(grep -o 'ERRPROBE_RESULT.*' "$CAPF" | tail -1); $(grep -o 'ERRPROBE_H1.*' "$CAPF" | tail -1)"
  fi
}
soak_step() { # soak_step N label
  capsudo 1500 "python3 scripts/kr260_onchip_soak.py soak $1"
  [ "$CAPRC" = 0 ] && has "SOAK: sent=$1 drained=$1 good=$1 bad=0 stalls=0" || { fail "soak $1 not clean (rc $CAPRC)"; return 1; }
  DETAIL="$1/$1 good, 0 bad, 0 stalls"
}
smoke1_step() {
  capsudo 120 "python3 scripts/kr260_onchip_soak.py smoke1"
  [ "$CAPRC" = 0 ] && has 'SMOKE1 PASS' || { fail "smoke1 failed (rc $CAPRC)"; return 1; }
  DETAIL="smoke1 byte-exact"
}
step_soak5000() { soak_step 5000; }
step_smoke1() { smoke1_step; }
step_postdip_soak5000() { soak_step 5000; }
step_postdip_smoke1() { smoke1_step; }
step_b19_dip() {
  # ALWAYS 0x27F00 THEN 0x27F07 (a dip without the restore wedged the PS in Wave C). Both writes are in b19_dip.py.
  capsudo 120 "python3 rev2hw/b19_dip.py"
  [ "$CAPRC" = 0 ] && has 'VERDICT: PASS' || { fail "B19 control failed (rc $CAPRC); if no 0x27f07 restore line is in the log, POR before anything else"; return 1; }
  DETAIL="dip 0x27F00 then restore 0x27F07: swi_enable held mid-dip (0x27f01), restored, OBS_FC_CREDIT unchanged"
}
step_crc_ctl() {
  capsudo 300 "python3 rev2hw/rev2hw.py crc ctl --dir a2b && python3 rev2hw/rev2hw.py crc ctl --dir b2a"
  if [ "$DRY" != 1 ]; then [ "$CAPRC" = 0 ] && [ "$(grep -c '^VERDICT: PASS' "$CAPF")" = 2 ] || { fail "CRC controls failed (rc $CAPRC)"; return 1; }; fi
  DETAIL="quiet counters + wrong-DataID arm inert + 0x23C holds its value, both directions (b2a clean traffic proven before any injection)"
  if [ "${CRCSTATS:-0}" = 1 ]; then   # 2026-10-14 statistics run: P(lost | detected CRC error), per direction (bounded single shots)
    local d rcs=0 sd xf="" sx=0 sdt=0 x dt
    [ "$EXPECT_FIXED" = 1 ] && xf=" --expect-fixed"
    for d in a2b b2a; do
      capsudo 900 "python3 rev2hw/rev2hw.py crc stats --dir $d --n $CRCSTATS_N$xf"; local rc=$CAPRC
      [ "$DRY" = 1 ] || cp "$CAPF" "$RES/14_crc_stats_$d.txt"
      sd="$(grep -o 'STATS_RESULT=.*' "$CAPF" 2>/dev/null | tail -1)"
      DETAIL="$DETAIL; stats $d rc=$rc ${sd:-(none)}"
      [ "$rc" = 0 ] || rcs=1
      if [ "$EXPECT_FIXED" = 1 ] && [ "$DRY" != 1 ]; then
        grep -q 'STATS_RESULT=FIXED_PASS' "$CAPF" 2>/dev/null || rcs=1
        x=$(grep -o 'FIXED_PASS exact=[0-9]*' "$CAPF" | tail -1 | cut -d= -f2); dt=$(grep -o 'FIXED_PASS exact=[0-9]* detected=[0-9]*' "$CAPF" | tail -1 | sed 's/.*detected=//')
        sx=$((sx + ${x:-0})); sdt=$((sdt + ${dt:-0}))
      fi
      grep -q 'STATS_RESULT=LINK_DEGRADED' "$CAPF" 2>/dev/null && break   # link degraded: do not drive the other direction
    done
    if [ "$EXPECT_FIXED" = 1 ] && [ "$DRY" != 1 ]; then
      DETAIL="$DETAIL; EXPECT_FIXED replayed exactly once $sx/$sdt over both directions (need all, and >= $CRCSTATS_MIN_DETECTED detected)"
      { [ "$sx" = "$sdt" ] && [ "$sdt" -ge "$CRCSTATS_MIN_DETECTED" ]; } || rcs=1
    fi
    [ "$rcs" = 0 ] || { fail "$DETAIL"; return 1; }
  fi
}
step_crc_a2b() {
  capsudo 600 "python3 rev2hw/rev2hw.py crc sweep --dir a2b --n $CRC_N"
  [ "$CAPRC" = 0 ] && has 'VERDICT: PASS' || { fail "a2b CRC sweep failed (rc $CAPRC)"; return 1; }
  DETAIL="$(grep -o 'CRC-SWEEP a2b: .*' "$CAPF" 2>/dev/null | tail -1)"
}
step_crc_b2a() {
  capsudo 600 "python3 rev2hw/rev2hw.py crc sweep --dir b2a --n $CRC_N"
  [ "$CAPRC" = 0 ] && has 'VERDICT: PASS' || { fail "b2a CRC sweep failed (rc $CAPRC)"; return 1; }
  DETAIL="$(grep -o 'CRC-SWEEP b2a: .*' "$CAPF" 2>/dev/null | tail -1)"
}
step_post_crc_health() {
  capsudo 900 "python3 scripts/kr260_onchip_soak.py soak 1000 && python3 scripts/kr260_onchip_soak.py smoke1 && python3 rev2hw/rev2hw.py regs"
  [ "$CAPRC" = 0 ] && has 'SOAK: sent=1000 drained=1000 good=1000 bad=0 stalls=0' && has 'SMOKE1 PASS' && has 'VERDICT: PASS' \
    || { fail "sideband path not healthy after the CRC errors (rc $CAPRC)"; return 1; }
  DETAIL="after 2x$CRC_N CRC errors on the sideband node: soak 1000 clean, smoke1 exact, injector reads 0, link up"
}
step_por2() { step_por_both_wrap; }

# ---- BRINGUPS=N: N x cold bring-up (acceptance item "37/37 bring-ups") ---------------------------------------
BU_WHY=""; BU_WEDGE=0
bringup_cycle() {   # bringup_cycle K N ; rc 0 = bring-up good; sets BU_WHY; BU_WEDGE=1 means STOP (board/PS/ssh lost)
  local k=$1 t0 kb first; t0=$(date +%s); BU_WHY=""; BU_WEDGE=0
  over() { [ "$DRY" != 1 ] && [ $(( $(date +%s) - t0 )) -gt "$BRINGUP_CYCLE_MAX" ]; }
  wedged() { [ "$CAPRC" = 124 ] && BU_WEDGE=1; return 0; }
  por_both || { BU_WHY="POR of $TGT1/$TGT2 failed or a board did not come back"; BU_WEDGE=1; return 1; }
  if [ "$DRY" != 1 ]; then
    ssh_ready "$HOST" && ssh_ready "$HOST2" || { BU_WHY="ssh lost after POR"; BU_WEDGE=1; return 1; }
    capssh 40 'grep CmaTotal /proc/meminfo'; wedged
    kb=$(awk '/CmaTotal/{print $2}' "$CAPF")
    [ "${kb:-0}" -ge 500000 ] || { BU_WHY="CmaTotal ${kb:-?} kB < 512 MB"; return 1; }
  fi
  over && { BU_WHY="cycle exceeded ${BRINGUP_CYCLE_MAX}s after POR"; BU_WEDGE=1; return 1; }
  deploy_image || { wedged; BU_WHY="deploy: $DETAIL"; return 1; }
  capsudo 120 "env KR260_AFI_TARGET=pair-onchip sh scripts/kr260_afi.sh fix"; wedged
  { has 'AFI: FIX OK' && has '\[PASS\] 0x84030204 = 0x00000001' && has '\[PASS\] 0x84030214 = 0x0000E4E4'; } || { BU_WHY="AFI fix/canaries (rc $CAPRC)"; return 1; }
  over && { BU_WHY="cycle exceeded ${BRINGUP_CYCLE_MAX}s after AFI"; BU_WEDGE=1; return 1; }
  capsudo 240 "python3 scripts/kr260_onchip_autonomy.py"
  [ "$CAPRC" = 2 ] && BU_WEDGE=1; wedged
  { [ "$CAPRC" = 0 ] && has 'AUTONOMY PROVEN'; } || { BU_WHY="autonomy not proven (rc $CAPRC; 2=wedged)"; return 1; }
  if [ "$STREAM" = 1 ]; then   # cold stream start; s2m (b2a) first on odd cycles, a2b first on even cycles
    first=b2a; [ $((k % 2)) = 0 ] && first=a2b
    stream_run "$first" "c$k"; local src=$?
    wedged
    [ "$src" = 0 ] || { BU_WHY="stream-start: $STREAM_DETAIL"; return 1; }
  fi
  capsudo 180 "python3 scripts/kr260_onchip_smoke.py"; wedged
  [ "$CAPRC" = 0 ] || { BU_WHY="smoke rc $CAPRC (2=wedged 3=bus error)"; return 1; }
  capsudo 60 "python3 rev2hw/rev2hw.py health"; wedged
  { [ "$CAPRC" = 0 ] && has '^VERDICT: PASS'; } || { BU_WHY="health: fcsm/cal not up (rc $CAPRC)"; return 1; }
  over && { BU_WHY="cycle exceeded ${BRINGUP_CYCLE_MAX}s"; BU_WEDGE=1; return 1; }
  return 0
}
step_bringups() {
  local k ok=0 nrun=0 t0 dt N=$BRINGUPS lastfail=""
  [ "$N" -ge 1 ] || { DETAIL="BRINGUPS=0"; return 3; }
  BOARD_TOUCHED=1
  printf 'cycle\tverdict\tseconds\twhy\n' > "$RES/bringups.tsv"
  if [ "$DRY" = 1 ]; then
    emit "  [dry-run] would run $N x: POR both -> ssh/CMA -> deploy -> AFI+canaries -> autonomy -> $([ "$STREAM" = 1 ] && echo "stream-start(${STREAM_N}x${STREAM_LEN}w, alternating first dir) -> ")smoke -> health; cycle bound ${BRINGUP_CYCLE_MAX}s, wedge aborts"
    bringup_cycle 1; DETAIL="(dry-run) $N bring-up cycles planned"; return 0
  fi
  for k in $(seq 1 "$N"); do
    t0=$(date +%s); emit "--- bring-up $k/$N  $(date '+%F %T')"
    bringup_cycle "$k"; local rc=$?; dt=$(( $(date +%s) - t0 )); nrun=$k
    if [ "$rc" = 0 ]; then ok=$((ok + 1)); emit "BRINGUP $k/$N PASS (${dt}s)  running total $ok/$k"; printf '%s\tPASS\t%s\t\n' "$k" "$dt" >> "$RES/bringups.tsv"
    else lastfail="cycle $k: $BU_WHY"; emit "BRINGUP $k/$N FAIL (${dt}s): $BU_WHY"; printf '%s\tFAIL\t%s\t%s\n' "$k" "$dt" "$BU_WHY" >> "$RES/bringups.tsv"; fi
    if [ "$BU_WEDGE" = 1 ]; then emit "!! WEDGE / board lost in cycle $k: aborting (the exit trap POR's both boards)"; DETAIL="bring-ups $ok/$N PASS; ABORTED at cycle $k (wedge): $BU_WHY"; return 1; fi
    if [ "$rc" != 0 ] && [ "$BRINGUP_STOP_ON_FAIL" = 1 ]; then break; fi
  done
  DETAIL="bring-ups $ok/$N PASS (ran $nrun; STREAM=$STREAM; per-cycle: $RES/bringups.tsv)"
  [ "$ok" = "$N" ] || { DETAIL="$DETAIL; last failure: $lastfail"; return 1; }
}
step_afi_a7window() {
  capsudo 180 "env KR260_AFI_TARGET=pair-onchip sh scripts/kr260_afi.sh fix && python3 rev2hw/rev2hw.py a7window"
  local rc=$CAPRC
  has 'AFI: FIX OK' || { fail "AFI fix/canaries did not report FIX OK"; return 1; }
  if [ "$DRY" != 1 ]; then
    if [ "$rc" = 4 ] || grep -q '^VERDICT: INCONCLUSIVE' "$CAPF"; then DETAIL="INCONCLUSIVE: $(grep -o 'VERDICT: INCONCLUSIVE.*' "$CAPF" | head -1 | cut -c1-200)"; return 4; fi
    [ "$rc" = 0 ] && has 'VERDICT: PASS' || { fail "A7 window test failed (rc $rc); if the log stops after 'A7 burst:' the ahb_sub write hung the PS: POR, then re-run with RUN_PART2=0"; return 1; }
    DETAIL="$(grep -o 'VERDICT: PASS.*' "$CAPF" | head -1 | cut -c15-220)"
  fi
}
step_post_a7_health() {
  capsudo 600 "python3 scripts/kr260_onchip_soak.py smoke1 && python3 scripts/kr260_onchip_soak.py soak 500 && python3 rev2hw/rev2hw.py health"
  [ "$CAPRC" = 0 ] && has 'SMOKE1 PASS' && has 'good=500 bad=0 stalls=0' && has 'VERDICT: PASS' || { fail "link or data path unhealthy after the A7 window test (rc $CAPRC)"; return 1; }
  DETAIL="smoke1 exact, soak 500 clean, link up after the AXI window traffic"
}
step_por_both_wrap() {
  emit "  Part 2: cold POR of BOTH boards again, then the image is reloaded (step 19) before any access"
  por_both || { fail "POR of $TGT1/$TGT2 failed or a board did not come back"; return 1; }
  [ "$DRY" = 1 ] && { DETAIL="(dry-run)"; return 0; }
  ssh_ready "$HOST" || { fail "cannot ssh to $HOST after POR"; return 1; }
  DETAIL="$TGT1 + $TGT2 POR'd again and back; PL empty until step 19"
}

# ---- restore: POR both, then the hand-off message.  Called as the last step AND from the EXIT trap. ------------
handoff_msg() {
  cat <<MSG

================================================================================================
 HAND-OFF TO THE RIG OWNER  ($(date '+%F %T'))
 This run POR'd $TGT1 and $TGT2.  BOTH boards are now cold with an EMPTY PL: nothing is loaded and no link is up.
 Whoever owns the rig MUST restore its standard images before using it:
   $RIG_RESTORE_NOTE
   board 1 ($IP1), board 2 ($IP2)
 This script does NOT restore them.  The flock is released when this script exits.
================================================================================================
MSG
}
restore_both() {
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  emit "=== RESTORE: POR both boards (leaves them cold and unprogrammed for the rig owner)"
  local save=$LOG; LOG=$RES/99_restore.txt; : > "$LOG"
  por_both; local rc=$?
  [ "$DRY" = 1 ] && rc=0
  if [ "$rc" = 0 ]; then emit "RESTORE: both boards POR'd and answering"; else emit "RESTORE: !! POR of the boards FAILED (rc $rc): power-cycle them by hand before anyone uses the rig"; fi
  handoff_msg | tee -a "$LOG"
  LOG=$save
  return "$rc"
}
step_restore() {
  restore_both || { fail "restore POR failed"; return 1; }
  DETAIL="both boards POR'd; the rig owner must restore: $RIG_RESTORE_NOTE"
}
on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$BOARD_TOUCHED" = 1 ] && [ "$RESTORED" != 1 ] && [ "$DRY" != 1 ]; then
    echo; echo "!! exiting early (rc $rc): restoring the rig (POR both) before releasing the lock"
    restore_both
  fi
  [ "$BOARD_TOUCHED" = 1 ] && [ "$DRY" != 1 ] && mux_close
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
IS_UNVETTED=0
unvetted_banner() {
  IS_UNVETTED=1; : > "$RES/UNVETTED"
  printf '00\tvetting\tUNVETTED\t0\tbuild not vetted (--unvetted): NOT EVIDENCE\n' >> "$SUMMARY"
  local l; for l in \
"################################################################################" \
"## UNVETTED BUILD  (--unvetted)                                               ##" \
"## The sources of this image were NOT proven to contain the fixes under test. ##" \
"## Every verdict below is UNVETTED. The run will exit 6, never 0.             ##" \
"## Nothing from it may be quoted as hardware evidence.                        ##" \
"################################################################################"; do emit "$l"; echo "$l" >&2; done
}
# ---- local preflight (no board, no lease) -------------------------------------------------------
preflight() {
  LOG=$RES/00_preflight.txt; : > "$LOG"; local bad=0
  p() { emit "[PREFLIGHT $1] $2"; [ "$1" = FAIL ] && bad=$((bad + 1)); return 0; }
  emit "=== local preflight $(date '+%F %T')  bitdir=$BITDIR  worktree=$WT  results=$RES  dry_run=$DRY"
  for t in ssh scp sshpass flock ping python3 timeout md5sum sha256sum; do command -v $t > /dev/null 2>&1 && p PASS "tool $t" || p FAIL "tool $t missing"; done
  for f in "$BIT" "$MAN" "$HWH"; do [ -f "$f" ] && p PASS "exists $(basename "$f")" || p FAIL "missing $f"; done
  for f in pynq_host/tl_socmap.py pynq_host/scripts/kr260_afi.sh pynq_host/scripts/kr260_onchip_autonomy.py pynq_host/scripts/kr260_onchip_smoke.py \
           pynq_host/scripts/kr260_onchip_soak.py fpga/scripts/bit2bin_zynqmp.py; do
    [ -f "$WT/$f" ] && p PASS "worktree has $f" || p FAIL "worktree lacks $f"
  done
  [ -d "$WT/.git" ] || [ -f "$WT/.git" ] || p FAIL "$WT is not a git worktree"
  if [ -z "$(git -C "$WT" status --porcelain 2>&1)" ]; then p PASS "worktree clean at $H8"; else p FAIL "worktree dirty: the scripts staged on the board would not be the tested commit"; fi
  if [ -f "$MAN" ]; then
    local out; out=$(HEAD_FULL="$HEAD_FULL" BIT="$BIT" MAN="$MAN" TARGET="$TARGET" python3 - <<'PYEOF'
import hashlib, json, os
m = json.load(open(os.environ["MAN"])); r = []
def a(ok, n, d): r.append("%s manifest %s: %s" % ("PASS" if ok else "FAIL", n, d))
a(m.get("phy_marker") == "V2", "phy_marker", repr(m.get("phy_marker")))
a(m.get("flist") == "tidelink_fpga_v2.flist", "flist", repr(m.get("flist")))
a(m.get("source_commit") == os.environ["HEAD_FULL"], "source_commit == worktree HEAD", "%s vs %s" % (m.get("source_commit"), os.environ["HEAD_FULL"]))
a(m.get("git_dirty") is False, "git_dirty", repr(m.get("git_dirty")))
a(m.get("xhb500_tree") == "match", "xhb500_tree", repr(m.get("xhb500_tree")))
a(m.get("target") == os.environ["TARGET"], "target", repr(m.get("target")))
h = hashlib.sha256(open(os.environ["BIT"], "rb").read()).hexdigest() if os.path.isfile(os.environ["BIT"]) else "-"
a(m.get("sha256") == h, "sha256 == sha256(tidelink.bit)", h[:16])
print("\n".join(r))
PYEOF
)
    while IFS= read -r l; do p "${l%% *}" "${l#* }"; done <<< "$out"
  fi
  # ---- vetting: was the image built from sources that contain the fixes?  (no bypass: see --unvetted)
  local mk="$HW_OUT/builds/$H8/markers-built-$H8.txt" vetted=0
  if [ -f "$mk" ] && grep -q '^MARKERS_RESULT=PASS' "$mk"; then
    p PASS "build.sh recorded MARKERS_RESULT=PASS for this commit ($mk)"; vetted=1
  elif [ -d "$WT/imp/fpga/tidelink_ip/src" ]; then
    # no build.sh record: re-run the SAME check on the packaged IP Vivado synthesised (needs the worktree it was built in)
    local rv="$RES/00_markers_revet.txt"
    if python3 "$HERE/check_markers.py" --tree "$WT" --mode built > "$rv" 2>&1 && grep -q '^MARKERS_RESULT=PASS' "$rv"; then
      p PASS "no build.sh record at $mk; hw_test.sh re-ran check_markers.py --mode built on $WT: MARKERS_RESULT=PASS ($rv)"; vetted=1
    else
      p FAIL "built-marker re-vet FAILED (see $rv): the packaged IP does not contain the fixes"
    fi
  else
    p FAIL "no passing built-marker report at $mk and no packaged IP under $WT/imp/fpga/tidelink_ip/src to re-vet: this image was not vetted"
  fi
  if [ "$vetted" != 1 ] && [ "$UNVETTED" = 1 ]; then
    bad=$((bad > 0 ? bad - 1 : 0))        # the vetting failure above is the one --unvetted acknowledges; every other failure still counts
    unvetted_banner
  elif [ "$vetted" != 1 ]; then
    emit "(pass --unvetted to run anyway: loud banner, results marked UNVETTED, exit status 6, never evidence)"
  fi
  [ -e "$KR260_LOCK" ] && p PASS "rig lock file exists: $KR260_LOCK" || p FAIL "rig lock file missing: $KR260_LOCK (create it once with touch; it is the lock everyone driving these boards shares)"
  if [ "$DRY" != 1 ] && [ "$TO" -ge 1 ] && [ "$FROM" -le 23 ]; then check_password && p PASS "KR260_PASSWORD is set and is not the placeholder (value never printed)" || p FAIL "KR260_PASSWORD"; fi
  emit "preflight: $bad failure(s)"
  if [ "$bad" -gt 0 ]; then
    if [ "$DRY" = 1 ] || [ "$REH" = 1 ]; then emit "(dry-run/rehearsal: continuing despite the failures above)"; return 0; fi
    emit "REFUSED: fix the preflight failures; no board command was run."; return 1
  fi
  return 0
}

# ---- runner --------------------------------------------------------------------------------------
INCONC=0
stop_banner() {
  echo
  echo "STOPPED at step $1 ($2): $3"
  echo "  log: $4"
  echo "  The exit trap now POR's both boards and prints the hand-off message for the rig owner (see $RES/99_restore.txt)."
  echo "  Resume after fixing the cause (takes the flock again, POR's again at step 01):"
  echo "      bash $HERE/hw_test.sh $BITDIR --results $RES --from 1"
}
printf 'step\tname\tverdict\tseconds\tdetail\n' > "$SUMMARY"

preflight || exit 2
mkdir -p "$RES"
for s in "${STEPS[@]}"; do
  nn=${s%% *}; name=${s#* }; n=$((10#$nn))
  [ "$n" -lt "$FROM" ] && continue
  [ "$n" -gt "$TO" ] && continue
  if [ "$BRINGUPS" -ge 1 ]; then case "$n" in 0|1|2|3|22|23) ;; *) continue ;; esac; else [ "$n" = 23 ] && continue; fi   # BRINGUPS mode replaces steps 04-21
  LOG=$RES/${nn}_${name}.txt; : > "$LOG"
  if [ "$n" -ge $PART2_FIRST ] && [ "$n" -le $PART2_LAST ] && [ "$RUN_PART2" != 1 ]; then
    why="RUN_PART2=0"; [ "${A7_NA:-0}" = 1 ] && why="A7 NOT TESTABLE (AUTO_ANCHOR_EN=0)"
    emit "=== step $nn $name: SKIPPED ($why)"; printf '%s\t%s\tSKIPPED\t0\t%s\n' "$nn" "$name" "$why" >> "$SUMMARY"; continue
  fi
  if [ "$n" -ge 1 ] && [ "$DRY" != 1 ]; then check_password || { printf '%s\t%s\tREFUSED\t0\tno password\n' "$nn" "$name" >> "$SUMMARY"; exit 2; }; fi
  emit "=== step $nn $name  $(date '+%F %T')"
  t0=$(date +%s); DETAIL=""
  "step_$name"; rc=$?
  dt=$(( $(date +%s) - t0 ))
  case "$rc" in
    0) V=PASS ;;  3) V=SKIPPED ;;  4) V=INCONCLUSIVE; INCONC=1 ;;  *) V=FAIL ;;
  esac
  [ "$DRY" = 1 ] && [ "$V" = PASS ] && V=PLANNED
  [ "$IS_UNVETTED" = 1 ] && DETAIL="[UNVETTED BUILD] $DETAIL"
  emit "VERDICT: $V  step $nn $name (${dt}s)  ${DETAIL}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$nn" "$name" "$V" "$dt" "$DETAIL" >> "$SUMMARY"
  if [ "$V" = FAIL ]; then stop_banner "$nn" "$name" "$DETAIL" "$LOG"; exit 1; fi
  if [ "$CRCSTATS" = 1 ] && [ "$name" = crc_ctl ] && [ "$TO" -ge 22 ]; then   # stats mode: restore (step 22) and stop
    LOG=$RES/22_restore.txt; : > "$LOG"; emit "=== step 22 restore  $(date '+%F %T')  (CRCSTATS=1: steps 15-21 not run)"
    t0=$(date +%s); DETAIL=""; step_restore; rc=$?; dt=$(( $(date +%s) - t0 ))
    V=PASS; [ "$rc" = 0 ] || V=FAIL; [ "$DRY" = 1 ] && [ "$V" = PASS ] && V=PLANNED
    [ "$IS_UNVETTED" = 1 ] && DETAIL="[UNVETTED BUILD] $DETAIL"
    emit "VERDICT: $V  step 22 restore (${dt}s)  ${DETAIL}"; printf '22\trestore\t%s\t%s\t%s\n' "$V" "$dt" "$DETAIL" >> "$SUMMARY"
    [ "$V" = FAIL ] && exit 1
    break
  fi
done
echo
echo "== SUMMARY ($RES/SUMMARY.tsv) =="
column -t -s $'\t' "$SUMMARY" | cut -c1-230
if [ "$IS_UNVETTED" = 1 ]; then
  echo "##### UNVETTED BUILD: THIS RUN IS NOT EVIDENCE (exit 6, marker file $RES/UNVETTED)."
  [ "$DRY" = 1 ] && { echo "DRY-RUN COMPLETE: nothing was executed."; }
  exit 6
fi
if [ "$INCONC" = 1 ]; then echo "ALL EXECUTED STEPS PASSED, but at least one was INCONCLUSIVE (see above)."; exit 4; fi
[ "$DRY" = 1 ] && { echo "DRY-RUN COMPLETE: nothing was executed."; exit 0; }
echo "ALL EXECUTED STEPS PASSED."
exit 0

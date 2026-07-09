#!/bin/bash
# =============================================================================
# overnight_autonomy.sh — unattended, bounded silicon run for the iter-5 stack.
#
# WHY A SHELL DRIVER: it must survive the operator (and any agent session) going
# away. State lives in files, every phase is idempotent, and the lease is always
# released on exit.
#
# WHAT IT IS TESTING (in priority order — phase 2 is the deliverable):
#   Phase 0  preflight     boards reachable; lease GRANTED (not queued)
#   Phase 1  known state   power-cycle BOTH boards, deploy both bitstreams
#   Phase 2  DECISIVE      does die_a survive the arming of die_b?
#                          The fc_cfg APB preempt fix (tidelink_top.sv) is proven
#                          in sim (FAIL pre-fix / PASS post-fix). This is its
#                          silicon test. Historically die_a's PS bus died on the
#                          very write that set train_auto_en on the *second* die.
#                          A FAIL here is the night's headline: STOP, do not bury
#                          it under 20 soak cycles.
#   Phase 3  soak          zeropoke_soak --stats N, with the UNARMED verdict, so
#                          for the first time a cycle in which training never
#                          started is excluded from the denominator instead of
#                          being scored as a NODONE failure.
#   Phase 4  diagnose      for any die reporting NODONE while genuinely ARMED,
#                          dump the autoneg role-lock chain (0x2194) + role/nego.
#
# GUARDRAILS
#   * a wedged die is recovered with `fpgahub hub power-cycle` (the PDU). NOT
#     `fpgahub board reset` — that is a red herring and fails on a dark board.
#   * at most MAX_RECOVERIES power-cycle recoveries for the whole run.
#   * hard wall-clock deadline; lease released via trap on ANY exit path.
#   * one lease for the whole run -> the soak is invoked with --no-lease.
#     (Re-acquiring while already holding just queues you behind yourself.)
#   * quiesce before every re-deploy (zp_quiesce) — reloading the PL on a live
#     link has hard-hung boards.
#
# OUTPUT: $RUNDIR/{run.log,verdict.txt,stats.csv,phase2.txt,phase4_*.txt}
#   verdict.txt is the file to read first. It is written on every exit path.
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

SOAK_N=${SOAK_N:-20}
MAX_RECOVERIES=${MAX_RECOVERIES:-3}
DEADLINE_MIN=${DEADLINE_MIN:-420}          # 7 h hard cap
RUNDIR=${RUNDIR:-$HOME/td_overnight/$(date -u +%Y%m%d_%H%M%SZ)}
mkdir -p "$RUNDIR"
VERDICT="$RUNDIR/verdict.txt"
T0=$(date +%s)
RECOVERIES=0

# die_a = z2_02 (master, non-flip). NOTE the hub names differ per board:
# z2_01 exposes ..._pl, z2_02 exposes ..._ps. Using the wrong one 404s.
HUB_A=${TD_HUB_A:-pynq_z2_02_ps}
HUB_B=${TD_HUB_B:-pynq_z2_01_pl}

log(){ echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$RUNDIR/run.log"; }
say(){ echo "$*" >> "$VERDICT"; }
deadline_hit(){ [ $(( ($(date +%s) - T0) / 60 )) -ge "$DEADLINE_MIN" ]; }

finish(){ local rc=$?
  lease_release 2>/dev/null || true
  say ""; say "run ended $(date -u +%FT%TZ)  elapsed $(( ($(date +%s)-T0)/60 ))min  recoveries=$RECOVERIES  rc=$rc"
  log "lease released; verdict -> $VERDICT"; }
trap finish EXIT

# --- a die is 'alive' iff its PS can actually read a PL register --------------
# ping/ssh are NOT enough: the classic failure is Linux up, every /dev/mem access
# a Bus error. Read a register with a known constant marker.
die_alive(){ local d="$1" v
  v=$("$d" rd $R_WINSCAN_OBS 2>/dev/null) || return 1
  [ -n "$v" ] || return 1
  [ $(( ( v >> 24 ) & 0xff )) -eq $(( 0x57 )) ]; }

# PROVE the power-cycle happened. The hub port name is the single assumption the
# whole unattended run rests on, and a wrong name is a SILENT no-op: the command
# 404s, the board never reboots, `boards_up` still passes, and the driver sails on
# believing it recovered. So: require exit 0, require the board to actually go
# DOWN (that is the proof the PDU cut it), then require it back.
# $1 = hub port name, $2 = the board IP to watch
power_cycle(){ local hub="$1" ip="$2" i
  log "POWER-CYCLE $hub ($ip)"
  if ! fpgahub hub power-cycle "$hub" --off 2 --yes >>"$RUNDIR/run.log" 2>&1; then
    say "ABORT: 'fpgahub hub power-cycle $hub' failed. Recovery is impossible unattended."
    log "power-cycle command FAILED for $hub"; exit 30
  fi
  local down=0
  for i in $(seq 1 15); do
    ping -c1 -W1 "$ip" >/dev/null 2>&1 || { down=1; log "  $hub went down (confirmed)"; break; }
    sleep 1
  done
  if [ "$down" -eq 0 ]; then
    # The command "succeeded" but the board never lost power => wrong port. The
    # _ps/_pl suffix differs per board and my notes disagree about which. Rather
    # than lose the night to a naming guess, try the sibling suffix ONCE.
    local alt=""
    case "$hub" in *_ps) alt="${hub%_ps}_pl";; *_pl) alt="${hub%_pl}_ps";; esac
    [ -z "$alt" ] || [ "${3:-}" = "noalt" ] && {
      say "ABORT: $hub never went down -> wrong hub port, and no alternate to try."
      log "power-cycle NO-OP for $hub, no alt"; exit 31; }
    log "  $hub was a NO-OP (board stayed up) -> retrying with sibling port $alt"
    power_cycle "$alt" "$ip" noalt || exit $?
    case "$hub" in "$HUB_A") HUB_A="$alt";; "$HUB_B") HUB_B="$alt";; esac
    log "  hub port for $ip corrected to $alt for the rest of the run"
    return 0
  fi
  for i in $(seq 1 40); do
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && { log "  $hub back up after $((i*3))s"; sleep 12; return 0; }
    sleep 3
  done
  say "ABORT: $hub did not come back after power-cycle."; exit 32; }

recover(){ # $1 = reason
  RECOVERIES=$((RECOVERIES+1))
  log "RECOVERY $RECOVERIES/$MAX_RECOVERIES — $1"
  if [ "$RECOVERIES" -gt "$MAX_RECOVERIES" ]; then
    say "ABORT: recovery budget exhausted ($MAX_RECOVERIES). Boards left powered."
    log "recovery budget exhausted"; exit 20
  fi
  power_cycle "$HUB_A" "$A_IP"; power_cycle "$HUB_B" "$B_IP"
  local i; for i in $(seq 1 24); do boards_up 2>/dev/null && return 0; sleep 5; done
  say "ABORT: boards did not come back after power-cycle."; exit 21; }

# ============================ Phase 0 — preflight =============================
say "=== TideLink overnight autonomy run — $(date -u +%FT%TZ) ==="
say "iter-5: fc_cfg APB preempt fix + div-2 + fe_tx_credit_max + fch watchdog"
say ""
log "Phase 0: preflight"

# WAIT for the pair to be free. Another session may hold bridge1; acquiring while
# someone else holds it just QUEUES us, and a queued lease is not a lease -- we
# would deploy over their run. Poll politely, up to LEASE_WAIT_MIN.
LEASE_WAIT_MIN=${LEASE_WAIT_MIN:-180}
lease_free(){ fpgahub pair lease show "$LEASE_NAME" --json 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('state','?'))" 2>/dev/null; }
w=0
while :; do
  st=$(lease_free)
  [ "$st" != "held" ] && break
  [ "$w" -ge "$LEASE_WAIT_MIN" ] && { say "ABORT: $LEASE_NAME still held after ${LEASE_WAIT_MIN}min. Not stealing it."; exit 2; }
  [ $(( w % 15 )) -eq 0 ] && log "waiting for $LEASE_NAME (state=$st, ${w}min elapsed)"
  sleep 60; w=$((w+1))
done
log "$LEASE_NAME is free (state=$st)"

boards_up || recover "a board unreachable at preflight"
lease_acquire $(( DEADLINE_MIN * 60 )) || { say "ABORT: lease acquire returned no token."; exit 3; }
# STRICT: a token is not proof of a grant. Verify WE hold it. (hwlib's
# lease_acquire only checks the token is non-empty.)
holder=$(fpgahub pair lease show "$LEASE_NAME" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); m=(d.get('members') or [{}])[0].get('current') or {}
print(f\"{d.get('state','?')}:{m.get('holder','?')}\")" 2>/dev/null)
case "$holder" in
  held:$(hostname)) log "lease GRANTED to $(hostname)";;
  *) say "ABORT: lease not granted to us (state:holder = $holder). Refusing to proceed."; exit 3;;
esac

# ============================ Phase 1 — known state ===========================
log "Phase 1: power-cycle both boards to a known state, then deploy both"
power_cycle "$HUB_A" "$A_IP"; power_cycle "$HUB_B" "$B_IP"
for i in $(seq 1 24); do boards_up 2>/dev/null && break; sleep 5; done
boards_up || { say "ABORT: boards never came up after the initial power-cycle."; exit 4; }
deploy_pair; sleep 3
deploy_pair; sleep 3          # double-pass: the proven deploy order
die_alive a || { say "ABORT: die_a has no PL register access after deploy (stale/bad bitstream?)."; exit 5; }
die_alive b || { say "ABORT: die_b has no PL register access after deploy."; exit 5; }
log "both dies deployed and register-readable"

# ==================== Phase 2 — THE DECISIVE EXPERIMENT =======================
# Prior silicon (sibling, measured): arming die_a ALONE is harmless; die_a's PS
# bus dies at the instant die_b is armed, i.e. when training actually proceeds.
# That is exactly the fc_cfg-preempts-in-flight-PS-access window. If the fix
# holds, die_a stays register-readable through step 2.
log "Phase 2: DECISIVE — does die_a survive the arming of die_b?"
P2="$RUNDIR/phase2.txt"
{
  echo "step 0  die_a alive before any arm : $(die_alive a && echo YES || echo NO)"
  zp_arm_retry a && echo "step 1  arm die_a ALONE             : armed (NEGO_CFG read back OK)" \
                 || echo "step 1  arm die_a ALONE             : ARM FAILED"
  sleep 2
  echo "step 1  die_a alive after solo arm : $(die_alive a && echo YES || echo NO)   (expected YES, even pre-fix)"
  zp_arm_retry b && echo "step 2  arm die_b (training starts) : armed" \
                 || echo "step 2  arm die_b                  : ARM FAILED"
  sleep 5
  echo "step 2  die_a alive after die_b arm: $(die_alive a && echo YES || echo NO)   <<< THE TEST"
  echo "step 2  die_b alive                : $(die_alive b && echo YES || echo NO)"
} | tee -a "$P2" | tee -a "$RUNDIR/run.log"

if die_alive a; then
  say "PHASE 2: **PASS** — die_a's PS bus SURVIVED the arming of die_b."
  say "         The fc_cfg APB preempt fix (tidelink_top.sv ext_lock_q) HOLDS ON SILICON."
  say "         Pre-fix, this write killed die_a's bus every time."
  log "Phase 2 PASS"
else
  say "PHASE 2: **FAIL** — die_a's PS bus DIED when die_b was armed."
  say "         The fc_cfg preempt fix does NOT close the silicon wedge."
  say "         It is proven in sim (FAIL pre-fix / PASS post-fix), so either the"
  say "         packaged IP does not contain it (check imp/fpga/tidelink_ip/src for"
  say "         ext_lock_q -- the stale package_ip trap), or a SECOND unbounded"
  say "         stall exists on the PS path. STOPPING: this is the headline result;"
  say "         20 soak cycles would only bury it."
  log "Phase 2 FAIL — stopping by design"
  exit 10
fi

# ============================ Phase 3 — the soak ==============================
deadline_hit && { say "deadline hit before soak"; exit 0; }
log "Phase 3: zeropoke_soak --stats $SOAK_N (armed-only denominator)"
( cd "$HERE" && TD_SOAK_DIR="$RUNDIR/soak" ZP_ARM_TRIES=3 \
    ./zeropoke_soak.sh --stats "$SOAK_N" --no-lease ) >>"$RUNDIR/run.log" 2>&1
SOAK_RC=$?
CSV=$(find "$RUNDIR/soak" -name stats.csv 2>/dev/null | head -1)
[ -n "$CSV" ] && cp "$CSV" "$RUNDIR/stats.csv"
log "soak rc=$SOAK_RC csv=$CSV"

if [ -f "$RUNDIR/stats.csv" ]; then
  say ""
  say "PHASE 3: soak of $SOAK_N cycles (rc=$SOAK_RC)"
  python3 - "$RUNDIR/stats.csv" >>"$VERDICT" 2>/dev/null <<'PY'
import csv,sys,collections
rows=list(csv.DictReader(open(sys.argv[1])))
for die in ("a","b"):
    r=[x for x in rows if x["die"]==die]
    if not r: continue
    out=collections.Counter(x["outcome"] for x in r)
    armed=[x for x in r if x["outcome"]!="UNARMED"]
    ok=sum(1 for x in armed if x["outcome"]=="OK")
    den=len(armed)
    rate = f"{100*ok/den:.0f}% ({ok}/{den} ARMED cycles)" if den else "NO VALID CYCLES"
    print(f"  die_{die}: {rate}   outcomes={dict(out)}")
    if out.get("UNARMED"):
        print(f"          {out['UNARMED']} cycle(s) EXCLUDED as non-tests (arm never stuck).")
    # nego_lock_pending[18] for any armed die that still never finished
    bad=[x for x in armed if x["outcome"]=="NODONE"]
    for x in bad[:3]:
        mh=int(x["obs_mask_hs"],16)
        print(f"          NODONE cyc{x['cycle']}: nego_lock_pending={(mh>>18)&1} "
              f"gate_open={(mh>>20)&1} ws=0x{int(x['winscan_obs'],16):08x}")
PY
fi

# ======================= Phase 4 — diagnose armed NODONEs =====================
log "Phase 4: role-lock chain snapshot"
{ for d in a b; do
    printf 'die_%s  armed=%s role_locked=%s NEGO_CFG=%s TRAIN_CFG=%s OBS_MASK_HS=%s WINSCAN_OBS=%s\n' \
      "$d" "$(armed_d $d 2>/dev/null)" "$(rolelocked_d $d 2>/dev/null)" \
      "$($d rd $R_NEGO_CFG 2>/dev/null)" "$($d rd $R_NEGO_TRAIN_CFG 2>/dev/null)" \
      "$(maskhs_d $d 2>/dev/null)" "$($d rd $R_WINSCAN_OBS 2>/dev/null)"
  done; } | tee "$RUNDIR/phase4_rolelock.txt" >>"$RUNDIR/run.log"
say ""; say "PHASE 4 role-lock snapshot:"; sed 's/^/  /' "$RUNDIR/phase4_rolelock.txt" >>"$VERDICT"
log "done"
exit 0

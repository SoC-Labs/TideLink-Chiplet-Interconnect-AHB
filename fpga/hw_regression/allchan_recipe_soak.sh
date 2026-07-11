#!/bin/bash
# =============================================================================
# allchan_recipe_soak.sh — N INDEPENDENT fresh-POR trials of RECIPE-mode
# bring-up + EVERY channel byte-exact, reported as a certifiable reliability
# number (pass count + Clopper-Pearson 95% CI).
#
# WHY THIS EXISTS
#   td_v2_channels.sh's --pors is a RETRY-until-linkup knob, not N independent
#   trials — it gives one bring-up N chances then tests channels ONCE. For the
#   deliverable ("all channels working reliably, PROVEN on the z2") we need the
#   opposite: N *independent* bring-ups, each scored all-pass/fail, so X/N is a
#   real reliability estimate. This wraps the proven per-trial engine
#   (td_v2_channels.sh) in that independent-trial loop.
#
# TRIAL INDEPENDENCE (--reset)
#   power  (default, RIGOROUS): each trial = power-cycle BOTH boards (true POR,
#          PL emptied) -> deploy both bins -> recipe bring-up -> all channels.
#          The only defensible fresh-POR trial; ~75 s/cycle. Uses the memory-
#          proven SAFE order (power-cycle -> deploy on a quiescent board; never
#          reload the PL on a live link).
#   soft   (FAST interim read): each trial = quiesce -> re-run recipe (its R8
#          SYNC->RECAL->SYNC re-runs cal+SYNC-detect+anchor) -> all channels.
#          Shares PHY analog state across trials; independence is WEAKER — do
#          NOT certify from soft numbers without first confirming on hardware
#          that a soft re-run genuinely re-runs the anchor lottery (does not
#          trivially re-confirm a still-up link). Guarded by a periodic
#          power-cycle every --power-every K cycles.
#
# RUNS ON the lab host (mapstone-dev) — it power-cycles via fpgahub, deploys via
# $HOME/deploy_pair.sh, and delegates bring-up+channels to td_v2_channels.sh in
# the same dir. Stage with stage_and_run.sh (rsync) or run in-place on the host.
#
# USAGE
#   ./allchan_recipe_soak.sh [--cycles N] [--mode manual|autonomous]
#         [--channels "data doorbell xhb"] [--reset power|soft]
#         [--power-every K] [--no-lease] [--keep] [--budget SEC] [--dry-run]
#   Exit 0 iff the run COMPLETED (not iff 100% pass); the number is the product.
#   Env: TD_HUB_A TD_HUB_B TD_DEPLOY_DIR TD_MASTER_IP TD_SLAVE_IP TD_LEASE
# =============================================================================
set -u

# ----- CLI ------------------------------------------------------------------
CYCLES=30
MODE=manual
CHANNELS="data doorbell xhb"
RESET=power
POWER_EVERY=8
DO_LEASE=1
KEEP_LEASE=0
BUDGET=0            # 0 = no wall-clock cap
DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --cycles)      CYCLES="$2"; shift;;
  --mode)        MODE="$2"; shift;;
  --channels)    CHANNELS="$2"; shift;;
  --reset)       RESET="$2"; shift;;
  --power-every) POWER_EVERY="$2"; shift;;
  --no-lease)    DO_LEASE=0;;
  --keep)        KEEP_LEASE=1;;
  --budget)      BUDGET="$2"; shift;;
  --dry-run)     DRY=1; DO_LEASE=0;;
  -h|--help)     sed -n '2,45p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see -h)"; exit 2;;
esac; shift; done
case "$MODE"  in manual|autonomous) ;; *) echo "bad --mode: $MODE";  exit 2;; esac
case "$RESET" in power|soft) ;;        *) echo "bad --reset: $RESET"; exit 2;; esac
case "$CYCLES" in ''|*[!0-9]*) echo "bad --cycles: $CYCLES"; exit 2;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/td_v2_channels.sh"
[ "$DRY" = 0 ] && { [ -x "$ENGINE" ] || { echo "missing per-trial engine: $ENGINE"; exit 2; }; }

HUB_A=${TD_HUB_A:-pynq_z2_02_ps}     # die_a PDU port (note _ps; _pl 404s)
HUB_B=${TD_HUB_B:-pynq_z2_01_pl}     # die_b PDU port (note _pl)
DEPLOY_DIR=${TD_DEPLOY_DIR:-/tmp/tidelink_deploy_l7}
DEPLOY_SH=${TD_DEPLOY_SH:-$HOME/deploy_pair.sh}
A_IP=${TD_MASTER_IP:-192.168.4.101}; A_BOARD=${TD_MASTER_BOARD:-z2_02}
B_IP=${TD_SLAVE_IP:-192.168.2.101};  B_BOARD=${TD_SLAVE_BOARD:-z2_01}
LEASE_NAME=${TD_LEASE:-bridge1}
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
CSV="allchan_recipe_soak_${STAMP}.csv"
START=$SECONDS

# ----- lease (verify GRANTED, never queued) ---------------------------------
LEASE_TOK=""
lease_acquire(){ local out
  out=$(fpgahub pair lease acquire "$LEASE_NAME" --ttl 4200 --json 2>/dev/null)
  LEASE_TOK=$(printf '%s' "$out" | grep -o '"token"[^,]*' | grep -o '[0-9a-f-]\{8,\}' | head -1)
  printf '%s' "$out" | grep -qiE '"state"\s*:\s*"granted"|granted' && [ -n "$LEASE_TOK" ]
}
lease_release(){ [ -n "$LEASE_TOK" ] && fpgahub pair lease release "$LEASE_NAME" --token "$LEASE_TOK" >/dev/null 2>&1; }
finish(){ local rc=$?; [ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release; exit $rc; }
trap finish EXIT INT TERM

# ----- power-cycle + deploy (the SAFE order) --------------------------------
power_cycle_one(){ local hub="$1"
  fpgahub hub power-cycle "$hub" --off 2 --yes >/dev/null 2>&1 || { echo "  power-cycle FAILED: $hub"; return 1; }
}
wait_ssh(){ local ip="$1" i
  for i in $(seq 1 40); do ssh -o ConnectTimeout=3 -o BatchMode=yes "xilinx@$ip" true >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}
power_cycle_pair(){
  power_cycle_one "$HUB_A" & power_cycle_one "$HUB_B" & wait
  wait_ssh "$A_IP" && wait_ssh "$B_IP" || { echo "  a board did not return from power-cycle"; return 1; }
}
deploy_pair(){
  "$DEPLOY_SH" "$A_IP" "$A_BOARD" die_a "$DEPLOY_DIR" --no-verify >/dev/null 2>&1
  "$DEPLOY_SH" "$B_IP" "$B_BOARD" die_b "$DEPLOY_DIR" --no-verify >/dev/null 2>&1
}

# ----- run one independent trial; echo PASS|FAIL --------------------------
run_trial(){ local n="$1" want_power="$2"
  if [ "$DRY" = 1 ]; then
    # deterministic pseudo-outcome for logic self-test: ~80% pass, no hardware.
    [ $(( (n*7+3) % 10 )) -lt 8 ] && echo PASS || echo "FAIL:data"; return 0
  fi
  if [ "$want_power" = 1 ]; then
    power_cycle_pair || { echo "FAIL:power"; return 0; }
    deploy_pair
  fi
  # per-trial engine: recipe bring-up + all channels, ONE bring-up attempt.
  if "$ENGINE" --mode "$MODE" --channels "$CHANNELS" --pors 1 --no-lease >"trial_${STAMP}_$n.log" 2>&1; then
    echo PASS
  else
    # surface which channel(s) failed from the engine's per-channel report
    local f; f=$(grep -oE "FAIL [a-z]+" "trial_${STAMP}_$n.log" 2>/dev/null | awk '{print $2}' | paste -sd, -)
    echo "FAIL:${f:-unknown}"
  fi
}

# ----- Clopper-Pearson 95% CI (exact binomial, pure-python: no scipy) --------
clopper_pearson(){ python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys, math
def betacf(a,b,x):
    MAXIT,EPS,FPMIN=200,3e-16,1e-300
    qab,qap,qam=a+b,a+1.0,a-1.0
    c=1.0; d=1.0-qab*x/qap
    if abs(d)<FPMIN: d=FPMIN
    d=1.0/d; h=d
    for m in range(1,MAXIT+1):
        m2=2*m
        aa=m*(b-m)*x/((qam+m2)*(a+m2))
        d=1.0+aa*d; d=FPMIN if abs(d)<FPMIN else d
        c=1.0+aa/c; c=FPMIN if abs(c)<FPMIN else c
        d=1.0/d; h*=d*c
        aa=-(a+m)*(qab+m)*x/((a+m2)*(qap+m2))
        d=1.0+aa*d; d=FPMIN if abs(d)<FPMIN else d
        c=1.0+aa/c; c=FPMIN if abs(c)<FPMIN else c
        d=1.0/d; de=d*c; h*=de
        if abs(de-1.0)<EPS: break
    return h
def betai(a,b,x):  # regularized incomplete beta I_x(a,b)
    if x<=0: return 0.0
    if x>=1: return 1.0
    lbeta=math.lgamma(a+b)-math.lgamma(a)-math.lgamma(b)
    bt=math.exp(lbeta+a*math.log(x)+b*math.log(1.0-x))
    return bt*betacf(a,b,x)/a if x<(a+1.0)/(a+b+2.0) else 1.0-bt*betacf(b,a,1.0-x)/b
def betainv(p,a,b):  # bisection inverse of I_x(a,b)=p
    lo,hi=0.0,1.0
    for _ in range(100):
        mid=(lo+hi)/2.0
        if betai(a,b,mid)<p: lo=mid
        else: hi=mid
    return (lo+hi)/2.0
k,n=int(sys.argv[1]),int(sys.argv[2])
if n==0: print("n=0"); sys.exit(0)
lo=0.0 if k==0 else betainv(0.025,k,n-k+1)
hi=1.0 if k==n else betainv(0.975,k+1,n-k)
print("%.1f%% [%.1f%%, %.1f%%] (Clopper-Pearson 95%%)"%(100.0*k/n,100.0*lo,100.0*hi))
PY
}

# ----- lease up -------------------------------------------------------------
if [ "$DO_LEASE" = 1 ]; then
  echo "-- acquiring lease '$LEASE_NAME' (verify GRANTED) --"
  lease_acquire || { echo "### lease NOT granted (queued or error) — refusing to touch boards"; exit 1; }
  echo "   lease GRANTED (token ${LEASE_TOK:0:8}...)"
fi

# ----- soak loop ------------------------------------------------------------
echo "=========================================================="
echo " allchan_recipe_soak  mode=$MODE reset=$RESET cycles=$CYCLES"
echo "   channels='$CHANNELS'  power-every=$POWER_EVERY  dry=$DRY"
echo "=========================================================="
echo "cycle,reset,verdict,detail,elapsed_s" > "$CSV"
PASS=0; DONE=0
for n in $(seq 1 "$CYCLES"); do
  if [ "$BUDGET" -gt 0 ] && [ $((SECONDS-START)) -ge "$BUDGET" ]; then
    echo "-- budget ${BUDGET}s reached at cycle $n; stopping --"; break
  fi
  want_power=0
  if [ "$RESET" = power ]; then want_power=1
  elif [ "$RESET" = soft ] && [ $(( (n-1) % POWER_EVERY )) -eq 0 ]; then want_power=1; fi
  t0=$SECONDS
  v=$(run_trial "$n" "$want_power")
  dt=$((SECONDS-t0))
  DONE=$((DONE+1))
  case "$v" in PASS) PASS=$((PASS+1)); tag="PASS";; *) tag="$v";; esac
  printf 'ALLCHAN_CYCLE %d/%d reset=%s -> %-14s (%ds)\n' "$n" "$CYCLES" "$([ $want_power = 1 ] && echo POR || echo soft)" "$tag" "$dt"
  echo "$n,$([ $want_power = 1 ] && echo POR || echo soft),${v%%:*},${v#*:},$dt" >> "$CSV"
done

# ----- verdict --------------------------------------------------------------
echo "=========================================================="
echo " RESULT: $PASS/$DONE all-channel PASS   $(clopper_pearson "$PASS" "$DONE")"
echo "   csv: $CSV"
echo "=========================================================="
exit 0

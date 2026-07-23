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

# ----- provenance: key every result to the bitstream that produced it --------
# The verification plan mandates it ("autonomy % without a named bitstream md5 is
# meaningless") and it was enforced nowhere: no run artefact was archived, so every
# hardware claim in this repo existed only as prose and could not be reproduced or
# defended. BITSTREAM_MD5 is captured up-front and stamped into the CSV name, a
# header comment, and every row.
bitstream_md5(){ local f
  for f in "$DEPLOY_DIR"/*.bit "$DEPLOY_DIR"/*.bit.bin "$DEPLOY_DIR"/*.bin; do
    [ -f "$f" ] && { md5sum "$f" 2>/dev/null | cut -c1-12; return; }
  done
  echo "nobitstream"
}
if [ "$DRY" = 1 ]; then BITSTREAM_MD5="SYNTHETIC"; else BITSTREAM_MD5="$(bitstream_md5)"; fi

# --dry-run fabricates outcomes with NO hardware (see run_trial). Its output used
# to be byte-indistinguishable from a real run -- same filename pattern, a genuine
# Clopper-Pearson CI over invented data. Anything synthetic is now labelled in the
# filename, the header and every row, so it can never be mistaken for evidence.
if [ "$DRY" = 1 ]; then
  CSV="SYNTHETIC_allchan_recipe_soak_${STAMP}.csv"
else
  CSV="allchan_recipe_soak_${STAMP}_bs-${BITSTREAM_MD5}.csv"
fi

# ARCHIVE_DIR: committed evidence, keyed by bitstream. Set TD_ARCHIVE_DIR=none to
# opt out. Synthetic runs are never archived as evidence.
ARCHIVE_DIR=${TD_ARCHIVE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/results/allchan_recipe_soak}

{
  echo "# tidelink allchan_recipe_soak"
  echo "# synthetic=$([ "$DRY" = 1 ] && echo YES-NO-HARDWARE || echo no)"
  echo "# bitstream_md5=$BITSTREAM_MD5"
  echo "# started=$STAMP  master=$A_IP($A_BOARD)  slave=$B_IP($B_BOARD)"
  echo "# git=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "cycle,reset,verdict,detail,elapsed_s,bitstream_md5,synthetic"
} > "$CSV"
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
BOARD_PW=${TD_BOARD_PW:-xilinx}
# Board login — one knob, defaults to xilinx (the PYNQ-Z2 image) so Z2 runs are
# unchanged; set TD_BOARD_USER for images that use a different login.
BOARD_USER=${TD_BOARD_USER:-xilinx}
wait_ssh(){ local ip="$1" i
  # boards are password-auth (sshpass), NOT key/BatchMode — match td_v2_hwlib.sh
  for i in $(seq 1 40); do
    sshpass -p "$BOARD_PW" ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=4 "$BOARD_USER@$ip" true >/dev/null 2>&1 && return 0
    sleep 2
  done
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
[ "$DRY" = 1 ] && echo " *** --dry-run: NO HARDWARE. Outcomes are FABRICATED (~80% pass). ***"
echo "   bitstream_md5=$BITSTREAM_MD5   csv=$CSV"
echo "=========================================================="
# NOTE: the CSV header + provenance block is written at setup (see BITSTREAM_MD5).
# Do NOT re-write it here with '>' -- that truncated the provenance away.
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
  echo "$n,$([ $want_power = 1 ] && echo POR || echo soft),${v%%:*},${v#*:},$dt,$BITSTREAM_MD5,$([ "$DRY" = 1 ] && echo SYNTHETIC || echo hw)" >> "$CSV"
done

# ----- verdict --------------------------------------------------------------
echo "=========================================================="
if [ "$DRY" = 1 ]; then
  echo " *** SYNTHETIC RUN — NO HARDWARE. The numbers below are FABRICATED."
  echo " *** Do NOT quote this as evidence; the CI is computed over invented data."
fi
echo " RESULT: $PASS/$DONE all-channel PASS   $(clopper_pearson "$PASS" "$DONE")"
echo "   bitstream_md5: $BITSTREAM_MD5"
echo "   csv: $CSV"

# ----- archive the evidence -------------------------------------------------
# Without this the run leaves nothing behind and the result survives only as prose
# in a markdown file — which is why no hardware claim in this repo is currently
# reproducible. Synthetic runs are deliberately NOT archived.
if [ "$DRY" = 1 ]; then
  echo "   archive: skipped (synthetic)"
elif [ "$ARCHIVE_DIR" = none ]; then
  echo "   archive: disabled (TD_ARCHIVE_DIR=none)"
elif [ "$BITSTREAM_MD5" = nobitstream ]; then
  echo "   archive: SKIPPED — no bitstream found under $DEPLOY_DIR, result is unattributable"
else
  if mkdir -p "$ARCHIVE_DIR" 2>/dev/null && cp "$CSV" "$ARCHIVE_DIR/" 2>/dev/null; then
    echo "   archive: $ARCHIVE_DIR/$(basename "$CSV")"
    echo "   ^ commit this: a result without an archived, md5-keyed CSV is not evidence."
  else
    echo "   archive: FAILED to write $ARCHIVE_DIR (result not persisted)"
  fi
fi
echo "=========================================================="

# NOTE ON EXIT STATUS: this is deliberately 0 on a completed sweep — the soak
# MEASURES a proportion, it does not assert one, and callers treat a non-zero exit
# as "the sweep broke". To use it as a gate, set TD_SOAK_MIN_PASS (e.g. 90) and it
# will fail when the Clopper-Pearson LOWER bound falls below that percentage.
if [ -n "${TD_SOAK_MIN_PASS:-}" ] && [ "$DRY" != 1 ]; then
  # Output looks like: "80.0% [28.4%, 99.5%] (Clopper-Pearson 95%)".
  # Gate on the CI LOWER bound (the bracketed first number), NEVER the point
  # estimate — gating on the point estimate is the "round 91% up to 95%" error the
  # verification plan explicitly warns against, and it is the permissive direction.
  lo=$(clopper_pearson "$PASS" "$DONE" | sed -n 's/.*\[\([0-9.]*\)%.*/\1/p')
  if [ -n "$lo" ] && awk "BEGIN{exit !($lo < $TD_SOAK_MIN_PASS)}"; then
    echo " GATE FAIL: CI-lower ${lo}% < TD_SOAK_MIN_PASS=${TD_SOAK_MIN_PASS}%"
    exit 1
  fi
  echo " GATE PASS: CI-lower ${lo}% >= TD_SOAK_MIN_PASS=${TD_SOAK_MIN_PASS}%"
fi
exit 0

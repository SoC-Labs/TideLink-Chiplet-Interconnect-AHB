#!/bin/bash
# =============================================================================
# proven_method_soak.sh — N INDEPENDENT fresh-POR trials scoring the channels
# that are SILICON-PROVEN to work, via the PROVEN recipe (not the raw ring).
#
# Per trial (true fresh POR): power-cycle BOTH -> deploy -> rcp bring-up ->
# wait reanchored -> enter_data_mode (R8=0x10, SYNC stripped) -> send_a2b
# (framed header+payload) -> verify GP1 RX 0x84010000 BYTE-EXACT -> doorbell
# both directions. Reports link/data/doorbell pass counts + all-3 Clopper-Pearson.
#
# WHY not td_v2_channels.sh: its 28-word RAW ring omits the packet header and
# (pre-fix) left SYNC_EN on -> false data failures. The framed send_a2b path is
# the method proven byte-exact on silicon 2026-07-11. XHB is EXCLUDED — it needs
# the data return path and wedges die_a's PS on a marginal beat (recover only by
# power-cycle); score it separately once the data path is hardened.
#
# Runs ON the lab host. Sources td_v2_hwlib.sh for the proven primitives.
#   ./proven_method_soak.sh [N]        (default 6)
#   env: TD_HUB_A TD_HUB_B TD_DEPLOY_DIR TD_DEPLOY_SH TD_MASTER_IP TD_SLAVE_IP
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

N=${1:-6}
# TD_AUTONOMOUS=1 => TRUE ZERO-POKE bring-up: issue NO pokes at all. The bitstream
# carries NEGO_CFG_RESET=0x61 and LANE_MASK_RESET=0xE4 as PARAMETERS, so autonomy
# self-arms at POR. We only READ BACK the arm (NEGO_CFG[0] & NEGO_TRAIN_CFG[0] =>
# autonomy_armed) and then poll for convergence. A cycle where the die was NOT armed
# is a NON-TEST and is excluded from the denominator — an unarmed die never runs the
# winscan, so scoring it as a failure would slander the FSM (this exact mistake was
# made for months when NEGO_CFG's POR was 0x00).
# Default (TD_AUTONOMOUS=0) = rcp(), the manual recipe, autonomy OFF.
AUTONOMOUS=${TD_AUTONOMOUS:-0}
AUTO_WAIT=${TD_AUTO_WAIT:-45}       # seconds to let autonomy converge
R_NEGO_CFG_A=0x44032090
R_NEGO_TRAIN_A=0x4403210C
HUB_A=${TD_HUB_A:-pynq_z2_02_ps}
HUB_B=${TD_HUB_B:-pynq_z2_01_pl}
BOARD_PW=${TD_BOARD_PW:-xilinx}
R_DOORBELL=0x44032014
R_DOORBELL_ACC=0x44032024
EXP=(0x00240000 0xcafe0001 0xcafe0002 0xcafe0003)   # TX_HDR + TX_PAYLOAD
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
CSV="proven_method_soak_${STAMP}.csv"

pc_one(){ fpgahub hub power-cycle "$1" --off 2 --yes >/dev/null 2>&1; }
wait_ssh(){ local ip="$1" i
  for i in $(seq 1 40); do
    sshpass -p "$BOARD_PW" ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=4 "$BOARD_USER@$ip" true >/dev/null 2>&1 && return 0
    sleep 2
  done; return 1
}
por(){ pc_one "$HUB_A" & pc_one "$HUB_B" & wait; wait_ssh "$A_IP" && wait_ssh "$B_IP"; }

# byte-exact GP1 RX check after a fresh send_a2b (receiver = die_b)
data_ok(){ local i w
  for i in 0 1 2 3; do
    w=$(printf '0x%08x' $(( $(gp1_rx $i) )) 2>/dev/null)
    [ "$w" = "${EXP[$i]}" ] || return 1
  done; return 0
}
# B->A: die_b sends the same framed packet; receiver = die_a's GP1 RX aperture
send_b2a(){ b txburst $TX_HDR ${TX_PAYLOAD[*]} >/dev/null 2>&1; }
data_b2a_ok(){ local i w
  for i in 0 1 2 3; do
    w=$(printf '0x%08x' $(( $(gp1_rx_d a $i) )) 2>/dev/null)
    [ "$w" = "${EXP[$i]}" ] || return 1
  done; return 0
}
doorbell_ok(){ local a2s s2a
  b rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep 0.2      # clear
  a wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  a2s=$(( $(b rd $R_DOORBELL_ACC) ))
  a rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep 0.2
  b wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  s2a=$(( $(a rd $R_DOORBELL_ACC) ))
  [ "$a2s" -gt 0 ] && [ "$s2a" -gt 0 ]
}

clopper_pearson(){ python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys, math
def betacf(a,b,x):
    FPMIN=1e-300; qab,qap,qam=a+b,a+1.0,a-1.0; c=1.0; d=1.0-qab*x/qap
    d=FPMIN if abs(d)<FPMIN else d; d=1.0/d; h=d
    for m in range(1,300):
        m2=2*m; aa=m*(b-m)*x/((qam+m2)*(a+m2))
        d=1.0+aa*d; d=FPMIN if abs(d)<FPMIN else d
        c=1.0+aa/c; c=FPMIN if abs(c)<FPMIN else c
        d=1.0/d; h*=d*c
        aa=-(a+m)*(qab+m)*x/((a+m2)*(qap+m2))
        d=1.0+aa*d; d=FPMIN if abs(d)<FPMIN else d
        c=1.0+aa/c; c=FPMIN if abs(c)<FPMIN else c
        d=1.0/d; de=d*c; h*=de
        if abs(de-1.0)<3e-16: break
    return h
def I(a,b,x):
    if x<=0: return 0.0
    if x>=1: return 1.0
    bt=math.exp(math.lgamma(a+b)-math.lgamma(a)-math.lgamma(b)+a*math.log(x)+b*math.log(1-x))
    return bt*betacf(a,b,x)/a if x<(a+1)/(a+b+2) else 1-bt*betacf(b,a,1-x)/b
def inv(p,a,b):
    lo,hi=0.0,1.0
    for _ in range(100):
        m=(lo+hi)/2
        if I(a,b,m)<p: lo=m
        else: hi=m
    return (lo+hi)/2
k,n=int(sys.argv[1]),int(sys.argv[2])
if n==0: print("n=0"); sys.exit()
lo=0.0 if k==0 else inv(0.025,k,n-k+1); hi=1.0 if k==n else inv(0.975,k+1,n-k)
print("%.1f%% [%.1f%%, %.1f%%]"%(100.0*k/n,100.0*lo,100.0*hi))
PY
}

MODE_STR=$([ "$AUTONOMOUS" = 1 ] && echo "ZERO-POKE AUTONOMOUS (no writes; POR-armed)" || echo "RECIPE (rcp; autonomy OFF)")
echo "=========================================================="
echo " proven_method_soak  N=$N"
echo "   bring-up: $MODE_STR"
echo "   channels: link + A->B + B->A (framed, byte-exact) + doorbell"
echo "=========================================================="
echo "cycle,link,a2b,b2a,doorbell,fcsm_a,fcsm_b,rea_a,rea_b,elapsed_s" > "$CSV"
LINK=0; DATA=0; B2A=0; DB=0; ALL=0; DONE=0
for n in $(seq 1 "$N"); do
  t0=$SECONDS
  if ! por; then echo "ALLCHAN_CYCLE $n/$N -> POR-FAIL (a board did not return)"; continue; fi
  deploy_pair; sleep 2
  armed=1
  if [ "$AUTONOMOUS" = 1 ]; then
    # ---- TRUE ZERO-POKE: no writes. Read back the POR arm, then poll. ----
    ca=$(( $(a rd $R_NEGO_CFG_A) & 0x7f )); cb=$(( $(b rd $R_NEGO_CFG_A) & 0x7f ))
    ta=$(( $(a rd $R_NEGO_TRAIN_A) & 1 ));  tb=$(( $(b rd $R_NEGO_TRAIN_A) & 1 ))
    aa=0; [ $(( ca & 1 )) -eq 1 ] && [ "$ta" -eq 1 ] && aa=1
    ab=0; [ $(( cb & 1 )) -eq 1 ] && [ "$tb" -eq 1 ] && ab=1
    if [ "$aa" -ne 1 ] || [ "$ab" -ne 1 ]; then
      armed=0
      printf 'ALLCHAN_CYCLE %d/%d -> UNARMED (NEGO_CFG a=0x%02x b=0x%02x train a=%s b=%s) — NON-TEST, excluded\n' \
        "$n" "$N" "$ca" "$cb" "$ta" "$tb"
      echo "$n,UNARMED,,,,,," >> "$CSV"
      continue
    fi
    for i in $(seq 1 "$AUTO_WAIT"); do
      sleep 1
      [ "$(reanchored_d a)" = 1 ] && [ "$(reanchored_d b)" = 1 ] \
        && [ "$(fcsm a)" = 4 ] && [ "$(fcsm b)" = 4 ] && break
    done
  else
    rcp
    for i in $(seq 1 8); do sleep 1; [ "$(reanchored)" = 1 ] && break; done
  fi
  fa=$(fcsm a); fb=$(fcsm b); rea=$(reanchored)
  ra=$(reanchored_d a); rb=$(reanchored_d b)
  lk=0; [ "$fa" = 4 ] && [ "$fb" = 4 ] && [ "$ra" = 1 ] && [ "$rb" = 1 ] && lk=1
  enter_data_mode
  # NO pre-send drain: fresh POR => RX FIFO empty, and `rxn` pops/advances the
  # FIFO pointer which misaligns the fixed-address gp1_rx read (silicon 2026-07-11:
  # draining before send_a2b made gp1_rx[0..3] read stale -> data=0 despite a
  # byte-exact transfer). Read the aperture directly, exactly like the proven test.
  send_a2b; sleep 1.5
  dt_ok=0; data_ok && dt_ok=1
  send_b2a; sleep 1.5
  b2a_ok=0; data_b2a_ok && b2a_ok=1
  db_ok=0; doorbell_ok && db_ok=1
  dt=$((SECONDS-t0)); DONE=$((DONE+1))
  [ "$lk" = 1 ] && LINK=$((LINK+1))
  [ "$dt_ok" = 1 ] && DATA=$((DATA+1))
  [ "$b2a_ok" = 1 ] && B2A=$((B2A+1))
  [ "$db_ok" = 1 ] && DB=$((DB+1))
  [ "$lk" = 1 ] && [ "$dt_ok" = 1 ] && [ "$b2a_ok" = 1 ] && [ "$db_ok" = 1 ] && ALL=$((ALL+1))
  printf 'ALLCHAN_CYCLE %d/%d -> link=%s a2b=%s b2a=%s doorbell=%s (fcsm %s/%s rea_a=%s rea_b=%s) %ds\n' \
    "$n" "$N" "$lk" "$dt_ok" "$b2a_ok" "$db_ok" "$fa" "$fb" "$ra" "$rb" "$dt"
  echo "$n,$lk,$dt_ok,$b2a_ok,$db_ok,$fa,$fb,$ra,$rb,$dt" >> "$CSV"
done
echo "=========================================================="
echo " link:     $LINK/$DONE  $(clopper_pearson "$LINK" "$DONE")"
echo " data A->B: $DATA/$DONE  $(clopper_pearson "$DATA" "$DONE")"
echo " data B->A: $B2A/$DONE  $(clopper_pearson "$B2A" "$DONE")"
echo " doorbell: $DB/$DONE  $(clopper_pearson "$DB" "$DONE")"
echo " ALL-4:    $ALL/$DONE  $(clopper_pearson "$ALL" "$DONE")"
echo " csv: $CSV"
echo "=========================================================="
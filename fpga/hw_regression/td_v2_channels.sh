#!/bin/bash
# =============================================================================
# td_v2_channels.sh — TideLink V2 CANONICAL on-silicon multi-channel regression
#
# Supersedes the ~245 hand-rolled one-shot bring-up/probe scripts that ride on
# mapstone-dev, and updates fpga/hw_regression/td_v2_regress.sh (2026-06-26,
# pre-deterministic-linkup) with the CURRENT proven July methodology:
#
#   * DETERMINISTIC link-up (no "eye lottery" --rolls retry loop). The July
#     deterministic-linkup work killed the bring-up lottery: R8 uses 0x1C
#     (bit0 CLEAR) as the sync/data base — bit0 (swi_training_mode) set was the
#     silent S_HOLD trap that made link-up a coin-flip. A POR-count still exists
#     but as a soak/robustness knob, NOT a retry-until-lucky loop.
#   * CORRECT register map (see REGS below). In particular autoneg is armed via
#     the RW NEGO_CFG at 0x44032090 — NOT the read-only status alias 0x44032110.
#   * Two bring-up modes: `manual` (deterministic poke recipe) and `autonomous`
#     (arm-once NEGO_CFG=0x61, longer poll to absorb the div-2 link clock).
#   * Channel gates run in a WEDGE-SAFE order (see main): cal=1 -> tl-data both
#     directions (rotation-aware ring compare) -> doorbell -> XHB transparent
#     window (timeout-wrapped, bounded, ONLY after data is proven).
#
# Runs ON a lab host that can SSH the PYNQ pair (e.g. mapstone-dev). Assumes
# tl39.py is already staged on both boards (TL39 path, default /home/xilinx).
# Does NOT hardcode mapstone-dev-only paths; boards + paths are env-overridable.
# Structure mirrors td_v2_regress.sh / td_v2_hwlib.sh and the canonical bring-up
# pynq_host/scripts/bringup_autocal_i2c.sh (autonomous NEGO_CFG=0x61) — build ON
# them; this file is self-contained so the July register map cannot drift back
# to the June (bit0-set) recipe.
#
# HARDWARE-SAFETY (z2_02 AHB-wedge discipline) baked in:
#   * every board register READ is THROTTLE-sleeved (no tight host<->ssh loops
#     — dense PS mmap access wedges the kernel, needs a physical power-cycle);
#   * NO premature AHB_TX writes — data is only pushed AFTER cal=1 gates PASS;
#   * XHB transparent-window reads are `timeout`-wrapped and TXN-BOUNDED, run
#     LAST and only if tl-data proved the datapath (the new ahb_sub HREADY
#     timeout backstop, cb33c9f, makes a window stall recoverable, but we still
#     bound it rather than trust the backstop alone);
#   * the window soak is BOUNDED (WIN_SOAK_TXNS), never unbounded.
#
# USAGE:
#   ./td_v2_channels.sh [--mode manual|autonomous] [--channels "data doorbell xhb"]
#                       [--pors N] [--no-lease] [--keep] [-h]
#   Env overrides: TD_MASTER_IP TD_SLAVE_IP TD_MASTER_BOARD TD_SLAVE_BOARD
#                  TD_TL39 TD_THROTTLE TD_BOARD_PW TD_LEASE TD_SSH_TIMEOUT
# Exit code: 0 = every selected channel PASS, 1 = any FAIL/abort (CI gate).
# =============================================================================
set -u

# ----- CLI ------------------------------------------------------------------
MODE=manual
CHANNELS="data doorbell xhb"
PORS=1
DO_LEASE=1
KEEP_LEASE=0
while [ $# -gt 0 ]; do case "$1" in
  --mode)     MODE="$2"; shift;;
  --channels) CHANNELS="$2"; shift;;
  --pors)     PORS="$2"; shift;;
  --no-lease) DO_LEASE=0;;
  --keep)     KEEP_LEASE=1;;
  -h|--help)  sed -n '2,40p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see -h)"; exit 2;;
esac; shift; done
case "$MODE" in manual|autonomous) ;; *) echo "bad --mode: $MODE"; exit 2;; esac

# ----- board / topology config (override via env) ---------------------------
MASTER_IP=${TD_MASTER_IP:-192.168.4.101}   # die_a: master / non-flip (A->B sender)
SLAVE_IP=${TD_SLAVE_IP:-192.168.2.101}      # die_b: slave  / flip     (A->B receiver)
MASTER_BOARD=${TD_MASTER_BOARD:-z2_02}
SLAVE_BOARD=${TD_SLAVE_BOARD:-z2_01}
TL39=${TD_TL39:-/home/xilinx/tl39.py}
LEASE_NAME=${TD_LEASE:-bridge1}
THROTTLE=${TD_THROTTLE:-0.25}               # sleep between board reads (PS-wedge guard)
SSH_TIMEOUT=${TD_SSH_TIMEOUT:-10}           # per-call ssh wall-clock timeout (s)
WIN_SOAK_TXNS=${TD_WIN_SOAK_TXNS:-8}        # BOUNDED XHB window soak transaction count

# ----- register map (AUTHORITATIVE — current July deterministic methodology) -
#   APB base 0x4403_0000; TideLink cfg region at 0x4403_2000. Data on GP1.
R_NEGO_CFG=0x44032090        # NEGO_CFG (RW) — ARM autoneg here (NOT the RO 0x110)
R_NEGO_STS=0x44032110        # NEGO status (RO) alias — never write this
R_ROLE=0x44032080            # role W1S: master=0x2, slave=0x3
R_STATUS=0x44032108          # [16]=cal [19:17]=fcsm(4=bilateral) [23]=cr [31]=fe_full
R_NEGO_TRAIN=0x4403210C      # NEGO_TRAIN_CFG (autonomy-off = 0x0 for manual)
R_R8=0x44032100              # PHY ctrl: 0x1C sync / 0x1E->0x1C recal / 0x10 data-en
                             #           NEVER bit0 (swi_training_mode = S_HOLD trap)
                             # data-en MUST clear bit2 (SYNC_EN): 0x10 not 0x14. With
                             # SYNC_EN left on during the burst the framer injects SYNC
                             # beacons mid-packet -> ~3/28 words corrupt per burst
                             # (silicon-proven 2026-07-11: 0x10 => GP1 RX byte-exact;
                             # 0x14 => filt=25/28 rot=-1). Matches hwlib enter_data_mode
                             # ("strip SYNC so the framer runs packets to completion").
R_SLIPLO=0x44032104          # SWI_BIT_SLIP_LO ([23:0]slip [27:24]word_pin [28]auto_dis)
R_LANEMASK=0x44030214        # rx/tx lane mask (0x0000_e4e4 = active lanes 2,5,6,7)
R_SYNCTOL=0x44032128         # [12:8]=SYNC tol(5) [7:0]=per-lane mask(0xe4)
R_LOCKTHR=0x44032160         # per-lane Hamming lock threshold (0x5555_5555 = 5)
R_REANCHORED=0x44032140      # [0]=epoch_anchored (deskew aligned, sticky)
R_FCCTRL=0x44030208          # LL/FC-node bootstrap triplet target
R_FCQUIESCE=0x44030230       # FC-node quiesce (pre-bootstrap)
R_DOORBELL=0x44032014        # WO: write -> ring doorbell to peer (self-clearing)
R_DOORBELL_ACC=0x44032024    # W-add / R-clear: doorbell responses RECEIVED from peer
TX_BASE=${TIDELINK_TX_BASE:-0x84000000}     # GP1 AHB_TX data aperture
RX_BASE=${TIDELINK_RXFIFO_BASE:-0x84010000} # GP1 RX FIFO data aperture
XHB_WINDOW=${TIDELINK_XHB_WINDOW:-0x40000000} # transparent peer window (M_AXI_GP0)

# LL/FC bootstrap triplet (bit0=swi_enable) and the R8 phase constants
FC_TRIPLET=(0x00027f09 0x00027f01 0x00027f07)
R8_SYNC=0x1C; R8_RECAL=0x1E; R8_DATA=0x10   # data-en strips SYNC_EN (bit2); see R_R8 note
NEGO_ARM=0x61                # nego_en | force_lock | mask_hs_auto_en (0x41 never latches)
ACTIVE_LANES="2 5 6 7"

# ----- SSH plumbing (one hop per call, throttled; modeled on td_v2_hwlib.sh) --
BOARD_PW=${TD_BOARD_PW:-xilinx}
SSH="sshpass -p ${BOARD_PW} ssh -n -o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
_PY="echo ${BOARD_PW} | sudo -S python3 $TL39"
# m/s: run a tl39 command on master/slave, wall-clock bounded so a wedged PS
# access degrades to a timeout (empty output) instead of hanging the suite.
m(){ timeout "$SSH_TIMEOUT" $SSH xilinx@$MASTER_IP "$_PY $*" 2>/dev/null; }
s(){ timeout "$SSH_TIMEOUT" $SSH xilinx@$SLAVE_IP  "$_PY $*" 2>/dev/null; }
# throttled reads: never issue back-to-back host->ssh reads without a sleep
mrd(){ local v; v=$(m rd $1); sleep "$THROTTLE"; echo "$v"; }
srd(){ local v; v=$(s rd $1); sleep "$THROTTLE"; echo "$v"; }
val(){ printf "%d" $(( ${1:-0} )) 2>/dev/null || echo 0; }   # hex/empty -> int

# ----- status decoders ------------------------------------------------------
# $1 = m|s (which die). fcsm / cal / cr read from R_STATUS, throttled.
_stat(){ [ "$1" = m ] && mrd $R_STATUS || srd $R_STATUS; }
fcsm(){ local v; v=$(val "$(_stat $1)"); echo $(( (v>>17)&7 )); }
cal(){  local v; v=$(val "$(_stat $1)"); echo $(( (v>>16)&1 )); }
cr(){   local v; v=$(val "$(_stat $1)"); echo $(( (v>>23)&1 )); }
reanchored(){ echo $(( $(val "$(srd $R_REANCHORED)")&1 )); }

# ----- assert framework (mirrors td_v2_hwlib.sh) ----------------------------
TD_PASS=0; TD_FAIL=0; DETAIL=()
ok(){    TD_PASS=$((TD_PASS+1)); DETAIL+=("    ok   $1"); }
bad(){   TD_FAIL=$((TD_FAIL+1)); DETAIL+=("    FAIL $1"); }
assert(){ if [ "$2" = "$3" ]; then ok "$1: $3"; else bad "$1: got=$3 want=$2"; return 1; fi; }
flush(){ [ ${#DETAIL[@]} -gt 0 ] && printf '%s\n' "${DETAIL[@]}"; DETAIL=(); }

# ----- lease + board health -------------------------------------------------
board_up(){ ping -c1 -W2 "$1" >/dev/null 2>&1; }
lease_acquire(){ local out tok
  out=$(fpgahub pair lease acquire "$LEASE_NAME" --ttl "${1:-2400}" --json 2>/dev/null)
  tok=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
  echo "LEASE_TOKEN=$tok" > "$HOME/.td_channels_lease"; [ -n "$tok" ]; }
lease_release(){ local tok
  tok=$(grep -o 'LEASE_TOKEN=.*' "$HOME/.td_channels_lease" 2>/dev/null | cut -d= -f2)
  [ -n "$tok" ] && fpgahub pair lease release "$LEASE_NAME" --token "$tok" >/dev/null 2>&1; }

abort(){ echo "### ABORT: $1"; [ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release; exit 1; }

# ============================================================================
# BRING-UP MODES
# ============================================================================
# Deterministic manual recipe. R8 base = 0x1C (bit0 CLEAR). Only the master
# pulses recal (0x1E->0x1C); the slave holds 0x1C — matches the proven recipe.
bringup_manual(){
  echo "-- manual (deterministic) bring-up --"
  m wr $R_NEGO_TRAIN 0x0    >/dev/null;  s wr $R_NEGO_TRAIN 0x0    >/dev/null
  m wr $R_LANEMASK 0x0000e4e4>/dev/null; s wr $R_LANEMASK 0x0000e4e4>/dev/null
  m wr $R_ROLE 0x2          >/dev/null;  s wr $R_ROLE 0x3          >/dev/null
  m wr $R_LOCKTHR 0x55555555>/dev/null;  s wr $R_LOCKTHR 0x55555555>/dev/null
  m wr $R_SLIPLO 0x0        >/dev/null;  s wr $R_SLIPLO 0x0        >/dev/null
  m wr $R_SYNCTOL 0x000005e4>/dev/null;  s wr $R_SYNCTOL 0x000005e4>/dev/null
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
  m wr $R_R8 $R8_RECAL      >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null; sleep 0.03
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
}
# Autonomous: arm NEGO_CFG=0x61 ONCE per die, then poll longer for the div-2
# link clock to converge. mask/tol/R8 sync config MUST precede nego_en (the
# autoneg FSM samples mask_hs at arm) — same ordering as bringup_autocal_i2c.sh.
bringup_autonomous(){
  echo "-- autonomous (arm-once NEGO_CFG=$NEGO_ARM) bring-up --"
  m wr $R_LANEMASK 0x0000e4e4>/dev/null; s wr $R_LANEMASK 0x0000e4e4>/dev/null
  m wr $R_SYNCTOL 0x000005e4>/dev/null;  s wr $R_SYNCTOL 0x000005e4>/dev/null
  m wr $R_LOCKTHR 0x55555555>/dev/null;  s wr $R_LOCKTHR 0x55555555>/dev/null
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
  m wr $R_ROLE 0x2          >/dev/null;  s wr $R_ROLE 0x3          >/dev/null
  m wr $R_NEGO_CFG $NEGO_ARM>/dev/null;  s wr $R_NEGO_CFG $NEGO_ARM>/dev/null
  # readback-verify the arm landed (RW register); a stuck 0 = wrong aperture
  local ma sa; ma=$(( $(val "$(mrd $R_NEGO_CFG)")&0x7f )); sa=$(( $(val "$(srd $R_NEGO_CFG)")&0x7f ))
  DETAIL+=("    NEGO_CFG readback master=0x$(printf %02x $ma) slave=0x$(printf %02x $sa)")
}

# FC/LL bootstrap (data-mode entry) — quiesce then the 0x27f09/01/07 triplet.
handoff(){
  m wr $R_FCQUIESCE 0x0>/dev/null; s wr $R_FCQUIESCE 0x0>/dev/null; sleep 0.1
  local v; for v in "${FC_TRIPLET[@]}"; do
    m wr $R_FCCTRL $v>/dev/null; s wr $R_FCCTRL $v>/dev/null; sleep 0.2
  done; sleep 0.3
}

# ============================================================================
# CHANNEL GATES (wedge-safe order enforced by main)
# ============================================================================
# GATE 0 — link + cal. Deterministic; PORS is a soak knob (re-bring-up + retest)
# NOT an eye-lottery retry. Every downstream channel depends on cal=1, so a
# failure here ABORTS (pushing data at cal=0 is exactly what wedges the PS).
gate_link(){
  local por ok=1 tries secs=18
  for por in $(seq 1 "$PORS"); do
    [ "$MODE" = autonomous ] && secs=40   # div-2 link clock needs a longer poll
    if [ "$MODE" = manual ]; then bringup_manual; else bringup_autonomous; fi
    for tries in $(seq 1 "$secs"); do
      sleep 1
      [ "$(fcsm m)" = 4 ] && [ "$(fcsm s)" = 4 ] && { ok=0; break; }
    done
    [ "$ok" = 0 ] && break
    echo "   (POR $por/$PORS: no bilateral fcsm=4 yet; re-bring-up)"
  done
  # cal=1 is the safety gate for EVERY downstream channel — fail the gate if
  # link was not reached OR any of the four asserts fell (fcsm=4 with cal=0 must
  # NOT be allowed to proceed to the data push).
  local gfail=0
  assert "fcsm master" 4 "$(fcsm m)" || gfail=1
  assert "fcsm slave"  4 "$(fcsm s)" || gfail=1
  assert "cal master"  1 "$(cal m)"  || gfail=1
  assert "cal slave"   1 "$(cal s)"  || gfail=1
  [ "$ok" = 0 ] && [ "$gfail" = 0 ]
}

# rotation-aware ring compare (host-side python). $1=label, then sent... "--" recv...
# PASS iff there is a cyclic rotation r with recv_filtered[i]==sent[(i+r)%N] for all i,
# where recv_filtered = recv words that are members of the sent set (drops packet
# headers / zeros / slack). Prints VERDICT PASS|FAIL and a diagnostic line.
ring_compare(){
  python3 - "$@" <<'PY'
import sys
args=sys.argv[1:]
label=args[0]; args=args[1:]
cut=args.index("--"); sent=[int(x,16) for x in args[:cut]]; recv=[int(x,16) for x in args[cut+1:]]
sset=set(sent); N=len(sent)
filt=[w for w in recv if w in sset][:N]
ok=False; roff=-1
if len(filt)==N:
    for r in range(N):
        if all(filt[i]==sent[(i+r)%N] for i in range(N)): ok=True; roff=r; break
print("VERDICT %s %s" % (label, "PASS" if ok else "FAIL"))
print("  sent=%d recv=%d filt=%d rot=%s" % (N,len(recv),len(filt),roff))
sys.exit(0 if ok else 1)
PY
}

# Build a 28-word unique nonzero sentinel ring for direction tag $1 (a2b|b2a)
ring_words(){ local tag=$1 base i out=""
  [ "$tag" = a2b ] && base=0xA2B00000 || base=0xB2A00000
  for i in $(seq 0 27); do out+=" $(printf 0x%08x $(( base + i )))"; done
  echo "$out"; }

# GATE 1 — tl-data both directions (rotation-aware 28-word ring).
# A->B first (the SAFE direction). B->A second, same throttling — now proven
# byte-exact on silicon, but ordered after A->B so an unexpected B->A wedge
# cannot poison the headline direction.
gate_data(){
  handoff
  m wr $R_FCCTRL 0x00027f07>/dev/null; s wr $R_FCCTRL 0x00027f07>/dev/null; sleep 0.5
  m wr $R_R8 $R8_DATA>/dev/null;       s wr $R_R8 $R8_DATA>/dev/null;       sleep 0.5
  local rc=0

  # ---- A->B ----
  local aw; aw=$(ring_words a2b)
  s rxn 32 >/dev/null 2>&1                    # drain stale RX FIFO on receiver
  m txburst $aw >/dev/null 2>&1; sleep 1.2
  local arx; arx=$(s rxn 32); sleep "$THROTTLE"
  DETAIL+=("    [a2b rx] ${arx:0:64}...")
  if ring_compare a2b $aw -- $arx; then ok "tl-data A->B ring (28w rotation-aware)"
  else bad "tl-data A->B ring (28w rotation-aware)"; rc=1; fi

  # ---- B->A ----  (guarded: slave is sender, master receives)
  local bw; bw=$(ring_words b2a)
  m rxn 32 >/dev/null 2>&1
  s txburst $bw >/dev/null 2>&1; sleep 1.2
  local brx; brx=$(m rxn 32); sleep "$THROTTLE"
  DETAIL+=("    [b2a rx] ${brx:0:64}...")
  if ring_compare b2a $bw -- $brx; then ok "tl-data B->A ring (28w rotation-aware)"
  else bad "tl-data B->A ring (28w rotation-aware)"; rc=1; fi
  return $rc
}

# GATE 2 — doorbell. Ring the doorbell from each die; the peer's RESPONSE_ACC
# (W-add / R-clear) must increment. Read-clears, so read once and compare >0.
gate_doorbell(){
  local rc=0 before after
  # master -> slave
  s rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep "$THROTTLE"     # clear
  m wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  after=$(val "$(srd $R_DOORBELL_ACC)")
  if [ "$after" -gt 0 ]; then ok "doorbell M->S (acc=$after)"; else bad "doorbell M->S (acc=0)"; rc=1; fi
  # slave -> master
  m rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep "$THROTTLE"
  s wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  after=$(val "$(mrd $R_DOORBELL_ACC)")
  if [ "$after" -gt 0 ]; then ok "doorbell S->M (acc=$after)"; else bad "doorbell S->M (acc=0)"; rc=1; fi
  return $rc
}

# GATE 3 — XHB transparent window. LAST, only reached after data is proven.
# Every access is timeout-wrapped (m/s already wrap ssh in `timeout`); the soak
# is BOUNDED to WIN_SOAK_TXNS write/read round-trips. Missing output (a wedged
# access) is counted as a FAIL, never a hang.
gate_xhb_window(){
  local rc=0 i good=0 off addr wv rv
  for i in $(seq 0 $((WIN_SOAK_TXNS-1))); do
    off=$(( i*4 )); addr=$(printf 0x%x $(( XHB_WINDOW + off )))
    wv=$(printf 0x%08x $(( 0xC0DE0000 + i )))
    m wr $addr $wv >/dev/null 2>&1; sleep "$THROTTLE"         # transparent write to peer
    rv=$(m rd $addr); sleep "$THROTTLE"                       # transparent read-back
    if [ -z "$rv" ]; then
      DETAIL+=("    [win $i] TIMEOUT/empty at $addr (wedge-guarded)"); rc=1; continue
    fi
    if [ "$(( rv ))" = "$(( wv ))" ]; then good=$((good+1))
    else DETAIL+=("    [win $i] $addr got=$rv want=$wv"); rc=1; fi
  done
  assert "XHB window round-trip ($good/$WIN_SOAK_TXNS)" "$WIN_SOAK_TXNS" "$good"
  return $rc
}

# ----- per-channel PASS/FAIL wrapper ----------------------------------------
CH_RESULT=()
run_gate(){ # name  fn
  local name=$1 fn=$2 t0=$SECONDS
  echo "== $name =="
  if $fn; then printf "  [PASS] %-12s %ds\n" "$name" $((SECONDS-t0)); CH_RESULT+=("PASS $name")
  else        printf "  [FAIL] %-12s %ds\n" "$name" $((SECONDS-t0)); CH_RESULT+=("FAIL $name"); fi
  flush
}

# ============================================================================
# MAIN
# ============================================================================
echo "======== TideLink V2 channel regression ($(date)) ========"
echo "  master=$MASTER_IP($MASTER_BOARD)  slave=$SLAVE_IP($SLAVE_BOARD)"
echo "  mode=$MODE  channels='$CHANNELS'  pors=$PORS  throttle=${THROTTLE}s"

board_up "$MASTER_IP" || abort "master $MASTER_IP unreachable (power-cycle?)"
board_up "$SLAVE_IP"  || abort "slave $SLAVE_IP unreachable (power-cycle?)"
if [ "$DO_LEASE" = 1 ]; then lease_acquire 2400 || abort "could not acquire $LEASE_NAME lease"; fi
trap '[ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release' EXIT

# GATE 0 is mandatory + gating: no cal=1 => downstream channels would wedge.
run_gate link gate_link
case " ${CH_RESULT[*]} " in *"FAIL link"*) abort "no bilateral cal=1 link — downstream channels unsafe";; esac

# Selected channels, in the fixed wedge-safe order (data -> doorbell -> xhb).
for ch in data doorbell xhb; do
  case " $CHANNELS " in *" $ch "*) ;; *) continue;; esac
  case $ch in
    data)     run_gate data     gate_data;;
    doorbell) run_gate doorbell gate_doorbell;;
    xhb)      run_gate xhb      gate_xhb_window;;
  esac
done

# ----- report ---------------------------------------------------------------
echo "========================================================"
echo "  per-channel:"; printf '    %s\n' "${CH_RESULT[@]}"
TOT=$((TD_PASS+TD_FAIL))
echo "  asserts: $TD_PASS/$TOT passed"
if [ "$TD_FAIL" = 0 ]; then echo "  PASS — all selected V2 channels intact"; RC=0
else echo "  FAIL — $TD_FAIL assertion(s) regressed"; RC=1; fi
echo "========================================================"
exit $RC

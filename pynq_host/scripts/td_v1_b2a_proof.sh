#!/usr/bin/env bash
#=============================================================================
# td_v1_b2a_proof.sh  —  reliable, self-verifying proof of V1 TideLink data
#   delivery on the bridge1 silicon pair (z2_02 <-> z2_01).
#   RTL tag: v1-silicon-b2a-2026-06-23 (commit 142a7ca).
#
# RUN ON mapstone-dev (needs fpgahub + routes to the board PS-mgmt network,
# logged in as the user whose key/sshpass reaches the boards — david).
#
# Stages:
#   [program] (optional, --program)  fpgahub pair up (lease+attach+boot) then
#             load each V1 bitstream via the PYNQ overlay method, and stage the
#             matching .bin at /lib/firmware/tidelink.bin for fast re-POR rolls.
#   [roll]    re-POR + SW-latch role_lock, repeat until a CLEAN bilateral link
#             (both fcsm=4 + cr + crack + cal_done, sender has credit). Bring-up
#             is a marginal-eye lottery, so we roll up to N times.
#   [prove]   send a FRESH UNIQUE 4-word packet from the sender die and verify
#             the unique word lands byte-exact in the receiver die's RX FIFO.
#
# Exit 0 ONLY on verified delivery (the unique word can't be stale -> a PASS
# is genuine fresh delivery). Default direction is B->A (die_b -> die_a), the
# proven-good path; A->B currently FAILS on the die_b flip build (LUT-driven
# pad_clk_rx -> marginal RX faults in data mode). Rebuild die_b with the
# flip-XDC BUFG fix to make A->B (and full bilateral) work.
#
# Usage:
#   ./td_v1_b2a_proof.sh                 # roll + prove B->A (boards already programmed)
#   ./td_v1_b2a_proof.sh --program       # full: program both dies first, then prove
#   ./td_v1_b2a_proof.sh --dir AtoB      # try the (currently-broken) A->B direction
#   ./td_v1_b2a_proof.sh --rolls 15 -v   # more lottery rolls, verbose per-roll status
#
# Env overrides: A_IP B_IP A_NAME B_NAME BIT_A BIT_B TIDELINK_BOARD_PASS
#                PAIR FPGAHUB TX_BASE RX_BASE MAX_ROLLS DWELL
#=============================================================================
set -u

# ---- config (env-overridable) ----------------------------------------------
PAIR="${PAIR:-bridge1}"
A_NAME="${A_NAME:-pynq_z2_02_pl}"; A_IP="${A_IP:-192.168.4.101}"   # die_a = master, non-flip
B_NAME="${B_NAME:-pynq_z2_01_pl}"; B_IP="${B_IP:-192.168.2.101}"   # die_b = slave, flip
BIT_A="${BIT_A:-/home/david/td_v1_deploy/tidelink.bit}"
BIT_B="${BIT_B:-/home/david/td_v1_deploy/tidelink-flip.bit}"
PW="${TIDELINK_BOARD_PASS:-xilinx}"
FPGAHUB="${FPGAHUB:-/opt/fpgahub/bin/fpgahub}"
TX="${TX_BASE:-0x84000000}"      # GP1 AHB_TX aperture (sender side)
RX="${RX_BASE:-0x84010000}"      # GP1 RX FIFO aperture (receiver side)
MAX_ROLLS="${MAX_ROLLS:-10}"; DWELL="${DWELL:-9}"
DO_PROGRAM=0; DIR="BtoA"; VERB=0

# TideLink APB register map (SoC base 0x44032000)
LS=0x44032108     # SWI_LANE_STATUS: [16]cal_done [19:17]fcsm [23]cr [24]crack [31]fe_full
ROLE=0x44032080   # ROLE_CFG: [0]role(0=master,1=slave) [1]role_lock W1S
CRED=0x4403219C   # OBS_FC_CREDIT: [7:0]credit_max [31:24]=0xFC marker
UNLOCK=0x44041000 # apb_debug_unlock GPIO (lets role_lock latch w/o I2C handshake)
FW=/sys/class/fpga_manager/fpga0/firmware

while [ $# -gt 0 ]; do case "$1" in
  --program) DO_PROGRAM=1; shift;;
  --dir) DIR="$2"; shift 2;;
  --rolls) MAX_ROLLS="$2"; shift 2;;
  -v|--verbose) VERB=1; shift;;
  -h|--help) sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0;;
  *) echo "unknown arg: $1 (try --help)" >&2; exit 2;;
esac; done

SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
vlog(){ [ "$VERB" = 1 ] && printf '      %s\n' "$*"; return 0; }
fail(){ echo "=================================================================="; echo "RESULT: FAIL — $1"; echo "=================================================================="; exit 1; }

command -v sshpass >/dev/null || fail "sshpass not found (run on mapstone-dev)"

# board root-shell — handles z2_01's PASSWORDED sudo via -S (z2_02 is passwordless; -S is harmless there)
bsh(){ local ip=$1; shift; sshpass -p "$PW" ssh $SSHC xilinx@"$ip" "echo '$PW' | sudo -S sh -c '$*' 2>/dev/null"; }
rdr(){ bsh "$1" "/usr/bin/devmem2 $2 w" | grep -oE '0x[0-9A-Fa-f]+' | tail -1; }   # read 32b reg
wrr(){ bsh "$1" "/usr/bin/devmem2 $2 w $3 >/dev/null"; }                            # write 32b reg
# link-up = cal_done & fcsm==4 & cr & crack  (reads LANE_STATUS)
linkup(){ local v; v=$(rdr "$1" $LS); v=$((${v:-0})); [ $(((v>>16)&1)) = 1 ] && [ $(((v>>17)&7)) = 4 ] && [ $(((v>>23)&1)) = 1 ] && [ $(((v>>24)&1)) = 1 ]; }
# sender has TX credit = credit_max (low byte of OBS_FC_CREDIT) != 0
credok(){ local c; c=$(rdr "$1" $CRED); [ -n "$c" ] && [ "${c: -2}" != "00" ]; }
statline(){ printf 'die_a[LS=%s cred=%s] die_b[LS=%s cred=%s]' "$(rdr "$A_IP" $LS)" "$(rdr "$A_IP" $CRED)" "$(rdr "$B_IP" $LS)" "$(rdr "$B_IP" $CRED)"; }

# direction -> sender/receiver
case "$DIR" in
  BtoA) SND_IP=$B_IP; RCV_IP=$A_IP; SND=die_b; RCV=die_a;;
  AtoB) SND_IP=$A_IP; RCV_IP=$B_IP; SND=die_a; RCV=die_b;;
  *) fail "unknown --dir '$DIR' (BtoA|AtoB)";;
esac
log "TideLink V1 delivery proof — pair=$PAIR  dir=$DIR ($SND -> $RCV)  TX=$TX RX=$RX  rolls<=$MAX_ROLLS"

# ---- [program] (optional) ---------------------------------------------------
if [ "$DO_PROGRAM" = 1 ]; then
  log "[program] $FPGAHUB pair up $PAIR (lease + attach + boot)"
  $FPGAHUB pair up "$PAIR" --ttl 3600 >/dev/null 2>&1 || fail "fpgahub pair up $PAIR failed"
  for pe in "$A_NAME|$BIT_A|$A_IP" "$B_NAME|$BIT_B|$B_IP"; do
    IFS='|' read -r nm bit ip <<EOF
$pe
EOF
    [ -f "$bit" ] || fail "bitstream not found: $bit"
    bin="${bit%.bit}.bin"
    log "[program] $nm <- $(basename "$bit") (PYNQ overlay) + stage .bin for re-POR"
    $FPGAHUB board program "$nm" "$bit" --method linux >/dev/null 2>&1 || fail "fpgahub program $nm failed"
    if [ -f "$bin" ]; then
      sshpass -p "$PW" scp $SSHC "$bin" "xilinx@$ip:/tmp/tidelink.bin" >/dev/null 2>&1 \
        && bsh "$ip" "cp /tmp/tidelink.bin /lib/firmware/tidelink.bin" \
        || log "[program] WARN: could not stage $bin on $ip (re-POR rolls may fail)"
    fi
  done
fi

# preflight: boards reachable + re-POR firmware present
for ip in "$A_IP" "$B_IP"; do
  [ "$(rdr "$ip" 0x4403211C)" = "0x50410100" ] || fail "$ip not reachable / wrong bitstream (PHY_ALIGN_ID != 0x50410100) — run with --program first"
done

# ---- [roll] to a clean bilateral link --------------------------------------
log "[roll] rolling marginal-eye link to a clean bilateral state ..."
clean=0
for r in $(seq 1 "$MAX_ROLLS"); do
  bsh "$A_IP" "echo tidelink.bin > $FW"; bsh "$B_IP" "echo tidelink.bin > $FW"   # re-POR both
  sleep 2
  wrr "$A_IP" $UNLOCK 0x1; wrr "$A_IP" $ROLE 0x2     # die_a: debug-unlock + master + role_lock W1S
  wrr "$B_IP" $UNLOCK 0x1; wrr "$B_IP" $ROLE 0x3     # die_b: debug-unlock + slave  + role_lock W1S
  sleep "$DWELL"
  vlog "roll $r: $(statline)"
  if linkup "$A_IP" && linkup "$B_IP" && credok "$SND_IP"; then
    log "[roll] CLEAN on roll $r — both fcsm=4+cr+crack+cal_done, $SND has credit"
    log "        $(statline)"
    clean=1; break
  fi
done
[ "$clean" = 1 ] || fail "no clean bilateral roll in $MAX_ROLLS tries (marginal-eye lottery — retry, or die_b RX too marginal -> rebuild flip half)"

# ---- [prove] delivery with a FRESH UNIQUE payload --------------------------
U0=$(printf '0xC0DE%04X' $(( RANDOM & 0xFFFF )))
U1=$(printf '0xFEED%04X' $(( RANDOM & 0xFFFF )))
pre=$(rdr "$RCV_IP" "$RX")
log "[prove] $SND -> $RCV: send hdr=0x00240000 + unique payload [$U0,$U1] (receiver FIFO[0] pre-send=$pre)"
wrr "$SND_IP" "$TX" 0x00240000     # hdr: WR_REQ, 2 payload words
wrr "$SND_IP" "$TX" 0x00000000     # target addr offset
wrr "$SND_IP" "$TX" "$U0"          # payload word 0
wrr "$SND_IP" "$TX" "$U1"          # payload word 1
sleep 2
hit=""; dump=""
for off in 0 4 8 12 16 20 24 28; do
  addr=$(printf '0x%X' $(( RX + off )))
  w=$(rdr "$RCV_IP" "$addr")
  dump="$dump +$off=$w"
  { [ "$w" = "$U0" ] || [ "$w" = "$U1" ]; } && hit="$w @ +$off"
done
vlog "receiver RX FIFO:$dump"
echo "=================================================================="
if [ -n "$hit" ]; then
  echo "RESULT: PASS — $SND -> $RCV delivered byte-exact: $hit  (sent [$U0,$U1])"
else
  echo "RESULT: FAIL — unique payload [$U0,$U1] not in $RCV RX FIFO"
  echo "  FIFO:$dump"
fi
echo "  final link: $(statline)"
echo "=================================================================="
[ -n "$hit" ] && exit 0 || exit 1

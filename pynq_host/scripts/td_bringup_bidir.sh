#!/usr/bin/env bash
#=============================================================================
# td_bringup_bidir.sh  —  "roll-until-A->B-clean" bring-up for reliable
#   BIDIRECTIONAL V1 TideLink data on the bridge1 silicon pair (z2_02 <-> z2_01).
#   RTL tag: v1-silicon-bilateral-2026-06-23 (die_b flip BUFG fix).
#
# RUN ON mapstone-dev (needs fpgahub + routes to the board PS-mgmt network,
# logged in as the user whose key/sshpass reaches the boards — david).
#
# WHY THIS EXISTS
#   PROVEN today: on a GOOD sample-phase POR with the link HELD (no re-POR),
#   BOTH B->A and A->B deliver 100% (12/12 each, word_pin OFF). The catch is
#   that bring-up is a marginal-eye lottery: each POR lands on a random RX
#   sample phase. td_v1_b2a_proof.sh's roll loop stops the instant B->A links
#   up (fcsm=4 + credit), which does NOT guarantee the A->B direction also
#   landed on its eye — so A->B is a per-POR coin flip.
#
#   THE FIX (Track 1, SW quick-win): keep the SAME re-POR roll mechanism, but
#   make the CLEAN criterion stricter — a roll is only accepted when, on the
#   SAME link-up, link is up (both fcsm=4 + credit) AND a B->A test packet
#   delivers byte-exact AND an A->B test packet delivers byte-exact. We roll
#   (re-POR) up to MAX_ROLLS until that holds, then STOP and HOLD the link
#   (no further re-POR). Selecting a POR where BOTH directions already proved
#   delivery deterministically lands a good sample-phase, so the subsequent
#   held-link traffic is reliably bidirectional.
#
# Stages:
#   [program] (optional, --program)  fpgahub pair up (lease+attach+boot), load
#             each V1 bitstream via the PYNQ overlay method, and stage the
#             matching .bin at /lib/firmware/tidelink.bin for fast re-POR rolls.
#   [roll]    re-POR + SW-latch role_lock, repeat until link-up AND a live
#             B->A AND a live A->B packet BOTH deliver on the same link-up.
#   [hold]    HOLD the good-phase link (no more re-POR) and run N interleaved
#             B->A + A->B sends, printing per-direction rates + a clear
#             "RELIABLE BIDIRECTIONAL N/N + N/N" verdict.
#
# Exit 0 ONLY if a clean bidirectional roll was found AND every held-link send
# in BOTH directions delivered (N/N + N/N). Each test packet carries a FRESH
# UNIQUE word, so a PASS can't be a stale-FIFO artifact.
#
# Usage:
#   ./td_bringup_bidir.sh                 # roll to bidir-clean + hold + 12+12 sends (boards already programmed)
#   ./td_bringup_bidir.sh --program       # full: program both dies first, then bring up bidirectional
#   ./td_bringup_bidir.sh --sends 20 -v    # more held-link sends per direction, verbose per-roll status
#   ./td_bringup_bidir.sh --rolls 20      # more lottery rolls before giving up
#   ./td_bringup_bidir.sh --program --release   # self-cleaning: program, bring up, then free the lease
#   ./td_bringup_bidir.sh --release       # standalone: free a lease left by a prior --program run
#   WORD_PIN=3 ./td_bringup_bidir.sh      # also set+hold die_b word_pin to window 3 after landing (belt-and-suspenders)
#
# Env overrides: A_IP B_IP A_NAME B_NAME BIT_A BIT_B TIDELINK_BOARD_PASS
#                PAIR FPGAHUB TX_BASE RX_BASE MAX_ROLLS DWELL SENDS WORD_PIN
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
SENDS="${SENDS:-12}"             # held-link sends per direction
PROBE_K="${PROBE_K:-4}"          # roll accept needs PROBE_K consecutive hits EACH dir (filters marginal PORs)
WORD_PIN="${WORD_PIN:-}"         # optional die_b word_pin window (0..15); empty = leave OFF
DO_PROGRAM=0; VERB=0; RELEASE=0
LEASE_TOKEN_FILE="${TMPDIR:-/tmp}/td_v1_lease_${PAIR}.token"   # --program captures the pair-lease token here; --release frees it

# TideLink APB register map (SoC base 0x44032000)
LS=0x44032108     # SWI_LANE_STATUS: [16]cal_done [19:17]fcsm [23]cr [24]crack [31]fe_full
ROLE=0x44032080   # ROLE_CFG: [0]role(0=master,1=slave) [1]role_lock W1S
CRED=0x4403219C   # OBS_FC_CREDIT: [7:0]credit_max [31:24]=0xFC marker
UNLOCK=0x44041000 # apb_debug_unlock GPIO (lets role_lock latch w/o I2C handshake)
WP_EN=0x4403214C  # word_pin enable mask (per-lane); 0xFF = all 8 lanes pinned
WP_WIN=0x44032148 # word_pin window select (nibble-per-lane); win*0x11111111
FW=/sys/class/fpga_manager/fpga0/firmware

while [ $# -gt 0 ]; do case "$1" in
  --program) DO_PROGRAM=1; shift;;
  --rolls) MAX_ROLLS="$2"; shift 2;;
  --sends) SENDS="$2"; shift 2;;
  --word-pin) WORD_PIN="$2"; shift 2;;
  -v|--verbose) VERB=1; shift;;
  --release) RELEASE=1; shift;;
  -h|--help) sed -n '2,60p' "$0" | sed 's/^# \?//'; exit 0;;
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

# send ONE fresh-unique 4-word packet snd_ip -> rcv_ip and verify byte-exact in rcv RX FIFO.
# echoes "PASS <word> @ +<off>" or "FAIL" ; returns 0 on delivery, 1 otherwise.
send_probe(){
  local snd_ip=$1 rcv_ip=$2 u0 u1 off addr w hit="" dump=""
  u0=$(printf '0xC0DE%04X' $(( RANDOM & 0xFFFF )))
  u1=$(printf '0xFEED%04X' $(( RANDOM & 0xFFFF )))
  wrr "$snd_ip" "$TX" 0x00240000     # hdr: WR_REQ, 2 payload words
  wrr "$snd_ip" "$TX" 0x00000000     # target addr offset
  wrr "$snd_ip" "$TX" "$u0"          # payload word 0
  wrr "$snd_ip" "$TX" "$u1"          # payload word 1
  sleep 2                            # let the packet cross + land in the RX FIFO before reading
  for off in 0 4 8 12 16 20 24 28; do
    addr=$(printf '0x%X' $(( RX + off )))
    w=$(rdr "$rcv_ip" "$addr")
    dump="$dump +$off=$w"
    { [ "$w" = "$u0" ] || [ "$w" = "$u1" ]; } && hit="$w @ +$off"
  done
  if [ -n "$hit" ]; then vlog "  probe $snd_ip->$rcv_ip [$u0,$u1] -> $hit"; echo "PASS $hit"; return 0; fi
  vlog "  probe $snd_ip->$rcv_ip [$u0,$u1] -> MISS  FIFO:$dump"; echo "FAIL"; return 1
}

# PROBE_K consecutive deliveries snd->rcv (ALL must pass). A single probe passes
# on a marginal eye by luck; K-in-a-row selects a STRONGLY-good sample phase.
pk_ok(){ local s=$1 d=$2 k; for k in $(seq 1 "$PROBE_K"); do send_probe "$s" "$d" >/dev/null || return 1; done; return 0; }

# lease release helper (--release): frees the pair lease captured during --program
release_lease(){
  local tok; tok=$(cat "$LEASE_TOKEN_FILE" 2>/dev/null)
  [ -n "$tok" ] || { vlog "[release] no captured lease token at $LEASE_TOKEN_FILE"; return 0; }
  log "[release] freeing $PAIR lease"
  $FPGAHUB pair lease release "$PAIR" --token "$tok" >/dev/null 2>&1 && rm -f "$LEASE_TOKEN_FILE"
}
# release-only mode: `--release` alone frees a lease left by a prior `--program` run, then exits
if [ "$RELEASE" = 1 ] && [ "$DO_PROGRAM" = 0 ]; then release_lease; exit 0; fi
# self-cleaning: with `--program --release`, free the lease on ANY exit (incl. fail())
[ "$RELEASE" = 1 ] && trap release_lease EXIT

log "TideLink V1 BIDIRECTIONAL bring-up — pair=$PAIR  TX=$TX RX=$RX  rolls<=$MAX_ROLLS  sends=$SENDS/dir${WORD_PIN:+  word_pin=win$WORD_PIN}"

# ---- [program] (optional) ---------------------------------------------------
if [ "$DO_PROGRAM" = 1 ]; then
  log "[program] $FPGAHUB pair up $PAIR (lease + attach + boot)"
  $FPGAHUB pair up "$PAIR" --ttl 3600 >/dev/null 2>&1 || fail "fpgahub pair up $PAIR failed"
  # capture a releasable lease token (pair up emits none; a same-holder acquire returns a usable token)
  LEASE_TOKEN=$($FPGAHUB pair lease acquire "$PAIR" --ttl 3600 --json 2>/dev/null | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  if [ -n "$LEASE_TOKEN" ]; then printf '%s' "$LEASE_TOKEN" > "$LEASE_TOKEN_FILE"; log "[program] lease token captured -> $LEASE_TOKEN_FILE (run with --release to free)"; else log "[program] WARN: could not capture lease token (--release won't free it)"; fi
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

# ---- [roll] to a BIDIRECTIONAL-clean link ----------------------------------
# A roll is accepted ONLY when, on the SAME link-up:
#   (a) link is up both ways  (both dies fcsm=4 + cr + crack + cal_done),
#   (b) BOTH dies have TX credit,
#   (c) a live B->A test packet delivers byte-exact, AND
#   (d) a live A->B test packet delivers byte-exact.
# This selects a POR that landed on a GOOD sample phase in BOTH directions,
# so the held link is reliably bidirectional (vs. the B->A-only proof, which
# left A->B a per-POR coin flip).
log "[roll] rolling marginal-eye link to a clean BIDIRECTIONAL state ..."
clean=0
for r in $(seq 1 "$MAX_ROLLS"); do
  bsh "$A_IP" "echo tidelink.bin > $FW"; bsh "$B_IP" "echo tidelink.bin > $FW"   # re-POR both
  sleep 2
  wrr "$A_IP" $UNLOCK 0x1; wrr "$A_IP" $ROLE 0x2     # die_a: debug-unlock + master + role_lock W1S
  wrr "$B_IP" $UNLOCK 0x1; wrr "$B_IP" $ROLE 0x3     # die_b: debug-unlock + slave  + role_lock W1S
  sleep "$DWELL"
  vlog "roll $r: $(statline)"
  # (a)+(b) link-up + credit both ways
  if ! { linkup "$A_IP" && linkup "$B_IP" && credok "$A_IP" && credok "$B_IP"; }; then
    vlog "roll $r: link/credit not clean — re-POR"
    continue
  fi
  # (c)+(d) require PROBE_K consecutive deliveries EACH direction. A single probe
  # passes on a MARGINAL eye by luck (held sends then flicker, as roll-14 showed);
  # K-in-a-row selects a STRONGLY-good sample phase where A->B is stably open.
  if ! pk_ok "$B_IP" "$A_IP"; then vlog "roll $r: B->A not $PROBE_K/$PROBE_K — re-POR"; continue; fi
  if ! pk_ok "$A_IP" "$B_IP"; then vlog "roll $r: A->B not $PROBE_K/$PROBE_K (marginal phase) — re-POR"; continue; fi
  log "[roll] CLEAN BIDIRECTIONAL on roll $r — link up both ways + B->A AND A->B both delivered"
  log "        $(statline)"
  clean=1; break
done
[ "$clean" = 1 ] || fail "no clean BIDIRECTIONAL roll in $MAX_ROLLS tries (marginal-eye lottery — raise --rolls, or RX too marginal -> rebuild)"

# ---- optional WORD_PIN belt-and-suspenders (HELD link, no re-POR) -----------
if [ -n "$WORD_PIN" ]; then
  win=$WORD_PIN
  pat=$(printf '0x%08X' $(( (win & 0xF) * 0x11111111 )))
  log "[hold] WORD_PIN: latching die_b word_pin to window $win (WP_WIN=$pat, WP_EN=0xFF) — link HELD"
  wrr "$B_IP" $WP_WIN "$pat"     # 0x44032148 = win*0x11111111 (nibble-per-lane window select)
  wrr "$B_IP" $WP_EN  0xFF       # 0x4403214C = enable word_pin on all 8 lanes
fi

# ---- [hold] N interleaved bidirectional sends, NO re-POR -------------------
log "[hold] link HELD on the good phase — running $SENDS interleaved B->A + A->B sends (NO re-POR)"
b2a_ok=0; a2b_ok=0
for i in $(seq 1 "$SENDS"); do
  if send_probe "$B_IP" "$A_IP" >/dev/null; then b2a_ok=$((b2a_ok+1)); b2a_r=PASS; else b2a_r=FAIL; fi
  if send_probe "$A_IP" "$B_IP" >/dev/null; then a2b_ok=$((a2b_ok+1)); a2b_r=PASS; else a2b_r=FAIL; fi
  log "  send $i/$SENDS: B->A=$b2a_r  A->B=$a2b_r"
done

echo "=================================================================="
echo "  B->A delivery: $b2a_ok/$SENDS"
echo "  A->B delivery: $a2b_ok/$SENDS"
if [ "$b2a_ok" = "$SENDS" ] && [ "$a2b_ok" = "$SENDS" ]; then
  echo "RESULT: PASS — RELIABLE BIDIRECTIONAL $b2a_ok/$SENDS + $a2b_ok/$SENDS (held good-phase link, word_pin ${WORD_PIN:-OFF})"
  verdict=0
else
  echo "RESULT: FAIL — bidirectional NOT fully reliable: B->A $b2a_ok/$SENDS, A->B $a2b_ok/$SENDS"
  verdict=1
fi
echo "  final link: $(statline)"
echo "=================================================================="
exit $verdict

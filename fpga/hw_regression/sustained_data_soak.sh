#!/bin/bash
# =============================================================================
# sustained_data_soak.sh — CONTINUAL data movement + the FIRST throughput
# measurement of the TideLink channel.
#
# WHY THIS EXISTS
#   Everything proven on silicon to date is ONE 4-word framed packet per
#   direction on a quiescent link (proven_method_soak.sh). That proves "a packet
#   works". It does NOT prove "the channel works": there is no back-to-back
#   traffic test, no burst-length sweep, and NO THROUGHPUT NUMBER AT ALL.
#   This script closes that gap.
#
# WHAT IT DOES (per burst size, per direction)
#   fresh POR -> deploy -> zero-poke autonomous bring-up (TD_AUTONOMOUS=1)
#   -> enter_data_mode -> push K framed packets BACK-TO-BACK -> drain them with
#   the protocol-legal sweep -> byte-compare EVERY word (incl. the first two)
#   -> report words/sec + payload bytes/sec.
#
# THE RECORDED BUG THIS TARGETS
#   "long-burst drops first ~2 words (both directions)" (2026-07-11, never
#   re-tested since).
#
#   SIM STATUS (2026-07-15, see docs/SUSTAINED_DATA_2026_07_15.md):
#     * EPOCH_PROFILE=zero  (ideal link): does NOT reproduce. Byte-exact to 126
#       payload words both directions. The datapath/FIFO/credit are sound.
#     * EPOCH_PROFILE=silicon (v37 fingerprint, 3-7 word cross-lane skew): DOES
#       reproduce. s2m len=8 isolated -> first_bad_idx=0 with got[0]=payload[2]
#       — the recorded silicon signature verbatim. m2s passes in isolation but
#       fails after ACCUMULATED traffic.
#   So the bug is skew-dependent, which is exactly why only real silicon can
#   settle it. Expect s2m (B->A, the marginal direction) to be the one that
#   fails here, and expect m2s to need SUSTAINED traffic before it does.
#
#   Two live mechanisms alias onto this one symptom — do not attribute without
#   measuring:
#     1. FCSM stream-start NACK/revert storm (fix/stream-start-loss 330e2a7,
#        NOT in this base) — a LINK defect; wedges exp, loses leading words.
#     2. Phantom-pop (fixed f9b94b7) — a READER defect; read_ptr walks 2 words.
#   Discriminate with the RXDETAIL flags below: CREDIT_ABOVE_MAX/underrun point
#   at the reader; a wedged link with fcsm/fe_full stuck points at the storm.
#
#   Note "~2 words" is also EXACTLY the phantom-pop signature (read_ptr walks 2
#   words on an empty-FIFO read; project_rxfifo_empty_read_phantom_pop). If this
#   script reproduces a 2-word LEADING shift, suspect the reader, not the link,
#   and check `underrun`/credit-above-max via `status`/`occ` before blaming the
#   channel.
#
# USAGE
#   ./sustained_data_soak.sh [options]
#     --sizes "4 8 16 32 64 128"   payload word counts to sweep (default below)
#     --packets K                  packets per size per direction (default 8)
#     --cycles N                   fresh-POR cycles (default 1)
#     --dir a2b|b2a|both           direction(s) (default both)
#     --manual                     rcp() recipe instead of zero-poke autonomy
#     --no-lease                   caller already holds the lease
#     --keep                       do not release the lease on exit
#     --no-deploy                  skip deploy (boards already carry the bits)
#   env: TD_A_IP TD_B_IP TD_HUB_A TD_HUB_B TD_DEPLOY_DIR TD_DEPLOY_SH
#        TD_AUTO_WAIT TD_THROTTLE TD_PKT_GAP
#
#   Typical first run (boards free, you hold nothing):
#     ./sustained_data_soak.sh --sizes "4 16 64" --packets 8 --cycles 1
#
# SAFETY RULES BAKED IN (do not remove)
#   * NEVER reads 0x440321AC / 0x440321B0 / 0x440321B4 — those SIGBUS-wedge the
#     PS (recover only by power-cycle). Zero-poke autonomy needs no winscan, so
#     this script never calls winscan().
#   * Host-side status reads are throttled (TD_THROTTLE). The board-side data
#     drain uses EXACTLY the access pattern tl39.py's proven `drain` already
#     uses (single aligned 32-bit ctypes reads, offset 0 first) — never a
#     struct/memoryview multi-beat access, which silently pops extra entries.
#   * NEVER pre-drains the RX FIFO. A fresh POR leaves it empty, and a read of
#     an empty FIFO pops a PHANTOM zero-length packet (walks read_ptr 2 words +
#     mints credit above max). Removing exactly such a drain took a prior soak
#     from 0/6 to 8/8.
#   * Never PL-reloads a live link: every cycle is a true power-cycle POR first.
#   * Bounded packet counts; total words per size stay under the 4096-word RX
#     FIFO so the sender cannot wedge on exhausted credit with no drainer.
#
# WHAT THE THROUGHPUT NUMBERS MEAN (read before quoting them)
#   tx_wps   words/sec the PS can push into the TX aperture, timed ON die_a.
#            With total words << FIFO depth this is the HOST store rate, NOT
#            the link rate — the FIFO absorbs the burst.
#   rx_wps   words/sec the receiving PS drains, timed ON die_b.
#   e2e_wps  delivered words/sec over the whole send+settle+drain wall time.
#            A LOWER BOUND (includes SSH + settle).
#   The link word clock is 2.343 MHz (426.7 ns UI). If tx_wps lands far below
#   that, the PS store rate is the bottleneck, not the channel — say so rather
#   than reporting a "link throughput" the link never limited.
#
# Runs ON the lab host. Sources td_v2_hwlib.sh.
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

SIZES="4 8 16 32 64 128"
PACKETS=8
CYCLES=1
DIRS="both"
AUTONOMOUS=${TD_AUTONOMOUS:-1}
DO_LEASE=1; KEEP_LEASE=0; DO_DEPLOY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sizes) SIZES="$2"; shift;;
    --packets) PACKETS="$2"; shift;;
    --cycles) CYCLES="$2"; shift;;
    --dir) DIRS="$2"; shift;;
    --manual) AUTONOMOUS=0;;
    --no-lease) DO_LEASE=0;;
    --keep) KEEP_LEASE=1;;
    --no-deploy) DO_DEPLOY=0;;
    -h|--help) sed -n '2,70p' "$0"; exit 0;;
    *) echo "unknown option: $1"; exit 2;;
  esac
  shift
done

AUTO_WAIT=${TD_AUTO_WAIT:-45}
PKT_GAP=${TD_PKT_GAP:-0}          # board-side sleep between packets (0 = true b2b)
HUB_A=${TD_HUB_A:-pynq_z2_02_ps}
HUB_B=${TD_HUB_B:-pynq_z2_01_pl}
BOARD_PW=${TD_BOARD_PW:-xilinx}
R_NEGO_CFG_A=0x44032090
R_NEGO_TRAIN_A=0x4403210C
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
CSV="sustained_data_soak_${STAMP}.csv"

# RX FIFO is 4096 words (RAM_ADDR_W=14 -> MAX_CREDITS=1<<12). Refuse to offer
# more than half of it with no concurrent drainer: the sender would exhaust
# credit and stall (and on a marginal die that stall has wedged the PS before).
FIFO_WORDS=4096

pc_one(){ fpgahub hub power-cycle "$1" --off 2 --yes >/dev/null 2>&1; }
wait_ssh(){ local ip="$1" i
  for i in $(seq 1 40); do
    sshpass -p "$BOARD_PW" ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=4 "xilinx@$ip" true >/dev/null 2>&1 && return 0
    sleep 2
  done; return 1
}
por(){ pc_one "$HUB_A" & pc_one "$HUB_B" & wait; wait_ssh "$A_IP" && wait_ssh "$B_IP"; }

# ---------------------------------------------------------------------------
# Board-side workers. Pushed via base64 (the winscan idiom) so the TIMING is
# taken ON the board — an SSH round trip per word would measure the network,
# not the channel.
# ---------------------------------------------------------------------------

# SENDER: write K framed packets of PAYLOAD_N words back-to-back, timed.
# Frame layout (tidelink/packet.py encode_word0 + fifo_ctrl):
#   word0 = length<<20 | pkt_type<<18 ; word1 = dest_addr ; then payload.
# pkt_type=1 (PKT_WR_REQ) matches the proven TX_HDR 0x00240000 (len=2,type=1).
read -r -d '' TX_PY <<'PYEOF'
import mmap, os, sys, time, ctypes
PAGE=4096; TXBASE=0x84000000
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC); maps={}
def mm(a):
    b=a & ~(PAGE-1)
    if b not in maps:
        maps[b]=mmap.mmap(fd,PAGE,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
    return maps[b], a-b
def wr(a,v):
    m,o=mm(a); ctypes.c_uint32.from_buffer(m,o).value = v & 0xFFFFFFFF
n=int(sys.argv[1]); k=int(sys.argv[2]); seed=int(sys.argv[3],16); gap=float(sys.argv[4])
pkts=[]
for p in range(k):
    w0=((n & 0xFFF)<<20) | (1<<18)
    pkts.append([w0,0x0]+[((seed+p)<<16)|i for i in range(n)])
t0=time.time()
for words in pkts:
    for i,w in enumerate(words): wr(TXBASE+i*4, w)
    if gap: time.sleep(gap)
t1=time.time()
tot=sum(len(w) for w in pkts)
print("TXDONE words=%d packets=%d secs=%.6f" % (tot,k,t1-t0))
PYEOF

# RECEIVER: drain K packets with the protocol-legal sweep and byte-check EVERY
# word against the expected frame — including word[0] and word[1], which the
# legacy 4-word oracle never checked. Reports the first bad index per packet so
# a LEADING 2-word shift (the recorded signature) is unambiguous.
read -r -d '' RX_PY <<'PYEOF'
import mmap, os, sys, time, ctypes
PAGE=4096; RXBASE=0x84010000; STATUS=0x44032010; CREDIT=0x4403200C
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC); maps={}
def mm(a):
    b=a & ~(PAGE-1)
    if b not in maps:
        maps[b]=mmap.mmap(fd,PAGE,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
    return maps[b], a-b
def rd(a):
    m,o=mm(a); return ctypes.c_uint32.from_buffer(m,o).value
n=int(sys.argv[1]); k=int(sys.argv[2]); seed=int(sys.argv[3],16)
st0=rd(STATUS); cr0=rd(CREDIT)&0xffff
ok=0; bad=0; details=[]
t0=time.time()
for p in range(k):
    exp=[((n & 0xFFF)<<20)|(1<<18), 0x0]+[((seed+p)<<16)|i for i in range(n)]
    # Protocol-legal drain: offset 0 FIRST (arms the length latch), then
    # consecutive offsets; the read of (length+1)*4 fires the pop.
    hdr=rd(RXBASE)
    length=(hdr>>20)&0xFFF
    total=length+2
    if total<2 or total>len(exp)+2:
        # A wild length means the stream is already desynced; stop rather than
        # sweep a bogus range (that is how you walk the pointer further).
        details.append("pkt%d WILDLEN hdr=0x%08x len=%d" % (p,hdr,length))
        bad+=1; break
    got=[hdr]+[rd(RXBASE+i*4) for i in range(1,total)]
    if got==exp:
        ok+=1
    else:
        bad+=1
        fb=next((i for i in range(min(len(got),len(exp))) if got[i]!=exp[i]), len(exp))
        details.append("pkt%d FIRSTBAD=%d exp=0x%08x got=0x%08x nwords=%d/%d"
                       % (p,fb,exp[fb] if fb<len(exp) else 0,
                          got[fb] if fb<len(got) else 0,len(got),len(exp)))
t1=time.time()
st1=rd(STATUS); cr1=rd(CREDIT)&0xffff
words=ok*(n+2)
print("RXDONE ok=%d bad=%d secs=%.6f words=%d cr0=%d cr1=%d st0=0x%x st1=0x%x"
      % (ok,bad,t1-t0,words,cr0,cr1,st0,st1))
# MAX_CREDITS = 1<<12 (RAM_ADDR_W=14). Credit above max is an IMPOSSIBLE state:
# the RX now advertises more space than it physically has and the peer may
# overrun it. Fixed in RTL 2026-07-15 (tidelink_fifo_ctrl saturate-at-MAX); if
# this fires, the deployed bitstream PREDATES that fix -- say so rather than
# reporting a data result from a link with fabricated credit.
if cr1 > 4096 or cr0 > 4096:
    print("  RXDETAIL CREDIT_ABOVE_MAX cr0=%d cr1=%d (MAX=4096) — bitstream "
          "predates the saturate-at-MAX fix; credit is fabricated" % (cr0,cr1))
if st1 & (1<<2):
    print("  RXDETAIL UNDERRUN sticky (st1=0x%x) — a read found no packet" % st1)
if st1 & (1<<1):
    print("  RXDETAIL OVERRUN sticky (st1=0x%x) — a write was discarded" % st1)
for d in details[:6]: print("  RXDETAIL "+d)
PYEOF

# Board-side worker timeout. A store into the TX aperture BLOCKS while the FC
# adapter holds HREADYOUT low, so if credit return is broken the sender sits in
# an uninterruptible kernel store and the SSH call would hang forever. The
# timeout lets the harness report a STALL and move on rather than wedging the
# whole soak. (It does NOT unwedge the board — a wedged PS still needs a
# power-cycle, which the next cycle's por() performs.)
PUSH_TIMEOUT=${TD_PUSH_TIMEOUT:-120}

push_run(){ # ip, python-body, args...
  local ip="$1" body="$2"; shift 2
  local b64; b64=$(printf '%s' "$body" | base64 -w0)
  timeout "$PUSH_TIMEOUT" $SSH "xilinx@$ip" \
    "echo $b64 | base64 -d > /tmp/td_sust.py && echo $BOARD_PW | sudo -S python3 /tmp/td_sust.py $*" 2>/dev/null
  local rc=$?
  [ "$rc" = 124 ] && echo "TIMEOUT after ${PUSH_TIMEOUT}s"
  return 0
}

bringup(){ # returns 0 healthy, 1 unarmed(non-test), 2 link down
  if [ "$AUTONOMOUS" = 1 ]; then
    local ca cb ta tb
    ca=$(( $(a rd $R_NEGO_CFG_A) & 0x7f )); cb=$(( $(b rd $R_NEGO_CFG_A) & 0x7f ))
    ta=$(( $(a rd $R_NEGO_TRAIN_A) & 1 ));  tb=$(( $(b rd $R_NEGO_TRAIN_A) & 1 ))
    if [ $(( ca & 1 )) -ne 1 ] || [ "$ta" -ne 1 ] || [ $(( cb & 1 )) -ne 1 ] || [ "$tb" -ne 1 ]; then
      printf '  UNARMED (NEGO_CFG a=0x%02x b=0x%02x train a=%s b=%s) — NON-TEST\n' "$ca" "$cb" "$ta" "$tb"
      return 1
    fi
    local i
    for i in $(seq 1 "$AUTO_WAIT"); do
      sleep 1
      [ "$(reanchored_d a)" = 1 ] && [ "$(reanchored_d b)" = 1 ] \
        && [ "$(fcsm a)" = 4 ] && [ "$(fcsm b)" = 4 ] && break
    done
  else
    rcp
    local i; for i in $(seq 1 8); do sleep 1; [ "$(reanchored)" = 1 ] && break; done
  fi
  [ "$(fcsm a)" = 4 ] && [ "$(fcsm b)" = 4 ] \
    && [ "$(reanchored_d a)" = 1 ] && [ "$(reanchored_d b)" = 1 ] || return 2
  return 0
}

# One (direction, size) measurement. Echoes a CSV fragment.
run_one(){ # dir size
  local dir="$1" n="$2" seed sender recver tx rx
  local tot=$(( PACKETS * (n + 2) ))
  if [ "$tot" -gt $(( FIFO_WORDS / 2 )) ]; then
    printf '    size=%-4s SKIP (offered %d words > half the %d-word RX FIFO; no concurrent drainer)\n' \
      "$n" "$tot" "$FIFO_WORDS"
    echo "$dir,$n,SKIP,,,,,," >> "$CSV"; return
  fi
  if [ "$dir" = "a2b" ]; then sender=$A_IP; recver=$B_IP; seed=a2b0; else sender=$B_IP; recver=$A_IP; seed=b2a0; fi

  local w0=$SECONDS
  tx=$(push_run "$sender" "$TX_PY" "$n" "$PACKETS" "$seed" "$PKT_GAP")
  if echo "$tx" | grep -q TIMEOUT; then
    # The sender blocked in a TX-aperture store => credit return stalled. This
    # is the fe_tx_credit_max / send-gate failure mode, NOT a data-integrity
    # result — record it as such rather than scoring it as a byte mismatch.
    printf '    size=%-4s TX-STALL (sender blocked >%ss in a TX store; credit return suspect — check fe_full/fcsm)\n' \
      "$n" "$PUSH_TIMEOUT"
    echo "$dir,$n,TX_STALL,0,$PACKETS,,,," >> "$CSV"; return
  fi
  sleep 1.5
  rx=$(push_run "$recver" "$RX_PY" "$n" "$PACKETS" "$seed")
  if echo "$rx" | grep -q TIMEOUT; then
    printf '    size=%-4s RX-STALL (receiver blocked >%ss in a drain)\n' "$n" "$PUSH_TIMEOUT"
    echo "$dir,$n,RX_STALL,0,$PACKETS,,,," >> "$CSV"; return
  fi
  local e2e=$(( SECONDS - w0 )); [ "$e2e" -lt 1 ] && e2e=1

  # Anchor every extractor to the ^TXDONE / ^RXDONE summary line and take the
  # first match. `sed -n s///p` prints for EVERY matching line, and the
  # RXDETAIL lines carry "nwords=%d/%d" — an unanchored `.*words=` would also
  # match those, making $rw multi-line and breaking the arithmetic below.
  local tw ts rok rbad rs rw
  tw=$(echo "$tx"  | sed -n 's/^TXDONE .*words=\([0-9]*\).*/\1/p'   | head -1)
  ts=$(echo "$tx"  | sed -n 's/^TXDONE .*secs=\([0-9.]*\).*/\1/p'   | head -1)
  rok=$(echo "$rx" | sed -n 's/^RXDONE ok=\([0-9]*\).*/\1/p'        | head -1)
  rbad=$(echo "$rx"| sed -n 's/^RXDONE .*bad=\([0-9]*\).*/\1/p'     | head -1)
  rs=$(echo "$rx"  | sed -n 's/^RXDONE .*secs=\([0-9.]*\).*/\1/p'   | head -1)
  rw=$(echo "$rx"  | sed -n 's/^RXDONE .*words=\([0-9]*\).*/\1/p'   | head -1)
  : "${tw:=0}" "${ts:=0}" "${rok:=0}" "${rbad:=$PACKETS}" "${rs:=0}" "${rw:=0}"
  # A worker that printed nothing parsable (crash, python traceback swallowed by
  # 2>/dev/null) must not silently become "0 words in 0 secs" = a fake result.
  if [ "$tw" = 0 ] || [ "$rs" = 0 ] && [ "$rok" = 0 ]; then
    printf '    size=%-4s NO-RESULT (worker produced no parsable summary; tx=%q rx=%q)\n' \
      "$n" "${tx:0:60}" "${rx:0:60}"
    echo "$dir,$n,NO_RESULT,0,$PACKETS,,,," >> "$CSV"; return
  fi

  local txwps rxwps e2ewps bps
  txwps=$(python3 -c "print('%.0f'%($tw/$ts))" 2>/dev/null || echo 0)
  rxwps=$(python3 -c "print('%.0f'%($rw/$rs))" 2>/dev/null || echo 0)
  e2ewps=$(python3 -c "print('%.0f'%($rw/$e2e))" 2>/dev/null || echo 0)
  bps=$(python3 -c "print('%.0f'%(($rok*$n*4)/$e2e))" 2>/dev/null || echo 0)

  # PASS demands BOTH: every packet accounted for AND zero scored bad. A
  # receiver that bailed early (WILDLEN) reports ok<PACKETS; one that read
  # every packet but mis-compared reports bad>0.
  local verdict=PASS
  { [ "$rok" = "$PACKETS" ] && [ "$rbad" = 0 ]; } || verdict=FAIL
  printf '    size=%-4s %s  pkts_ok=%s/%s  tx=%s w/s  rx=%s w/s  e2e=%s w/s (%s payload B/s)\n' \
    "$n" "$verdict" "$rok" "$PACKETS" "$txwps" "$rxwps" "$e2ewps" "$bps"
  echo "$rx" | sed -n 's/^  RXDETAIL/      RXDETAIL/p'
  echo "$dir,$n,$verdict,$rok,$PACKETS,$txwps,$rxwps,$e2ewps,$bps" >> "$CSV"
}

MODE_STR=$([ "$AUTONOMOUS" = 1 ] && echo "ZERO-POKE AUTONOMOUS (no writes; POR-armed)" || echo "RECIPE (rcp; autonomy OFF)")
echo "=============================================================="
echo " sustained_data_soak   cycles=$CYCLES packets/size=$PACKETS"
echo "   sizes:     $SIZES   dirs: $DIRS"
echo "   bring-up:  $MODE_STR"
echo "   link word clock 2.343 MHz (426.7 ns UI) — compare tx w/s against it"
echo "=============================================================="
[ "$DO_LEASE" = 1 ] && { lease_acquire $(( CYCLES * 900 + 600 )) || { echo "### ABORT: no $LEASE_NAME lease"; exit 3; }; }
trap '[ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release' EXIT

echo "dir,payload_words,verdict,pkts_ok,pkts_sent,tx_wps,rx_wps,e2e_wps,payload_Bps" > "$CSV"
case "$DIRS" in both) DLIST="a2b b2a";; *) DLIST="$DIRS";; esac

for c in $(seq 1 "$CYCLES"); do
  echo "--- cycle $c/$CYCLES ---"
  if ! por; then echo "  POR-FAIL (a board did not return) — skipping cycle"; continue; fi
  [ "$DO_DEPLOY" = 1 ] && { deploy_pair; sleep 2; }
  bringup; rc=$?
  if [ "$rc" = 1 ]; then echo "  cycle excluded (unarmed)"; continue; fi
  if [ "$rc" = 2 ]; then
    printf '  LINK DOWN (fcsm %s/%s rea_a=%s rea_b=%s) — data not attempted\n' \
      "$(fcsm a)" "$(fcsm b)" "$(reanchored_d a)" "$(reanchored_d b)"
    continue
  fi
  enter_data_mode
  echo "  link up (fcsm 4/4, reanchored both). NO pre-drain (fresh POR => RX FIFO empty)."
  for d in $DLIST; do
    echo "  direction $d:"
    for n in $SIZES; do run_one "$d" "$n"; done
  done
done

echo "=============================================================="
echo " per-size results: $CSV"
echo
echo " Read the throughput numbers with the caveats in this file's header:"
echo "   tx_wps is the PS store rate unless the burst exceeds the RX FIFO;"
echo "   e2e_wps includes SSH + settle and is a LOWER BOUND."
echo " A FAIL with FIRSTBAD=0..1 is a LEADING-word loss = the recorded"
echo " 'drops first ~2 words' signature; check st1 underrun[2] and whether"
echo " cr1 exceeds 4096 (credit above max => phantom-pop class, blame the"
echo " reader, not the link)."
echo "=============================================================="

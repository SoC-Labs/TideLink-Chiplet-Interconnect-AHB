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
# THE RECORDED BUG THIS TARGETS — SETTLED 2026-07-16: IT DOES NOT REPRODUCE
#   "long-burst drops first ~2 words (both directions)" (2026-07-11).
#
#   SILICON RESULT (2026-07-16, cd2db38 bitstream, zero-poke autonomous):
#     24/24 byte-exact. Sizes 4/8/16/32/64/128 at 8 back-to-back packets each,
#     plus 256/512/1024, BOTH directions, every word checked incl. the leading
#     two. Zero dropped words. Run with --negctl (below) validating the oracle
#     on the same live link first.
#   => This CONFIRMS the 07-14 phantom-pop attribution: the 07-11 report was the
#      harness's pre-send `rxn` drain popping a phantom packet and walking
#      read_ptr 2 words. RTL f9b94b7 + harness f3c5359 are both in this base.
#
#   SIM STATUS (see docs/SUSTAINED_DATA_2026_07_15.md):
#     * EPOCH_PROFILE=zero (ideal link): does NOT reproduce; byte-exact to 126
#       payload words both directions. Agrees with silicon.
#     * EPOCH_PROFILE=silicon: RED, but USELESS as evidence — under that same
#       compile the baseline single-4-word-packet suite (test_v2_pair_data)
#       ALSO fails 2/3, including test_01_bilateral_linkup, on PRISTINE cd2db38
#       RTL. A profile that cannot bring the link up cannot demonstrate a
#       burst-length effect. An earlier header here claimed it reproduced there;
#       that claim is RETRACTED. Every sim_gate target runs EPOCH_PROFILE=zero,
#       so nothing keeps `silicon` green -- it is an ungated known-red config.
#
#   If a future run DOES show a 2-word LEADING shift: "~2 words" is exactly the
#   phantom-pop signature (read_ptr walks 2 words on an empty-FIFO read;
#   project_rxfifo_empty_read_phantom_pop). Suspect the READER first — check
#   `underrun` / credit-above-max in the RXDETAIL lines before blaming the
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
#     --negctl                     run the ADVERSARIAL controls first (see
#                                  negctl() below). Each MUST come out RED; a
#                                  green control means the sweep's PASS is
#                                  vacuous. Run this before quoting any PASS.
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
#   *** DO NOT QUOTE THIS SCRIPT'S w/s AS THE CHANNEL'S THROUGHPUT. ***
#   The Python sender here reports ~24-27k words/s. That is CPython, not
#   TideLink: the identical ctypes store loop into ANONYMOUS memory (no AXI, no
#   link) measures 96k words/s on this PS, so this instrument's own ceiling is
#   ~24x BELOW the 2.343 MHz link and can never saturate the channel.
#   Use fpga/hw_regression/td_tput.c (compiled C) for throughput. It measures
#   ~48.8k words/s ~= 195 kB/s sustained = ~2.1% of the 2.343 Mword/s ceiling
#   (~48 link UIs per 32-bit word), with --busref as the control proving the
#   plateau is DUT-imposed rather than PS<->PL bridge cost.
#
#   This script's job is BYTE-EXACTNESS, which it does well. Its numbers:
#   tx_wps   words/sec CPython can push into the TX aperture, timed ON die_a.
#            Host-limited; see above.
#   rx_wps   words/sec the receiving PS drains, timed ON die_b. Host-limited.
#   e2e_wps  delivered words/sec over the whole send+settle+drain wall time.
#            A LOWER BOUND (includes SSH + settle).
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
DO_LEASE=1; KEEP_LEASE=0; DO_DEPLOY=1; DO_NEGCTL=${TD_NEGCTL:-0}
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
    --negctl) DO_NEGCTL=1;;
    # Print the whole leading comment block — a hardcoded line range rots the
    # moment the header grows (it already had).
    -h|--help) awk 'NR==1{next} /^[^#]/{exit} {print}' "$0"; exit 0;;
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
# Optional NEGATIVE-CONTROL knob (default 0 = normal scoring, bit-identical to
# before this arg existed). shift>0 emulates the recorded "dropped the first
# `shift` words" defect by shifting the EXPECTATION, so a correct transfer must
# be scored FAIL with FIRSTBAD=0. That proves this oracle can actually SEE the
# signature it claims to be hunting -- a PASS from an oracle never shown to
# fail is worthless (see feedback_verify_instrument_before_dut).
shift=int(sys.argv[4]) if len(sys.argv)>4 else 0
st0=rd(STATUS); cr0=rd(CREDIT)&0xffff
ok=0; bad=0; details=[]
t0=time.time()
for p in range(k):
    exp=[((n & 0xFFF)<<20)|(1<<18), 0x0]+[((seed+p)<<16)|i for i in range(n)]
    if shift: exp=exp[shift:]+[0]*shift
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

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL (--negctl) — prove the instrument HAS TEETH before believing
# any PASS from it.
#
# This suite passed 12/12 on its first silicon run (sizes 4..128, both
# directions, byte-exact). That is exactly the shape of a result that has
# burned this project repeatedly: the pair TB delivered B->A "byte-exact" on
# RTL that was 0/10 on silicon, and was blind to the SRAM X-init phantom-pop.
# A green oracle that has never been shown to go red is not evidence.
#
# Each control below MUST come out RED. If any goes green, the sweep's PASS is
# vacuous and must not be reported as a result.
#   NEG-1  drain with NOTHING sent      -> proves the checker reads THIS
#                                          transfer, not residue/stale bytes.
#   NEG-2  send seed X, expect seed Y   -> proves it compares real payload.
#   NEG-3  correct send, expectation
#          shifted by 2 words           -> proves the EXACT recorded signature
#                                          ("drops first ~2 words") is visible.
# POS     correct send, correct expect  -> must be GREEN, so the controls above
#                                          failed for the right reason and the
#                                          link was healthy throughout.
# ---------------------------------------------------------------------------
negctl(){
  local n=16 fails=0
  echo "  --- NEGATIVE CONTROLS (each MUST fail; a green control invalidates the sweep) ---"

  # NEG-1: no send at all. A fresh-POR RX FIFO is empty; scoring must not pass.
  local r1; r1=$(push_run "$B_IP" "$RX_PY" "$n" 1 a2b0)
  if echo "$r1" | grep -q "ok=1 bad=0"; then
    echo "    NEG-1 no-send drain      : *** GREEN — INSTRUMENT IS BLIND (reading residue) ***"; fails=1
  else
    echo "    NEG-1 no-send drain      : RED (good) -> $(echo "$r1" | sed -n 's/^RXDONE //p' | head -1)"
  fi

  # NEG-2: real send, wrong expected seed.
  push_run "$A_IP" "$TX_PY" "$n" 1 a2b0 0 >/dev/null; sleep 1.5
  local r2; r2=$(push_run "$B_IP" "$RX_PY" "$n" 1 dead)
  if echo "$r2" | grep -q "ok=1 bad=0"; then
    echo "    NEG-2 wrong-seed compare : *** GREEN — oracle is not comparing payload ***"; fails=1
  else
    echo "    NEG-2 wrong-seed compare : RED (good) -> $(echo "$r2" | sed -n 's/^RXDONE //p' | head -1)"
  fi

  # NEG-3: correct send, expectation shifted 2 words = the recorded signature.
  push_run "$A_IP" "$TX_PY" "$n" 1 b0b0 0 >/dev/null; sleep 1.5
  local r3; r3=$(push_run "$B_IP" "$RX_PY" "$n" 1 b0b0 2)
  # A RED here is only meaningful if it failed because of the SHIFT (FIRSTBAD=0)
  # and NOT because the packet never arrived. The `underrun` flag is STICKY and
  # NEG-1's deliberate empty read already set it, so the RXDETAIL underrun line
  # is expected noise here -- anchor on the FIRSTBAD line instead.
  local fb3; fb3=$(echo "$r3" | sed -n 's/.*\(FIRSTBAD=[0-9]*\).*/\1/p' | head -1)
  if echo "$r3" | grep -q "ok=1 bad=0"; then
    echo "    NEG-3 2-word-shift detect: *** GREEN — a 2-word LEADING SHIFT IS INVISIBLE ***"; fails=1
  elif [ "$fb3" = "FIRSTBAD=0" ]; then
    echo "    NEG-3 2-word-shift detect: RED (good) -> $fb3 = the shift was seen at word 0, as intended"
  else
    echo "    NEG-3 2-word-shift detect: RED but for the WRONG REASON (${fb3:-no FIRSTBAD; packet may not have arrived}) — control inconclusive"; fails=1
  fi

  # POS: correct send, correct expectation, same link — must be green.
  push_run "$A_IP" "$TX_PY" "$n" 1 c0c0 0 >/dev/null; sleep 1.5
  local r4; r4=$(push_run "$B_IP" "$RX_PY" "$n" 1 c0c0)
  if echo "$r4" | grep -q "ok=1 bad=0"; then
    echo "    POS   correct compare    : GREEN (good) — link healthy; controls failed for the right reason"
  else
    echo "    POS   correct compare    : *** RED — link unhealthy; the controls above prove nothing ***"; fails=1
  fi

  [ "$fails" = 0 ] && echo "  --- instrument HAS TEETH: sweep results are trustworthy ---" \
                   || echo "  --- INSTRUMENT UNTRUSTWORTHY: do not report the sweep as a result ---"
  return "$fails"
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
  # Controls run FIRST, on this same live link, so "the instrument has teeth"
  # is established on the very link the sweep then measures -- not on some
  # other cycle where the link may have differed.
  [ "${DO_NEGCTL:-0}" = 1 ] && negctl
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

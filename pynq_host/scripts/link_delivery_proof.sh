#!/usr/bin/env bash
# =============================================================================
# link_delivery_proof.sh — prove an allegedly-up TideLink link actually
# DELIVERS data, end to end, with one packet.
#
# Motivation (2026-06-12): the Wlink FE credit value received in the CR
# packet intermittently garbles on RX (deskew ~97% coherence residual).
# SWI_LANE_STATUS[31] fe_rx_is_full only flags the garbled-to-ZERO case;
# a credit garbled to a small NONZERO value lets 1-4 packets through and
# then wedges — the link "looks up" on every status probe but cannot carry
# traffic. The only honest health check is a delivered packet.
#
# What it does:
#   1. Reads OBS_FC_CREDIT (0x4403219C, new in the 2026-06-12 RTL) on both
#      boards and prints fe_rx_credit_max / fe_rx_ptr. Degrades gracefully
#      on older images (slot reads 0x00000000 — marker byte [31:24]=0xFC
#      absent means "obs not in this image").
#   2. Verifies pre-send state: fcsm=4 (LINK_IDLE) both sides, training=0
#      both sides (0x44032100 bit0), fe_rx_is_full=0 both sides.
#   3. Sends ONE 4-word packet master->slave via the AHB_TX aperture
#      (TIDELINK_TX_BASE env, default 0x44000000; use 0x84000000 on
#      GP1-split images): hdr 0x00240000 (WR_REQ, 2 payload words) + addr
#      + 2 payload words.
#   4. Verifies it LANDS in the slave RX FIFO: occupancy delta via
#      CREDIT_COUNT (0x4403200C), pops via TIDELINK_RXFIFO_BASE (default
#      0x44010000; 0x84010000 on GP1-split) and byte-compares the header.
#   5. Exit 0 ONLY on verified delivery. One-line verdict on the last line.
#
# Usage:
#   link_delivery_proof.sh <MASTER_IP> <SLAVE_IP>
# Env:
#   TIDELINK_TX_BASE      AHB_TX aperture on the master  (default 0x44000000)
#   TIDELINK_RXFIFO_BASE  RX FIFO aperture on the slave  (default 0x44010000)
#   TIDELINK_BOARD_PASS   board password                 (default xilinx)
#   TIDELINK_CATCH_TIMEOUT_S  slave-side wait for the packet (default 5)
#
# Exit codes: 0 = verified delivery, 1 = pre-send state bad, 2 = packet did
# not land / header mismatch, 3 = comms/staging failure.
#
# Register decode modeled on pynq_host/scripts/tlchar.py (authoritative
# SWI_LANE_STATUS 0x108 decode). Staged-python-helper pattern per
# pynq_host/scripts/unjam_fc_node.sh — NO inline python through double-ssh
# quoting (it mangles).
# =============================================================================
set -u

MASTER="${1:?usage: link_delivery_proof.sh <MASTER_IP> <SLAVE_IP>}"
SLAVE="${2:?usage: link_delivery_proof.sh <MASTER_IP> <SLAVE_IP>}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
TXB="${TIDELINK_TX_BASE:-0x44000000}"
RXB="${TIDELINK_RXFIFO_BASE:-0x44010000}"
CATCH_TIMEOUT="${TIDELINK_CATCH_TIMEOUT_S:-5}"
SSHC="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -q"
HDR_EXPECT="0x00240000"   # WR_REQ, 2 payload words => 4 words on the AHB_TX side

fail() { echo "DELIVERY-PROOF: FAIL — $2"; exit "$1"; }

# ── Stage the /dev/mem helper on both boards (real file over scp; inline
#    python through double-ssh quoting mangles — see unjam_fc_node.sh). ──────
HELPER=$(mktemp)
cat > "$HELPER" <<'PYEOF'
import mmap, struct, os, sys, time, json, ctypes

PAGE = 4096
TX_BASE  = int(os.environ.get("TIDELINK_TX_BASE", "0x44000000"), 16)
RXF_BASE = int(os.environ.get("TIDELINK_RXFIFO_BASE", "0x44010000"), 16)
PAIR_BASE = 0x44032000
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO free credits
R_PAIR_CREDIT  = PAIR_BASE + 0x028   # SW-maintained credits toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C
R_TRAINING     = PAIR_BASE + 0x100   # [0] swi_training_mode, [1] swi_recal
R_LANE_STATUS  = PAIR_BASE + 0x108
R_OBS_FCCRED   = PAIR_BASE + 0x19C   # OBS_FC_CREDIT (2026-06-12; 0 on old images)
MAX_CREDITS = 4096
HDR = 0x00240000                      # WR_REQ, length=2 payload words

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}
def _mm(addr):
    base = addr & ~(PAGE - 1)
    if base not in _maps:
        _maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return _maps[base], addr - base
# SoC Labs 2026-07-09: rd/wr MUST be single aligned 32-bit bus accesses.
# struct.pack_into/unpack_from emit ~5 AHB beats per u32 on this target -- the
# "5x over-advance phantom". This is a DELIVERY-PROOF tool: occupancy() reads
# the credit/RX FIFO counters, and a 5x read on a POP-on-read aperture silently
# consumes entries and corrupts the delivery count it is trying to prove.
# ctypes.c_uint32.from_buffer(m, o) is exactly one aligned load/store. (tl39.py)
def rd(addr):
    m, o = _mm(addr)
    return ctypes.c_uint32.from_buffer(m, o).value
def wr(addr, val):
    m, o = _mm(addr)
    ctypes.c_uint32.from_buffer(m, o).value = val & 0xFFFFFFFF

def occupancy():
    return MAX_CREDITS - rd(R_CREDIT_COUNT)

def cmd_obs():
    # SWI_LANE_STATUS packing per REGISTER_MAP.md / tlchar.py (RTL
    # authoritative): [19:17] fcsm, [16] cal_done, [23] cr_seen,
    # [24] crack_seen, [30] a2l_fc_replay_link_valid, [31] fe_rx_is_full.
    ls = rd(R_LANE_STATUS)
    fc = rd(R_OBS_FCCRED)
    out = {"lane_status": "0x%08x" % ls,
           "fcsm": (ls >> 17) & 0x7,
           "cal_done": (ls >> 16) & 1,
           "cr_seen": (ls >> 23) & 1,
           "crack_seen": (ls >> 24) & 1,
           "fe_rx_is_full": (ls >> 31) & 1,
           "training": rd(R_TRAINING) & 1,
           "credit_count": rd(R_CREDIT_COUNT),
           "occupancy": occupancy(),
           "pair_credits": rd(R_PAIR_CREDIT),
           "fc_obs_raw": "0x%08x" % fc,
           # OBS_FC_CREDIT @0x4403219C: [31:24]=0xFC marker, [16] full,
           # [15:8] fe_rx_ptr, [7:0] fe_rx_credit_max. Old images read 0.
           "fc_obs_live": 1 if ((fc >> 24) & 0xFF) == 0xFC else 0,
           "fe_rx_credit_max": fc & 0xFF,
           "fe_rx_ptr": (fc >> 8) & 0xFF,
           "fe_rx_is_full_obs": (fc >> 16) & 1}
    print(json.dumps(out))

def cmd_send4():
    # ONE 4-word packet: hdr + target addr + 2 tagged payload words.
    wr(TX_BASE, HDR)
    wr(TX_BASE, 0x44010000)        # peer RX FIFO (link-layer target addr)
    wr(TX_BASE, 0xDA7A0000)
    wr(TX_BASE, 0xDA7A0001)
    # Pair-credit hygiene: only meaningful if SW seeded the counter.
    if rd(R_PAIR_CREDIT) >= 4:
        wr(R_PAIR_CONSUME, 4)
    print(json.dumps({"sent": 1, "hdr": "0x%08x" % HDR,
                      "tx_base": "0x%08x" % TX_BASE}))

def cmd_catch(base_occ, timeout_s):
    # Poll locally (on-board, mmap-rate) until occupancy rises above the
    # pre-send snapshot, then pop the delta and report the words.
    deadline = time.monotonic() + timeout_s
    occ = occupancy()
    while occ <= base_occ and time.monotonic() < deadline:
        time.sleep(0.005)
        occ = occupancy()
    delta = occ - base_occ
    words = []
    for _ in range(max(0, min(delta, 8))):
        words.append("0x%08x" % rd(RXF_BASE))
    print(json.dumps({"base_occ": base_occ, "occ": occ, "delta": delta,
                      "words": words,
                      "hdr_match": 1 if (words and words[0] == "0x%08x" % HDR)
                                     else 0}))

if __name__ == "__main__":
    c = sys.argv[1]
    if c == "obs":
        cmd_obs()
    elif c == "send4":
        cmd_send4()
    elif c == "catch":
        cmd_catch(int(sys.argv[2]), float(sys.argv[3]))
    else:
        print(json.dumps({"error": "unknown cmd %s" % c}))
        sys.exit(1)
PYEOF

for ip in "$MASTER" "$SLAVE"; do
    sshpass -p "$PASS" scp $SSHC "$HELPER" "xilinx@$ip:/tmp/tl_dproof.py" \
        || { rm -f "$HELPER"; fail 3 "scp helper to $ip failed"; }
done
rm -f "$HELPER"

board() { # IP CMD [ARGS...] — boards need `echo 'xilinx' | sudo -S`
    local ip="$1"; shift
    sshpass -p "$PASS" ssh $SSHC "xilinx@$ip" \
        "echo '$PASS' | sudo -S TIDELINK_TX_BASE=$TXB TIDELINK_RXFIFO_BASE=$RXB \
         timeout 30 python3 /tmp/tl_dproof.py $*" 2>/dev/null
}

jget() { # JSON KEY — tiny extractor (numbers / quoted strings)
    python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" <<< "$1"
}

# ── 1. Credit observability, both sides ──────────────────────────────────────
M_OBS=$(board "$MASTER" obs); [ -n "$M_OBS" ] || fail 3 "master obs read failed"
S_OBS=$(board "$SLAVE"  obs); [ -n "$S_OBS" ] || fail 3 "slave obs read failed"

for side in MASTER SLAVE; do
    obs_var=$([ "$side" = MASTER ] && echo "$M_OBS" || echo "$S_OBS")
    live=$(jget "$obs_var" fc_obs_live)
    if [ "$live" = "1" ]; then
        echo "$side OBS_FC_CREDIT: raw=$(jget "$obs_var" fc_obs_raw)" \
             "fe_rx_credit_max=$(jget "$obs_var" fe_rx_credit_max)" \
             "fe_rx_ptr=$(jget "$obs_var" fe_rx_ptr)" \
             "fe_rx_is_full=$(jget "$obs_var" fe_rx_is_full_obs)"
    else
        echo "$side OBS_FC_CREDIT: not in this image (0x4403219C reads" \
             "$(jget "$obs_var" fc_obs_raw) — pre-2026-06-12 bitstream)"
    fi
done

# ── 2. Pre-send state gate ───────────────────────────────────────────────────
m_fcsm=$(jget "$M_OBS" fcsm);  s_fcsm=$(jget "$S_OBS" fcsm)
m_trn=$(jget "$M_OBS" training); s_trn=$(jget "$S_OBS" training)
m_full=$(jget "$M_OBS" fe_rx_is_full); s_full=$(jget "$S_OBS" fe_rx_is_full)
echo "pre-send: master fcsm=$m_fcsm training=$m_trn fe_full=$m_full |" \
     "slave fcsm=$s_fcsm training=$s_trn fe_full=$s_full"
[ "$m_fcsm" = "4" ] && [ "$s_fcsm" = "4" ] \
    || fail 1 "FCSM not LINK_IDLE(4) on both sides (m=$m_fcsm s=$s_fcsm)"
[ "$m_trn" = "0" ] && [ "$s_trn" = "0" ] \
    || fail 1 "swi_training_mode still set (m=$m_trn s=$s_trn) — link not released"
[ "$m_full" = "0" ] && [ "$s_full" = "0" ] \
    || fail 1 "fe_rx_is_full set (m=$m_full s=$s_full) — no TX credits"

# If the new obs is live on the master, a zero credit_max with fe_full=0
# can't happen (full bit derives from it) — but a SUSPICIOUSLY small value
# is exactly the garble case this script exists for. Flag it, don't gate.
if [ "$(jget "$M_OBS" fc_obs_live)" = "1" ]; then
    cm=$(jget "$M_OBS" fe_rx_credit_max)
    if [ "${cm:-0}" -lt 8 ] 2>/dev/null; then
        echo "WARNING: master fe_rx_credit_max=$cm (<8) — possible garbled CR credit"
    fi
fi

# ── 3+4. Snapshot slave occupancy, send on master, catch on slave ───────────
base_occ=$(jget "$S_OBS" occupancy)
echo "slave RX FIFO occupancy pre-send: $base_occ"

SEND=$(board "$MASTER" send4); [ -n "$SEND" ] || fail 3 "master send failed"
echo "master sent 4-word packet hdr=$HDR_EXPECT via TX_BASE=$TXB"

CATCH=$(board "$SLAVE" catch "$base_occ" "$CATCH_TIMEOUT")
[ -n "$CATCH" ] || fail 3 "slave catch failed"
delta=$(jget "$CATCH" delta); hdr_ok=$(jget "$CATCH" hdr_match)
words=$(jget "$CATCH" words)
echo "slave RX FIFO: delta=$delta words=$words"

[ "${delta:-0}" -gt 0 ] 2>/dev/null \
    || fail 2 "packet never landed in slave RX FIFO (occupancy delta=$delta after ${CATCH_TIMEOUT}s)"
[ "$hdr_ok" = "1" ] \
    || fail 2 "header mismatch — first popped word != $HDR_EXPECT (got: $words)"

echo "DELIVERY-PROOF: PASS — 4-word packet master($MASTER) -> slave($SLAVE) delivered, header byte-exact ($HDR_EXPECT), occupancy delta=$delta"
exit 0

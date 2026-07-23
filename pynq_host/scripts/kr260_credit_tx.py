#!/usr/bin/env python3
"""kr260_credit_tx.py -- CREDIT-AWARE TideLink sender for KR260 (wedge-safe TX).

⚠️ WHY THIS EXISTS (2026-07-23): the TX aperture (ahb_tx, 0xA4000000) has NO
hardware backpressure. An AHB write issued when the peer RX FIFO has no room
does NOT bus-error or time out — it HANGS the PS bus, hard-wedging the board
(JTAG POR only). A blind batch sender (tx_batch.py) therefore wedges the instant
it outruns credit. Firmware MUST gate every write on available credit.

SOFTWARE FLOW CONTROL (the intended mechanism, grounded in src/rtl/fifo +
cocotb/tidelink_ahb tests test_11/12/13):
  - REG_PAIR_CREDIT_ENABLE (0x84032030) = 1        -> enable pair-credit tracking
  - REG_PAIR_CREDIT_COUNTER (0x84032028)           -> peer's available credit as
        tracked locally; the peer's RETURNER updates it (via the credit-return
        sideband) each time the peer DRAINS its RX FIFO. Read before sending.
  - REG_PAIR_CREDIT_CONSUME (0x8403202c) = delta   -> after sending a packet of
        delta=(len+2) words, write delta to decrement the local credit view.
  - REG_RELEASED_ACC (0x84032020)                  -> raw released-credit
        accumulator (observed updating on real HW: read 0x14 during a drain).

Send loop: while credit_counter >= delta: write packet to ahb_tx; consume delta.
Else: poll credit_counter (peer must drain to free credit) up to a timeout; if it
never recovers, STOP (do NOT blind-write — that is the wedge).

🔴 REQUIRED PEER SETUP: the RECEIVING die must lower REG_REL_THRESHOLD (POR=20)
or the credit-return never fires for small drains and this sender STALLS (then,
if you blind-write anyway, WEDGES). Run `kr260_drain.py setup` on the receiver
first (sets REL_THRESHOLD=0 = immediate per-pop release). This is sim-proven
(cocotb/tidelink_top_pair_v2 test_v2_credit_loop_close, 2026-07-23): with the
default 20, a single delta-8 drain returns ZERO credit; with 0 it returns +8.

🔴 STATUS: end-to-end credit loop is SIM-PROVEN (die-B drain raises die-A
PAIR_CREDIT_COUNTER by exactly the returned credit) but UNVALIDATED ON REAL
SILICON. Validate on the lottery-free kr260-pair-onchip build BEFORE trusting for
an un-attended soak. Until then run with small `count` and watch for a STALL
(peer not crediting) — the loop refuses to blind-write, so it stalls, not wedges.
"""
import mmap, os, struct, sys, time, ctypes, argparse

TX_BASE   = 0xA4000000
APB_BASE  = 0x84030000            # region4 +0x2000 => TideLink FIFO APB at +0x2000
OFF_CREDIT_COUNT   = 0x200C       # local RX credit (this die), context only
OFF_PAIR_COUNTER   = 0x2028       # REG_PAIR_CREDIT_COUNTER  (peer credit, local view)
OFF_PAIR_CONSUME   = 0x202C       # REG_PAIR_CREDIT_CONSUME  (write delta after send)
OFF_PAIR_ENABLE    = 0x2030       # REG_PAIR_CREDIT_ENABLE
OFF_RELEASED_ACC   = 0x2020       # REG_RELEASED_ACC (raw released-credit accumulator)
MAX_CREDITS        = 0x1000       # 4096 words

_fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}
def _mm(a):
    b = a & ~0xFFF
    if b not in _maps:
        _maps[b] = mmap.mmap(_fd, 0x4000 if b == APB_BASE else 0x1000,
                             mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b
def rd(a):
    m, o = _mm(a); return ctypes.c_uint32.from_buffer(m, o).value
def wr(a, v):
    m, o = _mm(a); ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF

def pair_credit():
    return rd(APB_BASE + OFF_PAIR_COUNTER)

def send_packet(tag, length=2):
    # length-2 payload packet: [hdr(len), dest, tag, ~tag]
    m, o = _mm(TX_BASE)
    hdr = (length & 0xFFF) << 20
    words = [hdr, 0x00000000, tag & 0xFFFFFFFF, (tag ^ 0xFFFFFFFF) & 0xFFFFFFFF]
    for j, v in enumerate(words):
        ctypes.c_uint32.from_buffer(m, o + 4 * j).value = v

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("start", type=lambda x: int(x, 0))
    ap.add_argument("count", type=int)
    ap.add_argument("--len", type=int, default=2)
    ap.add_argument("--timeout", type=float, default=2.0,
                    help="seconds to wait for peer credit before declaring STALL")
    ap.add_argument("--no-enable", action="store_true",
                    help="skip writing PAIR_CREDIT_ENABLE (if already enabled)")
    a = ap.parse_args()
    delta = a.len + 2

    if not a.no_enable:
        wr(APB_BASE + OFF_PAIR_ENABLE, 1)

    sent = 0
    stalls = 0
    for i in range(a.count):
        tag = (a.start + i) & 0xFFFFFFFF
        # wait for credit
        t0 = time.time()
        while pair_credit() < delta:
            if time.time() - t0 > a.timeout:
                print("STALL at pkt %d (tag=0x%08x): pair_credit=%d < %d for %.1fs "
                      "-> peer not crediting; STOP (refusing blind-write = wedge)."
                      % (sent, tag, pair_credit(), delta, a.timeout))
                print("SENT=%d STALLED (credit-starved, NOT wedged)" % sent)
                return 2
            time.sleep(0.001)
        send_packet(tag, a.len)
        wr(APB_BASE + OFF_PAIR_CONSUME, delta)   # decrement local credit view
        sent += 1
    print("SENT=%d start=0x%08x last=0x%08x pair_credit_now=%d"
          % (sent, a.start, (a.start + sent - 1) & 0xFFFFFFFF, pair_credit()))
    return 0

if __name__ == "__main__":
    sys.exit(main())

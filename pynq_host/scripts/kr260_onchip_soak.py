#!/usr/bin/env python3
"""kr260_onchip_soak.py — credit-aware A->B data soak for the KR260 ON-CHIP pair.

One board, one PS: die_a (inst0) and die_b (inst1) both mmap'd here. die_a sends
credit-gated packets into its ahb_tx; they cross the in-fabric link to die_b's RX
FIFO; die_b drains them with the sequential-read pop protocol (which returns
credit to die_a). No cross-board ssh, no ribbon, no bring-up lottery.

Addresses (fpga/targets/kr260-pair-onchip/addrmap.tcl, stride 0x08000000):
  die_a: ahb_tx 0xA4000000  APB 0x84030000   (PAIR_CREDIT_COUNTER 0x84032028)
  die_b: ahb_fifo 0xAC010000 APB 0x8C030000  (STATUS 0x8C032010, REL_THRESHOLD 0x8C032004)

Modes:
  smoke1        send ONE packet A->B, drain+verify on B (wedge-safe)
  soak N [len]  credit-gated sustained soak of N packets, strided drain+verify
Credit safety: every send gates on die_a PAIR_CREDIT_COUNTER; if credit starves
the sender STALLS (never blind-writes — an ungated ahb_tx overrun hangs the PS).
Receiver setup: die_b REL_THRESHOLD=0 (immediate per-pop credit release) so the
credit loop actually recycles (POR default 20 would starve small drains).
"""
import mmap, os, sys, time, ctypes

# die_a (sender / inst0)
A_TX          = 0xA4000000
A_APB         = 0x84030000
A_PAIR_COUNT  = 0x84032028   # PAIR_CREDIT_COUNTER (peer credit, local view)
A_PAIR_CONS   = 0x8403202C   # PAIR_CREDIT_CONSUME
A_PAIR_EN     = 0x84032030   # PAIR_CREDIT_ENABLE
# die_b (receiver / inst1)
B_FIFO        = 0xAC010000
B_APB         = 0x8C030000
B_STATUS      = 0x8C032010
B_CREDIT      = 0x8C03200C
B_CTRL        = 0x8C03201C
B_RELTHRESH   = 0x8C032004

_fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}
def _mm(a):
    b = a & ~0xFFF
    if b not in _maps:
        _maps[b] = mmap.mmap(_fd, 0x10000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b
def rd(a):
    m, o = _mm(a); return ctypes.c_uint32.from_buffer(m, o).value
def wr(a, v):
    m, o = _mm(a); ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF

def send_packet(tag, length=2):
    m, o = _mm(A_TX)
    words = [(length & 0xFFF) << 20, 0x00000000,
             tag & 0xFFFFFFFF, (tag ^ 0xFFFFFFFF) & 0xFFFFFFFF]
    for j, v in enumerate(words):
        ctypes.c_uint32.from_buffer(m, o + 4 * j).value = v

def b_avail():
    return (rd(B_STATUS) >> 4) & 1

def drain_one():
    hdr = rd(B_FIFO); length = (hdr >> 20) & 0xFFF; total = length + 2
    w = [hdr] + [rd(B_FIFO + i * 4) for i in range(1, total)]
    return length, w

def a_credit():
    return rd(A_PAIR_COUNT)

def setup():
    wr(B_RELTHRESH, 0)      # immediate per-pop credit release on the receiver
    wr(A_PAIR_EN, 1)        # enable pair-credit tracking on the sender
    wr(B_CTRL, 0x2)         # flush die_b RX (EN=0, FLUSH=1) for a clean baseline
    print("setup: die_b REL_THRESHOLD=0, die_a PAIR_CREDIT_EN=1, die_b RX flushed")
    print("       die_a pair_credit=%d  die_b rx_credit=%d" % (a_credit(), rd(B_CREDIT)))

def b_room():
    # die_b RX credit_count (0x8C03200C): == MAX_CREDITS when empty, decreases by
    # (len+2) per queued packet. This IS the receiver's available room, readable
    # directly here (one PS). Gating on it makes an overrun — the wedge — impossible.
    return rd(B_CREDIT)

def gated_send(tag, length, timeout=2.0):
    delta = length + 2
    t0 = time.time()
    while b_room() < delta:            # wait until die_b RX has room (drain frees it)
        if time.time() - t0 > timeout:
            return False
        time.sleep(0.001)
    send_packet(tag, length)
    return True

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "smoke1"
    if cmd == "smoke1":
        setup()
        c0 = a_credit()
        if not gated_send(0x0A0C0001, 2):
            print("SMOKE1 STALL: die_a had no credit (%d) — not wedged" % a_credit()); return 2
        time.sleep(0.05)
        if not b_avail():
            print("SMOKE1 FAIL: nothing arrived at die_b (avail=0)"); return 1
        length, w = drain_one()
        pay, cpl = w[2], w[3]
        ok = (pay == 0x0A0C0001) and (cpl == (pay ^ 0xFFFFFFFF))
        print("SMOKE1 %s: sent 0x0A0C0001 got pay=0x%08x cpl=0x%08x len=%d; "
              "a_credit %d->%d" % ("PASS" if ok else "FAIL", pay, cpl, length, c0, a_credit()))
        return 0 if ok else 1
    elif cmd == "soak":
        n = int(sys.argv[2]); length = int(sys.argv[3]) if len(sys.argv) > 3 else 2
        setup()
        start = 0x10000000
        sent = good = bad = drained = stalls = 0
        for i in range(n):
            tag = (start + i) & 0xFFFFFFFF
            if not gated_send(tag, length):
                stalls += 1
                print("STALL at i=%d (a_credit=%d) — stopping (not wedged)" % (i, a_credit()))
                break
            sent += 1
            # drain as they arrive to recycle credit
            t0 = time.time()
            while not b_avail() and time.time() - t0 < 0.5:
                time.sleep(0.001)
            if b_avail():
                _, w = drain_one(); drained += 1
                pay, cpl = w[2], w[3]
                if pay == tag and cpl == (pay ^ 0xFFFFFFFF): good += 1
                else: bad += 1
        # drain any stragglers
        while b_avail():
            _, w = drain_one(); drained += 1
            pay = w[2]; cpl = w[3]
            exp = (start + good + bad) & 0xFFFFFFFF
            if pay == exp and cpl == (pay ^ 0xFFFFFFFF): good += 1
            else: bad += 1
        print("SOAK: sent=%d drained=%d good=%d bad=%d stalls=%d a_credit_now=%d"
              % (sent, drained, good, bad, stalls, a_credit()))
        return 0 if (bad == 0 and good == sent and stalls == 0) else 1
    else:
        print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main())

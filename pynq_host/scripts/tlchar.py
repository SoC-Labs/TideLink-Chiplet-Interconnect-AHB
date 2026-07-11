#!/usr/bin/env python3
"""tlchar.py — on-board TideLink characterization helper (runs ON the PYNQ).

Implements the measurement legs of HW_CHARACTERIZATION_PLAN_2026_06_12:
  T1 stream/drain, T4 ping/respond, T5 fill/credsample, T6b apblat.

Runs as root (needs /dev/mem). All loops are mmap-direct — SSH-per-access
would measure sshpass, not the link.

Address bases follow the GP1-split convention: data apertures default to
the OLD pre-split addresses; export TIDELINK_TX_BASE=0x84000000 and
TIDELINK_RXFIFO_BASE=0x84010000 against GP1-split images.

Commands:
  probe                       one-line status (credits, pair credits, status, 0x108)
  ping N GAP_MS               T4 master leg: N doorbell RTTs, GAP_MS quiesce between
  respond DURATION_S          T4/T1 peer leg: doorbell echo + RX-FIFO max-rate drain
  stream B DURATION_S         T1 master leg: credit-gated (hdr+addr+B payload) packets
  drain DURATION_S [WPS]      paced RX-FIFO drain (WPS words/s; 0 = max rate)
  fill TARGET_PCT             T5: push until peer FIFO ~TARGET_PCT% full (credit-gated)
  credsample DURATION_S HZ    T5: CSV of t_ns,pair_credits,released_acc
  apblat N                    T6b: N timed APB reads of SWI_LANE_STATUS -> percentiles
"""
import mmap, struct, os, sys, time, json, ctypes

PAGE = 4096
TX_BASE   = int(os.environ.get("TIDELINK_TX_BASE", "0x44000000"), 16)
RXF_BASE  = int(os.environ.get("TIDELINK_RXFIFO_BASE", "0x44010000"), 16)
PAIR_BASE = 0x44032000
R_REL_THRESH   = PAIR_BASE + 0x004
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO available credits
R_STATUS       = PAIR_BASE + 0x010
R_DOORBELL     = PAIR_BASE + 0x014
R_RELEASED_ACC = PAIR_BASE + 0x020   # read-clear
R_DB_RESP_ACC  = PAIR_BASE + 0x024   # read-clear
R_PAIR_CREDIT  = PAIR_BASE + 0x028   # credits available toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C   # WO: decrement pair counter by N
R_LANE_STATUS  = PAIR_BASE + 0x108
MAX_CREDITS = 4096

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}
def _mm(addr):
    base = addr & ~(PAGE - 1)
    if base not in _maps:
        _maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return _maps[base], addr - base

def _u32(m, o):
    # SoC Labs 2026-07-03: struct.pack_into/unpack_from emit ~5 narrow bus
    # accesses per u32 on this ARMv7 PYNQ (measured a2l wptr +5/word). For the
    # doorbell trigger that means ~5 doorbells per intended one -> corrupt
    # amplification/RTT. ctypes gives a single aligned u32 access.
    return ctypes.cast(ctypes.addressof(ctypes.c_uint32.from_buffer(m, o)),
                       ctypes.POINTER(ctypes.c_uint32))

def rd(addr):
    m, o = _mm(addr)
    return int(_u32(m, o)[0])

def wr(addr, val):
    m, o = _mm(addr)
    _u32(m, o)[0] = val & 0xFFFFFFFF

def pctiles(vals):
    s = sorted(vals)
    n = len(s)
    def p(q): return s[min(n - 1, int(q * n))]
    return {"n": n, "min": s[0], "p50": p(.50), "p90": p(.90),
            "p99": p(.99), "max": s[-1], "mean": sum(s) / n}

def probe():
    # SWI_LANE_STATUS packing per REGISTER_MAP.md (RTL authoritative, not RDL):
    # [19:17] fcsm  [20] a2l_replay_app_valid  [22:21] llrx_state  [23] cr_seen
    # [24] crack_seen  [25] short  [26] long  [29] llrx_valid
    # [30] a2l_fc_replay_link_valid  [31] fe_rx_is_full
    ls = rd(R_LANE_STATUS)
    return {"credit_count": rd(R_CREDIT_COUNT),
            "pair_credits": rd(R_PAIR_CREDIT),
            "status": rd(R_STATUS),
            "lane_status": "0x%08x" % ls,
            "fcsm": (ls >> 17) & 0x7,
            "cal_done": (ls >> 16) & 1,
            "a2l_replay_app_valid": (ls >> 20) & 1,
            "llrx_state": (ls >> 21) & 0x3,
            "cr_seen": (ls >> 23) & 1,
            "crack_seen": (ls >> 24) & 1,
            "llrx_valid": (ls >> 29) & 1,
            "a2l_fc_replay_link_valid": (ls >> 30) & 1,
            "fe_rx_is_full": (ls >> 31) & 1}

def cmd_ping(n, gap_ms):
    rd(R_DB_RESP_ACC)                       # clear
    rtts, acc_sum, lost = [], 0, 0
    for _ in range(n):
        t0 = time.monotonic_ns()
        wr(R_DOORBELL, 1)
        deadline = t0 + 2_000_000_000
        v = 0
        while v == 0:
            v = rd(R_DB_RESP_ACC)
            if v == 0 and time.monotonic_ns() > deadline:
                lost += 1
                break
        if v:
            rtts.append((time.monotonic_ns() - t0) / 1000.0)  # us
            acc_sum += v
        time.sleep(gap_ms / 1000.0)
    out = {"test": "T4_ping", "gap_ms": gap_ms, "lost": lost,
           "amplification": (acc_sum / len(rtts)) if rtts else None,
           "rtt_us": pctiles(rtts) if rtts else None}
    print(json.dumps(out))

def cmd_respond(duration_s):
    end = time.monotonic() + duration_s
    echoed, drained = 0, 0
    while time.monotonic() < end:
        v = rd(R_DB_RESP_ACC)
        if v:
            wr(R_DOORBELL, 1)
            echoed += v
        occ = MAX_CREDITS - rd(R_CREDIT_COUNT)
        for _ in range(min(occ, 256)):
            rd(RXF_BASE)
            drained += 1
    print(json.dumps({"test": "respond", "echoed": echoed, "drained_words": drained}))

def cmd_stream(burst, duration_s):
    hdr = ((burst & 0xFFF) << 20) | (1 << 18)   # WR_REQ, length=burst
    cost = burst + 2
    pkts = words = starve_ns = 0
    t_start = time.monotonic_ns()
    end = t_start + int(duration_s * 1e9)
    seq = 0
    while time.monotonic_ns() < end:
        if rd(R_PAIR_CREDIT) < cost:
            s0 = time.monotonic_ns()
            while rd(R_PAIR_CREDIT) < cost:
                if time.monotonic_ns() > end + 2_000_000_000:
                    print(json.dumps({"test": "T1_stream", "error": "credit_stall",
                                      "pkts": pkts, "words": words}))
                    return
            starve_ns += time.monotonic_ns() - s0
        wr(TX_BASE, hdr)
        wr(TX_BASE, 0x44010000)
        for i in range(burst):
            wr(TX_BASE, (0xDA << 24) | ((seq & 0xFFF) << 12) | (i & 0xFFF))
        wr(R_PAIR_CONSUME, cost)
        seq += 1
        pkts += 1
        words += cost
    el = (time.monotonic_ns() - t_start) / 1e9
    print(json.dumps({"test": "T1_stream", "burst": burst, "elapsed_s": round(el, 3),
                      "pkts": pkts, "words_total": words,
                      "payload_words": pkts * burst,
                      "words_per_s": round(words / el, 1),
                      "payload_words_per_s": round(pkts * burst / el, 1),
                      "payload_MBps": round(pkts * burst * 4 / el / 1e6, 4),
                      "starve_pct": round(100.0 * starve_ns / (el * 1e9), 2),
                      "end_pair_credits": rd(R_PAIR_CREDIT),
                      "end_status": rd(R_STATUS)}))

def cmd_drain(duration_s, wps):
    end = time.monotonic() + duration_s
    drained = 0
    period = (1.0 / wps) if wps > 0 else 0.0
    while time.monotonic() < end:
        occ = MAX_CREDITS - rd(R_CREDIT_COUNT)
        if occ <= 0:
            continue
        if period:
            for _ in range(min(occ, 64)):
                rd(RXF_BASE)
                drained += 1
                time.sleep(period)
        else:
            for _ in range(min(occ, 256)):
                rd(RXF_BASE)
                drained += 1
    print(json.dumps({"test": "drain", "drained_words": drained,
                      "end_credit_count": rd(R_CREDIT_COUNT),
                      "end_status": rd(R_STATUS)}))

def cmd_fill(target_pct):
    # Peer FIFO occupancy ~= MAX_CREDITS - pair_credits. Push raw filler
    # packets until pair_credits <= (100-target_pct)% of the idle baseline.
    base = rd(R_PAIR_CREDIT)
    target = int(base * (100 - target_pct) / 100.0)
    hdr = (16 << 20) | (1 << 18)
    pushed = 0
    t0 = time.monotonic()
    while rd(R_PAIR_CREDIT) > max(target, 20) and time.monotonic() - t0 < 30:
        if rd(R_PAIR_CREDIT) < 18:
            break
        wr(TX_BASE, hdr)
        wr(TX_BASE, 0x44010000)
        for i in range(16):
            wr(TX_BASE, 0xF1110000 | i)
        wr(R_PAIR_CONSUME, 18)
        pushed += 18
    print(json.dumps({"test": "T5_fill", "baseline": base, "target": target,
                      "pushed_words": pushed, "pair_credits": rd(R_PAIR_CREDIT)}))

def cmd_credsample(duration_s, hz):
    period = 1.0 / hz
    end = time.monotonic() + duration_s
    print("t_ns,pair_credits,released_acc")
    while time.monotonic() < end:
        print("%d,%d,%d" % (time.monotonic_ns(), rd(R_PAIR_CREDIT), rd(R_RELEASED_ACC)))
        time.sleep(period)

def cmd_apblat(n):
    lats = []
    for _ in range(n):
        t0 = time.monotonic_ns()
        rd(R_LANE_STATUS)
        lats.append((time.monotonic_ns() - t0) / 1000.0)
    print(json.dumps({"test": "T6b_apblat", "lat_us": pctiles(lats)}))

def cmd_seed(n):
    # Seed the SW-maintained pair-credit counter with the peer's FIFO size.
    # Writing 0x20 increments the pair counter AND released_credits_acc;
    # read 0x20 afterwards to clear the acc side.
    wr(R_RELEASED_ACC, n)
    rd(R_RELEASED_ACC)
    print(json.dumps({"test": "seed", "pair_credits": rd(R_PAIR_CREDIT)}))

if __name__ == "__main__":
    c = sys.argv[1]
    if c == "seed":
        cmd_seed(int(sys.argv[2]))
    elif c == "probe":
        print(json.dumps(probe()))
    elif c == "ping":
        cmd_ping(int(sys.argv[2]), float(sys.argv[3]))
    elif c == "respond":
        cmd_respond(float(sys.argv[2]))
    elif c == "stream":
        cmd_stream(int(sys.argv[2]), float(sys.argv[3]))
    elif c == "drain":
        cmd_drain(float(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0)
    elif c == "fill":
        cmd_fill(int(sys.argv[2]))
    elif c == "credsample":
        cmd_credsample(float(sys.argv[2]), float(sys.argv[3]))
    elif c == "apblat":
        cmd_apblat(int(sys.argv[2]))
    else:
        sys.exit("unknown cmd " + c)

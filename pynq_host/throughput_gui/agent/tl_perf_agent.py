#!/usr/bin/env python3
"""tl_perf_agent.py — ON-BOARD measurement agent (runs on the PYNQ).

Pushed afresh per run over SSH (cat -> /tmp/tl_perf_agent.py, then
``sudo python3 /tmp/tl_perf_agent.py ...`` on a persistent SSH channel;
results stream back as NDJSON on stdout). Modeled on
pynq_host/scripts/tlchar.py — same mmap-once /dev/mem access, same
address map (incl. TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE env
overrides for GP1-split images) and the authoritative SWI_LANE_STATUS
0x108 decode (fcsm = [19:17], THREE bits).

STDLIB ONLY (mmap/struct/time/json) — nothing may be pip-installed on
the boards. Keep this file 3.6-compatible-ish (PYNQ images vary).

Two invocation shapes:

  one-shot (gates / delivery proof — mirrors link_delivery_proof.sh):
    tl_perf_agent.py --cmd probe
    tl_perf_agent.py --cmd send4
    tl_perf_agent.py --cmd catch --args BASE_OCC TIMEOUT_S

  measurement run (GO-barrier protocol):
    tl_perf_agent.py --cfg-json '{"role":"stream","burst_words":16,...}'
      -> prints {"ev":"ready"}            then BLOCKS on stdin
      <- "GO <epoch_deadline>\n"          (or "ABORT\n")
      -> {"ev":"sample", ...} per window, {"ev":"done","summary":...}

DEV MODE: ``--fake`` swaps /dev/mem for an in-process model of this
die's registers plus a spool-file "wire" (dir from TIDELINK_FAKE_LINK_DIR)
shared with the peer agent process on the same host, so M->S words
genuinely traverse process boundaries and the delivery proof can only
pass if the master really sent. Synthetic link capacity / noise /
fault-injection knobs ride in via environment (see _FakeMem).

SAFETY: the AHB_TX aperture is written ONLY by cmd_send4 (one 4-word
proof packet) and the stream role — both of which the orchestrator
admits strictly behind the criterion-B + delivery-proof gates. No
speculative TX, ever.
"""
import argparse
import ctypes
import json
import os
import struct
import sys
import time

PAGE = 4096
TX_BASE = int(os.environ.get("TIDELINK_TX_BASE", "0x44000000"), 16)
RXF_BASE = int(os.environ.get("TIDELINK_RXFIFO_BASE", "0x44010000"), 16)
PAIR_BASE = 0x44032000
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO available credits
R_STATUS = PAIR_BASE + 0x010
R_RELEASED_ACC = PAIR_BASE + 0x020   # read-clear
R_PAIR_CREDIT = PAIR_BASE + 0x028    # SW-maintained credits toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C   # WO: decrement pair counter by N
R_TRAINING = PAIR_BASE + 0x100       # [0] swi_training_mode
R_LANE_STATUS = PAIR_BASE + 0x108
R_PHY_ID = PAIR_BASE + 0x11C
R_OBS_FCCRED = PAIR_BASE + 0x19C     # OBS_FC_CREDIT (2026-06-12+)
MAX_CREDITS = 4096
HDR4 = 0x00240000                    # WR_REQ, 2 payload words


def _emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


# ── Backends ──────────────────────────────────────────────────────────────

class _DevMem(object):
    """mmap-once /dev/mem accessor (identical to tlchar.py)."""

    def __init__(self):
        self._fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self._maps = {}

    def _mm(self, addr):
        base = addr & ~(PAGE - 1)
        if base not in self._maps:
            import mmap
            self._maps[base] = mmap.mmap(
                self._fd, PAGE, mmap.MAP_SHARED,
                mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        return self._maps[base], addr - base

    # SoC Labs 2026-07-09: rd/wr MUST be single aligned 32-bit bus accesses.
    # struct.pack_into/unpack_from on this ARMv7 PYNQ emit ~5 narrow bus beats
    # per u32 (measured: a2l wptr +5/word) -- the "5x over-advance phantom".
    # For a THROUGHPUT agent that is fatal: counter reads pop POP-on-read FIFOs
    # 5x and every send fires ~5x, corrupting the very rate being measured.
    # ctypes.c_uint32.from_buffer is exactly one aligned load/store per .value.
    # Mirrors tlchar.py / tl39.py. Do not revert to struct.
    def rd(self, addr):
        m, o = self._mm(addr)
        return ctypes.c_uint32.from_buffer(m, o).value

    def wr(self, addr, val):
        m, o = self._mm(addr)
        ctypes.c_uint32.from_buffer(m, o).value = val & 0xFFFFFFFF

    def idle(self):
        pass

    def barrier(self):
        """Ensure posted writes hit the wire (no-op on real HW)."""
        pass


class _FakeMem(object):
    """Plausible single-die TideLink model + spool-file wire (DEV MODE).

    Env knobs:
      TIDELINK_FAKE_LINK_DIR    shared dir for the m2s spool (required)
      TIDELINK_FAKE_ROLE        master|slave (required)
      TIDELINK_FAKE_CAP_WPS     link capacity, total words/s (default 150e3)
      TIDELINK_FAKE_SEED        noise seed (default 1234)
      TIDELINK_FAKE_JAM_AT_S    inject the CLASSIC jam signature after N s
      TIDELINK_FAKE_LINK_DOWN   1 => report cal_done=0, fcsm=0 (gate test)

    Model: pair credits replenish at the link-capacity rate (that is the
    peer draining its RX FIFO and returning credits), so a credit-gated
    stream loop is throttled to a realistic sustained rate. Words written
    to AHB_TX are appended to ``<dir>/m2s.spool`` ("t_ns hex8" lines);
    the slave-side instance ingests spool lines older than ~2 ms into
    its RX-FIFO model, so occupancy / drain genuinely track the master.
    """

    LATENCY_NS = 2_000_000   # one-way delivery latency

    def __init__(self):
        import random
        link_dir = os.environ.get("TIDELINK_FAKE_LINK_DIR")
        if not link_dir:
            raise SystemExit("fake backend requires TIDELINK_FAKE_LINK_DIR")
        self.role = os.environ.get("TIDELINK_FAKE_ROLE", "master")
        self.cap_wps = float(os.environ.get("TIDELINK_FAKE_CAP_WPS",
                                            "150000"))
        self._rng = random.Random(
            int(os.environ.get("TIDELINK_FAKE_SEED", "1234")))
        jam = os.environ.get("TIDELINK_FAKE_JAM_AT_S", "")
        self._jam_at = float(jam) if jam else None
        self._link_down = os.environ.get("TIDELINK_FAKE_LINK_DOWN") == "1"
        self._t0 = time.monotonic()
        self._spool = os.path.join(link_dir, "m2s.spool")
        # master side: SW-seeded pair credits toward the peer
        self._pair_credits = 1024.0
        self._pair_cap = 1024.0
        self._last_regen = time.monotonic()
        # slave side: RX FIFO model
        from collections import deque
        self._rxq = deque()
        self._spool_pos = 0
        self._spool_r = None
        self._spool_w = None
        # master side: words are batched one spool LINE per packet
        # ("t_ns w0 w1 ... wN", flushed on the R_PAIR_CONSUME write) —
        # a line per word can't be parsed at link rate by the peer.
        self._pend = []
        if self.role == "master":
            # create the spool so the slave can poll it immediately
            self._spool_w = open(self._spool, "a")

    # — internals —
    def _regen(self):
        now = time.monotonic()
        dt = now - self._last_regen
        if dt <= 0:
            return
        self._last_regen = now
        noise = 1.0 + self._rng.uniform(-0.03, 0.03)
        self._pair_credits = min(
            self._pair_cap, self._pair_credits + self.cap_wps * noise * dt)

    def _ingest(self):
        """Slave: pull delivered words from the spool into the RX FIFO.

        The m2s spool is the SLAVE's RX direction only — the master
        must never ingest its own TX spool (its RX FIFO would be the
        unmodeled s2m direction)."""
        if self.role != "slave":
            return
        if self._spool_r is None:
            if not os.path.exists(self._spool):
                return
            self._spool_r = open(self._spool, "r")
        fh = self._spool_r
        cutoff = time.monotonic_ns() - self.LATENCY_NS
        fh.seek(self._spool_pos)
        while True:
            pos = fh.tell()
            line = fh.readline()
            if not line or not line.endswith("\n"):
                break
            parts = line.split()
            if int(parts[0]) > cutoff:
                break              # not "arrived" yet; re-read next poll
            pos = fh.tell()
            for w in parts[1:]:
                self._rxq.append(int(w, 16))
        self._spool_pos = pos

    def _jammed(self):
        return (self._jam_at is not None
                and (time.monotonic() - self._t0) >= self._jam_at)

    def _lane_status(self):
        if self._link_down:
            return 0  # cal_done=0, fcsm=0, nothing locked
        if self._jammed():
            # CLASSIC jam: fcsm=5 + a2l_fc_replay_link_valid=1 + fe_full=0
            return (1 << 16) | (5 << 17) | (1 << 30)
        # healthy data-mode: cal_done=1, fcsm=4 (LINK_IDLE), lk=0 (post-M12)
        return (1 << 16) | (4 << 17)

    # — MMIO interface —
    def rd(self, addr):
        if addr == R_LANE_STATUS:
            return self._lane_status()
        if addr == R_PAIR_CREDIT:
            self._regen()
            return int(self._pair_credits)
        if addr == R_CREDIT_COUNT:
            self._ingest()
            return MAX_CREDITS - len(self._rxq)
        if addr == RXF_BASE:
            if not self._rxq:
                self._ingest()
            return self._rxq.popleft() if self._rxq else 0
        if addr == R_OBS_FCCRED:
            # marker 0xFC + healthy credit_max=0x1F (CLASSIC jam keeps
            # fe_full=0 by definition, so the full bit stays clear)
            return (0xFC << 24) | (0 << 16) | (0x07 << 8) | 0x1F
        if addr == R_TRAINING:
            return 0
        if addr == R_PHY_ID:
            return 0xFA4E0001
        if addr == R_STATUS:
            return 0
        return 0

    def _flush_pend(self):
        if not self._pend:
            return
        if self._spool_w is None:
            self._spool_w = open(self._spool, "a")
        self._spool_w.write("%d %s\n" % (
            time.monotonic_ns(),
            " ".join("%08x" % w for w in self._pend)))
        self._spool_w.flush()
        del self._pend[:]

    def wr(self, addr, val):
        if addr == TX_BASE:
            self._pend.append(val & 0xFFFFFFFF)
            if len(self._pend) >= 260:     # safety flush (no consume)
                self._flush_pend()
            return
        if addr == R_PAIR_CONSUME:
            self._flush_pend()             # packet hits the wire
            self._regen()
            self._pair_credits = max(0.0, self._pair_credits - val)
            return
        # other registers: accept + ignore

    def idle(self):
        # Keep the credit-starve busy-wait from melting a host CPU core.
        time.sleep(0.0002)

    def barrier(self):
        self._flush_pend()


# ── Decode + commands (shared by both backends) ──────────────────────────

def decode_status(mem):
    ls = mem.rd(R_LANE_STATUS)
    fc = mem.rd(R_OBS_FCCRED)
    occ = MAX_CREDITS - mem.rd(R_CREDIT_COUNT)
    return {
        "lane_status": "0x%08x" % ls,
        "locked_mask": ls & 0xFF,
        "lock_count": bin(ls & 0xFF).count("1"),
        "cal_done": (ls >> 16) & 1,
        "fcsm": (ls >> 17) & 0x7,
        "a2l_replay_app_valid": (ls >> 20) & 1,
        "cr_seen": (ls >> 23) & 1,
        "crack_seen": (ls >> 24) & 1,
        "a2l_fc_replay_link_valid": (ls >> 30) & 1,
        "fe_rx_is_full": (ls >> 31) & 1,
        "training": mem.rd(R_TRAINING) & 1,
        "credit_count": mem.rd(R_CREDIT_COUNT),
        "occupancy": occ,
        "pair_credits": mem.rd(R_PAIR_CREDIT),
        "phy_id": "0x%08x" % mem.rd(R_PHY_ID),
        "fc_obs_raw": "0x%08x" % fc,
        "fc_obs_live": 1 if ((fc >> 24) & 0xFF) == 0xFC else 0,
        "fe_rx_credit_max": fc & 0xFF,
        "fe_rx_ptr": (fc >> 8) & 0xFF,
    }


def cmd_probe(mem):
    _emit(decode_status(mem))


def cmd_send4(mem):
    """ONE 4-word proof packet (port of link_delivery_proof.sh send4)."""
    mem.wr(TX_BASE, HDR4)
    mem.wr(TX_BASE, 0x44010000)      # peer RX FIFO (link-layer target)
    mem.wr(TX_BASE, 0xDA7A0000)
    mem.wr(TX_BASE, 0xDA7A0001)
    if mem.rd(R_PAIR_CREDIT) >= 4:
        mem.wr(R_PAIR_CONSUME, 4)
    mem.barrier()
    _emit({"sent": 1, "hdr": "0x%08x" % HDR4, "tx_base": "0x%08x" % TX_BASE})


def cmd_catch(mem, base_occ, timeout_s):
    """Poll occupancy above the pre-send snapshot, pop + report words."""
    deadline = time.monotonic() + timeout_s
    occ = MAX_CREDITS - mem.rd(R_CREDIT_COUNT)
    while occ <= base_occ and time.monotonic() < deadline:
        time.sleep(0.005)
        occ = MAX_CREDITS - mem.rd(R_CREDIT_COUNT)
    delta = occ - base_occ
    words = []
    for _ in range(max(0, min(delta, 8))):
        words.append("0x%08x" % mem.rd(RXF_BASE))
    _emit({"base_occ": base_occ, "occ": occ, "delta": delta,
           "words": words,
           "hdr_match": 1 if (words and words[0] == "0x%08x" % HDR4) else 0})


# ── Measurement roles (GO-barrier protocol) ──────────────────────────────

def _wait_go():
    _emit({"ev": "ready"})
    line = sys.stdin.readline()
    if not line or line.strip().split()[0] != "GO":
        _emit({"ev": "aborted", "reason": "no GO (got %r)" % line.strip()})
        sys.exit(2)
    parts = line.strip().split()
    return float(parts[1]) if len(parts) > 1 else 0.0


def _observer_fields(mem):
    st = decode_status(mem)
    return {
        "fcsm": st["fcsm"], "cal_done": st["cal_done"],
        "credit_obs": st["pair_credits"], "occupancy": st["occupancy"],
        "fe_rx_is_full": st["fe_rx_is_full"],
        "a2l_replay_app_valid": st["a2l_replay_app_valid"],
        "a2l_fc_replay_link_valid": st["a2l_fc_replay_link_valid"],
    }


def _pctl(sorted_vals, q):
    return sorted_vals[min(len(sorted_vals) - 1,
                           int(q * len(sorted_vals)))]


def role_stream(mem, cfg):
    """T1-style credit-gated M->S stream, windowed (per tlchar
    cmd_stream, but emitting one NDJSON sample per window)."""
    burst = int(cfg.get("burst_words", 16))
    duration = float(cfg.get("duration_s", 10.0))
    win_s = float(cfg.get("win_s", 0.5))
    rate_pps = float(cfg.get("rate_pps", 0.0))
    hdr = ((burst & 0xFFF) << 20) | (1 << 18)   # WR_REQ, length=burst
    cost = burst + 2
    _wait_go()

    t_start = time.monotonic_ns()
    end = t_start + int(duration * 1e9)
    pkts = words = seq = 0
    win_pkts = win_words = 0
    win_starve_ns = 0
    win_t0 = t_start
    next_pkt_ns = t_start
    mbps = []
    timeouts = 0

    while True:
        now = time.monotonic_ns()
        if now >= end:
            break
        # window rollover
        if now - win_t0 >= int(win_s * 1e9):
            el = (now - win_t0) / 1e9
            tput = win_pkts * burst * 4 * 8 / el / 1e6
            mbps.append(tput)
            sample = {"ev": "sample", "board": "master", "dir": "m2s",
                      "t_ns": now - t_start, "win_s": round(el, 4),
                      "words_tx": win_words, "words_rx": 0,
                      "pkts": win_pkts,
                      "throughput_mbps": round(tput, 4),
                      "offered_mbps": round(
                          win_words * 4 * 8 / el / 1e6, 4),
                      "starve_pct": round(
                          100.0 * win_starve_ns / (el * 1e9), 2),
                      "err": {"timeouts": timeouts}}
            sample.update(_observer_fields(mem))
            _emit(sample)
            win_pkts = win_words = win_starve_ns = 0
            win_t0 = now
        # offered-rate throttle
        if rate_pps > 0:
            if now < next_pkt_ns:
                mem.idle()
                continue
            next_pkt_ns += int(1e9 / rate_pps)
        # credit gate
        if mem.rd(R_PAIR_CREDIT) < cost:
            s0 = time.monotonic_ns()
            while mem.rd(R_PAIR_CREDIT) < cost:
                mem.idle()
                if time.monotonic_ns() > end:
                    break
            win_starve_ns += time.monotonic_ns() - s0
            continue
        mem.wr(TX_BASE, hdr)
        mem.wr(TX_BASE, 0x44010000)
        for i in range(burst):
            mem.wr(TX_BASE, (0xDA << 24) | ((seq & 0xFFF) << 12)
                   | (i & 0xFFF))
        mem.wr(R_PAIR_CONSUME, cost)
        seq += 1
        pkts += 1
        words += cost
        win_pkts += 1
        win_words += cost

    el_total = (time.monotonic_ns() - t_start) / 1e9
    mbps_sorted = sorted(mbps) or [0.0]
    _emit({"ev": "done", "summary": {
        "board": "master", "test_leg": "stream",
        "elapsed_s": round(el_total, 3), "packets": pkts,
        "words_total": words, "payload_words": pkts * burst,
        "throughput_mbps_mean": round(sum(mbps_sorted) / len(mbps_sorted), 4),
        "throughput_mbps_p5": round(_pctl(mbps_sorted, 0.05), 4),
        "throughput_mbps_p95": round(_pctl(mbps_sorted, 0.95), 4),
        "errors": timeouts,
        "end_pair_credits": mem.rd(R_PAIR_CREDIT)}})


def role_drain(mem, cfg):
    """Peer leg: max-rate RX-FIFO drain, windowed (tlchar cmd_drain)."""
    duration = float(cfg.get("duration_s", 10.0))
    win_s = float(cfg.get("win_s", 0.5))
    _wait_go()

    t_start = time.monotonic_ns()
    end = t_start + int(duration * 1e9)
    drained = 0
    win_words = 0
    win_t0 = t_start
    mbps = []
    while True:
        now = time.monotonic_ns()
        if now >= end:
            break
        if now - win_t0 >= int(win_s * 1e9):
            el = (now - win_t0) / 1e9
            tput = win_words * 4 * 8 / el / 1e6
            mbps.append(tput)
            sample = {"ev": "sample", "board": "slave", "dir": "m2s",
                      "t_ns": now - t_start, "win_s": round(el, 4),
                      "words_tx": 0, "words_rx": win_words, "pkts": 0,
                      "throughput_mbps": round(tput, 4),
                      "offered_mbps": None, "starve_pct": None,
                      "err": {"timeouts": 0}}
            sample.update(_observer_fields(mem))
            _emit(sample)
            win_words = 0
            win_t0 = now
        occ = MAX_CREDITS - mem.rd(R_CREDIT_COUNT)
        if occ <= 0:
            mem.idle()
            continue
        for _ in range(min(occ, 256)):
            mem.rd(RXF_BASE)
            drained += 1
            win_words += 1

    el_total = (time.monotonic_ns() - t_start) / 1e9
    mbps_sorted = sorted(mbps) or [0.0]
    _emit({"ev": "done", "summary": {
        "board": "slave", "test_leg": "drain",
        "elapsed_s": round(el_total, 3), "drained_words": drained,
        "throughput_mbps_mean": round(sum(mbps_sorted) / len(mbps_sorted), 4),
        "throughput_mbps_p5": round(_pctl(mbps_sorted, 0.05), 4),
        "throughput_mbps_p95": round(_pctl(mbps_sorted, 0.95), 4),
        "end_occupancy": MAX_CREDITS - mem.rd(R_CREDIT_COUNT)}})


# ── Entry point ───────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="TideLink perf agent")
    ap.add_argument("--fake", action="store_true",
                    help="DEV MODE: in-process die model, no /dev/mem")
    ap.add_argument("--cmd", help="one-shot: probe|send4|catch")
    ap.add_argument("--args", nargs="*", default=[])
    ap.add_argument("--cfg-json", help="measurement run config (GO barrier)")
    ns = ap.parse_args()

    mem = _FakeMem() if ns.fake else _DevMem()

    if ns.cmd:
        if ns.cmd == "probe":
            cmd_probe(mem)
        elif ns.cmd == "send4":
            cmd_send4(mem)
        elif ns.cmd == "catch":
            cmd_catch(mem, int(ns.args[0]), float(ns.args[1]))
        else:
            _emit({"error": "unknown cmd %s" % ns.cmd})
            sys.exit(1)
        return

    if ns.cfg_json:
        cfg = json.loads(ns.cfg_json)
        role = cfg.get("role")
        if role == "stream":
            role_stream(mem, cfg)
        elif role == "drain":
            role_drain(mem, cfg)
        else:
            _emit({"error": "unknown role %r" % role})
            sys.exit(1)
        return

    ap.error("need --cmd or --cfg-json")


if __name__ == "__main__":
    main()

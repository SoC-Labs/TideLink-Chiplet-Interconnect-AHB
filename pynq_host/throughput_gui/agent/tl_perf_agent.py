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
    tl_perf_agent.py --cmd setthr --args VALUE      (RELEASE_THRESHOLD)

  live link monitor (Phase A of the link-monitor GUI):
    tl_perf_agent.py --cmd monitor --args PERIOD_MS DURATION_S [--perf] [--crc]
      -> {"ev":"mon","seq":N,"t":<monotonic>,"r":{"008":..,"00c":..}}  per poll
      -> {"ev":"mon_err","seq":N,"t":..,"reason":".."}        on a read error
      -> {"ev":"done","summary":{"samples":N,"elapsed_s":..,"errors":N}}
    DURATION_S <= 0 runs until stdin closes / SIGTERM (server-controlled
    stop); the server always passes a finite duration as a backstop.

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
speculative TX, ever. The monitor loop NEVER touches AHB_TX and never
reads an offset outside MONITOR_WHITELIST (enforced in _mon_rd, not by
convention — see the comment there).
"""
import argparse
import ctypes
import json
import os
import select
import signal
import struct
import sys
import time

PAGE = 4096
TX_BASE = int(os.environ.get("TIDELINK_TX_BASE", "0x44000000"), 16)
RXF_BASE = int(os.environ.get("TIDELINK_RXFIFO_BASE", "0x44010000"), 16)
PAIR_BASE = 0x44032000
R_REL_THRESH = PAIR_BASE + 0x004     # RELEASE_THRESHOLD, RW, POR 20
R_PKT_WORD_LEN = PAIR_BASE + 0x008   # current packet word length (RO)
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO available credits
R_STATUS = PAIR_BASE + 0x010
R_RELEASE_ACC = PAIR_BASE + 0x018    # sub-threshold freed credits (RO)
R_CTRL = PAIR_BASE + 0x01C           # [2] LOCK — blocks RELEASE_THRESHOLD
R_RELEASED_ACC = PAIR_BASE + 0x020   # read-clear  <- NOT 0x018, see above
R_PAIR_CREDIT = PAIR_BASE + 0x028    # SW-maintained credits toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C   # WO: decrement pair counter by N
R_TRAINING = PAIR_BASE + 0x100       # [0] swi_training_mode
R_LANE_STATUS = PAIR_BASE + 0x108
R_SYNC_DET = PAIR_BASE + 0x114       # [31:16] sync_detected sat-count
R_PHY_ID = PAIR_BASE + 0x11C         # PHY_ALIGN_ID — NEVER write (V2 write
                                     # latches a dormant FINALIZE_GO sticky)
R_SYNC_OBS = PAIR_BASE + 0x120       # V2 only, marker 0x5C
R_SYNC_DETECT = PAIR_BASE + 0x124    # V2 only, marker 0x5D
R_EPOCH_STATUS = PAIR_BASE + 0x140   # SWI_EPOCH_STATUS (V2)
R_OBS_MASK_HS = PAIR_BASE + 0x194    # OBS_MASK_HS
R_OBS_CAL = PAIR_BASE + 0x198        # OBS_CAL (M7 calibrator obs)
R_OBS_FCCRED = PAIR_BASE + 0x19C     # OBS_FC_CREDIT (2026-06-12+)
MAX_CREDITS = 4096
HDR4 = 0x00240000                    # WR_REQ, 2 payload words

REL_THRESHOLD_POR = 20               # RTL POR of RELEASE_THRESHOLD
REL_THRESHOLD_MAX = 4095

# Wlink FC-node CRC error count: Wlink APB region 0x4403_0000, TideLink FC
# node at +0x1700, "CRC Errors" [15:0] RO at node+0x20
# (docs/REGISTER_MAP.md:471). Accumulating, NOT read-clear.
# STRICTLY OPT-IN (--crc) and OFF by default — see _crc_rd for why.
WLINK_CRC_ERR_ADDR = 0x44031720

# ── Poll whitelist — the ONLY offsets the monitor loop may read ──────────
#
# HOST-SIDE TWIN: pynq_host/throughput_gui/regmap.py MONITOR_WHITELIST.
# These two tuples MUST stay in lockstep (same offsets, same key strings) —
# the host decodes what this agent emits by exactly these keys, and
# tests/test_agent_monitor.py asserts they are identical. The duplication is
# deliberate: this file is cat-ed to a plain PYNQ image and run standalone
# with NOTHING importable beside the stdlib, so it cannot import regmap.
#
# WHITELIST-DRIVEN, NOT "read a range": undecoded APB addresses can hang the
# PS and several nearby offsets are read-clear. Every entry is RO with no
# read side effect.
MONITOR_WHITELIST = (
    (0x008, "008"),   # PACKET_WORD_LENGTH
    (0x00C, "00c"),   # CREDIT_COUNT (free credits, not occupancy)
    (0x010, "010"),   # STATUS (sticky overrun/underrun/master_error)
    (0x018, "018"),   # RELEASE_ACC
    (0x01C, "01c"),   # CTRL — [2] LOCK. A blocked RELEASE_THRESHOLD write
                      #   raises NO pslverr (tidelink_apb_regs.sv:261,696),
                      #   so this readback is the ONLY way to know whether a
                      #   load-generator setting could ever land. Keep it.
    (0x028, "028"),   # PAIR_CREDIT_COUNTER
    (0x100, "100"),   # SWI_TRAINING_MODE
    (0x108, "108"),   # SWI_LANE_STATUS  <- headline register
    (0x114, "114"),   # SYNC_DET — only [31:16] is real; [15:0] is tied 0 in
                      #   RTL, so the host must never surface the low half
    (0x11C, "11c"),   # PHY_ALIGN_ID, constant 0x5041_0100. READ ONLY, EVER:
                      #   a V2 WRITE here latches a dormant FINALIZE_GO sticky
    (0x120, "120"),   # SYNC_OBS    V2 only, marker 0x5C in [31:24]
    (0x124, "124"),   # SYNC_DETECT V2 only, marker 0x5D in [31:24].
                      #   Both read 0 by construction on a V1 build, which is
                      #   NOT "zero syncs" — hence the markers.
    (0x140, "140"),   # SWI_EPOCH_STATUS (V2)
    (0x194, "194"),   # OBS_MASK_HS
    (0x198, "198"),   # OBS_CAL
    (0x19C, "19c"),   # OBS_FC_CREDIT (marker 0xFC)
)
MONITOR_OFFSETS = frozenset(off for off, _ in MONITOR_WHITELIST)

# Offsets that must NEVER be read by any polling loop. Mirrors
# regmap.FORBIDDEN_OFFSETS.
#   0x020 / 0x024  read-clear credit accumulators — reading corrupts the
#                  credit protocol the link depends on (drain path owns them)
#   0x038          PTP_RX_PAYLOAD — read clears PTP_CTRL.rx_valid
#   0x15C / 0x160  EYE_CRC_ERR_LANE_LO/HI — read-clears
#   0x168          EYE_SCORE_DATA — auto-increments the point index
#   0x1AC/0x1B0/   board-proven UNINTERRUPTIBLE PS hang on read; recovery is
#   0x1B4          a power-cycle (docs/HANDOVER_2026_07_10.md:14)
FORBIDDEN_OFFSETS = frozenset([
    0x020, 0x024, 0x038, 0x15C, 0x160, 0x168, 0x1AC, 0x1B0, 0x1B4,
])

# ── Phase-B perf block (regions 5/6/7, src/rtl/tidelink_perf.sv) ─────────
# Read ONLY while frozen. PERF_CTRL[2] is a write-PULSE (clear_counters,
# tidelink_perf.sv:240) and always reads back 0 (read mux line 463), so a
# writability probe must look at [0] enable, not at [2].
#
# VINTAGE: before the 2026-07-17 region-decode fix the block computed
# perf_reg_region = apb_region[1:0], so APB regions {5,6,7} mapped to
# {01,10,11} — region 5 could never produce 2'b00, PERF_CTRL was physically
# UNWRITABLE, and the whole block reads ONE REGION LOW (PERF_ID surfaces at
# 0x0DC, not 0x0FC). "PERF_ID at 0x0FC" is therefore NOT a sound liveness
# probe: pre-fix it reads 0, and so does a dead bus. The agent reads the
# whole PERF_WHITELIST (0x0DC is in it) and reports the 0x0A0
# write/readback — the only sound test that CTRL is live. Classification
# is the host's job (regmap.perf_vintage).
PERF_CTRL_OFF = 0x0A0
PERF_CTRL_ENABLE = 1 << 0
PERF_CTRL_FREEZE = 1 << 1
PERF_CTRL_CLEAR = 1 << 2
PERF_ID_OFF = 0x0FC
PERF_ID_EXPECT = 0x50460100          # "PF" v1.0 — block SYNTHESISED, no more

PERF_WHITELIST = (
    (0x0AC, "0ac"),   # PERF_STATUS
    (0x0C8, "0c8"),   # TX_PKT_COUNT
    (0x0CC, "0cc"),   # RX_PKT_COUNT
    (0x0D0, "0d0"),   # TX_WORD_COUNT
    (0x0D4, "0d4"),   # RX_WORD_COUNT
    (0x0D8, "0d8"),   # TX_STALL_COUNT
    (0x0DC, "0dc"),   # RX_STALL_COUNT
    (0x0E0, "0e0"),   # LINK_BUSY_COUNT
    (0x0E4, "0e4"),   # CREDIT_STARVE_COUNT
    (0x0E8, "0e8"),   # SAMPLE_COUNT
    (0x0EC, "0ec"),   # PERF_DEBUG
    (0x0F0, "0f0"),   # TX_INFLIGHT
    (0x0F4, "0f4"),   # RX_INFLIGHT
    (0x0F8, "0f8"),   # PERF_CONG_STATE
    (0x0FC, "0fc"),   # PERF_ID
)
PERF_OFFSETS = frozenset(off for off, _ in PERF_WHITELIST)
# PERF_CTRL is written by the window protocol and read back by the probe,
# so it joins the perf access set — but ONLY under --perf.
PERF_ACCESS_OFFSETS = PERF_OFFSETS | frozenset([PERF_CTRL_OFF])

# S_DONE, tidelink_phy_align_calibrator.sv:473
CAL_STATE_DONE = 4


def _emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


FPGA_MGR_STATE = "/sys/class/fpga_manager/fpga0/state"


def _pl_programmed_guard():
    """Refuse to mmap TideLink registers unless the PL is programmed.

    LEARNED THE HARD WAY, 2026-07-24: a Z2 that has rebooted still has the
    golden bitstream sitting in /lib/firmware, but nothing reloads it into
    the PL. The APB block at 0x4403_2000 then has no slave behind it, and
    on Zynq-7000 an AXI GP read to an undecoded address never completes —
    the PS stalls uninterruptibly and the board drops off the network until
    it is power-cycled. That is precisely what one ad-hoc probe did to
    z2_02, and NOTHING in the register whitelist protects against it,
    because the hazard is the absence of the peripheral, not the offset.

    ``/sys/class/fpga_manager/fpga0/state`` reads "operating" when the PL
    is programmed and "unknown" when it is not. It is a sysfs read with no
    bus traffic, so it is safe to check first, every time.

    This is a cheap necessary condition, not proof that the loaded
    bitstream is TideLink — provenance + verify_deployed.sh remain the
    authority on WHICH image is loaded. Set TIDELINK_SKIP_PL_CHECK=1 only
    on a platform where the fpga_manager node is absent or lies.
    """
    if os.environ.get("TIDELINK_SKIP_PL_CHECK") == "1":
        return
    try:
        fh = open(FPGA_MGR_STATE)
        try:
            state = fh.read().strip()
        finally:
            fh.close()
    except (IOError, OSError):
        # No fpga_manager node: cannot prove either way. Say so rather
        # than pretend the check passed.
        _emit({"warn": "no %s — PL-programmed check skipped"
                       % FPGA_MGR_STATE})
        return
    if state != "operating":
        sys.stderr.write(
            "\n[%s] REFUSING: PL is not programmed (%s = %r).\n"
            "  Reading 0x4403_xxxx with no PL image HANGS THE PS on "
            "Zynq-7000\n  (undecoded AXI GP read never completes; recovery "
            "is a power-cycle).\n  Load the TideLink bitstream first "
            "(deploy_pair.sh), then retry.\n"
            % (os.path.basename(__file__), FPGA_MGR_STATE, state))
        _emit({"error": "pl_not_programmed", "fpga_manager_state": state})
        raise SystemExit(4)


# ── Backends ──────────────────────────────────────────────────────────────

class _DevMem(object):
    """mmap-once /dev/mem accessor (identical to tlchar.py)."""

    def __init__(self):
        # --- ZynqMP (KR260) SAFETY GUARD -------------------------------------
        # This backend mmaps RAW Pynq-Z2 control literals (0x4403_xxxx /
        # 0x4404_xxxx / 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP
        # (KR260) those addresses are UNDECODED with NO bus timeout => a hard
        # PS hang. Pynq-Z2 ONLY. Refuse before opening /dev/mem (the --fake
        # backend never reaches here). On a KR260 use tl_poke.py (0x8403_xxxx)
        # or tl39.py.
        _tl_guard_soc = (os.environ.get("TIDELINK_SOC") or "").strip().lower()
        if _tl_guard_soc not in ("", "z2", "pynq-z2", "pynq_z2", "zynq7", "zynq"):
            sys.stderr.write(
                "\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 "
                "literals (0x4403_xxxx)\n  UNDECODED on a ZynqMP (KR260) => "
                "hard PS hang. Pynq-Z2 ONLY.\n  On a KR260 use tl_poke.py "
                "(0x8403_xxxx) or tl39.py, or run this agent with --fake.\n"
                % (os.path.basename(__file__), os.environ.get("TIDELINK_SOC")))
            raise SystemExit(3)
        _pl_programmed_guard()
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
      TIDELINK_FAKE_OVERRUN_AT_S  latch STATUS[1] (sticky overrun) after N s
      TIDELINK_FAKE_PERF_DEAD   1 => models a GOLDEN Z2 image: PERF_ID
                                answers but PERF_CTRL writes land nowhere
                                and every counter reads 0. Default is LIVE
                                counters so the Phase-B UI can be built
                                before the rebuilt bitstream exists.
      TIDELINK_FAKE_CRC_ERRS    Wlink CRC error count (default 0)

    Model: pair credits replenish at the link-capacity rate (that is the
    peer draining its RX FIFO and returning credits), so a credit-gated
    stream loop is throttled to a realistic sustained rate. Words written
    to AHB_TX are appended to ``<dir>/m2s.spool`` ("t_ns hex8" lines);
    the slave-side instance ingests spool lines older than ~2 ms into
    its RX-FIFO model, so occupancy / drain genuinely track the master.
    """

    LATENCY_NS = 2_000_000   # one-way delivery latency

    # Perf MODEL constants (see _perf_counters) — the §6 sanity anchor:
    # ~96 PL cycles per delivered word (the PS->PL store round trip), of
    # which the link itself is busy ~16 => ~17% utilisation.
    PERF_CYCLES_PER_WORD = 96
    PERF_LINK_CYCLES_PER_WORD = 16
    PERF_TX_STALL_CYCLES_PER_WORD = 8
    PERF_RX_STALL_CYCLES_PER_WORD = 2
    PERF_STARVE_CYCLES_PER_WORD = 1

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
        # — monitor-whitelist model state (Phase A) —
        self._rel_thresh = REL_THRESHOLD_POR
        # CTRL.LOCK: models an image where the load-generator control is
        # welded shut. The block is SILENT (no pslverr), so the only
        # evidence is 0x01C[2] plus a readback mismatch.
        self._ctrl_lock = os.environ.get("TIDELINK_FAKE_CTRL_LOCK") == "1"
        ov = os.environ.get("TIDELINK_FAKE_OVERRUN_AT_S", "")
        self._overrun_at = float(ov) if ov else None
        self._sticky_status = 0          # STICKY in HW: never self-clears
        self._crc_errs = int(os.environ.get("TIDELINK_FAKE_CRC_ERRS", "0"))
        self._last_pkt_len = 0
        self._drained = 0
        self._committed = 0
        # — perf-block model state (Phase B) —
        self._perf_dead = os.environ.get("TIDELINK_FAKE_PERF_DEAD") == "1"
        self._perf_ctrl = 0
        self._perf_t0 = self._t0
        self._perf_frozen = None         # snapshot taken at the freeze write

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
            # monitor model: PACKET_WORD_LENGTH tracks the last packet
            # that landed, STATUS[4] packet_committed latches with it
            self._last_pkt_len = len(parts) - 1
            self._committed = 1
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

    # — monitor-whitelist models —
    def _status(self):
        """STATUS @ 0x010. Bits [3:1] are STICKY in HW (cleared only by
        CTRL.FLUSH), so once TIDELINK_FAKE_OVERRUN_AT_S fires the bit
        stays set for the rest of the process — exactly the behaviour the
        UI's fault banner must not auto-clear."""
        if (self._overrun_at is not None
                and (time.monotonic() - self._t0) >= self._overrun_at):
            self._sticky_status |= 1 << 1          # overrun
        return self._sticky_status | ((1 << 4) if self._committed else 0)

    def _release_acc(self):
        """RELEASE_ACC @ 0x018 = credits freed but still BELOW
        RELEASE_THRESHOLD. With the POR threshold of 20 it sawtooths
        0..19 as the drain runs; with the threshold set to 0 (release per
        drain) nothing can accumulate sub-threshold, so it reads 0 —
        which is the whole point of the load-generator control."""
        thr = self._rel_thresh
        return (self._drained % thr) if thr > 0 else 0

    def _sync_count(self):
        if self._link_down:
            return 0
        return min(int((time.monotonic() - self._t0) * 40.0),  # ~40 sync/s
                   0xFFFF)

    def _sync_det(self):
        """SYNC_DET @ 0x114 — [31:16] saturating sync_detected count.
        [15:0] is tied 0 in RTL and is left 0 here so a host that reads
        the low half sees the same nothing it would see on silicon."""
        return self._sync_count() << 16

    def _sync_obs(self):
        """SYNC_OBS @ 0x120 — V2 only, marker 0x5C. This fake models a V2
        build; a V1 build reads 0 here, which is why the marker exists."""
        if self._link_down:
            return 0
        return ((0x5C << 24) | (0 << 17) | (1 << 16) | self._sync_count())

    def _sync_detect(self):
        """SYNC_DETECT @ 0x124 — V2 only, marker 0x5D, [23:16] lane mask."""
        if self._link_down:
            return 0
        return (0x5D << 24) | (0xFF << 16) | self._sync_count()

    def _epoch_status(self):
        if self._link_down:
            return 0
        return (12 << 1) | 1            # anchored, span 12 words

    def _obs_mask_hs(self):
        """OBS_MASK_HS @ 0x194 — the fake models a GENUINE handshake:
        match=1 AND gate=1. (gate=1 with match=0 is the sham-gate
        signature regmap.health() flags; inject it by hand, never by
        default, so a green fake can't launder that defect.)"""
        if self._link_down:
            return 0
        return (1 << 19) | (1 << 20)

    def _obs_cal(self):
        """OBS_CAL @ 0x198 — [3:0] cal_state, [19:4] resweep ctr,
        [20] live training_mode."""
        if self._link_down:
            return 0
        return (0 << 20) | (1 << 4) | CAL_STATE_DONE

    # — perf-block model (Phase B) —
    #
    # POST-FIX slot map: which logical counter each APB offset returns once
    # the 2026-07-17 region-decode fix is in the bitstream.
    PERF_MAP_POSTFIX = {
        0x0AC: "status", 0x0C8: "tx_pkt", 0x0CC: "rx_pkt",
        0x0D0: "tx_word", 0x0D4: "rx_word", 0x0D8: "tx_stall",
        0x0DC: "rx_stall", 0x0E0: "link_busy", 0x0E4: "credit_starve",
        0x0E8: "sample", 0x0EC: "debug", 0x0F0: "tx_inflight",
        0x0F4: "rx_inflight", 0x0F8: "cong",
    }
    # PRE-FIX slot map (the GOLDEN Z2 images): perf_reg_region =
    # apb_region[1:0] mapped regions {5,6,7} -> {01,10,11}, so APB region 5
    # returns Region-6 CONTENT, APB region 6 returns Region-7 content, and
    # APB region 7 (2'b11) hits the mux default and reads 0. The whole block
    # sits ONE REGION LOW: PERF_ID lands at 0x0DC and 0x0FC reads 0 — the
    # same as a dead bus, which is exactly why "PERF_ID at 0x0FC" is not a
    # sound liveness probe. Region 5 can never decode as 2'b00, so
    # PERF_CTRL is physically unwritable and the counters free-run from POR.
    PERF_MAP_PREFIX = {
        0x0A8: "tx_pkt", 0x0AC: "rx_pkt", 0x0B0: "tx_word",
        0x0B4: "rx_word", 0x0B8: "tx_stall", 0x0BC: "rx_stall",
        0x0C0: "link_busy", 0x0C4: "credit_starve", 0x0C8: "sample",
        0x0CC: "debug", 0x0D0: "tx_inflight", 0x0D4: "rx_inflight",
        0x0D8: "cong",
    }
    PERF_ID_OFF_PREFIX = 0x0DC           # Region-7 slot 7, read one low

    def _perf_counters(self, origin):
        """A MODEL, not a measurement.

        Self-consistent counter set built from the §6 sanity anchor: each
        delivered word costs ~96 PL cycles of PS->PL store round trip, of
        which the link is busy ~16 => utilisation ~= 16/96 ~= 17%. That
        makes the Phase-B UI (and its arithmetic) developable before the
        rebuilt bitstream exists, without pretending to be silicon.
        Counters saturate at 32 bits like the RTL (sat_inc)."""
        el = max(0.0, time.monotonic() - origin)
        words = self.cap_wps * el
        pkts = words / 18.0                     # N=16 payload + 2 hdr
        credit = MAX_CREDITS - len(self._rxq)

        def _sat(x):
            return min(int(x), 0xFFFFFFFF)

        return {
            # PERF_STATUS: ts valids + [3] freeze, sampled with the rest
            "status": 0x7 | (((self._perf_ctrl >> 1) & 1) << 3),
            "tx_pkt": _sat(pkts), "rx_pkt": _sat(pkts),
            "tx_word": _sat(words), "rx_word": _sat(words),
            "tx_stall": _sat(words * self.PERF_TX_STALL_CYCLES_PER_WORD),
            "rx_stall": _sat(words * self.PERF_RX_STALL_CYCLES_PER_WORD),
            "link_busy": _sat(words * self.PERF_LINK_CYCLES_PER_WORD),
            "credit_starve": _sat(words * self.PERF_STARVE_CYCLES_PER_WORD),
            "sample": _sat(words * self.PERF_CYCLES_PER_WORD),
            # PERF_DEBUG: [0] tx_router_idle [13:1] credit [14] fc_tx_valid
            "debug": ((1 if words == 0 else 0) | ((credit & 0x1FFF) << 1)
                      | (0 if words == 0 else (1 << 14))),
            "tx_inflight": 2, "rx_inflight": 2,
            # PERF_CONG_STATE: ewma_credit / level / trend / starve sticky
            "cong": (credit & 0x1FFF),
        }

    def _perf_rd(self, off):
        if self._perf_dead:
            # GOLDEN-IMAGE (pre-fix) MODEL — see PERF_MAP_PREFIX. Counters
            # free-run from POR because nothing can clear them.
            if off == self.PERF_ID_OFF_PREFIX:
                return PERF_ID_EXPECT
            name = self.PERF_MAP_PREFIX.get(off)
            if name is None:
                return 0
            return self._perf_counters(self._t0).get(name, 0)
        if off == PERF_CTRL_OFF:
            # [2] clear is a write-pulse and always reads back 0
            return self._perf_ctrl & ~PERF_CTRL_CLEAR
        if off == PERF_ID_OFF:
            return PERF_ID_EXPECT
        name = self.PERF_MAP_POSTFIX.get(off)
        if name is None:
            return 0
        snap = self._perf_frozen
        if snap is None:
            snap = self._perf_counters(self._perf_t0)
        return snap.get(name, 0)

    def _perf_wr(self, val):
        if self._perf_dead:
            return          # region 5 never decodes as 2'b00: write is lost
        self._perf_ctrl = val & 0x1F
        if val & PERF_CTRL_CLEAR:
            self._perf_t0 = time.monotonic()
        self._perf_frozen = (self._perf_counters(self._perf_t0)
                             if (val & PERF_CTRL_FREEZE) else None)

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
            if not self._rxq:
                return 0
            self._drained += 1
            return self._rxq.popleft()
        if addr == R_OBS_FCCRED:
            # marker 0xFC + healthy credit_max=0x1F (CLASSIC jam keeps
            # fe_full=0 by definition, so the full bit stays clear)
            return (0xFC << 24) | (0 << 16) | (0x07 << 8) | 0x1F
        if addr == R_TRAINING:
            return 0
        if addr == R_PHY_ID:
            # 0x11C is PHY_ALIGN_ID, a CONSTANT block-presence marker
            # (axi_chiplet_controller.sv:2684, docs/REGISTER_MAP.md:223) —
            # not a per-build PHY identity, despite the "PHYID runtime
            # cross-check" name it carries in the host code. The fake used
            # to return an invented 0xFA4E_0001; it now returns what the
            # RTL returns, so --fake and silicon agree on
            # decode_monitor()'s phy_align_present.
            return 0x50410100
        if addr == R_STATUS:
            return self._status()
        if addr == R_REL_THRESH:
            return self._rel_thresh
        if addr == R_PKT_WORD_LEN:
            self._ingest()
            return self._last_pkt_len & 0x3FFF
        if addr == R_RELEASE_ACC:
            self._ingest()
            return self._release_acc()
        if addr == R_CTRL:
            return (1 << 2) if self._ctrl_lock else 0
        if addr == R_SYNC_DET:
            return self._sync_det()
        if addr == R_SYNC_OBS:
            return self._sync_obs()
        if addr == R_SYNC_DETECT:
            return self._sync_detect()
        if addr == R_EPOCH_STATUS:
            return self._epoch_status()
        if addr == R_OBS_MASK_HS:
            return self._obs_mask_hs()
        if addr == R_OBS_CAL:
            return self._obs_cal()
        if addr == WLINK_CRC_ERR_ADDR:
            return self._crc_errs & 0xFFFF
        if PAIR_BASE + 0x0A0 <= addr <= PAIR_BASE + 0x0FC:
            return self._perf_rd(addr - PAIR_BASE)
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
        self._last_pkt_len = len(self._pend)
        self._committed = 1
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
        if addr == R_RELEASED_ACC:
            # W-add: bumps PAIR_CREDIT_COUNTER (and the acc, which the
            # seed path clears with one deliberate read). This is how
            # bring-up primes the credits toward the peer — model it, or
            # --fake cannot exercise the seed step that real hardware
            # cannot run without.
            self._released_acc = min(0xFFFF,
                                     getattr(self, "_released_acc", 0) + val)
            self._pair_credits = self._pair_credits + val
            self._pair_cap = max(self._pair_cap, self._pair_credits)
            return
        if addr == R_REL_THRESH:
            # RW until CTRL.LOCK (0x01C[2]) is set, after which the write
            # is DROPPED SILENTLY — no pslverr, no error, nothing
            # (tidelink_apb_regs.sv:261,696). Modelled faithfully so the
            # setthr lock report is exercised rather than assumed.
            if self._ctrl_lock:
                return
            self._rel_thresh = val & 0xFFF
            return
        if addr == PAIR_BASE + PERF_CTRL_OFF:
            self._perf_wr(val)
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


# ── Link monitor (Phase A) ───────────────────────────────────────────────

def _mon_rd(mem, off, allow=None):
    """The ONE read path the monitor loop uses. RAISES on anything not
    explicitly permitted — never warns, never silently skips.

    This assertion IS the deliverable: it is what makes "the monitor
    issues zero non-whitelisted reads" a checkable property rather than an
    aspiration. A range read or a stray offset on this APB can hard-hang
    the PS (0x1AC/0x1B0/0x1B4, uninterruptible, power-cycle to recover) or
    silently corrupt the credit protocol (0x020/0x024 are read-clear), so
    the cost of a mistake is a bench trip or a week of ghost-chasing.

    ``off`` is PAIR_BASE-relative. FORBIDDEN_OFFSETS is checked FIRST and
    UNCONDITIONALLY, so no ``allow`` set a caller passes can ever open a
    path to those registers. ``allow`` defaults to the monitor whitelist;
    the perf window passes PERF_ACCESS_OFFSETS, and nothing else may
    widen it.
    """
    off = int(off)
    if off in FORBIDDEN_OFFSETS:
        raise ValueError(
            "REFUSING forbidden offset 0x%03X: read-clear or board-proven "
            "PS hang (0x1AC/0x1B0/0x1B4 need a power-cycle to recover)"
            % off)
    allowed = MONITOR_OFFSETS if allow is None else allow
    if off not in allowed:
        raise ValueError(
            "REFUSING offset 0x%03X: not on the monitor whitelist "
            "(undecoded APB reads can hang the PS)" % off)
    return mem.rd(PAIR_BASE + off)


def _crc_rd(mem):
    """Wlink FC-node CRC error count — the ONE address the monitor reads
    outside the PAIR_BASE whitelist, and the ONE genuinely dangerous read
    in the whole loop. STRICTLY opt-in (--crc), OFF by default:

      1. It sits on the Wlink APB half, which has NO stall timeout —
         tidelink_top.sv:815 is a bare pready passthrough, unlike the
         TideLink half which force-completes after 1024 cycles. A wedged
         Wlink sub-slave can pin pready low and take the PS with it.
      2. crc_errors is muxed across clock domains with no synchroniser,
         so a single sample can be TORN. Require two agreeing consecutive
         samples before believing a rise.
      3. It reads 0 whenever the FC node is disabled or in reset, which is
         NOT the same as "no CRC errors".

    Accumulating, not read-clear (docs/REGISTER_MAP.md:471), so repeated
    polling has no side effect on the counter itself.
    """
    return mem.rd(WLINK_CRC_ERR_ADDR) & 0xFFFF


_STOP = {"flag": False}


def _install_stop_signal():
    """SIGTERM (and SIGINT) end the loop CLEANLY so the ``done`` summary
    still reaches the server — a killed poll loop that never summarises
    looks identical to a wedged board."""
    def _handler(signum, frame):
        _STOP["flag"] = True
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, _handler)
        except (ValueError, OSError, AttributeError, RuntimeError):
            pass          # not the main thread: the duration backstop stands


def _stdin_stop():
    """Non-blocking check for the server's stop signal on stdin.

    Only consulted for an OPEN-ENDED run: a finite run must not be killed
    at t=0 by an already-closed stdin (``< /dev/null`` reads ready-then-
    EOF immediately). EOF or any line == stop.
    """
    try:
        ready, _, _ = select.select([sys.stdin], [], [], 0)
    except (ValueError, OSError, TypeError):
        return False      # stdin not selectable (closed / not a real fd)
    if not ready:
        return False
    try:
        sys.stdin.readline()
    except (ValueError, OSError):
        pass
    return True


def _emit_perf_id(mem):
    """First-window probe: distinguish "perf block ABSENT" from "block
    PRESENT but PERF_CTRL not writable".

    The ONLY sound test that CTRL is live is a write/readback of 0x0A0
    bit[0]: write ENABLE, read it back. Probe with ENABLE only —
    PERF_CTRL[2] (clear) is a write-pulse and always reads back 0
    (tidelink_perf.sv:463).

    PERF_ID @ 0x0FC is NOT a liveness probe. On a pre-region-fix image the
    whole block reads one region low, so 0x0FC returns 0 — identical to a
    dead bus — and PERF_ID surfaces at 0x0DC instead. Both offsets are in
    PERF_WHITELIST and ride out in every ``perf`` record; classifying the
    vintage from the pair is the host's job (regmap.perf_vintage). We
    report raw facts here, never a verdict.
    """
    mem.wr(PAIR_BASE + PERF_CTRL_OFF, PERF_CTRL_ENABLE)
    ctrl = _mon_rd(mem, PERF_CTRL_OFF, PERF_ACCESS_OFFSETS)
    pid = _mon_rd(mem, PERF_ID_OFF, PERF_ACCESS_OFFSETS)
    _emit({"ev": "perf_id", "t": time.monotonic(),
           "perf_id": "0x%08x" % pid,
           "block_present": 1 if pid == PERF_ID_EXPECT else 0,
           "ctrl_readback": "0x%08x" % ctrl,
           "perf_ctrl_writable": 1 if (ctrl & PERF_CTRL_ENABLE) else 0})


def _perf_tick(mem, st, window_s):
    """Drive the frozen-window protocol, one step per monitor poll.

    enable+clear -> let the window run -> enable+FREEZE -> read -> emit ->
    enable+clear again. The counters are NEVER read unfrozen: an unfrozen
    read is a smear across an unknown interval, not a window.

    CONSEQUENCE the host must not get wrong: because every window STARTS
    with a clear, each emitted record is ALREADY a delta over ``win_s``,
    not a cumulative count. Differencing two consecutive records gives
    ~zero under steady state. Hence ``window_mode:"cleared"`` in the
    payload — diff against a zero baseline, not against the previous
    record.

    ``win_s`` is quantised to the monitor period (the tick is evaluated
    once per poll), so it is reported per record rather than assumed.
    """
    now = time.monotonic()
    if not st["armed"]:
        if not st["id_done"]:
            _emit_perf_id(mem)
            st["id_done"] = True
        mem.wr(PAIR_BASE + PERF_CTRL_OFF,
               PERF_CTRL_ENABLE | PERF_CTRL_CLEAR)
        st["t0"] = time.monotonic()
        st["armed"] = True
        return
    if now - st["t0"] < window_s:
        return
    mem.wr(PAIR_BASE + PERF_CTRL_OFF,
           PERF_CTRL_ENABLE | PERF_CTRL_FREEZE)      # freeze BEFORE reading
    rec = {}
    for off, key in PERF_WHITELIST:
        rec[key] = _mon_rd(mem, off, PERF_ACCESS_OFFSETS)
    _emit({"ev": "perf", "t": now, "win_s": round(now - st["t0"], 4),
           "window_mode": "cleared", "r": rec})
    # back-to-back windows: unfreeze + clear immediately
    mem.wr(PAIR_BASE + PERF_CTRL_OFF, PERF_CTRL_ENABLE | PERF_CTRL_CLEAR)
    st["t0"] = time.monotonic()


def cmd_monitor(mem, period_ms, duration_s, want_perf=False, want_crc=False,
                perf_window_s=1.0):
    """Whitelist-driven poll loop — one NDJSON ``mon`` line per period.

    Read-only by construction: AHB_TX is never touched, the RX FIFO
    aperture (pop-on-read) is never touched, and every register read goes
    through _mon_rd. Pacing is anchored to the loop start, not to
    "sleep(period) after each poll", so a slow poll does not shift every
    later sample's timestamp (drift makes rate arithmetic lie).
    """
    period_s = max(0.001, float(period_ms) / 1000.0)
    duration_s = float(duration_s)
    open_ended = duration_s <= 0.0
    _install_stop_signal()

    t0 = time.monotonic()
    end = None if open_ended else t0 + duration_s
    perf_st = {"armed": False, "t0": t0, "id_done": False}
    polls = samples = errors = 0

    try:
        while True:
            now = time.monotonic()
            if _STOP["flag"] or (end is not None and now >= end):
                break
            if open_ended and _stdin_stop():
                break

            rec = {}
            try:
                for off, key in MONITOR_WHITELIST:
                    rec[key] = _mon_rd(mem, off)
                if want_crc:
                    rec["crc"] = _crc_rd(mem)
            except Exception as exc:                 # keep going, report
                errors += 1
                _emit({"ev": "mon_err", "seq": polls, "t": now,
                       "reason": "%s: %s" % (type(exc).__name__, exc)})
            else:
                samples += 1
                _emit({"ev": "mon", "seq": polls, "t": now, "r": rec})
            polls += 1

            if want_perf:
                try:
                    _perf_tick(mem, perf_st, perf_window_s)
                except Exception as exc:
                    errors += 1
                    _emit({"ev": "mon_err", "seq": polls,
                           "t": time.monotonic(),
                           "reason": "perf: %s: %s"
                                     % (type(exc).__name__, exc)})

            # drift-free pacing: deadline from the START anchor, never
            # "now + period" (which accumulates every poll's own cost)
            slack = (t0 + polls * period_s) - time.monotonic()
            if end is not None:
                slack = min(slack, end - time.monotonic())
            if slack > 0:
                time.sleep(slack)

        _emit({"ev": "done", "summary": {
            "samples": samples,
            "elapsed_s": round(time.monotonic() - t0, 3),
            "errors": errors}})
    except BrokenPipeError:
        # The server tore the channel down mid-poll. There is nobody left
        # to hand the summary to; exit quietly rather than spraying a
        # traceback (and a second "Exception ignored" at interpreter
        # shutdown) into the run log, where it reads like a board fault.
        try:
            sys.stdout = open(os.devnull, "w")
        except Exception:
            pass


def cmd_setthr(mem, value):
    """Set RELEASE_THRESHOLD (0x004) — the credit-loop load-generator
    control. POR is 20: below that many freed credits nothing is returned
    to the peer, which is exactly how a small drain returns 0 credit and
    starves the loop. 0 = release per drain.

    Writes are BLOCKED once CTRL.LOCK (0x01C[2]) is set, and the block is
    SILENT: no pslverr, no error, the write is simply dropped
    (tidelink_apb_regs.sv:261,696). So we report BOTH pieces of evidence —
    ``ctrl_lock`` straight from 0x01C[2] (the authoritative bit) and
    ``locked``, which also fires on a readback mismatch with the lock bit
    clear, i.e. "the write did not take and we do not know why". Never
    return the stale readback as if the write had landed.
    """
    value = int(value)
    if value < 0 or value > REL_THRESHOLD_MAX:
        _emit({"error": "rel_threshold %d out of range 0..%d"
                        % (value, REL_THRESHOLD_MAX)})
        sys.exit(1)
    mem.wr(R_REL_THRESH, value)
    mem.barrier()
    readback = mem.rd(R_REL_THRESH)
    ctrl_lock = (mem.rd(R_CTRL) >> 2) & 1
    _emit({"rel_threshold": readback, "wrote": value,
           "por": REL_THRESHOLD_POR,
           "ctrl_lock": ctrl_lock,
           "locked": 1 if (ctrl_lock or readback != value) else 0})


def cmd_seed(mem, n):
    """Seed the SW-maintained pair-credit counter toward the peer.

    PAIR_CREDIT_COUNTER (0x028) is RO and software-maintained: it counts
    credits this die believes the PEER's RX FIFO has free. It is bumped by
    writes to RELEASED_CREDITS_ACC (0x020) and decremented by
    PAIR_CREDIT_CONSUME (0x02C). At POR it is 0, so a freshly-brought-up
    link has NO credits toward the peer and every credit-gated sender
    starves immediately — which reads on screen exactly like a dead link.
    Seeding is therefore a mandatory bring-up step, not an optimisation.

    Procedure is the one in char_session.sh::seed_one — seed with the
    peer's FREE credits minus what we already think we have:
        n = peer.credit_count - local.pair_credits
    The caller computes n from the two probes; this command just applies
    it. Port of tlchar.py::cmd_seed.

    NOTE ON 0x020: this register is in regmap.FORBIDDEN_OFFSETS and the
    monitor's poll loop must NEVER touch it, because a READ clears the
    accumulator and would corrupt the credit bookkeeping. This command is
    the one legitimate owner of that access — it WRITES the delta, then
    reads once, deliberately, to clear the accumulator side (the write
    bumps both the pair counter and the acc). Do not copy this pattern
    anywhere else.
    """
    n = int(n)
    if n < 0 or n > 0xFFFF:
        _emit({"error": "seed %d out of range 0..65535 (acc is 16-bit "
                        "saturating)" % n})
        sys.exit(1)
    before = mem.rd(R_PAIR_CREDIT)
    if n:
        mem.wr(R_RELEASED_ACC, n)
        mem.barrier()
        mem.rd(R_RELEASED_ACC)          # clear the acc side (see above)
    _emit({"seeded": n, "pair_credits_before": before,
           "pair_credits": mem.rd(R_PAIR_CREDIT)})


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
    ap.add_argument("--cmd",
                    help="one-shot: probe|send4|catch|setthr|seed|monitor")
    ap.add_argument("--args", nargs="*", default=[])
    ap.add_argument("--perf", action="store_true",
                    help="monitor: also sample the Phase-B perf window")
    ap.add_argument("--perf-window", type=float, default=1.0,
                    help="monitor: perf window length in seconds")
    ap.add_argument("--crc", action="store_true",
                    help="monitor: also read the Wlink CRC counter "
                         "(OPT-IN: unprotected APB half, see _crc_rd)")
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
        elif ns.cmd == "seed":
            cmd_seed(mem, ns.args[0])
        elif ns.cmd == "setthr":
            cmd_setthr(mem, int(ns.args[0]))
        elif ns.cmd == "monitor":
            period_ms = float(ns.args[0]) if ns.args else 200.0
            duration_s = float(ns.args[1]) if len(ns.args) > 1 else 0.0
            cmd_monitor(mem, period_ms, duration_s,
                        want_perf=ns.perf, want_crc=ns.crc,
                        perf_window_s=ns.perf_window)
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

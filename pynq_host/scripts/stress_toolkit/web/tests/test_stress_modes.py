"""Tests for the six stress-mode generators using FakeMmio.

We model a fairly faithful credit-counting peer behaviour:

* Writes to AHB_TX[0] are interpreted as the FifoPacket length word;
  writes to AHB_TX[N*4] for N>0 buffer the payload word N.
* The peer's AHB_FIFO behaviour mirrors a FIFO: reading address 0
  triggers the length capture into REG_PKT_WORD_LEN, then reads at
  N*4 drain payload N.
* CURRENT_CREDITS at the SOURCE drops by total_words on commit.
* RELEASED_ACC on the source rises by total_words when peer drains.
* DOORBELL writes on the SOURCE bump DOORBELL_RESP_ACC on the peer by
  MAX_CREDITS.
* DOORBELL_RESP_ACC is W-add / R-clear.

This is intentionally simplified: it captures the credit/doorbell
behaviour we expect to verify on the bench, not every RTL nuance.
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[5]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from pynq_host.scripts.stress_toolkit.stress_lib import (
    AHB_FIFO_BASE, AHB_TX_BASE, APB_BASE, MAX_CREDITS,
)
from pynq_host.scripts.stress_toolkit.web.mmio_remote import (
    FakeMmio, MmioInterface,
)
from pynq_host.scripts.stress_toolkit.web.stress_modes import (
    DoorbellStressConfig, ModeContext, PacketStressConfig,
    PhyHealthConfig, FcsmMonitorConfig,
    PtpConvergenceConfig,
    doorbell_stress, fcsm_monitor, packet_stress,
    phy_health_monitor, ptp_convergence,
)


# ── Pair model — simulates the two boards' MMIO behaviour. ───────────────

class PairBoard:
    """One half of the M/S pair, with FakeMmio shaped to honour
    packet/credit/doorbell semantics."""

    def __init__(self, peer_ref: list, name: str):
        self.name = name
        self.tx_buf: list[int] = []
        self.tx_length: int | None = None
        self.rx_q: list[list[int]] = []
        self.rx_drain_idx = 0
        self.rx_drain_active: list[int] | None = None
        # APB regs
        self.current_credits = MAX_CREDITS
        self.released_acc = 0
        self.doorbell_resp_acc = 0
        self.pkt_word_len = 0
        # FCSM healthy by default
        self.swi_lane_status = 0x0001_00FF  # locked=0xFF, cal_done=1
        self.ecc_counters = 0
        # PHY regs (8 regs from 0x4403_2160). All zero / OK / canary pass.
        self.phy_regs = {
            0x00: 0x33333333,        # thresh = 3 per lane
            0x04: 0, 0x08: 0,
            0x0C: 0, 0x10: 0,
            0x14: 0x2,               # mode = mean
            0x18: 0x5555,            # all 8 lanes OK
            0x1C: 0xFFFF,            # canary pass + valid
        }
        self.peer_ref = peer_ref     # mutable [None] so we can wire later

    def peer(self) -> "PairBoard":
        return self.peer_ref[0]

    def read(self, addr: int) -> int:
        if addr == APB_BASE + 0x000C:        # CURRENT_CREDITS
            return self.current_credits
        if addr == APB_BASE + 0x0008:        # REG_PKT_WORD_LEN
            return self.pkt_word_len
        if addr == APB_BASE + 0x0020:        # RELEASED_ACC: R-clear
            v = self.released_acc
            self.released_acc = 0
            return v
        if addr == APB_BASE + 0x0024:        # DOORBELL_RESP_ACC: R-clear
            v = self.doorbell_resp_acc
            self.doorbell_resp_acc = 0
            return v
        if addr == APB_BASE + 0x2108:        # SWI_LANE_STATUS
            return self.swi_lane_status
        if addr == APB_BASE + 0x2114:        # ECC counters
            return self.ecc_counters
        if 0x4403_2160 <= addr < 0x4403_2180:
            return self.phy_regs.get(addr - 0x4403_2160, 0)
        if AHB_FIFO_BASE <= addr < AHB_FIFO_BASE + 0x10000:
            return self._fifo_read(addr - AHB_FIFO_BASE)
        return 0

    def write(self, addr: int, val: int) -> None:
        if addr == APB_BASE + 0x0014:        # REG_DOORBELL
            # Bump peer's doorbell_resp_acc by MAX_CREDITS.
            self.peer().doorbell_resp_acc += MAX_CREDITS
            return
        if addr == APB_BASE + 0x2034:        # PTP_CTRL
            return
        if addr == APB_BASE + 0x2040:        # HW_SYNC_CTRL
            return
        if addr == APB_BASE + 0x2044:        # HW_SYNC_INTERVAL
            return
        if addr == APB_BASE + 0x204C:        # SERVO_CTRL
            return
        if addr == APB_BASE + 0x2050 or addr == APB_BASE + 0x2054 \
                or addr == APB_BASE + 0x2058:
            return
        if AHB_TX_BASE <= addr < AHB_TX_BASE + 0x10000:
            self._tx_write(addr - AHB_TX_BASE, val)
            return
        if 0x4405_0000 <= addr < 0x4405_1000:
            # PHC regs — silently swallow writes for stress tests.
            return
        if addr == 0x4404_2000:               # PMOD-B
            return
        # ignore otherwise

    # ── packet machinery ──
    def _tx_write(self, off: int, val: int) -> None:
        if off == 0x0000:
            self.tx_length = val
            self.tx_buf = []
            return
        idx = off // 4
        if self.tx_length is None:
            return
        # Beat indexes start at 1 for payload words.
        self.tx_buf.append(val)
        if len(self.tx_buf) == self.tx_length:
            # Commit: ship to peer, decrement own credits, peer rises
            # RELEASED_ACC by total_words when drained.
            payload = self.tx_buf[:]
            total = len(payload) + 2  # header + dest_addr + payload
            self.current_credits -= total
            self.peer().rx_q.append(payload)
            # peer drain happens on subsequent _fifo_read sequence.
            self.tx_buf = []
            self.tx_length = None

    def _fifo_read(self, off: int) -> int:
        if off == 0x0000:
            # Trigger length capture: pull the next packet off the queue
            # into the "active drain" slot.
            if self.rx_drain_active is None and self.rx_q:
                self.rx_drain_active = self.rx_q.pop(0)
                self.pkt_word_len = len(self.rx_drain_active)
                self.rx_drain_idx = 0
            return 0
        idx = off // 4 - 1  # payload starts at offset 0x4 -> idx 0
        if self.rx_drain_active is None:
            return 0
        if idx >= len(self.rx_drain_active):
            return 0
        v = self.rx_drain_active[idx]
        if idx == len(self.rx_drain_active) - 1:
            # Last word — release credits back to the source.
            released = len(self.rx_drain_active) + 2
            self.peer().released_acc += released
            self.peer().current_credits = min(
                self.peer().current_credits + released, MAX_CREDITS)
            self.rx_drain_active = None
            self.pkt_word_len = 0
        return v


def _pair() -> tuple[PairBoard, PairBoard]:
    a_peer: list[PairBoard | None] = [None]
    b_peer: list[PairBoard | None] = [None]
    a = PairBoard(b_peer, "master")
    b = PairBoard(a_peer, "slave")
    a_peer[0] = a
    b_peer[0] = b
    return a, b


def _mmio_pair() -> tuple[FakeMmio, FakeMmio, PairBoard, PairBoard]:
    a, b = _pair()

    def make(board: PairBoard) -> FakeMmio:
        def rd(addr: int, store: dict) -> int:
            return board.read(addr)

        def wr(addr: int, val: int, store: dict) -> None:
            board.write(addr, val)
        return FakeMmio(read_hook=rd, write_hook=wr)

    return make(a), make(b), a, b


# ── Packet stress tests ──────────────────────────────────────────────────

async def test_packet_stress_happy_path():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = PacketStressConfig(packet_size_words=4, packet_count=5,
                              direction="m2s")
    events = []
    async for ev in packet_stress(ctx, cfg):
        events.append(ev)

    kinds = [e.kind for e in events]
    assert "packet_stress_done" in kinds
    done = [e for e in events if e.kind == "packet_stress_done"][0]
    assert done.detail["errors"] == 0
    assert done.detail["tx_packets"] == 5
    assert done.detail["rx_packets"] == 5


async def test_packet_stress_cancel_mid_run():
    m_mmio, s_mmio, *_ = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = PacketStressConfig(packet_size_words=2, packet_count=1000,
                              direction="m2s",
                              inter_packet_us=1000.0)

    async def _runner():
        async for ev in packet_stress(ctx, cfg):
            pass

    task = asyncio.create_task(_runner())
    await asyncio.sleep(0.05)
    cancel.set()
    await asyncio.wait_for(task, timeout=2.0)


async def test_packet_stress_both_direction_alternates():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = PacketStressConfig(packet_size_words=2, packet_count=4,
                              direction="both")
    events = []
    async for ev in packet_stress(ctx, cfg):
        events.append(ev)
    done = [e for e in events if e.kind == "packet_stress_done"][0]
    assert done.detail["errors"] == 0
    assert done.detail["tx_packets"] == 4


# ── Doorbell stress ──────────────────────────────────────────────────────

async def test_doorbell_volume_correct_acc():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = DoorbellStressConfig(doorbell_count=10, rate_hz=10_000.0,
                                direction="m2s")
    events = []
    async for ev in doorbell_stress(ctx, cfg):
        events.append(ev)
    done = [e for e in events if e.kind == "doorbell_done"][0]
    results = done.detail["results"]
    assert results[0]["sent"] == 10
    assert results[0]["expected_acc"] == 10 * MAX_CREDITS
    assert results[0]["ok"] is True


async def test_doorbell_volume_alternating():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = DoorbellStressConfig(doorbell_count=4, rate_hz=10_000.0,
                                direction="alternating")
    events = []
    async for ev in doorbell_stress(ctx, cfg):
        events.append(ev)
    done = [e for e in events if e.kind == "doorbell_done"][0]
    # 4 rings, 2 each direction.
    assert sum(r["sent"] for r in done.detail["results"]) == 4
    assert all(r["ok"] for r in done.detail["results"])


# ── PHY health monitor ──────────────────────────────────────────────────

async def test_phy_health_monitor_emits_clean_samples():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = PhyHealthConfig(poll_period_s=0.01, duration_s=0.05)
    events = []
    async for ev in phy_health_monitor(ctx, cfg):
        events.append(ev)
    sample_count = sum(1 for e in events if e.kind == "phy_health_sample")
    assert sample_count >= 1
    sample = next(e for e in events if e.kind == "phy_health_sample")
    assert sample.detail["master_anomalies"] == []
    assert sample.detail["slave_anomalies"] == []


async def test_phy_health_monitor_detects_anomaly():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    # Force lane 5 wiring SWAPPED on master
    m_board.phy_regs[0x18] = 0x5555 ^ (0b11 << (5 * 2)) | (0b10 << (5 * 2))
    cancel = asyncio.Event()
    alarm = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio,
                      cancel=cancel, health_alarm=alarm)

    cfg = PhyHealthConfig(poll_period_s=0.01, duration_s=0.05)
    events = []
    async for ev in phy_health_monitor(ctx, cfg):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "phy_health_anomaly" in kinds
    assert alarm.is_set()


# ── FCSM monitor ─────────────────────────────────────────────────────────

async def test_fcsm_monitor_emits_samples():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = FcsmMonitorConfig(poll_period_s=0.01, duration_s=0.05)
    events = []
    async for ev in fcsm_monitor(ctx, cfg):
        events.append(ev)
    samples = [e for e in events if e.kind == "fcsm_sample"]
    assert samples, "expected at least one fcsm_sample"


async def test_fcsm_monitor_detects_transition():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    alarm = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio,
                      cancel=cancel, health_alarm=alarm)

    cfg = FcsmMonitorConfig(poll_period_s=0.01, duration_s=0.1)

    # After ~30ms, flip the master's FCSM into state 1 (wedge).
    async def _flip():
        await asyncio.sleep(0.03)
        m_board.swi_lane_status = 0x0003_00FF  # fcsm_state=1

    asyncio.create_task(_flip())
    events = []
    async for ev in fcsm_monitor(ctx, cfg):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "fcsm_transition" in kinds
    assert alarm.is_set()


# ── PTP convergence — minimal smoke (PHC counters are stubbed). ──────────

async def test_ptp_convergence_emits_phases_and_terminates():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    # Use a short duration so the test doesn't drag.
    cfg = PtpConvergenceConfig(
        duration_s=0.1, sample_period_s=0.02,
        offset_ok_ns=10**9,
        lock_hold_samples=1,
    )

    events = []
    async for ev in ptp_convergence(ctx, cfg):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "ptp_phase" in kinds
    assert "ptp_baseline" in kinds
    assert "ptp_done" in kinds


async def test_ptp_cancel_short_circuits():
    m_mmio, s_mmio, m_board, s_board = _mmio_pair()
    cancel = asyncio.Event()
    ctx = ModeContext(master=m_mmio, slave=s_mmio, cancel=cancel)

    cfg = PtpConvergenceConfig(
        duration_s=10.0, sample_period_s=0.05,
        offset_ok_ns=1, lock_hold_samples=1000)

    async def _runner():
        events = []
        async for ev in ptp_convergence(ctx, cfg):
            events.append(ev)
        return events

    task = asyncio.create_task(_runner())
    await asyncio.sleep(0.1)
    cancel.set()
    events = await asyncio.wait_for(task, timeout=2.0)
    done = [e for e in events if e.kind == "ptp_done"]
    assert done
    assert done[-1].detail["verdict"] == "ABORTED"

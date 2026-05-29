"""Six test-mode async generators consumed by the Run orchestrator.

Each generator yields ``ModeEvent`` records the runner forwards to the
SSE stream. Cancellation is via the ``cancel_event: asyncio.Event``
each generator polls inside its main loop.

Generators only depend on the ``MmioInterface`` abstraction from
``mmio_remote`` — pytest substitutes ``FakeMmio`` for full coverage
without touching real hardware.
"""
from __future__ import annotations

import asyncio
import random
import time
from dataclasses import dataclass, field
from typing import AsyncIterator, Optional

from ..stress_lib import (
    APB_BASE,
    APB_OFF_DOORBELL,
    APB_OFF_DOORBELL_RESP_ACC,
    APB_OFF_HW_SYNC_CTRL,
    APB_OFF_HW_SYNC_INTERVAL,
    APB_OFF_HW_SYNC_STATUS,
    APB_OFF_PTP_CTRL,
    APB_OFF_RELEASED_ACC,
    APB_OFF_SERVO_CTRL,
    APB_OFF_SERVO_KI,
    APB_OFF_SERVO_KP,
    APB_OFF_SERVO_STATUS,
    APB_OFF_SERVO_STEP_THRESH,
    AHB_FIFO_BASE,
    AHB_TX_BASE,
    ECC_COUNTERS_OFF,
    GPIO_PHY_REGS_BASE,
    LaneStatus,
    MAX_CREDITS,
    PhyHealth,
    StressStats,
    SWI_LANE_STATUS_OFF,
    offset_ns,
    parse_ecc_counters,
    parse_lane_status,
    phc_hw_cap_read,
    phc_init_50mhz,
    phc_quiesce_servo,
    phy_health_anomalies,
    pmod_trigger_pulse,
    read_phy_health,
)
from .mmio_remote import MmioInterface, MmioError


# ── ModeEvent ────────────────────────────────────────────────────────────

@dataclass
class ModeEvent:
    kind: str
    detail: dict = field(default_factory=dict)
    ts: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {"kind": self.kind, "ts": self.ts, **self.detail}


@dataclass
class ModeContext:
    """Per-run handles for the test-mode generators."""
    master: MmioInterface
    slave: MmioInterface
    cancel: asyncio.Event
    health_alarm: Optional[asyncio.Event] = None

    @property
    def aborted(self) -> bool:
        return self.cancel.is_set() or (
            self.health_alarm is not None
            and self.health_alarm.is_set())


# ── 1. AHB packet stress ─────────────────────────────────────────────────

@dataclass
class PacketStressConfig:
    packet_size_words: int = 16    # payload words (FifoPacket adds 2-word header)
    packet_count: int = 100
    direction: str = "both"        # "m2s" / "s2m" / "both" / "alternating"
    inter_packet_us: float = 0.0


async def packet_stress(ctx: ModeContext,
                        cfg: PacketStressConfig
                        ) -> AsyncIterator[ModeEvent]:
    """End-to-end AHB packet stress.

    Per packet:
      1. Build payload (deterministic sequence so RX side can verify).
      2. Write packet (header + payload) to the *source* board's TX
         aperture starting at AHB_TX_BASE.
      3. Wait for the local STATUS.returner_busy to drop.
      4. Read packet back from peer's AHB_FIFO at AHB_FIFO_BASE.
      5. Compare bit-exact.
      6. Sample CURRENT_CREDITS + RELEASED_ACC to track flow control.
      7. Sentinel: every 10 packets, sample SWI_LANE_STATUS — abort
         if FCSM leaves LINK_IDLE.

    Yields ``packet_stress_progress`` events every ~100 packets (or
    every packet if count < 100), plus final ``packet_stress_done``.
    """
    stats = StressStats()
    stats.start_ts = stats.last_ts = time.time()

    def _build_payload(seed: int) -> list[int]:
        # Simple deterministic sequence; verification re-derives it.
        return [(seed + i) & 0xFFFFFFFF for i in range(cfg.packet_size_words)]

    src_dst_pairs: list[tuple[str, MmioInterface, MmioInterface]] = []
    if cfg.direction in ("m2s", "both"):
        src_dst_pairs.append(("m2s", ctx.master, ctx.slave))
    if cfg.direction in ("s2m", "both"):
        src_dst_pairs.append(("s2m", ctx.slave, ctx.master))
    if cfg.direction == "alternating" and not src_dst_pairs:
        src_dst_pairs = [("m2s", ctx.master, ctx.slave),
                          ("s2m", ctx.slave, ctx.master)]
    if not src_dst_pairs:
        yield ModeEvent("packet_stress_done", {
            "tx_packets": 0, "rx_packets": 0, "errors": 0,
            "reason": f"unknown direction {cfg.direction!r}"})
        return

    progress_every = max(1, cfg.packet_count // 100)
    sentinel_every = max(10, progress_every)

    for i in range(cfg.packet_count):
        if ctx.aborted:
            yield ModeEvent("packet_stress_aborted", {
                "completed": i, **stats.to_dict()})
            return
        direction, src, dst = src_dst_pairs[i % len(src_dst_pairs)]
        payload = _build_payload(seed=i * 0x100 + 0xDEAD)

        try:
            # Write header (length word) then payload to TX aperture.
            await src.write(AHB_TX_BASE + 0x0000, len(payload))
            for j, w in enumerate(payload):
                await src.write(AHB_TX_BASE + (j + 1) * 4, w)
            stats.tx_packets += 1
            stats.bytes_tx += (1 + len(payload)) * 4

            # Wait for peer's RX FIFO header (trigger the length capture
            # by reading address 0).
            await dst.read(AHB_FIFO_BASE + 0x0000)
            # Read back length and verify.
            pkt_len = await dst.read(APB_BASE + 0x0008)  # REG_PKT_WORD_LEN
            if pkt_len != len(payload):
                stats.errors += 1
                yield ModeEvent("packet_error", {
                    "iteration": i, "direction": direction,
                    "reason": f"length mismatch: expected {len(payload)}, got {pkt_len}"})
                continue
            # Drain payload.
            rx_data = []
            for j in range(pkt_len):
                rx_data.append(await dst.read(AHB_FIFO_BASE + (j + 1) * 4))
            stats.rx_packets += 1
            stats.bytes_rx += (1 + pkt_len) * 4
            if rx_data != payload:
                stats.errors += 1
                yield ModeEvent("packet_error", {
                    "iteration": i, "direction": direction,
                    "reason": "payload mismatch"})
        except MmioError as exc:
            stats.errors += 1
            yield ModeEvent("packet_error", {
                "iteration": i, "direction": direction,
                "reason": f"mmio: {exc}"})

        stats.last_ts = time.time()

        if (i + 1) % sentinel_every == 0:
            # FCSM sentinel — read SWI_LANE_STATUS on the source.
            try:
                raw = await src.read(APB_BASE + SWI_LANE_STATUS_OFF)
                ls = parse_lane_status(raw)
                if not ls.link_idle or ls.lock_count < 8:
                    yield ModeEvent("packet_fcsm_alarm", {
                        "iteration": i,
                        "lane_status": ls.to_dict()})
            except MmioError:
                pass

        if (i + 1) % progress_every == 0:
            yield ModeEvent("packet_stress_progress",
                            {"completed": i + 1,
                             "total": cfg.packet_count,
                             "direction": direction,
                             **stats.to_dict()})

        if cfg.inter_packet_us > 0:
            await asyncio.sleep(cfg.inter_packet_us / 1e6)

    yield ModeEvent("packet_stress_done", {**stats.to_dict(),
                                            "total": cfg.packet_count})


# ── 2. Doorbell volume stress ─────────────────────────────────────────────

@dataclass
class DoorbellStressConfig:
    doorbell_count: int = 100
    rate_hz: float = 100.0
    direction: str = "m2s"  # "m2s", "s2m", "alternating", "both"


async def doorbell_stress(ctx: ModeContext,
                          cfg: DoorbellStressConfig
                          ) -> AsyncIterator[ModeEvent]:
    """Flood APB REG_DOORBELL on the source(s). Each ring causes the
    peer's DOORBELL_RESP_ACC to add MAX_CREDITS — verifying the
    response side of the FC adapter.

    REG_DOORBELL writes are pure APB so they NEVER wedge the PS, even
    on a broken link. The verification (DOORBELL_RESP_ACC delta) is
    R/W-clear on the peer.
    """
    if cfg.direction == "m2s":
        src_dsts = [(ctx.master, ctx.slave)]
    elif cfg.direction == "s2m":
        src_dsts = [(ctx.slave, ctx.master)]
    elif cfg.direction in ("alternating", "both"):
        src_dsts = [(ctx.master, ctx.slave), (ctx.slave, ctx.master)]
    else:
        yield ModeEvent("doorbell_done", {"reason": "unknown direction",
                                           "direction": cfg.direction})
        return

    # Clear the destination acc(s) first so the delta math is clean.
    for _src, dst in src_dsts:
        try:
            await dst.read(APB_BASE + APB_OFF_DOORBELL_RESP_ACC)
        except MmioError:
            pass

    period = 1.0 / max(cfg.rate_hz, 1e-3)
    sent_per_dst: dict[int, int] = {id(d): 0 for _, d in src_dsts}
    deadline_base = time.time()
    for i in range(cfg.doorbell_count):
        if ctx.aborted:
            break
        src, dst = src_dsts[i % len(src_dsts)]
        try:
            await src.write(APB_BASE + APB_OFF_DOORBELL, 1)
            sent_per_dst[id(dst)] += 1
        except MmioError as exc:
            yield ModeEvent("doorbell_error",
                            {"iteration": i, "reason": str(exc)})

        # Pace
        target_ts = deadline_base + (i + 1) * period
        slack = target_ts - time.time()
        if slack > 0:
            await asyncio.sleep(slack)

        # Periodic progress
        if (i + 1) % max(10, cfg.doorbell_count // 100) == 0:
            yield ModeEvent("doorbell_progress",
                            {"sent": i + 1,
                             "total": cfg.doorbell_count})

    # Verify accs
    results = []
    for src, dst in src_dsts:
        sent = sent_per_dst[id(dst)]
        try:
            acc = await dst.read(APB_BASE + APB_OFF_DOORBELL_RESP_ACC)
        except MmioError as exc:
            results.append({"direction": "->",
                             "sent": sent, "reason": str(exc)})
            continue
        expected = sent * MAX_CREDITS
        results.append({
            "sent": sent,
            "expected_acc": expected,
            "observed_acc": acc,
            "delta": acc - expected,
            "ok": acc == expected,
        })

    yield ModeEvent("doorbell_done", {"results": results,
                                      "total_sent": sum(sent_per_dst.values())})


# ── 3. PTP HW sync convergence ───────────────────────────────────────────

@dataclass
class PtpConvergenceConfig:
    duration_s: float = 60.0
    sample_period_s: float = 0.25
    offset_ok_ns: int = 500
    lock_hold_samples: int = 10
    master_initial_s: int = 100
    slave_initial_s: int = 200
    hw_sync_interval: int = 7_812_500  # 128 Hz @ 1 ns tick (50 MHz scaled)


async def ptp_convergence(ctx: ModeContext,
                          cfg: PtpConvergenceConfig
                          ) -> AsyncIterator[ModeEvent]:
    """Port of ``bringup_ptp_sync.sh``.

    Sequence:
      1. Quiesce servo + HW_SYNC on both.
      2. Programme distinct initial times (master=100, slave=200 by default).
      3. Pulse PMOD-B trigger on master; read both HW_CAP; record baseline.
      4. Enable PTP RX, set HW_SYNC_INTERVAL=128 Hz, configure servo.
      5. Start HW_SYNC initiator on master (force_en | enable = 0x5).
      6. Sample loop: every period, pulse trigger + read offsets +
         check SERVO_STATUS.locked. PASS when locked==1 AND |offset| <
         offset_ok_ns for ``lock_hold_samples`` consecutive ticks.
    """
    # Quiesce.
    yield ModeEvent("ptp_phase", {"phase": "quiesce"})
    try:
        phc_quiesce_servo_async = lambda mmio: phc_quiesce_pair(mmio)
        await phc_quiesce_pair(ctx.master)
        await phc_quiesce_pair(ctx.slave)
    except MmioError as exc:
        yield ModeEvent("ptp_failed", {"reason": f"quiesce: {exc}"})
        return

    # Programme PHCs.
    yield ModeEvent("ptp_phase", {"phase": "phc_init",
                                   "master_s": cfg.master_initial_s,
                                   "slave_s": cfg.slave_initial_s})
    try:
        await phc_init_async(ctx.master, cfg.master_initial_s)
        await phc_init_async(ctx.slave, cfg.slave_initial_s)
    except MmioError as exc:
        yield ModeEvent("ptp_failed", {"reason": f"phc_init: {exc}"})
        return

    # Baseline.
    try:
        await pmod_pulse_async(ctx.master)
        await asyncio.sleep(0.1)
        m_cap = await phc_hw_cap_async(ctx.master)
        s_cap = await phc_hw_cap_async(ctx.slave)
        yield ModeEvent("ptp_baseline", {
            "master_cap": list(m_cap),
            "slave_cap": list(s_cap),
            "offset_ns": offset_ns(m_cap, s_cap),
        })
    except MmioError as exc:
        yield ModeEvent("ptp_failed", {"reason": f"baseline: {exc}"})
        return

    # Enable PTP + configure servo.
    yield ModeEvent("ptp_phase", {"phase": "configure_servo"})
    try:
        await ctx.master.write(APB_BASE + APB_OFF_PTP_CTRL, 1)
        await ctx.slave.write(APB_BASE + APB_OFF_PTP_CTRL, 1)
        await ctx.master.write(APB_BASE + APB_OFF_HW_SYNC_INTERVAL,
                                cfg.hw_sync_interval)
        await ctx.slave.write(APB_BASE + APB_OFF_HW_SYNC_INTERVAL,
                               cfg.hw_sync_interval)
        await ctx.master.write(APB_BASE + APB_OFF_SERVO_CTRL, 1)        # GM mode
        await ctx.slave.write(APB_BASE + APB_OFF_SERVO_CTRL, 3)         # Sub mode + enable
        await ctx.slave.write(APB_BASE + APB_OFF_SERVO_KP, 0x0800_0000)
        await ctx.slave.write(APB_BASE + APB_OFF_SERVO_KI, 0x0080_0000)
        await ctx.slave.write(APB_BASE + APB_OFF_SERVO_STEP_THRESH,
                               1_000_000)
        # Start master HW_SYNC initiator: force_en | enable = 0x5.
        await ctx.master.write(APB_BASE + APB_OFF_HW_SYNC_CTRL, 0x5)
    except MmioError as exc:
        yield ModeEvent("ptp_failed",
                         {"reason": f"configure_servo: {exc}"})
        return

    # Convergence loop.
    yield ModeEvent("ptp_phase", {"phase": "converge",
                                   "duration_s": cfg.duration_s})
    start = time.time()
    locked_streak = 0
    verdict = "FAIL"
    while True:
        if ctx.aborted:
            verdict = "ABORTED"
            break
        elapsed = time.time() - start
        if elapsed >= cfg.duration_s:
            break
        try:
            await pmod_pulse_async(ctx.master)
            await asyncio.sleep(0.02)
            m_cap = await phc_hw_cap_async(ctx.master)
            s_cap = await phc_hw_cap_async(ctx.slave)
            off = offset_ns(m_cap, s_cap)
            servo = await ctx.slave.read(
                APB_BASE + APB_OFF_SERVO_STATUS)
        except MmioError as exc:
            yield ModeEvent("ptp_warn", {"reason": str(exc),
                                          "elapsed_s": elapsed})
            await asyncio.sleep(cfg.sample_period_s)
            continue

        locked_bit = bool(servo & 1)
        abs_off = abs(off)
        in_lock = locked_bit and abs_off < cfg.offset_ok_ns
        if in_lock:
            locked_streak += 1
            if locked_streak >= cfg.lock_hold_samples:
                verdict = "PASS"
                break
        else:
            locked_streak = 0
        yield ModeEvent("ptp_sample", {
            "elapsed_s": round(elapsed, 3),
            "offset_ns": off,
            "abs_offset_ns": abs_off,
            "locked": locked_bit,
            "locked_streak": locked_streak,
            "servo_status": servo,
        })
        await asyncio.sleep(cfg.sample_period_s)

    yield ModeEvent("ptp_done", {"verdict": verdict,
                                  "locked_streak": locked_streak,
                                  "required": cfg.lock_hold_samples,
                                  "elapsed_s": time.time() - start})


async def phc_quiesce_pair(mmio: MmioInterface) -> None:
    await mmio.write(APB_BASE + APB_OFF_HW_SYNC_CTRL, 0)
    await mmio.write(APB_BASE + APB_OFF_SERVO_CTRL, 0)


async def phc_init_async(mmio: MmioInterface, sec: int) -> None:
    # Implement phc_init_50mhz in async/await terms.
    from ..stress_lib import (
        PHC_BASE, PHC_OFF_CTRL, PHC_OFF_NS_INCR, PHC_OFF_NS_INCR_FRAC,
        PHC_OFF_SET_SECONDS_LO, PHC_OFF_SET_SECONDS_HI,
        PHC_OFF_SET_NANOSECONDS, PHC_CTRL_SET_TIME, PHC_CTRL_EN,
        NS_INCR_FOR_50MHZ,
    )
    await mmio.write(PHC_BASE + PHC_OFF_CTRL, 0)
    await mmio.write(PHC_BASE + PHC_OFF_NS_INCR, NS_INCR_FOR_50MHZ)
    await mmio.write(PHC_BASE + PHC_OFF_NS_INCR_FRAC, 0)
    await mmio.write(PHC_BASE + PHC_OFF_SET_SECONDS_LO, sec & 0xFFFFFFFF)
    await mmio.write(PHC_BASE + PHC_OFF_SET_SECONDS_HI,
                      (sec >> 32) & 0xFFFFFFFF)
    await mmio.write(PHC_BASE + PHC_OFF_SET_NANOSECONDS, 0)
    await mmio.write(PHC_BASE + PHC_OFF_CTRL, PHC_CTRL_SET_TIME)
    await mmio.write(PHC_BASE + PHC_OFF_CTRL, PHC_CTRL_EN)


async def phc_hw_cap_async(mmio: MmioInterface) -> tuple[int, int, int]:
    from ..stress_lib import (
        PHC_BASE, PHC_OFF_HW_CAP_SECONDS_LO, PHC_OFF_HW_CAP_SECONDS_HI,
        PHC_OFF_HW_CAP_NANOSECONDS, PHC_OFF_HW_CAP_NS_FRAC,
    )
    lo = await mmio.read(PHC_BASE + PHC_OFF_HW_CAP_SECONDS_LO)
    hi = await mmio.read(PHC_BASE + PHC_OFF_HW_CAP_SECONDS_HI)
    ns = await mmio.read(PHC_BASE + PHC_OFF_HW_CAP_NANOSECONDS)
    fr = await mmio.read(PHC_BASE + PHC_OFF_HW_CAP_NS_FRAC)
    return ((hi << 32) | lo), ns, fr


async def pmod_pulse_async(mmio: MmioInterface) -> None:
    # PMOD-B trigger lives at absolute 0x4404_2000.
    await mmio.write(0x44042000, 1)
    await mmio.write(0x44042000, 0)


# ── 4. PHY health monitor (passive) ──────────────────────────────────────

@dataclass
class PhyHealthConfig:
    poll_period_s: float = 1.0
    duration_s: float = 0.0   # 0 = run forever until cancelled
    base: int = GPIO_PHY_REGS_BASE


async def phy_health_monitor(ctx: ModeContext,
                             cfg: PhyHealthConfig
                             ) -> AsyncIterator[ModeEvent]:
    """Passive 1 Hz poll of the tidelink_gpio_phy_apb_regs slave.

    Reports per-lane noise + wiring + canary on every tick, and emits a
    ``phy_health_anomaly`` event whenever one of the spec §5/§6 alarms
    fires.
    """
    # Wrap async reads as a sync read_fn for stress_lib.read_phy_health.
    # Because read_phy_health is sync, we collect the 6 registers up
    # front, then call the sync parser.
    async def _snapshot(mmio: MmioInterface) -> PhyHealth:
        addrs = [
            cfg.base + 0x00, cfg.base + 0x04, cfg.base + 0x08,
            cfg.base + 0x0C, cfg.base + 0x10, cfg.base + 0x14,
            cfg.base + 0x18, cfg.base + 0x1C,
        ]
        try:
            vals = await mmio.read_many(addrs)
        except (MmioError, AttributeError):
            vals = []
            for a in addrs:
                vals.append(await mmio.read(a))
        reg = dict(zip(addrs, vals))
        return read_phy_health(lambda a: reg[a], base=cfg.base)

    start = time.time()
    tick = 0
    while True:
        if ctx.cancel.is_set():
            break
        if cfg.duration_s > 0 and (time.time() - start) >= cfg.duration_s:
            break
        try:
            h_m = await _snapshot(ctx.master)
            h_s = await _snapshot(ctx.slave)
        except MmioError as exc:
            yield ModeEvent("phy_health_warn", {"reason": str(exc)})
            await asyncio.sleep(cfg.poll_period_s)
            continue
        a_m = phy_health_anomalies(h_m)
        a_s = phy_health_anomalies(h_s)
        yield ModeEvent("phy_health_sample", {
            "tick": tick,
            "master": h_m.to_dict(),
            "slave": h_s.to_dict(),
            "master_anomalies": a_m,
            "slave_anomalies": a_s,
        })
        if a_m or a_s:
            if ctx.health_alarm is not None:
                ctx.health_alarm.set()
            yield ModeEvent("phy_health_anomaly", {
                "master": a_m, "slave": a_s, "tick": tick})
        tick += 1
        await asyncio.sleep(cfg.poll_period_s)


# ── 5. FCSM live state monitor ───────────────────────────────────────────

@dataclass
class FcsmMonitorConfig:
    poll_period_s: float = 0.1
    duration_s: float = 0.0

async def fcsm_monitor(ctx: ModeContext,
                       cfg: FcsmMonitorConfig
                       ) -> AsyncIterator[ModeEvent]:
    """10 Hz poll of SWI_LANE_STATUS on both sides.

    Surfaces every transition away from LINK_IDLE (fcsm_state != 0)
    and acts as a kill-switch for ahb/doorbell/ptp tests via the
    ``ctx.health_alarm`` event."""
    start = time.time()
    tick = 0
    last_state = (None, None)
    while True:
        if ctx.cancel.is_set():
            break
        if cfg.duration_s > 0 and (time.time() - start) >= cfg.duration_s:
            break
        try:
            m_raw = await ctx.master.read(
                APB_BASE + SWI_LANE_STATUS_OFF)
            s_raw = await ctx.slave.read(APB_BASE + SWI_LANE_STATUS_OFF)
            m_ecc = await ctx.master.read(APB_BASE + ECC_COUNTERS_OFF)
            s_ecc = await ctx.slave.read(APB_BASE + ECC_COUNTERS_OFF)
        except MmioError as exc:
            yield ModeEvent("fcsm_warn", {"reason": str(exc)})
            await asyncio.sleep(cfg.poll_period_s)
            continue
        m = parse_lane_status(m_raw)
        s = parse_lane_status(s_raw)
        m_ecc_d = parse_ecc_counters(m_ecc)
        s_ecc_d = parse_ecc_counters(s_ecc)
        cur = (m.fcsm_state, s.fcsm_state)
        ev_kind = "fcsm_sample"
        if last_state != (None, None) and cur != last_state:
            ev_kind = "fcsm_transition"
            if not m.link_idle or not s.link_idle:
                if ctx.health_alarm is not None:
                    ctx.health_alarm.set()
        last_state = cur
        yield ModeEvent(ev_kind, {
            "tick": tick,
            "master": m.to_dict(),
            "slave": s.to_dict(),
            "master_ecc": m_ecc_d,
            "slave_ecc": s_ecc_d,
        })
        tick += 1
        await asyncio.sleep(cfg.poll_period_s)


# ── 6. AUTO mode — randomised mix ────────────────────────────────────────

@dataclass
class AutoConfig:
    duration_s: float = 300.0
    seed: int = 0


async def auto_mix(ctx: ModeContext,
                   cfg: AutoConfig) -> AsyncIterator[ModeEvent]:
    """Random sequence of tests 1, 2, 3, 5 (PHY health, test 4, runs
    continuously as background alarm — caller wires it).

    Reports a running pass/fail table at the end as
    ``auto_summary``."""
    rng = random.Random(cfg.seed)
    summary: dict[str, dict] = {
        "packet_stress": {"runs": 0, "pass": 0, "fail": 0, "errors": 0},
        "doorbell": {"runs": 0, "pass": 0, "fail": 0},
        "ptp": {"runs": 0, "pass": 0, "fail": 0, "aborted": 0},
        "fcsm_alarm_aborts": 0,
    }
    start = time.time()

    def _pick_packet_cfg() -> PacketStressConfig:
        return PacketStressConfig(
            packet_size_words=rng.choice([1, 4, 16, 64, 256]),
            packet_count=rng.choice([100, 1000, 5000]),
            direction=rng.choice(["m2s", "s2m", "both"]),
        )

    def _pick_doorbell_cfg() -> DoorbellStressConfig:
        return DoorbellStressConfig(
            doorbell_count=rng.choice([100, 1000, 5000]),
            rate_hz=rng.choice([50.0, 200.0, 1000.0]),
            direction=rng.choice(["m2s", "s2m", "alternating"]),
        )

    def _pick_ptp_cfg() -> PtpConvergenceConfig:
        return PtpConvergenceConfig(
            duration_s=rng.choice([5.0, 10.0, 30.0]),
            sample_period_s=0.25,
            offset_ok_ns=500,
            lock_hold_samples=10,
        )

    choices = ("packet_stress", "doorbell", "ptp")

    while not ctx.aborted and (time.time() - start) < cfg.duration_s:
        pick = rng.choice(choices)
        yield ModeEvent("auto_pick", {"mode": pick,
                                       "elapsed_s": time.time() - start})
        verdict = "pass"
        try:
            if pick == "packet_stress":
                cfg_p = _pick_packet_cfg()
                summary["packet_stress"]["runs"] += 1
                async for ev in packet_stress(ctx, cfg_p):
                    yield ev
                    if ev.kind == "packet_stress_done":
                        if ev.detail.get("errors", 0) > 0:
                            verdict = "fail"
                            summary["packet_stress"]["fail"] += 1
                            summary["packet_stress"]["errors"] += int(
                                ev.detail.get("errors", 0))
                        else:
                            summary["packet_stress"]["pass"] += 1
            elif pick == "doorbell":
                cfg_d = _pick_doorbell_cfg()
                summary["doorbell"]["runs"] += 1
                ok = True
                async for ev in doorbell_stress(ctx, cfg_d):
                    yield ev
                    if ev.kind == "doorbell_done":
                        for r in ev.detail.get("results", []):
                            if not r.get("ok", False):
                                ok = False
                if ok:
                    summary["doorbell"]["pass"] += 1
                else:
                    summary["doorbell"]["fail"] += 1
                    verdict = "fail"
            elif pick == "ptp":
                cfg_pt = _pick_ptp_cfg()
                summary["ptp"]["runs"] += 1
                v = None
                async for ev in ptp_convergence(ctx, cfg_pt):
                    yield ev
                    if ev.kind == "ptp_done":
                        v = ev.detail.get("verdict")
                if v == "PASS":
                    summary["ptp"]["pass"] += 1
                elif v == "ABORTED":
                    summary["ptp"]["aborted"] += 1
                    verdict = "aborted"
                else:
                    summary["ptp"]["fail"] += 1
                    verdict = "fail"
        except Exception as exc:  # noqa: BLE001
            verdict = "exception"
            yield ModeEvent("auto_exception",
                             {"mode": pick, "reason": repr(exc)})

        if ctx.health_alarm is not None and ctx.health_alarm.is_set():
            summary["fcsm_alarm_aborts"] += 1
            yield ModeEvent("auto_health_alarm",
                             {"after_mode": pick, "verdict": verdict})
            break

        yield ModeEvent("auto_step_done",
                         {"mode": pick, "verdict": verdict,
                          "elapsed_s": time.time() - start})

    yield ModeEvent("auto_summary",
                     {"elapsed_s": time.time() - start,
                      "summary": summary})

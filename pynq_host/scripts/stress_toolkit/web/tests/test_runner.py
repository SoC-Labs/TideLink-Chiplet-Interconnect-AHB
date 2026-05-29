"""Tests for the stress_toolkit Run state machine.

The Run is constructed with stubbed mmio factories — no deploy is
needed for the modes themselves; tests pass skip_deploy + skip_converge
so the deploy phase is a no-op.
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
    APB_BASE, MAX_CREDITS,
)
from pynq_host.scripts.stress_toolkit.web.mmio_remote import FakeMmio
from pynq_host.scripts.stress_toolkit.web.runner import (
    Run, RunState, StressRunOptions,
)
from pynq_host.scripts.stress_toolkit.web.stress_modes import (
    DoorbellStressConfig, FcsmMonitorConfig, PacketStressConfig,
    PhyHealthConfig,
)


def _clean_mmio_pair():
    """Construct a pair of FakeMmios with healthy defaults — both report
    SWI_LANE_STATUS = 0xFF locked, FCSM in LINK_IDLE, all PHY regs clean.
    """
    from pynq_host.scripts.stress_toolkit.web.tests.test_stress_modes import (
        _mmio_pair,
    )
    return _mmio_pair()


async def _drain(run, *, max_events=2048):
    out = []
    while len(out) < max_events:
        try:
            ev = await asyncio.wait_for(run.events.get(), timeout=10.0)
        except asyncio.TimeoutError:
            break
        out.append(ev)
        if ev.kind == "closed":
            break
    return out


async def test_run_doorbell_to_done(lease_client):
    m_mmio, s_mmio, m_board, s_board = _clean_mmio_pair()

    opts = StressRunOptions(
        mode="doorbell",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
        doorbell=DoorbellStressConfig(
            doorbell_count=4, rate_hz=10_000.0, direction="m2s"),
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.DONE
    done = [e for e in events if e.kind == "doorbell_done"]
    assert done
    assert done[0].detail["results"][0]["ok"]


async def test_run_packet_to_done(lease_client):
    m_mmio, s_mmio, *_ = _clean_mmio_pair()
    opts = StressRunOptions(
        mode="packet",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
        packet=PacketStressConfig(packet_size_words=4,
                                   packet_count=3,
                                   direction="m2s"),
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.DONE
    done = [e for e in events if e.kind == "packet_stress_done"]
    assert done[0].detail["errors"] == 0


async def test_run_lease_queued_fails(lease_client, fake_lease_state):
    # Pretend someone else holds the lease.
    fake_lease_state["current"] = {
        "holder": "other", "user": "other", "token": "tok-other"}
    m_mmio, s_mmio, *_ = _clean_mmio_pair()
    opts = StressRunOptions(
        mode="doorbell",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
        doorbell=DoorbellStressConfig(doorbell_count=1, rate_hz=100.0),
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.FAILED
    assert "queued" in (run.error or "")


async def test_run_unknown_mode_fails(lease_client):
    m_mmio, s_mmio, *_ = _clean_mmio_pair()
    opts = StressRunOptions(
        mode="not-a-mode",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.FAILED


async def test_run_phy_monitor_short_duration(lease_client):
    m_mmio, s_mmio, *_ = _clean_mmio_pair()
    opts = StressRunOptions(
        mode="phy",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
        phy=PhyHealthConfig(poll_period_s=0.01, duration_s=0.05),
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.DONE
    samples = [e for e in events if e.kind == "phy_health_sample"]
    assert samples


async def test_run_cancel(lease_client):
    m_mmio, s_mmio, *_ = _clean_mmio_pair()
    opts = StressRunOptions(
        mode="fcsm",
        stage_dir="/tmp/never",
        master_ip="10.0.0.1", slave_ip="10.0.0.2",
        skip_deploy=True, skip_converge=True,
        enable_phy_sentinel=False,
        fcsm=FcsmMonitorConfig(poll_period_s=0.01, duration_s=10.0),
    )
    run = Run(lease_client, deploy_runner=None,
              mmio_master_factory=lambda: m_mmio,
              mmio_slave_factory=lambda: s_mmio,
              options=opts)
    run.start()
    await asyncio.sleep(0.05)
    await run.cancel()
    assert run.state in (RunState.ABORTED, RunState.DONE)

"""End-to-end state-machine test for Run with all subordinates mocked."""
from __future__ import annotations

import asyncio

import httpx
import pytest

from pynq_host.scripts.eye_toolkit.web import (
    deploy as deploy_mod,
    lease as lease_mod,
    runner as runner_mod,
)
from pynq_host.scripts.eye_toolkit.web.runner import (
    Run, RunOptions, RunState,
)
from pynq_host.scripts.eye_toolkit.web.sweep_live import SweepConfig


def _stub_sweep_configs():
    state = {"phy": 0}

    def rd(a):
        if a == 0x44030000:
            return state["phy"]
        return 0x00ff  # all 8 lanes locked

    def wr(a, sh, msk, v):
        if a == 0x44030000:
            state["phy"] = (v << sh) & (msk << sh)

    return [
        SweepConfig(board="master", ip="10.0.0.1", settle_s=0.0,
                    read_fn=rd, write_fn=wr),
        SweepConfig(board="slave", ip="10.0.0.2", settle_s=0.0,
                    read_fn=rd, write_fn=wr),
    ]


async def _drain(run: Run, *, until: str | None = None,
                 max_events: int = 4096) -> list:
    out = []
    while len(out) < max_events:
        ev = await asyncio.wait_for(run.events.get(), timeout=10.0)
        out.append(ev)
        if ev.kind == "closed":
            break
        if until is not None and ev.kind == until:
            break
    return out


async def test_happy_path_to_done(lease_client, staged_bitstream_dir,
                                  fake_deploy_script, fake_converge_script):
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    opts = RunOptions(stage_dir=str(staged_bitstream_dir))
    run = Run(lease_client, dep, _stub_sweep_configs(), opts)
    run.start()
    events = await _drain(run)
    kinds = [e.kind for e in events]
    assert "lease_acquired" in kinds
    assert "deploy" in kinds
    assert any(e.kind == "sweep_row" for e in events)
    assert events[-1].kind == "closed"
    assert run.state == RunState.DONE
    assert sum(1 for e in events if e.kind == "sweep_row") == 32


async def test_skip_deploy_goes_straight_to_sweep(
    lease_client, staged_bitstream_dir, fake_deploy_script,
    fake_converge_script,
):
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    opts = RunOptions(stage_dir=str(staged_bitstream_dir),
                      skip_deploy=True, skip_converge=True)
    run = Run(lease_client, dep, _stub_sweep_configs(), opts)
    run.start()
    events = await _drain(run)
    kinds = [e.kind for e in events]
    assert "deploy" not in kinds or all(
        e.detail.get("kind") not in ("deploying", "bringup_started")
        for e in events if e.kind == "deploy"
    )
    assert any(e.kind == "sweep_row" for e in events)
    assert run.state == RunState.DONE


async def test_converge_failure_fails_run(
    lease_client, staged_bitstream_dir, fake_deploy_script,
    fake_converge_script,
):
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    dep.env = {"FAKE_CONVERGE_OK": "0"}
    opts = RunOptions(stage_dir=str(staged_bitstream_dir))
    run = Run(lease_client, dep, _stub_sweep_configs(), opts)
    run.start()
    events = await _drain(run)
    deploy_kinds = [e.detail.get("deploy_kind") for e in events
                    if e.kind == "deploy"]
    assert "bringup_failed" in deploy_kinds
    assert run.state == RunState.FAILED
    assert run.error is not None


async def test_lease_queued_fails_run(
    lease_client, fake_lease_state, staged_bitstream_dir,
    fake_deploy_script, fake_converge_script,
):
    # Hold the lease under a different identity so the run gets queued.
    fake_lease_state["current"] = {
        "holder": "operator-X", "user": "operator-X", "token": "tok-prior",
    }
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    opts = RunOptions(stage_dir=str(staged_bitstream_dir))
    run = Run(lease_client, dep, _stub_sweep_configs(), opts)
    run.start()
    events = await _drain(run)
    assert run.state == RunState.FAILED
    assert "queued" in (run.error or "").lower()


async def test_cancel_mid_sweep_aborts(
    lease_client, staged_bitstream_dir, fake_deploy_script,
    fake_converge_script,
):
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    # Slow sweep so we can interrupt it.
    slow_cfgs = _stub_sweep_configs()
    for c in slow_cfgs:
        c.settle_s = 0.1
    opts = RunOptions(stage_dir=str(staged_bitstream_dir),
                      skip_deploy=True, skip_converge=True)
    run = Run(lease_client, dep, slow_cfgs, opts)
    run.start()
    await asyncio.sleep(0.25)
    await run.cancel()
    # Drain remaining events.
    while True:
        try:
            ev = await asyncio.wait_for(run.events.get(), timeout=2.0)
        except asyncio.TimeoutError:
            break
        if ev.kind == "closed":
            break
    assert run.state == RunState.ABORTED


async def test_run_state_idle_initially(lease_client, staged_bitstream_dir,
                                        fake_deploy_script,
                                        fake_converge_script):
    dep = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=fake_deploy_script,
        converge_script=fake_converge_script,
    )
    opts = RunOptions(stage_dir=str(staged_bitstream_dir))
    run = Run(lease_client, dep, _stub_sweep_configs(), opts)
    assert run.state == RunState.IDLE
    assert run.run_id

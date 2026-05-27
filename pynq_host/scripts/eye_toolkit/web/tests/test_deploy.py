"""Tests for DeployRunner subprocess wrapping + stdout parsing."""
from __future__ import annotations

import asyncio
import json
import os

import pytest

from pynq_host.scripts.eye_toolkit.web import deploy as deploy_mod


def _runner(staged_dir, fake_deploy, fake_converge):
    return deploy_mod.DeployRunner(
        stage_dir=staged_dir,
        board_a_ip="10.0.0.1",
        board_b_ip="10.0.0.2",
        deploy_script=fake_deploy,
        converge_script=fake_converge,
    )


def test_verify_stage_ok(staged_bitstream_dir):
    r = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script="/bin/true", converge_script="/bin/true",
    )
    staged = r.verify_stage()
    assert staged.primary_bin.name == "tidelink.bin"
    assert staged.primary_label == "test-A"
    assert staged.flip_bin is not None
    assert staged.flip_manifest["label"] == "test-B"


def test_verify_stage_missing(tmp_path):
    r = deploy_mod.DeployRunner(
        stage_dir=tmp_path / "empty",
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script="/bin/true", converge_script="/bin/true",
    )
    with pytest.raises(deploy_mod.DeployError):
        r.verify_stage()


def test_verify_stage_missing_manifest(tmp_path):
    d = tmp_path / "stage"
    d.mkdir()
    (d / "tidelink.bin").write_bytes(b"\x00")
    # No tidelink.bin.manifest.json — deploy_pair.sh would hard-abort.
    r = deploy_mod.DeployRunner(
        stage_dir=d, board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script="/bin/true", converge_script="/bin/true",
    )
    with pytest.raises(deploy_mod.DeployError):
        r.verify_stage()


async def test_deploy_both_happy_path(staged_bitstream_dir, fake_deploy_script,
                                      fake_converge_script):
    r = _runner(staged_bitstream_dir, fake_deploy_script, fake_converge_script)
    events = []
    async for ev in r.deploy_both():
        events.append(ev)
    kinds = [e.kind for e in events]
    assert kinds.count("deploying") == 2, kinds
    assert kinds.count("deployed") == 2, kinds
    assert "bringup_started" in kinds
    assert "bringup_ok" in kinds
    # The "RESULT: CONVERGED — full 16/16" line also yields a lane_count.
    lc = [e for e in events if e.kind == "lane_count" and not e.detail.get("best")]
    assert any(e.detail.get("count") == 16 for e in lc)


async def test_deploy_fail_path(staged_bitstream_dir, fake_deploy_script,
                                fake_converge_script):
    r = _runner(staged_bitstream_dir, fake_deploy_script, fake_converge_script)
    # Force deploy to emit DEPLOY-FAIL via env.
    r.env = {"FAKE_DEPLOY_FAIL": "1"}
    events = []
    async for ev in r.deploy_both(skip_converge=True):
        events.append(ev)
    fails = [e for e in events if e.kind == "deploy_failed"]
    assert fails, events


async def test_bringup_not_converged(staged_bitstream_dir, fake_deploy_script,
                                     fake_converge_script):
    r = _runner(staged_bitstream_dir, fake_deploy_script, fake_converge_script)
    r.env = {"FAKE_CONVERGE_OK": "0"}
    events = []
    async for ev in r.deploy_both(skip_deploy=True):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "bringup_started" in kinds
    assert "bringup_failed" in kinds
    best = [e for e in events if e.kind == "lane_count"
            and e.detail.get("best")]
    assert best, "expected a best-seen lane_count event"
    assert best[0].detail["count"] == 7


async def test_unreachable_line_emits_event(staged_bitstream_dir,
                                            fake_deploy_script,
                                            fake_converge_script):
    r = _runner(staged_bitstream_dir, fake_deploy_script, fake_converge_script)
    r.env = {"FAKE_DEPLOY_UNREACHABLE": "1"}
    events = []
    async for ev in r.deploy_both(skip_converge=True):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "unreachable" in kinds


async def test_skip_deploy_runs_only_converge(staged_bitstream_dir,
                                              fake_deploy_script,
                                              fake_converge_script):
    r = _runner(staged_bitstream_dir, fake_deploy_script, fake_converge_script)
    events = []
    async for ev in r.deploy_both(skip_deploy=True):
        events.append(ev)
    kinds = [e.kind for e in events]
    assert "deploying" not in kinds
    assert "bringup_started" in kinds


async def test_cancel_kills_pgrp(staged_bitstream_dir, tmp_path):
    """A long-running fake deploy is cancelled mid-flight; cancel()
    sends SIGTERM to the process group."""
    long_script = tmp_path / "long_deploy.sh"
    long_script.write_text("#!/bin/bash\nsleep 30\n")
    long_script.chmod(0o755)
    r = deploy_mod.DeployRunner(
        stage_dir=staged_bitstream_dir,
        board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
        deploy_script=long_script,
        converge_script="/bin/true",
    )

    async def _consume():
        async for _ in r.deploy_both(skip_converge=True):
            pass

    task = asyncio.create_task(_consume())
    await asyncio.sleep(0.3)
    await r.cancel()
    try:
        await asyncio.wait_for(task, timeout=3.0)
    except (asyncio.TimeoutError, asyncio.CancelledError, deploy_mod.DeployError):
        pass
    # All procs should have exited.
    for p in r._procs:
        assert p.returncode is not None

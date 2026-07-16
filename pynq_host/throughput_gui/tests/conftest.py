"""Shared fixtures for the throughput_gui test suite.

ALL tests run against the fake backend (LocalAgentChannel + the agent's
--fake die model) — no hardware, no network, per the sibling toolkits'
offline-test pattern (stress_toolkit FakeMmio).
"""
from __future__ import annotations

import asyncio
import shutil
import sys
from pathlib import Path

import pytest

THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from pynq_host.throughput_gui import provenance  # noqa: E402
from pynq_host.throughput_gui.agent_channel import (  # noqa: E402
    LocalAgentChannel,
)
from pynq_host.throughput_gui.app import AppConfig, create_app  # noqa: E402
from pynq_host.throughput_gui.lease import FakeLeaseClient  # noqa: E402
from pynq_host.throughput_gui.store import RunStore  # noqa: E402

# Short, CI-friendly canned params.
FAST_PARAMS = {"burst_words": 16, "duration_s": 1.2, "win_s": 0.2,
               "rate_pps": 0}


@pytest.fixture
def store(tmp_path) -> RunStore:
    return RunStore(tmp_path / "runs")


@pytest.fixture
def artefacts(tmp_path) -> Path:
    """Staged fake artefact tree with honest manifests."""
    root = tmp_path / "artefacts"
    provenance.make_fake_artefacts(root, "v0-fake")
    return root


@pytest.fixture
def valid_provenance(artefacts) -> dict:
    return provenance.load_provenance(artefacts, "v0-fake")


@pytest.fixture
def link_dir(tmp_path) -> Path:
    d = tmp_path / "wire"
    d.mkdir()
    return d


@pytest.fixture
def channel_pair(link_dir):
    """A master/slave LocalAgentChannel pair on a shared fake wire."""
    return (LocalAgentChannel("master", link_dir),
            LocalAgentChannel("slave", link_dir))


@pytest.fixture
def app_cfg(tmp_path, artefacts) -> AppConfig:
    return AppConfig(
        fake=True,
        store_root=tmp_path / "runs",
        artefact_root=artefacts,
        default_artefact_version="v0-fake",
        lock_file=tmp_path / "hw.lock",
    )


@pytest.fixture
def fake_app(app_cfg):
    return create_app(app_cfg, lease_client=FakeLeaseClient())


def pytest_collection_modifyitems(config, items):
    for item in items:
        if (isinstance(item, pytest.Function)
                and asyncio.iscoroutinefunction(item.function)):
            item.add_marker(pytest.mark.asyncio)

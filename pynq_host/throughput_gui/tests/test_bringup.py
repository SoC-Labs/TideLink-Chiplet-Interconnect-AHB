"""Offline tests for the data-mode bring-up ladder.

Covers the three pieces that make ``bringup=seed|beacon|full`` work:
  * the agent's ``--cmd syncbeacon`` / ``--cmd datamode`` register VALUES,
  * their lockstep with the host-side constants in ``regmap``,
  * ``orchestrator._bringup()`` issuing the right stages in order,
  * the registry validating the new ``bringup`` param.

HW-UNVALIDATED. These prove the wiring and the register values, NOT that
the recipe actually delivers on silicon — the only hardware run so far
violated the repro script's clean-start precondition and is confounded.
The register values themselves are taken from
``pynq_host/scripts/tl_z2_data_bringup_repro.sh`` and the RTL it cites.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from pynq_host.throughput_gui import regmap, tests_registry
from pynq_host.throughput_gui.orchestrator import ThroughputRun

AGENT = Path(__file__).resolve().parents[1] / "agent" / "tl_perf_agent.py"


def _load_agent():
    spec = importlib.util.spec_from_file_location("tl_agent_bu", AGENT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── register values / lockstep ──────────────────────────────────────────

def test_agent_regmap_bringup_lockstep():
    a = _load_agent()
    assert a.DATA_MODE_TRIPLET == regmap.DATA_MODE_TRIPLET
    assert a.SYNC_BEACON_VALUE == regmap.SYNC_BEACON_VALUE
    assert a.R_WLINK_ENABLE_RESET == regmap.R_WLINK_ENABLE_RESET


def test_datamode_triplet_holds_swi_enable():
    # bit0 (swi_enable) is HIGH in ALL THREE writes — the ...08/...00/...07
    # form that drops it forces the FCSM to state 0 and clears the credit
    # ring (axi_chiplet_controller.sv:3440-3462). This test is the guard
    # against someone "simplifying" the values back to the bad form.
    for v in regmap.DATA_MODE_TRIPLET:
        assert v & 1 == 1, "swi_enable dropped in 0x%08x" % v
    assert regmap.R_WLINK_ENABLE_RESET == 0x44030208
    assert regmap.SYNC_BEACON_VALUE == 0x1C


# ── registry param ──────────────────────────────────────────────────────

def test_registry_bringup_param():
    assert tests_registry.validate_params(
        "throughput_m2s", {})["bringup"] == "none"
    assert tests_registry.validate_params(
        "throughput_m2s", {"bringup": "full"})["bringup"] == "full"
    with pytest.raises(tests_registry.ParamError):
        tests_registry.validate_params(
            "throughput_m2s", {"bringup": "bogus"})


# ── orchestrator ladder ─────────────────────────────────────────────────

async def _drain(run):
    out = []
    while not run.events.empty():
        out.append(await run.events.get())
    return out


@pytest.mark.parametrize("stage,expect", [
    ("none", set()),
    ("seed", {"seed"}),
    ("beacon", {"seed", "beacon"}),
    ("full", {"seed", "beacon", "datamode"}),
])
async def test_bringup_stages(channel_pair, store, stage, expect):
    m, s = channel_pair
    run = ThroughputRun("rid-%s" % stage, store, m, s,
                        {"bringup": stage, "duration_s": 1.0})
    await run._bringup()
    assert run._bringup_stage == (None if stage == "none" else stage)
    evs = await _drain(run)
    kinds = {e.detail.get("stage") for e in evs if e.kind == "bringup"}
    assert kinds == expect
    await m.close()
    await s.close()


async def test_full_bringup_readbacks(channel_pair, store):
    """The 'full' stage must leave data-mode + beacon readbacks correct."""
    m, s = channel_pair
    run = ThroughputRun("rid-rb", store, m, s,
                        {"bringup": "full", "duration_s": 1.0})
    await run._bringup()
    evs = [e.detail for e in await _drain(run) if e.kind == "bringup"]

    seeds = [e for e in evs if e.get("stage") == "seed"]
    assert seeds and all(e["pair_credits"] >= e["pair_credits_before"]
                         for e in seeds)

    beacons = [e for e in evs if e.get("stage") == "beacon"]
    assert beacons and all(e["sync_insert_en"] == 1
                           and e["training_mode"] == 0 for e in beacons)

    dm = [e for e in evs if e.get("stage") == "datamode"]
    assert dm and all(e["swi_enable"] == 1 and e["ll_tx_enable"] == 1
                      and e["ll_rx_enable"] == 1 and e["sw_reset"] == 0
                      for e in dm)
    await m.close()
    await s.close()


async def test_bringup_none_is_a_noop(channel_pair, store):
    m, s = channel_pair
    run = ThroughputRun("rid-noop", store, m, s, {"duration_s": 1.0})
    await run._bringup()          # default "none"
    assert run._bringup_stage is None
    assert [e for e in await _drain(run) if e.kind == "bringup"] == []
    await m.close()
    await s.close()


async def test_bringup_unknown_stage_raises(channel_pair, store):
    from pynq_host.throughput_gui import gates
    m, s = channel_pair
    run = ThroughputRun("rid-bad", store, m, s,
                        {"bringup": "bogus", "duration_s": 1.0})
    with pytest.raises(gates.GateError):
        await run._bringup()
    await m.close()
    await s.close()


# ── beacon-state decode (the dead-I2C delivery-blocker signal) ──────────

def test_decode_surfaces_beacon_state():
    # golden pins the beacon via a since-fixed bug (R8=0x14); current
    # builds read R8=0x00 and cannot anchor; the interim workaround is 0x1C.
    golden = regmap.decode_monitor({"100": 0x14})
    assert golden["beacon_on"] == 1 and golden["sync_insert_en"] == 1
    assert golden["training"] == 0            # NOT training-mode, beacon-mode

    current = regmap.decode_monitor({"100": 0x00})
    assert current["beacon_on"] == 0

    workaround = regmap.decode_monitor({"100": 0x1C})
    assert workaround["sync_force_always"] == 1


def test_health_flags_beacon_off_on_a_trained_link():
    # cal_done + fcsm healthy but beacon off => trained yet cannot deliver.
    dec = regmap.decode_monitor({"108": (1 << 16) | (4 << 17), "100": 0x00})
    h = regmap.health(dec)
    assert any("beacon off" in r.lower() for r in h["reasons"])
    # beacon-on golden-style link raises no beacon reason
    dec_on = regmap.decode_monitor({"108": (1 << 16) | (4 << 17),
                                    "100": 0x14})
    assert not any("beacon off" in r.lower()
                   for r in regmap.health(dec_on)["reasons"])

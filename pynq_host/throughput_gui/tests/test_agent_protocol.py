"""Agent protocol against the --fake backend: oneshots, GO-barrier
runs, the delivery-proof port, and jam injection — all through real
local subprocesses (the same code path production uses, minus SSH)."""
from __future__ import annotations

import pytest

from pynq_host.throughput_gui import gates, regmap
from pynq_host.throughput_gui.agent_channel import LocalAgentChannel


async def test_oneshot_probe(channel_pair):
    master, slave = channel_pair
    obs = await master.oneshot("probe")
    assert obs["cal_done"] == 1
    assert obs["fcsm"] == 4                  # healthy LINK_IDLE
    assert obs["fe_rx_is_full"] == 0
    assert obs["fc_obs_live"] == 1
    assert obs["fe_rx_credit_max"] == 0x1F
    sobs = await slave.oneshot("probe")
    assert sobs["occupancy"] == 0


async def test_delivery_proof_passes_on_healthy_link(channel_pair):
    master, slave = channel_pair
    detail, warnings = await gates.delivery_proof(master, slave,
                                                  catch_timeout_s=3.0)
    assert int(detail["delta"]) >= 4
    assert detail["words"][0] == "0x00240000"   # header byte-exact
    assert warnings == []


async def test_delivery_proof_fails_when_nothing_sent(link_dir):
    """A slave with no master traffic must NOT pass — the proof gate is
    only satisfied by a genuinely delivered packet."""
    slave = LocalAgentChannel("slave", link_dir)
    # master on a DIFFERENT wire: its packet can never reach this slave
    other = link_dir / "elsewhere"
    other.mkdir()
    master = LocalAgentChannel("master", other)
    with pytest.raises(gates.GateError, match="never landed"):
        await gates.delivery_proof(master, slave, catch_timeout_s=0.5)


async def test_delivery_proof_refuses_bad_presend_state(link_dir):
    master = LocalAgentChannel("master", link_dir,
                               extra_env={"TIDELINK_FAKE_LINK_DOWN": "1"})
    slave = LocalAgentChannel("slave", link_dir)
    with pytest.raises(gates.GateError, match="not LINK_IDLE"):
        await gates.delivery_proof(master, slave)


async def test_link_gate(channel_pair):
    master, slave = channel_pair
    verdict = await gates.link_gate(master, slave)
    assert verdict.ok and verdict.criterion == "B"
    # 0x11C is PHY_ALIGN_ID, the constant block-presence marker the RTL
    # returns (axi_chiplet_controller.sv:2684) — the fake used to answer an
    # invented 0xFA4E_0001, which made --fake and silicon disagree.
    assert verdict.snapshot["m_phy_id"] == "0x%08x" % regmap.PHY_ALIGN_ID_EXPECT


async def test_link_gate_down(link_dir):
    master = LocalAgentChannel("master", link_dir,
                               extra_env={"TIDELINK_FAKE_LINK_DOWN": "1"})
    slave = LocalAgentChannel("slave", link_dir)
    verdict = await gates.link_gate(master, slave)
    assert not verdict.ok


async def test_stream_drain_run_with_go_barrier(channel_pair):
    """Full measurement leg: both agents ready -> GO -> samples flow on
    both sides and the slave genuinely receives the master's words."""
    master, slave = channel_pair
    await slave.start_run({"role": "drain", "duration_s": 1.6,
                           "win_s": 0.25})
    await master.start_run({"role": "stream", "burst_words": 16,
                            "duration_s": 1.2, "win_s": 0.25})
    await slave.send_go()
    await master.send_go()

    m_samples, m_done = [], None
    async for ev in master.events():
        if ev["ev"] == "sample":
            m_samples.append(ev)
        elif ev["ev"] == "done":
            m_done = ev["summary"]
    s_samples, s_done = [], None
    async for ev in slave.events():
        if ev["ev"] == "sample":
            s_samples.append(ev)
        elif ev["ev"] == "done":
            s_done = ev["summary"]
    await master.close()
    await slave.close()

    assert len(m_samples) >= 3 and len(s_samples) >= 3
    assert m_done["packets"] > 0
    assert m_done["throughput_mbps_mean"] > 0
    # delivery is real: slave drained a meaningful share of what the
    # master streamed (drain window outlives the stream)
    assert s_done["drained_words"] > 0.5 * m_done["words_total"]
    # observer fields ride along in every sample
    assert all(s["fcsm"] == 4 and s["cal_done"] == 1 for s in m_samples)
    # credit-gated stream is throttled near the modeled link capacity:
    # 150k words/s * 32 bits * 16/18 payload share ~= 4.27 Mbit/s
    assert 1.0 < m_done["throughput_mbps_mean"] < 6.0


async def test_jam_injection_surfaces_in_samples(link_dir):
    master = LocalAgentChannel(
        "master", link_dir,
        extra_env={"TIDELINK_FAKE_JAM_AT_S": "0.5"})
    await master.start_run({"role": "stream", "burst_words": 16,
                            "duration_s": 1.5, "win_s": 0.2})
    await master.send_go()
    jam_seen = False
    async for ev in master.events():
        if ev["ev"] == "sample" and gates.sample_excursion(ev):
            jam_seen = True
            break
    await master.close()
    assert jam_seen, "CLASSIC jam signature never surfaced in samples"

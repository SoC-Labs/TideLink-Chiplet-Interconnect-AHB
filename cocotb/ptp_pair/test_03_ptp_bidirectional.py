"""TEST 03 — bidirectional PTP traffic with no SYNC/FOLLOW-UP cross-talk.

Both sides drive PTP packets at the same time. Verify each side sees the
peer's packets, and that data_id 0x50 vs 0x51 are correctly distinguished
on both RX paths (i.e. the FC rxrouter ShortPacket node demux does not
collapse the two ids together).

SKIP: see test_01.
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.result import TestSuccess

from ptp_pair_common import (
    attempt_bringup, send_ptp_sp, SPObserver, skip_if_no_link_data,
    DATA_ID_PTP_SYNC, DATA_ID_PTP_FOLLOWUP,
)


async def _drive_seq(dut, side, sequence):
    """Drive an ordered list of (data_id, payload) packets from one side."""
    for did, pld in sequence:
        c = await send_ptp_sp(dut, side, did, pld, timeout_cycles=5000)
        assert c >= 0, f"{side} SP TX timeout did=0x{did:02x} pld=0x{pld:04x}"
        clk = dut.master_clk if side == "m" else dut.slave_clk
        await ClockCycles(clk, 25)


@cocotb.test()
async def test_03_ptp_bidirectional(dut):
    """Both sides drive PTP traffic concurrently; verify no cross-talk."""
    obs_link = await attempt_bringup(dut, observation_cycles=5000)
    skip, reason = skip_if_no_link_data(dut, obs_link, "test_03")
    if skip:
        dut._log.warning("SKIP: " + reason)
        raise TestSuccess(reason)

    # Master drives 4 SYNC, slave drives 4 FOLLOW-UP — different data_ids
    # on each direction so any leakage shows up as an unexpected id on
    # the wrong side.
    master_pkts = [(DATA_ID_PTP_SYNC,     0x3000 + i) for i in range(4)]
    slave_pkts  = [(DATA_ID_PTP_FOLLOWUP, 0x4000 + i) for i in range(4)]

    monitor_m = SPObserver(dut, "m")
    monitor_s = SPObserver(dut, "s")
    cocotb.start_soon(monitor_m.run(max_cycles=30000))
    cocotb.start_soon(monitor_s.run(max_cycles=30000))

    # Kick both drivers concurrently.
    t_m = cocotb.start_soon(_drive_seq(dut, "m", master_pkts))
    t_s = cocotb.start_soon(_drive_seq(dut, "s", slave_pkts))
    await t_m
    await t_s
    await ClockCycles(dut.master_clk, 3000)
    monitor_m.stop(); monitor_s.stop()
    await ClockCycles(dut.master_clk, 5)

    # Slave should have seen all 4 SYNCs from master, NO FOLLOW-UPs (those
    # were sent BY slave, not TO it).
    s_syncs = monitor_s.count_by_data_id(DATA_ID_PTP_SYNC)
    s_fups  = monitor_s.count_by_data_id(DATA_ID_PTP_FOLLOWUP)
    # Master should have seen all 4 FOLLOW-UPs from slave, NO SYNCs.
    m_syncs = monitor_m.count_by_data_id(DATA_ID_PTP_SYNC)
    m_fups  = monitor_m.count_by_data_id(DATA_ID_PTP_FOLLOWUP)
    dut._log.info(f"slave  RX: syncs={s_syncs} fups={s_fups}")
    dut._log.info(f"master RX: syncs={m_syncs} fups={m_fups}")

    assert s_syncs == 4, f"slave saw {s_syncs} SYNCs from master, expected 4"
    assert s_fups  == 0, f"slave saw {s_fups} FOLLOW-UPs (cross-talk — should be 0)"
    assert m_fups  == 4, f"master saw {m_fups} FOLLOW-UPs from slave, expected 4"
    assert m_syncs == 0, f"master saw {m_syncs} SYNCs (cross-talk — should be 0)"

    # Payload integrity per direction.
    expected_s_payloads = [p for _, p in master_pkts]
    actual_s_payloads   = monitor_s.payloads(DATA_ID_PTP_SYNC)
    for exp, got in zip(expected_s_payloads, actual_s_payloads):
        assert (got & 0xFFFF) == (exp & 0xFFFF), \
            f"slave SYNC payload mismatch: expected 0x{exp:04x}, got 0x{got:04x}"
    expected_m_payloads = [p for _, p in slave_pkts]
    actual_m_payloads   = monitor_m.payloads(DATA_ID_PTP_FOLLOWUP)
    for exp, got in zip(expected_m_payloads, actual_m_payloads):
        assert (got & 0xFFFF) == (exp & 0xFFFF), \
            f"master FOLLOW-UP payload mismatch: expected 0x{exp:04x}, got 0x{got:04x}"

    dut._log.info("PASS: bidirectional traffic, no SYNC/FOLLOW-UP cross-talk")

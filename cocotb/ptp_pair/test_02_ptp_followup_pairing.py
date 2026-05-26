"""TEST 02 — PTP SYNC + FOLLOW-UP pairs cross the paired link.

Goal: drive 4 (SYNC, FOLLOW-UP) pairs from master. Verify slave sees
both messages of each pair, in the right order, with matching sequence
numbers encoded in the 16-bit payload.

The task spec uses data_id=0x51 for the follow-up. In the canonical
PTP-over-FC encoding this slot is named DELAY_REQ in tidelink_ptp.sv;
we treat it as the follow-up companion for this test (data_ids are
opaque slots on the wire, the upper-layer interpretation is what
distinguishes them).

SKIP: see test_01 for the auto-skip rationale.
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.result import TestSuccess

from ptp_pair_common import (
    attempt_bringup, send_ptp_sp, SPObserver, skip_if_no_link_data,
    DATA_ID_PTP_SYNC, DATA_ID_PTP_FOLLOWUP,
)


@cocotb.test()
async def test_02_ptp_followup_pairing(dut):
    """(SYNC, FOLLOW-UP) pairs preserved on slave RX."""
    obs_link = await attempt_bringup(dut, observation_cycles=5000)
    skip, reason = skip_if_no_link_data(dut, obs_link, "test_02")
    if skip:
        dut._log.warning("SKIP: " + reason)
        raise TestSuccess(reason)

    monitor = SPObserver(dut, "s")
    cocotb.start_soon(monitor.run(max_cycles=30000))

    PAIRS = 4
    sent_pairs = []  # list of (sync_seq, followup_seq)
    for i in range(PAIRS):
        sync_seq = 0x2000 + i
        fup_seq  = 0x2000 + i  # paired: same sequence number
        c1 = await send_ptp_sp(dut, "m", DATA_ID_PTP_SYNC,     sync_seq)
        assert c1 >= 0, f"SYNC TX timeout pair {i}"
        await ClockCycles(dut.master_clk, 20)
        c2 = await send_ptp_sp(dut, "m", DATA_ID_PTP_FOLLOWUP, fup_seq)
        assert c2 >= 0, f"FOLLOW-UP TX timeout pair {i}"
        await ClockCycles(dut.master_clk, 50)
        sent_pairs.append((sync_seq, fup_seq))
        dut._log.info(f"  pair {i}: SYNC 0x{sync_seq:04x} + FOLLOW-UP 0x{fup_seq:04x}")

    await ClockCycles(dut.master_clk, 2000)
    monitor.stop()
    await ClockCycles(dut.master_clk, 5)

    # Reconstruct received pairs in arrival order. Expectation: each
    # SYNC is immediately followed by its FOLLOW-UP with matching seq.
    events = monitor.events
    dut._log.info(f"slave saw {len(events)} events: {[(hex(d), hex(p)) for d,p,_ in events]}")
    sync_count = sum(1 for d,_,_ in events if d == DATA_ID_PTP_SYNC)
    fup_count  = sum(1 for d,_,_ in events if d == DATA_ID_PTP_FOLLOWUP)
    assert sync_count == PAIRS, f"slave saw {sync_count} SYNC, expected {PAIRS}"
    assert fup_count  == PAIRS, f"slave saw {fup_count} FOLLOW-UP, expected {PAIRS}"

    # Walk events and check pair order/seq match.
    cursor = 0
    for i, (sync_seq, fup_seq) in enumerate(sent_pairs):
        # find next SYNC event from cursor
        while cursor < len(events) and events[cursor][0] != DATA_ID_PTP_SYNC:
            cursor += 1
        assert cursor < len(events), f"missing SYNC for pair {i}"
        d_s, p_s, _ = events[cursor]
        assert p_s == (sync_seq & 0xFFFF), f"pair {i} SYNC seq mismatch: got 0x{p_s:04x}, expected 0x{sync_seq:04x}"
        cursor += 1
        # next non-? event should be FOLLOW-UP with matching seq
        while cursor < len(events) and events[cursor][0] != DATA_ID_PTP_FOLLOWUP:
            cursor += 1
        assert cursor < len(events), f"missing FOLLOW-UP for pair {i}"
        d_f, p_f, _ = events[cursor]
        assert p_f == (fup_seq & 0xFFFF), f"pair {i} FOLLOW-UP seq mismatch: got 0x{p_f:04x}, expected 0x{fup_seq:04x}"
        cursor += 1

    dut._log.info(f"PASS: {PAIRS}/{PAIRS} SYNC+FOLLOW-UP pairs received in order with matching seq numbers")

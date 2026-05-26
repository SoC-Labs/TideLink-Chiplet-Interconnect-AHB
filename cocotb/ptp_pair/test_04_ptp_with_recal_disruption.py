"""TEST 04 — PTP traffic survives a mid-stream recal cycle.

Scenario replays the PHC-PHASE-1 HW debug context: send a few SYNC
packets, then inject the bring-up recal sequence (slot0 0x3→0x1→0x0 +
LL swreset), and verify that after re-convergence the PTP path resumes
(further SYNC packets cross the wire).

This is the test PHC-PHASE-1 was nominally trying to perform on the
bench. With the sim test in place, the next HW campaign reduces to a
"flash bitstream, rerun, expect PASS" close-out.

SKIP: see test_01.
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.result import TestSuccess

from ptp_pair_common import (
    setup, lock_master, lock_slave, recal_cycle, drop_training_and_swreset_ll,
    send_ptp_sp, SPObserver, skip_if_no_link_data, _fcsm, FCSM_LINK_DATA,
    DATA_ID_PTP_SYNC,
)


@cocotb.test()
async def test_04_ptp_with_recal_disruption(dut):
    """SYNC traffic → mid-stream recal → SYNC traffic resumes."""
    # Manually inline the bring-up here so we can interleave the second
    # recal_cycle after a packet burst. We still measure max FCSM state
    # to derive the SKIP condition.
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold=200, settle=200)
    await drop_training_and_swreset_ll(dut)

    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    pre_max_m = 0; pre_max_s = 0
    for _ in range(5000):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        if ms > pre_max_m: pre_max_m = ms
        if ss > pre_max_s: pre_max_s = ss

    bringup_obs = {
        "max_m": pre_max_m, "max_s": pre_max_s,
        "link_data": (pre_max_m >= FCSM_LINK_DATA) and (pre_max_s >= FCSM_LINK_DATA),
    }
    skip, reason = skip_if_no_link_data(dut, bringup_obs, "test_04")
    if skip:
        dut._log.warning("SKIP: " + reason)
        raise TestSuccess(reason)

    monitor = SPObserver(dut, "s")
    cocotb.start_soon(monitor.run(max_cycles=80000))

    # Burst 1: 4 SYNCs.
    for i in range(4):
        c = await send_ptp_sp(dut, "m", DATA_ID_PTP_SYNC, 0x5000 + i)
        assert c >= 0, f"pre-recal SYNC {i} TX timeout"
        await ClockCycles(dut.master_clk, 20)
    await ClockCycles(dut.master_clk, 500)
    pre_count = monitor.count_by_data_id(DATA_ID_PTP_SYNC)
    dut._log.info(f"before recal: slave saw {pre_count} SYNCs")
    assert pre_count == 4, f"pre-recal: slave saw {pre_count} SYNC packets, expected 4"

    # Disruption: recal + LL swreset (the very sequence bringup_pair_converge.sh
    # uses; see memory project_tidelink_interface_fcsm_bug for context).
    dut._log.info("injecting recal cycle mid-stream")
    await recal_cycle(dut, hold=200, settle=200)
    await drop_training_and_swreset_ll(dut)

    # Wait for re-convergence.
    post_max_m = 0; post_max_s = 0
    for _ in range(5000):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        if ms > post_max_m: post_max_m = ms
        if ss > post_max_s: post_max_s = ss
    dut._log.info(f"post-recal FCSM: m_max={post_max_m} s_max={post_max_s}")
    assert post_max_m >= FCSM_LINK_DATA, \
        f"master FCSM did not re-reach LINK_DATA post-recal (max={post_max_m})"
    assert post_max_s >= FCSM_LINK_DATA, \
        f"slave FCSM did not re-reach LINK_DATA post-recal (max={post_max_s})"

    # Burst 2: 4 more SYNCs.
    for i in range(4):
        c = await send_ptp_sp(dut, "m", DATA_ID_PTP_SYNC, 0x6000 + i)
        assert c >= 0, f"post-recal SYNC {i} TX timeout"
        await ClockCycles(dut.master_clk, 20)
    await ClockCycles(dut.master_clk, 2000)
    monitor.stop()
    await ClockCycles(dut.master_clk, 5)

    total = monitor.count_by_data_id(DATA_ID_PTP_SYNC)
    post_only = total - pre_count
    dut._log.info(f"after recal: slave saw {total} SYNCs total ({post_only} post-recal)")
    assert total == 8, f"slave saw {total} SYNC packets total, expected 8 (4 pre + 4 post)"
    assert post_only == 4, f"slave saw {post_only} SYNCs after recal, expected 4"

    # Validate post-recal payloads.
    seen = monitor.payloads(DATA_ID_PTP_SYNC)
    expected = [0x5000 + i for i in range(4)] + [0x6000 + i for i in range(4)]
    for exp, got in zip(expected, seen):
        assert (got & 0xFFFF) == (exp & 0xFFFF), \
            f"SYNC payload mismatch post-recal: expected 0x{exp:04x}, got 0x{got:04x}"
    dut._log.info("PASS: PTP SYNC traffic resumed cleanly after recal disruption")

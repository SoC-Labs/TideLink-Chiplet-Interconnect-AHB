"""TL-035: after a REAL CRC error, the AXI data-node state-7 NACK watchdog must still fire.

AXI-plane (FCSM_0..4) variant of test_tl036_real_crc.py (which covers the sideband
FCSM_6). Nodes: wlink_axiawFC (AW, FCSM), wlink_axiwFC (W, _1), wlink_axibFC (B, _2),
wlink_axiarFC (AR, _3), wlink_axirFC (R, _4), on the pair-TB master.

Per node:
  Step 0: enable link CRC explicitly (out_prepend_swi_disable_crc forced 0 on both
          dies; CRC resets OFF on main's FPGA flist, ON on the TL-018 ASIC overrides).
  Step 1: pulse crcCorruptSeen (the ack_nack_fifo 'real CRC error' tag) for 16 tx clocks,
          the event that latches socl_l7_real_crc_seen on the unfixed RTL.
  Step 2: inject the stuck-SEND_NACK wedge (a NACK whose replay never arrives) exactly
          as test_l7_wedge_repro does, on that node.
  Step 3: the watchdog must assert socl_l7_wdog_force_clear within RECOVERY_WAIT_CYCLES.

Expected: fixed RTL PASS; FAIL with +define+TL033_LEGACY_WDOG (sticky term restored).
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles
from test_l7_wedge_repro import (PairTB, RECOVERY_WAIT_CYCLES, SOCL_L7_WDOG_THRESHOLD)

AXI_FC_NODES = ["wlink_axiawFC", "wlink_axiwFC", "wlink_axibFC",
                "wlink_axiarFC", "wlink_axirFC"]


def _node(tb, side, inst):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return getattr(top.u_chiplet_controller.u_wlink.axi2wl, inst)


def _crc_on(tb, on):
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            h = _node(tb, side, inst).out_prepend_swi_disable_crc
            h.value = Force(0) if on else Release()


async def _run(dut, inst):
    tb = PairTB(dut)
    fc = _node(tb, "m", inst)
    assert hasattr(fc, "socl_l7_wdog_force_clear"), f"{inst}: no socl_l7_wdog_force_clear: wrong RTL"
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked(max_cycles=20000)
    await ClockCycles(dut.hclk, 1000)
    _crc_on(tb, True)
    await ClockCycles(dut.hclk, 100)
    assert int(fc.out_prepend_swi_disable_crc.value) == 0, "CRC enable force did not take"
    seen0 = int(fc.socl_l7_real_crc_seen.value)
    fc.crcCorruptSeen.value = Force(1)
    await ClockCycles(fc.io_tx_clk, 16)
    fc.crcCorruptSeen.value = Release()
    await ClockCycles(dut.hclk, 200)
    seen1 = int(fc.socl_l7_real_crc_seen.value)
    dut._log.info(f"[tl035:{inst}] real_crc_seen before={seen0} after the CRC pulse={seen1}")
    assert seen1 == 1, f"{inst}: CRC pulse did not latch real_crc_seen (precondition)"
    try:
        # same wedge injection as test_l7_wedge_repro._force_master_into_state7, on this node
        fc.socl_l7_reached_link_data.value = Force(1)
        fc.send_nack_req.value = Force(1)
        fc.state.value = Force(7)
        await ClockCycles(dut.hclk, 100)
        st = int(fc.state.value)
        assert st == 7, f"{inst}: injection failed: state {st}"
        fired, cnt_max, waited = -1, 0, 0
        while waited < RECOVERY_WAIT_CYCLES:
            await ClockCycles(dut.hclk, 1000)
            waited += 1000
            cnt_max = max(cnt_max, int(fc.socl_l7_wdog_cnt.value))
            if int(fc.socl_l7_wdog_force_clear.value):
                fired = waited
                break
        dut._log.info(f"[tl035:{inst}] after real CRC: watchdog fired_at={fired} hclk "
                      f"(threshold {SOCL_L7_WDOG_THRESHOLD}), wdog_cnt max=0x{cnt_max:04x}")
        assert fired >= 0, (f"TL-035 {inst}: the state-7 watchdog never fired after a real CRC "
                            f"error (real_crc_seen={seen1}, wdog_cnt max=0x{cnt_max:04x})")
    finally:
        for h in (fc.state, fc.send_nack_req, fc.socl_l7_reached_link_data):
            h.value = Release()
        _crc_on(tb, False)


@cocotb.test()
async def test_tl035_axi_w_watchdog_survives_real_crc(dut):
    await _run(dut, "wlink_axiwFC")


@cocotb.test()
async def test_tl035_axi_aw_watchdog_survives_real_crc(dut):
    await _run(dut, "wlink_axiawFC")


@cocotb.test()
async def test_tl035_axi_b_watchdog_survives_real_crc(dut):
    await _run(dut, "wlink_axibFC")


@cocotb.test()
async def test_tl035_axi_ar_watchdog_survives_real_crc(dut):
    await _run(dut, "wlink_axiarFC")


@cocotb.test()
async def test_tl035_axi_r_watchdog_survives_real_crc(dut):
    await _run(dut, "wlink_axirFC")

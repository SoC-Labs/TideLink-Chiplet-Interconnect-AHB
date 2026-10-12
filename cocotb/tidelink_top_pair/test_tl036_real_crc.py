"""TL-036: after a REAL CRC error, the sideband FCSM_6 state-7 NACK watchdog must still fire.

Step 1: pulse crcCorruptSeen (the ack_nack_fifo 'real CRC error' tag) for 16 tx clocks,
        the event that latches socl_l7_real_crc_seen on the unfixed RTL.
Step 2: inject the stuck-SEND_NACK wedge exactly as test_l7_wedge_repro does.
Step 3: the watchdog must assert socl_l7_wdog_force_clear within RECOVERY_WAIT_CYCLES.

Expected: d00ae69/837c747 (legacy gate) FAIL; compute/tl036-eco-golden PASS;
compute/tl036-fix PASS, and FAIL again with +define+TL033_LEGACY_WDOG.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles
from test_l7_wedge_repro import (PairTB, _fcsm, _has_f1_watchdog, _force_master_into_state7,
                                 RECOVERY_WAIT_CYCLES, SOCL_L7_WDOG_THRESHOLD)


@cocotb.test()
async def test_tl036_watchdog_survives_real_crc(dut):
    tb = PairTB(dut)
    assert _has_f1_watchdog(dut), "FCSM_6 has no socl_l7_wdog_force_clear: wrong RTL"
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked(max_cycles=20000)
    await ClockCycles(dut.hclk, 1000)
    fc = _fcsm(dut)
    seen0 = int(fc.socl_l7_real_crc_seen.value)
    fc.crcCorruptSeen.value = Force(1)
    await ClockCycles(fc.io_tx_clk, 16)
    fc.crcCorruptSeen.value = Release()
    await ClockCycles(dut.hclk, 200)
    seen1 = int(fc.socl_l7_real_crc_seen.value)
    tb.log.info(f"[tl036] real_crc_seen before={seen0} after the CRC pulse={seen1}")
    fc = _force_master_into_state7(tb)
    await ClockCycles(dut.hclk, 100)
    assert tb.fcsm_state("m") == 7, f"injection failed: state {tb.fcsm_state('m')}"
    fired, cnt_max, waited = -1, 0, 0
    while waited < RECOVERY_WAIT_CYCLES:
        await ClockCycles(dut.hclk, 1000)
        waited += 1000
        cnt_max = max(cnt_max, int(fc.socl_l7_wdog_cnt.value))
        if int(fc.socl_l7_wdog_force_clear.value):
            fired = waited
            break
    tb.log.info(f"[tl036] after real CRC: watchdog fired_at={fired} hclk "
                f"(threshold {SOCL_L7_WDOG_THRESHOLD}), wdog_cnt max=0x{cnt_max:04x}")
    assert fired >= 0, ("TL-036: the state-7 watchdog never fired after a real CRC error "
                        f"(real_crc_seen={seen1}, wdog_cnt max=0x{cnt_max:04x})")

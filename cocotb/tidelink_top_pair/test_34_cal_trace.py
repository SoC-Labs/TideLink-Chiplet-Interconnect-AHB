"""DIAGNOSTIC: trace BOTH calibrators (cur_state, calibration_done,
training_mode) + the gated LL-TX-enable through the autonomous bring-up.

Hypothesis: the master calibrator never holds calibration_done (re-arms via
S_VALIDATE), so the master's Wlink LL TX framing is gated OFF
(wlink_lltx_enable_gated = swi_lltx_enable & calibration_done), suppressing
the master's CRACK emission and/or holding its RX in training — which is why
the master never completes the CR/CRACK handshake (crack=0) while the slave,
whose calibrator DID hold done, reaches state=4.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_28_autonomous_i2c_bringup_converge import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    reset_no_pokes, wait_bilateral_role_lock, _si,
)


def _cal(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_calibrator


def _fcsm(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


@cocotb.test()
async def test_cal_trace(dut):
    tb = PairTB(dut)
    log = dut._log
    cocotb.start_soon(Clock(dut.hclk, int(round(CLK_PERIOD_NS*1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS*1000)), unit="ps").start())
    for p in ("m", "s"):
        for sig, val in (("apb_psel",0),("apb_penable",0),("apb_pwrite",0),
            ("apb_paddr",0),("apb_pwdata",0),("apb_pstrb",0xF),("apb_pprot",0),
            ("ahb_tx_hsel",0),("ahb_tx_htrans",0),("ahb_tx_hready_in",1),
            ("ahb_fifo_hsel",0),("ahb_fifo_htrans",0),("ahb_fifo_hready_in",1)):
            try: getattr(dut, f"{p}_{sig}").value = val
            except AttributeError: pass
    await reset_no_pokes(tb)
    locked, _ = await wait_bilateral_role_lock(tb)
    assert locked
    log.info("role-locked; tracing calibrators...")

    mc, sc = _cal(tb, "m"), _cal(tb, "s")
    mfc, sfc = _fcsm(tb, "m"), _fcsm(tb, "s")
    # track how many cycles master cal_done is HIGH vs LOW
    m_done_hi = m_done_lo = 0
    m_states = {}
    POLL = 100
    for i in range(320):  # 32000 cy
        await ClockCycles(dut.hclk, POLL)
        md = _si(mc.calibration_done)
        if md == 1: m_done_hi += 1
        else: m_done_lo += 1
        ms = _si(mc.cur_state); m_states[ms] = m_states.get(ms, 0) + 1
        # capture any trigger / edge on master calibrator
        for sig in ("trigger_now", "role_locked_rise", "swreset_fall",
                    "calibrated_once_q", "role_locked", "swreset",
                    "role_locked_sync", "role_locked_q"):
            try:
                v = int(getattr(mc, sig).value)
                if sig in ("trigger_now","role_locked_rise","swreset_fall") and v == 1:
                    log.info(f"  >> t+{i*POLL}: master {sig}=1 "
                             f"(role_locked={_si(mc.role_locked)} swreset={_si(mc.swreset)} "
                             f"calibrated_once={_si(getattr(mc,'calibrated_once_q',None) if hasattr(mc,'calibrated_once_q') else None)})")
            except (AttributeError, ValueError, TypeError):
                pass
        if i % 25 == 0:
            log.info(f"  t+{i*POLL}: M(cal_state={_si(mc.cur_state)} done={md} "
                     f"train={_si(mc.training_mode)} fcsm={_si(mfc.state)} crk={_si(mfc.crack_pkt_seen_rx)}) "
                     f"S(cal_state={_si(sc.cur_state)} done={_si(sc.calibration_done)} "
                     f"train={_si(sc.training_mode)} fcsm={_si(sfc.state)})")
    log.info(f"  MASTER cal_done HIGH for {m_done_hi}/{m_done_hi+m_done_lo} polls; "
             f"cal_state histogram={m_states}")
    log.info(f"  FINAL M(done={_si(mc.calibration_done)} train={_si(mc.training_mode)} "
             f"fcsm={_si(mfc.state)} crk={_si(mfc.crack_pkt_seen_rx)}) "
             f"S(done={_si(sc.calibration_done)} train={_si(sc.training_mode)} fcsm={_si(sfc.state)})")

"""DIAGNOSTIC: capture the EXACT signal that re-arms the master calibrator
out of S_DONE. After master cal_done first rises, fine-poll (every hclk) the
calibrator's trigger edges + raw inputs and the cur_state, logging the cycle
the state leaves S_DONE (4) and what trigger fired.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_28_autonomous_i2c_bringup_converge import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    reset_no_pokes, wait_bilateral_role_lock, _si,
)


def _cal(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_calibrator


@cocotb.test()
async def test_trigger_capture(dut):
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

    mc = _cal(tb, "m")
    # wait until master cal first reaches DONE (state 4)
    for _ in range(40000):
        await RisingEdge(dut.hclk)
        if _si(mc.cur_state) == 4:
            break
    log.info(f"  master cal reached S_DONE; now fine-polling for re-arm...")

    prev_state = 4
    last_role = _si(mc.role_locked); last_swr = _si(mc.swreset)
    count_state4 = 0
    for i in range(60000):
        await RisingEdge(dut.hclk)
        st = _si(mc.cur_state)
        if st == 4: count_state4 += 1
        # input changes
        r = _si(mc.role_locked); s = _si(mc.swreset)
        if r != last_role:
            log.info(f"  i={i}: role_locked {last_role}->{r} (cal_state={st})"); last_role = r
        if s != last_swr:
            log.info(f"  i={i}: swreset {last_swr}->{s} (cal_state={st})"); last_swr = s
        if st != prev_state:
            tn = _si(getattr(mc, "trigger_now", None)) if hasattr(mc,"trigger_now") else -1
            rr = _si(getattr(mc, "role_locked_rise", None)) if hasattr(mc,"role_locked_rise") else -1
            sf = _si(getattr(mc, "swreset_fall", None)) if hasattr(mc,"swreset_fall") else -1
            rs = _si(getattr(mc, "role_locked_sync", None)) if hasattr(mc,"role_locked_sync") else -1
            rq = _si(getattr(mc, "role_locked_q", None)) if hasattr(mc,"role_locked_q") else -1
            log.info(f"  i={i}: cal_state {prev_state}->{st} | trigger_now={tn} "
                     f"role_locked_rise={rr} swreset_fall={sf} rl_sync={rs} rl_q={rq} "
                     f"role_locked={r} swreset={s}")
            prev_state = st
            if st == 4 and count_state4 > 3000:
                break  # re-stabilized in DONE again, enough
    log.info(f"  done capturing. final cal_state={_si(mc.cur_state)} "
             f"calibrated_once={_si(getattr(mc,'calibrated_once_q',None)) if hasattr(mc,'calibrated_once_q') else 'NA'}")

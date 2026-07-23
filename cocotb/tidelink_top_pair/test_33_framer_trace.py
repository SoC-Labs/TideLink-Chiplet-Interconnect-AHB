"""DIAGNOSTIC: trace the master RX byte-align framer + per-lane calibrator
settle through the autonomous bring-up, to localize WHY the master RX never
decodes the slave's CRACK (framer never locks vs deskew mismatch vs race).

Samples every `poll` cy from just after role-lock to well past TRAIN_DONE:
  - master FCSM state / cr / crack stickies
  - master LL_RX framer obs_state / obs_valid  (==lock indicator)
  - master FCSM auto_rx_in_sop/valid/data_id   (did ANY pkt arrive?)
Then prints the per-lane slip/phase both calibrators latched.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_28_autonomous_i2c_bringup_converge import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    reset_no_pokes, wait_bilateral_role_lock, _state, _sname, _si,
    ST_TRAIN_DONE,
)


def _fcsm(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _llrx(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.llrx


def _cal(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_calibrator


@cocotb.test()
async def test_framer_trace(dut):
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
    log.info("role-locked; tracing master RX framer through training...")

    mfc, mrx = _fcsm(tb, "m"), _llrx(tb, "m")
    sfc = _fcsm(tb, "s")
    max_obs_state = 0; ever_valid = 0; ever_sop = 0
    seen_ids = {}
    POLL = 200
    for i in range(160):  # 160*200 = 32000 cy ~ 640us, covers full train
        await ClockCycles(dut.hclk, POLL)
        try:
            os_ = _si(mrx.io_obs_state); ov = _si(mrx.io_obs_valid)
            if os_ > max_obs_state: max_obs_state = os_
            if ov == 1: ever_valid = 1
            sop = _si(mfc.auto_rx_in_sop); val = _si(mfc.auto_rx_in_valid)
            if sop == 1 and val == 1:
                ever_sop = 1
                did = _si(mfc.auto_rx_in_data_id)
                seen_ids[did] = seen_ids.get(did, 0) + 1
        except Exception:
            pass
        # log transitions of interest
        if i % 20 == 0:
            log.info(f"  t+{i*POLL}cy: M.fcsm={_si(mfc.state)} cr={_si(mfc.cr_pkt_seen_rx)} "
                     f"crk={_si(mfc.crack_pkt_seen_rx)} | M.framer obs_state={_si(mrx.io_obs_state)} "
                     f"obs_valid={_si(mrx.io_obs_valid)} | S.fcsm={_si(sfc.state)} "
                     f"S.crk={_si(sfc.crack_pkt_seen_rx)}")

    idstr = " ".join(f"0x{k:02x}:{v}" for k,v in sorted(seen_ids.items()))
    log.info(f"  SUMMARY master RX framer: max_obs_state={max_obs_state} "
             f"ever_obs_valid={ever_valid} ever_sop={ever_sop} | data_ids seen: {idstr}")

    # per-lane calibrator settle
    for side in ("m", "s"):
        cal = _cal(tb, side)
        slips = []; phases = []
        for ln in range(8):
            try:
                slips.append(_si(cal.slip[ln])); phases.append(_si(cal.phase[ln]))
            except Exception:
                slips.append(-1); phases.append(-1)
        log.info(f"  {side} calibrator slip={slips} phase={phases} "
                 f"cal_done={_si(cal.calibration_done)}")

    log.info(f"  FINAL: M.crack={_si(mfc.crack_pkt_seen_rx)} (0=stall) "
             f"M.fcsm={_si(mfc.state)} S.fcsm={_si(sfc.state)}")

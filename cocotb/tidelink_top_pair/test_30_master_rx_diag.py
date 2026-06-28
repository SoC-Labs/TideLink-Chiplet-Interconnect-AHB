"""DIAGNOSTIC: what does the autonomous master FCSM RX actually see?

After autonomous bring-up (master stuck state=2 crack=0), sample the master
FCSM RX-decode inputs and the LL_RX framer obs to distinguish:

  (race)   slave stopped emitting CRACK before master RX locked -> master
           never sees a crack-id packet at all.
  (framer) master RX framer mis-aligned -> it sees packets but decodes the
           wrong data_id (no 0x45 crack).

Also runs experiments on the live (already-stuck) link:
  EXP1: drop training (R8 slot0=0) both sides, watch master RX.
  EXP2: SW recal cycle (slot0 3->1->0) + LL swreset, watch master RX.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_28_autonomous_i2c_bringup_converge import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    reset_no_pokes, wait_bilateral_role_lock, wait_master_terminal_train,
    _state, _sname, _si, ST_TRAIN_DONE,
)
from test_tidelink_pair_doorbell import (
    APB_WL_LINK_ENABLE_RESET,
    LL_BOOTSTRAP_SWRESET_ON, LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE,
    APB_R8_SLOT0, R8_SLOT0_TRAIN_RECAL, R8_SLOT0_TRAIN_ONLY, R8_SLOT0_OFF,
)


def _fcsm(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


async def _autonomous_bringup(dut):
    tb = PairTB(dut)
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
    s, _ = await wait_master_terminal_train(tb)
    assert s == ST_TRAIN_DONE
    return tb


async def _watch_master_rx(tb, n, label):
    """Count, on the master FCSM RX, how many CR / CRACK / other valid SOP
    packets arrive over n hclk cycles, and capture distinct data_ids."""
    dut = tb.dut
    fc = _fcsm(tb, "m")
    n_cr = n_crack = n_other = n_sop = 0
    ids = {}
    for _ in range(n):
        await RisingEdge(dut.hclk)
        try:
            sop = int(fc.auto_rx_in_sop.value)
            val = int(fc.auto_rx_in_valid.value)
        except (ValueError, AttributeError):
            continue
        if sop and val:
            n_sop += 1
            did = _si(fc.auto_rx_in_data_id)
            ids[did] = ids.get(did, 0) + 1
            try:
                if int(fc.pkt_is_cr_pkt.value): n_cr += 1
                elif int(fc.pkt_is_crack_pkt.value): n_crack += 1
                else: n_other += 1
            except (ValueError, AttributeError):
                pass
    idstr = " ".join(f"0x{k:02x}:{v}" for k, v in sorted(ids.items()))
    tb.log.info(f"  [{label}] master RX over {n} cy: sop={n_sop} "
                f"cr={n_cr} crack={n_crack} other={n_other} | data_ids: {idstr}")
    # framer obs
    try:
        llrx = tb.dut.u_master.u_chiplet_controller.u_wlink.llrx
        tb.log.info(f"  [{label}] master LL_RX obs_state={_si(llrx.io_obs_state)} "
                    f"obs_valid={_si(llrx.io_obs_valid)}")
    except AttributeError:
        pass
    return n_cr, n_crack, n_sop


def _dump(tb, label):
    def g(side):
        fc = _fcsm(tb, side)
        return (_si(fc.state), _si(fc.cr_pkt_seen_rx), _si(fc.crack_pkt_seen_rx))
    m, s = g("m"), g("s")
    tb.log.info(f"  [{label}] M(st={m[0]} cr={m[1]} crk={m[2]}) S(st={s[0]} cr={s[1]} crk={s[2]})")


@cocotb.test()
async def test_master_rx_diag(dut):
    tb = await _autonomous_bringup(dut)
    log = dut._log
    await ClockCycles(dut.hclk, 8000)
    _dump(tb, "post-bringup")
    await _watch_master_rx(tb, 4000, "STUCK baseline")

    # EXP1: drop training on both, watch master RX for fresh CRACK.
    log.info("EXP1: R8 slot0=0 (training OFF) both sides")
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 4000)
    _dump(tb, "after train-off")
    await _watch_master_rx(tb, 4000, "after train-off")

    # EXP2: SW recal cycle + LL swreset (full do_to_data_mode equivalent).
    log.info("EXP2: recal 3->1->0 + LL swreset bootstrap both sides")
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_RECAL)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_RECAL)
    await ClockCycles(dut.hclk, 400)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)
    await ClockCycles(dut.hclk, 400)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)
    for v in (LL_BOOTSTRAP_SWRESET_ON, LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE):
        await tb.m_apb.write(APB_WL_LINK_ENABLE_RESET, v)
        await tb.s_apb.write(APB_WL_LINK_ENABLE_RESET, v)
        await ClockCycles(dut.hclk, 40)
    await ClockCycles(dut.hclk, 6000)
    _dump(tb, "after recal+swreset")
    await _watch_master_rx(tb, 4000, "after recal+swreset")

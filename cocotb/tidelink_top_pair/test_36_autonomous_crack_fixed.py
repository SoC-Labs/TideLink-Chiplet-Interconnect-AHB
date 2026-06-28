"""PROOF-OF-FIX: with the calibrator sticky-DONE fix
(tidelink_phy_align_calibrator.sv calibrated_once_q), the PURELY AUTONOMOUS
I2C bring-up now reaches bilateral FCSM state=4 with master crack=1 and
non-zero credit — NO SW pokes, NO LL-swreset injection.

ROOT CAUSE (see calibrator header comment): the autoneg winner pulses
SWI_RECAL at training-EXIT; its falling edge re-triggered the master
calibrator out of S_DONE back into S_SWEEP, re-asserting training_mode and
squelching the master's CR/CRACK handshake (crack stuck 0, FCSM stuck 2).
The fix latches calibration as sticky once S_DONE is reached and ignores the
spurious training-exit recal pulse.

Run:
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 SIM_BUILD=sim_build_an \
      MODULE=test_36_autonomous_crack_fixed make
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_28_autonomous_i2c_bringup_converge import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    reset_no_pokes, wait_bilateral_role_lock, wait_master_terminal_train,
    _si, ST_TRAIN_DONE,
)
from test_tidelink_pair_doorbell import (
    APB_PAIR_CREDIT_COUNTER, APB_DOORBELL, APB_DOORBELL_RESP_ACC,
    APB_RELEASE_THRESHOLD,
)


def _fcsm(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


@cocotb.test()
async def test_autonomous_crack_fixed(dut):
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
    assert locked, "bilateral role_locked never asserted"
    s, _ = await wait_master_terminal_train(tb)
    assert s == ST_TRAIN_DONE, "autoneg did not reach ST_TRAIN_DONE"

    # Give the credit-init handshake time to complete on the now-stable link.
    await ClockCycles(dut.hclk, 12000)

    mfc, sfc = _fcsm(tb, "m"), _fcsm(tb, "s")
    m_st, m_cr, m_crk = _si(mfc.state), _si(mfc.cr_pkt_seen_rx), _si(mfc.crack_pkt_seen_rx)
    s_st, s_cr, s_crk = _si(sfc.state), _si(sfc.cr_pkt_seen_rx), _si(sfc.crack_pkt_seen_rx)
    log.info(f"  FCSM: M(state={m_st} cr={m_cr} crack={m_crk}) "
             f"S(state={s_st} cr={s_cr} crack={s_crk})")

    assert m_crk == 1, (
        f"master crack_pkt_seen_rx={m_crk} (want 1) — master still not decoding "
        f"the slave's CRACK. M.state={m_st}.")
    assert m_st >= 4 and s_st >= 4, (
        f"FCSM not in data phase: M.state={m_st} S.state={s_st} (want both >=4).")

    # A master doorbell must now actually CROSS to the slave (M->S data path
    # alive — the master holds TX credit because the CR/CRACK handshake
    # completed). DOORBELL_RESP_ACC on the slave goes non-zero when the ring
    # is received. (PAIR_CREDIT_COUNTER is a separate ledger readback that
    # reads 0 even on the working SW path — see test_04 — so it is NOT the
    # crossing indicator and is logged only as diagnostics.)
    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)
    pre_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 20)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(dut.hclk, 6000)
    s_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    s_pcc = await tb.s_apb.read(APB_PAIR_CREDIT_COUNTER)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  slave DOORBELL_RESP_ACC: pre=0x{pre_db:08x} post=0x{s_db:08x} | "
             f"PAIR_CREDIT_COUNTER M=0x{m_pcc:08x} S=0x{s_pcc:08x}")
    assert s_db != 0 and s_db != pre_db, (
        f"master doorbell did NOT cross to slave: DOORBELL_RESP_ACC "
        f"pre=0x{pre_db:08x} post=0x{s_db:08x} (M->S data path still dead).")
    log.info("  PROOF: autonomous bring-up now reaches bilateral state=4, "
             "master crack=1, and a master doorbell crosses to the slave — "
             "NO SW pokes, NO LL-swreset injection.")

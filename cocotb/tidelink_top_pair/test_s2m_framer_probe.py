"""S->M master LL_RX framer localisation (final cut point).

test_s2m_rxchain_probe proved the slave's data packet (...200700a1) arrives at
the master's llrx INPUT (llrx_io_link_data) but llrx_auto_out_valid stays 0 --
the master byte-align framer never decodes it. This probe inspects the master
framer's internal FSM and its reset/enable gating to find WHY:

  master llrx FSM    : llrx_io_obs_state (0=hunt,1=long-pkt,2=error)
  master llrx reset  : dbg_llrx_reset_out, swi_training_mode_rxsync_1,
                       rx_link_clk_reset_wrs_io_reset_out
  master llrx enable : llrx_io_enable, swi_training_mode_in
  framer-stuck flag  : dbg_framer_stuck
  link data in       : llrx_io_link_data
  framer out         : llrx_auto_out_valid / _sop

Compared to the slave llrx (the M->S reference) so the role asymmetry in the
framer reset/state is explicit.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full,
    APB_R8_SLOT0, R8_SLOT0_OFF, APB_RELEASE_THRESHOLD,
    APB_PAIR_CREDIT_COUNTER, APB_RELEASED_ACC,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


def _h(v, w):
    return "x" * w if v is None else f"{v:0{w}x}"


def wlink(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink


def framer_state(tb, dut, side):
    w = wlink(dut, side)
    tb.log.info(
        f"  [{side} framer] obs_state={_i(w.llrx_io_obs_state)} "
        f"llrx_reset={_i(w.dbg_llrx_reset_out)} "
        f"train_rxsync1={_i(w.swi_training_mode_rxsync_1)} "
        f"train_in={_i(w.swi_training_mode_in)} "
        f"clkrst={_i(w.rx_link_clk_reset_wrs_io_reset_out)} "
        f"llrx_en={_i(w.llrx_io_enable)} "
        f"stuck={_i(w.dbg_framer_stuck)}"
    )


@cocotb.test()
async def test_s2m_framer_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)
    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)

    log = tb.log
    log.info("=== framer gating snapshot (both sides) AFTER data mode ===")
    framer_state(tb, dut, "m")
    framer_state(tb, dut, "s")

    # Stuck-state internals: word_count (phantom long-pkt length latched on
    # filler) + first_short_pkt_seen (long_pkt_gate witness) for both sides.
    llrx_m = wlink(dut, "m").llrx
    llrx_s = wlink(dut, "s").llrx
    log.info(
        f"  [m llrx internals] state={_i(llrx_m.state)} "
        f"word_count={_i(llrx_m.word_count)} "
        f"first_short_pkt_seen={_i(llrx_m.first_short_pkt_seen)}"
    )
    log.info(
        f"  [s llrx internals] state={_i(llrx_s.state)} "
        f"word_count={_i(llrx_s.word_count)} "
        f"first_short_pkt_seen={_i(llrx_s.first_short_pkt_seen)}"
    )

    mw = wlink(dut, "m")

    async def trace_master_framer(n):
        last = None
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            din = _i(mw.llrx_io_link_data)
            st  = _i(mw.llrx_io_obs_state)
            rst = _i(mw.dbg_llrx_reset_out)
            t1  = _i(mw.swi_training_mode_rxsync_1)
            vo  = _i(mw.llrx_auto_out_valid)
            key = (st, rst, t1, vo, din != 0)
            if din or vo or key != last:
                log.info(
                    f"[mFRM c{cyc:4d}] din={_h(din,32)} obs_state={st} "
                    f"llrx_reset={rst} train_rxsync1={t1} out_valid={vo}"
                )
                last = key

    # Prime slave RX FIFO.
    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)
    await ClockCycles(dut.hclk, 1500)

    log.info("=== S->M: drain slave FIFO, trace MASTER framer FSM/reset ===")
    tB = cocotb.start_soon(trace_master_framer(4500))
    for off in (0x00, 0x04, 0x08, 0x0C):
        await tb.ahb_fifo_read_word("s", off)
    await ClockCycles(dut.hclk, 3000)
    await tB

    m_rel = await tb.m_apb.read(APB_RELEASED_ACC)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  master RELEASED_ACC=0x{m_rel:08x} PAIR_CREDIT=0x{m_pcc:08x}")

# =============================================================================
# DIRECTED L9b / L9c protection probe (fix/sideband-crc-replay, 2026-10-14).
#
# test_v2_stream_start_28w only exercises L9b/L9c under EPOCH_PROFILE=silicon, which at
# HEAD does not deliver (exp frozen at 0, 2803 reverts identically with L9b/L9c on or tied
# off -> the test cannot discriminate).  This probe makes the RX pktnum anchor WRONG on a
# healthy zero-skew link by depositing exp_pkt_num on the receiver after a warm-up packet
# (first_data_seen set), then streams a burst and counts TX link_revert pulses:
#   fwd  : exp deposited 2 BEHIND the incoming pktnum  -> isolated FORWARD gap -> L9b territory
#   back : exp deposited 3 AHEAD of the incoming pktnum -> BACKWARD/stale echo  -> L9c territory
# Healthy (L9b+L9c present): revert pulses <= budget and exp keeps advancing.
# Pristine (both absent)   : NACK->revert replay storm (exp can never converge on its own).
# Observables are logged as "[l9bc] <case> reverts=.. exp_distinct=.. l9b_fires=.. l9c_fires=..".
# =============================================================================
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from pair_v2_common import PairV2TB, run_bringup_full

BUDGET = 40
RING = 32


def _fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _i(s):
    try:
        return int(s.value)
    except Exception:
        return -1


async def _case(dut, name, delta):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    tx, rx = _fcsm(tb, "s"), _fcsm(tb, "m")          # s -> m
    await tb.ahb_tx_write_packet_b2b("s", [0xC0DE0000 + i for i in range(4)])   # warm-up: first_data_seen
    await ClockCycles(dut.hclk, 3000)
    cur = _i(rx.exp_pkt_num)
    assert _i(rx.socl_l9_first_data_seen_rx) == 1, "warm-up did not set first_data_seen: vacuous"
    rx.exp_pkt_num.value = (cur + delta) % RING      # deposit: wrong anchor
    st = dict(rev=0, l9b=0, l9c=0, exp=set())

    async def watch():
        for _ in range(12000):
            await RisingEdge(dut.hclk)
            st["rev"] += _i(tx.a2l_fc_replay_link_revert) == 1
            st["l9b"] += _i(rx.socl_l9b_reanchor_now) == 1
            st["l9c"] += _i(rx.socl_l9c_backward) == 1
            st["exp"].add(_i(rx.exp_pkt_num))
    w = cocotb.start_soon(watch())
    await tb.ahb_tx_write_packet_b2b("s", [0xA5A50000 + (i << 8) + i for i in range(20)])
    await ClockCycles(dut.hclk, 9000)
    await w
    tb.log.info(f"[l9bc] {name} cur_exp={cur} deposit={(cur + delta) % RING} reverts={st['rev']} "
                f"exp_distinct={len(st['exp'])} l9b_fires={st['l9b']} l9c_fires={st['l9c']}")
    assert st["rev"] <= BUDGET, f"{name}: NACK/revert storm: {st['rev']} reverts > {BUDGET}"
    assert len(st["exp"]) >= 8, f"{name}: exp_pkt_num frozen ({len(st['exp'])} distinct values)"


@cocotb.test()
async def test_l9b_forward_gap(dut):
    await _case(dut, "fwd", -2)


@cocotb.test()
async def test_l9c_backward_echo(dut):
    await _case(dut, "back", +3)

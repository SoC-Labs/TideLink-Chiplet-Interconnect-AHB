"""DIRECT PROOF (analysis lens, 2026-08-09): lane_mask=0xFF is an independent
anchor blocker when ONE lane is dead/marginal; masking that lane out unblocks.

Two scenarios on tb_deskew (TB_EPOCH_ANCHOR_EN=1 by default):

  A. mask=0xFF, lane 0 DEAD (no clock, no data), lanes 1..7 stream a coherent
     word. At 0xFF the readiness/anchor reduction is &(X | ~0xFF) = &X over ALL
     8 lanes, so the one dead lane vetoes forever -> out_valid NEVER asserts.

  B. mask=0xFE (lane 0 masked OUT), same stimulus. Now ~mask[0]=1 forces lane
     0's term true, the reduction is over the 7 live lanes -> the link comes up.

Delta A->B is PURELY the mask bit for the dead lane == the bare-link vs
eth-chiplet difference (0xFF vs a good-lane subset). Fast, single-unit.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

LANES = 8
WIDTH = 16
WORD_NS = 20


def lane_clk(dut, gi):
    return getattr(dut, f"lane_clk{gi}")


def lane_data(dut, gi):
    return getattr(dut, f"lane_data{gi}")


class LaneClock:
    def __init__(self, dut, gi, run=True):
        self.sig = lane_clk(dut, gi)
        self.stalled = not run
        self.sig.value = 0

    async def run(self):
        val = 0
        while True:
            while self.stalled:
                await Timer(WORD_NS / 2.0, units="ns")
            self.sig.value = val
            val ^= 1
            await Timer(WORD_NS / 2.0, units="ns")


async def feeder(dut, gi, idx_box, base=0x1000):
    while True:
        await RisingEdge(lane_clk(dut, gi))
        t = idx_box[gi]
        lane_data(dut, gi).value = (base | (t & 0x0FFF)) & 0xFFFF
        idx_box[gi] = t + 1


async def do_reset(dut, mask):
    dut.rst_n.value = 0
    dut.training_mode.value = 0
    dut.lane_mask.value = mask
    for gi in range(LANES):
        lane_data(dut, gi).value = 0
    await Timer(5 * WORD_NS, units="ns")
    dut.rst_n.value = 1
    await Timer(3 * WORD_NS, units="ns")


async def out_valid_ever(dut, cap):
    for _ in range(cap):
        await RisingEdge(dut.out_clk)
        if int(dut.out_valid.value) == 1:
            return True
    return False


async def _run(dut, mask):
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    live = [gi for gi in range(LANES) if gi != 0]     # lane 0 dead in both
    clks = [LaneClock(dut, gi, run=(gi in live)) for gi in range(LANES)]
    for c in clks:
        cocotb.start_soon(c.run())
    await do_reset(dut, mask)
    idx = [0] * LANES
    for gi in live:
        cocotb.start_soon(feeder(dut, gi, idx))
    return await out_valid_ever(dut, 300)


@cocotb.test()
async def test_mask_ff_dead_lane_wedges(dut):
    up = await _run(dut, 0xFF)
    print(f"VERDICT scenario=mask_FF_lane0_dead result="
          f"{'FAIL(link came up-unexpected)' if up else 'PASS(wedged as predicted)'} "
          f"out_valid_ever={up}")
    assert not up, ("mask=0xFF with a dead lane should WEDGE (all_ready/anchor "
                    "requires all 8) — it came up, hypothesis wrong")


@cocotb.test()
async def test_mask_fe_dead_lane_masked_up(dut):
    up = await _run(dut, 0xFE)
    print(f"VERDICT scenario=mask_FE_lane0_masked result="
          f"{'PASS(link up on 7-lane subset)' if up else 'FAIL(still wedged)'} "
          f"out_valid_ever={up}")
    assert up, ("mask=0xFE (dead lane masked out) should COME UP on the 7 live "
                "lanes — it wedged")

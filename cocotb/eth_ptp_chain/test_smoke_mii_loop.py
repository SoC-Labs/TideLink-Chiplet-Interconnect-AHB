"""Elaboration/compile smoke for the eth_ptp_chain bench (MII loopback wired).

Not the deliverable test — this exists only to prove the MII-loopback tb edits
elaborate and that the Shape-A link bring-up still passes with the MAC datapath
connected. The real chain test is test_ptp_chain.py.
"""
import cocotb
from cocotb.triggers import ClockCycles

from eth_pair_common import PairV2TB, run_bringup_full, EthAHBSubMaster


@cocotb.test()
async def test_smoke_mii_loop(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("[smoke] link up with MII loopback wired")
    tb.log.info(f"[smoke] mii_tx_frames={int(dut.mii_tx_frames.value)} "
                f"(expected 0 -- no frame driven yet)")

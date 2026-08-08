"""B-channel (0x82) a2l replay-FIFO CDC REPRODUCE — the data-plane analogue of
test_a2l_replay_cdc (which drives the _13 TideLink-sideband node).

DUT: WlinkGenericFCReplayV2_5 (14-bit data / 4-bit ptr / depth-8), standalone in
tb_top_5.sv. This answers the TL-027 CONTESTED question: does the ACK-lap-ahead
false-FULL self-latch (proven on the _13 sideband node) also reproduce on the B
WRITE-RESPONSE data-plane node? The a2l CDC self-latch theory is "plausible-not-
proven" for the data-plane nodes; this is the sim that settles it, and it
de-risks the (David-gated, netlist-affecting) TL-027 CDC-self-heal port BEFORE it
is bet on.

Geometry vs _13: depth-8 => a2l_full = a2l_app_addr[3]!=ack[3] & [2:0]==[2:0], and
the lap-ahead ACK value is 9 (0b1001) not 17 (0b10001).

Contract (reproduce-first A/B):
  USE_DEPS_DUT=1 (pristine deps _5)                 -> a2l_full=1 on the first write
                                                       => this test FAILS = BUG REPRODUCED.
  local_overrides/WlinkGenericFCReplayV2_5.v (fix)  -> a2l_full=0 => PASS = self-heal.
If deps _5 does NOT reproduce (a2l_full stays 0), that is the important NEGATIVE
result: the B node lacks the self-latch, so the TL-027 port is not its cure.
"""
import cocotb
from cocotb.triggers import RisingEdge
from test_a2l_replay_cdc import (
    start_clocks, reset_with_skew, probe, link_ack, _sigint, USE_DEPS_DUT)

LAP_AHEAD = 9   # depth-8: one lap (8) + 1  ->  a2l_full when wptr=1 (0b0001), ack=0b1001


@cocotb.test()
async def test_b_node_predata_ack_lap_ahead(dut):
    """A pre-data ACK a full lap ahead (=9) must NOT leave the first B-node app
    write false-FULL. Mirrors test_phase1_predata_ack_lap_ahead on the B node."""
    src = "deps(pristine)" if USE_DEPS_DUT else "local_override"
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    st = probe(dut)
    assert st["wbin_ptr"] == 0 and st["app_ready"] == 1, f"[_5] idle not clean: {st}"
    dut._log.info("[_5 %s] pre-ACK idle: %s", src, st)

    # spurious pre-data ACK acknowledging addr 1 of the NEXT lap (=9)
    await link_ack(dut, LAP_AHEAD, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break
    ack = _sigint(dut.dut.a2l_link_addr_app_clk)
    st = probe(dut)
    dut._log.info("[_5 %s] after spurious ACK(%d): synced_ack=%d (0b%s) wbin_ptr=%d a2l_full=%d app_ready=%d",
                  src, LAP_AHEAD, ack, format(ack & 0xf, "04b") if ack >= 0 else "X",
                  st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    # first app write (14-bit datum) — must be accepted (wbin_ptr 0->1, not full)
    dut.app_data.value  = 0x2DEA
    dut.app_valid.value = 1
    for _ in range(8):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.fifo_io_wbin_ptr) == 1:
            break
    dut.app_valid.value = 0
    await RisingEdge(dut.app_clk)

    wp   = _sigint(dut.dut.fifo_io_wbin_ptr)
    full = _sigint(dut.dut.a2l_full)
    rdy  = _sigint(dut.dut.app_ready)
    dut._log.info("[_5 %s] after first write: wbin_ptr=%d a2l_full=%d app_ready=%d", src, wp, full, rdy)

    assert full == 0 and rdy == 1, (
        f"B-node a2l false-FULL self-latch REPRODUCED ({src}): after a lap-ahead ACK({LAP_AHEAD}) "
        f"the first write sees a2l_full={full} app_ready={rdy} wbin_ptr={wp} -- winc never fires, "
        f"the B FCSM would never transmit. Pristine deps _5 => the TL-027 CDC self-latch is REAL "
        f"on the data-plane B node; the fixed override must make this PASS.")

"""W-channel (0x81) a2l replay-FIFO CDC REPRODUCE — data-plane analogue of
test_a2l_replay_cdc_5 for the W (write-data) node WlinkGenericFCReplayV2_3
(37-bit data / 6-bit ptr / depth-32).

Same reproduce-first A/B as _5 (settles the TL-027 contested question on the W
node too). Geometry: depth-32 => a2l_full = a2l_app_addr[5]!=ack[5] & [4:0]==[4:0],
and the lap-ahead ACK value is 33 (0b100001) not 9 (_5) or 17 (_13).

  USE_DEPS_DUT=1 (pristine deps _3)                 -> a2l_full=1 on the first write => FAIL (bug).
  local_overrides/WlinkGenericFCReplayV2_3.v (fix)  -> a2l_full=0 => PASS (self-heal).
"""
import cocotb
from cocotb.triggers import RisingEdge
from test_a2l_replay_cdc import (
    start_clocks, reset_with_skew, probe, link_ack, _sigint, USE_DEPS_DUT,
    run_revert_recovery)

LAP_AHEAD = 33   # depth-32: one lap (32) + 1  ->  a2l_full when wptr=1, ack=0b100001


@cocotb.test()
async def test_w_node_predata_ack_lap_ahead(dut):
    """A pre-data ACK a full lap ahead (=33) must NOT leave the first W-node app
    write false-FULL. Mirrors the _5 / _13 lap-ahead reproduce on the W node."""
    src = "deps(pristine)" if USE_DEPS_DUT else "local_override"
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    st = probe(dut)
    assert st["wbin_ptr"] == 0 and st["app_ready"] == 1, f"[_3] idle not clean: {st}"
    dut._log.info("[_3 %s] pre-ACK idle: %s", src, st)

    await link_ack(dut, LAP_AHEAD, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break
    ack = _sigint(dut.dut.a2l_link_addr_app_clk)
    st = probe(dut)
    dut._log.info("[_3 %s] after spurious ACK(%d): synced_ack=%d (0b%s) wbin_ptr=%d a2l_full=%d app_ready=%d",
                  src, LAP_AHEAD, ack, format(ack & 0x3f, "06b") if ack >= 0 else "X",
                  st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    dut.app_data.value  = 0x1_DEAD_BEEF & 0x1F_FFFF_FFFF   # 37-bit datum
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
    dut._log.info("[_3 %s] after first write: wbin_ptr=%d a2l_full=%d app_ready=%d", src, wp, full, rdy)

    assert full == 0 and rdy == 1, (
        f"W-node a2l false-FULL self-latch REPRODUCED ({src}): after a lap-ahead ACK({LAP_AHEAD}) "
        f"the first write sees a2l_full={full} app_ready={rdy} wbin_ptr={wp} -- winc never fires, "
        f"the W FCSM would never transmit. Pristine deps _3 => the TL-027 CDC self-latch is REAL "
        f"on the data-plane W node; the fixed override must make this PASS.")


@cocotb.test()
async def test_w_node_revert_recovery_ack_accepted(dut):
    """TL-032 residual R1 (W node, 6-bit ptr / depth-32 / window 6'h20): a mid-stream
    link_revert that rewinds rbin below the ACK ptr must not lock the guard out of
    accepting recovery ACKs. deps FAIL (guard not revert-aware), override PASS."""
    await run_revert_recovery(dut, "_3", ptr_mask=0x3F, window=32)

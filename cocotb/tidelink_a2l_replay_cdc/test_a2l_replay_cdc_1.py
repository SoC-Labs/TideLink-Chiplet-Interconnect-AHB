"""AW-channel (0x80) a2l replay-FIFO CDC REPRODUCE — data-plane analogue of
test_a2l_replay_cdc_5 for the AW (write-address) node WlinkGenericFCReplayV2_1
(101-bit data / 4-bit ptr / depth-8).

Same reproduce-first A/B as _5/_3 (completes the AW/W/B data-plane trio). depth-8
=> a2l_full = a2l_app_addr[3]!=ack[3] & [2:0]==[2:0], lap-ahead ACK = 9 (as _5).

  USE_DEPS_DUT=1 (pristine deps _1)                 -> a2l_full=1 on the first write => FAIL (bug).
  local_overrides/WlinkGenericFCReplayV2_1.v (fix)  -> a2l_full=0 => PASS (self-heal).
"""
import cocotb
from cocotb.triggers import RisingEdge
from test_a2l_replay_cdc import (
    start_clocks, reset_with_skew, probe, link_ack, _sigint, USE_DEPS_DUT)

LAP_AHEAD = 9   # depth-8: one lap (8) + 1


@cocotb.test()
async def test_aw_node_predata_ack_lap_ahead(dut):
    """A pre-data ACK a full lap ahead (=9) must NOT leave the first AW-node app
    write false-FULL. Mirrors the _5 / _3 lap-ahead reproduce on the AW node."""
    src = "deps(pristine)" if USE_DEPS_DUT else "local_override"
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    st = probe(dut)
    assert st["wbin_ptr"] == 0 and st["app_ready"] == 1, f"[_1] idle not clean: {st}"
    dut._log.info("[_1 %s] pre-ACK idle: %s", src, st)

    await link_ack(dut, LAP_AHEAD, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break
    ack = _sigint(dut.dut.a2l_link_addr_app_clk)
    st = probe(dut)
    dut._log.info("[_1 %s] after spurious ACK(%d): synced_ack=%d (0b%s) wbin_ptr=%d a2l_full=%d app_ready=%d",
                  src, LAP_AHEAD, ack, format(ack & 0xf, "04b") if ack >= 0 else "X",
                  st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    dut.app_data.value  = 0x1_DEAD_BEEF   # 101-bit datum (low bits set)
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
    dut._log.info("[_1 %s] after first write: wbin_ptr=%d a2l_full=%d app_ready=%d", src, wp, full, rdy)

    assert full == 0 and rdy == 1, (
        f"AW-node a2l false-FULL self-latch REPRODUCED ({src}): after a lap-ahead ACK({LAP_AHEAD}) "
        f"the first write sees a2l_full={full} app_ready={rdy} wbin_ptr={wp} -- winc never fires, "
        f"the AW FCSM would never transmit. Pristine deps _1 => the TL-027 CDC self-latch is REAL "
        f"on the data-plane AW node; the fixed override must make this PASS.")

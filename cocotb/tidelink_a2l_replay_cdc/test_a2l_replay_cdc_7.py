"""AR-channel (0x83) a2l replay-FIFO CDC REPRODUCE — the READ-path analogue of
test_a2l_replay_cdc_1 for the AR (read-address) node WlinkGenericFCReplayV2_7
(101-bit data / 4-bit ptr / depth-8 — geometry IDENTICAL to the AW node _1).

TL-043-ARR. THIS TEST IS EXPECTED TO FAIL TODAY, AND THAT IS THE POINT.

Unlike _1/_3/_5 (AW/W/B) and _12/_13 (sideband), there is NO
src/rtl/local_overrides/WlinkGenericFCReplayV2_7.v -- the file does not exist.
The bench Makefile selects "local override if present, else deps", so this env
compiles the RAW deps node, which is also exactly what the tapeout flist ships
(flists/tidelink_top_full_asic_v2.flist takes _7 and _9 from deps/).

So a FAIL here is not a broken test; it is the shipping read path reproducing
the TL-027 CDC self-latch that the write path was hardened against on 2026-08-08
and the read path never was.

  deps _7 (what ships, and what this compiles):
      assign link_addr_to_app_clk_w_inc = a2l_link_addr != a2l_link_addr_in;
    Edge-triggered. A torn value delivered through WavMultibitSync that is not
    followed by a further change never re-fires the edge -> the synced ACK ptr
    latches -> a2l_full sticks -> app_ready=0 -> the AR FCSM stops transmitting.

  local_overrides _1 (the hardened form, for contrast):
      assign link_addr_to_app_clk_w_inc = 1'b1;   // TL-027 continuous resend
    Self-heals within one mailbox round trip.

Silicon correlate on freeze 5e8bdb5a (v0.90): writes 6/6 runs 128/128 byte-exact
vs cross-die reads 2 PASS / 4 FAIL. The pass/fail split follows the
hardened/raw split exactly. Three distinct read failure signatures were observed,
so this explains a CLASS of read failure, not necessarily all of it -- reads are
also eye-sensitive, and the ASIC runs the same GPIO PHY at ~4x the FPGA rate.

⚠ THE REVERT TEST BELOW PASSES VACUOUSLY ON deps, AND MUST NOT BE READ AS HEALTH.
It checks that the TL-027 ACK-window guard is revert-aware, i.e. that a rewind
does not lock the guard out of accepting recovery ACKs. deps _7 contains ZERO
references to a2l_ack_valid -- there is no guard at all -- so there is nothing
to lock out and it passes for the wrong reason. Measured: deps _7
a2l_ack_valid = 0, hardened local_overrides _1 = 7.

So "TESTS=2 PASS=1 FAIL=1" on the shipping source means ONE real reproduce and
ONE vacuous pass, NOT partial health. The revert test only becomes meaningful
once an override exists; at that point it is the TL-032 check, and it should be
re-run with USE_PREFIX_DUT=1 to be non-vacuous.

Expected results:
  today (no override -> deps)        -> FAIL   (the gap, reproduced)
  once an override _7 is written     -> PASS   (self-heal)
  USE_DEPS_DUT=1, after the override -> FAIL   (non-vacuity control)
"""
import cocotb
from cocotb.triggers import RisingEdge
from test_a2l_replay_cdc import (
    start_clocks, reset_with_skew, probe, link_ack, _sigint, USE_DEPS_DUT,
    run_revert_recovery)

LAP_AHEAD = 9   # depth-8: one lap (8) + 1 — same as _1 / _5


@cocotb.test()
async def test_ar_node_predata_ack_lap_ahead(dut):
    """A pre-data ACK a full lap ahead (=9) must NOT leave the first AR-node app
    write false-FULL. Identical stimulus to the _1 AW reproduce; the AR node has
    the same 101/4/depth-8 geometry and differs only in its RAM instance."""
    src = "deps(pristine)" if USE_DEPS_DUT else "auto(deps: NO _7 override exists)"
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    st = probe(dut)
    assert st["wbin_ptr"] == 0 and st["app_ready"] == 1, f"[_7] idle not clean: {st}"
    dut._log.info("[_7 %s] pre-ACK idle: %s", src, st)

    await link_ack(dut, LAP_AHEAD, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break
    ack = _sigint(dut.dut.a2l_link_addr_app_clk)
    st = probe(dut)
    dut._log.info("[_7 %s] after spurious ACK(%d): synced_ack=%d (0b%s) wbin_ptr=%d a2l_full=%d app_ready=%d",
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
    dut._log.info("[_7 %s] after first write: wbin_ptr=%d a2l_full=%d app_ready=%d", src, wp, full, rdy)

    assert full == 0 and rdy == 1, (
        f"AR-node a2l false-FULL self-latch REPRODUCED ({src}): after a lap-ahead ACK({LAP_AHEAD}) "
        f"the first write sees a2l_full={full} app_ready={rdy} wbin_ptr={wp} -- w_inc never re-fires, "
        f"so the AR FCSM would never transmit. This is TL-043-ARR: the READ path ships from deps/ "
        f"WITHOUT the TL-027 self-heal that _1/_3/_5 carry, and this is the shipping configuration.")


@cocotb.test()
async def test_ar_node_revert_recovery_ack_accepted(dut):
    """VACUOUS ON deps (no window guard exists) — see module docstring.

    TL-032 residual R1 on the AR node (4-bit ptr / depth-8 / window 4'h8): a
    mid-stream link_revert that rewinds rbin below the ACK ptr must not lock the
    guard out of accepting recovery ACKs. deps has no window guard at all."""
    await run_revert_recovery(dut, "_7", ptr_mask=0xF, window=8)

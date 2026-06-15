"""V2 SYNC-insert ENABLE=1 on-wire proof (DEFAULT-OFF feature).

The companion to the zero-regression gates: those prove the feature is
bit-identical with the APB enable at its DEFAULT 0. THIS test proves the
feature actually WORKS end-to-end when SW opts in:

  * Bring the V2 pair up (POR -> role_lock -> autocal -> data mode).
  * Write the APB SWI_SYNC_INSERT_EN bit (Region 8 slot 0 bit[2],
    SoC 0x4403_2100, unified-view APB_R8_SLOT0=0x2100) = 1 on the MASTER.
  * During genuine inter-packet idle (io_link_tx_tx_idle=1, no payload), the
    master PHY's tidelink_phy_sync_insert must periodically (every
    TIDELINK_SYNC_PERIOD=32 link words) override ONE TX word with the
    cross-lane SYNC_WORD and pulse sync_inserting_o.
  * The peer (slave) RX deskew's SYNC matcher must SEE that beacon word on the
    aligned link bus (Wlink RX framer re-hunt beacon — the agreed silicon fix).

This can't be shown to FIX delivery in sim (back-to-back delivery already
passes in sim — see test_v2_pair_b2b), so this is a presence/observability
proof of the TX beacon + RX detection, NOT a before/after delivery test.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_sync_insert_en
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (PairV2TB, run_bringup_full, APB_R8_SLOT0,
                            APB_TIDELINK_BASE)

# Mirror of deps/tidelink-phy/rtl/tidelink_sync_word.svh.
SYNC_WORD = 0xF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00
SYNC_PERIOD = 32

# Region 8 slot 0 (APB_R8_SLOT0): bit[0]=train, bit[1]=recal, bit[2]=SYNC_EN,
# bit[3]=SYNC_FORCE_ALWAYS (PART 2 gate fix).
R8_SLOT0_SYNC_EN           = 0x4
R8_SLOT0_SYNC_FORCE_ALWAYS = 0x8

# SoC Labs SYNC-insert obs (PART 1): the new SYNC-OBS register lives at SoC MMIO
# 0x4403_2120 (unified APB view 0x2120 = Region 9 slot 0). Layout:
#   [15:0]=tx_sync_ins_cnt (saturating), [16]=tx_link_idle_level,
#   [17]=tx_training_level, [31:24]=0x5C marker.
APB_SYNC_OBS = APB_TIDELINK_BASE + 0x120          # 0x2120
SYNC_OBS_CNT    = lambda v: v & 0xFFFF
SYNC_OBS_IDLE   = lambda v: (v >> 16) & 1
SYNC_OBS_TRAIN  = lambda v: (v >> 17) & 1
SYNC_OBS_MARKER = lambda v: (v >> 24) & 0xFF

# SYNC_DETECTED_COUNTER (Region 8 slot 5, SoC 0x4403_2114): RX-side count of
# coherent SYNC words reassembled on the aligned link bus, bits[31:16].
APB_SYNC_DETECTED = APB_TIDELINK_BASE + 0x114     # 0x2114
SYNC_DET_CNT      = lambda v: (v >> 16) & 0xFFFF


def _sync_insert(tb, side):
    """Hierarchical handle to the per-die TX SYNC inserter inside the PHY."""
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio.u_tx_sync_insert


@cocotb.test()
async def test_sync_beacon_on_tx_when_enabled(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)

    ins = _sync_insert(tb, "m")

    # Default-off sanity: with the APB bit still 0, the inserter must NEVER fire.
    saw_default_off = 0
    for _ in range(SYNC_PERIOD * 4):
        await ClockCycles(ins.clk, 1)
        if ins.sync_inserting_o.value == 1:
            saw_default_off += 1
    assert saw_default_off == 0, \
        f"sync_inserting_o pulsed {saw_default_off}x with APB enable=0 (must be 0)"
    tb.log.info("DEFAULT-OFF confirmed: no SYNC insertion with APB enable=0")

    # Opt in: write SWI_SYNC_INSERT_EN (Region 8 slot 0 bit[2]) on the master.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN)
    rb = await tb.m_apb.read(APB_R8_SLOT0)
    assert (rb >> 2) & 1 == 1, f"SWI_SYNC_INSERT_EN readback={rb:#x}, bit[2] not set"
    tb.log.info(f"SWI_SYNC_INSERT_EN written + read back (0x{rb:08x})")

    # Watch for the beacon on the TX link bus. The inserter only fires in
    # genuine idle (io_link_tx_tx_idle) and ~training; after data-mode bringup
    # the link sits idle, so within a few SYNC_PERIODs we must see one.
    saw_beacon = False
    word_on_insert = None
    for _ in range(SYNC_PERIOD * 8):
        await RisingEdge(ins.clk)
        if ins.sync_inserting_o.value == 1:
            word_on_insert = int(ins.data_o.value)
            saw_beacon = True
            break

    assert saw_beacon, ("sync_inserting_o never pulsed within 8 SYNC_PERIODs "
                        "after enabling SWI_SYNC_INSERT_EN")
    assert word_on_insert == SYNC_WORD, \
        (f"TX word on sync_inserting_o = 0x{word_on_insert:032x}, "
         f"expected SYNC_WORD 0x{SYNC_WORD:032x}")
    tb.log.info(f"SYNC beacon on master TX bus: data_o=0x{word_on_insert:032x} "
                f"with sync_inserting_o=1 (matches SYNC_WORD)")

    # Confirm it is PERIODIC: the next beacon should land ~SYNC_PERIOD words on.
    gap = 0
    saw_second = False
    for _ in range(SYNC_PERIOD * 4):
        await RisingEdge(ins.clk)
        gap += 1
        if ins.sync_inserting_o.value == 1:
            saw_second = True
            break
    assert saw_second, "second SYNC beacon not observed (insertion not periodic)"
    tb.log.info(f"second SYNC beacon after {gap} link words "
                f"(SYNC_PERIOD={SYNC_PERIOD}) -> periodic insertion confirmed")


@cocotb.test()
async def test_sync_force_always_end_to_end(dut):
    """BONUS (2026-06-15): force_always=1 end-to-end SYNC works in sim.

    Proves the PART 1 observability + PART 2 gate fix together:
      * APB SYNC-OBS register (SoC 0x4403_2120) reads 0 count + 0x5C marker at
        default (sync_insert_en=0, force_always=0).
      * Writing SWI_SYNC_INSERT_EN | SWI_SYNC_FORCE_ALWAYS (Region 8 slot 0
        bits[2,3]) on the MASTER makes the PHY insert SYNC beacons regardless of
        the (sparse) io_link_tx_tx_idle gate — the silicon bring-up blocker the
        gate fix targets.
      * The TX-side SYNC-insert SATURATING counter (PART 1) climbs, observed both
        hierarchically (tx_sync_ins_cnt_q) AND through the new APB SYNC-OBS reg.
      * The peer (slave) RX SYNC-detect count (SoC 0x4403_2114 [31:16]) climbs —
        the beacon is reassembled coherently on the aligned RX link bus
        (end-to-end SYNC works in sim with force_always).
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)

    gpio_m = tb.top("m").u_chiplet_controller.u_wlink.phy.gpio

    # --- default-off observability: count 0, marker present ------------------
    obs0 = await tb.m_apb.read(APB_SYNC_OBS)
    assert SYNC_OBS_MARKER(obs0) == 0x5C, \
        f"SYNC-OBS marker = 0x{SYNC_OBS_MARKER(obs0):02x}, expected 0x5C (reg not live)"
    assert SYNC_OBS_CNT(obs0) == 0, \
        f"SYNC-OBS count = {SYNC_OBS_CNT(obs0)} at default (must be 0 — no insertion yet)"
    tb.log.info(f"DEFAULT-OFF SYNC-OBS @0x2120 = 0x{obs0:08x} "
                f"(marker=0x{SYNC_OBS_MARKER(obs0):02x} cnt=0)")

    rx_det_before = SYNC_DET_CNT(await tb.s_apb.read(APB_SYNC_DETECTED))

    # --- opt in: enable + force_always on the master ------------------------
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_SYNC_FORCE_ALWAYS)
    rb = await tb.m_apb.read(APB_R8_SLOT0)
    assert (rb >> 2) & 1 == 1, f"SWI_SYNC_INSERT_EN not set (readback 0x{rb:x})"
    assert (rb >> 3) & 1 == 1, f"SWI_SYNC_FORCE_ALWAYS not set (readback 0x{rb:x})"
    tb.log.info(f"enabled SYNC_EN + SYNC_FORCE_ALWAYS (R8_SLOT0 readback 0x{rb:08x})")

    # Let the inserter run; the force_always gate fires the beacon on enable
    # alone (still self-gates ~training, which is released after bring-up).
    await ClockCycles(dut.hclk, 8000)

    # --- TX counter climbed (hierarchical + APB) ----------------------------
    tx_cnt_hier = int(gpio_m.tx_sync_ins_cnt_q.value)
    assert tx_cnt_hier > 0, \
        "tx_sync_ins_cnt_q did not increment with force_always=1 (PHY not inserting)"

    obs1 = await tb.m_apb.read(APB_SYNC_OBS)
    assert SYNC_OBS_CNT(obs1) > 0, \
        f"APB SYNC-OBS count still 0 (0x{obs1:08x}) — obs/CDC path broken"
    tb.log.info(f"TX inserting: tx_sync_ins_cnt_q(hier)={tx_cnt_hier}, "
                f"APB SYNC-OBS @0x2120 = 0x{obs1:08x} (cnt={SYNC_OBS_CNT(obs1)}, "
                f"idle={SYNC_OBS_IDLE(obs1)}, train={SYNC_OBS_TRAIN(obs1)})")

    # --- RX SYNC-detect climbed at the peer ---------------------------------
    rx_det_after = SYNC_DET_CNT(await tb.s_apb.read(APB_SYNC_DETECTED))
    assert rx_det_after > rx_det_before, \
        (f"peer RX SYNC-detect count did not climb "
         f"(before={rx_det_before}, after={rx_det_after}) — beacon not reassembled")
    tb.log.info(f"RX SYNC-detect (slave @0x2114): {rx_det_before} -> {rx_det_after} "
                f"-> end-to-end SYNC works in sim with force_always=1")

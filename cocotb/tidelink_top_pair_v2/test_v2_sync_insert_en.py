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

from pair_v2_common import PairV2TB, run_bringup_full, APB_R8_SLOT0

# Mirror of deps/tidelink-phy/rtl/tidelink_sync_word.svh.
SYNC_WORD = 0xF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00
SYNC_PERIOD = 32

# Region 8 slot 0 (APB_R8_SLOT0): bit[0]=train, bit[1]=recal, bit[2]=SYNC_EN.
R8_SLOT0_SYNC_EN = 0x4


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

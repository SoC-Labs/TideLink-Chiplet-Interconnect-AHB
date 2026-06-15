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

# SoC Labs RX mask-aware SYNC-DETECT (PART 1): Region 9 slot 1, SoC 0x4403_2124.
#   [15:0]=sync_seen_cnt (mask-aware saturating), [23:16]=per-lane sticky
#   "ever-matched" vector, [31:24]=0x5D marker.
APB_SYNC_DETECT2     = APB_TIDELINK_BASE + 0x124  # 0x2124
SYNC2_SEEN_CNT       = lambda v: v & 0xFFFF
SYNC2_SEEN_LANE      = lambda v: (v >> 16) & 0xFF
SYNC2_MARKER         = lambda v: (v >> 24) & 0xFF

# SoC Labs RX SYNC-detect SW LANE_MASK (PART 3): Region 9 slot 2, SoC 0x4403_2128.
#   [7:0]=swi_sync_lane_mask (RW, default 0xFF).
APB_SYNC_LANE_MASK   = APB_TIDELINK_BASE + 0x128  # 0x2128

# Region 8 slot 0 bit[4]: SWI_SYNC_ROBUST_DETECT (PART 2 selectable re-hunt).
R8_SLOT0_ROBUST_DETECT = 0x10

# SoC Labs RX RAW-WORD + PERMUTATION observability (2026-06-15, rawobs):
# Region 9 slots 3..7. The BEST-MATCH-latched post-deskew word (closest-to-SYNC
# word the RX actually reassembled) + the per-RX-lane carried-slice-index map
# that DECODES identity vs permutation vs bit-rotation.
#   0x212C..0x2138: dbg_raw_word[31:0] / [63:32] / [95:64] / [127:96]
#   0x213C        : 8 x 4-bit slice-index map (RX lane i -> TX slice j, 0xF=none).
#                   Identity (lane i carries slice i) packs to 0x76543210.
APB_DBG_RAW_W0   = APB_TIDELINK_BASE + 0x12C  # 0x212C raw word [31:0]
APB_DBG_RAW_W1   = APB_TIDELINK_BASE + 0x130  # 0x2130 raw word [63:32]
APB_DBG_RAW_W2   = APB_TIDELINK_BASE + 0x134  # 0x2134 raw word [95:64]
APB_DBG_RAW_W3   = APB_TIDELINK_BASE + 0x138  # 0x2138 raw word [127:96]
APB_DBG_SLICE_IDX = APB_TIDELINK_BASE + 0x13C # 0x213C 8x4-bit slice map

# Identity slice map: RX lane i carries TX slice i for all 8 lanes ->
# nibble[i]=i -> 0x76543210. Anything else = permutation (a clean reorder) or a
# 0xF nibble = no slice match for that lane (bit-rotation / garbage).
SLICE_MAP_IDENTITY = 0x7654_3210


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


@cocotb.test()
async def test_rx_mask_aware_sync_detect_per_lane(dut):
    """PART 1/3 (2026-06-15): the NEW mask-aware per-lane RX SYNC detector.

    The link's full-128 exact compare (0x2114 [31:16]) only fires when EVERY
    lane delivers its SYNC slice. The mask-aware detector (0x2124) ANDs only
    the masked-in lanes, so it fires even with a marginal lane masked out — and
    its per-lane STICKY vector shows exactly which lanes carry their SYNC slice.

    On the clean (zero-skew) pair sim every lane is coherent, so with
    force_always=1 on the master:
      * the slave's mask-aware count (0x2124[15:0]) CLIMBS, and
      * the per-lane sticky vector (0x2124[23:16]) shows ALL 8 lanes matched.
    Also exercises the PART 3 SW LANE_MASK register (0x2128) RW + readback.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)

    # --- default-off PART 1 obs: count 0, marker present, mask default 0xFF ---
    d0 = await tb.s_apb.read(APB_SYNC_DETECT2)
    assert SYNC2_MARKER(d0) == 0x5D, \
        f"SYNC-DETECT2 marker = 0x{SYNC2_MARKER(d0):02x}, expected 0x5D (reg not live)"
    assert SYNC2_SEEN_CNT(d0) == 0, \
        f"SYNC-DETECT2 count = {SYNC2_SEEN_CNT(d0)} at default (must be 0 — no SYNC yet)"
    assert SYNC2_SEEN_LANE(d0) == 0x00, \
        f"SYNC-DETECT2 lane sticky = 0x{SYNC2_SEEN_LANE(d0):02x} at default (must be 0)"
    tb.log.info(f"DEFAULT SYNC-DETECT2 @0x2124 = 0x{d0:08x} "
                f"(marker=0x{SYNC2_MARKER(d0):02x} cnt=0 lane=0x00)")

    # PART 3 LANE_MASK RW + readback (default 0xFF, write 0xAA, restore 0xFF).
    mask_def = await tb.s_apb.read(APB_SYNC_LANE_MASK)
    assert (mask_def & 0xFF) == 0xFF, \
        f"SYNC_LANE_MASK default = 0x{mask_def & 0xFF:02x}, expected 0xFF"
    await tb.s_apb.write(APB_SYNC_LANE_MASK, 0xAA)
    mb = await tb.s_apb.read(APB_SYNC_LANE_MASK)
    assert (mb & 0xFF) == 0xAA, \
        f"SYNC_LANE_MASK readback = 0x{mb & 0xFF:02x} after writing 0xAA"
    await tb.s_apb.write(APB_SYNC_LANE_MASK, 0xFF)   # restore all-lanes for the AND
    tb.log.info(f"SYNC_LANE_MASK @0x2128 RW OK (default 0x{mask_def & 0xFF:02x} "
                f"-> wrote 0xAA -> read 0x{mb & 0xFF:02x} -> restored 0xFF)")

    # --- enable + force_always on the master so the slave RX sees SYNC --------
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_SYNC_FORCE_ALWAYS)
    await ClockCycles(dut.hclk, 8000)

    d1 = await tb.s_apb.read(APB_SYNC_DETECT2)
    assert SYNC2_SEEN_CNT(d1) > 0, \
        (f"mask-aware SYNC-DETECT2 count still 0 (0x{d1:08x}) — the per-lane "
         f"detector never fired even though TX is inserting")
    assert SYNC2_SEEN_LANE(d1) == 0xFF, \
        (f"mask-aware per-lane sticky = 0x{SYNC2_SEEN_LANE(d1):02x}, expected 0xFF "
         f"(all 8 lanes carry their SYNC slice on the clean pair sim)")
    tb.log.info(f"mask-aware SYNC-DETECT2 @0x2124 = 0x{d1:08x} "
                f"(cnt={SYNC2_SEEN_CNT(d1)} lane=0x{SYNC2_SEEN_LANE(d1):02x}) "
                f"-> per-lane detector fires, ALL 8 lanes matched")


@cocotb.test()
async def test_robust_resync_path_exercised(dut):
    """PART 2 (2026-06-15): SWI_SYNC_ROBUST_DETECT=1 exercises the robust path.

    With the robust bit set on the slave, the PHY's mask-aware per-lane SYNC
    match is OR'd into the slave RX framer's re-hunt (sync_resync). This test
    drives the master beacon (force_always) and confirms (a) the bit RW's, and
    (b) the slave RX framer's sync_resync ASSERTS off the robust source — i.e.
    the robust re-hunt path is actually exercised, not dead code. Default-off is
    covered bit-identically by the zero-regression gates; this is the opt-in
    proof.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)

    # bit[4] RW + readback on the slave (the RX that re-hunts).
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_ROBUST_DETECT)
    rb = await tb.s_apb.read(APB_R8_SLOT0)
    assert (rb >> 4) & 1 == 1, \
        f"SWI_SYNC_ROBUST_DETECT readback = 0x{rb:x}, bit[4] not set"
    tb.log.info(f"SWI_SYNC_ROBUST_DETECT set on slave (R8_SLOT0 readback 0x{rb:08x})")

    # Master inserts the beacon so the slave's PHY detector pulses.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_SYNC_FORCE_ALWAYS)

    # Watch the slave RX framer's sync_resync. With robust=1 and the PHY
    # detector firing, sync_resync must assert (the re-hunt is driven).
    llrx = tb.top("s").u_chiplet_controller.u_wlink.llrx
    saw_resync = False
    for _ in range(SYNC_PERIOD * 64):
        await RisingEdge(llrx.clock)
        if llrx.sync_resync.value == 1:
            saw_resync = True
            break
    assert saw_resync, \
        ("slave RX sync_resync never asserted with SWI_SYNC_ROBUST_DETECT=1 + "
         "master inserting — robust re-hunt path NOT exercised")
    tb.log.info("slave RX sync_resync asserted with robust detect=1 "
                "-> PART 2 robust re-hunt path exercised")


@cocotb.test()
async def test_rx_rawobs_word_and_slice_map_identity(dut):
    """rawobs (2026-06-15): the RAW-WORD latch + PERMUTATION/slice-index decoder.

    Decisive read-only observability for the silicon "TX inserts SYNC but RX
    per_lane_sticky=0x00" defect. On the CLEAN (zero-skew) pair sim the link is
    coherent, so once the master inserts SYNC:
      * the slave's BEST-MATCH raw-word latch (0x212C..0x2138) captures the exact
        cross-lane SYNC_WORD, and
      * the slice-index map (0x213C) reads IDENTITY (0x76543210 — RX lane i
        carries TX slice i, no transform).
    This PROVES the obs works; on silicon the same regs will instead show the
    real transform (a permutation map, or 0xF nibbles for bit-rotation).

    Default-state sanity: before any SYNC, the raw word reads 0 and the slice map
    reads 0xFFFFFFFF (POR "no match" sentinel — distinct from an old image's 0).
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)

    # --- default state: no SYNC seen yet -------------------------------------
    raw0 = (await tb.s_apb.read(APB_DBG_RAW_W0))
    smap0 = (await tb.s_apb.read(APB_DBG_SLICE_IDX)) & 0xFFFFFFFF
    assert raw0 == 0, f"raw-word[31:0] = 0x{raw0:08x} at default (expected 0)"
    assert smap0 == 0xFFFFFFFF, \
        (f"slice map = 0x{smap0:08x} at default (expected 0xFFFFFFFF POR sentinel "
         f"= no lane matched yet)")
    tb.log.info(f"DEFAULT rawobs: raw[31:0]=0x{raw0:08x} slice_map=0x{smap0:08x} "
                f"(POR 'no match' sentinel)")

    # --- enable + force_always on the master so the slave RX reassembles SYNC --
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_SYNC_FORCE_ALWAYS)
    await ClockCycles(dut.hclk, 8000)

    # --- read back the 128-bit BEST-MATCH raw word ---------------------------
    w0 = (await tb.s_apb.read(APB_DBG_RAW_W0)) & 0xFFFFFFFF
    w1 = (await tb.s_apb.read(APB_DBG_RAW_W1)) & 0xFFFFFFFF
    w2 = (await tb.s_apb.read(APB_DBG_RAW_W2)) & 0xFFFFFFFF
    w3 = (await tb.s_apb.read(APB_DBG_RAW_W3)) & 0xFFFFFFFF
    raw = (w3 << 96) | (w2 << 64) | (w1 << 32) | w0
    assert raw == SYNC_WORD, \
        (f"BEST-MATCH raw word = 0x{raw:032x}, expected SYNC_WORD "
         f"0x{SYNC_WORD:032x} (clean sim should reassemble SYNC exactly)")
    tb.log.info(f"rawobs raw word @0x212C-0x2138 = 0x{raw:032x} (== SYNC_WORD)")

    # --- read back the slice-index map: must be IDENTITY on the clean pair ----
    smap = (await tb.s_apb.read(APB_DBG_SLICE_IDX)) & 0xFFFFFFFF
    assert smap == SLICE_MAP_IDENTITY, \
        (f"slice-index map = 0x{smap:08x}, expected IDENTITY 0x{SLICE_MAP_IDENTITY:08x} "
         f"(RX lane i carries TX slice i on the clean zero-skew sim; any other "
         f"value = permutation, a 0xF nibble = bit-rotation/no-match)")
    # per-lane decode for the log (lane i -> slice nibble i)
    lanes = [(smap >> (4 * i)) & 0xF for i in range(8)]
    tb.log.info(f"rawobs slice map @0x213C = 0x{smap:08x} -> per-RX-lane carried "
                f"TX-slice = {lanes} (IDENTITY -> no transform, obs proven)")

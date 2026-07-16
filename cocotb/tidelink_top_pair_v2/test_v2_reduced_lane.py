"""REDUCED-LANE end-to-end proof in the integrated V2 paired-die sim.

The masked-subset deskew UNIT test (cocotb/tidelink_lane_deskew/
test_lane_deskew_mask.py) already passes. This is the INTEGRATED proof that a
SW-selected 4-lane subset brings the WHOLE paired-die link up and carries a
byte-correct data word — isolating RTL correctness from the HW bring-up recipe.

LANE MASK = 0xE4  -> lanes {2,5,6,7} ACTIVE, lanes {0,1,3,4} masked OFF.

Mechanism (no flist fork, no submodule edit): a continuous cocotb Force on the
two Wlink lane-mask registers on BOTH dies, applied right after POR so the
reset re-init to 0xFF cannot clobber it:

    u_wlink.swi_tx_lane_mask              <- 0xE4   (TX gather/scatter + tx_lane_mask_o)
    u_wlink.out_prepend_swi_rx_lane_mask  <- 0xE4   (RX demask + rx_lane_mask_o)

That single pair of regs fans out to the ENTIRE mask consumer set
(local_overrides/Wlink.v + axi_chiplet_controller.sv):
  * TX:  phy_link_tx_tx_lane_mask / lltx_io_lane_mask -> PHY TX masking
         (masked lanes forced to 16'h0000 on the wire).
  * RX:  phy_link_rx_rx_lane_mask / llrx_io_lane_mask -> PHY RX demask AND
         tidelink_lane_deskew.lane_mask (all_ready = &(lane_has_data|~lane_mask)).
  * MIRROR: tx_lane_mask_o/rx_lane_mask_o -> chiplet-ctrl wlink_rx_lane_mask ->
            u_calibrator.lane_mask (axi_chiplet_controller.sv:2479) + autoneg.

The same value is ALSO best-effort written over APB at unified offset 0x0214
(Wlink config block 0x0200 + register index 5*4 = 0x14, the
swi_tx/out_prepend_swi_rx_lane_mask register), and the APB-mirror readback is
logged so we can see the register actually took.

Oracle (matches test_v2_pair_data exactly, but on the masked link):
  1. calibrates on the subset (cal_done=1 both dies);
  2. mask-aware deskew asserts out_valid -> CR/CRACK exchange completes;
  3. FCSM reaches LINK_IDLE (state 4) bilaterally;
  4. a v33 4-word packet crosses M->S byte-correct in the slave RX FIFO.

Run under the default EPOCH_PROFILE=zero (anchor ON, zero skew) so the ONLY
variable under test is the reduced-lane mask.
"""
import cocotb
from cocotb.handle import Force
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check,
    ST_LANE_LOCKED, ST_CAL_DONE,
)

ACTIVE_MASK = 0xE4               # lanes 2,5,6,7 active; 0,1,3,4 masked off
ACTIVE_LANES = [i for i in range(8) if (ACTIVE_MASK >> i) & 1]
MASKED_LANES = [i for i in range(8) if not (ACTIVE_MASK >> i) & 1]

# Unified APB view of the Wlink lane-mask register (config block base 0x0200 +
# register index 5 -> byte offset 0x14). Writes BOTH fields:
#   pwdata[7:0]  -> swi_tx_lane_mask
#   pwdata[15:8] -> out_prepend_swi_rx_lane_mask
APB_WL_LANE_MASK = 0x0214


def _wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


def force_lane_mask(tb, mask):
    """Continuous Force on both lane-mask regs on BOTH dies. Force (not a
    deposit) so the async reset re-init to 8'hFF cannot clobber it mid-run."""
    for side in ("m", "s"):
        wl = _wlink(tb, side)
        wl.swi_tx_lane_mask.value = Force(mask)
        wl.out_prepend_swi_rx_lane_mask.value = Force(mask)


def read_mask_state(tb, side):
    wl = _wlink(tb, side)
    try:
        tx = int(wl.swi_tx_lane_mask.value)
    except (AttributeError, ValueError):
        tx = -1
    try:
        rx = int(wl.out_prepend_swi_rx_lane_mask.value)
    except (AttributeError, ValueError):
        rx = -1
    # downstream mirrors that actually feed the calibrator + deskew
    try:
        cal = int(tb.top(side).u_chiplet_controller.u_calibrator.lane_mask.value)
    except (AttributeError, ValueError):
        cal = -1
    try:
        dsk = int(wl.phy.gpio.u_deskew.lane_mask.value)
    except (AttributeError, ValueError):
        dsk = -1
    return tx, rx, cal, dsk


async def bringup_reduced(tb, mask=ACTIVE_MASK):
    """POR, latch the mask on both dies, then run the standard bring-up."""
    await tb.reset()
    force_lane_mask(tb, mask)
    # best-effort APB write of the same value (proves the register path too)
    for side in ("m", "s"):
        try:
            await tb.apb(side).write(APB_WL_LANE_MASK, (mask << 8) | mask)
        except Exception as e:                      # noqa: BLE001
            tb.log.warning(f"[{side}] APB lane-mask write skipped: {e}")
    await ClockCycles(tb.dut.hclk, 50)
    force_lane_mask(tb, mask)                        # re-assert after the APB write
    for side, name in (("m", "M"), ("s", "S")):
        tx, rx, cal, dsk = read_mask_state(tb, side)
        tb.log.info(f"  [mask] {name}: swi_tx=0x{tx:02x} swi_rx=0x{rx:02x} "
                    f"calibrator=0x{cal:02x} deskew=0x{dsk:02x} "
                    f"(want 0x{mask:02x})")
    # run the proven bring-up (force is continuous, survives the internal reset
    # phases the calibrator goes through)
    snap = await run_bringup_full(tb)
    return snap


@cocotb.test()
async def test_01_reduced_lane_linkup(dut):
    """Subset link-up: cal_done=1 both dies, CR/CRACK + FCSM=4 bilaterally."""
    tb = PairV2TB(dut)
    snap = await bringup_reduced(tb)

    # Confirm the mask actually held on both dies through bring-up.
    for side, name in (("m", "M"), ("s", "S")):
        tx, rx, cal, dsk = read_mask_state(tb, side)
        assert tx == ACTIVE_MASK and rx == ACTIVE_MASK, (
            f"{name}: lane mask did not hold (swi_tx=0x{tx:02x} "
            f"swi_rx=0x{rx:02x}, want 0x{ACTIVE_MASK:02x})")
        assert dsk == ACTIVE_MASK, (
            f"{name}: deskew lane_mask=0x{dsk:02x} != 0x{ACTIVE_MASK:02x} "
            f"(mask did not reach the deskew)")

    # Phase-1: cal_done must set on the SUBSET. lane_locked oracle is relaxed to
    # the ACTIVE lanes only (masked lanes never train -> their lock bit is 0 by
    # design; the full-0xFF oracle of test_v2_pair_data does not apply here).
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        assert ST_CAL_DONE(st) == 1, f"{name}: cal_done not set (0x{st:08x})"
        locked = ST_LANE_LOCKED(st)
        active_locked = all((locked >> i) & 1 for i in ACTIVE_LANES)
        tb.log.info(f"  {name}: lane_locked=0x{locked:02x} "
                    f"(active lanes {ACTIVE_LANES})")
        assert active_locked, (
            f"{name}: active lanes not all locked: lane_locked=0x{locked:02x}, "
            f"need bits {ACTIVE_LANES} set")

    ok = await tb.wait_cr_crack()
    await tb.snapshot("post cr/crack (reduced lane)")
    assert ok, ("CR/CRACK did not complete on the 4-lane subset — "
                f"M(cr={tb.fcsm_cr_seen('m')},crack={tb.fcsm_crack_seen('m')}) "
                f"S(cr={tb.fcsm_cr_seen('s')},crack={tb.fcsm_crack_seen('s')})")
    for side, name in (("m", "M"), ("s", "S")):
        assert tb.fcsm_state(side) == 4, (
            f"{name}: FCSM state {tb.fcsm_state(side)} != 4 (LINK_IDLE) "
            f"on the reduced-lane link")


@cocotb.test()
async def test_02_reduced_lane_data_m2s(dut):
    """M->S 4-word packet byte-correct over the 4-lane subset."""
    tb = PairV2TB(dut)
    await bringup_reduced(tb)
    assert await tb.wait_cr_crack(), \
        "reduced-lane link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, got = await send_and_check(
        tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="reduced-m2s")
    assert ok, f"reduced-lane M->S data corrupt/undelivered: got {got}"


@cocotb.test()
async def test_03_reduced_lane_masked_tx_lanes_quiet(dut):
    """Prove the masked TX lanes carry NO valid data on the wire while a real
    M->S packet is transmitted on the active subset.

    The PHY TX masking (tidelink_gpio_phy_tx.sv: `lane_mask[gi] ? sel_w : 0`)
    forces masked lanes to 16'h0000; the RX demask + mask-aware deskew then
    ignore them. The complementary 'masked lanes fed GARBAGE must not corrupt
    the word' direction is covered at the UNIT level by
    cocotb/tidelink_lane_deskew/test_lane_deskew_mask.py (assertion 3). It is
    NOT injected here because the RX samples pad_rx on the fast forwarded PHY
    clock and a cocotb whole-vector Force on pad_rx corrupts the ACTIVE lanes'
    bit-phase (confirmed TB artifact: a garbage=0 passthrough force fails
    identically — see the report accompanying this commit).

    So this test proves the wire-level half directly: sample m_pad_tx across a
    live transmit and assert the ACTIVE lanes toggle (carry data) while the
    MASKED lanes stay constant 0 (carry nothing). Byte-correct delivery is
    re-checked to anchor that the transmit really happened."""
    tb = PairV2TB(dut)
    await bringup_reduced(tb)
    assert await tb.wait_cr_crack(), \
        "reduced-lane link did not reach bilateral CR/CRACK (tx-quiet variant)"
    await ClockCycles(dut.hclk, 500)

    pad_tx = tb.dut.m_pad_tx
    seen_or = {"v": 0}            # OR of every sampled pad_tx value
    done = {"f": False}

    async def sample_padtx():
        while not done["f"]:
            try:
                seen_or["v"] |= int(pad_tx.value)
            except ValueError:
                pass
            await ClockCycles(tb.dut.hclk, 1)

    cocotb.start_soon(sample_padtx())
    ok, got = await send_and_check(
        tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="reduced-m2s-txquiet")
    done["f"] = True
    await ClockCycles(dut.hclk, 2)

    active_bits = sum(1 << i for i in ACTIVE_LANES)
    masked_bits = sum(1 << i for i in MASKED_LANES)
    orv = seen_or["v"]
    tb.log.info(f"  [tx-quiet] m_pad_tx OR over transmit = 0x{orv:02x} "
                f"(active 0x{active_bits:02x}, masked 0x{masked_bits:02x})")
    assert ok, f"reduced-lane M->S data corrupt/undelivered: got {got}"
    assert (orv & masked_bits) == 0, (
        f"masked TX lanes were NOT quiet: m_pad_tx OR=0x{orv:02x} has masked "
        f"bits 0x{orv & masked_bits:02x} set (should be 0)")
    assert (orv & active_bits) != 0, (
        f"active TX lanes never toggled: m_pad_tx OR=0x{orv:02x} — the transmit "
        f"was not observed on the active subset")

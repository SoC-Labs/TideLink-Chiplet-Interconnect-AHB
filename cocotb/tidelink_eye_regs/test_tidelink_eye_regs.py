"""Cocotb testbench for tidelink_eye_regs.

Standalone unit-test coverage for the APB Region-10 register file added in
the v2 PHY eye-visibility proposal (docs/EYE_VISIBILITY_RTL_PROPOSAL.md).
Exercises:

  * Reset defaults for every slot (DWELL_US=0x2710, PHY_EYE_ID=0x50450200,
    everything else zero)
  * APB3 protocol smoke (pready always high; pslverr stays low on legal
    transactions)
  * RW field write/read on every drivable RW slot (CTRL sticky bits,
    LANE_SEL, DWELL_US, FORCE_PHASE_EN/VAL, FORCE_SLIP_VAL, SCORE_IDX)
  * RO field write-ignore (PHY_EYE_ID, STATUS, CRC_LO/HI, SCORE_DATA,
    BURST_DATA, LAST_LATCHED stay at their input-driven value)
  * MODE=10 -> pslverr=1 (§13.5 DECODE_ERR for reserved Option B / DDR)
  * SWI_EYE_DWELL_US floor-clamp to 6000 (§13.6)
  * Reserved DDR slots (0x178, 0x17C) read as 0 with no pslverr
  * Burst sequence of back-to-back APB transactions
  * W1P self-clearing on CTRL.ENTER/CTRL.RESET
  * EYE_SCORE_IDX auto-increment after SCORE_DATA read when bit[16] set
  * CRC counter RC strobe asserts on read of CRC_LO / CRC_HI
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, ReadOnly

CLK_PERIOD_NS = 10

APB_ADDR_W = 12
DATA_W     = 32

# Byte offsets within the Region-10 window (paddr[5:2] selects the slot).
OFF_EYE_CTRL          = 0x140
OFF_EYE_LANE_SEL      = 0x144
OFF_EYE_DWELL_US      = 0x148
OFF_EYE_STATUS        = 0x14C
OFF_FORCE_PHASE_EN    = 0x150
OFF_FORCE_PHASE_VAL   = 0x154
OFF_FORCE_SLIP_VAL    = 0x158
OFF_CRC_ERR_LANE_LO   = 0x15C
OFF_CRC_ERR_LANE_HI   = 0x160
OFF_EYE_SCORE_IDX     = 0x164
OFF_EYE_SCORE_DATA    = 0x168
OFF_EYE_BURST_DATA    = 0x16C
OFF_EYE_LAST_LATCHED  = 0x170
OFF_PHY_EYE_ID        = 0x174
OFF_RESERVED_DDR_BASE = 0x178
OFF_RESERVED_DDR_SIZE = 0x17C

DWELL_US_RESET = 0x0000_2710
DWELL_US_MIN   = 6000
PHY_EYE_ID_VAL = 0x5045_0200


# ── BFM / helpers ───────────────────────────────────────────────────────────

async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = 0
    dut.pwdata.value  = 0
    dut.hresetn.value = 0

    # Stimulus inputs — quiescent defaults
    dut.eye_status_i.value             = 0
    dut.eye_score_data_i.value         = 0
    dut.eye_score_lane_passed_i.value  = 0
    dut.eye_score_best_i.value         = 0
    dut.eye_score_best_slip_i.value    = 0
    dut.eye_score_best_phase_i.value   = 0
    dut.lane_crc_err_cnt_0_i.value     = 0
    dut.lane_crc_err_cnt_1_i.value     = 0
    dut.lane_crc_err_cnt_2_i.value     = 0
    dut.lane_crc_err_cnt_3_i.value     = 0
    dut.lane_crc_err_cnt_4_i.value     = 0
    dut.lane_crc_err_cnt_5_i.value     = 0
    dut.lane_crc_err_cnt_6_i.value     = 0
    dut.lane_crc_err_cnt_7_i.value     = 0
    dut.eye_last_slip_i.value          = 0
    dut.eye_last_lane_fault_i.value    = 0


async def do_reset(dut):
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def apb_write(dut, addr, data):
    """APB3 write: setup phase + access phase, no wait-state."""
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 1
    dut.paddr.value   = addr & ((1 << APB_ADDR_W) - 1)
    dut.pwdata.value  = data & ((1 << DATA_W) - 1)
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    pready  = int(dut.pready.value)
    pslverr = int(dut.pslverr.value)
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    return pready, pslverr


async def apb_read(dut, addr):
    """APB3 read: setup phase + access phase. Returns (rdata, pready, pslverr)."""
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = addr & ((1 << APB_ADDR_W) - 1)
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    rdata   = int(dut.prdata.value)
    pready  = int(dut.pready.value)
    pslverr = int(dut.pslverr.value)
    dut.psel.value    = 0
    dut.penable.value = 0
    return rdata, pready, pslverr


# ══════════════════════════════════════════════════════════════════════════════
# Reset / default-value tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_01_reset_defaults(dut):
    """Every register reads its specified reset value after hresetn deassertion."""
    await setup(dut)
    await do_reset(dut)

    expected = {
        OFF_EYE_CTRL:          0x0000_0000,
        OFF_EYE_LANE_SEL:      0x0000_0000,
        OFF_EYE_DWELL_US:      DWELL_US_RESET,
        OFF_EYE_STATUS:        0x0000_0000,
        OFF_FORCE_PHASE_EN:    0x0000_0000,
        OFF_FORCE_PHASE_VAL:   0x0000_0000,
        OFF_FORCE_SLIP_VAL:    0x0000_0000,
        OFF_EYE_SCORE_IDX:     0x0000_0000,
        OFF_PHY_EYE_ID:        PHY_EYE_ID_VAL,
        OFF_RESERVED_DDR_BASE: 0x0000_0000,
        OFF_RESERVED_DDR_SIZE: 0x0000_0000,
    }
    for addr, want in expected.items():
        rdata, pready, pslverr = await apb_read(dut, addr)
        assert pready == 1, f"pready low on read of 0x{addr:03X}"
        assert pslverr == 0, f"pslverr asserted on legal read of 0x{addr:03X}"
        assert rdata == want, (
            f"Reset default 0x{addr:03X}: expected 0x{want:08X}, got 0x{rdata:08X}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# APB protocol smoke
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_02_apb_pready_always_high(dut):
    """pready is wired high — every transaction completes without wait state."""
    await setup(dut)
    await do_reset(dut)

    addrs = [OFF_EYE_LANE_SEL, OFF_FORCE_PHASE_EN, OFF_PHY_EYE_ID,
             OFF_EYE_DWELL_US, OFF_RESERVED_DDR_BASE]
    for addr in addrs:
        _, pready_r, _ = await apb_read(dut, addr)
        assert pready_r == 1, f"pready low on read 0x{addr:03X}"

    for addr in (OFF_EYE_LANE_SEL, OFF_FORCE_PHASE_EN, OFF_FORCE_SLIP_VAL):
        pready_w, _ = await apb_write(dut, addr, 0xA5A5_A5A5)
        assert pready_w == 1, f"pready low on write 0x{addr:03X}"


@cocotb.test()
async def test_03_apb_pslverr_clean_on_rw_slots(dut):
    """pslverr stays low on writes to all RW slots and reads to every slot."""
    await setup(dut)
    await do_reset(dut)

    rw_slots = [OFF_EYE_LANE_SEL, OFF_EYE_DWELL_US, OFF_FORCE_PHASE_EN,
                OFF_FORCE_PHASE_VAL, OFF_FORCE_SLIP_VAL, OFF_EYE_SCORE_IDX]
    for addr in rw_slots:
        # DWELL needs >= 6000 to avoid clamp-noise (clamp doesn't fault)
        wval = DWELL_US_MIN if addr == OFF_EYE_DWELL_US else 0x1234_5678
        _, pslverr_w = await apb_write(dut, addr, wval)
        assert pslverr_w == 0, f"pslverr asserted writing RW slot 0x{addr:03X}"

    # CTRL with MODE=00 — pslverr stays low (only MODE=10 faults)
    _, pslverr_ctrl = await apb_write(dut, OFF_EYE_CTRL, 0x0000_0000)
    assert pslverr_ctrl == 0, "pslverr asserted on benign CTRL write"


# ══════════════════════════════════════════════════════════════════════════════
# RW slot write/read coverage
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_04_lane_sel_rw(dut):
    """SWI_EYE_LANE_SEL is fully RW; lane[2:0] reaches the output port."""
    await setup(dut)
    await do_reset(dut)

    for pat in (0x0000_0003, 0x0000_0007, 0xFFFF_FFFF, 0x0000_0000):
        await apb_write(dut, OFF_EYE_LANE_SEL, pat)
        await ClockCycles(dut.hclk, 1)
        rdata, _, _ = await apb_read(dut, OFF_EYE_LANE_SEL)
        assert rdata == pat, (
            f"LANE_SEL RW: wrote 0x{pat:08X}, read 0x{rdata:08X}"
        )
        assert int(dut.swi_eye_lane_sel.value) == (pat & 0x7), (
            f"swi_eye_lane_sel port mismatch: expected {pat & 0x7}, "
            f"got {int(dut.swi_eye_lane_sel.value)}"
        )


@cocotb.test()
async def test_05_dwell_us_rw_above_floor(dut):
    """SWI_EYE_DWELL_US accepts values >= 6000 unchanged."""
    await setup(dut)
    await do_reset(dut)

    for pat in (DWELL_US_MIN, 0x0000_2710, 0x0001_0000, 0xFFFF_FFFF):
        await apb_write(dut, OFF_EYE_DWELL_US, pat)
        await ClockCycles(dut.hclk, 1)
        rdata, _, _ = await apb_read(dut, OFF_EYE_DWELL_US)
        assert rdata == pat, (
            f"DWELL_US RW (above floor) wrote 0x{pat:08X}, read 0x{rdata:08X}"
        )
        assert int(dut.swi_eye_dwell_us.value) == pat


@cocotb.test()
async def test_06_force_phase_and_slip_rw(dut):
    """FORCE_PHASE_EN/VAL and FORCE_SLIP_VAL are fully RW."""
    await setup(dut)
    await do_reset(dut)

    triples = [
        (OFF_FORCE_PHASE_EN,  0xDEAD_BEEF, "swi_force_phase_en"),
        (OFF_FORCE_PHASE_VAL, 0x1234_5678, "swi_force_phase_val"),
        (OFF_FORCE_SLIP_VAL,  0xCAFE_BABE, "swi_force_slip_val"),
    ]
    for addr, pat, port in triples:
        await apb_write(dut, addr, pat)
        await ClockCycles(dut.hclk, 1)
        rdata, _, _ = await apb_read(dut, addr)
        assert rdata == pat, (
            f"{port} RW: wrote 0x{pat:08X}, read 0x{rdata:08X}"
        )
        assert int(getattr(dut, port).value) == pat


@cocotb.test()
async def test_07_eye_ctrl_sticky_bits(dut):
    """EYE_CTRL sticky bits [5:4]=MODE, [8]=FFS, [9]=AUTO_INC persist; [0]/[1] self-clear."""
    await setup(dut)
    await do_reset(dut)

    # Write MODE=11, FFS=1, AUTO_INC=1, ENTER=1 (W1P), RESET=1 (W1P).
    # Use MODE=11 (NOT MODE=10 — that would trigger §13.5 pslverr) so both
    # MODE bits are exercised as sticky.
    write_val = (0b11 << 4) | (1 << 8) | (1 << 9) | (1 << 0) | (1 << 1)
    await apb_write(dut, OFF_EYE_CTRL, write_val)
    await ClockCycles(dut.hclk, 2)  # let W1P clear
    rdata, _, _ = await apb_read(dut, OFF_EYE_CTRL)

    # Sticky bits should remain; W1P bits [0] and [1] should be clear
    sticky_mask = (0b11 << 4) | (1 << 8) | (1 << 9)
    assert (rdata & sticky_mask) == sticky_mask, (
        f"EYE_CTRL sticky bits not held: read 0x{rdata:08X}"
    )
    assert (rdata & 0x3) == 0, (
        f"EYE_CTRL W1P bits [0]/[1] did not self-clear: 0x{rdata:08X}"
    )


@cocotb.test()
async def test_08_eye_ctrl_w1p_enter_pulse(dut):
    """Writing ENTER=1 latches swi_eye_ctrl[0] high for one cycle (the
    cycle following the access edge) and the W1P bit then auto-clears."""
    await setup(dut)
    await do_reset(dut)

    # Drive the access phase by hand so we control deassertion timing.
    # On the access-phase rising edge (psel=penable=1) the always_ff
    # latches swi_eye_ctrl_r[0] <= pwdata[0]. The continuous assign
    # propagates swi_eye_ctrl_r -> swi_eye_ctrl in the same Δ-cycle.

    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 1
    dut.paddr.value   = OFF_EYE_CTRL
    dut.pwdata.value  = 1  # ENTER=1
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    # The next rising edge is the access-phase edge that latches the W1P
    # bit. Hold all APB signals stable across this edge and sample
    # swi_eye_ctrl in the Δ after the NBA update lands.
    await RisingEdge(dut.hclk)
    await Timer(1, units="ns")
    ctrl_after_access = int(dut.swi_eye_ctrl.value)
    assert (ctrl_after_access & 0x1) == 1, (
        f"ENTER pulse did not latch on access edge: "
        f"swi_eye_ctrl=0x{ctrl_after_access:08X}"
    )

    # Now drop psel/penable; the next rising edge runs the default branch
    # of the always_ff and clears the W1P bit.
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    await RisingEdge(dut.hclk)
    await Timer(1, units="ns")
    ctrl_after_clear = int(dut.swi_eye_ctrl.value)
    assert (ctrl_after_clear & 0x1) == 0, (
        f"W1P bit did not self-clear: swi_eye_ctrl=0x{ctrl_after_clear:08X}"
    )


# ══════════════════════════════════════════════════════════════════════════════
# RO write-ignore
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_09_ro_phy_eye_id_write_ignored(dut):
    """PHY_EYE_ID is RO — writes raise pslverr and value is unchanged."""
    await setup(dut)
    await do_reset(dut)

    _, pslverr_w = await apb_write(dut, OFF_PHY_EYE_ID, 0xFFFF_FFFF)
    assert pslverr_w == 1, "pslverr should fire on write to PHY_EYE_ID (RO slot)"
    rdata, _, _ = await apb_read(dut, OFF_PHY_EYE_ID)
    assert rdata == PHY_EYE_ID_VAL, (
        f"PHY_EYE_ID mutated by write: expected 0x{PHY_EYE_ID_VAL:08X}, got 0x{rdata:08X}"
    )


@cocotb.test()
async def test_10_ro_status_reflects_input(dut):
    """EYE_STATUS is RO and reflects eye_status_i; writes raise pslverr only."""
    await setup(dut)
    await do_reset(dut)

    for stim in (0x0000_0001, 0xAAAA_5555, 0xFFFF_FFFF, 0x0000_0000):
        dut.eye_status_i.value = stim
        await ClockCycles(dut.hclk, 1)
        rdata, _, _ = await apb_read(dut, OFF_EYE_STATUS)
        assert rdata == stim, (
            f"EYE_STATUS read 0x{rdata:08X}, expected 0x{stim:08X}"
        )

    # Write attempt -> pslverr=1, but value continues to mirror eye_status_i
    dut.eye_status_i.value = 0xC0DE_C0DE
    await ClockCycles(dut.hclk, 1)
    _, pslverr_w = await apb_write(dut, OFF_EYE_STATUS, 0xDEAD_DEAD)
    assert pslverr_w == 1, "pslverr should fire on write to EYE_STATUS"
    rdata, _, _ = await apb_read(dut, OFF_EYE_STATUS)
    assert rdata == 0xC0DE_C0DE, (
        f"EYE_STATUS corrupted by write: 0x{rdata:08X}"
    )


@cocotb.test()
async def test_11_ro_crc_lanes_reflect_inputs_and_strobe(dut):
    """CRC_LO/HI reflect concatenated lane counters and assert clear-strobe on read."""
    await setup(dut)
    await do_reset(dut)

    dut.lane_crc_err_cnt_0_i.value = 0x11
    dut.lane_crc_err_cnt_1_i.value = 0x22
    dut.lane_crc_err_cnt_2_i.value = 0x33
    dut.lane_crc_err_cnt_3_i.value = 0x44
    dut.lane_crc_err_cnt_4_i.value = 0x55
    dut.lane_crc_err_cnt_5_i.value = 0x66
    dut.lane_crc_err_cnt_6_i.value = 0x77
    dut.lane_crc_err_cnt_7_i.value = 0x88
    await ClockCycles(dut.hclk, 1)

    rdata, _, _ = await apb_read(dut, OFF_CRC_ERR_LANE_LO)
    assert rdata == 0x4433_2211, f"CRC_LO: expected 0x44332211, got 0x{rdata:08X}"

    rdata, _, _ = await apb_read(dut, OFF_CRC_ERR_LANE_HI)
    assert rdata == 0x8877_6655, f"CRC_HI: expected 0x88776655, got 0x{rdata:08X}"

    # Write attempts to RC/RO slots return pslverr=1
    _, pslverr_lo = await apb_write(dut, OFF_CRC_ERR_LANE_LO, 0xFFFF_FFFF)
    _, pslverr_hi = await apb_write(dut, OFF_CRC_ERR_LANE_HI, 0xFFFF_FFFF)
    assert pslverr_lo == 1 and pslverr_hi == 1, (
        "pslverr should fire on writes to CRC_LO/HI (RO/RC slots)"
    )


@cocotb.test()
async def test_12_ro_last_latched_packs_inputs(dut):
    """EYE_LAST_LATCHED packs slip vector [23:0] | lane_fault [31:24]."""
    await setup(dut)
    await do_reset(dut)

    dut.eye_last_slip_i.value       = 0x12_3456
    dut.eye_last_lane_fault_i.value = 0xAB
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_LAST_LATCHED)
    expected = (0xAB << 24) | 0x12_3456
    assert rdata == expected, (
        f"LAST_LATCHED: expected 0x{expected:08X}, got 0x{rdata:08X}"
    )

    _, pslverr_w = await apb_write(dut, OFF_EYE_LAST_LATCHED, 0xDEAD_BEEF)
    assert pslverr_w == 1, "pslverr should fire on write to LAST_LATCHED (RO)"


# ══════════════════════════════════════════════════════════════════════════════
# §13.5 — MODE=10 returns pslverr=1
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_13_mode_10_returns_pslverr(dut):
    """Writing CTRL with MODE=10 returns pslverr=1 (§13.5 reserved Option B)."""
    await setup(dut)
    await do_reset(dut)

    # MODE=10 lives in bits [5:4]. ENTER/RESET cleared.
    pwd = (0b10 << 4)
    _, pslverr_w = await apb_write(dut, OFF_EYE_CTRL, pwd)
    assert pslverr_w == 1, (
        f"MODE=10 should raise pslverr per §13.5; got pslverr={pslverr_w}"
    )

    # Sanity: MODE=00, 01, 11 should NOT raise pslverr
    for mode in (0b00, 0b01, 0b11):
        pwd_ok = (mode << 4)
        _, ps = await apb_write(dut, OFF_EYE_CTRL, pwd_ok)
        assert ps == 0, f"MODE={mode:02b} unexpectedly raised pslverr"


# ══════════════════════════════════════════════════════════════════════════════
# §13.6 — DWELL_US floor clamp
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_14_dwell_us_floor_clamp(dut):
    """Writes below 6000 are floor-clamped to 6000 (§13.6)."""
    await setup(dut)
    await do_reset(dut)

    for low in (0, 1, 100, 5999):
        await apb_write(dut, OFF_EYE_DWELL_US, low)
        await ClockCycles(dut.hclk, 1)
        rdata, _, _ = await apb_read(dut, OFF_EYE_DWELL_US)
        assert rdata == DWELL_US_MIN, (
            f"DWELL_US clamp: wrote {low}, expected {DWELL_US_MIN}, got {rdata}"
        )
        assert int(dut.swi_eye_dwell_us.value) == DWELL_US_MIN

    # Boundary: writing exactly 6000 is held at 6000
    await apb_write(dut, OFF_EYE_DWELL_US, DWELL_US_MIN)
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_DWELL_US)
    assert rdata == DWELL_US_MIN

    # Above floor passes unchanged
    await apb_write(dut, OFF_EYE_DWELL_US, DWELL_US_MIN + 1)
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_DWELL_US)
    assert rdata == DWELL_US_MIN + 1


# ══════════════════════════════════════════════════════════════════════════════
# Reserved slots
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_15_reserved_ddr_slots_raz_wi(dut):
    """Reserved DDR slots (0x178/0x17C) read as 0; writes don't raise pslverr."""
    await setup(dut)
    await do_reset(dut)

    for addr in (OFF_RESERVED_DDR_BASE, OFF_RESERVED_DDR_SIZE):
        rdata, _, pslverr = await apb_read(dut, addr)
        assert pslverr == 0, f"pslverr on read of reserved 0x{addr:03X}"
        assert rdata == 0, (
            f"Reserved 0x{addr:03X} should RAZ; got 0x{rdata:08X}"
        )

        _, pslverr_w = await apb_write(dut, addr, 0xDEAD_BEEF)
        assert pslverr_w == 0, (
            f"pslverr on write to reserved 0x{addr:03X} (RAZ/WI, no fault)"
        )
        rdata, _, _ = await apb_read(dut, addr)
        assert rdata == 0, f"Reserved 0x{addr:03X} mutated: 0x{rdata:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Peer-aperture-style burst
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_16_burst_back_to_back_transactions(dut):
    """Back-to-back APB transactions across multiple slots all complete cleanly."""
    await setup(dut)
    await do_reset(dut)

    # Sequence: alternating read+write across RW slots, like a peer poking
    # the regfile through the chiplet aperture.
    sequence = [
        ("W", OFF_EYE_LANE_SEL,    0x0000_0005),
        ("R", OFF_EYE_LANE_SEL,    0x0000_0005),
        ("W", OFF_EYE_DWELL_US,    0x0000_4000),
        ("R", OFF_EYE_DWELL_US,    0x0000_4000),
        ("W", OFF_FORCE_PHASE_EN,  0x00FF_00FF),
        ("R", OFF_FORCE_PHASE_EN,  0x00FF_00FF),
        ("W", OFF_FORCE_PHASE_VAL, 0x0F0F_F0F0),
        ("R", OFF_FORCE_PHASE_VAL, 0x0F0F_F0F0),
        ("W", OFF_FORCE_SLIP_VAL,  0x1357_9BDF),
        ("R", OFF_FORCE_SLIP_VAL,  0x1357_9BDF),
        ("W", OFF_EYE_SCORE_IDX,   0x0000_0042),
        ("R", OFF_EYE_SCORE_IDX,   0x0000_0042),
        ("R", OFF_PHY_EYE_ID,      PHY_EYE_ID_VAL),
    ]
    for op, addr, val in sequence:
        if op == "W":
            pready, pslverr = await apb_write(dut, addr, val)
            assert pready == 1 and pslverr == 0, (
                f"Burst write 0x{addr:03X}=0x{val:08X}: "
                f"pready={pready} pslverr={pslverr}"
            )
        else:
            rdata, pready, pslverr = await apb_read(dut, addr)
            assert pready == 1 and pslverr == 0
            assert rdata == val, (
                f"Burst read 0x{addr:03X}: expected 0x{val:08X}, got 0x{rdata:08X}"
            )


# ══════════════════════════════════════════════════════════════════════════════
# SCORE_IDX auto-increment behaviour
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_17_score_idx_auto_increment_on_score_data_read(dut):
    """When SCORE_IDX[16]=1, reading SCORE_DATA bumps SCORE_IDX[6:0] by 1."""
    await setup(dut)
    await do_reset(dut)

    # Program auto-increment enable, idx[6:0]=0x10
    await apb_write(dut, OFF_EYE_SCORE_IDX, (1 << 16) | 0x10)
    await ClockCycles(dut.hclk, 1)

    # Read SCORE_DATA — eye_score_data_i defaulted to 0 so prdata is don't-care;
    # we just care about the idx bump
    await apb_read(dut, OFF_EYE_SCORE_DATA)
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_SCORE_IDX)
    assert (rdata & 0x7F) == 0x11, (
        f"SCORE_IDX did not auto-increment after SCORE_DATA read: 0x{rdata:08X}"
    )

    # A second SCORE_DATA read bumps again
    await apb_read(dut, OFF_EYE_SCORE_DATA)
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_SCORE_IDX)
    assert (rdata & 0x7F) == 0x12, (
        f"SCORE_IDX did not auto-increment a second time: 0x{rdata:08X}"
    )


@cocotb.test()
async def test_18_score_idx_burst_read_increments_by_five(dut):
    """Reading EYE_BURST_DATA bumps SCORE_IDX[6:0] by 5."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_EYE_SCORE_IDX, 0x00)
    await ClockCycles(dut.hclk, 1)

    await apb_read(dut, OFF_EYE_BURST_DATA)
    await ClockCycles(dut.hclk, 1)
    rdata, _, _ = await apb_read(dut, OFF_EYE_SCORE_IDX)
    assert (rdata & 0x7F) == 5, (
        f"SCORE_IDX should bump by 5 on burst read: 0x{rdata:08X}"
    )


@cocotb.test()
async def test_19_crc_read_asserts_clr_strobe(dut):
    """lane_crc_err_cnt_clr_o pulses high during the access phase of a CRC read."""
    await setup(dut)
    await do_reset(dut)

    # Drive a CRC_LO read; sample lane_crc_err_cnt_clr_o during access phase.
    # The strobe is purely combinational from psel & penable & ~pwrite & slot,
    # so we settle with a small Timer delay after the access-phase edge.
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = OFF_CRC_ERR_LANE_LO
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    # Advance Δt so VCS re-evaluates combinational signals on the new penable
    await Timer(1, units="ns")
    strobe = int(dut.lane_crc_err_cnt_clr_o.value)
    assert strobe == 1, (
        f"lane_crc_err_cnt_clr_o should pulse high on CRC_LO read; got {strobe}"
    )

    # Also test CRC_HI
    dut.psel.value    = 0
    dut.penable.value = 0
    await ClockCycles(dut.hclk, 1)
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = OFF_CRC_ERR_LANE_HI
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await Timer(1, units="ns")
    strobe_hi = int(dut.lane_crc_err_cnt_clr_o.value)
    assert strobe_hi == 1, (
        f"lane_crc_err_cnt_clr_o should pulse high on CRC_HI read; got {strobe_hi}"
    )

    # Idle: no APB transaction -> strobe low
    dut.psel.value    = 0
    dut.penable.value = 0
    await ClockCycles(dut.hclk, 2)
    strobe_idle = int(dut.lane_crc_err_cnt_clr_o.value)
    assert strobe_idle == 0, (
        f"lane_crc_err_cnt_clr_o should be low when no CRC slot is being "
        f"read; got {strobe_idle}"
    )

    # Reading a non-CRC slot (e.g., PHY_EYE_ID) should NOT pulse the strobe
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = OFF_PHY_EYE_ID
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await Timer(1, units="ns")
    strobe_phyid = int(dut.lane_crc_err_cnt_clr_o.value)
    assert strobe_phyid == 0, (
        f"lane_crc_err_cnt_clr_o spuriously high on non-CRC read; got "
        f"{strobe_phyid}"
    )
    dut.psel.value    = 0
    dut.penable.value = 0

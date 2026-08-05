"""Integrated PERF_CONG_STATE (0x20F8) APB read-aperture + field decode.

WHY THIS FILE EXISTS  (HANDOVER_UNIT_REGRESSION_FROM_ETHCHIPLET_2026_08_04.md,
                       item B4 / D2 / silicon finding #6)
--------------------------------------------------------------------------
The eth-chiplet silicon telemetry reads congestion state through the APB
aperture `PERF_CONG_STATE` at TideLink offset 0x0F8 (SoC 0x2_0F8 / 0x2_20F8 in
the integrated map). The handover flags that **no regression decodes 0x20F8 in
the integrated path** — the only coverage is block-level
(`cocotb/tidelink_perf_congestion`), which drives `tidelink_perf`'s internal
`perf_reg_*` port directly and NEVER exercises the `tidelink_apb_regs` APB
aperture the silicon actually reads through.

`test_perf_region_decode.py::cong_state_decodes_to_region_seven` covers the
WRITE-phase *addressing* seam (paddr 0x0F8 -> perf_reg_region=7, slot=6). It does
NOT cover the READ path (0x0F8 -> prdata) or the FIELD LAYOUT. This bench closes
both:

  1. APERTURE (RTL-enforced, tidelink_apb_regs.sv:670 `4'b0111: prdata =
     perf_reg_rdata`): an APB read of 0x0F8 routes the perf-block read data onto
     prdata, and 0x0F8 is genuinely the perf aperture (a non-perf region does
     NOT return the same data).
  2. FIELD LAYOUT (the silicon-telemetry contract, tidelink_perf.sv:503-514):
     level [17:16], trend [19:18], starve [20], ewma [12:0] decode correctly out
     of the value read at 0x0F8.

SCOPE (honest): in this standalone `tidelink_apb_regs` env, `perf_reg_rdata` is a
tb-driven input — it stands in for the congestion estimator output, whose
computation (EWMA, level/trend hysteresis, credit-starve stickiness) is validated
separately by `cocotb/tidelink_perf_congestion`. This bench validates the
APB READ APERTURE ROUTING and the PERF_CONG_STATE FIELD BIT-POSITIONS that
silicon reads through — the integration seam that was previously zero-covered.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10

# ── Address map (matches test_perf_region_decode.py) ──────────────────────
# Perf occupies APB regions 5..7 at 0x0A0-0x0FC. region N base = N * 0x20;
# slot within region = paddr[4:2]. PERF_CONG_STATE = region 7 slot 6 -> 0x0F8.
REGION_BASE = {5: 0x0A0, 6: 0x0C0, 7: 0x0E0}
CONG_STATE_SLOT = 6
CONG_STATE_ADDR = REGION_BASE[7] + CONG_STATE_SLOT * 4        # 0x0F8

# A region-0, fixed-constant register used as the "not the perf aperture"
# discriminator: region 0 slot 5 reads back the "TideLink v1.0" ID constant
# (tidelink_apb_regs.sv:638), independent of perf_reg_rdata.
TIDELINK_ID_ADDR = 0x014                                      # region 0 slot 5
TIDELINK_ID_VAL  = 0x544C_0100

# ── PERF_CONG_STATE field layout — tidelink_perf.sv:503-514, CREDIT_W = 13 ──
#   [12:0]   ewma_q_r
#   [15:13]  reserved
#   [17:16]  level
#   [19:18]  trend
#   [20]     credit_starve_sticky
#   [31:21]  reserved
EWMA_LSB,  EWMA_W  = 0, 13
LEVEL_LSB, LEVEL_W = 16, 2
TREND_LSB, TREND_W = 18, 2
STARVE_BIT         = 20


def encode_cong_state(level, trend, starve, ewma):
    """Pack fields into the PERF_CONG_STATE word per tidelink_perf.sv layout."""
    assert 0 <= level < (1 << LEVEL_W)
    assert 0 <= trend < (1 << TREND_W)
    assert starve in (0, 1)
    assert 0 <= ewma < (1 << EWMA_W)
    return ((ewma & ((1 << EWMA_W) - 1)) << EWMA_LSB) \
        | ((level & ((1 << LEVEL_W) - 1)) << LEVEL_LSB) \
        | ((trend & ((1 << TREND_W) - 1)) << TREND_LSB) \
        | ((starve & 1) << STARVE_BIT)


def decode_cong_state(word):
    """Decode a PERF_CONG_STATE word read at 0x0F8 into its four fields."""
    return dict(
        ewma=(word >> EWMA_LSB) & ((1 << EWMA_W) - 1),
        level=(word >> LEVEL_LSB) & ((1 << LEVEL_W) - 1),
        trend=(word >> TREND_LSB) & ((1 << TREND_W) - 1),
        starve=(word >> STARVE_BIT) & 1,
    )


async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    # Sideband inputs held quiet so they cannot perturb the read path.
    dut.packet_word_length.value = 0
    dut.current_credit_count.value = 0
    dut.read_complete.value = 0
    dut.returner_busy.value = 0
    dut.fifo_overrun.value = 0
    dut.fifo_underrun.value = 0
    dut.master_error.value = 0
    dut.packet_committed.value = 0
    dut.perf_reg_rdata.value = 0
    dut.hresetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    await RisingEdge(dut.hclk)


async def apb_read(dut, addr, perf_rdata):
    """Drive perf_reg_rdata, run an APB read at `addr`, sample prdata in ACCESS."""
    dut.perf_reg_rdata.value = perf_rdata
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = addr & 0xFFF
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    prdata = int(dut.prdata.value)
    dut.psel.value = 0
    dut.penable.value = 0
    await RisingEdge(dut.hclk)
    return prdata


# Field vectors chosen to toggle every bit of every field, incl. the field
# boundaries (level/trend adjacency, the starve bit sitting above trend, and
# the ewma MSB at bit12 adjacent to the [15:13] reserved gap).
VECTORS = [
    # (level, trend, starve, ewma)
    (0, 0, 0, 0x0000),
    (3, 3, 1, 0x1FFF),   # all-ones in every field
    (1, 2, 0, 0x1555),   # ewma = ...010101010101
    (2, 1, 1, 0x0AAA),   # ewma = ...001010101010
    (3, 0, 0, 0x1000),   # ewma MSB only (bit12), guards the reserved gap
    (0, 3, 1, 0x0001),   # ewma LSB only
]


@cocotb.test()
async def test_cong_state_aperture_routes_perf_rdata(dut):
    """0x0F8 read routes perf_reg_rdata onto prdata (tidelink_apb_regs.sv:670)
    and 0x0F8 is genuinely the perf aperture (a non-perf region does not)."""
    await setup(dut)
    SENTINEL = 0xDEAD_BEEF

    got = await apb_read(dut, CONG_STATE_ADDR, SENTINEL)
    assert got == SENTINEL, (
        f"APB read of PERF_CONG_STATE (0x{CONG_STATE_ADDR:03X}) must return "
        f"perf_reg_rdata on prdata: drove 0x{SENTINEL:08X}, prdata=0x{got:08X}. "
        f"tidelink_apb_regs.sv:670 (region 7 -> prdata = perf_reg_rdata).")

    # Discriminator: a non-perf region must NOT echo perf_reg_rdata, proving
    # 0x0F8 is specifically the perf aperture and not a coincidental pass-through.
    other = await apb_read(dut, TIDELINK_ID_ADDR, SENTINEL)
    assert other == TIDELINK_ID_VAL, (
        f"region-0 ID reg (0x{TIDELINK_ID_ADDR:03X}) must read 0x{TIDELINK_ID_VAL:08X}, "
        f"got 0x{other:08X}")
    assert other != SENTINEL, (
        "non-perf region wrongly echoed perf_reg_rdata — the perf aperture is "
        "not confined to regions 5..7")
    dut._log.info("PERF_CONG_STATE aperture: 0x0F8 routes perf_reg_rdata; "
                  "region-0 ID reg does not. Aperture confined.")


@cocotb.test()
async def test_cong_state_field_decode(dut):
    """Every field (level[17:16], trend[19:18], starve[20], ewma[12:0]) decodes
    byte-exact out of the value read at 0x20F8's aperture (0x0F8)."""
    await setup(dut)
    for (level, trend, starve, ewma) in VECTORS:
        enc = encode_cong_state(level, trend, starve, ewma)
        got = await apb_read(dut, CONG_STATE_ADDR, enc)
        assert got == enc, (
            f"aperture read mismatch: drove 0x{enc:08X}, read 0x{got:08X}")
        d = decode_cong_state(got)
        assert d["level"] == level and d["trend"] == trend and \
            d["starve"] == starve and d["ewma"] == ewma, (
            f"PERF_CONG_STATE field decode mismatch at 0x{CONG_STATE_ADDR:03X}: "
            f"expected level={level} trend={trend} starve={starve} "
            f"ewma=0x{ewma:04X}; got {d} (raw 0x{got:08X})")
        dut._log.info(
            f"0x0F8 decode OK: level={level} trend={trend} starve={starve} "
            f"ewma=0x{ewma:04X} (raw 0x{got:08X})")

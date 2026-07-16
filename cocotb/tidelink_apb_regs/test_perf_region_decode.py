"""APB -> perf-block region decode.

WHY THIS FILE EXISTS
--------------------
`tidelink_apb_regs` formed `perf_reg_region` as the RAW region index
(`apb_region[1:0]`), but `tidelink_perf.sv:53` declares that port as
OFFSET-FROM-5: `00=Region5, 01=Region6, 10=Region7`. Off by one, and it broke
the whole perf block:

  * `perf_reg_write` is gated to apb_region 5..7, so the raw `[1:0]` was only
    ever 01/10/11 and NEVER 2'b00. `tidelink_perf.sv:437` writes `perf_enable_r`
    only under `perf_reg_write && perf_reg_region == 2'b00` — unreachable. So
    `perf_enable_r` was stuck at its reset value of 0, `perf_active` never
    asserted, and every perf counter (including `ewma_q_r` -> `ewma_credit_o`,
    the congestion telemetry exported all the way to the chiplet boundary as
    `tl_ewma_credit_o`) was permanently zero.
  * The same skew rotated the read mux: Region 7 fell through to `default:` and
    read 0, killing PERF_ID — the presence gate bring-up scripts check first.

`cocotb/tidelink_perf_congestion` could not catch it: that bench compiles
`tidelink_perf.sv` WITHOUT `tidelink_apb_regs.sv` and drives `perf_reg_region`
directly, hardcoding `REGION5 = 0b00`. It encodes the module's convention, so it
passed while the integration was broken. Nothing tested the seam BETWEEN the two
files — which is exactly where the bug was. This bench is that seam.

Every test below FAILS against the raw-index form and passes against the fix.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10

# Perf occupies APB regions 5..7 at 0x0A0-0x0FC. apb_region = paddr[8:5], and
# the slot within a region is paddr[4:2], so region N base = N * 0x20.
REGION_BASE = {5: 0x0A0, 6: 0x0C0, 7: 0x0E0}

# tidelink_perf.sv's contract for perf_reg_region: offset-from-5.
EXPECTED_REGION_CODE = {5: 0b00, 6: 0b01, 7: 0b10}

PERF_CTRL_SLOT = 0  # region 5, slot 0 -> 0x0A0
CONG_STATE_SLOT = 6  # region 7, slot 6 -> 0x0F8


def addr_of(region, slot):
    """APB byte address of a perf register slot."""
    return REGION_BASE[region] + (slot * 4)


async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    # Unrelated sideband inputs — held quiet so they cannot perturb the decode.
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


async def apb_write_sample(dut, addr, data):
    """Drive an APB write; sample the perf decode during the ENABLE phase.

    perf_reg_write is combinational on the APB access phase, so it must be
    sampled while penable is high — not after the transfer completes.
    """
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 1
    dut.paddr.value = addr & 0xFFF
    dut.pwdata.value = data
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    sample = {
        "write": int(dut.perf_reg_write.value),
        "region": int(dut.perf_reg_region.value),
        "addr": int(dut.perf_reg_addr.value),
        "wdata": int(dut.perf_reg_wdata.value),
    }
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    await RisingEdge(dut.hclk)
    return sample


@cocotb.test()
async def perf_region_code_is_offset_from_five(dut):
    """Each perf region must present its OFFSET-FROM-5 code, per tidelink_perf.sv:53."""
    await setup(dut)
    for region, expected in EXPECTED_REGION_CODE.items():
        s = await apb_write_sample(dut, addr_of(region, 0), 0x0000_0001)
        assert s["write"] == 1, (
            f"perf_reg_write should assert for region {region} "
            f"(paddr 0x{addr_of(region, 0):03X})"
        )
        assert s["region"] == expected, (
            f"region {region} (paddr 0x{addr_of(region, 0):03X}): "
            f"perf_reg_region = 0b{s['region']:02b}, expected 0b{expected:02b}. "
            f"Raw-index bug gives 0b{region & 0b11:02b}."
        )


@cocotb.test()
async def perf_ctrl_write_is_reachable(dut):
    """THE regression: PERF_CTRL must be writable.

    `perf_enable_r` is written only under `perf_reg_write && perf_reg_region ==
    2'b00`. If region 5 does not decode to 2'b00, perf can never be enabled and
    every counter — including tl_ewma_credit_o — reads zero forever.
    """
    await setup(dut)
    s = await apb_write_sample(dut, addr_of(5, PERF_CTRL_SLOT), 0x0000_0001)
    assert s["write"] == 1 and s["region"] == 0b00 and s["addr"] == PERF_CTRL_SLOT, (
        "PERF_CTRL (region 5, slot 0, paddr 0x0A0) must reach tidelink_perf as "
        f"region=0b00 addr=0: got write={s['write']} region=0b{s['region']:02b} "
        f"addr={s['addr']}. With region != 0b00 the PERF_CTRL write branch is "
        "unreachable and perf_enable_r stays 0 forever."
    )
    assert s["wdata"] == 0x0000_0001, "write data must pass through unmodified"


@cocotb.test()
async def cong_state_decodes_to_region_seven(dut):
    """PERF_CONG_STATE (ewma credit) lives at region 7 slot 6 = paddr 0x0F8.

    tidelink_perf.sv reads it under region 2'b10. With the raw-index bug the
    register answered at 0x0D8 (region 6) instead, and region 7 read back 0.
    """
    await setup(dut)
    s = await apb_write_sample(dut, addr_of(7, CONG_STATE_SLOT), 0)
    assert s["region"] == 0b10 and s["addr"] == CONG_STATE_SLOT, (
        "paddr 0x0F8 must present region=0b10 slot=6 to tidelink_perf: got "
        f"region=0b{s['region']:02b} addr={s['addr']}"
    )


@cocotb.test()
async def perf_write_bounded_to_regions_five_to_seven(dut):
    """perf_reg_write must not assert outside regions 5..7.

    Guards the subtraction: region 4 would underflow perf_reg_region to 2'b11,
    which is harmless ONLY while perf_reg_write stays low there. This test is
    what makes that reasoning safe to rely on.
    """
    await setup(dut)
    for region in (3, 4, 8, 9):
        s = await apb_write_sample(dut, (region << 5), 0xDEAD_BEEF)
        assert s["write"] == 0, (
            f"perf_reg_write must stay low for region {region} "
            f"(paddr 0x{region << 5:03X}) — perf owns only regions 5..7"
        )

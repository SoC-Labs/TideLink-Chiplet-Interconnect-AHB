"""Shared helpers for TideLink py_pair test suites.

Contains cocotb-specific AHB master monitor, APB read/write helpers,
setup/reset, and FIFO write helper. Pure-logic components (constants,
PairRegisterBank) are imported from the shared tidelink package.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

# Import shared constants and model from the tidelink package
from tidelink.regs import (
    MAX_TOKENS,
    OFF_PAIR_BASE_ADDR, OFF_PKT_WORD_LEN, OFF_TOKEN_COUNT,
    OFF_STATUS, OFF_DOORBELL, OFF_RELEASED_TOKENS,
    OFF_DOORBELL_RESPONSE, OFF_PAIR_TOKEN_COUNTER,
    OFF_PAIR_TOKEN_CONSUME, OFF_PAIR_TOKEN_ENABLE,
)
from tidelink.pair_model import PairRegisterBank

# ── Testbench-specific constants ─────────────────────────────────────────────
CLK_PERIOD_NS = 10
PAIR_BASE     = 0x4000_1000  # Must match tb_top parameter TIDELINK_PAIR_BASE


# ── AHB Master Monitor ──────────────────────────────────────────────────────

async def ahb_master_monitor(dut, pair_model):
    """Monitor the DUT's AHB master outputs and route writes to the pair model."""
    dut.ahbm_hready.value = 1
    dut.ahbm_hresp.value  = 0
    dut.ahbm_hrdata.value = 0

    pending_addr = None

    while True:
        await RisingEdge(dut.hclk)

        try:
            htrans = int(dut.ahbm_htrans.value)
            hwrite = int(dut.ahbm_hwrite.value)
        except ValueError:
            continue

        if htrans == 2 and hwrite == 1:
            pending_addr = int(dut.ahbm_haddr.value)
        elif pending_addr is not None:
            try:
                hwdata = int(dut.ahbm_hwdata.value)
            except ValueError:
                hwdata = 0

            dut._log.info(f"AHB Master write: addr=0x{pending_addr:08X} "
                          f"data=0x{hwdata:08X}")

            responses = pair_model.handle_ahb_write(pending_addr, hwdata)

            for resp_addr, resp_data in responses:
                await apb_write(dut, resp_addr, resp_data)

            pending_addr = None


# ── APB Helpers ──────────────────────────────────────────────────────────────

async def apb_write(dut, addr, data):
    """Perform an APB write to the DUT's APB slave interface."""
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 1
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 1
    dut.apbs_paddr.value   = addr & 0xFFF
    dut.apbs_pwdata.value  = data
    await RisingEdge(dut.hclk)
    dut.apbs_penable.value = 1
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0


async def apb_read(dut, addr):
    """Perform an APB read from the DUT's APB slave interface."""
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 1
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0
    dut.apbs_paddr.value   = addr & 0xFFF
    await RisingEdge(dut.hclk)
    dut.apbs_penable.value = 1
    await RisingEdge(dut.hclk)
    rdata = int(dut.apbs_prdata.value)
    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    return rdata


# ── Setup / Reset ────────────────────────────────────────────────────────────

async def setup(dut):
    """Start clock and initialise all inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())

    dut.ahbs_hsel.value    = 0
    dut.ahbs_hready.value  = 1
    dut.ahbs_htrans.value  = 0
    dut.ahbs_hsize.value   = 2
    dut.ahbs_hwrite.value  = 0
    dut.ahbs_haddr.value   = 0
    dut.ahbs_hwdata.value  = 0

    dut.ahbm_hready.value  = 1
    dut.ahbm_hresp.value   = 0
    dut.ahbm_hrdata.value  = 0

    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0
    dut.apbs_paddr.value   = 0
    dut.apbs_pwdata.value  = 0


async def do_reset(dut, cycles=5):
    """Assert reset for given cycles then deassert. Enables FIFO data window."""
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, cycles)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)
    # Enable FIFO data window: write CTRL.EN=1 (offset 0x01C)
    await apb_write(dut, 0x01C, 0x1)


# ── AHB Slave (FIFO) Write Helper ───────────────────────────────────────────

async def fifo_write_packet(dut, data_words):
    """Write a packet into the DUT's FIFO via the AHB slave interface."""
    pkt_len = len(data_words)

    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0000
    dut.ahbs_hready.value = 1
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = pkt_len
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    for i, word in enumerate(data_words):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 1
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_hwdata.value = word
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        await RisingEdge(dut.hclk)
        dut.ahbs_hwrite.value = 0

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)


# ── Common Test Setup Pattern ────────────────────────────────────────────────

async def setup_with_pair(dut):
    """Full test setup: clock, defaults, pair model, AHB monitor, reset.

    Returns the PairRegisterBank instance.
    """
    await setup(dut)
    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    cocotb.start_soon(ahb_master_monitor(dut, pair))
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    return pair

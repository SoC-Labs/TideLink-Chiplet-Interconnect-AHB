"""Cocotb unit tests for the tidelink_autoneg FSM.

Tests the auto-negotiation FSM in isolation — AXI-Lite responses are driven
by the test to simulate the I2C master core's behaviour.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# FSM state encoding (matches tidelink_autoneg.sv)
ST_IDLE       = 0
ST_NEGO_INIT  = 1
ST_NEGO_WAIT  = 2
ST_NEGO_CLAIM = 3
ST_NEGO_POLL  = 4
ST_NEGO_DONE  = 5
ST_BYPASS     = 6
ST_ERROR      = 7


async def setup(dut):
    """Start clock and initialise all inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())

    # Defaults: negotiation disabled, bus idle
    dut.nego_en.value = 0
    dut.nego_start.value = 0
    dut.nego_pri_sel.value = 0
    dut.nego_fallback.value = 1
    dut.nego_force_lock.value = 1
    dut.nego_priority_reg.value = 0xFFFF
    dut.nego_priority_i.value = 0
    dut.puf_seed.value = 0
    dut.puf_ready.value = 0
    dut.nego_timeout_reg.value = 131_082_000
    dut.i2c_sda_i.value = 1   # bus idle
    dut.i2c_scl_i.value = 1   # bus idle
    dut.i2c_prescale_reg.value = 500

    # AXI-Lite slave defaults: not ready, no response
    dut.m_axil_awready.value = 0
    dut.m_axil_wready.value = 0
    dut.m_axil_bresp.value = 0
    dut.m_axil_bvalid.value = 0
    dut.m_axil_arready.value = 0
    dut.m_axil_rdata.value = 0
    dut.m_axil_rresp.value = 0
    dut.m_axil_rvalid.value = 0


async def do_por(dut):
    """Assert POR for 5 cycles, then deassert."""
    dut.poresetn.value = 0
    await ClockCycles(dut.clk, 5)
    dut.poresetn.value = 1
    await ClockCycles(dut.clk, 2)


def get_state(dut):
    return int(dut.nego_state.value)


# ── Tests ──────────────────────────────────────────────────────────────────


@cocotb.test()
async def test_01_bypass_mode(dut):
    """NEGO-U01: nego_en=0 → FSM goes to ST_BYPASS."""
    await setup(dut)
    await do_por(dut)

    # Default: nego_en=0 → should transition to BYPASS
    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    assert state == ST_BYPASS, f"Expected ST_BYPASS ({ST_BYPASS}), got {state}"

    # nego_role_r should be 1 (slave default)
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (slave) in bypass"

    # No done, no error
    assert int(dut.nego_done.value) == 0
    assert int(dut.nego_error.value) == 0

    dut._log.info("NEGO-U01: Bypass mode — passed")


@cocotb.test()
async def test_02_nego_init_enters(dut):
    """NEGO-U02: nego_en=1 → FSM enters NEGO_INIT then NEGO_WAIT."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x0001
    dut.nego_pri_sel.value = 2  # PUF source
    await do_por(dut)

    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    # Should have passed through INIT into WAIT (PUF is ready)
    assert state == ST_NEGO_WAIT, f"Expected ST_NEGO_WAIT ({ST_NEGO_WAIT}), got {state}"

    dut._log.info("NEGO-U02: Negotiation enters WAIT — passed")


@cocotb.test()
async def test_03_puf_stall(dut):
    """NEGO-U10: PUF not ready → FSM stalls in ST_NEGO_INIT."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2  # PUF source
    dut.puf_ready.value = 0     # PUF not ready
    await do_por(dut)

    await ClockCycles(dut.clk, 10)

    state = get_state(dut)
    assert state == ST_NEGO_INIT, f"Expected ST_NEGO_INIT ({ST_NEGO_INIT}), got {state}"

    # Now set PUF ready
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x1234
    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    assert state == ST_NEGO_WAIT, f"After PUF ready, expected ST_NEGO_WAIT, got {state}"

    dut._log.info("NEGO-U10: PUF stall and release — passed")


@cocotb.test()
async def test_04_sda_early_exit(dut):
    """NEGO-U03: SDA START detected during NEGO_WAIT → becomes slave."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0       # register priority
    dut.nego_priority_reg.value = 0xFFFF  # max delay (won't expire in test)
    dut.nego_force_lock.value = 1
    await do_por(dut)

    # Wait for NEGO_WAIT
    for _ in range(20):
        await RisingEdge(dut.clk)
        if get_state(dut) == ST_NEGO_WAIT:
            break
    assert get_state(dut) == ST_NEGO_WAIT, "FSM should be in NEGO_WAIT"

    # Inject I2C START: SDA falling while SCL high
    dut.i2c_scl_i.value = 1
    dut.i2c_sda_i.value = 1
    await RisingEdge(dut.clk)
    dut.i2c_sda_i.value = 0  # falling edge
    await ClockCycles(dut.clk, 3)

    state = get_state(dut)
    assert state == ST_NEGO_DONE, f"Expected ST_NEGO_DONE after SDA START, got {state}"
    assert int(dut.nego_lost.value) == 1, "nego_lost should be 1"
    assert int(dut.sda_start_seen.value) == 1, "sda_start_seen should be 1"
    assert int(dut.nego_done.value) == 1, "nego_done should be 1"
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (slave)"

    dut._log.info("NEGO-U03: SDA early exit — passed")


@cocotb.test()
async def test_05_timeout(dut):
    """NEGO-U04: Short timeout → ST_ERROR with fallback role."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0
    dut.nego_priority_reg.value = 0xFFFF  # max backoff
    dut.nego_timeout_reg.value = 50       # very short timeout
    dut.nego_fallback.value = 1           # fallback = slave
    dut.nego_force_lock.value = 1
    await do_por(dut)

    # Wait for timeout (50 + some cycles for INIT→WAIT transition)
    await ClockCycles(dut.clk, 80)

    state = get_state(dut)
    assert state == ST_ERROR, f"Expected ST_ERROR after timeout, got {state}"
    assert int(dut.nego_error.value) == 1, "nego_error should be 1"
    assert int(dut.nego_error_irq.value) == 1, "nego_error_irq should be 1"
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (fallback=slave)"

    dut._log.info("NEGO-U04: Timeout with fallback — passed")


@cocotb.test()
async def test_06_force_lock_disabled(dut):
    """NEGO-U06: force_lock=0 → SDA early-exit sets role but no auto-lock."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0
    dut.nego_priority_reg.value = 0xFFFF
    dut.nego_force_lock.value = 0  # no auto-lock
    await do_por(dut)

    # Wait for NEGO_WAIT
    for _ in range(20):
        await RisingEdge(dut.clk)
        if get_state(dut) == ST_NEGO_WAIT:
            break

    # Inject SDA START to resolve as slave
    dut.i2c_sda_i.value = 0
    await ClockCycles(dut.clk, 3)

    assert get_state(dut) == ST_NEGO_DONE, "Should be in NEGO_DONE"
    assert int(dut.nego_done.value) == 1
    assert int(dut.nego_role_r.value) == 1, "Should be slave"

    dut._log.info("NEGO-U06: Force lock disabled — passed")


@cocotb.test()
async def test_07_puf_priority_used(dut):
    """NEGO-U09: pri_sel=2 uses puf_seed as priority for backoff delay."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2  # PUF
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x0000  # lowest possible priority → shortest delay
    dut.nego_timeout_reg.value = 100_000
    await do_por(dut)

    # With priority=0, backoff = 0 * NEGO_TICK + NEGO_BASE_DELAY = 2000 cycles
    # Should reach NEGO_CLAIM after ~2000 cycles
    await ClockCycles(dut.clk, 2020)

    state = get_state(dut)
    assert state in [ST_NEGO_CLAIM, ST_NEGO_POLL], \
        f"Expected CLAIM or POLL state with PUF priority=0, got {state}"
    assert int(dut.nego_role_r.value) == 0, "nego_role_r should be 0 (master) during claim"

    dut._log.info("NEGO-U09: PUF priority source — passed")

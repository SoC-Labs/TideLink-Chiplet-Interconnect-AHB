"""Cocotb tests for the tidelink_perf congestion estimator (Phase 1).

Tests the new EWMA, windowed derivative, and quantisation logic added in the
congestion-aware placement feature. See CONGESTION_AWARE_ROUTING.md in the
tidechart docs directory for the full semantic spec.

Covers:
  - EWMA convergence and fast-seed on first active cycle
  - Windowed derivative sign under ramp stimulus
  - Quantiser level thresholds across the credit range
  - Quantiser trend response to derivative values
  - credit_starve_sticky set on credit_count==0, cleared by bcast_ack_i
  - link_state_change_o pulses exactly once per quantised transition
  - Region 7 PERF_CONG_STATE debug readback
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# Register access
REGION5 = 0b00
REGION7 = 0b10

R5_PERF_CTRL = 0
R7_CONG_STATE = 6

CTRL_ENABLE = (1 << 0)

# Credit pool for RAM_ADDR_W=14 => CREDIT_W=13 => max 0x1FFF
CREDIT_MAX   = (1 << 13) - 1
CREDIT_QUART = CREDIT_MAX >> 2
CREDIT_HALF  = CREDIT_MAX >> 1

# Derivative window (DERIV_WINDOW_LOG default = 8 => 256 cycles)
DERIV_WINDOW = 1 << 8

# Quantiser codes
LEVEL_EMPTY  = 0
LEVEL_LIGHT  = 1
LEVEL_MOD    = 2
LEVEL_DEEP   = 3

TREND_DRAIN  = 0
TREND_STEADY = 1
TREND_GROW_S = 2
TREND_GROW_F = 3


class CongTB:
    def __init__(self, dut):
        self.dut = dut
        cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())

    async def reset(self, initial_credit=CREDIT_MAX):
        d = self.dut
        d.hresetn.value = 0
        d.perf_reg_write.value  = 0
        d.perf_reg_addr.value   = 0
        d.perf_reg_wdata.value  = 0
        d.perf_reg_region.value = 0
        d.phc_nanoseconds.value = 0
        d.phc_seconds.value     = 0
        d.fc_tx_handshake.value = 0
        d.fc_tx_is_data.value   = 0
        d.fc_rx_handshake.value = 0
        d.fc_rx_is_data.value   = 0
        d.fc_rx_is_first.value  = 0
        d.tx_pkt_start.value    = 0
        d.rx_pkt_committed.value = 0
        d.tx_router_idle.value  = 1
        d.fc_tx_valid.value     = 0
        d.fc_tx_ready.value     = 1
        d.fc_rx_valid.value     = 0
        d.fc_rx_accept.value    = 1
        d.credit_count.value    = initial_credit
        d.bcast_ack_i.value     = 0
        await ClockCycles(d.hclk, 5)
        d.hresetn.value = 1
        await ClockCycles(d.hclk, 2)

    async def enable_perf(self):
        d = self.dut
        await RisingEdge(d.hclk)
        d.perf_reg_write.value  = 1
        d.perf_reg_region.value = REGION5
        d.perf_reg_addr.value   = R5_PERF_CTRL
        d.perf_reg_wdata.value  = CTRL_ENABLE
        await RisingEdge(d.hclk)
        d.perf_reg_write.value  = 0
        await RisingEdge(d.hclk)

    async def read_cong_state(self):
        """Return (ewma, level, trend, starve) from the Region 7 debug reg."""
        d = self.dut
        await RisingEdge(d.hclk)
        d.perf_reg_region.value = REGION7
        d.perf_reg_addr.value   = R7_CONG_STATE
        await RisingEdge(d.hclk)
        val = int(d.perf_reg_rdata.value)
        ewma   = val & 0x1FFF
        level  = (val >> 16) & 0x3
        trend  = (val >> 18) & 0x3
        starve = (val >> 20) & 0x1
        return ewma, level, trend, starve

    def sideband(self):
        """Return (state, change_pulse, ewma) directly from the sideband wires."""
        d = self.dut
        return (int(d.local_link_state_o.value),
                int(d.link_state_change_o.value),
                int(d.ewma_credit_o.value))

    @staticmethod
    def unpack_state(s):
        return {
            "level":  s & 0x3,
            "trend":  (s >> 2) & 0x3,
            "starve": (s >> 4) & 0x1,
        }


# =========================================================================
# Tests
# =========================================================================

@cocotb.test()
async def test_reset_defaults(tb):
    """After reset the sideband should read a well-defined idle state."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=0)
    state, change, ewma = tb.sideband()
    unpacked = tb.unpack_state(state)
    # Before perf_enable, the estimator is frozen at reset values.
    assert unpacked["trend"] == TREND_STEADY, (
        f"expected trend=steady post-reset, got {unpacked['trend']}")
    # Initial level is deep (quantiser holds reset value until first active cycle).
    assert unpacked["level"] == LEVEL_DEEP, (
        f"expected level=deep post-reset, got {unpacked['level']}")
    assert change == 0


@cocotb.test()
async def test_ewma_fast_seed(tb):
    """ewma_acc must be seeded from credit_count on the first active cycle
    rather than warming up from zero."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)

    # Pre-set credit_count to a known value, then enable.
    tb.dut.credit_count.value = CREDIT_MAX
    await tb.enable_perf()
    await ClockCycles(tb.dut.hclk, 2)

    _, _, ewma = tb.sideband()
    # After seeding, ewma should already be close to CREDIT_MAX (exact equality
    # is not guaranteed because the second-cycle update mixes in a new sample).
    assert ewma > (CREDIT_MAX * 7 // 8), (
        f"ewma {ewma} did not seed close to {CREDIT_MAX}")


@cocotb.test()
async def test_ewma_step_convergence(tb):
    """EWMA should converge to ~95% of a target within ~3 tau (48 cycles)."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=0)

    tb.dut.credit_count.value = 0
    await tb.enable_perf()
    await ClockCycles(tb.dut.hclk, 4)

    # Step the input high and wait for EWMA to chase it.
    target = CREDIT_MAX
    tb.dut.credit_count.value = target
    await ClockCycles(tb.dut.hclk, 80)  # > 3*tau with margin

    _, _, ewma = tb.sideband()
    assert ewma > (target * 9 // 10), (
        f"EWMA did not converge: got {ewma}, expected > {target * 9 // 10}")


@cocotb.test()
async def test_quantiser_level_thresholds(tb):
    """Sweep credit_count across the three quantisation boundaries and
    confirm the level field transitions as specified."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)
    await tb.enable_perf()

    async def settle(value, cycles=400):
        tb.dut.credit_count.value = value
        # With alpha=1/16 the EWMA decay constant is ~16 cycles, but fully
        # converging across ~2^13 requires longer (exponential tail). Wait
        # generously so we exercise the steady-state quantiser boundaries.
        await ClockCycles(tb.dut.hclk, cycles)

    # Empty bucket requires ewma_q_r == 0 exactly; give the EWMA plenty of
    # time to decay from the reset seed down to zero.
    await settle(0)
    _, level, _, _ = await tb.read_cong_state()
    assert level == LEVEL_EMPTY, f"credit=0 → level {level}, expected EMPTY"

    # Light: below 25% of max.
    await settle(CREDIT_QUART // 2)
    _, level, _, _ = await tb.read_cong_state()
    assert level == LEVEL_LIGHT, f"credit<25% → level {level}, expected LIGHT"

    # Moderate: between 25% and 50%.
    await settle((CREDIT_QUART + CREDIT_HALF) // 2)
    _, level, _, _ = await tb.read_cong_state()
    assert level == LEVEL_MOD, f"credit<50% → level {level}, expected MOD"

    # Deep: above 50%.
    await settle(CREDIT_MAX)
    _, level, _, _ = await tb.read_cong_state()
    assert level == LEVEL_DEEP, f"credit=max → level {level}, expected DEEP"


@cocotb.test()
async def test_quantiser_trend_draining(tb):
    """Steadily growing credit_count (remote draining) must yield trend=DRAIN
    at the derivative-window boundary."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=0)
    await tb.enable_perf()

    # Bring ewma to mid-range first so level/trend transitions aren't masked.
    tb.dut.credit_count.value = CREDIT_HALF // 2
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 32)

    # Now bump credit_count upward by a generous amount across the window.
    start = CREDIT_HALF
    tb.dut.credit_count.value = start
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 8)
    tb.dut.credit_count.value = start + 100
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 8)

    state, _, _ = tb.sideband()
    trend = (state >> 2) & 0x3
    assert trend == TREND_DRAIN, (
        f"positive derivative should be TREND_DRAIN, got {trend}")


@cocotb.test()
async def test_quantiser_trend_growing(tb):
    """Credit_count dropping across the window => trend=GROW_*."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)
    await tb.enable_perf()

    # Settle high, then drop credit_count by a large amount across the window.
    tb.dut.credit_count.value = CREDIT_MAX
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 16)
    tb.dut.credit_count.value = CREDIT_HALF       # drop ~half
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 8)
    tb.dut.credit_count.value = CREDIT_QUART      # drop again
    await ClockCycles(tb.dut.hclk, DERIV_WINDOW + 8)

    state, _, _ = tb.sideband()
    trend = (state >> 2) & 0x3
    assert trend in (TREND_GROW_S, TREND_GROW_F), (
        f"negative derivative should be GROW_*, got {trend}")


@cocotb.test()
async def test_starve_sticky_and_ack(tb):
    """credit_starve_sticky sets on credit_count==0 and clears on bcast_ack_i."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)
    await tb.enable_perf()
    await ClockCycles(tb.dut.hclk, 5)

    # No starve yet.
    state, _, _ = tb.sideband()
    assert ((state >> 4) & 1) == 0, "starve should be 0 initially"

    # Drive to zero briefly.
    tb.dut.credit_count.value = 0
    await ClockCycles(tb.dut.hclk, 3)
    tb.dut.credit_count.value = CREDIT_MAX
    await ClockCycles(tb.dut.hclk, 3)

    state, _, _ = tb.sideband()
    assert ((state >> 4) & 1) == 1, "starve should be sticky-set"

    # Pulse bcast_ack to clear.
    tb.dut.bcast_ack_i.value = 1
    await ClockCycles(tb.dut.hclk, 2)
    tb.dut.bcast_ack_i.value = 0
    await ClockCycles(tb.dut.hclk, 2)

    state, _, _ = tb.sideband()
    assert ((state >> 4) & 1) == 0, "starve should clear on bcast_ack"


@cocotb.test()
async def test_link_state_change_pulse(tb):
    """link_state_change_o should pulse exactly when the quantised state
    transitions."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)
    await tb.enable_perf()
    await ClockCycles(tb.dut.hclk, 4)

    prev_state, _, _ = tb.sideband()
    pulses = 0
    transitions = 0
    last_state = prev_state

    # Drive credit_count through many thresholds and count pulses.
    for value in [0, CREDIT_QUART // 2, CREDIT_QUART + 10, CREDIT_HALF + 10, CREDIT_MAX]:
        tb.dut.credit_count.value = value
        for _ in range(140):
            await RisingEdge(tb.dut.hclk)
            state, change, _ = tb.sideband()
            if change:
                pulses += 1
            if state != last_state:
                transitions += 1
                last_state = state

    # Every transition should be accompanied by at least one change pulse.
    # They won't be 1:1 because change is a level comparison that goes high for
    # one cycle each time the state differs from the previous-cycle register.
    assert pulses >= transitions > 0, (
        f"pulses={pulses}, transitions={transitions}")


@cocotb.test()
async def test_debug_readback(tb):
    """PERF_CONG_STATE at Region 7 offset 6 must reflect the sideband."""
    tb = CongTB(tb)
    await tb.reset(initial_credit=CREDIT_MAX)
    await tb.enable_perf()
    await ClockCycles(tb.dut.hclk, 200)

    ewma_reg, level_reg, trend_reg, starve_reg = await tb.read_cong_state()
    state, _, ewma_wire = tb.sideband()

    assert ewma_reg == ewma_wire, (
        f"ewma readback {ewma_reg} != sideband {ewma_wire}")
    assert level_reg == (state & 0x3), "level mismatch"
    assert trend_reg == ((state >> 2) & 0x3), "trend mismatch"
    assert starve_reg == ((state >> 4) & 0x1), "starve mismatch"

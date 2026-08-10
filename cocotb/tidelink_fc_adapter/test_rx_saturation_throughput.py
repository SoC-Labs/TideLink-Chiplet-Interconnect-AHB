"""RX saturation throughput floor regression — tidelink_fc_adapter.sv.

BACKGROUND (link-survey 2026-08-01): the RX FSM (RX_IDLE -> RX_ADDR_PHASE ->
RX_IDLE for FIFO_DATA packets) has an off-by-one in the RX_IDLE ->
RX_ADDR_PHASE transition. `rx_accept` (the combinational signal that latches
an incoming FC word into rx_fc_word_r/rx_pending_r) can fire the same cycle
the FSM is sitting in RX_IDLE, but the old `rx_state_next` logic only left
RX_IDLE on the *registered* rx_pending_r, not on the combinational rx_accept
— so the FSM had to wait one extra idle cycle for rx_pending_r to register
before it could even start moving to RX_ADDR_PHASE. Under full saturation
(tl_fc_l2a_valid held high, fc_rx_fifo_ready held high, no backpressure
anywhere) that manifests as a hard throughput floor of 3 hclk cycles per
word, when the FSM only actually needs 2 (1 cycle to latch + 1 cycle to
issue the FIFO write).

THE FIX: tidelink_fc_adapter.sv's RX_IDLE case now tests
`rx_pending_r || rx_accept`, letting the FSM leave RX_IDLE the very cycle a
word is accepted. This collapses the floor from 3 -> 2 cycles/word.

This test drives the FC RX interface saturated (tl_fc_l2a_valid permanently
asserted, a fresh FIFO_DATA word presented immediately after every accept)
with fc_rx_fifo_ready held high, and measures the steady-state gap between
consecutive tl_fc_l2a_accept pulses. It is a hard regression gate: it must
read exactly 2 cycles/word. If this ever regresses back to 3 (or anything
else), the test fails — the RX floor must never silently regress.
"""

import cocotb
from cocotb.triggers import RisingEdge

from test_tidelink_fc_adapter import (
    PKT_FIFO_DATA,
    FCDriver,
    setup,
    do_reset,
)

# Number of accepted words to sample before judging steady state.
NUM_WORDS = 24
# First N accept events are discarded to avoid any reset/startup transient
# polluting the measurement.
WARMUP_WORDS = 4

EXPECTED_CYCLES_PER_WORD = 2


@cocotb.test()
async def test_rx_saturation_cycles_per_word(dut):
    """RX FIFO_DATA saturation floor must be exactly 2 hclk cycles/word.

    No backpressure anywhere: tl_fc_l2a_valid held high continuously and
    fc_rx_fifo_ready held high. Measures the accept-to-accept cycle gap
    over NUM_WORDS accepted words and asserts it is uniform and equal to
    EXPECTED_CYCLES_PER_WORD.
    """
    await setup(dut)
    await do_reset(dut)

    # No downstream backpressure on the FIFO direct-write port.
    dut.fc_rx_fifo_ready.value = 1

    accept_cycle = []  # hclk edge index (1-based) at which each accept fired
    cycle = 0
    word_idx = 0

    # Prime the bus with the first word and hold valid high permanently —
    # this is the saturation condition: the source never de-asserts valid.
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value = FCDriver.encode(
        PKT_FIFO_DATA, (word_idx * 4) & 0x3FFF, 0xA0000000 | word_idx)

    while len(accept_cycle) < NUM_WORDS:
        await RisingEdge(dut.hclk)
        cycle += 1
        if int(dut.tl_fc_l2a_accept.value) == 1:
            accept_cycle.append(cycle)
            word_idx += 1
            # Immediately present the next word — still saturated (valid
            # never drops), matching a source that always has data ready.
            dut.tl_fc_l2a_data.value = FCDriver.encode(
                PKT_FIFO_DATA, (word_idx * 4) & 0x3FFF, 0xA0000000 | word_idx)

    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value = 0

    gaps = [accept_cycle[i] - accept_cycle[i - 1]
            for i in range(1, len(accept_cycle))]
    dut._log.info(f"RX saturation accept-cycle gaps (all): {gaps}")

    steady_gaps = gaps[WARMUP_WORDS:]
    assert steady_gaps, "not enough accepted words to measure steady state"

    assert all(g == steady_gaps[0] for g in steady_gaps), (
        f"RX saturation accept gap is not uniform in steady state: "
        f"{steady_gaps} (full sequence: {gaps})")

    assert steady_gaps[0] == EXPECTED_CYCLES_PER_WORD, (
        f"RX saturation floor regressed: measured "
        f"{steady_gaps[0]} cycles/word, expected exactly "
        f"{EXPECTED_CYCLES_PER_WORD}. Full gap sequence: {gaps}")

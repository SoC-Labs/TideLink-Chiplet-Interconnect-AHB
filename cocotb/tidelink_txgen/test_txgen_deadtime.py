"""Per-packet dead-time regression (link-survey campaign, 2026-08-01).

CONTEXT. tidelink_tx_gen's sequencer is strictly serialized: nothing about
packet N+1 is computed while packet N is still in S_SEND. Concretely, once a
packet's final data phase drains, the FSM must pass through S_GAP (even when
the configured inter-packet gap `gap_r` is already zero — the check-then-
transition itself costs a registered cycle) and then S_ARMED (which latches
`total_beats_r`/`beat_r` and re-validates `can_take` before the next packet's
first address can be driven) before S_SEND resumes. With IPG=0 that is 2 dead
hclk cycles per packet in which `gen_owns` is low and nothing productive
happens — confirmed here on unmodified RTL before the fix below existed.

THE FIX (src/rtl/tidelink_tx_gen.sv, S_SEND's final-data-phase branch): when
the packet that just finished has `ipg_r == '0`, skip S_GAP entirely and
transition straight to S_ARMED. This is safe because S_GAP's own zero-gap
path did nothing but immediately re-check `running_r` and fall through to
S_ARMED (or S_IDLE) on its very next cycle — S_ARMED unconditionally
re-validates `running_r`/`budget_r`/`can_take` regardless of which state it
was entered from, so admission safety is unaffected; only the timing of that
check moves one cycle earlier. The non-zero-gap path (`gap_r` counting down
from `ipg_r`) is completely untouched — it still costs `ipg_r + 1` cycles in
S_GAP plus 1 in S_ARMED, exactly as before.

THE INSTRUMENT. `stall_r` (R_STALL) already counts every hclk cycle the
generator is `running_r` and NOT in S_SEND (plus a separate AHB-busy term
that is inert here because the bench holds `tl_fc_a2l_ready` high the whole
time, so the adapter's `fc_hreadyout` never de-asserts and no S_SEND cycle is
ever a stall). With the link never back-pressured, every non-S_SEND cycle
while running is exactly the dead time this fix targets, so
  dead_cycles_per_packet = delta(R_STALL) / delta(R_WORDS)/(n+2)
is a direct, byte-exact measurement — no timing heuristics, no sampling
windows to tune.

WHAT THIS FILE LOCKS IN.
  test_deadtime_zero_gap_is_one_cycle_or_less   — IPG=0: <=1 dead cycle/pkt
      post-fix (was 2 pre-fix; this is the fix's whole purpose. A future
      regression back to 2 fails this test).
  test_deadtime_nonzero_gap_is_unaffected       — IPG=3: exactly 5 dead
      cycles/pkt (3 gap + 1 S_GAP-exit check + 1 S_ARMED), proving the fix's
      `ipg_r=='0` special-case did not change the general gapped path.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_txgen_unit import reset, wr, rd, R_CTRL, R_PKT, R_GAP, R_WORDS, R_STALL, \
    CTRL_EN, CTRL_FOREVER, CTRL_START


async def _measure_dead_cycles_per_packet(dut, n, ipg, warmup=200, window=4000):
    """Arm the generator (link never back-pressured) and return the measured
    dead (non-S_SEND, running) cycles per packet, plus the raw deltas so a
    caller can log the evidence.
    """
    await reset(dut)
    dut.tl_fc_a2l_ready.value = 1
    per_packet = n + 2

    await wr(dut, R_PKT, n)
    await wr(dut, R_GAP, ipg)
    await wr(dut, R_CTRL, CTRL_EN | CTRL_FOREVER)
    await wr(dut, R_CTRL, CTRL_EN | CTRL_FOREVER | CTRL_START)

    await ClockCycles(dut.hclk, warmup)          # let it reach steady state
    w0 = int(await rd(dut, R_WORDS))
    s0 = int(await rd(dut, R_STALL))
    await ClockCycles(dut.hclk, window)
    w1 = int(await rd(dut, R_WORDS))
    s1 = int(await rd(dut, R_STALL))

    words_delta = w1 - w0
    stall_delta = s1 - s0
    assert words_delta > 0, "generator produced no words in the measurement window"
    packets = words_delta / per_packet
    dead_per_pkt = stall_delta / packets
    return dead_per_pkt, words_delta, stall_delta, packets


@cocotb.test()
async def test_deadtime_zero_gap_is_one_cycle_or_less(dut):
    """IPG=0 ⇒ at most 1 dead hclk cycle between packets (was 2 pre-fix).

    This is the direct regression for the S_GAP-skip fix: if S_GAP's extra
    registered check cycle ever comes back for the zero-gap case, this fails.
    """
    n = 6
    dead_per_pkt, words_delta, stall_delta, packets = \
        await _measure_dead_cycles_per_packet(dut, n=n, ipg=0)

    dut._log.info(
        f"[deadtime] IPG=0, n={n}: {words_delta} words / {packets:.1f} packets, "
        f"stall delta={stall_delta} => {dead_per_pkt:.3f} dead cycles/packet "
        f"(pre-fix baseline was 2.0)"
    )
    assert dead_per_pkt <= 1.05, (
        f"measured {dead_per_pkt:.3f} dead cycles/packet with IPG=0, expected "
        f"<=1 (S_GAP should be skipped entirely when gap_r is already 0). "
        f"This is the fix's whole purpose — a regression back toward 2.0 means "
        f"S_GAP is being entered again on the zero-gap path."
    )
    assert dead_per_pkt >= 0.90, (
        f"measured {dead_per_pkt:.3f} dead cycles/packet with IPG=0 — "
        f"suspiciously below the S_ARMED floor of 1 cycle (a single registered "
        f"state is structurally required to latch total_beats_r/beat_r before "
        f"S_SEND can resume); this smells like a broken measurement rather "
        f"than a real improvement, double check the instrument"
    )


@cocotb.test()
async def test_deadtime_nonzero_gap_is_unaffected(dut):
    """IPG=3 ⇒ exactly 5 dead cycles/packet (3 gap + 1 S_GAP-exit + 1 S_ARMED),
    unchanged by the zero-gap fix. Pins the claim that the fix's `ipg_r=='0'`
    special case does not touch the general (nonzero-gap) path at all.
    """
    n = 6
    ipg = 3
    dead_per_pkt, words_delta, stall_delta, packets = \
        await _measure_dead_cycles_per_packet(dut, n=n, ipg=ipg)

    expected = ipg + 2
    dut._log.info(
        f"[deadtime] IPG={ipg}, n={n}: {words_delta} words / {packets:.1f} "
        f"packets, stall delta={stall_delta} => {dead_per_pkt:.3f} dead "
        f"cycles/packet (expected exactly {expected})"
    )
    assert abs(dead_per_pkt - expected) <= 0.05, (
        f"measured {dead_per_pkt:.3f} dead cycles/packet with IPG={ipg}, "
        f"expected {expected} ({ipg} gap-countdown cycles + 1 S_GAP-exit "
        f"check + 1 S_ARMED admission cycle). The zero-gap fast path must not "
        f"perturb the general gapped path's cycle count."
    )

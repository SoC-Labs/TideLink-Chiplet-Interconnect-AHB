"""V2 SUSTAINED / LONG-BURST data gate.

Closes the gap between "a packet works" and "the channel works". Everything
proven on silicon to date is a SINGLE 4-word framed packet per direction on a
quiescent link. This suite sweeps burst LENGTH and sends BACK-TO-BACK packets
in both directions, byte-checking EVERY word.

Why every word, explicitly:
  The legacy `send_and_check` oracle asserts only got[0], got[2], got[3] --
  it never checks got[1], and it only ever runs at payload_len=2. The recorded
  silicon defect is "long burst drops the first ~2 words (both directions)",
  and the phantom-pop defect class (project_rxfifo_empty_read_phantom_pop,
  fixed f9b94b7) walks read_ptr by EXACTLY 2 words. A 2-word shift is
  invisible to an oracle that does not compare the leading words against their
  own expected values -- so this suite uses send_and_check_burst, which diffs
  all length+2 words.

Oracles:
  test_10  M->S burst-length sweep 2..128 payload words, every word exact.
  test_11  S->M burst-length sweep, same.
  test_12  M->S back-to-back packets (no inter-packet idle), every word exact,
           every packet.
  test_13  S->M back-to-back packets, same.
  test_14  bidirectional concurrent bursts (both directions in flight at once).

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_pair_sustained
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check_burst,
    make_packet, read_packet_drain, diff_words,
)

# Payload word counts to sweep. 2 = the only length ever proven on silicon;
# everything above it is new coverage. 126 payload words = 128 FIFO words.
# Override for focused runs, e.g. TD_SWEEP_LENS="8" to isolate ONE size with its
# own bring-up. Essential under EPOCH_PROFILE=silicon, where the first failure
# WEDGES the link (330e2a7: the replay storm ratchets to credit-max and wedges
# exp, POR-only clear) so every later size in the same bring-up is cascade.
SWEEP_LENS = [int(x) for x in os.environ.get(
    "TD_SWEEP_LENS", "2 4 8 16 32 64 126").split()]

# Number of back-to-back packets in the b2b tests.
B2B_PACKETS = 4
B2B_PAYLOAD_LEN = 4


def payload_for(n, seed):
    """Distinct, position-encoding payload: a wrong-position word is a
    mismatch, so a SHIFT (the 'drops first 2 words' signature) is caught
    rather than aliasing onto a neighbouring word."""
    return [(seed << 16) | i for i in range(n)]


@cocotb.test()
async def test_10_burst_sweep_master_to_slave(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    results = {}
    for n in SWEEP_LENS:
        ok, got, mism = await send_and_check_burst(
            tb, "m", "s", payload_for(n, 0xA2B0), ctx=f"m2s-len{n}",
            expect_pass=False)
        results[n] = (ok, mism)
        tb.log.info(f"  [SWEEP m2s] len={n}: {'PASS' if ok else 'FAIL'}")

    _report_sweep(tb, "m2s", results)


@cocotb.test()
async def test_11_burst_sweep_slave_to_master(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    results = {}
    for n in SWEEP_LENS:
        ok, got, mism = await send_and_check_burst(
            tb, "s", "m", payload_for(n, 0xB2A0), ctx=f"s2m-len{n}",
            expect_pass=False)
        results[n] = (ok, mism)
        tb.log.info(f"  [SWEEP s2m] len={n}: {'PASS' if ok else 'FAIL'}")

    _report_sweep(tb, "s2m", results)


def _report_sweep(tb, ctx, results):
    """Emit a per-size table so the drop-threshold is visible, then assert.

    IMPORTANT — the sizes share ONE bring-up, so the sizes are NOT independent
    measurements once anything fails. A failed burst leaves the RX FIFO's
    read_ptr/write_ptr mid-packet, and every LATER size then reads stale bytes
    at a misaligned pointer. Measured 2026-07-15: after a len=16 failure, sizes
    32/64/126 all returned the IDENTICAL stale words despite different headers.
    Only the FIRST failing size is real evidence; everything after it is
    cascade. The table labels this rather than letting a future reader (or a
    future me) read seven independent failures where there is one.
    """
    tb.log.info(f"  ===== {ctx} burst-length sweep =====")
    seen_fail = False
    for n, (ok, mism) in results.items():
        detail = ""
        if mism:
            detail = (f" first_bad_idx={mism[0][0]} "
                      f"({len(mism)} words wrong)")
        taint = "  <- CASCADE (not independent; see docstring)" if (
            seen_fail and not ok) else ""
        tb.log.info(
            f"    payload_len={n:4d} -> {'PASS' if ok else 'FAIL'}{detail}{taint}")
        if not ok:
            seen_fail = True
    bad = [n for n, (ok, _) in results.items() if not ok]
    first_bad = bad[0] if bad else None
    assert not bad, (
        f"{ctx}: burst lengths {bad} did not deliver byte-exact "
        f"(passing lengths: {[n for n, (ok, _) in results.items() if ok]}). "
        f"THE ONLY TRUSTWORTHY DATA POINT IS THE FIRST: payload_len={first_bad} "
        f"first_bad_idx={results[first_bad][1][0][0]}. Sizes after it share the "
        f"same bring-up and read a desynced FIFO — diagnose {first_bad} alone, "
        f"and re-run it in isolation before believing any threshold.")


@cocotb.test()
async def test_12_back_to_back_packets_master_to_slave(dut):
    await _b2b_packets(dut, "m", "s", 0xC2D0)


@cocotb.test()
async def test_13_back_to_back_packets_slave_to_master(dut):
    await _b2b_packets(dut, "s", "m", 0xD2C0)


async def _b2b_packets(dut, src, dst, seed):
    """Send B2B_PACKETS framed packets with NO idle between them, then drain
    and score each packet independently. This is the continual-traffic case:
    the single-packet tests always hand the link a quiescent window to
    recover in, which is exactly the condition that could hide a
    per-packet-boundary pointer or credit error."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    sent = [make_packet(payload_for(B2B_PAYLOAD_LEN, seed + p))
            for p in range(B2B_PACKETS)]

    # Push all packets back-to-back with NO inter-packet gap.
    for words in sent:
        await tb.ahb_tx_write_packet(src, words, gap=0)

    await ClockCycles(dut.hclk, 4000 + 600 * B2B_PACKETS * (B2B_PAYLOAD_LEN + 2))

    fails = []
    for p, words in enumerate(sent):
        got = await read_packet_drain(tb, dst, len(words))
        mism = diff_words(words, got)
        tb.log.info(
            f"  [b2b {src}->{dst}] packet {p}: "
            f"{'OK' if not mism else f'{len(mism)} MISMATCH'} "
            f"sent=[{', '.join(f'0x{w:08x}' for w in words)}] "
            f"got=[{', '.join(f'0x{w:08x}' for w in got)}]")
        if mism:
            fails.append((p, mism))

    assert not fails, (
        f"back-to-back {src}->{dst}: {len(fails)}/{B2B_PACKETS} packets "
        f"corrupt. First bad packet {fails[0][0]}, first bad word index "
        f"{fails[0][1][0][0]} (expected 0x{fails[0][1][0][1]:08x} got "
        f"0x{fails[0][1][0][2]:08x})")


@cocotb.test()
async def test_14_bidirectional_concurrent_burst(dut):
    """Both directions in flight simultaneously -- the sustained case the
    sequential tests never exercise. Credit return for A->B shares the link
    with B->A data, so a credit/data arbitration error only shows here."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    n = 16
    m2s = make_packet(payload_for(n, 0xE2F0))
    s2m = make_packet(payload_for(n, 0xF2E0))

    # Interleave the two directions' AHB writes so both are on the wire at
    # the same time.
    m_task = cocotb.start_soon(tb.ahb_tx_write_packet("m", m2s, gap=0))
    s_task = cocotb.start_soon(tb.ahb_tx_write_packet("s", s2m, gap=0))
    await m_task
    await s_task

    await ClockCycles(dut.hclk, 3000 + 400 * (n + 2))

    got_s = await read_packet_drain(tb, "s", len(m2s))
    got_m = await read_packet_drain(tb, "m", len(s2m))
    mism_s = diff_words(m2s, got_s)
    mism_m = diff_words(s2m, got_m)
    tb.log.info(f"  [bidir] m->s: {'OK' if not mism_s else f'{len(mism_s)} BAD'} "
                f"| s->m: {'OK' if not mism_m else f'{len(mism_m)} BAD'}")
    assert not mism_s and not mism_m, (
        f"bidirectional concurrent burst corrupt: "
        f"m->s {len(mism_s)} bad words, s->m {len(mism_m)} bad words")

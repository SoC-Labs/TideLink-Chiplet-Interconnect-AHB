"""FULL-LINK credit-return LOOP-CLOSURE proof (verification-only, no RTL touched).

Question: when die B (dst) DRAINS its RX FIFO (sequential-read pop ->
released_credits -> returner ships a credit-return SIDEBAND packet across the
FC link to die A), does die A's (src) PAIR_CREDIT_COUNTER (0x028) actually
INCREASE end-to-end IN SIM?

Mechanism under test (structurally, from the RTL):
  dst RX pop -> read_complete -> release accumulator crosses REL_THRESHOLD
  -> release_credits_trigger -> tidelink_returner AHB write of the released
  delta to the PEER's Released-Credits-Acc register (offset 0x020)
  -> tidelink_fc_adapter intercepts (prefix_fc_adapter path) and ships it as
  PKT_SIDEBAND over the FC link -> far (src) fc_adapter RX writes src APB
  offset 0x020 -> that write INCREMENTS src pair_credit_counter (0x028,
  tidelink_apb_regs.sv:375,390).

So the loop CLOSES iff, after a dst drain, SRC's 0x028 rises. dst's own 0x028
must NOT rise (only the far end receives the credit-return) -> negative control.

NOTE on threshold: REL_THRESHOLD POR default is 20 (apb_regs.sv:252), and the
shared bring-up never writes it, so a single small-packet drain (~4-6 credits)
would NOT cross it and NO credit-return would be emitted. This test writes
dst REL_THRESHOLD=0 (immediate release per pop) so one drain deterministically
emits a credit-return -- isolating the LOOP, not the threshold policy.

Run (force a fresh build; beware the stale-simv trap):
  cd cocotb/tidelink_top_pair_v2
  rm -rf sim_build_zero results.xml
  make EPOCH_PROFILE=zero MODULE=test_v2_credit_loop_close
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, read_packet_drain,
    APB_PAIR_CREDIT_COUNTER, APB_RELEASE_THRESHOLD,
)


async def _pcc(tb, side):
    return int(await tb.apb(side).read(APB_PAIR_CREDIT_COUNTER))


async def _credit_loop(dut, src, dst):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    # Immediate credit release per pop on the DRAINING die (dst), so a single
    # packet drain deterministically emits a credit-return sideband.
    await tb.apb(dst).write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 20)

    src_pcc0 = await _pcc(tb, src)
    dst_pcc0 = await _pcc(tb, dst)
    tb.log.info(f"[LOOP {src}->{dst}] BEFORE: src({src}) pcc={src_pcc0} "
                f"dst({dst}) pcc={dst_pcc0}")

    # Send a packet src->dst and DRAIN it on dst (the pop that must return credit).
    payload = [0xCC000000 | i for i in range(6)]   # 6-word payload
    words = make_packet(payload)                    # -> len(words) == 8
    await tb.ahb_tx_write_packet(src, words)
    await ClockCycles(dut.hclk, 4000)

    got = await read_packet_drain(tb, dst, len(words))
    tb.log.info(f"[LOOP {src}->{dst}] drained dst RX: "
                f"[{', '.join(f'0x{w:08x}' for w in got)}]")

    # Give the returner + FC link + far-side APB write time to propagate.
    for _ in range(6):
        await ClockCycles(dut.hclk, 2000)
        src_pcc = await _pcc(tb, src)
        if src_pcc != src_pcc0:
            break

    src_pcc1 = await _pcc(tb, src)
    dst_pcc1 = await _pcc(tb, dst)
    delta_src = src_pcc1 - src_pcc0
    delta_dst = dst_pcc1 - dst_pcc0
    tb.log.info(f"[LOOP {src}->{dst}] AFTER:  src({src}) pcc={src_pcc1} "
                f"(delta {delta_src:+d})  dst({dst}) pcc={dst_pcc1} "
                f"(delta {delta_dst:+d})")

    assert delta_src > 0, (
        f"CREDIT LOOP DID NOT CLOSE: after dst({dst}) drained its RX FIFO, "
        f"src({src}) PAIR_CREDIT_COUNTER stayed {src_pcc1} (was {src_pcc0}). "
        f"No credit-return reached the sender.")
    # Negative control: the draining die does not credit ITSELF.
    assert delta_dst == 0, (
        f"unexpected: draining die ({dst}) pcc rose by {delta_dst} "
        f"(credit-return should target the FAR end, not self)")
    tb.log.info(f"[LOOP {src}->{dst}] PASS: drain on {dst} raised {src}'s "
                f"pair-credit by {delta_src}; loop closed end-to-end.")
    return delta_src


@cocotb.test()
async def test_credit_loop_m_sends_s_drains(dut):
    """die A = master (src). die B = slave (dst) drains -> A's pcc must rise."""
    await _credit_loop(dut, src="m", dst="s")


@cocotb.test()
async def test_credit_loop_s_sends_m_drains(dut):
    """Reverse direction: die B = slave (src). die A = master (dst) drains
    -> B's pcc must rise."""
    await _credit_loop(dut, src="s", dst="m")

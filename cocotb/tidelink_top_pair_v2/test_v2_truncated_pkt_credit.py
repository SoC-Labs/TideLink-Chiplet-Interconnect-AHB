"""TRUNCATED-PACKET credit gate — the phantom-pop's surviving sibling.

DEFECT (measured 2026-07-15, sim-reproduced here):
  tidelink_fifo_ctrl.sv:270-278 — the credit counter saturates at ZERO on
  write_complete (the BUG-002 underflow fix) but has NO ceiling on
  read_complete:

      end else if (read_complete) begin
          credit_count_nxt = credit_count_r + (RAM_ADDR_W-1)'(packet_delta);

  So a read_complete for a packet the FIFO is not actually holding mints
  credit ABOVE MAX_CREDITS — an impossible state that OVER-ADVERTISES buffer
  space to the peer, inviting a real overrun of the receive buffer.

WHY THE f9b94b7 GUARD DOES NOT COVER THIS:
  That fix qualified the AHB-read length-latch arm with `&& !rx_fifo_empty`, so
  a read of offset 0 on an empty FIFO no longer arms anything. But
  `packet_active_r` / `packet_word_length_r` / `read_target_addr_r` are ALSO set
  by the FC WRITE path (fc_write_addr0, :198). If a packet's header arrives and
  the packet then NEVER completes (write_complete requires the exact
  write_target_addr), those stay armed. A subsequent reader sweep hits
  read_target_addr, read_complete fires (:107, gated only by packet_active_r),
  and credit is minted above max — with the empty-FIFO guard fully in place.

IS A TRUNCATED PACKET REACHABLE ON SILICON? Yes, by design:
  tidelink_fc_adapter.sv:250-300 — after TX_STALL_TIMEOUT (2^16 hclk) of
  continuous back-pressure the adapter DELIBERATELY abandons the in-flight beat
  with an AHB ERROR response. If the abandoned beat is a packet's last word,
  the RX packet never completes and this state is entered. Link errors and a
  data-mode toggle mid-packet do the same.

This test sends a header declaring N payload words but only delivers N-1 of
them, then drains — with NO harness misbehaviour of any kind.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_truncated_pkt_credit
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, make_packet

MAX_CREDITS = 1 << 12   # RAM_ADDR_W=14 -> tidelink_fifo_ctrl.sv:74


def credit_of(tb, side):
    return int(tb.top(side).u_tidelink_fifo.u_fifo_mem.credit_count.value)


@cocotb.test()
async def test_40_truncated_packet_must_not_mint_credit_above_max(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    n = 8
    payload = [(0x7C00 << 16) | i for i in range(n)]
    words = make_packet(payload)          # [hdr(len=8), dest, p0..p7] = 10 words

    # Deliver the header + all but the LAST payload word. write_complete needs
    # the beat at write_target_addr = (len+1)*4 = word 9, which never arrives,
    # so the packet is never committed -- but packet_active_r stays set.
    await tb.ahb_tx_write_packet("m", words[:-1], gap=4)
    await ClockCycles(dut.hclk, 3000 + 400 * len(words))

    cred_before = credit_of(tb, "s")
    tb.log.info(f"  after truncated packet: credit={cred_before} "
                f"(MAX={MAX_CREDITS})")
    assert cred_before <= MAX_CREDITS, \
        f"credit already above max before any read: {cred_before}"

    # A driver now drains, exactly as the protocol prescribes: offset 0 first,
    # then consecutive offsets. Nothing improper here.
    for i in range(len(words)):
        await tb.ahb_fifo_read_word("s", i * 4)

    cred_after = credit_of(tb, "s")
    tb.log.info(f"  after protocol-legal drain: credit={cred_after} "
                f"(MAX={MAX_CREDITS})")

    assert cred_after <= MAX_CREDITS, (
        f"CREDIT MINTED ABOVE MAX: credit_count={cred_after} > "
        f"MAX_CREDITS={MAX_CREDITS} after draining a TRUNCATED packet. The "
        f"RX buffer now advertises more space than it physically has; the peer "
        f"may overrun it. tidelink_fifo_ctrl.sv:277 needs the same saturation "
        f"the write side already has at :272.")

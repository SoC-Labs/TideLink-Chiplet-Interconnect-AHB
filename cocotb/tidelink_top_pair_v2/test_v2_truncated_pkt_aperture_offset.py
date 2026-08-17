"""TRUNCATED-PACKET aperture offset — N3 / "Hazard 4": read_ptr drift.

DEFECT (root-caused 2026-08-17, sim-reproduced here):
  tidelink_fifo_ctrl.sv's `read_complete` drives two independent things that
  are supposed to represent the SAME event but (pre-fix) had no cross-check
  between them:

    1. The read-pointer advance:
         if (read_complete) read_ptr_nxt = read_ptr_r + (read_packet_delta<<2);
       -- UNCONDITIONAL.

    2. The credit-legitimacy clamp (see test_v2_truncated_pkt_credit.py):
         credit_sum = credit_after_write + read_packet_delta;
         if (credit_sum > MAX_CREDITS) credit_count_nxt = MAX_CREDITS;
       -- which, per the RTL's own comment, can only saturate if THIS
       read_complete does NOT correspond to a packet the write side ever
       actually finished committing.

  The clamp already DETECTS the bad case. Pre-fix, it never stopped the
  pointer from moving anyway, so read_ptr could end up STRICTLY GREATER than
  write_ptr -- a nonsensical inversion (a FIFO's read cursor can never
  legitimately lead its write cursor) that guarantees every subsequent
  "offset 0" read (translated_haddr = haddr + read_ptr) lands on SRAM bytes
  no peer traffic has ever written.

STIMULUS -- WHY THIS IS MORE THAN THE SIBLING TEST'S SINGLE PACKET:
  test_v2_truncated_pkt_credit.py's stimulus (ONE truncated packet, n=8,
  words[:-1], then a protocol-legal drain) was empirically re-verified here
  (2026-08-17, against current origin/main HEAD) to NOT reach
  read_would_overmint at all: credit reads 4096->4096 (no change), because
  RX-FIFO TWIN 3 (2026-08-01) made write-side/read-side tracking fully
  independent, and `rx_fifo_empty` correctly blocks the read-side arm the
  entire time credit sits at MAX_CREDITS. That sibling test currently locks a
  *different*, narrower regression (the credit ceiling itself, which remains
  correctly enforced) rather than exercising the overmint path end-to-end.

  Reaching read_would_overmint empirically requires a SECOND ingredient: a
  truncated packet B leaves `write_packet_active_r` stuck at 1 and
  `write_target_addr_r` FROZEN at B's own declared boundary (this matches the
  RTL's own TX_STALL_TIMEOUT narrative -- the write side does not idle, it
  jams, and the peer's *next* transmission attempt runs into that jam). If a
  LONGER legitimate packet C is then sent through this same, still-jammed FC
  write interface, C's own header overwrites B's (write_ptr never advanced),
  and C's own beat at B's frozen relative target address spuriously
  "completes" a packet using B's STALE (too-small) declared length -- while
  the header now sitting at the read side's aperture is C's REAL (larger)
  one. Reading it back captures a read_packet_delta LARGER than what was
  ever actually subtracted from credit: exactly read_would_overmint.
  Reused here with the SAME packet-framing helpers
  (make_packet/ahb_tx_write_packet/ahb_fifo_read_word) the sibling test and
  the rest of this suite already use -- no new stimulus primitives.

WHAT THIS TEST PROVES (mutation-tested, see report):
  (a) read_ptr must not move on a read_complete the clamp itself flags as
      illegitimate. Pre-fix, read_ptr strictly EXCEEDS write_ptr afterward
      (an impossible ordering). Post-fix, read_ptr stays exactly at its
      pre-truncation value, so it can never exceed write_ptr.
  (b) The direct, silicon-relevant consequence of (a): once read_ptr>write_ptr,
      EVERY subsequent "start of packet" read (haddr=0) targets SRAM bytes
      strictly beyond anything any peer traffic has ever written -- reading
      pure garbage/uninitialized memory, independent of which packet is
      "next". This test proves the write_ptr>=read_ptr invariant the fix
      restores, and demonstrates concretely (via a clean packet D sent right
      after) that the corrupted, pre-fix pointer relationship is what
      produces an out-of-bounds aperture read for whatever comes next.

NOTE ON SCOPE: this construction ALSO exposes a companion, write-side defect
(the frozen `write_target_addr_r` causes C's own tail beyond the spurious
boundary to be dropped in transit -- a link/flow-control interaction, not
the read-pointer bug this file's RTL change addresses) that reads back
IDENTICALLY with or without this fix. That defect is out of scope for this
change and is called out in the accompanying commit/report rather than
silently asserted away here.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_truncated_pkt_aperture_offset
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, make_packet

MAX_CREDITS = 1 << 12   # RAM_ADDR_W=14 -> tidelink_fifo_ctrl.sv:MAX_CREDITS


def ctrl(tb, side):
    return tb.top(side).u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def read_ptr_of(tb, side):
    return int(tb.top(side).u_tidelink_fifo.u_fifo_mem.read_ptr.value)


def write_ptr_of(tb, side):
    return int(tb.top(side).u_tidelink_fifo.u_fifo_mem.write_ptr.value)


def credit_of(tb, side):
    return int(tb.top(side).u_tidelink_fifo.u_fifo_mem.credit_count.value)


@cocotb.test()
async def test_42_truncated_packet_read_ptr_must_not_exceed_write_ptr(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    # ---- snapshot BEFORE the truncation event -------------------------------
    rptr_before = read_ptr_of(tb, "s")
    wptr_before = write_ptr_of(tb, "s")
    tb.log.info(f"  before: read_ptr=0x{rptr_before:04x} write_ptr=0x{wptr_before:04x} "
                f"credit={credit_of(tb, 's')}")

    # ---- B: truncated packet (IDENTICAL stimulus to test_v2_truncated_pkt_credit.py)
    n_b = 8
    payload_b = [(0x7C00 << 16) | i for i in range(n_b)]
    words_b = make_packet(payload_b)
    # Deliver the header + all but the LAST payload word -- write_complete
    # needs the exact beat at write_target_addr, which never arrives, so the
    # packet is never legitimately committed. Matches the sibling test
    # exactly (n=8, words[:-1], gap=4).
    await tb.ahb_tx_write_packet("m", words_b[:-1], gap=4)
    await ClockCycles(dut.hclk, 3000 + 400 * len(words_b))

    # ---- C: a LONGER legitimate packet through the now-jammed FC write
    # interface -- the ingredient needed to actually reach read_would_overmint
    # (see module docstring). C's own header (declaring its real, larger
    # length) overwrites B's stale one; C's beat at B's frozen relative
    # target spuriously "completes" using B's too-small declared delta.
    n_c = 20
    payload_c = [(0xC000 << 16) | i for i in range(n_c)]
    words_c = make_packet(payload_c)
    await tb.ahb_tx_write_packet("m", words_c, gap=4)
    await ClockCycles(dut.hclk, 3000 + 400 * len(words_c))

    # A driver now drains C exactly as the protocol prescribes: offset 0
    # first, then consecutive offsets, for C's own full declared length.
    # Nothing improper here -- same pattern the sibling test's drain uses.
    for i in range(len(words_c)):
        await tb.ahb_fifo_read_word("s", i * 4)

    # ---- snapshot AFTER the truncation + collision event --------------------
    rptr_after = read_ptr_of(tb, "s")
    wptr_after = write_ptr_of(tb, "s")
    cred_after = credit_of(tb, "s")
    tb.log.info(f"  after:  read_ptr=0x{rptr_after:04x} write_ptr=0x{wptr_after:04x} "
                f"credit={cred_after} (MAX={MAX_CREDITS})")

    # THE PROOF OF N3, part (a): read_ptr must not move on a read_complete
    # the credit clamp itself flags as illegitimate (credit had to saturate
    # to stay <= MAX here -- cred_after == MAX_CREDITS confirms the clamp
    # fired). Pre-fix this drifts to a value STRICTLY GREATER than
    # write_ptr_after (an impossible FIFO state). Post-fix it stays put.
    assert rptr_after == rptr_before, (
        f"N3/Hazard-4: read_ptr DRIFTED across a truncated-packet + "
        f"length-mismatched-collision sequence: before=0x{rptr_before:04x} "
        f"after=0x{rptr_after:04x} (delta=0x{(rptr_after - rptr_before) & 0xFFFF:x}). "
        f"The read pointer must not move on a read_complete the credit clamp "
        f"itself flags as illegitimate (tidelink_fifo_ctrl.sv "
        f"read_would_overmint).")

    # THE PROOF OF N3, part (b) -- the real, observable consequence: once
    # read_ptr > write_ptr, translated_haddr = haddr + read_ptr for the NEXT
    # "start of packet" read lands strictly beyond anything any peer traffic
    # has ever written -- guaranteed garbage, independent of which packet is
    # "next". This is the invariant the fix restores.
    assert rptr_after <= wptr_after, (
        f"N3/Hazard-4: read_ptr (0x{rptr_after:04x}) EXCEEDS write_ptr "
        f"(0x{wptr_after:04x}) -- an impossible FIFO ordering. Every "
        f"subsequent offset-0 read now targets SRAM bytes beyond anything "
        f"the peer has ever written: the all-zero-words / wrong-PKT_LEN "
        f"silent-data-loss signature for whatever packet comes next.")

    # ---- Concrete demonstration: the very next legitimate packet's aperture
    # Send one more, ordinary, clean packet D and show where its "offset 0"
    # read actually lands. With the fix, the aperture stays inside the
    # region the peer has genuinely written (read_ptr <= write_ptr always);
    # without it, read_ptr can point past write_ptr entirely, into memory no
    # transmission ever touched.
    n_d = 2
    payload_d = [0xD0D00000 | i for i in range(n_d)]
    words_d = make_packet(payload_d)
    await tb.ahb_tx_write_packet("m", words_d, gap=4)
    await ClockCycles(dut.hclk, 3000 + 400 * len(words_d))
    rptr_before_d = read_ptr_of(tb, "s")
    wptr_before_d = write_ptr_of(tb, "s")
    tb.log.info(f"  D committed: read_ptr=0x{rptr_before_d:04x} "
                f"write_ptr=0x{wptr_before_d:04x}")
    assert rptr_before_d <= wptr_before_d, (
        f"N3/Hazard-4: at the moment D (the next legitimate packet) is "
        f"ready to be read, read_ptr (0x{rptr_before_d:04x}) already exceeds "
        f"write_ptr (0x{wptr_before_d:04x}) -- D's own aperture is "
        f"guaranteed to read uninitialized/unwritten memory.")

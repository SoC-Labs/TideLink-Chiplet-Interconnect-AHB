"""RX-FIFO TWIN 3 regression bench — link-survey campaign, 2026-08-01.

Originally a diagnostic bench built to chase the alternative-to-testbench-
artifact hypothesis for the concurrent-drain data-corruption defect hit by
cocotb/tidelink_top_pair_v2/test_v2_txgen_kr260_ratio.py and
cocotb/tidelink_top_pair_v2/test_v2_bidir_throughput.py. It proved the defect
was a genuine RTL race (not a testbench bug) at the unit level, and is now
promoted to a permanent POSITIVE regression test pinning the fix.

THE DEFECT (fixed, RX-FIFO TWIN 3, 2026-08-01)
-----------------------------------------------
tidelink_fifo_ctrl.sv (src/rtl/fifo/tidelink_fifo_ctrl.sv) used to have
exactly ONE set of "packet in flight" metadata registers — packet_active_r,
packet_word_length_r, write_target_addr_r, read_target_addr_r,
check_addr_r — shared between TWO independent producers:

  1. The FC direct-write port (fc_wr_valid/fc_wr_write/fc_wr_addr/
     fc_wr_wdata) — a single-cycle, NEVER-BACKPRESSURED path
     (tidelink_fifo_mem.sv: `assign fc_wr_ready = 1'b1;`) used by a die's
     RX FSM (tidelink_fc_adapter RX_ADDR_PHASE) to write each newly-arrived
     word of an INBOUND packet from the peer into this die's RX FIFO.
     `fc_write_addr0` fired unconditionally whenever fc_wr_addr==0 (the
     header of ANY new inbound packet) — it was NOT gated on
     `!packet_active_r`.

  2. The AHB read port — local software/TXGEN DRAINING an
     already-queued packet out of the same RX FIFO. A drain read of a
     multi-word packet held packet_active_r==1 for the packet's entire
     read duration (it only clears on read_complete, at the LAST beat).

  The write-side AHB path WAS explicitly gated against this exact hazard
  (`ahb_pkt_start_ok = ahb_write_addr0 && !packet_active_r && ...` — see the
  TWIN-2 comment block above it). The FC direct-write path had NO
  equivalent gate, so an inbound packet's header landing mid-drain of an
  older packet silently overwrote packet_word_length_r/write_target_addr_r/
  read_target_addr_r with the new packet's values — desyncing the ring
  buffer for every subsequent read.

  Note this predicted (and the campaign's data confirmed) a
  SINGLE-DIRECTION defect: it needs only "peer keeps sending" concurrent
  with "local software drains the RX FIFO before the peer is done sending"
  — no bidirectional contention required.

THE FIX (tidelink_fifo_ctrl.sv, 2026-08-01)
--------------------------------------------
Write-side and read-side packet metadata are now fully independent register
sets (write_packet_active_r/write_packet_word_length_r vs.
read_packet_active_r/read_packet_word_length_r — `packet_active_r` and
`packet_word_length_r` no longer exist as single shared signals). An
inbound FC-write header can no longer clobber an in-progress AHB drain's
metadata, and vice versa. write_complete and read_complete are now
independent events that can legitimately coincide on the same cycle
(previously impossible since they shared one packet_active_r) — pointer
management and the credit counter were updated to compose both correctly
rather than assume mutual exclusion.

This bench drives tidelink_fifo_mem directly (same DUT as
cocotb/tidelink_fifo, extended in tb_top.sv to expose fc_wr_* instead of
tying it off) with NO PHY/link/FC-adapter/credit stack in the way, so the
race (and its absence, post-fix) can be produced and inspected in isolation
from bidirectional-traffic noise, TXGEN pacing, or KR260/Z2 clock-ratio
artifacts.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from tidelink.packet import FifoPacket
from tidelink.regs import MAX_CREDITS

CLK_PERIOD_NS = 10


# ── Helpers ──────────────────────────────────────────────────────────────────

async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    dut.hsel.value = 0
    dut.htrans.value = 0
    dut.hwrite.value = 0
    dut.hsize.value = 2
    dut.haddr.value = 0x3FFF
    dut.hwdata.value = 0
    dut.flush.value = 0
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0
    dut.fc_wr_addr.value = 0
    dut.fc_wr_wdata.value = 0


async def do_reset(dut):
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


def get_credit_count(dut):
    return int(dut.u_dut.u_fifo_ctrl.credit_count_r.value)


def snapshot_ctrl(dut, label=""):
    """Cycle-accurate snapshot of the (now-independent) packet-metadata
    registers. RX-FIFO TWIN 3 FIX: packet_active_r/packet_word_length_r no
    longer exist as single shared signals — read the write-side and
    read-side registers separately."""
    c = dut.u_dut.u_fifo_ctrl
    fields = {
        "write_packet_active_r":      int(c.write_packet_active_r.value),
        "read_packet_active_r":       int(c.read_packet_active_r.value),
        "write_packet_word_length_r": int(c.write_packet_word_length_r.value),
        "read_packet_word_length_r":  int(c.read_packet_word_length_r.value),
        "write_target_addr_r":        int(c.write_target_addr_r.value),
        "read_target_addr_r":         int(c.read_target_addr_r.value),
        "check_addr_r":               int(c.check_addr_r.value),
        "read_ptr_r":                 int(c.read_ptr_r.value),
        "write_ptr_r":                int(c.write_ptr_r.value),
        "credit_count_r":             int(c.credit_count_r.value),
    }
    dut._log.info(f"[{label}] " + " ".join(f"{k}={v}" for k, v in fields.items()))
    return fields


async def fc_write_packet(dut, pkt, label=""):
    """Write a FifoPacket via the FC direct-write port (single cycle/word,
    never backpressured — models an inbound packet arriving from the RX FSM,
    tidelink_fc_adapter.sv fc_rx_fifo_* in RX_ADDR_PHASE)."""
    words = pkt.all_words
    for i, word in enumerate(words):
        await RisingEdge(dut.hclk)
        dut.fc_wr_valid.value = 1
        dut.fc_wr_write.value = 1
        dut.fc_wr_addr.value = i * 4
        dut.fc_wr_wdata.value = word
    # Let the last word register (write_complete fires combinationally
    # during the interval just set, captured at this edge).
    await RisingEdge(dut.hclk)
    write_complete = int(dut.u_dut.u_fifo_ctrl.write_complete.value)
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0
    dut._log.info(f"[{label}] fc_write_packet: {len(words)} words, "
                  f"write_complete={write_complete}")
    await RisingEdge(dut.hclk)
    return write_complete


async def ahb_read_addr0(dut):
    """Issue the AHB read of address 0 that starts draining a queued packet
    (mirrors cocotb/tidelink_fifo/test_tidelink_fifo.py::read_packet's
    opening beat). Returns after the 4-cycle metadata-capture pipeline."""
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1
    dut.htrans.value = 2  # NONSEQ
    dut.hwrite.value = 0
    dut.hsize.value = 2
    dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0
    dut.hsel.value = 0
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 4)


async def ahb_read_word(dut, addr):
    """Read one word via AHB, sampling read_complete at the correct cycle.
    Returns (data, read_complete)."""
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1
    dut.htrans.value = 2
    dut.hwrite.value = 0
    dut.hsize.value = 2
    dut.haddr.value = addr

    await RisingEdge(dut.hclk)
    try:
        hit = int(dut.read_complete.value)
    except ValueError:
        hit = 0
    dut.htrans.value = 0
    dut.hsel.value = 0
    dut.haddr.value = 0x3FFF

    await RisingEdge(dut.hclk)
    try:
        word = int(dut.hrdata.value)
    except ValueError:
        word = 0
    return word, hit


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_baseline_no_race(dut):
    """Control: FC-write one packet, drain it fully via AHB with NO
    concurrent inbound traffic. Must be byte-exact and read_complete must
    fire exactly once, at the last beat. Establishes the non-buggy
    baseline the race tests are compared against."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    wc = await fc_write_packet(dut, pktA, label="WR_A")
    assert wc, "FC write_complete should fire for packet A"
    assert get_credit_count(dut) == MAX_CREDITS - pktA.total_words

    await ahb_read_addr0(dut)
    pkt_len = int(dut.packet_word_length_out.value)
    assert pkt_len == pktA.length, f"expected length {pktA.length}, got {pkt_len}"

    read_words = []
    any_hit = False
    for i in range(pkt_len + 1):  # +1 for dest_addr
        addr = (i + 1) * 4
        word, hit = await ahb_read_word(dut, addr)
        read_words.append(word)
        any_hit = any_hit or hit

    assert any_hit, "read_complete never fired in the no-race baseline"
    assert read_words[0] == pktA.dest_addr
    assert read_words[1:] == pktA.data, \
        f"baseline corrupted with no race: expected {pktA.data}, got {read_words[1:]}"
    await ClockCycles(dut.hclk, 5)
    assert get_credit_count(dut) == MAX_CREDITS, "credits not restored in baseline"
    dut._log.info("BASELINE OK: no corruption without a concurrent FC write")


@cocotb.test()
async def test_02_metadata_not_clobbered_signal_level(dut):
    """RX-FIFO TWIN 3 FIX regression: an FC-write packet-start (fc_wr_addr==0)
    landing WHILE an AHB drain read already owns read_packet_active_r must NOT
    change read_target_addr_r / read_packet_word_length_r out from under the
    in-progress read. Pre-fix, this assertion FAILED (proving the defect);
    post-fix it must PASS — the write-side and read-side registers are now
    fully independent, so packet B's header can only touch the write-side
    copies."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    pktB = FifoPacket(data=[0xB0000000 | i for i in range(4)], dest_addr=0xBBBB0000)

    wc = await fc_write_packet(dut, pktA, label="WR_A")
    assert wc

    # Start draining packet A: read length (addr0) + dest_addr + 2 payload
    # words, matching the real defect's reported first-mismatch point
    # (pkt=2, word=2) — i.e. the race is injected after a couple of words
    # have already been streamed out correctly.
    await ahb_read_addr0(dut)
    before = snapshot_ctrl(dut, "PRE-RACE (after addr0 capture)")
    assert before["read_packet_active_r"] == 1, \
        "read_packet_active_r should be claimed by the read side mid-drain"
    assert before["read_target_addr_r"] == (pktA.length + 1) * 4, \
        "read_target_addr_r should reflect packet A before the race"
    # RX-FIFO TWIN 3 FIX: write_target_addr_r is NOT expected to equal
    # read_target_addr_r anymore — they are independent registers now, and
    # packet A's FC write already completed (write_packet_active_r cleared
    # back to 0) before this drain even started, so write_target_addr_r sits
    # at its post-clear default. Under the OLD shared-register design these
    # were always equal by construction (same source register); that
    # invariant no longer holds by design — that IS the fix.
    assert before["write_packet_active_r"] == 0, \
        "packet A's write already completed; write side should be idle"

    await ahb_read_word(dut, 0x0004)  # dest_addr
    await ahb_read_word(dut, 0x0008)  # payload[0]
    await ahb_read_word(dut, 0x000C)  # payload[1]  -> "word index 2" boundary

    mid = snapshot_ctrl(dut, "MID-DRAIN (2 payload words read, still packet_active)")
    assert mid["read_packet_active_r"] == 1, \
        "packet A's drain should still be in progress (more words to go)"
    assert mid["read_target_addr_r"] == (pktA.length + 1) * 4, \
        "read_target_addr_r should still target packet A mid-drain"

    # Concurrent inbound traffic: while packet A's drain is still in progress
    # (read_packet_active_r==1, more payload words left to read), packet B's
    # header arrives via the FC direct-write port — exactly as a peer's
    # continued TX would deliver the next packet into this die's RX FIFO
    # while local software is still streaming reads of the previous one.
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 1
    dut.fc_wr_write.value = 1
    dut.fc_wr_addr.value = 0
    dut.fc_wr_wdata.value = pktB.word0
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0
    # Settle one more delta: a `.value` read taken in the same Python
    # statement as the edge that registers an update sees the PRE-edge
    # (old) state in this cocotb/VCS setup (confirmed empirically — the
    # fc_write_packet() write_complete sample above relies on exactly this
    # behavior to catch a same-edge pulse). Wait one more edge so any
    # newly-registered write-side state is visible.
    await RisingEdge(dut.hclk)

    after = snapshot_ctrl(dut, "POST-FIX (packet B header landed mid packet-A drain)")

    unaffected = (after["read_target_addr_r"] == (pktA.length + 1) * 4)
    dut._log.info(
        f"VERDICT: read_target_addr_r "
        f"{'unaffected by inbound packet B (FIX HOLDS)' if unaffected else 'CLOBBERED — FIX REGRESSED'} "
        f"— before={before['read_target_addr_r']}, "
        f"expected(A)={(pktA.length + 1) * 4}, "
        f"expected(B)={(pktB.length + 1) * 4}, after={after['read_target_addr_r']}"
    )

    assert unaffected, (
        "RX-FIFO TWIN 3 REGRESSION: read_target_addr_r was clobbered by an "
        "inbound packet's header landing mid-drain — the write-side/read-side "
        "metadata split in tidelink_fifo_ctrl.sv no longer holds. Check that "
        "fc_write_addr0 is still gated by !write_packet_active_r and that the "
        "read-side capture branches (check_addr_r) only ever write "
        "read_packet_word_length_r/read_packet_active_r, never the write-side "
        "copies."
    )
    assert after["read_target_addr_r"] == (pktA.length + 1) * 4, \
        "read_target_addr_r must still target packet A, unaffected by packet B"
    assert after["read_packet_word_length_r"] == pktA.length, \
        "read_packet_word_length_r must still reflect packet A's length"
    # Packet B's header SHOULD still have been captured correctly, just on
    # the independent write-side registers — confirms the fix doesn't just
    # suppress the capture, it correctly routes it to the other side.
    assert after["write_packet_active_r"] == 1, \
        "packet B's header should still be captured, on the write-side registers"
    assert after["write_target_addr_r"] == (pktB.length + 1) * 4, \
        "write_target_addr_r should reflect packet B, independent of the read side"


@cocotb.test()
async def test_03_end_to_end_no_data_corruption(dut):
    """RX-FIFO TWIN 3 FIX regression: follow test_02's signal-level guarantee
    through to the end-to-end consequence. Local software keeps streaming
    reads of packet A exactly as real firmware / the cocotb drain loop
    would, unaware a new inbound packet's header just arrived — post-fix,
    this must come back byte-exact, at the correct read_complete offset,
    despite the concurrent FC write."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    pktB = FifoPacket(data=[0xB0000000 | i for i in range(4)], dest_addr=0xBBBB0000)

    assert await fc_write_packet(dut, pktA, label="WR_A")

    await ahb_read_addr0(dut)
    read_words = []
    for addr in (0x0004, 0x0008, 0x000C):  # dest_addr, payload[0], payload[1]
        w, _ = await ahb_read_word(dut, addr)
        read_words.append(w)

    # Concurrent inbound traffic: packet B's header lands mid-drain of packet A.
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 1
    dut.fc_wr_write.value = 1
    dut.fc_wr_addr.value = 0
    dut.fc_wr_wdata.value = pktB.word0
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0
    await RisingEdge(dut.hclk)

    # Software has no way to know anything happened — it keeps reading
    # packet A's remaining words at the addresses it always would.
    any_hit = False
    hit_addr = None
    # payload[j] lives at byte address (j+2)*4 (word0=header, word1=dest_addr,
    # payload[0] at word-offset 2, ...). Already read payload[0..1] above;
    # this covers payload[2..pktA.length-1] at their real addresses.
    remaining_addrs = [(j + 2) * 4 for j in range(2, pktA.length)]
    for addr in remaining_addrs:
        w, hit = await ahb_read_word(dut, addr)
        read_words.append(w)
        if hit and not any_hit:
            any_hit = True
            hit_addr = addr

    expected_target = (pktA.length + 1) * 4  # 0x24 — where read_complete must fire

    dut._log.info(f"read_complete fired at addr=0x{hit_addr:04X}" if any_hit
                  else "read_complete NEVER fired for packet A's drain")
    dut._log.info(f"Words actually read back: "
                  f"{[f'0x{w:08X}' for w in read_words]}")
    dut._log.info(f"Packet A expected payload: "
                  f"{[f'0x{w:08X}' for w in pktA.data]}")

    assert any_hit and hit_addr == expected_target, (
        f"RX-FIFO TWIN 3 REGRESSION: read_complete fired at "
        f"{'0x%04X' % hit_addr if any_hit else 'never'}, expected "
        f"0x{expected_target:04X} (packet A's real target) — the drain's "
        "completion offset was disturbed by the concurrent inbound packet."
    )

    got_payload = read_words[1:]  # drop dest_addr
    assert got_payload == pktA.data[:len(got_payload)], (
        f"RX-FIFO TWIN 3 REGRESSION: packet A's observed read stream was "
        f"corrupted by the concurrent FC write — expected {pktA.data}, got "
        f"{got_payload}."
    )
    dut._log.info(
        "FIX HOLDS: packet A drained byte-exact, read_complete fired at the "
        "correct offset, despite packet B's header landing mid-drain."
    )

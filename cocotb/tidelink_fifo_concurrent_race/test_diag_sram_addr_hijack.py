"""DIAGNOSTIC (link-survey campaign, 2026-08-02) -- SRAM read-address-pipeline
hijack under FC-write / AHB-read arbitration in tidelink_fifo_mem.sv.

CONTEXT -- why this file exists
--------------------------------
test_v2_bidir_throughput.py::test_bidir_throughput_two_sizes, re-run after
today's RX-FIFO TWIN 3 fix (src/rtl/fifo/tidelink_fifo_ctrl.sv -- write-side
and read-side packet metadata split into independent registers), no longer
loses packets (100% drain in every config, drain_timed_out=False
everywhere) -- but still shows large WORD-LEVEL mismatch counts (N16:
260-284/320 words per sub-run, N60: ~582-586/600). TWIN 3's own mechanism
was a pointer/offset defect (read_complete firing at the wrong time); this
residual is a plain value corruption with CORRECT completion timing, which
TWIN 3 cannot explain.

A testbench-bookkeeping hypothesis was raised: that residual mismatches are
a leftover, undrained packet from a PREVIOUS phase (whose drain loop timed
out on the suite's known, separately-tracked "last packet of a finite
TXGEN run never delivered" defect) being picked up by the NEXT phase's
drain loop and compared against the wrong expected seq. That hypothesis is
REFUTED by a plain re-run of the unmodified suite (no edits, sim-only):
every single phase in every config reports `drain_timed_out=False` (see
the accompanying report) -- there is no timed-out predecessor phase to
leave a leftover behind, and mismatches occur even in N16-uni-m2s, the
FIRST phase of the entire test (no possible predecessor at all: 272/320
words already wrong). So the residual is NOT the leftover-packet
testbench artifact.

This file follows the task's alternative lead instead: directly verify
whether tidelink_fifo_mem.sv's SRAM arbitration between the FC direct-write
port (inbound packets from the peer) and the AHB read port (local drain) is
actually correct under concurrent access, rather than trusting the
"correctly arbitrated" claim in test_concurrent_race.py's docstring
(written for the TWIN-3 metadata race, never checked at the raw SRAM DATA
level).

THE MECHANISM THIS FILE TESTS
-------------------------------
tidelink_fifo_mem.sv drives a SINGLE-PORT SRAM through an address mux that
gives the FC-write port top priority:

    ADDR = fc_active ? fc_translated_addr[...] : puf_can_read ? puf_addr
                      : translated_addr
    hreadyout = ahb_hreadyout_raw && !fc_active   // stalls the AHB port
                                                    // whenever fc_active

The AHB *protocol* side of this is correct: an AHB read whose data phase
lands on an fc_active cycle sees hreadyout=0 and (correctly, per TWIN 3)
does not fire read_complete or move any pointer prematurely -- the caller
just waits longer, exactly like a normal AHB stall.

But the underlying vendor SRAM model, src/rtl/fifo/fpga/tidelink_sram.sv ->
cmsdk_fpga_sram.v (/research/AAA/ip_library/.../cmsdk_fpga_sram.v, read-only
vendor IP, NOT modified here), registers its READ ADDRESS unconditionally,
every cycle, regardless of CS:

    always @ (posedge CLK) begin
      ...
      // do not use enable on read interface.
      addr_q1 <= ADDR[AW-1:2];
    end
    assign read_data = {BRAM3[addr_q1], BRAM2[addr_q1], BRAM1[addr_q1], BRAM0[addr_q1]};

So: if an AHB read's data-phase wait spans a cycle where a concurrent FC
write is asserted (fc_active=1, needed to make the port arbitration correct
per the paragraph above), that SAME cycle's ADDR mux value (the FC write's
own target address) gets latched into addr_q1 -- unconditionally, whether
or not the AHB side was the one "supposed" to own the port that cycle. Once
the FC write ends and hreadyout returns to 1, the AHB master samples HRDATA
believing its own stalled transfer has completed -- but addr_q1 no longer
points at the AHB read's own target; it points at wherever the intervening
FC write went. There is no path to recover the original address: after a
read's own one-cycle address phase passes, `ahb_read` (the only condition
under which the ADDR mux even considers the AHB side) is combinationally
false for every later stall cycle, so on any subsequent cycle without an FC
write the mux instead shows `buf_addr` (a write-buffer leftover, equally
irrelevant) -- the original read target is simply gone.

Net effect: read_complete/read_ptr_r/credit_count_r (the TWIN-3-fixed
metadata) all still fire/advance at the CORRECT time, against the CORRECT
target address -- the transaction looks completely healthy from the
control-plane's point of view -- but the DATA VALUE returned on the bus is
whatever the colliding FC write's address held, not what the AHB read
actually asked for. This is exactly the "correctly-timed, wrong-value"
signature test_v2_bidir_throughput.py's mismatches show (e.g. baseline
re-run 2026-08-02, N16-uni-m2s packet 0 header slot: expected the header
word 0x00E40000, got 0x0001000D, which decodes cleanly as a real, valid
{seq=1,beat=13} payload word from a DIFFERENT packet -- not noise).

This bench reuses cocotb/tidelink_fifo_concurrent_race/tb_top.sv (the
existing diagnostic wrapper around the PRODUCTION tidelink_fifo_mem
instance, both FC and AHB ports exposed) -- no RTL is modified. Imports
setup()/do_reset()/fc_write_packet()/ahb_read_addr0()/snapshot_ctrl() from
the sibling test_concurrent_race.py rather than duplicating them (that file
is NOT edited). Diagnostic-only -- not registered in sim_gate.
"""
import cocotb
from cocotb.triggers import RisingEdge

from tidelink.packet import FifoPacket

from test_concurrent_race import (
    setup, do_reset, fc_write_packet, ahb_read_addr0, snapshot_ctrl,
    get_credit_count,
)


async def ahb_read_word_honest(dut, addr, hijack=None, hijack_cycles=1):
    """AHB read of one word that PROPERLY honors hreadyout on BOTH the
    address phase and the data phase -- unlike test_concurrent_race.py's
    own ahb_read_word(), which fires straight through RisingEdges
    regardless of hready/hreadyout (fine for that file's purpose, since it
    only ever injects an FC write BETWEEN fully-completed, back-to-back AHB
    reads, never during one's own in-flight data phase). This mirrors
    pair_v2_common.py's ahb_fifo_read_word EXACTLY (poll hready after the
    address phase, then poll again and sample hrdata at the same edge once
    ready) -- the identical pattern the real drain loop
    (read_packet_drain -> ahb_fifo_read_word) uses in production.

    hijack: optional (fc_addr, fc_wdata). If given, drives a concurrent FC
    write of `fc_wdata` to `fc_addr` for `hijack_cycles` cycles immediately
    after this read's OWN address phase is accepted -- landing in exactly
    the window a real inbound packet stream would occupy if it happened to
    write during this read's stall -- then releases it and waits for
    hreadyout to clear before finally sampling HRDATA.

    Returns (word, read_complete_seen_at_address_phase).
    """
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1
    dut.htrans.value = 2
    dut.hwrite.value = 0
    dut.hsize.value = 2
    dut.haddr.value = addr

    # Address phase: wait for hready (pre-edge convention, matches this
    # repo's documented cocotb+VCS same-edge-read semantics).
    for _ in range(50):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.hready.value):
                break
        except ValueError:
            pass
    else:
        raise TimeoutError(f"address phase for 0x{addr:04x} never accepted")

    read_complete_seen = False
    try:
        read_complete_seen = bool(int(dut.read_complete.value))
    except ValueError:
        pass

    # Single-beat transfer: deselect immediately (matches every other
    # helper in this suite -- pair_v2_common.ahb_fifo_read_word does the
    # same).
    dut.hsel.value = 0
    dut.htrans.value = 0
    dut.haddr.value = 0x3FFF

    if hijack is not None:
        fc_addr, fc_wdata = hijack
        dut.fc_wr_valid.value = 1
        dut.fc_wr_write.value = 1
        dut.fc_wr_addr.value = fc_addr
        dut.fc_wr_wdata.value = fc_wdata
        for _ in range(hijack_cycles):
            await RisingEdge(dut.hclk)
        dut.fc_wr_valid.value = 0
        dut.fc_wr_write.value = 0

    # Data phase: wait for hready, sample hrdata at the SAME edge.
    word = 0
    for _ in range(50):
        await RisingEdge(dut.hclk)
        try:
            ready = int(dut.hready.value)
        except ValueError:
            ready = 0
        if ready:
            try:
                word = int(dut.hrdata.value)
            except ValueError:
                word = 0
            break
    else:
        raise TimeoutError(f"data phase for 0x{addr:04x} never became ready")

    return word, read_complete_seen


def addr_q1(dut):
    """Hierarchical probe into the vendor SRAM's registered read-address
    latch (cmsdk_fpga_sram.v) -- read-only observation, no RTL touched."""
    return int(dut.u_dut.u_sram.u_sram.addr_q1.value)


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_00_baseline_honest_driver_no_race(dut):
    """Control: the properly-hready-honoring driver, with NO concurrent FC
    write, must read packet A back byte-exact -- establishes that
    ahb_read_word_honest() itself is not the source of any discrepancy
    before using it to probe the race."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    assert await fc_write_packet(dut, pktA, label="WR_A")
    await ahb_read_addr0(dut)

    got = []
    for j in range(pktA.length + 1):  # dest_addr + payload
        addr = (j + 1) * 4
        w, _ = await ahb_read_word_honest(dut, addr)
        got.append(w)

    assert got[0] == pktA.dest_addr
    assert got[1:] == pktA.data, (
        f"baseline (honest driver, no race) corrupted: expected "
        f"{[hex(w) for w in pktA.data]}, got {[hex(w) for w in got[1:]]}")
    dut._log.info("BASELINE OK: honest driver reproduces test_01's clean result")


@cocotb.test()
async def test_01_hijack_corrupts_midpacket_read(dut):
    """THE PROOF: a one-cycle concurrent FC write landing in an in-flight
    AHB read's stalled data-phase window corrupts the VALUE returned, while
    leaving read_complete/pointer bookkeeping (checked separately) alone.
    Uses a POISON address far outside packet A's own footprint and addr 0,
    so the FC write has zero interaction with any packet-metadata state
    machine (fc_wr_addr != 0 never arms fc_write_addr0) -- isolating this
    to the raw SRAM data path, exactly as the module comment above claims
    is "correctly arbitrated" but was never directly checked."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    assert await fc_write_packet(dut, pktA, label="WR_A")
    await ahb_read_addr0(dut)

    # Sanity: payload[0] read normally (no hijack) must still be correct.
    w0, _ = await ahb_read_word_honest(dut, 0x0008)  # payload[0]
    assert w0 == pktA.data[0], "pre-hijack sanity read already wrong -- setup bug"

    POISON_ADDR = 0x2000       # fc_wr_addr; != 0, never touches write metadata
    POISON_VAL = 0xDEADBEEF
    before = snapshot_ctrl(dut, "PRE-HIJACK")

    # payload[1] at byte offset 0x000C -- read it WITH the hijack injected.
    w1, hit1 = await ahb_read_word_honest(
        dut, 0x000C, hijack=(POISON_ADDR, POISON_VAL))

    after = snapshot_ctrl(dut, "POST-HIJACK (still mid-packet, more words left)")
    q1 = addr_q1(dut)

    dut._log.info(
        f"payload[1]: expected=0x{pktA.data[1]:08x} got=0x{w1:08x} "
        f"poison=0x{POISON_VAL:08x} addr_q1(post)=0x{q1:04x} "
        f"read_target_addr_r={after['read_target_addr_r']} (unaffected="
        f"{after['read_target_addr_r'] == before['read_target_addr_r']})")

    # Metadata/pointer bookkeeping (the TWIN-3-fixed layer) must be
    # UNTOUCHED by an fc_wr_addr!=0 write -- confirms this is NOT a TWIN-3
    # regression, it's a layer below it.
    assert after["read_target_addr_r"] == before["read_target_addr_r"], (
        "read_target_addr_r moved -- this would be a TWIN-3-class metadata "
        "regression, not the SRAM-arbitration defect this test targets")
    assert after["read_packet_active_r"] == 1, \
        "packet A's drain should still be mid-flight (2 more words to go)"

    assert w1 == POISON_VAL, (
        f"EXPECTED the hijack to reproduce: got=0x{w1:08x} did not equal "
        f"the poison value 0x{POISON_VAL:08x} -- SRAM arbitration hijack "
        f"NOT reproduced with this timing; see file docstring for the "
        f"exact cycle window required and cross-check addr_q1 above")
    assert w1 != pktA.data[1], "corrupted value coincidentally matched the real payload"
    dut._log.info(
        "HIJACK CONFIRMED: AHB read returned the concurrent FC write's own "
        "data (0x%08x) instead of packet A's real payload[1] (0x%08x), "
        "while read_target_addr_r/read_packet_active_r report a perfectly "
        "healthy, on-target, still-in-progress drain." % (w1, pktA.data[1]))


@cocotb.test()
async def test_02_hijack_corrupts_final_beat_without_disturbing_read_complete(dut):
    """Stronger form: inject the SAME hijack on packet A's LAST beat (the
    one whose read fires read_complete and pops the packet / advances
    read_ptr_r / restores credit). Confirms the "silent" character of the
    defect end-to-end: completion timing, pointer advance, and credit
    restoration are all EXACTLY as if nothing happened -- only the 32-bit
    value on the bus that cycle is wrong. This is precisely why the bidir
    suite sees drained==npkt (100%) with drain_timed_out=False, and yet
    the packets it did drain still contain wrong words: the popping
    machinery has no way to know its own final-beat read the wrong value."""
    await setup(dut)
    await do_reset(dut)

    pktA = FifoPacket(data=[0xA0000000 | i for i in range(8)], dest_addr=0xAAAA0000)
    assert await fc_write_packet(dut, pktA, label="WR_A")
    await ahb_read_addr0(dut)

    # Drain payload[0..6] normally first (7 of 8 payload words).
    for j in range(7):
        addr = (j + 2) * 4
        w, _ = await ahb_read_word_honest(dut, addr)
        assert w == pktA.data[j], f"payload[{j}] already wrong before the hijack beat"

    before = snapshot_ctrl(dut, "PRE-FINAL-BEAT")
    assert before["read_packet_active_r"] == 1
    credit_before = get_credit_count(dut)

    POISON_ADDR = 0x2100
    POISON_VAL = 0xC0FFEE07
    last_addr = (pktA.length + 1) * 4  # the read_complete-firing offset
    w_last, hit_last = await ahb_read_word_honest(
        dut, last_addr, hijack=(POISON_ADDR, POISON_VAL))

    after = snapshot_ctrl(dut, "POST-FINAL-BEAT (packet should have popped)")
    credit_after = get_credit_count(dut)

    dut._log.info(
        f"final beat (0x{last_addr:04x}): expected=0x{pktA.data[7]:08x} "
        f"got=0x{w_last:08x} poison=0x{POISON_VAL:08x} "
        f"read_packet_active_r pre={before['read_packet_active_r']} "
        f"post={after['read_packet_active_r']} credit pre={credit_before} "
        f"post={credit_after}")

    # The POP itself must be perfectly healthy -- this is the "silent"
    # part of the defect: nothing downstream can detect the value was
    # wrong from the control-plane state alone.
    assert after["read_packet_active_r"] == 0, \
        "packet should have completed/popped on its real final beat"
    assert credit_after == credit_before + pktA.total_words, (
        f"credit should be restored by exactly the packet's word count "
        f"(a healthy pop) -- pre={credit_before} post={credit_after} "
        f"delta={credit_after - credit_before} expected={pktA.total_words}")

    # But the VALUE on the bus for that same, correctly-popping beat is
    # the hijacker's, not packet A's real last payload word.
    assert w_last == POISON_VAL, (
        f"expected the hijack to reproduce on the final (popping) beat too: "
        f"got=0x{w_last:08x} vs poison=0x{POISON_VAL:08x}")
    assert w_last != pktA.data[7]
    dut._log.info(
        "CONFIRMED: even the packet's OWN popping beat -- credit restored "
        "correctly, read_packet_active_r cleared correctly, i.e. a "
        "perfectly healthy completion from the control plane's point of "
        "view -- returned the concurrent FC write's data instead of "
        "packet A's real last word. This is silent, undetectable corruption "
        "purely at the SRAM data-path level, one layer below the "
        "TWIN-3-fixed metadata registers.")

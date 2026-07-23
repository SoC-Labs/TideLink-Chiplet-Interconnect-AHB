"""Drain / credit-return protocol verification for the RX FIFO (Q1 + Q2).

Reuses the TidelinkAhbTB from test_tidelink_ahb (same tb_top / DUT).

Q1  test_drain_multi_diff_len
    Fill the FIFO with several packets of DIFFERENT lengths, drain them with
    the protocol-legal sequential-read sweep (read offset 0 header -> read
    up to read_target), and assert per-pop:
      (a) exactly one read_complete pop per packet
      (b) credit_count returns by (len+2) per pop
      (c) read_ptr_r advances by (len+2) words per pop
      (d) payloads read back byte-exact and IN ORDER across all packets.

Q2  test_fixed_offset_no_pop
    Model the on-silicon read-protocol artifact (project_kr260_first_data_
    crossing_2026_07_22): a reader that reads a FIXED absolute offset (0x8)
    instead of the read-ptr-relative sweep. Assert it NEVER fires
    read_complete, NEVER returns credit, NEVER advances read_ptr, and keeps
    returning the SAME (packet-0) word -> only ever "sees" packet 0.

Run (force a clean build — beware the stale-simv trap):
  cd cocotb/tidelink_ahb
  rm -rf sim_build results.xml
  make MODULE=test_tidelink_drain_credit
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_ahb import TidelinkAhbTB
from tidelink.regs import (
    MAX_CREDITS, REG_REL_THRESHOLD, REG_CTRL, CTRL_AHB_INJECT_ARM,
    PAIR_RELEASED_CREDITS_OFFSET,
)

# Default TIDELINK_PAIR_BASE = 0 -> returner targets the raw offset.
PAIR_RELEASED_CREDITS_ADDR = PAIR_RELEASED_CREDITS_OFFSET


# ── Hierarchical probes into the FIFO controller ────────────────────────────

def _ctrl(dut):
    return dut.u_dut.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def _read_ptr(dut):
    return int(_ctrl(dut).read_ptr_r.value)


def _credit(dut):
    return int(_ctrl(dut).credit_count_r.value)


def _read_complete(dut):
    try:
        return int(_ctrl(dut).read_complete.value)
    except ValueError:
        return 0


# ── Instrumented sequential drain of ONE packet ─────────────────────────────
# Mirrors tb.read_packet but records read_complete pop count + read_ptr, and
# reads the header/dest/data at read-ptr-relative offsets 0,4,(i+2)*4.

async def drain_one_instrumented(tb, label=""):
    dut = tb.dut

    rp_before = _read_ptr(dut)
    cr_before = _credit(dut)

    # Read Word 0 (header) at relative offset 0x0 -> arms the length latch
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value, dut.ahbs_htrans.value = 1, 2
    dut.ahbs_hwrite.value, dut.ahbs_hsize.value = 0, 2
    dut.ahbs_haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value, dut.ahbs_hsel.value = 0, 0
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    pkt_len = int(dut.u_dut.u_tidelink_fifo.u_fifo_mem.packet_word_length_out.value)

    # Read Word 1 (dest_addr) at relative offset 0x4
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value, dut.ahbs_htrans.value = 1, 2
    dut.ahbs_hwrite.value, dut.ahbs_hsize.value = 0, 2
    dut.ahbs_haddr.value = 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value, dut.ahbs_hsel.value = 0, 0
    dut.ahbs_haddr.value = 0x3FFF
    await RisingEdge(dut.hclk)

    pop_count = 0
    data = []
    for i in range(pkt_len):
        addr = (i + 2) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value, dut.ahbs_htrans.value = 1, 2
        dut.ahbs_hwrite.value, dut.ahbs_hsize.value = 0, 2
        dut.ahbs_haddr.value = addr
        await RisingEdge(dut.hclk)
        pop_count += _read_complete(dut)  # sampled in the data phase (per tb.read_packet)
        dut.ahbs_htrans.value, dut.ahbs_hsel.value = 0, 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)
        try:
            data.append(int(dut.ahbs_hrdata.value))
        except ValueError:
            data.append(0)

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    rp_after = _read_ptr(dut)
    cr_after = _credit(dut)
    tb.log.info(
        f"[{label}] len={pkt_len} pops={pop_count} "
        f"read_ptr {rp_before}->{rp_after} (+{rp_after-rp_before}B) "
        f"credit {cr_before}->{cr_after} (+{cr_after-cr_before})")
    return {
        "len": pkt_len, "data": data, "pops": pop_count,
        "rp_before": rp_before, "rp_after": rp_after,
        "cr_before": cr_before, "cr_after": cr_after,
    }


# ── Q1: multi-packet, different lengths ─────────────────────────────────────

@cocotb.test()
async def test_drain_multi_diff_len(dut):
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    # TWIN-2: the AHB write-into-RX path is POR-disarmed; arm CTRL[3] to fill
    # via write_packet (the RX-fill path this bench exposes).
    await tb.cfg_write(REG_CTRL, 1 << CTRL_AHB_INJECT_ARM)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_REL_THRESHOLD, 0)  # immediate release

    # Three packets, DIFFERENT payload lengths, position-encoded payloads so a
    # 2-word shift / cross-packet aliasing is a hard mismatch.
    packets = [
        [0x1000_0000 | i for i in range(2)],   # len=2, delta=4
        [0x2000_0000 | i for i in range(5)],   # len=5, delta=7
        [0x3000_0000 | i for i in range(1)],   # len=1, delta=3
    ]

    # ---- Fill ----
    cr = _credit(dut)
    assert cr == MAX_CREDITS, f"post-reset credit {cr} != {MAX_CREDITS}"
    for k, p in enumerate(packets):
        hit = await tb.write_packet(p, label=f"WR{k}")
        assert hit, f"packet {k} write_complete did not fire"
    cr_after_fill = _credit(dut)
    expect_consumed = sum(len(p) + 2 for p in packets)
    assert cr_after_fill == MAX_CREDITS - expect_consumed, (
        f"after fill credit={cr_after_fill}, "
        f"expected {MAX_CREDITS - expect_consumed}")

    # ---- Drain sequentially, verifying each pop ----
    prev_rp = _read_ptr(dut)
    for k, p in enumerate(packets):
        res = await drain_one_instrumented(tb, label=f"RD{k}")
        exp_len = len(p)
        exp_delta = exp_len + 2

        # (a) exactly one pop
        assert res["pops"] == 1, (
            f"packet {k}: expected exactly 1 read_complete pop, "
            f"got {res['pops']}")
        # length latch matched what we wrote
        assert res["len"] == exp_len, (
            f"packet {k}: latched len {res['len']} != written {exp_len}")
        # (b) credit returned by (len+2)
        assert res["cr_after"] - res["cr_before"] == exp_delta, (
            f"packet {k}: credit delta {res['cr_after']-res['cr_before']} "
            f"!= {exp_delta}")
        # (c) read_ptr advanced by (len+2) words == delta*4 bytes
        assert res["rp_after"] - res["rp_before"] == exp_delta * 4, (
            f"packet {k}: read_ptr delta {res['rp_after']-res['rp_before']}B "
            f"!= {exp_delta*4}B")
        assert res["rp_before"] == prev_rp, "read_ptr moved between drains"
        prev_rp = res["rp_after"]
        # (d) payload byte-exact and in order
        assert res["data"] == p, (
            f"packet {k}: payload mismatch\n  got={[hex(x) for x in res['data']]}"
            f"\n  exp={[hex(x) for x in p]}")

    # Fully drained -> credit restored to MAX
    cr_end = _credit(dut)
    assert cr_end == MAX_CREDITS, f"after full drain credit={cr_end} != {MAX_CREDITS}"
    tb.log.info("Q1 PASS: multi-packet different-length sequential drain "
                "pops 1/pkt, returns (len+2) credit, advances read_ptr, "
                "byte-exact in order.")


# ── Q2: fixed-offset read never pops ────────────────────────────────────────

@cocotb.test()
async def test_fixed_offset_no_pop(dut):
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_CTRL, 1 << CTRL_AHB_INJECT_ARM)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_REL_THRESHOLD, 0)

    # Two DISTINCT packets in the FIFO. A correct drain would see both; the
    # fixed-offset reader must only ever see packet 0.
    pkt0 = [0xA5A5_0000, 0xA5A5_0001, 0xA5A5_0002]  # data[0] @ rel offset 0x8
    pkt1 = [0x5A5A_0000, 0x5A5A_0001, 0x5A5A_0002]
    assert await tb.write_packet(pkt0, label="WR0")
    assert await tb.write_packet(pkt1, label="WR1")

    rp0 = _read_ptr(dut)
    cr0 = _credit(dut)

    # Repeatedly read the SAME fixed absolute offset 0x8, never reading the
    # header at 0x0 -> packet_active never re-arms, read_complete never fires.
    seen = []
    pops = 0
    for n in range(5):
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value, dut.ahbs_htrans.value = 1, 2
        dut.ahbs_hwrite.value, dut.ahbs_hsize.value = 0, 2
        dut.ahbs_haddr.value = 0x0008
        await RisingEdge(dut.hclk)
        pops += _read_complete(dut)
        dut.ahbs_htrans.value, dut.ahbs_hsel.value = 0, 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)
        try:
            seen.append(int(dut.ahbs_hrdata.value))
        except ValueError:
            seen.append(0)
        await ClockCycles(dut.hclk, 2)

    rp1 = _read_ptr(dut)
    cr1 = _credit(dut)
    tb.log.info(f"[FIXED0x8] reads={[hex(x) for x in seen]} pops={pops} "
                f"read_ptr {rp0}->{rp1} credit {cr0}->{cr1}")

    # No pop ever
    assert pops == 0, f"fixed-offset read fired {pops} read_complete pops (expected 0)"
    # read_ptr frozen -> never advances to packet 1
    assert rp1 == rp0, f"read_ptr moved {rp0}->{rp1} on fixed-offset reads"
    # credit never returned
    assert cr1 == cr0, f"credit changed {cr0}->{cr1} on fixed-offset reads"
    # Every read returns packet-0's data[0] -> packet 1 is NEVER observed
    assert all(v == seen[0] for v in seen), (
        f"fixed-offset reads not all identical: {[hex(x) for x in seen]}")
    assert seen[0] == pkt0[0], (
        f"fixed offset 0x8 should return packet-0 data[0]=0x{pkt0[0]:08x}, "
        f"got 0x{seen[0]:08x}")
    assert all(v != pkt1[0] for v in seen), \
        "fixed-offset reader must NEVER see packet 1"
    tb.log.info("Q2 PASS: fixed-offset (0x8) reader never pops, never returns "
                "credit, never advances read_ptr, only ever sees packet 0 — "
                "the on-silicon read-protocol artifact reproduced.")


# ── Q3 (emitter side): RX pop drives a credit-return WRITE to the peer ───────

@cocotb.test()
async def test_drain_returns_credit_to_peer_addr(dut):
    """The RX-side pop must emit a credit-return toward the FAR end. Here the
    returner AHB master writes the released delta to the PEER's released-credits
    register address (a stub slave RAM in this bench). This proves the EMITTER
    of the cross-link credit-return; the far-end CONSUMPTION is only observable
    in a full-link bench (tidelink_top_pair_v2), noted in the report."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_CTRL, 1 << CTRL_AHB_INJECT_ARM)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_REL_THRESHOLD, 0)  # immediate release per pop

    payload = [0xC0FFEE00 | i for i in range(4)]   # len=4 -> delta=6
    assert await tb.write_packet(payload, label="WR")

    # Clear the returner target, then drain -> read_complete -> returner fires.
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')
    res = await drain_one_instrumented(tb, label="RD")
    assert res["pops"] == 1
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    delta = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    exp = len(payload) + 2
    tb.log.info(f"[Q3] returner wrote released_credits delta={delta} "
                f"to peer addr 0x{PAIR_RELEASED_CREDITS_ADDR:03x} (expected {exp})")
    assert delta == exp, f"returner credit-return delta {delta} != {exp}"
    tb.log.info("Q3 PASS (emitter): RX pop emits a credit-return WRITE of "
                "(len+2) to the peer's released-credits register address.")

"""DIAGNOSTIC (not a gate): separate 'arrived wrong' from 'read back wrong'.

Dumps the destination RX FIFO SRAM contents by hierarchy -- WITHOUT any AHB
read -- immediately after a burst lands, then dumps the pointer/credit state,
then performs the AHB drain sweep and dumps again.

If SRAM holds the burst byte-exact but the drain returns shifted/short data,
the defect is in the READ/pointer path. If SRAM itself is wrong, the defect is
TX-side or link/commit-side. This is the measurement that has to come before
any theory (feedback_verify_instrument_before_dut).

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_diag_burst
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, read_packet_drain, diff_words,
)


def fifo_mem(tb, side):
    return tb.top(side).u_tidelink_fifo.u_fifo_mem


def sram_word(tb, side, widx):
    """Reassemble a 32-bit SRAM word from the cmsdk_fpga_sram byte arrays."""
    u = fifo_mem(tb, side).u_sram.u_sram
    try:
        b0 = int(u.BRAM0[widx].value)
        b1 = int(u.BRAM1[widx].value)
        b2 = int(u.BRAM2[widx].value)
        b3 = int(u.BRAM3[widx].value)
    except (AttributeError, ValueError):
        return None
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0


def dump_ptrs(tb, side, label):
    m = fifo_mem(tb, side)
    def g(n):
        try:
            return int(getattr(m, n).value)
        except (AttributeError, ValueError):
            return -1
    tb.log.info(
        f"  [{label}] {side}: write_ptr={g('write_ptr')} read_ptr={g('read_ptr')} "
        f"wtgt={g('write_target_addr')} rtgt={g('read_target_addr')} "
        f"pkt_len={g('packet_word_length')} credit={g('credit_count')} "
        f"overrun={g('overrun')} underrun={g('underrun')}")


def dump_sram(tb, side, n, label):
    vals = [sram_word(tb, side, i) for i in range(n)]
    tb.log.info(f"  [{label}] {side} SRAM[0..{n-1}]:")
    for base in range(0, n, 8):
        chunk = vals[base:base + 8]
        tb.log.info("      w%-3d: %s" % (
            base, "  ".join("XXXXXXXX" if v is None else f"{v:08x}"
                            for v in chunk)))
    return vals


async def monitor_fc_writes(tb, side, log):
    """Record every FC direct write presented to the dst FIFO. This is the
    stream AFTER the link and BEFORE the SRAM, so it splits the datapath:
      - stream already missing words  => TX / link / framer defect
      - stream complete but SRAM wrong => FIFO write-path defect
    """
    m = fifo_mem(tb, side)
    while True:
        await RisingEdge(tb.dut.hclk)
        try:
            if int(m.fc_wr_valid.value) and int(m.fc_wr_write.value):
                log.append((int(m.fc_wr_addr.value) // 4,
                            int(m.fc_wr_wdata.value)))
        except (AttributeError, ValueError):
            pass


@cocotb.test()
async def test_22_diag_fc_stream(dut):
    """Localize the drop: compare the FC write stream at the RX FIFO against
    what was sent AND against what ended up in SRAM."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    n = 40
    payload = [(0xA2B0 << 16) | i for i in range(n)]
    words = make_packet(payload)

    rx_log = []
    cocotb.start_soon(monitor_fc_writes(tb, "s", rx_log))
    tx_log = []
    cocotb.start_soon(monitor_fc_writes(tb, "m", tx_log))

    await tb.ahb_tx_write_packet("m", words, gap=4)
    await ClockCycles(dut.hclk, 6000 + 600 * len(words))

    tb.log.info(f"  SENT {len(words)} words")
    tb.log.info(f"  FC writes seen at RX FIFO: {len(rx_log)}")
    for k, (a, d) in enumerate(rx_log):
        exp = words[k] if k < len(words) else None
        flag = "" if (exp is not None and d == exp and a == k) else "   <== ANOMALY"
        tb.log.info(f"      rx_fc[{k:3d}]: slot={a:3d} data=0x{d:08x} "
                    f"(sent[{k}]=0x{exp:08x})" % () if exp is not None
                    else f"      rx_fc[{k:3d}]: slot={a:3d} data=0x{d:08x}")
        if flag:
            tb.log.info(f"          {flag.strip()}")
    missing = [i for i, w in enumerate(words)
               if w not in [d for _, d in rx_log]]
    tb.log.info(f"  words NEVER presented to the RX FIFO: {missing}")


@cocotb.test()
async def test_21_diag_periodicity(dut):
    """Send ONE long burst and report EVERY missing index, so the drop
    periodicity (if any) is measured rather than guessed."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    n = 126
    payload = [(0xA2B0 << 16) | i for i in range(n)]
    words = make_packet(payload)
    await tb.ahb_tx_write_packet("m", words, gap=4)
    await ClockCycles(dut.hclk, 6000 + 600 * len(words))

    sram = dump_sram(tb, "s", len(words) + 4, "post-arrival long burst")
    dump_ptrs(tb, "s", "post-arrival long burst")

    # Where did each sent word actually land?
    tb.log.info("  ---- landing map ----")
    missing = [i for i, w in enumerate(words) if w not in sram]
    tb.log.info(f"  sent {len(words)} words; MISSING from SRAM entirely: "
                f"{missing}")
    landed = {}
    for i, w in enumerate(words):
        if w in sram:
            landed[i] = sram.index(w)
    shifted = {i: j for i, j in landed.items() if i != j}
    tb.log.info(f"  words landing at a SHIFTED slot (sent_idx -> sram_idx): "
                f"{shifted}")


@cocotb.test()
async def test_20_diag_len16_master_to_slave(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    n = 16
    payload = [(0xA2B0 << 16) | i for i in range(n)]
    words = make_packet(payload)
    tb.log.info(f"  SENT ({len(words)} words): "
                f"[{', '.join(f'0x{w:08x}' for w in words)}]")

    dump_ptrs(tb, "s", "pre-send")
    await tb.ahb_tx_write_packet("m", words, gap=4)
    await ClockCycles(dut.hclk, 3000 + 400 * len(words))

    # ---- NON-INVASIVE: what physically landed in the RX SRAM? ----
    sram = dump_sram(tb, "s", 24, "post-arrival (NO ahb read yet)")
    dump_ptrs(tb, "s", "post-arrival")

    sram_mism = diff_words(words, sram[:len(words)])
    if sram_mism:
        tb.log.info(f"  >> SRAM CONTENT WRONG: {len(sram_mism)} words differ; "
                    f"first bad idx {sram_mism[0][0]} "
                    f"(expected 0x{sram_mism[0][1]:08x} got "
                    f"0x{sram_mism[0][2]:08x}) => TX/link/commit-side defect")
    else:
        tb.log.info("  >> SRAM CONTENT IS BYTE-EXACT => any drain mismatch is "
                    "a READ/POINTER-path defect")

    # ---- Now the AHB drain sweep ----
    got = await read_packet_drain(tb, "s", len(words))
    dump_ptrs(tb, "s", "post-drain")
    drain_mism = diff_words(words, got)
    tb.log.info(f"  DRAIN got: [{', '.join(f'0x{w:08x}' for w in got)}]")
    if drain_mism:
        for i, s, g in drain_mism:
            tb.log.info(f"      drain word[{i}]: expected 0x{s:08x} got 0x{g:08x}")

    tb.log.info(f"  VERDICT: sram_mismatches={len(sram_mism)} "
                f"drain_mismatches={len(drain_mism)}")

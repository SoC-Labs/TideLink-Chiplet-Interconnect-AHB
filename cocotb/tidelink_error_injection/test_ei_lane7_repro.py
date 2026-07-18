"""F14 · Scenario 3b — REPRODUCIBILITY of the per-lane corruption classes.

The one-shot lane sweep (test_ei_lane_dropout::test_01) reported lane 7 FLIP as
SILENT-CORRUPTION (PKT_LEN=0xd committed, payload wrong) while lanes 0-6 were
dropped — but it also produced INCONSISTENT one-shot results elsewhere (lane 2
stuck0/stuck1 read back byte-exact). A single trial per lane is not evidence:
the RX FIFO can return STALE words, and the fault window vs. the packet's actual
link-word transit is timing-dependent.

This test makes the claim falsifiable:
  * DRAIN the destination RX FIFO before every trial (so a stale word can never
    masquerade as a delivery),
  * use a UNIQUE payload per trial (so stale data is always distinguishable),
  * repeat each (lane, mode) R times and report the CLASS HISTOGRAM.

A class is only reported as real if it reproduces. Classes:
  BYTE-EXACT          - delivered correctly despite the fault
  NOT-COMMITTED       - PKT_LEN==0 and no fresh data (dropped / NACKed)
  COMMITTED-WRONG     - PKT_LEN!=0 with data != sent  => SILENT CORRUPTION
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_PKT_WORD_LEN,
)
from errinj_common import (
    inject_data, clear_all, link_healthy, classify_recovery, crc_snapshot,
    M_STUCK0, M_STUCK1, M_STUCKX, M_FLIP,
)

REPS = 4


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy ({detail})"
    return tb


async def _drain_rx(tb, side, words=8):
    """Read the RX FIFO until it stops yielding fresh data, so no stale word
    can be mistaken for a delivery in the next trial."""
    for i in range(words):
        await tb.ahb_fifo_read_word(side, i * 4)
    await ClockCycles(tb.dut.hclk, 200)


async def _trial(tb, dut, lane, mode, tag):
    """One drained, uniquely-tagged injection trial. Returns (klass, plen, got)."""
    await _drain_rx(tb, "m")
    crc_before = crc_snapshot(tb, "m")
    payload = [0x7E570000 | tag, 0xA5000000 | tag]
    words = make_packet(payload)
    inject_data(dut, "s2m", mode, lane_mask=(1 << lane))
    await tb.ahb_tx_write_packet("s", words)
    await ClockCycles(dut.hclk, 3000)
    plen = await tb.apb("m").read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word("m", i * 4) for i in range(4)]
    crc_after = crc_snapshot(tb, "m")
    clear_all(dut)
    await ClockCycles(dut.hclk, 1500)

    byte_exact = (got[0] == words[0] and got[2] == payload[0]
                  and got[3] == payload[1])
    fresh = any(g not in (0,) and (g & 0xFFFF) == (tag & 0xFFFF) for g in got)
    if byte_exact:
        klass = "BYTE-EXACT"
    elif plen != 0:
        klass = "COMMITTED-WRONG"          # silent corruption
    elif fresh:
        klass = "COMMITTED-WRONG"          # fresh but wrong, len not latched
    else:
        klass = "NOT-COMMITTED"
    # FLAGGED vs SILENT: did the FCSM's CRC error state move for this packet?
    flagged = (crc_after["crc_errors"] != crc_before["crc_errors"]
               or crc_after["io_rx_crc_err"] == 1)
    if klass == "COMMITTED-WRONG":
        klass += "/FLAGGED" if flagged else "/SILENT"
    return klass, plen, got, words, crc_before, crc_after


async def _sweep_lane_mode(dut, lane, mode, name):
    tb = await _bringup_healthy(dut)
    hist = {}
    for r in range(REPS):
        klass, plen, got, words, cb, ca = await _trial(tb, dut, lane, mode,
                                                       0x10 + r)
        hist[klass] = hist.get(klass, 0) + 1
        tb.log.info(f"  lane{lane} {name} rep{r} -> {klass} "
                    f"(PKT_LEN=0x{plen:x} sent_hdr=0x{words[0]:08x} "
                    f"got=[{', '.join(hex(w) for w in got)}] "
                    f"crc_errors {cb['crc_errors']}->{ca['crc_errors']} "
                    f"rx_crc_err {cb['io_rx_crc_err']}->{ca['io_rx_crc_err']})")
        ok, _ = await link_healthy(tb)
        if not ok:
            await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S3b_lane{lane}_{name}_x{REPS}]: histogram={hist}")


@cocotb.test()
async def test_01_lane7_flip_repro(dut):
    await _sweep_lane_mode(dut, 7, M_FLIP, "flip")


@cocotb.test()
async def test_02_lane6_flip_control(dut):
    """Control: the adjacent lane, same stimulus."""
    await _sweep_lane_mode(dut, 6, M_FLIP, "flip")


@cocotb.test()
async def test_03_lane7_stuck1_repro(dut):
    await _sweep_lane_mode(dut, 7, M_STUCK1, "stuck1")


@cocotb.test()
async def test_04_lane7_stuck0_repro(dut):
    await _sweep_lane_mode(dut, 7, M_STUCK0, "stuck0")

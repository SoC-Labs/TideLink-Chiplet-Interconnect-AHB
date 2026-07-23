"""F14 · Scenario 3c — FULL 8-LANE x 3-MODE x 2-DIRECTION corruption sweep.

WHY THIS EXISTS
---------------
`test_ei_lane7_repro.py` proved, under a strict protocol, that corrupting lane 7
makes the RX COMMIT a packet with a corrupted length and payload while raising no
CRC error, and that the lane-6 control is correctly NOT committed. That leaves the
severity question open:

    Is the silent commit LANE-7-SPECIFIC (lane 7 happens to carry the length /
    header bits -> bad, bounded, explainable), or is it GENERIC (any lane's
    corruption can be silently committed -> the link has no working integrity
    check at all)?

This test answers it by classifying every (lane, mode, direction) cell under the
SAME strict protocol lane Y-C established:
  * DRAIN the destination RX FIFO before every trial (a stale word must never be
    mistakable for a delivery),
  * UNIQUE payload tag per trial (stale data is always distinguishable),
  * REPEAT each cell REPS times and report the class HISTOGRAM,
  * SAMPLE the FCSM CRC state immediately before and after every trial.

*** INSTRUMENT CORRECTION — READ THIS BEFORE COMPARING TO THE OLD RESULTS ***
----------------------------------------------------------------------------
`test_ei_lane7_repro.py` classified a trial as COMMITTED using `PKT_WORD_LEN`
(APB 0x2008) != 0. **That register is not a commit indicator.** It is the
*in-progress* packet-length latch `packet_word_length_r`
(`src/rtl/fifo/tidelink_fifo_ctrl.sv:199,204,232`), and it is explicitly
**cleared to 0 the moment the packet completes**:

    src/rtl/fifo/tidelink_fifo_ctrl.sv:192-194
        if (write_complete || read_complete) begin
            packet_word_length_nxt = '0;

So a **correctly delivered** packet reads PKT_WORD_LEN == 0 (confirmed on every
healthy round trip in this bench's own log), and PKT_WORD_LEN != 0 means the
packet write is **still open / never completed** — the opposite of committed.

This test therefore classifies on the GROUND TRUTH for commit, sampled directly
from the RX FIFO controller (`u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl`):

  * `write_ptr_r`           advances by (len+2)*4 on commit  (:121-122)
  * `credit_count_r`        decrements by (len+2)  on commit  (:270-275)
  * `packet_committed_irq_r` sets on `write_complete`         (:302)
  * `packet_active_r`       left 1 => an OPEN, never-completed packet (:200)

COMMIT is defined as `write_ptr_r` advancing. Everything else is corroboration.

CLASSES
-------
  BYTE-EXACT               committed and byte-identical to what was sent
  COMMITTED-WRONG          write_ptr advanced (packet accepted into the FIFO)
                           but the contents differ from what was sent
  NOT-COMMITTED            write_ptr did not advance -> packet rejected
  (each of the two non-exact classes is suffixed /FLAGGED or /SILENT depending
   on whether ANY error indication moved, and NOT-COMMITTED additionally gets
   +OPEN if it left packet_active_r=1, and +READABLE if the corrupt words were
   nonetheless visible through the AHB RX aperture.)

Both outcomes are split on the flag axis deliberately. Y-C's honest caveat was
that `crc_errors` stayed 0 for the lane-6 control too, so "the CRC rejected
lane 6" was never shown. Splitting both outcomes makes that testable.

LINK HYGIENE
------------
A corrupted lane can wedge the link (see S1/S3c). If a trial leaves the link
unhealthy the sweep re-brings-up before continuing, and the trial that caused it
is annotated `+DISTURBED`, so a wedge can never silently contaminate the
classification of the following cells.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_PKT_WORD_LEN,
)
from errinj_common import (
    inject_data, clear_all, link_healthy, crc_snapshot,
    M_STUCK0, M_STUCK1, M_FLIP,
)

REPS = 4
LANES = range(8)

# direction -> (injector direction, packet source side, packet dest side)
#   'm2s' corrupts the SLAVE's RX  -> drive m->s, observe at 's'
#   's2m' corrupts the MASTER's RX -> drive s->m, observe at 'm'
DIRS = {
    "m2s": ("m2s", "m", "s"),
    "s2m": ("s2m", "s", "m"),
}

MODES = [(M_FLIP, "flip"), (M_STUCK1, "stuck1"), (M_STUCK0, "stuck0")]


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy ({detail})"
    return tb


async def _drain_rx(tb, side, words=8):
    for i in range(words):
        await tb.ahb_fifo_read_word(side, i * 4)
    await ClockCycles(tb.dut.hclk, 200)


def _fifoctrl(tb, side):
    """The RX FIFO controller that actually decides commit-vs-reject."""
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def _fifo_snapshot(tb, side):
    """GROUND TRUTH for 'was this packet committed?'. See module docstring."""
    fc = _fifoctrl(tb, side)
    out = {}
    for name in ("write_ptr_r", "read_ptr_r", "credit_count_r",
                 "packet_active_r", "packet_word_length_r",
                 "packet_committed_irq_r", "overrun_r", "underrun_r"):
        try:
            out[name] = int(fc._id(name, extended=False).value)
        except Exception:
            try:
                out[name] = int(getattr(fc, name).value)
            except Exception:
                out[name] = -1
    return out


def _err_snapshot(tb, side):
    """Every error/status flag a receiver could plausibly use to reject a
    packet, sampled together so we can say WHICH one (if any) moved."""
    snap = crc_snapshot(tb, side)
    fc = tb.fcsm(side)
    for name in ("send_nack_req", "crcCorruptSeen", "isNotExpPacket",
                 "exp_pkt_not_seen", "valid_rx_pkt_crc_err",
                 "pkt_is_data_pkt", "state"):
        try:
            snap[name] = int(getattr(fc, name).value)
        except (AttributeError, ValueError, TypeError):
            snap[name] = -1
    return snap


def _flag_moved(before, after):
    """Did ANY error indication change / assert across the trial?"""
    moved = []
    if after["crc_errors"] != before["crc_errors"]:
        moved.append("crc_errors")
    if after["io_rx_crc_err"] == 1:
        moved.append("io_rx_crc_err")
    for k in ("send_nack_req", "crcCorruptSeen", "isNotExpPacket",
              "valid_rx_pkt_crc_err"):
        if after.get(k, -1) == 1 and before.get(k, -1) != 1:
            moved.append(k)
    return moved


async def _trial(tb, dut, inj_dir, src, dst, lane, mode, tag):
    await _drain_rx(tb, dst)
    before = _err_snapshot(tb, dst)
    fbefore = _fifo_snapshot(tb, dst)

    payload = [0x7E570000 | tag, 0xA5000000 | tag]
    words = make_packet(payload)

    inject_data(dut, inj_dir, mode, lane_mask=(1 << lane))
    await tb.ahb_tx_write_packet(src, words)
    await ClockCycles(dut.hclk, 3000)

    # Sample commit state BEFORE any AHB read — reading the aperture perturbs
    # read_ptr / packet_committed_irq / packet_word_length, so the post-write
    # sample is the only uncontaminated one.
    fafter = _fifo_snapshot(tb, dst)
    plen = await tb.apb(dst).read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    after = _err_snapshot(tb, dst)

    clear_all(dut)
    await ClockCycles(dut.hclk, 1500)

    # --- GROUND TRUTH: did the RX FIFO commit the packet? ---
    committed = (fafter["write_ptr_r"] != fbefore["write_ptr_r"]
                 or fafter["packet_committed_irq_r"] == 1
                 or fafter["credit_count_r"] < fbefore["credit_count_r"])
    left_open = (fafter["packet_active_r"] == 1)

    byte_exact = (got[0] == words[0] and got[2] == payload[0]
                  and got[3] == payload[1])
    # "fresh" == carries THIS trial's unique tag, so a stale FIFO word can never
    # be mistaken for a delivery. Note this is READ-VISIBILITY, which is NOT the
    # same thing as commit: the FC writes land in the SRAM as they arrive and
    # the AHB aperture reads the SRAM at read_ptr, so an UNCOMMITTED packet's
    # bytes can still be read out. Tracking both is the point.
    fresh = any(g != 0 and (g & 0xFFFF) == (tag & 0xFFFF) for g in got)

    if committed and byte_exact:
        klass = "BYTE-EXACT"
    elif committed:
        klass = "COMMITTED-WRONG"
    else:
        klass = "NOT-COMMITTED"

    moved = _flag_moved(before, after)
    if klass != "BYTE-EXACT":
        klass += "/FLAGGED" if moved else "/SILENT"
    if not committed:
        if left_open:
            klass += "+OPEN"
        if fresh:
            klass += "+READABLE"
    return klass, plen, got, words, before, after, moved, fbefore, fafter


async def _sweep(dut, dirname, modeval, modename, lanes):
    """One bring-up, then REPS trials on each lane in `lanes`.

    HARNESS CONSTRAINT (measured, 2026-07-18): a SECOND `run_bringup_full` in the
    same simulation does NOT re-run autocal — the retry comes back cal=IDLE /
    cal_done=0 / fcsm=0 and CR/CRACK never lands. There is therefore exactly ONE
    usable healthy link per cocotb test, so this sweep must NOT try to recover
    in-test. Instead each cell is a separate cocotb test (its own bring-up), and
    a trial that leaves the link degraded is annotated `+DISTURBED` and the row
    is ABORTED rather than continuing to classify against a broken link. Silence
    would be worse than a short row.
    """
    inj_dir, src, dst = DIRS[dirname]
    tb = await _bringup_healthy(dut)
    tag = 0x10
    matrix = {}
    for lane in lanes:
        hist = {}
        aborted = False
        for r in range(REPS):
            tag = (tag + 1) & 0xFF
            (klass, plen, got, words, before, after, moved,
             fb, fa) = await _trial(tb, dut, inj_dir, src, dst,
                                    lane, modeval, tag)
            # Drain BOTH apertures before the health probe: a half-consumed RX
            # FIFO makes a perfectly good health packet read back misaligned,
            # which would otherwise be misreported as fault-induced damage.
            await _drain_rx(tb, "m")
            await _drain_rx(tb, "s")
            ok, detail = await link_healthy(tb)
            if not ok:
                klass += "+DISTURBED"
            hist[klass] = hist.get(klass, 0) + 1
            tb.log.info(
                f"  [{dirname}] lane{lane} {modename} rep{r} -> {klass} "
                f"(PKT_LEN=0x{plen:x} sent_hdr=0x{words[0]:08x} "
                f"got=[{', '.join(hex(w) for w in got)}] "
                f"crc_errors {before['crc_errors']}->{after['crc_errors']} "
                f"rx_crc_err {before['io_rx_crc_err']}->{after['io_rx_crc_err']} "
                f"flags_moved={moved or 'NONE'} | "
                f"wptr {fb['write_ptr_r']}->{fa['write_ptr_r']} "
                f"cred {fb['credit_count_r']}->{fa['credit_count_r']} "
                f"pkt_active {fb['packet_active_r']}->{fa['packet_active_r']} "
                f"pwl {fb['packet_word_length_r']}->{fa['packet_word_length_r']} "
                f"cmt_irq {fa['packet_committed_irq_r']} "
                f"ovr/und {fa['overrun_r']}/{fa['underrun_r']})")
            if not ok:
                tb.log.warning(f"  link left DEGRADED by lane{lane} {modename} "
                               f"rep{r} ({detail}) — aborting this row; the "
                               f"harness cannot re-bring-up in-sim.")
                aborted = True
                break
        matrix[lane] = hist
        tb.log.info(f" ROW[{dirname}/{modename}/lane{lane}]: {hist}"
                    f"{' (ABORTED EARLY)' if aborted else ''}")
        if aborted:
            break
    tb.log.info(f"VERDICT[S3c_sweep_{dirname}_{modename}_x{REPS}]: {matrix}")


def _mk(dirname, modeval, modename, lane):
    @cocotb.test(name=f"test_{dirname}_{modename}_lane{lane}")
    async def _t(dut, _d=dirname, _mv=modeval, _mn=modename, _l=lane):
        await _sweep(dut, _d, _mv, _mn, [_l])
    return _t


# 8 lanes x 3 modes x 2 directions = 48 independent cells, each with its own
# bring-up. Select groups with cocotb's TESTCASE= (see the Makefile's
# `ei_sweep` target).
for _dirname in ("s2m", "m2s"):
    for _modeval, _modename in MODES:
        for _lane in LANES:
            globals()[f"test_{_dirname}_{_modename}_lane{_lane}"] = _mk(
                _dirname, _modeval, _modename, _lane)

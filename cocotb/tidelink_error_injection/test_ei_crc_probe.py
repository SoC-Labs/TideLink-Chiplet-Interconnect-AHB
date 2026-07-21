"""F14 · Scenario 3d — WHAT DOES THE CRC ACTUALLY PROTECT?

The lane-7 finding (F14-A) rests on `crc_errors` reading 0 across a corrupted
packet. That is a BEFORE/AFTER sample of a counter, and a counter sample is a
weak instrument for a combinational event:

  * `crc_errors` lives in the io_rx_clk domain and is FORCED TO ZERO on every
    edge that `en_ff2_rx` (the demetted app `enable`) is low
    (`WlinkGenericFCSM_6.v:670-672`), so any enable dip ERASES the evidence;
  * it is also async-reset by `io_rx_reset`;
  * so "crc_errors was 0 afterwards" does NOT establish "the CRC never fired".

This test replaces the sample with a CONTINUOUS MONITOR: a coroutine latches
every assertion of the combinational `crc_corrupt` / `valid_rx_pkt_crc_err` /
`pkt_is_data_pkt` / `send_nack_req` wires for the whole duration of a packet,
so a single-cycle assertion cannot be missed. It also dumps the STATIC CRC
configuration, because if `disable_crc` is set then the integrity check does not
exist in this build and every "the CRC missed it" statement is the wrong claim.

WHAT THE RTL SAYS THE COVERAGE IS (for the report; this test checks it)
----------------------------------------------------------------------
A Wlink data packet on the wire is 13 bytes (`wordCountSize = 56/8 = 7`,
`FC.scala:74`):

    byte 0      data_id
    byte 1..2   word_count (= 7)
    byte 3      ECC over the 24-bit header       <- SEC-DED, NOT the CRC
    byte 4..10  ll.data[55:0] = {48b app data, 8b FC pkt num}
    byte 11..12 CRC-16

  * `FC.scala:155`   rx_crc_computed = WlinkCrcGen(ll_rx.data)
  * `LinkLayer.scala:786-794`  ll.data  = bytes 4..10,
                               ll.crc   = bytes (word_count+4), (word_count+5)
  * `FC.scala:157`   crc_corrupt = sop && valid && (data_id === swi_data_id)
                                   && ~disable_crc && (computed =/= received)

So the CRC covers the ENTIRE 56-bit data field and NOTHING ELSE. The header
(data_id / word_count) is covered only by the ECC byte, and — critically — the
CRC comparison is GATED on `data_id === swi_data_id`, so a corruption that
changes the data_id makes the packet not-a-data-packet and the CRC is never
evaluated at all.

With 8 lanes x 16-bit phyDataWidth the RX packs 16 bytes/cycle, so the whole
13-byte packet lands in ONE cycle and the lane->field map is fixed
(`LinkLayer.scala:768-778`: lane i low byte -> byte_index[i], high byte ->
byte_index[i+8]):

    lane 0 lo -> byte 0  data_id        lane 0 hi -> byte 8   app[31:24]
    lane 1 lo -> byte 1  word_count lo  lane 1 hi -> byte 9   app[39:32]
    lane 2 lo -> byte 2  word_count hi  lane 2 hi -> byte 10  app[47:40]
    lane 3 lo -> byte 3  ECC            lane 3 hi -> byte 11  CRC[7:0]
    lane 4 lo -> byte 4  FC pkt num     lane 4 hi -> byte 12  CRC[15:8]
    lane 5 lo -> byte 5  app[7:0]       lane 5 hi -> byte 13  (unused)
    lane 6 lo -> byte 6  app[15:8]      lane 6 hi -> byte 14  (unused)
    lane 7 lo -> byte 7  app[23:16]     lane 7 hi -> byte 15  (unused)

That map PREDICTS the F14-A observation exactly: a lane-7 flip inverts
app[23:16], which is byte 2 of the TideLink header word, so 0x00240000 becomes
0x00db0000, and TideLink's length field (bits [31:20],
`tidelink_fifo_ctrl.sv:203`) reads 0xd instead of 0x2 — precisely the PKT_LEN
lane Y-C measured. This test checks the map against silicon-of-record (sim)
rather than leaving it as arithmetic.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_PKT_WORD_LEN,
)
from errinj_common import (
    inject_data, clear_all, link_healthy, M_FLIP,
)

# Combinational / registered signals in WlinkGenericFCSM_6 worth latching.
WATCH = ("crc_corrupt", "valid_rx_pkt_crc_err", "pkt_is_data_pkt",
         "send_nack_req", "crcCorruptSeen", "isNotExpPacket",
         "pkt_is_cr_pkt", "pkt_is_ack_pkt", "pkt_is_nack_pkt")

STATIC = ("out_prepend_swi_disable_crc", "swi_data_id_1",
          "en_ff2_rx_demet_io_out", "crc_errors")


def _sig(fc, name):
    try:
        return getattr(fc, name)
    except AttributeError:
        return None


def _rd(fc, name, default=-1):
    s = _sig(fc, name)
    if s is None:
        return default
    try:
        return int(s.value)
    except (ValueError, TypeError):
        return default


class CrcMonitor:
    """Latches ANY assertion of the watched wires until stopped. A before/after
    counter sample cannot see a single-cycle pulse; this can."""

    def __init__(self, tb, side):
        self.tb = tb
        self.fc = tb.fcsm(side)
        self.seen = {n: 0 for n in WATCH}
        self.crc_errors_max = 0
        self._run = False
        self._task = None

    async def _loop(self):
        while self._run:
            await RisingEdge(self.tb.dut.hclk)
            for n in WATCH:
                if _rd(self.fc, n, 0) == 1:
                    self.seen[n] += 1
            ce = _rd(self.fc, "crc_errors", 0)
            if ce > self.crc_errors_max:
                self.crc_errors_max = ce

    def start(self):
        self._run = True
        self.seen = {n: 0 for n in WATCH}
        self.crc_errors_max = 0
        self._task = cocotb.start_soon(self._loop())

    def stop(self):
        self._run = False

    def asserted(self):
        return {n: v for n, v in self.seen.items() if v}


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


@cocotb.test()
async def test_01_crc_config_and_coverage(dut):
    """Static config first (is the CRC even enabled?), then a monitored clean
    packet (does the monitor stay quiet on a good packet — instrument sanity),
    then a monitored corrupted packet on every lane."""
    tb = await _bringup_healthy(dut)
    fc = tb.fcsm("m")

    # ---- 1. STATIC CONFIG: does the integrity check exist in this build? ----
    cfg = {n: _rd(fc, n) for n in STATIC}
    tb.log.info(f"VERDICT[S3d_crc_static_config]: {cfg}")
    dis = cfg["out_prepend_swi_disable_crc"]
    if dis == 1:
        tb.log.warning("VERDICT[S3d_crc_DISABLED]: out_prepend_swi_disable_crc=1 "
                       "-> FC.scala:157 forces crc_corrupt=false. THE DATA-PATH "
                       "INTEGRITY CHECK DOES NOT EXIST IN THIS CONFIGURATION.")
    elif dis == 0:
        tb.log.info("VERDICT[S3d_crc_ENABLED]: out_prepend_swi_disable_crc=0 "
                    "-> the CRC comparison is live (FC.scala:157).")
    else:
        tb.log.warning("VERDICT[S3d_crc_UNREADABLE]: could not read "
                       "out_prepend_swi_disable_crc — treat CRC state as UNKNOWN.")

    # ---- 2. INSTRUMENT SANITY: a CLEAN packet must not trip the monitor ----
    await _drain_rx(tb, "m")
    mon = CrcMonitor(tb, "m")
    mon.start()
    words = make_packet([0x7E570000 | 0xC0, 0xA5000000 | 0xC0])
    await tb.ahb_tx_write_packet("s", words)
    await ClockCycles(dut.hclk, 3000)
    mon.stop()
    clean = dict(mon.asserted())
    clean_max = mon.crc_errors_max
    got = [await tb.ahb_fifo_read_word("m", i * 4) for i in range(4)]
    tb.log.info(f"VERDICT[S3d_clean_baseline]: asserted={clean} "
                f"crc_errors_max={clean_max} got=[{', '.join(hex(w) for w in got)}]")
    if clean.get("pkt_is_data_pkt", 0) == 0:
        tb.log.warning("  INSTRUMENT WARNING: pkt_is_data_pkt never asserted even "
                       "on a CLEAN delivered packet -> the monitor is not seeing "
                       "the RX packet events; treat all S3d results as UNPROVEN.")

    # ---- 3. PER-LANE: does the CRC fire for a corruption in its coverage? ----
    for lane in range(8):
        await _drain_rx(tb, "m")
        mon.start()
        tag = 0xD0 + lane
        payload = [0x7E570000 | tag, 0xA5000000 | tag]
        words = make_packet(payload)
        inject_data(dut, "s2m", M_FLIP, lane_mask=(1 << lane))
        await tb.ahb_tx_write_packet("s", words)
        await ClockCycles(dut.hclk, 3000)
        mon.stop()
        seen = dict(mon.asserted())
        cmax = mon.crc_errors_max
        plen = await tb.apb("m").read(APB_PKT_WORD_LEN)
        got = [await tb.ahb_fifo_read_word("m", i * 4) for i in range(4)]
        clear_all(dut)
        await ClockCycles(dut.hclk, 1500)
        tb.log.info(
            f"VERDICT[S3d_lane{lane}_flip]: crc_corrupt={seen.get('crc_corrupt',0)} "
            f"valid_rx_pkt_crc_err={seen.get('valid_rx_pkt_crc_err',0)} "
            f"pkt_is_data_pkt={seen.get('pkt_is_data_pkt',0)} "
            f"send_nack_req={seen.get('send_nack_req',0)} "
            f"crc_errors_max={cmax} PKT_LEN=0x{plen:x} "
            f"got=[{', '.join(hex(w) for w in got)}] all={seen}")
        ok, detail = await link_healthy(tb)
        if not ok:
            tb.log.warning(f"  link DEGRADED after lane{lane} ({detail}) — "
                           f"later lanes in this test are NOT trustworthy; "
                           f"re-run the remaining lanes in a fresh sim.")
            break
        await _drain_rx(tb, "m")
        await _drain_rx(tb, "s")


@cocotb.test()
async def test_02_when_is_crc_disabled(dut):
    """WHEN does `disable_crc` become 1? This decides where the fix lives.

    `out_prepend_swi_disable_crc` has POR = 1'h0 (`WlinkGenericFCSM_6.v:656-657`)
    and is only writable from APB bit[16] of the FC node's SM_CONTROL register
    (offset 0x14, `:425-426,658-659`; cf. `src/sw/wlink.h:144,161`). So a value
    of 1 after bring-up means EITHER
      (a) the register is never reset in this build (the reg is X/1 by accident),
      (b) something in the bring-up writes bit[16], or
      (c) the reset is asserted but the value is driven back to 1 afterwards.
    Sampling the bit across the bring-up phases distinguishes these, and
    (a) vs (b) is the difference between an RTL/reset bug and a one-line
    bring-up-recipe change.
    """
    tb = PairV2TB(dut)
    marks = []

    def mark(label):
        for side in ("m", "s"):
            fc = tb.fcsm(side)
            s = _sig(fc, "out_prepend_swi_disable_crc")
            raw = "?" if s is None else str(s.value)
            marks.append((label, side, raw, _rd(fc, "out_prepend_swi_disable_crc")))

    mark("t0 (pre-reset)")
    await tb.reset()
    mark("after tb.reset()")
    await tb.do_role_lock()
    await tb.wait_role_locked()
    mark("after role_lock")
    await tb.wait_cal_done()
    mark("after autocal")
    await tb.do_to_data_mode()
    await ClockCycles(dut.hclk, 5000)
    mark("after to_data_mode")
    await tb.wait_cr_crack()
    mark("after CR/CRACK")

    for label, side, raw, val in marks:
        tb.log.info(f"  disable_crc[{side}] @ {label:22s} = {val} (raw '{raw}')")
    tb.log.info(f"VERDICT[S3d_disable_crc_timeline]: "
                f"{[(l, s, v) for l, s, _, v in marks]}")

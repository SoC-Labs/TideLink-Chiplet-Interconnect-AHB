"""STEP 3 — pinpoint the abort, with statistics.

test_crc_beacon_ab established the failing cell: 4-lane (0xE4) AND the SYNC
beacon in force_always mode. Neither alone fails. This test instruments
WlinkRxLinkLayer on the receiving die to show WHERE the packet dies.

The claim being tested:

    WlinkRxLinkLayer.v:393   sync_resync_boundary = sync_resync & (state != 2'h1)

d593058 added the `state != 2'h1` term so a beacon cannot abort a long packet
while its BODY is being consumed (state 1). But a long packet that spans more
than one beat is ALSO vulnerable on its FIRST beat, which is consumed in
state 0 (the header beat, where is_long_pkt latches word_count and sets
byte_count = bytesPerCycle before moving to state 1). In that cycle
state == 0, so the guard does NOT apply, and sync_resync_boundary takes
PRIORITY over the state==0 branch in all three registers:

    state      <= 2'h0     (WlinkRxLinkLayer.v:1272)
    word_count <= 16'h0    (WlinkRxLinkLayer.v:1858)
    byte_count <= 17'h0    (WlinkRxLinkLayer.v:1875)

so the half-consumed long packet is discarded and its remaining body bytes are
re-parsed as a fresh header.

That window EXISTS only when a long packet needs more than one beat:
    beats = ceil((word_count + 6) / bytesPerCycle) = ceil(13 / bytesPerCycle)
    8 lanes -> bytesPerCycle = 16 -> 1 beat  -> no window  -> immune
    4 lanes -> bytesPerCycle =  8 -> 2 beats -> window     -> vulnerable

which is exactly the 8-lane/4-lane split measured in test_crc_beacon_ab.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import make_packet
from crc_common import bringup, drain_rx, enable_crc, CrcMonitor, rd
from test_crc_beacon_ab import set_beacon, force_lane_mask, ACTIVE_MASK_4LANE

N_PACKETS = 24


class RxFramerTrace:
    """Latch every cycle where sync_resync_boundary fires, together with the
    framer state it fired in, so a beacon that lands on the packet-START beat
    is distinguishable from one that lands on an idle bus."""

    def __init__(self, tb, side):
        self.tb = tb
        self.llrx = tb.top(side).u_chiplet_controller.u_wlink.llrx
        self.reset()
        self._run = False

    def reset(self):
        self.resync_in_state = {0: 0, 1: 0, 2: 0, 3: 0}
        self.resync_on_long_start = 0
        self.long_starts = 0

    async def _loop(self):
        llrx = self.llrx
        while self._run:
            await RisingEdge(self.tb.dut.hclk)
            st = rd(llrx, "state", -1)
            boundary = rd(llrx, "sync_resync_boundary", 0)
            is_long = rd(llrx, "is_long_pkt", 0)
            en = rd(llrx, "enable_ff2_demet_io_out", 0)
            # A "long packet start beat": framer in hunt, a well-formed long
            # header decoded this cycle.
            long_start = (st == 0 and is_long == 1 and en == 1)
            if long_start:
                self.long_starts += 1
            if boundary == 1:
                if st in self.resync_in_state:
                    self.resync_in_state[st] += 1
                if long_start:
                    self.resync_on_long_start += 1

    def start(self):
        self.reset()
        self._run = True
        cocotb.start_soon(self._loop())

    def stop(self):
        self._run = False


@cocotb.test()
async def test_20_rootcause_4lane_beacon(dut):
    """Failing cell, N packets, with the framer instrumented."""
    tb = await bringup(dut)
    force_lane_mask(tb, ACTIVE_MASK_4LANE)
    await ClockCycles(dut.hclk, 2000)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    await set_beacon(tb, True)

    mon = CrcMonitor(tb, "m")
    trace = RxFramerTrace(tb, "m")
    bad, crc_fired, total = 0, 0, 0
    first_bad = None

    for i in range(N_PACKETS):
        await drain_rx(tb, "m")
        mon.start()
        trace.start()
        words = make_packet([0x7E570000 | i, 0xA5000000 | i])
        await tb.ahb_tx_write_packet("s", words)
        await ClockCycles(dut.hclk, 4000)
        mon.stop()
        trace.stop()
        got = [await tb.ahb_fifo_read_word("m", j * 4) for j in range(4)]
        ok = all(got[j] == words[j] for j in range(4))
        fired = mon.seen.get("crc_corrupt", 0)
        total += 1
        if not ok:
            bad += 1
        if fired:
            crc_fired += 1
        if (not ok or fired) and first_bad is None:
            first_bad = mon.report(f"pkt{i}")
        tb.log.info(
            f"  pkt{i:02d}: delivered={ok} crc_corrupt={fired} "
            f"resync_by_state={trace.resync_in_state} "
            f"long_starts={trace.long_starts} "
            f"resync_ON_LONG_START={trace.resync_on_long_start}")

    tb.log.info(f"VERDICT[rootcause_stats]: {bad}/{total} packets corrupt, "
                f"{crc_fired}/{total} tripped the CRC")
    if first_bad:
        tb.log.info(f"VERDICT[rootcause_first_bad]: {first_bad}")

    tb.log.info(
        "VERDICT[rootcause_mechanism]: sync_resync_boundary "
        "(WlinkRxLinkLayer.v:393) is gated only on state != 1 (packet BODY). "
        "A beacon landing on the packet-START beat (state == 0 with "
        "is_long_pkt) still zeroes state/word_count/byte_count at :1272/:1858/"
        ":1875, aborting a multi-beat long packet. The window exists only when "
        "ceil(13 / bytesPerCycle) > 1, i.e. 4 lanes (8 B/cyc) and not 8 lanes "
        "(16 B/cyc).")

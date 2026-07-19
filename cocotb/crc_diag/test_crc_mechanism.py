"""STEP 4 — correct the mechanism, and separate 'wedge' from 'per-packet corruption'.

test_crc_rootcause REFUTED its own hypothesis: `resync_ON_LONG_START` was 0 in
every window. That is structural, not luck -- a given RX cycle carries EITHER a
SYNC beacon OR packet data, so `sync_resync` (beacon decoded) and `is_long_pkt`
(long header decoded) can never be true in the same cycle. Any explanation that
needs them to coincide is dead.

The surviving mechanism is the one d593058 half-addressed:

    beat 0 of a 2-beat long packet is consumed in state 0  -> state := 1
    the NEXT cycle carries a SYNC beacon
    sync_resync_boundary = sync_resync & (state != 1)  ->  BLOCKED (state==1)

so the framer is no longer reset -- but nothing SKIPS the beacon word either.
In state 1 the body-accumulate path runs on io_ll_rx_valid, so the beacon's
16 bytes are absorbed INTO THE PACKET BODY, overwriting ll_byte_index at
byte_count.. . The CRC bytes then read back as beacon bytes -> CRC mismatch,
or the packet is silently mis-assembled.

At 8 lanes the whole 13-byte packet is consumed in ONE beat, so there is no
mid-packet cycle for a beacon to land in -> immune. That reproduces the exact
8-lane/4-lane split measured in test_crc_beacon_ab.

This test measures, per packet window:
  * beacon_while_state1 -- beacon cycles landing MID-LONG-PACKET (the claim)
  * guard_blocked       -- cycles where d593058's guard actually suppressed a reset
  * whether the link is WEDGED (a beacon-off packet after the failures recovers)
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import make_packet
from crc_common import bringup, drain_rx, enable_crc, CrcMonitor, rd
from test_crc_beacon_ab import set_beacon, force_lane_mask, ACTIVE_MASK_4LANE


class Trace:
    def __init__(self, tb, side):
        self.tb = tb
        self.llrx = tb.top(side).u_chiplet_controller.u_wlink.llrx
        self.reset()
        self._run = False

    def reset(self):
        self.beacon_while_state1 = 0   # beacon lands mid-long-packet body
        self.guard_blocked = 0         # d593058's guard suppressed a reset
        self.resync_fired = 0          # reset actually happened
        self.state1_cycles = 0

    async def _loop(self):
        llrx = self.llrx
        while self._run:
            await RisingEdge(self.tb.dut.hclk)
            st = rd(llrx, "state", -1)
            resync = rd(llrx, "sync_resync", 0)
            boundary = rd(llrx, "sync_resync_boundary", 0)
            if st == 1:
                self.state1_cycles += 1
                if resync == 1:
                    self.beacon_while_state1 += 1
                    if boundary == 0:
                        self.guard_blocked += 1
            if boundary == 1:
                self.resync_fired += 1

    def start(self):
        self.reset()
        self._run = True
        cocotb.start_soon(self._loop())

    def stop(self):
        self._run = False

    def d(self):
        return {"beacon_while_state1": self.beacon_while_state1,
                "guard_blocked": self.guard_blocked,
                "resync_fired": self.resync_fired,
                "state1_cycles": self.state1_cycles}


async def _send(tb, mon, trace, i, rx="m", tx="s"):
    await drain_rx(tb, rx)
    mon.start()
    trace.start()
    words = make_packet([0x7E570000 | i, 0xA5000000 | i])
    await tb.ahb_tx_write_packet(tx, words)
    await ClockCycles(tb.dut.hclk, 4000)
    mon.stop()
    trace.stop()
    got = [await tb.ahb_fifo_read_word(rx, j * 4) for j in range(4)]
    ok = all(got[j] == words[j] for j in range(4))
    return ok, mon.seen.get("crc_corrupt", 0), trace.d(), got, words


@cocotb.test()
async def test_30_mechanism_and_wedge(dut):
    """Beacon ON for 8 packets, then beacon OFF for 4 -- if the OFF packets
    recover, the failures were per-packet corruption, not a wedge."""
    tb = await bringup(dut)
    force_lane_mask(tb, ACTIVE_MASK_4LANE)
    await ClockCycles(dut.hclk, 2000)
    for s in ("m", "s"):
        await enable_crc(tb, s)

    mon = CrcMonitor(tb, "m")
    trace = Trace(tb, "m")

    await set_beacon(tb, True)
    on_ok = 0
    for i in range(8):
        ok, fired, d, got, words = await _send(tb, mon, trace, i)
        on_ok += ok
        tb.log.info(f"  BEACON_ON  pkt{i:02d}: delivered={ok} crc_corrupt={fired} {d}"
                    + ("" if ok else f" got={[hex(w) for w in got]} "
                                     f"want={[hex(w) for w in words]}"))

    await set_beacon(tb, False)
    await ClockCycles(dut.hclk, 5000)
    off_ok = 0
    for i in range(100, 104):
        ok, fired, d, got, words = await _send(tb, mon, trace, i)
        off_ok += ok
        tb.log.info(f"  BEACON_OFF pkt{i:02d}: delivered={ok} crc_corrupt={fired} {d}"
                    + ("" if ok else f" got={[hex(w) for w in got]}"))

    tb.log.info(f"VERDICT[wedge_test]: beacon_ON {on_ok}/8 delivered, "
                f"then beacon_OFF {off_ok}/4 delivered")
    if off_ok == 4 and on_ok < 8:
        tb.log.info("VERDICT[NOT_A_WEDGE]: the link recovers the moment the "
                    "beacon is turned off -> the beacon corrupts packets "
                    "individually; it does not wedge the framer.")
    elif off_ok < 4:
        tb.log.warning("VERDICT[WEDGED]: failures persist after the beacon is "
                       "off -> the earlier per-packet failure counts are NOT "
                       "per-packet corruption and must not be read as such.")

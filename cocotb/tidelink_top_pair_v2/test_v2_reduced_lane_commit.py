"""REDUCED-LANE RX-FIFO COMMIT gate — reproduces the V2 mask-aware-SYNC defect.

ROOT CAUSE (RTL-verified): under any reduced-lane mask (silicon 0xE4 = lanes
{2,5,6,7}) the V2 RX framer cannot re-align after a byte/word boundary slip.
In src/rtl/local_overrides/WlinkRxLinkLayer.v:321

    wire sync_detected = (io_link_data == SYNC_WORD);   // FULL 128-bit compare

is a full-128 compare, but the PHY TX zeroes masked lanes on the wire
(deps/tidelink-phy/rtl/tidelink_gpio_phy_tx.sv:71-72:
`lane_mask[gi] ? sel_w : 0`). So under 0xE4 the received SYNC beat carries
16'h0000 on lanes {0,1,3,4} and can NEVER equal the 128-bit SYNC_WORD
constant -> sync_detected NEVER pulses -> the framer's re-hunt (:330
sync_resync) AND the SYNC strip (:333 effective_link_data) are both dead.
After any boundary slip, FC words 2-4 mis-frame and silently drop (no ECC).
Only word0 (the header) reaches the L2A replay ring, so the RX-FIFO commit
gate (tidelink_fifo_ctrl.sv: write_complete needs fc_wr_addr ==
write_target_addr_r == 12 for a 2-payload packet) NEVER fires -> write_ptr_r
(RXW) stays 0 and STATUS[4]=0.

This is GEOMETRY-driven (eye-independent). The existing test_v2_reduced_lane
PASSES because its zero-skew sim never slips (the framer locks once and never
needs to re-hunt). This test forces the slip by applying the silicon EPOCH
profile (whole-word cross-lane skew on the active lanes of the masked RX) so
the framer must re-align -> the dead SYNC under 0xE4 is exposed.

WHICH DIRECTION SLIPS:  the Makefile silicon EPOCH_PROFILE applies 3..7-word
epochs on the S->M lanes only (the master's RX), so this gate drives S->M and
asserts the commit on the MASTER's RX FIFO. Build/run:

    make EPOCH_PROFILE=silicon MODULE=test_v2_reduced_lane_commit

The 0xFF control (test_03) runs the SAME stimulus under the full mask and
MUST commit -> proves the delta is purely the reduced-lane mask geometry.
"""
import cocotb
from cocotb.handle import Force
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet,
    APB_PKT_WORD_LEN,
)
from test_v2_reduced_lane import (
    bringup_reduced, ACTIVE_MASK, ACTIVE_LANES, MASKED_LANES,
)

FULL_MASK = 0xFF

# Silicon 4-word structured packet (byte-identical to make_packet):
#   word0 = header (len=2, WR_REQ) = 0x00240000
#   word1 = dest_addr = 0
#   word2,3 = 2 payload words
PAYLOAD = [0xCAFE0002, 0xCAFE0003]

# Unified APB view (HW 0x44032000 -> 0x2000). The FIFO STATUS register is at
# config offset 0x010; bit[4] is packet_committed (tidelink_apb_regs.sv:555).
APB_FIFO_STATUS = 0x2010
STATUS_COMMITTED = lambda v: (v >> 4) & 1


# ---------------------------------------------------------------------------
# Hierarchical probes into the destination die's RX path (root-cause monitor)
# ---------------------------------------------------------------------------
def _fifo_ctrl(tb, side):
    # tidelink_top.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl
    return tb.top(side).u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def read_rxw(tb, side):
    """write_ptr_r (RXW, silicon 0x440320D4) straight off the fifo_ctrl reg."""
    try:
        return int(_fifo_ctrl(tb, side).write_ptr_r.value)
    except (AttributeError, ValueError):
        return -1


def _llrx(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.llrx


class RxFramerMonitor:
    """Passive monitor on the destination die's RX framer + fifo_ctrl.

    Counts sync_detected pulses (root-cause check: 0 under 0xE4),
    l2a_fc_replay_app_valid pulses (expect 1 not 4 under the bug) and
    fifo_ctrl write_complete pulses (expect 0 under the bug)."""

    def __init__(self, tb, side):
        self.tb = tb
        self.side = side
        self.sync_detected_pulses = 0
        self.l2a_valid_pulses = 0
        self.write_complete_pulses = 0
        self._run = False
        self._llrx = _llrx(tb, side)
        self._fcsm = tb.fcsm(side)
        self._fctrl = _fifo_ctrl(tb, side)

    def _get(self, obj, name):
        try:
            return int(getattr(obj, name).value)
        except (AttributeError, ValueError):
            return 0

    async def run(self):
        self._run = True
        prev_sync = prev_l2a = prev_wc = 0
        while self._run:
            await ClockCycles(self.tb.dut.hclk, 1)
            # sync_detected lives in the link-word clock domain; sampling on
            # hclk catches the level often enough to prove it NEVER asserts.
            sd = self._get(self._llrx, "sync_detected")
            if sd and not prev_sync:
                self.sync_detected_pulses += 1
            prev_sync = sd
            l2a = self._get(self._fcsm, "l2a_fc_replay_app_valid")
            if l2a and not prev_l2a:
                self.l2a_valid_pulses += 1
            prev_l2a = l2a
            wc = self._get(self._fctrl, "write_complete")
            if wc and not prev_wc:
                self.write_complete_pulses += 1
            prev_wc = wc

    def stop(self):
        self._run = False


async def _bringup(tb, mask):
    """Bring both dies up under `mask`, confirm bilateral CR/CRACK + FCSM=4."""
    if mask == FULL_MASK:
        await run_bringup_full(tb)
    else:
        await bringup_reduced(tb, mask)
    assert await tb.wait_cr_crack(), (
        f"mask 0x{mask:02x}: link did not reach bilateral CR/CRACK")
    for side, name in (("m", "M"), ("s", "S")):
        assert tb.fcsm_state(side) == 4, (
            f"{name}: FCSM state {tb.fcsm_state(side)} != 4 (LINK_IDLE) "
            f"under mask 0x{mask:02x}")


async def _send_4word_separate(tb, src, words, gap):
    """Send the 4 FC words as 4 SEPARATE AHB-TX writes to offsets 0,4,8,12."""
    for i, w in enumerate(words):
        await tb.ahb_tx_write_word(src, i * 4, w)
        if gap:
            await ClockCycles(tb.dut.hclk, gap)


async def _commit_attempt(tb, mask, gap, ctx):
    """Bring up under `mask`, send the 4-word packet src->dst with inter-word
    `gap`, then read back the COMMIT state on the dst RX FIFO.

    Returns dict: rxw, committed, pkt_len, got[4], and the framer-monitor
    counters."""
    # silicon EPOCH profile skews the S->M lanes (master RX), so drive S->M.
    src, dst = "s", "m"
    await _bringup(tb, mask)

    mon = RxFramerMonitor(tb, dst)
    cocotb.start_soon(mon.run())

    await ClockCycles(tb.dut.hclk, 500)
    rxw_before = read_rxw(tb, dst)

    words = make_packet(PAYLOAD)
    await _send_4word_separate(tb, src, words, gap)
    await ClockCycles(tb.dut.hclk, 4000)

    apb = tb.apb(dst)
    rxw = read_rxw(tb, dst)
    status = await apb.read(APB_FIFO_STATUS)
    pkt_len = await apb.read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    mon.stop()
    await ClockCycles(tb.dut.hclk, 2)

    committed = STATUS_COMMITTED(status)
    tb.log.info(
        f"  [{ctx}] mask=0x{mask:02x} gap={gap} {src}->{dst}: "
        f"RXW {rxw_before}->{rxw} STATUS=0x{status:08x} committed={committed} "
        f"PKT_LEN=0x{pkt_len:x} "
        f"rx=[{', '.join(f'0x{w:08x}' for w in got)}] "
        f"(sent hdr=0x{words[0]:08x} payload=[0x{PAYLOAD[0]:08x},0x{PAYLOAD[1]:08x}])")
    tb.log.info(
        f"  [{ctx}] FRAMER MON ({dst} RX): sync_detected_pulses="
        f"{mon.sync_detected_pulses} l2a_valid_pulses={mon.l2a_valid_pulses} "
        f"write_complete_pulses={mon.write_complete_pulses}")

    payload_ok = (got[0] == words[0] and got[2] == PAYLOAD[0]
                  and got[3] == PAYLOAD[1])
    return {
        "rxw": rxw, "committed": committed, "pkt_len": pkt_len, "got": got,
        "payload_ok": payload_ok, "words": words,
        "sync_pulses": mon.sync_detected_pulses,
        "l2a_pulses": mon.l2a_valid_pulses,
        "wc_pulses": mon.write_complete_pulses,
    }


def _assert_committed(r, ctx):
    assert r["rxw"] > 0, (
        f"{ctx}: RXW (write_ptr) did NOT advance (={r['rxw']}) — the packet "
        f"never committed to the RX FIFO. STATUS committed={r['committed']}, "
        f"rx={r['got']}")
    assert r["committed"] == 1, (
        f"{ctx}: STATUS[4] (packet_committed) == 0 — no commit (RXW={r['rxw']})")
    assert r["payload_ok"], (
        f"{ctx}: committed but payload mismatch: got {r['got']} "
        f"(want hdr=0x{r['words'][0]:08x} payload="
        f"[0x{PAYLOAD[0]:08x},0x{PAYLOAD[1]:08x}])")


# ===========================================================================
# THE GATE (under EPOCH_PROFILE=silicon): the 0xE4 cases must FAIL to commit
# on the CURRENT (unfixed) RTL; the 0xFF control must commit.
# ===========================================================================

@cocotb.test()
async def test_01_reduced_lane_commit_gap(dut):
    """0xE4, PS-latency-spaced (gap>0): the 4-word packet must COMMIT to the
    masked RX FIFO. On unfixed RTL this FAILS (RXW=0) because the framer slips
    under the silicon epoch and the full-128 sync_detected is dead under 0xE4."""
    tb = PairV2TB(dut)
    r = await _commit_attempt(tb, ACTIVE_MASK, gap=4,
                              ctx="0xE4-gap4-commit")
    _assert_committed(r, "0xE4 gap=4 commit")


@cocotb.test()
async def test_02_reduced_lane_commit_b2b(dut):
    """0xE4, back-to-back (gap=0): same commit assertion, b2b spacing forces a
    tighter boundary so the slip is even more likely. Must COMMIT."""
    tb = PairV2TB(dut)
    r = await _commit_attempt(tb, ACTIVE_MASK, gap=0,
                              ctx="0xE4-b2b-commit")
    _assert_committed(r, "0xE4 gap=0 commit")


@cocotb.test()
async def test_03_full_lane_commit_control(dut):
    """0xFF CONTROL, same stimulus + same silicon epoch: full-128 sync_detected
    is alive (no masked lanes), so the framer re-aligns and the packet COMMITS.
    Proves the only variable is the reduced-lane mask."""
    tb = PairV2TB(dut)
    r = await _commit_attempt(tb, FULL_MASK, gap=4,
                              ctx="0xFF-gap4-control")
    _assert_committed(r, "0xFF gap=4 control")
    # Root-cause corroboration: under the full mask the framer's SYNC re-hunt
    # is available (sync_detected can pulse). Logged, not hard-asserted (the
    # zero-skew framer may lock once and never need it).
    tb.log.info(f"  [control] sync_detected_pulses under 0xFF = "
                f"{r['sync_pulses']} (alive path)")

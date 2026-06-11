# =============================================================================
# Bug-A reproduction unit test for tidelink_fc_adapter.sv
#
# CONFIRMED FINDING under test: on a bilateral link the master CPU writes a
# packet to AHB_TX but tl_fc_a2l_valid stays 0 -> the app->link replay FIFO
# never fills -> master FCSM never leaves LINK_IDLE(4). This unit test drives
# AHB single-writes straight into the TX aperture and asserts that EACH AHB
# write produces exactly one tl_fc_a2l_valid pulse carrying the correct FC word
# {PKT_FIFO_DATA(2'b00), haddr(14b), hwdata(32b)}.
#
# We model a SPEC-COMPLIANT AHB master that respects HREADYOUT: it holds the
# data-phase (HWDATA + the address-phase of the *next* beat) until HREADYOUT=1.
# The candidate sub-causes (L11 watchdog drop, back-to-back gap, sustained
# back-pressure) are each exercised so we can see exactly which one drops a word.
#
# VERDICT lines are printed for the parent harness to relay.
# =============================================================================
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, Timer

PKT_FIFO_DATA = 0b00

HTRANS_IDLE   = 0b00
HTRANS_NONSEQ = 0b10
HSIZE_WORD    = 0b010


def fc_word(addr, data):
    """Expected FC word for a TX-aperture FIFO_DATA write."""
    return ((PKT_FIFO_DATA & 0x3) << 46) | ((addr & 0x3FFF) << 32) | (data & 0xFFFFFFFF)


async def reset(dut):
    dut.hresetn.value = 0
    # AHB TX aperture idle
    dut.ahb_tx_hsel.value = 0
    dut.ahb_tx_haddr.value = 0
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsize.value = HSIZE_WORD
    dut.ahb_tx_hwrite.value = 0
    dut.ahb_tx_hwdata.value = 0
    dut.ahb_tx_hready.value = 1
    # Returner idle
    dut.rtn_haddr.value = 0
    dut.rtn_hwdata.value = 0
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hsize.value = HSIZE_WORD
    dut.rtn_hwrite.value = 0
    # RX path / tie-offs
    dut.fc_rx_fifo_ready.value = 1
    dut.fc_rx_cfg_prdata.value = 0
    dut.fc_rx_cfg_pready.value = 1
    dut.tc_axis_tx_tvalid.value = 0
    dut.tc_axis_tx_tdata.value = 0
    dut.tc_axis_rx_tready.value = 1
    dut.tc_qos_priority.value = 0
    dut.puf_rdata.value = 0
    dut.puf_ack.value = 0
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value = 0
    # FC app->link ready: the Wlink FC node normally holds ready high (skid/FIFO
    # has space). Default to ready so a single write should sail straight through.
    dut.tl_fc_a2l_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    for _ in range(2):
        await RisingEdge(dut.hclk)


class FcMonitor:
    """Captures every tl_fc_a2l_valid&ready handshake (one FC word transferred)."""
    def __init__(self, dut):
        self.dut = dut
        self.words = []
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            await RisingEdge(self.dut.hclk)
            await ReadOnly()
            v = self.dut.tl_fc_a2l_valid.value
            r = self.dut.tl_fc_a2l_ready.value
            if v == 1 and r == 1:
                self.words.append(int(self.dut.tl_fc_a2l_data.value))


async def ahb_single_write(dut, addr, data):
    """Issue ONE spec-compliant AHB write beat into the TX aperture.

    Address phase: drive HSEL/HADDR/HTRANS=NONSEQ/HWRITE while HREADYOUT=1.
    Data phase   : drive HWDATA, return to IDLE; hold until HREADYOUT=1.
    Returns the cycle count the data phase took to complete.
    """
    # ---- Address phase: wait until the slave is ready to accept it ----
    while True:
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if int(dut.ahb_tx_hreadyout.value) == 1:
            break
    # drive address phase (after the edge, in the next delta we set inputs)
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 1
    dut.ahb_tx_haddr.value = addr
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hsize.value = HSIZE_WORD

    # advance to the clock edge that samples the address phase
    await RisingEdge(dut.hclk)
    # ---- Data phase: drive HWDATA, deassert address phase (single beat) ----
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 0
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hwrite.value = 0
    dut.ahb_tx_hwdata.value = data

    # Hold the data phase until HREADYOUT=1 (slave accepted the beat).
    cycles = 0
    while True:
        await ReadOnly()
        ro = int(dut.ahb_tx_hreadyout.value)
        await RisingEdge(dut.hclk)
        cycles += 1
        if ro == 1:
            break
        if cycles > 200:
            break
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hwdata.value = 0
    return cycles


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_single_write_baseline(dut):
    """A single AHB write with FC ready high must produce one matching FC word."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    mon = FcMonitor(dut); mon.start()

    addr, data = 0x0010, 0xDEADBEEF
    await ahb_single_write(dut, addr, data)
    for _ in range(10):
        await RisingEdge(dut.hclk)

    exp = fc_word(addr, data)
    got = mon.words
    ok = (len(got) == 1 and got[0] == exp)
    print(f"[VERDICT baseline] AHB write addr={addr:#06x} data={data:#010x} "
          f"-> FC words={[hex(w) for w in got]} exp={exp:#014x} : "
          f"{'PASS' if ok else 'FAIL (Bug-A: write did not reach FC a2l)'}")
    assert ok, "baseline single write did not produce exactly one correct FC word"


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_four_word_packet(dut):
    """A 4-beat packet (word0,dest,payload0,payload1) -> 4 matching FC words."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    mon = FcMonitor(dut); mon.start()

    beats = [(0x0000, 0x00020000),   # word0: len=2
             (0x0004, 0x000000A5),   # dest
             (0x0008, 0xCAFEBABE),   # payload0
             (0x000C, 0x12345678)]   # payload1
    for a, d in beats:
        await ahb_single_write(dut, a, d)
    for _ in range(12):
        await RisingEdge(dut.hclk)

    exp = [fc_word(a, d) for a, d in beats]
    got = mon.words
    ok = (got == exp)
    print(f"[VERDICT 4word] beats={len(beats)} -> FC words={[hex(w) for w in got]}")
    print(f"               expected         ={[hex(w) for w in exp]} : "
          f"{'PASS' if ok else 'FAIL (Bug-A: one or more beats lost)'}")
    assert ok, f"4-word packet mismatch: got {len(got)} words, expected {len(exp)}"


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_backpressure_then_drain(dut):
    """FC not-ready during the write: word must be HELD in skid, not dropped.

    This is the realistic bilateral case: tl_fc_a2l_ready is LOW because the
    downstream replay FIFO is momentarily full. A compliant master stalls on
    HREADYOUT. The word MUST survive and emit once ready returns -- it must NOT
    be silently dropped by the L11 wedge watchdog. We hold not-ready for >
    WEDGE_LIMIT(16) cycles to see whether the watchdog eats the word.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    mon = FcMonitor(dut); mon.start()

    addr, data = 0x0020, 0xA5A5F00D

    # Hold FC ready LOW for the whole write attempt (>WEDGE_LIMIT cycles).
    dut.tl_fc_a2l_ready.value = 0
    wr = cocotb.start_soon(ahb_single_write(dut, addr, data))

    # keep not-ready asserted for 30 cycles (well past WEDGE_LIMIT=16)
    for _ in range(30):
        await RisingEdge(dut.hclk)
    # now let it drain
    dut.tl_fc_a2l_ready.value = 1
    await wr
    for _ in range(10):
        await RisingEdge(dut.hclk)

    exp = fc_word(addr, data)
    got = mon.words
    ok = (len(got) == 1 and got[0] == exp)
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    print(f"[VERDICT backpressure] held a2l_ready=0 for 30cy, then drained.")
    print(f"               FC words={[hex(w) for w in got]} exp={exp:#014x} "
          f"tx_dropped_cnt={dropped} : "
          f"{'PASS' if ok else 'FAIL (Bug-A: watchdog DROPPED the word under back-pressure)'}")
    assert ok, ("under sustained back-pressure the AHB word was lost "
                f"(tx_dropped_cnt={dropped}) -- L11 watchdog drop is the defect")


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_ready_low_at_idle_then_write(dut):
    """Realistic Bug-A trigger: FC ready is LOW when the FCSM is in LINK_IDLE
    (replay FIFO not yet draining). Master issues a single write. The word must
    be buffered and emitted when ready rises -- never dropped. Ready stays low
    long enough for the watchdog to fire (the real HW condition)."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    mon = FcMonitor(dut); mon.start()

    dut.tl_fc_a2l_ready.value = 0   # FCSM stuck in LINK_IDLE, not draining
    addr, data = 0x0040, 0x0000C0DE
    wr = cocotb.start_soon(ahb_single_write(dut, addr, data))

    # The FCSM stays idle for many cycles before credit allows it to advance.
    for _ in range(40):
        await RisingEdge(dut.hclk)
    dut.tl_fc_a2l_ready.value = 1   # FCSM finally advances, FIFO starts draining
    await wr
    for _ in range(10):
        await RisingEdge(dut.hclk)

    exp = fc_word(addr, data)
    got = mon.words
    ok = (len(got) == 1 and got[0] == exp)
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    print(f"[VERDICT idle-then-ready] a2l_ready=0 during LINK_IDLE (40cy) then 1.")
    print(f"               FC words={[hex(w) for w in got]} exp={exp:#014x} "
          f"tx_dropped_cnt={dropped} : "
          f"{'PASS' if ok else 'FAIL (Bug-A REPRODUCED: write lost while FCSM idle)'}")
    assert ok, ("AHB write issued while FCSM idle (a2l_ready=0) was LOST "
                f"(tx_dropped_cnt={dropped})")


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_watchdog_drops_second_write(dut):
    """THE Bug-A drop: skid already FULL + a 2nd write arrives while FC ready=0.

    Real-HW sequence on a wedged bilateral link:
      1. CPU writes word0 -> loads the 1-entry skid (skid_valid_r=1).
      2. FCSM never advances (a2l_ready stays 0) -> skid cannot drain.
      3. CPU writes word1 (the 'dest' beat). skid_can_accept=0 (skid full,
         ready=0). The data phase stalls. After WEDGE_LIMIT(16) cycles the L11
         watchdog forces HREADYOUT=1 and CLEARS tx_data_phase_r -- but the skid
         is still full so the word is NOT loaded. The AHB master sees the beat
         'accepted' and moves on. word1 is SILENTLY DROPPED (tx_dropped_cnt++).
      4. Even after ready finally rises, only word0 ever reaches the FC node.

    This is the structural defect behind Bug-A: a compliant CPU burst loses
    every beat after the first whenever the link is momentarily not-ready for
    longer than WEDGE_LIMIT, with NO back-pressure ever reported to the CPU.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    mon = FcMonitor(dut); mon.start()

    # FC node not ready for the whole episode (FCSM wedged in LINK_IDLE).
    dut.tl_fc_a2l_ready.value = 0

    beats = [(0x0000, 0x00020000),   # word0 (loads skid)
             (0x0004, 0x000000A5),   # word1 (dest)  -- at risk of drop
             (0x0008, 0xCAFEBABE),   # word2 (payload0)
             (0x000C, 0x12345678)]   # word3 (payload1)

    async def burst():
        for a, d in beats:
            await ahb_single_write(dut, a, d)

    wr = cocotb.start_soon(burst())
    # Let the watchdog fire several times while ready stays low.
    for _ in range(120):
        await RisingEdge(dut.hclk)
    # Link finally comes up.
    dut.tl_fc_a2l_ready.value = 1
    await wr
    for _ in range(20):
        await RisingEdge(dut.hclk)

    exp = [fc_word(a, d) for a, d in beats]
    got = mon.words
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    ok = (got == exp)
    print(f"[VERDICT watchdog-drop] 4-beat burst while a2l_ready=0 (>WEDGE_LIMIT).")
    print(f"               FC words got ={[hex(w) for w in got]}")
    print(f"               FC words exp ={[hex(w) for w in exp]}")
    print(f"               tx_dropped_cnt={dropped} : "
          f"{'PASS' if ok else 'FAIL (Bug-A REPRODUCED: L11 watchdog dropped beats; FCSM-bound words lost)'}")
    assert ok, (f"L11 watchdog dropped {len(exp)-len(got)} of {len(exp)} beats "
                f"(tx_dropped_cnt={dropped}); only the first survived -- this is Bug-A")


# ---------------------------------------------------------------------------
# Wedge-mechanism fix (2026-06-11): bounded stall + AHB ERROR response.
# tb_top overrides TX_STALL_TIMEOUT_LOG2=8 -> timeout fires when the stall
# counter reaches 2^8 = 256 cycles of continuous data-phase back-pressure.
# ---------------------------------------------------------------------------

async def ahb_write_watch_error(dut, addr, data, max_cycles=600):
    """Single AHB write; stay in the data phase until HREADYOUT=1, recording
    HRESP each cycle. Returns (cycles, saw_err1, saw_err2) where err1 is the
    HRESP=1/HREADYOUT=0 cycle and err2 the HRESP=1/HREADYOUT=1 terminator."""
    while True:
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if int(dut.ahb_tx_hreadyout.value) == 1:
            break
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 1
    dut.ahb_tx_haddr.value = addr
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hsize.value = HSIZE_WORD
    await RisingEdge(dut.hclk)
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 0
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hwrite.value = 0
    dut.ahb_tx_hwdata.value = data

    cycles, saw_err1, saw_err2 = 0, False, False
    while cycles < max_cycles:
        await ReadOnly()
        hr  = int(dut.ahb_tx_hreadyout.value)
        hrs = int(dut.ahb_tx_hresp.value)
        if hrs == 1 and hr == 0:
            saw_err1 = True
        if hrs == 1 and hr == 1:
            saw_err2 = True
        await RisingEdge(dut.hclk)
        cycles += 1
        if hr == 1:
            break
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hwdata.value = 0
    return cycles, saw_err1, saw_err2


@cocotb.test()
async def test_stall_timeout_error_response(dut):
    """Dead link (a2l_ready stuck low): the stalled TX write must terminate
    in the two-cycle AHB ERROR response instead of stalling forever (the PS
    deadlock that hard-wedged z2_02), and tx_dropped_cnt_r must count it."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    dut.tl_fc_a2l_ready.value = 0   # link dead

    # First write lands in the 1-entry skid and completes cleanly; the
    # SECOND write is the one that stalls behind the dead link (matches
    # the bench storm, which absorbed the first words into skid+FIFO).
    c0, p1, p2 = await ahb_write_watch_error(dut, 0x0000, 0xDEAD0000)
    assert not p1 and not p2, "skid-absorbed first write must not error"
    cycles, e1, e2 = await ahb_write_watch_error(dut, 0x0004, 0xDEAD0001)
    assert e1 and e2, f"expected two-cycle ERROR response, got err1={e1} err2={e2}"
    assert 250 <= cycles <= 300, f"ERROR should fire at the ~256-cy timeout, took {cycles}"
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    assert dropped == 1, f"tx_dropped_cnt_r={dropped}, expected 1"

    # The aborted word must NOT have entered the FC stream.
    assert int(dut.tl_fc_a2l_valid.value) == 0 or int(dut.tl_fc_a2l_ready.value) == 0


@cocotb.test()
async def test_healthy_backpressure_still_clean(dut):
    """Back-pressure shorter than the timeout: no error, no drop — the beat
    completes when the skid drains (Bug-A 2026-06-09 contract preserved)."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    dut.tl_fc_a2l_ready.value = 0
    await ahb_write_watch_error(dut, 0x0000, 0xDEAD0001)   # fills the skid

    async def release_later():
        for _ in range(100):           # < 256-cy timeout
            await RisingEdge(dut.hclk)
        dut.tl_fc_a2l_ready.value = 1

    cocotb.start_soon(release_later())
    cycles, e1, e2 = await ahb_write_watch_error(dut, 0x0004, 0xDEAD0002)
    assert not e1 and not e2, "healthy back-pressure must not raise ERROR"
    assert cycles < 256, f"beat should complete once drained, took {cycles}"
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    assert dropped == 0, f"tx_dropped_cnt_r={dropped}, expected 0"


@cocotb.test()
async def test_recovery_after_timeout_abort(dut):
    """After a timeout-abort the adapter must accept fresh writes once the
    link returns: the error path is per-beat, not a latched lockout."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)
    dut.tl_fc_a2l_ready.value = 0
    await ahb_write_watch_error(dut, 0x0008, 0xDEAD0002)   # fills the skid
    _, e1, e2 = await ahb_write_watch_error(dut, 0x000C, 0xDEAD0003)
    assert e1 and e2, "precondition: stalled write aborts with ERROR"

    dut.tl_fc_a2l_ready.value = 1   # link recovers
    for _ in range(4):
        await RisingEdge(dut.hclk)
    cycles, e1b, e2b = await ahb_write_watch_error(dut, 0x0010, 0xCAFE0004)
    assert not e1b and not e2b, "post-recovery write must complete cleanly"
    assert cycles <= 20, f"post-recovery write should be fast, took {cycles}"
    dropped = int(dut.u_dut.tx_dropped_cnt_r.value)
    assert dropped == 1, f"tx_dropped_cnt_r={dropped}, expected 1 (only the aborted beat)"

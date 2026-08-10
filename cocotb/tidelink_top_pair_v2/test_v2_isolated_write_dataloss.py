"""V2 XHB500 transparent-window — ISOLATED write data-loss gate.

Reproduces / guards the NanoSoC Compute-Chiplet handover
(`TIDELINK_ISOLATED_WRITE_DATA_LOSS.md`): a D2D peer-aperture write that is
NOT immediately followed by another AHB transfer was reported to cross the link
with its ADDRESS correct but its write DATA delivered as 0x0000_0000 — the
cross-die mailbox doorbell (an isolated MSG_VALID=1 store) and any isolated D2D
payload lost. The report's masking artefact: every prior D2D write proof used a
back-to-back pair carrying IDENTICAL data, so a data-phase shift was invisible.

That report pinned tidelink @ 3f3de09 (v2026.07.16-chiplet-verified), a line
that does NOT contain `cb33c9f` ("xhb: fix ahb_sub hready comb loop — silicon
window write-vanish root cause"). This suite runs on the CURRENT tree (which
DOES contain cb33c9f + the I2 read-pipe mask + I5 backstops) and asserts the
isolated write now delivers its data.

WHAT THIS ADDS OVER test_v2_xhb_window
--------------------------------------
* An HREADY-AWARE far-`ahb_mng` monitor (`MngWriteMonitor`) that samples the
  s_mng_* port in each DATA phase (the report's own sender monitor was
  inconclusive because it ignored wait-states — this one does not). It is
  cross-checked against the far BRAM terminus (`u_s_mng_bram`) every test so the
  instrument itself is verified, not trusted.
* DISTINCT data on both writes of a back-to-back pair (the report's masking
  case) — so a one-cycle data-phase shift, if present, would be caught.
* A deliberately NON-COMPLIANT "prompt-drop" master that withdraws HWDATA the
  cycle after it believes the data phase ended (drops to 0), rather than holding
  it across the cross-link wait — the exact stimulus the report's mechanism
  predicts loses data. This probes the actual failure surface directly.

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh
    export TIDELINK_PHY_V2=1
    make MODULE=test_v2_isolated_write_dataloss
"""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from test_v2_xhb_window import AHBSubMaster, _slave_bram_peek, APERTURE_BASE

WRITE_SETTLE = 8000          # cycles for a posted window write to land at the far BRAM
DOORBELL_VAL = 0x0000_0001   # report write #4: MSG_VALID doorbell (distinct, small)
MSG_VAL      = 0xD2D0_DB01   # report write #3: mbox msg payload (distinct)


def _int_or_none(sig):
    try:
        return int(sig.value)
    except ValueError:
        return None


class MngWriteMonitor:
    """HREADY-aware monitor on the FAR die's ahb_mng (s_mng_*) port.

    Mirrors the far BRAM terminus's own capture rule (tb_ahb_bram_slave: commit
    HWDATA in the data phase of the transfer whose address phase was accepted
    with HREADY high) but exposes every (addr, data) write it observes so the
    test can assert on the delivered DATA directly at the ahb_mng boundary —
    the report's definitive tap. Sampled at FallingEdge so bus values are read
    mid-cycle when stable (no post-edge delta ambiguity)."""

    def __init__(self, dut):
        self.dut     = dut
        self.clk     = dut.hclk
        self.htrans  = dut.s_mng_htrans
        self.hwrite  = dut.s_mng_hwrite
        self.haddr   = dut.s_mng_haddr
        self.hwdata  = dut.s_mng_hwdata
        self.hready  = dut.s_mng_hready
        self.enabled = False
        self.writes  = []          # list of (addr, data) captured in data phase
        cocotb.start_soon(self._run())

    async def _run(self):
        prev_active = prev_wr = 0
        prev_addr = 0
        while True:
            await FallingEdge(self.clk)
            hready = _int_or_none(self.hready)
            if hready is None:
                prev_active = prev_wr = 0
                continue
            # DATA phase (this cycle) of the address accepted last cycle.
            if hready and prev_active and prev_wr and self.enabled:
                data = _int_or_none(self.hwdata)
                self.writes.append((prev_addr, data))
            # ADDRESS phase capture advances only when HREADY is high.
            if hready:
                tr = _int_or_none(self.htrans)
                prev_active = 0 if tr is None else (tr >> 1) & 1
                prev_wr     = _int_or_none(self.hwrite) or 0
                prev_addr   = _int_or_none(self.haddr) or 0

    def arm(self):
        self.writes = []
        self.enabled = True

    def data_for(self, addr):
        """Most recent captured data delivered to `addr` (masked to 32b), or
        None if this monitor observed no write to that address."""
        hits = [d for a, d in self.writes if a == (addr & 0xFFFF_FFFF)]
        return hits[-1] if hits else None


class PromptDropSubMaster(AHBSubMaster):
    """Isolated-write master that WITHDRAWS HWDATA early (non-compliant).

    AHBSubMaster holds HWDATA valid from the address phase all the way to the
    cross-link completion. A real isolated store on a bus that goes IDLE right
    after does not: it presents the single NONSEQ address, drives HWDATA for the
    cycle(s) it believes are the data phase, then releases the bus (HWDATA->0).
    This master models exactly that: after `data_hold` cycles of driving HWDATA
    it forces the bus to 0, then waits out the true cross-link completion. If the
    outbound path samples HWDATA one cycle late (the report's mechanism), it
    captures the 0 and the far BRAM sees 0."""

    async def write_promptdrop(self, addr, data, data_hold=1, timeout=60000):
        # ---- address phase: NONSEQ for one cycle (pipeline latches it) --------
        await RisingEdge(self.clk)
        self.hsel.value   = 1
        self.haddr.value  = addr & 0xFFFF_FFFF
        self.htrans.value = 2     # NONSEQ
        self.hsize.value  = 2
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hwrite.value = 1
        self.hready.value = 1
        self.hwdata.value = data & 0xFFFF_FFFF
        await RisingEdge(self.clk)
        # release address-phase controls; drive HWDATA for `data_hold` cycles
        self.hsel.value   = 0
        self.htrans.value = 0
        self.hwrite.value = 0
        self.hburst.value = 0
        for _ in range(data_hold):
            await RisingEdge(self.clk)
        # WITHDRAW the write data (bus goes to 0), as an idle bus would.
        self.hwdata.value = 0
        # ---- wait for true completion: skip the accept pulse (low first) ------
        seen_low = False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            r = _int_or_none(self.hreadyout)
            if r == 0:
                seen_low = True
            elif seen_low and r == 1:
                break
        self.idle()


async def _bringup(dut):
    tb = PairV2TB(dut)
    m = AHBSubMaster(dut)            # idle ahb_sub before bring-up
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    return tb, m


def _check_instrument(tb, mon, off, expect):
    """Cross-check the HREADY-aware monitor against the BRAM ground truth."""
    peek = _slave_bram_peek(tb.dut, off)
    mon_d = mon.data_for(APERTURE_BASE + off)
    tb.log.info(
        f"  [iso] +0x{off:03x}: expect=0x{expect:08x} | far ahb_mng monitor="
        f"{'None' if mon_d is None else f'0x{mon_d:08x}'} | "
        f"BRAM={'None' if peek is None else f'0x{peek:08x}'}")
    return peek, mon_d


# ─────────────────────────────────────────────────────────────────────────────
# (1) ISOLATED write with DISTINCT data — the report's core claim
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_isolated_distinct_write_delivers(dut):
    """A single isolated D2D write (address, one data beat, then bus IDLE) must
    cross with its DATA intact — no trailing transfer required. Covers both the
    mailbox payload (0xD2D0DB01) and the doorbell (MSG_VALID=1)."""
    tb, m = await _bringup(dut)
    mon = MngWriteMonitor(dut)

    vectors = [(0x020, MSG_VAL), (0x040, DOORBELL_VAL)]
    fails = []
    for off, data in vectors:
        mon.arm()
        await m.write(APERTURE_BASE + off, data)     # compliant, but ISOLATED
        await ClockCycles(dut.hclk, WRITE_SETTLE)
        peek, mon_d = _check_instrument(tb, mon, off, data)
        # Instrument self-check: monitor MUST agree with BRAM ground truth.
        assert mon_d == peek, (
            f"far monitor ({mon_d}) disagrees with BRAM ({peek}) @+0x{off:03x} "
            f"— the instrument is unreliable, fix it before trusting a result")
        if peek != data or mon_d != data:
            fails.append((off, data, peek, mon_d))

    assert not fails, (
        "ISOLATED write LOST its data (address ok, data wrong) — the reported "
        "defect reproduces on this tree:\n" + "\n".join(
            f"  +0x{o:03x}: wrote 0x{d:08x}  BRAM={_f(p)}  monitor={_f(mn)}"
            for o, d, p, mn in fails))
    tb.log.info("  [iso] PASS: isolated writes (incl. doorbell) deliver data "
                "with NO following transfer")


# ─────────────────────────────────────────────────────────────────────────────
# (2) BACK-TO-BACK pair with DISTINCT data — the report's masking case
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_back_to_back_distinct_writes(dut):
    """Two back-to-back window writes carrying DISTINCT data must BOTH land at
    their own address with their own data. If the outbound path shifted data by
    one transfer, the first would carry the second's word (or 0) — invisible
    only when the two words are identical, which every prior proof used."""
    tb, m = await _bringup(dut)
    mon = MngWriteMonitor(dut)
    mon.arm()

    a_off, a_data = 0x100, 0xD2D0_BEEF
    b_off, b_data = 0x104, 0xFEED_FACE
    # Issue the two writes with no long idle between them.
    await m.write(APERTURE_BASE + a_off, a_data)
    await m.write(APERTURE_BASE + b_off, b_data)
    await ClockCycles(dut.hclk, WRITE_SETTLE)

    pa, ma = _check_instrument(tb, mon, a_off, a_data)
    pb, mb = _check_instrument(tb, mon, b_off, b_data)
    assert ma == pa and mb == pb, "far monitor disagrees with BRAM — instrument bad"
    fails = []
    if pa != a_data:
        fails.append((a_off, a_data, pa))
    if pb != b_data:
        fails.append((b_off, b_data, pb))
    assert not fails, (
        "BACK-TO-BACK distinct-data writes did not each deliver their own word "
        "(data-phase shift):\n" + "\n".join(
            f"  +0x{o:03x}: wrote 0x{d:08x} got {_f(g)}" for o, d, g in fails))
    tb.log.info("  [b2b] PASS: both distinct-data words landed at their own "
                "addresses — no one-transfer data shift")


# ─────────────────────────────────────────────────────────────────────────────
# (3) PROMPT-DROP isolated write — non-compliant master, direct failure probe
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_isolated_promptdrop_write(dut):
    """Drive an isolated write whose master WITHDRAWS HWDATA the cycle after its
    believed data phase (bus -> 0), instead of holding it across the cross-link
    wait. This is the report's mechanism made explicit: if the outbound path
    latches HWDATA one cycle late it captures the withdrawn 0. On a timing-
    correct outbound path (address pipe-fill stall re-aligns the master's data
    phase with XHB500's) the beat is captured while still driven, so it lands."""
    tb, _ = await _bringup(dut)
    pm = PromptDropSubMaster(dut)
    mon = MngWriteMonitor(dut)

    # data_hold=1 : HWDATA driven for exactly one cycle after address release,
    # then forced to 0 — the tightest isolated-store timing.
    for off, data, hold in [(0x200, 0xD2D00001, 1), (0x208, 0xD2D00002, 2)]:
        mon.arm()
        await pm.write_promptdrop(APERTURE_BASE + off, data, data_hold=hold)
        await ClockCycles(dut.hclk, WRITE_SETTLE)
        peek, mon_d = _check_instrument(tb, mon, off, data)
        assert mon_d == peek, "far monitor disagrees with BRAM — instrument bad"
        # This is a PROBE: report the outcome plainly. A timing-correct path
        # lands `data`; a one-cycle-late capture lands 0 (or the poison).
        if peek == data:
            tb.log.info(f"  [drop] +0x{off:03x} hold={hold}: LANDED 0x{peek:08x} "
                        f"— outbound path captured the beat while driven")
        else:
            tb.log.warning(f"  [drop] +0x{off:03x} hold={hold}: data NOT intact "
                           f"(got {_f(peek)}) — non-compliant early HWDATA "
                           f"withdrawal is NOT tolerated at this hold depth")
    # The gate assertion is on the COMPLIANT isolated write (test 1); this probe
    # documents the tolerance margin and must at least not error out.


def _f(v):
    return "None" if v is None else f"0x{v:08x}"


# ─────────────────────────────────────────────────────────────────────────────
# (4) HREADY-LOOPBACK isolated write — the report's SoC/FPGA-wrapper condition
# ─────────────────────────────────────────────────────────────────────────────
async def _hready_loopback(dut):
    """Model the FPGA wrapper / AHB-fabric feedback the report's harness has:
    ahb_sub_hready is driven from ahb_sub_hreadyout (the wrapper does this
    combinationally: tidelink_vivado_wrapper.v `assign ahb_sub_hready =
    sub_hreadyout_int`). Sampled at FallingEdge (mid-cycle, hreadyout settled)
    and driven for the next posedge — a half-cycle-registered stand-in for the
    comb net (a true zero-delay comb loop is not expressible from cocotb and
    hangs VCS; this reproduces the same address-phase gating deterministically).

    On the pre-cb33c9f RTL `ext_addr_phase = hsel & htrans[1] & ahb_sub_hready`,
    so the fill-stall cycle (hreadyout=0 -> looped hready=0) makes ext_addr_phase
    drop, the address pipe never latches, and the isolated write VANISHES. The
    post-cb33c9f RTL drops the `& ahb_sub_hready` term, so the pipe latches and
    the write crosses regardless of the loopback."""
    while True:
        await FallingEdge(dut.hclk)
        try:
            dut.m_ahb_sub_hready.value = int(dut.m_ahb_sub_hreadyout.value)
        except ValueError:
            dut.m_ahb_sub_hready.value = 1


@cocotb.test()
async def test_isolated_write_hready_loopback(dut):
    """Compliant isolated write while ahb_sub_hready is looped back from
    ahb_sub_hreadyout (the report's SoC/FPGA-wrapper condition). Must deliver
    its data. This is the test that DISCRIMINATES the cb33c9f fix: it stays
    GREEN on the current tree and goes RED (data vanishes) on the pre-cb33c9f
    RTL."""
    tb, m = await _bringup(dut)
    cocotb.start_soon(_hready_loopback(dut))
    await ClockCycles(dut.hclk, 50)          # let the loopback take over hready
    mon = MngWriteMonitor(dut)

    off, data = 0x300, 0xD2D0_10AB
    mon.arm()
    await m.write(APERTURE_BASE + off, data)
    await ClockCycles(dut.hclk, WRITE_SETTLE)
    peek, mon_d = _check_instrument(tb, mon, off, data)
    assert mon_d == peek, "far monitor disagrees with BRAM — instrument bad"
    assert peek == data, (
        f"isolated write under hready-loopback LOST its data (got {_f(peek)}) "
        f"— the reported defect. On the current tree cb33c9f prevents this; if "
        f"you are seeing RED here, the ext_addr_phase hready-gating is back.")
    tb.log.info("  [loopback] PASS: isolated write delivered under the "
                "hready<->hreadyout loopback (cb33c9f invariant holds)")

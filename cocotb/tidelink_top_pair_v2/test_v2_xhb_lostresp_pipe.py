"""V2 XHB500 window — I2 (peer-READ pipe offset) + I5 (lost-response backstop).

Proves two silicon-feedback fixes upstreamed into src/rtl/tidelink_top.sv.

I2 — rd_pipe_r peer-READ completion guard
-----------------------------------------
The ahb_sub address pipeline presents the address to the XHB500 bridge one cycle
late, so on the master's FIRST data-phase cycle the bridge is still in its
RESP_FSM_IDLE_BUSY state where hreadyout=1 ("ready to accept an address"). A real
AHB master reads that as its READ completing and captures STALE hrdata one cycle
before the AXI read is even issued. The idealized AHBSubMaster in
test_v2_xhb_window DODGES this by waiting for hreadyout to go LOW first; a real
master does not. Here a STRICT master (captures on the FIRST hreadyout-high in the
data phase) reads back the value it wrote — byte-exact WITH the fix, and 0x0
(the bridge's idle hrdata, captured at the accept pulse) WITHOUT it. We also probe
u_master.rd_pipe_r to show the guard masks exactly the accept-pulse cycle.

I5 — outstanding-response backstop (HREADYOUT-blind)
----------------------------------------------------
The pre-existing per-beat stall timer only accumulates while hreadyout is LOW. A
lost peer R/B beat (AR/AW accepted onto the s_axi channel, but the returning
R(last)/B never comes back) is timed out by the NEW backstop that tracks the
transaction outstanding on the s_axi handshakes directly, regardless of hreadyout.

To prove it is the NEW backstop firing (and not the old per-beat timer) the two
timeouts are SPLIT at compile time:
    TIDELINK_SUB_STALL_TIMEOUT_LOG2=20        per-beat timer ~1e6 cyc  (parked)
    TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10  outstanding timer 1024 cyc
so an ERROR arriving in ~1024 cyc can ONLY be the outstanding backstop — the
per-beat timer could not have fired for another ~1e6 cycles. Internal probes
confirm: sub_rd_os_r set, sub_osr_ctr_r reached its top bit, sub_stall_ctr_r stayed
far below its own (2^20) limit.

Run (both tests, one build):
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh ; export PATH=$VCS_HOME/bin:$PATH TIDELINK_PHY_V2=1
    make MODULE=test_v2_xhb_lostresp_pipe SIM_BUILD=sim_build_lostresp \
      EXTRA_DEFINES="+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=20 \
                     +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10"
"""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from test_v2_xhb_window import AHBSubMaster, _slave_bram_peek

APERTURE_BASE = 0x4000_0000
WRITE_SETTLE  = 8000


def _ctr_log2(sig):
    """The as-BUILT LOG2 of a [LOG2:0] backstop counter, read straight off the
    compiled RTL signal width — so the test tracks whatever the +define set,
    with no dependence on a matching os.environ export."""
    return len(sig) - 1


def _int_or_none(sig):
    try:
        return int(sig.value)
    except ValueError:
        return None


class StrictAHBSubMaster:
    """AHB-Lite master that captures HRDATA on the FIRST hreadyout-high in the
    data phase — i.e. WITHOUT the "wait for hreadyout LOW first" workaround the
    idealized AHBSubMaster uses to dodge the bridge's IDLE-state accept pulse.
    This is what a real AHB master does; it is what exposes the I2 pipe offset."""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.hclk
        self.hsel      = dut.m_ahb_sub_hsel
        self.haddr     = dut.m_ahb_sub_haddr
        self.hburst    = dut.m_ahb_sub_hburst
        self.hprot     = dut.m_ahb_sub_hprot
        self.hsize     = dut.m_ahb_sub_hsize
        self.htrans    = dut.m_ahb_sub_htrans
        self.hwdata    = dut.m_ahb_sub_hwdata
        self.hwrite    = dut.m_ahb_sub_hwrite
        self.hready    = dut.m_ahb_sub_hready
        self.hrdata    = dut.m_ahb_sub_hrdata
        self.hresp     = dut.m_ahb_sub_hresp
        self.hreadyout = dut.m_ahb_sub_hreadyout
        self.idle()

    def idle(self):
        self.hsel.value   = 0
        self.haddr.value  = 0
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hsize.value  = 2
        self.htrans.value = 0
        self.hwdata.value = 0
        self.hwrite.value = 0
        self.hready.value = 1

    async def strict_read(self, addr, timeout=20000, probe=None):
        """One READ whose data-phase capture is at the FIRST hreadyout-high after
        the address phase (no skip-low). Returns (rdata, resp, accept_pulse) where
        accept_pulse is hreadyout sampled the cycle after the address phase (the
        cycle rd_pipe_r must mask). `probe`, if given, is a 0-arg callable sampled
        at that same accept-pulse cycle (used to read u_master.rd_pipe_r)."""
        await RisingEdge(self.clk)                 # C0: address phase
        self.hsel.value   = 1
        self.haddr.value  = addr & 0xFFFF_FFFF
        self.htrans.value = 2                      # NONSEQ
        self.hsize.value  = 2
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hwrite.value = 0
        self.hready.value = 1
        await RisingEdge(self.clk)                 # C1: pipe accept-pulse cycle
        self.hsel.value   = 0
        self.htrans.value = 0
        first = True
        accept_pulse = None
        probe_val = None
        for _ in range(timeout):
            await FallingEdge(self.clk)
            h = _int_or_none(self.hreadyout)
            if first:
                accept_pulse = h                   # what an un-guarded master sees
                if probe is not None:
                    probe_val = probe()
                first = False
            if h == 1:
                rdata = _int_or_none(self.hrdata)
                resp  = _int_or_none(self.hresp)
                await RisingEdge(self.clk)
                self.idle()
                return rdata, resp, accept_pulse, probe_val
            await RisingEdge(self.clk)
        self.idle()
        raise TimeoutError(f"strict_read 0x{addr:08x} never completed")


# ─────────────────────────────────────────────────────────────────────────────
# I2 — strict-master peer READ returns the written word (rd_pipe_r guard)
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_i2_strict_read_pipe_offset(dut):
    """A strict AHB master (captures on the first hreadyout-high) reads back the
    written word byte-exact — proving the rd_pipe_r guard masks the bridge's
    IDLE-state accept pulse. Without the guard the master captures 0x0 there."""
    tb = PairV2TB(dut)
    ideal  = AHBSubMaster(dut)          # idles ahb_sub before bring-up
    strict = StrictAHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    vectors = [(0x040, 0xC0FFEE01), (0x104, 0x5A5A_1234), (0x208, 0xDEADBEEF)]
    fails = []
    for off, data in vectors:
        addr = APERTURE_BASE + off
        await ideal.write(addr, data)
        await ClockCycles(dut.hclk, WRITE_SETTLE)

        rdata, resp, accept_pulse, rd_pipe = await strict.strict_read(
            addr, probe=lambda: _int_or_none(dut.u_master.rd_pipe_r))
        peek = _slave_bram_peek(dut, off)
        tb.log.info(
            f"  [i2] +0x{off:03x} wrote=0x{data:08x} strict-read="
            f"{'X' if rdata is None else f'0x{rdata:08x}'} resp={resp} "
            f"accept-pulse-hreadyout={accept_pulse} rd_pipe_r@pulse={rd_pipe} "
            f"BRAM={'n/a' if peek is None else f'0x{peek:08x}'}")
        # The guard must have masked the accept pulse cycle (hreadyout held 0 there,
        # rd_pipe_r=1), and the strict read must return the written value, not 0x0.
        if rdata != data or resp:
            fails.append((off, data, rdata, resp))
        assert accept_pulse == 0, (
            f"+0x{off:03x}: the accept-pulse cycle showed hreadyout={accept_pulse} "
            f"— rd_pipe_r did NOT mask it (I2 regression: a strict master would "
            f"capture stale hrdata here)")
        assert rd_pipe == 1, (
            f"+0x{off:03x}: rd_pipe_r was {rd_pipe} at the accept-pulse cycle "
            f"(expected 1 — the guard must be asserted exactly there)")

    assert not fails, (
        "I2 strict-master peer read MISMATCH (rd_pipe_r guard broken):\n" +
        "\n".join(f"  +0x{o:03x} wrote=0x{d:08x} read="
                  f"{'X' if g is None else f'0x{g:08x}'} resp={r}"
                  for o, d, g, r in fails))
    tb.log.info(f"  [i2] PASS: {len(vectors)}/{len(vectors)} strict-master peer "
                f"reads byte-exact; accept-pulse masked by rd_pipe_r each time")


# ─────────────────────────────────────────────────────────────────────────────
# I5 — a lost peer R/B beat trips the outstanding backstop to AHB ERROR
# ─────────────────────────────────────────────────────────────────────────────
async def _watch_master_backstop(dut, stop):
    """Sample the master die's backstop state every cycle until stop['go']=False.
    Records: whether the read/write outstanding flags set, the max outstanding and
    per-beat counters seen, whether sub_err1_r fired, and whether hreadyout_raw was
    ever HIGH while a transaction was outstanding (the I5-specific blind spot)."""
    st = {"rd_os": 0, "wr_os": 0, "osr_max": 0, "stall_max": 0,
          "err_fired": 0, "os_raw_hi": 0, "os_raw_lo": 0, "os_raw_x": 0,
          "os_stallbusy": 0, "os_subext": 0}
    m = dut.u_master
    while stop["go"]:
        await RisingEdge(dut.hclk)
        rd = _int_or_none(m.sub_rd_os_r) or 0
        wr = 1 if (_int_or_none(m.sub_wr_os_ctr) or 0) > 0 else 0   # counter (Fix H) -> outstanding bool
        osr = _int_or_none(m.sub_osr_ctr_r) or 0
        stc = _int_or_none(m.sub_stall_ctr_r) or 0
        err = _int_or_none(m.sub_err1_r) or 0
        raw = _int_or_none(m.xhb_sub_hreadyout_raw)
        busy = _int_or_none(m.sub_stall_busy) or 0
        sxt = _int_or_none(m.sub_ext_stalled) or 0
        st["rd_os"] |= rd
        st["wr_os"] |= wr
        st["osr_max"] = max(st["osr_max"], osr)
        st["stall_max"] = max(st["stall_max"], stc)
        st["err_fired"] |= err
        if rd or wr:                       # characterise state WHILE outstanding
            if raw == 1:   st["os_raw_hi"] += 1
            elif raw == 0: st["os_raw_lo"] += 1
            else:          st["os_raw_x"]  += 1
            st["os_stallbusy"] += busy
            st["os_subext"]    += sxt
    stop["st"] = st


@cocotb.test()
async def test_i5_lost_response_backstop(dut):
    """A peer READ whose R beat is LOST (far BRAM wedged) must be terminated with
    an AHB ERROR by the OUTSTANDING backstop within ~2^OSR cycles — far below the
    per-beat timer (built at 2^20 here) — instead of hanging the PS forever."""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    osr_log2   = _ctr_log2(dut.u_master.sub_osr_ctr_r)     # as-built from RTL
    stall_log2 = _ctr_log2(dut.u_master.sub_stall_ctr_r)
    osr_cyc   = 1 << osr_log2
    stall_cyc = 1 << stall_log2
    tb.log.info(f"  [i5] backstops (as built): outstanding=2^{osr_log2}={osr_cyc} "
                f"cyc, per-beat stall=2^{stall_log2}={stall_cyc} cyc")
    assert stall_cyc >= 16 * osr_cyc, (
        "this test needs the per-beat timer built MUCH larger than the "
        "outstanding timer to attribute a fast ERROR to the outstanding backstop; "
        "rebuild with +define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=20 "
        "+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10")

    # ---- sanity: healthy round-trip does NOT false-trip the outstanding timer --
    off_ok, data_ok = 0x040, 0x51A7_0001
    await master.write(APERTURE_BASE + off_ok, data_ok)
    await ClockCycles(dut.hclk, WRITE_SETTLE)
    got = await master.read(APERTURE_BASE + off_ok)
    assert got == data_ok, (
        f"window not healthy pre-wedge (wrote 0x{data_ok:08x} read 0x{got:08x}); "
        f"the outstanding timer may be sized below the healthy round-trip")
    tb.log.info(f"  [i5] pre-wedge healthy round-trip OK (+0x{off_ok:03x}=0x{got:08x})")

    # ---- wedge the far terminus so the R beat is LOST ------------------------
    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 4)
    assert int(dut.u_s_mng_bram.force_stall.value) == 1, "stall deposit didn't take"

    stop = {"go": True}
    watcher = cocotb.start_soon(_watch_master_backstop(dut, stop))

    # A READ across the wedge cannot complete. It must return ERROR within a
    # window comfortably above the outstanding timeout but FAR below the per-beat
    # timeout — if the outstanding backstop is absent/broken this hangs.
    read_window = osr_cyc + 6000
    assert read_window < stall_cyc // 4, "read window must sit below the per-beat timer"
    got_err = hung = False
    try:
        await master.read(APERTURE_BASE + 0x080, timeout=read_window)
    except RuntimeError as e:
        got_err = "HRESP=ERROR" in str(e)
        tb.log.info(f"  [i5] wedged read returned ERROR as expected: {e}")
    except TimeoutError as e:
        hung = True
        tb.log.error(f"  [i5] wedged read HUNG: {e}")

    await ClockCycles(dut.hclk, 50)
    stop["go"] = False
    await ClockCycles(dut.hclk, 2)
    st = stop.get("st", {})
    dut.u_s_mng_bram.force_stall.value = 0
    await ClockCycles(dut.hclk, 50)

    tb.log.info(f"  [i5] backstop probes: {st}")

    assert not hung, (
        "ahb_sub HUNG on a lost peer R beat — the outstanding-response backstop "
        "did NOT terminate the transfer within the outstanding timeout.")
    assert got_err, "wedged read did not return HRESP=ERROR (backstop absent/OKAY)"
    assert st.get("rd_os"), "sub_rd_os_r never set — the read was not tracked outstanding"
    assert st.get("osr_max", 0) >= (osr_cyc >> 1), (
        f"outstanding counter only reached {st.get('osr_max')} (< {osr_cyc>>1}); "
        f"the ERROR was not driven by the outstanding backstop")
    assert st.get("err_fired"), "sub_err1_r never pulsed at the master"
    assert st.get("stall_max", 0) < (stall_cyc >> 2), (
        f"per-beat stall counter reached {st.get('stall_max')} (>= {stall_cyc>>2}) "
        f"— cannot attribute the ERROR to the OUTSTANDING backstop")
    tb.log.info("  [i5] PASS: lost peer R beat terminated with AHB ERROR by the "
                "OUTSTANDING backstop (per-beat timer nowhere near its limit) — "
                "the PS would un-block (SIGBUS) instead of hanging.")

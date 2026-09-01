"""Fixed-length AHB burst measurement on TideLink's `ahb_sub` peer aperture.

WHY THIS EXISTS
---------------
The XHB500 AHB->AXI bridge behind `ahb_sub` has a burst guard:

    deps/xhb500/.../xhb500_ahb_to_axi_bridge_chiplet_slv_core_addr.sv:147
        singles_burst <= ~hprot[3] || hexcl || hburst == BUR_INCR;

`singles_burst == 1` makes EVERY AHB beat its own single-beat AXI transaction
(core_addr.sv:163-166 admits SEQ beats into the address pipe).  `singles_burst
== 0` is the real burst path: one AW with awlen = N-1 and N W beats.

`hexcl` is tied 0 (tidelink_top.sv:2680), so the guard reduces to
`~hprot[3] || hburst == BUR_INCR`.  Every existing bench in this repo, and both
burst tests in nanosoc-ethernet-chiplet/verif/g2_soc_pair, drive `hprot = 0`,
so `singles_burst` has been 1 in 100% of validation to date and the
non-singles arm has NEVER executed.

This bench measures both arms directly:
  * a per-cycle census of the hburst encodings actually presented at `ahb_sub`
    AND at the XHB500 boundary (`u_master.xhb_sub_hburst`),
  * the latched `singles_burst` guard value,
  * the AXI AW beats XHB500 emits (awlen/awburst) and the W beats it consumes,
  * byte-exactness of every beat at the far die's ahb_mng BRAM terminus.

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh ; export TIDELINK_PHY_V2=1
    make MODULE=test_v2_burst_encodings SIM_BUILD=sim_build_burst
"""
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full


APERTURE_BASE = 0x4000_0000

# AHB HBURST encodings (AMBA AHB5, Table 3-3).
BUR_SINGLE = 0b000
BUR_INCR   = 0b001      # undefined length
BUR_INCR4  = 0b011
BUR_INCR8  = 0b101
BUR_INCR16 = 0b111

BURST_NAME = {
    BUR_SINGLE: "SINGLE(000)",
    BUR_INCR:   "INCR(001)",
    BUR_INCR4:  "INCR4(011)",
    BUR_INCR8:  "INCR8(101)",
    BUR_INCR16: "INCR16(111)",
}

# Beats each encoding must supply.  A fixed-length INCR<n> is a protocol
# contract: exactly n beats, no more, no fewer.
BEATS = {
    BUR_SINGLE: 1,
    BUR_INCR:   4,       # undefined length -- we choose 4
    BUR_INCR4:  4,
    BUR_INCR8:  8,
    BUR_INCR16: 16,
}

# Per-beat handshake budget.  A healthy beat completes in well under 200 hclk
# (the control test_v2_xhb_window round-trip settles in ~60).  3000 is ~15x the
# worst healthy case and far BELOW the 2^16 wrapper backstop, so a stall is
# reported as a stall rather than being masked by the timeout recovery.
BEAT_TIMEOUT = 3000

# Long budget, used by the one test that deliberately waits for the wrapper's
# 2^16-cycle backstop to fire.
BACKSTOP_TIMEOUT = 90000

WRITE_SETTLE = 3000     # let a posted burst cross both FC directions


# ---------------------------------------------------------------------------
# Instrument
# ---------------------------------------------------------------------------
class BurstCensus:
    """Per-cycle monitor of the ahb_sub burst path.

    Counts hburst encodings at TWO points -- the tb-facing `m_ahb_sub_*` port
    and the internal `u_master.xhb_sub_*` bundle actually presented to XHB500
    -- so a beat dropped BETWEEN them is visible as a count mismatch rather
    than as a silent absence.
    """

    def __init__(self, dut, log):
        self.dut = dut
        self.log = log
        self.reset_counts()

    def reset_counts(self):
        self.port_hburst = {}       # accepted address phases at ahb_sub
        self.xhb_hburst = {}        # accepted address phases at XHB500
        self.port_nonseq = 0
        self.port_seq = 0
        self.xhb_nonseq = 0
        self.xhb_seq = 0
        self.singles_burst_seen = set()
        self.aw_beats = []          # (awlen, awburst)
        self.w_beats = []           # (wdata, wlast)
        self.w_consumed = 0
        self.probe_errors = set()

    # -- safe hierarchical reads ------------------------------------------
    def _i(self, path, default=None):
        try:
            node = self.dut
            for part in path.split("."):
                node = getattr(node, part)
            return int(node.value)
        except Exception as exc:            # missing signal or X/Z
            self.probe_errors.add(f"{path}: {type(exc).__name__}")
            return default

    async def run(self, cycles):
        """Sample for `cycles` clocks.  Started with cocotb.start_soon."""
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            await ReadOnly()

            # ---- ahb_sub port (what the chiplet wrapper presents) --------
            hsel = self._i("m_ahb_sub_hsel", 0)
            htrans = self._i("m_ahb_sub_htrans", 0)
            hready = self._i("m_ahb_sub_hreadyout", 0)
            if hsel and (htrans & 0b10) and hready:
                hb = self._i("m_ahb_sub_hburst", -1)
                self.port_hburst[hb] = self.port_hburst.get(hb, 0) + 1
                if htrans == 0b10:
                    self.port_nonseq += 1
                else:
                    self.port_seq += 1

            # ---- XHB500 boundary inside tidelink_top ---------------------
            xsel = self._i("u_master.xhb_sub_hsel", 0)
            xtrans = self._i("u_master.xhb_sub_htrans", 0)
            xready = self._i("u_master.xhb_sub_hready", 0)
            if xsel and (xtrans & 0b10) and xready:
                xb = self._i("u_master.xhb_sub_hburst", -1)
                self.xhb_hburst[xb] = self.xhb_hburst.get(xb, 0) + 1
                if xtrans == 0b10:
                    self.xhb_nonseq += 1
                else:
                    self.xhb_seq += 1

            # ---- the guard itself ----------------------------------------
            sb = self._i("u_master.u_xhb_sub.u_core.u_addr.singles_burst")
            if sb is not None:
                self.singles_burst_seen.add(sb)

            # ---- AXI side: what XHB500 actually emitted -------------------
            if self._i("u_master.s_axi_awvalid", 0) and \
               self._i("u_master.s_axi_awready", 0):
                self.aw_beats.append((self._i("u_master.s_axi_awlen", -1),
                                      self._i("u_master.s_axi_awburst", -1)))
            if self._i("u_master.s_axi_wvalid", 0) and \
               self._i("u_master.s_axi_wready", 0):
                self.w_beats.append((self._i("u_master.s_axi_wdata", -1),
                                     self._i("u_master.s_axi_wlast", -1)))
            if self._i("u_master.ahb_sub_w_beat_consumed_o", 0):
                self.w_consumed += 1

    def summary(self):
        def fmt(d):
            if not d:
                return "{}"
            return "{" + ", ".join(
                f"{BURST_NAME.get(k, hex(k) if k is not None else '?')}: {v}"
                for k, v in sorted(d.items(), key=lambda kv: (kv[0] is None, kv[0]))
            ) + "}"
        return (
            f"port hburst={fmt(self.port_hburst)} "
            f"(NONSEQ={self.port_nonseq} SEQ={self.port_seq}); "
            f"xhb hburst={fmt(self.xhb_hburst)} "
            f"(NONSEQ={self.xhb_nonseq} SEQ={self.xhb_seq}); "
            f"singles_burst={sorted(self.singles_burst_seen)}; "
            f"AW(len,burst)={self.aw_beats}; "
            f"W beats={len(self.w_beats)} wlast={sum(1 for _, l in self.w_beats if l)}; "
            f"w_beat_consumed_o pulses={self.w_consumed}"
        )


# ---------------------------------------------------------------------------
# Burst-capable AHB-Lite master on m_ahb_sub_*
# ---------------------------------------------------------------------------
class BurstAHBSubMaster:
    """AHB-Lite master that can issue a real multi-beat burst.

    HREADY is driven constant high, never looped back from HREADYOUT: that is
    the same constraint the shipping chiplet obeys
    (nanosoc_eth_chiplet.sv:301 `hready_to_peer = dph_peer ? 1'b1 : ...`),
    because ahb_sub_hreadyout reads ahb_sub_hready combinationally and looping
    it closes a zero-delay cycle.

    Beats advance on HREADYOUT, per AHB: the address phase of beat k+1 overlaps
    the data phase of beat k, and a transfer boundary is a rising edge with
    HREADYOUT high.
    """

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.hclk

    def idle(self):
        d = self.dut
        d.m_ahb_sub_hsel.value = 0
        d.m_ahb_sub_haddr.value = 0
        d.m_ahb_sub_hburst.value = 0
        d.m_ahb_sub_hprot.value = 0
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_htrans.value = 0
        d.m_ahb_sub_hwdata.value = 0
        d.m_ahb_sub_hwrite.value = 0
        d.m_ahb_sub_hready.value = 1

    def _readyout(self):
        try:
            return int(self.dut.m_ahb_sub_hreadyout.value)
        except ValueError:
            return 0

    def _resp(self):
        try:
            return int(self.dut.m_ahb_sub_hresp.value)
        except ValueError:
            return 0

    async def _await_boundary(self, timeout):
        """Hold the current drive until HREADYOUT is high at a rising edge.

        Returns (ok, hresp_at_boundary).  Samples in ReadOnly so the
        combinational HREADYOUT is settled, then crosses the edge so the
        caller may drive the next phase.
        """
        for _ in range(timeout):
            await ReadOnly()
            r = self._readyout()
            resp = self._resp()
            await RisingEdge(self.clk)
            if r:
                return True, resp
        return False, 0

    async def burst_write(self, base, datas, hburst, hprot=0,
                          timeout=BEAT_TIMEOUT):
        """Issue one AHB write burst.  Returns a result dict (never raises on
        a stall -- a stall is a measurement, not a harness error)."""
        d = self.dut
        n = len(datas)
        res = {"beats_accepted": 0, "stalled_at": None, "hresp": 0,
               "completed": False}

        await RisingEdge(self.clk)
        # beat 0 address phase
        d.m_ahb_sub_hsel.value = 1
        d.m_ahb_sub_haddr.value = base & 0xFFFF_FFFF
        d.m_ahb_sub_htrans.value = 0b10          # NONSEQ
        d.m_ahb_sub_hsize.value = 2              # WORD
        d.m_ahb_sub_hburst.value = hburst
        d.m_ahb_sub_hprot.value = hprot
        d.m_ahb_sub_hwrite.value = 1
        d.m_ahb_sub_hready.value = 1

        for k in range(n):
            ok, resp = await self._await_boundary(timeout)
            if not ok:
                res["stalled_at"] = k
                self.idle()
                return res
            res["beats_accepted"] = k + 1
            if resp:
                res["hresp"] = 1
            # data phase of beat k
            d.m_ahb_sub_hwdata.value = datas[k] & 0xFFFF_FFFF
            if k + 1 < n:
                # address phase of beat k+1 (SEQ, +4, hburst/hprot held)
                d.m_ahb_sub_haddr.value = (base + 4 * (k + 1)) & 0xFFFF_FFFF
                d.m_ahb_sub_htrans.value = 0b11      # SEQ
            else:
                d.m_ahb_sub_hsel.value = 0
                d.m_ahb_sub_htrans.value = 0b00      # IDLE
                d.m_ahb_sub_hwrite.value = 0
                d.m_ahb_sub_hburst.value = 0

        # final data phase must retire too
        ok, resp = await self._await_boundary(timeout)
        if resp:
            res["hresp"] = 1
        res["completed"] = ok
        if not ok:
            res["stalled_at"] = n            # stalled in the last data phase
        self.idle()
        return res

    async def read_single(self, addr, timeout=BEAT_TIMEOUT):
        """Known-good single-beat read (identical sequencing to the passing
        test_v2_xhb_window control)."""
        d = self.dut
        await RisingEdge(self.clk)
        d.m_ahb_sub_hsel.value = 1
        d.m_ahb_sub_haddr.value = addr & 0xFFFF_FFFF
        d.m_ahb_sub_htrans.value = 0b10
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hburst.value = 0
        d.m_ahb_sub_hprot.value = 0
        d.m_ahb_sub_hwrite.value = 0
        d.m_ahb_sub_hready.value = 1
        await RisingEdge(self.clk)
        d.m_ahb_sub_hsel.value = 0
        d.m_ahb_sub_htrans.value = 0

        seen_low = False
        for _ in range(timeout):
            await ReadOnly()
            r = self._readyout()
            try:
                rd = int(self.dut.m_ahb_sub_hrdata.value)
            except ValueError:
                rd = -1
            await RisingEdge(self.clk)
            if not r:
                seen_low = True
            elif seen_low:
                self.idle()
                return rd
        self.idle()
        return None


def _bram_peek(dut, off):
    try:
        return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception:
        return None


async def _bringup(dut):
    tb = PairV2TB(dut)
    m = BurstAHBSubMaster(dut)
    m.idle()
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    return tb, m


async def _measure_one(dut, tb, m, hburst, hprot, base_off, label,
                       beat_timeout=BEAT_TIMEOUT):
    """Drive one burst, census it, and check every beat at the far die."""
    n = BEATS[hburst]
    datas = [(0xB0000000 | (hburst << 20) | (hprot << 16) | (i << 4) | i)
             & 0xFFFF_FFFF for i in range(n)]
    base = APERTURE_BASE + base_off

    census = BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(beat_timeout * (n + 2) + WRITE_SETTLE + 64))

    res = await m.burst_write(base, datas, hburst, hprot, timeout=beat_timeout)
    await ClockCycles(dut.hclk, WRITE_SETTLE)

    # far-die check: BRAM peek is the ground truth (the read path is a
    # separate single-beat transaction and would mask a lost write).
    got = [_bram_peek(dut, base_off + 4 * i) for i in range(n)]
    bad = [(i, datas[i], got[i]) for i in range(n) if got[i] != datas[i]]

    tb.log.info(f"[burst] {label}: hburst={BURST_NAME[hburst]} hprot=0x{hprot:x} "
                f"beats={n} -> accepted={res['beats_accepted']} "
                f"completed={res['completed']} stalled_at={res['stalled_at']} "
                f"hresp={res['hresp']}")
    tb.log.info(f"[burst] {label}: {census.summary()}")
    if census.probe_errors:
        tb.log.warning(f"[burst] {label}: PROBE ERRORS {sorted(census.probe_errors)}")
    tb.log.info(f"[burst] {label}: W payloads (data,wlast)="
                + str([(f"0x{d:08x}" if d is not None and d >= 0 else str(d), l)
                       for d, l in census.w_beats]))
    for i in range(n):
        g = "None" if got[i] is None else f"0x{got[i]:08x}"
        tb.log.info(f"[burst] {label}:   beat{i:2d} @0x{base + 4*i:08x} "
                    f"wrote=0x{datas[i]:08x} bram={g}"
                    f"{'  <-- MISMATCH' if got[i] != datas[i] else ''}")

    mon.kill()
    return {"label": label, "hburst": hburst, "hprot": hprot, "n": n,
            "res": res, "census": census, "bad": bad}


# ===========================================================================
# TEST 1 -- CONTROL + shipping-equivalent census (hprot=0, singles path)
# ===========================================================================
@cocotb.test()
async def test_burst_census_hprot0(dut):
    """hprot=0: the SHIPPING ethernet-chiplet configuration.

    nanosoc_eth_chiplet.sv:995 ties ahb_sub_hprot[3:2]=00, so hprot[3]=0 and
    the guard latches singles_burst=1 for EVERY encoding.  Expectation: all
    five encodings behave identically (each beat a separate AXI single) and
    every beat is byte-exact.  This is the configuration g2_soc_pair's
    INCR4/INCR16 tests actually exercised.
    """
    tb, m = await _bringup(dut)

    plan = [
        (BUR_SINGLE, 0x000, "h0-SINGLE"),
        (BUR_INCR,   0x040, "h0-INCR"),
        (BUR_INCR4,  0x080, "h0-INCR4"),
        (BUR_INCR8,  0x0C0, "h0-INCR8"),
        (BUR_INCR16, 0x140, "h0-INCR16"),
    ]
    out = []
    for hburst, off, label in plan:
        out.append(await _measure_one(dut, tb, m, hburst, 0x0, off, label))

    tb.log.info("=" * 78)
    tb.log.info("CENSUS hprot=0 (shipping eth-chiplet tie-down equivalent)")
    for r in out:
        c = r["census"]
        tb.log.info(f"  {r['label']:12s} singles_burst={sorted(c.singles_burst_seen)} "
                    f"AW={c.aw_beats} Wbeats={len(c.w_beats)} "
                    f"accepted={r['res']['beats_accepted']}/{r['n']} "
                    f"bad_beats={len(r['bad'])}")
    tb.log.info("=" * 78)

    fails = [r for r in out if r["bad"] or not r["res"]["completed"]]
    assert not fails, (
        "hprot=0 burst path FAILED:\n" + "\n".join(
            f"  {r['label']}: completed={r['res']['completed']} "
            f"stalled_at={r['res']['stalled_at']} bad={r['bad']}"
            for r in fails))


# ===========================================================================
# TEST 2..6 -- the NEVER-EXECUTED path: hprot[3]=1 (cacheable/modifiable)
# ===========================================================================
async def _cacheable_case(dut, hburst, off, label):
    tb, m = await _bringup(dut)
    r = await _measure_one(dut, tb, m, hburst, 0x8, off, label)
    c = r["census"]
    tb.log.info("-" * 78)
    tb.log.info(f"RESULT {label}: singles_burst={sorted(c.singles_burst_seen)} "
                f"AW={c.aw_beats} Wbeats={len(c.w_beats)} "
                f"wlast={sum(1 for _, l in c.w_beats if l)} "
                f"accepted={r['res']['beats_accepted']}/{r['n']} "
                f"completed={r['res']['completed']} bad_beats={len(r['bad'])}")
    tb.log.info("-" * 78)
    return r


@cocotb.test()
async def test_cacheable_single(dut):
    """hprot[3]=1, SINGLE.  Guard clears singles_burst, but a SINGLE is one
    beat with awlen=0, so this must still work.  It is the CONTROL for the
    cacheable configuration: if this fails, the failure is not burst-specific.
    """
    r = await _cacheable_case(dut, BUR_SINGLE, 0x200, "h8-SINGLE")
    assert r["res"]["completed"] and not r["bad"], (
        f"cacheable SINGLE control FAILED: {r['res']} bad={r['bad']}")


@cocotb.test()
async def test_cacheable_incr_undefined(dut):
    """hprot[3]=1, INCR(001).  `hburst == BUR_INCR` keeps singles_burst=1, so
    this stays on the validated singles path even with hprot[3] set.  Second
    control: isolates "cacheable" from "fixed-length"."""
    r = await _cacheable_case(dut, BUR_INCR, 0x240, "h8-INCR")
    assert r["res"]["completed"] and not r["bad"], (
        f"cacheable undefined-INCR control FAILED: {r['res']} bad={r['bad']}")


@cocotb.test()
async def test_cacheable_incr4(dut):
    """hprot[3]=1, INCR4(011) -- THE UNTESTED PATH.  singles_burst=0, so
    XHB500 must emit ONE AW with awlen=3 and consume 4 W beats."""
    r = await _cacheable_case(dut, BUR_INCR4, 0x280, "h8-INCR4")
    assert r["res"]["completed"], (
        f"INCR4 on the fixed-length path did NOT complete: {r['res']}")
    assert not r["bad"], f"INCR4 beat corruption: {r['bad']}"


@cocotb.test()
async def test_cacheable_incr8(dut):
    """hprot[3]=1, INCR8(101) -- untested path, awlen=7."""
    r = await _cacheable_case(dut, BUR_INCR8, 0x300, "h8-INCR8")
    assert r["res"]["completed"], (
        f"INCR8 on the fixed-length path did NOT complete: {r['res']}")
    assert not r["bad"], f"INCR8 beat corruption: {r['bad']}"


@cocotb.test()
async def test_cacheable_incr16(dut):
    """hprot[3]=1, INCR16(111) -- untested path, awlen=15."""
    r = await _cacheable_case(dut, BUR_INCR16, 0x380, "h8-INCR16")
    assert r["res"]["completed"], (
        f"INCR16 on the fixed-length path did NOT complete: {r['res']}")
    assert not r["bad"], f"INCR16 beat corruption: {r['bad']}"


# ===========================================================================
# TEST 7 -- if INCR4 stalls, does the wrapper backstop recover it?
# ===========================================================================
@cocotb.test()
async def test_cacheable_incr4_backstop(dut):
    """Give a cacheable INCR4 the full 2^16 wrapper-backstop budget.

    Characterisation, not a pass/fail gate: records whether the stall (if any)
    is escaped by the I5 outstanding-response backstop / synthetic-B drain,
    and what the master eventually sees.
    """
    tb, m = await _bringup(dut)
    r = await _measure_one(dut, tb, m, BUR_INCR4, 0x8, 0x400,
                           "h8-INCR4-backstop", beat_timeout=BACKSTOP_TIMEOUT)
    c = r["census"]
    tb.log.info("=" * 78)
    tb.log.info(f"BACKSTOP CHARACTERISATION: accepted={r['res']['beats_accepted']}/4 "
                f"completed={r['res']['completed']} hresp={r['res']['hresp']} "
                f"singles_burst={sorted(c.singles_burst_seen)} AW={c.aw_beats} "
                f"Wbeats={len(c.w_beats)} bad_beats={len(r['bad'])}")
    tb.log.info("=" * 78)
    assert True    # characterisation only


# ===========================================================================
# TEST 8 -- is the duplicated AW an artifact of the driver, or the wrapper?
# ===========================================================================
class LatchProbe:
    """Counts the ahb_sub address-pipeline LATCH event.

    tidelink_top.sv:1662  `if (ext_is_nonseq && !pipe_valid_r)` is the only
    condition that loads pipe_haddr_r/pipe_hburst_r.  One AHB transfer should
    latch exactly ONCE.  A second latch means the same address phase is
    presented to XHB500 twice and XHB500 issues it twice.
    """

    def __init__(self, dut):
        self.dut = dut
        self.latches = 0
        self.aw = 0
        self.w = 0

    def _i(self, path, default=0):
        try:
            node = self.dut
            for p in path.split("."):
                node = getattr(node, p)
            return int(node.value)
        except Exception:
            return default

    async def run(self, cycles):
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            await ReadOnly()
            if self._i("u_master.ext_is_nonseq") and \
               not self._i("u_master.pipe_valid_r"):
                self.latches += 1
            if self._i("u_master.s_axi_awvalid") and \
               self._i("u_master.s_axi_awready"):
                self.aw += 1
            if self._i("u_master.s_axi_wvalid") and \
               self._i("u_master.s_axi_wready"):
                self.w += 1


async def _drive_hold_style(dut, addr, data):
    """AHB-COMPLIANT: hold the NONSEQ address phase while HREADYOUT is low
    (AMBA AHB5 3.4: the manager must hold address/control stable through a
    subordinate wait state)."""
    m = BurstAHBSubMaster(dut)
    return await m.burst_write(addr, [data], BUR_SINGLE, 0x0)


async def _drive_pulse_style(dut, addr, data):
    """The convention every existing bench uses: present NONSEQ for exactly ONE
    cycle then drop to IDLE, regardless of HREADYOUT.  See
    test_v2_xhb_window.py:54-57 -- 'drop to IDLE so it is not re-latched'."""
    d = dut
    await RisingEdge(d.hclk)
    d.m_ahb_sub_hsel.value = 1
    d.m_ahb_sub_haddr.value = addr & 0xFFFF_FFFF
    d.m_ahb_sub_htrans.value = 0b10
    d.m_ahb_sub_hsize.value = 2
    d.m_ahb_sub_hburst.value = 0
    d.m_ahb_sub_hprot.value = 0
    d.m_ahb_sub_hwrite.value = 1
    d.m_ahb_sub_hready.value = 1
    d.m_ahb_sub_hwdata.value = data & 0xFFFF_FFFF
    await RisingEdge(d.hclk)
    d.m_ahb_sub_hsel.value = 0
    d.m_ahb_sub_htrans.value = 0
    d.m_ahb_sub_hwrite.value = 0
    seen_low = False
    for _ in range(BEAT_TIMEOUT):
        await ReadOnly()
        try:
            r = int(d.m_ahb_sub_hreadyout.value)
        except ValueError:
            r = 0
        await RisingEdge(d.hclk)
        if not r:
            seen_low = True
        elif seen_low:
            break
    BurstAHBSubMaster(dut).idle()


@cocotb.test()
async def test_nonseq_relatch_ab(dut):
    """A/B the two address-phase conventions on ONE single-beat write each.

    Measures the pipeline latch count, AXI AW count and AXI W count for
    (A) holding NONSEQ through the wait state (AHB-mandatory), versus
    (B) pulsing NONSEQ for one cycle (what every existing bench does).
    Characterisation only.
    """
    tb, m = await _bringup(dut)

    results = {}
    for label, drive, off in (("HOLD-NONSEQ", _drive_hold_style, 0x600),
                              ("PULSE-NONSEQ", _drive_pulse_style, 0x640)):
        p = LatchProbe(dut)
        t = cocotb.start_soon(p.run(BEAT_TIMEOUT + WRITE_SETTLE + 64))
        await drive(dut, APERTURE_BASE + off, 0xD0D0_0000 | off)
        await ClockCycles(dut.hclk, WRITE_SETTLE)
        t.kill()
        got = _bram_peek(dut, off)
        results[label] = (p.latches, p.aw, p.w, got)
        tb.log.info(f"[relatch] {label}: pipe latches={p.latches} "
                    f"AXI AW={p.aw} AXI W={p.w} bram="
                    f"{'None' if got is None else f'0x{got:08x}'} "
                    f"(expected 0x{0xD0D00000 | off:08x})")

    tb.log.info("=" * 78)
    tb.log.info(f"RELATCH A/B: {results}")
    tb.log.info("=" * 78)
    assert True


@cocotb.test()
async def test_h0_incr4_payloads(dut):
    """hprot=0 INCR4 with the W payloads dumped -- the shipping ethernet-chiplet
    configuration, for direct comparison against the hprot[3]=1 fixed-length
    result."""
    tb, m = await _bringup(dut)
    r = await _measure_one(dut, tb, m, BUR_INCR4, 0x0, 0x700, "h0-INCR4-payload")
    assert r["res"]["completed"] and not r["bad"], f"{r['res']} bad={r['bad']}"


@cocotb.test()
async def test_incr4_cacheable_pulse_nonseq(dut):
    """MECHANISM TEST: drive a cacheable INCR4 whose NONSEQ is pulsed for one
    cycle instead of held.

    If the leading all-zero AXI burst disappears when the NONSEQ is not held,
    the zero burst is caused by the wrapper's address-pipeline RE-LATCH
    (tidelink_top.sv:1662) and not by XHB500's burst mode alone.
    Characterisation only.
    """
    tb, m = await _bringup(dut)
    n = 4
    base_off = 0x780
    base = APERTURE_BASE + base_off
    datas = [(0xC0000000 | (i << 4) | i) for i in range(n)]

    census = BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(BEAT_TIMEOUT + WRITE_SETTLE + 64))

    d = dut
    await RisingEdge(d.hclk)
    d.m_ahb_sub_hsel.value = 1
    d.m_ahb_sub_haddr.value = base
    d.m_ahb_sub_htrans.value = 0b10          # NONSEQ, ONE cycle only
    d.m_ahb_sub_hsize.value = 2
    d.m_ahb_sub_hburst.value = BUR_INCR4
    d.m_ahb_sub_hprot.value = 0x8
    d.m_ahb_sub_hwrite.value = 1
    d.m_ahb_sub_hready.value = 1
    await RisingEdge(d.hclk)
    d.m_ahb_sub_hsel.value = 0
    d.m_ahb_sub_htrans.value = 0             # IDLE -- not re-latched

    # feed the remaining beats' data as XHB500 asks for them
    d.m_ahb_sub_hwdata.value = datas[0]
    for k in range(1, n):
        for _ in range(BEAT_TIMEOUT):
            await ReadOnly()
            try:
                r = int(d.m_ahb_sub_hreadyout.value)
            except ValueError:
                r = 0
            await RisingEdge(d.hclk)
            if r:
                break
        d.m_ahb_sub_hwdata.value = datas[k]
    await ClockCycles(d.hclk, 200)
    m.idle()
    await ClockCycles(d.hclk, WRITE_SETTLE)
    mon.kill()

    got = [_bram_peek(dut, base_off + 4 * i) for i in range(n)]
    tb.log.info(f"[pulse] cacheable INCR4, NONSEQ pulsed: {census.summary()}")
    tb.log.info("[pulse] W payloads="
                + str([(f"0x{x:08x}" if x is not None and x >= 0 else str(x), l)
                       for x, l in census.w_beats]))
    for i in range(n):
        g = "None" if got[i] is None else f"0x{got[i]:08x}"
        tb.log.info(f"[pulse]   word{i} @0x{base + 4*i:08x} "
                    f"intended=0x{datas[i]:08x} bram={g}")
    assert True


@cocotb.test()
async def test_cacheable_incr4_destroys_prior_data(dut):
    """Does the leading all-zero AXI burst actually LAND in peer memory?

    Pre-fill four peer words with known non-zero data, then issue ONE cacheable
    INCR4 (AHB-compliant held NONSEQ) over the same four addresses while
    sampling the far-die BRAM every cycle.  Records every distinct state the
    peer memory passes through.
    """
    tb, m = await _bringup(dut)

    base_off = 0x800
    base = APERTURE_BASE + base_off
    seed = [0x5EED0000 | i for i in range(4)]
    final = [0xF1A10000 | (i << 4) | i for i in range(4)]

    # ---- pre-fill with the PULSE convention (one clean AXI single each) ----
    for i, v in enumerate(seed):
        await _drive_pulse_style(dut, base + 4 * i, v)
        await ClockCycles(dut.hclk, 1500)
    pre = [_bram_peek(dut, base_off + 4 * i) for i in range(4)]
    tb.log.info(f"[destroy] pre-fill = {[f'0x{x:08x}' if x is not None else None for x in pre]}")
    assert pre == seed, f"pre-fill failed: {pre} != {seed}"

    # ---- sample the peer BRAM every cycle across the burst -----------------
    states = []

    async def sampler(cycles):
        last = None
        for _ in range(cycles):
            await RisingEdge(dut.hclk)
            await ReadOnly()
            cur = tuple(_bram_peek(dut, base_off + 4 * i) for i in range(4))
            if cur != last:
                states.append(cur)
                last = cur

    census = BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(BEAT_TIMEOUT + WRITE_SETTLE + 64))
    smp = cocotb.start_soon(sampler(BEAT_TIMEOUT + WRITE_SETTLE + 64))

    res = await m.burst_write(base, final, BUR_INCR4, 0x8)
    await ClockCycles(dut.hclk, WRITE_SETTLE)
    mon.kill()
    smp.kill()

    tb.log.info(f"[destroy] burst result = {res}")
    tb.log.info(f"[destroy] {census.summary()}")
    tb.log.info(f"[destroy] peer-memory states traversed ({len(states)}):")
    for s in states:
        tb.log.info("[destroy]   "
                    + " ".join("None" if x is None else f"0x{x:08x}" for x in s))

    zero_state = any(all(x == 0 for x in s) for s in states)
    tb.log.info(f"[destroy] ALL-ZERO state observed in peer memory: {zero_state}")
    tb.log.info(f"[destroy] final = {[f'0x{x:08x}' for x in states[-1]]} "
                f"intended = {[f'0x{x:08x}' for x in final]}")
    assert True

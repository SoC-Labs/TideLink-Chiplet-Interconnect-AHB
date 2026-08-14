"""N1 — does the WRITE backstop permanently disable the READ backstop?

CLAIM UNDER TEST (imp/hw_gate/ESCAPE_VS_SAFETY_AUDIT_2026_08_13.md, finding N1;
code-path reading only until this file). Against `src/rtl/tidelink_top.sv`:

  1. Both ahb_sub backstops share ONE age timer (`sub_osr_ctr_r`) and ONE
     outstanding predicate (`sub_axi_outstanding = sub_rd_os_r |
     (sub_wr_os_ctr != 0)`, :1573), so a COINCIDENT stuck READ + stuck WRITE
     expires them TOGETHER at some cycle T.
  2. At T the read path sets `sub_err1_r` (:1674, `if (sub_rd_os_r)`) and the
     write path sets `synth_b_pending` (:1857/:1865, keyed on the SAME expiry
     via `sub_wr_stuck_fire`).
  3. :1898/:1906 gate the master-facing ERROR with `& ~synth_b_pending`, so the
     read's two-cycle AHB ERROR is SUPPRESSED for as long as the synth-B drain
     is pending.
  4. :1675 `sub_rd_os_r <= 1'b0;` clears UNCONDITIONALLY — outside the
     `if (sub_rd_os_r)` guard on the line above.
  5. BOTH ERROR fire sites (:1645 per-beat, :1674 I5) are `if (sub_rd_os_r)`.

  => the read receives no ERROR, and with sub_rd_os_r cleared neither backstop
     can ever fire for it again: no error, no retry, PS hangs with NO recovery.

WHY THIS IS A SIM TASK. It needs a stuck READ and a stuck WRITE outstanding at
the SAME time. Last night's HW capture could not produce it (`sub_rd_os_r` and
`rd_pipe_r` read 0 on every sample of every window — no read was ever
outstanding, so the coincidence had no opportunity).

REACHABILITY — why the previous attempt concluded the route was closed.
`test_axi_datanode_gaps.py:test_i5_traffic_behind_a_stuck_write_is_bounded`
measured "XHB500 serialises the sub port" and wrote the route off. It does not.
XHB500's AR gate is (xhb500 core_addr.sv:151-154, :139, hazard_list.sv:84,:139):

    read submitted iff  ready_for_read & ~hazard        (hazard_full/empty
                                                         appear ONLY in the
                                                         WRITE arm)
    hazard  = |match_addr_i
    match_addr_i[i] = valid_entry(i) & (hazard_list_addr[i] == chk_addr[31:12])

i.e. a read is blocked ONLY by a 4KB-PAGE ADDRESS MATCH against a live EWR
entry — never by the list merely being non-empty. `ready_for_read`
(core_resp.sv:233) counts outstanding R beats only and is untouched by writes,
and an EWR write never sets `wait_for_b` (core_wdata.sv:303,:248) so it releases
the AHB data phase without waiting for B. The earlier test used OFF_POST=0x400
and OFF_RD=0x300 — the SAME 4KB page — so its read was address-hazard-stalled
behind the write. Put the read in a DIFFERENT 4KB page and the AR issues while
the write's B is still outstanding. That is what these tests do.

TESTS (each needs its OWN sim — a second run_bringup_full does not re-POR):

  test_n1_control_stuck_read_alone_gets_error   (CONTROL / non-vacuity)
      Far terminus stalled, ONE blocking read, NO write outstanding. The read
      must be bounded by a legal 2-cycle HRESP=ERROR. Establishes that the
      vehicle really does produce a stuck read that the backstop rescues.

  test_n1_coincident_stuck_rd_wr_defeats_read_backstop   (PRIMARY)
      IDENTICAL stimulus plus N posted (bufferable, EWR) writes outstanding in
      a DIFFERENT 4KB page. Asserts (a) the coincident state is genuinely
      entered, (b) whether sub_err1_r is suppressed by synth_b_pending at the
      port, (c) whether sub_rd_os_r is cleared unconditionally, (d) whether the
      read ever subsequently gets an AHB ERROR or any completion.

  test_n1_forced_aw_coincidence                 (BACKUP vehicle, force-run only)
      Builds the same coincident state by Forcing s_axi_awvalid instead of
      routing real posted writes, for the case where the natural route is shut.
      Forces the VALID, never the READY: forcing s_axi_awready/s_axi_wready LOW
      wedges XHB500 unrecoverably (measured 2026-08-13) so a test built that way
      can never show post-recovery behaviour.

BUILD: run with the SHORT I5 window so the expiry is reachable in sim —
  make -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_n1 \
       EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
       MODULE=test_n1_read_backstop_defeat TESTCASE=<name>
The N1 mechanism is timeout-VALUE independent (it is a gating-term interaction),
and the per-beat stall backstop is deliberately LEFT at its 2^16 default so the
"does anything rescue it later" window covers a real stall expiry too.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

# Helpers only (no @cocotb.test names imported, so nothing leaks into this
# module's regression set).
from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)

# The stuck WRITE lives in 4KB page 0x40000; the stuck READ in page 0x40001, so
# XHB500's hazard_list address match (chk_addr[31:12]) does NOT fire and the AR
# is issued while the write's B is still outstanding. The far-side BRAM is
# tb_ahb_bram_slave #(.AW(12)) (tb_top.sv:870) so page bits are aliased away at
# the terminus — irrelevant here, the terminus is stalled and returns nothing.
WR_PAGE   = 0x0000        # page 0x40000
RD_PAGE   = 0x1000        # page 0x40001  <- different page: no hazard match
OFF_WR    = 0x400
OFF_RD    = 0x300
ADDR_WR   = APER_BASE + WR_PAGE + OFF_WR
ADDR_RD   = APER_BASE + RD_PAGE + OFF_RD
D_SEED    = 0x5EED0042

N_POSTED  = 3             # >=2 so the synth-B drain spans BOTH ERROR cycles
                          # (XHB500 EWR hazard list is depth 4)

# Long enough to cover the 2^16 per-beat stall backstop (65536) plus margin, so
# "nothing ever rescues the read" is measured across a real stall expiry and
# many I5 windows, not just asserted.
OBSERVE_CYCLES = 140_000


# ── safe sampling ────────────────────────────────────────────────────────────
def _i(h, default=None):
    try:    return int(h.value)
    except Exception: return default


def _g(obj, name, default=None):
    """Read a possibly-absent child signal (an A/B build may not have it)."""
    try:    return int(getattr(obj, name).value)
    except Exception: return default


def _set_far_stall(dut, on):
    """tb_top.sv:1075 — `reg force_stall`, no other driver, so a deposit holds.
    Models a wedged far terminus: neither B nor R ever comes back."""
    try:    dut.u_s_mng_bram.force_stall.value = Force(1 if on else 0)
    except Exception:
        try:    dut.u_s_mng_bram.force_stall.value = 1 if on else 0
        except Exception: pass


def _osr_log2(m):
    """SUB_OUTSTANDING_TIMEOUT_LOG2 for THIS build: sub_osr_ctr_r is
    [LOG2:0], so its width is LOG2+1 and the expiry bit is the MSB."""
    try:    return len(m.sub_osr_ctr_r) - 1
    except Exception: return 16


class N1Watch:
    """Cycle-accurate recorder for the N1 chain.

    Records, every hclk:
      * whether the COINCIDENT state holds (sub_rd_os_r=1 AND sub_wr_os_ctr!=0)
      * every timer EXPIRY, with the full backstop state at that cycle
      * sub_err1_r/sub_err2_r and whether they were VISIBLE at the master port
        (i.e. not masked by synth_b_pending)
      * every HRESP=1 pulse the master could actually see
      * whether ahb_sub_hreadyout ever returns high (the read completing)
    plus a +/- window of raw samples around the first err1 assertion."""

    def __init__(self, dut, pre=12, post=40):
        self.dut = dut
        self.m = dut.u_master
        self.log2 = _osr_log2(self.m)
        self.pre, self.post = pre, post
        self.o = {
            "coincident_cycles": 0, "first_coincident": None,
            "coincident_at_expiry": None,
            "expiries": [], "err1_rises": 0,
            "err1_visible_cycles": 0, "err2_visible_cycles": 0,
            "port_err_pulses": [], "rd_os_cleared_at": None,
            "rd_os_high_cycles": 0, "wr_ctr_max": 0,
            "hreadyout_high_after_arm": 0, "window": [], "log2": self.log2,
            "synthb_rises": 0,
        }
        self._ring = []
        self._captured = False
        self._left = 0

    def _sample(self, c):
        m = self.m
        osr = _g(m, "sub_osr_ctr_r", 0)
        return {
            "c": c,
            "rd_os": _g(m, "sub_rd_os_r"),
            "wr_ctr": _g(m, "sub_wr_os_ctr"),
            "osr": osr,
            "osr_exp": (osr >> self.log2) & 1 if osr is not None else None,
            "st_exp": _g(m, "sub_stall_expired"),
            "err1": _g(m, "sub_err1_r"),
            "err2": _g(m, "sub_err2_r"),
            "sb": _g(m, "synth_b_pending"),
            "raw": _g(m, "xhb_sub_hreadyout_raw"),
            "prdy": _i(self.dut.m_ahb_sub_hreadyout),
            "prsp": _i(self.dut.m_ahb_sub_hresp),
            "bv": _g(m, "s_axi_bvalid"), "br": _g(m, "s_axi_bready"),
        }

    async def run(self, cycles, armed_after=None):
        """armed_after: a callable returning True once the read's address phase
        has been issued, so `hreadyout_high_after_arm` only counts the read."""
        o = self.o
        prev_err1 = 0; prev_rd = 0; prev_sb = 0
        for c in range(cycles):
            await RisingEdge(self.dut.hclk)
            s = self._sample(c)
            self._ring.append(s)
            if len(self._ring) > self.pre: self._ring.pop(0)

            if s["rd_os"]:
                o["rd_os_high_cycles"] += 1
                if s["wr_ctr"]:
                    o["coincident_cycles"] += 1
                    if o["first_coincident"] is None: o["first_coincident"] = c
            if s["wr_ctr"] is not None and s["wr_ctr"] > o["wr_ctr_max"]:
                o["wr_ctr_max"] = s["wr_ctr"]

            # Timer expiry (either backstop) — capture the FULL state at T.
            if s["osr_exp"] or s["st_exp"]:
                if len(o["expiries"]) < 12:
                    o["expiries"].append(dict(s))
                if o["coincident_at_expiry"] is None:
                    o["coincident_at_expiry"] = bool(s["rd_os"] and s["wr_ctr"])

            if s["err1"]:
                if not prev_err1: o["err1_rises"] += 1
                if not s["sb"]:   o["err1_visible_cycles"] += 1
            if s["err2"] and not s["sb"]: o["err2_visible_cycles"] += 1
            if s["sb"] and not prev_sb: o["synthb_rises"] += 1

            # (c) unconditional clear of sub_rd_os_r
            if prev_rd and not s["rd_os"] and o["rd_os_cleared_at"] is None:
                o["rd_os_cleared_at"] = dict(s)

            # (d) anything the AHB master could act on
            if s["prsp"]:
                if len(o["port_err_pulses"]) < 12:
                    o["port_err_pulses"].append(dict(s))
            if armed_after is not None and armed_after() and s["prdy"]:
                o["hreadyout_high_after_arm"] += 1

            # +/- window around the FIRST err1 assertion
            if not self._captured and s["err1"]:
                o["window"] = list(self._ring); self._captured = True
                self._left = self.post
            elif self._left:
                o["window"].append(s); self._left -= 1

            prev_err1 = s["err1"] or 0
            prev_rd = s["rd_os"] or 0
            prev_sb = s["sb"] or 0


def _dump(dut, tag, o):
    dut._log.info(
        f"[n1] {tag}: coincident_cycles={o['coincident_cycles']} "
        f"first_coincident={o['first_coincident']} "
        f"coincident_at_expiry={o['coincident_at_expiry']} "
        f"wr_ctr_max={o['wr_ctr_max']} err1_rises={o['err1_rises']} "
        f"err1_visible={o['err1_visible_cycles']} err2_visible={o['err2_visible_cycles']} "
        f"synthb_rises={o['synthb_rises']} port_err_pulses={len(o['port_err_pulses'])} "
        f"hready_high_after_arm={o['hreadyout_high_after_arm']} "
        f"osr_log2={o['log2']}")
    for e in o["expiries"]:
        dut._log.info(f"[n1] {tag} EXPIRY @{e['c']}: rd_os={e['rd_os']} "
                      f"wr_ctr={e['wr_ctr']} osr_exp={e['osr_exp']} st_exp={e['st_exp']} "
                      f"err1={e['err1']} sb={e['sb']}")
    if o["rd_os_cleared_at"]:
        s = o["rd_os_cleared_at"]
        dut._log.info(f"[n1] {tag} rd_os CLEARED @{s['c']}: err1={s['err1']} sb={s['sb']} "
                      f"wr_ctr={s['wr_ctr']} port(rdy={s['prdy']},rsp={s['prsp']})")
    for s in o["window"]:
        dut._log.info(f"[n1] {tag} T{s['c']:>7} rd_os={s['rd_os']} wr={s['wr_ctr']} "
                      f"osr_exp={s['osr_exp']} st_exp={s['st_exp']} err1={s['err1']} "
                      f"err2={s['err2']} sb={s['sb']} raw={s['raw']} "
                      f"port_rdy={s['prdy']} port_rsp={s['prsp']} "
                      f"bv={s['bv']} br={s['br']}")


async def _read_task(master, addr, timeout, out):
    try:
        out["val"] = await master.read(addr, timeout=timeout)
        out["cls"] = "COMPLETE"
    except RuntimeError: out["cls"] = "ERROR"
    except TimeoutError: out["cls"] = "HANG"
    except Exception as e: out["cls"] = f"EXC:{e}"


# =============================================================================
# CONTROL — the same stuck read with NO coincident write must get its ERROR.
# =============================================================================
@cocotb.test()
async def test_n1_control_stuck_read_alone_gets_error(dut):
    """NON-VACUITY CONTROL for the primary test below.

    Identical vehicle (far terminus stalled, one blocking read at ADDR_RD) but
    with NO write outstanding, so `sub_wr_os_ctr == 0` at the shared timer's
    expiry, `sub_wr_stuck_fire` is 0 and `synth_b_pending` is never set. The
    read backstop must then deliver its 2-cycle AHB ERROR to the master.

    If this FAILS the primary result is meaningless — the vehicle would not be
    producing a rescuable stuck read in the first place."""
    tb, master = await _bringup(dut)
    m = dut.u_master

    # Prove the read path works BEFORE stalling, so a later hang is the stall
    # and not a broken/undecoded read address (ADDR_RD is a different 4KB page
    # from every other address this suite uses).
    await master.write(ADDR_RD, D_SEED)
    await ClockCycles(dut.hclk, 2000)
    pre = await master.read(ADDR_RD)
    assert pre == D_SEED, f"clean read of ADDR_RD broken before stall: 0x{pre:08x}"

    armed = {"v": False}
    w = N1Watch(dut)
    wt = cocotb.start_soon(w.run(OBSERVE_CYCLES, armed_after=lambda: armed["v"]))

    _set_far_stall(dut, True)
    await ClockCycles(dut.hclk, 20)

    out = {}
    armed["v"] = True
    rt = cocotb.start_soon(_read_task(master, ADDR_RD, OBSERVE_CYCLES - 2000, out))
    while "cls" not in out:
        await ClockCycles(dut.hclk, 200)
    await ClockCycles(dut.hclk, 200)
    wt.kill(); rt.kill()
    _set_far_stall(dut, False)
    _release_all(tb)
    o = w.o
    _dump(dut, "CONTROL", o)
    dut._log.info(f"[n1] CONTROL read class={out['cls']}")

    assert o["rd_os_high_cycles"] > 0, (
        "VACUOUS: sub_rd_os_r never asserted — no read was ever outstanding on "
        "s_axi, so no read backstop could be under test")
    assert o["coincident_cycles"] == 0, (
        f"CONTROL IS NOT A CONTROL: {o['coincident_cycles']} cycles with a write "
        f"also outstanding (wr_ctr_max={o['wr_ctr_max']}) — it is not the "
        f"read-alone case")
    assert o["synthb_rises"] == 0, (
        f"synth_b_pending fired ({o['synthb_rises']}x) with no write outstanding")
    assert out["cls"] == "ERROR", (
        f"the read-ALONE backstop did not deliver an AHB ERROR (class={out['cls']}, "
        f"err1_rises={o['err1_rises']}, err1_visible={o['err1_visible_cycles']}). "
        f"The vehicle is not producing a rescuable stuck read — the primary N1 "
        f"result would be vacuous.")
    assert o["err1_visible_cycles"] > 0, (
        "read errored but sub_err1_r was never visible at the port")
    dut._log.info("[n1] CONTROL PASS: a stuck read with NO coincident write is "
                  "bounded by a visible 2-cycle AHB ERROR")


# =============================================================================
# PRIMARY — the coincident case.
# =============================================================================
@cocotb.test()
async def test_n1_coincident_stuck_rd_wr_defeats_read_backstop(dut):
    """N1 PRIMARY: a coincident stuck READ + stuck WRITE on the ahb_sub port.

    Vehicle (all through the real RTL paths — no forced handshakes):
      1. stall the far terminus so NOTHING comes back (neither B nor R)
      2. post N_POSTED bufferable/EWR writes in 4KB page 0x40000. XHB500's
         early-write-response releases the AHB master immediately, so they sit
         outstanding on s_axi (sub_wr_os_ctr = N) with the bus free.
      3. issue a blocking read in 4KB page 0x40001 — a DIFFERENT page, so
         XHB500's hazard_list address match does not stall it and the AR is
         accepted onto s_axi (sub_rd_os_r = 1) while the writes are still
         outstanding. That is the coincident state.
      4. let the ONE shared age timer expire on both of them at cycle T.

    ASSERTS
      (a) the coincident state is genuinely entered (rd_os=1 AND wr_ctr!=0 with
          the timer running) — else the test is VACUOUS and says so;
      (b) whether sub_err1_r is suppressed at the master port by
          synth_b_pending;
      (c) whether sub_rd_os_r is cleared unconditionally (cleared on a cycle
          where the ERROR was NOT delivered);
      (d) whether the read EVER subsequently gets an AHB ERROR or any
          completion, across >2^16 further cycles (so a later per-beat stall
          expiry is included, not assumed away)."""
    tb, master = await _bringup(dut)
    m = dut.u_master

    await master.write(ADDR_RD, D_SEED)
    await ClockCycles(dut.hclk, 2000)
    pre = await master.read(ADDR_RD)
    assert pre == D_SEED, f"clean read of ADDR_RD broken before stall: 0x{pre:08x}"

    armed = {"v": False}
    w = N1Watch(dut)
    wt = cocotb.start_soon(w.run(OBSERVE_CYCLES, armed_after=lambda: armed["v"]))

    _set_far_stall(dut, True)
    await ClockCycles(dut.hclk, 20)

    # ── step 2: N posted (EWR) writes, page 0x40000 ──────────────────────────
    posted = 0
    for i in range(N_POSTED):
        try:
            await master.write_bufferable(ADDR_WR + i * 4, 0xC0DE0000 + i, m,
                                          timeout=3000)
            posted += 1
        except (TimeoutError, RuntimeError) as e:
            dut._log.info(f"[n1] posted write {i}: {e}")
    ctr_after_writes = _g(m, "sub_wr_os_ctr")
    osr_after_writes = _g(m, "sub_osr_ctr_r")
    dut._log.info(f"[n1] posted={posted}/{N_POSTED} sub_wr_os_ctr={ctr_after_writes} "
                  f"osr_ctr={osr_after_writes}")

    # ── step 3: the blocking read, DIFFERENT 4KB page ────────────────────────
    out = {}
    armed["v"] = True
    rt = cocotb.start_soon(_read_task(master, ADDR_RD, OBSERVE_CYCLES - 4000, out))

    # (a) the coincidence must actually be entered, with the timer running and
    #     well before the expiry — capture the proof directly.
    coin = None
    for _ in range(4000):
        await RisingEdge(dut.hclk)
        rd, wr = _g(m, "sub_rd_os_r"), _g(m, "sub_wr_os_ctr")
        if rd and wr:
            o1 = _g(m, "sub_osr_ctr_r")
            await ClockCycles(dut.hclk, 4)
            o2 = _g(m, "sub_osr_ctr_r")
            coin = {"rd_os": rd, "wr_ctr": wr, "osr_1": o1, "osr_2": o2,
                    "timer_running": (o2 is not None and o1 is not None and o2 > o1)}
            break
    dut._log.info(f"[n1] COINCIDENCE PROOF: {coin}")

    while "cls" not in out:
        await ClockCycles(dut.hclk, 500)
    await ClockCycles(dut.hclk, 200)
    wt.kill(); rt.kill()
    _set_far_stall(dut, False)
    _release_all(tb)
    o = w.o
    _dump(dut, "N1", o)
    dut._log.info(f"[n1] PRIMARY read class={out['cls']} posted={posted}")

    # ── (a) NON-VACUITY ──────────────────────────────────────────────────────
    assert posted >= 2, (
        f"CANNOT CONSTRUCT: only {posted} bufferable write(s) posted — the EWR "
        f"path is not being exercised, so there is no coincident write")
    assert coin is not None, (
        f"CANNOT CONSTRUCT: sub_rd_os_r and sub_wr_os_ctr!=0 were NEVER "
        f"simultaneously true (rd_os_high_cycles={o['rd_os_high_cycles']}, "
        f"wr_ctr_max={o['wr_ctr_max']}). XHB500 did not issue the AR while the "
        f"posted writes were outstanding — N1's precondition is unreachable from "
        f"this port and the finding is DOWNGRADED. THIS IS NOT A PASS.")
    assert coin["timer_running"], (
        f"the shared age timer was NOT running during the coincident state "
        f"({coin}) — something is resetting sub_osr_ctr_r, so no expiry can occur")
    assert o["coincident_at_expiry"] is True, (
        f"the timer expired but NOT in the coincident state (expiries="
        f"{o['expiries']}). The two backstops did not expire together, so N1's "
        f"step 1 does not hold — DOWNGRADED, not a pass.")

    # ── (b) is the read's ERROR suppressed by synth_b_pending? ───────────────
    suppressed = (o["err1_rises"] > 0 and o["err1_visible_cycles"] == 0)
    dut._log.info(f"[n1] (b) err1_rises={o['err1_rises']} "
                  f"err1_visible={o['err1_visible_cycles']} "
                  f"err2_visible={o['err2_visible_cycles']} -> suppressed={suppressed}")

    # ── (c) was sub_rd_os_r cleared without the ERROR being delivered? ───────
    cleared_undelivered = (o["rd_os_cleared_at"] is not None
                           and not o["rd_os_cleared_at"]["prsp"])
    dut._log.info(f"[n1] (c) rd_os_cleared_at={o['rd_os_cleared_at']} "
                  f"-> cleared_without_error={cleared_undelivered}")

    # ── (d) does the read EVER get an error or a completion afterwards? ──────
    dut._log.info(f"[n1] (d) read class={out['cls']} "
                  f"port_err_pulses={o['port_err_pulses']} "
                  f"hready_high_after_arm={o['hreadyout_high_after_arm']}")

    # THE VERDICT. This assertion FAILS if N1 reproduces — a failing run here is
    # the tapeout blocker, a passing run is the downgrade.
    assert out["cls"] != "HANG", (
        f"N1 REPRODUCED — UNRECOVERABLE HANG.\n"
        f"  coincident state entered at cycle {o['first_coincident']} "
        f"(rd_os=1, wr_ctr={o['wr_ctr_max']}, timer running)\n"
        f"  the shared timer expired IN that state (expiries={o['expiries']})\n"
        f"  sub_err1_r fired {o['err1_rises']}x but was visible at the master "
        f"port on {o['err1_visible_cycles']} cycles (synth_b_pending masks "
        f":1898/:1906)\n"
        f"  sub_rd_os_r was cleared at {o['rd_os_cleared_at']} — with the ERROR "
        f"NOT delivered, so neither :1645 nor :1674 can ever fire for this read "
        f"again\n"
        f"  over the following {OBSERVE_CYCLES} cycles (> the 2^16 per-beat stall "
        f"window) the master saw {len(o['port_err_pulses'])} HRESP pulses and "
        f"hreadyout high on {o['hreadyout_high_after_arm']} cycles: the read "
        f"never completed and never errored.")
    dut._log.info(f"[n1] read was bounded (class={out['cls']}) — N1 does NOT "
                  f"reproduce on this vehicle; see the log for the mechanism")


# =============================================================================
# BACKUP vehicle — construct the coincidence by forcing s_axi_awvalid.
# =============================================================================
@cocotb.test(skip=True)
async def test_n1_forced_aw_coincidence(dut):
    """BACKUP (force-run with TESTCASE=...): same verdict, but the coincident
    write state is built by Forcing s_axi_awvalid rather than by routing real
    posted writes — for the case where the natural route above is shut.

    Forces the VALID, never the READY. Forcing s_axi_awready/s_axi_wready LOW to
    build a stuck state wedges XHB500 unrecoverably (measured 2026-08-13), so a
    test built that way can never show post-recovery behaviour; forcing awvalid
    reaches the same wrapper state (sub_wr_os_ctr increments through the RTL's
    own `sub_aw_accept` term) with the bridge left live.

    Weaker than the primary test — it proves the CONSEQUENCE of the coincident
    state without proving the state is reachable through XHB500. Read the
    primary test for reachability."""
    tb, master = await _bringup(dut)
    m = dut.u_master

    await master.write(ADDR_RD, D_SEED)
    await ClockCycles(dut.hclk, 2000)
    assert (await master.read(ADDR_RD)) == D_SEED, "clean read broken before stall"

    armed = {"v": False}
    w = N1Watch(dut)
    wt = cocotb.start_soon(w.run(OBSERVE_CYCLES, armed_after=lambda: armed["v"]))

    _set_far_stall(dut, True)
    await ClockCycles(dut.hclk, 20)

    out = {}
    armed["v"] = True
    rt = cocotb.start_soon(_read_task(master, ADDR_RD, OBSERVE_CYCLES - 4000, out))

    # wait for the read to be outstanding on s_axi, then manufacture the writes
    got_rd = False
    for _ in range(4000):
        await RisingEdge(dut.hclk)
        if _g(m, "sub_rd_os_r"):
            got_rd = True; break
    assert got_rd, "CANNOT CONSTRUCT: sub_rd_os_r never asserted"

    m.s_axi_awvalid.value = Force(1)
    n = 0
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        if _g(m, "s_axi_awvalid") and _g(m, "s_axi_awready"): n += 1
        if n >= N_POSTED: break
    m.s_axi_awvalid.value = Release()
    await ClockCycles(dut.hclk, 4)
    ctr = _g(m, "sub_wr_os_ctr")
    dut._log.info(f"[n1] FORCED-AW accepts={n} sub_wr_os_ctr={ctr} "
                  f"rd_os={_g(m, 'sub_rd_os_r')}")

    while "cls" not in out:
        await ClockCycles(dut.hclk, 500)
    await ClockCycles(dut.hclk, 200)
    wt.kill(); rt.kill()
    _set_far_stall(dut, False)
    _release_all(tb)
    o = w.o
    _dump(dut, "FORCED-AW", o)

    assert ctr and ctr > 0, (
        f"CANNOT CONSTRUCT: forcing s_axi_awvalid did not raise sub_wr_os_ctr "
        f"(accepts={n}, ctr={ctr})")
    assert o["coincident_cycles"] > 0, "CANNOT CONSTRUCT: never coincident"
    assert out["cls"] != "HANG", (
        f"N1 REPRODUCED on the forced-AW vehicle: coincident stuck read + "
        f"outstanding write => err1_rises={o['err1_rises']} "
        f"err1_visible={o['err1_visible_cycles']} rd_os_cleared_at="
        f"{o['rd_os_cleared_at']} and the read NEVER completed or errored.")

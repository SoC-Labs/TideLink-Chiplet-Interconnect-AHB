"""TL-045 — CROSS-DIE EXCLUSIVES: refused loudly, never silently executed.

THE DEFECT THIS FILE USED TO DOCUMENT (rev2/integration and earlier)
    Two initiators could both complete a store-exclusive to the same cross-die
    address:

        A: read  X       "LDREX"
        B: read  X       "LDREX"   (breaks A's reservation)
        B: write X = D_B "STREX"
        A: write X = D_A "STREX"   -- a global monitor would REJECT this

    BOTH stores committed, BOTH were answered OKAY, and the far memory ended up
    holding A's value. Software using cross-die exclusives for mutual exclusion
    had no mutual exclusion AND no indication that it had none. Measured; the
    log line is preserved in the commit that introduced TL-045.

    Three independent breaks produced it, all in the integration (Wlink itself
    carries axlock as AW/AR payload bit 13, AXI4ToWlink.v:454/473):
      * tidelink_top's AHB subordinate port had no HEXCL and no HEXOKAY pin, so
        the marker was gone at TideLink's own pins;
      * u_xhb_sub .hexcl(1'b0) forced awlock/arlock to 0 for EVERY outbound
        transaction (core_addr.sv:253/268) -- the exclusive did not merely go
        unanswered across the boundary, IT NEVER CROSSED IT;
      * u_xhb_mng .hexokay(1'b0) makes AXI_RESP_EXOKAY unreachable inbound
        (core_h_xout.sv:180).

WHAT TL-045 DOES, AND WHY IT IS A REFUSAL AND NOT A REPAIR
    tidelink_top now has ahb_sub_hexcl (in) and ahb_sub_hexokay (out, constant
    0). A transfer presented with HEXCL high is:
      * NEVER ISSUED  -- xhb_sub_hsel is gated, so XHB500 never latches it,
        nothing reaches the link, and PEER MEMORY IS NOT MODIFIED;
      * ANSWERED with a two-cycle AHB ERROR on ahb_sub_hresp;
      * ANSWERED with ahb_sub_hexokay = 0.

    Supporting exclusives properly was evaluated and rejected: it needs a GLOBAL
    EXCLUSIVE MONITOR at the far terminus (there is none, and tidelink_top's
    ahb_mng port has no HEXOKAY pin to reach one), and it needs a per-initiator
    AxID, which collides with the Fix K hazard-list BID override that keeps
    die_a's PS alive. The full argument is in the TL-045 block in
    src/rtl/tidelink_top.sv. A granted-but-unmonitored exclusive would be WORSE
    than the original defect, because software would then trust it.

WHAT THIS FILE PROVES
    test_xdie_exclusive_is_refused
        one exclusive read and one exclusive write are ERRORed, no AR/AW leaves
        the die for either, and the far memory is untouched.
    test_xdie_two_initiators_cannot_both_commit
        THE CONTROL FOR THE DEFECT. The exact four-transaction sequence above,
        with HEXCL asserted: all four ERROR, nothing crosses, and the far memory
        still holds the seed. Pre-fix this same sequence left D_A there.
    test_xdie_ordinary_traffic_unaffected
        the same four transactions with HEXCL LOW still behave exactly as they
        did before TL-045 (both stores commit, far memory holds A's value). The
        refusal is caused by the marker, not by the existence of the new logic.
    test_xdie_prefix_control_double_commit_returns
        RUNS ONLY IN THE MUTANT BUILD (+define+TIDELINK_XDIE_EXCL_LEGACY_MUTANT,
        `make xdie_exclusive_redproof`). It asserts the PRE-FIX behaviour
        POSITIVELY -- the double commit comes back. This is the "the control
        must FAIL without the fix" obligation, discharged as a positive
        assertion rather than an inverted exit code, so a broken build cannot
        masquerade as a red proof.

INSTRUMENT BEFORE DUT
    Every negative measurement here ("no AR left the die", "the far memory did
    not change") is preceded, in the SAME simulation, by a positive one that
    uses the SAME observer:
      * a SENTINEL write proves _slave_bram_peek reports what was written, so
        "the memory did not change" is falsifiable;
      * an ORDINARY (non-exclusive) cross-die read+write proves the AR/AW
        observers count, so "no AR was issued" is falsifiable;
      * each test reads dut.u_master.excl_enforce and requires it to be the
        value its build is supposed to have, so a test can never pass because
        it silently ran against the other build.

    A monitor artefact was caught here during the original investigation and the
    guard is kept: u_xhb_mng.hexcl is a payload-register field on an output left
    UNCONNECTED at tidelink_top.sv, so it HOLDS its last value between
    transfers. It is sampled only in an AHB address phase.

  make -C cocotb/tidelink_axi_datanode_recovery xdie_exclusive
  make -C cocotb/tidelink_axi_datanode_recovery xdie_exclusive_redproof
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)

# ALL THREE must be inside the peer BRAM window that _slave_bram_peek indexes
# (dut.u_s_mng_bram.mem is 1024 words = offsets 0x000..0xFFC). A peek outside it
# returns None, which the sentinel then reports as COULD-NOT-EVALUATE rather than
# as a result -- MEASURED: the first version of this file used 0x1780 and got
# "Invalid Index - Index 1504 is not in the range of [0:1023]".
OFF_X    = 0x300      # the contended cross-die address
OFF_CTL  = 0x800      # a different page, used by the ordinary-traffic control
OFF_ORD  = 0xB00      # a third page, for the ordinary-traffic regression arm
D_SEED   = 0x0000_0BAD
D_A      = 0x1111_AAAA
D_B      = 0x2222_BBBB
D_CTL    = 0x3333_CCCC

TIMEOUT = 60000


def _g(obj, name, default=None):
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return default


def _present(obj, name):
    try:
        getattr(obj, name).value
        return True
    except Exception:
        return False


class ExclMaster(AHBSubMaster):
    """AHBSubMaster that can raise HEXCL in the address phase.

    HEXCL is held for the whole call rather than pulsed exactly across the
    address phase. That is equivalent and race-free: the refusal term in the
    RTL is `ahb_sub_hsel & ahb_sub_htrans[1] & ahb_sub_hexcl`, so while HSEL is
    low (every cycle of the data phase, because the parent drops HSEL after the
    address phase) HEXCL cannot select anything. idle() drops it again.
    """

    def __init__(self, dut):
        self.hexcl = dut.m_ahb_sub_hexcl
        self.hexokay = dut.m_ahb_sub_hexokay
        self._excl = False
        super().__init__(dut)

    def idle(self):
        super().idle()
        try:
            self.hexcl.value = 0
        except Exception:
            pass

    async def _run(self, addr, write, wdata, timeout):
        self.hexcl.value = 1 if self._excl else 0
        return await super()._run(addr, write, wdata, timeout)

    async def excl_write(self, addr, data, timeout=TIMEOUT):
        self._excl = True
        try:
            return await self.write(addr, data, timeout=timeout)
        finally:
            self._excl = False

    async def excl_read(self, addr, timeout=TIMEOUT):
        self._excl = True
        try:
            return await self.read(addr, timeout=timeout)
        finally:
            self._excl = False


class LockMon:
    """Records (AxLOCK, AxID) for every AW/AR accepted on the OUTBOUND AXI port
    of the near die, the far die's inbound AxLOCK, the far AHB manager's
    exclusive marker, and the master-facing HEXOKAY."""

    def __init__(self, dut):
        self.dut = dut
        self.near = dut.u_master              # this die: AHB in, AXI out
        self.far = dut.u_slave                # peer die: AXI in, AHB out
        try:
            self.sub = dut.u_master.u_xhb_sub
        except Exception:
            self.sub = None
        try:
            self.mng = dut.u_slave.u_xhb_mng
        except Exception:
            self.mng = None
        self.taps = {
            "near.s_axi_arvalid": _present(self.near, "s_axi_arvalid"),
            "near.s_axi_awvalid": _present(self.near, "s_axi_awvalid"),
            "near.s_axi_arlock": _present(self.near, "s_axi_arlock"),
            "near.s_axi_awlock": _present(self.near, "s_axi_awlock"),
            "near.excl_err1_r": _present(self.near, "excl_err1_r"),
            "near.excl_err2_r": _present(self.near, "excl_err2_r"),
            "near.excl_refused_sticky": _present(self.near,
                                                 "excl_refused_sticky"),
            "near.excl_inbound_sticky": _present(self.near,
                                                 "excl_inbound_sticky"),
            "far.m_axi_arlock": _present(self.far, "m_axi_arlock"),
            "far.m_axi_awlock": _present(self.far, "m_axi_awlock"),
            "far.ahb_mng_htrans": _present(self.far, "ahb_mng_htrans"),
            "mng.hexcl": _present(self.mng, "hexcl"),
            "mng.hexokay": _present(self.mng, "hexokay"),
            "dut.m_ahb_sub_hexcl": _present(dut, "m_ahb_sub_hexcl"),
            "dut.m_ahb_sub_hexokay": _present(dut, "m_ahb_sub_hexokay"),
        }
        self.reset()

    def missing(self):
        return sorted(k for k, v in self.taps.items() if not v)

    def reset(self):
        self.ar = []          # (arlock, arid) per accepted AR, near die
        self.aw = []          # (awlock, awid) per accepted AW, near die
        self.far_lock_high = 0
        self.mng_aphase = 0
        self.mng_hexcl_high = 0
        self.mng_hexokay_high = 0
        self.excl_err_fires = 0
        self.hexokay_high = 0
        self.cycles = 0
        self._prev_e1 = 0

    async def run(self, cycles):
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            self.cycles += 1
            if _g(self.near, "s_axi_arvalid", 0) and _g(self.near, "s_axi_arready", 0):
                self.ar.append((_g(self.near, "s_axi_arlock", -1),
                                _g(self.near, "s_axi_arid", -1)))
            if _g(self.near, "s_axi_awvalid", 0) and _g(self.near, "s_axi_awready", 0):
                self.aw.append((_g(self.near, "s_axi_awlock", -1),
                                _g(self.near, "s_axi_awid", -1)))
            e1 = _g(self.near, "excl_err1_r", 0)
            if e1 and not self._prev_e1:
                self.excl_err_fires += 1
            self._prev_e1 = e1
            if _g(self.dut, "m_ahb_sub_hexokay", 0):
                self.hexokay_high += 1
            # QUALIFIED. u_xhb_mng.hexcl is a payload-register field on an
            # UNCONNECTED output: it holds the last transfer's value between
            # transfers, so an unqualified count reports the previous
            # transaction's exclusivity for hundreds of idle cycles (MEASURED --
            # the first version of this file counted 641 such cycles). Sample it
            # only in an AHB address phase, where it is the signal it claims.
            if (_g(self.far, "m_axi_arvalid", 0) and _g(self.far, "m_axi_arlock", 0)) \
               or (_g(self.far, "m_axi_awvalid", 0) and _g(self.far, "m_axi_awlock", 0)):
                self.far_lock_high += 1
            if (_g(self.far, "ahb_mng_htrans", 0) or 0) & 0b10:
                self.mng_aphase += 1
                if _g(self.mng, "hexcl", 0):
                    self.mng_hexcl_high += 1
            if _g(self.mng, "hexokay", 0):
                self.mng_hexokay_high += 1

    def s(self):
        return dict(cycles=self.cycles, ar=self.ar, aw=self.aw,
                    far_lock_high=self.far_lock_high,
                    mng_aphase=self.mng_aphase,
                    mng_hexcl_high=self.mng_hexcl_high,
                    mng_hexokay_high=self.mng_hexokay_high,
                    excl_err_fires=self.excl_err_fires,
                    hexokay_high=self.hexokay_high)


def _require_build(dut, enforce_expected):
    """Read the RTL's own policy bit and require it to match the build this
    test belongs to.

    Without this, the shipping tests would PASS unchanged in the mutant build if
    they ever stopped depending on the fix, and the red proof would PASS in the
    shipping build. It is the cheapest possible guard against testing the wrong
    binary, which is a repeat failure mode in this repository (stale simv)."""
    assert _present(dut.u_master, "excl_enforce"), (
        "COULD-NOT-EVALUATE — dut.u_master.excl_enforce does not resolve. It is "
        "the TL-045 policy bit; without it this test cannot tell which build it "
        "is running against.")
    got = int(dut.u_master.excl_enforce.value)
    if enforce_expected:
        need = ("This test needs the SHIPPING build (no "
                "TIDELINK_XDIE_EXCL_LEGACY_MUTANT define).")
    else:
        need = ("This test needs the MUTANT build "
                "(+define+TIDELINK_XDIE_EXCL_LEGACY_MUTANT); it is a red proof "
                "and is meaningless against the fixed RTL.")
    assert got == enforce_expected, (
        f"WRONG BUILD — excl_enforce reads {got}, expected "
        f"{enforce_expected}. {need}")


def _pin_presence(dut):
    """The pins TL-045 added must EXIST, checked against a must-be-present
    control so the presence check can itself fail."""
    assert _present(dut.u_master, "ahb_sub_hwrite"), (
        "COULD-NOT-EVALUATE — the port-presence check cannot see a port that "
        "definitely exists, so its results prove nothing")
    for pin in ("ahb_sub_hexcl", "ahb_sub_hexokay"):
        assert _present(dut.u_master, pin), (
            f"tidelink_top has no {pin} pin. TL-045 is not present in this "
            f"build and every result below is about different RTL.")


async def _ordinary_traffic_control(dut, master, mon):
    """MANDATORY, and it replaces the old forced-hexcl control.

    Drive one ORDINARY (non-exclusive) cross-die write+read and require the
    AR/AW observers to count them. Without this, "no AR was issued for the
    exclusive" is equally consistent with an observer that is simply dead --
    the single most expensive class of false green in this repository. Nothing
    is forced: the control uses the same driver and the same observers as the
    measurement."""
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    await master.write(APER_BASE + OFF_CTL, D_CTL, timeout=TIMEOUT)
    got = await master.read(APER_BASE + OFF_CTL, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 200)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] ORDINARY-TRAFFIC CONTROL: {s} got=0x{got:08x}")
    assert got == D_CTL, \
        f"COULD-NOT-EVALUATE — the control read failed (0x{got:08x})"
    assert s["ar"], (
        "COULD-NOT-EVALUATE — an ORDINARY cross-die read produced no AR at the "
        "observer. The AR observer is dead, and 'the exclusive produced no AR' "
        "below would be meaningless.")
    assert s["aw"], (
        "COULD-NOT-EVALUATE — an ORDINARY cross-die write produced no AW at the "
        "observer. The AW observer is dead.")
    assert s["excl_err_fires"] == 0, (
        f"ORDINARY traffic tripped the TL-045 refusal {s['excl_err_fires']} "
        f"time(s). The refusal must key on HEXCL and nothing else.")
    return s


async def _sentinel(dut, master):
    """The far-memory observer must report what was written, or 'the memory did
    not change' is unfalsifiable."""
    await master.write(APER_BASE + OFF_X, D_SEED, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 3000)
    seed = _slave_bram_peek(dut, OFF_X)
    assert seed == D_SEED, (
        f"COULD-NOT-EVALUATE — the far-memory observer read 0x{(seed or 0):08x} "
        f"after a write of 0x{D_SEED:08x}; every 'the memory did not change' "
        f"below would be unfalsifiable.")
    return seed


@cocotb.test()
async def test_xdie_exclusive_is_refused(dut):
    """A single cross-die exclusive is ERRORed and never issued.

      (a) the TL-045 pins exist (with a must-be-present control);
      (b) an exclusive READ and an exclusive WRITE each raise HRESP=ERROR;
      (c) neither produces an AR or an AW on the outbound AXI port -- nothing
          crossed the die -- while an ORDINARY read+write through the SAME
          observers does produce them;
      (d) the far memory still holds the seed after the exclusive write;
      (e) ahb_sub_hexokay is never high, and no exclusive marker or EXOKAY
          appears on the far die.
    """
    tb, master0 = await _bringup(dut)
    _require_build(dut, 1)
    _pin_presence(dut)
    master = ExclMaster(dut)
    mon = LockMon(dut)
    missing = mon.missing()
    dut._log.info(f"[xdie] taps: {mon.taps}")
    assert not missing, f"COULD-NOT-EVALUATE — these taps do not resolve: {missing}"

    await _sentinel(dut, master)

    # THE MEASUREMENT.
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    outcomes = {}
    try:
        outcomes["excl_read"] = await master.excl_read(APER_BASE + OFF_X)
    except RuntimeError:
        outcomes["excl_read"] = "ERROR"
    except TimeoutError:
        outcomes["excl_read"] = "HANG"
    try:
        await master.excl_write(APER_BASE + OFF_X, D_A)
        outcomes["excl_write"] = "OK"
    except RuntimeError:
        outcomes["excl_write"] = "ERROR"
    except TimeoutError:
        outcomes["excl_write"] = "HANG"
    await ClockCycles(dut.hclk, 3000)
    after = _slave_bram_peek(dut, OFF_X)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] EXCLUSIVE REFUSAL: outcomes={outcomes} "
                  f"far_mem=0x{(after or 0):08x} {s}")

    # THE CONTROL, in the same simulation, through the same observers.
    ctl = await _ordinary_traffic_control(dut, master, mon)
    _release_all(tb)

    assert outcomes["excl_read"] == "ERROR", (
        f"an exclusive cross-die READ was not ERRORed: {outcomes}. TL-045 "
        f"requires a loud refusal, not a silent ordinary access.")
    assert outcomes["excl_write"] == "ERROR", (
        f"an exclusive cross-die WRITE was not ERRORed: {outcomes}. This is the "
        f"one that matters: an unrefused exclusive write COMMITS.")
    assert s["excl_err_fires"] == 2, (
        f"expected exactly 2 refusals (one read, one write), got "
        f"{s['excl_err_fires']}: {s}")
    assert s["ar"] == [] and s["aw"] == [], (
        f"a refused exclusive still reached the outbound AXI port "
        f"(ar={s['ar']} aw={s['aw']}) — it must never be issued. The ordinary "
        f"control through these same observers saw ar={ctl['ar']} "
        f"aw={ctl['aw']}, so they are alive.")
    assert after == D_SEED, (
        f"THE EXCLUSIVE WRITE MODIFIED PEER MEMORY (0x{(after or 0):08x} != "
        f"0x{D_SEED:08x}). A refused store-exclusive that still writes is worse "
        f"than the defect TL-045 replaced.")
    assert s["hexokay_high"] == 0, (
        f"ahb_sub_hexokay went high for {s['hexokay_high']} cycles; this "
        f"subordinate must never grant an exclusive")
    assert s["far_lock_high"] == 0, \
        f"the peer die saw AxLOCK high for {s['far_lock_high']} cycles: {s}"
    assert s["mng_hexcl_high"] == 0, \
        f"an exclusive marker appeared on the far AHB manager: {s}"
    assert s["mng_hexokay_high"] == 0, \
        f"EXOKAY appeared on the far die: {s}"
    assert int(dut.u_master.excl_refused_sticky.value) == 1, \
        "obs 0x21F8 bit[15] (excl_refused_sticky) did not latch a real refusal"
    assert int(dut.u_master.excl_inbound_sticky.value) == 0, (
        "obs 0x21F8 bit[16] (excl_inbound_sticky) latched: the peer die emitted "
        "AxLOCK=1 at us, which TL-045's analysis says is unreachable on a "
        "TideLink<->TideLink pair. The inbound block is then a real work item.")


@cocotb.test()
async def test_xdie_two_initiators_cannot_both_commit(dut):
    """THE CONTROL FOR THE DEFECT — the exact four-transaction sequence.

        A: LDREX X
        B: LDREX X    (breaks A's reservation)
        B: STREX X = D_B
        A: STREX X = D_A   -- a global monitor would reject this

    Both initiators reach TideLink through its single AHB subordinate port,
    which is how they arrive in silicon.

    PRE-FIX: all four completed, both stores committed, far memory held D_A.
    POST-FIX: all four are ERRORed, nothing crosses the die, and the far memory
    still holds the seed — the mutual-exclusion violation is no longer
    reachable and its absence is no longer silent.
    """
    tb, master0 = await _bringup(dut)
    _require_build(dut, 1)
    _pin_presence(dut)
    master = ExclMaster(dut)
    mon = LockMon(dut)
    assert not mon.missing(), f"COULD-NOT-EVALUATE — taps missing: {mon.missing()}"

    await _sentinel(dut, master)

    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    outcomes = {}

    async def op(name, write, data=0):
        try:
            if write:
                await master.excl_write(APER_BASE + OFF_X, data)
                outcomes[name] = "OK"
            else:
                outcomes[name] = await master.excl_read(APER_BASE + OFF_X)
        except RuntimeError:
            outcomes[name] = "ERROR"
        except TimeoutError:
            outcomes[name] = "HANG"

    await op("A_ldrex", False)
    await op("B_ldrex", False)
    await op("B_strex", True, D_B)
    await ClockCycles(dut.hclk, 3000)
    after_b = _slave_bram_peek(dut, OFF_X)
    await op("A_strex", True, D_A)
    await ClockCycles(dut.hclk, 3000)
    final = _slave_bram_peek(dut, OFF_X)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] TWO INITIATORS (post-TL-045): outcomes={outcomes} "
                  f"after_B=0x{(after_b or 0):08x} final=0x{(final or 0):08x} {s}")

    ctl = await _ordinary_traffic_control(dut, master, mon)
    _release_all(tb)

    assert all(v == "ERROR" for v in outcomes.values()), (
        f"not every exclusive was refused: {outcomes}. Any transaction that is "
        f"not ERRORed here is one software can mistake for a working exclusive.")
    assert s["excl_err_fires"] == 4, \
        f"expected 4 refusals, got {s['excl_err_fires']}: {s}"
    assert s["ar"] == [] and s["aw"] == [], (
        f"a refused exclusive reached the outbound AXI port (ar={s['ar']} "
        f"aw={s['aw']}). The ordinary control saw ar={ctl['ar']} aw={ctl['aw']}.")
    assert after_b == D_SEED, (
        f"B's store-exclusive COMMITTED (0x{(after_b or 0):08x}) despite being "
        f"refused")
    assert final == D_SEED, (
        f"DOUBLE EXCLUSIVE IS STILL REACHABLE: the far memory holds "
        f"0x{(final or 0):08x}, not the untouched seed 0x{D_SEED:08x}. A store "
        f"a global monitor would have rejected has modified peer memory.")
    assert s["hexokay_high"] == 0, \
        f"ahb_sub_hexokay went high for {s['hexokay_high']} cycles"
    assert s["mng_hexcl_high"] == 0 and s["mng_hexokay_high"] == 0, \
        f"an exclusive marker or EXOKAY appeared on the far die: {s}"
    assert int(dut.u_master.excl_inbound_sticky.value) == 0, \
        "obs bit[16]: the peer die emitted an inbound exclusive at us"


@cocotb.test()
async def test_xdie_ordinary_traffic_unaffected(dut):
    """REGRESSION GUARD — the refusal keys on HEXCL and on nothing else.

    The SAME four transactions to the SAME address with HEXCL LOW must behave
    exactly as they did before TL-045: all four complete, both stores commit,
    and the far memory ends up holding A's value. If this test ever fails, the
    refusal has leaked into ordinary cross-die traffic, which is every cross-die
    access this design makes.

    It is also the honest statement of what TL-045 does NOT do: an ORDINARY
    read-modify-write pair still races, because it was never exclusive. TL-045
    removes the silence, not the need for a real lock.
    """
    tb, master0 = await _bringup(dut)
    _require_build(dut, 1)
    master = ExclMaster(dut)
    mon = LockMon(dut)
    assert not mon.missing(), f"COULD-NOT-EVALUATE — taps missing: {mon.missing()}"

    await master.write(APER_BASE + OFF_ORD, D_SEED, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 3000)
    seed = _slave_bram_peek(dut, OFF_ORD)
    assert seed == D_SEED, (
        f"COULD-NOT-EVALUATE — far-memory observer read 0x{(seed or 0):08x}")

    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    outcomes = {}

    async def op(name, write, data=0):
        try:
            if write:
                await master.write(APER_BASE + OFF_ORD, data, timeout=TIMEOUT)
                outcomes[name] = "OK"
            else:
                outcomes[name] = await master.read(APER_BASE + OFF_ORD,
                                                   timeout=TIMEOUT)
        except RuntimeError:
            outcomes[name] = "ERROR"
        except TimeoutError:
            outcomes[name] = "HANG"

    await op("A_read", False)
    await op("B_read", False)
    await op("B_write", True, D_B)
    await ClockCycles(dut.hclk, 3000)
    await op("A_write", True, D_A)
    await ClockCycles(dut.hclk, 3000)
    final = _slave_bram_peek(dut, OFF_ORD)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] ORDINARY (HEXCL low): outcomes={outcomes} "
                  f"final=0x{(final or 0):08x} {s}")
    _release_all(tb)

    assert outcomes["A_read"] == D_SEED and outcomes["B_read"] == D_SEED, \
        f"an ordinary cross-die read broke: {outcomes}"
    assert outcomes["B_write"] == "OK" and outcomes["A_write"] == "OK", (
        f"TL-045 ERRORed ORDINARY cross-die traffic: {outcomes}. The refusal "
        f"has leaked past HEXCL and every cross-die access is now failing.")
    assert s["excl_err_fires"] == 0, \
        f"the TL-045 refusal fired {s['excl_err_fires']} times with HEXCL LOW"
    assert len(s["ar"]) == 2 and len(s["aw"]) == 2, \
        f"expected 2 AR + 2 AW for ordinary traffic, got {s}"
    assert final == D_A, (
        f"ordinary cross-die traffic no longer behaves as before TL-045: far "
        f"memory holds 0x{(final or 0):08x}, expected A's value 0x{D_A:08x}")


@cocotb.test()
async def test_xdie_prefix_control_double_commit_returns(dut):
    """RED PROOF. Runs ONLY in the mutant build; asserts the DEFECT positively.

        make -C cocotb/tidelink_axi_datanode_recovery xdie_exclusive_redproof

    With +define+TIDELINK_XDIE_EXCL_LEGACY_MUTANT the refusal is compiled out
    (excl_enforce == 0) and the RTL is bit-identical to pre-TL-045 on this path.
    The same four transactions, with HEXCL ASSERTED, must then reproduce the
    original defect: all four complete, both stores commit, and the far memory
    holds A's value.

    This is a POSITIVE assertion of the old behaviour, not an inverted exit
    code, so a build that simply fails to compile or fails to bring up cannot
    masquerade as a red proof.
    """
    tb, master0 = await _bringup(dut)
    _require_build(dut, 0)
    _pin_presence(dut)
    master = ExclMaster(dut)
    mon = LockMon(dut)
    assert not mon.missing(), f"COULD-NOT-EVALUATE — taps missing: {mon.missing()}"

    await _sentinel(dut, master)

    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    outcomes = {}

    async def op(name, write, data=0):
        try:
            if write:
                await master.excl_write(APER_BASE + OFF_X, data)
                outcomes[name] = "OK"
            else:
                outcomes[name] = await master.excl_read(APER_BASE + OFF_X)
        except RuntimeError:
            outcomes[name] = "ERROR"
        except TimeoutError:
            outcomes[name] = "HANG"

    await op("A_ldrex", False)
    await op("B_ldrex", False)
    await op("B_strex", True, D_B)
    await ClockCycles(dut.hclk, 3000)
    after_b = _slave_bram_peek(dut, OFF_X)
    await op("A_strex", True, D_A)
    await ClockCycles(dut.hclk, 3000)
    final = _slave_bram_peek(dut, OFF_X)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] RED PROOF (mutant, pre-TL-045): outcomes={outcomes} "
                  f"after_B=0x{(after_b or 0):08x} final=0x{(final or 0):08x} {s}")
    _release_all(tb)

    assert outcomes["A_ldrex"] == D_SEED and outcomes["B_ldrex"] == D_SEED, (
        f"COULD-NOT-EVALUATE — the two load-exclusives did not both read the "
        f"seed: {outcomes}. The mutant build is not reproducing the pre-fix "
        f"path, so it proves nothing about the fix.")
    assert outcomes["B_strex"] == "OK" and outcomes["A_strex"] == "OK", (
        f"COULD-NOT-EVALUATE — a store was not answered OKAY in the MUTANT "
        f"build: {outcomes}. The pre-fix behaviour is that both succeed "
        f"silently; if they do not, this is not the pre-fix RTL.")
    assert s["excl_err_fires"] == 0, \
        f"the refusal fired in the mutant build ({s['excl_err_fires']}): {s}"
    assert len(s["ar"]) == 2 and len(s["aw"]) == 2, (
        f"COULD-NOT-EVALUATE — the mutant build did not issue 2 AR + 2 AW: {s}")
    assert s["ar"] == [(0, 0), (0, 0)] and s["aw"] == [(0, 0), (0, 0)], (
        f"the two initiators were distinguishable on the cross-die AXI port "
        f"(ar={s['ar']} aw={s['aw']}); pre-fix, .hexcl(1'b0)/.hmaster(12'd0) "
        f"make them identical.")
    assert after_b == D_B, (
        f"COULD-NOT-EVALUATE — B's store did not land in the mutant build "
        f"(0x{(after_b or 0):08x}); 'A overwrote B' cannot be concluded from a "
        f"store that never happened.")
    assert final == D_A, (
        f"THE RED PROOF DID NOT REPRODUCE THE DEFECT: with the TL-045 refusal "
        f"compiled out, B's committed store (0x{D_B:08x}) was expected to be "
        f"silently overwritten by A's (0x{D_A:08x}), but the far memory holds "
        f"0x{(final or 0):08x}. Either the mutant is not the pre-fix RTL or the "
        f"post-fix tests are passing for some reason other than the fix — "
        f"EITHER WAY THE GREEN ONES ARE NOT EVIDENCE.")

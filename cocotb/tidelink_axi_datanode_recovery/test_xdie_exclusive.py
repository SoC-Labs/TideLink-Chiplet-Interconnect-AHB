"""CROSS-DIE EXCLUSIVES — what an AXI exclusive actually does over the link.

THE QUESTION FOR REV 2
    Can two initiators both believe they hold an exclusive on the same
    cross-die address?

WHAT WAS ALREADY ESTABLISHED
    src/rtl/tidelink_top.sv:3319 ties u_xhb_mng.hexokay to 1'b0, so the INBOUND
    bridge can never produce AXI_RESP_EXOKAY (core_h_xout.sv:180), and
    src/rtl/tidelink_top.sv:3169 ties u_xhb_sub.hmastlock to 1'b0, so
    RESP_FSM_LOCK_ERROR is dead as integrated.  Both are asserted at the bridge
    pins by cocotb/xhb500_bridge/test_xhb500_bridge.py.

WHAT THIS FILE ADDS — the break is EARLIER and HARDER than that
    Two more integration constants decide the answer before the response path
    is ever reached:

      src/rtl/tidelink_top.sv:3171   .hexcl   (1'b0)    on u_xhb_sub
      src/rtl/tidelink_top.sv:3172   .hmaster (12'd0)   on u_xhb_sub

    core_addr.sv:253/268 assign awlock/arlock = cntrl_2_out.hexcl, and
    core_addr.sv:248/263 assign awid/arid = cntrl_2_out.hmaster.  So every
    outbound transaction leaves this die as (AxLOCK=0, AxID=0).  The exclusive
    marker does not merely go unanswered across the die boundary — IT NEVER
    CROSSES IT, and every initiator is bit-identical on the wire.

    And tidelink_top's own AHB subordinate port has no HEXCL and no HEXOKAY pin
    at all (src/rtl/tidelink_top.sv:273-284), so an AHB5 manager's exclusive
    marker is already gone at TideLink's pins, one level above the tie-off.

    Wlink itself is NOT the problem: AXI4ToWlink.v:454/473 carries axlock as
    bit 13 of the AW/AR payload, so a wired exclusive WOULD cross the link.
    Every break is in the integration.

CONSEQUENCE, DEMONSTRATED HERE
    A cross-die "exclusive" sequence executes as an ORDINARY read followed by
    an ORDINARY write.  The store is committed unconditionally.  No monitor
    exists anywhere on the path, so nothing can break anyone's reservation and
    nothing can report that one was broken.  Two initiators therefore both
    complete their store-exclusive to the same address, both are answered
    OKAY, and the second store silently overwrites the first.

    Any software using cross-die exclusives for mutual exclusion has no mutual
    exclusion.  Because the only monitor left in the system is each
    initiator's own LOCAL monitor, and local monitors cannot observe each
    other, both initiators' STREX report success.

INSTRUMENT BEFORE DUT
    Every "it is 0" measurement in this file is preceded, in the SAME
    simulation, by forcing the tie-off input to 1 and showing the observer
    reads 1.  An AxLOCK observer that is simply dead would otherwise report
    exactly the result this file concludes from.

RED PROOF
    MX1  src/rtl/tidelink_top.sv  .hexcl (1'b0) -> (1'b1) on u_xhb_sub
         -> BOTH tests FAIL.  tidelink_top.sv was restored and `git diff
         --quiet` verified clean afterwards.
    Each test additionally carries its own in-run instrument control (hexcl
    FORCED high), which is the stronger statement: every observer this file
    concludes a 0 from is shown reading 1 in the same simulation — the near
    AxLOCK/AxID, the peer die's inbound AxLOCK, and the far AHB manager's
    HEXCL.

    A monitor artefact was caught and fixed here too: u_xhb_mng.hexcl is a
    payload-register field on an output left UNCONNECTED at tidelink_top.sv:3313,
    so it HOLDS its last value between transfers.  An unqualified count
    attributed 641 idle cycles of the forced control's exclusivity to the
    shipping measurement that followed it.  It is now sampled only in an AHB
    address phase, and the shipping measurement runs BEFORE the forced control.

  make -C cocotb/tidelink_axi_datanode_recovery xdie_exclusive
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)

OFF_X    = 0x300      # the contended cross-die address
OFF_CTL  = 0x1340     # a different 4KB page, used by the instrument control
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


class LockMon:
    """Records (AxLOCK, AxID) for every AW/AR accepted on the OUTBOUND AXI port
    of the near die, and the far die's inbound AxLOCK, and every cycle in which
    an exclusive marker or an EXOKAY appears anywhere on the path."""

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
            "near.s_axi_arlock": _present(self.near, "s_axi_arlock"),
            "near.s_axi_awlock": _present(self.near, "s_axi_awlock"),
            "near.s_axi_arid": _present(self.near, "s_axi_arid"),
            "near.s_axi_awid": _present(self.near, "s_axi_awid"),
            "far.m_axi_arlock": _present(self.far, "m_axi_arlock"),
            "far.m_axi_awlock": _present(self.far, "m_axi_awlock"),
            "far.ahb_mng_htrans": _present(self.far, "ahb_mng_htrans"),
            "sub.hexcl": _present(self.sub, "hexcl"),
            "sub.hmaster": _present(self.sub, "hmaster"),
            "mng.hexcl": _present(self.mng, "hexcl"),
            "mng.hexokay": _present(self.mng, "hexokay"),
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
        self.cycles = 0

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
            # QUALIFIED, both of them. u_xhb_mng.hexcl is a payload-register
            # field on an UNCONNECTED output (tidelink_top.sv:3313): it holds
            # the last transfer's value between transfers, so an unqualified
            # count reports the previous transaction's exclusivity for hundreds
            # of idle cycles. MEASURED, not guessed -- the first run of this
            # file counted 641 such cycles that all belonged to the forced
            # instrument control that had run before it. Sample it only in an
            # AHB address phase, where it is the signal it claims to be.
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
                    mng_hexokay_high=self.mng_hexokay_high)


async def _instrument_control(dut, master, mon):
    """MANDATORY. Force the tie-off input HIGH for one cross-die read and
    require the AxLOCK observer to read 1.

    Without this, every "AxLOCK was 0" verdict below is equally consistent with
    an observer that is simply dead — the single most expensive class of false
    green in this repository. Nothing else in this file forces anything."""
    dut.u_master.u_xhb_sub.hexcl.value = Force(1)
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    await master.write(APER_BASE + OFF_CTL, D_CTL, timeout=TIMEOUT)
    got = await master.read(APER_BASE + OFF_CTL, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 200)
    t.kill()
    dut.u_master.u_xhb_sub.hexcl.value = Release()
    await ClockCycles(dut.hclk, 50)
    s = mon.s()
    dut._log.info(f"[xdie] INSTRUMENT CONTROL (hexcl forced 1): {s} got=0x{got:08x}")
    assert got == D_CTL, \
        f"COULD-NOT-EVALUATE — the control read failed (0x{got:08x})"
    assert s["ar"] and all(l == 1 for l, _ in s["ar"]), (
        f"COULD-NOT-EVALUATE — with hexcl FORCED HIGH the AxLOCK observer still "
        f"read 0 ({s['ar']}). The observer is dead, and every 'AxLOCK was 0' "
        f"result in this file would be meaningless.")
    assert s["aw"] and all(l == 1 for l, _ in s["aw"]), (
        f"COULD-NOT-EVALUATE — AWLOCK observer read 0 with hexcl forced high "
        f"({s['aw']})")
    assert s["far_lock_high"] > 0, (
        f"COULD-NOT-EVALUATE — with hexcl forced high the PEER die never saw "
        f"AxLOCK ({s['far_lock_high']}), so 'the peer never saw it' below "
        f"would prove nothing. (Wlink does carry axlock: AXI4ToWlink.v:454/473.)")
    assert s["mng_aphase"] > 0 and s["mng_hexcl_high"] > 0, (
        f"COULD-NOT-EVALUATE — with hexcl forced high the far AHB manager never "
        f"asserted HEXCL in an address phase (aphase={s['mng_aphase']} "
        f"hexcl={s['mng_hexcl_high']}); the far-side observer is dead.")
    return s


@cocotb.test()
async def test_xdie_exclusive_marker_never_reaches_axi(dut):
    """THE STRUCTURE. An exclusive cannot be expressed across this boundary.

    Three independent findings, each measured:

      (a) tidelink_top's AHB subordinate port has no HEXCL and no HEXOKAY pin,
          so an AHB5 manager's exclusive marker is lost at TideLink's pins.
          Checked against a must-be-present control (ahb_sub_hwrite) so the
          absence check itself can fail.
      (b) with the shipping .hexcl(1'b0), every outbound AR/AW leaves this die
          as (AxLOCK=0, AxID=0) — measured over a real cross-die read and
          write, and preceded by the forced-high instrument control.
      (c) nothing exclusive appears on the far die either: the peer's inbound
          AxLOCK is never high, u_xhb_mng.hexcl (the far AHB manager's
          exclusive marker, left UNCONNECTED at tidelink_top.sv:3313) is never
          high, and u_xhb_mng.hexokay (tied 1'b0 at :3319) is never high.
    """
    tb, master = await _bringup(dut)
    mon = LockMon(dut)
    missing = mon.missing()
    dut._log.info(f"[xdie] taps: {mon.taps}")
    assert not missing, (
        f"COULD-NOT-EVALUATE — these taps do not resolve: {missing}")

    # (a) the pins do not exist -- with a must-be-present control.
    assert _present(dut.u_master, "ahb_sub_hwrite"), (
        "COULD-NOT-EVALUATE — the port-presence check cannot see a port that "
        "definitely exists, so its negative results prove nothing")
    absent = [n for n in ("ahb_sub_hexcl", "ahb_sub_hexokay",
                          "ahb_sub_hmastlock", "ahb_sub_hmaster")
              if not _present(dut.u_master, n)]
    dut._log.info(f"[xdie] tidelink_top AHB-subordinate pins ABSENT: {absent}")
    assert "ahb_sub_hexcl" in absent and "ahb_sub_hexokay" in absent, (
        f"tidelink_top DOES expose an exclusive-capable AHB subordinate port "
        f"({absent}) — the premise of this analysis is wrong and the whole "
        f"file needs revisiting.")

    # (b)/(c) THE SHIPPING MEASUREMENT RUNS FIRST, so nothing the forced
    # control does can leak into it through a payload register that holds its
    # last value.  The control then follows, in the same simulation, and proves
    # every observer used here can read 1.
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    await master.write(APER_BASE + OFF_X, D_SEED, timeout=TIMEOUT)
    got = await master.read(APER_BASE + OFF_X, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 300)
    t.kill()
    s = mon.s()
    dut._log.info(f"[xdie] SHIPPING wiring, real cross-die read+write: {s} "
                  f"got=0x{got:08x}")
    await _instrument_control(dut, master, mon)
    _release_all(tb)

    assert got == D_SEED, f"the cross-die read failed (0x{got:08x})"
    assert s["ar"] and s["aw"], \
        f"COULD-NOT-EVALUATE — no AR/AW was observed at all: {s}"
    assert all(l == 0 for l, _ in s["ar"]), \
        f"ARLOCK reached AXI with .hexcl(1'b0): {s['ar']}"
    assert all(l == 0 for l, _ in s["aw"]), \
        f"AWLOCK reached AXI with .hexcl(1'b0): {s['aw']}"
    assert all(i == 0 for _, i in s["ar"] + s["aw"]), \
        f"AxID was non-zero with .hmaster(12'd0): ar={s['ar']} aw={s['aw']}"
    # (c) nothing exclusive on the far die.
    assert s["far_lock_high"] == 0, \
        f"the peer die saw AxLOCK high for {s['far_lock_high']} cycles: {s}"
    assert s["mng_hexcl_high"] == 0, \
        f"the far AHB manager asserted HEXCL for {s['mng_hexcl_high']} cycles"
    assert s["mng_hexokay_high"] == 0, (
        f"u_xhb_mng.hexokay is tied 1'b0 but read high for "
        f"{s['mng_hexokay_high']} cycles — the tie-off is not what it looks like")


@cocotb.test()
async def test_xdie_two_initiators_both_commit(dut):
    """THE HAZARD. Two initiators, one cross-die address, both stores commit.

    Both initiators reach TideLink through its single AHB subordinate port —
    which is exactly how they arrive in silicon, since that port carries no
    HMASTER and the bridge ties .hmaster(12'd0): whatever an SoC interconnect
    knows about who is asking is discarded at TideLink's pins.

        A: read  X            "load-exclusive"
        B: read  X            "load-exclusive"  (breaks A's reservation)
        B: write X = D_B      "store-exclusive" -- must succeed
        A: write X = D_A      "store-exclusive" -- MUST FAIL in a monitored
                                                   system; here it commits

    MEASURED: all four transactions leave this die as (AxLOCK=0, AxID=0), both
    stores are answered OKAY with no ERROR anywhere, and the far memory ends up
    holding A's value.  A's store — the one a global monitor would have
    rejected — silently overwrote B's.

    RED PROOF, in this run, in order:
      * the SENTINEL write proves _slave_bram_peek is live and reports the
        value actually written (a stuck peek would make 'A won' unfalsifiable);
      * the INSTRUMENT CONTROL proves the AxLOCK observer can read 1;
      * B's store is verified to have landed BEFORE A's is issued, so 'A won'
        means A overwrote a committed value and not that B never got there.
    """
    tb, master = await _bringup(dut)
    mon = LockMon(dut)
    assert not mon.missing(), f"COULD-NOT-EVALUATE — taps missing: {mon.missing()}"

    # SENTINEL: the far-memory observer must report what was written.
    await master.write(APER_BASE + OFF_X, D_SEED, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 3000)
    seed = _slave_bram_peek(dut, OFF_X)
    assert seed == D_SEED, (
        f"COULD-NOT-EVALUATE — the far-memory observer read 0x{(seed or 0):08x} "
        f"after a write of 0x{D_SEED:08x}; 'A won' below would be unfalsifiable.")

    # The instrument control runs AFTER the measured sequence (below) so that
    # nothing it forces can leak into the measurement through a payload
    # register that holds its last value -- see LockMon.run.
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    outcomes = {}

    async def op(name, write, data=0):
        try:
            if write:
                await master.write(APER_BASE + OFF_X, data, timeout=TIMEOUT)
                outcomes[name] = "OK"
            else:
                outcomes[name] = await master.read(APER_BASE + OFF_X,
                                                   timeout=TIMEOUT)
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
    dut._log.info(f"[xdie] TWO INITIATORS: outcomes={outcomes} "
                  f"after_B=0x{(after_b or 0):08x} final=0x{(final or 0):08x} {s}")
    await _instrument_control(dut, master, mon)
    _release_all(tb)

    assert outcomes["A_ldrex"] == D_SEED and outcomes["B_ldrex"] == D_SEED, (
        f"COULD-NOT-EVALUATE — the two load-exclusives did not both read the "
        f"seed: {outcomes}")
    assert after_b == D_B, (
        f"COULD-NOT-EVALUATE — B's store did not land (0x{(after_b or 0):08x}); "
        f"'A overwrote B' cannot be concluded from a store that never happened.")
    assert outcomes["B_strex"] == "OK" and outcomes["A_strex"] == "OK", (
        f"one of the stores was not answered OKAY: {outcomes}. If a store had "
        f"been errored there WOULD be a failure indication and this would not "
        f"be a silent hazard.")
    assert len(s["ar"]) == 2 and len(s["aw"]) == 2, \
        f"COULD-NOT-EVALUATE — expected 2 AR + 2 AW, got {s}"
    assert s["ar"] == [(0, 0), (0, 0)] and s["aw"] == [(0, 0), (0, 0)], (
        f"the two initiators were distinguishable on the cross-die AXI port "
        f"(ar={s['ar']} aw={s['aw']}) — with .hexcl(1'b0)/.hmaster(12'd0) they "
        f"must be identical.")
    assert s["mng_hexokay_high"] == 0, \
        f"EXOKAY appeared on the far die: {s}"
    assert s["mng_hexcl_high"] == 0 and s["mng_aphase"] > 0, \
        f"an exclusive marker appeared on the far AHB manager: {s}"
    assert final == D_A, (
        f"DOUBLE EXCLUSIVE IS REACHABLE ACROSS THE DIE BOUNDARY: B's committed "
        f"store (0x{D_B:08x}) was silently overwritten by A's store "
        f"(0x{(final or 0):08x}), which a global exclusive monitor would have "
        f"rejected because B's load broke A's reservation. Neither initiator "
        f"can detect this: no HEXOKAY pin exists on TideLink's AHB subordinate "
        f"port, AxLOCK never leaves the die, and both stores answer OKAY.")

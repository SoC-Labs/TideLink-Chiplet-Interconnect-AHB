"""TL-044 — the READ DEAD GATE: what the port does AFTER the read backstop has
already done its job correctly.

THE DEFECT, measured on KR260 silicon and reproduced here.
---------------------------------------------------------
A cross-die read whose R is permanently lost IS retired correctly: the read
backstop fires (0x21F8 bit[9]=1) and the master gets a legal 2-cycle AHB ERROR.
TL-037 (already in this tree) additionally bounds the NEXT transfer addressed to
this port. Neither of them touches the thing that actually wedges the host:

    src/rtl/tidelink_top.sv   assign ahb_sub_hreadyout = ... : xhb_sub_hreadyout_raw;
                                                               ^^^^^^^^^^^^^^^^^^^^^
XHB500's read_counter is decremented ONLY by r_done (core_resp.sv:115-123), so a
lost R parks it non-zero forever, ready_for_read stays 0, and
xhb_sub_hreadyout_raw goes 0 and STAYS 0. MEASURED, not assumed: in the TL-037
vehicle on pristine 5e8bdb5a RTL, `raw_high_cycles` is 0 out of 8093 cycles after
the backstop ERROR. sub_err{1,2}_r are ONE-SHOTS (:1705 clears by default), so
two cycles after the ERROR every term of the mux is 0 and the port falls through
to that terminal fallback:

    HREADYOUT IS DRIVEN LOW WHILE THE BUS IS IDLE, FOREVER.

That is an AHB-Lite protocol violation whose blast radius is the whole bus, not
just this slave: the AHB mux keeps presenting this port's HREADYOUT to the
manager between transfers, so the manager cannot start a transfer to ANY slave.
"The next transaction of any kind hangs the PS with no bus timeout" — JTAG-POR
only. TL-037's terminal timeout cannot cover it: that arm needs
`sub_mst_dphase_r` (a master waiting in a data phase), which on an IDLE bus is 0
by construction. And for transfers that ARE addressed here, TL-037 charges a
full SUB_STALL_TIMEOUT window each (2^16 hclk ~ 2.6 ms @25 MHz on the shipping
default) — bounded on paper, indistinguishable from a hang to a driver.

WHY READS AND NOT WRITES: both error arms carry `& ~synth_b_pending`. The write
path can FABRICATE a response — a synthetic B completes the write through
XHB500's own response path, independent of the wedge. There is no synthetic-R
equivalent, because you cannot fabricate read DATA.

THE FIX UNDER TEST (TL-044, CONTAINMENT — not repair)
-----------------------------------------------------
A sticky `xhb_dead_r`, armed when a 2-cycle ERROR has fired on this port AND the
bridge has then shown no sign of life (raw low AND zero s_axi progress) for
XHB_DEAD_ARM_LOG2 consecutive cycles. While it holds, the port stops falling
through to the known-wedged raw: an idle bus is RELEASED (HREADYOUT=1) and any
subsequent transfer is retired with a bounded 2-cycle AHB ERROR. It never
invents read data and never reports OKAY for a transfer XHB500 did not complete.

TESTS (each needs its OWN sim — a second run_bringup_full does not re-POR):

  test_tl044_red_idle_bus_is_held_low_after_backstop      RED / A-B
      The defect itself. After the backstop retires the read and the master goes
      IDLE, is HREADYOUT ever released? Pristine: never (0 high cycles across
      several arm windows). Fixed: released within the arm window and held high.

  test_tl044_green_subsequent_transfers_are_bounded       GREEN / A-B
      With the bridge dead, a subsequent READ and a subsequent WRITE must each
      be retired by a legal AHB ERROR within TL044_BOUND_CYCLES. Pristine: each
      costs a full stall window (>= 2**TL044_STALL_LOG2). Measured, not assumed.

  test_tl044_mutant_detection_without_action              MUTANT (needs the
      +define+TIDELINK_XHB_DEAD_NO_ACTION build). Detection still latches
      xhb_dead_r; the action taps are tied 0, so the port behaves exactly as
      pristine and the idle bus is still held low. Proves detection is separable
      from action. The `mutant` make target ALSO runs the GREEN test under that
      define and requires it to FAIL.

  test_tl044_safety_clears_and_normal_path_survives       SAFETY (mandatory)
      (i) the containment's OWN state clears when the underlying condition goes
      away — debounced — and the pre-existing protections are found at rest and
      undisturbed (synth_b_pending, wr_hold_r, sub_rd_os_r, sub_err{1,2}_r);
      (ii) a NORMAL write AND a NORMAL read still work afterwards, byte-exact.
      A passing escape test is not a safety test.

  test_tl044_intermittent_does_not_thrash                 INTERMITTENT
      The dangerous third branch. A brief ready blip must NOT clear the sticky
      (debounce), and after TL044_RELAPSE_MAX clear/re-arm cycles the sticky
      must latch PERMANENTLY rather than oscillate. WHITE-BOX BY CONSTRUCTION:
      it FORCES xhb_sub_hreadyout_raw to author an arbitrary raw waveform,
      because nobody has yet measured what the real bridge does after this park
      — the whole point of the branch is to characterise the containment's
      response to a waveform we cannot obtain from the far terminus.

  test_tl044_false_fire_guard_zero_arms                   FALSE-FIRE GUARD
      Many rounds of ordinary mixed read/write traffic on a healthy link. Zero
      arms, zero containment errors, and — the strong form — every ACTION tap 0
      in EVERY cycle, which makes ahb_sub_hreadyout provably bit-identical to
      pristine RTL over the whole run.

BUILD: short stall/outstanding windows so the backstop is reachable in sim, and
short containment windows so the arm/debounce are reachable. The four env vars
below MUST match the four +defines (the Makefile target sets both).

  make -C cocotb/tidelink_axi_datanode_recovery tl044
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

# Helpers only — importing a module that defines @cocotb.test() would pull its
# tests into this module's regression set, so only plain helpers are taken.
from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)

STALL_LOG2   = int(os.environ.get("TL044_STALL_LOG2", "13"))
ARM_LOG2     = int(os.environ.get("TL044_ARM_LOG2", "8"))
RECOVER_LOG2 = int(os.environ.get("TL044_RECOVER_LOG2", "8"))
RELAPSE_MAX  = int(os.environ.get("TL044_RELAPSE_MAX", "2"))

STALL_WINDOW   = 1 << STALL_LOG2
ARM_WINDOW     = 1 << ARM_LOG2
RECOVER_WINDOW = 1 << RECOVER_LOG2

# The GREEN bar. The containment path is fill(1) + dphase(1) + err1(1) + err2(1),
# so ~4-6 cycles; 32 is generous and still ~256x under one stall window.
BOUND_CYCLES = 32

OFF_RD1  = 0x300     # the read whose R is permanently lost
OFF_RD2  = 0x1340    # a DIFFERENT 4KB page, so an XHB500 hazard_list address
                     # match (compared on chk_addr[31:12]) cannot be why it
                     # stalls. Low bits differ too: the far terminus is
                     # tb_ahb_bram_slave #(.AW(12)), which aliases the page bits
                     # away, so 0x300/0x1300 would be the same physical word.
OFF_WR2  = 0x2350
OFF_POST = 0x400     # the post-recovery clean transfer
D_RD1  = 0x5EED0042
D_RD2  = 0x5EED1043
D_WR2  = 0x1234ABCD
D_POST = 0xA5A50FF0

SECOND_TIMEOUT = 6 * STALL_WINDOW


def _g(obj, name, default=None):
    """Read a possibly-absent child signal (the pristine build lacks the new ones)."""
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return default


class Cycles:
    """Free-running hclk counter, so latencies are MEASURED in cycles."""

    def __init__(self, dut):
        self.dut = dut
        self.n = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.hclk)
            self.n += 1


class DeadGateMon:
    """Samples the containment + the pre-existing backstop state every hclk.

    `idle_low` / `idle_high` are the RED/GREEN measurement: HREADYOUT sampled
    ONLY on cycles where the master has no transfer outstanding, i.e. exactly
    the AHB-Lite "an idle slave must not hold HREADY low" question.
    """

    def __init__(self, dut, master):
        self.dut = dut
        self.top = dut.u_master
        self.master = master
        self.cycle = 0
        self.idle_low = 0
        self.idle_high = 0
        self.idle_low_run = 0
        self.idle_low_run_max = 0
        self.first_idle_high = None
        self.dead_arms = 0            # 0->1 transitions of xhb_dead_r
        self.dead_clears = 0          # 1->0 transitions of xhb_dead_r
        self.dead_cycles = 0
        self.perm_seen = 0
        self.dg_err1_rises = 0
        self.dg_err2_cycles = 0
        self.act_nonzero_cycles = 0   # any ACTION tap asserted
        self.err1_rises = 0           # the PRE-EXISTING backstop
        self.synthb_rises = 0
        self.wrhold_cycles = 0
        self.raw_high_cycles = 0
        self.port_err_pulses = 0
        self.port_err_illegal = 0

    async def run(self, cycles):
        prev_dead = prev_e1 = prev_sb = prev_resp = prev_dg1 = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            self.cycle += 1
            raw = _g(self.top, "xhb_sub_hreadyout_raw", 1)
            if raw:
                self.raw_high_cycles += 1

            try:
                hro = int(self.dut.m_ahb_sub_hreadyout.value)
            except ValueError:
                hro = 1
            if not self.master.outstanding:
                if hro:
                    self.idle_high += 1
                    if self.first_idle_high is None:
                        self.first_idle_high = self.cycle
                    self.idle_low_run = 0
                else:
                    self.idle_low += 1
                    self.idle_low_run += 1
                    if self.idle_low_run > self.idle_low_run_max:
                        self.idle_low_run_max = self.idle_low_run

            dead = _g(self.top, "xhb_dead_r", 0) or 0
            if dead:
                self.dead_cycles += 1
            if dead and not prev_dead:
                self.dead_arms += 1
            if prev_dead and not dead:
                self.dead_clears += 1
            prev_dead = dead
            if _g(self.top, "xhb_dead_perm_r", 0):
                self.perm_seen = 1

            dg1 = _g(self.top, "dg_err1_r", 0) or 0
            if dg1 and not prev_dg1:
                self.dg_err1_rises += 1
            prev_dg1 = dg1
            if _g(self.top, "dg_err2_r", 0):
                self.dg_err2_cycles += 1
            if (_g(self.top, "dg_act_err1", 0) or _g(self.top, "dg_act_err2", 0)
                    or _g(self.top, "dg_act_ready", 0)
                    or _g(self.top, "dg_act_abort", 0)):
                self.act_nonzero_cycles += 1

            e1 = _g(self.top, "sub_err1_r", 0) or 0
            if e1 and not prev_e1:
                self.err1_rises += 1
            prev_e1 = e1
            sb = _g(self.top, "synth_b_pending", 0) or 0
            if sb and not prev_sb:
                self.synthb_rises += 1
            prev_sb = sb
            if _g(self.top, "wr_hold_r", 0):
                self.wrhold_cycles += 1

            try:
                resp = int(self.dut.m_ahb_sub_hresp.value)
            except ValueError:
                resp = prev_resp
            if resp and not prev_resp:
                self.port_err_pulses += 1
                if not self.master.outstanding:
                    self.port_err_illegal += 1
            prev_resp = resp

    def summary(self):
        return {k: getattr(self, k) for k in (
            "cycle", "idle_low", "idle_high", "idle_low_run_max",
            "first_idle_high", "dead_arms", "dead_clears", "dead_cycles",
            "perm_seen", "dg_err1_rises", "dg_err2_cycles",
            "act_nonzero_cycles", "err1_rises", "synthb_rises", "wrhold_cycles",
            "raw_high_cycles", "port_err_pulses", "port_err_illegal")}


async def _classify(master, addr, write=False, data=0, timeout=None):
    """ERROR = bounded by HRESP=ERROR; OK = completed; HANG = never answered."""
    timeout = SECOND_TIMEOUT if timeout is None else timeout
    try:
        if write:
            await master.write(addr, data, timeout=timeout)
            return "OK", None
        v = await master.read(addr, timeout=timeout)
        return "OK", v
    except RuntimeError:
        return "ERROR", None
    except TimeoutError:
        return "HANG", None


async def _stage(dut):
    """Bring the pair up, PROVE the clean peer read path, then wedge the far
    terminus so neither R nor B ever comes back. No AXI handshake is forced."""
    tb, master = await _bringup(dut)
    await master.write(APER_BASE + OFF_RD1, D_RD1)
    await master.write(APER_BASE + OFF_RD2, D_RD2)
    await ClockCycles(dut.hclk, 2000)
    pre1 = await master.read(APER_BASE + OFF_RD1)
    assert pre1 == D_RD1, f"clean peer READ broken before the fault: 0x{pre1:08x}"
    pre2 = await master.read(APER_BASE + OFF_RD2)
    assert pre2 == D_RD2, f"clean peer READ broken before the fault: 0x{pre2:08x}"
    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 20)
    return tb, master


async def _wedge_and_trip(dut, master):
    """Wedge established: drive the read whose R never returns and require the
    PRE-EXISTING read backstop to retire it. Everything after this point is
    about what the port does NEXT."""
    cls, _ = await _classify(master, APER_BASE + OFF_RD1)
    assert cls == "ERROR", (
        f"CANNOT CONSTRUCT — the read backstop did not retire the stuck read "
        f"(class={cls}). Nothing else in this test is interpretable; run "
        f"test_tl037_control_first_stuck_read_is_bounded first.")


# =============================================================================
# RED — the defect
# =============================================================================
@cocotb.test()
async def test_tl044_red_idle_bus_is_held_low_after_backstop(dut):
    """RED / A-B. After the read backstop has retired the read and the master is
    IDLE, is HREADYOUT ever released?

    PRISTINE: never. Every term of the mux is 0 on an idle bus, so the port
    drives the terminal fallback xhb_sub_hreadyout_raw == 0 forever, and an AHB
    manager behind the bus mux can never start another transfer to ANY slave.

    FIXED: the containment arms one ARM_WINDOW after the ERROR and releases the
    bus, which is what makes the port protocol-legal again."""
    tb, master = await _stage(dut)
    await _wedge_and_trip(dut, master)

    # Master is idle from here. Watch several arm windows so "never released"
    # is MEASURED across real opportunities rather than assumed.
    watch = 6 * ARM_WINDOW + 400
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(watch))
    await ClockCycles(dut.hclk, watch + 20)
    m.kill()
    s = mon.summary()
    dut._log.info(f"[tl044] RED idle-bus watch ({watch} cy): {s}")
    _release_all(tb)

    # NON-VACUITY: the wedge really is a wedge — raw never came back on its own.
    assert s["raw_high_cycles"] == 0, (
        f"CANNOT CONSTRUCT — xhb_sub_hreadyout_raw went HIGH {s['raw_high_cycles']} "
        f"times during the watch, so the bridge was not parked and this window "
        f"does not exercise the dead gate. {s}")
    assert s["idle_low"] + s["idle_high"] > 4 * ARM_WINDOW, (
        f"CANNOT CONSTRUCT — the master was not idle for long enough to sample "
        f"the idle bus. {s}")

    # ── VERDICT ─────────────────────────────────────────────────────────────
    assert s["idle_high"] > 0, (
        f"TL-044 REPRODUCED: after the read backstop fired, ahb_sub_hreadyout is "
        f"held LOW on an IDLE bus for {s['idle_low']} consecutive cycles "
        f"(longest run {s['idle_low_run_max']}) and never once released. "
        f"sub_err{{1,2}}_r are one-shots, so the mux falls through to "
        f"xhb_sub_hreadyout_raw, which is 0 for all {watch} cycles. On silicon "
        f"the AHB mux keeps presenting this to the manager between transfers, so "
        f"the NEXT transaction of any kind — to this port or to any other slave "
        f"— never starts. No bus timeout; JTAG-POR only. {s}")
    assert s["first_idle_high"] is not None and \
        s["first_idle_high"] <= 2 * ARM_WINDOW + 200, (
        f"the bus was released, but only after {s['first_idle_high']} cycles — "
        f"longer than the containment's own arm window (2*{ARM_WINDOW}+200). {s}")
    assert s["idle_low_run_max"] <= 2 * ARM_WINDOW + 200, (
        f"the idle bus was held low for a run of {s['idle_low_run_max']} cycles "
        f"after the containment should have released it. {s}")
    assert s["port_err_illegal"] == 0, (
        f"an HRESP=ERROR pulse landed on an idle bus ({s['port_err_illegal']} "
        f"illegal pulses) — AHB-illegal. {s}")


# =============================================================================
# GREEN — bounded errors for subsequent transfers, both directions
# =============================================================================
@cocotb.test()
async def test_tl044_green_subsequent_transfers_are_bounded(dut):
    """GREEN / A-B. With the bridge dead, a subsequent READ and a subsequent
    WRITE must each be retired by a legal 2-cycle AHB ERROR within
    BOUND_CYCLES.

    PRISTINE: TL-037 eventually errors them, but only after a FULL stall window
    each (>= 2**STALL_LOG2 cycles) — on the shipping 2^16 default that is ~2.6 ms
    per access. This test measures the latency, so 'bounded' is a number."""
    tb, master = await _stage(dut)
    await _wedge_and_trip(dut, master)

    cyc = Cycles(dut)
    c = cocotb.start_soon(cyc.run())
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(4 * SECOND_TIMEOUT))

    # Let the containment arm (fixed RTL). On pristine RTL nothing happens here.
    await ClockCycles(dut.hclk, 2 * ARM_WINDOW + 200)
    dead_before = _g(dut.u_master, "xhb_dead_r", None)

    results = []
    for label, addr, is_wr, data in (
            ("read2",  APER_BASE + OFF_RD2, False, 0),
            ("write2", APER_BASE + OFF_WR2, True,  D_WR2),
            ("read3",  APER_BASE + OFF_RD2, False, 0),
            ("write3", APER_BASE + OFF_WR2, True,  D_WR2),
    ):
        t0 = cyc.n
        cls, val = await _classify(master, addr, write=is_wr, data=data)
        results.append((label, cls, cyc.n - t0, val))
        await ClockCycles(dut.hclk, 20)

    await ClockCycles(dut.hclk, 100)
    m.kill(); c.kill()
    s = mon.summary()
    dut._log.info(f"[tl044] GREEN xhb_dead_r(before)={dead_before} "
                  f"results={results} {s}")
    _release_all(tb)

    assert s["raw_high_cycles"] == 0, (
        f"CANNOT CONSTRUCT — the bridge un-parked during the run "
        f"(raw_high_cycles={s['raw_high_cycles']}), so these transfers are not "
        f"measuring the dead-gate path. {s}")

    for label, cls, lat, val in results:
        assert cls == "ERROR", (
            f"TL-044 {label}: class={cls}, not the bounded ERROR the containment "
            f"must deliver. HANG = the dead gate; OK = the port INVENTED a "
            f"completion for a transfer XHB500 never performed (val={val}), "
            f"which is worse. {results} {s}")
        assert lat <= BOUND_CYCLES, (
            f"TL-044 {label}: retired with an ERROR but only after {lat} cycles "
            f"(bound {BOUND_CYCLES}; one stall window is {STALL_WINDOW}). The "
            f"containment did not own this transfer — the pre-existing "
            f"stall-timeout backstop did, at a full window each. {results} {s}")

    assert s["dg_err1_rises"] >= len(results), (
        f"the containment ERROR sequencer fired {s['dg_err1_rises']}x for "
        f"{len(results)} transfers — some were retired by something else, so "
        f"this result is not attributable to TL-044. {s}")
    assert s["port_err_illegal"] == 0, (
        f"a containment HRESP=ERROR landed on an idle bus "
        f"({s['port_err_illegal']} illegal pulses) — that is the F-1 defect and "
        f"an upstream AXI->AHB bridge is entitled to discard it. {s}")
    assert s["synthb_rises"] == 0, (
        f"the containment armed synth_b_pending ({s['synthb_rises']} rises). It "
        f"must not touch the write-drain state at all. {s}")


# =============================================================================
# MUTANT — detection separable from action
# =============================================================================
@cocotb.test()
async def test_tl044_mutant_detection_without_action(dut):
    """MUTANT build only (+define+TIDELINK_XHB_DEAD_NO_ACTION).

    Detection is untouched: xhb_dead_r still latches on exactly the same
    evidence. The four ACTION taps are tied 0, so ahb_sub_hreadyout /
    ahb_sub_hresp / the address pipeline are bit-identical to pristine — and the
    idle bus is therefore STILL held low. This is the positive statement of
    separability; the `mutant` make target states the negative one by requiring
    the GREEN test to FAIL under the same define."""
    tb, master = await _stage(dut)
    await _wedge_and_trip(dut, master)

    watch = 6 * ARM_WINDOW + 400
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(watch))
    await ClockCycles(dut.hclk, watch + 20)
    m.kill()
    s = mon.summary()
    dut._log.info(f"[tl044] MUTANT watch ({watch} cy): {s}")
    _release_all(tb)

    assert s["raw_high_cycles"] == 0, f"CANNOT CONSTRUCT — bridge not parked. {s}"
    # DETECTION intact.
    assert s["dead_arms"] >= 1 and s["dead_cycles"] > 0, (
        f"MUTANT: detection did NOT latch (dead_arms={s['dead_arms']}). The "
        f"define is supposed to disable the ACTION only — if detection is gone "
        f"too, the mutant proves nothing about separability. {s}")
    # ACTION absent.
    assert s["act_nonzero_cycles"] == 0, (
        f"MUTANT: an ACTION tap was asserted for {s['act_nonzero_cycles']} "
        f"cycles — the define did not disable the action. {s}")
    assert s["idle_high"] == 0, (
        f"MUTANT: the idle bus was released for {s['idle_high']} cycles with the "
        f"action disabled — so the release is NOT coming from the containment "
        f"action and the GREEN result is not attributable to this fix. {s}")


# =============================================================================
# SAFETY — the containment's own state clears, and the normal path survives
# =============================================================================
@cocotb.test()
async def test_tl044_safety_clears_and_normal_path_survives(dut):
    """SAFETY (mandatory).

    (a) FIRES    — the containment arms and retires a subsequent access.
    (b) CLEARS   — with the underlying condition removed, xhb_dead_r clears
                   (debounced), the sequencer is at rest, the anti-oscillation
                   latch did NOT engage, and every PRE-EXISTING protection is
                   found at rest and undisturbed (synth_b_pending, wr_hold_r,
                   sub_rd_os_r, sub_err{1,2}_r).
    (c) SURVIVES — a NORMAL write lands byte-exact at the far terminus AND a
                   NORMAL read returns it byte-exact. A passing escape test is
                   not a safety test."""
    tb, master = await _stage(dut)
    await _wedge_and_trip(dut, master)

    cyc = Cycles(dut)
    c = cocotb.start_soon(cyc.run())
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(6 * SECOND_TIMEOUT))

    await ClockCycles(dut.hclk, 2 * ARM_WINDOW + 200)
    t0 = cyc.n
    cls2, _ = await _classify(master, APER_BASE + OFF_RD2)
    lat2 = cyc.n - t0
    await ClockCycles(dut.hclk, 50)

    # (a) FIRES
    assert cls2 == "ERROR", f"(a) the containment did not fire — class={cls2}"
    assert lat2 <= BOUND_CYCLES, f"(a) fired but unbounded: {lat2} cycles"
    armed_dead = _g(dut.u_master, "xhb_dead_r")
    assert armed_dead == 1, f"(a) xhb_dead_r not set while contained ({armed_dead})"

    # (b) CLEARS — remove the underlying condition and let the debounce run.
    dut.u_s_mng_bram.force_stall.value = 0
    await ClockCycles(dut.hclk, 4 * RECOVER_WINDOW + 4000)
    resting = {n: _g(dut.u_master, n) for n in (
        "xhb_dead_r", "xhb_dead_perm_r", "dg_armed_r", "dg_err1_r", "dg_err2_r",
        "sub_err1_r", "sub_err2_r", "synth_b_pending", "sub_mst_dphase_r",
        "sub_rd_os_r", "sub_wr_os_ctr", "wr_hold_r")}
    dut._log.info(f"[tl044] SAFETY resting after clear: {resting} lat2={lat2}")

    assert resting["xhb_dead_r"] == 0, (
        f"(b) THE STICKY NEVER CLEARED. With the wedge removed and raw high for "
        f"{4 * RECOVER_WINDOW + 4000} cycles, xhb_dead_r is still set — the fix "
        f"has converted a transient fault into a permanent brick, which is worse "
        f"than the bug. {resting}")
    assert resting["xhb_dead_perm_r"] == 0, (
        f"(b) the anti-oscillation latch engaged after a SINGLE arm/clear — it "
        f"must only latch after {RELAPSE_MAX} relapses. {resting}")
    for n in ("dg_armed_r", "dg_err1_r", "dg_err2_r", "sub_err1_r", "sub_err2_r",
              "synth_b_pending", "sub_mst_dphase_r", "sub_rd_os_r", "wr_hold_r"):
        assert resting[n] == 0, (
            f"(b) STATE DID NOT CLEAR — {n}={resting[n]} still set. {resting}")

    # (c) SURVIVES — byte-exact, both directions.
    try:
        await master.write(APER_BASE + OFF_POST, D_POST, timeout=SECOND_TIMEOUT)
        await ClockCycles(dut.hclk, 3000)
        landed = _slave_bram_peek(dut, OFF_POST)
    except (TimeoutError, RuntimeError) as e:
        m.kill(); c.kill(); _release_all(tb)
        raise AssertionError(
            f"(c) NORMAL PATH DEAD AFTER THE CONTAINMENT FIRED: with the wedge "
            f"REMOVED, the next clean peer write failed ({e}). A containment that "
            f"leaves the port unusable is a report, not a containment.")
    assert landed == D_POST, (
        f"(c) post-recovery write landed 0x{landed:08x} != 0x{D_POST:08x} — the "
        f"write DATA path is corrupted after the containment fired (this is the "
        f"Rank-1 wr_hold_r hazard: the containment outranks wr_hold_r in the "
        f"hreadyout mux while xhb_dead_r holds, and must not survive into normal "
        f"operation)")

    cls3, got = await _classify(master, APER_BASE + OFF_POST)
    m.kill(); c.kill()
    s = mon.summary()
    dut._log.info(f"[tl044] SAFETY post-recovery read class={cls3} "
                  f"got={None if got is None else hex(got)} {s}")
    _release_all(tb)
    assert cls3 == "OK", f"(c) a clean peer READ after the containment gave class={cls3}"
    assert got == D_POST, f"(c) post-recovery read returned 0x{got:08x} != 0x{D_POST:08x}"
    assert s["dead_arms"] == 1 and s["dead_clears"] == 1, (
        f"(c) the containment armed {s['dead_arms']}x and cleared "
        f"{s['dead_clears']}x — it should have done each exactly once. {s}")


# =============================================================================
# INTERMITTENT — the dangerous third branch
# =============================================================================
async def _force_raw(dut, value):
    dut.u_master.xhb_sub_hreadyout_raw.value = Force(value)


async def _release_raw(dut):
    dut.u_master.xhb_sub_hreadyout_raw.value = Release()


async def _wait_dead(dut, want, limit):
    for _ in range(limit):
        await RisingEdge(dut.hclk)
        if (_g(dut.u_master, "xhb_dead_r", 0) or 0) == want:
            return True
    return False


@cocotb.test()
async def test_tl044_intermittent_does_not_thrash(dut):
    """INTERMITTENT — raw returns, then dips again. Two properties:

      DEBOUNCE   a ready blip SHORTER than RECOVER_WINDOW must clear NOTHING.
                 Clearing on a blip would drop the port straight back onto the
                 unbounded fall-through the fix exists to remove.
      NO THRASH  after RELAPSE_MAX clear/re-arm cycles the sticky latches
                 PERMANENTLY. Oscillating between pass-through and bounded-error
                 mode is worse than either stable state, because software cannot
                 tell 'retry, the link blipped' from 'this port is gone'.

    WHITE-BOX BY CONSTRUCTION. This arm FORCES xhb_sub_hreadyout_raw to author a
    raw waveform the far terminus cannot produce on demand. That is deliberate:
    nobody has measured what the real bridge does after this park, so the
    containment must be characterised against an ARBITRARY raw waveform. The
    AHB master is idle throughout the forced windows and no AXI handshake is
    forced anywhere."""
    tb, master = await _bringup(dut)
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(60 * (STALL_WINDOW + ARM_WINDOW)))

    async def arm_once(tag):
        """Park the bridge by force, drive one read into it, and let the
        pre-existing stall backstop fire so the containment can arm."""
        await _force_raw(dut, 0)
        await ClockCycles(dut.hclk, 10)
        cls, _ = await _classify(master, APER_BASE + OFF_RD1)
        assert cls == "ERROR", f"{tag}: the stall backstop did not fire (class={cls})"
        ok = await _wait_dead(dut, 1, 4 * ARM_WINDOW + 2000)
        assert ok, f"{tag}: xhb_dead_r never armed within 4 arm windows"

    # ── relapse 0: arm, then a BLIP that must not clear anything ─────────────
    await arm_once("arm0")
    blip = max(4, RECOVER_WINDOW // 2)
    await _force_raw(dut, 1)
    await ClockCycles(dut.hclk, blip)
    await _force_raw(dut, 0)
    await ClockCycles(dut.hclk, 50)
    after_blip = _g(dut.u_master, "xhb_dead_r")
    arms_after_blip = mon.dead_arms
    clears_after_blip = mon.dead_clears
    dut._log.info(f"[tl044] INTERMITTENT blip={blip}cy (RECOVER_WINDOW="
                  f"{RECOVER_WINDOW}) xhb_dead_r={after_blip} "
                  f"arms={arms_after_blip} clears={clears_after_blip}")
    assert after_blip == 1, (
        f"DEBOUNCE FAILED: a {blip}-cycle ready blip cleared the sticky "
        f"(RECOVER_WINDOW={RECOVER_WINDOW}). A single-sample observation of raw "
        f"going high is NOT evidence the bridge is back, and clearing on it "
        f"returns the port to the unbounded fall-through.")
    assert clears_after_blip == 0, (
        f"DEBOUNCE FAILED: {clears_after_blip} clear(s) during the blip window")

    # Hold it low again long enough to prove no late clear leaks through.
    await ClockCycles(dut.hclk, 2 * ARM_WINDOW)
    assert _g(dut.u_master, "xhb_dead_r") == 1, "sticky dropped after the blip window"
    assert mon.dead_arms == arms_after_blip, (
        f"THRASH: the sticky re-armed ({mon.dead_arms} vs {arms_after_blip}) "
        f"without ever having cleared")

    # ── full relapse cycles: clear (debounced) then re-arm, RELAPSE_MAX times ─
    for i in range(RELAPSE_MAX):
        await _force_raw(dut, 1)
        ok = await _wait_dead(dut, 0, 4 * RECOVER_WINDOW + 2000)
        assert ok, (
            f"relapse {i}: a FULL debounced recovery ({RECOVER_WINDOW} cycles of "
            f"raw high) did not clear the sticky — the RECOVERED branch is broken")
        assert _g(dut.u_master, "xhb_dead_perm_r") == 0, (
            f"relapse {i}: the permanent latch engaged early (allowance is "
            f"{RELAPSE_MAX})")
        await ClockCycles(dut.hclk, 200)
        await arm_once(f"relapse{i + 1}")

    # ── the allowance is now spent: the NEXT recovery must NOT clear ─────────
    perm = _g(dut.u_master, "xhb_dead_perm_r")
    dut._log.info(f"[tl044] INTERMITTENT after {RELAPSE_MAX} relapses: "
                  f"perm={perm} arms={mon.dead_arms} clears={mon.dead_clears}")
    assert perm == 1, (
        f"NO THRASH FAILED: after {RELAPSE_MAX} clear/re-arm cycles the "
        f"anti-oscillation latch is still 0, so the port can keep oscillating "
        f"between pass-through and bounded-error mode indefinitely.")
    await _force_raw(dut, 1)
    await ClockCycles(dut.hclk, 6 * RECOVER_WINDOW + 1000)
    still = _g(dut.u_master, "xhb_dead_r")
    s = mon.summary()
    await _release_raw(dut)
    m.kill()
    dut._log.info(f"[tl044] INTERMITTENT terminal: xhb_dead_r={still} {s}")
    _release_all(tb)
    assert still == 1, (
        f"NO THRASH FAILED: the sticky cleared AGAIN after the permanent latch "
        f"engaged — {s}")
    assert s["dead_arms"] == RELAPSE_MAX + 1 and s["dead_clears"] == RELAPSE_MAX, (
        f"expected exactly {RELAPSE_MAX + 1} arms and {RELAPSE_MAX} clears; got "
        f"{s['dead_arms']}/{s['dead_clears']}. {s}")


# =============================================================================
# FALSE-FIRE GUARD
# =============================================================================
@cocotb.test()
async def test_tl044_false_fire_guard_zero_arms(dut):
    """FALSE-FIRE GUARD. Many rounds of ordinary mixed read/write traffic on a
    healthy link must produce ZERO arms.

    The strong form is `act_nonzero_cycles == 0`: not one of the four ACTION
    taps is asserted in ANY cycle of the run, which makes ahb_sub_hreadyout,
    ahb_sub_hresp and the address pipeline PROVABLY bit-identical to pristine
    RTL over the whole run — the four taps are the only place TL-044 enters
    them."""
    tb, master = await _bringup(dut)
    mon = DeadGateMon(dut, master)
    m = cocotb.start_soon(mon.run(400000))

    ROUNDS = 24
    bad = []
    for i in range(ROUNDS):
        addr_w = APER_BASE + 0x500 + ((i * 4) & 0xFF)
        addr_r = APER_BASE + 0x600 + ((i * 4) & 0xFF)
        data_w = 0xD0000000 | (i * 0x01010101 & 0x0FFFFFFF)
        data_r = 0xE0000000 | (i * 0x02020202 & 0x0FFFFFFF)
        await master.write(addr_w, data_w)
        await master.write(addr_r, data_r)
        await ClockCycles(dut.hclk, 400)
        got = await master.read(addr_r)
        if got != data_r:
            bad.append((i, hex(got), hex(data_r)))
        landed = _slave_bram_peek(dut, (addr_w - APER_BASE) & 0xFFF)
        if landed != data_w:
            bad.append((i, "wr", hex(landed), hex(data_w)))
        await ClockCycles(dut.hclk, 100)

    await ClockCycles(dut.hclk, 500)
    m.kill()
    s = mon.summary()
    dut._log.info(f"[tl044] FALSE-FIRE {ROUNDS} rounds mixed R/W: {s} bad={bad}")
    _release_all(tb)

    assert not bad, f"ordinary traffic was already broken: {bad}"
    assert s["cycle"] > 20000, f"vacuous — only {s['cycle']} cycles observed. {s}"
    assert s["dead_arms"] == 0 and s["dead_cycles"] == 0, (
        f"FALSE FIRE: the containment armed {s['dead_arms']}x during "
        f"{ROUNDS} rounds of ordinary healthy traffic. {s}")
    assert s["dg_err1_rises"] == 0 and s["dg_err2_cycles"] == 0, (
        f"FALSE FIRE: the containment ERROR sequencer fired on healthy traffic. {s}")
    assert s["act_nonzero_cycles"] == 0, (
        f"FALSE FIRE (strong form): a containment ACTION tap was asserted for "
        f"{s['act_nonzero_cycles']} cycles of healthy traffic, so "
        f"ahb_sub_hreadyout was NOT bit-identical to pristine RTL. {s}")
    assert s["err1_rises"] == 0, (
        f"the PRE-EXISTING backstop fired {s['err1_rises']}x on healthy traffic — "
        f"the vehicle is not healthy, so the zero-arm result is not meaningful. {s}")
    assert s["port_err_pulses"] == 0, (
        f"{s['port_err_pulses']} HRESP=ERROR pulse(s) on healthy traffic. {s}")

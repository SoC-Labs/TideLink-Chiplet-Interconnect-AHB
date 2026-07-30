"""FAITHFUL cr_seen=0 repro (I1 bring-up). See docs/I1_SIM_REPRO_PLAN.md and
docs/I1_REPRO_ASYNC_LADDER.md.

The two existing envs are BLIND because (a) cr_seen (cr_pkt_seen_rx) is a sticky
latch that sets on ONE intact peer CR, so on a zero-BER shared-clock wire it
always latches 1; (b) they force_calibrator_sim_bypass() (forcing cal_done, which
severs the cal<-cr coupling); (c) they run a clean bring-up first; (d) they assert
on state==4, never on cr_seen.

This env: COLD bring-up, UN-BYPASSED calibrator, an oracle on the silicon
4-tuple (cr_seen/crack_seen/cal_done/fcsm), and EDGE-TRIGGERED witnesses for
pkt_is_cr_pkt and per-router-input grants (the starvation mechanism).

RED lever = the L6 state-1 CR-emit hold (local_overrides FCSM 0-4); GREEN = deps
FCSM.  See the ladder rungs driven by the Makefile.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from pair_v2_common import (PairV2TB, APBMaster, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
                            ST_CR_SEEN, ST_CRACK_SEEN, ST_CAL_DONE, ST_LANE_LOCKED,
                            APB_R8_SWI_LANE_STATUS)

FCSM_SRC   = os.environ.get("FCSM_SRC", "local")
CAL_BYPASS = os.environ.get("TIDELINK_CAL_BYPASS", "0") == "1"
SILICON_LANE_STATUS = 0x00100000     # cr=0 crack=0 cal=0 fcsm=0, only bit20 set

# F6 async-clock knobs (only active when the DUT is compiled +define+TB_SPLIT_CLK
# and TIDELINK_SPLIT_CLK=1 is exported; otherwise the shared-clock PairV2TB runs).
SPLIT_CLK     = os.environ.get("TIDELINK_SPLIT_CLK", "0") == "1"
DIE_CLK_PPM   = float(os.environ.get("TIDELINK_DIE_CLK_PPM", "0"))
RESET_SKEW_NS = float(os.environ.get("TIDELINK_RESET_SKEW_NS", "0"))


class SplitPairV2TB(PairV2TB):
    """F6 variant: the slave die runs on INDEPENDENT s_hclk/s_ref_clk oscillators
    (ppm offset) and its POR release is skewed, so the two dies' calibrator
    training windows genuinely race.  Requires tb_top compiled +TB_SPLIT_CLK."""

    def __init__(self, dut):
        super().__init__(dut)                       # starts master hclk/ref_clk
        scale = 1.0 + DIE_CLK_PPM / 1e6
        s_hclk_ps = max(1, int(round(CLK_PERIOD_NS * 1000 * scale)))
        s_ref_ps = max(1, int(round(REF_CLK_PERIOD_NS * 1000 * scale)))
        cocotb.start_soon(Clock(dut.s_hclk, s_hclk_ps, unit="ps").start())
        cocotb.start_soon(Clock(dut.s_ref_clk, s_ref_ps, unit="ps").start())
        # Re-bind the slave APB master onto the slave's own clock.
        self.s_apb = APBMaster(dut, dut.s_hclk, "s")
        dut._log.info(f"[SplitPairV2TB] slave hclk={s_hclk_ps}ps ref={s_ref_ps}ps "
                      f"(ppm={DIE_CLK_PPM}) reset_skew={RESET_SKEW_NS}ns")

    async def reset(self):
        """Skewed per-die POR release (F6). Master releases first; the slave's
        pad/POR gate stays low RESET_SKEW_NS longer (a later-arriving die)."""
        self.dut.poresetn.value = 0
        self.dut.hresetn.value = 0
        self.dut.m_por_gate.value = 1
        self.dut.s_por_gate.value = 0 if RESET_SKEW_NS > 0 else 1
        await ClockCycles(self.dut.hclk, 20)
        self.dut.poresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        if RESET_SKEW_NS > 0:
            await Timer(int(round(RESET_SKEW_NS)), unit="ns")
            self.dut.s_por_gate.value = 1
        await ClockCycles(self.dut.hclk, 50)


def make_tb(dut):
    return SplitPairV2TB(dut) if SPLIT_CLK else PairV2TB(dut)

# Poll window (chunks of 200 hclk = 4 us at 20 ns).  The un-bypassed calibrator
# needs ~1 full sweep+hold+validate (~0.6 ms) so default the budget generously.
POLL_CHUNKS   = int(os.environ.get("POLL_CHUNKS",   "600"))   # 2.4 ms
SETTLE_CHUNKS = int(os.environ.get("SETTLE_CHUNKS", "150"))   # RED sustain window


# =====================================================================
# Edge-triggered witnesses (plan 5.3 / 5.4).  Spawned right after reset so
# nothing is missed.  cr_pkt_seen_rx is a sticky latch; here we count the
# underlying pkt_is_cr_pkt PULSES independently, plus per-router-input grants.
# =====================================================================
class Witness:
    ROUTER_INPUTS = (0, 1, 2, 3, 4, 6)   # 0-4 = AXI FC nodes, 6 = sideband tl2wl

    def __init__(self, tb):
        self.tb = tb
        self.cr_pulses    = {"m": 0, "s": 0}
        self.crack_pulses = {"m": 0, "s": 0}
        self.grants       = {"m": {i: 0 for i in self.ROUTER_INPUTS},
                             "s": {i: 0 for i in self.ROUTER_INPUTS}}
        self._stop = False

    def _router(self, side):
        return self.tb.top(side).u_chiplet_controller.u_wlink.txrouter

    def start(self):
        for side in ("m", "s"):
            fc = self.tb.fcsm(side)
            cocotb.start_soon(self._pulse_mon(fc.pkt_is_cr_pkt, self.cr_pulses, side))
            try:
                cocotb.start_soon(self._pulse_mon(fc.pkt_is_crack_pkt,
                                                  self.crack_pulses, side))
            except AttributeError:
                pass
            rt = self._router(side)
            for i in self.ROUTER_INPUTS:
                h = getattr(rt, f"auto_in_{i}_advance", None)
                if h is not None:
                    cocotb.start_soon(self._grant_mon(h, side, i))

    async def _pulse_mon(self, handle, store, side):
        while not self._stop:
            try:
                await RisingEdge(handle)
            except Exception:
                return
            store[side] += 1

    async def _grant_mon(self, handle, side, idx):
        while not self._stop:
            try:
                await RisingEdge(handle)
            except Exception:
                return
            self.grants[side][idx] += 1

    def stop(self):
        self._stop = True

    def grant_summary(self, side):
        g = self.grants[side]
        axi = sum(g[i] for i in (0, 1, 2, 3, 4))
        sb = g[6]
        return f"AXI(0-4)={axi} sideband(6)={sb} detail={g}"


# ------------------------------------------------------------------ helpers
def _read_status_raw(tb, side):
    """Read SWI_LANE_STATUS BinaryValue to check for X before int()."""
    return tb.apb(side)._prdata  # not used directly; APB read below handles it


async def _read_status(tb, side):
    return await tb.apb(side).read(APB_R8_SWI_LANE_STATUS)


def _hier_cr(tb, side):
    return tb.fcsm_cr_seen(side)


def _status_has_x(tb, side):
    """True if the last APB prdata held X/Z (X-masking guard, plan 5.6)."""
    try:
        return not tb.apb(side)._prdata.value.is_resolvable
    except Exception:
        return False


async def _tuple(tb, side):
    st = await _read_status(tb, side)
    return (ST_CR_SEEN(st), ST_CRACK_SEEN(st), ST_CAL_DONE(st),
            tb.fcsm_state(side), st)


def _dbg(tb, side):
    """Probe the internal signals gating S_HOLD -> S_VALIDATE."""
    ctrl = tb.top(side).u_chiplet_controller
    out = {}
    for name, path in (("tm", lambda: ctrl.swi_training_mode_r),
                       ("hold", lambda: ctrl.u_calibrator.hold_ctr),
                       ("rlk", lambda: ctrl.u_calibrator.role_locked_sync),
                       ("tmode", lambda: ctrl.u_calibrator.training_mode)):
        try:
            out[name] = int(path().value)
        except Exception:
            out[name] = -1
    return out


async def _cold_bringup(tb):
    """POR -> (optional bypass) -> role_lock -> LL enable (data mode).  We do NOT
    run a clean bring-up first and we sample cr_seen from cold."""
    await tb.reset()
    if CAL_BYPASS:
        tb.force_calibrator_sim_bypass()          # rung 0 positive control ONLY
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.do_to_data_mode()                    # LL enable -> FCSM state 0->1 attempt


async def _poll(tb, wit, dut, converge=True, log_every=25):
    """Poll the 4-tuple for POLL_CHUNKS; return trajectory + convergence flag.
    converge=True stops early once cr&cal both 1 on both sides."""
    converged = False
    for k in range(POLL_CHUNKS):
        await ClockCycles(dut.hclk, 200)
        m = await _tuple(tb, "m")
        s = await _tuple(tb, "s")
        if k % log_every == 0 or (converge and m[0] and s[0]):
            dm, ds = _dbg(tb, "m"), _dbg(tb, "s")
            dut._log.info(
                f"  t={k*4}us M[cr={m[0]} crk={m[1]} cal={m[2]} fcsm={m[3]} "
                f"cal_st={tb.cal_state_name('m')} tm={dm['tm']} hold={dm['hold']} "
                f"tmode={dm['tmode']} 0x{m[4]:08x}] "
                f"S[cr={s[0]} cal={s[2]} fcsm={s[3]} cal_st={tb.cal_state_name('s')} "
                f"tm={ds['tm']} hold={ds['hold']} tmode={ds['tmode']}] "
                f"crpulse m={wit.cr_pulses['m']} s={wit.cr_pulses['s']}")
        if converge and m[0] == 1 and s[0] == 1:
            converged = True
            break
    return converged


# =====================================================================
# Tests
# =====================================================================
@cocotb.test()
async def test_diag(dut):
    """PURE OBSERVATION (no asserts). Cold un-bypassed bring-up; log the whole
    4-tuple trajectory + calibrator state + grant witness for FCSM_SRC. Run this
    for deps AND local to see WHERE (if anywhere) the ladder splits."""
    dut._log.info(f"=== DIAG === FCSM_SRC={FCSM_SRC} CAL_BYPASS={CAL_BYPASS} "
                  f"ref={REF_CLK_PERIOD_NS}ns hclk={CLK_PERIOD_NS}ns")
    tb = make_tb(dut)
    wit = Witness(tb)
    await tb.reset()
    wit.start()
    if CAL_BYPASS:
        tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    rl = await tb.wait_role_locked()
    dut._log.info(f"  role_locked={rl}")
    await tb.do_to_data_mode()
    await _poll(tb, wit, dut, converge=False, log_every=25)
    wit.stop()
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        dut._log.info(f"  FINAL [{side}] cr={cr} crack={crack} cal={cal} "
                      f"fcsm={fcsm} cal_st={tb.cal_state_name(side)} "
                      f"0x{st:08x} cr_pulses={wit.cr_pulses[side]} "
                      f"grants[{wit.grant_summary(side)}]")


@cocotb.test()
async def test_rung0_green_baseline(dut):
    """Positive control (plan 5.1): deps FCSM, calibrator bypassed. cr_seen MUST
    reach 1 and cal_done MUST reach 1, and pkt_is_cr_pkt MUST pulse. If THIS
    fails the observable path is broken and every later RED is meaningless."""
    dut._log.info(f"=== rung0 GREEN baseline === FCSM_SRC={FCSM_SRC} "
                  f"CAL_BYPASS={CAL_BYPASS}")
    tb = make_tb(dut)
    wit = Witness(tb)
    await tb.reset()
    wit.start()
    if CAL_BYPASS:
        tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.do_to_data_mode()
    conv = await _poll(tb, wit, dut, converge=True)
    wit.stop()
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        dut._log.info(f"  [{side}] cr={cr} crack={crack} cal={cal} fcsm={fcsm} "
                      f"0x{st:08x} cr_pulses={wit.cr_pulses[side]} "
                      f"grants[{wit.grant_summary(side)}]")
        assert not _status_has_x(tb, side), f"[{side}] SWI_LANE_STATUS read X"
        assert cr == 1, f"[{side}] positive control FAILED: cr_seen never latched"
        assert cal == 1, f"[{side}] positive control FAILED: cal_done never set"
        assert ST_CR_SEEN(st) == max(_hier_cr(tb, side), 0), (
            f"[{side}] APB cr disagrees with RTL cr_pkt_seen_rx")
        assert wit.cr_pulses[side] > 0, f"[{side}] pkt_is_cr_pkt never pulsed"


@cocotb.test()
async def test_cold_bringup_cr_seen(dut):
    """THE ORACLE (FCSM_SRC-keyed).
      deps  (GREEN): cr_seen -> 1 and cal_done -> 1 within POLL_CHUNKS; a CR
                     crossed (pkt_is_cr_pkt pulsed).
      local (RED):   cr_seen stays 0 for a sustained window and NO CR ever
                     crossed (pkt_is_cr_pkt never pulses).  The 4-tuple and the
                     exact silicon status word are recorded but the LOAD-BEARING
                     RED assertion is cr_seen==0 + no cr pulse (see doc: cal_done
                     may time-out to 1 under V2 VAL_TIMEOUT_TO_DONE)."""
    dut._log.info(f"=== cold cr_seen oracle === FCSM_SRC={FCSM_SRC} "
                  f"CAL_BYPASS={CAL_BYPASS}")
    tb = make_tb(dut)
    wit = Witness(tb)
    await tb.reset()
    wit.start()
    if CAL_BYPASS:
        tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.do_to_data_mode()

    if FCSM_SRC == "deps":
        conv = await _poll(tb, wit, dut, converge=True)
        wit.stop()
        for side in ("m", "s"):
            cr, crack, cal, fcsm, st = await _tuple(tb, side)
            dut._log.info(f"  GREEN [{side}] cr={cr} cal={cal} fcsm={fcsm} "
                          f"0x{st:08x} cr_pulses={wit.cr_pulses[side]}")
            assert cr == 1 and cal == 1, (
                f"[{side}] GREEN(deps) FAILED to converge: cr={cr} cal={cal}")
            assert wit.cr_pulses[side] > 0, f"[{side}] deps CR never crossed"
        return

    # RED (local): the CR must NEVER cross.  Poll the full budget without early
    # exit, then require a sustained cr_seen=0 with no cr pulses.
    await _poll(tb, wit, dut, converge=False)
    # sustain check
    for _ in range(SETTLE_CHUNKS):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            cr, crack, cal, fcsm, st = await _tuple(tb, side)
            assert cr == 0, (
                f"[{side}] NOT RED: cr_seen={cr} latched (status=0x{st:08x}) "
                f"cr_pulses={wit.cr_pulses[side]}")
    wit.stop()
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        dut._log.info(f"  RED [{side}] cr={cr} crack={crack} cal={cal} fcsm={fcsm} "
                      f"0x{st:08x} cr_pulses={wit.cr_pulses[side]} "
                      f"grants[{wit.grant_summary(side)}]")
        assert not _status_has_x(tb, side), f"[{side}] SWI_LANE_STATUS read X"
        assert wit.cr_pulses[side] == 0, (
            f"[{side}] pkt_is_cr_pkt PULSED in RED ({wit.cr_pulses[side]}x) -- a "
            f"CR crossed; this is the emit-gate livelock (blind), NOT cr_seen=0")
    dut._log.info("  RED reproduced: cr_seen=0 sustained, no CR crossed")


@cocotb.test()
async def test_refuted_fix_stays_red(dut):
    """Plan 5.5: the refuted emit-gate fix MUST NOT green a faithful cr_seen=0
    RED. Compile the fix in (Makefile HOLD_ALWAYS / L6=1 as configured) and assert
    the RED still holds (cr_seen=0, no CR pulse). If cr_seen reaches 1 here, the
    sim is reproducing the emit-gate livelock, not the deadlock -- fidelity fail."""
    assert FCSM_SRC == "local", "refuted-fix check is a local-FCSM RED control"
    dut._log.info("=== refuted-fix-stays-red ===")
    tb = make_tb(dut)
    wit = Witness(tb)
    await tb.reset()
    wit.start()
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.do_to_data_mode()
    await _poll(tb, wit, dut, converge=False)
    wit.stop()
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        dut._log.info(f"  [{side}] cr={cr} cal={cal} fcsm={fcsm} 0x{st:08x} "
                      f"cr_pulses={wit.cr_pulses[side]}")
        assert cr == 0, (
            f"[{side}] FIDELITY FAILURE: the refuted emit-gate fix greened the "
            f"RED (cr_seen={cr}); sim reproduces the emit-gate livelock, not "
            f"the cr_seen=0 deadlock silicon shows.")
        assert wit.cr_pulses[side] == 0, f"[{side}] CR crossed under the refuted fix"
    dut._log.info("  refuted fix correctly STAYED RED (matches silicon)")

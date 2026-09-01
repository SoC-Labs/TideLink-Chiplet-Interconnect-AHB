"""TL-044 PARK RECIPE — can a parked XHB500 port be armed ON DEMAND, and what
does it actually do afterwards?

WHY THIS FILE EXISTS
--------------------
test_tl044_read_deadgate.py tests the CONTAINMENT.  Its NEVER and RECOVERED
arms are driven by a real fault (the far AHB terminus stops responding); its
INTERMITTENT arm is driven by FORCING `xhb_sub_hreadyout_raw` to author a
waveform "because nobody has yet measured what the real bridge does after this
park".  That leaves the exit branch — the one property a hardware test would
have to confirm — resting on an authored waveform.

This file answers the two questions the containment tests do not:

  1. WHAT STIMULUS PARKS THE REAL BRIDGE?  Two independent recipes are driven
     here, neither of which forces any signal in the design:
       S1  the far terminus stops answering  (u_s_mng_bram.force_stall, a
           testbench MEMORY MODEL knob, not a force on a DUT net).  Hardware
           analogue: a cross-die access to a peer address with no responder, or
           a peer subsystem held in reset with the link still up.
       S2  the R packet is lost IN THE LINK, with the far die perfectly healthy
           (persistent pktnum corruption on the far die's R node — the Wlink
           built-in injector, the on-silicon 0x2E03_003C model).  This is the
           SILICON signature: 0x21F8 bit[9]=1 with the peer alive.
     Both are shown to produce the same INTERNAL park signature, which is what
     makes them the same defect and not two coincidences.

  2. WHICH EXIT BRANCH DOES IT TAKE?  Answered structurally, not statistically.
     Once the port is parked, XHB500's `ready_for_read` is 0
     (core_resp.sv:233), which holds `pause_addr_submit` (core_addr.sv:153) and
     stops any further AR being submitted.  No AR => no R => no `r_done` =>
     `read_counter` can never decrement.  So the ONLY event that can ever un-park
     the port is the arrival of the ORIGINAL transaction's R.  Which branch you
     get is therefore decided ENTIRELY by the fault, not by the bridge:

        R lost forever   -> NEVER        (test_park_exit_is_structurally_never)
        R merely late    -> RECOVERED    (test_park_exit_recovers_when_late)
        R late, repeatedly -> INTERMITTENT (test_park_exit_intermittent_latches)

     All three are exercised here with real stimulus and NO Force anywhere, so
     the containment's three branches are no longer characterised only against
     an authored waveform.

INSTRUMENT BEFORE DUT
---------------------
Every test here takes its measurements with the SAME monitor over a clean
pre-fault window first, and requires that window to show the opposite reading
(raw high, read_counter 0, AR accepts > 0).  A monitor that reports "parked"
because it is reading a signal that does not exist, or counting a handshake
that never fires, is exactly the failure this repository has been bitten by;
`_g()` returning a default silently is the shape of that bug, so the pre-fault
control is mandatory in every test and is reported as CANNOT-EVALUATE, never
as a pass.

RED PROOF — every test here has been demonstrated FAILING
--------------------------------------------------------
Single-line mutations were applied to the DUT, the suite re-run, and the
sources restored and verified: `find deps/xhb500/generated -type f | sort |
xargs md5sum | md5sum` = 391c23fd3cc0af55f3828bce50ae1924 before AND after, and
`git diff --quiet -- src/rtl/tidelink_top.sv` clean before AND after.  Victim
lists were RECORDED, not predicted:

  MP1 slv_core_resp  assign ready_for_read = 1'b1
                     -> park_recipe_far_terminus_stall, park_recipe_lost_r_in_link
                     NOTE: this does NOT redden the three exit tests, and that
                     is a finding, not a gap — the park is enforced by the RESP
                     FSM sitting in SEQ_NSEQ with no beat_done, not by
                     ready_for_read alone.  ready_for_read only stops the NEXT
                     AR; hreadyout is what holds the bus.
  MP2a tidelink_top  relapse-latch condition -> if (1'b0)   (never latches)
                     -> park_exit_intermittent_latches
  MP2b tidelink_top  relapse-latch condition -> if (1'b1)   (latches on arm 1)
                     -> park_exit_intermittent_latches
                     MP2a/MP2b are the two-sided pair: the test cannot pass
                     against a latch stuck either way.
  MP3  tidelink_top  the RECOVERED arm's `xhb_dead_r <= 1'b0` -> 1'b1
                     -> park_exit_recovers_when_late, park_exit_intermittent_latches
  MP4  slv_core_resp RESP_FSM_SEQ_NSEQ `hreadyout = beat_done & ~axi_err`
                     -> `hreadyout = 1'b1`   (the port cannot stay parked)
                     -> ALL FIVE tests

Two of this file's own diagnostics were caught FAILING SILENTLY during
development and are recorded here because the same shape will recur:
  * the R-beat tap read tidelink_top's `s_axi_rvalid`, which does not resolve
    to a readable handle in this build.  It reported r_beats=0 on a HEALTHY
    link — a park signature — until the mandatory clean control refused it.
    The taps now come from the XHB500 RESP block and `ParkMon.taps` records by
    name which handles resolved.
  * the clean control's monitor had a fixed 4000-cycle budget and stopped
    before a cross-die read completed, again reporting r_beats=0.  The budget
    is now a ceiling, not a window.

BUILD: the same short windows as the `tl044` target — the backstop and the
containment arm/debounce must both be reachable inside a sim.

  make -C cocotb/tidelink_axi_datanode_recovery tl044_park
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
    _arm_injector_persistent, _disarm_injector, NODES, BYTE_PKTNUM,
)

STALL_LOG2   = int(os.environ.get("TL044_STALL_LOG2", "13"))
ARM_LOG2     = int(os.environ.get("TL044_ARM_LOG2", "8"))
RECOVER_LOG2 = int(os.environ.get("TL044_RECOVER_LOG2", "8"))
RELAPSE_MAX  = int(os.environ.get("TL044_RELAPSE_MAX", "2"))

STALL_WINDOW   = 1 << STALL_LOG2
ARM_WINDOW     = 1 << ARM_LOG2
RECOVER_WINDOW = 1 << RECOVER_LOG2

# XHB500 slv RESP FSM encoding (core_resp.sv:76-79).
FSM_IDLE_BUSY, FSM_SEQ_NSEQ, FSM_ERROR, FSM_LOCK_ERROR = 0, 1, 2, 3

OFF_A    = 0x300     # the read that gets stuck
OFF_B    = 0x1340    # a DIFFERENT 4KB page (no XHB500 hazard-list address match)
OFF_POST = 0x400
D_A, D_B, D_POST = 0x5EED0042, 0x5EED1043, 0xA5A50FF0

TIMEOUT = 6 * STALL_WINDOW


def _g(obj, name, default=None):
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return default


def _present(obj, name):
    """Does this tap RESOLVE to a readable handle at all?

    `_g` returning its default on a missing handle is the exact shape of a
    diagnostic that cannot fail, so every tap this file relies on is checked
    for presence separately and reported by name.  A missing tap is
    COULD-NOT-EVALUATE, never a pass."""
    if obj is None:
        return False
    try:
        getattr(obj, name).value
        return True
    except Exception:
        return False


class ParkMon:
    """Samples the PARK ITSELF — XHB500's own internal state — not just the
    containment's opinion of it.

    Every field here answers a specific question:
      raw_high            is the port ready at all?
      rc_nonzero/rc_max   is XHB500's read_counter parked non-zero?  (the
                          documented cause: decremented ONLY by r_done,
                          core_resp.sv:115-123)
      rfr_low             is ready_for_read 0? (core_resp.sv:233 — the term
                          that holds pause_addr_submit and blocks the next AR)
      fsm_seq_nseq        is the RESP FSM stuck in SEQ_NSEQ, i.e. still waiting
                          for a beat that will not come?
      ar_accepts          how many ARs were accepted?  ZERO after the park is
                          the structural proof that no NEW read can ever
                          generate the r_done that would un-park it.
      r_beats             how many R beats arrived?
    """

    def __init__(self, dut):
        self.dut = dut
        self.top = dut.u_master
        self.resp = None
        try:
            self.resp = dut.u_master.u_xhb_sub.u_core.u_resp
        except Exception:
            self.resp = None
        # rvalid/rready are read from the XHB500 RESP block, not from
        # tidelink_top's s_axi_* wires: the top-level net for rvalid does not
        # resolve to a readable handle in this build (MEASURED -- the first run
        # of this file reported rvalid_high=0 across a window in which
        # read_counter demonstrably went 1 -> 0, i.e. an r_done had happened).
        # Taking them where they are named signals removes that failure mode,
        # and `taps` below records exactly which handles resolved.
        self.rsrc = self.resp
        self.taps = {
            "u_resp": self.resp is not None,
            "resp.rvalid": _present(self.resp, "rvalid"),
            "resp.rready": _present(self.resp, "rready"),
            "resp.r_done": _present(self.resp, "r_done"),
            "resp.read_counter": _present(self.resp, "read_counter"),
            "resp.ready_for_read": _present(self.resp, "ready_for_read"),
            "resp.resp_fsm_state": _present(self.resp, "resp_fsm_state"),
            "top.raw": _present(self.top, "xhb_sub_hreadyout_raw"),
            "top.s_axi_arvalid": _present(self.top, "s_axi_arvalid"),
            "top.s_axi_arready": _present(self.top, "s_axi_arready"),
            "top.sub_err1_r": _present(self.top, "sub_err1_r"),
            "top.xhb_dead_r": _present(self.top, "xhb_dead_r"),
        }
        self.reset()

    def reset(self):
        self.cycles = 0
        self.raw_high = 0
        self.rc_nonzero = 0
        self.rc_max = 0
        self.rc_values = set()
        self.rfr_low = 0
        self.fsm_seq_nseq = 0
        self.fsm_states = set()
        self.ar_accepts = 0
        self.aw_accepts = 0
        self.r_beats = 0
        self.rvalid_high = 0
        self.rready_high = 0
        self.r_done = 0
        self.err1_rises = 0
        self.dead_arms = 0
        self.dead_clears = 0
        self.perm_seen = 0
        self.raw_low_run = 0
        self.raw_low_run_max = 0
        self.first_raw_high = None
        self._prev_e1 = 0
        self._prev_dead = 0

    async def run(self, cycles):
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            self.cycles += 1

            raw = _g(self.top, "xhb_sub_hreadyout_raw", None)
            if raw is None:
                continue                      # counted as neither; see readable()
            if raw:
                self.raw_high += 1
                self.raw_low_run = 0
                if self.first_raw_high is None:
                    self.first_raw_high = self.cycles
            else:
                self.raw_low_run += 1
                if self.raw_low_run > self.raw_low_run_max:
                    self.raw_low_run_max = self.raw_low_run

            if self.resp is not None:
                rc = _g(self.resp, "read_counter", None)
                if rc is not None:
                    self.rc_values.add(rc)
                    if rc:
                        self.rc_nonzero += 1
                    if rc > self.rc_max:
                        self.rc_max = rc
                rfr = _g(self.resp, "ready_for_read", None)
                if rfr == 0:
                    self.rfr_low += 1
                st = _g(self.resp, "resp_fsm_state", None)
                if st is not None:
                    self.fsm_states.add(st)
                    if st == FSM_SEQ_NSEQ:
                        self.fsm_seq_nseq += 1

            if _g(self.top, "s_axi_arvalid", 0) and _g(self.top, "s_axi_arready", 0):
                self.ar_accepts += 1
            if _g(self.top, "s_axi_awvalid", 0) and _g(self.top, "s_axi_awready", 0):
                self.aw_accepts += 1
            rv = _g(self.rsrc, "rvalid", 0)
            rr = _g(self.rsrc, "rready", 0)
            if rv:
                self.rvalid_high += 1
            if rr:
                self.rready_high += 1
            if rv and rr:
                self.r_beats += 1
            # r_done is XHB500's OWN decrement term (core_resp.sv:104) -- the
            # single signal the whole NEVER argument rests on. Kept alongside
            # the raw handshake so a zero can be told apart from a dead tap.
            if _g(self.resp, "r_done", 0):
                self.r_done += 1

            e1 = _g(self.top, "sub_err1_r", 0) or 0
            if e1 and not self._prev_e1:
                self.err1_rises += 1
            self._prev_e1 = e1

            d = _g(self.top, "xhb_dead_r", 0) or 0
            if d and not self._prev_dead:
                self.dead_arms += 1
            if self._prev_dead and not d:
                self.dead_clears += 1
            self._prev_dead = d
            if _g(self.top, "xhb_dead_perm_r", 0):
                self.perm_seen = 1

    def missing_taps(self):
        """Names of the taps that do NOT resolve.  A monitor whose taps are
        absent reports a perfect park, which is the false-green shape this
        repository has documented more than once."""
        return sorted(k for k, v in self.taps.items() if not v)

    def s(self):
        return dict(cycles=self.cycles, raw_high=self.raw_high,
                    raw_low_run_max=self.raw_low_run_max,
                    first_raw_high=self.first_raw_high,
                    rc_nonzero=self.rc_nonzero, rc_max=self.rc_max,
                    rc_values=sorted(self.rc_values), rfr_low=self.rfr_low,
                    fsm_seq_nseq=self.fsm_seq_nseq,
                    fsm_states=sorted(self.fsm_states),
                    ar_accepts=self.ar_accepts, aw_accepts=self.aw_accepts,
                    r_beats=self.r_beats, rvalid_high=self.rvalid_high,
                    rready_high=self.rready_high, r_done=self.r_done,
                    err1_rises=self.err1_rises,
                    dead_arms=self.dead_arms, dead_clears=self.dead_clears,
                    perm_seen=self.perm_seen)


async def _watch(dut, cycles, mon=None):
    mon = mon or ParkMon(dut)
    mon.reset()
    t = cocotb.start_soon(mon.run(cycles))
    await ClockCycles(dut.hclk, cycles + 5)
    t.kill()
    return mon


async def _stick_and_measure(dut, master, label, window):
    """Drive the stuck read with the monitor ALREADY running (so the one-shot
    sub_err1_r is captured), then measure the park window separately."""
    mon = ParkMon(dut)
    mon.reset()
    t = cocotb.start_soon(mon.run(1_000_000))
    try:
        await master.read(APER_BASE + OFF_A, timeout=TIMEOUT)
        cls = "OK"
    except RuntimeError:
        cls = "ERROR"
    except TimeoutError:
        cls = "HANG"
    await ClockCycles(dut.hclk, 20)
    err1 = mon.err1_rises
    t.kill()
    assert cls == "ERROR", (
        f"COULD-NOT-EVALUATE [{label}] — the read backstop did not retire the "
        f"stuck read (class={cls}); nothing after this point is interpretable.")
    park = await _watch(dut, window)
    return cls, err1, park


async def _clean_control(dut, master, label):
    """MANDATORY pre-fault control.  The same monitor over healthy traffic must
    read the OPPOSITE of a park.  Without it, every 'parked' verdict below
    would be indistinguishable from a monitor reading nothing at all."""
    mon = ParkMon(dut)
    missing = mon.missing_taps()
    dut._log.info(f"[park] taps [{label}]: {mon.taps}")
    assert not missing, (
        f"COULD-NOT-EVALUATE [{label}] — these ParkMon taps do not resolve in "
        f"this build: {missing}. Every verdict below would be vacuous.")
    mon.reset()
    # The budget is a CEILING, not a window: a cross-die write/read round trip
    # is several thousand hclk at the silicon clock ratio, and a monitor that
    # stopped before the read completed reported r_beats=0 on a perfectly
    # healthy link on the first run of this file. The task is killed when the
    # traffic is done, so `cycles` in the log is the real length.
    t = cocotb.start_soon(mon.run(1_000_000))
    await master.write(APER_BASE + OFF_A, D_A)
    await master.write(APER_BASE + OFF_B, D_B)
    await ClockCycles(dut.hclk, 1500)
    v = await master.read(APER_BASE + OFF_A)
    await ClockCycles(dut.hclk, 400)
    t.kill()
    s = mon.s()
    dut._log.info(f"[park] CLEAN CONTROL [{label}]: {s}")
    assert v == D_A, f"COULD-NOT-EVALUATE [{label}] — clean peer read broken (0x{v:08x})"
    assert s["raw_high"] > 0, (
        f"COULD-NOT-EVALUATE [{label}] — xhb_sub_hreadyout_raw never read HIGH "
        f"on a HEALTHY link, so a later 'raw never high' proves nothing. {s}")
    assert s["ar_accepts"] > 0, (
        f"COULD-NOT-EVALUATE [{label}] — no AR was ever seen accepted on a "
        f"healthy link, so a later ar_accepts==0 proves nothing. {s}")
    assert s["r_beats"] > 0 and s["r_done"] > 0, (
        f"COULD-NOT-EVALUATE [{label}] — no R beat was seen on a HEALTHY link "
        f"(r_beats={s['r_beats']} r_done={s['r_done']} "
        f"rvalid_high={s['rvalid_high']} rready_high={s['rready_high']}). "
        f"Either the R tap is mis-named or the read did not use the AXI path; "
        f"a later r_beats==0 would prove nothing. {s}")
    assert 0 in s["rc_values"], (
        f"COULD-NOT-EVALUATE [{label}] — read_counter never read 0 on a healthy "
        f"link, so a later 'parked non-zero' proves nothing. {s}")
    return s


def _assert_parked(s, label, window, err1_rises):
    """The PARK SIGNATURE, stated as five independent readings that must agree.

    `err1_rises` is measured over the window that CONTAINS the stuck read, not
    over the post-backstop window: sub_err{1,2}_r are one-shots that have
    already retired by the time the park window opens, so looking for them
    there finds nothing and would make the precondition unfalsifiable."""
    assert err1_rises >= 1, (
        f"[{label}] NOT PARKED — the read backstop never fired (sub_err1_r "
        f"rises={err1_rises}), so this is not the TL-044 precondition. {s}")
    assert s["raw_high"] == 0, (
        f"[{label}] NOT PARKED — xhb_sub_hreadyout_raw went HIGH for "
        f"{s['raw_high']} of {window} cycles after the backstop. {s}")
    assert s["rc_max"] > 0 and s["rc_nonzero"] == s["cycles"], (
        f"[{label}] the park is not the documented one — XHB500's read_counter "
        f"is not parked non-zero for the whole window (max={s['rc_max']}, "
        f"nonzero={s['rc_nonzero']}/{s['cycles']}). {s}")
    assert s["rfr_low"] == s["cycles"], (
        f"[{label}] ready_for_read was HIGH for "
        f"{s['cycles'] - s['rfr_low']} cycles, so the port was not actually "
        f"blocked. {s}")
    assert s["fsm_seq_nseq"] == s["cycles"], (
        f"[{label}] the RESP FSM left SEQ_NSEQ ({s['fsm_states']}) — it is not "
        f"waiting on a beat that never comes. {s}")


# =============================================================================
# RECIPE S1 — the far terminus stops answering
# =============================================================================
@cocotb.test()
async def test_park_recipe_far_terminus_stall(dut):
    """RECIPE S1.  Stop the far AHB terminus answering, drive one cross-die
    read, let the read backstop retire it — and the port is PARKED.

    No signal in the design is forced: `force_stall` is a knob on the bench's
    behavioural BRAM (tb_top.sv:1075), i.e. a property of the far MEMORY, which
    is what a peer subsystem held in reset or an unanswered peer address looks
    like from this side.

    Records the internal signature so this park can be compared with S2's."""
    tb, master = await _bringup(dut)
    await _clean_control(dut, master, "S1")

    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 20)
    window = 6 * ARM_WINDOW
    _cls, err1, mon = await _stick_and_measure(dut, master, "S1", window)
    s = mon.s()
    dut._log.info(f"[park] S1 far-terminus stall, err1_rises={err1}, "
                  f"post-backstop {window} cy: {s}")
    _release_all(tb)
    _assert_parked(s, "S1", window, err1)
    assert s["ar_accepts"] == 0, (
        f"[S1] an AR was accepted while parked ({s['ar_accepts']}) — the park "
        f"is not blocking new reads and the structural argument fails. {s}")


# =============================================================================
# RECIPE S2 — the R is lost IN THE LINK, far die healthy
# =============================================================================
@cocotb.test()
async def test_park_recipe_lost_r_in_link(dut):
    """RECIPE S2.  The far die answers perfectly; the R packet never survives
    the link (persistent pktnum corruption on the far die's R node, so every
    NACK-driven replay is re-corrupted and the response never converges).

    This is the SILICON case: peer alive, local read_counter parked.  S1 could
    be dismissed as "both ends are broken"; S2 cannot.  The far terminus is
    NEVER stalled in this test — asserted, not assumed.

    Same five-reading park signature as S1.  Two stimuli, one signature."""
    tb, master = await _bringup(dut)
    await _clean_control(dut, master, "S2")

    assert int(dut.u_s_mng_bram.force_stall.value) == 0, (
        "COULD-NOT-EVALUATE — the far terminus is stalled in a test whose whole "
        "point is that it is not")

    await _arm_injector_persistent(tb, "s", NODES["R"]["data_id"], BYTE_PKTNUM)
    window = 6 * ARM_WINDOW
    _cls, err1, mon = await _stick_and_measure(dut, master, "S2", window)
    s = mon.s()
    dut._log.info(f"[park] S2 lost-R-in-link, err1_rises={err1}, "
                  f"post-backstop {window} cy: {s}")
    assert int(dut.u_s_mng_bram.force_stall.value) == 0, \
        "the far terminus became stalled during the run"
    _release_all(tb)
    _assert_parked(s, "S2", window, err1)
    assert s["ar_accepts"] == 0, (
        f"[S2] an AR was accepted while parked ({s['ar_accepts']}). {s}")


# =============================================================================
# EXIT — NEVER, and WHY it is never
# =============================================================================
@cocotb.test()
async def test_park_exit_is_structurally_never(dut):
    """EXIT BRANCH: NEVER — established as a STRUCTURE, not as a long wait.

    "We watched for N cycles and nothing happened" is weak evidence.  The
    strong statement is the one the RTL makes: while parked, ready_for_read is
    0, so pause_addr_submit holds and NO further AR is submitted; with no AR
    there is no R, with no R there is no r_done, and read_counter is
    decremented by NOTHING ELSE (core_resp.sv:115-123).  The only event that
    can un-park the port is the arrival of the ORIGINAL R.

    This test measures the two facts that argument needs, across a window with
    ONGOING ATTEMPTED TRAFFIC (an idle bus would make ar_accepts==0 trivially
    true, which is why traffic is driven throughout):

        ar_accepts == 0     no new read is admitted, so no new r_done is
                            possible
        read_counter never changes value

    With the R permanently lost, both hold, and the branch is NEVER by
    construction rather than by observation."""
    tb, master = await _bringup(dut)
    ctl = await _clean_control(dut, master, "NEVER")

    await _arm_injector_persistent(tb, "s", NODES["R"]["data_id"], BYTE_PKTNUM)
    try:
        await master.read(APER_BASE + OFF_A, timeout=TIMEOUT)
    except RuntimeError:
        pass
    except TimeoutError:
        _release_all(tb)
        raise AssertionError("COULD-NOT-EVALUATE — the read hung instead of "
                             "being retired by the backstop")

    mon = ParkMon(dut)
    mon.reset()
    window = 8 * ARM_WINDOW
    t = cocotb.start_soon(mon.run(window))

    # Drive traffic THROUGHOUT, so ar_accepts==0 is a real refusal and not the
    # absence of any request. Each of these is expected to be retired by the
    # containment; what matters is that none of them reaches AXI.
    attempts = {"ERROR": 0, "OK": 0, "HANG": 0}
    for i in range(6):
        for addr, wr in ((OFF_B, False), (OFF_B, True), (OFF_A, False)):
            try:
                if wr:
                    await master.write(APER_BASE + addr, 0xD0D0_0000 + i,
                                       timeout=4 * ARM_WINDOW)
                else:
                    await master.read(APER_BASE + addr, timeout=4 * ARM_WINDOW)
                attempts["OK"] += 1
            except RuntimeError:
                attempts["ERROR"] += 1
            except TimeoutError:
                attempts["HANG"] += 1
    await ClockCycles(dut.hclk, 200)
    t.kill()
    s = mon.s()
    dut._log.info(f"[park] NEVER: attempts={attempts} {s}")
    _release_all(tb)

    assert s["raw_high"] == 0, (
        f"the bridge un-parked on its own (raw high {s['raw_high']} cycles) — "
        f"the NEVER branch is not what this fault produces. {s}")
    assert s["ar_accepts"] == 0, (
        f"THE STRUCTURAL ARGUMENT FAILS: {s['ar_accepts']} AR(s) were accepted "
        f"while the port was parked, so a NEW read could generate the r_done "
        f"that decrements read_counter, and the park would NOT be structurally "
        f"permanent. {s}")
    assert s["r_beats"] == 0 and s["r_done"] == 0, (
        f"an R beat arrived while parked (r_beats={s['r_beats']} "
        f"r_done={s['r_done']}) — see above. {s}")
    assert len(s["rc_values"]) == 1 and s["rc_values"][0] > 0, (
        f"read_counter moved while parked ({s['rc_values']}); with no r_done "
        f"it cannot, so either the monitor or the argument is wrong. {s}")
    # The control read the opposite on healthy traffic — stated here so the
    # verdict and its refutation live in the same log line.
    assert ctl["ar_accepts"] > 0 and ctl["r_beats"] > 0 and ctl["r_done"] > 0
    assert attempts["OK"] + attempts["ERROR"] + attempts["HANG"] == 18


# =============================================================================
# EXIT — RECOVERED, driven by a real late R
# =============================================================================
@cocotb.test()
async def test_park_exit_recovers_when_late(dut):
    """EXIT BRANCH: RECOVERED — with a real late R, not an authored waveform.

    Park via S1, hold the park long enough to be sure it IS a park, then let
    the far terminus answer.  The original transaction's R arrives, r_done
    fires, read_counter returns to 0, raw goes high and STAYS high, and the
    containment sticky clears after its debounce.  A clean peer read afterwards
    must be byte-exact — a recovery that leaves the port unusable is not a
    recovery.

    ATTRIBUTION: the park window is measured FIRST and must show raw_high == 0,
    so the raw that appears afterwards is attributable to the release and not
    to the bridge having quietly recovered on its own."""
    tb, master = await _bringup(dut)
    await _clean_control(dut, master, "RECOVERED")

    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 20)
    try:
        await master.read(APER_BASE + OFF_A, timeout=TIMEOUT)
    except RuntimeError:
        pass
    except TimeoutError:
        _release_all(tb)
        raise AssertionError("COULD-NOT-EVALUATE — the stuck read was not retired")

    parked = await _watch(dut, 4 * ARM_WINDOW)
    ps = parked.s()
    dut._log.info(f"[park] RECOVERED, park window: {ps}")
    assert ps["raw_high"] == 0, (
        f"COULD-NOT-EVALUATE — the port was not parked before the release "
        f"(raw high {ps['raw_high']} cycles), so any later recovery is not "
        f"attributable to the release. {ps}")
    assert ps["dead_arms"] >= 1, (
        f"COULD-NOT-EVALUATE — the containment never armed, so 'it cleared' "
        f"below would be vacuous. {ps}")

    dut.u_s_mng_bram.force_stall.value = 0
    rec = await _watch(dut, 4 * RECOVER_WINDOW + 4000)
    rs = rec.s()
    dut._log.info(f"[park] RECOVERED, post-release window: {rs}")

    assert rs["raw_high"] > 0, (
        f"THE LATE R DID NOT UN-PARK THE BRIDGE: with the far terminus "
        f"answering again, xhb_sub_hreadyout_raw stayed low for all "
        f"{rs['cycles']} cycles. The RECOVERED branch would then be "
        f"unreachable in reality and TL-044 should say so. {rs}")
    assert rs["r_beats"] >= 1 and rs["r_done"] >= 1, (
        f"raw returned but no R beat was seen — the recovery did not come from "
        f"the mechanism this test claims. {rs}")
    assert 0 in rs["rc_values"], (
        f"read_counter never returned to 0 after the late R. {rs}")
    assert rs["dead_clears"] >= 1 and _g(dut.u_master, "xhb_dead_r") == 0, (
        f"the containment sticky never cleared after a genuine recovery. {rs}")
    assert _g(dut.u_master, "xhb_dead_perm_r") == 0, (
        "the anti-oscillation latch engaged after a single arm/clear")

    await master.write(APER_BASE + OFF_POST, D_POST, timeout=TIMEOUT)
    await ClockCycles(dut.hclk, 3000)
    landed = _slave_bram_peek(dut, OFF_POST)
    got = await master.read(APER_BASE + OFF_POST, timeout=TIMEOUT)
    _release_all(tb)
    assert landed == D_POST, f"post-recovery write landed 0x{landed:08x}"
    assert got == D_POST, f"post-recovery read returned 0x{got:08x}"


# =============================================================================
# EXIT — INTERMITTENT, with no forced waveform
# =============================================================================
@cocotb.test()
async def test_park_exit_intermittent_latches(dut):
    """EXIT BRANCH: INTERMITTENT — RELAPSE_MAX+1 GENUINE park/recover cycles,
    driven entirely by the far terminus going away and coming back.  Nothing is
    forced; this is the arm that test_tl044_intermittent_does_not_thrash has to
    author with Force because it drives raw directly.

    SELF-CONTAINED RED/GREEN: xhb_dead_perm_r is sampled after EVERY arm.  It
    must be 0 after each of the first RELAPSE_MAX arms and 1 after the next
    one.  A latch that is stuck set fails the first check; a latch that never
    sets fails the last; a test that only looked at the end could pass against
    either."""
    tb, master = await _bringup(dut)
    await _clean_control(dut, master, "INTERMITTENT")

    perm_after = []
    dead_after = []
    for i in range(RELAPSE_MAX + 1):
        dut.u_s_mng_bram.force_stall.value = 1
        await ClockCycles(dut.hclk, 20)
        try:
            await master.read(APER_BASE + OFF_A, timeout=TIMEOUT)
            cls = "OK"
        except RuntimeError:
            cls = "ERROR"
        except TimeoutError:
            cls = "HANG"
        assert cls == "ERROR", (
            f"COULD-NOT-EVALUATE — relapse {i}: the stuck read was not retired "
            f"(class={cls})")
        # let the containment arm
        await ClockCycles(dut.hclk, 2 * ARM_WINDOW + 200)
        armed = _g(dut.u_master, "xhb_dead_r")
        assert armed == 1, (
            f"COULD-NOT-EVALUATE — relapse {i}: the containment did not arm "
            f"(xhb_dead_r={armed}); the relapse counter cannot have advanced.")
        dead_after.append(armed)
        perm_after.append(_g(dut.u_master, "xhb_dead_perm_r"))

        # release: the pending far read completes, its R arrives, the port
        # un-parks and the sticky debounces clear (unless it has latched).
        dut.u_s_mng_bram.force_stall.value = 0
        await ClockCycles(dut.hclk, 4 * RECOVER_WINDOW + 4000)
        dut._log.info(f"[park] INTERMITTENT relapse {i}: perm={perm_after[-1]} "
                      f"dead_now={_g(dut.u_master, 'xhb_dead_r')} "
                      f"relapse_ctr={_g(dut.u_master, 'dg_relapse_ctr_r')}")

    perm_final = _g(dut.u_master, "xhb_dead_perm_r")
    dead_final = _g(dut.u_master, "xhb_dead_r")
    dut._log.info(f"[park] INTERMITTENT: perm_after={perm_after} "
                  f"perm_final={perm_final} dead_final={dead_final}")
    _release_all(tb)

    assert all(p == 0 for p in perm_after[:RELAPSE_MAX]), (
        f"the anti-oscillation latch engaged EARLY: xhb_dead_perm_r after each "
        f"arm was {perm_after}, but the first {RELAPSE_MAX} arms are within the "
        f"allowance and must not latch.")
    assert perm_after[RELAPSE_MAX] == 1, (
        f"THE THIRD BRANCH NEVER LATCHES: after {RELAPSE_MAX + 1} genuine "
        f"park/recover cycles xhb_dead_perm_r is {perm_after[RELAPSE_MAX]}. The "
        f"port would oscillate between pass-through and bounded-error mode "
        f"indefinitely, which is the state TL-044 says it will not leave the "
        f"port in. perm_after={perm_after}")
    assert perm_final == 1 and dead_final == 1, (
        f"the latch did not hold (perm={perm_final} dead={dead_final})")

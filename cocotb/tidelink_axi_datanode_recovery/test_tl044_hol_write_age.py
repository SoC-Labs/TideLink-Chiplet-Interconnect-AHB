"""TL-042 instance 1 — the ahb_sub write backstop STARVES: an aggregate-progress
age timer is re-zeroed by UNRELATED traffic, so a genuinely stuck write is never
timed out and the synth-B drain never arms.

SILICON EVIDENCE (given, not re-derived here). Region-F observability word
`0x8403_21F8` (tidelink_top.sv `xhb_sub_obs_word`) during a D2D peer-write wedge:

    healthy 0xB5000001      wedged 0xB5000498
                            bit[0]  xhb_sub_hreadyout_raw   = 0   bridge stalled
                            bit[3:1]sub_wr_os_ctr           = 4   4 writes outstanding
                            bit[4]  pipe_hprot_r[2]         = 1   bufferable / EWR
                            bit[7:5]sub_wr_os_hwm           = 4
                            bit[8]  sub_wr_stuck_sticky     = 0   <<< NEVER FIRED
                            bit[10] xhb_stall_stuck_sticky  = 1   raw low >= 2^12

`sub_wr_stuck_sticky` is SET-ONLY (two assignments in tidelink_top.sv: `<= 1'b0`
under `if (!hresetn)`, `<= 1'b1` on the fire condition), so bit[8]==0 PROVES the
expiry itself never happened -- the backstop is not masked, it is STARVED.

THE MECHANISM (the thing this file reproduces):

    sub_axi_progress = sub_r_done | sub_b_done;          // NO transaction identity
    if (!sub_axi_outstanding || sub_axi_progress) sub_osr_ctr_r <= '0;

    sub_ext_stalled  = (sub_stall_fill || sub_stall_busy) && !sub_err1_r && !sub_err2_r;
    if (!sub_ext_stalled) sub_stall_ctr_r <= '0;         // ANY raw-high pulse re-zeroes

ONE age counter is shared by every transaction on both channels. A READ that
completes pulses `sub_r_done` -> `sub_axi_progress` -> the counter of a WRITE
that is going nowhere is re-armed. Neither counter reaches its threshold, so
`sub_wr_stuck_fire = (sub_osr_expired | sub_stall_expired) & (sub_wr_os_ctr != 0)`
never asserts, `synth_b_pending` never sets, and the XHB500 hazard entry is never
freed. RAISING THE TIMEOUT CANNOT HELP -- the counters never reach ANY threshold.

WHY A CROSS-PAGE READ IS THE RIGHT STARVATION SOURCE (and why the existing
`test_i5_traffic_behind_a_stuck_write_is_bounded` measured the route as CLOSED):
XHB500 pauses a READ on `~ready_for_read || hazard_read`
(core_addr.sv:151-154) where `hazard = |match_addr_i` and
`match_addr_i[i] = (list_pointer>i) & (hazard_list_addr[i] == chk_addr[31:12])`
(hazard_list.sv:82) -- a 4KB-PAGE compare. That suite reads OFF_RD=0x300 while
the stuck write sits at OFF_POST=0x400: SAME page, so every read hazards behind
the stuck write and no concurrent progress can be generated. Read a DIFFERENT
page and the read is submitted, completes, and pulses `sub_r_done` -- the
starvation source, from ORDINARY traffic. A bufferable write never pauses on a
read (`pause_addr_submit`'s write arm keys on `hazard_full` only), so the AHB
master is free to issue those reads while the write is posted and stuck.

TESTS (each needs its OWN sim -- a second run_bringup_full does not re-POR):

  test_tl044_control_aggregate_backstop_fires_without_traffic   CONTROL
      Same stuck posted write, NO concurrent reads. The EXISTING aggregate
      backstop must fire (synth_b_pending rises, sub_wr_stuck_sticky sets).
      This is the non-vacuity control for the starvation claim itself: it proves
      the short-timeout build CAN expire, so a non-expiry in the primary test is
      caused by the re-zeroing and not by the timeout being long.

  test_tl044_starvation_defeats_the_aggregate_backstop          PRIMARY / A-B
      Same stuck posted write PLUS periodic cross-page reads. Asserts, in order:
        (a) STARVATION IS PRESENT -- sub_osr_ctr_r never reaches its expiry bit
            and sub_wr_stuck_sticky stays 0 while the write is outstanding, i.e.
            the silicon signature (bit[8]==0 with sub_wr_os_ctr != 0) is
            reproduced. Holds in BOTH builds; if it ever stops holding the test
            is no longer testing starvation and says so.
        (b) THE WRITE IS RETIRED ANYWAY -- some backstop must free it inside the
            observation window. FAILS on pre-fix RTL (nothing ever fires).

  test_tl044_escape_is_clean_and_normal_path_survives           ESCAPE-VS-SAFETY
      (a) the mechanism FIRES, (b) its own state CLEARS afterwards, (c) the
      NORMAL path still works: a clean peer write + read-back byte-exact with
      the fault removed.

  test_tl044_healthy_traffic_never_trips_the_watchdog           FALSE-FIRE GUARD
      No injection at all: a mixed write/read soak longer than the watchdog
      window must NOT arm it.

NO FORCED HANDSHAKES. Nothing here forces s_axi ready/valid. The only stimulus
hooks are the Wlink built-in error injector (the on-silicon 0x2E03_003C model)
and ordinary AHB traffic on m_ahb_sub_*.

BUILD: the two AGGREGATE timers short (2^13) so they are reachable in a sim, and
the head-of-line watchdog one binade above them (2^14) so it keeps its shipping
relationship to them (it must never pre-empt a backstop that would have fired).

  make -C cocotb/tidelink_axi_datanode_recovery tl044
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Helpers only -- importing a module that defines @cocotb.test() would pull its
# tests into this module's regression set, so only plain helpers are taken.
from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, _arm_injector_persistent,
    _disarm_injector, APER_BASE, NODES, BYTE_PKTNUM,
)

AGG_LOG2 = int(os.environ.get("TL044_AGG_LOG2", "13"))   # must match the build define
HOL_LOG2 = int(os.environ.get("TL044_HOL_LOG2", "14"))   # must match the build define
AGG_WINDOW = 1 << AGG_LOG2
HOL_WINDOW = 1 << HOL_LOG2

B_DATA_ID = NODES["B"]["data_id"]

# The stuck posted write and the starvation reads live in DIFFERENT 4KB pages so
# the reads cannot hazard behind the write (hazard_list.sv compares [31:12]).
# The far terminus is tb_ahb_bram_slave #(.AW(12)) (tb_top.sv:870), which aliases
# the page bits away, so the two must ALSO differ in [11:0] or they would be the
# same physical word.
OFF_STUCK = 0x200        # page 0x40000
OFF_RD    = 0x1340       # page 0x40001, aliases to word 0x340
OFF_POST  = 0x420        # page 0x40000, post-recovery clean transfer
D_STUCK   = 0xBEEF4442
D_RD      = 0x5EED4442
D_POST    = 0xA5A54442


def _g(obj, name, default=None):
    """Read a possibly-absent child signal (the pre-fix build lacks the new ones)."""
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return default


class HolWatch:
    """Samples every ahb_sub backstop input and output on every hclk.

    The measurement this file lives or dies by is narrow: while a write is
    OUTSTANDING (sub_wr_os_ctr != 0), how high did the shared age counter get,
    and did the write-stuck fire condition EVER assert? Those two numbers are
    the sim analogue of obs bits [3:1] and [8]."""

    def __init__(self, dut, master):
        self.dut = dut
        self.top = dut.u_master
        self.master = master
        self.cycle = 0
        # aggregate-timer starvation evidence
        self.osr_max = 0                 # max sub_osr_ctr_r seen with a write outstanding
        self.stall_max = 0               # max sub_stall_ctr_r seen with a write outstanding
        self.osr_expiries = 0
        self.stall_expiries = 0
        self.wr_stuck_fire_cycles = 0    # (osr_exp | stall_exp) & wr_os_ctr!=0
        # progress events that do the re-zeroing
        self.r_done = 0
        self.b_done = 0
        self.aw_accept = 0
        # backstop reactions
        self.synthb_rises = 0
        self.err1_rises = 0
        self.hol_b_rises = 0             # NEW watchdog drain (absent pre-fix)
        self.hol_age_max = 0
        self.hol_present = False
        # port-level
        self.wr_os_max = 0
        self.wr_outstanding_cycles = 0
        self.raw_low_run = 0
        self.raw_low_run_max = 0
        self.port_err_pulses = 0
        self.port_err_illegal = 0
        self.sticky_wr_stuck = 0
        self.sticky_hol = None

    async def run(self, cycles):
        prev_sb = prev_e1 = prev_hb = prev_resp = 0
        prev_osr_exp = prev_stall_exp = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            self.cycle += 1
            wr = _g(self.top, "sub_wr_os_ctr", 0)
            osr = _g(self.top, "sub_osr_ctr_r", 0)
            stall = _g(self.top, "sub_stall_ctr_r", 0)
            raw = _g(self.top, "xhb_sub_hreadyout_raw", 1)
            sb = _g(self.top, "synth_b_pending", 0)
            e1 = _g(self.top, "sub_err1_r", 0)

            osr_exp = (osr >> AGG_LOG2) & 1
            stall_exp = (stall >> AGG_LOG2) & 1

            if wr:
                self.wr_outstanding_cycles += 1
                if osr > self.osr_max:
                    self.osr_max = osr
                if stall > self.stall_max:
                    self.stall_max = stall
                if (osr_exp or stall_exp):
                    self.wr_stuck_fire_cycles += 1
            if wr > self.wr_os_max:
                self.wr_os_max = wr

            if osr_exp and not prev_osr_exp:
                self.osr_expiries += 1
            prev_osr_exp = osr_exp
            if stall_exp and not prev_stall_exp:
                self.stall_expiries += 1
            prev_stall_exp = stall_exp

            if raw:
                self.raw_low_run = 0
            else:
                self.raw_low_run += 1
                if self.raw_low_run > self.raw_low_run_max:
                    self.raw_low_run_max = self.raw_low_run

            # progress events -- read straight off the s_axi handshakes so the
            # count does not depend on any wrapper-internal name.
            try:
                if int(self.top.s_axi_rvalid.value) and int(self.top.s_axi_rready.value) \
                        and int(self.top.s_axi_rlast.value):
                    self.r_done += 1
            except Exception:
                pass
            try:
                if int(self.top.s_axi_bvalid.value) and int(self.top.s_axi_bready.value):
                    self.b_done += 1
            except Exception:
                pass
            try:
                if int(self.top.s_axi_awvalid.value) and int(self.top.s_axi_awready.value):
                    self.aw_accept += 1
            except Exception:
                pass

            if sb and not prev_sb:
                self.synthb_rises += 1
            prev_sb = sb
            if e1 and not prev_e1:
                self.err1_rises += 1
            prev_e1 = e1

            hb = _g(self.top, "sub_wr_hol_b_pending", None)
            if hb is not None:
                self.hol_present = True
                if hb and not prev_hb:
                    self.hol_b_rises += 1
                prev_hb = hb
            age = _g(self.top, "sub_wr_hol_age_r", None)
            if age is not None and age > self.hol_age_max:
                self.hol_age_max = age

            st = _g(self.top, "sub_wr_stuck_sticky", 0)
            if st:
                self.sticky_wr_stuck = 1
            hs = _g(self.top, "sub_wr_hol_stuck_sticky", None)
            if hs is not None:
                self.sticky_hol = hs

            try:
                resp = int(self.dut.m_ahb_sub_hresp.value)
            except Exception:
                resp = prev_resp
            if resp and not prev_resp:
                self.port_err_pulses += 1
                if not self.master.outstanding:
                    self.port_err_illegal += 1
            prev_resp = resp

    def summary(self):
        return {
            "cycles": self.cycle,
            "wr_os_max": self.wr_os_max,
            "wr_outstanding_cycles": self.wr_outstanding_cycles,
            "osr_max": self.osr_max, "agg_window": AGG_WINDOW,
            "stall_max": self.stall_max,
            "osr_expiries": self.osr_expiries,
            "stall_expiries": self.stall_expiries,
            "wr_stuck_fire_cycles": self.wr_stuck_fire_cycles,
            "r_done": self.r_done, "b_done": self.b_done, "aw_accept": self.aw_accept,
            "synthb_rises": self.synthb_rises, "err1_rises": self.err1_rises,
            "hol_present": self.hol_present, "hol_b_rises": self.hol_b_rises,
            "hol_age_max": self.hol_age_max, "hol_window": HOL_WINDOW,
            "sticky_wr_stuck": self.sticky_wr_stuck, "sticky_hol": self.sticky_hol,
            "raw_low_run_max": self.raw_low_run_max,
            "port_err_pulses": self.port_err_pulses,
            "port_err_illegal": self.port_err_illegal,
        }


async def _stick_a_posted_write(dut, tb, master):
    """Post ONE bufferable write whose B is PERMANENTLY lost.

    Persistent injection on the B node (0x82, byte 4 = pktnum) re-corrupts every
    NACK-driven REPLAY too, so the response can never converge -- the proven
    'permanently-lost response' vehicle from test_i5_error_is_ahb_legal. The
    write is BUFFERABLE (HPROT[2]=1) so XHB500's early-write-response releases
    the AHB master immediately: the bus goes IDLE with the write still
    outstanding on s_axi, which is the on-silicon shape (obs bit[4]=1)."""
    await _arm_injector_persistent(tb, "s", B_DATA_ID, BYTE_PKTNUM)
    try:
        await master.write_bufferable(APER_BASE + OFF_STUCK, D_STUCK,
                                      dut.u_master, timeout=20000)
        return "POSTED"
    except (TimeoutError, RuntimeError) as e:
        dut._log.info(f"[tl044] posted write did not post cleanly: {e}")
        return "NOT-POSTED"


async def _starvation_reads(dut, mon, master, cycles, gap=100, read_timeout=6000):
    """Keep the OTHER channel progressing for `cycles` hclk of REAL sim time.

    Each completed cross-page read pulses sub_r_done -> sub_axi_progress ->
    sub_osr_ctr_r <= 0. Elapsed time is taken from the monitor's own per-hclk
    cycle counter (NOT estimated from the loop shape -- a read's latency
    dominates the gap, so an estimate would overrun by an order of magnitude).
    The read timeout is deliberately BELOW the aggregate window so a read that
    is merely slow cannot be mistaken for the wedge, and the loop keeps going
    after a bounded read so one HRESP does not stop the starvation drive."""
    out = {"ok": 0, "err": 0, "hang": 0, "bad": 0, "cycles": 0}
    t0 = mon.cycle
    while (mon.cycle - t0) < cycles:
        try:
            got = await master.read(APER_BASE + OFF_RD, timeout=read_timeout)
            if got == D_RD:
                out["ok"] += 1
            else:
                out["bad"] += 1
        except RuntimeError:
            out["err"] += 1
        except TimeoutError:
            out["hang"] += 1
        await ClockCycles(dut.hclk, gap)
        if out["hang"] > 3:
            break
    out["cycles"] = mon.cycle - t0
    return out


def _fmt(s):
    return " ".join(f"{k}={v}" for k, v in s.items())


# =============================================================================
@cocotb.test()
async def test_tl044_control_aggregate_backstop_fires_without_traffic(dut):
    """CONTROL / non-vacuity of the starvation claim.

    IDENTICAL stuck posted write, but NOTHING else on the port. With no
    unrelated progress to re-zero it, the shared age counter must reach its
    expiry and the EXISTING backstop must fire (synth_b_pending rises and
    sub_wr_stuck_sticky sets = obs bit[8] goes 1).

    If this FAILS the primary test proves nothing: a non-expiry there could
    then be blamed on the timeout being unreachable in a sim rather than on
    the re-zeroing."""
    tb, master = await _bringup(dut)
    mon = HolWatch(dut, master)
    run = cocotb.start_soon(mon.run(6 * AGG_WINDOW))

    posted = await _stick_a_posted_write(dut, tb, master)
    await ClockCycles(dut.hclk, 4 * AGG_WINDOW)
    run.kill()
    _release_all(tb)
    s = mon.summary()
    dut._log.info(f"[tl044-control] posted={posted} {_fmt(s)}")

    assert s["wr_os_max"] > 0, (
        f"VEHICLE BROKEN: no write was ever outstanding on s_axi ({s}) -- the "
        f"bufferable write never reached the bridge, so nothing was stuck.")
    assert s["osr_expiries"] > 0 or s["stall_expiries"] > 0, (
        f"the aggregate age timer never expired even with an idle port ({s}). "
        f"The short-timeout build is not reachable in this window, so the "
        f"primary starvation test would be vacuous.")
    assert s["synthb_rises"] > 0, (
        f"the EXISTING synth-B backstop did not fire on an idle port with a "
        f"permanently-stuck posted write ({s}).")
    assert s["sticky_wr_stuck"] == 1, (
        f"sub_wr_stuck_sticky (obs bit[8]) never set on the control ({s}).")


# =============================================================================
@cocotb.test()
async def test_tl044_starvation_defeats_the_aggregate_backstop(dut):
    """PRIMARY / A-B — the same wedge, plus ORDINARY unrelated traffic.

    Cross-page reads complete while the posted write is permanently stuck. Every
    completion pulses sub_r_done -> sub_axi_progress -> sub_osr_ctr_r <= 0, and
    every raw-high cycle re-zeroes sub_stall_ctr_r. Neither reaches its
    threshold, so `sub_wr_stuck_fire` never asserts: the sim reproduction of
    obs bit[8]==0 with sub_wr_os_ctr != 0.

    (a) asserts the starvation is REAL and MEASURED (it must hold in both
        builds -- it is the precondition, not the fix).
    (b) asserts the stuck write is retired ANYWAY inside the window. That is
        the A-B discriminator: pre-fix nothing ever fires."""
    tb, master = await _bringup(dut)

    # Prove the cross-page read path works BEFORE the wedge, so a later failure
    # cannot be blamed on the vehicle.
    await master.write(APER_BASE + OFF_RD, D_RD)
    await ClockCycles(dut.hclk, 2000)
    pre = await master.read(APER_BASE + OFF_RD, timeout=20000)
    assert pre == D_RD, f"clean cross-page read failed pre-wedge: 0x{pre:08x}"

    mon = HolWatch(dut, master)
    run = cocotb.start_soon(mon.run(12 * HOL_WINDOW))

    posted = await _stick_a_posted_write(dut, tb, master)

    # Drive unrelated progress for well past BOTH windows.
    reads = await _starvation_reads(dut, mon, master, cycles=3 * HOL_WINDOW)
    await ClockCycles(dut.hclk, 2000)
    run.kill()
    _release_all(tb)
    s = mon.summary()
    dut._log.info(f"[tl044-primary] posted={posted} reads={reads} {_fmt(s)}")

    # ---- vehicle ----------------------------------------------------------
    assert s["wr_os_max"] > 0, (
        f"VEHICLE BROKEN: no write was ever outstanding on s_axi ({s}).")
    assert reads["ok"] > 0, (
        f"VEHICLE BROKEN: not one cross-page read completed while the write was "
        f"stuck ({reads}), so no unrelated progress was generated and this is "
        f"not a starvation test. (If XHB500 has started serialising reads behind "
        f"a posted write regardless of page, the route is closed -- say so, do "
        f"not weaken the assertion.)")
    assert s["r_done"] > 4, (
        f"VEHICLE BROKEN: only {s['r_done']} R completions on s_axi -- the "
        f"re-zeroing source is missing ({s}).")

    # ---- (a) STARVATION IS PRESENT ---------------------------------------
    assert s["osr_expiries"] == 0 and s["stall_expiries"] == 0, (
        f"NOT A STARVATION TEST ANY MORE: an aggregate timer DID expire "
        f"({s}). The unrelated reads no longer re-zero it, so this test is not "
        f"exercising the defect it was written for.")
    assert s["osr_max"] < AGG_WINDOW, (
        f"the shared age counter reached {s['osr_max']} >= {AGG_WINDOW}: it was "
        f"not starved ({s}).")

    # ---- (b) THE STUCK WRITE IS RETIRED ANYWAY ---------------------------
    assert (s["hol_b_rises"] > 0 or s["synthb_rises"] > 0), (
        f"STARVATION CONFIRMED AND UNRECOVERED (the defect): a write stayed "
        f"outstanding for {s['wr_outstanding_cycles']} hclk with its B "
        f"permanently lost, {s['r_done']} unrelated read completions re-zeroed "
        f"the shared age counter (max {s['osr_max']} of {AGG_WINDOW}), "
        f"sub_wr_stuck_sticky stayed {s['sticky_wr_stuck']} (obs bit[8]) and NO "
        f"backstop ever fired. The hazard entry is never freed and the port "
        f"never recovers. {s}")
    assert s["port_err_illegal"] == 0, (
        f"AHB-ILLEGAL: {s['port_err_illegal']} HRESP=1 pulse(s) with no transfer "
        f"in its data phase ({s}) -- see F-1 / test_i5_error_is_ahb_legal.")


# =============================================================================
@cocotb.test()
async def test_tl044_escape_is_clean_and_normal_path_survives(dut):
    """ESCAPE-VS-SAFETY — a passing escape test is not a safety test.

    (a) the mechanism FIRES under starvation;
    (b) its own state CLEARS afterwards (the drain is not left latched);
    (c) with the fault REMOVED the normal path still works -- a clean peer
        write lands byte-exact at the far terminus and reads back."""
    tb, master = await _bringup(dut)
    mon = HolWatch(dut, master)
    run = cocotb.start_soon(mon.run(12 * HOL_WINDOW))

    await _stick_a_posted_write(dut, tb, master)
    await _starvation_reads(dut, mon, master, cycles=3 * HOL_WINDOW)
    await ClockCycles(dut.hclk, 2000)
    s_fire = mon.summary()

    # (a) fired
    assert (s_fire["hol_b_rises"] > 0 or s_fire["synthb_rises"] > 0), (
        f"no escape fired under starvation ({s_fire})")

    # Remove the fault entirely and let the link settle.
    _disarm_injector(tb, "s")
    await ClockCycles(dut.hclk, 20000)
    run.kill()
    s_after = mon.summary()

    # (b) the escape's own state cleared
    hb = _g(dut.u_master, "sub_wr_hol_b_pending", 0)
    sb = _g(dut.u_master, "synth_b_pending", 0)
    assert hb == 0, f"the head-of-line drain is still latched after the escape ({s_after})"
    assert sb == 0, f"synth_b_pending is still latched after the escape ({s_after})"

    # (c) the normal path survives
    try:
        await master.write(APER_BASE + OFF_POST, D_POST, timeout=60000)
        await ClockCycles(dut.hclk, 4000)
        landed = _slave_bram_peek(dut, OFF_POST)
        rb = await master.read(APER_BASE + OFF_POST, timeout=60000)
    except (TimeoutError, RuntimeError) as e:
        _release_all(tb)
        raise AssertionError(
            f"PATH DEAD AFTER THE ESCAPE: with the fault removed the next clean "
            f"write/read still failed ({e}). {s_after}")
    _release_all(tb)
    dut._log.info(f"[tl044-safety] landed=0x{landed:08x} rb=0x{rb:08x} {_fmt(s_after)}")

    # (d) THE DRAIN MUST BE BOUNDED. Every synthetic B is a write-completion the
    # far side never acknowledged, so the count is the blast radius of the
    # escape. One accepted AW may legitimately produce at most two B handshakes:
    # the synthetic one that retires it, plus the far side's REAL B arriving
    # late once the link recovers. Anything beyond that is a runaway -- which is
    # exactly what an unguarded retire pointer produced before the fix
    # (aw_accept=1, b_done=17, hol_b_rises=2: the pointer overtook `issue` and
    # the drain ran until the 4-bit counter wrapped).
    assert s_after["b_done"] <= s_after["aw_accept"] + 2, (
        f"SYNTHETIC-B RUNAWAY: {s_after['b_done']} B handshakes for "
        f"{s_after['aw_accept']} accepted AW(s) ({s_after}). The drain is "
        f"injecting completions for writes that do not exist.")

    assert landed == D_POST, (
        f"post-escape write landed 0x{landed:08x} != 0x{D_POST:08x} ({s_after})")
    assert rb == D_POST, (
        f"post-escape read-back 0x{rb:08x} != 0x{D_POST:08x} ({s_after})")


# =============================================================================
@cocotb.test()
async def test_tl044_healthy_traffic_never_trips_the_watchdog(dut):
    """FALSE-FIRE GUARD — no injection at all.

    A mixed write/read soak longer than the watchdog window must leave the
    watchdog un-armed and every transfer byte-exact. A backstop that fires on
    healthy traffic would inject spurious OKAY B responses into XHB500 and
    corrupt the write-completion accounting."""
    tb, master = await _bringup(dut)
    mon = HolWatch(dut, master)
    run = cocotb.start_soon(mon.run(6 * HOL_WINDOW))

    bad = 0
    for i in range(24):
        a = OFF_POST + 4 * (i % 8)
        d = 0xC0DE0000 | i
        await master.write(APER_BASE + a, d, timeout=40000)
        await ClockCycles(dut.hclk, 200)
        got = await master.read(APER_BASE + a, timeout=40000)
        if got != d:
            bad += 1
        # bufferable traffic too -- the EWR path is the one the watchdog counts
        await master.write_bufferable(APER_BASE + a, d, dut.u_master, timeout=40000)
        await ClockCycles(dut.hclk, 200)
    await ClockCycles(dut.hclk, 2 * HOL_WINDOW)
    run.kill()
    _release_all(tb)
    s = mon.summary()
    dut._log.info(f"[tl044-falsefire] bad={bad} {_fmt(s)}")

    assert bad == 0, f"healthy traffic corrupted ({bad} mismatches) {s}"
    assert s["hol_b_rises"] == 0, (
        f"FALSE FIRE: the head-of-line watchdog armed on HEALTHY traffic ({s})")
    assert s["synthb_rises"] == 0, (
        f"FALSE FIRE: the synth-B backstop armed on HEALTHY traffic ({s})")
    assert s["port_err_pulses"] == 0, (
        f"healthy traffic produced {s['port_err_pulses']} HRESP=ERROR pulse(s) ({s})")

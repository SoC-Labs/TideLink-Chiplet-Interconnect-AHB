"""TL-037 — is there ANY timeout on an ahb_sub transfer that stalls BEFORE it
reaches s_axi?

CLAIM UNDER TEST (registry TL-037 says "no AXI Firewall / AXI Timeout IP in the
block design", i.e. an FPGA-only integration gap). This file tests the RTL
instead, because `src/rtl/tidelink_top.sv` already contains two backstops that
are supposed to be exactly that timeout — and both of them are conditioned on an
s_axi transaction ALREADY BEING OUTSTANDING:

  :1636-1645  per-beat HREADYOUT-low stall backstop
                  end else if (sub_stall_expired) begin
                      sub_stall_ctr_r <= '0;
                      if (sub_rd_os_r) sub_err1_r <= 1'b1;   // <-- READ-ONLY gate
                  end
  :1669-1696  I5 outstanding-response backstop — only ever ARMED while
              `sub_axi_outstanding = sub_rd_os_r | (sub_wr_os_ctr != 0)`
  :1856       synth-B write drain — `sub_wr_stuck_fire` requires
              `sub_wr_os_ctr != 3'd0`

So when the master-facing HREADYOUT is held low with NEITHER a read nor a write
outstanding on s_axi, the per-beat stall timer runs to 2**16, RESETS ITSELF, and
does nothing at all — no AHB ERROR, no synth-B, no recovery. `ahb_sub_hreadyout`
stays low forever and the PS store/load never returns. That is TL-037, in RTL,
on the ASIC path as much as the FPGA one.

WHY THAT STATE IS ORDINARY, NOT EXOTIC. XHB500 holds `hreadyout` low in
RESP_FSM_SEQ_NSEQ whenever it cannot submit the address
(core_resp.sv:181-183 `if (~address_readyout) hreadyout = 1'b0;`), and
`pause_addr_submit` (core_addr.sv:151-154) blocks a READ on

    ~ready_for_read || hazard_read

with `ready_for_read = (read_counter==0 | (r_done & read_counter==1))`
(core_resp.sv:233) and `read_counter` decremented ONLY by `r_done`
(core_resp.sv:115-123). A read whose R is permanently lost therefore parks
`read_counter` at 1 FOREVER — and the tidelink read backstop's own recovery
makes this worse, not better: it retires the master with an AHB ERROR and clears
`sub_rd_os_r`, but it cannot make the far side return the R, so XHB500 stays
un-idled. From that moment every subsequent peer access is paused BEFORE its
AR/AW reaches s_axi, i.e. in exactly the "nothing outstanding" state neither
backstop covers.

Net: on a wedged link the port gives you EXACTLY ONE recoverable bus error, and
every access after it hangs unbounded. This matches the on-silicon capture
already quoted in `test_axi_datanode_gaps.py:test_i5_clean_drop_leaves_path_usable`
— "for ALL 3839 samples after the backstop ERROR, `dbg_xhb_hrdyout_raw` is 0 —
never once high — `dbg_i5_ext_stalled` is 1, and `dbg_i5_stall_ctr` is ramping
again toward the next 2^16 expiry" — a stall counter ramping to an expiry that
fires nothing is the signature of the dead gate.

TESTS (each needs its OWN sim — a second run_bringup_full does not re-POR):

  test_tl037_control_first_stuck_read_is_bounded          (CONTROL / vehicle)
      Far terminus stalled, ONE blocking read. Must be bounded by a legal
      2-cycle HRESP=ERROR. Establishes that the vehicle produces the RECOVERABLE
      case, so a hang in the primary test cannot be blamed on the vehicle.

  test_tl037_second_access_after_backstop_hangs           (PRIMARY / A-B)
      Identical, then a SECOND peer read while the link is still wedged.
      Proves the dead-gate state is genuinely entered (rd_os=0 AND wr_ctr=0 AND
      xhb_sub_hreadyout_raw=0 held across a full stall-timeout window, with the
      stall timer actually EXPIRING in that state) and then asserts the second
      access is bounded. FAILS pre-fix (unbounded hang), PASSES post-fix.

  test_tl037_fix_clears_state_and_normal_path_survives    (ESCAPE-VS-SAFETY)
      The three-part bar: (a) the mechanism FIRES, (b) its own state CLEARS
      afterwards, (c) the NORMAL path still works once it has fired — the far
      terminus is un-stalled and a clean write + read-back must be byte-exact.

NO FORCED HANDSHAKES. Nothing in this file forces `s_axi_awready`/`s_axi_wready`
(which wedges XHB500 unrecoverably and would make post-recovery unobservable) or
any other AXI ready/valid. The only stimulus hook is the TB's documented far-
terminus model `u_s_mng_bram.force_stall` (tb_top.sv:1075).

BUILD: short stall + outstanding windows so both expiries are reachable in sim.

  make -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_tl037 \
       EXTRA_DEFINES="+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=13 \
                      +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13" \
       MODULE=test_tl037_ahb_sub_terminal_timeout TESTCASE=<name>

  TL037_STALL_LOG2=13 must match the define (the tests read it to know where
  the stall counter's expiry bit is). The defect is a GATING-TERM interaction
  and is timeout-value independent.
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Helpers only — importing a module that defines @cocotb.test() would pull its
# tests into this module's regression set, so only plain helpers are taken.
from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)

STALL_LOG2 = int(os.environ.get("TL037_STALL_LOG2", "13"))
STALL_WINDOW = 1 << STALL_LOG2

OFF_RD1 = 0x300          # the read whose R is permanently lost
OFF_RD2 = 0x1340         # the SECOND access — a DIFFERENT 4KB page (0x40001),
                         # so an XHB500 hazard_list address match (compared on
                         # chk_addr[31:12]) cannot be the reason it stalls; that
                         # isolates ~ready_for_read as the cause. The low bits
                         # differ too because the far-side terminus is
                         # tb_ahb_bram_slave #(.AW(12)) (tb_top.sv:870), which
                         # ALIASES the page bits away — 0x300 and 0x1300 would
                         # be the same physical word and the seeds would collide.
OFF_POST = 0x400         # the post-recovery clean transfer
D_RD1 = 0x5EED0042
D_RD2 = 0x5EED1043
D_POST = 0xA5A50FF0

# Long enough to cover several 2**STALL_LOG2 windows, so "nothing ever rescues
# it" is MEASURED across real expiries rather than assumed.
SECOND_TIMEOUT = 6 * STALL_WINDOW


def _g(obj, name, default=None):
    """Read a possibly-absent child signal (the pre-fix build lacks the new one)."""
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return default


class DeadGateMonitor:
    """Samples the ahb_sub backstop state every hclk.

    The question this instrument answers is narrow and must not be fudged: was
    the port in the state `xhb_sub_hreadyout_raw == 0` AND `sub_rd_os_r == 0`
    AND `sub_wr_os_ctr == 0` (the 'nothing outstanding, master held' dead gate)
    at the moment the per-beat stall timer expired?
    """

    def __init__(self, dut, master):
        self.dut = dut
        self.top = dut.u_master
        self.master = master
        self.deadgate_cycles = 0
        self.deadgate_run = 0
        self.deadgate_run_max = 0
        self.stall_expiries = 0
        self.deadgate_at_expiry = 0
        self.err1_rises = 0
        self.err2_cycles = 0
        self.synthb_rises = 0
        self.port_err_pulses = 0
        self.port_err_illegal = 0
        self.raw_high_cycles = 0
        self.first_deadgate = None
        self.cycle = 0
        self.dphase_seen = 0

    async def run(self, cycles):
        prev_e1 = prev_sb = prev_resp = prev_exp = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.hclk)
            self.cycle += 1
            raw = _g(self.top, "xhb_sub_hreadyout_raw", 1)
            rd_os = _g(self.top, "sub_rd_os_r", 0)
            wr = _g(self.top, "sub_wr_os_ctr", 0)
            sb = _g(self.top, "synth_b_pending", 0)
            e1 = _g(self.top, "sub_err1_r", 0)
            e2 = _g(self.top, "sub_err2_r", 0)
            ctr = _g(self.top, "sub_stall_ctr_r", 0)
            dph = _g(self.top, "sub_mst_dphase_r", None)

            if raw:
                self.raw_high_cycles += 1
            if dph:
                self.dphase_seen += 1

            dead = (raw == 0) and (rd_os == 0) and (wr == 0) and (sb == 0) \
                and self.master.outstanding
            if dead:
                self.deadgate_cycles += 1
                self.deadgate_run += 1
                if self.first_deadgate is None:
                    self.first_deadgate = self.cycle
                if self.deadgate_run > self.deadgate_run_max:
                    self.deadgate_run_max = self.deadgate_run
            else:
                self.deadgate_run = 0

            expired = (ctr >> STALL_LOG2) & 1
            if expired and not prev_exp:
                self.stall_expiries += 1
                if dead:
                    self.deadgate_at_expiry += 1
            prev_exp = expired

            if e1 and not prev_e1:
                self.err1_rises += 1
            prev_e1 = e1
            if e2:
                self.err2_cycles += 1
            if sb and not prev_sb:
                self.synthb_rises += 1
            prev_sb = sb

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
            "deadgate_cycles": self.deadgate_cycles,
            "deadgate_run_max": self.deadgate_run_max,
            "first_deadgate": self.first_deadgate,
            "stall_expiries": self.stall_expiries,
            "deadgate_at_expiry": self.deadgate_at_expiry,
            "err1_rises": self.err1_rises,
            "err2_cycles": self.err2_cycles,
            "synthb_rises": self.synthb_rises,
            "port_err_pulses": self.port_err_pulses,
            "port_err_illegal": self.port_err_illegal,
            "raw_high_cycles": self.raw_high_cycles,
            "dphase_seen": self.dphase_seen,
        }


async def _classify_read(master, addr, timeout):
    """ERROR = bounded by HRESP=ERROR; OK = completed; HANG = never answered."""
    try:
        v = await master.read(addr, timeout=timeout)
        return "OK", v
    except RuntimeError:
        return "ERROR", None
    except TimeoutError:
        return "HANG", None


async def _stage(dut):
    """Bring the pair up, prove the clean peer read path, then wedge the far
    terminus. Returns (tb, master)."""
    tb, master = await _bringup(dut)

    # Seed the far terminus and PROVE a clean peer read works before any fault,
    # so a later hang cannot be a broken read path.
    await master.write(APER_BASE + OFF_RD1, D_RD1)
    await master.write(APER_BASE + OFF_RD2, D_RD2)
    await ClockCycles(dut.hclk, 2000)
    pre1 = await master.read(APER_BASE + OFF_RD1)
    assert pre1 == D_RD1, f"clean peer READ broken before the fault: 0x{pre1:08x}"
    pre2 = await master.read(APER_BASE + OFF_RD2)
    assert pre2 == D_RD2, f"clean peer READ broken before the fault: 0x{pre2:08x}"

    # Wedge the far terminus: neither R nor B ever comes back. This is the TB's
    # documented wedged-link model — no AXI handshake is forced anywhere.
    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 20)
    return tb, master


@cocotb.test()
async def test_tl037_control_first_stuck_read_is_bounded(dut):
    """CONTROL — the vehicle really does produce a RECOVERABLE stuck read.

    One blocking read into a wedged far terminus. The AR IS accepted onto s_axi
    (`sub_rd_os_r` = 1), so the I5 / per-beat backstop owns it and must retire
    the master with a legal 2-cycle AHB ERROR. If this fails, the primary test's
    hang would be uninterpretable."""
    tb, master = await _stage(dut)
    mon = DeadGateMonitor(dut, master)
    m = cocotb.start_soon(mon.run(SECOND_TIMEOUT + 4000))

    cls, _ = await _classify_read(master, APER_BASE + OFF_RD1,
                                  timeout=SECOND_TIMEOUT)
    await ClockCycles(dut.hclk, 200)
    m.kill()
    dut._log.info(f"[tl037] CONTROL read1 class={cls} {mon.summary()}")
    _release_all(tb)

    assert cls == "ERROR", (
        f"CONTROL FAILED — a stuck read whose AR WAS accepted was not bounded by "
        f"an AHB ERROR (class={cls}). The vehicle is not producing the "
        f"recoverable case, so nothing else in this file is interpretable. "
        f"{mon.summary()}")
    assert mon.err1_rises > 0, "CONTROL: the ERROR backstop never fired (vacuous)"
    assert mon.port_err_pulses > 0, "CONTROL: no HRESP pulse reached the port"
    assert mon.port_err_illegal == 0, (
        f"CONTROL: an HRESP=ERROR pulse landed on an idle bus "
        f"({mon.port_err_illegal} illegal pulses) — AHB-illegal")


@cocotb.test()
async def test_tl037_second_access_after_backstop_hangs(dut):
    """PRIMARY / the A-B discriminator.

    After the read backstop has retired read #1 with an ERROR, XHB500's
    `read_counter` is STILL 1 (its R was never returned and only `r_done`
    decrements it), so `ready_for_read` is 0 and read #2 is paused BEFORE its AR
    reaches s_axi. `sub_rd_os_r` and `sub_wr_os_ctr` are therefore both 0 while
    the master is held with `xhb_sub_hreadyout_raw` = 0.

    NON-VACUITY: the test asserts that the dead-gate state is genuinely entered
    and that the per-beat stall timer actually EXPIRED while in it. If either is
    absent it fails as CANNOT CONSTRUCT rather than passing.

    VERDICT: read #2 must be BOUNDED. Pre-fix it hangs; post-fix it gets a
    legal AHB ERROR one stall window later."""
    tb, master = await _stage(dut)

    # Trip 1 — the covered case. Establishes the wedge and clears sub_rd_os_r.
    mon1 = DeadGateMonitor(dut, master)
    m1 = cocotb.start_soon(mon1.run(SECOND_TIMEOUT + 2000))
    cls1, _ = await _classify_read(master, APER_BASE + OFF_RD1,
                                   timeout=SECOND_TIMEOUT)
    await ClockCycles(dut.hclk, 100)
    m1.kill()
    dut._log.info(f"[tl037] trip1 class={cls1} {mon1.summary()}")
    assert cls1 == "ERROR", (
        f"CANNOT CONSTRUCT — trip 1 gave class={cls1}, not the ERROR the "
        f"existing backstop is supposed to deliver. Run "
        f"test_tl037_control_first_stuck_read_is_bounded first. {mon1.summary()}")

    rd_os_after = _g(dut.u_master, "sub_rd_os_r", None)
    wr_after = _g(dut.u_master, "sub_wr_os_ctr", None)
    dut._log.info(f"[tl037] after trip1: sub_rd_os_r={rd_os_after} "
                  f"sub_wr_os_ctr={wr_after} "
                  f"raw={_g(dut.u_master, 'xhb_sub_hreadyout_raw')}")

    # Trip 2 — the UNCOVERED case: a second peer access while the link is still
    # wedged. Different 4KB page, so an EWR hazard address match cannot explain
    # the stall.
    mon2 = DeadGateMonitor(dut, master)
    m2 = cocotb.start_soon(mon2.run(SECOND_TIMEOUT + 2000))
    cls2, _ = await _classify_read(master, APER_BASE + OFF_RD2,
                                   timeout=SECOND_TIMEOUT)
    await ClockCycles(dut.hclk, 200)
    m2.kill()
    s = mon2.summary()
    dut._log.info(f"[tl037] trip2 class={cls2} {s}")
    _release_all(tb)

    # ── NON-VACUITY: the dead gate must genuinely have been entered ──────────
    # The precise assertion is `deadgate_at_expiry` below — the stall timer
    # EXPIRED while the port was in the dead-gate state. This run-length check
    # only rules out a one-cycle blip. It is deliberately half a window rather
    # than a full one: the master-outstanding flag necessarily lags the start of
    # the stall by a cycle or two, so requiring the full 2**LOG2 would make the
    # guard fail for a reason that has nothing to do with the defect.
    assert s["deadgate_run_max"] >= STALL_WINDOW // 2, (
        f"CANNOT CONSTRUCT / DOWNGRADED — THIS IS NOT A PASS. The port never "
        f"held the dead-gate state (raw=0, sub_rd_os_r=0, sub_wr_os_ctr=0, "
        f"master held) for even half a stall window ({STALL_WINDOW // 2} "
        f"cycles); longest run was {s['deadgate_run_max']}. {s}")
    assert s["deadgate_at_expiry"] >= 1, (
        f"CANNOT CONSTRUCT / DOWNGRADED — THIS IS NOT A PASS. The per-beat stall "
        f"timer never EXPIRED while in the dead-gate state "
        f"(stall_expiries={s['stall_expiries']}, "
        f"deadgate_at_expiry={s['deadgate_at_expiry']}). {s}")
    assert s["synthb_rises"] == 0, (
        f"the write drain fired on trip 2 — that is not the uncovered case "
        f"this test is about. {s}")

    # ── VERDICT ─────────────────────────────────────────────────────────────
    assert cls2 == "ERROR", (
        f"TL-037 REPRODUCED: the second peer access is UNBOUNDED (class={cls2}). "
        f"The per-beat stall timer expired {s['stall_expiries']}x in the "
        f"dead-gate state and fired nothing "
        f"(err1_rises={s['err1_rises']}, port_err_pulses={s['port_err_pulses']}) "
        f"because both ERROR fire sites are gated on sub_rd_os_r and the synth-B "
        f"drain is gated on sub_wr_os_ctr, and BOTH are 0 when the transfer is "
        f"stalled before it reaches s_axi. `ahb_sub_hreadyout` stays low forever "
        f"=> PS hangs with no bus error and no recovery. {s}")
    assert s["port_err_illegal"] == 0, (
        f"the terminal timeout drove HRESP=ERROR onto an idle bus "
        f"({s['port_err_illegal']} illegal pulses) — that is the F-1 defect and "
        f"an upstream AXI->AHB bridge is entitled to discard it. {s}")


@cocotb.test()
async def test_tl037_second_access_write_after_backstop_hangs(dut):
    """PRIMARY, WRITE DIRECTION — the registry's own framing of TL-037.

    TL-037 is titled "no AXI firewall / AXI timeout on the cross-die WRITE
    path", so the same dead gate is demonstrated for a write. The mechanism is
    direction-agnostic: XHB500's response FSM is still parked in
    RESP_FSM_SEQ_NSEQ on the read whose R was lost, so `hreadyout` is 0 for
    ANY following transfer regardless of its direction, and a write stalled
    there has `sub_wr_os_ctr` == 0 because its AW was never accepted onto
    s_axi. Neither ERROR fire site (gated on sub_rd_os_r) nor the synth-B drain
    (gated on sub_wr_os_ctr) can reach it.

    This is the case that on silicon presents as "the PS store never returns,
    ssh dies at 60 s, recovery is JTAG-POR only"."""
    tb, master = await _stage(dut)

    cls1, _ = await _classify_read(master, APER_BASE + OFF_RD1,
                                   timeout=SECOND_TIMEOUT)
    assert cls1 == "ERROR", f"CANNOT CONSTRUCT — trip 1 class={cls1}"
    await ClockCycles(dut.hclk, 100)

    mon = DeadGateMonitor(dut, master)
    m = cocotb.start_soon(mon.run(SECOND_TIMEOUT + 2000))
    try:
        await master.write(APER_BASE + OFF_RD2, D_RD2, timeout=SECOND_TIMEOUT)
        cls2 = "OK"
    except RuntimeError:
        cls2 = "ERROR"
    except TimeoutError:
        cls2 = "HANG"
    await ClockCycles(dut.hclk, 300)
    m.kill()
    s = mon.summary()
    wr_hold = _g(dut.u_master, "wr_hold_r")
    dut._log.info(f"[tl037] WRITE trip2 class={cls2} wr_hold_r={wr_hold} {s}")
    _release_all(tb)

    assert s["deadgate_run_max"] >= STALL_WINDOW // 2, (
        f"CANNOT CONSTRUCT / DOWNGRADED — THIS IS NOT A PASS: the dead-gate "
        f"state was never held (run_max={s['deadgate_run_max']}). {s}")
    assert s["deadgate_at_expiry"] >= 1, (
        f"CANNOT CONSTRUCT / DOWNGRADED — THIS IS NOT A PASS: the stall timer "
        f"never expired in the dead-gate state. {s}")
    assert s["synthb_rises"] == 0, (
        f"synth-B fired — the write reached s_axi, so this is the ALREADY "
        f"COVERED case, not the uncovered one this test is about. {s}")

    assert cls2 == "ERROR", (
        f"TL-037 REPRODUCED ON THE WRITE PATH: the cross-die write is UNBOUNDED "
        f"(class={cls2}). The stall timer expired {s['stall_expiries']}x with "
        f"sub_rd_os_r=0 and sub_wr_os_ctr=0 and fired nothing. On silicon this "
        f"is the PS store that never returns. {s}")
    assert s["port_err_illegal"] == 0, (
        f"the write-path terminal timeout drove HRESP=ERROR onto an idle bus "
        f"({s['port_err_illegal']} illegal pulses). {s}")

    # ── (c) for the write direction, and the TL-042 interaction, MEASURED ────
    # The terminal timeout deliberately does NOT touch `wr_hold_clr`: adding a
    # term there is precisely what got the TL-042 candidate rejected on hardware
    # (`synth_b_pending` is a LEVEL and a term of wr_hold_clr, so arming it
    # disables the TL-002 peer-write data-phase hold). So after the ERROR is
    # delivered — err1/err2 outrank wr_hold_r in the ahb_sub_hreadyout mux, so
    # delivery is not in question — `wr_hold_r` is still SET. This step measures
    # whether that self-heals: wr_hold_r does not gate the address path into
    # XHB500 (`xhb_sub_hready` is raw, not wr_hold_r), so a later write's W beat
    # should still reach s_axi and clear it.
    dut.u_s_mng_bram.force_stall.value = 0
    await ClockCycles(dut.hclk, 4000)
    try:
        await master.write(APER_BASE + OFF_POST, D_POST, timeout=SECOND_TIMEOUT)
        await ClockCycles(dut.hclk, 3000)
        landed = _slave_bram_peek(dut, OFF_POST)
    except (TimeoutError, RuntimeError) as e:
        raise AssertionError(
            f"(c) WRITE PATH DEAD AFTER THE TIMEOUT FIRED: with the wedge "
            f"removed, the next clean peer write failed ({e}). wr_hold_r was "
            f"{wr_hold} at the fire and did not self-heal — the terminal "
            f"timeout bounds the hang but leaves the port unusable, so it would "
            f"need to be paired with a wr_hold_r escape (TL-042).")
    assert landed == D_POST, (
        f"(c) post-recovery write landed 0x{landed:08x} != 0x{D_POST:08x}")
    dut._log.info(f"[tl037] WRITE (c) recovered: landed=0x{landed:08x} "
                  f"wr_hold_r_now={_g(dut.u_master, 'wr_hold_r')}")


@cocotb.test()
async def test_tl037_fix_clears_state_and_normal_path_survives(dut):
    """ESCAPE-VS-SAFETY — all three parts, asserted separately.

    (a) FIRES     — the second access is retired by a legal 2-cycle AHB ERROR.
    (b) CLEARS    — after it fires, every piece of backstop state is back at
                    rest (sub_err1_r, sub_err2_r, synth_b_pending, and the new
                    sub_mst_dphase_r), and it did NOT latch synth_b_pending
                    (which is a LEVEL that disables the TL-002 peer-write hold —
                    the exact mistake that got the TL-042 candidate rejected on
                    hardware).
    (c) SURVIVES  — with the far terminus released, a clean peer WRITE lands
                    byte-exact at the far side AND a clean peer READ returns it.

    Pre-fix this fails at (a); it is not a post-fix-only test."""
    tb, master = await _stage(dut)

    cls1, _ = await _classify_read(master, APER_BASE + OFF_RD1,
                                   timeout=SECOND_TIMEOUT)
    assert cls1 == "ERROR", f"CANNOT CONSTRUCT — trip 1 class={cls1}"
    await ClockCycles(dut.hclk, 100)

    mon = DeadGateMonitor(dut, master)
    m = cocotb.start_soon(mon.run(SECOND_TIMEOUT + 2000))
    cls2, _ = await _classify_read(master, APER_BASE + OFF_RD2,
                                   timeout=SECOND_TIMEOUT)
    await ClockCycles(dut.hclk, 500)
    m.kill()
    s = mon.summary()
    dut._log.info(f"[tl037] safety trip2 class={cls2} {s}")

    # (a) FIRES
    assert cls2 == "ERROR", (
        f"(a) THE MECHANISM DID NOT FIRE — second access class={cls2}. {s}")
    assert s["err1_rises"] > 0, f"(a) sub_err1_r never rose — vacuous. {s}"
    assert s["port_err_illegal"] == 0, (
        f"(a) the ERROR was AHB-illegal (landed with no transfer in its data "
        f"phase). {s}")

    # (b) CLEARS
    resting = {
        "sub_err1_r": _g(dut.u_master, "sub_err1_r"),
        "sub_err2_r": _g(dut.u_master, "sub_err2_r"),
        "synth_b_pending": _g(dut.u_master, "synth_b_pending"),
        "sub_mst_dphase_r": _g(dut.u_master, "sub_mst_dphase_r"),
        "sub_rd_os_r": _g(dut.u_master, "sub_rd_os_r"),
        "sub_wr_os_ctr": _g(dut.u_master, "sub_wr_os_ctr"),
        "wr_hold_r": _g(dut.u_master, "wr_hold_r"),
    }
    dut._log.info(f"[tl037] resting state after the fire: {resting}")
    for name in ("sub_err1_r", "sub_err2_r", "synth_b_pending",
                 "sub_mst_dphase_r", "sub_rd_os_r"):
        assert resting[name] == 0, (
            f"(b) STATE DID NOT CLEAR — {name}={resting[name]} is still set "
            f"after the terminal timeout fired. {resting}")
    assert s["synthb_rises"] == 0, (
        f"(b) the terminal timeout asserted synth_b_pending "
        f"({s['synthb_rises']} rises). synth_b_pending is a LEVEL and a term of "
        f"wr_hold_clr, so asserting it disables the TL-002 peer-write hold — the "
        f"exact defect that got the TL-042 candidate rejected on hardware. {s}")

    # (c) SURVIVES — release the wedge and prove the normal path still works.
    dut.u_s_mng_bram.force_stall.value = 0
    await ClockCycles(dut.hclk, 4000)

    try:
        await master.write(APER_BASE + OFF_POST, D_POST, timeout=SECOND_TIMEOUT)
        await ClockCycles(dut.hclk, 3000)
        landed = _slave_bram_peek(dut, OFF_POST)
    except (TimeoutError, RuntimeError) as e:
        _release_all(tb)
        raise AssertionError(
            f"(c) NORMAL PATH DEAD AFTER THE TIMEOUT FIRED: with the wedge "
            f"REMOVED, the next clean peer write still failed ({e}). A recovery "
            f"that leaves the port unusable is a report, not a recovery.")
    assert landed == D_POST, (
        f"(c) post-recovery write completed but landed 0x{landed:08x} != "
        f"0x{D_POST:08x} — the data path is corrupted after the timeout fired")

    cls3, got = await _classify_read(master, APER_BASE + OFF_POST,
                                     timeout=SECOND_TIMEOUT)
    _release_all(tb)
    assert cls3 == "OK", (
        f"(c) a clean peer READ after the timeout fired gave class={cls3} — the "
        f"read path did not survive")
    assert got == D_POST, (
        f"(c) post-recovery read returned 0x{got:08x} != 0x{D_POST:08x}")

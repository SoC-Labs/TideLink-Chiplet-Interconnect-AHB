"""REPRODUCE-FIRST BENCH (kept as the A/B evidence for TL-048; NOT in the gate).
Its FINDING arms PASS when the defect is present and FAIL once it is fixed:
on the pre-fix servo (ad09040 and earlier) all 12 pass; after TL-048 the
plus_5s / minus_5s / sticky-flag arms fail by design. The gating form is
test_servo_converge.py, which imports this module's loop model.

Rev-2 review LP-13 re-derivation: can the PTP servo converge from an initial
offset of more than one second?

Closed loop: the servo (Subordinate) drives a REAL phc_clock_core; the
Grandmaster is an ideal Python clock (epoch + simulation time).  Each exchange
feeds t1/t4 from the model and t2/t3 from the PHC's own hw_capture; the
servo's phase steps and frequency adjustments act on the PHC it is measuring.
After every exchange the test reads the PHC and reports the residual error
against the master, whether the servo took the STEP or the PI branch, and the
sticky needs_phase_step_r flag.

Path delay is symmetric (200 ns each way) so the offset computation is exact.
The PHC runs at exactly the master rate (ns_incr=4 @ 250 MHz, frac 0), so the
only error to remove is the initial phase offset.

What would REFUTE the finding: a run starting 5 s away whose residual error
falls below the step threshold (1 ms) within a handful of exchanges.
"""
import cocotb
import math
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.utils import get_sim_time

CLK_PERIOD_NS = 4
NS_INCR = 4
EPOCH_S = 1000                     # grandmaster epoch (seconds)
PATH_DELAY_NS = 200
STEP_THRESH_NS = 1_000_000         # 1 ms, as in the existing servo tests
N_EXCH = 10
ONE_S = 1_000_000_000

REG_CTRL, REG_KP, REG_KI, REG_THRESH, REG_STATUS, REG_OFFSET = 0, 1, 2, 3, 4, 5


EPOCH_PHASE_NS = 0                 # master nanosecond phase at sim time 0 (per test)


def master_now_ns():
    return EPOCH_S * ONE_S + EPOCH_PHASE_NS + int(round(get_sim_time("ns")))


def split(t_ns):
    return t_ns // ONE_S, t_ns % ONE_S


class Loop:
    def __init__(self, dut):
        self.dut = dut
        self.step_pulses = 0
        self.adj_pulses = 0
        self.last_set = None
        self.bad_ns_writes = 0

    async def start(self, off0_ns, kp=0.7, ki=0.02):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, CLK_PERIOD_NS, unit="ns").start())
        d.resetn.value = 0
        for s in ("servo_reg_write", "sync_rx_done", "dreq_tx_done", "hw_capture",
                  "mbox_reg_write", "mbox_reg_addr", "mbox_reg_wdata",
                  "servo_reg_addr", "servo_reg_wdata", "phc_set_time",
                  "phc_set_seconds", "phc_set_nanoseconds", "phc_ns_incr_frac"):
            getattr(d, s).value = 0
        d.phc_enable.value = 1
        d.phc_ns_incr.value = NS_INCR
        await ClockCycles(d.clk, 5)
        d.resetn.value = 1
        await ClockCycles(d.clk, 2)
        # subordinate PHC := master + off0
        await self.sw_set(master_now_ns() + off0_ns)
        # servo: subordinate + enable, gains, threshold
        await self.reg_write(REG_KP, int(kp * (1 << 32)) & 0xFFFFFFFF)
        await self.reg_write(REG_KI, int(ki * (1 << 32)) & 0xFFFFFFFF)
        await self.reg_write(REG_THRESH, STEP_THRESH_NS)
        await self.reg_write(REG_CTRL, 0x3)
        cocotb.start_soon(self._pulse_monitor())

    async def _pulse_monitor(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            try:
                if int(d.phc_hw_set_time.value):
                    self.step_pulses += 1
                    ns = int(d.phc_hw_set_nanoseconds.value)
                    self.last_set = (int(d.phc_hw_set_seconds.value), ns)
                    if ns >= ONE_S:
                        self.bad_ns_writes += 1
                if int(d.phc_hw_adj_valid.value):
                    self.adj_pulses += 1
            except ValueError:
                pass

    async def sw_set(self, t_ns):
        s, n = split(t_ns)
        self.dut.phc_set_seconds.value = s
        self.dut.phc_set_nanoseconds.value = n
        self.dut.phc_set_time.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.phc_set_time.value = 0
        await RisingEdge(self.dut.clk)

    async def reg_write(self, addr, data):
        d = self.dut
        d.servo_reg_write.value = 1
        d.servo_reg_addr.value = addr
        d.servo_reg_wdata.value = data
        await RisingEdge(d.clk)
        d.servo_reg_write.value = 0
        await RisingEdge(d.clk)

    async def reg_read(self, addr):
        self.dut.servo_reg_addr.value = addr
        await RisingEdge(self.dut.clk)
        return int(self.dut.servo_reg_rdata.value)

    async def write_mbox(self, t_ns):
        s, n = split(t_ns)
        d = self.dut
        for addr, data in ((2, s & 0xFFFFFFFF), (3, (s >> 32) & 0xFFFF), (4, n)):
            d.mbox_reg_write.value = 1
            d.mbox_reg_addr.value = addr
            d.mbox_reg_wdata.value = data
            await RisingEdge(d.clk)
        d.mbox_reg_write.value = 0
        await RisingEdge(d.clk)

    async def capture_then(self, event_sig):
        """hw_capture one cycle, then the servo event one cycle.  Returns the
        master time at the capture edge."""
        d = self.dut
        d.hw_capture.value = 1
        await RisingEdge(d.clk)
        m = master_now_ns()
        d.hw_capture.value = 0
        event_sig.value = 1
        await RisingEdge(d.clk)
        event_sig.value = 0
        return m

    def sub_err_ns(self):
        """PHC time minus master time, signed ns (read at the current edge)."""
        d = self.dut
        sub = int(d.phc_seconds.value) * ONE_S + int(d.phc_nanoseconds.value)
        return sub - master_now_ns()

    async def exchange(self):
        d = self.dut
        steps0, adjs0 = self.step_pulses, self.adj_pulses
        # SYNC arrives: sub captures t2; master sent it PATH_DELAY earlier
        m_sync = await self.capture_then(d.sync_rx_done)
        t1 = m_sync - PATH_DELAY_NS
        # servo raises DELAY_REQ; sub captures t3 on tx_done
        for _ in range(60):
            await RisingEdge(d.clk)
            if int(d.servo_dreq_trigger.value):
                break
        else:
            raise TimeoutError("servo_dreq_trigger never asserted")
        m_dreq = await self.capture_then(d.dreq_tx_done)
        t4 = m_dreq + PATH_DELAY_NS
        await self.write_mbox(t1)
        await ClockCycles(d.clk, 2)
        await self.write_mbox(t4)
        # wait for the compute/adjust pipeline to return to SUB_IDLE
        for _ in range(600):
            await RisingEdge(d.clk)
            if int(d.u_servo.sub_state_r.value) == 0:
                break
        else:
            raise TimeoutError("servo sub FSM did not return to IDLE")
        await ClockCycles(d.clk, 3)
        off = await self.reg_read(REG_OFFSET)
        if off >= 1 << 31:
            off -= 1 << 32
        return dict(
            offset_reg=off, err=self.sub_err_ns(),
            step=self.step_pulses - steps0, adj=self.adj_pulses - adjs0,
            nps=int(d.u_servo.needs_phase_step_r.value),
            fwd_ovf=int(d.u_servo.sec_diff_fwd_ovf.value),
            locked=int(d.servo_locked.value), last_set=self.last_set)


def fmt(v):
    return f"{v/ONE_S:+.6f} s" if abs(v) >= 1_000_000 else f"{v:+d} ns"


async def run_case(dut, off0_ns, n=N_EXCH, coarse_set_after=None, phase_ns=0):
    global EPOCH_PHASE_NS
    EPOCH_PHASE_NS = phase_ns
    lp = Loop(dut)
    await lp.start(off0_ns)
    await ClockCycles(dut.clk, 5)
    dut._log.info(f"=== initial offset {fmt(off0_ns)}  (sub - master), master phase {phase_ns} ns, "
                  f"err before any exchange = {fmt(lp.sub_err_ns())}")
    rows = []
    for i in range(n):
        if coarse_set_after is not None and i == coarse_set_after:
            await lp.sw_set(master_now_ns() + 100)
            dut._log.info(f"  [software coarse set: sub := master + 100 ns, "
                          f"err now {fmt(lp.sub_err_ns())}]")
        r = await lp.exchange()
        rows.append(r)
        ls = r['last_set']
        dut._log.info(
            f"  exch {i:2d}: offset_reg={fmt(r['offset_reg'])} err_after={fmt(r['err'])} "
            f"branch={'STEP' if r['step'] else ('PI' if r['adj'] else '-')} "
            f"needs_phase_step_r={r['nps']} fwd_ovf={r['fwd_ovf']} locked={r['locked']}"
            + (f" set=({ls[0]},{ls[1]})" if r['step'] and ls else ""))
        await ClockCycles(dut.clk, 200)
    return lp, rows


@cocotb.test()
async def test_control_50ns(dut):
    """CONTROL: 50 ns away -> PI branch every exchange, no step, flag clear."""
    lp, rows = await run_case(dut, 50)
    assert all(r['adj'] == 1 and r['step'] == 0 for r in rows), rows
    assert all(r['nps'] == 0 for r in rows)
    drift = rows[-1]['err'] - rows[0]['err']
    frac = int(dut.u_phc.ns_incr_frac_active.value)
    dut._log.info(f"+50 ns control: PI engaged every exchange; err drift over run = {drift:+d} ns; "
                  f"PHC ns_incr_frac_active=0x{frac:08x} ({frac / (1 << 32):.6f} ns/tick)")
    # NOTE (measured 2026-09-22): a POSITIVE offset needs a NEGATIVE frequency
    # word; the servo computes current_frac_r - (P+I) < 0 and the PHC consumes
    # it as an UNSIGNED fraction -> the subordinate runs ~1 ns/tick FASTER and
    # the error grows.  Reported as an additional finding, not asserted here.


@cocotb.test()
async def test_control_2ms(dut):
    """CONTROL: 2 ms away (> step threshold, < 1 s) -> one phase step brings
    the error under the threshold, then the PI branch runs."""
    lp, rows = await run_case(dut, 2_000_000)
    assert rows[0]['step'] == 1, rows[0]
    assert abs(rows[1]['err']) < STEP_THRESH_NS, rows[1]
    assert rows[-1]['adj'] == 1 and rows[-1]['step'] == 0, rows[-1]
    assert rows[-1]['nps'] == 0


@cocotb.test()
async def test_plus_5s(dut):
    """FINDING: 5 s ahead.  Refuted if err falls below the step threshold."""
    lp, rows = await run_case(dut, 5 * ONE_S)
    final = rows[-1]['err']
    dut._log.info(f"+5 s: final err {fmt(final)}, steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} bad_ns_writes={lp.bad_ns_writes}")
    assert abs(final) > STEP_THRESH_NS, f"REFUTED: converged to {fmt(final)}"
    assert rows[-1]['nps'] == 1 and lp.adj_pulses == 0


@cocotb.test()
async def test_minus_5s(dut):
    """FINDING: 5 s behind."""
    lp, rows = await run_case(dut, -5 * ONE_S)
    final = rows[-1]['err']
    dut._log.info(f"-5 s: final err {fmt(final)}, steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} bad_ns_writes={lp.bad_ns_writes}")
    assert abs(final) > STEP_THRESH_NS, f"REFUTED: converged to {fmt(final)}"


@cocotb.test()
async def test_plus_1p5s(dut):
    """1.5 s ahead: |dsec| = 1 so the compressed path is taken, but the
    nanosecond difference exceeds the signed-31-bit d_fwd_r range."""
    lp, rows = await run_case(dut, ONE_S + ONE_S // 2)
    dut._log.info(f"+1.5 s: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} bad_ns_writes={lp.bad_ns_writes}")


@cocotb.test()
async def test_plus_0p5s(dut):
    """0.5 s ahead (review: 'expect lock in N exchanges, currently never /
    invalid ns')."""
    lp, rows = await run_case(dut, ONE_S // 2)
    dut._log.info(f"+0.5 s: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} bad_ns_writes={lp.bad_ns_writes}")


@cocotb.test()
async def test_minus_0p5s(dut):
    """0.5 s behind: the step's ns subtraction must borrow from seconds."""
    lp, rows = await run_case(dut, -(ONE_S // 2))
    dut._log.info(f"-0.5 s: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} bad_ns_writes={lp.bad_ns_writes}")


@cocotb.test()
async def test_sticky_flag_after_sw_coarse_set(dut):
    """Sticky flag: start 5 s away, let the servo see the overflow once, then
    have software set the PHC to within 100 ns of the master.  If
    needs_phase_step_r is never cleared, every later exchange still takes the
    STEP branch and the PI loop is never entered."""
    lp, rows = await run_case(dut, 5 * ONE_S, n=8, coarse_set_after=3)
    after = rows[3:]
    dut._log.info(f"after coarse set: branches="
                  f"{['STEP' if r['step'] else ('PI' if r['adj'] else '-') for r in after]} "
                  f"errs={[fmt(r['err']) for r in after]}")
    assert all(r['step'] == 1 and r['adj'] == 0 for r in after), \
        "REFUTED: servo entered the PI branch after the coarse set"


@cocotb.test()
async def test_plus_0p5s_phase_0p7(dut):
    """+0.5 s with the master at ns-phase 0.7e9: t3/t4 straddle a second
    boundary (sub is in the next second).  Exercises the reverse-path seconds
    adjustment."""
    lp, rows = await run_case(dut, ONE_S // 2, phase_ns=700_000_000)
    dut._log.info(f"+0.5 s @0.7: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} locked={rows[-1]['locked']}")


@cocotb.test()
async def test_minus_0p5s_phase_0p7(dut):
    """-0.5 s with the master at ns-phase 0.7e9: all four timestamps in the
    same second, so no seconds adjustment is needed anywhere."""
    lp, rows = await run_case(dut, -(ONE_S // 2), phase_ns=700_000_000)
    dut._log.info(f"-0.5 s @0.7: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} locked={rows[-1]['locked']}")


@cocotb.test()
async def test_minus_0p5s_phase_0p2(dut):
    """-0.5 s with the master at ns-phase 0.2e9: sub is in the previous
    second; forward AND reverse pairs straddle the boundary."""
    lp, rows = await run_case(dut, -(ONE_S // 2), phase_ns=200_000_000)
    dut._log.info(f"-0.5 s @0.2: final err {fmt(rows[-1]['err'])} steps={lp.step_pulses} "
                  f"adj={lp.adj_pulses} locked={rows[-1]['locked']}")


@cocotb.test()
async def test_minus_2ms_phase_boundary(dut):
    """-2 ms with the master 1 ms past a second boundary: a SMALL offset whose
    reverse pair straddles the boundary.  Shows the reverse-path adjustment
    bug is not confined to half-second offsets."""
    lp, rows = await run_case(dut, -2_000_000, phase_ns=1_000_000)
    dut._log.info(f"-2 ms @boundary: offsets={[fmt(r['offset_reg']) for r in rows[:3]]} "
                  f"errs={[fmt(r['err']) for r in rows[:3]]} locked={rows[-1]['locked']}")

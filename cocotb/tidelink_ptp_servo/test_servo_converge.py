"""PTP servo closed-loop CONVERGENCE (rev-2 LP-13 / TL-048) -- the gating form.

Same closed loop as test_closed_loop.py (the reproduce-first bench it imports
its model from): tidelink_ptp_servo drives a REAL phc_clock_core, and an ideal
Python grandmaster supplies t1/t4. Where test_closed_loop.py PASSES when the
defect is present, this module PASSES only when it is gone.

What TL-048 guarantees, and each test asserts:
  * ONE phase step brings any start -- +/-5 s, +/-1.5 s, +/-0.5 s at several
    master phases, +/-2 ms including one straddling a second boundary -- to
    within the servo's own 1 us default step threshold, and every later
    exchange frequency-steers (PI branch) with needs_phase_step_r clear.
  * servo_locked is never asserted while the error exceeds the lock window
    (step threshold / 4). Pre-fix, a +/-0.5 s start whose two paths straddle
    a second boundary computed an offset of ~0 and LOCKED 0.5 s wrong.
  * A software coarse set after an out-of-range start is followed by the PI
    branch, not by a step on every exchange (the old sticky flag).
  * CONTROL: a +50 ns start stays in the PI branch and does not run away
    (pre-fix the negative frequency word wrapped and the slave ran 25% fast:
    +42 ns grew to +2.7 us in ten exchanges).

NOT asserted, and why: the residual after the step is a few hundred ns and the
PI loop does not remove it within ten exchanges. That is TL-049 (frequency
loop: cannot slow below the integer increment; gains round to ~0 for sub-ms
offsets), a separate design decision, not part of this fix.
"""
import cocotb

import test_closed_loop as cl

ONE_S = cl.ONE_S
STEP_THRESH = cl.STEP_THRESH_NS          # the bench programs 1 ms
LOCK_WINDOW = STEP_THRESH // 4           # servo_locked uses step_thresh / 4
SETTLED_NS = 1_000                       # the servo's own DEFAULT_STEP_THRESH


def _branch(r):
    return 'STEP' if r['step'] else ('PI' if r['adj'] else '-')


def check_no_false_lock(rows):
    for i, r in enumerate(rows):
        if r['locked']:
            assert abs(r['err']) < LOCK_WINDOW, (
                f"exch {i}: servo_locked=1 with err {cl.fmt(r['err'])} "
                f"(lock window {cl.fmt(LOCK_WINDOW)}) -- FALSE LOCK")


async def converges(dut, off0_ns, phase_ns=0):
    lp, rows = await cl.run_case(dut, off0_ns, phase_ns=phase_ns)
    tag = f"{cl.fmt(off0_ns)} @phase {phase_ns} ns"
    dut._log.info(f"{tag}: branches={[_branch(r) for r in rows]} "
                  f"errs={[cl.fmt(r['err']) for r in rows]}")
    assert rows[0]['step'] == 1, f"{tag}: first exchange did not step ({_branch(rows[0])})"
    assert lp.step_pulses == 1, f"{tag}: {lp.step_pulses} steps -- expected exactly one"
    for i, r in enumerate(rows[1:], start=1):
        assert r['step'] == 0 and r['adj'] == 1, \
            f"{tag}: exch {i} took {_branch(r)}, expected PI after the step"
        assert r['nps'] == 0, f"{tag}: exch {i} needs_phase_step_r still set"
        assert abs(r['err']) < SETTLED_NS, \
            f"{tag}: exch {i} err {cl.fmt(r['err'])} not within {SETTLED_NS} ns"
    check_no_false_lock(rows)


@cocotb.test()
async def plus_5s(dut):
    await converges(dut, 5 * ONE_S)


@cocotb.test()
async def minus_5s(dut):
    await converges(dut, -5 * ONE_S)


@cocotb.test()
async def plus_1p5s(dut):
    await converges(dut, 3 * ONE_S // 2)


@cocotb.test()
async def minus_1p5s_phase_0p7(dut):
    await converges(dut, -3 * ONE_S // 2, phase_ns=700_000_000)


@cocotb.test()
async def plus_0p5s(dut):
    await converges(dut, ONE_S // 2)


@cocotb.test()
async def minus_0p5s(dut):
    await converges(dut, -(ONE_S // 2))


@cocotb.test()
async def plus_0p5s_phase_0p7(dut):
    await converges(dut, ONE_S // 2, phase_ns=700_000_000)


@cocotb.test()
async def minus_0p5s_phase_0p2(dut):
    await converges(dut, -(ONE_S // 2), phase_ns=200_000_000)


@cocotb.test()
async def minus_2ms_phase_boundary(dut):
    await converges(dut, -2_000_000, phase_ns=1_000_000)


@cocotb.test()
async def plus_2ms(dut):
    await converges(dut, 2_000_000)


@cocotb.test()
async def coarse_set_after_out_of_range_start_returns_to_pi(dut):
    lp, rows = await cl.run_case(dut, 5 * ONE_S, n=8, coarse_set_after=3)
    after = rows[3:]
    dut._log.info(f"after coarse set: branches={[_branch(r) for r in after]} "
                  f"errs={[cl.fmt(r['err']) for r in after]}")
    assert all(r['step'] == 0 and r['adj'] == 1 for r in after), \
        "servo kept stepping after a software coarse set -- sticky needs_phase_step_r"
    assert all(r['nps'] == 0 for r in after)
    check_no_false_lock(rows)


@cocotb.test()
async def control_50ns_pi_no_runaway(dut):
    lp, rows = await cl.run_case(dut, 50)
    drift = rows[-1]['err'] - rows[0]['err']
    dut._log.info(f"+50 ns control: branches={[_branch(r) for r in rows]} drift={drift:+d} ns")
    assert all(r['step'] == 0 and r['adj'] == 1 for r in rows), "control left the PI branch"
    assert abs(drift) < 100, (f"+50 ns control drifted {drift:+d} ns over {len(rows)} "
                              f"exchanges -- frequency word wrapped (slave runs fast)")
    check_no_false_lock(rows)

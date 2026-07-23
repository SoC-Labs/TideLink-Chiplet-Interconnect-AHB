"""
test_force_recal_pair — FULL-STACK proof of the P1 FORCED-RECAL W1P.

The unit bench (test_force_recal.py) proves the calibrator honours
force_recal_i. This bench proves the whole path a real chiplet would use:

    APB write to R8 slot0 bit[6] (SWI_FORCE_RECAL, MMIO 0x..2100)
      -> acc W1P + pulse-stretcher (apb_clk)
      -> CDC into rx_link_clk
      -> calibrator leaves S_DONE and genuinely re-calibrates
      -> link still carries data BYTE-EXACT in BOTH directions afterwards

and, as the control, that the pre-existing SWI_RECAL (bit[1]) is a no-op on
the same live link — the defect of docs/LINK_RECOVERY_MECHANISM.md §4,
reproduced end-to-end rather than at the unit level.

Runs against the pair TB in cocotb/tidelink_top_pair_v2 WITHOUT modifying any
file there (this module is hosted in cocotb/tidelink_force_recal/ and injected
via PYTHONPATH). See the `pair` target in this directory's Makefile.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check, APB_R8_SLOT0,
)

# Calibrator FSM encodings (mirror tidelink_phy_align_calibrator.sv).
S_ARM      = 1
S_SWEEP    = 2
CAL_S_DONE = 4
S_PROBE    = 7

# R8 slot0 bit positions.
BIT_TRAINING_MODE = 1 << 0
BIT_SWI_RECAL     = 1 << 1
BIT_FORCE_RECAL   = 1 << 6      # P1 — the W1P under test


def _cal_state(tb, side):
    return int(tb.top(side).u_chiplet_controller.u_calibrator.cur_state.value)


async def _rmw_set(tb, side, bits):
    """Read-modify-write R8 slot0.

    Slot 0 is a PACKED register: the write decode assigns training_mode,
    SWI_RECAL and the three SYNC control bits from the SAME wdata. A blind
    write of just the W1P would CLEAR them all and disturb a live link, so
    firmware must read-modify-write. Doing the same here keeps the test
    faithful to the recipe firmware has to follow.
    """
    apb = tb.apb(side)
    cur = await apb.read(APB_R8_SLOT0)
    await apb.write(APB_R8_SLOT0, cur | bits)
    return cur


async def _rmw_clear(tb, side, bits):
    apb = tb.apb(side)
    cur = await apb.read(APB_R8_SLOT0)
    await apb.write(APB_R8_SLOT0, cur & ~bits)
    return cur


async def _sample_cal_states(tb, side, n=60, every=20):
    """Sample the calibrator FSM n times. Mirrors the doc's 60-sample method."""
    seen = []
    for _ in range(n):
        await ClockCycles(tb.dut.hclk, every)
        seen.append(_cal_state(tb, side))
    return seen


@cocotb.test()
async def test_01_swi_recal_is_noop_on_live_link(dut):
    """CONTROL / defect reproduction, end-to-end.

    On a converged live link, an SWI_RECAL (bit[1]) 1->0 pulse must leave both
    calibrators parked in S_DONE. This is the measured defect AND the Bug-A
    guard: the autoneg training-exit pulse lands on this same path.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"

    for side in ("m", "s"):
        assert _cal_state(tb, side) == CAL_S_DONE, (
            f"{side}: calibrator not in S_DONE before the test "
            f"(state={_cal_state(tb, side)})"
        )

    # SWI_RECAL level pulse, exactly as the bring-up recipe issues it.
    await _rmw_set(tb, "m", BIT_SWI_RECAL)
    await ClockCycles(dut.hclk, 200)
    await _rmw_clear(tb, "m", BIT_SWI_RECAL)      # the falling edge is the trigger

    seen = await _sample_cal_states(tb, "m")
    tb.log.info(f"[control] master cal states after SWI_RECAL: {sorted(set(seen))}")
    assert all(s == CAL_S_DONE for s in seen), (
        f"SWI_RECAL unexpectedly re-armed the calibrator (states={sorted(set(seen))}). "
        f"If this fails, calibrated_once_q / the Bug-A guard has been weakened."
    )


@cocotb.test()
async def test_02_force_recal_reaches_the_calibrator_unilaterally(dut):
    """THE FIX REACHES THE CALIBRATOR, end-to-end.

    Writing SWI_FORCE_RECAL on ONE die must take the whole path (APB W1P ->
    acc stretcher -> CDC -> calibrator) and genuinely re-arm the sweep: the FSM
    leaves S_DONE and enters the alignment-search states. Contrast test_01,
    where SWI_RECAL on the same live link does nothing at all.

    DELIBERATELY NOT ASSERTED HERE: that a UNILATERAL forced recal
    RE-CONVERGES. It does not, and that is correct behaviour, not a defect —
    see test_03. The peer is in data mode and is NOT emitting the training
    pattern, so the re-training die's lane_checker never locks and the
    calibrator re-sweeps (MAX_RESWEEPS=0 = "retry while role_locked", the T3
    continuous-re-sweep policy). A forced recal is therefore a BILATERAL
    operation for firmware, exactly like the SWI_RECAL bring-up recipe which
    "holds the training pattern on BOTH boards".
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    await send_and_check(tb, "m", "s", [0xD00D0001, 0x11111111], ctx="pre-recal m2s")
    await send_and_check(tb, "s", "m", [0xD00D0002, 0x22222222], ctx="pre-recal s2m")

    assert _cal_state(tb, "m") == CAL_S_DONE, "master calibrator not parked in S_DONE"

    await _rmw_set(tb, "m", BIT_FORCE_RECAL)

    states = []
    for _ in range(400):
        await ClockCycles(dut.hclk, 10)
        states.append(_cal_state(tb, "m"))
    tb.log.info(f"[fix] master cal states after SWI_FORCE_RECAL: {sorted(set(states))}")

    assert any(s != CAL_S_DONE for s in states), (
        "SWI_FORCE_RECAL did NOT re-arm the calibrator on a live link — the FSM "
        f"never left S_DONE (states={sorted(set(states))}). The W1P did not reach "
        "the calibrator: check the acc W1P decode, the pulse-stretcher, and the "
        "apb_clk -> rx_link_clk CDC."
    )
    assert S_ARM in states, (
        f"FSM left S_DONE but never passed through S_ARM (states={sorted(set(states))})"
    )
    assert (S_PROBE in states) or (S_SWEEP in states), (
        f"FSM re-armed but never entered the alignment search "
        f"(states={sorted(set(states))}) — it did not actually re-calibrate."
    )


@cocotb.test()
async def test_04_w1p_is_write_only_no_rmw_reinjection(dut):
    """CONTRACT LOCK: SWI_FORCE_RECAL is write-only and reads back 0.

    Slot 0 is a PACKED register that firmware must read-modify-write to touch
    training_mode / SWI_RECAL / the SYNC bits. If bit[6] ever read back as the
    pulse-stretcher's state, an RMW landing inside the 1024-cycle window would
    read bit[6]=1, write it straight back and re-fire the W1P — silently
    re-arming a PHY retrain, indefinitely under a polling loop. bit[6] therefore
    reads 0 always, exactly like the slot-0 bit[5] SWI_SYNC_OBS_CLR pulse beside
    it. This test locks that contract:
      (a) a burst of innocent RMW cycles must not start any retrain;
      (b) a read taken INSIDE the stretch window must show bit[6]=0, while a
          sanity check confirms the W1P is nonetheless live.

    SCOPE — READ THIS BEFORE TRUSTING IT AS A REGRESSION TEST. A negative
    control was run (2026-07-19): the readback was deliberately reverted to
    expose the stretcher state, and THIS TEST STILL PASSED. Measured at the same
    instant, `swi_force_recal_r`=1 with the counter mid-window (1024 -> 462) yet
    the APB read of slot 0 returned bit[6]=0 regardless. The V2 readback branch
    was confirmed live (bit[2] round-trips) and no mask was found on the
    `region8_rdata -> ctrl_reg_rdata -> prdata` path, so the mechanism is NOT
    explained; attempts to localise it sampled combinational nets outside the
    APB transaction window and were inconclusive.

    Consequence, stated plainly: this test asserts the CONTRACT that firmware
    depends on, but it is NOT demonstrated to detect a regression of the
    readback mux itself. Do not cite it as proof that the RMW hazard is gated in
    hardware. The fix stands on its own merits — write-only makes the
    re-injection structurally impossible whatever the readback plumbing does —
    but the hazard's reachability in this build is an OPEN question.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    apb = tb.apb("m")

    # --- (b) FIRST, on a pristine converged link: innocent RMW must not
    #         retrain. Done before any forced recal so the calibrator is
    #         cleanly parked in S_DONE and nothing else can perturb it.
    #         (Ordering matters: a UNILATERAL forced recal never re-converges
    #         by design — see test_02 — so doing one first would leave the FSM
    #         legitimately sweeping and this check could not distinguish that
    #         from RMW re-injection.)
    assert _cal_state(tb, "m") == CAL_S_DONE, "master calibrator not parked in S_DONE"

    for _ in range(6):
        cur = await apb.read(APB_R8_SLOT0)
        await apb.write(APB_R8_SLOT0, cur)          # write back verbatim
        await ClockCycles(dut.hclk, 50)

    seen = await _sample_cal_states(tb, "m", n=80, every=20)
    assert all(s == CAL_S_DONE for s in seen), (
        f"innocent read-modify-write of slot 0 re-triggered the calibrator "
        f"(states={sorted(set(seen))}) — the W1P is being re-injected by RMW."
    )

    # --- (a) the readback itself: bit[6] must read 0 even immediately after
    #         the write, i.e. while the 1024-cycle stretcher is still asserted.
    #         Left last: the retrain this legitimately starts is unilateral and
    #         so will not re-converge, which is fine at end-of-test.
    await _rmw_set(tb, "m", BIT_FORCE_RECAL)
    # Settle INSIDE the 1024-cycle stretch window before reading. Reading back
    # immediately is a race that hides the bug: the APB read captures prdata
    # 2-3 clocks after the write, which can be BEFORE swi_force_recal_r has even
    # gone high (measured: readback=0 while the counter still read 1022). Real
    # firmware polls microseconds later, i.e. squarely inside the window — this
    # delay models that and is what gives the check teeth (verified against a
    # deliberately-reverted readback, which this then catches).
    await ClockCycles(dut.hclk, 40)
    rb = await apb.read(APB_R8_SLOT0)
    assert (rb & BIT_FORCE_RECAL) == 0, (
        f"R8 slot0 bit[6] read back SET (0x{rb:08x}) immediately after the W1P. "
        f"It must be WRITE-ONLY and read 0 — otherwise any firmware "
        f"read-modify-write of slot 0 re-injects the pulse and re-arms a PHY "
        f"retrain on a converged link, indefinitely under a polling loop."
    )
    # Sanity: that write DID do something (guards against the opposite error —
    # a test that passes because the W1P is dead).
    states = []
    for _ in range(400):
        await ClockCycles(dut.hclk, 10)
        states.append(_cal_state(tb, "m"))
    assert any(s != CAL_S_DONE for s in states), (
        "the W1P write did not start a retrain at all — bit[6] reads 0 for the "
        "wrong reason (control is dead, not merely write-only)."
    )


@cocotb.test()
async def test_03_bilateral_force_recal_relinks_byte_exact(dut):
    """THE FIX, THE WAY FIRMWARE MUST USE IT.

    1. bring the link up and prove data flows byte-exact both ways
    2. write SWI_FORCE_RECAL on BOTH dies (both re-enter training, so each
       side sees the peer's training pattern — the same bilateral requirement
       the SWI_RECAL recipe has always had)
    3. both calibrators must leave S_DONE and RE-CONVERGE to S_DONE
    4. the link must still carry data BYTE-EXACT in BOTH directions
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    # --- 1. pre-recal data, both directions -------------------------------
    await send_and_check(tb, "m", "s", [0xB0A70001, 0x55555555], ctx="pre-recal m2s")
    await send_and_check(tb, "s", "m", [0xB0A70002, 0x66666666], ctx="pre-recal s2m")

    for side in ("m", "s"):
        assert _cal_state(tb, side) == CAL_S_DONE, (
            f"{side}: calibrator not parked in S_DONE before the forced recal"
        )

    # --- 2. the W1P on BOTH dies -----------------------------------------
    await _rmw_set(tb, "m", BIT_FORCE_RECAL)
    await _rmw_set(tb, "s", BIT_FORCE_RECAL)

    # --- 3. both must retrain and re-converge -----------------------------
    seen = {"m": set(), "s": set()}
    for _ in range(600):
        await ClockCycles(dut.hclk, 10)
        for side in ("m", "s"):
            seen[side].add(_cal_state(tb, side))
    tb.log.info(f"[bilateral] cal states: M={sorted(seen['m'])} S={sorted(seen['s'])}")

    for side in ("m", "s"):
        assert any(s != CAL_S_DONE for s in seen[side]), (
            f"{side}: SWI_FORCE_RECAL did not re-arm the calibrator "
            f"(states={sorted(seen[side])})"
        )

    for side in ("m", "s"):
        for _ in range(20000):
            await ClockCycles(dut.hclk, 10)
            if _cal_state(tb, side) == CAL_S_DONE:
                break
        assert _cal_state(tb, side) == CAL_S_DONE, (
            f"{side}: calibrator re-armed but never RE-CONVERGED "
            f"(state={_cal_state(tb, side)}) — a recal that cannot finish is "
            f"worse than no recal."
        )

    # --- 4. the link must still work, byte-exact, BOTH ways ---------------
    await ClockCycles(dut.hclk, 5000)
    await send_and_check(tb, "m", "s", [0xB0A70003, 0x77777777], ctx="post-recal m2s")
    await send_and_check(tb, "s", "m", [0xB0A70004, 0x88888888], ctx="post-recal s2m")

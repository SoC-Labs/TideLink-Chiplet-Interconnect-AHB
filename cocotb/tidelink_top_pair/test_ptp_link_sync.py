"""Real PTP-over-link clock-synchronisation test for the integrated
``tidelink_top`` pair (V2 PHY branch).

Why this exists
---------------
The prior integrated PTP "test" (``test_ptp_corrected_regs.py``) ran against a
testbench that **tied off the whole PHC interface** — ``phc_*`` inputs to 0 and,
critically, ``phc_locked_i = 1'b1`` on both sides. That made
``HW_SYNC_STATUS[18]`` (phc_locked) a *spurious* pass: the bit read back high
even though no PTP traffic ever crossed the link and no timestamps were ever
captured. PTP-over-the-link sync was therefore never actually demonstrated in
the integrated pair sim.

This test fixes that. ``tb_top.sv`` now instantiates a behavioural PHC model
(``tb_phc_model.sv``) per die that:
  * free-runs a real ns/sec clock,
  * latches timestamps on the PTP module's ``phc_hw_capture`` pulse,
  * applies the servo's ``phc_hw_set_time`` phase step and
    ``phc_hw_adj_ns_incr_frac`` frequency steer,
  * asserts ``phc_locked_i`` ONLY after the PHC has been running (NOT tied).

The slave PHC starts with a large initial offset versus the master. We then:
  1. bring the link up + role-lock (reusing the doorbell test helpers),
  2. verify phc_locked is a *real* status bit (drive it low, see it follow),
  3. configure the master servo as Grandmaster + slave servo as Subordinate,
  4. enable PTP on both sides and arm the master HW_SYNC initiator,
  5. run repeated SYNC / DELAY_REQ exchanges across the link,
  6. ASSERT the servo-reported offset converges toward zero AND the two PHC
     counters actually align — a genuine pass/fail gate.

PHC <-> servo register map (TideLink APB, via tidelink_apb_regs.sv):
  0x034 PTP_CTRL       [0] ptp_enable
  0x040 HW_SYNC_CTRL   [0] enable [1] seq_clear(W1C) [2] force_en
  0x044 HW_SYNC_INTERVAL
  0x048 HW_SYNC_STATUS [0] active [1] busy [17:2] seq_num [18] phc_locked
  0x04C SERVO_CTRL     [0] enable [1] mode (0=GM, 1=Sub)
  0x058 SERVO_STEP_THRESH
  0x05C SERVO_STATUS   [0] locked [1] active
  0x060 SERVO_DELAY*   -> last_offset_r (signed ns)   (servo_reg_addr 5)
  0x064 SERVO_NS_FRAC* -> last_delay_r  (ns)           (servo_reg_addr 6)
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_TIDELINK_BASE,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)

# --- Register offsets (absolute APB addresses) -----------------------------
APB_PTP_CTRL         = APB_TIDELINK_BASE + 0x034
APB_HW_SYNC_CTRL     = APB_TIDELINK_BASE + 0x040
APB_HW_SYNC_INTERVAL = APB_TIDELINK_BASE + 0x044
APB_HW_SYNC_STATUS   = APB_TIDELINK_BASE + 0x048
APB_SERVO_CTRL       = APB_TIDELINK_BASE + 0x04C
APB_SERVO_STEP       = APB_TIDELINK_BASE + 0x058
APB_SERVO_STATUS     = APB_TIDELINK_BASE + 0x05C
APB_SERVO_OFFSET     = APB_TIDELINK_BASE + 0x060   # last_offset_r (signed ns)
APB_SERVO_DELAY      = APB_TIDELINK_BASE + 0x064   # last_delay_r (ns)

# Field encodings
PTP_ENABLE           = 0x01
HW_SYNC_FORCE_EN     = 0x05     # [2] force_en | [0] enable
HW_SYNC_ENABLE       = 0x01
SERVO_GM_ENABLE      = 0x01     # enable, mode=0 (Grandmaster)
SERVO_SUB_ENABLE     = 0x03     # enable, mode=1 (Subordinate)
SERVO_DISABLE        = 0x00

# A generous step threshold so the first (large) offset takes a SET_TIME phase
# step, then subsequent small offsets ride the PI frequency steer toward lock.
SERVO_STEP_THRESH_NS = 12000


def _s32(v):
    """Interpret a 32-bit register value as signed."""
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & (1 << 31) else v


def _phc_now_ns(dut, side):
    """Total PHC time (seconds*1e9 + ns) for the given die's PHC model."""
    phc = dut.u_m_phc if side == "m" else dut.u_s_phc
    sec = int(phc.phc_seconds.value)
    ns = int(phc.phc_nanoseconds.value)
    return sec * 1_000_000_000 + ns


async def _gm_seq(tb):
    return (await tb.m_apb.read(APB_HW_SYNC_STATUS) >> 2) & 0xFFFF


async def _run_one_exchange(tb, settle=8000, fire_timeout=400):
    """Fire EXACTLY ONE master SYNC and let the full single-phase exchange
    complete: SYNC TX(t1) -> link -> SYNC RX(t2) -> DELAY_REQ TX(t3) -> link
    -> DELAY_REQ RX(t4) -> GM sends t1,t4 via FC SIDEBAND -> slave latches,
    computes offset = ((t2-t1)-(t4-t3))/2, and disciplines its PHC.

    The HW_SYNC initiator free-runs while force_en is held (it re-arms and
    re-fires every ~dozen cycles), so we arm with force_en, wait for the GM
    sequence number to advance by exactly one, then fully DISABLE HW_SYNC
    (CTRL=0) to drop the FSM back to IDLE. This yields one SYNC per call —
    overlapping exchanges otherwise interleave the GM/Sub FSMs and corrupt
    the t1..t4 capture."""
    seq0 = await _gm_seq(tb)
    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_FORCE_EN)
    # Wait for one fire (seq increments), then disable immediately.
    fired = False
    for _ in range(fire_timeout):
        await ClockCycles(tb.dut.hclk, 1)
        if ((await _gm_seq(tb)) - seq0) & 0xFFFF >= 1:
            fired = True
            break
    await tb.m_apb.write(APB_HW_SYNC_CTRL, SERVO_DISABLE)  # CTRL=0 -> FSM IDLE
    assert fired, "GM HW_SYNC did not fire within timeout (no SYNC emitted)"
    # Let the SYNC/DELAY_REQ + FC SIDEBAND round-trip + servo compute settle.
    await ClockCycles(tb.dut.hclk, settle)


async def _setup_ptp(tb):
    """Bring the link up, configure GM/Sub roles, enable PTP."""
    await run_bringup_full(tb)

    # Ensure both sides are in data mode (run_bringup_full already does this,
    # but explicit is harmless and matches the corrected-regs test).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Servo roles: master = Grandmaster, slave = Subordinate.
    await tb.m_apb.write(APB_SERVO_STEP, SERVO_STEP_THRESH_NS)
    await tb.s_apb.write(APB_SERVO_STEP, SERVO_STEP_THRESH_NS)
    await tb.m_apb.write(APB_SERVO_CTRL, SERVO_GM_ENABLE)
    await tb.s_apb.write(APB_SERVO_CTRL, SERVO_SUB_ENABLE)

    # Enable PTP short-packet engine on both sides (opens RX accept + TX).
    await tb.s_apb.write(APB_PTP_CTRL, PTP_ENABLE)
    await tb.m_apb.write(APB_PTP_CTRL, PTP_ENABLE)
    await ClockCycles(tb.dut.hclk, 100)


# ===========================================================================
# Tests
# ===========================================================================

@cocotb.test()
async def test_phc_locked_is_real_not_tied(dut):
    """Guard: phc_locked is a genuine status bit driven by the PHC model,
    NOT hard-tied to 1. Pull the slave PHC lock gate low and confirm
    HW_SYNC_STATUS[18] follows; restore it and confirm it re-asserts."""
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await ClockCycles(dut.hclk, 200)

    # After bringup the PHC has been running well past LOCK_AFTER_CYCLES.
    s_status = await tb.s_apb.read(APB_HW_SYNC_STATUS)
    locked_hi = (s_status >> 18) & 1
    tb.log.info(f"  slave HW_SYNC_STATUS = 0x{s_status:08x} phc_locked={locked_hi}")
    assert locked_hi == 1, (
        "phc_locked should be high once the PHC has settled "
        f"(status=0x{s_status:08x})"
    )

    # Drop the TB lock gate -> phc_locked must fall (proves it is NOT tied).
    dut.s_phc_lock_enable.value = 0
    await ClockCycles(dut.hclk, 50)
    s_status = await tb.s_apb.read(APB_HW_SYNC_STATUS)
    locked_lo = (s_status >> 18) & 1
    tb.log.info(f"  after lock_enable=0: status=0x{s_status:08x} phc_locked={locked_lo}")
    assert locked_lo == 0, (
        "phc_locked stayed high after the PHC lock gate dropped — it is "
        f"spuriously tied (status=0x{s_status:08x})"
    )

    # Restore — it should re-assert.
    dut.s_phc_lock_enable.value = 1
    await ClockCycles(dut.hclk, 50)
    s_status = await tb.s_apb.read(APB_HW_SYNC_STATUS)
    assert (s_status >> 18) & 1 == 1, "phc_locked did not re-assert after restore"
    tb.log.info("  phc_locked tracks the PHC lock gate -> NOT tied. PASS")


@cocotb.test()
async def test_ptp_offset_converges_over_link(dut):
    """REAL PTP-over-link sync: master(GM) and slave(Sub) servos exchange
    SYNC/DELAY_REQ + FC SIDEBAND timestamps across the link; assert the
    servo-reported offset converges toward zero and the two PHC counters
    actually align."""
    tb = PairTB(dut)
    await _setup_ptp(tb)

    init_skew = _phc_now_ns(dut, "s") - _phc_now_ns(dut, "m")
    tb.log.info(f"  initial PHC skew (slave - master) = {init_skew} ns")
    assert abs(init_skew) > SERVO_STEP_THRESH_NS, (
        "test misconfigured: initial skew should exceed the step threshold "
        f"so there is a real error to null (skew={init_skew} ns)"
    )

    # The first SYNC/DELAY_REQ round-trip runs before the PHC capture pipeline
    # (PTP-module -> CDC -> PHC -> CDC -> servo) is primed, so its t1..t4 are
    # cold. Run a couple of WARMUP exchanges to prime the loop and apply the
    # coarse phase step, then MEASURE steady-state convergence.
    N_WARMUP   = 3
    N_MEASURE  = 6
    for i in range(N_WARMUP):
        await _run_one_exchange(tb)
        off = _s32(await tb.s_apb.read(APB_SERVO_OFFSET))
        skew = _phc_now_ns(dut, "s") - _phc_now_ns(dut, "m")
        tb.log.info(f"  warmup {i}: servo_last_offset={off} ns  PHC skew={skew} ns")

    skew_after_warmup = _phc_now_ns(dut, "s") - _phc_now_ns(dut, "m")

    offsets = []
    skews   = []
    for i in range(N_MEASURE):
        await _run_one_exchange(tb)
        off = _s32(await tb.s_apb.read(APB_SERVO_OFFSET))
        skew = _phc_now_ns(dut, "s") - _phc_now_ns(dut, "m")
        seq = (await tb.m_apb.read(APB_HW_SYNC_STATUS) >> 2) & 0xFFFF
        offsets.append(off)
        skews.append(skew)
        tb.log.info(
            f"  measure {i}: GM seq=0x{seq:04x} servo_last_offset={off} ns  "
            f"PHC skew(slave-master)={skew} ns"
        )

    # --- Gate 1: the GM initiator actually fired (seq advanced) ------------
    final_seq = (await tb.m_apb.read(APB_HW_SYNC_STATUS) >> 2) & 0xFFFF
    assert final_seq > 0, (
        f"GM HW_SYNC never fired (seq_num=0x{final_seq:04x}); no SYNC crossed "
        "the link"
    )

    # --- Gate 2: the slave servo computed a non-trivial offset at least once
    # (proves the full t1..t4 round-trip: SYNC RX, DELAY_REQ TX, and FC
    #  SIDEBAND timestamp delivery all worked end-to-end across the link).
    assert any(o != 0 for o in offsets), (
        "slave servo never produced a non-zero offset — the PTP "
        f"SYNC/DELAY_REQ/SIDEBAND exchange did not complete (offsets={offsets})"
    )

    # --- Gate 3: convergence — the warmup phase nulled the bulk of the skew,
    # and the steady-state servo offset stays small (servo drove the error
    # toward zero and HOLDS it).
    worst_off  = max(abs(o) for o in offsets)
    worst_skew = max(abs(s) for s in skews)
    final_skew = skews[-1]
    tb.log.info(
        f"  CONVERGENCE: init_skew={init_skew} ns -> after warmup "
        f"{skew_after_warmup} ns -> steady-state worst |offset|={worst_off} ns, "
        f"worst |skew|={worst_skew} ns, final skew={final_skew} ns"
    )

    assert abs(skew_after_warmup) < abs(init_skew), (
        f"servo did not reduce the PHC skew during warmup: "
        f"|after_warmup|={abs(skew_after_warmup)} >= |init|={abs(init_skew)}"
    )
    # Steady-state servo offset must stay well below the coarse step threshold:
    # the loop has converged into the fine (PI frequency-steer) regime.
    assert worst_off <= SERVO_STEP_THRESH_NS, (
        f"steady-state servo offset did not stay converged: worst |offset|="
        f"{worst_off} ns > {SERVO_STEP_THRESH_NS} ns (offsets={offsets})"
    )
    # The disciplined PHC counters must actually track each other now — the
    # real proof of clock sync, independent of the servo's self-report. Allow a
    # few step-thresholds of residual to cover the irreducible link/loop
    # latency between t2 capture and SET_TIME application.
    assert worst_skew <= 3 * SERVO_STEP_THRESH_NS, (
        f"PHC counters did not stay aligned: worst |skew|={worst_skew} ns "
        f"(init was {init_skew} ns)"
    )
    tb.log.info("  PTP-over-link clock sync CONVERGED and HELD. PASS")

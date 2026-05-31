"""Bug B regression — PHC ``phc_time_reached`` saturation symptom.

Companion to:
  * ``docs/BUG_B_FIX_PLAN_2026_05_29.md``       (RTL root cause + Option A)
  * ``docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`` (RTL diff to tidelink_ptp.sv)
  * ``docs/BUG_B_BD_FIX_DESIGN_2026_05_31.md``  (BD-level wiring fix)

What this test covers
---------------------
Bug B has two coupled defects:

(1) RTL — ``phc_time_reached`` (tidelink_ptp.sv:398-415 pre-patch)
    ignored ``hw_sync_force_en_r``. With the BD/sim tie-off
    ``phc_nanoseconds = 30'h0`` (still hard-coded in
    ``cocotb/tidelink_top_pair/tb_top.sv:315``), the HW_SYNC FSM wedged
    in ``HW_SYNC_ARMED`` forever after SW wrote ``HW_SYNC_CTRL = 0x05``
    because ``target_ns_r = 999_999_999 >> phc_nanoseconds = 0``.

(2) BD — Six Vivado targets (single, loopback, pair-slow,
    pair-flip-slow, pair-ila, pair-flip-ila) tie ``phc_nanoseconds``
    to a 30-bit zero ``xlconstant``. With (1) fixed, ``force_en = 1``
    is the only way HW_SYNC ever fires — and it fires at ~3.6 Mpps
    (saturation symptom). The natural cadence
    (``HW_SYNC_CTRL = 0x01``, no force_en) cannot fire at all.

This file ships two tests:

  * ``test_phc_time_reached_saturation_with_tieoff``
      Reproduces the saturation symptom: with the pair tb_top's
      built-in ``phc_nanoseconds = 30'h0`` tie-off (= BD tie-off
      equivalent), writing ``HW_SYNC_CTRL = 0x05`` should drive
      ``phc_time_reached`` permanently high. ``hw_seq_num`` should
      increment monotonically with no upper bound — the saturation
      signature.

      With the RTL patch applied, this test PASSES (saturation IS the
      observed behaviour, by design of the force_en bypass).
      Without the RTL patch, this test FAILS at the seq_num assertion
      (FSM wedges in ARMED, seq_num stays at 0). So the test serves
      double duty: (a) RTL-patch regression, (b) saturation-symptom
      witness for the BD-fix discussion.

  * ``test_phc_time_reached_only_when_counter_genuinely_reaches_target``
      Stubs the BD-level free-running counter via cocotb ``Force`` on
      ``dut.u_master.u_ptp.phc_nanoseconds``. Writes
      ``HW_SYNC_CTRL = 0x01`` (no force_en) with a short
      ``HW_SYNC_INTERVAL``. Verifies seq_num does NOT increment until
      the forced counter genuinely crosses the target, then increments
      exactly once per crossing. This is what silicon will do after
      BD wiring lands.

The test deliberately uses ``Force``/``Release`` on inner DUT nets so
it stresses the natural cadence path without needing the actual PHC
Vivado IP in sim — the BD wiring fix is a Vivado-only change and is
covered in ``docs/BUG_B_BD_FIX_DESIGN_2026_05_31.md``.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the canonical pair-bringup fixtures verbatim.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_TIDELINK_BASE,
    APB_PTP_CTRL,
    APB_HW_SYNC_CTRL,
    APB_HW_SYNC_STATUS,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


# HW_SYNC_INTERVAL lives at OFF_HW_SYNC_INTERVAL = 0x044 (tidelink_ptp.sv:354)
OFF_HW_SYNC_INTERVAL = 0x044
APB_HW_SYNC_INTERVAL = APB_TIDELINK_BASE + OFF_HW_SYNC_INTERVAL   # 0x2044

# HW_SYNC_STATUS bitfield (tidelink_ptp.sv:521 + handoff §6)
#   [0]     active
#   [1]     busy
#   [17:2]  hw_seq_num (16-bit)
#   [18]    phc_locked
HW_SYNC_STATUS_SEQNUM_SHIFT = 2
HW_SYNC_STATUS_SEQNUM_MASK  = 0xFFFF

# HW_SYNC_CTRL bits
HW_SYNC_CTRL_ENABLE         = 0x01
HW_SYNC_CTRL_FORCE_ENABLE   = 0x05   # force_en | enable

# PTP_CTRL bits — see test_ptp_corrected_regs.py
PTP_CTRL_MASTER_GM_ENABLE   = 0x09   # GM | enable
PTP_CTRL_SLAVE_ENABLE       = 0x01


def _seq_num(status):
    return (status >> HW_SYNC_STATUS_SEQNUM_SHIFT) & HW_SYNC_STATUS_SEQNUM_MASK


_PTP_HANDLE_CACHE = {}


def _ptp_handle(dut, side):
    """Resolve the ``tidelink_ptp`` instance under ``u_master`` /
    ``u_slave``.

    ``u_ptp`` lives inside a ``generate if (STUB_PTP == 1'b0)`` block
    named ``gen_ptp_real`` (src/rtl/tidelink_top.sv:1213). VCS+cocotb
    expose this as a SINGLE attribute whose name literally contains
    a dot: ``"gen_ptp_real.u_ptp"`` — use ``__getitem__`` (subscript)
    rather than dotted ``getattr`` traversal.
    """
    key = ("m" if side == "m" else "s")
    cached = _PTP_HANDLE_CACHE.get(key)
    if cached is not None:
        return cached

    top = dut.u_master if side == "m" else dut.u_slave
    # VCS-elaborated child name (verified at runtime via dir(u_master))
    candidates = (
        "gen_ptp_real.u_ptp",
        "u_ptp",
    )
    for name in candidates:
        try:
            h = top[name]
            _ = h.hw_sync_state_r
            _PTP_HANDLE_CACHE[key] = h
            return h
        except (KeyError, AttributeError, ValueError):
            continue
    raise AttributeError(
        f"cannot resolve u_ptp under "
        f"{top._path if hasattr(top, '_path') else top}"
    )


def _phc_time_reached(dut, side):
    """Direct probe on the combinational ``phc_time_reached`` wire."""
    try:
        return int(_ptp_handle(dut, side).phc_time_reached.value)
    except (AttributeError, ValueError):
        return -1


def _hw_sync_state(dut, side):
    try:
        return int(_ptp_handle(dut, side).hw_sync_state_r.value)
    except (AttributeError, ValueError):
        return -1


def _hw_seq_num(dut, side):
    try:
        return int(_ptp_handle(dut, side).hw_seq_num_int_r.value)
    except (AttributeError, ValueError):
        return -1


# ---------------------------------------------------------------------------
# Test 1 — saturation symptom (post-RTL-patch, pre-BD-fix)
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_phc_time_reached_saturation_with_tieoff(dut):
    """Reproduce the Bug B saturation symptom on the patched RTL.

    With the RTL fix applied and the pair tb_top's built-in
    ``phc_nanoseconds = 30'h0`` tie-off (= BD tie-off equivalent),
    writing ``HW_SYNC_CTRL = 0x05`` should:

      * Drive ``phc_time_reached`` permanently high (the force_en
        OR-term in tidelink_ptp.sv:412 bypasses the PHC comparison).
      * Cause ``hw_seq_num`` to increment monotonically with no
        upper bound (saturation; ~1 SYNC every 12-30 hclk cycles per
        BUG_B_FIX_VERIFICATION_2026_05_29 §4).

    Pre-RTL-patch, the second assertion fails: the FSM wedges in
    ARMED and seq_num stays at 0.

    This test serves as the RTL-patch regression witness AND as the
    saturation-symptom evidence motivating the BD-level fix.
    """
    tb = PairTB(dut)
    snaps = await run_bringup_full(tb)
    tb.log.info(f"  bringup complete: {snaps}")

    # Drop training mode (belt-and-braces over run_bringup_full).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Enable PTP on both sides — slave first (opens rx_accept gate).
    await tb.s_apb.write(APB_PTP_CTRL, PTP_CTRL_SLAVE_ENABLE)
    await tb.m_apb.write(APB_PTP_CTRL, PTP_CTRL_MASTER_GM_ENABLE)
    await ClockCycles(tb.dut.hclk, 100)

    # ARM HW_SYNC with force_en + enable. With the RTL patch this
    # should fire-now-bypass-PHC-time. Without the patch, the FSM
    # wedges in ARMED and the assertion later in this test fails.
    seq_before = await tb.m_apb.read(APB_HW_SYNC_STATUS)
    seq_before_n = _seq_num(seq_before)
    tb.log.info(
        f"  pre-arm  master HW_SYNC_STATUS=0x{seq_before:08x} seq={seq_before_n}"
    )

    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_CTRL_FORCE_ENABLE)
    tb.log.info(
        f"  master HW_SYNC_CTRL <= 0x{HW_SYNC_CTRL_FORCE_ENABLE:02x} "
        "(force_en + enable)"
    )

    # Give the APB write 50 hclk cycles to propagate through the bridge
    # to the PTP register block before sampling the inner state.
    await ClockCycles(tb.dut.hclk, 50)

    # Sanity-probe: confirm the register write reached the PTP block.
    try:
        en_v   = int(_ptp_handle(dut, "m").hw_sync_en_r.value)
        fen_v  = int(_ptp_handle(dut, "m").hw_sync_force_en_r.value)
        state0 = _hw_sync_state(dut, "m")
        gate_v = int(_ptp_handle(dut, "m").hw_sync_gate.value)
        tb.log.info(
            f"  post-write probe: hw_sync_en_r={en_v} hw_sync_force_en_r={fen_v} "
            f"hw_sync_state_r={state0} hw_sync_gate={gate_v}"
        )
    except (AttributeError, ValueError) as e:
        tb.log.warning(f"  post-write probe unavailable: {e}")

    # Sample the phc_time_reached probe over a 500-cy window.
    phc_tr_high = 0
    armed_state = 0
    fire_state  = 0
    for _ in range(500):
        await RisingEdge(dut.hclk)
        if _phc_time_reached(dut, "m") == 1:
            phc_tr_high += 1
        st = _hw_sync_state(dut, "m")
        # hw_sync_state_t enum: IDLE=0, ARMED=1, FIRE=2, WAIT_TX=3
        if st == 1:
            armed_state += 1
        elif st == 2:
            fire_state += 1
    tb.log.info(
        f"  500cy probe: phc_time_reached high={phc_tr_high}/500 "
        f"ARMED={armed_state}/500 FIRE={fire_state}/500"
    )

    # Assertion 1 — phc_time_reached must be predominantly HIGH
    # whenever the FSM is in or has passed ARMED. The post-patch RTL
    # makes the OR-term ``hw_sync_force_en_r`` true while CTRL.force_en
    # is held, so the comb wire reads 1 every sample (give 5% wiggle
    # room for the small startup window before the CTRL write
    # propagated).
    assert phc_tr_high >= 475, (
        f"phc_time_reached only high in {phc_tr_high}/500 cy with "
        f"force_en=1 — RTL patch may not be applied (expected ~500/500). "
        f"See docs/BUG_B_PROPOSED_FIX_2026_05_29.patch."
    )

    # Assertion 2 — hw_seq_num must be incrementing (saturation
    # signature). Read again after a 2000-cy settle.
    await ClockCycles(tb.dut.hclk, 2000)
    seq_after = await tb.m_apb.read(APB_HW_SYNC_STATUS)
    seq_after_n = _seq_num(seq_after)
    tb.log.info(
        f"  post-arm master HW_SYNC_STATUS=0x{seq_after:08x} "
        f"seq={seq_after_n} (delta={seq_after_n - seq_before_n})"
    )
    assert seq_after_n > seq_before_n, (
        f"hw_seq_num did NOT advance ({seq_before_n} -> {seq_after_n}) "
        f"after HW_SYNC_CTRL=0x05 — FSM wedged in ARMED. This is the "
        f"pre-patch Bug B symptom; verify the OR-term fix at "
        f"src/rtl/tidelink_ptp.sv:412."
    )
    # Saturation rate sanity: in 2000 cy at ~1 SYNC per 27 cy we expect
    # ~70 increments. Demand at least 20 as a robust lower bound.
    assert (seq_after_n - seq_before_n) >= 20, (
        f"seq_num only advanced by {seq_after_n - seq_before_n} in 2000 cy "
        f"— expected ~70 (saturation rate per VERIFICATION §4)."
    )

    tb.log.info(
        "  SATURATION SYMPTOM REPRODUCED — RTL patch correct, BD fix "
        "still required to recover natural cadence "
        "(see docs/BUG_B_BD_FIX_DESIGN_2026_05_31.md)."
    )


# ---------------------------------------------------------------------------
# Test 2 — post-BD-fix behaviour: phc_time_reached follows the counter
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_phc_time_reached_only_when_counter_genuinely_reaches_target(dut):
    """Verify the post-BD-fix behaviour by stubbing the BD counter.

    The BD fix wires ``phc_nanoseconds`` to a free-running counter
    (the phc_vivado_wrapper). In sim we stub this by ``Force``-ing
    ``dut.u_master.u_ptp.phc_nanoseconds`` to a programmable value.

    With ``HW_SYNC_CTRL = 0x01`` (no force_en) and a short
    ``HW_SYNC_INTERVAL`` (e.g. 1000 ns), the FSM must:

      * Stay in ARMED while forced ``phc_nanoseconds < target_ns_r``.
      * Cross to FIRE when forced ``phc_nanoseconds >= target_ns_r``.
      * Increment ``hw_seq_num`` exactly once per crossing (NOT
        saturate, because force_en=0 lets the post-patch ``||
        hw_sync_force_en_r`` term go false).

    Without the RTL patch, this test would also pass (force_en is 0
    and the time comparison was the only gate). So this test
    specifically guards against a regression where the patch
    accidentally welded ``phc_time_reached = 1``.
    """
    tb = PairTB(dut)
    snaps = await run_bringup_full(tb)
    tb.log.info(f"  bringup complete: {snaps}")

    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    await tb.s_apb.write(APB_PTP_CTRL, PTP_CTRL_SLAVE_ENABLE)
    await tb.m_apb.write(APB_PTP_CTRL, PTP_CTRL_MASTER_GM_ENABLE)
    await ClockCycles(tb.dut.hclk, 100)

    # Stub the BD counter: force phc_nanoseconds to a fixed low value
    # well below the chosen target. The tb_top hard-codes 30'h0 at
    # the port; Force on the inner net overrides it.
    m_phc_ns = _ptp_handle(dut, "m").phc_nanoseconds
    INTERVAL_NS = 1000     # 1 µs target interval
    INITIAL_NS  = 500      # 500 ns — well below first target (500 + 1000 = 1500)

    m_phc_ns.value = Force(INITIAL_NS)
    await ClockCycles(tb.dut.hclk, 10)

    # Program the interval and arm with NO force_en.
    await tb.m_apb.write(APB_HW_SYNC_INTERVAL, INTERVAL_NS)
    seq_before = _seq_num(await tb.m_apb.read(APB_HW_SYNC_STATUS))
    tb.log.info(f"  programmed HW_SYNC_INTERVAL={INTERVAL_NS}, pre-arm seq={seq_before}")

    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_CTRL_ENABLE)
    await ClockCycles(tb.dut.hclk, 50)

    # Phase A — counter held at INITIAL_NS. phc_time_reached must NOT
    # assert; seq must NOT increment.
    held_phc_tr = 0
    for _ in range(200):
        await RisingEdge(dut.hclk)
        if _phc_time_reached(dut, "m") == 1:
            held_phc_tr += 1
    seq_held = _seq_num(await tb.m_apb.read(APB_HW_SYNC_STATUS))
    tb.log.info(
        f"  phase A (counter held @ {INITIAL_NS}): "
        f"phc_time_reached_high={held_phc_tr}/200 seq={seq_held}"
    )
    assert held_phc_tr == 0, (
        f"phc_time_reached asserted in phase A ({held_phc_tr}/200 cy) "
        f"despite forced phc_nanoseconds={INITIAL_NS} < target_ns_r="
        f"{INITIAL_NS + INTERVAL_NS}. The post-patch wire likely has "
        f"a stuck-high regression. See src/rtl/tidelink_ptp.sv:412."
    )
    assert seq_held == seq_before, (
        f"seq_num advanced in phase A ({seq_before} -> {seq_held}) "
        f"with phc_nanoseconds < target — natural cadence guard broken."
    )

    # Phase B — bump the counter past the target. The FSM must
    # advance ARMED->FIRE and increment seq.
    POST_NS = INITIAL_NS + INTERVAL_NS + 100   # 1600 — comfortably past
    m_phc_ns.value = Force(POST_NS)
    await ClockCycles(tb.dut.hclk, 100)

    seq_after = _seq_num(await tb.m_apb.read(APB_HW_SYNC_STATUS))
    tb.log.info(
        f"  phase B (counter bumped to {POST_NS}): "
        f"seq={seq_after} (delta={seq_after - seq_before})"
    )
    assert seq_after > seq_before, (
        f"seq_num did NOT advance ({seq_before} -> {seq_after}) "
        f"after forced phc_nanoseconds={POST_NS} crossed target_ns_r="
        f"{INITIAL_NS + INTERVAL_NS}. The natural cadence path is "
        f"broken; check the time-comparison logic at "
        f"src/rtl/tidelink_ptp.sv:412-415."
    )

    # Phase C — hold the counter past the target. Without force_en
    # and without target advancement, seq advances at most O(1) more
    # times (the FSM re-arms with a new target = POST_NS + INTERVAL
    # = 2600, which is still > the held value, so seq freezes again).
    seq_c0 = _seq_num(await tb.m_apb.read(APB_HW_SYNC_STATUS))
    await ClockCycles(tb.dut.hclk, 500)
    seq_c1 = _seq_num(await tb.m_apb.read(APB_HW_SYNC_STATUS))
    tb.log.info(
        f"  phase C (counter held @ {POST_NS} for 500 cy): "
        f"seq {seq_c0} -> {seq_c1} (delta={seq_c1 - seq_c0})"
    )
    assert (seq_c1 - seq_c0) <= 2, (
        f"seq_num kept advancing in phase C (delta={seq_c1 - seq_c0}) "
        f"with phc_nanoseconds held at {POST_NS} and no force_en. "
        f"This is the saturation regression — the patched RTL should "
        f"only saturate under force_en=1."
    )

    # Cleanup.
    m_phc_ns.value = Release()
    tb.log.info(
        "  POST-BD-FIX BEHAVIOUR VALIDATED — natural cadence honours "
        "counter, no saturation without force_en."
    )

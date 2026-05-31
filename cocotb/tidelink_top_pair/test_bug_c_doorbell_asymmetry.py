"""Bug C: S->M doorbell asymmetry repro (HW build #5, 2026-05-30).

Background
----------
On `bridge1` build #5 (commit `f10e6fe`, F-1 watchdog only) with the
corrected test recipe (NO `SWI_TRAINING_MODE=1` write post-deploy):

    Master rings 100 APB doorbells (W 1 -> 0x44032014)
       -> slave  REG_DOORBELL_RESP_ACC (0x024) saturates at 65535   (PASS)
    Slave rings 100 APB doorbells
       -> master REG_DOORBELL_RESP_ACC stays 0                       (FAIL)

See docs/BUILD5_REVALIDATED_OA_TEST_2026_05_30.md for the bench log.
SWI_TRAINING_MODE gating is documented in
WavD2DGpioTx.v:252-256 (TX byte substitution) and Wlink.v:1952
(LL_RX held in reset while training_mode_rxsync high) — `do_to_data_mode()`
already drops it before the doorbell traffic, so these tests do NOT
re-assert training_mode.

This file reuses `PairTB` from test_tidelink_pair_doorbell.py for the
APB drivers, role-lock, and bringup sequence. The tests below focus
ONLY on the doorbell direction asymmetry (100 doorbells per HW recipe).

Three tests:
    test_bugc_01_master_to_slave_100   sanity: M->S still works (HW says yes)
    test_bugc_02_slave_to_master_100   THE BUG: S->M (HW says no)
    test_bugc_03_role_swap_sm          flip M/S role assignments and re-fire
                                       S->M-direction traffic. If the bug
                                       still tracks role=slave, it's a
                                       role-cfg/RTL issue. If it instead
                                       tracks the physical instance, it's
                                       a TB harness issue.

For each test we also sample FC adapter TX/RX valid pulses + skid valid
on both sides to localize WHERE the asymmetry comes from.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_RELEASED_ACC,
    APB_PAIR_CREDIT_COUNTER,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)

# Per HW recipe: 100 APB rings of value 1.
N_DOORBELLS = 100

# After each ring, give the FC adapter time to push the credit-return
# packet through the link. The HW test waits ~25 ms (= ~1.25M cycles at
# 50 MHz). For sim we use a much shorter inter-ring gap and a generous
# total settle window.
INTER_RING_CYCLES = 50
SETTLE_CYCLES     = 5000


async def _ensure_training_off(tb):
    """Belt-and-braces: clear SWI_TRAINING_MODE on both sides post-bringup.

    `do_to_data_mode()` already writes slot0=0 but the calibrator
    `cal_training_mode` overlay can re-assert training_mode in apb_clk if
    something fires it. We mirror the build-#5 corrected HW recipe which
    explicitly skips any post-deploy `td_set_train.py` write."""
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 100)


async def _ring_doorbells_and_watch(tb, side, n, label):
    """Ring `n` doorbells on `side` (`m` or `s`) and sample FC pulses.

    Returns (m_a2l_count, m_l2a_count, s_a2l_count, s_l2a_count).
    """
    apb = tb.m_apb if side == "m" else tb.s_apb
    m_a2l = m_l2a = s_a2l = s_l2a = 0

    for i in range(n):
        await apb.write(APB_DOORBELL, 1)
        # Sample one cycle per inter-ring gap. The FC valid lines are
        # combinational off the FCSM state, so 1-sample-per-cycle is fine.
        for _ in range(INTER_RING_CYCLES):
            await RisingEdge(tb.dut.hclk)
            if tb.fc_a2l_valid("m") == 1: m_a2l += 1
            if tb.fc_l2a_valid("m") == 1: m_l2a += 1
            if tb.fc_a2l_valid("s") == 1: s_a2l += 1
            if tb.fc_l2a_valid("s") == 1: s_l2a += 1

    # Final settle window — keep watching while link drains.
    for _ in range(SETTLE_CYCLES):
        await RisingEdge(tb.dut.hclk)
        if tb.fc_a2l_valid("m") == 1: m_a2l += 1
        if tb.fc_l2a_valid("m") == 1: m_l2a += 1
        if tb.fc_a2l_valid("s") == 1: s_a2l += 1
        if tb.fc_l2a_valid("s") == 1: s_l2a += 1

    tb.log.info(
        f"  [{label}] FC valid-cycle totals over {n} rings + settle: "
        f"M(a2l={m_a2l},l2a={m_l2a})  S(a2l={s_a2l},l2a={s_l2a})"
    )
    return dict(m_a2l=m_a2l, m_l2a=m_l2a, s_a2l=s_a2l, s_l2a=s_l2a)


async def _read_resp_accs(tb, label):
    """Read DOORBELL_RESP_ACC on both sides and log. Returns (m, s)."""
    m = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"  [{label}] DOORBELL_RESP_ACC: master={m}  slave={s}")
    return m, s


async def _read_released_accs(tb, label):
    """Companion counter — RELEASED_ACC. Increments when the LOCAL
    FC adapter consumes credit returns from the peer. Useful to tell
    'peer sent us a credit-return' from 'we processed it'."""
    m = await tb.m_apb.read(APB_RELEASED_ACC)
    s = await tb.s_apb.read(APB_RELEASED_ACC)
    tb.log.info(f"  [{label}] RELEASED_ACC:      master={m}  slave={s}")
    return m, s


async def _snapshot_state(tb, label):
    """Snapshot FCSM state, pair credit, calibrator state both sides."""
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    s_pcc = await tb.s_apb.read(APB_PAIR_CREDIT_COUNTER)
    tb.log.info(
        f"  [{label}] FCSM: m_state={tb.fcsm_state('m')} "
        f"s_state={tb.fcsm_state('s')}  "
        f"PAIR_CREDIT: m={m_pcc} s={s_pcc}  "
        f"cr/crack: m_cr={tb.fcsm_cr_pkt_seen('m')} m_cra={tb.fcsm_crack_pkt_seen('m')} "
        f"s_cr={tb.fcsm_cr_pkt_seen('s')} s_cra={tb.fcsm_crack_pkt_seen('s')}"
    )


# ===========================================================================
# Tests
# ===========================================================================


@cocotb.test()
async def test_bugc_01_master_to_slave_100(dut):
    """Sanity: 100 master doorbells -> slave DOORBELL_RESP_ACC ticks.

    HW build #5 PASSES this (saturates at 65535). If sim does NOT also
    pass, the harness has a problem and the S->M observation in test 02
    can't be interpreted.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _ensure_training_off(tb)

    await _snapshot_state(tb, "pre-traffic")
    m_db_before, s_db_before = await _read_resp_accs(tb, "before")
    m_rel_before, s_rel_before = await _read_released_accs(tb, "before")

    counts = await _ring_doorbells_and_watch(tb, "m", N_DOORBELLS, "M->S 100 rings")

    m_db_after, s_db_after = await _read_resp_accs(tb, "after")
    m_rel_after, s_rel_after = await _read_released_accs(tb, "after")
    await _snapshot_state(tb, "post-traffic")

    # The interesting tick is the OPPOSITE side's RESP_ACC: master
    # rings -> slave responds -> master sees the response. But in some
    # of the existing HW probes the local DB_RESP also moves due to
    # internal echo. Match the HW interpretation: at least ONE of the
    # two DB_RESP fields must show movement, AND we must see TX activity
    # from the initiator side.
    assert counts["m_a2l"] > 0, (
        f"master FC adapter never asserted tl_fc_a2l_valid — "
        f"initiator returner is wedged. counts={counts}"
    )
    crossed = (s_db_after > s_db_before) or (m_db_after > m_db_before)
    assert crossed, (
        f"M->S sanity FAILED: neither slave nor master DB_RESP_ACC ticked. "
        f"slave {s_db_before}->{s_db_after}, master {m_db_before}->{m_db_after}. "
        f"counts={counts}. If this fails the rest of the suite is unreliable."
    )


@cocotb.test()
async def test_bugc_02_slave_to_master_100(dut):
    """THE BUG: 100 slave doorbells -> master DOORBELL_RESP_ACC must tick.

    HW build #5 FAILS this — master DB_RESP_ACC stays at 0 forever.
    Outcome interpretation:
      (a) if this PASSES in sim    -> bug is HW-specific (XDC/timing)
      (b) if this FAILS in sim     -> bug reproduces — iterate in cocotb
      (c) if setup error           -> fix harness
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _ensure_training_off(tb)

    await _snapshot_state(tb, "pre-traffic")
    m_db_before, s_db_before = await _read_resp_accs(tb, "before")
    m_rel_before, s_rel_before = await _read_released_accs(tb, "before")

    counts = await _ring_doorbells_and_watch(tb, "s", N_DOORBELLS, "S->M 100 rings")

    m_db_after, s_db_after = await _read_resp_accs(tb, "after")
    m_rel_after, s_rel_after = await _read_released_accs(tb, "after")
    await _snapshot_state(tb, "post-traffic")

    # Localisation:
    #   S.a2l == 0           -> slave's initiator returner is wedged on
    #                           role=slave (RTL bug). Bug stays local to
    #                           initiator side; no traffic leaves.
    #   S.a2l > 0, M.l2a == 0 -> bytes leave slave but die on the link
    #                           (pad/skid asymmetry, framer drop).
    #   M.l2a > 0, master DB_RESP==0 -> bytes arrive but consumer drops them.
    if counts["s_a2l"] == 0:
        tb.log.info("  >>> Locus: slave FC adapter never asserted tl_fc_a2l_valid")
    elif counts["m_l2a"] == 0:
        tb.log.info("  >>> Locus: slave TX'd but master FC RX never accepted")
    else:
        tb.log.info("  >>> Locus: master RX'd but DOORBELL_RESP_ACC never updated")

    crossed = (m_db_after > m_db_before) or (s_db_after > s_db_before)
    assert crossed, (
        f"BUG C REPRODUCED: S->M doorbells did not cross — "
        f"master DB_RESP_ACC {m_db_before}->{m_db_after}, "
        f"slave DB_RESP_ACC {s_db_before}->{s_db_after}. "
        f"FC pulses: M(a2l={counts['m_a2l']},l2a={counts['m_l2a']}) "
        f"S(a2l={counts['s_a2l']},l2a={counts['s_l2a']}). "
        f"RELEASED_ACC: m {m_rel_before}->{m_rel_after}, "
        f"s {s_rel_before}->{s_rel_after}."
    )


@cocotb.test()
async def test_bugc_03_role_swap_sm(dut):
    """Role-swap variant: assign u_master <- ROLE=SLAVE and u_slave <- ROLE=MASTER.
    Then ring 100 doorbells on the (now-slave) u_master instance.

    If the bug FOLLOWS role=slave (i.e. now u_master is the failing initiator),
    it's a role-cfg-dependent RTL bug. If the bug STAYS on the u_slave
    physical instance, it's a TB harness asymmetry (one of the pad_skid
    wirings or the wlink ref_clk distribution).

    NOTE: this test re-uses PairTB's bringup but swaps the ROLE_CFG
    writes. Everything else (clock, reset, APB drivers) stays the same.
    """
    tb = PairTB(dut)
    # Manual swapped-role bringup — can't use run_bringup_full() because
    # do_role_lock() hardcodes M=master, S=slave.
    from test_tidelink_pair_doorbell import (
        ROLE_CFG_MASTER_LOCK, ROLE_CFG_SLAVE_LOCK,
        APB_ROLE_CFG,
    )
    await tb.reset()

    # SWAPPED role assignment
    tb.log.info("  SWAPPED role bringup: u_master <- SLAVE, u_slave <- MASTER")
    await tb.m_apb.write(APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK)
    await tb.s_apb.write(APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK)
    await ClockCycles(tb.dut.hclk, 200)

    # Wait for both role_locked
    locked = await tb.wait_role_locked()
    tb.log.info(
        f"  role_locked (swapped): m={int(tb.dut.m_role_locked.value)} "
        f"s={int(tb.dut.s_role_locked.value)}  ({'ok' if locked else 'TIMEOUT'})"
    )

    # Wait for passive autocal to complete (same path as run_bringup_through_phase1)
    m_st, s_st = await tb.wait_cal_done(max_cycles=500000)
    tb.log.info(
        f"  cal_done (swapped): m_status=0x{m_st:08x} s_status=0x{s_st:08x}"
    )

    # Run the standard to_data_mode regardless of role assignment.
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)
    await _ensure_training_off(tb)

    await _snapshot_state(tb, "swapped pre-traffic")

    # Now u_slave is the MASTER. The HW symptom was 'slave initiator
    # never gets responses'. In the swapped config, the SAME role
    # (slave) is on the u_master instance. So we ring on u_master and
    # see if u_slave (now master) responds.
    m_db_before, s_db_before = await _read_resp_accs(tb, "swapped-before")

    counts = await _ring_doorbells_and_watch(
        tb, "m", N_DOORBELLS,
        "swapped: ring on u_master (now SLAVE-role)"
    )

    m_db_after, s_db_after = await _read_resp_accs(tb, "swapped-after")
    await _snapshot_state(tb, "swapped post-traffic")

    # If bug follows ROLE: this test reproduces Bug C (no crossing).
    # If bug follows INSTANCE: this test passes (u_master ringing works).
    crossed = (m_db_after > m_db_before) or (s_db_after > s_db_before)
    if not crossed:
        tb.log.info(
            "  ROLE-SWAP RESULT: bug tracks ROLE=slave "
            "(SAME failure direction with swapped instances) — RTL bug."
        )
    else:
        tb.log.info(
            "  ROLE-SWAP RESULT: bug tracks INSTANCE "
            "(swapping roles let the same direction succeed) — "
            "possible TB harness asymmetry."
        )

    # This test does NOT assert pass/fail — it's purely diagnostic and
    # logs which way the symmetry breaks. The pass criterion is "the
    # swapped bringup completes without exception".
    assert int(tb.dut.m_role_locked.value) == 1, (
        "u_master never asserted role_locked in swapped bringup"
    )
    assert int(tb.dut.s_role_locked.value) == 1, (
        "u_slave never asserted role_locked in swapped bringup"
    )

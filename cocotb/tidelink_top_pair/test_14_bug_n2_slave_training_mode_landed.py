"""Bug N2 regression — proves the slave's SWI_TRAINING_MODE register
accepts master's I²C-write during ST_TRAIN_ENTER.

Background
----------
Bug N2 (diagnosed 2026-05-29, see test_15 probe + BUG_N2_DIAGNOSIS.md):

  Once Bug N1 is fixed (mask-handshake completes), the master autoneg
  FSM advances to ST_TRAIN_ENTER (state 12) and performs a 6-byte I²C
  write of `swi_training_mode_r = 1` to the peer's chiplet-controller
  via the peer's I²C-slave interface.

  Test_10 trace (HEAD 5a87158, /tmp/td_autonomy_test10_postfix_224926.log):

      t≈ 1665 µs: master enters ST_TRAIN_ENTER (state 12)
      master gets peer-ACK → local_train_set_pulse_r fires →
      master's OWN swi_training_mode_r=1, FSM advances to ST_TRAIN_RUN
      (state 13).
      t≈14461 µs: master at ST_TRAIN_FAIL (state 17).
      Slave still at ST_NEGO_DONE (state 5) with
      swi_training_mode_r=0 throughout.

  The I²C write reached the I²C-slave layer (master got ACK and
  progressed past the write), but the slave's APB never wrote
  `swi_training_mode_r`. The bridge from the I²C-slave back-channel
  into the slave's chiplet-controller APB has a gap.

  Consequence: slave's lane_checker never sees `training_mode=1`, so
  `lane_locked` stays 0, so master's POLL_PEER eventually times out
  → ST_TRAIN_FAIL.

Test contract
-------------
Under `BYPASS_AUTONEG=0` (autoneg + train engaged, no APB stimulus):

  1. Reset both dies.
  2. Wait for the master autoneg FSM to first enter ST_TRAIN_ENTER
     (state 12). Bounded by ~5 ms sim time (test_10 sees entry at
     ~1.7 ms).
  3. Once state 12 is entered, record sim time T0.
  4. Poll the slave's `swi_training_mode_r` for up to BUDGET_MS = 2.0
     sim ms.
  5. PASS if the slave's `swi_training_mode_r` flips to 1 within
     budget.
  6. FAIL with a clear Bug N2 message if the budget elapses with the
     slave's register still 0.

Time budget rationale
---------------------
Master's ST_TRAIN_ENTER does a 6-byte I²C write at 100 kHz (after the
prescale fix):
    one byte = 9 SCL cycles + START/STOP framing ≈ 100 µs
    6 bytes  ≈ 600 µs
2 ms gives ~3× margin — fail-fast, but ample over the natural
completion time.

Failure mode
------------
On current RTL (Bug N2 present) the slave's `swi_training_mode_r`
stays 0 for the full BUDGET_MS window → AssertionError raised with
master/slave state, slave register value, slave debug-unlock pin,
and I²C bus snapshot. On fixed RTL the register flips to 1 within
~600 µs of T0 and the test PASSes.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_14_bug_n2_slave_training_mode_landed \
        make MODULE=test_14_bug_n2_slave_training_mode_landed
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0       # 50 MHz hclk / apb_clk
REF_CLK_PERIOD_NS = 8.0

# State decoder — matches tidelink_autoneg.sv state_r encoding.
ST_NAMES = {
    0:  "ST_IDLE",
    1:  "ST_NEGO_INIT",
    2:  "ST_NEGO_WAIT",
    3:  "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL",
    5:  "ST_NEGO_DONE",
    6:  "ST_BYPASS",
    7:  "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX",
    9:  "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA",
    11: "ST_NEGO_DONE_PRE",
    12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN",
    14: "ST_TRAIN_POLL_PEER",
    15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE",
    17: "ST_TRAIN_FAIL",
}

ST_TRAIN_ENTER = 12

# How long, in sim time, are we willing to wait for the master to
# first enter ST_TRAIN_ENTER after POR? test_10 sees entry at
# ~1.7 ms. 5 ms is a 3× margin and fails fast if the upstream
# NEGO path itself has regressed (Bug N1 etc.).
TRAIN_ENTER_BUDGET_MS = 5.0

# Once master is in ST_TRAIN_ENTER, how long do we allow the slave's
# swi_training_mode_r to stay 0 before declaring Bug N2? See module
# docstring for the 600 µs natural completion + 3× margin rationale.
BUDGET_MS = 2.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _state_name(st):
    return ST_NAMES.get(st, f"UNKNOWN({st})")


@cocotb.test()
async def test_14_bug_n2_slave_training_mode_landed(dut):
    """Regression: slave SWI_TRAINING_MODE must be written by master's
    ST_TRAIN_ENTER I²C burst.

    See module docstring for full Bug N2 background. This test FAILs on
    pre-fix RTL (slave's swi_training_mode_r never set by master's
    I²C-write) and PASSes once the I²C-slave → chiplet-controller APB
    bridge correctly lands the write.
    """
    log = dut._log
    log.info("Bug N2 regression — test_14_bug_n2_slave_training_mode_landed")

    # Start clocks.
    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all bus stimulus — the FSM is engaged purely by the tb_top
    # BYPASS_AUTONEG=0 force block, no SW writes are performed by this
    # test.
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    # Reset.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Hierarchy handles.
    m_an  = dut.u_master.u_chiplet_controller.u_autoneg
    s_an  = dut.u_slave.u_chiplet_controller.u_autoneg
    s_ctl = dut.u_slave.u_chiplet_controller

    # ─── Phase A: wait for master to first enter ST_TRAIN_ENTER ────────
    entry_budget_cycles = int(TRAIN_ENTER_BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    poll = 200  # 4 µs per poll @ 50 MHz hclk
    waited = 0
    entered = False
    while waited < entry_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == ST_TRAIN_ENTER:
            entered = True
            break
    t_entry_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"Phase A: master ST_TRAIN_ENTER entry seen={entered} after "
        f"{waited} cycles ({waited * CLK_PERIOD_NS / 1000:.1f} µs), "
        f"sim time {t_entry_ns:.0f} ns"
    )
    assert entered, (
        f"Test prerequisite failed: master FSM never reached "
        f"ST_TRAIN_ENTER (state 12) within {TRAIN_ENTER_BUDGET_MS} ms. "
        f"Current master state = {_safe_int(m_an.state_r)} "
        f"({_state_name(_safe_int(m_an.state_r))}). "
        f"This likely indicates a regression in the upstream NEGO "
        f"path (Bug N1 etc.), not Bug N2."
    )

    # ─── Phase B: dwell budget — assert slave swi_training_mode_r=1 ────
    dwell_budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    dwelled = 0
    landed = False
    while dwelled < dwell_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        dwelled += poll
        if _safe_int(s_ctl.swi_training_mode_r) == 1:
            landed = True
            break

    dwell_ms = dwelled * CLK_PERIOD_NS / 1_000_000
    t_now_ns = cocotb.utils.get_sim_time(unit="ns")

    # Probes for the failure message (so a future maintainer can see
    # at-a-glance whether the symptom matches Bug N2's signature).
    m_state       = _safe_int(m_an.state_r)
    s_state       = _safe_int(s_an.state_r)
    s_train_mode  = _safe_int(s_ctl.swi_training_mode_r)
    s_dbg_unlock  = _safe_int(dut.s_apb_debug_unlock)
    i2c_scl       = _safe_int(dut.i2c_scl)
    i2c_sda       = _safe_int(dut.i2c_sda)
    m_scl_o       = _safe_int(dut.m_i2c_scl_o)
    m_sda_o       = _safe_int(dut.m_i2c_sda_o)

    if not landed:
        # Bug N2 fingerprint: slave swi_training_mode_r still 0 well
        # past the natural 6-byte I²C burst time.
        raise AssertionError(
            f"Bug N2: slave swi_training_mode_r stuck at 0 for "
            f"{dwell_ms:.3f} ms after master entered ST_TRAIN_ENTER "
            f"(sim t={t_now_ns:.0f} ns).\n"
            f"  master state = {m_state} ({_state_name(m_state)})\n"
            f"  slave  state = {s_state} ({_state_name(s_state)})\n"
            f"  slave swi_training_mode_r = {s_train_mode} (expected 1)\n"
            f"  slave apb_debug_unlock_i  = {s_dbg_unlock}\n"
            f"  i2c bus: scl={i2c_scl} sda={i2c_sda} "
            f"(m_scl_o={m_scl_o} m_sda_o={m_sda_o})\n"
            f"Expected: slave swi_training_mode_r=1 within "
            f"{BUDGET_MS} ms (6-byte I²C burst ≈ 600 µs at 100 kHz). "
            f"This is the master-I²C-write → slave-APB drop "
            f"diagnosed by test_15 probe + BUG_N2_DIAGNOSIS.md."
        )

    log.info(
        f"PASS: slave swi_training_mode_r=1 landed after {dwell_ms*1000:.1f} µs "
        f"dwell (sim t={t_now_ns:.0f} ns); "
        f"master state={m_state} ({_state_name(m_state)}) "
        f"slave state={s_state} ({_state_name(s_state)}) "
        f"slave dbg_unlock={s_dbg_unlock} "
        f"i2c scl={i2c_scl} sda={i2c_sda}"
    )

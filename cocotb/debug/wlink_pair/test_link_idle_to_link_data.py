"""LINK_IDLE -> LINK_DATA gating test under training_mode pulse + drop.

HW status (2026-05-25, tdif-03 deploy, see docs/TIDELINK_HANDOFF_2026_05_25.md):
After the per-lane WavD2DGpioTx fix lands, the bidirectional CR/CRACK
handshake completes (cr_seen=1, ck_seen=1 on BOTH sides; rx_data_valid=1
on both LinkStatus regs). But FCSM is stuck:
  - master @ LINK_IDLE  (state 4)
  - slave  @ SEND_NACK  (state 7)
PAIR_CREDIT_COUNTER stays at 0. Doorbells/AHB SUB/PHC do not cross.

The passing test_assert_bringup.py tests (test_07/08/09) show FCSM
reaching LINK_DATA (state>=5) in sim BUT they don't pulse training_mode.
On HW the bringup script asserts swi_training_mode=1, lets the calibrator
lock, then drops it, then cycles LL swreset (0x208: 0x27f08 -> 0x27f00 ->
0x27f07).

This file extends the passing wlink_pair scenario by pulsing training_mode
the same way, then asks: does FCSM still reach LINK_DATA in sim?
  - If sim NOW fails the same way HW does -> tight sim repro of the
    LINK_IDLE blocker (drives the tdif-04 RTL fix design).
  - If sim still passes -> sim/HW gap; need silicon ILA (Track C).

Tests:
  test_01_baseline_no_training_pulse_reaches_link_data    (matches test_07)
  test_02_training_pulse_then_drop_still_reaches_link_data
  test_03_training_pulse_long_observation
  test_04_probe_internal_signals_under_stuck_state
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write, ctrl_read,
    apb_read, apb_write,
)

# -----------------------------------------------------------------------
# Constants — match HW bringup script
# -----------------------------------------------------------------------
# Region 8 ctrl_reg_addr: bit[3]=1 selects Region 8, bits[2:0]=slot.
R8_SLOT0_TRAIN_RECAL = 0b1000   # slot 0 — SWI_TRAINING_MODE + SWI_RECAL

# LL_CTRL (0x208) values the HW bringup script writes during the swreset cycle.
# See deploy_pair scripts + handoff doc Step 3:
#   0x27f08 -> swreset asserted (bit[3]=1)
#   0x27f00 -> swreset deasserted but link_disable (bit[0..2]=000)
#   0x27f07 -> link enabled, normal (bit[0..2]=111)
WL_LINK_ENABLE_RESET = 0x0208
LL_CTRL_SWRESET_ON   = 0x27f08
LL_CTRL_SWRESET_OFF  = 0x27f00
LL_CTRL_ENABLED      = 0x27f07


# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------
def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


async def _set_training_both(dut, on):
    """Write Region 8 slot 0 on both sides: bit[0]=swi_training_mode."""
    val = 0x1 if on else 0x0
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, val)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, val)


async def _ll_swreset_cycle(dut):
    """Replay the HW bringup LL swreset cycle on both sides.
    Mirrors `bringup_pair_converge.sh` step writing 0x208 with three
    successive values, with a short settle between each."""
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)


async def _wait_for_fcsm(dut, cycles):
    """Run for `cycles` master_clks and return (max_m, max_s, final_m, final_s)."""
    m = _fcsm(dut, "m").state
    s = _fcsm(dut, "s").state
    max_m = 0; max_s = 0
    for _ in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.value); ss = int(s.value)
        if ms > max_m: max_m = ms
        if ss > max_s: max_s = ss
    return max_m, max_s, int(m.value), int(s.value)


def _try_signal(handle, names):
    """Return (name, int_value) of the first attribute that resolves and reads."""
    for n in names:
        if hasattr(handle, n):
            try:
                return n, int(getattr(handle, n).value)
            except (ValueError, Exception):
                continue
    return None, None


# -----------------------------------------------------------------------
# TEST 1 — baseline: no training pulse, FCSM should reach LINK_DATA.
# This MATCHES test_07_assert_all_fc_channels_bringup and is the proven
# passing scenario. Restated here so the file is self-contained.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_baseline_no_training_pulse_reaches_link_data(dut):
    """Baseline: same protocol as test_07 — POR, lock both roles, wait
    5000 cycles, assert FCSM on both sides reaches LINK_DATA (state>=5)
    (or at least LINK_EN_WAIT / LINK_IDLE, state>=4).

    This is the FCSM-can-reach-LINK_DATA control case. If this fails,
    something other than the training pulse is broken."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    max_m, max_s, fin_m, fin_s = await _wait_for_fcsm(dut, 5000)
    dut._log.info(
        f"  [baseline] max_state m={max_m} s={max_s}  "
        f"final m={fin_m} s={fin_s}")

    assert max_m >= 4, f"baseline master FCSM stuck at max={max_m} (expected >=4)"
    assert max_s >= 4, f"baseline slave  FCSM stuck at max={max_s} (expected >=4)"
    # Strong form: did EITHER side reach LINK_DATA (state 5)?
    if max_m >= 5 or max_s >= 5:
        dut._log.info("  baseline reached LINK_DATA on at least one side — OK")
    else:
        dut._log.warning(
            "  baseline only reached state 4 (LINK_IDLE) — "
            "this matches HW symptom even without a training pulse, "
            "meaning the bug may not need the training pulse")


# -----------------------------------------------------------------------
# TEST 2 — KEY TEST: with training pulse + drop + LL swreset cycle,
# does FCSM still reach LINK_DATA? Matches HW bringup sequence.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_training_pulse_then_drop_still_reaches_link_data(dut):
    """1. Lock master + slave.
    2. Pulse swi_training_mode HIGH on both sides (R8 slot0 = 1).
    3. Wait for calibrator-equivalent settle (500 cycles).
    4. Drop swi_training_mode (R8 slot0 = 0).
    5. Cycle LL swreset: 0x208 = 0x27f08 -> 0x27f00 -> 0x27f07.
    6. Wait 5000 cycles.
    7. Assert FCSM on both sides reaches state>=5 (LINK_DATA).

    HW: this entire sequence is what `bringup_pair_converge.sh` does, then
    the FCSM gets stuck at master=4 (LINK_IDLE) / slave=7 (SEND_NACK).
    If sim reproduces that pattern, we have a TIGHT sim repro."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Pulse training_mode HIGH
    await _set_training_both(dut, on=True)
    await ClockCycles(dut.master_clk, 500)

    # Sample state under training (diagnostic)
    m_during = int(_fcsm(dut, "m").state.value)
    s_during = int(_fcsm(dut, "s").state.value)
    dut._log.info(f"  during training: m.state={m_during} s.state={s_during}")

    # Drop training_mode
    await _set_training_both(dut, on=False)
    await ClockCycles(dut.master_clk, 50)

    # LL swreset cycle on both sides
    await _ll_swreset_cycle(dut)

    # Long observation for FCSM convergence
    max_m, max_s, fin_m, fin_s = await _wait_for_fcsm(dut, 5000)
    dut._log.info(
        f"  [post-train+swreset] max_state m={max_m} s={max_s}  "
        f"final m={fin_m} s={fin_s}")

    if max_m >= 5 and max_s >= 5:
        dut._log.info(
            "  SIM PASSES under training pulse — sim/HW divergence "
            "(HW stuck at m=4, s=7). Need Track C ILA on silicon.")
    else:
        dut._log.warning(
            f"  SIM REPRO: FCSM did not reach LINK_DATA "
            f"(max m={max_m} s={max_s}, final m={fin_m} s={fin_s}). "
            "Compare to HW (m=4 LINK_IDLE, s=7 SEND_NACK).")

    # Assertive: both sides must reach LINK_DATA. If this assert fails
    # we have a sim repro that drives tdif-04.
    assert max_m >= 5, (
        f"master FCSM did not reach LINK_DATA under training pulse: "
        f"max={max_m} final={fin_m} "
        f"(HW shows m=4 LINK_IDLE — if sim shows the same, we have a repro)")
    assert max_s >= 5, (
        f"slave  FCSM did not reach LINK_DATA under training pulse: "
        f"max={max_s} final={fin_s} "
        f"(HW shows s=7 SEND_NACK — if sim shows the same, we have a repro)")


# -----------------------------------------------------------------------
# TEST 3 — longer observation: does it EVENTUALLY advance? Snapshots
# state at several time points so we can see whether it oscillates,
# advances, or remains pinned.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_training_pulse_long_observation(dut):
    """Same setup as test_02 but observes for 10000 cycles. Snapshots
    state on both sides at t=1000, 2500, 5000, 7500, 10000 master clks
    after the LL swreset cycle. Pure diagnostic — logs only."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    await _set_training_both(dut, on=True)
    await ClockCycles(dut.master_clk, 500)
    await _set_training_both(dut, on=False)
    await ClockCycles(dut.master_clk, 50)
    await _ll_swreset_cycle(dut)

    m = _fcsm(dut, "m").state
    s = _fcsm(dut, "s").state

    snapshots = [1000, 2500, 5000, 7500, 10000]
    next_idx = 0
    last_m = -1; last_s = -1
    max_m = 0; max_s = 0
    transitions = []
    for cyc in range(10001):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.value); ss = int(s.value)
        if ms > max_m: max_m = ms
        if ss > max_s: max_s = ss
        if ms != last_m or ss != last_s:
            if len(transitions) < 40:
                transitions.append((cyc, ms, ss))
            last_m = ms; last_s = ss
        if next_idx < len(snapshots) and cyc == snapshots[next_idx]:
            dut._log.info(
                f"  t=+{cyc:5d}  m.state={ms}  s.state={ss}  "
                f"max(m,s)=({max_m},{max_s})")
            next_idx += 1

    dut._log.info(f"  TOTAL transitions observed: {len(transitions)} "
                  f"(first 40 logged below)")
    for cyc, ms, ss in transitions[:40]:
        dut._log.info(f"    [+{cyc:5d}] m={ms} s={ss}")
    dut._log.info(
        f"  FINAL: max m={max_m} s={max_s}  end m={int(m.value)} s={int(s.value)}")


# -----------------------------------------------------------------------
# TEST 4 — KEY TEST: probe internal FCSM signals while stuck. This
# guides the tdif-04 RTL fix by showing which gate is held.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_04_probe_internal_signals_under_stuck_state(dut):
    """Same setup as test_02. After 3000 cycles, hierarchically read:
      - state                    (FCSM state, expected LINK_DATA=5+ in sim)
      - fe_tx_credit_max         (credit window init — must be non-zero)
      - fe_rx_is_full            (receiver full — should be 0 to leave LINK_IDLE)
      - send_nack_req, send_ack_req
      - auto_tx_out_advance
      - cr_pkt_seen_rx, crack_pkt_seen_rx (handshake completion latches)
      - pkt_is_cr_pkt, pkt_is_crack_pkt
    Logs everything; asserts nothing (pure diagnostic)."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    await _set_training_both(dut, on=True)
    await ClockCycles(dut.master_clk, 500)
    await _set_training_both(dut, on=False)
    await ClockCycles(dut.master_clk, 50)
    await _ll_swreset_cycle(dut)
    await ClockCycles(dut.master_clk, 3000)

    probe_names = [
        "state",
        ("fe_tx_credit_max",
            ["fe_tx_credit_max", "fe_credit_max", "fe_tx_credit_max_loaded"]),
        ("fe_rx_credit_max",
            ["fe_rx_credit_max", "fe_credit_max_rx"]),
        ("fe_rx_is_full", ["fe_rx_is_full", "rx_is_full"]),
        ("send_nack_req", ["send_nack_req", "send_nack"]),
        ("send_ack_req",  ["send_ack_req",  "send_ack"]),
        ("auto_tx_out_advance", ["auto_tx_out_advance"]),
        ("cr_pkt_seen_rx", ["cr_pkt_seen_rx"]),
        ("crack_pkt_seen_rx", ["crack_pkt_seen_rx", "ck_pkt_seen_rx"]),
        ("pkt_is_cr_pkt", ["pkt_is_cr_pkt"]),
        ("pkt_is_crack_pkt", ["pkt_is_crack_pkt", "pkt_is_ck_pkt"]),
    ]

    for side in ("m", "s"):
        tl = _fcsm(dut, side)
        ms_state = int(tl.state.value)
        dut._log.info(f"  ---- side={side} stuck-state probe (FCSM state={ms_state}) ----")
        for entry in probe_names:
            if isinstance(entry, str):
                # 'state' alone
                if hasattr(tl, entry):
                    v = int(getattr(tl, entry).value)
                    dut._log.info(f"    {entry:25s} = {v}")
                continue
            label, candidates = entry
            found, val = _try_signal(tl, candidates)
            if found is None:
                dut._log.info(f"    {label:25s} = <not found> "
                              f"(tried {candidates})")
            else:
                dut._log.info(f"    {label:25s} = {val}  (via .{found})")

    # Summary line at the bottom of the log for ease of grep.
    m_state = int(_fcsm(dut, "m").state.value)
    s_state = int(_fcsm(dut, "s").state.value)
    dut._log.info(
        f"  SUMMARY: stuck-state final m.state={m_state} s.state={s_state} "
        f"(HW: m=4 LINK_IDLE, s=7 SEND_NACK)")

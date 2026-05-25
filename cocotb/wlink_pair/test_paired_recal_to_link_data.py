"""End-to-end paired-Wlink regression for the tdif-06 interface bug.

This file is a NEW regression suite intended to catch the 2026-05-24
TideLink interface FCSM bug — the asymmetric LL_RX byte-align loss
where:
  * master's LL sees slave's CR packet  (cr_pkt_seen_rx=1 sticky)
  * slave's  LL NEVER sees master's CR packet (cr_pkt_seen_rx=0 forever)
  * Both FCSMs stick in SEND_CREDITS1/2 (states 1/2), never reach
    LINK_DATA (state 5). Doorbells/credits don't cross either way.

The existing test_link_idle_to_link_data, test_credit_handshake_end_to_end
and test_assert_bringup tests do NOT exercise the actual HW bringup
sequence (`bringup_pair_converge.sh`):
  set_slot0 0x3   (training+recal hold, BOTH sides)
  wait RECAL_HOLD
  set_slot0 0x1   (training hold, recal falls -> calibrator S_ARM/S_SWEEP)
  wait SETTLE
  set_slot0 0x0   (training drops -> FC data handoff)
  cycle LL_CTRL swreset 0x208: 0x27f08 -> 0x27f00 -> 0x27f07

This file replays exactly that sequence and asserts a SYMMETRIC bringup:
both sides reach LINK_DATA (state 5), both cr_pkt_seen_rx latch, both
crack_pkt_seen_rx latch, and the LinkStatus rx_data_valid is set on
both sides. Any asymmetric failure is flagged loudly as the diagnostic
signature of the HW bug.

PASS criteria (all hard assertions):
  - Master and slave both reach FCSM state>=5 (LINK_DATA)
  - cr_pkt_seen_rx high on BOTH sides
  - crack_pkt_seen_rx high on BOTH sides
  - rx_data_valid bit of LinkStatus (0x234[4]) set on BOTH sides
  - No asymmetric (one-side-only) cr_pkt_seen failure

A separate test inspects the asymmetric signature explicitly: this is
the diagnostic test that flags WHICH side is broken.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write, ctrl_read,
    apb_read, apb_write,
)

# ---- HW bringup constants (mirrored from bringup_pair_converge.sh) ----
R8_SLOT0_TRAIN_RECAL = 0b1000   # Region 8 slot 0  (bit0 train, bit1 recal)
R8_SLOT2_LANE_STATUS = 0b1010   # Region 8 slot 2  (lane_locked + CREDIT_PATH_STATUS)

WL_LINK_ENABLE_RESET = 0x0208
WL_LINK_STATUS       = 0x0234
LL_CTRL_SWRESET_ON   = 0x27f08
LL_CTRL_SWRESET_OFF  = 0x27f00
LL_CTRL_ENABLED      = 0x27f07

# State enum from FC.scala
FCSM_IDLE          = 0
FCSM_SEND_CREDITS1 = 1
FCSM_SEND_CREDITS2 = 2
FCSM_LINK_EN_WAIT  = 3
FCSM_LINK_IDLE     = 4
FCSM_LINK_DATA     = 5
FCSM_SEND_NACK     = 7

STATE_NAME = {
    0: "IDLE", 1: "SEND_CREDITS1", 2: "SEND_CREDITS2", 3: "LINK_EN_WAIT",
    4: "LINK_IDLE", 5: "LINK_DATA", 6: "??", 7: "SEND_NACK",
}


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


async def set_slot0(dut, val):
    """Replay set_slot0 from bringup_pair_converge.sh on BOTH sides."""
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, val)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, val)


async def recal_cycle(dut, hold_cycles=200, settle_cycles=200):
    """Replay recal_cycle() from bringup_pair_converge.sh on both sides:
    slot0=0x3 (train+recal hold) -> wait -> slot0=0x1 (recal falls).
    """
    await set_slot0(dut, 0x3)
    await ClockCycles(dut.master_clk, hold_cycles)
    await set_slot0(dut, 0x1)
    await ClockCycles(dut.master_clk, settle_cycles)


async def drop_training_and_swreset_ll(dut):
    """After recal_cycle, drop training (slot0=0x0) then cycle the LL
    swreset gate on both sides (0x208: 0x27f08 -> 0x27f00 -> 0x27f07)."""
    await set_slot0(dut, 0x0)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)


async def _observe_state_window(dut, cycles, label=""):
    """Walk `cycles` master_clks, recording per-side max_state and
    cr/crack latches. Returns dict suitable for the assert block."""
    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    obs = dict(
        max_m=0, max_s=0,
        cr_m=False, cr_s=False,
        crack_m=False, crack_s=False,
        nack_m=False, nack_s=False,
    )
    for _ in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        if ms > obs["max_m"]: obs["max_m"] = ms
        if ss > obs["max_s"]: obs["max_s"] = ss
        if int(m.cr_pkt_seen_rx.value):    obs["cr_m"]    = True
        if int(s.cr_pkt_seen_rx.value):    obs["cr_s"]    = True
        if int(m.crack_pkt_seen_rx.value): obs["crack_m"] = True
        if int(s.crack_pkt_seen_rx.value): obs["crack_s"] = True
        if ms == FCSM_SEND_NACK: obs["nack_m"] = True
        if ss == FCSM_SEND_NACK: obs["nack_s"] = True
    obs["final_m"] = int(m.state.value)
    obs["final_s"] = int(s.state.value)
    return obs


def _log_obs(dut, obs, label):
    dut._log.info(
        f"  [{label}]  m: max={obs['max_m']} ({STATE_NAME.get(obs['max_m'],'?')})  "
        f"final={obs['final_m']} ({STATE_NAME.get(obs['final_m'],'?')})  "
        f"cr={int(obs['cr_m'])} crack={int(obs['crack_m'])} nack={int(obs['nack_m'])}")
    dut._log.info(
        f"  [{label}]  s: max={obs['max_s']} ({STATE_NAME.get(obs['max_s'],'?')})  "
        f"final={obs['final_s']} ({STATE_NAME.get(obs['final_s'],'?')})  "
        f"cr={int(obs['cr_s'])} crack={int(obs['crack_s'])} nack={int(obs['nack_s'])}")


# -----------------------------------------------------------------------
# TEST 1 — KEY TEST. Replay the full HW bringup sequence:
#   role-lock -> recal_cycle -> drop training -> LL swreset cycle ->
#   observe FCSM/cr/crack latches on BOTH sides.
# Asserts SYMMETRIC bring-up. If only one side latches cr_pkt_seen_rx the
# test PRINTS the asymmetric signature loudly THEN FAILS.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_paired_recal_to_link_data_symmetric(dut):
    """Full HW bringup-sequence replay. PASS == both sides reach LINK_DATA,
    cr_pkt_seen_rx and crack_pkt_seen_rx latched on BOTH sides, and link
    status rx_data_valid is set on BOTH sides. FAIL == asymmetric flag."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Stage 1: recal_cycle (the HW pair-bringup heartbeat).
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    obs_post_recal = await _observe_state_window(dut, 200, "after recal_cycle")
    _log_obs(dut, obs_post_recal, "after recal_cycle")

    # Stage 2: drop training + LL swreset cycle (the HW handoff to FC data).
    await drop_training_and_swreset_ll(dut)

    # Stage 3: long observation for FCSM convergence (~5000 cycles is plenty).
    obs = await _observe_state_window(dut, 5000, "post-swreset")
    _log_obs(dut, obs, "post-swreset")

    # Read final LinkStatus on both sides.
    m_ls = await apb_read(dut, "m", WL_LINK_STATUS)
    s_ls = await apb_read(dut, "s", WL_LINK_STATUS)
    m_rxv = (m_ls >> 4) & 1
    s_rxv = (s_ls >> 4) & 1
    dut._log.info(f"  LinkStatus m=0x{m_ls:08x} rx_data_valid={m_rxv}")
    dut._log.info(f"  LinkStatus s=0x{s_ls:08x} rx_data_valid={s_rxv}")

    # -- ASYMMETRIC FAILURE DETECTOR ----------------------------------------
    # If cr_pkt_seen_rx latched on one side but NOT the other, we have
    # reproduced the HW bug in sim. Print the signature loudly THEN fail.
    if obs["cr_m"] != obs["cr_s"]:
        bad = "slave" if not obs["cr_s"] else "master"
        good = "master" if not obs["cr_s"] else "slave"
        dut._log.error("*" * 70)
        dut._log.error(
            f"  ASYMMETRIC cr_pkt_seen_rx FAILURE — {good} latched, {bad} DID NOT")
        dut._log.error(
            "  This is the HW signature (tdif-06 bug). The fix L1/L2/L3 "
            "stack should hold cr_pkt_seen symmetric.")
        dut._log.error("*" * 70)
        assert False, (
            f"asymmetric cr_pkt_seen_rx: m={obs['cr_m']} s={obs['cr_s']} "
            f"-> {bad}'s LL_RX byte-alignment broken. HW bug repro in sim.")

    # -- Strict per-side bringup asserts -------------------------------------
    assert obs["cr_m"],  "master cr_pkt_seen_rx never latched (master LL_RX broken)"
    assert obs["cr_s"],  "slave  cr_pkt_seen_rx never latched (slave  LL_RX broken)"
    assert obs["crack_m"], "master crack_pkt_seen_rx never latched"
    assert obs["crack_s"], "slave  crack_pkt_seen_rx never latched"
    assert obs["max_m"] >= FCSM_LINK_DATA, (
        f"master FCSM never reached LINK_DATA: max={obs['max_m']} "
        f"({STATE_NAME.get(obs['max_m'],'?')})")
    assert obs["max_s"] >= FCSM_LINK_DATA, (
        f"slave  FCSM never reached LINK_DATA: max={obs['max_s']} "
        f"({STATE_NAME.get(obs['max_s'],'?')})")
    assert m_rxv == 1, f"master rx_data_valid not set (LinkStatus=0x{m_ls:08x})"
    assert s_rxv == 1, f"slave  rx_data_valid not set (LinkStatus=0x{s_ls:08x})"

    dut._log.info(
        "  PASS: symmetric bring-up — both sides at LINK_DATA, both cr+crack "
        "latched, both rx_data_valid. Tdif-06 fix-stack holds the link.")


# -----------------------------------------------------------------------
# TEST 2 — diagnostic-quality asymmetry flag. Replays test_01 once and
# reports which side fails first (if any). NEVER fails — purely
# diagnostic complement to test_01 for triage logs.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_paired_recal_to_link_data_diagnostic(dut):
    """Diagnostic. Replays the same bringup sequence but ONLY logs the
    asymmetric signature (one cr_pkt_seen latched, the other not).
    Pairs with test_01 for the failure mode summary."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    obs = await _observe_state_window(dut, 5000, "diagnostic")
    _log_obs(dut, obs, "diagnostic")
    asym = obs["cr_m"] ^ obs["cr_s"]
    fcsm_asym = obs["max_m"] != obs["max_s"]
    dut._log.info(
        f"  diagnostic flags: cr_asym={asym} fcsm_asym={fcsm_asym}  "
        f"(asym=True means HW signature reproduced in sim)")

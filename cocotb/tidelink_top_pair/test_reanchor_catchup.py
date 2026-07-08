"""FIX-1 fail-first — REANCHOR-WITHOUT-WINSCAN CATCH-UP (the iter-1 NODONE).

Silicon failure class (iter-1, build 564ddde — root-caused, evidence-backed)
----------------------------------------------------------------------------
The SECOND-armed die (the slave) is left with a COMMITTED + VERIFIED deskew
anchor but winscan_done NEVER asserts -> the fch handoff deadlocks (NODONE).

Root cause: the slave's I2C ACK from POR lands BEFORE autonomy_armed=1, so the
training FALL that would kick its winscan is DROPPED by the LOOP-9 armed-only
gate on ws_kick_evt (ws_kick_evt requires autonomy_armed AT the fall).
autonomy_armed then rises with NO fresh training fall, so the winscan stays
parked in WS_IDLE and winscan_done stays 0 forever. BUT the die DID re-anchor
passively (the peer's beacons drove reanchored=1 => ws_anchor_q=1) AND that
anchor is ZERO-TOLERANCE VERIFIED (ws_verify_q=1, verify_stuck=0 — the EXACT
WS_FINALIZE release-gate criterion). It is a fully-committed, verified anchor
missing ONLY winscan_done + fch_pending_r.

FIX-1 (ws_reanchor_catchup, axi_chiplet_controller.sv) detects exactly that
state — armed, WS_IDLE, never kicked, ws_anchor_q & ws_verify_q, training low —
and completes the handoff arc WITHOUT running a scan: it raises winscan_done in
place (STAYS in WS_IDLE so winscan_owns_taps stays 0 = host/APB anchor taps
untouched, no sweep) and queues fch_pending_r so the FC bootstrap runs.

How this test models it deterministically
-----------------------------------------
This is a FOCUSED mechanism test: it drives the die directly into the exact
committed+verified-but-unkicked precondition (the direct-force path the FIX-1
task sanctions), with the autoneg left dormant (ST_BYPASS, training LOW) so no
armed kick ever fires — precisely the dropped-fall end state:

  * autonomy_armed forced 1   (arming completed AFTER the fall — the skew)
  * ws_anchor_q     forced 1  (reanchored passively from the peer's beacons)
  * ws_verify_q     forced 1  (the anchor exact-verifies; verify_stuck=0)
  * ws_state_r == WS_IDLE, ws_kicked_q == 0, swi_training_mode_r == 0 (natural
    post-reset state — the winscan was never kicked)

ASSERT: winscan_done asserts AND the fch bootstrap runs (fch_pending_r latches,
fch_active_r drives the proven FCH_LL_SWRESET_ON=0x27f09 first write) — the
handoff that was deadlocked now proceeds. The winscan must STAY in WS_IDLE (no
stale-tap sweep). On ca19da3 (pre-FIX-1) winscan_done NEVER rises and the fch
never arms — the NODONE — so the assertions FAIL (fail-first).

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_reanchor_catchup
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from test_31_autonomous_training_exit import (
    _ctrl, _fcsm, _si, _idle_stimulus, _reset,
)

CLK_PERIOD_NS = 20.0

WS_IDLE = 0                       # winscan FSM idle (axi_chiplet_controller.sv)
FCH_SWRESET_ON = 0x0002_7F09      # FCH_LL_SWRESET_ON — first bootstrap write

# Model the SECOND-armed die (the slave) — the one whose armed training fall is
# dropped by the LOOP-9 gate. (The mechanism is symmetric; "s" is the observed
# silicon polarity.)
SIDE = "s"


@cocotb.test()
async def test_reanchor_catchup(dut):
    """A die that is autonomy_armed with a committed + VERIFIED anchor but whose
    winscan is still parked in WS_IDLE (its armed kick was dropped) must complete
    the FC handoff: winscan_done asserts + the fch bootstrap runs. On ca19da3 it
    HANGS (NODONE) — winscan_done never rises and the fch never arms."""
    log = dut._log
    log.info("FIX-1 catch-up repro — armed + reanchored + verified, WS_IDLE, "
             "never kicked (the iter-1 NODONE)")
    tb = PairTB(dut)                 # starts the clocks + idles the buses
    await _idle_stimulus(dut)
    await _reset(dut)
    await ClockCycles(dut.hclk, 200)

    c = _ctrl(dut, SIDE)

    # ---- Precondition: dormant winscan, never kicked, training LOW ------------
    assert _si(c.ws_state_r) == WS_IDLE, (
        f"[{SIDE}] winscan not in WS_IDLE pre-force (ws_state="
        f"{_si(c.ws_state_r)}) — the autoneg ran a scan (unexpected in the "
        f"dormant model)")
    assert _si(c.ws_kicked_q) == 0, f"[{SIDE}] ws_kicked_q set pre-force"
    assert _si(c.swi_training_mode_r) == 0, (
        f"[{SIDE}] swi_training_mode_r high pre-force — the catch-up correctly "
        f"declines the stuck-training-high variant, so this must be low")
    assert _si(c.winscan_done) == 0, f"[{SIDE}] winscan_done already set pre-force"

    # ---- Model the dropped-fall committed+verified anchor --------------------
    # autonomy_armed is a derived wire (nego_en & role_locked & train_cfg[0]);
    # forcing it 1 models "arming completed" without a role_locked rising edge
    # (avoids a spurious calibrator recal). ws_anchor_q / ws_verify_q are the
    # controller's CDC'd deskew reanchor + verify latches — the exact gate
    # inputs — forced 1 to model the passive re-anchor that exact-verifies.
    c.autonomy_armed.value = Force(1)
    c.ws_anchor_q.value    = Force(1)
    c.ws_verify_q.value    = Force(1)

    # ---- Let the FIX-1 catch-up arc run --------------------------------------
    saw_pending  = False
    saw_active   = False
    saw_boot     = False
    done         = 0
    for _ in range(400):
        await ClockCycles(dut.hclk, 4)
        if _si(c.fch_pending_r) == 1:
            saw_pending = True
        if _si(c.fch_active_r) == 1:
            saw_active = True
        if _si(c.fch_wdata_r) == FCH_SWRESET_ON:
            saw_boot = True
        done = _si(c.winscan_done)
        if done == 1 and saw_active:
            break

    # Snapshot the load-bearing state BEFORE releasing the forces.
    ws_state = _si(c.ws_state_r)
    owns     = _si(c.winscan_owns_taps)
    fcsm     = _si(_fcsm(dut, SIDE).state)
    log.info("================ FIX-1 CATCH-UP EVIDENCE ================")
    log.info(f"[{SIDE}] winscan_done={done} ws_state={ws_state} "
             f"winscan_owns_taps={owns} fch_pending_seen={saw_pending} "
             f"fch_active_seen={saw_active} bootstrap_0x27f09_seen={saw_boot} "
             f"fcsm={fcsm}")
    log.info("========================================================")

    for name in ("autonomy_armed", "ws_anchor_q", "ws_verify_q"):
        getattr(c, name).value = Release()
    await ClockCycles(dut.hclk, 20)

    # ---- THE FIX-1 ASSERTIONS (RED on ca19da3 = NODONE) ----------------------
    assert done == 1, (
        f"[{SIDE}] NODONE: winscan_done never asserted for a die parked in "
        f"WS_IDLE holding a committed + VERIFIED anchor (ws_anchor_q & "
        f"ws_verify_q) whose armed training-fall was dropped — the fch handoff "
        f"deadlocks. FIX-1 (ws_reanchor_catchup) must raise winscan_done in "
        f"place.")
    assert saw_pending or saw_active, (
        f"[{SIDE}] the fch handoff never armed (fch_pending_r/fch_active_r never "
        f"observed) — winscan_done rose but did not open the fch handoff gate")
    assert saw_boot, (
        f"[{SIDE}] the fch bootstrap never drove FCH_LL_SWRESET_ON (0x27f09) — "
        f"the handoff sequencer did not run the proven bootstrap")
    # Safety: the catch-up completes IN PLACE — no stale-tap sweep.
    assert ws_state == WS_IDLE, (
        f"[{SIDE}] the catch-up left WS_IDLE (ws_state={ws_state}) — it must STAY "
        f"in WS_IDLE (going WS_DONE would set winscan_owns_taps and PIN stale "
        f"taps over the host/APB anchor)")
    assert owns == 0, (
        f"[{SIDE}] winscan_owns_taps={owns} — the catch-up must NOT take tap "
        f"ownership (no sweep, host/APB anchor taps untouched)")

    log.info("VERDICT: PASS — winscan_done asserted in place + the fch bootstrap "
             "ran (0x27f09) for a WS_IDLE committed+verified anchor; taps left "
             "to the host/APB (no sweep). The NODONE is broken.")

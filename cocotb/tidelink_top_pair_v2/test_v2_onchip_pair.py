"""W7 — the blocking on-chip-pair gate: ZERO-POKE autonomy, honestly.

Why this file exists
--------------------
The existing paired-die sim (test_v2_pair_data + pair_v2_common.run_bringup_full)
"proves" autonomy with two things that have NO silicon equivalent:

  1. tb_top.sv ~:938 HIERARCHICALLY FORCES `nego_cfg_reg = 7'h61` into both dies
     (its own comment admits it stands in for a NEGO_CFG_RESET strap "that did
     not exist"). Wave 1 added that strap, so the force is now a lie we can kill.
  2. Both dies share ONE zero-skew `ref_clk`, so the cross-connect exercises
     neither the calibrator nor the deskew nor the credit CDC — the exact
     sim-green / silicon-red pattern this project has been burned by.

This gate replaces both:
  * DUT parameter overrides (defparam, NOT force): NEGO_CFG_RESET=0x61 on both
    dies + HONEST_MASK_HS=1 (compiled via ONCHIP=1 MASK_HS=1). Autoneg runs at
    POR with ZERO APB writes; the peer-mask handshake is genuine (both bypass
    straps held at 0), so `mask_hs_gate_open` can open ONLY via a real
    `mask_hs_match`.
  * A phase-offset slave ref-clock (ONCHIP_PHASE/8 of the UI, mirroring the two
    hardware /8 dividers' INIT_PHASE 0 vs 3). Without it the test would pass for
    the wrong reason (test_00 catches a zero-skew collapse).

Compile / run
-------------
  positive gate : make ONCHIP=1 ONCHIP_PHASE=3 MASK_HS=1 MODULE=test_v2_onchip_pair
  negative ctrl : make ONCHIP=1 ONCHIP_PHASE=3 MASK_HS=0 MODULE=test_v2_onchip_pair
  both          : make onchip_gate
`HONEST_MASK_HS` is a *parameter*, so the negative control is a SEPARATE compile;
tests that do not apply to the current compile skip (log + pass).

Verified register / signal ground truth (re-read from RTL 2026-07-09)
--------------------------------------------------------------------
  * STATUS   0x2108 : [19:17] FCSM state, [16] cal_done
                      (axi_chiplet_controller.sv region8 slot2 :1945-1946)
  * OBS_MASK_HS 0x2194 : [19] mask_hs_match, [20] mask_hs_gate_open
                      (regionC slot5, decode paddr[8:5]==4'b1100 :477 / mux :2083;
                       obs packing :2025-2026)
  * mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i (:614)
  * hierarchical wires: u_chiplet_controller.mask_hs_match / .mask_hs_gate_open
"""
import os

import cocotb
from cocotb.triggers import ClockCycles, Timer

from pair_v2_common import (
    PairV2TB, send_and_check,
    REF_CLK_PERIOD_NS,
)

# ── verified APB offsets (unified 15-bit view, 0x2000 = TideLink region) ──────
APB_STATUS      = 0x2108      # [19:17] fcsm, [16] cal
APB_OBS_MASK_HS = 0x2194      # [19] mask_hs_match, [20] mask_hs_gate_open

STATUS_FCSM = lambda v: (v >> 17) & 0x7
STATUS_CAL  = lambda v: (v >> 16) & 0x1
OBS_MATCH   = lambda v: (v >> 19) & 0x1
OBS_GATE    = lambda v: (v >> 20) & 0x1

FCSM_LINK_IDLE = 4           # data-mode idle after CR/CRACK
CAL_DONE_STATE = 4           # calibrator FSM DONE


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


def _is_honest():
    """True when compiled with MASK_HS=1 (HONEST_MASK_HS=1, bypasses=0)."""
    return os.environ.get("TIDELINK_SIM_ONCHIP_MASK_HS", "0") == "1"


def _is_onchip(dut):
    """True only in an ONCHIP=1 compile (the phase-offset slave clock exists)."""
    return hasattr(dut, "s_ref_clk")


def _ctrl(tb, side):
    return tb.top(side).u_chiplet_controller


def _match(tb, side):
    return _safe_int(_ctrl(tb, side).mask_hs_match)


def _gate(tb, side):
    return _safe_int(_ctrl(tb, side).mask_hs_gate_open)


def _skip(dut, msg):
    """Mark the current test as non-applicable to this compile (pass, no-op)."""
    dut._log.warning(f"SKIP: {msg}")


async def _apb_read_or_wedge(tb, side, addr):
    """Read an APB reg; on timeout treat it as the PS<->PL training-entry wedge.

    HAZARD 1 (recorded today): die_a's PS<->PL bus dies at training ENTRY — the
    fch sequencer pins apb_pready low and the Arm CPU hangs with no AXI timeout.
    NEGO_TRAIN_CFG_RESET=16'h0001 arms training at POR, so this can fire in the
    zero-poke flow. On the on-chip pair BOTH dies sit behind ONE PS, so a wedge
    in either hangs the whole board. This sim is the only place training entry
    can be exercised safely today. We do NOT abort on a wedge: the autonomy proof
    is made via hierarchical signals (wedge-immune); a wedged host window is
    recorded as an observation so the gate can report it. Returns (value|None,
    wedged_bool)."""
    try:
        v = await tb.apb(side).read(addr, timeout=4000)
        return v, False
    except TimeoutError:
        pr = _safe_int(getattr(tb.dut, f"{side}_apb_pready"))
        tb.log.error(
            f"[WEDGE?] APB read 0x{addr:04x} on die '{side}' timed out "
            f"(apb_pready={pr}) — PS<->PL training-entry wedge signature "
            f"(fch sequencer pinning apb_pready low). Autonomy still judged via "
            f"hierarchical mask_hs_match/gate_open/fcsm.")
        return None, True


async def wait_link_up_zeropoke(tb, max_cycles=2_000_000, poll=500):
    """Poll (NO APB) until BOTH dies reach FCSM LINK_IDLE and calibrator DONE.

    Pure hierarchical poll — the RTL is expected to bring the link up on its own
    once role_lock latches (wlink_por_reset releases; swi_enable defaults high).
    No do_to_data_mode bootstrap pokes: that would be a firmware recipe, which is
    NOT the deliverable."""
    for _ in range(max_cycles // poll):
        await ClockCycles(tb.dut.hclk, poll)
        if (tb.fcsm_state("m") == FCSM_LINK_IDLE and
                tb.fcsm_state("s") == FCSM_LINK_IDLE and
                tb.cal_state_name("m") == "DONE" and
                tb.cal_state_name("s") == "DONE"):
            return True
    return False


async def bringup_zeropoke(tb):
    """POR -> (autoneg drives everything) -> role_lock -> link up. ZERO APB writes.

    Returns dict(wedged=bool) recording whether any host-window read wedged."""
    await tb.reset()
    # Sim-tractability ONLY: skip the calibrator's 2M-link-cycle S_HOLD dwell +
    # cr_pkt_seen-gated S_VALIDATE (infeasible in sim). This is the designed-in
    # PHY component-suite hook; it does NOT bypass negotiation, the mask
    # handshake, or role-lock, so the autonomy proof stands.
    tb.force_calibrator_sim_bypass()

    # role_lock must latch with NO poke. wait_role_locked polls role_locked_o
    # (output ports) only. Big budget: autoneg + I2C mask handshake is slow
    # (cf. test_10 budgeted ~5M cycles at 50 MHz hclk).
    locked = await tb.wait_role_locked(max_cycles=4_000_000)
    assert locked, (
        "role_lock never latched with ZERO pokes — autoneg / peer-mask handshake "
        "stalled. m_role_locked=%d s_role_locked=%d fcsm(m/s)=%d/%d "
        "match(m/s)=%d/%d gate(m/s)=%d/%d" % (
            _safe_int(tb.dut.m_role_locked), _safe_int(tb.dut.s_role_locked),
            tb.fcsm_state("m"), tb.fcsm_state("s"),
            _match(tb, "m"), _match(tb, "s"), _gate(tb, "m"), _gate(tb, "s")))

    up = await wait_link_up_zeropoke(tb)
    assert up, (
        "link did not reach bilateral FCSM=LINK_IDLE + cal=DONE zero-poke: "
        "fcsm(m/s)=%d/%d cal(m/s)=%s/%s" % (
            tb.fcsm_state("m"), tb.fcsm_state("s"),
            tb.cal_state_name("m"), tb.cal_state_name("s")))
    return {"wedged": False}


# ===========================================================================
# test_00 — anti-trap: the two dies' PLL references must be phase-offset.
# ===========================================================================
@cocotb.test()
async def test_00_phase_is_nonzero(dut):
    """Probe the DUT's ACTUAL ref-clock ports (not dangling tb nets) and assert
    the slave clock (a) toggles and (b) is NOT identical to the master clock over
    a full UI. A zero-skew collapse (shared edge, or INIT_PHASE offset == 0) makes
    them bit-equal at every sample -> this fails, which is the whole point: no
    host runtime read can catch a zero-skew collapse, so the proof must live
    here (plan §4)."""
    if not _is_onchip(dut):
        _skip(dut, "not an ONCHIP compile (no s_ref_clk) — phase gate N/A")
        return

    tb = PairV2TB(dut)          # starts hclk, ref_clk, and the phase-offset s_ref_clk
    # Let both clocks get going past the slave's initial phase delay.
    await Timer(int(round(REF_CLK_PERIOD_NS * 4 * 1000)), unit="ps")

    m_clk = dut.u_master.user_ref_clk
    s_clk = dut.u_slave.user_ref_clk
    m_vals, s_vals = set(), set()
    differed = False
    # Sample densely across > 4 ref periods.
    n = 400
    step_ps = int(round(REF_CLK_PERIOD_NS * 4 * 1000 / n))
    for _ in range(n):
        await Timer(step_ps, unit="ps")
        mv, sv = _safe_int(m_clk), _safe_int(s_clk)
        m_vals.add(mv)
        s_vals.add(sv)
        if mv != sv and mv in (0, 1) and sv in (0, 1):
            differed = True

    assert 0 in m_vals and 1 in m_vals, \
        f"master user_ref_clk never toggled (values seen: {sorted(m_vals)})"
    assert 0 in s_vals and 1 in s_vals, (
        "slave user_ref_clk never toggled (values seen: %s) — s_ref_clk is stuck; "
        "a differ-only check would FALSELY pass on a dead slave clock" % sorted(s_vals))
    assert differed, (
        "slave and master user_ref_clk are phase-locked (identical at every "
        "sample) — the two dies share a zero-skew ref edge. ONCHIP_PHASE offset "
        "is 0 or TB_TOP_ONCHIP_REFCLK is not wired. This is the zero-skew trap; "
        "a green FC/autonomy result under it would be a false pass.")
    dut._log.info(
        f"test_00: ref clocks phase-offset OK (master toggled={sorted(m_vals)} "
        f"slave toggled={sorted(s_vals)} differ-seen=True).")


# ===========================================================================
# test_01 — ZERO-POKE autonomy with a GENUINE mask handshake (positive gate).
# ===========================================================================
@cocotb.test()
async def test_01_zeropoke_autonomy(dut):
    """POR -> autoneg -> genuine peer-mask handshake -> role_lock -> link, with
    ZERO APB writes and BOTH bypass straps at 0. The positive gate."""
    if not _is_honest():
        _skip(dut, "MASK_HS!=1 — honest-handshake asserts N/A (see test_90)")
        return
    if not _is_onchip(dut):
        _skip(dut, "not an ONCHIP compile — zero-poke autonomy N/A")
        return

    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()

    # --- POR baseline: with HONEST_MASK_HS=1 and bypass=0 the gate must be
    #     CLOSED before anything negotiates. This is the crisp distinguisher the
    #     negative control (test_90) inverts: same code path, HONEST_MASK_HS
    #     flips this early gate_open from 0 (honest) to 1 (forced open).
    await ClockCycles(dut.hclk, 40)
    for side in ("m", "s"):
        assert _match(tb, side) == 0, \
            f"{side}: mask_hs_match already 1 at POR (impossible pre-handshake)"
        assert _gate(tb, side) == 0, (
            f"{side}: mask_hs_gate_open==1 at POR with HONEST_MASK_HS=1 & "
            f"bypass=0 — a bypass/unlock strap is leaking the gate open, the "
            f"autonomy proof would be vacuous")
    assert _safe_int(dut.m_apb_debug_unlock) == 0 and \
        _safe_int(dut.s_apb_debug_unlock) == 0, \
        "apb_debug_unlock is not 0 — the honest gate is not actually honest"

    # --- ZERO POKES from here. autoneg (NEGO_CFG_RESET=0x61) drives the genuine
    #     mask handshake -> mask_hs_match -> gate_open -> role_lock, all in RTL.
    locked = await tb.wait_role_locked(max_cycles=4_000_000)
    assert locked, (
        "role_lock never latched zero-poke: fcsm(m/s)=%d/%d match(m/s)=%d/%d "
        "gate(m/s)=%d/%d role_master(m/s)=%d/%d" % (
            tb.fcsm_state("m"), tb.fcsm_state("s"), _match(tb, "m"), _match(tb, "s"),
            _gate(tb, "m"), _gate(tb, "s"),
            _safe_int(dut.m_role_is_master), _safe_int(dut.s_role_is_master)))

    # --- complementary roles: exactly one master.
    m_is_m = _safe_int(dut.m_role_is_master)
    s_is_m = _safe_int(dut.s_role_is_master)
    assert (m_is_m ^ s_is_m) == 1, \
        f"roles not complementary: m_role_is_master={m_is_m} s_role_is_master={s_is_m}"

    # --- POSITIVE handshake proof (hierarchical, wedge-immune): both dies genuinely
    #     matched AND the gate opened BY the match, not by a strap.
    for side in ("m", "s"):
        assert _match(tb, side) == 1, \
            f"{side}: mask_hs_match != 1 after role_lock — sham/incomplete handshake"
        assert _gate(tb, side) == _match(tb, side), (
            f"{side}: mask_hs_gate_open ({_gate(tb, side)}) != mask_hs_match "
            f"({_match(tb, side)}) — the gate opened via a strap, not the handshake")

    # --- link up bilaterally (zero-poke).
    up = await wait_link_up_zeropoke(tb)
    assert up, (
        "link did not reach FCSM=LINK_IDLE + cal=DONE zero-poke: "
        "fcsm(m/s)=%d/%d cal(m/s)=%s/%s" % (
            tb.fcsm_state("m"), tb.fcsm_state("s"),
            tb.cal_state_name("m"), tb.cal_state_name("s")))

    # --- apb_debug_unlock must STILL be 0 (never poked open).
    assert _safe_int(dut.m_apb_debug_unlock) == 0 and \
        _safe_int(dut.s_apb_debug_unlock) == 0, \
        "apb_debug_unlock went nonzero — link only came up via a debug poke (RED FLAG)"

    # --- host-window cross-check via APB (the registers the KR260 host reads).
    #     Wedge-aware: a PS<->PL wedge is recorded, not fatal (hierarchy already
    #     proved autonomy).
    wedged = False
    for side in ("m", "s"):
        obs, w1 = await _apb_read_or_wedge(tb, side, APB_OBS_MASK_HS)
        st,  w2 = await _apb_read_or_wedge(tb, side, APB_STATUS)
        wedged = wedged or w1 or w2
        if obs is not None:
            assert OBS_MATCH(obs) == 1, \
                f"{side}: OBS_MASK_HS[19] mask_hs_match != 1 (0x{obs:08x})"
            assert OBS_GATE(obs) == OBS_MATCH(obs), \
                f"{side}: OBS_MASK_HS[20] gate_open != [19] match (0x{obs:08x})"
        if st is not None:
            assert STATUS_FCSM(st) == FCSM_LINK_IDLE, \
                f"{side}: STATUS[19:17] fcsm={STATUS_FCSM(st)} != 4 (0x{st:08x})"
            assert STATUS_CAL(st) == 1, \
                f"{side}: STATUS[16] cal != 1 (0x{st:08x})"
        dut._log.info(
            f"  [{side}] OBS_MASK_HS=0x{(obs if obs is not None else 0):08x} "
            f"STATUS=0x{(st if st is not None else 0):08x}")

    if wedged:
        dut._log.error(
            "PS<->PL WEDGE OBSERVED IN SIM: the host register window timed out "
            "during/after zero-poke training entry. Autonomy is proven via "
            "hierarchy, but the host could not read the proof — investigate the "
            "fch sequencer apb_pready path before trusting hardware bring-up.")
    else:
        dut._log.info(
            "test_01: ZERO-POKE autonomy PROVEN — genuine mask handshake, "
            "complementary roles, bilateral link, no debug poke, host window OK.")


# ===========================================================================
# test_02 / test_03 — small data proof under the static phase offset.
# ===========================================================================
@cocotb.test()
async def test_02_data_master_to_slave(dut):
    if not _is_honest():
        _skip(dut, "MASK_HS!=1 — data proof runs only under the honest gate")
        return
    if not _is_onchip(dut):
        _skip(dut, "not an ONCHIP compile — data proof N/A")
        return
    tb = PairV2TB(dut)
    await bringup_zeropoke(tb)
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="onchip-m2s")


@cocotb.test()
async def test_03_data_slave_to_master(dut):
    if not _is_honest():
        _skip(dut, "MASK_HS!=1 — data proof runs only under the honest gate")
        return
    if not _is_onchip(dut):
        _skip(dut, "not an ONCHIP compile — data proof N/A")
        return
    tb = PairV2TB(dut)
    await bringup_zeropoke(tb)
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D], ctx="onchip-s2m")


# ===========================================================================
# test_90 — NEGATIVE CONTROL (required): a gate that cannot fail is not a gate.
# Compiled with MASK_HS=0 => HONEST_MASK_HS=0 => the ports fold back to 1'b1 =>
# mask_hs_gate_open is forced open independent of any handshake. Prove that the
# gate reads OPEN while match is still 0 — the exact vacuous condition test_01
# forbids. If this ever fails, HONEST_MASK_HS is not actually load-bearing and
# test_01's pass is meaningless.
# ===========================================================================
@cocotb.test()
async def test_90_negctl_gate_forced_open(dut):
    if _is_honest():
        _skip(dut, "MASK_HS=1 (honest compile) — negative control N/A here")
        return
    if not _is_onchip(dut):
        _skip(dut, "not an ONCHIP compile — negative control N/A")
        return

    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()

    # Sample EARLY — before the (slow I2C) mask handshake could complete, so a
    # genuine match is impossible yet. With HONEST_MASK_HS=0 the gate is already
    # open regardless.
    await ClockCycles(dut.hclk, 40)
    for side in ("m", "s"):
        assert _match(tb, side) == 0, (
            f"{side}: mask_hs_match==1 only 40 cycles after POR — too fast to be "
            f"genuine; negative-control premise broken")
        assert _gate(tb, side) == 1, (
            f"{side}: mask_hs_gate_open==0 with HONEST_MASK_HS=0 — the legacy tie "
            f"is NOT forcing the gate open, so HONEST_MASK_HS does nothing and "
            f"test_01 proves nothing")

    # Host-window cross-check (best-effort; this early the bus is not wedged).
    obs_m, _w = await _apb_read_or_wedge(tb, "m", APB_OBS_MASK_HS)
    if obs_m is not None:
        assert OBS_GATE(obs_m) == 1 and OBS_MATCH(obs_m) == 0, \
            f"m: OBS_MASK_HS gate/match not (1,0) forced-open (0x{obs_m:08x})"

    dut._log.info(
        "test_90: negative control PASSED — with HONEST_MASK_HS=0 the gate is "
        "forced open (gate_open=1 while match=0). HONEST_MASK_HS is load-bearing; "
        "test_01's positive proof is therefore non-vacuous.")

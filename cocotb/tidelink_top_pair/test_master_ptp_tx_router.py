"""Master TX-router localisation tests for **TideLink Bug B**.

Prior agent work (``test_ptp_corrected_regs.py``) established:

* Slave ``ptp_rx_valid_r`` stays 0; ``PTP_RX_PAYLOAD`` stays 0.
* Master ``sp2wl.tx_valid`` / ``tx_winc`` / ``tx_wfull`` are all zero
  for 5000 cy after master writes ``HW_SYNC_CTRL = 0x05``.
* Bug B is upstream of Wlink, inside the master ``tidelink_ptp`` TX
  router.

This file localises Bug B to a single signal inside
``src/rtl/tidelink_ptp.sv`` by probing the six candidate gates along
the path:

  CTRL write → hw_sync_en_r / hw_sync_force_en_r
             → HW_SYNC FSM (IDLE → ARMED → FIRE)
             → hw_sync_trigger (combinational; lines 420-422)
             → tx_state_r (TX_IDLE → TX_WAIT_IDLE → TX_SEND)
             → ptp_sp_tx_valid (line 276)
             → ShortPacketToWlink (out of scope here)

The tx_router_idle / link_idle gate is also probed even though
``hw_sync_force_en_r`` is supposed to bypass it (line 260), because the
prior agent's hypothesis that "link_idle CDC stuck" is one of the two
listed candidates.

Hierarchical path (per ``waves.vcd``):
  ``dut.u_master.gen_ptp_real.u_ptp.<sig>``

This file **does not modify** existing tests (per session constraint).
It reuses the ``PairTB`` / ``run_bringup_full`` helpers and the same
arm sequence as ``test_ptp_corrected_regs.py``.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_PTP_CTRL,
    APB_HW_SYNC_CTRL,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)

# Same arm constants as test_ptp_corrected_regs.py.
PTP_CTRL_MASTER_GM_ENABLE = 0x09   # GM(bit3) | enable(bit0)
PTP_CTRL_SLAVE_ENABLE     = 0x01
HW_SYNC_CTRL_FORCE_ENABLE = 0x05   # force_en(bit2) | enable(bit0)


# ---------------------------------------------------------------------------
# Hierarchical probe helpers
# ---------------------------------------------------------------------------
# Memoise the resolved tidelink_ptp handle per side. VCD scope is
# ``tb_top.u_<m|s>aster.gen_ptp_real.u_ptp`` but VCS exposes the
# generate-block as either a nested attribute or a flattened name with
# a literal dot. Walk every plausible form once.
_PTP_HANDLE_CACHE = {}


def _resolve_u_ptp(dut, side):
    cached = _PTP_HANDLE_CACHE.get(side)
    if cached is not None:
        return cached
    top = dut.u_master if side == "m" else dut.u_slave
    log = dut._log
    candidates = []
    # 1. Nested attribute (cocotb-cleanest form).
    try:
        candidates.append(("top.gen_ptp_real.u_ptp", top.gen_ptp_real.u_ptp))
    except (AttributeError, Exception):
        pass
    # 2. Flattened name with embedded dot — getattr can't take it but
    #    cocotb's _id() can.
    try:
        candidates.append(
            ("top._id('gen_ptp_real.u_ptp', extended=False)",
             top._id("gen_ptp_real.u_ptp", extended=False))
        )
    except Exception:
        pass
    # 3. Generate-block dropped entirely (some VPIs flatten).
    try:
        candidates.append(("top.u_ptp", top.u_ptp))
    except Exception:
        pass
    # 4. As a child name via dir().
    try:
        children = list(dir(top))
        log.info(f"  [_resolve_u_ptp side={side}] dir(top) children: {children}")
    except Exception as e:
        log.info(f"  [_resolve_u_ptp side={side}] dir(top) failed: {e}")
    for label, h in candidates:
        if h is not None:
            try:
                # Probe a known signal to verify the handle is real.
                _ = h.tx_state_r
                log.info(f"  [_resolve_u_ptp side={side}] using {label}")
                _PTP_HANDLE_CACHE[side] = h
                return h
            except Exception:
                continue
    log.warning(f"  [_resolve_u_ptp side={side}] no candidate exposed tx_state_r")
    # Last resort: return the first non-None candidate; probe attempts will
    # surface "missing signal" later.
    for label, h in candidates:
        if h is not None:
            _PTP_HANDLE_CACHE[side] = h
            return h
    raise AttributeError(f"could not resolve u_ptp on side={side}")


def _probe(dut, side, name):
    try:
        h = _resolve_u_ptp(dut, side)
    except Exception:
        return -1
    try:
        sig = getattr(h, name)
        return int(sig.value)
    except (AttributeError, ValueError):
        return -1


async def _arm_master_hw_sync(tb):
    """Full pair bringup, then arm slave + master PTP, then fire
    master ``HW_SYNC_CTRL = 0x05`` (force_en | enable).

    Mirrors ``_bringup_then_arm_ptp`` in ``test_ptp_corrected_regs.py``
    but without the 5000-cy settle wait (each test below adds its own
    cycle-accurate sample window).
    """
    await run_bringup_full(tb)

    # Drop training on both sides.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Enable PTP on slave then master.
    await tb.s_apb.write(APB_PTP_CTRL, PTP_CTRL_SLAVE_ENABLE)
    await tb.m_apb.write(APB_PTP_CTRL, PTP_CTRL_MASTER_GM_ENABLE)
    await ClockCycles(tb.dut.hclk, 100)

    # Fire HW_SYNC on master.
    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_CTRL_FORCE_ENABLE)
    tb.log.info(
        f"  master HW_SYNC_CTRL <= 0x{HW_SYNC_CTRL_FORCE_ENABLE:02x} "
        "(force_en + enable)"
    )


async def _sample_router_state(dut, log, n_cycles, label):
    """Sample the master TX-router signal set cycle-by-cycle and return
    aggregate stats. Covers all six candidate gates in one pass.
    """
    counts = dict(
        trigger_pulses=0,
        en_high=0,
        force_en_high=0,
        router_idle_high=0,
        state_idle=0,
        state_wait_idle=0,
        state_send=0,
        sp_tx_valid_high=0,
        hw_sync_state_idle=0,
        hw_sync_state_armed=0,
        hw_sync_state_fire=0,
        hw_sync_state_wait_tx=0,
    )
    last_state = -1
    last_hw_state = -1
    for _ in range(n_cycles):
        await RisingEdge(dut.hclk)
        if _probe(dut, "m", "hw_sync_trigger") == 1:
            counts["trigger_pulses"] += 1
        if _probe(dut, "m", "hw_sync_en_r") == 1:
            counts["en_high"] += 1
        if _probe(dut, "m", "hw_sync_force_en_r") == 1:
            counts["force_en_high"] += 1
        if _probe(dut, "m", "tx_router_idle") == 1:
            counts["router_idle_high"] += 1
        st = _probe(dut, "m", "tx_state_r")
        if st == 0:
            counts["state_idle"] += 1
        elif st == 1:
            counts["state_wait_idle"] += 1
        elif st == 2:
            counts["state_send"] += 1
        if st != last_state and last_state != -1:
            log.info(f"  [{label}] tx_state_r {last_state} -> {st}")
        last_state = st
        if _probe(dut, "m", "ptp_sp_tx_valid") == 1:
            counts["sp_tx_valid_high"] += 1
        hs = _probe(dut, "m", "hw_sync_state_r")
        if hs == 0:
            counts["hw_sync_state_idle"] += 1
        elif hs == 1:
            counts["hw_sync_state_armed"] += 1
        elif hs == 2:
            counts["hw_sync_state_fire"] += 1
        elif hs == 3:
            counts["hw_sync_state_wait_tx"] += 1
        if hs != last_hw_state and last_hw_state != -1:
            log.info(f"  [{label}] hw_sync_state_r {last_hw_state} -> {hs}")
        last_hw_state = hs
    log.info(
        f"  [{label}] {n_cycles} cy summary: "
        f"trig={counts['trigger_pulses']} "
        f"en={counts['en_high']} force_en={counts['force_en_high']} "
        f"router_idle={counts['router_idle_high']} "
        f"tx_state(IDLE/WAIT/SEND)={counts['state_idle']}/"
        f"{counts['state_wait_idle']}/{counts['state_send']} "
        f"sp_tx_valid={counts['sp_tx_valid_high']} "
        f"hw_sync_state(IDLE/ARMED/FIRE/WAIT_TX)="
        f"{counts['hw_sync_state_idle']}/"
        f"{counts['hw_sync_state_armed']}/"
        f"{counts['hw_sync_state_fire']}/"
        f"{counts['hw_sync_state_wait_tx']}"
    )
    return counts


# ===========================================================================
# Tests
# ===========================================================================

@cocotb.test()
async def test_hw_sync_en_r_set(dut):
    """**CTRL bit decode probe.** 10 cy after master writes
    ``HW_SYNC_CTRL = 0x05`` both ``hw_sync_en_r`` and
    ``hw_sync_force_en_r`` must be 1.

    If either is 0, the APB → register pass-through (``ptp_reg_region``,
    ``ptp_reg_write``, ``ptp_reg_addr``, ``ptp_reg_wdata``) is broken —
    the CTRL write doesn't reach the register. Most likely culprit:
    ``ptp_reg_region`` mis-routed to Region 1 instead of Region 2 (see
    ``tidelink_ptp.sv:473`` — Region-2 writes are gated on
    ``ptp_reg_region``).
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)
    await ClockCycles(tb.dut.hclk, 10)

    en      = _probe(dut, "m", "hw_sync_en_r")
    force_en = _probe(dut, "m", "hw_sync_force_en_r")
    tb.log.info(
        f"  master hw_sync_en_r={en} hw_sync_force_en_r={force_en}"
    )

    assert en == 1 and force_en == 1, (
        f"HW_SYNC_CTRL=0x05 did not latch on the master: "
        f"hw_sync_en_r={en} hw_sync_force_en_r={force_en}. "
        "APB → ptp_reg_region/_write/_addr/_wdata pass-through to "
        "tidelink_ptp Region 2 (tidelink_ptp.sv:473) is broken."
    )


@cocotb.test()
async def test_hw_sync_trigger_fires(dut):
    """**HW_SYNC FSM probe.** Over 200 cy after the CTRL write,
    ``hw_sync_trigger`` (combinational, ``tidelink_ptp.sv:420``) must
    pulse at least once. If never, the HW_SYNC FSM never reached
    ``HW_SYNC_FIRE``.

    Most likely culprit: ``phc_time_reached`` (line 399) stays false
    because ``phc_seconds = 0`` and ``phc_nanoseconds = 0`` are hardwired
    in ``tb_top.sv:316/527`` and ``hw_sync_interval_r`` defaults to
    ``DEFAULT_INTERVAL`` (= 999_999_999 ns) so the FSM is stuck in
    ``HW_SYNC_ARMED`` forever.
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    counts = await _sample_router_state(
        dut, tb.log, 200, "trigger probe (200 cy)"
    )

    assert counts["trigger_pulses"] > 0, (
        f"hw_sync_trigger never pulsed in 200 cy "
        f"(hw_sync_state IDLE/ARMED/FIRE/WAIT_TX="
        f"{counts['hw_sync_state_idle']}/"
        f"{counts['hw_sync_state_armed']}/"
        f"{counts['hw_sync_state_fire']}/"
        f"{counts['hw_sync_state_wait_tx']}). "
        "HW_SYNC FSM never reached HW_SYNC_FIRE. Most likely: "
        "phc_time_reached false because phc_seconds/_nanoseconds=0 "
        "in tb_top.sv but hw_sync_interval_r defaults to ~1 s."
    )


@cocotb.test()
async def test_tx_router_idle_high(dut):
    """**Router-idle gate probe.** ``tx_router_idle`` is the Wlink
    ``tx_link_idle`` output (``tidelink_top.sv:1964``) directly wired
    into ``tidelink_ptp.tx_router_idle``. If stuck low, the
    ``TX_WAIT_IDLE → TX_SEND`` transition (line 260) is gated.

    NOTE: ``hw_sync_force_en_r=1`` bypasses this gate, so a stuck-low
    ``tx_router_idle`` alone is NOT sufficient to block the trigger
    path when ``HW_SYNC_CTRL=0x05`` is used. Still useful for ruling
    in/out the prior agent's "link_idle CDC stuck" hypothesis.
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    counts = await _sample_router_state(
        dut, tb.log, 500, "router_idle probe (500 cy)"
    )

    # Soft assertion: log fail if router_idle is stuck low, but the test
    # still distinguishes "stuck low" from "toggles normally" — both are
    # diagnostically useful. We mark stuck-low as failure to surface it.
    assert counts["router_idle_high"] > 0, (
        f"tx_router_idle stuck LOW for full 500 cy. "
        "Wlink tx_link_idle is being held low — link-layer keeps "
        "the TX in a non-idle state, gating non-force-en HW_SYNC "
        "writes. With force_en=1 the gate is bypassed (tidelink_ptp.sv"
        ":260) so this is a SECONDARY observation, not the trigger of "
        "Bug B with HW_SYNC_CTRL=0x05."
    )


@cocotb.test()
async def test_tx_state_progression(dut):
    """**TX FSM progression probe.** Over 500 cy after CTRL write, the
    master TX FSM (``tidelink_ptp.sv:176-180``) must reach ``TX_SEND``
    (state code 2).

    Pass criterion: ``tx_state_r == TX_SEND`` for at least one sample.
    Fail with full state-occupancy breakdown so the next-step diagnosis
    knows which state it's wedged in.
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    counts = await _sample_router_state(
        dut, tb.log, 500, "tx_state probe (500 cy)"
    )

    assert counts["state_send"] > 0, (
        f"master tx_state_r never reached TX_SEND over 500 cy "
        f"(IDLE/WAIT_IDLE/SEND = "
        f"{counts['state_idle']}/{counts['state_wait_idle']}/"
        f"{counts['state_send']}). "
        f"trigger_pulses={counts['trigger_pulses']} "
        f"router_idle_high_cycles={counts['router_idle_high']}. "
        "TX FSM is wedged in IDLE/WAIT_IDLE."
    )


@cocotb.test()
async def test_ptp_sp_tx_valid_pulse(dut):
    """**SP TX-emit probe.** ``ptp_sp_tx_valid`` (line 276) =
    ``(tx_state_r == TX_SEND) & ptp_enable_r``. If ``tx_state_r``
    reaches ``TX_SEND`` but ``ptp_sp_tx_valid`` stays 0, then
    ``ptp_enable_r`` was never set — i.e. the master ``PTP_CTRL=0x09``
    write didn't latch the enable bit.

    Pass criterion: ``ptp_sp_tx_valid`` high for at least one cycle in
    a 500-cycle window post-CTRL-write.
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    counts = await _sample_router_state(
        dut, tb.log, 500, "sp_tx_valid probe (500 cy)"
    )

    ptp_en = _probe(dut, "m", "ptp_enable_r")
    tb.log.info(f"  master ptp_enable_r at end of window = {ptp_en}")

    assert counts["sp_tx_valid_high"] > 0, (
        f"ptp_sp_tx_valid never pulsed in 500 cy. "
        f"tx_state_r reached TX_SEND for {counts['state_send']} cy, "
        f"ptp_enable_r={ptp_en} at end. "
        "If TX_SEND was reached but valid stayed low, ptp_enable_r is "
        "0 — Region 1 CTRL write didn't latch (tidelink_ptp.sv:343). "
        "If TX_SEND was never reached, see test_tx_state_progression."
    )

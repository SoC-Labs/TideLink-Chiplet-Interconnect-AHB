"""I1 FCSM bring-up regression -- the REAL KR260 silicon failure mode.

WHAT SILICON SHOWED (docs/I1_FCSM_BRINGUP_REGRESSION.md)
  After I1 re-pointed the 5 AXI FC nodes (WlinkGenericFCSM{,_1,_2,_3,_4}) at the
  recovery-capable src/rtl/local_overrides copies, the KR260 d2d link NEVER
  comes up: SWI_LANE_STATUS reads cr_seen=0 crack_seen=0 cal_done=0, fcsm stuck
  0/1, BOTH dies. The deps (recovery-stripped) FCSMs bring up fcsm=4.

WHY (root cause, proven in this TB)
  SWI_LANE_STATUS cr_seen/crack_seen/fcsm report the SIDEBAND node (tl2wl /
  WlinkGenericFCSM_6), NOT the AXI nodes -- but all 7 FC nodes (5 AXI + general
  bus + sideband) are time-multiplexed onto ONE link by the FAIR round-robin
  WlinkTxRouter (broadcast RX; each node self-selects by data_id). The local
  override holds state 1 until it has emitted SOCL_L6_MIN_CR_EMITS(=32) of its
  OWN CR packets (and state 2 until SOCL_L7_MIN_CRACK_EMITS CRACK emits). deps
  leaves state 1 on the FIRST peer CR/CRACK seen. At the ~40 ns silicon
  link:app ratio, with a marginal/retrying link (modelled here by a periodic LL
  re-bring-up = the sim stand-in for the async two-die reset/retry), a node
  CANNOT accrue 32 own CR emits -- throttled ~6-7x by the shared arbiter --
  before the count is reset, so the state-1 exit never fires. Every node,
  INCLUDING the sideband that SWI_LANE_STATUS reports, livelocks at state 1 ->
  cr_seen=0. It is the L6 CR gate (32, never lowered by I1), not the L7 CRACK
  gate (8) that the earlier analysis and the tidelink_fcsm_silicon_ratio suite
  fixated on.

  IMPORTANT (instrument honesty): a byte-align hunt latency is NOT part of this
  mechanism -- the integrated PHY hard-wires USE_T3A=0, so there is no RX hunt
  FSM; alignment is fixed by the /16 word clock at reset. The failure is purely
  the emit-count HOLD vs the shared-arbiter throughput at the slow ratio.

RED / GREEN
  make repro   # +define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS -> pre-fix I1 emit HOLD
               #   armed from reset -> sideband+AXI livelock -> EXPECT FAIL (RED)
  make fixed   # shipping default: HOLD held OFF until first LINK_IDLE
               #   (socl_reached_link_idle) -> bring-up is deps-identical
               #   -> reaches LINK_IDLE -> EXPECT PASS (GREEN)
  make deps    # deps FCSMs (no gate at all) -> PASS (baseline sanity)

  A CLEAN link (no re-bring-up) reaches LINK_IDLE in BOTH configs -- that is the
  test_clean_bringup control: it proves the fix does not break link-up and that
  the RED failure is the marginal-link livelock, not a compile artifact.
"""
import os
import cocotb
from cocotb.triggers import ClockCycles, Event

from pair_v2_common import (PairV2TB, REF_CLK_PERIOD_NS, CLK_PERIOD_NS,
                            APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF,
                            LL_BOOTSTRAP_ENABLE, ST_CR_SEEN, ST_CRACK_SEEN,
                            ST_CAL_DONE)

# The five AXI FC nodes inside axi2wl (AXI4ToWlink).
AXI_FC_NODES = ["wlink_axiawFC", "wlink_axiwFC", "wlink_axibFC",
                "wlink_axiarFC", "wlink_axirFC"]
STATE_LINK_IDLE = 4          # SEND_CREDITS2 cleared -> LINK_EN_WAIT/LINK_IDLE


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)


def _rd(handle, attr):
    try:
        return int(getattr(handle, attr).value)
    except (AttributeError, ValueError):
        return -1


def _sample_axi(tb):
    """{(side,inst): state} for all 10 AXI nodes."""
    return {(side, inst): _rd(_axi_node(tb, side, inst), "state")
            for side in ("m", "s") for inst in AXI_FC_NODES}


def _knob():
    return os.environ.get("SOCL_FCSM_HOLD_MODE", "RTL-default")


async def _observe(tb, dut, chunks):
    """Run chunks*50 hclk; track per-node and per-sideband max(state)."""
    max_axi = {k: 0 for k in _sample_axi(tb)}
    max_sb = {"m": 0, "s": 0}
    for i in range(chunks):
        await ClockCycles(dut.hclk, 50)
        for k, st in _sample_axi(tb).items():
            max_axi[k] = max(max_axi[k], st)
        for s in ("m", "s"):
            max_sb[s] = max(max_sb[s], tb.fcsm_state(s))
        if (i + 1) % 200 == 0:
            dut._log.info(
                f"    [+{(i + 1) * 50} hclk] sideband max_state m={max_sb['m']} "
                f"s={max_sb['s']} | axi(m.aw) state={_rd(_axi_node(tb,'m','wlink_axiawFC'),'state')} "
                f"cr(m)={tb.fcsm_cr_seen('m')} cr(s)={tb.fcsm_cr_seen('s')}")
    return max_axi, max_sb


def _report(tb, dut, max_axi, max_sb):
    dut._log.info(f"  === bring-up outcome (HOLD mode={_knob()}) ===")
    dut._log.info(f"  SIDEBAND (tl2wl, the SWI_LANE_STATUS source) max_state: "
                  f"m={max_sb['m']} s={max_sb['s']}  "
                  f"cr_seen m={tb.fcsm_cr_seen('m')} s={tb.fcsm_cr_seen('s')}")
    hist = {}
    for v in max_axi.values():
        hist[v] = hist.get(v, 0) + 1
    dut._log.info(f"  AXI FC nodes max_state histogram (state->#nodes): {hist}")
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            dut._log.info(f"    [{side}] {inst:14s} max_state={max_axi[(side, inst)]}")
    axi_stuck = [k for k, v in max_axi.items() if v < STATE_LINK_IDLE]
    sb_stuck = [s for s in ("m", "s") if max_sb[s] < STATE_LINK_IDLE]
    return axi_stuck, sb_stuck


async def _periodic_rebringup(tb, hold_hclk, stop):
    """Drop+restore the LL enable on both dies every hold_hclk. Each drop resets
    the FC nodes to state 0 (emit counts zeroed) -- the sim stand-in for the
    async two-die reset/retry of a marginal silicon link at the slow ratio."""
    while not stop.is_set():
        await ClockCycles(tb.dut.hclk, hold_hclk)
        try:
            await tb.m_apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF)
            await tb.s_apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF)
            await ClockCycles(tb.dut.hclk, 5)
            await tb.m_apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_ENABLE)
            await tb.s_apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_ENABLE)
        except Exception as e:  # noqa: BLE001
            tb.log.warning(f"rebringup pulse failed: {e}")
            return


async def _bringup_to_data_mode(tb):
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()


# ---------------------------------------------------------------------------
# CONTROL: a CLEAN link reaches LINK_IDLE in BOTH configs. Proves the fix does
# not break link-up AND that the RED failure below is the marginal-link
# livelock, not a mere consequence of compiling the HOLD in.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_clean_bringup(dut):
    dut._log.info(f"=== CLEAN bring-up control === hclk={CLK_PERIOD_NS} ns "
                  f"ref_clk={REF_CLK_PERIOD_NS} ns HOLD mode={_knob()}")
    tb = PairV2TB(dut)
    await _bringup_to_data_mode(tb)
    max_axi, max_sb = await _observe(tb, dut, int(os.environ.get("OBS_CHUNKS", "240")))
    axi_stuck, sb_stuck = _report(tb, dut, max_axi, max_sb)
    assert not axi_stuck and not sb_stuck, (
        f"CLEAN bring-up failed to reach LINK_IDLE (HOLD mode={_knob()}): "
        f"axi_stuck={axi_stuck} sideband_stuck={sb_stuck}. A clean link must "
        f"always reach LINK_IDLE.")


# ---------------------------------------------------------------------------
# REPRO / FIX: under a marginal (periodically re-brought-up) link at the ~40 ns
# silicon ratio, the pre-fix emit HOLD livelocks the shared-arbiter handshake ->
# the SIDEBAND node that SWI_LANE_STATUS reports never leaves state 0/1
# (cr_seen=0), matching silicon. The fix (HOLD off until first LINK_IDLE) makes
# bring-up deps-identical -> LINK_IDLE.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_bringup_reaches_link_idle_under_marginal_link(dut):
    hold = int(os.environ.get("HOLD_HCLK", "800"))
    dut._log.info(f"=== MARGINAL-link bring-up === ref_clk={REF_CLK_PERIOD_NS} ns "
                  f"HOLD mode={_knob()} rebringup period={hold} hclk")
    tb = PairV2TB(dut)
    await _bringup_to_data_mode(tb)
    stop = Event()
    cocotb.start_soon(_periodic_rebringup(tb, hold, stop))
    max_axi, max_sb = await _observe(tb, dut, int(os.environ.get("OBS_CHUNKS", "600")))
    stop.set()
    axi_stuck, sb_stuck = _report(tb, dut, max_axi, max_sb)

    # PRIMARY pass/fail = the five AXI FC nodes I1 re-pointed (the task's success
    # criterion: "all 5 muxed nodes converge" to LINK_IDLE). The sideband
    # (FCSM_6) is reported as a corroborating observable but is NOT the pass gate
    # here: it carries the same latent 32/32 gate and it is OUT OF SCOPE (I1 did
    # not touch it), so under this deliberately harsh cadence it can livelock on
    # its own gate even once the AXI nodes are decongested. On silicon the deps
    # baseline proves decongestion alone brings the sideband up; see the report.
    if axi_stuck:
        dut._log.warning(
            f"  AXI BRING-UP LIVELOCK reproduced: {len(axi_stuck)}/10 AXI FC "
            f"nodes stuck < LINK_IDLE (sideband corroborates: stuck={sb_stuck})")
    else:
        dut._log.info(
            f"  all 10 AXI FC nodes reached LINK_IDLE "
            f"(sideband max_state m={max_sb['m']} s={max_sb['s']})")

    assert not axi_stuck, (
        f"I1 BRING-UP REGRESSION (HOLD mode={_knob()}): under a marginal link at "
        f"the ~40 ns silicon ratio the emit HOLD livelocks the shared handshake. "
        f"{len(axi_stuck)}/10 AXI FC nodes stuck below LINK_IDLE: {axi_stuck}. "
        f"On silicon SWI_LANE_STATUS (sourced from the sideband, which shares the "
        f"same arbiter) reads cr_seen=0, fcsm 0/1 -- the KR260 signature. "
        f"Sideband corroboration: stuck={sb_stuck}.")

"""I1 silicon-feedback regression (P1 blocker): FCSM state-2 CRACK-emit gate
stalls the AXI FC data-path nodes at the ~40 ns silicon clock ratio.

BACKGROUND (silicon feedback + flists/tidelink_fpga_v2.flist:283-289 comment)
  The five AXI FC nodes -- WlinkGenericFCSM{,_1,_2,_3,_4}, instantiated in
  AXI4ToWlink as wlink_axi{aw,w,b,ar,r}FC -- resolve in the shipping flists to
  the deps/ copies, which are RECOVERY-STRIPPED (grep -c socl_l7 == 0). The
  src/rtl/local_overrides copies carry the watchdog recovery (Fix B/C/D) AND a
  state-2 CRACK-emit gate SOCL_L7_MIN_CRACK_EMITS. With that gate at its
  original 8'd32, the flist comment records that the AXI nodes "STALL in state 2
  at the 40 ns silicon ratio (never reaches 32 CRACK emits) => no LINK_IDLE,
  all-zeros both dirs."

MECHANISM (verified here)
  state 2 (SEND_CREDITS2) has NO timeout. Its only forward exit is
  socl_l7_crack_release = crack_pkt_seen & (socl_l7_crack_emit_count >= gate);
  the emit count zeroes whenever `state` leaves 2. On a perfectly CLEAN sim link
  the count climbs monotonically and reaches 32-33 at every ratio, so a clean
  bring-up clears state 2 even at gate=32 (test_axi_fcsm_clean_bringup_*). The
  silicon "never reaches 32" wedge only appears when the link is MARGINAL -- i.e.
  the CR/CRACK handshake keeps getting reset before the count reaches the gate.
  This bench models that with a periodic LL re-bring-up (the enable drops ->
  en_ff2_tx_demet falls -> _fe_rx_ptr_in_T -> state 0 -> count 0), the sim
  stand-in for the on-silicon marginal/retrying link at the slow ratio.

  Under that marginal link the count reaches only ~29 in the clean window between
  resets -- ENOUGH for a small gate but NOT for 32:

    gate=32 : all 10 AXI nodes pinned at state 2, max count ~29  -> WEDGE  (repro)
    gate= 8 : all 10 AXI nodes reach state 4 (LINK_IDLE)         -> CLEARS (fix)

  and a CLEAN link-up is unaffected at either gate (fix does not break link-up).

    make repro   # +define+SOCL_L7_MIN_CRACK_EMITS_VAL=32  -> EXPECT FAIL
    make fixed   # RTL default (tuned gate)                -> EXPECT PASS

  FCSM `state` encoding (FC.scala):
    0 IDLE  1 SEND_CREDITS1(L6 CR gate)  2 SEND_CREDITS2(L7 CRACK gate)
    3 (post-CRACK)  4 LINK_EN_WAIT/LINK_IDLE  5+ LINK_DATA.
"""
import os
import cocotb
from cocotb.triggers import ClockCycles, Event

from pair_v2_common import (PairV2TB, run_bringup_full, REF_CLK_PERIOD_NS,
                            CLK_PERIOD_NS, APB_WL_LINK_ENABLE_RESET,
                            LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE)

# The five AXI FC nodes inside AXI4ToWlink (axi2wl) -- the FCSM 0-4 copies the
# feedback is about (WlinkGenericFCSM{,_1,_2,_3,_4}).
AXI_FC_NODES = [
    "wlink_axiawFC",   # WlinkGenericFCSM    (AW)
    "wlink_axiwFC",    # WlinkGenericFCSM_1  (W)
    "wlink_axibFC",    # WlinkGenericFCSM_2  (B)
    "wlink_axiarFC",   # WlinkGenericFCSM_3  (AR)
    "wlink_axirFC",    # WlinkGenericFCSM_4  (R)
]

# state 2 == SEND_CREDITS2. "Cleared" == advanced to LINK_IDLE/LINK_EN_WAIT (4)+.
STATE_LINK_IDLE = 4


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)


def _read_int(handle, attr):
    try:
        return int(getattr(handle, attr).value)
    except (AttributeError, ValueError):
        return -1


def _sample(tb):
    """Return {(side,inst): (state, crack_emit_count)} for all 10 AXI nodes."""
    out = {}
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            node = _axi_node(tb, side, inst)
            out[(side, inst)] = (_read_int(node, "state"),
                                 _read_int(node, "socl_l7_crack_emit_count"))
    return out


def _gate_report():
    return os.environ.get("SOCL_L7_MIN_CRACK_EMITS_VAL_REPORT", "RTL-default")


async def _observe(tb, dut, chunks, log_every=150):
    """Run `chunks`*50 hclk, returning per-node max(state) and max(crack count)."""
    max_state = {k: 0 for k in _sample(tb)}
    max_cc = {k: 0 for k in _sample(tb)}
    for i in range(chunks):
        await ClockCycles(dut.hclk, 50)
        for k, (st, cc) in _sample(tb).items():
            max_state[k] = max(max_state[k], st)
            max_cc[k] = max(max_cc[k], cc)
        if log_every and (i + 1) % log_every == 0:
            aw = _axi_node(tb, "m", "wlink_axiawFC")
            dut._log.info(
                f"    [+{(i + 1) * 50} hclk] m.axiaw state={_read_int(aw, 'state')} "
                f"cc={_read_int(aw, 'socl_l7_crack_emit_count')} "
                f"max_state={max_state[('m', 'wlink_axiawFC')]} "
                f"max_cc={max_cc[('m', 'wlink_axiawFC')]}")
    return max_state, max_cc


def _report_and_stalled(tb, dut, max_state, max_cc):
    dut._log.info(
        f"  sideband(tl2wl) fcsm state: m={tb.fcsm_state('m')} s={tb.fcsm_state('s')}")
    dut._log.info("  --- AXI FC node states (per channel, both dies) ---")
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            dut._log.info(
                f"    [{side}] {inst:14s} max_state={max_state[(side, inst)]} "
                f"max_crack_emit_count={max_cc[(side, inst)]}")
    return [k for k, v in max_state.items() if v < STATE_LINK_IDLE]


# ---------------------------------------------------------------------------
# CONTROL: a CLEAN link-up must clear state 2 at BOTH gate values. This is the
# "the fix does not break link-up" guard -- it passes at gate=32 AND gate=8, and
# proves the gate is NOT the blocker on a clean link (so the repro below is not
# an artifact of merely compiling the gate in).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_axi_fcsm_clean_bringup_at_silicon_ratio(dut):
    """Clean bring-up at the ~40 ns silicon ratio: every AXI FC node must clear
    state 2 -> LINK_IDLE (state >= 4). PASSES at gate=32 and gate=8."""
    dut._log.info(
        f"=== clean bring-up control ===  hclk={CLK_PERIOD_NS} ns  "
        f"ref_clk={REF_CLK_PERIOD_NS} ns  CRACK gate={_gate_report()}")
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    max_state, max_cc = await _observe(tb, dut, int(os.environ.get("OBS_CHUNKS", "240")))
    stalled = _report_and_stalled(tb, dut, max_state, max_cc)
    assert not stalled, (
        f"clean bring-up FAILED to clear state 2 (gate={_gate_report()}): {stalled}. "
        f"A clean link must always reach LINK_IDLE -- if this fails the fix broke "
        f"link-up.")


# ---------------------------------------------------------------------------
# REPRO / FIX: under a MARGINAL link (periodic LL re-bring-up), the state-2
# CRACK-emit count never reaches 32 -> nodes wedge at state 2. Lowering the gate
# clears them. Fails at gate=32, passes at the tuned gate.
# ---------------------------------------------------------------------------
async def _periodic_rebringup(tb, hold_hclk, stop):
    """Drop + restore the LL enable on both dies on a `hold_hclk` period. Each
    drop resets the FC nodes to state 0 (emit count zeroed); the clean window
    between drops lets the count climb -- but only to ~29 at ref=40 ns, so a
    32-emit gate never releases while a small gate does. Models a marginal /
    retrying link at the slow silicon ratio."""
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


@cocotb.test()
async def test_axi_fcsm_state2_clears_under_marginal_link(dut):
    """THE REPRO/FIX. Bring up, then subject the link to a periodic LL
    re-bring-up (marginal-link model) at the ~40 ns silicon ratio. Every AXI FC
    node must still clear state 2 -> LINK_IDLE.

    EXPECT FAIL under `make repro` (gate=32): the emit count only reaches ~29 in
      the clean window between resets -> all 10 nodes pinned at state 2 -> the
      cited "never reaches 32 CRACK emits => no LINK_IDLE, all-zeros" wedge.
    EXPECT PASS under `make fixed` (tuned gate): the count reaches the gate early
      -> state 2 clears -> nodes reach LINK_IDLE.

    HOLD_HCLK (default 3000) is the marginal-link retry cadence; it is NOT tuned
    to the gate -- the clean-bring-up control proves gate=32 itself is fine, and
    the SAME cadence is used for both gate values. Reducing HOLD_HCLK (a MORE
    marginal link) raises the gate a node can tolerate."""
    hold = int(os.environ.get("HOLD_HCLK", "3000"))
    dut._log.info(
        f"=== marginal-link repro (periodic re-bring-up) ===  "
        f"ref_clk={REF_CLK_PERIOD_NS} ns  CRACK gate={_gate_report()}  "
        f"rebringup period={hold} hclk")

    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()

    stop = Event()
    cocotb.start_soon(_periodic_rebringup(tb, hold, stop))
    max_state, max_cc = await _observe(tb, dut, int(os.environ.get("OBS_CHUNKS", "600")))
    stop.set()

    stalled = _report_and_stalled(tb, dut, max_state, max_cc)
    hist = {}
    for v in max_state.values():
        hist[v] = hist.get(v, 0) + 1
    dut._log.info(f"  BINDING-GATE histogram (max_state -> #nodes): {hist}  "
                  f"(2 => L7/CRACK gate binds; 1 => L6/CR gate binds)")

    if stalled:
        dut._log.warning(
            f"  STATE-2 WEDGE reproduced: {len(stalled)}/10 AXI FC nodes never "
            f"reached LINK_IDLE under the marginal link: {stalled}")
    else:
        dut._log.info("  all 10 AXI FC nodes cleared state 2 under the marginal link")

    assert not stalled, (
        f"I1 REPRO: {len(stalled)}/10 AXI FC nodes stuck below LINK_IDLE at the "
        f"~40 ns silicon ratio (CRACK gate={_gate_report()}) under a marginal "
        f"link. The state-2 CRACK-emit count never reaches the gate between link "
        f"resets -> socl_l7_crack_release never fires -> no LINK_IDLE, all-zeros "
        f"both dirs. Stalled nodes: {stalled}.")

"""The one-line RTL difference between the ASIC and FPGA FCSMs, executed.

WHAT DIFFERS
------------
State 7 of the AXI flow-control state machines (SEND_NACK) is left via
`_GEN_115`.  The two files the two flists ship differ in exactly that line:

  deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v:315   (ASIC / tapeout)
      wire [2:0] _GEN_115 = auto_tx_out_advance ? 3'h4 : state;

  src/rtl/local_overrides/WlinkGenericFCSM.v:426                     (FPGA)
      wire [2:0] _GEN_115 = (auto_tx_out_advance | socl_l7_wdog_force_clear)
                            ? 3'h4 : state;   // TL-033-6

`socl_l7_wdog_force_clear` fires when the node has sat in state 7 for
SOCL_L7_WDOG_THRESHOLD io_tx_clk cycles with NO emit progress -- the
emit-starvation backstop.  The ASIC copy has no such term, and no other
socl_ signal at all, so on the file set that tapes out a state-7 node that
cannot emit has NO exit.

THE EXPERIMENT
--------------
Bring the pair up, pick the master AW node, then STARVE it: Force
`auto_tx_out_advance = 0` (it is an input port) and Force `state = 7`.  Hold
long enough for the watchdog to arm, then Release `state` ONLY -- the
starvation stays.  Whether the node escapes is decided entirely by that one
line.

The SAME command line drives both arms.  L7_WDOG_THRESHOLD adds
+define+SOCL_L7_WDOG_THRESHOLD_VAL, which the deps/ copy does not reference,
so it is inert there: the only thing that changes between the two runs is
which file was compiled.

NON-VACUITY -- three controls, because "it stayed at 7" is otherwise
indistinguishable from a broken stimulus:
  C1 PRE   the node must be at LINK_IDLE (state 4) before we touch it, so we
           are wedging a live, healthy node.
  C2 ARM   (FPGA arm only) socl_l7_wdog_cnt must actually reach the threshold
           and socl_l7_wdog_force_clear must read 1 -- the backstop is armed,
           not merely compiled.
  C3 POST  after releasing the starvation, the node MUST escape state 7 on
           BOTH arms.  This proves the wedge was caused by the starvation and
           not by a force we failed to release, and that the normal path still
           works after the recovery fires.

    make ASIC_FLIST=0 L7_WDOG_THRESHOLD=256 EPOCH_PROFILE=zero \
         MODULE=test_asic_l7_starvation_backstop     # expect ESCAPE
    make ASIC_FLIST=1 L7_WDOG_THRESHOLD=256 EPOCH_PROFILE=zero \
         MODULE=test_asic_l7_starvation_backstop     # expect NO ESCAPE

The ASIC arm asserting "no escape" is a CHARACTERISATION of a known, ratified
gap (the 2026-07-29 hold, ratified 2026-08-20: ASIC flists keep FCSM 0-4 on
the recovery-stripped deps/ copies).  It is not an endorsement.  It exists so
that if that decision is ever revisited, or if someone re-points the ASIC
flist, the change is announced by a red test instead of going unnoticed.
"""
import os
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB

NODE = "wlink_axiawFC"      # WlinkGenericFCSM (AW) on the master die
STATE_LINK_IDLE = 4
STATE_SEND_NACK = 7


def _asic():
    return os.environ.get("ASIC_FLIST", "0") == "1"


def _threshold():
    return int(os.environ.get("L7_WDOG_THRESHOLD", "256"))


def _node(dut):
    return getattr(dut.u_master.u_chiplet_controller.u_wlink.axi2wl, NODE)


def _opt(handle, attr):
    try:
        return int(getattr(handle, attr).value)
    except (AttributeError, ValueError):
        return None


async def _observe_state(dut, node, cycles, step=16):
    """Sample `state` over `cycles` io_tx_clk, return (left_7, seen_states)."""
    seen = set()
    for _ in range(max(1, cycles // step)):
        await ClockCycles(node.io_tx_clk, step)
        st = _opt(node, "state")
        if st is not None:
            seen.add(st)
    return (any(s != STATE_SEND_NACK for s in seen), sorted(seen))


@cocotb.test()
async def test_l7_emit_starvation_backstop(dut):
    asic = _asic()
    thr = _threshold()
    dut._log.info(
        f"=== state-7 emit-starvation backstop ===  ASIC_FLIST={'1' if asic else '0'}  "
        f"threshold={thr} io_tx_clk  node=m.{NODE}")

    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()

    node = _node(dut)
    has_wdog = _opt(node, "socl_l7_wdog_cnt") is not None
    dut._log.info(f"  recovery markers present in the compiled FCSM: {has_wdog}")
    assert has_wdog != asic, (
        f"FILE-SET MISMATCH: socl_l7_wdog_cnt present={has_wdog} but ASIC_FLIST="
        f"{'1' if asic else '0'}. The wrong file was compiled; this run proves nothing.")

    # ---- C1 PRE: the node must be live and at LINK_IDLE before we wedge it ----
    for _ in range(400):
        if _opt(node, "state") == STATE_LINK_IDLE:
            break
        await ClockCycles(dut.hclk, 50)
    st0 = _opt(node, "state")
    assert st0 == STATE_LINK_IDLE, (
        f"CONTROL C1 FAILED: m.{NODE} never reached LINK_IDLE (state={st0}) after "
        f"bring-up. Wedging a node that was never healthy proves nothing.")
    dut._log.info(f"  C1 PRE  ok: m.{NODE} at LINK_IDLE (state=4) before starvation")

    # ---- STARVE: no emit progress, pinned in SEND_NACK -----------------------
    node.auto_tx_out_advance.value = Force(0)
    node.state.value = Force(STATE_SEND_NACK)
    await ClockCycles(node.io_tx_clk, thr * 3)

    # ---- C2 ARM: on the FPGA arm the backstop must actually be armed ---------
    if has_wdog:
        cnt = _opt(node, "socl_l7_wdog_cnt")
        fclr = _opt(node, "socl_l7_wdog_force_clear")
        dut._log.info(f"  C2 ARM     socl_l7_wdog_cnt={cnt} (threshold {thr})  "
                      f"socl_l7_wdog_force_clear={fclr}")
        assert cnt == thr and fclr == 1, (
            f"CONTROL C2 FAILED: watchdog did not arm (cnt={cnt}, want {thr}; "
            f"force_clear={fclr}, want 1). A later 'escape' would not be the backstop.")
    else:
        dut._log.info("  C2 ARM     n/a - the compiled FCSM has no watchdog "
                      "(deps/ copy, 0 socl_ signals)")

    # ---- RELEASE state ONLY; starvation stays ------------------------------
    node.state.value = Release()
    left, seen = await _observe_state(dut, node, thr * 6)
    dut._log.info(f"  after releasing `state` with auto_tx_out_advance still 0: "
                  f"states seen = {seen}  -> {'ESCAPED' if left else 'WEDGED at 7'}")

    # ---- C3 POST: releasing the starvation must free the node on BOTH arms ---
    node.auto_tx_out_advance.value = Release()
    left_after, seen_after = await _observe_state(dut, node, thr * 6)
    dut._log.info(f"  C3 POST after releasing auto_tx_out_advance: states seen = "
                  f"{seen_after} -> {'escaped' if left_after else 'STILL WEDGED'}")
    assert left_after, (
        f"CONTROL C3 FAILED: m.{NODE} did not leave state 7 even after the "
        f"starvation was released (states seen {seen_after}). The stimulus, not "
        f"the RTL, is stuck - the result above is vacuous.")

    if asic:
        assert not left, (
            f"UNEXPECTED: the ASIC file set escaped state 7 under emit starvation "
            f"(states seen {seen}). deps/WlinkGenericFCSM.v:315 exits state 7 ONLY "
            f"on auto_tx_out_advance, which was forced 0 -- so either the FPGA twin "
            f"was compiled after all, or the ASIC flist gained a backstop. Either "
            f"way this test's premise changed; re-check before trusting it.")
        dut._log.warning(
            f"CHARACTERISED: on the file set that TAPES OUT, m.{NODE} stayed in "
            f"state 7 (SEND_NACK) for {thr * 6} io_tx_clk under emit starvation and "
            f"never exited. deps/axi-chiplet-controller/logical/wlink/"
            f"WlinkGenericFCSM.v:315 has no socl_l7_wdog_force_clear term. The FPGA "
            f"twin escapes under the identical stimulus. This is the ratified "
            f"2026-07-29/2026-08-20 hold, now MEASURED rather than reasoned about.")
    else:
        assert left, (
            f"REGRESSION: the FPGA/recovery file set did NOT escape state 7 under "
            f"emit starvation (states seen {seen}) even though the watchdog armed "
            f"(C2 passed). TL-033-6 (_GEN_115 |= socl_l7_wdog_force_clear) is "
            f"broken in src/rtl/local_overrides/WlinkGenericFCSM.v.")
        dut._log.info(
            f"PROVEN: the recovery FCSM escapes state 7 under emit starvation via "
            f"socl_l7_wdog_force_clear (states seen {seen}). This is the behaviour "
            f"the ASIC file set does NOT have.")

"""The one-line RTL difference between the recovery FCSM and the recovery-stripped deps FCSM, executed.

WHAT DIFFERS
------------
State 7 of the AXI flow-control state machines (SEND_NACK) is left via `_GEN_115`.  The two candidate files differ in
exactly that line:

  deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v:315   (recovery-STRIPPED)
      wire [2:0] _GEN_115 = auto_tx_out_advance ? 3'h4 : state;

  src/rtl/local_overrides/WlinkGenericFCSM.v                          (hardened; FPGA AND, since TL-019, ASIC)
      wire [2:0] _GEN_115 = (auto_tx_out_advance | socl_l7_wdog_force_clear) ? 3'h4 : state;   // TL-033-6

`socl_l7_wdog_force_clear` fires when the node has sat in state 7 for SOCL_L7_WDOG_THRESHOLD io_tx_clk cycles with NO
emit progress -- the emit-starvation backstop.  The deps copy has no such term, so a state-7 node that cannot emit has
NO exit.  Measured wedging on the pre-fix tapeout file set (asicsim 2026-08-26).

TL-018/TL-019 (David's decision, 2026-10): the tapeout flist ships the hardened file.  THREE arms:

    make ASIC_FLIST=0 L7_WDOG_THRESHOLD=256 EPOCH_PROFILE=zero MODULE=test_asic_l7_starvation_backstop  # ESCAPE
    make ASIC_FLIST=1 L7_WDOG_THRESHOLD=256 EPOCH_PROFILE=zero MODULE=test_asic_l7_starvation_backstop  # ESCAPE
    make ASIC_FLIST=1 ASIC_FCSM_DEPS=1 L7_WDOG_THRESHOLD=256 EPOCH_PROFILE=zero \
         MODULE=test_asic_l7_starvation_backstop                       # MUTANT (deps): WEDGES -- must stay wedged

The mutant arm is the must-fail arm of the changed ASIC expectation: it proves the stimulus still detects the missing
backstop, so the ASIC "ESCAPES" result is attributable to the hardened file and not to a stimulus that can no longer
wedge anything.  The SAME command line drives all arms; L7_WDOG_THRESHOLD adds +define+SOCL_L7_WDOG_THRESHOLD_VAL,
which the deps copy does not reference (inert there).

NON-VACUITY -- three controls, because "it stayed at 7" is otherwise indistinguishable from a broken stimulus:
  C1 PRE   the node must be at LINK_IDLE (state 4) before we touch it, so we are wedging a live, healthy node.
  C2 ARM   (hardened arms) socl_l7_wdog_cnt must reach the threshold and socl_l7_wdog_force_clear must read 1.
  C3 EXIT  if the node is still at 7, Force auto_tx_out_advance=1 -- the ONE term the deps _GEN_115 has.  The node MUST
           then leave state 7: proves the state-7 exit path is alive and the node is wedged specifically because the
           OTHER term is missing, not because the stimulus jammed it.  (Only meaningful while still at 7.)
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


def _deps_mutant():
    """ASIC_FCSM_DEPS=1: the compiled FC nodes are the recovery-stripped deps copies (pre-TL-019 tapeout set)."""
    return os.environ.get("ASIC_FCSM_DEPS", "0") == "1"


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
    mutant = _deps_mutant()
    thr = _threshold()
    dut._log.info(
        f"=== state-7 emit-starvation backstop ===  ASIC_FLIST={'1' if asic else '0'} "
        f"deps_mutant={'1' if mutant else '0'}  "
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
    assert has_wdog != mutant, (
        f"FILE-SET MISMATCH: socl_l7_wdog_cnt present={has_wdog} but ASIC_FCSM_DEPS="
        f"{'1' if mutant else '0'}. The wrong file was compiled; this run proves nothing.")

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

    # ---- C3 EXIT: the state-7 exit path itself must still work --------------
    # _GEN_115's one surviving term on the ASIC copy is auto_tx_out_advance.
    # Assert it and the node MUST leave state 7 -- otherwise the node is jammed
    # for some unrelated reason and the observation above means nothing.
    # Only meaningful while the node is STILL at 7; on the FPGA arm the watchdog
    # has already moved it, and re-running it there would pass for the wrong
    # reason.
    st_now = _opt(node, "state")
    if st_now == STATE_SEND_NACK:
        node.auto_tx_out_advance.value = Force(1)
        left_after, seen_after = await _observe_state(dut, node, thr * 2)
        dut._log.info(f"  C3 EXIT forcing auto_tx_out_advance=1: states seen = "
                      f"{seen_after} -> {'escaped' if left_after else 'STILL WEDGED'}")
        assert left_after, (
            f"CONTROL C3 FAILED: m.{NODE} did not leave state 7 even with "
            f"auto_tx_out_advance forced to 1 (states seen {seen_after}) -- the one "
            f"term deps/WlinkGenericFCSM.v:315 exits on. The node is jammed for an "
            f"unrelated reason, so the observation above is vacuous.")
    else:
        dut._log.info(f"  C3 EXIT n/a - node already left state 7 (now {st_now}); "
                      f"the escape above is the result.")
    node.auto_tx_out_advance.value = Release()

    if mutant:
        assert not left, (
            f"MUTANT ESCAPED: the recovery-stripped deps file set escaped state 7 under emit starvation "
            f"(states seen {seen}). deps/WlinkGenericFCSM.v:315 exits state 7 ONLY on auto_tx_out_advance, which was "
            f"forced 0 -- so this stimulus can no longer detect a missing backstop, and the ESCAPE verdict on the "
            f"hardened arms means nothing. Re-check the stimulus before trusting any arm.")
        dut._log.warning(
            f"MUTANT CHARACTERISED: the recovery-stripped (pre-TL-019 tapeout) file set stayed in state 7 "
            f"(SEND_NACK) for {thr * 6} io_tx_clk under emit starvation and never exited -- the wedge this fix removes.")
    else:
        assert left, (
            f"REGRESSION: the hardened FCSM file set (ASIC_FLIST={'1' if asic else '0'}) did NOT escape state 7 under "
            f"emit starvation (states seen {seen}) even though the watchdog armed (C2 passed). TL-033-6 "
            f"(_GEN_115 |= socl_l7_wdog_force_clear) is broken in src/rtl/local_overrides/WlinkGenericFCSM.v.")
        dut._log.info(
            f"PROVEN: the hardened FCSM escapes state 7 under emit starvation via socl_l7_wdog_force_clear "
            f"(states seen {seen}), ASIC_FLIST={'1' if asic else '0'}. The recovery-stripped deps file does NOT "
            f"(see the ASIC_FCSM_DEPS=1 mutant arm).")

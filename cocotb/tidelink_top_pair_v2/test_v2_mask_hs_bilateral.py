"""SIM REPRODUCTION of the KR260 kr260-pair-onchip SLAVE-SIDE SHAM MASK GATE.

Hardware observation (kr260-pair-onchip, 2026-07-23), APB OBS_MASK_HS @ 0x2194:

    MASTER (inst0) : 0x0019E4E4  -> [19] mask_hs_match=1  [20] gate_open=1
                                    [16] autoneg local match=1
                                    low16 peer mask = 0xE4E4  (CAPTURED)
    SLAVE  (inst1) : 0x00100000  -> [19] mask_hs_match=0  [20] gate_open=1
                                    [16] autoneg local match=0
                                    low16 peer mask = 0x0000  (NOTHING CAPTURED)

i.e. the slave's gate is open ONLY because a bypass/debug strap forces it. The
peer-mask handshake is a SHAM on the slave side.

WHAT THIS FILE DOES
-------------------
Brings the V2 pair up on the AUTONOMOUS path (BYPASS_AUTONEG=0: tb_top forces
nego_cfg_reg=7'h61 / nego_train_cfg_r at time 0, which is what makes the autoneg
FSM actually walk POLL -> MASK_RD_ADDR -> MASK_RD_DATA -> MASK_RES_TX, exactly
as it does on the KR260 build) and then reads OBS_MASK_HS on BOTH dies through
the same APB window the host uses, plus the hierarchical internals that say
WHERE the slave stalls.

    test_00_mask_hs_bilateral_report   — measurement + the honest bilateral
                                         assertion. RED == defect reproduced.
    test_01_slave_stall_point          — diagnostic: proves WHICH signal is
                                         structurally stuck at 0 on the slave.

RUN
---
    source ./set_env.sh && export TIDELINK_PHY_V2=1
    cd cocotb/tidelink_top_pair_v2
    rm -rf sim_build_zero_auto
    make EPOCH_PROFILE=zero BYPASS_AUTONEG=0 MODULE=test_v2_mask_hs_bilateral
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB

APB_OBS_MASK_HS = 0x2194
APB_STATUS      = 0x2108

OBS_PEER_TX = lambda v: (v >> 0) & 0xFF
OBS_PEER_RX = lambda v: (v >> 8) & 0xFF
OBS_LOCAL_MATCH = lambda v: (v >> 16) & 0x1   # autoneg.mask_hs_local_match_r
OBS_LOCAL_FAIL  = lambda v: (v >> 17) & 0x1
OBS_LOCK_PEND   = lambda v: (v >> 18) & 0x1
OBS_MATCH       = lambda v: (v >> 19) & 0x1   # controller.mask_hs_match
OBS_GATE        = lambda v: (v >> 20) & 0x1   # controller.mask_hs_gate_open
OBS_WLINK_HS    = lambda v: (v >> 21) & 0x3   # controller.wlink_mask_hs_result

STATE_NAMES = {
    0: "IDLE", 1: "NEGO_INIT", 2: "NEGO_WAIT", 3: "NEGO_CLAIM", 4: "NEGO_POLL",
    5: "NEGO_DONE", 6: "BYPASS", 7: "ERROR", 8: "MASK_RES_TX",
    9: "MASK_RD_ADDR", 10: "MASK_RD_DATA", 11: "NEGO_DONE_PRE",
    12: "TRAIN_ENTER", 13: "TRAIN_RUN", 14: "TRAIN_POLL_PEER",
    15: "TRAIN_EXIT", 16: "TRAIN_DONE", 17: "TRAIN_FAIL",
    18: "FIN_RDV", 19: "FIN_GO",
}


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _ctrl(tb, side):
    return tb.top(side).u_chiplet_controller


def _an(tb, side):
    return _ctrl(tb, side).u_autoneg


def _autoneg_state(tb, side):
    s = _si(_an(tb, side).state_r)
    return s, STATE_NAMES.get(s, f"?{s}")


async def _bringup_autonomous(tb, budget=4_000_000):
    """POR -> autoneg (zero APB writes) -> role_lock on both dies."""
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    locked = await tb.wait_role_locked(max_cycles=budget)
    return locked


def _snapshot(tb, side):
    ms, mn = _autoneg_state(tb, side)
    return {
        "state": ms,
        "state_name": mn,
        "an_local_match": _si(_an(tb, side).mask_hs_local_match_r),
        "an_local_fail": _si(_an(tb, side).mask_hs_local_fail_r),
        "an_peer_tx": _si(_an(tb, side).peer_tx_lane_mask_r),
        "an_peer_rx": _si(_an(tb, side).peer_rx_lane_mask_r),
        "ctrl_match": _si(_ctrl(tb, side).mask_hs_match),
        "ctrl_gate": _si(_ctrl(tb, side).mask_hs_gate_open),
        "wlink_hs": _si(_ctrl(tb, side).wlink_mask_hs_result),
        "role_locked": _si(getattr(tb.dut, f"{'m' if side == 'm' else 's'}_role_locked")),
    }


def _log_snapshot(tb, side, snap, obs):
    tb.log.info(
        f"  [{'MASTER' if side == 'm' else 'SLAVE '}] "
        f"OBS_MASK_HS=0x{obs:08x}  "
        f"[19]match={OBS_MATCH(obs)} [20]gate={OBS_GATE(obs)} "
        f"[16]an_match={OBS_LOCAL_MATCH(obs)} [17]an_fail={OBS_LOCAL_FAIL(obs)} "
        f"[22:21]wlink_hs={OBS_WLINK_HS(obs)} "
        f"low16=0x{obs & 0xFFFF:04x} "
        f"(peer_rx=0x{OBS_PEER_RX(obs):02x} peer_tx=0x{OBS_PEER_TX(obs):02x})")
    tb.log.info(
        f"          hier: autoneg_state={snap['state']}({snap['state_name']}) "
        f"local_match={snap['an_local_match']} local_fail={snap['an_local_fail']} "
        f"peer_tx=0x{max(snap['an_peer_tx'], 0):02x} "
        f"peer_rx=0x{max(snap['an_peer_rx'], 0):02x} "
        f"wlink_mask_hs_result={snap['wlink_hs']} "
        f"role_locked={snap['role_locked']}")


# ===========================================================================
# test_00 — the measurement + the honest bilateral requirement.
# ===========================================================================
@cocotb.test()
async def test_00_mask_hs_bilateral_report(dut):
    """Read OBS_MASK_HS on BOTH dies after an autonomous bring-up.

    A genuine bilateral peer-mask handshake requires mask_hs_match==1 on BOTH
    dies. RED here == the KR260 slave-side sham gate reproduced in sim."""
    if os.environ.get("BYPASS_AUTONEG", "1") != "0":
        dut._log.warning(
            "BYPASS_AUTONEG != 0 — the autoneg FSM parks in ST_BYPASS and NO die "
            "runs the mask handshake. Re-run with BYPASS_AUTONEG=0 for a "
            "meaningful result.")

    tb = PairV2TB(dut)
    locked = await _bringup_autonomous(tb)
    # Let the master's post-lock states (MASK_RES_TX -> DONE_PRE -> TRAIN_*)
    # run out; the handshake latch is sticky, so extra dwell can only help.
    await ClockCycles(dut.hclk, 200_000)

    # Q2 (F3 regression risk): with the nego_lost_w "trust the winner" free pass
    # retired, a slave whose verdict never arrives can NEVER role_lock -> Wlink
    # held in reset -> link dead. Poll for bilateral FCSM=LINK_IDLE(4).
    fcsm_ok = False
    for _ in range(400):
        if tb.fcsm_state("m") == 4 and tb.fcsm_state("s") == 4:
            fcsm_ok = True
            break
        await ClockCycles(dut.hclk, 2000)

    dut._log.info("=" * 78)
    dut._log.info(f"OBS_MASK_HS bilateral snapshot (role_locked both = {locked}, "
                  f"fcsm=4 both = {fcsm_ok}; m_fcsm={tb.fcsm_state('m')} "
                  f"s_fcsm={tb.fcsm_state('s')}; "
                  f"m_role_locked={_si(dut.m_role_locked)} "
                  f"s_role_locked={_si(dut.s_role_locked)})")
    dut._log.info("=" * 78)

    obs = {}
    snaps = {}
    for side in ("m", "s"):
        snaps[side] = _snapshot(tb, side)
        try:
            obs[side] = await tb.apb(side).read(APB_OBS_MASK_HS, timeout=4000)
        except TimeoutError:
            dut._log.error(f"[{side}] APB read of OBS_MASK_HS WEDGED")
            obs[side] = None
        if obs[side] is not None:
            _log_snapshot(tb, side, snaps[side], obs[side])
        else:
            dut._log.info(f"  [{side}] hier-only: {snaps[side]}")

    dut._log.info("=" * 78)
    dut._log.info("HW reference (kr260-pair-onchip): MASTER=0x0019E4E4 SLAVE=0x00100000")
    dut._log.info("=" * 78)

    assert locked, (
        "BLOCKING: role_lock never latched on both dies.\n"
        "  m_role_locked=%d s_role_locked=%d  m_fcsm=%d s_fcsm=%d\n"
        "  master: match=%d gate=%d an_match=%d state=%s\n"
        "  slave : match=%d gate=%d an_match=%d state=%s\n"
        "  If the slave is the one stuck, this is the F3 regression: retiring "
        "the nego_lost_w 'trust the winner' free pass means a slave whose "
        "verdict never arrives can NEVER lock -> Wlink held in reset -> LINK "
        "DEAD." % (
            snaps["m"]["role_locked"], snaps["s"]["role_locked"],
            tb.fcsm_state("m"), tb.fcsm_state("s"),
            snaps["m"]["ctrl_match"], snaps["m"]["ctrl_gate"],
            snaps["m"]["an_local_match"], snaps["m"]["state_name"],
            snaps["s"]["ctrl_match"], snaps["s"]["ctrl_gate"],
            snaps["s"]["an_local_match"], snaps["s"]["state_name"]))
    assert fcsm_ok, (
        "BLOCKING: role_lock latched but the pair never reached bilateral "
        "FCSM=LINK_IDLE(4): m_fcsm=%d s_fcsm=%d" % (
            tb.fcsm_state("m"), tb.fcsm_state("s")))

    # ---- the honest requirement: BOTH dies genuinely matched ----------------
    bad = [s for s in ("m", "s") if snaps[s]["ctrl_match"] != 1]
    assert not bad, (
        "SLAVE-SIDE SHAM MASK GATE REPRODUCED IN SIM.\n"
        "  mask_hs_match must be 1 on BOTH dies for a genuine bilateral peer-mask "
        "handshake; it is 0 on: %s\n"
        "  master: OBS_MASK_HS=%s ctrl_match=%d gate=%d an_local_match=%d "
        "peer_tx=0x%02x peer_rx=0x%02x wlink_hs=%d state=%s\n"
        "  slave : OBS_MASK_HS=%s ctrl_match=%d gate=%d an_local_match=%d "
        "peer_tx=0x%02x peer_rx=0x%02x wlink_hs=%d state=%s\n"
        "  A gate_open==1 with match==0 means the gate was opened by "
        "mask_hs_bypass_i / apb_debug_unlock_i (axi_chiplet_controller.sv:687), "
        "NOT by the handshake." % (
            ",".join(bad),
            ("0x%08x" % obs["m"]) if obs["m"] is not None else "WEDGED",
            snaps["m"]["ctrl_match"], snaps["m"]["ctrl_gate"],
            snaps["m"]["an_local_match"], max(snaps["m"]["an_peer_tx"], 0),
            max(snaps["m"]["an_peer_rx"], 0), snaps["m"]["wlink_hs"],
            snaps["m"]["state_name"],
            ("0x%08x" % obs["s"]) if obs["s"] is not None else "WEDGED",
            snaps["s"]["ctrl_match"], snaps["s"]["ctrl_gate"],
            snaps["s"]["an_local_match"], max(snaps["s"]["an_peer_tx"], 0),
            max(snaps["s"]["an_peer_rx"], 0), snaps["s"]["wlink_hs"],
            snaps["s"]["state_name"]))

    dut._log.info("Bilateral handshake GENUINE on both dies.")


# ===========================================================================
# test_01 — diagnostic: WHERE does the slave stall?
# ===========================================================================
@cocotb.test()
async def test_01_wlink_verdict_sniffer_present(dut):
    """STATIC structural probe — no reset, no bring-up (a second tb.reset() in
    the same simv cannot re-negotiate: tb_top releases its BYPASS_AUTONEG=0
    force at 5 ms, so a later POR parks both FSMs in ST_BYPASS).

    The slave's ONLY non-autoneg gate-opener is wlink_mask_hs_result[0], driven
    by Wlink.mask_hs_result_o. Two Wlink sources exist in the tree:

      src/rtl/local_overrides/Wlink.v:433   assign mask_hs_result_o = 2'b00;
          -> DEAD STUB. This is what every flist compiles.
      deps/axi-chiplet-controller/logical/wlink/Wlink.v:212-238
          -> real 0x21C verdict sniffer (hs_result_match_q / hs_result_fail_q),
             added 2026-05-18 (743821b, SHORTCOMINGS-14a/14b). Compiled by
             NOTHING.

    hs_result_match_q exists ONLY in the fixed version, so its absence in the
    elaborated hierarchy proves which Wlink is in the build."""
    tb = PairV2TB(dut)
    sniffer = {}
    for side in ("m", "s"):
        sniffer[side] = hasattr(_ctrl(tb, side).u_wlink, "hs_result_match_q")

    dut._log.info("-" * 78)
    dut._log.info("WLINK 0x21C VERDICT-SNIFFER STRUCTURAL PROBE")
    dut._log.info(f"  master u_wlink.hs_result_match_q present : {sniffer['m']}")
    dut._log.info(f"  slave  u_wlink.hs_result_match_q present : {sniffer['s']}")
    dut._log.info("  STRAP POSTURE AS SEEN *AT THE CONTROLLER* "
                  "(what actually gates, post tidelink_top.sv:2341/2342 ties):")
    for side in ("m", "s"):
        c = _ctrl(tb, side)
        dut._log.info(
            f"    [{side}] apb_debug_unlock_i={_si(c.apb_debug_unlock_i)} "
            f"mask_hs_bypass_i={_si(c.mask_hs_bypass_i)}  "
            f"(0/0 == honest: gate can ONLY open via a real mask_hs_match)")
    dut._log.info("-" * 78)

    if not sniffer["s"]:
        dut._log.error(
            "DEAD STUB CONFIRMED IN THE ELABORATED DESIGN: the compiled Wlink "
            "has no 0x21C verdict sniffer, so mask_hs_result_o is hardwired "
            "2'b00 and wlink_mask_hs_result can NEVER be non-zero on either "
            "die. Combined with the MASTER-ONLY MASK_RES_TX states "
            "(tidelink_autoneg.sv:248-251), the slave has ZERO hardware paths "
            "to a genuine mask_hs_match.")
    else:
        dut._log.info(
            "Fixed Wlink is in the build — the 0x21C verdict sniffer exists.")

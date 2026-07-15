"""test_zeropoke_por — TRUE zero-poke autonomous bring-up from the POR parameter.

The mandated deliverable: the hardware self-negotiates from power-on with NO host
writes. Every prior "zero-poke" sim actually armed autonomy one of two ways:

  * an APB write of NEGO_CFG=0x61 + NEGO_TRAIN_CFG=0x1 (a host poke), or
  * the tb `force` block (BYPASS_AUTONEG=0), which drives nego_cfg_reg=7'h61 /
    nego_train_cfg_r=16'h00F1 at time 0 and releases them after reset — a
    stand-in for the parameter the tb header itself calls "a future
    NEGO_CFG_RESET strap" (tb_top.sv:725-726).

This test removes BOTH crutches. It runs with BYPASS_AUTONEG=1 (the force block is
a dead branch) and arms the autonomy chain ONLY from the reset value of
nego_cfg_reg, which is the tidelink_top parameter NEGO_CFG_RESET. In sim that
parameter is set via the tb (compile-time +define+TB_TOP_NEGO_CFG_RESET); in the
FPGA image it is set by tidelink_vivado_wrapper's parameter default (captured
into the packaged IP's component.xml → OOC synth). Same parameter, same POR value.

Fail-first contract (run it BOTH ways — a test that only passes proves nothing)
-------------------------------------------------------------------------------
  * DEFAULT build (NEGO_CFG_RESET=7'h00, the value EVERY bitstream ever built
    used): nego_cfg_reg PORs to 0 → nego_en=0 → autonomy_armed is gated off
    forever. The test FAILS at the nego_en precondition (the exact root cause),
    and — had it proceeded — the link would never reach cal/fcsm.
  * FIXED build (NEGO_CFG_RESET=7'h61): nego_en=1 from POR, role auto-locks
    (nego_force_lock), train_auto_en=1 (NEGO_TRAIN_CFG POR 0x0001), the link
    comes up bilaterally (cal=1, fcsm=4) with ZERO writes to NEGO_CFG /
    NEGO_TRAIN_CFG on either die.

7'h61 = nego_en[0] | nego_force_lock[5] | mask_hs_auto_en[6].

The sim-model knobs (short cal hold/dwell, winscan/fch dwell, flat-eye
obs_sync_dist=0) are IDENTICAL to test_31 — pure timing/eye accommodations so the
run is bounded in RTL sim; NONE of them is an APB write and NONE touches
NEGO_CFG/NEGO_TRAIN_CFG. The arming is the POR parameter and nothing else.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    export CMSDK_FPGA_SRAM_V="$CMSDK_DIR/logical/models/memories/cmsdk_fpga_sram.v"

    # PASS (fixed default):
    TIDELINK_PHY_V2=1 TB_TOP_NO_DUMP=1 \
      COMPILE_ARGS+="+define+TB_TOP_SHORT_CAL_HOLD=64 +define+TB_TOP_SHORT_CAL_DWELL=8 +define+TB_TOP_NEGO_CFG_RESET=7'h61" \
      SIM=vcs MODULE=test_zeropoke_por SIM_BUILD=sim_build_zpk_61 \
      make MODULE=test_zeropoke_por

    # FAIL (current default 7'h00 — omit the NEGO_CFG_RESET define):
    TIDELINK_PHY_V2=1 TB_TOP_NO_DUMP=1 \
      COMPILE_ARGS+="+define+TB_TOP_SHORT_CAL_HOLD=64 +define+TB_TOP_SHORT_CAL_DWELL=8" \
      SIM=vcs MODULE=test_zeropoke_por SIM_BUILD=sim_build_zpk_00 \
      make MODULE=test_zeropoke_por
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

from test_tidelink_pair_doorbell import PairTB

CLK_PERIOD_NS = 20.0

# Calibrator state encoding (deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv)
CAL_S_DONE = 4
CAL_S_HOLD = 6
CAL_NAMES = {0: "S_IDLE", 1: "S_ARM", 2: "S_SWEEP", 3: "S_FINISH", 4: "S_DONE",
             5: "S_CANCEL", 6: "S_HOLD", 7: "S_PROBE", 8: "S_FINALIZE",
             9: "S_VALIDATE"}

FCSM_DATA = 4   # tidelink framer FCSM data-mode state

# The tb force block (BYPASS_AUTONEG=0) would drive nego_train_cfg_r=16'h00F1;
# the genuine POR value is 16'h0001. Observing 0x0001 PROVES the force never ran.
NEGO_TRAIN_CFG_POR = 0x0001


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _ctrl(dut, side):
    return _top(dut, side).u_chiplet_controller


def _cal(dut, side):
    return _ctrl(dut, side).u_calibrator


def _fcsm(dut, side):
    return _ctrl(dut, side).u_wlink.tl2wl.wlink_tidelinktl


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


async def _idle_stimulus(dut):
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value    = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value  = 0
        getattr(dut, f"{prefix}_apb_paddr").value   = 0
        getattr(dut, f"{prefix}_apb_pwdata").value  = 0
        getattr(dut, f"{prefix}_apb_pstrb").value   = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value   = 0
        for port in ("tx", "fifo"):
            getattr(dut, f"{prefix}_ahb_{port}_hsel").value      = 0
            getattr(dut, f"{prefix}_ahb_{port}_haddr").value     = 0
            getattr(dut, f"{prefix}_ahb_{port}_htrans").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hsize").value     = 2
            getattr(dut, f"{prefix}_ahb_{port}_hwrite").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hwdata").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hready_in").value = 1


async def _reset(dut):
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)


@cocotb.test()
async def test_zeropoke_por(dut):
    log = dut._log
    log.info("ZERO-POKE POR bring-up: autonomy armed by NEGO_CFG_RESET alone "
             "(no APB write, no tb force)")

    tb = PairTB(dut)
    await _idle_stimulus(dut)
    await _reset(dut)

    # ---- (0) Prove NO tb force path is compiled in ---------------------------
    # BYPASS_AUTONEG must be 1 (the force block at tb_top.sv:768 is a dead
    # branch). If the parameter is not introspectable in this simulator, the
    # nego_train_cfg_r==0x0001 check below is the authoritative "no force" proof
    # (the force drives 0x00F1).
    bypass = _si(getattr(dut, "BYPASS_AUTONEG", None))
    if bypass != -1:
        assert bypass == 1, (
            f"BYPASS_AUTONEG={bypass} — this test MUST run with the tb force "
            f"block disabled (BYPASS_AUTONEG=1); arming must come from the POR "
            f"parameter, not a tb `force`.")
    for side in ("m", "s"):
        fq = _si(_cal(dut, side).tb_early_exit_force_q)
        assert fq == 0, (f"[{side}] tb_early_exit_force_q={fq} — a calibrator "
                         f"bypass force is engaged; this test must be de-forced.")

    # ---- (1) POR arming values — the crux -----------------------------------
    m_cfg = _si(_ctrl(dut, "m").nego_cfg_reg)
    s_cfg = _si(_ctrl(dut, "s").nego_cfg_reg)
    m_trn = _si(_ctrl(dut, "m").nego_train_cfg_r)
    s_trn = _si(_ctrl(dut, "s").nego_train_cfg_r)
    log.info(f"POST-RESET (no writes issued): "
             f"M nego_cfg_reg=0x{m_cfg:02x} nego_train_cfg_r=0x{m_trn:04x} | "
             f"S nego_cfg_reg=0x{s_cfg:02x} nego_train_cfg_r=0x{s_trn:04x}")

    # nego_train_cfg_r must be the genuine POR (0x0001), NOT the force's 0x00F1.
    assert m_trn == NEGO_TRAIN_CFG_POR and s_trn == NEGO_TRAIN_CFG_POR, (
        f"nego_train_cfg_r POR = M:0x{m_trn:04x} S:0x{s_trn:04x} — expected "
        f"0x{NEGO_TRAIN_CFG_POR:04x}. 0x00F1 would mean the tb force ran; any "
        f"other value means NEGO_TRAIN_CFG_RESET is wrong.")

    # THE fail-first gate: nego_en (bit0) must be set FROM POR on both dies.
    # On the default build (NEGO_CFG_RESET=7'h00) this is 0 → autonomy_armed
    # (= nego_en & role_locked & train_auto_en) can NEVER assert → zero-poke
    # bring-up is structurally impossible. This is the exact reason every
    # bitstream ever built could not self-negotiate.
    assert (m_cfg & 0x1) and (s_cfg & 0x1), (
        f"nego_en (NEGO_CFG bit0) is 0 at POR (M nego_cfg_reg=0x{m_cfg:02x}, "
        f"S nego_cfg_reg=0x{s_cfg:02x}) with ZERO host writes. autonomy_armed "
        f"is gated off and the link can NEVER come up unpoked. This is the "
        f"pre-fix default NEGO_CFG_RESET=7'h00. Rebuild the IP with the "
        f"parameter default 7'h61 (in sim: +define+TB_TOP_NEGO_CFG_RESET=7'h61).")
    assert m_cfg == 0x61 and s_cfg == 0x61, (
        f"NEGO_CFG POR = M:0x{m_cfg:02x} S:0x{s_cfg:02x} — expected 0x61 "
        f"(nego_en|nego_force_lock|mask_hs_auto_en). Autonomy may arm but not "
        f"with the proven bring-up value.")

    # ---- (2) Sim-model knobs (identical to test_31 — timing/eye only) --------
    for side in ("m", "s"):
        _ctrl(dut, side).tb_winscan_dwell_short_q.value = 1
        _ctrl(dut, side).tb_fch_dwell_short_q.value     = 1
        _ctrl(dut, side).tb_ws_anchor_short_q.value     = 1
        _ctrl(dut, side).obs_sync_dist_vec_w.value      = Force(0)

    # ---- (3) Drive the autonomous bring-up to cal=1 + fcsm=4 -----------------
    seen_hold = {"m": False, "s": False}
    seen_done = {"m": False, "s": False}
    fc_ok     = {"m": False, "s": False}

    MAX_CYCLES = 5_000_000
    POLL = 200
    waited = 0
    last_log = 0
    while waited < MAX_CYCLES:
        await ClockCycles(dut.hclk, POLL)
        waited += POLL
        for side in ("m", "s"):
            cs = _si(_cal(dut, side).cur_state)
            if cs == CAL_S_HOLD:
                seen_hold[side] = True
            if cs == CAL_S_DONE:
                seen_done[side] = True
            if _si(_fcsm(dut, side).state) == FCSM_DATA:
                fc_ok[side] = True

        # Fail-fast: a poke must NEVER land on the nego registers.
        assert _si(dut.m_nego_poke_seen) == 0, (
            "A ctrl-reg write landed on MASTER NEGO_CFG/NEGO_TRAIN_CFG — this "
            "run is NOT zero-poke.")
        assert _si(dut.s_nego_poke_seen) == 0, (
            "A ctrl-reg write landed on SLAVE NEGO_CFG/NEGO_TRAIN_CFG — this "
            "run is NOT zero-poke.")

        if waited - last_log >= 200_000:
            last_log = waited
            log.info(
                f"t={waited*CLK_PERIOD_NS/1000:.0f}us  "
                f"M cal={CAL_NAMES.get(_si(_cal(dut,'m').cur_state))} "
                f"fcsm={_si(_fcsm(dut,'m').state)} | "
                f"S cal={CAL_NAMES.get(_si(_cal(dut,'s').cur_state))} "
                f"fcsm={_si(_fcsm(dut,'s').state)} | "
                f"doneM={seen_done['m']} fcM={fc_ok['m']} "
                f"doneS={seen_done['s']} fcS={fc_ok['s']}")

        if all(seen_done.values()) and all(fc_ok.values()):
            log.info(f"bilateral cal=S_DONE + fcsm=4 reached by "
                     f"{waited*CLK_PERIOD_NS/1000:.0f}us")
            break

    # ---- (4) Final snapshot + assertions ------------------------------------
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        log.info(f"{name}: seen_HOLD={seen_hold[side]} seen_DONE={seen_done[side]} "
                 f"cal_now={CAL_NAMES.get(_si(_cal(dut,side).cur_state))} "
                 f"fcsm={_si(_fcsm(dut,side).state)} "
                 f"nego_cfg_reg=0x{_si(_ctrl(dut,side).nego_cfg_reg):02x} "
                 f"role_locked={_si(_ctrl(dut,side).role_lock_reg)}")

    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert seen_done[side], (
            f"{name} calibrator never reached S_DONE (cal=1) — the autonomous "
            f"POR bring-up did not converge (cal_now="
            f"{CAL_NAMES.get(_si(_cal(dut,side).cur_state))}).")
        assert fc_ok[side], (
            f"{name} FCSM never reached {FCSM_DATA} (data mode) — the "
            f"autonomous FC handoff did not complete "
            f"(fcsm={_si(_fcsm(dut,side).state)}).")

    # ---- (5) THE zero-poke invariant: no write EVER touched the nego regs ----
    assert _si(dut.m_nego_poke_seen) == 0, (
        "MASTER NEGO_CFG/NEGO_TRAIN_CFG was WRITTEN during the run — not "
        "zero-poke.")
    assert _si(dut.s_nego_poke_seen) == 0, (
        "SLAVE NEGO_CFG/NEGO_TRAIN_CFG was WRITTEN during the run — not "
        "zero-poke.")

    # And the arming registers still hold their untouched POR value.
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        cfg = _si(_ctrl(dut, side).nego_cfg_reg)
        trn = _si(_ctrl(dut, side).nego_train_cfg_r)
        assert cfg == 0x61, (
            f"{name} nego_cfg_reg=0x{cfg:02x} at end (POR 0x61) — a write "
            f"perturbed it; the sticky monitor should have caught it.")
        assert trn == NEGO_TRAIN_CFG_POR, (
            f"{name} nego_train_cfg_r=0x{trn:04x} at end (POR 0x0001).")

    log.info("VERDICT: PASS — TRUE zero-poke autonomous bring-up. Both dies "
             "armed from NEGO_CFG_RESET=0x61 at POR (nego_train_cfg_r=0x0001, "
             "proving no tb force), reached bilateral cal=S_DONE + fcsm=4, and "
             "NOT A SINGLE ctrl-reg write landed on NEGO_CFG or NEGO_TRAIN_CFG "
             "on either die. Firmware recipe eliminated: the hardware "
             "self-negotiated from power-on.")

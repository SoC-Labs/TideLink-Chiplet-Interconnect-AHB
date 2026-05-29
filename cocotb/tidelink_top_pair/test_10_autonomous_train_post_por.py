"""Phase 0c — autonomous training engagement, no APB stimulus.

Goal
----
Confirm in sim that the tidelink_autoneg FSM walks the full

    ST_IDLE → ST_NEGO_INIT → ST_NEGO_WAIT → ST_NEGO_CLAIM → ST_NEGO_POLL
        → ST_NEGO_MASK_RD_ADDR → ST_NEGO_MASK_RD_DATA → ST_NEGO_MASK_RES_TX
        → ST_NEGO_DONE_PRE → ST_TRAIN_ENTER → ST_TRAIN_RUN → ST_TRAIN_POLL_PEER
        → ST_TRAIN_EXIT → ST_TRAIN_DONE

chain without any APB writes. The testbench (tb_top.sv) forces
`nego_cfg_reg = 7'h61` and `nego_train_cfg_r = 16'h00F1` on both dies at
time 0 (under `BYPASS_AUTONEG=0` compile flag), which is the stand-in for
the production `NEGO_TRAIN_CFG_RESET = 16'h0001` parameter override that
the parallel RTL agent is landing in Phase 2.

This test is INFO-only — no `assert` calls. It collects a state trace,
strobes, and timing snapshots, then logs them. Phase 7a will turn the
observations into real regression assertions once the RTL agent has
finalised the strap+reset-override interface.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
        TESTCASE=test_10_autonomous_train_post_por \
        make MODULE=test_10_autonomous_train_post_por

Hierarchy used
--------------
    dut.u_master.u_chiplet_controller.u_autoneg.state_r
                                              .local_train_set_pulse_r
                                              .local_train_clr_pulse_r
                                              .swreset_hold_r
                                              .peer_lane_locked_r
                                              .peer_lane_fault_r
                                              .peer_cal_done_r
                                              .train_ok_o
                                              .train_fail_o
    dut.u_master.u_chiplet_controller.nego_cfg_reg
    dut.u_master.u_chiplet_controller.nego_train_cfg_r
    dut.u_master.u_chiplet_controller.swi_training_mode_r
    dut.m_role_locked / dut.s_role_locked
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state  (FCSM)

Hardware ↔ sim mapping
----------------------
The autoneg FSM ticks at apb_clk = hclk = 50 MHz in this tb. Worst-case wall
times from the Phase 0 audit (extrapolated to 50 MHz instead of 100 MHz):
    NEGO claim + mask hs : ~20 ms
    ST_TRAIN_ENTER       :  ~1 ms (6 I²C bytes)
    ST_TRAIN_RUN dwell   :  0.08 ms (4096 cycles)
    ST_TRAIN_POLL_PEER   : up to ~19 ms (15 polls × ~1.2 ms)
    ST_TRAIN_EXIT        :  ~1 ms
    Total worst-case     : ~41 ms ≈ 50 ms safety budget
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

# State decoder — matches tidelink_autoneg.sv:157-193 verbatim.
ST_NAMES = {
    0:  "ST_IDLE",
    1:  "ST_NEGO_INIT",
    2:  "ST_NEGO_WAIT",
    3:  "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL",
    5:  "ST_NEGO_DONE",
    6:  "ST_BYPASS",
    7:  "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX",
    9:  "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA",
    11: "ST_NEGO_DONE_PRE",
    12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN",
    14: "ST_TRAIN_POLL_PEER",
    15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE",
    17: "ST_TRAIN_FAIL",
}


def _autoneg(dut, side):
    """Handle into the autoneg FSM on `side` ('m' or 's')."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _ctrl(dut, side):
    """Handle into the chiplet controller's reg storage on `side`."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller


def _fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


def _state_name(s):
    return ST_NAMES.get(s, f"ST_?({s})")


def snapshot(dut, label):
    """One-shot state capture across both dies. Logs and returns a dict."""
    rec = {"label": label, "sim_time_ns": cocotb.utils.get_sim_time(unit="ns")}
    for side in ("m", "s"):
        an = _autoneg(dut, side)
        cc = _ctrl(dut, side)
        fc = _fcsm(dut, side)
        st = _safe_int(an.state_r)
        rec[f"{side}_state"]     = st
        rec[f"{side}_state_name"] = _state_name(st)
        rec[f"{side}_train_set_pulse"]    = _safe_int(an.local_train_set_pulse_r)
        rec[f"{side}_train_clr_pulse"]    = _safe_int(an.local_train_clr_pulse_r)
        rec[f"{side}_swreset_hold"]       = _safe_int(an.swreset_hold_r)
        rec[f"{side}_peer_lane_locked"]   = _safe_int(an.peer_lane_locked_r)
        rec[f"{side}_peer_lane_fault"]    = _safe_int(an.peer_lane_fault_r)
        rec[f"{side}_peer_cal_done"]      = _safe_int(an.peer_cal_done_r)
        rec[f"{side}_train_ok"]           = _safe_int(an.train_ok_r)
        rec[f"{side}_train_fail"]         = _safe_int(an.train_fail_r)
        rec[f"{side}_nego_done"]          = _safe_int(an.nego_done_r)
        rec[f"{side}_swi_training_mode"]  = _safe_int(cc.swi_training_mode_r)
        rec[f"{side}_nego_cfg_reg"]       = _safe_int(cc.nego_cfg_reg)
        rec[f"{side}_nego_train_cfg"]     = _safe_int(cc.nego_train_cfg_r)
        rec[f"{side}_fcsm_state"]         = _safe_int(fc.state)
    rec["m_role_locked"] = _safe_int(dut.m_role_locked)
    rec["s_role_locked"] = _safe_int(dut.s_role_locked)
    rec["i2c_scl"]       = _safe_int(dut.i2c_scl)
    rec["i2c_sda"]       = _safe_int(dut.i2c_sda)

    log = dut._log
    log.info(f"========= snapshot @ {label} (t={rec['sim_time_ns']:.0f}ns) =========")
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        log.info(
            f"  {name}: state={rec[f'{side}_state']}({rec[f'{side}_state_name']}) "
            f"nego_cfg=0x{rec[f'{side}_nego_cfg_reg']:02x} "
            f"train_cfg=0x{rec[f'{side}_nego_train_cfg']:04x}"
        )
        log.info(
            f"  {name}: training_mode_set/clr=({rec[f'{side}_train_set_pulse']},"
            f"{rec[f'{side}_train_clr_pulse']}) "
            f"swreset_hold={rec[f'{side}_swreset_hold']} "
            f"swi_training_mode={rec[f'{side}_swi_training_mode']}"
        )
        log.info(
            f"  {name}: peer_lane_locked=0x{rec[f'{side}_peer_lane_locked']:02x} "
            f"peer_lane_fault=0x{rec[f'{side}_peer_lane_fault']:02x} "
            f"peer_cal_done={rec[f'{side}_peer_cal_done']}"
        )
        log.info(
            f"  {name}: train_ok={rec[f'{side}_train_ok']} "
            f"train_fail={rec[f'{side}_train_fail']} "
            f"nego_done={rec[f'{side}_nego_done']} "
            f"fcsm={rec[f'{side}_fcsm_state']}"
        )
    log.info(
        f"  ROLE: m_locked={rec['m_role_locked']} s_locked={rec['s_role_locked']}  "
        f"I2C: scl={rec['i2c_scl']} sda={rec['i2c_sda']}"
    )
    return rec


async def wait_for_state(dut, side, target_states, max_cycles, poll_every=200):
    """Poll the FSM until state_r hits any of `target_states` (or timeout).

    Returns (matched_state, cycles_waited). matched_state = -1 on timeout.
    """
    if isinstance(target_states, int):
        target_states = {target_states}
    else:
        target_states = set(target_states)
    an = _autoneg(dut, side)
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll_every)
        waited += poll_every
        s = _safe_int(an.state_r)
        if s in target_states:
            return s, waited
    return -1, waited


async def wait_for_signal(dut, side, attr, max_cycles, poll_every=200):
    """Poll the FSM until `attr` is logic 1."""
    an = _autoneg(dut, side)
    sig = getattr(an, attr)
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll_every)
        waited += poll_every
        if _safe_int(sig) == 1:
            return True, waited
    return False, waited


@cocotb.test()
async def test_10_autonomous_train_post_por(dut):
    """POR → observe the autoneg FSM walk to ST_TRAIN_DONE with no APB writes.

    Configuration of the FSM comes from the tb_top.sv force block (only
    engaged when BYPASS_AUTONEG=0). The test itself just resets, then
    waits and snapshots.
    """
    log = dut._log
    log.info("Phase 0c — autonomous train test starting")

    # Start clocks.
    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle the AHB / APB stimulus so the dies don't get hassled. We rely
    # entirely on the tb's BYPASS_AUTONEG=0 force to drive the FSM.
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value    = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value   = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value  = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value  = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    # Reset.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # ---- Snapshot 1: t=POR (just after hresetn rises). Should see the
    #      forced nego_cfg_reg/nego_train_cfg_r and FSM still in ST_IDLE
    #      (transitions are clocked, not combinational).
    snap_por = snapshot(dut, "after-reset")

    # ---- Wait for role_locked on either side. The FSM that wins the I²C
    #      arbitration will pulse nego_set_role_lock; on the loser the
    #      sda_start_detect path drives it. With nego_force_lock=1 in
    #      nego_cfg_reg[5], both nego_set_role_lock_w pulses fire.
    log.info("Waiting for role_locked (timeout = 5 ms)...")
    role_locked_seen = False
    role_locked_waited = 0
    for _ in range(2500):
        await ClockCycles(dut.hclk, 100)
        role_locked_waited += 100
        if _safe_int(dut.m_role_locked) == 1 or _safe_int(dut.s_role_locked) == 1:
            role_locked_seen = True
            break
    log.info(
        f"role_locked first-rise: seen={role_locked_seen} "
        f"after {role_locked_waited} cycles "
        f"({role_locked_waited * CLK_PERIOD_NS / 1000:.1f} µs)"
    )

    # ---- Snapshot 2: t=role_locked_rise (or just past the role-lock wait
    #      timeout — either way we record the state at this point).
    snap_role = snapshot(dut, "role_locked-or-timeout")

    # ---- Wait for ST_TRAIN_ENTER (state 12) on the master. The mask-hs
    #      auto path goes MASK_RD_ADDR → MASK_RD_DATA → MASK_RES_TX →
    #      NEGO_DONE_PRE → TRAIN_ENTER once the master has won.
    log.info("Waiting for master to enter ST_TRAIN_ENTER (state 12)...")
    s, w = await wait_for_state(dut, "m", {12}, max_cycles=5_000_000, poll_every=200)
    log.info(
        f"ST_TRAIN_ENTER entry on master: matched={s} "
        f"after {w} cycles "
        f"({w * CLK_PERIOD_NS / 1000:.1f} µs)"
    )

    # ---- Snapshot 3: at ST_TRAIN_ENTER entry (or timeout).
    snap_train_enter = snapshot(dut, "ST_TRAIN_ENTER-or-timeout")

    # ---- Wait for ST_TRAIN_DONE (state 16) or ST_TRAIN_FAIL (17). Big
    #      cycle budget — worst case is ~41 ms ≈ 2 M cycles at 50 MHz.
    log.info("Waiting for master to reach ST_TRAIN_DONE or ST_TRAIN_FAIL...")
    s, w = await wait_for_state(
        dut, "m", {16, 17}, max_cycles=5_000_000, poll_every=200
    )
    log.info(
        f"Terminal training state on master: matched={s} ({_state_name(s)}) "
        f"after {w} cycles "
        f"({w * CLK_PERIOD_NS / 1000:.1f} µs)"
    )

    # ---- Snapshot 4: at ST_TRAIN_DONE.
    snap_train_done = snapshot(dut, "ST_TRAIN_DONE-or-FAIL-or-timeout")

    # ---- Wait for train_ok_r rising on the master (or train_fail_r). Use
    #      the autoneg-internal r-reg names to avoid X-prop on the wires.
    log.info("Waiting for train_ok_r=1 on master...")
    ok, w = await wait_for_signal(dut, "m", "train_ok_r", max_cycles=200_000)
    fail = _safe_int(_autoneg(dut, "m").train_fail_r) == 1
    log.info(f"train_ok_r seen: {ok}  train_fail_r={fail}  after {w} cycles")

    # ---- Snapshot 5: end of test.
    snap_end = snapshot(dut, "train_ok_or_fail-final")

    # ---- Roll up the trace.
    snaps = [snap_por, snap_role, snap_train_enter, snap_train_done, snap_end]
    log.info("============== Phase 0c trace summary ==============")
    for s in snaps:
        log.info(
            f"  t={s['sim_time_ns']:>10.0f}ns [{s['label']:36s}] "
            f"M={s['m_state']:>2}({s['m_state_name']:<22}) "
            f"S={s['s_state']:>2}({s['s_state_name']:<22}) "
            f"m_role={s['m_role_locked']} s_role={s['s_role_locked']} "
            f"m_train_ok={s['m_train_ok']} m_train_fail={s['m_train_fail']}"
        )

    # ---- Verdict (INFO-only, no assert):
    if ok and not fail:
        log.info("Phase 0c VERDICT: PASS — autonomous training reached train_ok")
    elif fail:
        log.warning("Phase 0c VERDICT: TRAIN_FAIL observed — investigate POLL_PEER snapshot")
    else:
        log.warning("Phase 0c VERDICT: TIMEOUT before train_ok/train_fail — investigate ST_NEGO_* states")

    # Don't `assert` anything yet. Phase 7a will turn this into a real gate.
    log.info("Phase 0c test complete (INFO-only).")

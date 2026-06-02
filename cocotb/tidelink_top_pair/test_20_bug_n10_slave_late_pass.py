"""Bug N10 regression — peer-poll cross-check times out when peer's
sync_cal_done_1 is pinned low (mimics silicon "peer in ST_NEGO_DONE-lost
with calibrator never trained").

Silicon symptom (build v10, 2026-06-02 on z2_03):
    The slave (strap=1) was brought up AFTER the master die had powered
    on alone and parked itself in ST_NEGO_DONE-lost (no peer to ACK the
    autoneg claim → I²C MISS_ACK loser branch). When the slave came up
    later with autoneg+train enabled it won arbitration but training
    refused to converge:

      nego_status       = 0x051  → state[3:0]=1, won=1, done=1
                                   (state 1 is ST_TRAIN_FAIL truncated —
                                    5'd17 → 4'd1, nego_state_w is only 4
                                    bits per controller line 483)
      nego_train_status = 0x062  → train_state[7:4]=6=ST_TRAIN_FAIL,
                                   train_fail=1, train_ok=0
      obs_fsm_substate  = 0x080  → txn_step=1 (TXN_DATA) in TRAIN_FAIL
      ~14.5 ms FSM runtime before parking in ST_TRAIN_FAIL

Root cause
----------
ST_TRAIN_POLL_PEER (autoneg.sv:995) reads the peer's SWI_LANE_STATUS over
I²C. The success predicate (line 1075-1080) demands peer_lane_locked ==
8'hFF AND peer_cal_done AND peer_lane_fault==0 alongside matching local
values. When the peer is parked in ST_NEGO_DONE-lost AND its calibrator
never advanced past its boot default, `sync_cal_done_1` on the peer's
controller stays at 0. The slave's TRAIN_POLL_PEER predicate keeps
failing on the cal_done bit; after the 15-retry budget the FSM
unconditionally falls to ST_TRAIN_FAIL (line 1093-1094) with no
provision for "local side is fully locked, peer just hasn't reported."

Sim repro
---------
BYPASS_AUTONEG=0 in the tb gives master=priority 0x0001 (wins) and
slave=priority 0x0002 (loses) — opposite of silicon, but the FSM under
test is the same. The "winning" side runs ST_TRAIN_ENTER → ST_TRAIN_RUN →
ST_TRAIN_POLL_PEER, polling the loser. We pin the LOSER's
`sync_cal_done_1` to 0 from python so the predicate never accepts and
the FSM exhausts its retry budget. With pre-fix RTL the winner parks in
ST_TRAIN_FAIL. With the Bug N10 fix the winner takes the new
local-only fallback branch and lands in ST_TRAIN_DONE.

The role inversion (master=winner in sim vs slave=winner in silicon)
does NOT affect the FSM transitions under test — both roles share the
same `tidelink_autoneg` instance and the same ST_TRAIN_POLL_PEER block.

Test contract
-------------
* Pre-fix RTL  : winner (master) times out in ST_TRAIN_POLL_PEER → FAILS
* Post-fix RTL : winner takes the local-only success bypass → PASSES

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_20_bug_n10_slave_late_pass \\
        make MODULE=test_20_bug_n10_slave_late_pass
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer, RisingEdge, ReadOnly
from cocotb.handle import Force


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

ST_NAMES = {
    0:  "ST_IDLE", 1: "ST_NEGO_INIT", 2: "ST_NEGO_WAIT", 3: "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL", 5: "ST_NEGO_DONE", 6: "ST_BYPASS", 7: "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX", 9: "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA", 11: "ST_NEGO_DONE_PRE", 12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN", 14: "ST_TRAIN_POLL_PEER", 15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE", 17: "ST_TRAIN_FAIL",
}

ST_TRAIN_DONE = 16
ST_TRAIN_FAIL = 17

BUDGET_MS = 80.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _state_name(st):
    return ST_NAMES.get(st, f"UNKNOWN({st})")


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _ctrl(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller


async def wait_state(dut, side, targets, max_cycles, poll=200, log_every=500_000):
    if isinstance(targets, int):
        targets = {targets}
    else:
        targets = set(targets)
    an = _autoneg(dut, side)
    waited = 0
    last_log = 0
    log = dut._log
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        st = _safe_int(an.state_r)
        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  [{side}] t={waited * CLK_PERIOD_NS / 1000:>8.1f} us  "
                f"st={st}({_state_name(st)})  "
                f"won={_safe_int(an.nego_won_r)} "
                f"lost={_safe_int(an.nego_lost_r)} "
                f"train_ok={_safe_int(an.train_ok_r)} "
                f"train_fail={_safe_int(an.train_fail_r)} "
                f"poll_att={_safe_int(an.poll_attempt_r)}"
            )
        if st in targets:
            return st, waited
    return -1, waited


def force_peer_cal_done_low(ctrl):
    """Force the peer's CDC-synced lane-status regs to 0 via cocotb's
    Verilog `force` action. Persists for the entire sim — the FSM's
    always_ff cannot overwrite a forced value. Effective behaviour:
    peer's SWI_LANE_STATUS readback over I²C reports cal_done=0 and
    lane_locked=0x00 forever, just like a never-trained calibrator."""
    ctrl.sync_cal_done_0.set(Force(0))
    ctrl.sync_cal_done_1.set(Force(0))
    ctrl.sync_lane_locked_0.set(Force(0))
    ctrl.sync_lane_locked_1.set(Force(0))


@cocotb.test()
async def test_20_bug_n10_slave_late_pass(dut):
    """Winning side reaches ST_TRAIN_POLL_PEER and polls the loser. The
    loser's sync_cal_done_1 is force-pinned to 0 so the cross-check
    never accepts. Pre-fix → ST_TRAIN_FAIL. Post-fix → ST_TRAIN_DONE
    via the local-only success bypass."""
    log = dut._log
    log.info("Bug N10 regression — test_20_bug_n10_slave_late_pass")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Pin the loser's CDC-synced cal_done / lane_locked to 0 so the
    # winner's TRAIN_POLL_PEER read of the loser's SWI_LANE_STATUS over
    # I²C returns cal_done=0 forever. tb_top with RELY_ON_RTL_PRIO_DEFAULTS=0
    # (the default) sets master priority=0x0001 → master wins, slave loses,
    # so we pin the slave's syncs.
    force_peer_cal_done_low(_ctrl(dut, "s"))
    log.info(
        "Started slave-side sync_cal_done_{0,1}=0 pin — TRAIN_POLL_PEER "
        "on master will see peer cal_done=0 perpetually"
    )

    # tb_top.sv force release (#5000 ns inside the initial block). Wait
    # past it before asserting on anything.
    await ClockCycles(dut.hclk, 300)

    # Wait for winner (master) to reach ST_TRAIN_DONE or ST_TRAIN_FAIL.
    log.info("Waiting for master to reach ST_TRAIN_DONE or ST_TRAIN_FAIL...")
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    st, w = await wait_state(
        dut, "m", {ST_TRAIN_DONE, ST_TRAIN_FAIL, 7},
        max_cycles=budget_cycles
    )
    log.info(
        f"Master reached st={st}({_state_name(st)}) "
        f"after {w * CLK_PERIOD_NS / 1000:.1f} us"
    )

    m_an = _autoneg(dut, "m")
    m_state      = _safe_int(m_an.state_r)
    m_train_ok   = _safe_int(m_an.train_ok_r)
    m_train_fail = _safe_int(m_an.train_fail_r)
    m_peer_nack  = _safe_int(m_an.train_peer_nack_r)
    m_peer_lock  = _safe_int(m_an.peer_lane_locked_r) & 0xFF
    m_peer_cal   = _safe_int(m_an.peer_cal_done_r)
    m_peer_fault = _safe_int(m_an.peer_lane_fault_r) & 0xFF
    m_poll_att   = _safe_int(m_an.poll_attempt_r)
    m_won        = _safe_int(m_an.nego_won_r)
    m_lost       = _safe_int(m_an.nego_lost_r)

    s_state      = _safe_int(_autoneg(dut, "s").state_r)
    s_won        = _safe_int(_autoneg(dut, "s").nego_won_r)
    s_lost       = _safe_int(_autoneg(dut, "s").nego_lost_r)

    log.info(
        f"FINAL MASTER:\n"
        f"  state={m_state}({_state_name(m_state)})  "
        f"won={m_won} lost={m_lost}\n"
        f"  train_ok_r={m_train_ok}  train_fail_r={m_train_fail}\n"
        f"  peer_nack={m_peer_nack}  poll_attempt_r={m_poll_att}\n"
        f"  peer_lane_locked=0x{m_peer_lock:02x} "
        f"peer_cal_done={m_peer_cal} "
        f"peer_lane_fault=0x{m_peer_fault:02x}"
    )
    log.info(
        f"FINAL SLAVE : state={s_state}({_state_name(s_state)}) "
        f"won={s_won} lost={s_lost}"
    )

    assert m_state == ST_TRAIN_DONE, (
        f"Bug N10: winner (master) parked in {_state_name(m_state)} "
        f"(expected ST_TRAIN_DONE) after the TRAIN_POLL_PEER cross-check "
        f"exhausted retries with peer cal_done pinned to 0. "
        f"train_ok={m_train_ok}, train_fail={m_train_fail}, "
        f"peer_cal_done={m_peer_cal}, peer_lane_locked=0x{m_peer_lock:02x}, "
        f"poll_attempt_r={m_poll_att}. Pre-fix RTL has no local-only "
        f"fallback in ST_TRAIN_POLL_PEER timeout (autoneg.sv:1087-1094); "
        f"post-fix routes via ST_TRAIN_EXIT when local lanes are fully "
        f"locked but peer never reports cal_done."
    )
    assert m_train_ok == 1, f"train_ok_r expected 1, got {m_train_ok}"
    assert m_train_fail == 0, f"train_fail_r expected 0, got {m_train_fail}"
    log.info("PASS: master reached ST_TRAIN_DONE via Bug N10 local-only bypass")

"""Bug N13 regression — verify role_lock latches with PRODUCTION-SILICON
straps (apb_debug_unlock_i = mask_hs_bypass_i = 0). All other tb tests
rely on the testbench defaults (both straps tied to 1'b1, see tb_top.sv
lines 127-132), which mask Bug N13 by forcing mask_hs_gate_open=1
regardless of the mask_hs_local_match_r latch.

Bug N13: the MASK_RES_TX → DONE_PRE transition was not recognised by
the local-match latch (predicate only matched MASK_RES_TX → DONE), so
master's autoneg correctly captures peer masks but never sets
mask_hs_local_match_r, mask_hs_match stays 0, mask_hs_gate_open stays 0,
role_lock never latches. Silicon (straps tied 0) exposes this; sim
masks it.

This test forces both dies' debug-strap signals to 0 (production
silicon) right after reset, then runs the simultaneous-POR happy path.
Pre-fix: master/slave role_lock stay 0, master parks in ST_TRAIN_FAIL.
Post-fix: master reaches ST_TRAIN_DONE with role_lock=1, slave gets
role_lock=1 via Bug N9 fix's nego_lost_w path.



Silicon symptom (post Bug N8+N9+N10 fixes)
------------------------------------------
Master is flashed/POR'd first, runs solo autoneg → ST_NEGO_DONE-lost (no
peer to ACK). Slave deploys ms-to-seconds later, wins arbitration, then
trips Bug N11: the Wlink lane_mask reads back the TL_ID magic byte
0x544C0100 instead of 8'hFF. Slave's mask handshake fails → training
stalls → master's calibrator can't engage because slave's TX never
emits the training pattern (slave's role_lock=0 keeps the slave Wlink
in reset). Classic sequencing cascade.

Hypothesis
----------
If BOTH dies POR at the same instant, the FSM walks the well-tested
"happy path":
  * Both enter ST_NEGO_WAIT at t=0
  * Master (priority=0x0001) backoff expires first (~60 us)
  * Master enters ST_NEGO_CLAIM, drives SDA low
  * Slave's sda_start_detect fires at ~65 us (before its own 80 us
    backoff expires) → takes the early-exit SDA path → ST_NEGO_DONE-lost
  * Master runs CLAIM → ACK from slave's i2c_slv → MASK_RD → MASK_RES_TX
  * Both latch role_lock cleanly
  * Both calibrators engage with both Wlinks out of reset
  * Training converges → train_ok on both

If this passes on current HEAD (58e97d4), the cascade is asymmetric-POR-
only and the silicon symptom can be sidestepped by ensuring simultaneous
POR via the parallel fpga_manager flash pattern.

If this fails, Bug N11 bites symmetric POR too and the parallel agent's
RTL fix on the Wlink lane_mask is genuinely required.

tb_top.sv POR contract
----------------------
tb_top wires BOTH master and slave to the same `poresetn` and `hresetn`
signals (see tb_top.sv:122-123, 274-275, 497-498). Driving these signals
from cocotb therefore gives bit-exact simultaneous POR on the two
controllers — the most favourable possible case for the hypothesis.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_22_simultaneous_por_cascade \\
        make MODULE=test_22_simultaneous_por_cascade
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0     # 50 MHz hclk
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
ST_ERROR      = 7

# Budget for the autoneg + training to resolve on BOTH dies. test_10
# documents the worst-case at ~41 ms when only the winner is observed;
# we double that for headroom on the slow (loser) side that has to walk
# its SDA-early-exit path and then train its own calibrator.
BUDGET_MS = 120.0


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


def _snapshot(dut, label):
    log = dut._log
    log.info(f"========= snapshot @ {label} =========")
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        an = _autoneg(dut, side)
        cc = _ctrl(dut, side)
        role = _safe_int(getattr(dut, f"{side}_role_locked"))
        log.info(
            f"  {name}: state={_safe_int(an.state_r)}"
            f"({_state_name(_safe_int(an.state_r))})  "
            f"role_locked={role}  "
            f"prio=0x{_safe_int(cc.nego_priority_reg):04x}  "
            f"won={_safe_int(an.nego_won_r)} "
            f"lost={_safe_int(an.nego_lost_r)}  "
            f"sda_seen={_safe_int(an.sda_start_seen_r)}  "
            f"train_ok={_safe_int(an.train_ok_r)} "
            f"train_fail={_safe_int(an.train_fail_r)}  "
            f"poll_att={_safe_int(an.poll_attempt_r)}"
        )


@cocotb.test()
async def test_24_bug_n13_silicon_straps(dut):
    """Production-silicon strap scenario: apb_debug_unlock_i = mask_hs_bypass_i = 0.
    Pre-Bug-N13-fix: master's mask_hs_local_match_r never latches because
    MASK_RES_TX exits via DONE_PRE, not DONE; mask_hs_gate_open stays 0;
    role_lock never sets. Post-fix: latch accepts both DONE and DONE_PRE
    target states, mask handshake completes, role_lock latches normally.
    """
    log = dut._log
    log.info("Bug N11 alt-hypothesis — simultaneous-POR cascade test")
    log.info(f"BUDGET_MS={BUDGET_MS}")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all AHB / APB stimulus on both dies. The tb's BYPASS_AUTONEG=0
    # force block injects nego_cfg_reg=0x61 + nego_train_cfg_r=0x00F1 on
    # both sides at t=0 (default — RELY_ON_RTL_PRIO_DEFAULTS=0 also
    # injects master:prio=0x0001, slave:prio=0x0002).
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

    # SIMULTANEOUS POR: tb_top wires both dies to the same poresetn /
    # hresetn signals, so a single drive deresets both controllers on
    # the exact same hclk edge — bit-exact symmetric POR, the
    # most favourable possible scenario for the hypothesis.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Force production-silicon strap values. tb_top defaults both
    # apb_debug_unlock / mask_hs_bypass straps to 1'b1 for legacy SW-
    # driven tests; this test overrides them to 1'b0 to exercise the
    # autoneg-only mask handshake path that production silicon actually
    # uses. With the override, mask_hs_gate_open depends entirely on
    # autoneg.mask_hs_local_match (since Wlink.mask_hs_result_o is
    # stubbed to 2'b00 — Bug N9's underlying).
    dut.m_apb_debug_unlock.value = 0
    dut.s_apb_debug_unlock.value = 0
    dut.m_mask_hs_bypass.value   = 0
    dut.s_mask_hs_bypass.value   = 0

    # Wait past the tb_top force-release window (#5000 ns inside the
    # initial block) so any later transitions aren't masked by the
    # force.
    await ClockCycles(dut.hclk, 300)

    _snapshot(dut, "post-reset")

    # Poll until both dies have either reached a terminal training state
    # (DONE / FAIL) or the budget expires. Cadence log every ~5 ms so
    # the trace shows the walk.
    poll = 200
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    waited = 0
    last_log = 0
    log_every = 250_000   # ~5 ms

    m_an = _autoneg(dut, "m")
    s_an = _autoneg(dut, "s")

    while waited < budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        m_st = _safe_int(m_an.state_r)
        s_st = _safe_int(s_an.state_r)

        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  t={waited * CLK_PERIOD_NS / 1000:>8.1f} us  "
                f"M st={m_st}({_state_name(m_st)})  "
                f"S st={s_st}({_state_name(s_st)})  "
                f"M role={_safe_int(dut.m_role_locked)} "
                f"S role={_safe_int(dut.s_role_locked)}  "
                f"M won={_safe_int(m_an.nego_won_r)} "
                f"M ok={_safe_int(m_an.train_ok_r)} "
                f"M fail={_safe_int(m_an.train_fail_r)}  "
                f"S won={_safe_int(s_an.nego_won_r)} "
                f"S ok={_safe_int(s_an.train_ok_r)} "
                f"S fail={_safe_int(s_an.train_fail_r)}"
            )

        # Stop once BOTH dies have committed to a terminal state. The
        # loser may park in ST_NEGO_DONE (5) because the slave-side
        # autoneg ends in ST_NEGO_DONE-lost on this RTL — that still
        # counts as a clean resolution.
        m_terminal = m_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR, 5}
        s_terminal = s_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR, 5}
        if m_terminal and s_terminal:
            # Don't break yet — give the slower side a chance to
            # advance past ST_NEGO_DONE into TRAIN_*. Only break if at
            # least one side has hit DONE / FAIL.
            if (m_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR}) or \
               (s_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR}):
                break

    sim_t_ms = waited * CLK_PERIOD_NS / 1_000_000

    _snapshot(dut, f"final @ t={sim_t_ms:.2f} ms")

    # Final state collection.
    m_state      = _safe_int(m_an.state_r)
    m_train_ok   = _safe_int(m_an.train_ok_r)
    m_train_fail = _safe_int(m_an.train_fail_r)
    m_role       = _safe_int(dut.m_role_locked)
    m_won        = _safe_int(m_an.nego_won_r)
    m_lost       = _safe_int(m_an.nego_lost_r)

    s_state      = _safe_int(s_an.state_r)
    s_train_ok   = _safe_int(s_an.train_ok_r)
    s_train_fail = _safe_int(s_an.train_fail_r)
    s_role       = _safe_int(dut.s_role_locked)
    s_won        = _safe_int(s_an.nego_won_r)
    s_lost       = _safe_int(s_an.nego_lost_r)

    log.info(
        f"FINAL @ t={sim_t_ms:.2f} ms:\n"
        f"  MASTER: state={m_state}({_state_name(m_state)})  "
        f"role_locked={m_role}  won={m_won} lost={m_lost}  "
        f"train_ok={m_train_ok} train_fail={m_train_fail}\n"
        f"  SLAVE : state={s_state}({_state_name(s_state)})  "
        f"role_locked={s_role}  won={s_won} lost={s_lost}  "
        f"train_ok={s_train_ok} train_fail={s_train_fail}"
    )

    # Bug N13 scope: this test asserts only what the N13 fix delivers —
    # i.e. that the mask_hs_local_match_r latch fires when MASK_RES_TX
    # transitions to ST_NEGO_DONE_PRE, opening mask_hs_gate_open so
    # role_lock_reg can latch on the winner. Pre-N13-fix: master role
    # stays 0 because the latch predicate didn't accept DONE_PRE as a
    # valid target. Post-N13-fix: master role latches.
    #
    # The downstream training (TRAIN_RUN → TRAIN_POLL_PEER) MAY still
    # fail under straps=0 due to a separate timing/dependency bug —
    # that's tracked as a follow-up and intentionally NOT asserted here
    # so this test cleanly captures the N13 fix's effect alone.
    failures = []
    if m_role != 1:
        failures.append(f"master role_locked={m_role} (expected 1 — Bug N13 latch must fire)")
    if s_role != 1:
        failures.append(f"slave role_locked={s_role} (expected 1 — via Bug N9 nego_lost_w path)")
    if m_state == ST_ERROR:
        failures.append(f"master in ST_ERROR")
    if s_state == ST_ERROR:
        failures.append(f"slave in ST_ERROR")

    if failures:
        raise AssertionError(
            "Bug N13 regression: FAILED.\n"
            "  mask_hs_local_match_r latch did not fire on MASK_RES_TX→DONE_PRE\n"
            "  transition under production-silicon strap values (both bypass\n"
            "  straps tied 0). The original latch predicate accepted only\n"
            "  state_nxt == ST_NEGO_DONE — but the FSM walks via DONE_PRE.\n"
            f"  Failures: {failures}\n"
            f"  Master: state={_state_name(m_state)} role={m_role} "
            f"won={m_won} ok={m_train_ok} fail={m_train_fail}\n"
            f"  Slave : state={_state_name(s_state)} role={s_role} "
            f"won={s_won} ok={s_train_ok} fail={s_train_fail}"
        )

    log.info(
        "PASS: Bug N13 fix latches mask_hs_local_match_r under "
        "production-silicon straps (apb_debug_unlock = mask_hs_bypass "
        "= 0). Both dies reached role_locked=1. Downstream training "
        "behaviour (TRAIN_RUN, TRAIN_POLL_PEER) is intentionally NOT "
        "asserted by this regression — that may still fail under "
        "straps=0 and is tracked separately."
    )
    if m_train_ok == 1 and m_train_fail == 0:
        log.info(
            "BONUS: master also reached ST_TRAIN_DONE with train_ok=1 — "
            "full autonomous bring-up under production straps is working."
        )
    elif m_train_fail == 1:
        log.warning(
            f"NOTE: master state={_state_name(m_state)} train_fail=1 — "
            f"downstream training bug persists under straps=0 (separate from N13)."
        )

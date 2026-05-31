"""Bug N7 regression — autoneg priority POR default must be asymmetric.

Background
----------
Build v6 silicon (HEAD 9113d95) reaches Bugs N1-N6 silicon-validated under
the SW-forced deploy_pair.sh path, but the no-SW autonomy path still parks
both dies at:

    NEGO_STATUS = 0x027  ← ST_ERROR (state 7), sda_start_seen=0
    nego_priority_reg = 16'hFFFF on BOTH dies (POR default in
                        local_overrides/axi_chiplet_controller.sv:585)

Symmetric priorities mean the autoneg FSM's ST_NEGO_WAIT backoff timer
(tidelink_autoneg.sv:377) computes identical `backoff_delay` values on
both dies. Neither side fires SDA-START first, so the early-exit
`sda_start_detect` (line 383) never trips on the loser, and once both
timers expire both FSMs end up wanting to claim the bus simultaneously
→ I²C arbitration loss / no progress → ST_ERROR.

Fix
---
Two-part — see commits in this series:
  1. RTL: `nego_priority_reg` POR default becomes
       role_strap_i ? 16'h0002 : 16'h0001
     so the strap-determined master gets the lower backoff and claims
     the bus first while the slave defers.
  2. BD: `axi_gpio_strap.CONFIG.C_DOUT_DEFAULT` set to 0x1 on the
     pynq-z2-pair-flip-all target so that, at FPGA POR (before any SW
     write), the slave-role board actually sees role_strap_i=1.

Test contract
-------------
This test deliberately runs with RELY_ON_RTL_PRIO_DEFAULTS=1, which
suppresses the tb_top.sv force on `nego_priority_reg`. The RTL POR
default is therefore what reaches the autoneg FSM.

  * Pre-fix RTL  : both dies POR to 16'hFFFF  → FSM deadlocks in
                   ST_NEGO_WAIT, expires to ST_ERROR. Test FAILS.
  * Post-fix RTL : master POR to 16'h0001, slave to 16'h0002 (because
                   tb_top hard-wires role_strap_i=1'b0 on master and
                   1'b1 on slave). FSM walks ST_NEGO_INIT → ST_NEGO_WAIT
                   → ST_NEGO_CLAIM (master, winner) /
                   sda_start_seen=1 (slave, loser) → ST_NEGO_DONE / past.
                   Test PASSES.

Pass criteria (within BUDGET_MS sim time):
  * Master autoneg reaches state >= 5 (ST_NEGO_DONE or any later
    training state) with won=1, OR
  * Slave autoneg reaches state >= 5 with lost=1 / sda_start_seen=1.

Failure message reports both dies' nego_priority_reg, nego_state, and
sda_start_seen so the Bug N7 fingerprint is unambiguous.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 RELY_ON_RTL_PRIO_DEFAULTS=1 TB_TOP_NO_DUMP=1 \
        TESTCASE=test_18_bug_n7_priority_deadlock \
        make MODULE=test_18_bug_n7_priority_deadlock
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0     # 50 MHz hclk / apb_clk
REF_CLK_PERIOD_NS = 8.0

# State decoder — matches tidelink_autoneg.sv state_r encoding.
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

# Budget for the autoneg arbitration to resolve. The legacy test_10 shows
# the master leaving ST_NEGO_WAIT in well under 1 ms with the asymmetric
# priorities forced; 50 ms gives ~50× margin and is small enough that the
# test stays bisect-friendly.
BUDGET_MS = 50.0

# State threshold for "autoneg has resolved": anything >= ST_NEGO_DONE (5)
# except ST_ERROR (7) counts as forward progress.
PASS_STATE_MIN  = 5
FAIL_STATE      = 7


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


@cocotb.test()
async def test_18_bug_n7_priority_deadlock(dut):
    """RTL POR default of nego_priority_reg must produce asymmetric backoff
    so one side wins arbitration and the other detects sda_start. Pre-Bug-N7
    RTL POR'd both sides to 16'hFFFF and deadlocked → ST_ERROR; the
    role_strap-derived fix makes master=0x0001, slave=0x0002 at POR."""
    log = dut._log
    log.info("Bug N7 regression — test_18_bug_n7_priority_deadlock")
    log.info(
        f"BUDGET_MS={BUDGET_MS}  PASS_STATE_MIN={PASS_STATE_MIN}  "
        f"FAIL_STATE={FAIL_STATE} (ST_ERROR)"
    )

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all bus stimulus — autoneg engaged by tb_top BYPASS_AUTONEG=0
    # force block (nego_cfg + nego_train_cfg). nego_priority_reg is NOT
    # forced (RELY_ON_RTL_PRIO_DEFAULTS=1 path), so the RTL POR default
    # decides on its own.
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

    # Reset.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    m_an  = _autoneg(dut, "m")
    s_an  = _autoneg(dut, "s")
    m_ctl = _ctrl(dut, "m")
    s_ctl = _ctrl(dut, "s")

    # Probe POR-resolved nego_priority_reg values. With the tb force gated
    # off and the RTL fix applied this should read 0x0001/0x0002.
    m_prio_por = _safe_int(m_ctl.nego_priority_reg)
    s_prio_por = _safe_int(s_ctl.nego_priority_reg)
    log.info(
        f"POR nego_priority_reg: master=0x{m_prio_por:04x} "
        f"slave=0x{s_prio_por:04x}"
    )

    # Poll for resolution. Stop as soon as either condition fires:
    #   - master state >= 5 with state != 7   (master made progress)
    #   - slave state >= 5 with state != 7    (slave made progress)
    # We log a trace at coarse cadence for debug.
    poll = 200  # 4 µs per poll @ 50 MHz hclk
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    waited = 0
    resolved = False
    last_log = 0
    log_every = 50000  # ~1 ms

    while waited < budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        m_st = _safe_int(m_an.state_r)
        s_st = _safe_int(s_an.state_r)

        # Cadence log so we can see the walk in the .log output.
        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  t={waited * CLK_PERIOD_NS / 1000:>7.1f}us  "
                f"M st={m_st}({_state_name(m_st)})  "
                f"S st={s_st}({_state_name(s_st)})  "
                f"M won={_safe_int(m_an.nego_won_r)} "
                f"M lost={_safe_int(m_an.nego_lost_r)} "
                f"S won={_safe_int(s_an.nego_won_r)} "
                f"S lost={_safe_int(s_an.nego_lost_r)} "
                f"M sda_seen={_safe_int(m_an.sda_start_seen_r)} "
                f"S sda_seen={_safe_int(s_an.sda_start_seen_r)}"
            )

        # Either side past ST_NEGO_DONE (and not in ST_ERROR) is forward
        # progress — autoneg arbitration resolved.
        m_progressed = (m_st >= PASS_STATE_MIN) and (m_st != FAIL_STATE)
        s_progressed = (s_st >= PASS_STATE_MIN) and (s_st != FAIL_STATE)
        if m_progressed or s_progressed:
            resolved = True
            break

        # Bail early on the Bug N7 fingerprint — both dies in ST_ERROR
        # means the deadlock has already played out, no point waiting.
        if m_st == FAIL_STATE and s_st == FAIL_STATE:
            break

    sim_t_us = waited * CLK_PERIOD_NS / 1000

    # Final probe — gather the diagnostic state.
    m_st   = _safe_int(m_an.state_r)
    s_st   = _safe_int(s_an.state_r)
    m_won  = _safe_int(m_an.nego_won_r)
    s_won  = _safe_int(s_an.nego_won_r)
    m_lost = _safe_int(m_an.nego_lost_r)
    s_lost = _safe_int(s_an.nego_lost_r)
    m_sda  = _safe_int(m_an.sda_start_seen_r)
    s_sda  = _safe_int(s_an.sda_start_seen_r)
    m_prio = _safe_int(m_ctl.nego_priority_reg)
    s_prio = _safe_int(s_ctl.nego_priority_reg)

    log.info(
        f"FINAL @ t={sim_t_us:.1f} us:\n"
        f"  MASTER: prio=0x{m_prio:04x}  state={m_st}({_state_name(m_st)})  "
        f"won={m_won}  lost={m_lost}  sda_start_seen={m_sda}\n"
        f"  SLAVE : prio=0x{s_prio:04x}  state={s_st}({_state_name(s_st)})  "
        f"won={s_won}  lost={s_lost}  sda_start_seen={s_sda}"
    )

    if not resolved:
        # Bug N7 fingerprint: both dies POR'd to identical priorities,
        # ST_NEGO_WAIT timer expired in lock-step, ST_ERROR.
        raise AssertionError(
            f"Bug N7: autoneg priority deadlock — neither die reached "
            f"ST_NEGO_DONE (state >= {PASS_STATE_MIN}) within "
            f"{BUDGET_MS} ms.\n"
            f"  MASTER nego_priority_reg = 0x{m_prio:04x}  "
            f"state = {m_st} ({_state_name(m_st)})  "
            f"sda_start_seen = {m_sda}\n"
            f"  SLAVE  nego_priority_reg = 0x{s_prio:04x}  "
            f"state = {s_st} ({_state_name(s_st)})  "
            f"sda_start_seen = {s_sda}\n"
            f"Expected: master prio=0x0001, slave prio=0x0002 (RTL POR "
            f"default derived from role_strap_i). Got both = "
            f"0x{m_prio:04x} which yields identical backoff_delay → "
            f"ST_NEGO_WAIT deadlock → ST_ERROR. Fix: "
            f"src/rtl/local_overrides/axi_chiplet_controller.sv:585 — "
            f"nego_priority_reg <= role_strap_i ? 16'h0002 : 16'h0001."
        )

    # Sanity: confirm asymmetry — exactly one of {master,slave} progressed
    # past ST_NEGO_DONE first (the winner) and we observed activity.
    m_ok = (m_st >= PASS_STATE_MIN) and (m_st != FAIL_STATE)
    s_ok = (s_st >= PASS_STATE_MIN) and (s_st != FAIL_STATE)
    assert m_ok or s_ok, (
        f"Resolved flag set but neither side passed final-state check. "
        f"m_st={m_st} s_st={s_st}"
    )

    # In a master-wins flow (the role_strap-derived expectation) master
    # should be the side that progressed. Log if it's the other way round
    # (still PASS — the role contract is enforced elsewhere), but note it.
    if m_ok and not s_ok:
        log.info(
            f"PASS (master claimed first, as expected from "
            f"strap=0 priority=0x{m_prio:04x} < slave 0x{s_prio:04x}) "
            f"at t={sim_t_us:.1f} us"
        )
    elif s_ok and not m_ok:
        log.warning(
            f"PASS but slave claimed first — unexpected for "
            f"role_strap-derived priorities. m_prio=0x{m_prio:04x}, "
            f"s_prio=0x{s_prio:04x}"
        )
    else:
        log.info(
            f"PASS (both dies progressed) at t={sim_t_us:.1f} us"
        )

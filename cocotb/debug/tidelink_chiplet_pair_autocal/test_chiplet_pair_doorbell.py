"""Doorbell-style M→S / S→M asymmetry probe at the chiplet-controller-pair
scope (AUTOCAL_ENABLE=1). The chiplet controller has no top-level DOORBELL
register — the unit-level equivalent of "doorbell crosses" is the FCSM's
`cr_pkt_seen_rx` sticky latch, which represents the very first sideband
packet to make it across in each direction:

    M's `cr_pkt_seen_rx` = 1  ↔  slave's cr_pkt reached master    (S→M works)
    S's `cr_pkt_seen_rx` = 1  ↔  master's cr_pkt reached slave    (M→S works)

The HW symptom in cocotb/tidelink_top_pair / FPGA bridge1 b24 is one side
latches but the other does NOT. Same shape of failure is what we look for
here.

Sequence (mirrors bringup_pair_converge.sh / wlink_pair
test_paired_recal_to_link_data.py):
   POR → role-lock both → wait for calibration_done →
   recal-cycle (slot0=0x3 hold then 0x1) →
   drop training (slot0=0x0) → LL swreset cycle on both Wlinks →
   observe cr_pkt_seen_rx for ~5000 cycles → report asymmetry.

This is the FAST iteration loop (~6 min wall) the calibrator-fix author
wants.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ---------------------------------------------------------------------
# APB register addresses (same as wlink_pair tests).
# ---------------------------------------------------------------------
WL_LINK_ENABLE_RESET = 0x0208
WL_LINK_STATUS       = 0x0234
LL_CTRL_SWRESET_ON   = 0x27f08
LL_CTRL_SWRESET_OFF  = 0x27f00
LL_CTRL_ENABLED      = 0x27f07

# Region 8 / Region 4 ctrl_reg addresses (4-bit; bit[3]=1 selects Region 8).
R8_SLOT0  = 0b1000   # SWI_TRAINING_MODE / SWI_RECAL
R8_SLOT2  = 0b1010   # SWI_LANE_STATUS

FCSM_NAMES = {
    0: "IDLE", 1: "SEND_CR1", 2: "SEND_CR2", 3: "LE_WAIT",
    4: "LINK_IDLE", 5: "LINK_DATA", 6: "?6", 7: "SEND_NACK",
}

CAL_NAMES = {0: "IDLE", 1: "ARM", 2: "SWEEP", 3: "FINISH",
             4: "DONE", 5: "CANCEL", 6: "HOLD"}


# ---------------------------------------------------------------------
# Bus helpers (ctrl_reg single-cycle + APB master).
# ---------------------------------------------------------------------
async def ctrl_write(dut, side, addr, data):
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    sig_d.value = data
    sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0


async def ctrl_read(dut, side, addr):
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_r = getattr(dut, f"{side}_ctrl_reg_rdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    await RisingEdge(dut.apb_clk)
    return int(sig_r.value)


async def apb_read(dut, side, addr):
    psel  = getattr(dut, f"{side}_apb_psel")
    pen   = getattr(dut, f"{side}_apb_penable")
    pwr   = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pready = getattr(dut, f"{side}_apb_pready")
    prdata = getattr(dut, f"{side}_apb_prdata")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 0
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            try:
                data = int(prdata.value)
            except ValueError:
                data = 0
            break
    psel.value = 0
    pen.value = 0
    return data


async def apb_write(dut, side, addr, data):
    psel  = getattr(dut, f"{side}_apb_psel")
    pen   = getattr(dut, f"{side}_apb_penable")
    pwr   = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwdata = getattr(dut, f"{side}_apb_pwdata")
    pstrb = getattr(dut, f"{side}_apb_pstrb")
    pready = getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 1
    pwdata.value = data
    pstrb.value = 0xF
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0


# ---------------------------------------------------------------------
# Bring-up sequencing.
# ---------------------------------------------------------------------
async def setup_and_por(dut, period_ns=20.0):
    cocotb.start_soon(Clock(dut.master_clk, int(round(period_ns * 1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  int(round(period_ns * 1000)), unit="ps").start())
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value = 0
        getattr(dut, f"{prefix}_apb_paddr").value = 0
        getattr(dut, f"{prefix}_apb_pwdata").value = 0
        getattr(dut, f"{prefix}_apb_pprot").value = 0
        getattr(dut, f"{prefix}_apb_pstrb").value = 0xF
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value  = 0; dut.s_hresetn.value  = 0
    await ClockCycles(dut.master_clk, 10)
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value  = 1; dut.s_hresetn.value  = 1
    await ClockCycles(dut.master_clk, 20)


async def lock_both(dut):
    await ctrl_write(dut, 'm', 0, 0x02)   # master, lock
    await ctrl_write(dut, 's', 0, 0x03)   # slave, lock
    await ClockCycles(dut.master_clk, 50)


async def wait_cal_done(dut, max_cycles=50_000):
    """Spin until both sides report cal_calibration_done=1, or timeout."""
    chunk = 200
    for _ in range(max_cycles // chunk):
        await ClockCycles(dut.master_clk, chunk)
        try:
            m_done = int(dut.m_cal_calibration_done.value)
            s_done = int(dut.s_cal_calibration_done.value)
        except ValueError:
            continue
        if m_done and s_done:
            return True
    return False


async def set_slot0_both(dut, val):
    await ctrl_write(dut, 'm', R8_SLOT0, val)
    await ctrl_write(dut, 's', R8_SLOT0, val)


async def recal_cycle(dut, hold_cycles=200, settle_cycles=200):
    """Replay the HW bringup_pair_converge.sh recal_cycle:
        slot0 = 0x3 (training+recal hold)  →  wait
        slot0 = 0x1 (recal falls → calibrator re-arms+sweeps)  →  wait
    """
    await set_slot0_both(dut, 0x3)
    await ClockCycles(dut.master_clk, hold_cycles)
    await set_slot0_both(dut, 0x1)
    await ClockCycles(dut.master_clk, settle_cycles)


async def drop_training_and_swreset_ll(dut):
    """Step 3+ of bringup_pair_converge.sh: drop training and toggle Wlink LL
    swreset+enable on both sides."""
    await set_slot0_both(dut, 0x0)
    await ClockCycles(dut.master_clk, 50)
    for val in (LL_CTRL_SWRESET_ON, LL_CTRL_SWRESET_OFF, LL_CTRL_ENABLED):
        await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, val)
        await apb_write(dut, 's', WL_LINK_ENABLE_RESET, val)
        await ClockCycles(dut.master_clk, 50)


# ---------------------------------------------------------------------
# Observation helper.
# ---------------------------------------------------------------------
def _fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_wlink.tl2wl.wlink_tidelinktl


async def _observe(dut, cycles):
    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    obs = dict(max_m=0, max_s=0, cr_m=False, cr_s=False,
               crack_m=False, crack_s=False)
    for _ in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        try:
            ms = int(m.state.value)
            ss = int(s.state.value)
        except ValueError:
            continue
        if ms > obs["max_m"]: obs["max_m"] = ms
        if ss > obs["max_s"]: obs["max_s"] = ss
        try:
            if int(m.cr_pkt_seen_rx.value): obs["cr_m"] = True
            if int(s.cr_pkt_seen_rx.value): obs["cr_s"] = True
            if int(m.crack_pkt_seen_rx.value): obs["crack_m"] = True
            if int(s.crack_pkt_seen_rx.value): obs["crack_s"] = True
        except (AttributeError, ValueError):
            pass
    return obs


def _log_state(dut, label):
    try:
        m_cal = int(dut.m_cal_cur_state.value)
        s_cal = int(dut.s_cal_cur_state.value)
        m_lock = int(dut.m_lane_locked_w.value)
        s_lock = int(dut.s_lane_locked_w.value)
        m_done = int(dut.m_cal_calibration_done.value)
        s_done = int(dut.s_cal_calibration_done.value)
        m_train = int(dut.m_cal_training_mode.value)
        s_train = int(dut.s_cal_training_mode.value)
        m_po = int(dut.m_phase_offset.value)
        s_po = int(dut.s_phase_offset.value)
    except Exception as e:
        dut._log.error(f"  [{label}] state read failed: {e!r}")
        return
    dut._log.info(
        f"  [{label}] M: cal={CAL_NAMES.get(m_cal,'?')} "
        f"locked=0x{m_lock:02x} done={m_done} train={m_train} "
        f"phase=0x{m_po:08x}"
    )
    dut._log.info(
        f"  [{label}] S: cal={CAL_NAMES.get(s_cal,'?')} "
        f"locked=0x{s_lock:02x} done={s_done} train={s_train} "
        f"phase=0x{s_po:08x}"
    )


# ---------------------------------------------------------------------
# TEST 1 — passive autocal then SW-coordinated bring-up.  Looks for
# the M→S vs S→M asymmetric cr_pkt_seen_rx signature.
# ---------------------------------------------------------------------
@cocotb.test()
async def test_chiplet_pair_cr_pkt_symmetric(dut):
    """Bring-up the chiplet pair with AUTOCAL_ENABLE=1 and check both
    cr_pkt_seen_rx latches by the end of the LL swreset cycle.

    Reports the asymmetric direction explicitly. Does NOT hard-fail on the
    asymmetric flag (this is a diagnostic env); only flags missing latches.
    """
    await setup_and_por(dut)
    await lock_both(dut)
    _log_state(dut, "post role_lock")

    # Phase 1 — let the natural autocal run.
    cal_done = await wait_cal_done(dut, max_cycles=50_000)
    _log_state(dut, "after passive autocal")
    if cal_done:
        dut._log.info("  passive autocal: BOTH sides reached calibration_done")
    else:
        dut._log.warning("  passive autocal: TIMED OUT before both done")

    # Phase 2 — recal_cycle (mirrors bringup_pair_converge.sh).
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    _log_state(dut, "after recal_cycle")

    # Phase 3 — drop training + LL swreset cycle.
    await drop_training_and_swreset_ll(dut)
    _log_state(dut, "after LL swreset cycle")

    # Phase 4 — observe cr/crack latches over ~5000 cycles.
    obs = await _observe(dut, 5000)
    dut._log.info(
        f"  M: max_state={obs['max_m']} ({FCSM_NAMES.get(obs['max_m'],'?')}) "
        f"cr={int(obs['cr_m'])} crack={int(obs['crack_m'])}"
    )
    dut._log.info(
        f"  S: max_state={obs['max_s']} ({FCSM_NAMES.get(obs['max_s'],'?')}) "
        f"cr={int(obs['cr_s'])} crack={int(obs['crack_s'])}"
    )

    asym_cr = obs["cr_m"] != obs["cr_s"]
    if asym_cr:
        bad = "slave" if not obs["cr_s"] else "master"
        good = "master" if not obs["cr_s"] else "slave"
        dut._log.error("*" * 70)
        dut._log.error(
            f"  M→S ASYMMETRIC cr_pkt_seen_rx — {good} latched, {bad} DID NOT")
        dut._log.error(
            "  This is the calibrator-PHY bug at the chiplet-pair scope.")
        dut._log.error("*" * 70)

    # The unit-level repro flag: AT LEAST ONE side must have NOT latched
    # cr_pkt_seen_rx for the HW symptom to be reproduced. If BOTH latched,
    # the wlink_pair-AUTOCAL=1 fold is symmetric and the bug needs the
    # tidelink_top wrapper context.
    both_latched = obs["cr_m"] and obs["cr_s"]
    if both_latched:
        dut._log.info(
            "  RESULT: BOTH cr_pkt_seen_rx latched at chiplet_pair scope. "
            "Bug requires tidelink_top wrapper context (FC adapter / returner / "
            "fifo / glue).")
    else:
        dut._log.info(
            "  RESULT: at least one cr_pkt_seen_rx FAILED to latch — "
            "bug REPRODUCED at chiplet_pair scope (calibrator-PHY).")

    # Hard assertion: both must latch. If this fails, the unit-level
    # reproduces the symptom.
    assert obs["cr_m"], (
        f"master cr_pkt_seen_rx never latched at chiplet_pair scope. "
        f"obs={obs}")
    assert obs["cr_s"], (
        f"slave  cr_pkt_seen_rx never latched at chiplet_pair scope. "
        f"obs={obs}")


# ---------------------------------------------------------------------
# TEST 2 — same path but DIAGNOSTIC-ONLY (never fails; just reports).
# ---------------------------------------------------------------------
@cocotb.test()
async def test_chiplet_pair_cr_pkt_diagnostic(dut):
    """Same sequence as test_01, but never asserts. Always reports the
    asymmetric flag in the log."""
    await setup_and_por(dut)
    await lock_both(dut)
    await wait_cal_done(dut, max_cycles=50_000)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    obs = await _observe(dut, 5000)
    dut._log.info(
        f"  diagnostic: cr_m={int(obs['cr_m'])} cr_s={int(obs['cr_s'])} "
        f"crack_m={int(obs['crack_m'])} crack_s={int(obs['crack_s'])} "
        f"max_m={obs['max_m']} max_s={obs['max_s']} "
        f"asym_cr={obs['cr_m'] ^ obs['cr_s']}"
    )

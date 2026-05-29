"""Passive calibrator/PHY state probe — runs bring-up on a paired
axi_chiplet_controller with AUTOCAL_ENABLE=1 and just observes calibrator
+ FCSM state on BOTH sides, dumping a histogram.

This is the *diagnostic* leg of the new unit-level env. No assertions; the
test always passes. The output gives Agent D (the fix author) a fast read
on whether the calibrator FSM is parked, sweeping, or in DONE on each side
— and whether `lane_locked_w` reaches 0xff symmetrically.

Hierarchical paths used (all mirrored at top level by tb_top.sv):
  m_cal_cur_state, s_cal_cur_state           — tidelink_phy_align_calibrator.cur_state
  m_lane_locked_w, s_lane_locked_w           — tidelink_lane_checker.lane_locked
  m_cal_training_mode, s_cal_training_mode   — calibrator.training_mode
  m_cal_calibration_done, s_cal_calibration_done — calibrator.calibration_done
  m_phase_offset / s_phase_offset            — calibrator.phase_offset[31:0] (4b ×8)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from collections import Counter

CAL_STATE_NAMES = {
    0: "IDLE", 1: "ARM", 2: "SWEEP", 3: "FINISH",
    4: "DONE", 5: "CANCEL", 6: "HOLD",
}

# FCSM state names (FC.scala).
FCSM_NAMES = {
    0: "IDLE", 1: "SEND_CR1", 2: "SEND_CR2", 3: "LE_WAIT",
    4: "LINK_IDLE", 5: "LINK_DATA", 6: "?6", 7: "SEND_NACK",
}


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


async def lock_both(dut):
    """Latch role_lock on master (role=0) and slave (role=1) via ctrl_reg."""
    await ctrl_write(dut, 'm', 0, 0x02)   # master, lock
    await ctrl_write(dut, 's', 0, 0x03)   # slave, lock
    await ClockCycles(dut.master_clk, 50)


def _safe_int(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


def _fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_wlink.tl2wl.wlink_tidelinktl


@cocotb.test()
async def test_passive_calibrator_probe(dut):
    """Bring up the pair (role-lock only) and watch calibrator + FCSM for
    10_000 cycles. Dump a histogram of cal_state on both sides + the final
    lane_locked / phase_offset values. No assertions — always passes; we
    only want the diagnostic numbers.
    """
    await setup_and_por(dut)
    await lock_both(dut)

    dut._log.info("---- Hierarchical handles (sanity) ----")
    try:
        dut._log.info(
            f"  cal cur_state @ M  = {CAL_STATE_NAMES.get(int(dut.m_cal_cur_state.value), '?')}, "
            f"S = {CAL_STATE_NAMES.get(int(dut.s_cal_cur_state.value), '?')}")
        dut._log.info(
            f"  lane_locked_w  M = 0x{int(dut.m_lane_locked_w.value):02x}, "
            f"S = 0x{int(dut.s_lane_locked_w.value):02x}")
        dut._log.info(
            f"  cal_training_mode M = {int(dut.m_cal_training_mode.value)}, "
            f"S = {int(dut.s_cal_training_mode.value)}")
        dut._log.info(
            f"  cal_calibration_done M = {int(dut.m_cal_calibration_done.value)}, "
            f"S = {int(dut.s_cal_calibration_done.value)}")
        dut._log.info(
            f"  phase_offset @ M = 0x{int(dut.m_phase_offset.value):08x}, "
            f"S = 0x{int(dut.s_phase_offset.value):08x}")
    except Exception as e:
        dut._log.error(f"  hierarchical handle read failed: {e!r}")

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")

    # ------------ Histogram sweep ----------------------------------------
    m_cal_hist = Counter()
    s_cal_hist = Counter()
    m_fcsm_hist = Counter()
    s_fcsm_hist = Counter()
    m_locked_hist = Counter()
    s_locked_hist = Counter()
    m_phase_first = None; m_phase_last = 0
    s_phase_first = None; s_phase_last = 0

    cycles_to_sample = 10_000
    for _ in range(cycles_to_sample):
        await RisingEdge(dut.master_clk)
        m_cal = _safe_int(dut.m_cal_cur_state)
        s_cal = _safe_int(dut.s_cal_cur_state)
        m_cal_hist[m_cal] += 1
        s_cal_hist[s_cal] += 1
        m_fcsm_hist[_safe_int(m_fcsm.state)] += 1
        s_fcsm_hist[_safe_int(s_fcsm.state)] += 1
        m_locked_hist[_safe_int(dut.m_lane_locked_w)] += 1
        s_locked_hist[_safe_int(dut.s_lane_locked_w)] += 1
        m_phase_last = _safe_int(dut.m_phase_offset)
        s_phase_last = _safe_int(dut.s_phase_offset)
        if m_phase_first is None and m_phase_last != 0:
            m_phase_first = m_phase_last
        if s_phase_first is None and s_phase_last != 0:
            s_phase_first = s_phase_last

    dut._log.info("=" * 70)
    dut._log.info(f"Calibrator-state histogram over {cycles_to_sample} apb_clk cycles")
    dut._log.info("=" * 70)
    def _fmt_cal_hist(h):
        return ", ".join(
            f"{CAL_STATE_NAMES.get(k, f'?{k}')}={v}"
            for k, v in sorted(h.items()))
    def _fmt_fcsm_hist(h):
        return ", ".join(
            f"{FCSM_NAMES.get(k, f'?{k}')}={v}"
            for k, v in sorted(h.items()))
    dut._log.info(f"  cal M: {_fmt_cal_hist(m_cal_hist)}")
    dut._log.info(f"  cal S: {_fmt_cal_hist(s_cal_hist)}")
    dut._log.info(f"  FCSM M: {_fmt_fcsm_hist(m_fcsm_hist)}")
    dut._log.info(f"  FCSM S: {_fmt_fcsm_hist(s_fcsm_hist)}")
    dut._log.info(f"  lane_locked M histogram: "
                  f"{[(f'0x{k:02x}', v) for k, v in m_locked_hist.most_common(5)]}")
    dut._log.info(f"  lane_locked S histogram: "
                  f"{[(f'0x{k:02x}', v) for k, v in s_locked_hist.most_common(5)]}")
    dut._log.info(f"  phase_offset M final 0x{m_phase_last:08x} (first-nonzero 0x{m_phase_first or 0:08x})")
    dut._log.info(f"  phase_offset S final 0x{s_phase_last:08x} (first-nonzero 0x{s_phase_first or 0:08x})")

    # Asymmetry summary
    m_done_frac = m_cal_hist.get(4, 0) / cycles_to_sample
    s_done_frac = s_cal_hist.get(4, 0) / cycles_to_sample
    dut._log.info("-" * 70)
    dut._log.info(
        f"  CAL DONE residency: M={m_done_frac:.1%}  S={s_done_frac:.1%}  "
        f"({'symmetric' if abs(m_done_frac - s_done_frac) < 0.05 else 'ASYMMETRIC'})")
    m_locked_done = max(m_locked_hist, default=0)
    s_locked_done = max(s_locked_hist, default=0)
    dut._log.info(
        f"  max lane_locked seen: M=0x{m_locked_done:02x}  S=0x{s_locked_done:02x}")
    dut._log.info("=" * 70)

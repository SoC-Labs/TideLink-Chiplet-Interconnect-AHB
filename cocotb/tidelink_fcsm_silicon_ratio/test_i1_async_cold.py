"""I1 async + COLD bring-up repro (sim/i1-repro-silicon-ratio).

GOAL: reproduce, IN SIMULATION, the I1 silicon failure where re-pointing the 5
AXI FC nodes (WlinkGenericFCSM{,_1..4}) to the recovery-capable local_overrides
copies regresses d2d bring-up:  cr_seen=0 / cal_done=0 / fcsm=0 on BOTH dies.

Why the EXISTING env (test_fcsm_silicon_ratio.py) cannot show it
  * it forces `tb_early_exit_force_q` (calibrator bypass) -> cal never exercises
    the true cr_pkt_seen-gated S_VALIDATE path;
  * it runs both dies off ONE shared ref_clk -> zero plesiochronous stress;
  * it models "marginal link" with an artificial periodic LL re-bring-up.
On a clean SYNChronous link with the bypass, the override comes up cr=1 GREEN
(the `control` target passes) -- so the silicon RED must live in conditions the
existing env suppresses.

What THIS test changes (the missing instrument)
  1. COLD: no tb_early_exit bypass. cal walks sweep -> S_HOLD -> the true
     cr_pkt_seen-gated S_VALIDATE. TB_TOP_CAL_FAST shrinks only the S_HOLD /
     S_VALIDATE *windows* (defparam) so the cold run is sim-feasible; the
     cr_pkt_seen gate stays armed. (VAL_TIMEOUT_TO_DONE=1 in the wrapper means
     cal_done still times out to DONE, so the load-bearing oracle is
     cr_pkt_seen_rx in data mode, NOT cal_done.)
  2. ASYNC: TB_TOP_SPLIT_REFCLK gives the slave die its own PHY reference
     (ref_clk_s) with an I1_REF_PPM ppm / I1_REF_PHASE_PS phase offset -> the two
     dies' io_tx_clk (= ref/16) and forwarded pad clocks are genuinely
     asynchronous (silicon's two-oscillator condition; the PHY is
     source-synchronous / no shared PLL, so this is legal but stresses every
     TX<->peer-RX CDC and the pad clock-gate window).
  3. POR STAGGER: I1_POR_STAGGER_HCLK holds the slave die in reset past the
     master's release (deploy-skew emulation) via s_por_gate.
  4. SKID: compile-time TB_TOP_SKID_BITS bit-level RX capture-phase skew.

ORACLE (both dies): cr_pkt_seen_rx (the sticky sideband CR-seen latch the
SWI_LANE_STATUS bit[23] reports) + the SWI_LANE_STATUS 4-tuple.

The Makefile drives the four INSTRUMENT-TRUST-GATE configs against the SAME
test body (identical async knobs, only FCSM_SRC / SPLIT_REFCLK differ):
  make i1_deps        FCSM_SRC=deps    + async   -> EXPECT GREEN (cr=1 both)
  make i1_override    FCSM_SRC=override + async   -> the RED candidate
  make i1_emitfix     FCSM_SRC=emitfix + async   -> must ALSO stay RED
  make i1_poscontrol  FCSM_SRC=override, SYNC     -> EXPECT GREEN (TB can read cr=1)
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer, Event
from cocotb.utils import get_sim_time

from pair_v2_common import (PairV2TB, REF_CLK_PERIOD_NS, CLK_PERIOD_NS,
                            ST_LANE_LOCKED, ST_CAL_DONE, ST_CR_SEEN,
                            ST_CRACK_SEEN, ST_LLRX_VALID, APB_R8_SWI_LANE_STATUS)

REF_PPM          = float(os.environ.get("I1_REF_PPM", "0"))
REF_PHASE_PS     = int(os.environ.get("I1_REF_PHASE_PS", "0"))
POR_STAGGER_HCLK = int(os.environ.get("I1_POR_STAGGER_HCLK", "0"))
OBS_CHUNKS       = int(os.environ.get("OBS_CHUNKS", "800"))


class ColdAsyncTB(PairV2TB):
    """PairV2TB + an independent slave PHY reference clock (ref_clk_s)."""

    def __init__(self, dut):
        super().__init__(dut)          # starts shared hclk + master ref_clk
        base_ps = int(round(REF_CLK_PERIOD_NS * 1000))
        slave_ps = int(round(base_ps * (1.0 + REF_PPM * 1e-6)))
        self._slave_ref_ps = slave_ps
        self.log.info(
            f"[ColdAsyncTB] master ref={base_ps} ps  slave ref_clk_s={slave_ps} ps "
            f"(ppm={REF_PPM:+g} phase={REF_PHASE_PS} ps)  por_stagger={POR_STAGGER_HCLK} hclk")
        cocotb.start_soon(self._start_slave_ref())

    async def _start_slave_ref(self):
        # Optional static phase offset (independent-oscillator random phase).
        if REF_PHASE_PS:
            await Timer(REF_PHASE_PS, unit="ps")
        cocotb.start_soon(
            Clock(self.dut.ref_clk_s, self._slave_ref_ps, unit="ps").start())

    async def cold_reset(self, stagger_hclk):
        """POR both dies; optionally hold the SLAVE in reset `stagger_hclk`
        cycles past the master's release (via s_por_gate)."""
        self.dut.m_por_gate.value = 1
        self.dut.s_por_gate.value = 1
        self.dut.poresetn.value = 0
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 20)
        if stagger_hclk > 0:
            self.dut.s_por_gate.value = 0     # keep slave squashed
        self.dut.poresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        if stagger_hclk > 0:
            await ClockCycles(self.dut.hclk, stagger_hclk)
            self.dut.s_por_gate.value = 1     # release slave later
        await ClockCycles(self.dut.hclk, 50)


def _tuple(tb, side, st):
    return (f"locked=0x{ST_LANE_LOCKED(st):02x} cal_done={ST_CAL_DONE(st)} "
            f"cal={tb.cal_state_name(side)} fcsm={tb.fcsm_state(side)} "
            f"cr_seen={ST_CR_SEEN(st)} crack={ST_CRACK_SEEN(st)} "
            f"llrx_v={ST_LLRX_VALID(st)} cr_pkt_seen_rx={tb.fcsm_cr_seen(side)}")


async def _run_cold(dut, expect_cr):
    tb = ColdAsyncTB(dut)
    await tb.cold_reset(POR_STAGGER_HCLK)

    # ---- COLD bring-up: NO force_calibrator_sim_bypass ----
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    dut._log.info(f"role_locked both = {locked} "
                  f"(m={int(dut.m_role_locked.value)} s={int(dut.s_role_locked.value)})")
    assert locked, "role_locked did not assert on both dies (bring-up dead before cal)"

    m_st, s_st = await tb.wait_cal_done()
    dut._log.info(f"post-cal (true cold path, no bypass): "
                  f"M cal_done={ST_CAL_DONE(m_st)} cal={tb.cal_state_name('m')} | "
                  f"S cal_done={ST_CAL_DONE(s_st)} cal={tb.cal_state_name('s')}")

    await tb.do_to_data_mode()

    # ---- observe cr_pkt_seen_rx (sticky) over a long data-mode window ----
    m_cr_first = s_cr_first = -1
    for i in range(OBS_CHUNKS):
        await ClockCycles(dut.hclk, 50)
        if m_cr_first < 0 and tb.fcsm_cr_seen("m") == 1:
            m_cr_first = (i + 1) * 50
        if s_cr_first < 0 and tb.fcsm_cr_seen("s") == 1:
            s_cr_first = (i + 1) * 50
        if m_cr_first >= 0 and s_cr_first >= 0:
            break
        if (i + 1) % 150 == 0:
            dut._log.info(f"  [+{(i+1)*50} hclk] m.cr_pkt_seen_rx={tb.fcsm_cr_seen('m')} "
                          f"s.cr_pkt_seen_rx={tb.fcsm_cr_seen('s')} "
                          f"m.fcsm={tb.fcsm_state('m')} s.fcsm={tb.fcsm_state('s')}")

    snap = await tb.snapshot("final")
    m_st, s_st = snap["m_st"], snap["s_st"]
    dut._log.info("  === I1 4-tuple oracle ===")
    dut._log.info(f"    [M] {_tuple(tb, 'm', m_st)}  cr_first@{m_cr_first} hclk")
    dut._log.info(f"    [S] {_tuple(tb, 's', s_st)}  cr_first@{s_cr_first} hclk")

    m_cr = tb.fcsm_cr_seen("m")
    s_cr = tb.fcsm_cr_seen("s")
    verdict = "GREEN (cr=1 both)" if (m_cr == 1 and s_cr == 1) else "RED (cr_seen stuck 0)"
    dut._log.info(f"  === VERDICT: {verdict}  (m_cr={m_cr} s_cr={s_cr}, "
                  f"FCSM_SRC={os.environ.get('FCSM_SRC','?')}, "
                  f"split={os.environ.get('SPLIT_REFCLK','?')}, ppm={REF_PPM}) ===")

    if expect_cr:
        assert m_cr == 1 and s_cr == 1, (
            f"I1: cr_pkt_seen_rx did NOT reach 1 on both dies "
            f"(m={m_cr} s={s_cr}) -- silicon RED reproduced / or link dead. "
            f"M[{_tuple(tb,'m',m_st)}] S[{_tuple(tb,'s',s_st)}]")
    return m_cr, s_cr


CR_ID = 0x44  # swi_cr_id POR default (WlinkGenericFCSM_6.v)


def _router(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.txrouter


def _txclk(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy_link_tx_tx_link_clk


def _rxclk(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy_link_rx_rx_link_clk


async def _grant_mon(tb, side, cnt, stop):
    """Count per-channel router grants (auto_in_N_advance) + first ch6 CR emit."""
    rt = _router(tb, side)
    clk = _txclk(tb, side)
    while not stop.is_set():
        await RisingEdge(clk)
        for ch in range(8):
            try:
                if int(getattr(rt, f"auto_in_{ch}_advance").value):
                    cnt[f"{side}_ch{ch}"] += 1
                    if ch == 6:
                        try:
                            did = int(getattr(rt, "auto_in_6_data_id").value)
                        except ValueError:
                            did = -1
                        if did == CR_ID:
                            cnt[f"{side}_ch6_cr"] += 1
                            if cnt[f"{side}_ch6_cr_first_ns"] < 0:
                                cnt[f"{side}_ch6_cr_first_ns"] = get_sim_time("ns")
            except ValueError:
                pass


async def _rx_cr_mon(tb, side, cnt, stop):
    """Detect first pkt_is_cr_pkt pulse at this die's sideband RX decode."""
    node = tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl
    clk = _rxclk(tb, side)
    while not stop.is_set():
        await RisingEdge(clk)
        try:
            if int(node.pkt_is_cr_pkt.value):
                cnt[f"{side}_rx_cr"] += 1
                if cnt[f"{side}_rx_cr_first_ns"] < 0:
                    cnt[f"{side}_rx_cr_first_ns"] = get_sim_time("ns")
        except (AttributeError, ValueError):
            pass


@cocotb.test()
async def test_i1_mechanism_probe(dut):
    """Diagnostic: measure the sideband (ch6) grant share + CR-emit / CR-decode
    timing under the SAME cold+async point, so deps vs override can be compared
    for the panel's 'ch6 starvation' mechanism. Never asserts RED/GREEN — it
    reports counters. Run twice (FCSM_SRC=deps, FCSM_SRC=override)."""
    from collections import defaultdict
    dut._log.info(f"=== I1 mechanism probe === FCSM_SRC={os.environ.get('FCSM_SRC','?')} "
                  f"split={os.environ.get('SPLIT_REFCLK','?')} ppm={REF_PPM} "
                  f"stagger={POR_STAGGER_HCLK}")
    tb = ColdAsyncTB(dut)
    await tb.cold_reset(POR_STAGGER_HCLK)
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert"
    await tb.wait_cal_done()

    cnt = defaultdict(int)
    for side in ("m", "s"):
        cnt[f"{side}_ch6_cr_first_ns"] = -1
        cnt[f"{side}_rx_cr_first_ns"] = -1
    stop = Event()
    mons = []
    for side in ("m", "s"):
        mons.append(cocotb.start_soon(_grant_mon(tb, side, cnt, stop)))
        mons.append(cocotb.start_soon(_rx_cr_mon(tb, side, cnt, stop)))

    await tb.do_to_data_mode()
    await ClockCycles(dut.hclk, 20000)
    stop.set()
    await ClockCycles(dut.hclk, 5)

    dut._log.info("  --- router grant counts (per channel, both dies) ---")
    for side in ("m", "s"):
        tot = sum(cnt[f"{side}_ch{ch}"] for ch in range(8))
        share = (100.0 * cnt[f"{side}_ch6"] / tot) if tot else 0.0
        chs = " ".join(f"ch{ch}={cnt[f'{side}_ch{ch}']}" for ch in range(8))
        dut._log.info(f"    [{side}] {chs}  total={tot}  ch6_share={share:.1f}%")
        dut._log.info(f"    [{side}] ch6 CR-emits={cnt[f'{side}_ch6_cr']} "
                      f"first@{cnt[f'{side}_ch6_cr_first_ns']}ns | "
                      f"RX CR-decodes={cnt[f'{side}_rx_cr']} "
                      f"first@{cnt[f'{side}_rx_cr_first_ns']}ns | "
                      f"cr_pkt_seen_rx={tb.fcsm_cr_seen(side)}")


@cocotb.test()
async def test_i1_cold_bringup_cr_seen(dut):
    """The instrument. GREEN iff cr_pkt_seen_rx==1 on BOTH dies after a genuine
    cold + (optionally async) bring-up. The Makefile target selects FCSM_SRC and
    the async knobs; EXPECT_CR (env) sets whether this config is expected GREEN."""
    expect_cr = os.environ.get("EXPECT_CR", "1") == "1"
    dut._log.info(
        f"=== I1 cold/async repro ===  FCSM_SRC={os.environ.get('FCSM_SRC','?')} "
        f"SPLIT_REFCLK={os.environ.get('SPLIT_REFCLK','?')} ppm={REF_PPM} "
        f"phase={REF_PHASE_PS}ps stagger={POR_STAGGER_HCLK} "
        f"skid={os.environ.get('SKID','0')} EXPECT_CR={expect_cr}")
    await _run_cold(dut, expect_cr)

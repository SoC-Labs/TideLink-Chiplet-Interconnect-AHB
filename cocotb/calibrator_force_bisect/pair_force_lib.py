"""Shared library for calibrator force-bisect cocotb tests.

Provides:
    - PairTB harness (subset of cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py)
    - hierarchical-force helpers
    - the common M→S / S→M doorbell probe sequence

Each variant test imports run_force_bisect() and supplies a force callback
that gets the PairTB at two stages:
    * pre-reset      (so forces effective from t=0)
    * post-cal-done  (so forces effective only after S_DONE)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release


# --- Register addresses (mirror of test_tidelink_pair_doorbell.py) -------
APB_WL_LINK_ENABLE_RESET = 0x0208
APB_TIDELINK_BASE        = 0x2000
OFF_CREDIT_COUNT        = 0x00C
OFF_DOORBELL            = 0x014
OFF_RELEASED_ACC        = 0x020
OFF_DOORBELL_RESP_ACC   = 0x024
OFF_PAIR_CREDIT_COUNTER = 0x028
OFF_R8_SLOT0            = 0x100
OFF_R8_SLOT2            = 0x108
OFF_ROLE_CFG            = 0x080

APB_ROLE_CFG            = APB_TIDELINK_BASE + OFF_ROLE_CFG
APB_R8_SLOT0            = APB_TIDELINK_BASE + OFF_R8_SLOT0
APB_R8_SWI_LANE_STATUS  = APB_TIDELINK_BASE + OFF_R8_SLOT2
APB_DOORBELL            = APB_TIDELINK_BASE + OFF_DOORBELL
APB_RELEASED_ACC        = APB_TIDELINK_BASE + OFF_RELEASED_ACC
APB_DOORBELL_RESP_ACC   = APB_TIDELINK_BASE + OFF_DOORBELL_RESP_ACC
APB_PAIR_CREDIT_COUNTER = APB_TIDELINK_BASE + OFF_PAIR_CREDIT_COUNTER
APB_CREDIT_COUNT        = APB_TIDELINK_BASE + OFF_CREDIT_COUNT

ROLE_CFG_MASTER_LOCK = 0x02
ROLE_CFG_SLAVE_LOCK  = 0x03

LL_BOOTSTRAP_SWRESET_ON  = 0x00027f08
LL_BOOTSTRAP_SWRESET_OFF = 0x00027f00
LL_BOOTSTRAP_ENABLE      = 0x00027f07

R8_SLOT0_TRAIN_RECAL = 0x3
R8_SLOT0_TRAIN_ONLY  = 0x1
R8_SLOT0_OFF         = 0x0

CLK_PERIOD_NS    = 20.0
REF_CLK_PERIOD_NS = 8.0


class APBMaster:
    def __init__(self, dut, clk, prefix):
        self._dut = dut
        self._clk = clk
        self._psel    = getattr(dut, f"{prefix}_apb_psel")
        self._penable = getattr(dut, f"{prefix}_apb_penable")
        self._pwrite  = getattr(dut, f"{prefix}_apb_pwrite")
        self._paddr   = getattr(dut, f"{prefix}_apb_paddr")
        self._pwdata  = getattr(dut, f"{prefix}_apb_pwdata")
        self._pstrb   = getattr(dut, f"{prefix}_apb_pstrb")
        self._pprot   = getattr(dut, f"{prefix}_apb_pprot")
        self._prdata  = getattr(dut, f"{prefix}_apb_prdata")
        self._pready  = getattr(dut, f"{prefix}_apb_pready")
        self.idle()

    def idle(self):
        self._psel.value    = 0
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = 0
        self._pwdata.value  = 0
        self._pstrb.value   = 0xF
        self._pprot.value   = 0

    async def write(self, addr, data, timeout=200):
        addr15 = addr & 0x7FFF
        await RisingEdge(self._clk)
        self._psel.value    = 1
        self._paddr.value   = addr15
        self._pwrite.value  = 1
        self._pwdata.value  = data
        self._pstrb.value   = 0xF
        self._pprot.value   = 0
        self._penable.value = 0
        await RisingEdge(self._clk)
        self._penable.value = 1
        for _ in range(timeout):
            await RisingEdge(self._clk)
            if int(self._pready.value):
                break
        else:
            raise TimeoutError(f"APB write to 0x{addr:04x} did not complete")
        self.idle()

    async def read(self, addr, timeout=200):
        addr15 = addr & 0x7FFF
        await RisingEdge(self._clk)
        self._psel.value    = 1
        self._paddr.value   = addr15
        self._pwrite.value  = 0
        self._pwdata.value  = 0
        self._pstrb.value   = 0xF
        self._pprot.value   = 0
        self._penable.value = 0
        await RisingEdge(self._clk)
        self._penable.value = 1
        for _ in range(timeout):
            await RisingEdge(self._clk)
            if int(self._pready.value):
                try:
                    data = int(self._prdata.value)
                except ValueError:
                    data = 0
                self.idle()
                return data
        self.idle()
        raise TimeoutError(f"APB read from 0x{addr:04x} did not complete")


class PairTB:
    CAL_STATE_NAMES = {0: "IDLE", 1: "ARM", 2: "SWEEP", 3: "FINISH",
                       4: "DONE", 5: "CANCEL", 6: "HOLD"}

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
        )
        cocotb.start_soon(
            Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
        )

        for prefix in ("m", "s"):
            getattr(dut, f"{prefix}_ahb_tx_hsel").value     = 0
            getattr(dut, f"{prefix}_ahb_tx_haddr").value    = 0
            getattr(dut, f"{prefix}_ahb_tx_htrans").value   = 0
            getattr(dut, f"{prefix}_ahb_tx_hsize").value    = 2
            getattr(dut, f"{prefix}_ahb_tx_hwrite").value   = 0
            getattr(dut, f"{prefix}_ahb_tx_hwdata").value   = 0
            getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1

            getattr(dut, f"{prefix}_ahb_fifo_hsel").value     = 0
            getattr(dut, f"{prefix}_ahb_fifo_haddr").value    = 0
            getattr(dut, f"{prefix}_ahb_fifo_htrans").value   = 0
            getattr(dut, f"{prefix}_ahb_fifo_hsize").value    = 2
            getattr(dut, f"{prefix}_ahb_fifo_hwrite").value   = 0
            getattr(dut, f"{prefix}_ahb_fifo_hwdata").value   = 0
            getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

        self.m_apb = APBMaster(dut, dut.hclk, "m")
        self.s_apb = APBMaster(dut, dut.hclk, "s")

    # ----- Reset --------------------------------------------------------------
    async def reset(self):
        self.dut.poresetn.value = 0
        self.dut.hresetn.value  = 0
        await ClockCycles(self.dut.hclk, 20)
        self.dut.poresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value  = 1
        await ClockCycles(self.dut.hclk, 50)

    # ----- Hierarchical handles ---------------------------------------------
    def chiplet(self, side):
        return (self.dut.u_master if side == "m" else self.dut.u_slave).u_chiplet_controller

    def calibrator(self, side):
        return self.chiplet(side).u_calibrator

    # ----- Hierarchical probes ----------------------------------------------
    def cal_state(self, side):
        try:
            return int(self.calibrator(side).cur_state.value)
        except (AttributeError, ValueError):
            return -1

    def cal_state_name(self, side):
        return self.CAL_STATE_NAMES.get(self.cal_state(side), f"?{self.cal_state(side)}")

    def fcsm(self, side):
        top = self.dut.u_master if side == "m" else self.dut.u_slave
        return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl

    def fcsm_cr_pkt_seen(self, side):
        try:
            return int(self.fcsm(side).cr_pkt_seen_rx.value)
        except (AttributeError, ValueError):
            return -1

    def fcsm_crack_pkt_seen(self, side):
        try:
            return int(self.fcsm(side).crack_pkt_seen_rx.value)
        except (AttributeError, ValueError):
            return -1

    def fcsm_state(self, side):
        try:
            return int(self.fcsm(side).state.value)
        except (AttributeError, ValueError):
            return -1

    def _fc(self, side):
        top = self.dut.u_master if side == "m" else self.dut.u_slave
        return top.u_fc_adapter

    def fc_a2l_valid(self, side):
        try:
            return int(self._fc(side).tl_fc_a2l_valid.value)
        except (AttributeError, ValueError):
            return -1

    def fc_l2a_valid(self, side):
        try:
            return int(self._fc(side).tl_fc_l2a_valid.value)
        except (AttributeError, ValueError):
            return -1

    # ----- Bringup primitives ------------------------------------------------
    async def do_role_lock(self):
        await self.m_apb.write(APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK)
        await self.s_apb.write(APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK)
        await ClockCycles(self.dut.hclk, 200)

    async def wait_role_locked(self, max_cycles=20000):
        for _ in range(max_cycles // 50):
            await ClockCycles(self.dut.hclk, 50)
            try:
                if (int(self.dut.m_role_locked.value) == 1 and
                    int(self.dut.s_role_locked.value) == 1):
                    return True
            except ValueError:
                pass
        return False

    async def wait_cal_done(self, max_cycles=500000):
        m_st = s_st = 0
        for _ in range(max_cycles // 200):
            await ClockCycles(self.dut.hclk, 200)
            try:
                m_st = await self.m_apb.read(APB_R8_SWI_LANE_STATUS)
                s_st = await self.s_apb.read(APB_R8_SWI_LANE_STATUS)
            except TimeoutError:
                continue
            m_done = (m_st >> 16) & 1
            s_done = (s_st >> 16) & 1
            if m_done and s_done:
                return m_st, s_st
        return m_st, s_st

    async def do_to_data_mode(self):
        await self.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
        await self.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
        await ClockCycles(self.dut.hclk, 20)
        for val in (LL_BOOTSTRAP_SWRESET_ON,
                    LL_BOOTSTRAP_SWRESET_OFF,
                    LL_BOOTSTRAP_ENABLE):
            await self.m_apb.write(APB_WL_LINK_ENABLE_RESET, val)
            await self.s_apb.write(APB_WL_LINK_ENABLE_RESET, val)
            await ClockCycles(self.dut.hclk, 20)

    async def watch_fc_pulses(self, n_cycles, label=""):
        m_a2l = m_l2a = s_a2l = s_l2a = 0
        for _ in range(n_cycles):
            await RisingEdge(self.dut.hclk)
            if self.fc_a2l_valid("m") == 1: m_a2l += 1
            if self.fc_l2a_valid("m") == 1: m_l2a += 1
            if self.fc_a2l_valid("s") == 1: s_a2l += 1
            if self.fc_l2a_valid("s") == 1: s_l2a += 1
        self.log.info(
            f"  [{label}] FC valid-cycle counts over {n_cycles} cy: "
            f"M(a2l={m_a2l},l2a={m_l2a})  S(a2l={s_a2l},l2a={s_l2a})"
        )
        return dict(m_a2l=m_a2l, m_l2a=m_l2a, s_a2l=s_a2l, s_l2a=s_l2a)

    async def snapshot(self, label):
        m_st = await self.m_apb.read(APB_R8_SWI_LANE_STATUS)
        s_st = await self.s_apb.read(APB_R8_SWI_LANE_STATUS)
        m_pcc = await self.m_apb.read(APB_PAIR_CREDIT_COUNTER)
        s_pcc = await self.s_apb.read(APB_PAIR_CREDIT_COUNTER)
        m_cr  = self.fcsm_cr_pkt_seen("m")
        s_cr  = self.fcsm_cr_pkt_seen("s")
        m_cra = self.fcsm_crack_pkt_seen("m")
        s_cra = self.fcsm_crack_pkt_seen("s")
        self.log.info(
            f"  [{label}] M: locked=0x{m_st & 0xff:02x} done={(m_st>>16)&1} "
            f"cal={self.cal_state_name('m')} fcsm={self.fcsm_state('m')} "
            f"cr={m_cr} crack={m_cra} pcc={m_pcc}"
        )
        self.log.info(
            f"  [{label}] S: locked=0x{s_st & 0xff:02x} done={(s_st>>16)&1} "
            f"cal={self.cal_state_name('s')} fcsm={self.fcsm_state('s')} "
            f"cr={s_cr} crack={s_cra} pcc={s_pcc}"
        )
        return dict(
            m_lane_status=m_st, s_lane_status=s_st,
            m_pair_credit=m_pcc, s_pair_credit=s_pcc,
            m_cr_seen=m_cr, s_cr_seen=s_cr,
            m_crack_seen=m_cra, s_crack_seen=s_cra,
        )


# ===========================================================================
# Variant runner: drives the full bringup with pre/post-cal-done force hooks
# ===========================================================================

async def run_variant(dut, variant_name,
                      pre_reset_force=None,
                      post_cal_done_force=None,
                      m_to_s_required=True,
                      cal_done_max_cycles=500000):
    """Run a bringup + doorbell probe with optional hierarchical forces.

    Args:
        pre_reset_force(tb):     async callback applied BEFORE reset is released
        post_cal_done_force(tb): async callback applied AFTER both cal_done=1

    Returns dict with results suitable for the bisect table.
    """
    tb = PairTB(dut)
    tb.log.info(f"=== VARIANT {variant_name} ===")

    # Apply forces that need to be effective from t=0
    if pre_reset_force is not None:
        await pre_reset_force(tb)

    await tb.reset()

    # Some forces (notably the constant-zero forces) need to be re-asserted
    # after reset because reset of internal regs may have cleared them; the
    # pre_reset_force callback is responsible for that if needed. Cocotb's
    # Force is sticky across reset for nets/wires, but we re-call to be safe.
    if pre_reset_force is not None:
        await pre_reset_force(tb)

    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    tb.log.info(f"role_locked: M={int(tb.dut.m_role_locked.value)} "
                f"S={int(tb.dut.s_role_locked.value)}  "
                f"({'PASS' if locked else 'TIMEOUT'})")

    m_st, s_st = await tb.wait_cal_done(max_cycles=cal_done_max_cycles)
    m_done = (m_st >> 16) & 1
    s_done = (s_st >> 16) & 1
    tb.log.info(f"cal_done: M={m_done} S={s_done}  "
                f"M_status=0x{m_st:08x} S_status=0x{s_st:08x}")

    if post_cal_done_force is not None:
        tb.log.info("Applying post-cal-done force...")
        await post_cal_done_force(tb)
        await ClockCycles(tb.dut.hclk, 100)

    snap_p1 = await tb.snapshot("end-of-Phase1")

    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)
    snap_p2 = await tb.snapshot("after to_data_mode")

    # ----- M→S doorbell probe -------------------------------------------
    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_before = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"DOORBELL_RESP_ACC before M→S: M={m_db_before} S={s_db_before}")

    await tb.m_apb.write(APB_DOORBELL, 1)
    m2s_counts = await tb.watch_fc_pulses(2000, "M doorbell")

    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_after = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"DOORBELL_RESP_ACC after M→S: M={m_db_after} S={s_db_after}")

    m2s_pass = (s_db_after > s_db_before) or (m_db_after > m_db_before)

    # ----- S→M doorbell probe -------------------------------------------
    # Re-read post-M2S accumulators (W-add/R-clear so the read above already
    # cleared them; treat now as the new "before" baseline).
    m_db_before2 = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s_db_before2 = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)

    await tb.s_apb.write(APB_DOORBELL, 1)
    s2m_counts = await tb.watch_fc_pulses(2000, "S doorbell")

    m_db_after2 = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s_db_after2 = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"DOORBELL_RESP_ACC after S→M: M={m_db_after2} S={s_db_after2}")

    s2m_pass = (m_db_after2 > m_db_before2) or (s_db_after2 > s_db_before2)

    tb.log.info(f"=== VARIANT {variant_name} RESULT ===")
    tb.log.info(f"  cal_done: M={m_done} S={s_done}")
    tb.log.info(f"  pair_credit: M={snap_p2['m_pair_credit']} S={snap_p2['s_pair_credit']}")
    tb.log.info(f"  M→S doorbell: {'PASS' if m2s_pass else 'FAIL'} "
                f"(fc M(a2l={m2s_counts['m_a2l']},l2a={m2s_counts['m_l2a']}) "
                f"S(a2l={m2s_counts['s_a2l']},l2a={m2s_counts['s_l2a']}))")
    tb.log.info(f"  S→M doorbell: {'PASS' if s2m_pass else 'FAIL'} "
                f"(fc M(a2l={s2m_counts['m_a2l']},l2a={s2m_counts['m_l2a']}) "
                f"S(a2l={s2m_counts['s_a2l']},l2a={s2m_counts['s_l2a']}))")

    return dict(
        variant=variant_name,
        m_cal_done=m_done, s_cal_done=s_done,
        m_pair_credit=snap_p2['m_pair_credit'],
        s_pair_credit=snap_p2['s_pair_credit'],
        m2s_pass=m2s_pass, s2m_pass=s2m_pass,
        m2s_counts=m2s_counts, s2m_counts=s2m_counts,
    )

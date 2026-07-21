"""Shared harness for the V2 (TIDELINK_PHY_V2) paired-die environment.

Self-contained trim of cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py
helpers (the repo convention is per-environment copies — each cocotb dir is
its own PYTHONPATH root). V2 deltas vs the V1 original:

  * Calibrator state names follow the deps/tidelink-phy enum (S_PROBE=7 etc.).
  * `force_calibrator_sim_bypass` drives the V2 component's
    tb_early_exit_force_q (same name/semantics: skip the S_HOLD peer-
    convergence dwell + the cr_pkt_seen-gated S_VALIDATE, which would burn
    the whole sim budget at 2M link cycles).
  * `wait_link_up` additionally polls the Region-8 slot-2 OBS bits via APB —
    same surface the v37 silicon debug used (cr/crack at [23]/[24]).

The bring-up sequence itself is the proven V1 SW recipe (role_lock W1S ->
passive autocal -> slot0 OFF + Wlink LL swreset bootstrap): the V2 wrapper
keeps the same Region-8/ROLE_CFG register surface, and the V2 calibrator
auto-arms on the role_locked rising edge exactly like V1 (AUTOCAL_ENABLE=1
at tidelink_top.sv).
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ---------------------------------------------------------------------------
# Register map (unified 15-bit APB view; HW 0x44030000 -> 0x0000,
# 0x44032000 -> 0x2000)
# ---------------------------------------------------------------------------
APB_WL_LINK_ENABLE_RESET = 0x0208
APB_TIDELINK_BASE        = 0x2000

OFF_RELEASE_THRESHOLD   = 0x004
OFF_PKT_WORD_LEN        = 0x008
OFF_DOORBELL            = 0x014
OFF_DOORBELL_RESP_ACC   = 0x024
OFF_PAIR_CREDIT_COUNTER = 0x028
OFF_ROLE_CFG            = 0x080
OFF_R8_SLOT0            = 0x100
OFF_R8_SLOT2            = 0x108

APB_ROLE_CFG            = APB_TIDELINK_BASE + OFF_ROLE_CFG            # 0x2080
APB_R8_SLOT0            = APB_TIDELINK_BASE + OFF_R8_SLOT0            # 0x2100
APB_R8_SWI_LANE_STATUS  = APB_TIDELINK_BASE + OFF_R8_SLOT2            # 0x2108
APB_PAIR_CREDIT_COUNTER = APB_TIDELINK_BASE + OFF_PAIR_CREDIT_COUNTER
APB_RELEASE_THRESHOLD   = APB_TIDELINK_BASE + OFF_RELEASE_THRESHOLD
APB_PKT_WORD_LEN        = APB_TIDELINK_BASE + OFF_PKT_WORD_LEN

ROLE_CFG_MASTER_LOCK = 0x02
ROLE_CFG_SLAVE_LOCK  = 0x03

LL_BOOTSTRAP_SWRESET_ON  = 0x00027f08
LL_BOOTSTRAP_SWRESET_OFF = 0x00027f00
LL_BOOTSTRAP_ENABLE      = 0x00027f07

R8_SLOT0_OFF = 0x0

# SWI_LANE_STATUS / SEND-GATE OBS bit positions (Region 8 slot 2 read mux,
# src/rtl/local_overrides/axi_chiplet_controller.sv)
ST_LANE_LOCKED = lambda v: v & 0xFF
ST_CAL_DONE    = lambda v: (v >> 16) & 1
ST_CR_SEEN     = lambda v: (v >> 23) & 1
ST_CRACK_SEEN  = lambda v: (v >> 24) & 1
ST_PKT_IS_CR   = lambda v: (v >> 27) & 1
ST_SHORT_PKT   = lambda v: (v >> 25) & 1
ST_LLRX_VALID  = lambda v: (v >> 29) & 1

CLK_PERIOD_NS     = 20.0
# ── Silicon clock-ratio knob (sim-only, wip/txoveradvance-simrepro) ─────────
# hclk (app clock) is CLK_PERIOD_NS=20 ns (~50 MHz). ref_clk drives the PHY
# user_ref_clk / link beat. The default 8.0 ns ref keeps the link fast enough
# that the a2l replay FIFO drains between AHB writes; combined with the
# spec-compliant SINGLE-CYCLE ahb_tx_write_word (NONSEQ dropped to IDLE after
# one beat), that is what HID the silicon x5 a2l emit-vs-consume over-advance in
# sim. Override with TIDELINK_SIM_REF_PERIOD_NS to model the true silicon
# 32-hclk/beat ratio (e.g. 40.0). NOTE: the over-advance itself is an hclk-only
# (fc_adapter address-phase re-latch) phenomenon — the ref period only changes
# how quickly a2l back-pressure clamps it; see ahb_tx_write_word_held below and
# test_v2_multipkt_pktnum.py.
REF_CLK_PERIOD_NS = float(os.environ.get("TIDELINK_SIM_REF_PERIOD_NS", "8.0"))


class APBMaster:
    """Minimal APB master on a side prefix (copied from the V1 pair env)."""

    def __init__(self, dut, clk, prefix):
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
        await RisingEdge(self._clk)
        self._psel.value    = 1
        self._paddr.value   = addr & 0x7FFF
        self._pwrite.value  = 1
        self._pwdata.value  = data
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
        await RisingEdge(self._clk)
        self._psel.value    = 1
        self._paddr.value   = addr & 0x7FFF
        self._pwrite.value  = 0
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


class PairV2TB:
    """Both-die harness: clocks, APB masters, AHB writers, bring-up phases."""

    # deps/tidelink-phy calibrator state enum (tidelink_phy_align_calibrator.sv)
    CAL_STATE_NAMES = {0: "IDLE", 1: "ARM", 2: "SWEEP", 3: "FINISH",
                       4: "DONE", 5: "CANCEL", 6: "HOLD", 7: "PROBE",
                       8: "FINALIZE", 9: "VALIDATE"}

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(
            Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
        cocotb.start_soon(
            Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

        for prefix in ("m", "s"):
            for port in ("tx", "fifo"):
                getattr(dut, f"{prefix}_ahb_{port}_hsel").value      = 0
                getattr(dut, f"{prefix}_ahb_{port}_haddr").value     = 0
                getattr(dut, f"{prefix}_ahb_{port}_htrans").value    = 0
                getattr(dut, f"{prefix}_ahb_{port}_hsize").value     = 2
                getattr(dut, f"{prefix}_ahb_{port}_hwrite").value    = 0
                getattr(dut, f"{prefix}_ahb_{port}_hwdata").value    = 0
                getattr(dut, f"{prefix}_ahb_{port}_hready_in").value = 1

        self.m_apb = APBMaster(dut, dut.hclk, "m")
        self.s_apb = APBMaster(dut, dut.hclk, "s")

    def apb(self, side):
        return self.m_apb if side == "m" else self.s_apb

    def top(self, side):
        return self.dut.u_master if side == "m" else self.dut.u_slave

    # ----- reset + sim hooks -------------------------------------------------

    async def reset(self):
        self.dut.poresetn.value = 0
        self.dut.hresetn.value  = 0
        await ClockCycles(self.dut.hclk, 20)
        self.dut.poresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value  = 1
        await ClockCycles(self.dut.hclk, 50)

    def force_calibrator_sim_bypass(self):
        """tb_early_exit_force_q=1 on both V2 calibrators: skip the S_HOLD
        dwell + the cr_pkt_seen-gated S_VALIDATE (2M link-cycle budget —
        infeasible in sim; same designed-in hook the PHY component pair
        suites use)."""
        for side in ("m", "s"):
            try:
                self.top(side).u_chiplet_controller.u_calibrator.\
                    tb_early_exit_force_q.value = 1
            except AttributeError:
                self.log.warning(f"[{side}] tb_early_exit_force_q not found")

    # ----- hierarchical probes ------------------------------------------------

    def fcsm(self, side):
        return self.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl

    def fcsm_cr_seen(self, side):
        try:
            return int(self.fcsm(side).cr_pkt_seen_rx.value)
        except (AttributeError, ValueError):
            return -1

    def fcsm_crack_seen(self, side):
        try:
            return int(self.fcsm(side).crack_pkt_seen_rx.value)
        except (AttributeError, ValueError):
            return -1

    def fcsm_state(self, side):
        try:
            return int(self.fcsm(side).state.value)
        except (AttributeError, ValueError):
            return -1

    def cal_state_name(self, side):
        try:
            s = int(self.top(side).u_chiplet_controller.u_calibrator.cur_state.value)
        except (AttributeError, ValueError):
            return "?"
        return self.CAL_STATE_NAMES.get(s, f"?{s}")

    # ----- bring-up phases ----------------------------------------------------

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
            if ST_CAL_DONE(m_st) and ST_CAL_DONE(s_st):
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

    async def wait_cr_crack(self, max_cycles=40000):
        """Poll until cr+crack latched on BOTH sides (FCSM CR handshake)."""
        for _ in range(max_cycles // 200):
            await ClockCycles(self.dut.hclk, 200)
            if all(self.fcsm_cr_seen(x) == 1 and self.fcsm_crack_seen(x) == 1
                   for x in ("m", "s")):
                return True
        return False

    async def snapshot(self, label):
        m_st = await self.m_apb.read(APB_R8_SWI_LANE_STATUS)
        s_st = await self.s_apb.read(APB_R8_SWI_LANE_STATUS)
        m_pcc = await self.m_apb.read(APB_PAIR_CREDIT_COUNTER)
        s_pcc = await self.s_apb.read(APB_PAIR_CREDIT_COUNTER)
        for name, st, pcc, side in (("M", m_st, m_pcc, "m"),
                                    ("S", s_st, s_pcc, "s")):
            self.log.info(
                f"  [{label}] {name}: locked=0x{ST_LANE_LOCKED(st):02x} "
                f"cal_done={ST_CAL_DONE(st)} cal={self.cal_state_name(side)} "
                f"fcsm={self.fcsm_state(side)} cr={ST_CR_SEEN(st)} "
                f"crack={ST_CRACK_SEEN(st)} pkt_is_cr={ST_PKT_IS_CR(st)} "
                f"short={ST_SHORT_PKT(st)} llrx_v={ST_LLRX_VALID(st)} pcc={m_pcc if side=='m' else s_pcc}")
        return {"m_st": m_st, "s_st": s_st, "m_pcc": m_pcc, "s_pcc": s_pcc}

    # ----- AHB TX / FIFO (compliant timing, proven in the V1 env) -------------

    async def ahb_tx_write_word(self, side, byte_addr, data):
        dut = self.dut
        g = lambda n: getattr(dut, f"{side}_ahb_tx_{n}")
        hready = g("hready")
        await RisingEdge(dut.hclk)
        for _ in range(50):
            try:
                if int(hready.value):
                    break
            except ValueError:
                pass
            await RisingEdge(dut.hclk)
        g("hsel").value, g("htrans").value = 1, 2
        g("hsize").value, g("hwrite").value = 2, 1
        g("haddr").value = byte_addr & ((1 << 14) - 1)
        await RisingEdge(dut.hclk)
        g("hsel").value, g("htrans").value, g("hwrite").value = 0, 0, 0
        g("hwdata").value = data & 0xFFFFFFFF
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                if int(hready.value):
                    break
            except ValueError:
                pass
        g("hwdata").value = 0

    async def ahb_tx_write_packet(self, side, words, gap=4):
        for i, w in enumerate(words):
            await self.ahb_tx_write_word(side, i * 4, w)
            if gap:
                await ClockCycles(self.dut.hclk, gap)

    async def ahb_tx_write_packet_b2b(self, side, words):
        """Back-to-back variant: no inter-word idle gap. Drives the FC TX
        aperture with consecutive AHB writes so the Wlink LL framer packs
        adjacent FC words into back-to-back long packets with NO inter-packet
        idle slot. This is the gate that exposes the V2 packet-boundary slip
        (the spaced ahb_tx_write_packet hid it). See test_v2_pair_b2b.py."""
        await self.ahb_tx_write_packet(side, words, gap=0)

    # ----- SILICON-FAITHFUL AHB-TX (held-NONSEQ bridge model) ----------------

    async def ahb_tx_write_word_held(self, side, byte_addr, data,
                                     hold_cycles=11, mid_idle=False,
                                     bw_idle=False, bw_gap=6):
        """Model the Xilinx axi_ahblite_bridge:3.0 master as observed on
        silicon: it holds HTRANS=NONSEQ with HADDR/HWDATA stable for the whole
        AXI transaction (~10 hclk on the PS GP1->SMC->bridge path) while the
        vivado wrapper loops the adapter's HREADYOUT straight back as HREADY
        (tb_top already wires m_ahb_tx_hready <= adapter HREADYOUT). The
        fc_adapter's LEVEL address-phase detect then re-latches a fresh FC word
        every time a data phase completes during the hold — the silicon x5 a2l
        over-advance. This is the exact stimulus of
        cocotb/tidelink_fc_adapter/test_held_nonseq.py::bridge_held_write,
        lifted into the integrated pair so the a2l wptr walk + credit
        exhaustion are observable end-to-end. The proven-compliant
        ahb_tx_write_word (single-cycle NONSEQ) is what hid it in sim.

        One held write == ONE logical store; a spec-correct adapter (and the
        in-tree tx_xfer_lock fix) must emit EXACTLY ONE FC word for it."""
        dut = self.dut
        g = lambda n: getattr(dut, f"{side}_ahb_tx_{n}")
        await RisingEdge(dut.hclk)
        g("hsel").value   = 1
        g("haddr").value  = byte_addr & ((1 << 14) - 1)
        g("htrans").value = 2                       # NONSEQ, held
        g("hsize").value  = 2
        g("hwrite").value = 1
        g("hwdata").value = data & 0xFFFFFFFF
        for c in range(hold_cycles):
            if mid_idle and c == hold_cycles // 2:
                # SILICON DEFEAT of the 2026-07-07 lock: a mid-held-NONSEQ IDLE
                # beat with hsel HELD (htrans->IDLE for one beat, then back to the
                # SAME-address NONSEQ). The old clear condition released the lock
                # on this bare IDLE -> the next same-addr NONSEQ re-accepted the
                # SAME store -> residual ~5x/store still leaked on silicon while
                # the continuous-held writer (which deselects) read a clean 1:1.
                # The 2026-07-08 lock holds through it (clears only on ~hsel or a
                # different-address NONSEQ) -> must stay 1:1 here.
                g("htrans").value = 0
                await RisingEdge(dut.hclk)
                g("htrans").value = 2
            await RisingEdge(dut.hclk)
        # Transaction end.
        if bw_idle:
            # SILICON BETWEEN-WORD separator: an IDLE gap with hsel HELD (NOT a
            # deselect). The v2 lock (clear only on ~hsel / diff-addr) never sees a
            # boundary here -> STICKS -> next word suppressed -> data path wedged.
            # The v3 IDLE-gap-count clears after TX_IDLE_GAP idle beats -> separates
            # words while still holding through the brief mid-store IDLE above.
            g("htrans").value = 0                       # IDLE, hsel STAYS 1
            g("hwrite").value = 0
            for _ in range(bw_gap):
                await RisingEdge(dut.hclk)
            g("hsel").value = 0                         # release after the gap
        else:
            g("hsel").value   = 0                       # deselect
            g("htrans").value = 0
            g("hwrite").value = 0
            for _ in range(4):
                await RisingEdge(dut.hclk)
        g("hwdata").value = 0

    async def ahb_tx_write_packet_held(self, side, words, hold_cycles=11,
                                       gap=6, mid_idle=False, bw_idle=False,
                                       same_addr=False):
        """Write `words` to die_a's AHB-TX aperture using the silicon held-NONSEQ
        bridge model. mid_idle=True inserts the mid-hold IDLE beat; bw_idle=True
        uses an hsel-held IDLE between-word gap (the silicon separator); same_addr
        keeps one address (FIFO aperture) so the between-word gap is the ONLY word
        separator (the worst case for the lock)."""
        for i, w in enumerate(words):
            addr = 0 if same_addr else i * 4
            await self.ahb_tx_write_word_held(side, addr, w, hold_cycles,
                                              mid_idle=mid_idle, bw_idle=bw_idle)
            if gap and not bw_idle:
                await ClockCycles(self.dut.hclk, gap)

    # ----- a2l replay / credit observability (io_obs_* on tl2wl) -------------

    def _tl2wl(self, side):
        return self.top(side).u_chiplet_controller.u_wlink.tl2wl

    def _obs(self, side, name):
        try:
            return int(getattr(self._tl2wl(side), name).value)
        except (AttributeError, ValueError):
            return -1

    def a2l_wptr(self, side):
        """5-bit a2l replay-FIFO write pointer — advances once per FC word the
        fc_adapter pushes. Δwptr per AHB word IS the over-advance multiplier."""
        return self._obs(side, "io_obs_a2l_wptr")

    def a2l_synced_ack(self, side):
        """5-bit a2l replay ACK pointer (== pktnum acked by the peer)."""
        return self._obs(side, "io_obs_a2l_synced_ack")

    def a2l_full(self, side):
        return self._obs(side, "io_obs_a2l_full")

    def a2l_app_ready(self, side):
        return self._obs(side, "io_obs_a2l_replay_app_ready")

    def fc_a2l_hs(self, side):
        """1 when the master fc_adapter is emitting an FC word this cycle
        (tl_fc_a2l_valid & tl_fc_a2l_ready)."""
        try:
            fa = self.top(side).u_fc_adapter
            return int(fa.tl_fc_a2l_valid.value) & int(fa.tl_fc_a2l_ready.value)
        except (AttributeError, ValueError):
            return -1

    async def ahb_fifo_read_word(self, side, byte_addr):
        dut = self.dut
        g = lambda n: getattr(dut, f"{side}_ahb_fifo_{n}")
        hready, hrdata = g("hready"), g("hrdata")
        await RisingEdge(dut.hclk)
        for _ in range(50):
            try:
                if int(hready.value):
                    break
            except ValueError:
                pass
            await RisingEdge(dut.hclk)
        g("hsel").value, g("htrans").value = 1, 2
        g("hsize").value, g("hwrite").value = 2, 0
        g("haddr").value = byte_addr & ((1 << 14) - 1)
        await RisingEdge(dut.hclk)
        g("hsel").value, g("htrans").value = 0, 0
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                if int(hready.value):
                    break
            except ValueError:
                pass
        try:
            return int(hrdata.value)
        except ValueError:
            return 0


# ---------------------------------------------------------------------------
# Shared bring-up + packet helpers
# ---------------------------------------------------------------------------

async def run_bringup_full(tb):
    """POR -> role_lock -> passive autocal -> to_data_mode.

    Returns a dict with the PHASE-1 lane statuses (m_p1/s_p1 — sample
    lane_locked/cal_done HERE; lane_locked naturally drops back to 0 once
    training is released for data mode, the checker only scores the training
    pattern) plus the post-data-mode snapshot."""
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    assert locked, "role_locked did not assert on both dies"
    m_p1, s_p1 = await tb.wait_cal_done()
    tb.log.info(f"post-autocal: M=0x{m_p1:08x} S=0x{s_p1:08x} "
                f"cal M={tb.cal_state_name('m')} S={tb.cal_state_name('s')}")
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)
    snap = await tb.snapshot("after to_data_mode")
    snap["m_p1"], snap["s_p1"] = m_p1, s_p1
    return snap


def make_packet(payload):
    """v33-style 4-word FC packet: word0 header + dest_addr + 2 payload words."""
    from tidelink.packet import encode_word0, PKT_WR_REQ
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + list(payload)


async def send_and_check(tb, src, dst, payload, ctx, expect_pass=True):
    """Send a 4-word packet src->dst and byte-compare what lands in the
    peer's RX FIFO (header word + both payload words). Returns (ok, got)."""
    words = make_packet(payload)
    await tb.ahb_tx_write_packet(src, words)
    await ClockCycles(tb.dut.hclk, 3000)
    apb = tb.apb(dst)
    pkt_len = await apb.read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    tb.log.info(f"  [{ctx}] {src}->{dst}: PKT_LEN=0x{pkt_len:x} "
                f"hdr=0x{got[0]:08x} (sent 0x{words[0]:08x}) "
                f"rx=[{', '.join(f'0x{w:08x}' for w in got)}]")
    # Compare ALL FOUR words, including word 1 (dest_addr). This check used to be
    # `got[0] and got[2] and got[3]`, silently skipping word 1 -- so any corruption
    # of dest_addr passed the primary gating data check. That word is expected to
    # survive intact: send_and_check_b2b() below, over the same RX FIFO and the same
    # read path, asserts `all(got[i] == words[i])` across every word. There is no
    # in-transit rewrite of dest_addr to accommodate.
    ok = all(got[i] == words[i] for i in range(4))
    if expect_pass:
        assert ok, (f"{ctx} {src}->{dst} packet corrupt/undelivered: "
                    f"sent [{', '.join(f'0x{w:08x}' for w in words)}] got "
                    f"[{', '.join(f'0x{w:08x}' for w in got)}] len=0x{pkt_len:x}"
                    + ("" if got[1] == words[1] else
                       f"  <-- word1/dest_addr MISMATCH "
                       f"(sent 0x{words[1]:08x}, got 0x{got[1]:08x}); this word was "
                       f"previously excluded from the compare"))
    # NOTE: pkt_len is read above and deliberately NOT asserted here -- its exact
    # encoding/stickiness is not established, and a wrong assertion would produce
    # false failures. It is logged. Establishing its semantics and gating on it
    # would additionally catch "stale FIFO contents happen to match".
    return ok, got


async def send_and_check_b2b(tb, src, dst, words, ctx, expect_pass=True):
    """Send `words` (a raw FIFO-data word list) src->dst with NO inter-word
    idle gap, then byte-compare every word against the dst RX FIFO at the same
    byte offset. This is the back-to-back gate: the FC adapter maps AHB word i
    to FC FIFO_DATA at addr i*4, and the Wlink LL framer packs adjacent FC
    words into back-to-back long packets. Without packet-boundary re-alignment,
    the second-and-later packets' headers land mid-link-word and the RX never
    re-syncs (no SYNC in V2) -> CRC saturates, no enqueue. Returns (ok, got)."""
    await tb.ahb_tx_write_packet_b2b(src, words)
    await ClockCycles(tb.dut.hclk, 4000)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(len(words))]
    tb.log.info(f"  [{ctx}] {src}->{dst} B2B: sent="
                f"[{', '.join(f'0x{w:08x}' for w in words)}] "
                f"rx=[{', '.join(f'0x{w:08x}' for w in got)}]")
    ok = all(got[i] == words[i] for i in range(len(words)))
    if expect_pass:
        assert ok, (f"{ctx} {src}->{dst} back-to-back corrupt/undelivered: "
                    f"sent [{', '.join(f'0x{w:08x}' for w in words)}] "
                    f"got [{', '.join(f'0x{w:08x}' for w in got)}]")
    return ok, got

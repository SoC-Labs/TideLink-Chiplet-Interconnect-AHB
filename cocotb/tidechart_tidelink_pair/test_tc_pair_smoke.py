"""TideChart <-> TideLink pair integration smoke  (verification-plan gap F18).

TideChart is verification-green standalone (60/60 cocotb + UVM) but has NEVER
been co-simulated with a real TideLink pair. This bench closes that: it stands
up the proven two-die TideLink V2 pair AND attaches a `tidechart_controller`
(via the ASIC `tidechart_shim`) on BOTH dies, wired exactly as the chiplet
integration wires it (tc_axis_* / link_active / congestion sideband).

It proves three things:
  (a) COMPILE/ELABORATE  — the combined stack builds (implicit: the sim runs).
  (b) LINK STILL UP      — the pair reaches role_lock + cal_done with TideChart
                           attached (reused verbatim from the pair's PairTB).
  (c) CROSS-BOUNDARY OBS — TideChart consumes a REAL TideLink event: die_a's
                           election FSM is parked in ST_WAIT_LINKS while
                           tidelink's link_active=0, and only advances once
                           tidelink asserts link_active. That transition is
                           gated *solely* on the tidelink output — a genuine
                           TideLink -> TideChart observation, not a self-tick.

Stretch observations (logged, and asserted where they reliably complete):
  * election_done / is_root latch in TC_STATUS after the link reaches data mode.
  * a LINK_STATE_BCAST (PKT_EXT) emitted by die_a's TideChart crossing the real
    link to die_b's TideChart rx counter — reported; a wiring gap here is a
    documented result, not a failure (see README).

The bring-up sequence is imported UNCHANGED from the sibling pair bench.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the proven pair bring-up harness (PairTB) + register addresses.
from test_tidelink_pair_doorbell import (
    PairTB, ROLE_CFG_MASTER_LOCK, ROLE_CFG_SLAVE_LOCK,
)

# ---- TideChart register map (bytes) — from tidechart_apb_regs.sv:172 --------
TC_STATUS      = 0x00   # RO [0]election_done [1]is_root [2]enum_done
TC_CTRL        = 0x08   # RW [0]election_start [1]enum_start
TC_TIMEOUT     = 0x0C   # RW [15:0]election_timeout
TC_DEVICE_CLASS= 0x10
TC_PORT_COUNT  = 0x24   # RO [2:0]num_ports
TC_CONG_CTRL   = 0x74   # RW [0]bcast_enable [1]bcast_trigger(W1P)
TC_CONG_STATUS = 0x78   # RO [23:16]rx_bcast_count [31:24]tx_bcast_count

# Election FSM state encodings (tidechart_election_fsm.sv:74-78)
ST_IDLE, ST_WAIT_LINKS, ST_CLAIM_TX, ST_LISTEN, ST_SETTLED = 0, 1, 2, 3, 4
ST_NAMES = {0: "IDLE", 1: "WAIT_LINKS", 2: "CLAIM_TX", 3: "LISTEN", 4: "SETTLED"}


class TCApb:
    """Minimal APB master for a TideChart shim (single-cycle pready)."""

    def __init__(self, dut, clk, prefix):
        self.clk = clk
        self.psel    = getattr(dut, f"{prefix}_tc_apb_psel")
        self.penable = getattr(dut, f"{prefix}_tc_apb_penable")
        self.pwrite  = getattr(dut, f"{prefix}_tc_apb_pwrite")
        self.paddr   = getattr(dut, f"{prefix}_tc_apb_paddr")
        self.pwdata  = getattr(dut, f"{prefix}_tc_apb_pwdata")
        self.prdata  = getattr(dut, f"{prefix}_tc_apb_prdata")
        self.idle()

    def idle(self):
        self.psel.value = 0
        self.penable.value = 0
        self.pwrite.value = 0
        self.paddr.value = 0
        self.pwdata.value = 0

    async def write(self, addr, data):
        self.paddr.value = addr & 0xFF
        self.psel.value = 1
        self.pwrite.value = 1
        self.pwdata.value = data & 0xFFFFFFFF
        self.penable.value = 0
        await RisingEdge(self.clk)
        self.penable.value = 1
        await RisingEdge(self.clk)
        self.idle()
        await RisingEdge(self.clk)

    async def read(self, addr):
        self.paddr.value = addr & 0xFF
        self.psel.value = 1
        self.pwrite.value = 0
        self.penable.value = 0
        await RisingEdge(self.clk)
        self.penable.value = 1
        await RisingEdge(self.clk)
        try:
            val = int(self.prdata.value)
        except ValueError:
            val = 0
        self.idle()
        await RisingEdge(self.clk)
        return val


def _election_state(dut, prefix):
    """Backdoor read of a die's TideChart election FSM state (localization)."""
    inst = dut.u_tc_master if prefix == "m" else dut.u_tc_slave
    try:
        return int(inst.u_tidechart_controller.u_election.state_r.value)
    except Exception:
        return -1


@cocotb.test()
async def test_tidechart_tidelink_pair_smoke(dut):
    log = dut._log
    tb = PairTB(dut)                       # starts clocks, idles AHB, builds APB
    m_tc = TCApb(dut, dut.hclk, "m")
    s_tc = TCApb(dut, dut.hclk, "s")

    # ---------------------------------------------------------------------
    # (a) elaboration is implicit (we are running). Reset both dies.
    # ---------------------------------------------------------------------
    await tb.reset()
    tb.force_calibrator_sim_bypass()       # pair-bench convention (S_VALIDATE)

    # Shim APB connectivity sanity: TideChart's own regs answer across the shim.
    dev  = await m_tc.read(TC_DEVICE_CLASS)
    pcnt = await m_tc.read(TC_PORT_COUNT)
    log.info(f"[die_a TideChart] DEVICE_CLASS=0x{dev:04x}  PORT_COUNT={pcnt & 0x7}")
    assert (dev & 0xFFFF) == 0x0001, f"shim APB dead? DEVICE_CLASS=0x{dev:08x}"
    assert (pcnt & 0x7) == 2, f"expected NUM_PORTS=2, got {pcnt & 0x7}"

    # ---------------------------------------------------------------------
    # (c) CROSS-BOUNDARY: election parks on tidelink's link_active.
    # Arm election on die_a BEFORE the link is up. link_active[0]=role_locked=0,
    # so the FSM must sit in ST_WAIT_LINKS and NOT self-advance.
    # ---------------------------------------------------------------------
    assert int(dut.m_link_active.value) == 0, "link_active should be 0 pre-role-lock"
    await m_tc.write(TC_CTRL, 0x1)          # election_start (auto-clears)
    await ClockCycles(dut.hclk, 50)

    st_parked  = _election_state(dut, "m")
    status_pre = await m_tc.read(TC_STATUS)
    log.info(f"[link DOWN] die_a election FSM = {ST_NAMES.get(st_parked, st_parked)} "
             f"({st_parked})  TC_STATUS=0x{status_pre:08x}  link_active={int(dut.m_link_active.value)}")
    assert st_parked == ST_WAIT_LINKS, (
        f"election should PARK in ST_WAIT_LINKS while tidelink link_active=0, "
        f"got state {st_parked}")
    assert (status_pre & 0x1) == 0, "election_done must be 0 with the link down"

    # ---- Bring the pair link up (real tidelink event: link_active 0->1) ----
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    log.info(f"[bring-up] role_locked master={int(dut.m_role_locked.value)} "
             f"slave={int(dut.s_role_locked.value)} ({'PASS' if locked else 'TIMEOUT'})")
    assert locked, "pair failed to role_lock with TideChart attached"
    assert int(dut.m_link_active.value) == 1, "tidelink link_active never asserted"

    await ClockCycles(dut.hclk, 50)
    st_after = _election_state(dut, "m")
    log.info(f"[link UP] die_a election FSM = {ST_NAMES.get(st_after, st_after)} ({st_after})")
    assert st_after > ST_WAIT_LINKS, (
        f"die_a TideChart election did NOT advance past ST_WAIT_LINKS after "
        f"tidelink asserted link_active — the cross-boundary link_active signal "
        f"was not consumed (state stayed {st_after})")
    log.info("CROSS-BOUNDARY PROVEN: TideChart election advanced ONLY after "
             "TideLink asserted link_active.")

    # ---------------------------------------------------------------------
    # (b) Link continues to cal_done / data mode with TideChart attached.
    # ---------------------------------------------------------------------
    m_st, s_st = await tb.wait_cal_done(max_cycles=500000)
    log.info(f"[cal] SWI_LANE_STATUS M=0x{m_st:08x} S=0x{s_st:08x}  "
             f"cal M={tb.cal_state_name('m')} S={tb.cal_state_name('s')}")
    assert (m_st >> 16) & 1, f"master cal_done not set with TideChart attached (0x{m_st:08x})"
    assert (s_st >> 16) & 1, f"slave  cal_done not set with TideChart attached (0x{s_st:08x})"
    await tb.do_to_data_mode()
    await ClockCycles(dut.hclk, 3000)

    # Arm die_b election too, now that its link is up, so both dies elect.
    await s_tc.write(TC_CTRL, 0x1)

    # ---- STRETCH 1: election settles in TC_STATUS (needs link datapath) ----
    m_done = m_root = s_done = s_root = 0
    for _ in range(60):
        await ClockCycles(dut.hclk, 100)
        ms = await m_tc.read(TC_STATUS)
        ss = await s_tc.read(TC_STATUS)
        m_done, m_root = ms & 1, (ms >> 1) & 1
        s_done, s_root = ss & 1, (ss >> 1) & 1
        if m_done and s_done:
            break
    log.info(f"[election] die_a: done={m_done} is_root={m_root}  "
             f"die_b: done={s_done} is_root={s_root}  "
             f"(FSM m={ST_NAMES.get(_election_state(dut,'m'))} "
             f"s={ST_NAMES.get(_election_state(dut,'s'))})")
    assert m_done == 1, (
        f"die_a election_done never latched after data mode "
        f"(FSM={ST_NAMES.get(_election_state(dut,'m'))}) — see README stretch note")

    # ---- STRETCH 2: PKT_EXT broadcast crossing the real link (logged) ----
    def _rxcnt(v):
        return (v >> 16) & 0xFF

    await s_tc.write(TC_CONG_CTRL, 0x1)                 # enable rx on die_b
    st_b0 = await s_tc.read(TC_CONG_STATUS)
    await m_tc.write(TC_CONG_CTRL, 0x1 | 0x2)           # enable + one-shot trigger on die_a
    m_tx_valid_seen = 0
    for _ in range(3000):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.m_tc_tx_tvalid.value):
                m_tx_valid_seen += 1
        except ValueError:
            pass
    st_b1 = await s_tc.read(TC_CONG_STATUS)
    rx0, rx1 = _rxcnt(st_b0), _rxcnt(st_b1)
    crossed = rx1 > rx0
    log.info(f"[bcast] die_a TideChart drove tc_tx_tvalid for {m_tx_valid_seen} cy; "
             f"die_b rx_bcast_count {rx0} -> {rx1}  "
             f"=> PKT_EXT crossed the die boundary: {crossed}")

    log.info("=" * 68)
    log.info("SMOKE RESULT SUMMARY")
    log.info(f"  (a) combined stack elaborated + ran        : PASS")
    log.info(f"  (b) pair link up w/ TideChart (role+cal)   : PASS")
    log.info(f"  (c) TideChart consumed tidelink link_active: PASS")
    log.info(f"  stretch: die_a election_done/is_root       : {m_done}/{m_root}")
    log.info(f"  stretch: die_b election_done/is_root       : {s_done}/{s_root}")
    log.info(f"  stretch: die_a->die_b PKT_EXT bcast crossed: {crossed} "
             f"(tx_valid_cy={m_tx_valid_seen}, rx_cnt {rx0}->{rx1})")
    log.info("=" * 68)

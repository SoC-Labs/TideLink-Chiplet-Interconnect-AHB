"""TideChart pair election run IN DATA MODE — closes findings G1 + G2.

Sibling of `test_tc_pair_smoke.py`. The smoke bench proved the cross-boundary
handoff (TideChart's election parks on tidelink `link_active`) but, doing so,
exposed two gaps:

  G1  `link_active` (= `role_locked`, tidelink_top.sv:2539) asserts ~5 us BEFORE
      the link-layer reaches data mode. TideChart's election is gated on
      `link_active`, so both dies leave ST_WAIT_LINKS and SETTLE as root long
      before any CLAIM packet can cross the die boundary  =>  DUAL ROOT.
  G2  No TideChart PKT_EXT was ever observed crossing the real link (elections
      settled pre-data-mode; the ext-FC channel was not yet carrying).

This test removes the premature-arming that caused G1 and drives the election
the way the *fixed* integration must drive it:

  THE HOLD (what the bench controls):
    election_start is the TideChart APB register TC_CTRL[0]. The bench holds it
    DEASSERTED on BOTH dies until the pair is genuinely in DATA MODE — i.e.
    role_lock + cal_done + do_to_data_mode(), verified by FCSM state >= 4 (the
    Wlink LL credit/data-exchange region) on both dies. Only THEN is election_start
    written. This is exactly the sequencing contract the FPGA/ASIC build needs:
    gate election on "link carries EXT traffic", not on bare role_locked.
    (Documented in docs/TIDECHART_G1_SEQUENCING_CONTRACT.md.)

  THE DESYMMETRISER (a bench artefact, not part of the contract):
    PUF_ENABLE=0 in the shim => puf_seed=0 on both dies, and the two dies share
    one reset, so their election LFSRs step in lockstep. Arming both elections on
    the SAME cycle would give identical random_ids => a legitimate TIE => both
    remain root. Real silicon never resets two dies on the same cycle; here we
    model that asymmetry by writing the two election_start bits a few cycles
    apart, giving the two dies distinct random_ids.

Then it PROVES:
  (a) EXACTLY ONE root across the two dies (single-root election), and
  (b) at least one TideChart PKT_EXT (election CLAIM) demonstrably CROSSED the
      real TideLink: the far die's tc_axis_rx delivers a word with
      tdata[47:46]==2'b10 (PKT_EXT) and subtype 0x0001 (ELECTION_CLAIM).
      This is the first proof the tidechart datapath carries traffic end-to-end
      over a real TideLink pair (closes G2).
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import PairTB

# ---- TideChart register map (bytes) — from tidechart_apb_regs.sv:172 --------
TC_STATUS       = 0x00   # RO [0]election_done [1]is_root [2]enum_done
TC_CTRL         = 0x08   # RW [0]election_start [1]enum_start
TC_TIMEOUT      = 0x0C   # RW [15:0]election_timeout (LISTEN window, cycles)
TC_DEVICE_CLASS = 0x10
TC_PORT_COUNT   = 0x24   # RO [2:0]num_ports

# Election FSM state encodings (tidechart_election_fsm.sv:74-78)
ST_IDLE, ST_WAIT_LINKS, ST_CLAIM_TX, ST_LISTEN, ST_SETTLED = 0, 1, 2, 3, 4
ST_NAMES = {0: "IDLE", 1: "WAIT_LINKS", 2: "CLAIM_TX", 3: "LISTEN", 4: "SETTLED"}

# FC packet-format constants (tidechart_election_fsm.sv:68-69)
PKT_EXT          = 0b10
SUBTYPE_ELECTION = 0x0001

# Election LISTEN timeout (cycles). Must exceed the tidechart->tidelink->link->
# tidelink->tidechart round trip so a peer's CLAIM lands inside the LISTEN window.
ELECTION_TIMEOUT = 0x0800

# Desymmetrising offset between the two election_start writes (cycles). Any
# non-zero value that gives the two LFSRs distinct step counts works; 16 is
# comfortably clear of any short-cycle coincidence.
ARM_OFFSET_CY = 16


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


def _election_inst(dut, prefix):
    inst = dut.u_tc_master if prefix == "m" else dut.u_tc_slave
    return inst.u_tidechart_controller.u_election


def _election_state(dut, prefix):
    try:
        return int(_election_inst(dut, prefix).state_r.value)
    except Exception:
        return -1


def _own_random(dut, prefix):
    try:
        return int(_election_inst(dut, prefix).own_random_r.value)
    except Exception:
        return -1


def _best_claim(dut, prefix):
    try:
        return int(_election_inst(dut, prefix).best_claim_out.value)
    except Exception:
        return -1


class ExtRxMonitor:
    """Counts TideChart PKT_EXT ELECTION words accepted at a die's tc_axis_rx.

    A crossing is a beat where tvalid & tready with tdata[47:46]==PKT_EXT and
    subtype 0x0001. Counting the handshaken beat (not the held level) means one
    CLAIM word == one count.
    """

    def __init__(self, dut, clk, tvalid, tready, tdata, name):
        self.clk = clk
        self.tvalid, self.tready, self.tdata = tvalid, tready, tdata
        self.name = name
        self.count = 0
        self.first_word = None
        self._run = True

    async def run(self):
        while self._run:
            await RisingEdge(self.clk)
            try:
                v = int(self.tvalid.value)
                r = int(self.tready.value)
            except ValueError:
                continue
            if v and r:
                try:
                    d = int(self.tdata.value)
                except ValueError:
                    continue
                if (d >> 46) & 0b11 == PKT_EXT and (d >> 32) & 0x3FFF == SUBTYPE_ELECTION:
                    self.count += 1
                    if self.first_word is None:
                        self.first_word = d

    def stop(self):
        self._run = False


@cocotb.test()
async def test_tc_pair_election_datamode(dut):
    log = dut._log
    tb = PairTB(dut)
    m_tc = TCApb(dut, dut.hclk, "m")
    s_tc = TCApb(dut, dut.hclk, "s")

    await tb.reset()
    tb.force_calibrator_sim_bypass()

    dev  = await m_tc.read(TC_DEVICE_CLASS)
    pcnt = await m_tc.read(TC_PORT_COUNT)
    log.info(f"[die_a TideChart] DEVICE_CLASS=0x{dev:04x}  PORT_COUNT={pcnt & 0x7}")
    assert (dev & 0xFFFF) == 0x0001, f"shim APB dead? DEVICE_CLASS=0x{dev:08x}"
    assert (pcnt & 0x7) == 2, f"expected NUM_PORTS=2, got {pcnt & 0x7}"

    # Election_start is HELD deasserted on both dies (we simply do not write it).
    assert (await m_tc.read(TC_STATUS)) & 0x1 == 0, "die_a election_done must be 0 pre-arm"
    assert (await s_tc.read(TC_STATUS)) & 0x1 == 0, "die_b election_done must be 0 pre-arm"

    # -------------------------------------------------------------------------
    # Bring the pair ALL THE WAY to data mode BEFORE arming any election.
    #   role_lock  ->  cal_done  ->  do_to_data_mode  ->  FCSM state >= 4.
    # -------------------------------------------------------------------------
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    log.info(f"[bring-up] role_locked master={int(dut.m_role_locked.value)} "
             f"slave={int(dut.s_role_locked.value)} ({'PASS' if locked else 'TIMEOUT'})  "
             f"link_active m={int(dut.m_link_active.value)} s={int(dut.s_link_active.value)}")
    assert locked, "pair failed to role_lock with TideChart attached"
    # G1 in one line: link_active is ALREADY 1 here, long before data mode.
    assert int(dut.m_link_active.value) == 1 and int(dut.s_link_active.value) == 1

    m_st, s_st = await tb.wait_cal_done(max_cycles=500000)
    log.info(f"[cal] SWI_LANE_STATUS M=0x{m_st:08x} S=0x{s_st:08x}  "
             f"cal M={tb.cal_state_name('m')} S={tb.cal_state_name('s')}")
    assert (m_st >> 16) & 1 and (s_st >> 16) & 1, "cal_done not set on both dies"

    await tb.do_to_data_mode()
    await ClockCycles(dut.hclk, 5000)      # let the FCSM settle into data exchange

    m_fcsm, s_fcsm = tb.fcsm_state("m"), tb.fcsm_state("s")
    log.info(f"[data-mode] FCSM state m={m_fcsm} s={s_fcsm} "
             f"(>=4 == LL credit/data-exchange region)")
    assert m_fcsm >= 4 and s_fcsm >= 4, (
        f"link not in data mode (FCSM m={m_fcsm} s={s_fcsm}) — election must be held")

    # -------------------------------------------------------------------------
    # Start the PKT_EXT crossing monitors on BOTH dies' tc_axis_rx.
    # -------------------------------------------------------------------------
    mon_a = ExtRxMonitor(dut, dut.hclk, dut.m_tc_rx_tvalid, dut.m_tc_rx_tready,
                         dut.m_tc_rx_tdata, "die_a")
    mon_b = ExtRxMonitor(dut, dut.hclk, dut.s_tc_rx_tvalid, dut.s_tc_rx_tready,
                         dut.s_tc_rx_tdata, "die_b")
    cocotb.start_soon(mon_a.run())
    cocotb.start_soon(mon_b.run())

    # -------------------------------------------------------------------------
    # Arm both elections IN DATA MODE, ARM_OFFSET_CY cycles apart (desymmetrise).
    # -------------------------------------------------------------------------
    await m_tc.write(TC_TIMEOUT, ELECTION_TIMEOUT)
    await s_tc.write(TC_TIMEOUT, ELECTION_TIMEOUT)

    await m_tc.write(TC_CTRL, 0x1)         # die_a election_start
    await ClockCycles(dut.hclk, ARM_OFFSET_CY)
    await s_tc.write(TC_CTRL, 0x1)         # die_b election_start
    log.info(f"[arm] both elections armed in data mode ({ARM_OFFSET_CY}-cy offset)  "
             f"own_random die_a=0x{_own_random(dut,'m'):04x} "
             f"die_b=0x{_own_random(dut,'s'):04x}")

    # -------------------------------------------------------------------------
    # Poll to settle.
    # -------------------------------------------------------------------------
    m_done = m_root = s_done = s_root = 0
    for _ in range(400):
        await ClockCycles(dut.hclk, 100)
        ms = await m_tc.read(TC_STATUS)
        ss = await s_tc.read(TC_STATUS)
        m_done, m_root = ms & 1, (ms >> 1) & 1
        s_done, s_root = ss & 1, (ss >> 1) & 1
        if m_done and s_done:
            break

    await ClockCycles(dut.hclk, 200)
    mon_a.stop(); mon_b.stop()

    n_roots = m_root + s_root
    total_cross = mon_a.count + mon_b.count
    log.info(f"[election] die_a: done={m_done} is_root={m_root} "
             f"best=0x{_best_claim(dut,'m'):08x} own_rand=0x{_own_random(dut,'m'):04x}  "
             f"FSM={ST_NAMES.get(_election_state(dut,'m'))}")
    log.info(f"[election] die_b: done={s_done} is_root={s_root} "
             f"best=0x{_best_claim(dut,'s'):08x} own_rand=0x{_own_random(dut,'s'):04x}  "
             f"FSM={ST_NAMES.get(_election_state(dut,'s'))}")
    log.info(f"[crossing] PKT_EXT ELECTION words delivered  "
             f"die_a.rx={mon_a.count} (first=0x{(mon_a.first_word or 0):012x})  "
             f"die_b.rx={mon_b.count} (first=0x{(mon_b.first_word or 0):012x})")

    # -------------------------------------------------------------------------
    # PROOF (a): single-root election.
    # -------------------------------------------------------------------------
    assert m_done and s_done, (
        f"election did not settle on both dies (m_done={m_done} s_done={s_done})")
    assert n_roots == 1, (
        f"NOT single-root: {n_roots} roots elected (die_a is_root={m_root}, "
        f"die_b is_root={s_root}). Expected exactly ONE root in a 2-node fabric.")

    # -------------------------------------------------------------------------
    # PROOF (b): at least one PKT_EXT CLAIM crossed the real link (closes G2).
    # -------------------------------------------------------------------------
    assert total_cross >= 1, (
        "NO TideChart PKT_EXT crossed the link — the ext-FC datapath did not "
        f"carry the election CLAIM (die_a.rx={mon_a.count}, die_b.rx={mon_b.count})")
    # Corroboration: the NON-root die must have ADOPTED the root's claim over the
    # link — its best_claim random differs from its own random (it heard a peer).
    non_root_prefix = "s" if m_root else "m"
    nr_best_rand = _best_claim(dut, non_root_prefix) & 0xFFFF
    nr_own_rand  = _own_random(dut, non_root_prefix) & 0xFFFF
    assert nr_best_rand != nr_own_rand, (
        f"non-root die ({non_root_prefix}) best random 0x{nr_best_rand:04x} == own "
        f"0x{nr_own_rand:04x}: it did NOT adopt a peer claim — crossing not causal")

    log.info("=" * 70)
    log.info("ELECTION-IN-DATA-MODE RESULT (closes G1 + G2)")
    log.info(f"  data mode reached (FCSM>=4) before arming    : PASS")
    log.info(f"  (a) SINGLE root across the two dies           : PASS "
             f"(die_a root={m_root}, die_b root={s_root})")
    log.info(f"  (b) PKT_EXT CLAIM crossed the real TideLink   : PASS "
             f"(die_a.rx={mon_a.count}, die_b.rx={mon_b.count})")
    log.info("=" * 70)

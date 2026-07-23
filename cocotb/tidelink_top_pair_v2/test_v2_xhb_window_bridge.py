"""V2 XHB500 transparent-window — BRIDGE-ACCURATE timing (silicon write-vanish repro).

Silicon (E1 build) symptom: PS writes via 0x4000_0000 window VANISH (write X,
read back 0) while reads complete promptly with 0x0; repeated traffic
eventually collapses the link (fcsm 4->0). Meanwhile the idealized
test_v2_xhb_window passes 4/4.

ROOT CAUSE THIS MODULE MODELS
-----------------------------
On silicon the port is driven by Xilinx axi_ahblite_bridge:3.0 (`axi_ahb_sub`)
through imp/fpga/tidelink_ip/src/tidelink_vivado_wrapper.v, which wires

    .ahb_sub_hsel   (1'b1),                 // hardwired
    .ahb_sub_hready (sub_hreadyout_int),    // "HREADY loopback" (line 476)
    .ahb_sub_hreadyout (sub_hreadyout_int), // (line 479)
    assign ahb_sub_hready = sub_hreadyout_int;  // -> bridge HREADY (line 427)

while src/rtl/tidelink_top.sv makes hreadyout depend COMBINATIONALLY on
hready-in:

    1119: ext_addr_phase = hsel & htrans[1] & ahb_sub_hready;
    1120: ext_is_nonseq  = ext_addr_phase & (htrans == 2'b10);
    1169: ahb_sub_hreadyout = (ext_is_nonseq && !pipe_valid_r) ? 1'b0
                                                        : xhb_sub_hreadyout_raw;

With the wrapper loopback substituted:  hreadyout = !(NONSEQ & hreadyout &
!pipe_valid) & raw.  Whenever a NONSEQ arrives while XHB500 is ready (raw=1)
there is NO stable solution -> the net is a RING OSCILLATOR for that cycle
(Vivado routed timing summary: "There is 1 combinational loop in the design.
(HIGH)").  The bridge's HREADY flop, tidelink's pipe_valid_r flop and XHB500's
FSM each sample an oscillating net INDEPENDENTLY, so their views of "was the
address phase accepted?" can DIVERGE.  The cocotb TB never sees any of this
because it drives hready-in constant-high (tb_top.sv:355) and its master
politely waits out the stall.

The two divergent resolutions modelled here (deterministically, through the
ports; each 1-cycle hready-in value below is a legitimate sample of the
physical ring at the tidelink tap):

  PHANTOM-LOST (bridge tap=1, tidelink tap=0)
      tidelink samples hready-in=0 -> ext_addr_phase=0 -> pipe never latches,
      no stall is inserted, so hreadyout legitimately stays 1 -> the bridge
      sees its address phase accepted and its 1-cycle data phase complete.
      The transfer NEVER REACHES XHB500: write vanishes entirely, read
      returns idle hrdata (0x0) promptly, link stays quiet.  ("write X, read
      back 0", "reads return 0x0 promptly")

  DATA-LATE (bridge tap=1, tidelink tap=1)
      pipe latches (stall cycle hreadyout=0) but the bridge's flop sampled the
      ring HIGH, so the bridge proceeds: data phase next cycle, sees the
      pipeline's 1-cycle address-ACCEPT PULSE on hreadyout and withdraws
      HWDATA after one cycle.  XHB500 (address delayed one cycle by the pipe)
      samples HWDATA one cycle AFTER the bridge stopped driving it -> the
      write crosses the link carrying the WRONG word ("Finding 5": staged
      address at tidelink_top.sv:1136-1145 vs RAW .hwdata at :1711).

Offsets are disjoint across the three tests so they cannot mask each other.
Each test performs its OWN full bring-up (PairV2TB's clock tasks die with the
test that spawned them — sharing a tb across tests starves VCS of events):
  a) idealized control  b) phantom-lost repro  c) data-late repro

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh
    export TIDELINK_PHY_V2=1
    make MODULE=test_v2_xhb_window_bridge
"""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from test_v2_xhb_window import AHBSubMaster, _slave_bram_peek

APERTURE_BASE = 0x4000_0000
WRITE_SETTLE  = 8000          # cycles for a posted window write to land (base test)
POISON        = 0xBAD0_BAD0   # what the bridge drives AFTER its believed data phase

async def _bringup(dut):
    """Fresh POR + full V2 bring-up (per test — clock tasks are test-scoped)."""
    tb = PairV2TB(dut)
    ideal = AHBSubMaster(dut)          # idles ahb_sub before bring-up
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    return tb, ideal


def _int_or_none(sig):
    try:
        return int(sig.value)
    except ValueError:
        return None      # X/Z


class BridgeAHBSubMaster:
    """AHB-Lite master modelling the Xilinx axi_ahblite_bridge:3.0 view of the
    ahb_sub port under the silicon hready<->hreadyout ring oscillation.

    Unlike test_v2_xhb_window.AHBSubMaster (hwdata held from address phase to
    final completion), this BFM drives HWDATA ONLY during the cycle(s) the
    bridge believes are the data phase — PG320-accurate — and lets the caller
    choose which resolution of the oscillating hready net each side sampled.
    """

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.hclk
        self.hsel      = dut.m_ahb_sub_hsel
        self.haddr     = dut.m_ahb_sub_haddr
        self.hburst    = dut.m_ahb_sub_hburst
        self.hprot     = dut.m_ahb_sub_hprot
        self.hsize     = dut.m_ahb_sub_hsize
        self.htrans    = dut.m_ahb_sub_htrans
        self.hwdata    = dut.m_ahb_sub_hwdata
        self.hwrite    = dut.m_ahb_sub_hwrite
        self.hready    = dut.m_ahb_sub_hready     # tidelink-tap sample of the ring
        self.hrdata    = dut.m_ahb_sub_hrdata
        self.hresp     = dut.m_ahb_sub_hresp
        self.hreadyout = dut.m_ahb_sub_hreadyout  # bridge-tap sample of the ring
        self.idle()

    def idle(self):
        self.hsel.value   = 0
        self.haddr.value  = 0
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hsize.value  = 2
        self.htrans.value = 0
        self.hwdata.value = 0
        self.hwrite.value = 0
        self.hready.value = 1

    async def wait_bus_idle(self, need=32, timeout=200_000):
        """Wait until hreadyout has been high `need` consecutive cycles (any
        in-flight XHB500 transaction fully retired)."""
        count = 0
        for _ in range(timeout):
            await FallingEdge(self.clk)
            count = count + 1 if _int_or_none(self.hreadyout) == 1 else 0
            if count >= need:
                return True
        return False

    def _addr_phase(self, addr, write):
        self.hsel.value   = 1
        self.haddr.value  = addr & 0xFFFF_FFFF
        self.htrans.value = 2          # NONSEQ
        self.hsize.value  = 2
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hwrite.value = 1 if write else 0

    def _end_addr_phase(self):
        self.hsel.value   = 0
        self.htrans.value = 0
        self.hwrite.value = 0

    async def write_phantom_lost(self, addr, data):
        """Silicon resolution (bridge tap=1, tidelink tap=0).

        hready-in is driven LOW for the single NONSEQ cycle: the tidelink-side
        flops sampled the ring low -> ext_addr_phase=0 -> pipe never latches,
        no stall term -> hreadyout genuinely stays 1, which is exactly what
        the bridge's flop sampled -> it runs a 1-cycle data phase and moves
        on.  Returns (h_c0, h_c1) = hreadyout seen by the bridge mid-C0/C1
        (1,1 = phantom accept + phantom completion)."""
        await RisingEdge(self.clk)               # C0: address phase
        self._addr_phase(addr, write=True)
        self.hready.value = 0                    # tidelink tap sampled the ring LOW
        await FallingEdge(self.clk)
        h_c0 = _int_or_none(self.hreadyout)      # bridge tap: expect 1 (no stall)
        await RisingEdge(self.clk)               # C1: bridge's believed data phase
        self._end_addr_phase()
        self.hready.value = 1
        self.hwdata.value = data & 0xFFFF_FFFF   # driven ONLY this cycle (PG320)
        await FallingEdge(self.clk)
        h_c1 = _int_or_none(self.hreadyout)      # expect 1 -> bridge: write done
        await RisingEdge(self.clk)               # C2: bridge idles the W bus
        self.hwdata.value = 0
        return h_c0, h_c1

    async def write_data_late(self, addr, data, poison=POISON, timeout=60_000):
        """Silicon resolution (bridge tap=1, tidelink tap=1).

        hready-in stays high -> the pipe latches (real stall cycle,
        hreadyout=0) but the bridge's flop sampled the ring HIGH, so it
        proceeds anyway: 1-cycle data phase at C1, where it sees the
        pipeline's address-accept PULSE (hreadyout=1 for exactly one cycle,
        see test_v2_xhb_window docstring) and concludes the write completed.
        From C2 the bridge no longer drives DATA — modelled as POISON held
        until XHB500's REAL data phase ends (B response) so whatever XHB500
        captured is unambiguous.  Returns (h_c0, h_c1, drained)."""
        await RisingEdge(self.clk)               # C0: address phase (pipe latches)
        self._addr_phase(addr, write=True)
        self.hready.value = 1
        await FallingEdge(self.clk)
        h_c0 = _int_or_none(self.hreadyout)      # sim: 0 (stall). bridge believed 1.
        await RisingEdge(self.clk)               # C1: bridge's believed data phase
        self._end_addr_phase()
        self.hwdata.value = data & 0xFFFF_FFFF   # the ONLY cycle DATA is driven
        await FallingEdge(self.clk)
        h_c1 = _int_or_none(self.hreadyout)      # accept pulse: 1 -> bridge leaves
        await RisingEdge(self.clk)               # C2: bridge withdrew the data
        self.hwdata.value = poison & 0xFFFF_FFFF
        drained = False
        for _ in range(timeout):                 # hold poison until B retires
            await FallingEdge(self.clk)
            if _int_or_none(self.hreadyout) == 1:
                drained = True
                break
        await RisingEdge(self.clk)               # let a capture-at-END edge see it
        self.hwdata.value = 0
        return h_c0, h_c1, drained

    async def read_bridge_desync(self, addr):
        """Read with the same (1,1) divergence: the pipe latches the AR (a
        REAL read crosses the link) but the bridge treats the C1 accept pulse
        as data-phase completion and captures hrdata THERE — XHB500's idle
        hrdata — returning promptly. The genuine R retires ~µs later with
        nobody in a data phase. Returns (rdata_phantom_or_None, h_c1)."""
        await RisingEdge(self.clk)               # C0: address phase (pipe latches)
        self._addr_phase(addr, write=False)
        self.hready.value = 1
        await FallingEdge(self.clk)
        await RisingEdge(self.clk)               # C1: bridge's believed data phase
        self._end_addr_phase()
        await FallingEdge(self.clk)
        h_c1 = _int_or_none(self.hreadyout)      # accept pulse
        rdata = _int_or_none(self.hrdata)        # what the bridge's flop captures
        await RisingEdge(self.clk)
        return rdata, h_c1


def _fmt(v):
    return "X" if v is None else f"0x{v:08x}"


# ─────────────────────────────────────────────────────────────────────────────
# (a) CONTROL — idealized timing (current test style) must still pass
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_a_bringup_and_idealized_control(dut):
    """Prove the window is healthy under the idealized (tied-hready,
    hwdata-held-to-completion) timing — the same flow test_v2_xhb_window
    passes 4/4 with."""
    tb, ideal = await _bringup(dut)

    off, data = 0x000, 0xC0DE1234
    await ideal.write(APERTURE_BASE + off, data)
    await ClockCycles(dut.hclk, WRITE_SETTLE)
    peek = _slave_bram_peek(dut, off)
    got = await ideal.read(APERTURE_BASE + off)
    tb.log.info(f"  [bridge/ctrl] idealized write/read @+0x{off:03x}: "
                f"wrote=0x{data:08x} read=0x{got:08x} BRAM={_fmt(peek)}")
    assert got == data, (
        f"CONTROL failed — idealized window round-trip broke "
        f"(wrote 0x{data:08x}, read 0x{got:08x}); bridge tests are moot")


# ─────────────────────────────────────────────────────────────────────────────
# (b) PHANTOM-LOST — the silicon write-vanish, deterministically
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_b_bridge_phantom_write_vanish(dut):
    """Divergent ring sampling (bridge=1, tidelink=0): the write phantom-
    completes at the bridge but never reaches XHB500 — write X, read back 0,
    prompt read, link stays up.  This test PASSES iff the silicon symptom
    REPRODUCES."""
    tb, ideal = await _bringup(dut)
    br = BridgeAHBSubMaster(dut)

    vectors = [(0x100, 0xCAFE0001), (0x204, 0xCAFE0002), (0x308, 0xCAFE0003)]
    fcsm_pre = (tb.fcsm_state("m"), tb.fcsm_state("s"))
    not_vanished = []

    for off, data in vectors:
        addr = APERTURE_BASE + off
        assert await br.wait_bus_idle(), "bus never idle before phantom write"
        pre = _slave_bram_peek(dut, off)

        h_c0, h_c1 = await br.write_phantom_lost(addr, data)
        await ClockCycles(dut.hclk, WRITE_SETTLE)
        post = _slave_bram_peek(dut, off)

        # prompt "0x0" read, exactly as PS sees it (real AR does cross)
        rphantom, rh = await br.read_bridge_desync(addr)
        drained = await br.wait_bus_idle(timeout=200_000)

        # ground-truth read via correct timing
        got = await ideal.read(addr)

        tb.log.info(
            f"  [bridge/phantom] @+0x{off:03x} wrote=0x{data:08x} | "
            f"bridge saw hreadyout C0={h_c0} C1={h_c1} (phantom done in 2 cyc) | "
            f"BRAM pre={_fmt(pre)} post={_fmt(post)} | "
            f"prompt-read={_fmt(rphantom)} (pulse={rh}) drained={drained} | "
            f"true-read=0x{got:08x}")

        if got == data or post == data:
            not_vanished.append((off, data, got, post))

    fcsm_post = (tb.fcsm_state("m"), tb.fcsm_state("s"))
    tb.log.info(f"  [bridge/phantom] fcsm m/s: {fcsm_pre} -> {fcsm_post} "
                f"(link {'UP' if fcsm_post == fcsm_pre else 'CHANGED'})")

    assert not not_vanished, (
        "write-vanish did NOT reproduce under phantom-lost timing — these "
        "writes landed: " +
        ", ".join(f"+0x{o:03x}=0x{d:08x}(read 0x{g:08x})"
                  for o, d, g, _ in not_vanished))
    tb.log.info("  [bridge/phantom] REPRODUCED: all writes vanished "
                "(read back 0), reads prompt, link stayed up — the E1 "
                "silicon signature")


# ─────────────────────────────────────────────────────────────────────────────
# (c) DATA-LATE — pipe latches, bridge withdraws HWDATA one cycle too early
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_c_bridge_dataphase_late_capture(dut):
    """Divergent ring sampling (bridge=1, tidelink=1): the transfer DOES cross
    but XHB500 — its address delayed one cycle by the pipe register while
    .hwdata is wired RAW (tidelink_top.sv:1711) — samples HWDATA the cycle
    AFTER the bridge withdrew it. The peer BRAM receives the POISON word, not
    the written one. PASSES iff the wrong-data capture reproduces."""
    tb, ideal = await _bringup(dut)
    br = BridgeAHBSubMaster(dut)

    vectors = [(0x400, 0xFEED0001), (0x504, 0xFEED0002)]
    intact = []

    for off, data in vectors:
        addr = APERTURE_BASE + off
        assert await br.wait_bus_idle(), "bus never idle before data-late write"

        h_c0, h_c1, drained = await br.write_data_late(addr, data)
        await ClockCycles(dut.hclk, WRITE_SETTLE)
        post = _slave_bram_peek(dut, off)
        got = await ideal.read(addr)

        which = ("POISON (one-cycle-late HWDATA capture PROVEN)"
                 if post == POISON else
                 "stale/other (beat lost)" if post != data else "INTACT")
        tb.log.info(
            f"  [bridge/late] @+0x{off:03x} wrote=0x{data:08x} | "
            f"hreadyout C0={h_c0} (bridge believed 1) C1={h_c1} accept-pulse | "
            f"B-drained={drained} | BRAM={_fmt(post)} -> {which} | "
            f"true-read=0x{got:08x}")

        if got == data:
            intact.append((off, data, got, post))

    assert not intact, (
        "data-late timing did NOT corrupt the write — landed intact: " +
        ", ".join(f"+0x{o:03x}=0x{d:08x}" for o, d, _, _ in intact))
    tb.log.info("  [bridge/late] REPRODUCED: written word never lands — "
                "XHB500 captured the post-data-phase bus value instead")

"""OFF-ARM GATE for the D2D link-rate register bank.

WHAT IS BEING GATED
    src/rtl/tidelink_top.sv carries the link-rate feature behind

        if (LINK_RATE_REGS_PRESENT) begin : g_link_rate_regs   ... end
        else                        begin : g_link_rate_absent
            assign link_ratio_sel_w = link_clk_div_ratio_i;
            assign rate_prdata      = {SYS_DATA_W{1'b0}};
            assign rate_pready      = 1'b1;
            assign rate_pslverr     = 1'b0;
        end

    The parameter defaults to 1'b0 and every shipping wrapper takes the default,
    so THE ELSE ARM IS THE SHIPPING RTL. Its whole contract is that it restores,
    exactly, what tidelink_top did before the feature existed:

      C1  APB quadrant 11 (paddr[14:13]==2'b11) is an undecoded fall-through:
          reads 0, acks in ONE access cycle, never asserts pslverr.
      C2  Software has NO path to the D2D rate. This is the safety rule, not
          tidiness: changing the rate invalidates the calibrator's phase offset,
          so it is legal only while the PHY is held in POR. In the OFF build
          there is no register to write, hence no way to violate it at all.
      C3  tidelink_link_clk_div.ratio_i is the PORT link_clk_div_ratio_i,
          unmuxed. The strap remains authoritative and the real forwarded clock
          follows it.

WHY THIS DIRECTORY EXISTS AT ALL — THE DEFECT IT CLOSES
    The evidence first offered for "the change is inert at PRESENT=0" was that
    cocotb/tidelink_top_pair produced an identical 2011520.01 ns / 11-tests
    signature before and after. That signature CANNOT SEE the OFF arm: no test
    in that directory addresses quadrant 11, so `assign rate_pready = 1'b1;`
    could be broken to 1'b0 and the signature would not move by a picosecond.
    An indiscriminate check quoted as though it discriminated is worse than no
    check. Everything below was chosen to be falsifiable, and then actually
    falsified — see MUTATIONS.

MUTATIONS — REALLY RUN against src/rtl/tidelink_top.sv, block g_link_rate_absent
    Each row: revert to pristine, apply that one edit, then

        make -C cocotb/tidelink_link_rate_regs_inert

    (the Makefile's flist staleness guard forces the full VCS re-elaboration, so
    no row can be a stale-simv artefact). Results below are the observed
    PASS/FAIL counts, 2026-08-18:

      #   edit                                                  result
      --  (pristine)                                            PASS=4 FAIL=0
      M1  rate_pready  1'b1 -> 1'b0                             PASS=2 FAIL=2  (t02,t03)
      M2  rate_pslverr 1'b0 -> 1'b1                             PASS=2 FAIL=2  (t02,t03)
      M3  rate_prdata  '0   -> 32'hDEAD_BEEF                    PASS=3 FAIL=1  (t02)
      M4  link_ratio_sel_w  link_clk_div_ratio_i -> 3'd0        PASS=2 FAIL=2  (t03,t04)
      M5  link_ratio_sel_w  -> {ratio_i[0], ratio_i[2:1]}       PASS=2 FAIL=2  (t03,t04)
      M6  rate_prdata  '0   -> {19'b0, apb_paddr[12:0]}         PASS=3 FAIL=1  (t02)
      M7  the WHOLE generate deleted (both arms)                PASS=1 FAIL=3  (t02,t03,t04)
      M8  arms swapped: if (!LINK_RATE_REGS_PRESENT)            PASS=2 FAIL=2  (t02,t03)

    M1 is the mutation the audit named as INVISIBLE to the evidence originally
    offered (the pair suite's identical 2011520.01 ns / 11-per-test signature).
    Here it is caught twice over. It is caught as a missing ACK rather than as a
    wrong value because quadrant 11 is deliberately NOT covered by tidelink_top's
    bounded-stall watchdog -- that watchdog keys on ext_txn = apb_sel_tidelink &&
    apb_penable, i.e. quadrant 01 only -- and the Zynq M_AXI_GP behind it has no
    bus timeout, so a lost ack there is an unrecoverable PS hang.

    M5 and M6 are in the table because they are the mutations a LAZIER version of
    this gate would have missed, and they are why two specific design decisions
    are load-bearing rather than decorative:
      * M5 keeps the ratio tracking the port, just permuted. A check that only
        asserted "the ratio moved when I moved the port" passes it. Asserting the
        MEASURED PERIOD of link_hsclk_w against (1<<code)*REF_PERIOD_NS does not.
      * M6 reads back 0 at 0x6000 and only 0x6000. A single-address probe of the
        quadrant passes it; it was caught at 0x6004, the second entry in
        RATE_SWEEP. That is what the sweep is for.

    M7 and M8 are the two ways the OFF arm gets broken by an edit that LOOKS
    right, and the RTL header beside the generate warns about both:
      * M7 is "just delete the generate" -- which the header calls out as a
        SILENT functional break rather than a revert, because link_ratio_sel_w
        and the rate_* wires are then undriven ('z) while the module-scope
        residue that names them stays. Lint objects; simulation propagates 'z
        happily. Three of four tests here object too.
      * M8 inverts the condition, so the OFF build silently INSTANTIATES the
        bank. test_02 reads the bank's own ID magic 0x4C43_4401 out of a
        quadrant that must read zero, and test_03 reports the failure in the
        terms that actually matter: "THE LINK RATE MOVED BECAUSE OF AN APB
        WRITE. ratio_eff 2 -> 4". That is the safety rule being violated from
        software in a build where the feature is nominally switched off, which
        is the worst outcome this whole gate exists to make impossible to ship
        unnoticed.

CONTROLS — so that a zero here is a MEASURED zero
    test_02 reads TideLink's ID register in quadrant 01 (0x2014 -> 0x544C_0100)
    BEFORE it reads quadrant 11. A dead APB master, a DUT still in reset or a
    mis-elaborated harness all produce "0, acked" from quadrant 11 while proving
    nothing; the non-zero control read makes that failure mode loud instead of
    green. test_04 measures ratio /1 first, which is the divider's reset state,
    so a divider that never left reset cannot masquerade as a passing sweep --
    the later /2../16 points are what force it to have moved.

test_01 additionally refuses to run at all if LINK_RATE_REGS_PRESENT has been
flipped to 1: at that point this gate would be measuring the ON build and its
PASS would mean nothing.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer, with_timeout
from cocotb.utils import get_sim_time

# --------------------------------------------------------------------------- #
# Timing
# --------------------------------------------------------------------------- #
HCLK_PERIOD_NS = 10.0     # fabric clock (APB)
REF_PERIOD_NS  = 10.0     # user_ref_clk -> tidelink_link_clk_div.clk_in

# Cycles of user_ref_clk allowed for a ratio change to reach the output clock.
# The divider resynchronises ratio_i through 2 flops, then hands over via
# byp_en_r (2 negedges of clk_in) and div_en_r (2 negedges of clkdiv_r). At /16
# a clkdiv_r edge is 8 ref cycles, so the div_en_r leg alone can take ~32 ref
# cycles; 400 is comfortable slack, not a tuned number.
RATIO_SETTLE_REF_CYCLES = 400

# --------------------------------------------------------------------------- #
# Address map of the 15-bit unified APB window (tidelink_top.sv decode)
#   paddr[14:13] = 00  Wlink chiplet controller
#                = 01  TideLink config registers
#                = 10  address translator
#                = 11  link-rate quadrant  <-- under test, must be undecoded
# --------------------------------------------------------------------------- #
Q_TIDELINK = 0x2000
Q_RATE     = 0x6000

# Positive control: tidelink_apb_regs region 0, paddr[4:2]==3'h5, a constant in
# the read mux (fifo/tidelink_apb_regs.sv:703). Chosen because it is reset- and
# traffic-independent, so it can only read back wrong if the APB path is wrong.
TL_ID_ADDR  = Q_TIDELINK + 0x014
TL_ID_MAGIC = 0x544C_0100

# Addresses swept in quadrant 11. Covers where the bank's registers WOULD be
# (ID/CTRL/STAT/pad at +0x000..+0x00C), just past it (+0x010), and both ends of
# the 8 KB quadrant, so a partial decode cannot hide.
RATE_SWEEP = [
    Q_RATE + 0x000,   # LINK_RATE_ID would live here
    Q_RATE + 0x004,   # LINK_RATE_CTRL would live here  <- the dangerous one
    Q_RATE + 0x008,   # LINK_RATE_STAT would live here
    Q_RATE + 0x00C,
    Q_RATE + 0x010,
    Q_RATE + 0x800,
    Q_RATE + 0x1FFC,  # top word of the quadrant
]

RATIO_NAMES = {0: "/1", 1: "/2", 2: "/4", 3: "/8", 4: "/16"}


# --------------------------------------------------------------------------- #
# Minimal APB requester
# --------------------------------------------------------------------------- #
class APB:
    """APB3 requester on tidelink_top's unified port.

    read()/write() return the number of ACCESS cycles the subordinate took to
    ack, and the pslverr sampled ON the acking edge. Both matter: C1 is not
    "reads zero", it is "reads zero, in one cycle, without an error", and the
    ack-cycle count is the only thing that distinguishes the combinational
    fall-through from something that registered its way to the same value.
    """

    def __init__(self, dut):
        self.dut = dut

    def idle(self):
        self.dut.apb_psel.value    = 0
        self.dut.apb_penable.value = 0
        self.dut.apb_pwrite.value  = 0

    async def _access(self, addr, write, wdata, limit):
        d = self.dut
        await RisingEdge(d.hclk)
        d.apb_psel.value    = 1
        d.apb_penable.value = 0
        d.apb_paddr.value   = addr & 0x7FFF
        d.apb_pwrite.value  = 1 if write else 0
        d.apb_pwdata.value  = wdata & 0xFFFFFFFF
        d.apb_pstrb.value   = 0xF
        d.apb_pprot.value   = 0
        await RisingEdge(d.hclk)
        d.apb_penable.value = 1                      # ACCESS phase
        for n in range(1, limit + 1):
            await RisingEdge(d.hclk)
            if d.apb_pready.value.is_resolvable and int(d.apb_pready.value):
                raw     = d.apb_prdata.value
                rdata   = int(raw) if raw.is_resolvable else None
                sv      = d.apb_pslverr.value
                slverr  = int(sv) if sv.is_resolvable else None
                self.idle()
                return rdata, n, slverr
        self.idle()
        raise AssertionError(
            f"APB {'write' if write else 'read'} to 0x{addr:04X} NEVER ACKED "
            f"within {limit} hclk cycles. At LINK_RATE_REGS_PRESENT=0 the "
            f"quadrant-11 response must be the constant rate_pready=1'b1 from "
            f"g_link_rate_absent; quadrant 11 is outside tidelink_top's "
            f"bounded-stall watchdog, so a lost ack is an unrecoverable PS hang."
        )

    async def read(self, addr, limit=64):
        return await self._access(addr, False, 0, limit)

    async def write(self, addr, data, limit=64):
        return await self._access(addr, True, data, limit)


# --------------------------------------------------------------------------- #
# Harness
# --------------------------------------------------------------------------- #
async def bringup(dut):
    """Start both clocks, release the resets, hand back an APB requester.

    Per-test, deliberately: cocotb cancels the tasks a test started when that
    test ends, so each test must start its own clocks and exactly one clock
    driver is ever live -- which is what makes test_04's period measurement
    mean anything.
    """
    cocotb.start_soon(Clock(dut.hclk, HCLK_PERIOD_NS, "ns").start())
    cocotb.start_soon(Clock(dut.user_ref_clk, REF_PERIOD_NS, "ns").start())

    dut.hresetn.value              = 0
    dut.poresetn.value             = 0
    dut.link_clk_div_ratio_i.value = 0
    apb = APB(dut)
    apb.idle()

    await ClockCycles(dut.hclk, 10)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 20)
    return apb


def check_present_off(dut):
    """Refuse to certify anything unless the DUT really is the OFF build."""
    v = dut.obs_present.value
    assert v.is_resolvable and int(v) == 0, (
        f"LINK_RATE_REGS_PRESENT elaborated as {v} in this build. This gate "
        f"only means something at 0 -- it certifies the ELSE arm "
        f"(g_link_rate_absent). At 1 it would be measuring the register bank "
        f"and reporting PASS for a claim it never tested. Fix the default in "
        f"src/rtl/tidelink_top.sv or retire this directory; do not relax this."
    )


async def set_ratio(dut, ratio):
    dut.link_clk_div_ratio_i.value = ratio
    await ClockCycles(dut.user_ref_clk, RATIO_SETTLE_REF_CYCLES)


async def measure_hsclk_period_ns(dut, edges=8):
    """Average period of the divider's REAL output clock, in ns.

    Measured on obs_link_hsclk (a tap on tidelink_top's link_hsclk_w, the net
    that clocks the PHY), not on a status register. A register readback can
    agree with a mutated ratio source; the clock cannot.
    """
    await RisingEdge(dut.obs_link_hsclk)   # discard any handover transient
    await RisingEdge(dut.obs_link_hsclk)
    t0 = get_sim_time("ps")
    for _ in range(edges):
        await RisingEdge(dut.obs_link_hsclk)
    t1 = get_sim_time("ps")
    return (t1 - t0) / edges / 1000.0


# --------------------------------------------------------------------------- #
# 01 -- the build really is the OFF build
# --------------------------------------------------------------------------- #
@cocotb.test()
async def test_inert_01_off_arm_is_elaborated(dut):
    """Guard: this whole directory is meaningless unless PRESENT elaborated 0."""
    await bringup(dut)
    check_present_off(dut)
    dut._log.info("LINK_RATE_REGS_PRESENT = 0 -- g_link_rate_absent is the "
                  "elaborated arm, as every shipping wrapper takes it.")


# --------------------------------------------------------------------------- #
# 02 -- C1: quadrant 11 is an undecoded fall-through
# --------------------------------------------------------------------------- #
@cocotb.test()
async def test_inert_02_quadrant11_reads_zero_and_acks(dut):
    """Quadrant 11 reads 0, acks in one cycle, never errors -- with a control.

    KILLS: rate_prdata != 0, rate_pready != 1, rate_pslverr != 0, and any
    accidental decode of the quadrant.
    """
    apb = await bringup(dut)
    check_present_off(dut)

    # ---- CONTROL. Prove the APB requester and the DUT are alive by reading a
    # register whose value is NOT zero. Without this, every assertion below is
    # satisfied just as well by a bus that is not connected to anything.
    ctl_data, ctl_cycles, ctl_err = await apb.read(TL_ID_ADDR)
    assert ctl_data == TL_ID_MAGIC, (
        f"CONTROL READ FAILED: 0x{TL_ID_ADDR:04X} (TideLink ID, quadrant 01) "
        f"returned {ctl_data if ctl_data is None else hex(ctl_data)}, expected "
        f"0x{TL_ID_MAGIC:08X}. The APB path is not working, so the quadrant-11 "
        f"zeros this test is about would measure NOTHING. Do not read any "
        f"result below as a pass."
    )
    assert ctl_err == 0, f"control read raised pslverr={ctl_err}"
    dut._log.info(f"control: 0x{TL_ID_ADDR:04X} -> 0x{ctl_data:08X} in "
                  f"{ctl_cycles} access cycle(s) -- APB path proven live")

    # ---- The property.
    for addr in RATE_SWEEP:
        data, cycles, slverr = await apb.read(addr)
        assert data == 0, (
            f"quadrant-11 read 0x{addr:04X} returned "
            f"{data if data is None else hex(data)}, expected 0x00000000. "
            f"At LINK_RATE_REGS_PRESENT=0 this quadrant is undecoded and "
            f"g_link_rate_absent must drive rate_prdata = '0."
        )
        assert slverr == 0, (
            f"quadrant-11 read 0x{addr:04X} asserted pslverr={slverr}. The "
            f"pre-feature fall-through never errored; g_link_rate_absent must "
            f"drive rate_pslverr = 1'b0."
        )
        assert cycles == 1, (
            f"quadrant-11 read 0x{addr:04X} acked after {cycles} access "
            f"cycles, expected 1. The fall-through is combinational "
            f"(rate_pready = 1'b1); anything slower is new logic on a path "
            f"that had none."
        )
    dut._log.info(f"{len(RATE_SWEEP)} quadrant-11 addresses: all read "
                  f"0x00000000, pslverr=0, acked in 1 cycle")


# --------------------------------------------------------------------------- #
# 03 -- C2: software has no path to the rate
# --------------------------------------------------------------------------- #
@cocotb.test()
async def test_inert_03_quadrant11_write_cannot_move_the_rate(dut):
    """No APB write anywhere in quadrant 11 may disturb the link rate.

    This is the SAFETY RULE expressed for the OFF build. With the bank absent
    there is no legal write window and no interlock -- the correct behaviour is
    that the write lands nowhere at all. The check is made on the divider's real
    output clock, before and after, at a NON-DEFAULT ratio so that "unchanged"
    is a measurement rather than a coincidence with the reset value.
    """
    apb = await bringup(dut)
    check_present_off(dut)

    await set_ratio(dut, 2)                       # /4 via the strap/port
    before_eff    = int(dut.obs_ratio_eff.value)
    before_period = await with_timeout(
        measure_hsclk_period_ns(dut), 20, "us")
    assert before_eff == 2 and abs(before_period - 4 * REF_PERIOD_NS) < 0.01, (
        f"setup failed: wanted /4 from the port, got ratio_eff={before_eff}, "
        f"period={before_period} ns"
    )

    # Every offset a bank would have made writable, plus a couple that a
    # partial decode might catch. All ratio codes, including legal ones -- if
    # any of these could take effect the safety rule would be violable from
    # software with the feature nominally switched off.
    for addr in [Q_RATE + 0x000, Q_RATE + 0x004, Q_RATE + 0x008,
                 Q_RATE + 0x00C, Q_RATE + 0x010, Q_RATE + 0x1FFC]:
        for val in (0x0, 0x1, 0x3, 0x4, 0x7, 0xFFFF_FFFF):
            _, cycles, slverr = await apb.write(addr, val)
            assert slverr == 0, (
                f"quadrant-11 write 0x{addr:04X}<=0x{val:08X} asserted "
                f"pslverr={slverr}; the undecoded fall-through never errored")
            assert cycles == 1, (
                f"quadrant-11 write 0x{addr:04X}<=0x{val:08X} acked after "
                f"{cycles} cycles, expected 1")

    await ClockCycles(dut.user_ref_clk, RATIO_SETTLE_REF_CYCLES)
    after_eff    = int(dut.obs_ratio_eff.value)
    after_period = await with_timeout(measure_hsclk_period_ns(dut), 20, "us")

    assert after_eff == before_eff, (
        f"THE LINK RATE MOVED BECAUSE OF AN APB WRITE. ratio_eff "
        f"{before_eff} -> {after_eff} after writes to quadrant 11 with "
        f"LINK_RATE_REGS_PRESENT=0. In the OFF build software must have no "
        f"path to the rate at all -- changing it invalidates the calibrator's "
        f"phase offset and is legal only with the PHY held in POR."
    )
    assert abs(after_period - before_period) < 0.01, (
        f"the forwarded PHY clock period moved {before_period} -> "
        f"{after_period} ns across quadrant-11 writes"
    )
    dut._log.info(f"36 quadrant-11 writes: rate unmoved at "
                  f"/{1 << after_eff} ({after_period} ns)")


# --------------------------------------------------------------------------- #
# 04 -- C3: the port is the ratio source
# --------------------------------------------------------------------------- #
@cocotb.test()
async def test_inert_04_ratio_port_is_authoritative(dut):
    """link_clk_div_ratio_i drives the real forwarded clock, unmuxed.

    KILLS: any mutation of `assign link_ratio_sel_w = link_clk_div_ratio_i;`.
    The sweep returns to /1 at the end so the handover is exercised in both
    directions, and the assertion is on the MEASURED period of link_hsclk_w --
    the clock the PHY actually gets -- with the divider's own ratio_o readback
    only as corroboration.
    """
    apb = await bringup(dut)
    check_present_off(dut)

    for ratio in (0, 1, 2, 3, 4, 0):
        await set_ratio(dut, ratio)
        sel    = dut.obs_ratio_sel.value
        eff    = dut.obs_ratio_eff.value
        period = await with_timeout(measure_hsclk_period_ns(dut), 40, "us")
        expect = (1 << ratio) * REF_PERIOD_NS

        assert sel.is_resolvable and int(sel) == ratio, (
            f"link_ratio_sel_w = {sel} with link_clk_div_ratio_i = {ratio}. "
            f"At LINK_RATE_REGS_PRESENT=0, g_link_rate_absent must alias the "
            f"port straight onto the divider -- no mux, no constant."
        )
        assert eff.is_resolvable and int(eff) == ratio, (
            f"divider ratio_o = {eff}, expected {ratio}")
        assert abs(period - expect) < 0.01, (
            f"link_hsclk_w period {period} ns at ratio code {ratio} "
            f"({RATIO_NAMES[ratio]}), expected {expect} ns. The PHY reference "
            f"clock is not following link_clk_div_ratio_i."
        )
        dut._log.info(f"ratio code {ratio} ({RATIO_NAMES[ratio]:>3}): "
                      f"link_hsclk_w period {period} ns  [expected {expect}]")

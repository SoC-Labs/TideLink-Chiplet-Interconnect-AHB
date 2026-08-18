"""D2D link-rate CONTROL PATH test — drives the divider from the APB register
bank, not from a testbench signal.

WHY THIS FILE EXISTS
    The existing rate evidence in this directory is the whole bring-up suite
    re-run at +LINK_DIV_RATIO=0..4. That plusarg drives tb_top's `link_div_ratio`
    straight into the tidelink_top port `link_clk_div_ratio_i`. It is excellent
    evidence that tidelink_link_clk_div WORKS — a divided link trains, calibrates
    and carries traffic — but it proves nothing about how silicon would ever ASK
    for a divided rate. On the ethernet chiplet that port is tied to 3'd0 in
    src/rtl/nanosoc_eth_chiplet.sv, so the only reachable control path is
    tidelink_link_rate_regs in APB quadrant 11. This file exercises exactly that
    path: every ratio change below originates from an APB write, and one of the
    checks is made on the real divided clock rather than on a register readback.

WHAT IS CHECKED
    test_rate_01_id_and_decode        the quadrant decodes at all (ID magic), and
                                      does not alias across its 8 KB aperture
    test_rate_02_write_before_lock    a pre-role-lock CTRL write is ACCEPTED,
                                      src_sticky sets, ratio_eff converges
    test_rate_03_divider_follows_reg  the REAL clock period changes /1 -> /4 -> /16
                                      as a result of APB writes only
    test_rate_04_write_after_lock     a post-role-lock CTRL write is REFUSED,
                                      the ratio is unchanged, write_refused sets
    test_rate_05_clamp                an out-of-range request clamps to MAX_RATIO
                                      and records ratio_clamped
    test_rate_06_undefined_offsets    undefined offsets read 0 and still ack in a
                                      single access cycle (property 3: no PS hang)

HOW TO RUN — THE PARAMETER OVERRIDE IS MANDATORY
    tidelink_top instantiates the bank under
        if (LINK_RATE_REGS_PRESENT) begin : g_link_rate_regs
    and that parameter DEFAULTS TO 1'b0 (src/rtl/tidelink_top.sv:253). tb_top.sv
    does not override it, and this file must not change either — the OFF default
    is what the shipping wrapper elaborates today. So the bench is turned on from
    the command line, through the Makefile's existing EXTRA_DEFINES hook (it is
    appended raw to COMPILE_ARGS, so it carries VCS elaboration switches as
    happily as it carries +define+):

      export CMSDK_FPGA_SRAM_V="$(realpath ../../imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v)"
      make MODULE=test_link_rate_regs SIM_BUILD=sim_build_rate_regs \\
           TB_TOP_NO_DUMP=1 \\
           EXTRA_DEFINES="-pvalue+tb_top.u_master.LINK_RATE_REGS_PRESENT=1 \\
                          -pvalue+tb_top.u_slave.LINK_RATE_REGS_PRESENT=1"

    Use a dedicated SIM_BUILD: the -pvalue+ overrides are baked into the
    elaborated simv, so sharing sim_build/ with the ordinary pair tests would
    hand them a DUT with the bank present. Nothing in this file can detect that,
    and it would be a silent change of what every other test in this directory
    measures.

    If the override does not reach the DUT, every test here fails in
    require_bank_present() with an explicit diagnosis, BEFORE any register read —
    because at LINK_RATE_REGS_PRESENT=0 quadrant 11 reads a clean, acked zero at
    every address, so a bare `0 != 0x4C434401` would be indistinguishable from a
    broken register bank. Verified: with the override omitted this file reports
    6 FAIL, all naming the missing parameter (2026-08-18).

Register map — tidelink_link_rate_regs.sv, quadrant 11 => APB 0x6000 in the
tb's 15-bit unified window (SoC 0x2E03_6000 on the ethernet chiplet).
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, SimTimeoutError, with_timeout
from cocotb.utils import get_sim_time

# Reuse the pair harness verbatim: APB master idiom, clock start-up, AHB
# quiescing, reset sequence and the ROLE_CFG W1S role-lock helper. Importing
# only names (never `import *`) keeps the doorbell module's own @cocotb.test
# objects out of this module's namespace, so cocotb's discovery — which scans
# vars(module) for Test instances — does not pull the 11 doorbell tests into
# this run.
from test_tidelink_pair_doorbell import (
    APBMaster,
    PairTB,
    REF_CLK_PERIOD_NS,
)

# ---------------------------------------------------------------------------
# Register map — tidelink_link_rate_regs.sv header. Quadrant select is
# apb_paddr[14:13] == 2'b11, i.e. base 0x6000 of the 15-bit unified APB.
# ---------------------------------------------------------------------------
RATE_BASE = 0x6000
RATE_ID   = RATE_BASE + 0x000          # RO magic
RATE_CTRL = RATE_BASE + 0x004          # RW [2:0] ratio_req
RATE_STAT = RATE_BASE + 0x008          # RO status

# Undefined offsets. 0x00C is INSIDE the 16-byte bank (in_bank=1, word 3 -> the
# case default) and 0x010 / 0x800 are outside it (in_bank=0). Both classes must
# read 0 and ack, and 0x010 additionally proves the bank does not alias — the
# config quadrant next door aliases its map 16x, and a clock knob must not.
RATE_UNDEF_IN_BANK  = RATE_BASE + 0x00C
RATE_UNDEF_OUT_LOW  = RATE_BASE + 0x010
RATE_UNDEF_OUT_HIGH = RATE_BASE + 0x800

ID_MAGIC = 0x4C43_4401                 # "LCD" + version 01

# STAT field positions
STAT_EFF_LSB       = 0    # [2:0]
STAT_SETTLED       = 3
STAT_ROLE_LOCKED   = 4
STAT_REQ_LSB       = 5    # [7:5]
STAT_SRC_STICKY    = 8
STAT_WRITE_REFUSED = 9
STAT_MAX_RATIO_LSB = 10   # [12:10]
STAT_RATIO_CLAMPED = 13

# The MAX_RATIO the parent instantiates with. tidelink_top.sv:2900-2904 passes
# only APB_ADDR_W and SYS_DATA_W, so MAX_RATIO keeps the module default 3'd4
# (all five divider modes reachable). Asserted, not assumed: if the parent ever
# starts overriding it, this test says so instead of silently re-scoping.
EXPECT_MAX_RATIO = 4

RATIO_NAMES = {0: "/1", 1: "/2", 2: "/4", 3: "/8", 4: "/16"}


def decode_stat(v):
    """Unpack LINK_RATE_STAT into a dict (field layout from the RTL header)."""
    return {
        "ratio_eff":     (v >> STAT_EFF_LSB) & 0x7,
        "settled":       (v >> STAT_SETTLED) & 1,
        "role_locked":   (v >> STAT_ROLE_LOCKED) & 1,
        "ratio_req":     (v >> STAT_REQ_LSB) & 0x7,
        "src_sticky":    (v >> STAT_SRC_STICKY) & 1,
        "write_refused": (v >> STAT_WRITE_REFUSED) & 1,
        "max_ratio":     (v >> STAT_MAX_RATIO_LSB) & 0x7,
        "ratio_clamped": (v >> STAT_RATIO_CLAMPED) & 1,
        "raw":           v,
    }


def fmt_stat(v):
    d = decode_stat(v)
    return ("STAT=0x{raw:08x} eff={ratio_eff} req={ratio_req} settled={settled} "
            "role_locked={role_locked} src_sticky={src_sticky} "
            "refused={write_refused} max={max_ratio} clamped={ratio_clamped}"
            ).format(**d)


# ---------------------------------------------------------------------------
# APB master with an access-phase cycle count
# ---------------------------------------------------------------------------
class CountingAPBMaster(APBMaster):
    """PairTB's APB master plus a read that reports how many access cycles the
    subordinate took to ack.

    Needed for property 3: quadrant 11 sits outside tidelink_top's bounded-stall
    watchdog (ext_txn covers quadrant 01 only) and behind a Zynq M_AXI_GP with no
    bus timeout, so an un-acked access there hangs the PS for ever. "Reads 0" is
    only half the requirement; "and completes" is the half that matters, and the
    base class's read() hides it inside a 200-cycle poll.
    """

    async def read_counted(self, addr, timeout=200):
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
        for n in range(1, timeout + 1):
            await RisingEdge(self._clk)
            if int(self._pready.value):
                try:
                    data = int(self._prdata.value)
                except ValueError:
                    data = 0
                self.idle()
                return data, n
        self.idle()
        raise TimeoutError(
            f"APB read from 0x{addr:04x} never acked — quadrant 11 must ack "
            f"unconditionally (tidelink_link_rate_regs property 3)")


# ---------------------------------------------------------------------------
# Harness helpers
# ---------------------------------------------------------------------------
def make_tb(dut):
    """Build the pair harness and swap in the counting APB masters.

    A fresh PairTB per test is deliberate, not sloppy: cocotb cancels every task
    a test started when that test ends (cocotb/_test.py:97-100), so the hclk and
    ref_clk drivers die with the test that started them and each test must start
    its own. It also means exactly ONE clock driver is ever live, which is what
    makes the period measurement in test_rate_03 trustworthy.
    """
    tb = PairTB(dut)
    tb.m_apb = CountingAPBMaster(dut, dut.hclk, "m")
    tb.s_apb = CountingAPBMaster(dut, dut.hclk, "s")
    return tb


def side_top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def require_bank_present(dut, side="m"):
    """Fail with the actual cause if the bank was not elaborated.

    Without this the whole file fails on `0 != 0x4C434401`, which reads exactly
    like a broken register bank and is in fact a build that never contained one:
    at LINK_RATE_REGS_PRESENT=0 the g_link_rate_absent arm ties quadrant 11 to
    prdata=0 / pready=1, so every read in this file returns a clean, acked zero.

    HOW THE CHECK IS MADE, AND A TRAP THAT COST A RUN. The obvious probe —
    `dut.u_master.g_link_rate_regs.u_link_rate_regs` — raises AttributeError
    EVEN WHEN THE ARM IS ELABORATED. VCS's VPI does not publish the generate
    block as a nested scope under tidelink_top; it publishes its contents as
    children of tidelink_top whose NAMES contain a dot
    ("g_link_rate_regs.u_link_rate_regs"). Written the obvious way this guard
    reports "the bank is absent" about a build that contains it, which is a
    check that measures nothing while looking decisive. So: read the parameter
    itself (unambiguous), and confirm with the dotted-name child lookup.
    """
    top = side_top(dut, side)
    present = None
    try:
        present = int(top.LINK_RATE_REGS_PRESENT.value)
    except (AttributeError, ValueError):
        present = None
    try:
        top["g_link_rate_regs.u_link_rate_regs"]
        instantiated = True
    except (AttributeError, KeyError, IndexError):
        instantiated = False

    if present == 1 and instantiated:
        return
    if present == 1 and not instantiated:
        raise AssertionError(
            "u_{} has LINK_RATE_REGS_PRESENT=1 but no "
            "g_link_rate_regs.u_link_rate_regs instance — the generate arm did "
            "not elaborate the bank.".format("master" if side == "m" else "slave"))
    if instantiated:
        return
    raise AssertionError(
            "tidelink_link_rate_regs was NOT elaborated in u_{}: the generate "
            "arm g_link_rate_regs is absent, so LINK_RATE_REGS_PRESENT is 0 and "
            "quadrant 11 is the old undecoded fall-through (reads 0, acks, never "
            "errors). Rebuild with\n"
            "  make MODULE=test_link_rate_regs SIM_BUILD=sim_build_rate_regs \\\n"
            "       EXTRA_DEFINES=\"-pvalue+tb_top.u_master.LINK_RATE_REGS_PRESENT=1 "
            "-pvalue+tb_top.u_slave.LINK_RATE_REGS_PRESENT=1\"\n"
            "and use a SIM_BUILD not shared with the other pair tests."
            .format("master" if side == "m" else "slave")) from None


def link_hsclk(dut, side):
    """Handle on the divider output that becomes the PHY's user_hsclk.

    Two candidate paths because which of them survives depends on how VCS
    collapses the net: link_hsclk_w is the tidelink_top-level wire, clk_out is
    the divider's own output port. They are the same net.
    """
    top = side_top(dut, side)
    for path in (("link_hsclk_w",), ("u_link_clk_div", "clk_out")):
        obj = top
        try:
            for part in path:
                obj = getattr(obj, part)
            return obj
        except AttributeError:
            continue
    raise AssertionError(
        "neither u_{}.link_hsclk_w nor u_{}.u_link_clk_div.clk_out is visible — "
        "cannot measure the real link clock".format(side, side))


async def measure_period_ns(sig, periods=6, edge_timeout_ns=40000.0):
    """Mean rising-edge period of `sig` in ns, or None if it is not toggling.

    Measured on the real clock net, which is the point: the whole feature is a
    clock knob, and a register that reads back the right code while the clock
    keeps its old period would pass every readback check in this file.
    """
    try:
        await with_timeout(RisingEdge(sig), edge_timeout_ns, "ns")
    except SimTimeoutError:
        return None
    t0 = get_sim_time("ns")
    for _ in range(periods):
        try:
            await with_timeout(RisingEdge(sig), edge_timeout_ns, "ns")
        except SimTimeoutError:
            return None
    t1 = get_sim_time("ns")
    return (t1 - t0) / periods


async def poll_stat(apb, predicate, cycles=400, clk=None):
    """Poll LINK_RATE_STAT until `predicate(decoded)` holds. Returns the last
    STAT value read, whether or not the predicate was ever satisfied — the
    caller asserts, so a timeout still yields a printable state."""
    stat = 0
    for _ in range(cycles):
        stat = await apb.read(RATE_STAT)
        if predicate(decode_stat(stat)):
            return stat
        if clk is not None:
            await ClockCycles(clk, 4)
    return stat


# ===========================================================================
# Tests
# ===========================================================================

@cocotb.test()
async def test_rate_01_id_and_decode(dut):
    """Quadrant 11 decodes, and it decodes only where it should.

    Before this feature quadrant 11 was undecoded and every address in its 8 KB
    read back 0 through the response-mux fall-through, so a wrong address is
    indistinguishable from a wrong build unless something in the aperture reads
    non-zero. ID is that something.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")
    require_bank_present(dut, "s")

    for side, apb in (("master", tb.m_apb), ("slave", tb.s_apb)):
        ident = await apb.read(RATE_ID)
        tb.log.info(f"  {side} LINK_RATE_ID = 0x{ident:08x}")
        assert ident == ID_MAGIC, (
            f"{side} LINK_RATE_ID read 0x{ident:08x}, expected 0x{ID_MAGIC:08x}. "
            f"0x00000000 means quadrant 11 is still the undecoded fall-through; "
            f"anything else means the bank answered with the wrong identity.")

    # STAT out of reset, and a second non-zero field from a different word so
    # that "the bank answered" does not rest on the ID constant alone.
    stat = await tb.m_apb.read(RATE_STAT)
    d = decode_stat(stat)
    tb.log.info(f"  master reset {fmt_stat(stat)}")
    assert d["max_ratio"] == EXPECT_MAX_RATIO, (
        f"STAT.max_ratio={d['max_ratio']} but tidelink_top instantiates the bank "
        f"without a MAX_RATIO override, so the module default {EXPECT_MAX_RATIO} "
        f"is expected. If the parent now overrides it, this test's clamp "
        f"expectations need re-scoping too.")
    assert d["src_sticky"] == 0, "src_sticky set out of reset — the port must stay authoritative"
    assert d["write_refused"] == 0, "write_refused set out of reset"
    assert d["ratio_clamped"] == 0, "ratio_clamped set out of reset"
    assert d["ratio_req"] == 0, "ratio_req not /1 out of reset"
    assert d["settled"] == 0, "settled must be 0 while src_sticky is 0"
    assert d["role_locked"] == 0, "role_locked already high before role lock"

    ctrl = await tb.m_apb.read(RATE_CTRL)
    assert ctrl == 0, f"CTRL out of reset = 0x{ctrl:08x}, expected 0 (/1 bypass)"

    # No aliasing: one word past the bank must NOT mirror ID (property 4).
    alias = await tb.m_apb.read(RATE_UNDEF_OUT_LOW)
    assert alias == 0, (
        f"0x{RATE_UNDEF_OUT_LOW:04x} read 0x{alias:08x} — the bank is aliasing "
        f"across its aperture; a clock knob must answer at exactly three "
        f"addresses (property 4).")


@cocotb.test()
async def test_rate_02_write_before_lock(dut):
    """A CTRL write while !role_locked is accepted end to end.

    Accepted means all four of: CTRL reads back the request, src_sticky sets (so
    the parent's mux has handed the divider over to this bank), STAT.ratio_req
    shows what the bank drives, and STAT.ratio_eff — which is the DIVIDER's own
    ratio_o resynchronised back into hclk — converges to it. The last one is the
    only one that involves the divider at all.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")

    assert int(dut.m_role_locked.value) == 0, "master already role-locked at POR"

    target = 2   # /4
    await tb.m_apb.write(RATE_CTRL, target)

    ctrl = await tb.m_apb.read(RATE_CTRL)
    assert ctrl == target, (
        f"CTRL readback 0x{ctrl:08x} after writing {target} — the pre-lock write "
        f"was not accepted")

    stat = await poll_stat(
        tb.m_apb,
        lambda d: d["src_sticky"] == 1 and d["ratio_eff"] == target and d["settled"] == 1,
        cycles=200, clk=dut.hclk)
    d = decode_stat(stat)
    tb.log.info(f"  after CTRL<={target} ({RATIO_NAMES[target]}): {fmt_stat(stat)}")

    assert d["src_sticky"] == 1, (
        "src_sticky did not set — the parent's sticky source mux is still "
        "selecting the link_clk_div_ratio_i port, so software cannot reach the "
        "divider at all")
    assert d["ratio_req"] == target, f"STAT.ratio_req={d['ratio_req']}, expected {target}"
    assert d["ratio_eff"] == target, (
        f"STAT.ratio_eff={d['ratio_eff']} never reached {target}: the divider's "
        f"ratio_o did not follow the register. {fmt_stat(stat)}")
    assert d["settled"] == 1, f"settled never asserted. {fmt_stat(stat)}"
    assert d["write_refused"] == 0, "write_refused set by an accepted write"
    assert d["ratio_clamped"] == 0, f"ratio_clamped set by an in-range request ({target})"

    # The port is now irrelevant — and must be, because the sticky mux never
    # hands back. tb_top holds link_div_ratio at 0 (/1); if the mux were still
    # listening to it, ratio_eff would have gone back to 0 by now.
    assert int(dut.link_div_ratio.value) == 0, (
        "this test assumes the tb port strap is /1; it is not, so the "
        "port-vs-register distinction below is not being tested")


@cocotb.test()
async def test_rate_03_divider_follows_reg(dut):
    """The REAL clock changes rate because of an APB write.

    Everything above is a register talking about itself. This measures the
    period of the net that feeds WlinkGPIOPHY's user_hsclk — which IS the per-lane
    bit rate, there being no PLL on that path — before and after the write.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")

    hs = link_hsclk(dut, "m")

    # Baseline: /1 bypass, so clk_out is user_ref_clk gated straight through.
    base = await measure_period_ns(hs)
    assert base is not None, "link hs clock is not toggling at POR (/1 bypass)"
    tb.log.info(f"  measured hsclk period at POR: {base:.3f} ns "
                f"(ref_clk = {REF_CLK_PERIOD_NS} ns)")
    assert abs(base - REF_CLK_PERIOD_NS) < 0.05 * REF_CLK_PERIOD_NS, (
        f"POR hsclk period {base:.3f} ns is not the undivided ref_clk "
        f"{REF_CLK_PERIOD_NS} ns — the /1 bypass reset state is wrong, and every "
        f"ratio measured below would be measured against the wrong baseline")

    for target in (2, 4):     # /4 then /16
        expect = REF_CLK_PERIOD_NS * (1 << target)
        await tb.m_apb.write(RATE_CTRL, target)
        stat = await poll_stat(tb.m_apb, lambda d: d["ratio_eff"] == target,
                               cycles=200, clk=dut.hclk)
        assert decode_stat(stat)["ratio_eff"] == target, (
            f"ratio_eff never reached {target}. {fmt_stat(stat)}")
        # Let the glitchless interlock finish. div_en_r retimes on the falling
        # edge of the DIVIDED clock, so the handover costs up to two divided
        # half-periods; at /16 that is ~256 ns. 200 hclk = 4 us covers it with
        # room, and the handover deliberately parks clk_out low in between.
        await ClockCycles(dut.hclk, 200)

        got = await measure_period_ns(hs)
        assert got is not None, (
            f"link hs clock STOPPED after an APB write of ratio {target} "
            f"({RATIO_NAMES[target]}) — the handover interlock never re-enabled "
            f"a leg. This is a dead link, not a slow one.")
        tb.log.info(f"  APB CTRL<={target} ({RATIO_NAMES[target]}): "
                    f"hsclk period {got:.3f} ns, expected {expect:.3f} ns")
        assert abs(got - expect) < 0.05 * expect, (
            f"hsclk period {got:.3f} ns after an APB write of ratio {target} "
            f"({RATIO_NAMES[target]}); expected {expect:.3f} ns. The register "
            f"reports ratio_eff={target} but the clock disagrees.")

    # Control: the slave was never written, so its clock must still be /1. This
    # is what separates "the APB write did it" from "something global did it".
    s_base = await measure_period_ns(link_hsclk(dut, "s"))
    assert s_base is not None, "slave link hs clock stopped"
    tb.log.info(f"  control: slave hsclk period {s_base:.3f} ns (never written)")
    assert abs(s_base - REF_CLK_PERIOD_NS) < 0.05 * REF_CLK_PERIOD_NS, (
        f"slave hsclk period {s_base:.3f} ns changed without a slave APB write — "
        f"the rate change is not scoped to the die whose register was written")


@cocotb.test()
async def test_rate_04_write_after_lock_refused(dut):
    """A CTRL write AFTER role-lock is refused, recorded, and still acked.

    The sequencing rule (a rate change invalidates the calibrator's phase
    solution, so it is legal only while the PHY is held in POR) is enforced in
    RTL rather than in a bring-up script. Two halves matter equally: the ratio
    must not move, and the attempt must be visible afterwards — a silently
    dropped write is how a run ends up chasing a PHY fault that is really a rate
    that never changed.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")

    # Establish a non-default ratio through the legal window first, so "refused"
    # is proven as "the ratio stayed at 1", not as "the ratio stayed at its reset
    # value" — which a bank that ignored every write would also satisfy.
    pre = 1   # /2
    await tb.m_apb.write(RATE_CTRL, pre)
    stat = await poll_stat(tb.m_apb, lambda d: d["ratio_eff"] == pre,
                           cycles=200, clk=dut.hclk)
    assert decode_stat(stat)["ratio_eff"] == pre, (
        f"pre-lock write of {pre} did not take effect; the refusal test below "
        f"would be vacuous. {fmt_stat(stat)}")

    # Role-lock via the ROLE_CFG W1S path (the same one deploy_pair.sh uses).
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    assert locked and int(dut.m_role_locked.value) == 1, (
        "role_locked never asserted — the refusal window was never entered, so "
        "this test cannot say anything about post-lock writes")

    stat = await tb.m_apb.read(RATE_STAT)
    assert decode_stat(stat)["role_locked"] == 1, (
        f"STAT.role_locked reads 0 while m_role_locked is 1 — the bank is not "
        f"seeing the write gate. {fmt_stat(stat)}")

    # The refused write. It must ACK: APBMaster.write raises TimeoutError if it
    # does not, and quadrant 11 has no bounded-stall watchdog behind it.
    post = 4   # /16 — would be a large, obvious change if it landed
    await tb.m_apb.write(RATE_CTRL, post)
    await ClockCycles(dut.hclk, 50)

    ctrl = await tb.m_apb.read(RATE_CTRL)
    stat = await tb.m_apb.read(RATE_STAT)
    d = decode_stat(stat)
    tb.log.info(f"  post-lock write of {post}: CTRL=0x{ctrl:08x} {fmt_stat(stat)}")

    assert ctrl == pre, (
        f"CTRL moved from {pre} to 0x{ctrl:08x} on a post-role-lock write — the "
        f"write window is not enforced, and a rate change on a locked link "
        f"invalidates the calibrator's phase solution")
    assert d["ratio_req"] == pre, f"STAT.ratio_req moved to {d['ratio_req']}"
    assert d["ratio_eff"] == pre, (
        f"the divider moved to {d['ratio_eff']} on a refused write")
    assert d["write_refused"] == 1, (
        "write_refused did not set: the write was dropped silently, which is the "
        "failure mode property 2 exists to prevent")

    # The real clock is the arbiter, same as test_03.
    got = await measure_period_ns(link_hsclk(dut, "m"))
    expect = REF_CLK_PERIOD_NS * (1 << pre)
    assert got is not None, "link hs clock stopped after the refused write"
    tb.log.info(f"  hsclk after refused write: {got:.3f} ns "
                f"(expect {expect:.3f} ns = {RATIO_NAMES[pre]})")
    assert abs(got - expect) < 0.05 * expect, (
        f"hsclk period {got:.3f} ns after a REFUSED write; expected "
        f"{expect:.3f} ns ({RATIO_NAMES[pre]}). The register refused it and the "
        f"clock took it anyway.")


@cocotb.test()
async def test_rate_05_out_of_range_clamps(dut):
    """An out-of-range request clamps to MAX_RATIO and says so.

    MAX_RATIO is the statement that the reachable ratio set and the STA-certified
    ratio set are the same. If a request above it landed unclamped, a host loop
    waiting for ratio_eff == what-it-wrote would never terminate.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")

    asked = 7   # 3'b111 — above MAX_RATIO=4 and above the divider's own decode
    await tb.m_apb.write(RATE_CTRL, asked)

    ctrl = await tb.m_apb.read(RATE_CTRL)
    stat = await poll_stat(tb.m_apb,
                           lambda d: d["ratio_eff"] == EXPECT_MAX_RATIO,
                           cycles=200, clk=dut.hclk)
    d = decode_stat(stat)
    tb.log.info(f"  wrote {asked}: CTRL=0x{ctrl:08x} {fmt_stat(stat)}")

    assert ctrl == EXPECT_MAX_RATIO, (
        f"CTRL reads 0x{ctrl:08x} after writing {asked}; expected the clamped "
        f"{EXPECT_MAX_RATIO}. Clamping on the way IN is what lets a host poll "
        f"ratio_eff against its own CTRL readback.")
    assert d["ratio_req"] == EXPECT_MAX_RATIO, f"STAT.ratio_req={d['ratio_req']}"
    assert d["ratio_clamped"] == 1, (
        "ratio_clamped did not set — the host cannot tell 'running /16 because I "
        "asked' from 'running /16 because the build will not give me more'")
    assert d["ratio_eff"] == EXPECT_MAX_RATIO, (
        f"ratio_eff={d['ratio_eff']} did not reach the clamped "
        f"{EXPECT_MAX_RATIO}. {fmt_stat(stat)}")
    assert d["write_refused"] == 0, "write_refused set by an accepted (clamped) write"

    got = await measure_period_ns(link_hsclk(dut, "m"))
    expect = REF_CLK_PERIOD_NS * (1 << EXPECT_MAX_RATIO)
    assert got is not None, "link hs clock stopped at the clamped ratio"
    tb.log.info(f"  hsclk at clamped ratio: {got:.3f} ns (expect {expect:.3f} ns)")
    assert abs(got - expect) < 0.05 * expect, (
        f"hsclk period {got:.3f} ns at the clamped ratio; expected {expect:.3f} ns")


@cocotb.test()
async def test_rate_06_undefined_offsets_raz_and_ack(dut):
    """Undefined offsets in the quadrant read 0 AND complete in one cycle.

    The ack half is the one with teeth: quadrant 11 is outside tidelink_top's
    ext_txn bounded-stall watchdog and the KR260's M_AXI_GP has no bus timeout,
    so an aperture that can stall for ever is strictly worse than one that is
    absent. A read of a hole must therefore be boring, not silent.
    """
    tb = make_tb(dut)
    await tb.reset()
    require_bank_present(dut, "m")

    # Control first: a DEFINED offset, so a uniform "everything acks in 1 and
    # reads 0" cannot be mistaken for a pass. If ID also read 0 the checks below
    # would be measuring a build with no bank in it.
    ident, n_id = await tb.m_apb.read_counted(RATE_ID)
    assert ident == ID_MAGIC, (
        f"control read of LINK_RATE_ID gave 0x{ident:08x}; the RAZ checks below "
        f"would be vacuous")
    assert n_id == 1, f"LINK_RATE_ID acked in {n_id} access cycles, expected 1"
    tb.log.info(f"  control: ID=0x{ident:08x} in {n_id} cycle(s)")

    for addr, why in ((RATE_UNDEF_IN_BANK,  "inside the 16-byte bank, undefined word"),
                      (RATE_UNDEF_OUT_LOW,  "one word past the bank"),
                      (RATE_UNDEF_OUT_HIGH, "deep in the 8 KB aperture")):
        data, n = await tb.m_apb.read_counted(addr)
        tb.log.info(f"  0x{addr:04x} ({why}): data=0x{data:08x} acked in {n} cycle(s)")
        assert data == 0, (
            f"0x{addr:04x} ({why}) read 0x{data:08x}, expected 0 — an undefined "
            f"offset is answering with real register content")
        assert n == 1, (
            f"0x{addr:04x} ({why}) took {n} access cycles to ack; pready is a "
            f"hard 1'b1 in this bank, so anything but 1 means the response mux "
            f"is not selecting quadrant 11")

    # A write to a hole must also complete (APBMaster.write raises on timeout)
    # and must not disturb the bank.
    await tb.m_apb.write(RATE_UNDEF_OUT_LOW, 0xFFFF_FFFF)
    await ClockCycles(dut.hclk, 10)
    stat = await tb.m_apb.read(RATE_STAT)
    d = decode_stat(stat)
    tb.log.info(f"  after a write to a hole: {fmt_stat(stat)}")
    assert d["src_sticky"] == 0, (
        "a write to an undefined offset set src_sticky — the CTRL decode is "
        "answering outside its word")
    assert d["ratio_req"] == 0, f"a write to a hole moved ratio_req to {d['ratio_req']}"
    assert d["write_refused"] == 0, "a write to a hole set write_refused"

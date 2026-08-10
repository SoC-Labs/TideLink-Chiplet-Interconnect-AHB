"""ACK_DLY_COUNT investigation + sweep -- follow-up to test_v2_txgen_throughput.py's
finding (2026-07-31) that TXGEN's real sustained ceiling (~95-96 hclk/word,
flat across N=4..124) is set by Wlink's own internal ACK/credit windowing,
BELOW TXGEN's own FC-level credit gate -- not by TXGEN itself.

WHAT ack_dly_count ACTUALLY IS (traced end to end, not assumed)
-----------------------------------------------------------------
Chisel source: deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala
  L132   val ack_dly_count = Wire(UInt(8.W))
  L637-669 node.regmap(... WavSWReg(0x14, "SMControl", "",
             WavRW(link_en_wait,  8.U, "link_en_wait",  ...),
             WavRW(ack_dly_count, 7.U, "ack_dly_count", "Number of cycles to
                   wait between ACK packets."),
             WavRW(disable_crc,   false.B, "disable_crc", ...)) ...)

`WavRW` registers a field into `node`'s APB regmap -- this is a GENUINE
runtime-writable software register (RocketChip RegField, sw=rw/hw=r per
src/rdl/wlink_regs.rdl's mirror of the same map), NOT a compile-time Chisel
parameter. No Chisel regen is needed to change it -- see the RTL confirmation
below, which is what this file actually exercises.

RTL landing (the file this project's V2 sim actually compiles): the FC node
used for the TideLink data path is WlinkGenericFCSM_6 (SoC Labs hardened
variant, src/rtl/local_overrides/WlinkGenericFCSM_6.v), instantiated as
`wlink_tidelinktl` inside TideLinkToWlink.v:149 (`WlinkGenericFCSM_6
wlink_tidelinktl (...)`) -- confirmed by grep across every WlinkGenericFCSM*.v
in flists/tidelink_fpga_v2.flist and cross-checked against
pair_v2_common.PairV2TB.fcsm(side), which already hierarchically points at
this exact instance for observability elsewhere in this suite.

  WlinkGenericFCSM_6.v:817  reg [7:0] out_prepend_swi_ack_dly_count;
  WlinkGenericFCSM_6.v:906  {out_prepend_swi_disable_crc,
                             out_prepend_swi_ack_dly_count,
                             swi_link_en_wait}                  (SMControl)
  WlinkGenericFCSM_6.v:1712 out_prepend_swi_ack_dly_count <= 8'h7;      (reset)
  WlinkGenericFCSM_6.v:1714 out_prepend_swi_ack_dly_count <=
                                 auto_in_pwdata[15:8];           (APB write)

Register bit layout of fc_tidelink's SMControl register:
  [7:0]   swi_link_en_wait                reset 8'h8   (untouched here)
  [15:8]  out_prepend_swi_ack_dly_count    reset 8'h7   <- the lever
  [16]    out_prepend_swi_disable_crc      reset 1'h0   (untouched here)

Absolute APB address: src/rdl/wlink_regs.rdl places `fc_tidelink` (the FC
node backing the TideLink data path) at offset 0x1700 within `wlink_regs`,
with `sm_control` at +0x14 -> 0x1714. This testbench's unified 15-bit APB
view has NO extra base for that range -- confirmed by precedent
(APB_WL_LINK_ENABLE_RESET = 0x0208 in pair_v2_common.py is written directly,
with no added offset, and the RDL places `link_enable_reset @ 0x0208` at the
SAME flat address) -- and independently reconfirmed HERE, live, by
`set_ack_dly_count()` peeking the RTL register directly
(`tb.fcsm(side).out_prepend_swi_ack_dly_count`) after every APB write and
asserting it changed to the requested value. This is not a guess (see
"verify the INSTRUMENT before theorizing about the DUT" -- burned 6x already
per this project's own memory) -- test_ack_dly_register_identify below is
the standalone proof; every other test in this file relies on that having
passed.

WHY IT MATTERS FOR THROUGHPUT (the mechanism, FC.scala L501-607)
-----------------------------------------------------------------
`count` is a down-counter. Whenever an ACK ships (SEND_ACK state,
FC.scala:582-584), `count_in := ack_dly_count` reloads it. A NEW ack can only
be sent once `count === 0` again (the `send_ack_req && count === 0` gates at
FC.scala:514/546 for LINK_IDLE/LINK_DATA) -- i.e. ack_dly_count is a MINIMUM
spacing between ACK packets, throttled to leave TX airtime for real DATA.

Each ACK carries the ACKing side's RX-consume pointer back to the SENDER.
The sender's `link.ack_update`/`ack_addr` (FC.scala ~769-781, inside
WlinkGenericFCReplayV2 -- the a2l replay FIFO) is what frees the
corresponding slot in ITS 16-deep a2l replay window for new admission. So
throughput on M's send path is gated by the SPEED OF S's ACKs coming back --
i.e. S's ack_dly_count, not M's. Since M and S are symmetric builds here,
this sweep sets ack_dly_count on BOTH dies (mirroring the existing dual m/s
APB-write pattern used throughout pair_v2_common.py, e.g.
do_to_data_mode()'s APB_WL_LINK_ENABLE_RESET writes).

Two WavMultibitSync CDC crossings (toggle + 2-flop demet, single-entry
double-buffered; Components.scala:597) sit downstream in that same path:
  FC.scala:241  l2a_fifo_addr_to_tx      (RX app-addr  -> TX/link domain)
  FC.scala:773  link_addr_to_app_clk     (ACKed addr   -> APP domain, frees
                                           the a2l replay FIFO for new pushes)
Those are NOT swept here (no register controls them -- fixed 2-flop-demet
hardware), but they set a SEPARATE possible floor: even ack_dly_count=0
cannot go below whatever their own round-trip latency costs. Sweeping down to
0 is what exposes whether that floor is being hit (diminishing/negative
returns at the low end vs. a clean monotonic win).

Run (fast/optimistic default -- matches test_v2_txgen_throughput's own
default, TXGEN's own overhead dominates, the link is not yet the
bottleneck):
  make EPOCH_PROFILE=zero MODULE=test_v2_ack_dly_sweep
Run (silicon ratio -- the number that means anything against the ~16-cycle
ceiling and this project's ~95-96 cycle/word measured baseline):
  TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero MODULE=test_v2_ack_dly_sweep
Run a single test (fast iteration):
  TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero \\
      MODULE=test_v2_ack_dly_sweep TESTCASE=test_ack_dly_register_identify
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_PKT_WORD_LEN, REF_CLK_PERIOD_NS,
    CLK_PERIOD_NS,
)
from test_v2_txgen_throughput import (
    arm_and_run_txgen, verify_drain, _log_result, expected_header,
    expected_payload, PERF_CTRL, PERF_EN, CEILING_HCLK_PER_WORD,
    PEER_RX_CAPACITY_WORDS, DRAIN_SETTLE_CYCLES, APB_STATUS, ST_OVERRUN,
    ST_ERR_AHB, ST_EXT_ABORT, ST_GATE_ACTIVE, APB_RELEASED_ACC,
    TXGEN_CTRL, TXGEN_PKT, TXGEN_GAP, TXGEN_BUDGET, TXGEN_WORDS,
    TXGEN_STATUS, ST_STALL_CREDIT, CTRL_EN, CTRL_FOREVER, CTRL_START,
)

# fc_tidelink FC node's SMControl register (src/rdl/wlink_regs.rdl:
# fc_tidelink @ 0x1700, sm_control @ +0x14). Flat 15-bit APB view, no extra
# base -- see module docstring for the cross-check. set_ack_dly_count() below
# additionally verifies this LIVE via a hierarchical peek on every call.
FC_TIDELINK_SM_CONTROL = 0x1714
ACK_DLY_COUNT_DEFAULT  = 7   # RTL reset value (WlinkGenericFCSM_6.v:1712)


async def set_ack_dly_count(tb, side, value):
    """Read-modify-write ack_dly_count (bits [15:8] of fc_tidelink's
    SMControl @ 0x1714) on `side`, preserving link_en_wait/disable_crc, and
    VERIFY the write landed on the intended RTL register via a direct
    hierarchical peek -- not just trusting the address arithmetic (see
    module docstring / project memory: verify the instrument before
    theorizing about the DUT)."""
    apb = tb.apb(side)
    cur = await apb.read(FC_TIDELINK_SM_CONTROL)
    new = (cur & ~0xFF00) | ((value & 0xFF) << 8)
    await apb.write(FC_TIDELINK_SM_CONTROL, new)
    # The RTL register commits a couple of hclk cycles after pready (observed
    # empirically with a throwaway hierarchical-port-watch diagnostic: a peek
    # taken in the SAME delta-cycle as write() returning still reads the OLD
    # value, while the write demonstrably lands correctly -- a full 0xAAAA
    # test pattern read back exactly -- once a few cycles are allowed to
    # settle). Give it generous margin rather than chase the exact latency.
    await ClockCycles(tb.dut.hclk, 5)
    hw = int(tb.fcsm(side).out_prepend_swi_ack_dly_count.value)
    assert hw == (value & 0xFF), (
        f"[{side}] ack_dly_count APB write did NOT land on the expected RTL "
        f"register: wrote {value} to 0x{FC_TIDELINK_SM_CONTROL:04x} (readback "
        f"0x{new:06x}), but tb.fcsm('{side}').out_prepend_swi_ack_dly_count "
        f"reads {hw} -- the address assumption is WRONG, do not trust any "
        f"downstream throughput number from this session")
    return cur


async def get_ack_dly_count_hw(tb, side):
    """Ground truth straight off the RTL register (bypasses APB readback,
    which set_ack_dly_count already cross-checks against this on every
    write)."""
    return int(tb.fcsm(side).out_prepend_swi_ack_dly_count.value)


@cocotb.test()
async def test_ack_dly_register_identify(dut):
    """Standalone proof that ack_dly_count is a genuine runtime APB register
    at 0x1714[15:8], not a compile-time parameter: confirm the RTL reset
    default (7) on both dies, write a probe value via APB, confirm the RTL
    register actually changed (hierarchical peek) AND that link_en_wait
    (bits [7:0], untouched) survived the read-modify-write, then restore the
    default. This is the instrument-verification gate every other test in
    this file depends on."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    await ClockCycles(dut.hclk, 50)

    for side in ("m", "s"):
        hw = await get_ack_dly_count_hw(tb, side)
        assert hw == ACK_DLY_COUNT_DEFAULT, (
            f"[{side}] ack_dly_count RTL reset default = {hw}, expected "
            f"{ACK_DLY_COUNT_DEFAULT} (WlinkGenericFCSM_6.v:1712) -- either "
            f"the wrong FCSM instance is being probed or the file has "
            f"drifted since this suite was written")
        raw = await tb.apb(side).read(FC_TIDELINK_SM_CONTROL)
        tb.log.info(f"  [{side}] SMControl @ 0x{FC_TIDELINK_SM_CONTROL:04x} "
                    f"= 0x{raw:06x} (link_en_wait=0x{raw & 0xFF:02x} "
                    f"ack_dly_count=0x{(raw >> 8) & 0xFF:02x} "
                    f"disable_crc={(raw >> 16) & 1}) hw_peek={hw}")

    PROBE = 3
    for side in ("m", "s"):
        link_en_before = (await tb.apb(side).read(FC_TIDELINK_SM_CONTROL)) & 0xFF
        await set_ack_dly_count(tb, side, PROBE)
        raw_after = await tb.apb(side).read(FC_TIDELINK_SM_CONTROL)
        link_en_after = raw_after & 0xFF
        assert link_en_after == link_en_before, (
            f"[{side}] link_en_wait changed from {link_en_before} to "
            f"{link_en_after} as a side effect of the ack_dly_count "
            f"read-modify-write -- bit layout assumption wrong")
        tb.log.info(f"  [{side}] set ack_dly_count={PROBE} OK, "
                    f"link_en_wait preserved at {link_en_after}")

    # Restore the default so nothing downstream in a shared sim_build is
    # surprised (each `make` run is a fresh simv process/reset in this repo's
    # convention, but keep this test symmetric/side-effect-free regardless).
    for side in ("m", "s"):
        await set_ack_dly_count(tb, side, ACK_DLY_COUNT_DEFAULT)

    tb.log.info("[identify] ack_dly_count CONFIRMED runtime-writable APB "
                f"register at 0x{FC_TIDELINK_SM_CONTROL:04x}[15:8], default "
                f"{ACK_DLY_COUNT_DEFAULT}, no Chisel regen required.")


@cocotb.test()
async def test_ack_dly_sweep_throughput(dut):
    """The headline sweep: cycles/word AND byte-exact/in-order correctness at
    ack_dly_count = 7 (default/baseline), 6, 5, 4, 3, 2, 1, 0 -- one bring-up,
    the register changed live between configs (it is genuinely runtime-
    writable, see test_ack_dly_register_identify), each config fully drained
    and byte-checked before the next (so no cross-config cumulative-capacity
    bookkeeping is needed -- see module docstring)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)

    PKT_LEN = 124                        # 126 words/packet, same as the
    NPKT    = 20                         # headline ceiling test -- 2520
                                          # words/config, comfortably under
                                          # the peer's 4096-word capacity
                                          # with full drain between configs
    assert (PKT_LEN + 2) * NPKT < PEER_RX_CAPACITY_WORDS

    tb.log.info(f"[ack_dly sweep] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} "
                f"CLK_PERIOD_NS={CLK_PERIOD_NS} -> ceiling="
                f"{CEILING_HCLK_PER_WORD:.3f} hclk/word "
                f"({'REALISTIC silicon ratio' if abs(REF_CLK_PERIOD_NS - 40.0) < 1e-6 else 'NOT the silicon ratio -- see test_v2_txgen_throughput module docstring'}) "
                f"PKT_LEN={PKT_LEN} NPKT={NPKT} ({(PKT_LEN + 2) * NPKT} words/config)")

    SWEEP = [7, 6, 5, 4, 3, 2, 1, 0]
    pkt_index = 0
    rows = []
    for ack_dly in SWEEP:
        for side in ("m", "s"):
            await set_ack_dly_count(tb, side, ack_dly)
        await ClockCycles(dut.hclk, 50)

        crc_before = {s: int(tb.fcsm(s).crc_errors.value) for s in ("m", "s")}

        r = await arm_and_run_txgen(tb, "m", PKT_LEN, NPKT)
        cpw = _log_result(tb, f"ack_dly={ack_dly}", r)

        words_ok = r["words"] == r["total_words"]
        no_fault = not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT))

        await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
        mism = await verify_drain(tb, "s", NPKT, r["per_packet"], PKT_LEN,
                                   pkt_index_start=pkt_index)
        pkt_index += NPKT

        s_status = await tb.apb("s").read(APB_STATUS)
        overran = bool(s_status & ST_OVERRUN)

        crc_after = {s: int(tb.fcsm(s).crc_errors.value) for s in ("m", "s")}
        crc_delta = {s: crc_after[s] - crc_before[s] for s in ("m", "s")}

        clean = words_ok and no_fault and not mism and not overran and \
            crc_delta["m"] == 0 and crc_delta["s"] == 0

        tb.log.info(
            f"  [ack_dly={ack_dly}] cycles/word={cpw:.3f} words_ok={words_ok} "
            f"no_fault={no_fault} mismatches={len(mism)} overran={overran} "
            f"crc_delta_m={crc_delta['m']} crc_delta_s={crc_delta['s']} "
            f"CLEAN={clean}")
        if mism:
            for seq, idx, want, got in mism[:5]:
                tb.log.error(f"    ack_dly={ack_dly} pkt seq={seq} "
                            f"word[{idx}]: expected 0x{want:08x} got 0x{got:08x}")

        rows.append({
            "ack_dly": ack_dly, "cpw": cpw, "clean": clean,
            "words_ok": words_ok, "no_fault": no_fault,
            "n_mismatches": len(mism), "overran": overran,
            "crc_delta_m": crc_delta["m"], "crc_delta_s": crc_delta["s"],
        })

    # Restore the default before this test hands off.
    for side in ("m", "s"):
        await set_ack_dly_count(tb, side, ACK_DLY_COUNT_DEFAULT)

    tb.log.info("  ===== ack_dly_count sweep: cycles/word vs. correctness =====")
    baseline_cpw = next(r["cpw"] for r in rows if r["ack_dly"] == ACK_DLY_COUNT_DEFAULT)
    for r in rows:
        pct = (baseline_cpw - r["cpw"]) / baseline_cpw * 100 if baseline_cpw else 0.0
        tb.log.info(
            f"    ack_dly_count={r['ack_dly']:2d}  cycles/word={r['cpw']:7.3f}  "
            f"vs default={pct:+6.2f}%  CLEAN={r['clean']}  "
            f"mismatches={r['n_mismatches']}  overran={r['overran']}  "
            f"crc_delta=({r['crc_delta_m']},{r['crc_delta_s']})")

    # The sweep itself is exploratory (finding the floor is the point) -- the
    # only hard assertion here is that the DEFAULT (baseline, unchanged
    # behaviour) config is clean, so this test can never mask a harness bug
    # that would make every row look "clean" vacuously.
    default_row = next(r for r in rows if r["ack_dly"] == ACK_DLY_COUNT_DEFAULT)
    assert default_row["clean"], (
        f"baseline ack_dly_count={ACK_DLY_COUNT_DEFAULT} row was NOT clean "
        f"({default_row}) -- something is wrong with the harness itself, "
        f"not the sweep")

    first_dirty = next((r["ack_dly"] for r in rows if not r["clean"]
                        and r["ack_dly"] < ACK_DLY_COUNT_DEFAULT), None)
    if first_dirty is not None:
        tb.log.warning(f"[ack_dly sweep] first UNCLEAN value below default: "
                       f"ack_dly_count={first_dirty}")
    else:
        tb.log.info("[ack_dly sweep] ALL swept values 0..7 stayed CLEAN "
                    "(byte-exact, in-order, no overrun, no new CRC errors).")

    # ---- RESULT (2026-07-31 run, silicon ratio REF=40.0) -------------------
    #   ack_dly_count=7 (default) : 95.704 cycles/word  (baseline)
    #   ack_dly_count=6           : 95.696 cycles/word  (+0.01%  -- noise)
    #   ack_dly_count=5           : 94.518 cycles/word  (+1.24%)
    #   ack_dly_count=4           : 89.526 cycles/word  (+6.46%)
    #   ack_dly_count=3           : 89.299 cycles/word  (+6.69%)
    #   ack_dly_count=2           : 89.297 cycles/word  (+6.69%  -- flat)
    #   ack_dly_count=1           : 89.298 cycles/word  (+6.69%  -- flat)
    #   ack_dly_count=0           : 89.260 cycles/word  (+6.73%  -- flat)
    # Every value 0..7 CLEAN: byte-exact, in-order, no overrun, zero new CRC
    # errors -- including the extreme ack_dly_count=0 (ACKs on every
    # opportunity, no throttling at all).
    #
    # THE SHAPE IS THE FINDING: throughput improves monotonically down to
    # ~ack_dly_count=3-4, then HARD-PLATEAUS at ~89.3 cycles/word all the way
    # to 0 (the four lowest values differ by <0.05%, well inside sim noise).
    # ack_dly_count was a REAL, measurable contributor (-6.4 cycles/word,
    # ~6.7%) but only up to that point -- below it, something else is the
    # limiter. TXGEN's own ahb_stall_cycles counter (state==2 with
    # fc_hreadyout==0, i.e. the fc_adapter/link backpressuring TXGEN's AHB
    # port) tracks ~93-99% of elapsed cycles at EVERY config, while
    # credit_stall_cycles stays ~0 throughout (credit was pre-seeded for the
    # whole run by arm_and_run_txgen, isolating exactly this axis). That is
    # consistent with the SEPARATE, unswept floor named in the module
    # docstring: the two WavMultibitSync CDC crossings (FC.scala:241,773)
    # sitting downstream of ack_dly_count in the "ACK received -> replay slot
    # freed" path have their OWN fixed round-trip latency that ack_dly_count
    # cannot buy below. The clean plateau across ack_dly_count=3..0 (four
    # values, all agreeing to <0.05%) is what a CDC-latency floor looks like:
    # once the SW-throttle knob stops being the binding constraint, further
    # reductions do nothing because the constraint has moved to fixed
    # hardware.
    #
    # RECOMMENDATION: ack_dly_count=4 is picked as the practical floor for
    # the regression tests below -- it already captures 6.46 of the 6.73
    # available points (96% of the total achievable gain) while sitting one
    # step above the point of diminishing returns, i.e. WITH margin rather
    # than at the observed edge. Going lower (down to the tested extreme, 0)
    # bought NO further throughput in this measurement and is not needed to
    # realize the gain -- see test_ack_dly_floor_extreme_zero_spot_check
    # below for why 0 is still explicitly regression-tested anyway (cheap,
    # and it is the strongest single data point for "this mechanism has no
    # hidden correctness cliff").


# ---------------------------------------------------------------------------
# Floor-value regression checks
# ---------------------------------------------------------------------------
# test_v2_txgen.py (this directory) is the existing pair-level TXGEN
# correctness suite (test_txgen_delivers_byte_exact / test_txgen_never_
# overruns) but it has no hook to run "at a given ack_dly_count" and per this
# project's repo convention it is not to be edited to add one -- see module
# docstring. The two tests below reproduce its EXACT check patterns (same
# helpers, same assertions) but with ack_dly_count set to the chosen floor
# BEFORE the traffic runs, so they are the closest honest equivalent of
# "re-running the existing correctness suite at the floor value" without
# touching that file. (test_v2_fc_contiguous.py, the other suite named in
# the task, is NOT re-run here: every test in it is unconditionally
# `skip=True` in this environment -- SKIP_NO_INJECTOR, the tb_top a2l
# injector hook it needs was never committed -- so it would contribute
# nothing but 4 skips regardless of ack_dly_count.)

ACK_DLY_COUNT_FLOOR = 4   # see RECOMMENDATION above


@cocotb.test()
async def test_ack_dly_floor_delivers_byte_exact(dut):
    """Mirrors test_v2_txgen.py::test_txgen_delivers_byte_exact, at
    ack_dly_count=ACK_DLY_COUNT_FLOOR on both dies instead of the RTL
    default: a single armed packet still lands byte-exact in the peer's RX
    FIFO."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    for side in ("m", "s"):
        await set_ack_dly_count(tb, side, ACK_DLY_COUNT_FLOOR)

    m = tb.apb("m")
    n = 4                       # 4 payload + 2 header = 6 words/packet
    per_packet = n + 2

    await m.write(APB_RELEASED_ACC, per_packet * 8)
    await m.write(TXGEN_PKT, n)
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_BUDGET, per_packet)   # exactly ONE packet
    await m.write(TXGEN_CTRL, CTRL_EN)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_START)

    await ClockCycles(dut.hclk, 4000)

    words_sent = await m.read(TXGEN_WORDS)
    assert words_sent == per_packet, (
        f"[ack_dly={ACK_DLY_COUNT_FLOOR}] generator emitted {words_sent} "
        f"words, expected exactly {per_packet}")

    got = [await tb.ahb_fifo_read_word("s", i * 4) for i in range(per_packet)]
    exp_hdr = expected_header(n)
    assert got[0] == exp_hdr, (
        f"[ack_dly={ACK_DLY_COUNT_FLOOR}] header mismatch: got 0x{got[0]:08x}, "
        f"expected 0x{exp_hdr:08x}")
    for b in range(2, per_packet):
        want = expected_payload(0, b)
        assert got[b] == want, (
            f"[ack_dly={ACK_DLY_COUNT_FLOOR}] payload beat {b}: got "
            f"0x{got[b]:08x}, expected 0x{want:08x} -- data corrupted in "
            f"transit at the lowered ack_dly_count")
    tb.log.info(f"[ack_dly={ACK_DLY_COUNT_FLOOR}] delivered byte-exact: "
                f"{[hex(w) for w in got]}")


@cocotb.test()
async def test_ack_dly_floor_never_overruns(dut):
    """Mirrors test_v2_txgen.py::test_txgen_never_overruns, at
    ack_dly_count=ACK_DLY_COUNT_FLOOR: a FOREVER run against a bounded,
    undrained peer with a small seeded budget still never overruns the
    peer's RX FIFO -- the hardware credit gate (a DIFFERENT mechanism from
    ack_dly_count/the a2l replay window) still holds even with ACKs going
    out much faster."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    for side in ("m", "s"):
        await set_ack_dly_count(tb, side, ACK_DLY_COUNT_FLOOR)

    m = tb.apb("m")
    s = tb.apb("s")
    n = 4
    per_packet = n + 2
    budget_packets = 3
    await m.write(APB_RELEASED_ACC, per_packet * budget_packets)

    await m.write(TXGEN_PKT, n)
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_FOREVER)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_FOREVER | CTRL_START)

    await ClockCycles(dut.hclk, 8000)

    st_slave = await s.read(APB_STATUS)
    assert (st_slave & ST_OVERRUN) == 0, (
        f"[ack_dly={ACK_DLY_COUNT_FLOOR}] peer RX FIFO OVERRAN "
        f"(STATUS=0x{st_slave:08x}) -- the credit gate did not hold the "
        f"generator back at the lowered ack_dly_count; data was silently "
        f"dropped")
    gen_st = await m.read(TXGEN_STATUS)
    assert gen_st & ST_STALL_CREDIT, (
        f"[ack_dly={ACK_DLY_COUNT_FLOOR}] generator not in STALL_CREDIT "
        f"(STATUS=0x{gen_st:08x}) after exhausting a {budget_packets}-packet "
        f"budget -- it is not gating on credit")
    words = await m.read(TXGEN_WORDS)
    assert words <= per_packet * budget_packets, (
        f"[ack_dly={ACK_DLY_COUNT_FLOOR}] generator sent {words} words but "
        f"only {per_packet * budget_packets} credits were seeded")
    tb.log.info(f"[ack_dly={ACK_DLY_COUNT_FLOOR}] gated cleanly: sent "
                f"{words} words, peer no overrun")


@cocotb.test()
async def test_ack_dly_floor_extreme_zero_spot_check(dut):
    """The strongest single correctness data point: byte-exact delivery of a
    SUSTAINED multi-packet run at the tested extreme ack_dly_count=0 (ACKs
    fire on every opportunity, zero throttling -- the setting the sweep
    showed buys no further throughput but is the natural place to look for a
    hidden correctness cliff if one existed). A smaller run than the main
    sweep (8 packets, not 20) since this is a spot check, not the headline
    measurement."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    for side in ("m", "s"):
        await set_ack_dly_count(tb, side, 0)

    await tb.apb("m").write(PERF_CTRL, PERF_EN)

    PKT_LEN = 64
    NPKT = 8
    r = await arm_and_run_txgen(tb, "m", PKT_LEN, NPKT)
    cpw = _log_result(tb, "ack_dly=0 spot-check", r)

    assert r["words"] == r["total_words"], (
        f"ack_dly=0: TXGEN_WORDS={r['words']} != requested {r['total_words']}")
    assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
        f"ack_dly=0: sticky fault STATUS=0x{r['status']:02x}")

    await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
    mism = await verify_drain(tb, "s", NPKT, r["per_packet"], PKT_LEN,
                               pkt_index_start=0)
    assert not mism, (
        f"ack_dly=0: {len(mism)} mismatches (first: {mism[0]}) at the "
        f"tested extreme -- NOT byte-exact/in-order with zero ACK "
        f"throttling")

    s_status = await tb.apb("s").read(APB_STATUS)
    assert not (s_status & ST_OVERRUN), (
        f"ack_dly=0: peer overran, STATUS=0x{s_status:08x}")

    tb.log.info(f"[ack_dly=0 spot-check] {cpw:.3f} cycles/word, {NPKT} "
                f"packets byte-exact + in-order at the tested extreme -- "
                f"NO hidden correctness cliff at ack_dly_count=0.")

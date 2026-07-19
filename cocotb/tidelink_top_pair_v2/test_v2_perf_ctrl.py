"""V2 PERF_CTRL end-to-end proof (Wave-0 fix #9).

Proves the PERF_CTRL off-by-one fix (src/rtl/fifo/tidelink_apb_regs.sv:540,
`perf_reg_region = apb_region - 5` replacing `apb_region[1:0]`) END-TO-END
through the real APB -> tidelink_apb_regs -> tidelink_perf path in a fully
brought-up V2 pair, NOT via a unit tb that drives perf_reg_region directly
(the cocotb/tidelink_perf tb does exactly that and is therefore BLIND to this
bug — it was load-bearing false confidence).

Perf register map inside the tidelink APB block (base 0x2000; apb_region =
paddr[8:5], word = paddr[4:2]):
    PERF_CTRL        region 5 word 0  -> 0x20A0  (enable bit0 / freeze bit1)
    TX_WORD_COUNT    region 6 word 4  -> 0x20D0
    TX_STALL_COUNT   region 6 word 6  -> 0x20D8
    SAMPLE_COUNT     region 7 word 2  -> 0x20E8

Before the fix, apb_region {5,6,7} -> perf_reg_region {01,10,11}, so:
  * a write to region 5 (PERF_CTRL) produced perf_reg_region=01, NEVER the
    2'b00 the perf PERF_CTRL decode requires -> perf_enable_r stayed 0 ->
    NO counter ever counted; and
  * a read of region 7 produced perf_reg_region=11 -> read-mux default -> 0.
So sample_count read back 0 for BOTH reasons. After the fix region 5->00,
6->01, 7->10, PERF_CTRL is writable, perf_enable_r sets, and sample_count
(a free-running perf_active cycle counter, tidelink_perf.sv:268-270) counts.

Oracle (the thing Wave 2/3 depend on): the counter must ACTUALLY COUNT, not
merely be writable.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, send_and_check

PERF_CTRL      = 0x20A0   # region 5 word 0
PERF_TX_WORDS  = 0x20D0   # region 6 word 4  (tx_word_count_r)
PERF_TX_STALL  = 0x20D8   # region 6 word 6  (tx_stall_count_r)
PERF_SAMPLES   = 0x20E8   # region 7 word 2  (sample_count_r, free-running)

PERF_EN = 0x1             # PERF_CTRL[0] = perf_enable


@cocotb.test()
async def test_perf_ctrl_counts(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")

    # --- 1. Baseline: perf disabled at POR ----------------------------------
    ctrl0 = await m.read(PERF_CTRL)
    samp0 = await m.read(PERF_SAMPLES)
    tb.log.info(f"[perf] POR: PERF_CTRL=0x{ctrl0:08x} SAMPLE_COUNT=0x{samp0:08x}")
    assert (ctrl0 & PERF_EN) == 0, \
        f"perf unexpectedly enabled at POR (PERF_CTRL=0x{ctrl0:08x})"
    assert samp0 == 0, \
        f"SAMPLE_COUNT nonzero before enable (0x{samp0:08x}) — counter free-ran uncontrolled"

    # --- 2. Enable perf via PERF_CTRL, prove the WRITE LANDED ----------------
    # RED before the fix: region-5 write emits perf_reg_region=01, never 00, so
    # perf_enable_r never sets and this read-back stays 0.
    await m.write(PERF_CTRL, PERF_EN)
    await ClockCycles(dut.hclk, 5)
    ctrl1 = await m.read(PERF_CTRL)
    tb.log.info(f"[perf] after enable: PERF_CTRL=0x{ctrl1:08x}")
    assert (ctrl1 & PERF_EN) == PERF_EN, (
        f"PERF_CTRL enable did not stick (read 0x{ctrl1:08x}) — PERF_CTRL is "
        f"UNWRITABLE (the region off-by-one is present)")

    # --- 3. Prove the counter ACTUALLY COUNTS -------------------------------
    # sample_count_r free-runs every hclk while perf_active. Two reads spaced
    # by a fixed dwell must strictly increase.
    samp_a = await m.read(PERF_SAMPLES)
    await ClockCycles(dut.hclk, 300)
    samp_b = await m.read(PERF_SAMPLES)
    tb.log.info(f"[perf] SAMPLE_COUNT after enable: a=0x{samp_a:08x} b=0x{samp_b:08x} "
                f"(+{samp_b - samp_a} over 300 hclk)")
    assert samp_b > samp_a > 0, (
        f"SAMPLE_COUNT did not advance (a=0x{samp_a:08x} b=0x{samp_b:08x}) — "
        f"perf never enabled / counters dead")

    # --- 4. Corroborate under real traffic: TX_WORD_COUNT counts ------------
    txw0 = await m.read(PERF_TX_WORDS)
    await send_and_check(tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="perf-m2s")
    await ClockCycles(dut.hclk, 200)
    txw1 = await m.read(PERF_TX_WORDS)
    tb.log.info(f"[perf] TX_WORD_COUNT: before=0x{txw0:08x} after=0x{txw1:08x} "
                f"(+{txw1 - txw0} words)")
    assert txw1 > txw0, (
        f"TX_WORD_COUNT did not advance across a real packet "
        f"(before=0x{txw0:08x} after=0x{txw1:08x}) — perf blind to TX traffic")

    tb.log.info("[perf] PASS: PERF_CTRL writable + counters count end-to-end")

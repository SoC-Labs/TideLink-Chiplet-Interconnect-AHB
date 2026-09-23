"""TL-052 (B19): a late LL bootstrap must not kill the AXI data channels.

KR260, 2026-09-23: compute (master) ran the LL bootstrap -- 0x208 <- 0x27F08,
0x27F00, 0x27F07 -- after the pair had exchanged CR/CRACK. The HARDEN_SWI_ENABLE
shim forced swi_enable high only on the swreset write, so the middle write
cleared swi_enable. That dip zeroes fe_tx/fe_rx_credit_max in the five AXI
data-channel FCSMs (WlinkGenericFCSM{,_1.._4}); the peer never re-handshakes.
Symptom: w0 lands, w1-w7 return OKAY fabricated by the 2^16 wrapper backstop,
w8+ ERROR, FCSM_6 still reads 4. Confirmed on the boards by removing the
bootstrap. The fix forces swi_enable on EVERY 0x208 write.

Each test: lockstep bring-up (the bench default), optionally repeat the
bootstrap on ONE die, then 16 spaced non-bufferable SINGLE writes master ->
slave through a protocol-correct AHB master. PASS requires the re-bootstrapped
die's five data-channel credit maxima to be intact AND every write to land
with a real B (well under the backstop). Pre-fix the late cases fail at the
credit check (all five channels read 0/0 on the re-bootstrapped die); post-fix
all three PASS. Without the credit assertion the writes still fail: in this
bench w0-w7 return an OKAY fabricated by the backstop (65539 cycles) with
nothing landed, w8 onwards ERROR.
"""
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

import test_v2_burst_encodings as be
import test_v2_ahb_compliant as ac

N_WRITES = 16
GAP = 3000
TIMEOUT = 300_000
REAL_B_MAX = 5_000            # a real B round trip is ~250 hclk; the backstop is 2^16
LL_SEQ = (0x00027F08, 0x00027F00, 0x00027F07)
APB_WL_LINK_ENABLE_RESET = 0x0208
CHANNELS = (("AW", "wlink_axiawFC"), ("W", "wlink_axiwFC"), ("B", "wlink_axibFC"),
            ("AR", "wlink_axiarFC"), ("R", "wlink_axirFC"))
_TAG = {"n": 0}


def credmax(tb, side):
    out = {}
    for ch, inst in CHANNELS:
        n = getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)
        out[ch] = (int(n.fe_tx_credit_max.value), int(n.fe_rx_credit_max.value))
    return out


async def one_write(dut, addr, data):
    t = dict(addr=addr, data=data, htrans=ac.NONSEQ, hburst=be.BUR_SINGLE, hprot=0x1)
    resp = {"err": 0}
    done = {"v": False}

    async def watch():
        while not done["v"]:
            await ReadOnly()
            try:
                if int(dut.m_ahb_sub_hresp.value):
                    resp["err"] = 1
            except ValueError:
                pass
            await RisingEdge(dut.hclk)
    w = cocotb.start_soon(watch())
    res = await ac.CompliantAHBMaster(dut).run([t], timeout=TIMEOUT)
    done["v"] = True
    await RisingEdge(dut.hclk)
    w.kill()
    return res, resp["err"]


async def writes_land(dut, tb, label):
    base_off = 0x800                  # tb_ahb_bram_slave AW=12 (4 KB); keep inside it
    _TAG["n"] += 1
    tag = _TAG["n"] & 0xFF
    for i in range(N_WRITES):         # the BRAM persists across tests: clear, then tag
        dut.u_s_mng_bram.mem[(base_off >> 2) + i].value = 0
    await ClockCycles(dut.hclk, 2)
    assert all(be._bram_peek(dut, base_off + 4 * i) == 0 for i in range(N_WRITES))
    first_bad = None
    for i in range(N_WRITES):
        v = 0xA5000000 | (tag << 16) | (i << 8) | ((0x77 - i) & 0xFF)
        res, err = await one_write(dut, be.APERTURE_BASE + base_off + 4 * i, v)
        await ClockCycles(dut.hclk, GAP)
        landed = be._bram_peek(dut, base_off + 4 * i)
        good = res["completed"] and not err and landed == v and res["cycles"] < REAL_B_MAX
        tb.log.info(f"[{label}] w{i:<2} cycles={res['cycles']:<7} hresp={'ERROR' if err else 'OKAY '} "
                    f"landed={'0x%08x' % landed if landed is not None else None} want=0x{v:08x} "
                    f"{'OK' if good else 'BAD'}")
        if not good and first_bad is None:
            first_bad = i
    return first_bad


async def scenario(dut, late_side):
    tb, _ = await be._bringup(dut)
    if late_side:
        before = credmax(tb, late_side)
        apb = tb.apb(late_side)
        for val in LL_SEQ:
            await apb.write(APB_WL_LINK_ENABLE_RESET, val)
            await ClockCycles(dut.hclk, 2000)
        await ClockCycles(dut.hclk, 10000)
        after = credmax(tb, late_side)
        tb.log.info(f"[late-{late_side}] credit max before={before} after={after}")
        lost = [ch for ch in after if after[ch] != before[ch]]
        assert not lost, (f"late LL bootstrap on die {late_side} changed the credit maxima of "
                          f"{lost}: {after} (was {before}) -- the swi_enable dip is back")
    first_bad = await writes_land(dut, tb, f"late-{late_side or 'none'}")
    assert first_bad is None, f"write w{first_bad} did not land with a real B"


@cocotb.test()
async def control_lockstep(dut):
    await scenario(dut, None)


@cocotb.test()
async def late_master_bootstrap(dut):
    await scenario(dut, "m")


@cocotb.test()
async def late_slave_bootstrap(dut):
    await scenario(dut, "s")

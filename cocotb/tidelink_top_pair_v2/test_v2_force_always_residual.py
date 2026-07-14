"""RESIDUAL s->m corruption — the 0044bef guard does NOT cover force_always.

Coordinator 2026-07-14 silicon: the guard-in bitstream leaves B->A (slave->
master) hard-dead 0/9 under R8=0x14 both dies, while A->B recovered to ~67%.
A direction-asymmetric residual.

V1-vs-V2 audit root cause (axi_chiplet_controller.sv:5924-5939): V2 drives the
Wlink SYNC-insert force ports as
    swi_sync_insert_en_in   = swi_sync_insert_en_r  | winscan_force_sync | ws_serve_active_r
    swi_sync_force_always_in= swi_sync_force_always_r| winscan_force_sync | ws_serve_active_r
    swi_sync_robust_detect_in=swi_sync_robust_detect_r|winscan_force_sync | ws_serve_active_r
The 0044bef drain guard is applied ONLY to the idle-gated path
(io_link_tx_tx_idle & postcount==0); force_always deliberately BYPASSES it
(WavD2DGpio_v2.v:625-628). V1 (WavD2DGpio.v:625) has NO force_always path — its
postcount guard is UNCONDITIONAL.

`ws_serve_active_r` (axi_chiplet_controller.sv:1393, 4249) is SLAVE-ONLY
(~role_is_master) and, per its own comment, forces SYNC every grid slot
"WITHOUT quiescing its FC (its RX stays live)". So the SLAVE transmits s->m FC
data AND unguarded force_always beacons simultaneously => the beacons overwrite
s->m payload => the direction-asymmetric silicon death, which the 0044bef guard
CANNOT cover.

This test reproduces that class in sim WITH THE GUARD IN: enable force_always on
the SLAVE (R8 bit[3], the same port ws_serve_active_r ORs into) during s->m
traffic. Expected: s->m corrupts even though 0044bef is present -> the guard is
necessary but NOT sufficient; force_always (ws_serve/winscan_force_sync) needs
its own drain guard or an FC quiesce.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_force_always_residual
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_R8_SLOT0,
)

R8_SYNC_EN        = 0x4    # insert_en
R8_FORCE_ALWAYS   = 0x8    # force_always (the port ws_serve_active_r ORs into)
R8_ROBUST         = 0x10


async def drain_rx(tb, dst, n):
    return [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(n)]


@cocotb.test()
async def test_force_always_residual_s2m(dut):
    """GUARD IN + force_always on the SLAVE -> s->m corrupts (the residual the
    drain guard does not cover). This is NOT a revert; the 0044bef guard is
    present. It proves the guard is necessary-but-insufficient."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"

    # SLAVE = the s->m transmitter. Enable insert+robust+FORCE_ALWAYS (R8=0x1C).
    # force_always models exactly what ws_serve_active_r / winscan_force_sync OR
    # into the force ports during the slave serve window — beacons every 32 words
    # regardless of idle/postcount, WHILE FC is live.
    await tb.s_apb.write(APB_R8_SLOT0, R8_SYNC_EN | R8_FORCE_ALWAYS | R8_ROBUST)
    rb = await tb.s_apb.read(APB_R8_SLOT0)
    assert (rb >> 3) & 1 == 1, f"force_always not set (R8=0x{rb:x})"
    tb.log.info(f"SLAVE R8_SLOT0=0x{rb:08x} insert_en={(rb>>2)&1} "
                f"force_always={(rb>>3)&1} robust={(rb>>4)&1} (models ws_serve)")

    NPKT = 24
    ok = 0
    mism = []
    for k in range(NPKT):
        p = [0xB0BA0000 | (k << 4), 0x5A5A0000 | k]
        w = make_packet(p)
        await tb.ahb_tx_write_packet("s", w, gap=2)
        await ClockCycles(dut.hclk, 300 + k)
        got = await drain_rx(tb, "m", 4)
        good = (got[0] == w[0] and got[2] == p[0] and got[3] == p[1])
        if good:
            ok += 1
        else:
            mism.append((k, [f"0x{x:08x}" for x in w], [f"0x{x:08x}" for x in got]))

    tb.log.info(f"s2m under force_always (guard IN): {ok}/{NPKT} byte-exact, "
                f"{len(mism)} corrupt")
    for idx, exp, got in mism[:8]:
        tb.log.info(f"  MISMATCH s2m pkt {idx}: sent={exp} got={got}")

    # The residual assertion: force_always corrupts s->m EVEN WITH the guard in.
    # (If this ever passes clean, the force_always word-deletion is not
    #  reproducible in this TB — report that; it does NOT mean the residual is
    #  gone on silicon.)
    assert mism, (
        f"force_always on the slave did NOT corrupt s->m in this TB ({ok}/{NPKT} "
        f"clean) — the residual word-deletion was not exercised here")
    tb.log.info(
        f"RESIDUAL REPRODUCED: with the 0044bef guard PRESENT, force_always on "
        f"the slave still corrupts s->m ({len(mism)}/{NPKT}). The guard covers "
        f"only the idle-gated path; the force_always OR terms (ws_serve_active_r "
        f"SLAVE-only, winscan_force_sync) bypass it — the direction-asymmetric "
        f"silicon s->m death. FIX: drain-guard the force_always path too, or "
        f"quiesce FC during the slave serve window.")

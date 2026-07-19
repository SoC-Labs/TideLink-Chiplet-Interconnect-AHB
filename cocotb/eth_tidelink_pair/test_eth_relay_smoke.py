"""Ethernet-over-TideLink M0 smoke — frame-relay datapath skeleton.

Proves the M0 milestone of docs/ETHERNET_CHIPLET_INTEGRATION.md: an AHB write
entering die_a's TideLink peer aperture crosses the link and lands BYTE-EXACT in
an ethernet-subsystem memory attached behind die_b's ahb_mng port.

    die_a peer window (ahb_sub) WRITE @ 0x4000_0000 + off
      -> XHB500 AHB->AXI -> master chiplet controller s_axi (Wlink AXI target)
      -> FC aw/w/b channels -> chiplet link -> die_b
      -> die_b XHB500 AXI->AHB -> die_b ahb_mng
      -> nanosoc_region_sram (eth scratch, u_s_eth_scratch) -> sl_ahb_sram
    READ-back @ the SAME addresses returns the stored frame byte-exact, and a
    hierarchical peek confirms it physically landed in the eth-scratch BRAMs.

This is Shape B (scaffold §3): the ethernet-subsystem *memory* alone behind
ahb_mng, no full multicore SoC — a real component from the ethernet repos
receiving link-crossed AHB writes, which is exactly the M0 point.

Run:
    cd cocotb/eth_tidelink_pair
    source ../../set_env.sh ; export TIDELINK_PHY_V2=1
    make MODULE=test_eth_relay_smoke
"""
import cocotb
from cocotb.triggers import ClockCycles

from eth_pair_common import (PairV2TB, run_bringup_full, AHBSubMaster,
                             make_eth_frame, eth_scratch_peek,
                             PEER_APERTURE_BASE, ETH_SCRATCH_RX_OFF)

# Cycles to let the last posted write settle in the far eth-scratch before the
# read-back chases it (the transparent window is longer-latency than the local
# FIFO path; matches the proven pair_v2 xhb-window margin).
WRITE_SETTLE = 8000
NWORDS = 16          # 64 B = minimum ethernet frame


@cocotb.test()
async def test_eth_relay_smoke(dut):
    """die_a peer-window frame -> die_b ethernet-scratch RAM, byte-exact."""
    tb = PairV2TB(dut)
    m_ahb = AHBSubMaster(dut)          # idles m_ahb_sub before bring-up

    # --- 1. Bring the V2 pair link up (POR -> role_lock -> autocal -> data
    #        mode), then wait for the bilateral CR/CRACK so the FC channels
    #        carry AHB traffic across the ribbon. -----------------------------
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("[eth-relay] link up (cal+CR/CRACK); starting frame relay")

    frame = make_eth_frame(NWORDS)

    # --- 2. die_a stages the frame across its peer window into die_b's
    #        eth-scratch RX range. Each AHBSubMaster.write() blocks until the
    #        cross-link write response returns, so the burst is ordered. ------
    for i, w in enumerate(frame):
        addr = PEER_APERTURE_BASE + ETH_SCRATCH_RX_OFF + i * 4
        await m_ahb.write(addr, w)
    tb.log.info(f"[eth-relay] wrote {NWORDS}-word frame to peer window "
                f"0x{PEER_APERTURE_BASE + ETH_SCRATCH_RX_OFF:08x}+")
    await ClockCycles(dut.hclk, WRITE_SETTLE)

    # --- 3. Read the frame back out of die_b's eth-scratch: (a) round-trip via
    #        the peer window (proves the full bidirectional path), and (b) a
    #        hierarchical peek straight into the eth-scratch BRAMs (proves it
    #        physically landed in the REAL ethernet component). ---------------
    fails = []
    for i, w in enumerate(frame):
        off  = ETH_SCRATCH_RX_OFF + i * 4
        addr = PEER_APERTURE_BASE + off
        got  = await m_ahb.read(addr)
        peek = eth_scratch_peek(dut, off, side="s")
        peek_s = "n/a" if peek is None else f"0x{peek:08x}"
        tb.log.info(f"  [eth-relay] w{i:2d} addr=0x{addr:08x} sent=0x{w:08x} "
                    f"read=0x{got:08x} eth_scratch[{off >> 2}]={peek_s}")
        if got != w:
            fails.append((i, addr, w, got, peek))
        elif peek is not None and peek != w:
            fails.append((i, addr, w, got, peek))

    assert not fails, (
        "Ethernet frame relay MISMATCH (peer-window read-back / eth-scratch "
        "peek):\n" + "\n".join(
            f"  w{i} addr=0x{a:08x} sent=0x{s:08x} read=0x{g:08x} "
            f"eth_scratch={'n/a' if p is None else f'0x{p:08x}'}"
            for i, a, s, g, p in fails))

    tb.log.info(f"[eth-relay] PASS: {NWORDS}/{NWORDS}-word frame relayed "
                f"die_a peer window -> link -> die_b ethernet-scratch RAM, "
                f"byte-exact (round-trip + hierarchical peek).")

# =============================================================================
# Held-NONSEQ (Xilinx axi_ahblite_bridge) duplication repro for
# tidelink_fc_adapter.sv — the SILICON x5 TX packet-multiplication bug
# (2026-07-03).
#
# CONFIRMED SILICON FINDING under test: the Xilinx axi_ahblite_bridge:3.0
# master holds HTRANS=NONSEQ with HADDR/HWDATA stable for the duration of its
# internal AXI transaction (~10 hclk at the GP1->SMC->bridge path), while the
# vivado wrapper loops the adapter's HREADYOUT straight back as HREADY (always
# 1 when the skid drains). The adapter's address-phase detect
#     tx_valid_addr_phase = hsel & htrans[1] & hready & hwrite
# is a pure level, so it re-latches an address phase every time a data phase
# completes while NONSEQ is still held -> one FC word every 2 hclk for the
# whole hold -> EXACTLY +5 a2l FIFO writes per single PS store (measured on
# silicon: wptr +5/+5/+5 for three single writes, 4-word burst -> +20).
# Downstream harm: pktnum == replay rptr walks 5x -> fe credit ceiling 0x1f
# exhausted after ~6 logical words -> exp saturates 0x20 -> NACK/replay wedge.
#
# THE CONTRACT ASSERTED HERE: one held-NONSEQ write transaction (however long
# the master holds it) must produce EXACTLY ONE FC word. Spec-compliant
# single-cycle NONSEQ masters and back-to-back bursts with moving HADDR must
# be unaffected; a fresh transaction to the SAME address after an IDLE gap
# must still be accepted.
#
# UNFIXED RTL: test_bridge_held_nonseq_single fails with ~5 identical words.
# =============================================================================
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly

from test_buga import (PKT_FIFO_DATA, HTRANS_IDLE, HTRANS_NONSEQ, HSIZE_WORD,
                       fc_word, reset, FcMonitor, ahb_single_write)


async def bridge_held_write(dut, addr, data, hold_cycles=11):
    """Model the axi_ahblite_bridge's observed behaviour: HTRANS=NONSEQ with
    HADDR/HWDATA held stable for the whole AXI transaction, HREADY high
    (wrapper loop, skid draining)."""
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 1
    dut.ahb_tx_haddr.value = addr
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hsize.value = HSIZE_WORD
    dut.ahb_tx_hwdata.value = data
    for _ in range(hold_cycles):
        await RisingEdge(dut.hclk)
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hsel.value = 0
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hwrite.value = 0
    # let the final data phase drain
    for _ in range(4):
        await RisingEdge(dut.hclk)
    await FallingEdge(dut.hclk)
    dut.ahb_tx_hwdata.value = 0


@cocotb.test()
async def test_bridge_held_nonseq_single(dut):
    """One held-NONSEQ store (11-cycle hold) must yield EXACTLY ONE FC word."""
    cocotb.start_soon(Clock(dut.hclk, 10, unit="ns").start())
    await reset(dut)
    mon = FcMonitor(dut)
    mon.start()

    await bridge_held_write(dut, 0x0000, 0x77BB0000, hold_cycles=11)
    for _ in range(8):
        await RisingEdge(dut.hclk)

    exp = fc_word(0x0000, 0x77BB0000)
    dut._log.info("VERDICT held-NONSEQ single: fc_words=%d (want 1) words=%s"
                  % (len(mon.words), ["0x%012x" % w for w in mon.words]))
    assert len(mon.words) == 1, \
        "held-NONSEQ store duplicated: %d FC words (silicon x5 bug)" % len(mon.words)
    assert mon.words[0] == exp


@cocotb.test()
async def test_bridge_held_nonseq_burst4(dut):
    """Four held-NONSEQ stores at walking addresses (the tl39 txburst shape)
    must yield exactly 4 FC words, in order."""
    cocotb.start_soon(Clock(dut.hclk, 10, unit="ns").start())
    await reset(dut)
    mon = FcMonitor(dut)
    mon.start()

    vals = [(0x0, 0x77BB0000), (0x4, 0x77BB0001),
            (0x8, 0x77BB0002), (0xC, 0x77BB0003)]
    for a, d in vals:
        await bridge_held_write(dut, a, d, hold_cycles=11)
    for _ in range(8):
        await RisingEdge(dut.hclk)

    dut._log.info("VERDICT held-NONSEQ burst4: fc_words=%d (want 4)" % len(mon.words))
    assert len(mon.words) == 4, \
        "4 held-NONSEQ stores -> %d FC words (silicon: 20)" % len(mon.words)
    for i, (a, d) in enumerate(vals):
        assert mon.words[i] == fc_word(a, d), "word %d mismatch" % i


@cocotb.test()
async def test_same_addr_two_transactions(dut):
    """Two SEPARATE held-NONSEQ transactions to the SAME address (IDLE gap
    between) are two genuine writes -> exactly 2 FC words. Guards the fix
    against over-suppression (repeated doorbell writes are real traffic)."""
    cocotb.start_soon(Clock(dut.hclk, 10, unit="ns").start())
    await reset(dut)
    mon = FcMonitor(dut)
    mon.start()

    await bridge_held_write(dut, 0x4, 0x22222222, hold_cycles=11)
    await bridge_held_write(dut, 0x4, 0x22222222, hold_cycles=11)
    for _ in range(8):
        await RisingEdge(dut.hclk)

    dut._log.info("VERDICT same-addr x2 transactions: fc_words=%d (want 2)" % len(mon.words))
    assert len(mon.words) == 2, \
        "two same-addr transactions -> %d FC words (want 2)" % len(mon.words)


@cocotb.test()
async def test_spec_master_unaffected(dut):
    """Spec-compliant single-cycle NONSEQ writes (the existing test_buga
    master) must still deliver 1 word each after the fix."""
    cocotb.start_soon(Clock(dut.hclk, 10, unit="ns").start())
    await reset(dut)
    mon = FcMonitor(dut)
    mon.start()

    await ahb_single_write(dut, 0x0, 0xAAAA0001)
    await ahb_single_write(dut, 0x4, 0xAAAA0002)
    await ahb_single_write(dut, 0x8, 0xAAAA0003)
    for _ in range(8):
        await RisingEdge(dut.hclk)

    dut._log.info("VERDICT spec master x3: fc_words=%d (want 3)" % len(mon.words))
    assert len(mon.words) == 3
    assert mon.words[0] == fc_word(0x0, 0xAAAA0001)
    assert mon.words[1] == fc_word(0x4, 0xAAAA0002)
    assert mon.words[2] == fc_word(0x8, 0xAAAA0003)

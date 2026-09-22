"""TideChart TX beat ACK-and-drop in tidelink_fc_adapter (rev-2, 2026-09-22).

DEFECT. `tc_axis_tx_tready` for a REMOTE TideChart word was
    skid_can_accept & ~sideband_starving
i.e. it did not include the arbiter's decision. In a cycle where the skid can
accept but the arbiter loads a DIFFERENT source -- the TX aperture when
tc_qos_priority == 0, or a returner/servo sideband word at any priority --
the TideChart master sees tvalid && tready, retires the beat, and the word is
never loaded. An election claim is broadcast ONCE, so a single dropped beat
is a silently lost election.

Both chiplet wrappers tie tc_qos_priority to 3'b000, so the TX-aperture
collision is the shipping configuration.

RED/GREEN. The two `drop_*` tests FAIL on the unfixed RTL (word never seen on
tl_fc_a2l) and PASS once tready follows the arbiter's actual selection. The
two `control_*` tests PASS on both, proving the monitor can see delivery and
that the ordinary path still works around the collision (a fix that only
stopped the drop by blocking TideChart forever would fail them).

The AXI-Stream master here is a CORRECT master: it holds tvalid until it
observes tready high at a rising edge, then drops tvalid. A sloppy master
that re-presents the word would mask the defect.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from test_tidelink_fc_adapter import (
    setup, do_reset, tx_aperture_write, rtn_write,
    PKT_EXT, PKT_FIFO_DATA, PKT_SIDEBAND, HTRANS_IDLE, HTRANS_NONSEQ,
)

TC_SUBTYPE = 0x0101            # any non-PUF subtype -> "remote" TideChart word
TC_PAYLOAD = 0xCAFE0001


def tc_word(subtype=TC_SUBTYPE, payload=TC_PAYLOAD):
    return (PKT_EXT << 46) | ((subtype & 0x3FFF) << 32) | (payload & 0xFFFFFFFF)


async def axis_master_one_beat(dut, word, max_cycles=50):
    """Present ONE beat like a compliant AXI-Stream master.

    Returns the number of cycles tvalid was held (1 == accepted first cycle).
    """
    dut.tc_axis_tx_tdata.value = word
    dut.tc_axis_tx_tvalid.value = 1
    held = 0
    for _ in range(max_cycles):
        await FallingEdge(dut.hclk)          # combinational tready settled
        rdy = int(dut.tc_axis_tx_tready.value)
        await RisingEdge(dut.hclk)           # the handshake edge
        held += 1
        if rdy:
            dut.tc_axis_tx_tvalid.value = 0
            dut.tc_axis_tx_tdata.value = 0
            return held
    dut.tc_axis_tx_tvalid.value = 0
    raise TimeoutError("TideChart beat never accepted (tready stuck low)")


async def drain(fc_mon, cycles, dut):
    await ClockCycles(dut.hclk, cycles)
    pkts = []
    while not fc_mon.packets.empty():
        pkts.append(fc_mon.packets.get_nowait())
    return pkts


def count_tc(pkts):
    return sum(1 for p in pkts
               if p["pkt_type"] == PKT_EXT and p["addr_offset"] == TC_SUBTYPE
               and p["payload"] == TC_PAYLOAD)


# ---------------------------------------------------------------------------
# CONTROLS (pass on both RTLs -- prove the instrument)
# ---------------------------------------------------------------------------
@cocotb.test()
async def control_remote_word_delivered_when_idle(dut):
    """No collision: a remote word at qos=0 must reach tl_fc_a2l exactly once."""
    fc_mon, *_ = await setup(dut)
    await do_reset(dut)
    held = await axis_master_one_beat(dut, tc_word())
    pkts = await drain(fc_mon, 20, dut)
    assert count_tc(pkts) == 1, f"expected the TideChart word once, got {count_tc(pkts)} in {pkts}"
    dut._log.info(f"CONTROL: delivered, tvalid held {held} cycle(s)")


@cocotb.test()
async def control_tx_aperture_word_delivered(dut):
    """The ordinary TX-aperture path delivers its word (sanity for the collision test)."""
    fc_mon, *_ = await setup(dut)
    await do_reset(dut)
    await tx_aperture_write(dut, 0x0010, 0x11112222)
    pkts = await drain(fc_mon, 20, dut)
    fifo = [p for p in pkts if p["pkt_type"] == PKT_FIFO_DATA and p["payload"] == 0x11112222]
    assert len(fifo) == 1, f"TX aperture word not delivered exactly once: {pkts}"


# ---------------------------------------------------------------------------
# DROP 1: qos=0, TideChart word presented in the TX aperture's data phase
# ---------------------------------------------------------------------------
@cocotb.test()
async def drop_tx_aperture_collision_qos0(dut):
    """qos=0: TX aperture wins the arbiter; tready must NOT ack the TideChart beat.

    Unfixed RTL: tready=1 that cycle (skid can accept), the skid takes the
    TX word, the TideChart word is retired by the master and lost.
    """
    fc_mon, *_ = await setup(dut)
    await do_reset(dut)
    dut.tc_qos_priority.value = 0

    # AHB address phase for a TX-aperture write
    dut.ahb_tx_hsel.value   = 1
    dut.ahb_tx_haddr.value  = 0x0020
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hready.value = 1
    await RisingEdge(dut.hclk)
    # Data phase: tx_fc_valid (= tx_data_phase_r) is high THIS cycle.
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_hwdata.value = 0x33334444
    # ...and the TideChart word arrives in the same cycle.
    held = await axis_master_one_beat(dut, tc_word())

    pkts = await drain(fc_mon, 30, dut)
    n_tc = count_tc(pkts)
    n_tx = sum(1 for p in pkts if p["pkt_type"] == PKT_FIFO_DATA and p["payload"] == 0x33334444)
    dut._log.info(f"collision qos=0: tvalid held {held} cycle(s); tc={n_tc} tx={n_tx}; pkts={pkts}")
    assert n_tx == 1, f"TX aperture word must still be delivered once (got {n_tx})"
    assert n_tc == 1, (f"TideChart word ACKed (tvalid held {held} cycle(s)) but delivered {n_tc} times "
                       f"-- ACK-AND-DROP")


# ---------------------------------------------------------------------------
# DROP 2: qos>0, TideChart word and a RETURNER sideband word contend for the
# same skid slot the cycle it frees. Returner has fixed priority; tready must
# not ack the TideChart beat in that cycle.
# ---------------------------------------------------------------------------
@cocotb.test()
async def drop_returner_collision_qos1(dut):
    """qos=1: returner outranks TideChart; tready must NOT ack the TideChart beat that cycle."""
    fc_mon, *_ = await setup(dut)
    await do_reset(dut)
    dut.tc_qos_priority.value = 1

    # Fill the one-entry skid with a TX word and hold the a2l sink closed so it
    # cannot drain: skid_can_accept goes low.
    dut.tl_fc_a2l_ready.value = 0
    await tx_aperture_write(dut, 0x0030, 0x55556666)
    await ClockCycles(dut.hclk, 2)

    # Queue a returner sideband word by hand: rtn_pending_r is set at the
    # ADDRESS-phase edge and rtn_hready then stays low until the skid can
    # accept, so the rtn_write() helper (which waits for hready) cannot be
    # used here. The data-phase value is held on rtn_hwdata because the RTL
    # forms the sideband word from the live bus when it finally loads it.
    dut.rtn_haddr.value  = 0x0004
    dut.rtn_htrans.value = HTRANS_NONSEQ
    dut.rtn_hwrite.value = 1
    await RisingEdge(dut.hclk)
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hwrite.value = 0
    dut.rtn_hwdata.value = 0x00000001            # credit return
    await ClockCycles(dut.hclk, 2)
    assert int(dut.rtn_hready.value) == 0, "setup: returner word should be pending behind the full skid"

    # Present the TideChart word: tready is low (skid full) so a correct
    # master holds it. Now open the sink: the cycle the skid frees, both the
    # returner word and the TideChart word are candidates. Returner wins.
    async def opener():
        await ClockCycles(dut.hclk, 3)
        dut.tl_fc_a2l_ready.value = 1
    cocotb.start_soon(opener())
    held = await axis_master_one_beat(dut, tc_word())

    pkts = await drain(fc_mon, 30, dut)
    n_tc  = count_tc(pkts)
    n_rtn = sum(1 for p in pkts if p["pkt_type"] == PKT_SIDEBAND)
    n_tx  = sum(1 for p in pkts if p["pkt_type"] == PKT_FIFO_DATA and p["payload"] == 0x55556666)
    dut._log.info(f"collision qos=1/returner: tvalid held {held}; tc={n_tc} rtn={n_rtn} tx={n_tx}; pkts={pkts}")
    assert n_tx == 1, f"skid-resident TX word must drain once (got {n_tx})"
    assert n_rtn == 1, f"returner word must be delivered once (got {n_rtn})"
    assert n_tc == 1, (f"TideChart word ACKed (tvalid held {held} cycle(s)) but delivered {n_tc} times "
                       f"-- ACK-AND-DROP behind the returner")

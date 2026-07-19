"""PENDING-DECISION #1 — RX-FIFO TWIN 2 red/green proof.

TWIN 2 (tidelink_fifo_ctrl.sv:189/:109): a stray AHB NONSEQ write pair to
offset 0 then offset 4 arms the write-side length latch and completes an AHB
write, advancing the FC-SHARED write_ptr by 2 words and burning 2 credits.
That mis-frames the NEXT genuine FC-direct packet.

There is no supported CPU-write-to-RX path (the RX FIFO is filled by the peer
over the FC direct-write port). ENABLE_AHB_WRITE=0 (ASIC posture) disables the
AHB write side; AHB reads are untouched.

  MODE=red   (ENABLE_AHB_WRITE=1): AHB pair corrupts write_ptr -> 8 bytes,
                                   credit -> MAX-2, and the FC packet mis-frames.
  MODE=green (ENABLE_AHB_WRITE=0): AHB pair is a no-op, write_ptr stays 0,
                                   credit stays MAX, FC packet reads back exact.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE = os.environ.get("TWIN2_MODE", "red")
RAM_ADDR_W = 14
MAX_CREDITS = 1 << (RAM_ADDR_W - 2)   # 4096
NONSEQ = 0b10
IDLE = 0b00

CTRL = "u_dut.u_fifo_ctrl"


def _ctrl(dut):
    return getattr(dut, "u_dut").u_fifo_ctrl


async def reset(dut):
    dut.hsel.value = 0
    dut.htrans.value = IDLE
    dut.hsize.value = 2
    dut.hwrite.value = 0
    dut.haddr.value = 0
    dut.hwdata.value = 0
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0
    dut.fc_wr_addr.value = 0
    dut.fc_wr_wdata.value = 0
    dut.flush.value = 0
    dut.hresetn.value = 0
    for _ in range(4):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    await RisingEdge(dut.hclk)


async def ahb_write(dut, addr, data):
    """One AHB single-beat NONSEQ write (address phase, then data phase)."""
    # Address phase
    dut.hsel.value = 1
    dut.htrans.value = NONSEQ
    dut.hwrite.value = 1
    dut.haddr.value = addr
    await RisingEdge(dut.hclk)
    # Data phase — bus goes idle, data presented
    dut.htrans.value = IDLE
    dut.hsel.value = 0
    dut.hwrite.value = 0
    dut.hwdata.value = data
    await RisingEdge(dut.hclk)
    dut.hwdata.value = 0


async def fc_write(dut, addr, word):
    """One FC direct-write beat (addr+data same cycle)."""
    dut.fc_wr_valid.value = 1
    dut.fc_wr_write.value = 1
    dut.fc_wr_addr.value = addr
    dut.fc_wr_wdata.value = word
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 0
    dut.fc_wr_write.value = 0


def wp(dut):
    return int(_ctrl(dut).write_ptr_r.value)


def cc(dut):
    return int(_ctrl(dut).credit_count_r.value)


async def ahb_read_word(dut, byte_addr):
    """AHB single-beat read; returns the word from hrdata (data phase)."""
    dut.hsel.value = 1
    dut.htrans.value = NONSEQ
    dut.hwrite.value = 0
    dut.haddr.value = byte_addr
    await RisingEdge(dut.hclk)
    dut.htrans.value = IDLE
    dut.hsel.value = 0
    await RisingEdge(dut.hclk)
    return dut.hrdata.value


@cocotb.test()
async def test_twin2_ahb_write_corruption(dut):
    """RED: AHB write pair walks the FC-shared write_ptr. GREEN: it cannot."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    assert wp(dut) == 0, "write_ptr should start at 0"
    assert cc(dut) == MAX_CREDITS, f"credit should start at MAX ({MAX_CREDITS})"

    # ---- The TWIN-2 corruptor: a stray clear/probe AHB write pair ----------
    # W_A: write offset 0 with a zero word  (length field [31:20] == 0)
    await ahb_write(dut, 0, 0x0000_0000)
    # W_B: write offset 4 (== write_target for length 0) -> completes an AHB write
    await ahb_write(dut, 4, 0xDEAD_BEEF)
    for _ in range(4):
        await RisingEdge(dut.hclk)

    wp_after = wp(dut)
    cc_after = cc(dut)
    dut._log.info(f"[{MODE}] after AHB write pair: write_ptr={wp_after} B, "
                  f"credit={cc_after} (MAX={MAX_CREDITS})")

    if MODE == "red":
        assert wp_after == 8, (
            f"RED expected write_ptr walked to 8 bytes (2 words); got {wp_after}. "
            "The TWIN-2 corruption did NOT reproduce — the instrument is broken.")
        assert cc_after == MAX_CREDITS - 2, (
            f"RED expected credit burned to {MAX_CREDITS-2}; got {cc_after}")
        dut._log.info("RED confirmed: stray AHB write pair corrupted write_ptr+credit.")
    else:  # green
        assert wp_after == 0, (
            f"GREEN expected write_ptr UNMOVED (0); got {wp_after}. "
            "ENABLE_AHB_WRITE=0 failed to block the AHB write side.")
        assert cc_after == MAX_CREDITS, (
            f"GREEN expected credit UNBURNED ({MAX_CREDITS}); got {cc_after}")
        dut._log.info("GREEN confirmed: AHB write pair is a no-op on write_ptr/credit.")


@cocotb.test()
async def test_twin2_fc_byte_exact_after_stray_ahb(dut):
    """The point of the decision: after the SAME stray AHB pair, does the next
    genuine FC-direct packet land correctly?

    GREEN: FC packet (len=2) lands at word 0 and reads back byte-exact.
    RED:   write_ptr is pre-walked to word 2, so the FC packet lands at word 2
           and a reader draining from offset 0 gets the WRONG (X/garbage) data
           — i.e. mis-framed.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    # Same stray AHB write pair as above
    await ahb_write(dut, 0, 0x0000_0000)
    await ahb_write(dut, 4, 0xDEAD_BEEF)
    for _ in range(4):
        await RisingEdge(dut.hclk)

    wp_before_fc = wp(dut)
    dut._log.info(f"[{MODE}] write_ptr before FC packet = {wp_before_fc} bytes")

    # Genuine FC-direct packet: length=2 payload words -> 4 words total.
    # word0 length field lives in bits [31:20].
    LEN = 2
    word0 = (LEN << 20) | 0x00055
    word1 = 0x1000_2000            # dest_addr
    pay0 = 0xAAAA_0001
    pay1 = 0xBBBB_0002
    await fc_write(dut, 0x0, word0)
    await fc_write(dut, 0x4, word1)
    await fc_write(dut, 0x8, pay0)
    await fc_write(dut, 0xC, pay1)   # 0xC == write_target for len=2 -> completes
    for _ in range(4):
        await RisingEdge(dut.hclk)

    # Drain from offset 0 (what a real reader does): read word0..word3
    got0 = await ahb_read_word(dut, 0x0)
    dut._log.info(f"[{MODE}] FC packet read-back @offset0 word0 = {got0}")

    if MODE == "green":
        assert wp_before_fc == 0, "GREEN: write_ptr must be 0 before FC packet"
        # word0's length field must survive round-trip byte-exact
        assert got0.is_resolvable, f"GREEN word0 unresolvable: {got0}"
        got0i = int(got0)
        assert (got0i >> 20) & 0xFFF == LEN, (
            f"GREEN FC packet mis-framed: word0=0x{got0i:08X}, "
            f"length field={(got0i>>20)&0xFFF} != {LEN}")
        dut._log.info("GREEN confirmed: FC packet byte-exact at offset 0.")
    else:  # red
        assert wp_before_fc == 8, "RED: write_ptr must be pre-walked to 8 bytes"
        # The FC packet was written at word 2, NOT word 0. A reader draining
        # from offset 0 does NOT see the packet header -> mis-framed. With
        # X-init SRAM the stale word 0 is X (unresolvable) or the AHB garbage,
        # never the FC word0 length field.
        mis = (not got0.is_resolvable) or (((int(got0) >> 20) & 0xFFF) != LEN)
        assert mis, (
            f"RED expected mis-framed read-back at offset 0; got a valid "
            f"header 0x{int(got0):08X}. Corruption did not manifest.")
        dut._log.info("RED confirmed: FC packet mis-framed by pre-walked write_ptr.")


@cocotb.test()
async def test_twin1_held_nonseq_locked(dut):
    """TWIN 1 lock (documented accidental one-shot, :158-159 NONSEQ-only).

    Holding htrans=NONSEQ + hwrite to offset 0 for several cycles must NOT walk
    write_ptr or burn credit (there is no completing write to a distinct
    write_target). Expected PASS in BOTH modes — this pins the accidental
    one-shot so a future refactor cannot silently turn it into a corruptor.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    # Held NONSEQ write to offset 0 for 6 cycles (stuck bus / mis-decode)
    dut.hsel.value = 1
    dut.htrans.value = NONSEQ
    dut.hwrite.value = 1
    dut.haddr.value = 0
    dut.hwdata.value = 0x0000_0000
    for _ in range(6):
        await RisingEdge(dut.hclk)
    dut.hsel.value = 0
    dut.htrans.value = IDLE
    dut.hwrite.value = 0
    for _ in range(4):
        await RisingEdge(dut.hclk)

    assert wp(dut) == 0, (
        f"TWIN-1 regression: held NONSEQ walked write_ptr to {wp(dut)} — the "
        "accidental one-shot became a corruptor.")
    assert cc(dut) == MAX_CREDITS, (
        f"TWIN-1 regression: held NONSEQ burned credit to {cc(dut)}")
    assert int(dut.overrun.value) == 0, "TWIN-1: unexpected overrun on held NONSEQ"
    dut._log.info(f"[{MODE}] TWIN-1 locked: held NONSEQ left write_ptr=0, credit=MAX.")

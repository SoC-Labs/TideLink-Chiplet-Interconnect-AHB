"""RX-FIFO TWIN 2 — chip-killer fix proof (DECISION #1, David 2026-07-19).

TWIN 2: the write-side packet-length latch (tidelink_fifo_ctrl.sv) armed on ANY
AHB NONSEQ write to offset 0. A stray two-word "clear"/probe pair (write
offset 0 with a zero word, then offset 4) therefore self-completed an AHB write,
walking the FC-SHARED write_ptr by two words and burning two credits — which
mis-frames the NEXT genuine FC-direct packet, because
    fc_translated_addr = fc_wr_addr + write_ptr_r.

DECISION: AHB-CPU-write-to-RX **IS a supported path**, so it must NOT be gated
off. The ROBUST fix (2026-07-21) makes intent EXPLICIT rather than guessing at
patterns: a runtime ARM bit (APB CTRL[3], swi_ahb_inject_arm) POR-DISARMED. A
stray probe with a garbage non-zero length is bit-identical to a legal minimal
packet, so no `!= 0` / pattern test can separate them — only the arm can. The
old `!= 0` reject is REMOVED (it also broke a legal length-0 RD_REQ).
ENABLE_AHB_WRITE stays 1'b1; the arm is the runtime gate.

Both halves are asserted here, and BOTH must hold:
  1. test_stray_write_pair_is_noop / test_fc_packet_byte_exact_after_stray_ahb
     — DISARMED (arm=0): the BUG is gone: a stray pair moves neither write_ptr
       nor credit, and the next FC packet lands byte-exact at word 0.
  2. test_legit_ahb_inject_still_works / test_legit_ahb_inject_len0_rd_req
     — ARMED (arm=1): the SUPPORTED path works: a real AHB-injected packet
       (incl. a length-0 RD_REQ) is accepted and reads back byte-exact.
       A fix that breaks either is a FAILED fix.
  3. test_twin1_held_nonseq_locked — TWIN-1 regression lock (ARMED), unchanged.

RED/GREEN: this file asserts the FIXED behaviour. It is proven able to go RED by
neutralising the arm gating in tidelink_fifo_ctrl.sv (see run_redgreen.sh),
where the DISARMED tests FAIL because a stray pair again walks write_ptr. SRAM
is X-init (+define+TIDELINK_SRAM_NO_ZERO_INIT), faithful to the vendor model —
a zero-init BRAM hides the mis-framing.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

RAM_ADDR_W = 14
MAX_CREDITS = 1 << (RAM_ADDR_W - 2)   # 4096
NONSEQ = 0b10
IDLE = 0b00


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
    # POR-disarmed by default: the runtime AHB-inject arm (CTRL[3]) starts 0.
    dut.swi_ahb_inject_arm.value = 0
    dut.hresetn.value = 0
    for _ in range(4):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    await RisingEdge(dut.hclk)


async def ahb_write(dut, addr, data):
    """One AHB single-beat NONSEQ write (address phase, then data phase)."""
    dut.hsel.value = 1
    dut.htrans.value = NONSEQ
    dut.hwrite.value = 1
    dut.haddr.value = addr
    await RisingEdge(dut.hclk)
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


async def ahb_read_word(dut, byte_addr):
    """AHB single-beat read; returns hrdata (data phase)."""
    dut.hsel.value = 1
    dut.htrans.value = NONSEQ
    dut.hwrite.value = 0
    dut.haddr.value = byte_addr
    await RisingEdge(dut.hclk)
    dut.htrans.value = IDLE
    dut.hsel.value = 0
    await RisingEdge(dut.hclk)
    return dut.hrdata.value


def wp(dut):
    return int(_ctrl(dut).write_ptr_r.value)


def cc(dut):
    return int(_ctrl(dut).credit_count_r.value)


async def stray_clear_probe_pair(dut):
    """THE TWIN-2 CORRUPTOR: a two-word clear/probe write pair on an idle FIFO.

    W_A: offset 0 with a ZERO word -> length field [31:20] == 0
    W_B: offset 4  == write_target for a zero-length packet -> self-completes
    """
    await ahb_write(dut, 0, 0x0000_0000)
    await ahb_write(dut, 4, 0xDEAD_BEEF)
    for _ in range(4):
        await RisingEdge(dut.hclk)


@cocotb.test()
async def test_stray_write_pair_is_noop(dut):
    """HALF 1 (the bug): a stray clear/probe pair must move NOTHING."""
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    assert wp(dut) == 0, "write_ptr should start at 0"
    assert cc(dut) == MAX_CREDITS, f"credit should start at MAX ({MAX_CREDITS})"

    await stray_clear_probe_pair(dut)

    dut._log.info(f"after stray AHB pair: write_ptr={wp(dut)} B, credit={cc(dut)}")
    assert wp(dut) == 0, (
        f"TWIN-2 LIVE: stray AHB write pair walked write_ptr to {wp(dut)} bytes "
        "(expected 0). The FC-shared write pointer is corrupted.")
    assert cc(dut) == MAX_CREDITS, (
        f"TWIN-2 LIVE: stray AHB write pair burned credit to {cc(dut)} "
        f"(expected {MAX_CREDITS}).")
    dut._log.info("PASS: stray AHB write pair is a no-op on write_ptr/credit.")


@cocotb.test()
async def test_fc_packet_byte_exact_after_stray_ahb(dut):
    """HALF 1 (the consequence): the next genuine FC packet must land correctly.

    With TWIN-2 live, write_ptr is pre-walked to word 2, so the FC packet lands
    two words late and a reader draining from offset 0 sees garbage/X.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    await stray_clear_probe_pair(dut)
    assert wp(dut) == 0, (
        f"write_ptr pre-walked to {wp(dut)} by the stray pair — TWIN-2 live")

    # INSTRUMENT NOTE (not part of the DUT fix): cmsdk_ahb_to_sram keeps a
    # write-forward entry for the last AHB write. FC direct writes BYPASS that
    # bridge, so after the stray write to offset 4 the bridge would shadow a
    # later CPU read of offset 4 with the stale 0xDEADBEEF even though the SRAM
    # array itself holds the correct FC word (verified: rdata=0x10002000 while
    # hrdata=0xDEADBEEF). A benign write to a far scratch offset displaces that
    # entry. Without this, word1 read back stale and the byte-exact check failed
    # for a reason that has nothing to do with write_ptr framing.
    await ahb_write(dut, 0x100, 0x0000_0000)
    for _ in range(2):
        await RisingEdge(dut.hclk)

    # Genuine FC-direct packet: 2 payload words -> 4 words total.
    LEN = 2
    words = [
        (LEN << 20) | 0x0_0055,   # word0: length field in [31:20]
        0x1000_2000,              # word1: dest_addr
        0xAAAA_0001,              # payload 0
        0xBBBB_0002,              # payload 1
    ]
    for i, w in enumerate(words):
        await fc_write(dut, i * 4, w)   # 0xC == write_target for len=2 -> completes
    for _ in range(4):
        await RisingEdge(dut.hclk)

    # Drain from offset 0, exactly as a real reader does.
    got = []
    for i in range(4):
        got.append(await ahb_read_word(dut, i * 4))

    for i, (g, exp) in enumerate(zip(got, words)):
        assert g.is_resolvable, (
            f"FC packet word{i} unresolvable ({g}) — mis-framed: the reader is "
            "looking at X-init SRAM the packet was never written to.")
        assert int(g) == exp, (
            f"FC packet MIS-FRAMED at word{i}: got 0x{int(g):08X}, "
            f"expected 0x{exp:08X}")
    dut._log.info("PASS: FC packet byte-exact at offset 0 after a stray AHB pair.")


@cocotb.test()
async def test_legit_ahb_inject_still_works(dut):
    """HALF 2 (the supported path): a REAL AHB-injected packet must still work.

    This is the whole point of David's decision — AHB-CPU-write-to-RX IS
    supported. A fix that blocks this is a FAILED fix.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    # ARM the inject path (software would set CTRL[3]=1 before injecting).
    dut.swi_ahb_inject_arm.value = 1
    await RisingEdge(dut.hclk)

    LEN = 2
    words = [
        (LEN << 20) | 0x0_00A5,   # word0: length header
        0x3000_4000,              # word1: dest_addr
        0xC0DE_0001,              # payload 0
        0xC0DE_0002,              # payload 1
    ]
    # Inject the packet over AHB: header to offset 0, then the data words.
    for i, w in enumerate(words):
        await ahb_write(dut, i * 4, w)   # 0xC == write_target -> completes
    for _ in range(4):
        await RisingEdge(dut.hclk)

    total_words = LEN + 2
    dut._log.info(f"after legit AHB inject: write_ptr={wp(dut)} B, credit={cc(dut)}")
    assert wp(dut) == total_words * 4, (
        f"SUPPORTED PATH BROKEN: AHB-injected packet did not commit — "
        f"write_ptr={wp(dut)}, expected {total_words * 4} bytes.")
    assert cc(dut) == MAX_CREDITS - total_words, (
        f"SUPPORTED PATH BROKEN: credit={cc(dut)}, "
        f"expected {MAX_CREDITS - total_words}.")

    # And it must read back byte-exact from offset 0.
    got = []
    for i in range(4):
        got.append(await ahb_read_word(dut, i * 4))
    for i, (g, exp) in enumerate(zip(got, words)):
        assert g.is_resolvable, f"AHB-injected word{i} unresolvable ({g})"
        assert int(g) == exp, (
            f"SUPPORTED PATH BROKEN: AHB-injected packet word{i} read back "
            f"0x{int(g):08X}, expected 0x{exp:08X}")
    dut._log.info("PASS: legitimate AHB-injected packet committed and byte-exact.")


@cocotb.test()
async def test_legit_ahb_inject_len0_rd_req(dut):
    """HALF 2 (the regression the OLD `!= 0` reject caused): a length-0 packet is
    a LEGAL type — PKT_RD_REQ, a header-only read request. The removed reject
    silently dropped it on the AHB path. ARMED, it must be accepted and commit.

    total_words = 0 + 2 = 2; write_target = (0+1)<<2 = offset 4, so the write of
    word1 (dest_addr) self-completes the 2-word packet.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    dut.swi_ahb_inject_arm.value = 1
    await RisingEdge(dut.hclk)

    words = [
        (0 << 20) | 0x0_00A5,     # word0: length 0 (RD_REQ), fields in low bits
        0x5000_6000,              # word1: dest_addr
    ]
    for i, w in enumerate(words):
        await ahb_write(dut, i * 4, w)
    for _ in range(4):
        await RisingEdge(dut.hclk)

    total_words = 2
    dut._log.info(f"after len-0 AHB inject: write_ptr={wp(dut)} B, credit={cc(dut)}")
    assert wp(dut) == total_words * 4, (
        f"RD_REQ DROPPED: length-0 AHB packet did not commit — write_ptr={wp(dut)}, "
        f"expected {total_words * 4}. The removed `!= 0` reject would drop it.")
    assert cc(dut) == MAX_CREDITS - total_words, (
        f"RD_REQ DROPPED: credit={cc(dut)}, expected {MAX_CREDITS - total_words}.")

    got = [await ahb_read_word(dut, 0), await ahb_read_word(dut, 4)]
    for i, (g, exp) in enumerate(zip(got, words)):
        assert g.is_resolvable, f"len-0 RD_REQ word{i} unresolvable ({g})"
        assert int(g) == exp, (
            f"len-0 RD_REQ word{i} read back 0x{int(g):08X}, expected 0x{exp:08X}")
    dut._log.info("PASS: length-0 RD_REQ accepted and byte-exact when ARMED.")


@cocotb.test()
async def test_twin1_held_nonseq_locked(dut):
    """TWIN 1 lock (documented accidental one-shot, NONSEQ-only).

    Holding htrans=NONSEQ + hwrite to offset 0 must NOT walk write_ptr or burn
    credit. Pins the accidental one-shot so a refactor cannot silently turn it
    into a corruptor.
    """
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())
    await reset(dut)

    # ARMED, so the held-NONSEQ one-shot is genuinely exercised against a LIVE
    # write path (a disarmed path would pass this trivially and prove nothing).
    dut.swi_ahb_inject_arm.value = 1
    await RisingEdge(dut.hclk)

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
        f"TWIN-1 regression: held NONSEQ walked write_ptr to {wp(dut)}")
    assert cc(dut) == MAX_CREDITS, (
        f"TWIN-1 regression: held NONSEQ burned credit to {cc(dut)}")
    assert int(dut.overrun.value) == 0, "TWIN-1: unexpected overrun on held NONSEQ"
    dut._log.info("TWIN-1 locked: held NONSEQ left write_ptr=0, credit=MAX.")

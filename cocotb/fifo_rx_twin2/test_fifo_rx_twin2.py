"""RX-FIFO TWIN 2 reproduction + fix gate (verification-plan gap F10).

DEFECT (root-caused 2026-07-16, verified against current RTL 2026-07-18):
    tidelink_fifo_ctrl.sv arms the WRITE-side packet-length latch on ANY AHB
    write to offset 0:
        capture_write_length_nxt = valid_ahb_access && (haddr==0) && hwrite;
    with NO guard. The sibling READ-side arm got `&& !rx_fifo_empty` in the
    2026-07-14 phantom-pop fix; the WRITE arm got nothing. So an AHB write to
    offset 0 (e.g. a driver "clearing" the RX window with zeros) latches a
    phantom packet length and sets packet_active; the paired write to offset 4
    then fires write_complete, which walks write_ptr by (len+2) words and burns
    (len+2) credits.

BLAST RADIUS — worse than the read-side phantom pop:
    write_ptr is SHARED with the FC committer:
        fc_translated_addr = fc_wr_addr + write_ptr_r    (tidelink_fifo_ctrl.sv)
    so after a stray AHB write, the NEXT genuine FC-committed packet is written
    at the wrong SRAM base (mis-framed), and the local credit count is desynced
    from the peer. The reader, addressing from read_ptr=0, sees stale words.

INTENT (answered with grep evidence — see docs/RXFIFO_TWIN2_DISPOSITION.md):
    No software ever WRITES the RX aperture. Every hw_regression script only
    READS 0x84010000 (gp1_rx) to verify received data byte-exact; CPU writes go
    to the separate TX aperture 0x84000000. The RX FIFO is committed by the FC
    direct-write port, not by AHB. => AHB-write-to-RX is NOT a supported silicon
    path, and the fix is to make it a NO-OP (ENABLE_AHB_WRITE=0 at the SoC).

This bench EXPOSES the FC direct-write port (the real committer) so the genuine
packet is delivered independently of the (defective) AHB write path. Checks are
WHITEBOX on write_ptr / credit_count — immune to the SRAM X-init blindness that
hid the phantom pop. The tb ties ENABLE_AHB_WRITE(0): ignored on the unfixed RTL
(bug reproduces => FAIL), honoured on the patched copy (=> PASS).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10
RAM_ADDR_W    = 14
MAX_CREDITS   = 1 << (RAM_ADDR_W - 2)   # 4096


# ── word0 header packing (length in bits [31:20]) ────────────────────────────
def word0(length):
    return (length & 0xFFF) << 20


# ── whitebox probes ──────────────────────────────────────────────────────────
def write_ptr(dut):      return int(dut.u_dut.write_ptr.value)
def read_ptr(dut):       return int(dut.u_dut.read_ptr.value)
def credit(dut):         return int(dut.u_dut.credit_count.value)

def packet_active(dut):
    try:
        return int(dut.u_dut.u_fifo_ctrl.packet_active_r.value)
    except ValueError:
        return 0

def fc_landing_addr(dut):
    """Byte address the FC committer is CURRENTLY writing = fc_wr_addr + write_ptr_r."""
    try:
        return int(dut.u_dut.fc_translated_addr.value)
    except ValueError:
        return -1

def sram_word(dut, word_addr):
    """Read a 32-bit word straight from the BRAM byte arrays (X/Z -> 0)."""
    def b(sig):
        try:
            return int(sig.value) & 0xFF
        except ValueError:
            return 0
    s = dut.u_dut.u_sram.u_sram
    return ((b(s.BRAM3[word_addr]) << 24) | (b(s.BRAM2[word_addr]) << 16)
            | (b(s.BRAM1[word_addr]) << 8) | b(s.BRAM0[word_addr]))


# ── stimulus helpers ─────────────────────────────────────────────────────────
async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    # Idle all inputs
    dut.hsel.value = 0; dut.htrans.value = 0; dut.hwrite.value = 0
    dut.hsize.value = 2; dut.haddr.value = 0x3FFF; dut.hwdata.value = 0
    dut.flush.value = 0
    dut.fc_wr_valid.value = 0; dut.fc_wr_write.value = 0
    dut.fc_wr_addr.value = 0; dut.fc_wr_wdata.value = 0


async def do_reset(dut):
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def ahb_write_raw(dut, addr, data):
    """One NONSEQ AHB write beat (addr phase, data phase, idle) — the exact shape
    a CPU/bridge write to the RX window takes."""
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 1
    dut.hsize.value = 2; dut.haddr.value = addr
    await RisingEdge(dut.hclk)
    dut.hwdata.value = data
    dut.htrans.value = 0; dut.hsel.value = 0
    await RisingEdge(dut.hclk)
    dut.hwrite.value = 0; dut.haddr.value = 0x3FFF


async def fc_commit_packet(dut, length, dest_addr, payload):
    """Commit a genuine packet through the FC direct-write port (the real silicon
    committer): word0(len) @0, dest_addr @4, payload @8.. . One word/cycle."""
    words = [word0(length), dest_addr] + list(payload)
    landing_of_header = None
    for i, w in enumerate(words):
        await RisingEdge(dut.hclk)
        dut.fc_wr_valid.value = 1
        dut.fc_wr_write.value = 1
        dut.fc_wr_addr.value  = i * 4
        dut.fc_wr_wdata.value = w
        if i == 0:
            # sample the header's landing address one delta after drive settles
            await ClockCycles(dut.hclk, 0)
    await RisingEdge(dut.hclk)
    dut.fc_wr_valid.value = 0; dut.fc_wr_write.value = 0
    dut.fc_wr_addr.value = 0; dut.fc_wr_wdata.value = 0
    await ClockCycles(dut.hclk, 3)


async def clear_write_rx_window(dut, n=2):
    """The offending access: a driver 'clears'/probes the RX window by writing
    zeros to offsets 0, 4, ... — the write-side analogue of the phantom-pop
    drain. On the unfixed RTL the first two beats already fire write_complete."""
    for i in range(n):
        await ahb_write_raw(dut, i * 4, 0)
        await ClockCycles(dut.hclk, 3)


# ── tests ────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_00_fc_commit_baseline(dut):
    """BASELINE (must PASS on both unfixed and patched): a genuine FC-committed
    packet lands at base 0 and accounts credit correctly. Establishes that the
    FC committer — the real silicon path — works in this bench."""
    await setup(dut)
    await do_reset(dut)

    assert write_ptr(dut) == 0 and credit(dut) == MAX_CREDITS, "clean precondition"

    payload = [0xC0DE0001, 0xC0DE0002, 0xC0DE0003]     # length 3, total 5 words
    await fc_commit_packet(dut, length=3, dest_addr=0xDEAD0000, payload=payload)

    total = 3 + 2
    assert write_ptr(dut) == total * 4, \
        f"FC packet should advance write_ptr to {total*4}, got {write_ptr(dut)}"
    assert credit(dut) == MAX_CREDITS - total, \
        f"credit should drop by {total}, got {MAX_CREDITS - credit(dut)}"
    # Landed byte-exact at base 0
    assert sram_word(dut, 0) == word0(3),        f"SRAM[0]=0x{sram_word(dut,0):08X}"
    assert sram_word(dut, 1) == 0xDEAD0000,      f"SRAM[1]=0x{sram_word(dut,1):08X}"
    for i, p in enumerate(payload):
        assert sram_word(dut, 2 + i) == p, \
            f"SRAM[{2+i}]=0x{sram_word(dut,2+i):08X} != 0x{p:08X}"
    dut._log.info("baseline FC commit lands at base 0, credit correct")


@cocotb.test()
async def test_01_ahb_clear_write_is_noop(dut):
    """TWIN 2 core (mirrors phantom-pop test_41): an AHB write to the RX window
    must NOT move write_ptr or burn credit. This is the primary, X-immune
    whitebox check.

    UNFIXED: the offset-0 write latches a phantom length; the offset-4 write
    fires write_complete -> write_ptr += 8, credit -= 2. Assert FAILS.
    PATCHED (ENABLE_AHB_WRITE=0): AHB write path is dead -> no-op. Assert PASSES.
    """
    await setup(dut)
    await do_reset(dut)

    wp0, cc0 = write_ptr(dut), credit(dut)
    assert wp0 == 0 and cc0 == MAX_CREDITS, "clean precondition"

    await clear_write_rx_window(dut, n=2)

    wp1, cc1 = write_ptr(dut), credit(dut)
    assert cc1 == MAX_CREDITS, (
        f"TWIN 2: an AHB write to the RX window BURNED credit "
        f"({MAX_CREDITS} -> {cc1}). The FC-shared credit counter is now desynced "
        f"from the peer for a packet that was never received.")
    assert wp1 == 0, (
        f"TWIN 2: an AHB write to the RX window WALKED write_ptr "
        f"(0x{wp0:04X} -> 0x{wp1:04X}). write_ptr is shared with the FC committer "
        f"(fc_translated_addr = fc_wr_addr + write_ptr), so the next genuine "
        f"received packet will be committed at the wrong SRAM base.")
    assert packet_active(dut) == 0, "no phantom packet should be armed"
    dut._log.info("AHB write to RX window is a no-op: write_ptr and credit unchanged")


@cocotb.test()
async def test_02_genuine_fc_packet_survives_ahb_clear(dut):
    """TWIN 2 blast radius (mirrors phantom-pop test_42, end-to-end): a stray AHB
    'clear the RX window' write, THEN a genuine FC-committed packet. The packet
    must land at base 0, byte-exact, with correct credit — proving the stray
    write did not corrupt the committer.

    UNFIXED: the clear-write pre-advances write_ptr to 8, so the FC header lands
    at SRAM word 2 (mis-framed), write_ptr ends 8 high, credit 2 low. FAILS.
    PATCHED: clear-write is a no-op -> packet lands at base 0. PASSES.
    """
    await setup(dut)
    await do_reset(dut)

    # (c) the offending AHB write to the read-only RX aperture
    await clear_write_rx_window(dut, n=2)

    # (b) a genuine received packet, committed via the FC direct-write port
    payload = [0xA2B00000 + i for i in range(6)]        # length 6, total 8 words
    total = 6 + 2

    # The header's landing address is write_ptr at commit time. On the unfixed
    # RTL the stray write already pushed write_ptr to 8, so watch it directly.
    landing = []
    async def watch_landing():
        for _ in range(12):
            await RisingEdge(dut.hclk)
            if int(dut.fc_wr_valid.value) and int(dut.fc_wr_addr.value) == 0:
                landing.append(fc_landing_addr(dut))
    cocotb.start_soon(watch_landing())

    await fc_commit_packet(dut, length=6, dest_addr=0xBEEF0000, payload=payload)

    assert landing and landing[0] == 0, (
        f"TWIN 2 BLAST RADIUS: the genuine FC packet's header was committed at "
        f"SRAM byte 0x{(landing[0] if landing else -1):04X}, not 0 — a prior stray "
        f"AHB write to the RX window walked the FC-shared write_ptr, so this "
        f"received packet is mis-framed.")
    assert write_ptr(dut) == total * 4, (
        f"TWIN 2 BLAST RADIUS: after one genuine {total}-word packet write_ptr "
        f"should be {total*4}, got {write_ptr(dut)} (stray AHB write added an offset).")
    assert credit(dut) == MAX_CREDITS - total, (
        f"TWIN 2 BLAST RADIUS: credit should reflect ONLY the genuine packet "
        f"({MAX_CREDITS - total}), got {credit(dut)} (stray AHB write burned extra).")
    # Byte-exact at base 0
    assert sram_word(dut, 0) == word0(6), \
        f"SRAM[0]=0x{sram_word(dut,0):08X} != header 0x{word0(6):08X} (packet mis-landed)"
    assert sram_word(dut, 1) == 0xBEEF0000, f"SRAM[1]=0x{sram_word(dut,1):08X}"
    for i, p in enumerate(payload):
        assert sram_word(dut, 2 + i) == p, \
            f"payload word {i}: SRAM[{2+i}]=0x{sram_word(dut,2+i):08X} != 0x{p:08X}"
    dut._log.info("genuine FC packet survived a stray AHB clear-write, byte-exact at base 0")

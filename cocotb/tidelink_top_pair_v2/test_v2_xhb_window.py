"""V2 XHB500 transparent-window round-trip gate (sim-only, FPGA sim-gate).

Proves the transparent AHB datapath END-TO-END, independent of the PHY eye:

    master PS-side AHB (ahb_sub) WRITE @ 0x4000_0000+off
      -> XHB500 AHB->AXI  -> master chiplet controller s_axi (Wlink AXI target)
      -> FC aw/w/b/ar/r channels -> chiplet link -> slave die
      -> slave XHB500 AXI->AHB -> slave ahb_mng -> tb BRAM terminus (u_s_mng_bram)
    READ-back @ the SAME address returns the stored value byte-exact.

Address translation is IDENTITY at reset (tl_addr_trans_cam global_enable=0),
so the peer BRAM (AW=12, decodes HADDR[11:2]) sees the same low offset and the
0x4000_0000 aperture bits are ignored by the terminus. Because write@X and
read@X both traverse the identical (data-independent) mapping, byte-exactness
holds regardless of any fixed base the window applies.

The datapath RTL is silicon/UVM-proven (uvm/tidelink_top_system's
test_top_ahb_passthrough: 4/4 byte-exact ahb_sub->XHB500->peer ahb_mng
round-trips); this cocotb variant is the sim-gate that authorises the FPGA
build of the transparent window (peer ahb_mng terminated by a real BRAM).

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh
    export TIDELINK_PHY_V2=1
    make MODULE=test_v2_xhb_window
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full


APERTURE_BASE = 0x4000_0000

# (offset < 4 KB, data). Offsets are word-aligned and distinct in the low 12
# bits so each lands at its own BRAM word.
VECTORS = [
    (0x000, 0xCAFEF00D),
    (0x100, 0xDEADBEEF),
    (0x204, 0x12345678),
    (0x408, 0xA5A55A5A),
]

# Cycles to let a posted write cross both AXI FC directions and settle in the
# peer's ahb_mng BRAM before the read chases it (the window is longer-latency
# than the FIFO path).
WRITE_SETTLE = 8000


class AHBSubMaster:
    """Hand-rolled AHB-Lite single-beat master on the exposed m_ahb_sub_* port.

    Handles tidelink_top's 1-wait-state NONSEQ pipeline: present NONSEQ for a
    single cycle (the pipeline register latches the translated address), then
    drop to IDLE so it is not re-latched, and wait for hreadyout — which the
    XHB500 slv holds low across the cross-link round-trip and raises with the
    b/r response.  hready is driven CONSTANT-high (never looped to hreadyout)
    to avoid the known hready<->hreadyout comb loop.
    """

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.hclk
        self.hsel      = dut.m_ahb_sub_hsel
        self.haddr     = dut.m_ahb_sub_haddr
        self.hburst    = dut.m_ahb_sub_hburst
        self.hprot     = dut.m_ahb_sub_hprot
        self.hsize     = dut.m_ahb_sub_hsize
        self.htrans    = dut.m_ahb_sub_htrans
        self.hwdata    = dut.m_ahb_sub_hwdata
        self.hwrite    = dut.m_ahb_sub_hwrite
        self.hready    = dut.m_ahb_sub_hready
        self.hrdata    = dut.m_ahb_sub_hrdata
        self.hresp     = dut.m_ahb_sub_hresp
        self.hreadyout = dut.m_ahb_sub_hreadyout
        self.idle()

    def idle(self):
        self.hsel.value   = 0
        self.haddr.value  = 0
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hsize.value  = 2     # WORD
        self.htrans.value = 0     # IDLE
        self.hwdata.value = 0
        self.hwrite.value = 0
        self.hready.value = 1     # const-high (no comb loop)

    def _resp(self):
        try:
            return int(self.hresp.value)
        except ValueError:
            return 0

    def _rdata(self):
        try:
            return int(self.hrdata.value)
        except ValueError:
            return -1

    async def _run(self, addr, write, wdata, timeout):
        """One AHB-Lite single-beat transfer through tidelink_top's pipelined
        XHB500 slv, waiting for the TRUE cross-link completion.

        The tidelink pipeline register raises hreadyout for one cycle at
        address-accept, then holds it LOW while the transfer crosses the FC
        link, then raises it again with the b/r response. Breaking on the
        address-accept pulse (and idling) leaves the XHB500 slv wedged
        (observed: subsequent transfers never get an s_axi handshake). So we
        skip the accept pulse (require hreadyout to go LOW first) and complete
        on the following HIGH. HWDATA is held valid across the whole data phase;
        hsel is released after the address phase (holding it also stalls the
        bridge).
        """
        # ---- address phase: NONSEQ for one cycle (the pipeline latches it) ----
        await RisingEdge(self.clk)
        self.hsel.value   = 1
        self.haddr.value  = addr & 0xFFFF_FFFF
        self.htrans.value = 2     # NONSEQ
        self.hsize.value  = 2     # WORD
        self.hburst.value = 0
        self.hprot.value  = 0
        self.hwrite.value = 1 if write else 0
        self.hready.value = 1
        if write:
            self.hwdata.value = wdata & 0xFFFF_FFFF   # held through data phase
        await RisingEdge(self.clk)
        # release address-phase controls; keep HWDATA valid (write)
        self.hsel.value   = 0
        self.htrans.value = 0
        self.hwrite.value = 0
        self.hburst.value = 0

        # ---- wait for true completion: skip accept pulse (low first) then high
        seen_low = False
        rdata, resp, done = -1, 0, False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            r = int(self.hreadyout.value)
            if not r:
                seen_low = True
            elif seen_low:
                rdata = self._rdata()
                resp = self._resp()
                done = True
                break
        self.idle()
        op = "WRITE" if write else "READ"
        if not done:
            raise TimeoutError(f"ahb_sub {op} 0x{addr:08x} did not complete")
        if resp:
            raise RuntimeError(f"ahb_sub {op} 0x{addr:08x} HRESP=ERROR")
        return rdata

    async def write(self, addr, data, timeout=60000):
        await self._run(addr, write=True, wdata=data, timeout=timeout)

    async def read(self, addr, timeout=60000):
        return await self._run(addr, write=False, wdata=0, timeout=timeout)


def _slave_bram_peek(dut, off):
    """Hierarchical peek at the slave die's BRAM terminus (u_s_mng_bram),
    where a master ahb_sub write into the aperture lands. Returns the stored
    word or None if the path/index can't be resolved. Diagnostic only."""
    try:
        return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception:
        return None


@cocotb.test()
async def test_xhb_window_roundtrip(dut):
    """Byte-exact master-ahb_sub -> peer-ahb_mng round-trip over the link."""
    tb = PairV2TB(dut)
    m_ahb = AHBSubMaster(dut)          # idles ahb_sub before bring-up

    # Bring the V2 link up (POR -> role_lock -> passive autocal -> data mode),
    # then wait for the bilateral CR/CRACK handshake so the FC channels carry.
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    fails = []
    for off, data in VECTORS:
        addr = APERTURE_BASE + off
        await m_ahb.write(addr, data)
        await ClockCycles(dut.hclk, WRITE_SETTLE)

        peek = _slave_bram_peek(dut, off)
        got = await m_ahb.read(addr)

        peek_s = "n/a" if peek is None else f"0x{peek:08x}"
        tb.log.info(f"  [xhb-window] addr=0x{addr:08x} wrote=0x{data:08x} "
                    f"read=0x{got:08x} (slave BRAM[{off >> 2}]={peek_s})")
        if got != data:
            fails.append((addr, data, got, peek))

    assert not fails, (
        "XHB500 transparent-window round-trip MISMATCH:\n" +
        "\n".join(
            f"  addr=0x{a:08x} wrote=0x{d:08x} read=0x{g:08x} "
            f"slaveBRAM={'n/a' if p is None else f'0x{p:08x}'}"
            for a, d, g, p in fails))

    tb.log.info(f"  [xhb-window] PASS: {len(VECTORS)}/{len(VECTORS)} byte-exact "
                f"round-trips across the transparent window")

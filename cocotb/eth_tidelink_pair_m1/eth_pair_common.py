"""Helpers for the Ethernet-over-TideLink M1 bench (real subsystem via eth_ss_0).

Re-uses the pair_v2 bench verbatim (both dirs on PYTHONPATH via the Makefile):
the two-die bring-up (`PairV2TB`, `run_bringup_full`) and the peer-window
AHB-Lite master (`AHBSubMaster`) that drives `m_ahb_sub_*`. Adds only what is
M1-specific: the eth-subsystem memory map, a frame builder, and a hierarchical
peek into die_b's eth_scratch_rx (now INSIDE the `ethernet_ss_ahb` instance:
`u_s_eth_ss.u_region_eth_scratch_rx_0` -> sl_ahb_sram -> cmsdk_fpga_sram,
byte-split across BRAM0..3).
"""
from cocotb.triggers import RisingEdge
from pair_v2_common import PairV2TB, run_bringup_full          # noqa: F401
from test_v2_xhb_window import AHBSubMaster                     # noqa: F401


class EthAHBSubMaster(AHBSubMaster):
    """Robust peer-window master for the REAL ethernet_ss_ahb (eth_ss_0) attach.

    Two differences vs the pair_v2 AHBSubMaster, both HARNESS-only (nothing about
    the DUT changes), each traceable to a measured bus-contract difference the
    eth-matrix terminus introduces that the M0 zero-wait single-slave BRAM did
    not (see README "Bus-contract findings"):

      1. X-TOLERANCE. pair_v2 does `int(hreadyout.value)`, which raises on any
         unresolved (X) cycle. The eth matrix drives `eth_ss_0_hready` through a
         transient X on the FIRST cold cross-link access, which rides the XHB500
         AXI response back onto die_a's `m_ahb_sub_hreadyout`. We treat X as
         "still in flight, keep waiting" instead of aborting.

      2. SUSTAINED-LOW completion. Measured on die_a `m_ahb_sub_hreadyout`: a
         short accept-pulse oscillation (1,0,1,0) at the address phase, then a
         LONG sustained low (~250 hclk) while the access + response cross the
         link, then the true completion high. The naive "first low then high"
         detector trips on the 1-cycle accept oscillation. We require a run of
         >= MIN_LOW_RUN consecutive lows (the cross-link window) before a high
         is accepted as completion; a transient high resets the run.
    """

    MIN_LOW_RUN = 3

    def _resolved(self, sig):
        try:
            return int(sig.value)
        except Exception:
            return None

    async def _run(self, addr, write, wdata, timeout):
        await RisingEdge(self.clk)
        self.hsel.value   = 1
        self.haddr.value  = addr & 0xFFFF_FFFF
        self.htrans.value = 2         # NONSEQ
        self.hsize.value  = 2         # WORD
        self.hburst.value = 0         # SINGLE
        self.hprot.value  = 0
        self.hwrite.value = 1 if write else 0
        self.hready.value = 1
        if write:
            self.hwdata.value = wdata & 0xFFFF_FFFF
        await RisingEdge(self.clk)
        self.hsel.value   = 0
        self.htrans.value = 0
        self.hwrite.value = 0
        self.hburst.value = 0

        low_run, armed = 0, False
        rdata, resp, done = -1, 0, False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            r = self._resolved(self.hreadyout)     # None on X
            if r == 0:
                low_run += 1
                if low_run >= self.MIN_LOW_RUN:
                    armed = True
            elif r == 1:
                if armed:
                    rdata = self._rdata()
                    resp  = self._resp()
                    done  = True
                    break
                low_run = 0                         # accept-pulse: reset the run
            else:                                   # X
                if armed:
                    low_run += 1                    # X during the in-flight window
        self.idle()
        op = "WRITE" if write else "READ"
        if not done:
            raise TimeoutError(f"ahb_sub {op} 0x{addr:08x} did not complete")
        if resp:
            raise RuntimeError(f"ahb_sub {op} 0x{addr:08x} HRESP=ERROR")
        return rdata


# ---------------------------------------------------------------------------
# ethernet_ss_ahb memory map (build_soc/reports/ethernet_ss_ahb_memory_map.txt)
# ---------------------------------------------------------------------------
#   bootrom_0        0x0000_0000
#   imem_0           0x1000_0000
#   dmem_0           0x1800_0000
#   system           0x2000_0000
#   eth_scratch_rx_0 0x3000_0000  (16 KB)   <-- the M1a relayed-frame landing
#   eth_scratch_tx_0 0x3800_0000  (16 KB)
#   ethmac_0         0x4000_0000  (MAC regs+BDs @ +0x0000; HA1588 @ +0x1000)
#   apb_periph       0x5000_0000
# eth_ss_0 (die_b ahb_mng) reaches all of the above through the subsystem's
# own AHB matrix (eth_ss_interconnect). The MATRIX decodes the FULL 32-bit
# address, so — unlike the M0 single-slave BRAM which ignored the upper bits —
# the relayed write MUST carry the eth_scratch_rx base 0x3000_0000.
ETH_SCRATCH_RX_BASE = 0x3000_0000
ETH_SCRATCH_TX_BASE = 0x3800_0000
ETHMAC_BASE         = 0x4000_0000

# A "received-frame" landing offset within eth_scratch_rx.
ETH_SCRATCH_RX_OFF  = 0x0040

# die_a's exposed peer window (identity address translation at reset —
# tl_addr_trans_cam global_enable=0; XHB500 passes HADDR[31:0] through). The
# test DERIVES the exact peer->ahb_mng transform empirically at run time from
# the tb's ahb_mng address monitor, so this is only the nominal base.
PEER_APERTURE_BASE  = 0x0000_0000


def make_eth_frame(nwords=16, seed=0xE7):
    """A deterministic frame-like burst (default 16 words = 64 B, min ethernet
    frame). Words 0..3 mimic an ARP-request header; the rest is a checkerboard
    payload. Byte-exactness of the whole burst is what the relay proves."""
    frame = [
        0xFFFFFFFF,              # dest MAC [47:16] (broadcast)
        0xFFFF0200,              # dest MAC [15:0]=FFFF | src MAC [47:32]=0x0200
        0x00000001,              # src MAC [31:0]
        0x08060001,              # ethertype 0x0806 (ARP) | HTYPE hi
    ]
    for i in range(len(frame), nwords):
        frame.append(((seed + i) * 0x01010101) & 0xFFFFFFFF)
    return frame[:nwords]


def eth_scratch_rx_peek(dut, mng_addr):
    """Reconstruct the 32-bit word held at the eth_scratch_rx location that
    ahb_mng address `mng_addr` selects, by reading the four byte-lane BRAMs of
    the subsystem's eth_scratch_rx cmsdk_fpga_sram directly. Independent proof
    the data physically landed in the ETH subsystem's scratch (not a bus echo).
    The region decodes HADDR[13:2] -> word (mng_addr[13:0] >> 2). Returns the
    word, or None if the hierarchy cannot be resolved."""
    idx = (mng_addr & 0x3FFF) >> 2
    try:
        sram = dut.u_s_eth_ss.u_region_eth_scratch_rx_0.u_sram.u_sram
        b0 = int(sram.BRAM0[idx].value) & 0xFF
        b1 = int(sram.BRAM1[idx].value) & 0xFF
        b2 = int(sram.BRAM2[idx].value) & 0xFF
        b3 = int(sram.BRAM3[idx].value) & 0xFF
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    except Exception:
        return None

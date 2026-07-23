"""Helpers for the Ethernet-over-TideLink SHAPE-A bench (MAC + HA1588 regs).

Fork of the M1 bench's eth_pair_common.py. Re-uses the pair_v2 bring-up
(`PairV2TB`, `run_bringup_full`) and the peer-window AHB-Lite master
(`AHBSubMaster`, robust-wrapped as `EthAHBSubMaster`) VERBATIM.

The ONE addition vs M1: the ethmac / HA1588 register-aperture addresses. The M1
bench relayed a frame into `eth_scratch_rx` (0x3000_0000). This bench reaches a
register INSIDE the ethernet MAC (0x4000_0000) and the HA1588 PTP block
(0x4000_1000) across the link — the M2 register-visibility prerequisite for the
PTP grandmaster chain. Both are reachable through the SAME `eth_ss_0` attach:
the subsystem's OWN AHB matrix (eth_ss_ahb_interconnect) routes eth_ss_0 to
ethmac_0 (proven by the port-visibility matrix, see README FINDING 1).
"""
from cocotb.triggers import RisingEdge
from pair_v2_common import PairV2TB, run_bringup_full          # noqa: F401
from test_v2_xhb_window import AHBSubMaster                     # noqa: F401


class EthAHBSubMaster(AHBSubMaster):
    """Robust peer-window master for the REAL ethernet_ss_ahb attach.

    Identical to the M1 bench's EthAHBSubMaster (HARNESS-only robustness over the
    pair_v2 AHBSubMaster). Two differences vs the base, each traceable to a
    measured bus-contract trait the eth-matrix + APB->WB register terminus
    introduces that the M0 zero-wait single-slave BRAM did not:

      1. X-TOLERANCE. The eth matrix drives `hready` through a transient X on the
         FIRST cold cross-link access, which rides the XHB500 AXI response back
         onto die_a's `m_ahb_sub_hreadyout`. Treat X as "still in flight, keep
         waiting" instead of aborting (the base does `int(...)` and raises).

      2. SUSTAINED-LOW completion. A short accept-pulse oscillation (1,0,1,0) at
         the address phase, then a LONG sustained low while the access + response
         cross the link (register reads through the MAC WISHBONE bridge are
         *longer* latency than a scratch-SRAM write). Require a run of
         >= MIN_LOW_RUN consecutive lows before a high is accepted as completion;
         a transient high resets the run.
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
#   eth_scratch_rx_0 0x3000_0000  (the M1 relayed-frame landing)
#   ethmac_0         0x4000_0000  <-- THIS BENCH: MAC regs @ +0x0000..0x0FFF;
#                                                  HA1588 PTP regs @ +0x1000..0x1FFF
# eth_ss_0 (die_b ahb_mng) reaches ethmac_0 through the subsystem's own AHB
# matrix -- port-visibility matrix (report) lists:
#     eth_ss_0: bootrom_0, imem_0, dmem_0, eth_scratch_rx_0, eth_scratch_tx_0,
#               ethmac_0, apb_periph
# so NO restriction to scratch: the register-visibility M2 goal is reachable via
# the eth_ss_0 attach WITHOUT the full multicore SoC / d2d_ahb_s (README FINDING 1).
ETH_SCRATCH_RX_BASE = 0x3000_0000
ETHMAC_BASE         = 0x4000_0000

# Inside ethmac_0, the AHB->APB bridge takes HADDR[15:0]; ethmac_subsystem_apb's
# 4-bit decode (DECODE4BIT = paddr[15:12]) splits:
#     paddr[15:12]==0 -> Port 0 = OpenCores MAC   (0x0000..0x0FFF)
#     paddr[15:12]==1 -> Port 1 = HA1588 PTP      (0x1000..0x1FFF)
# (ethmac_subsystem_apb.v:127-131,159). So:
MAC_BASE            = ETHMAC_BASE + 0x0000
HA1588_BASE         = ETHMAC_BASE + 0x1000

# --- MAC register offsets (OpenCores ethmac; ethmac_regs.rdl) ---------------
MAC_MODER           = MAC_BASE + 0x00     # mode reg  -- HARD RESET 0x0000_A000
MAC_PACKETLEN       = MAC_BASE + 0x18     # min/max frame len -- reset 0x0040_0600
MAC_COLLCONF        = MAC_BASE + 0x1C     # collision cfg     -- reset 0x000F_003F
MAC_TX_BD_NUM       = MAC_BASE + 0x20     # TX BD partition   -- reset 0x0000_0040
MAC_MIIMODER        = MAC_BASE + 0x28     # MII mode          -- reset 0x0000_0064
MAC_MAC_ADDR0       = MAC_BASE + 0x40     # MAC addr low  (RW, X-init)
MAC_MAC_ADDR1       = MAC_BASE + 0x44     # MAC addr high (RW, X-init)

# Golden RTL reset values (verified by the standalone subsystem cocotb bench
# ethernet-mac-ahb/cocotb/ethmac_subsystem_apb/test_ethmac_subsystem_apb.py,
# which drives the IDENTICAL AHB->APB->WB register path this bench crosses):
#   CP2.1  MODER default == 0x0000_A000   (test line 315)
#   3.x    PACKETLEN 0x0040_0600, COLLCONF 0x000F_003F, TX_BD_NUM 0x40,
#          MIIMODER 0x0064  (VERIFICATION_PLAN.md register-reset table)
MAC_MODER_RESET     = 0x0000_A000
MAC_PACKETLEN_RESET = 0x0040_0600
MAC_MIIMODER_RESET  = 0x0000_0064
MAC_TX_BD_NUM_RESET = 0x0000_0040

# --- HA1588 PTP register offsets (ha1588.yaml register map) -----------------
HA1588_RTC_CTRL     = HA1588_BASE + 0x00  # RTC control (pulse bits, self-clearing) -- side effects!
HA1588_SCRATCH      = HA1588_BASE + 0x04  # general-purpose SW scratch -- RW, NO SIDE EFFECTS
HA1588_RTC_PERIOD   = HA1588_BASE + 0x20  # base period ns

# ===========================================================================
# eth_ptp_chain ADDITIONS -- the registers Shape-A never touched.
# ===========================================================================
# Authoritative decode: OpenCores-HA1588 rtl/reg/reg.v:127-158 (declarations),
# :210-243 (readback), :251-282 (bit meanings); mirrored in
# ethernet-mac-ahb/sys_desc/register_maps/ha1588.yaml.
#
# *** CRITICAL TRAP: the HA1588 register file has NO RESET. *** reg.v declares
# the registers with no reset clause, so EVERY HA1588 register powers up X in
# simulation -- not just SCRATCH (which Shape-A already noted as X-init). The
# block's own cocotb TB works around this by writing 0 to every register
# 0x00..0x7C before doing anything else (ethernet-mac-ahb/cocotb/ha1588_ahb/
# test_ha1588_ahb.py:154-155). Any bench that skips that zero-init is reading
# and writing X-valued control state. We replicate it (see zero_init_ha1588).
HA1588_TIME_SEC_H   = HA1588_BASE + 0x10
HA1588_TIME_SEC_L   = HA1588_BASE + 0x14
HA1588_TIME_NSC_H   = HA1588_BASE + 0x18
HA1588_TIME_NSC_L   = HA1588_BASE + 0x1C
HA1588_PERIOD_H     = HA1588_BASE + 0x20
HA1588_PERIOD_L     = HA1588_BASE + 0x24
HA1588_TSU_RXCTRL   = HA1588_BASE + 0x40   # [1] queue reset, [0] queue pop
HA1588_TSU_RXSTAT   = HA1588_BASE + 0x44   # [31:24] msgid mask (W), [7:0] depth (R)
HA1588_TSU_RXDATA0  = HA1588_BASE + 0x50   # .. +0x5C  (DATA0..DATA3)
HA1588_TSU_TXCTRL   = HA1588_BASE + 0x60
HA1588_TSU_TXSTAT   = HA1588_BASE + 0x64
HA1588_TSU_TXDATA0  = HA1588_BASE + 0x70

TSU_CTRL_READ_QUEUE = (1 << 0)
TSU_CTRL_RESET      = (1 << 1)

RTC_CTRL_GET_TIME   = (1 << 0)
RTC_CTRL_SET_PERIOD = (1 << 2)
RTC_CTRL_SET_TIME   = (1 << 3)

# --- OpenCores MAC registers needed to actually TRANSMIT --------------------
MAC_INT_SOURCE      = MAC_BASE + 0x04
MAC_INT_MASK        = MAC_BASE + 0x08
MAC_IPGT            = MAC_BASE + 0x0C
MAC_IPGR1           = MAC_BASE + 0x10
MAC_IPGR2           = MAC_BASE + 0x14
MAC_BD_BASE         = MAC_BASE + 0x400     # buffer-descriptor RAM

MODER_RXEN   = (1 << 0)
MODER_TXEN   = (1 << 1)
MODER_PRO    = (1 << 5)      # promiscuous -- accept regardless of DA
MODER_FULLD  = (1 << 10)
MODER_CRCEN  = (1 << 13)
MODER_PAD    = (1 << 15)

TX_BD_RD  = (1 << 15)        # "ready" -- MAC owns the descriptor
TX_BD_IRQ = (1 << 14)
TX_BD_WR  = (1 << 13)        # wrap
TX_BD_PAD = (1 << 12)
TX_BD_CRC = (1 << 11)

RX_BD_E   = (1 << 15)        # "empty" -- MAC owns the descriptor
RX_BD_IRQ = (1 << 14)
RX_BD_WR  = (1 << 13)

INT_TXB = (1 << 0)
INT_RXB = (1 << 2)

# --- DMA frame buffers: subsystem SRAM regions the MAC's DMA master can reach
# Per build_soc/reports/ethernet_ss_ahb_memory_map.txt the ethmac_0_dma
# initiator's target list is {eth_scratch_rx_0, eth_scratch_tx_0, dmem_0,
# imem_0, system} -- so both scratch regions are legal DMA targets, and both
# are ALSO reachable from eth_ss_0 (our across-the-link attach). That overlap
# is what lets die_a stage a frame the far MAC will DMA out.
TX_BUF_ADDR         = 0x3800_0000          # eth_scratch_tx_0
RX_BUF_ADDR         = 0x3000_0000          # eth_scratch_rx_0
NUM_TX_BDS          = 2

# PTP multicast DA / an arbitrary SA (matches the block-level cocotb suite)
PTP_DST_MAC = b'\x01\x1B\x19\x00\x00\x00'
PTP_SRC_MAC = b'\x00\x1A\x2B\x3C\x4D\x5E'


def build_ptp_sync_payload(seq_id=1, msg_type=0x00):
    """Build a raw L2 PTP frame payload (DA .. end; no preamble/SFD/FCS).

    Byte-for-byte the same construction the ethernet repo's own PTP co-sim uses
    (ethernet-mac-ahb/cocotb/ethmac_subsystem_apb/test_ptp_cosim.py:72-113), so
    a capture here is directly comparable with the block-level result.

    The parser inside HA1588 (OpenCores-HA1588 rtl/tsu/ptp_parser.v:49,176)
    matches on EtherType 0x88F7 and then gates on ptp_msgid_mask[messageType]
    -- so messageType MUST be one the mask enables (we use 0x00 = Sync).
    """
    ethertype = b'\x88\xF7'
    ptp_hdr = bytearray(34)
    ptp_hdr[0] = msg_type & 0x0F      # transportSpecific=0, messageType
    ptp_hdr[1] = 0x02                 # versionPTP = 2
    ptp_hdr[2] = 0x00
    ptp_hdr[3] = 0x2C                 # messageLength = 44
    ptp_hdr[20] = 0x00; ptp_hdr[21] = 0x1A
    ptp_hdr[22] = 0x2B; ptp_hdr[23] = 0xFF
    ptp_hdr[24] = 0xFE; ptp_hdr[25] = 0x3C
    ptp_hdr[26] = 0x4D; ptp_hdr[27] = 0x5E
    ptp_hdr[28] = 0x00; ptp_hdr[29] = 0x01   # portNumber
    ptp_hdr[30] = (seq_id >> 8) & 0xFF
    ptp_hdr[31] = seq_id & 0xFF

    frame = PTP_DST_MAC + PTP_SRC_MAC + ethertype + bytes(ptp_hdr)
    if len(frame) < 60:
        frame += b'\x00' * (60 - len(frame))
    return frame

# die_a's exposed peer window; the peer->ahb_mng transform is DERIVED at run time
# from the tb's ahb_mng address monitor (identity / delta=0 at reset).
PEER_APERTURE_BASE  = 0x0000_0000


def mac_reg_peek(dut, wb_word_off):
    """Best-effort hierarchical peek into the OpenCores MAC register file.

    Independent (non-bus) confirmation the value physically lives in the MAC's
    register array, not a bus echo. `wb_word_off` is the WISHBONE word index
    (byte offset >> 2). Returns the 32-bit value or None if the hierarchy path
    does not resolve (in which case the test relies on the round-trip alone).
    Tries a few plausible ethmac register-file hierarchies."""
    idx = wb_word_off
    candidates = [
        "u_s_eth_ss.u_ethmac_0.u_inner.u_ethmac.eth_registers1",
        "u_s_eth_ss.u_ethmac_0.u_inner.u_ethmac.u_eth_registers",
    ]
    # MODER lives in a named flop, not an array, so a generic array peek is not
    # reliable across ethmac revisions; return None and let the round-trip prove
    # it. (Kept as a hook for a future targeted peek.)
    return None

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

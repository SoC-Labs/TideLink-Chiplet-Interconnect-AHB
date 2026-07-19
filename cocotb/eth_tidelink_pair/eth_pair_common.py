"""Helpers for the Ethernet-over-TideLink M0 smoke.

Re-uses the pair_v2 bench verbatim (both dirs are on PYTHONPATH via the
Makefile): the two-die bring-up (`PairV2TB`, `run_bringup_full`) and the
peer-window AHB-Lite master (`AHBSubMaster`) that drives `m_ahb_sub_*`. This
module adds only what is ethernet-specific: a small frame builder and a
hierarchical peek into the die_b ethernet-scratch SRAM (`nanosoc_region_sram`
-> `sl_ahb_sram` -> `cmsdk_fpga_sram`, byte-split across BRAM0..BRAM3).
"""
from pair_v2_common import PairV2TB, run_bringup_full          # noqa: F401
from test_v2_xhb_window import AHBSubMaster                     # noqa: F401


# ---------------------------------------------------------------------------
# Peer aperture + eth-scratch geometry
# ---------------------------------------------------------------------------
# die_a's peer window base (identity address translation at reset, so the low
# bits reach die_b's ahb_mng unchanged). The eth-scratch terminus (RAM_ADDR_W
# =14 => 16 KB) decodes HADDR[13:2], ignoring the aperture bits, so any small
# word-aligned offset selects word (off>>2).
PEER_APERTURE_BASE = 0x4000_0000
ETH_SCRATCH_RX_OFF = 0x0040        # a "received-frame" landing offset in scratch


def make_eth_frame(nwords=16, seed=0xE7):
    """A deterministic frame-like burst (default 16 words = 64 B, min ethernet
    frame). Word 0/1/2 mimic an ARP-request header (broadcast dest MAC, a src
    MAC, ethertype 0x0806); the rest is a checkerboard payload. Byte-exactness
    of the whole burst is what M0 proves — the exact framing is illustrative."""
    frame = [
        0xFFFFFFFF,              # dest MAC [47:16] (broadcast)
        0xFFFF0200,              # dest MAC [15:0]=FFFF | src MAC [47:32]=0x0200
        0x00000001,              # src MAC [31:0]
        0x08060001,              # ethertype 0x0806 (ARP) | HTYPE hi
    ]
    for i in range(len(frame), nwords):
        frame.append(((seed + i) * 0x01010101) & 0xFFFFFFFF)
    return frame[:nwords]


def eth_scratch_peek(dut, off, side="s"):
    """Reconstruct the 32-bit word stored at byte-offset `off` in a die's
    ethernet-scratch SRAM, reading the four byte-lane BRAMs of cmsdk_fpga_sram
    directly. Diagnostic only (independent proof the data landed in the ETH
    component, not just an AHB echo). Returns the word or None if the
    hierarchy/index cannot be resolved."""
    inst = "u_s_eth_scratch" if side == "s" else "u_m_eth_scratch"
    idx = off >> 2
    try:
        sram = getattr(dut, inst).u_sram.u_sram      # nanosoc_region_sram -> sl_ahb_sram -> cmsdk_fpga_sram
        b0 = int(sram.BRAM0[idx].value) & 0xFF
        b1 = int(sram.BRAM1[idx].value) & 0xFF
        b2 = int(sram.BRAM2[idx].value) & 0xFF
        b3 = int(sram.BRAM3[idx].value) & 0xFF
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    except Exception:
        return None

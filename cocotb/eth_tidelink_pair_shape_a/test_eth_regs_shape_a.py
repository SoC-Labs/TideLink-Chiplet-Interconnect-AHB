"""Ethernet-over-TideLink SHAPE-A — reach MAC + HA1588 REGISTERS across the link.

The M2 register-visibility prerequisite for the PTP grandmaster chain. Where the
M1 bench relayed a frame into eth_scratch_rx (0x3000_0000), this bench drives a
link-crossed access to a register INSIDE the ethernet MAC (0x4000_0000) and the
HA1588 PTP block (0x4000_1000), through the SAME eth_ss_0 attach — the
subsystem's OWN AHB matrix routes eth_ss_0 to ethmac_0 (port-visibility matrix;
README FINDING 1), so no full multicore SoC / d2d_ahb_s is needed.

    die_a peer window (ahb_sub) @ 0x4000_0000 / 0x4000_1004
      -> XHB500 AHB->AXI -> chiplet controller -> FC -> link -> die_b
      -> die_b XHB500 AXI->AHB -> die_b ahb_mng (presents addr T)
      -> ethernet_ss_ahb.eth_ss_0 -> eth_ss_ahb_interconnect (matrix decode)
      -> u_ethmac_0 -> cmsdk_ahb_to_apb -> ethmac_subsystem_apb
           paddr[15:12]==0 -> OpenCores MAC   (MODER @ 0x00, reset 0xA000)
           paddr[15:12]==1 -> HA1588 PTP      (SCRATCH @ 0x1004, RW)

TEST (byte-exact both directions of the link):
  A. READ a known-constant across the link: MAC MODER == 0x0000_A000 (its HARD
     RESET value; the far die read direction die_b->die_a). Plus PACKETLEN /
     MIIMODER / TX_BD_NUM golden-reset reads for good measure.
  B. WRITE + READBACK a scratch-safe RW register: HA1588 SCRATCH (0x4000_1004).
     JUSTIFICATION for scratch-safety: ha1588.yaml documents SCRATCH as a
     "general-purpose scratch register for software use" with NO hardware side
     effects (unlike HA1588 RTC_CTRL @ +0x1000, whose bits are self-clearing
     pulse actions that reset RTC counters / load time). Writing SCRATCH cannot
     perturb the RTC, the MAC, or any datapath. Exercised die_a->die_b (write)
     then die_a<-die_b (readback), both across the link.

Run:
    cd cocotb/eth_tidelink_pair_shape_a
    source ../../set_env.sh
    source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
    export TIDELINK_PHY_V2=1
    make                       # EPOCH_PROFILE=zero -> THE SHAPE-A GATE
"""
import cocotb
from cocotb.triggers import ClockCycles

from eth_pair_common import (
    PairV2TB, run_bringup_full, EthAHBSubMaster,
    ETH_SCRATCH_RX_BASE, ETHMAC_BASE, MAC_BASE, HA1588_BASE,
    MAC_MODER, MAC_PACKETLEN, MAC_MIIMODER, MAC_TX_BD_NUM,
    MAC_MODER_RESET, MAC_PACKETLEN_RESET, MAC_MIIMODER_RESET, MAC_TX_BD_NUM_RESET,
    HA1588_SCRATCH,
)

SETTLE = 4000


def _u(sig):
    try:
        return int(sig.value)
    except ValueError:
        return -1


@cocotb.test()
async def test_eth_regs_shape_a(dut):
    """die_a reaches MAC MODER (read-const) + HA1588 SCRATCH (write/readback)
    across the TideLink pair, through the ethernet subsystem's own AHB matrix."""
    tb = PairV2TB(dut)
    m_ahb = EthAHBSubMaster(dut)

    # --- 1. Bring the V2 pair link up + wait bilateral CR/CRACK. --------------
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("[shapeA] link up (cal+CR/CRACK); eth subsystem behind die_b ahb_mng")

    # --- 2. DERIVE the peer-window -> ahb_mng transform (identity at reset). ---
    #     Probe with a WRITE into eth_scratch_rx (harmless, and avoids the X-init
    #     read-before-write stall the M1 bench documented). The tb monitor latches
    #     the address die_b's ahb_mng presented, giving delta.
    probe_peer = ETH_SCRATCH_RX_BASE + 0x100
    await m_ahb.write(probe_peer, 0xA5A50100)
    await ClockCycles(dut.hclk, 5)
    observed = _u(dut.s_mng_haddr_seen)
    delta = (observed - probe_peer) & 0xFFFF_FFFF
    tb.log.info(f"[shapeA] MEMORY-MAP DERIVATION: peer 0x{probe_peer:08x} -> "
                f"ahb_mng presented 0x{observed:08x}  (delta=0x{delta:08x}; "
                f"{'IDENTITY' if delta == 0 else 'FIXED-OFFSET window'})")

    def peer_for(target):
        return (target - delta) & 0xFFFF_FFFF

    fails = []

    # --- 3A. READ known-constant registers across the link. -------------------
    #     MAC MODER is the identity/mode reg; its HARD RESET value 0xA000 is a
    #     defined constant (NOT X-init), so reading it cold proves a genuine
    #     register read across the link (no prior write). Region check first.
    obs_region = ("ethmac" if ETHMAC_BASE <= observed + (MAC_BASE - probe_peer) else "?")
    tb.log.info(f"[shapeA] MAC aperture peer addr for MODER (0x{MAC_MODER:08x}) "
                f"= 0x{peer_for(MAC_MODER):08x}")

    id_reads = [
        ("MODER",     MAC_MODER,     MAC_MODER_RESET),
        ("PACKETLEN", MAC_PACKETLEN, MAC_PACKETLEN_RESET),
        ("MIIMODER",  MAC_MIIMODER,  MAC_MIIMODER_RESET),
        ("TX_BD_NUM", MAC_TX_BD_NUM, MAC_TX_BD_NUM_RESET),
    ]
    for name, addr, golden in id_reads:
        got = await m_ahb.read(peer_for(addr))
        ok = (got == golden)
        tb.log.info(f"  [shapeA] READ  MAC.{name:9s} @0x{addr:08x} "
                    f"(peer 0x{peer_for(addr):08x}) = 0x{got:08x}  "
                    f"golden=0x{golden:08x}  {'OK' if ok else 'MISMATCH'}")
        if not ok:
            fails.append((f"MAC.{name} read-const", addr, golden, got))

    # --- 3B. WRITE + READBACK a scratch-safe RW register (HA1588 SCRATCH). -----
    #     Reaches the HA1588 PTP block (+0x1000) directly. SCRATCH has no side
    #     effects (see module docstring JUSTIFICATION). X-init, so write first.
    save = None  # SCRATCH is X-init; nothing to preserve/restore.
    rw_patterns = [0xDEADBEEF, 0xCAFEBABE, 0xA5A5A5A5, 0x5A5A5A5A, 0x00000000, 0xFFFFFFFF]
    for pat in rw_patterns:
        await m_ahb.write(peer_for(HA1588_SCRATCH), pat)
        await ClockCycles(dut.hclk, SETTLE)
        got = await m_ahb.read(peer_for(HA1588_SCRATCH))
        ok = (got == pat)
        tb.log.info(f"  [shapeA] W/RB HA1588.SCRATCH @0x{HA1588_SCRATCH:08x} "
                    f"(peer 0x{peer_for(HA1588_SCRATCH):08x}) wrote=0x{pat:08x} "
                    f"read=0x{got:08x}  {'OK' if ok else 'MISMATCH'}")
        if not ok:
            fails.append(("HA1588.SCRATCH write/readback", HA1588_SCRATCH, pat, got))

    # --- 4. Verdict. ----------------------------------------------------------
    assert not fails, (
        "SHAPE-A ethernet register access FAILED (MAC + HA1588 via eth_ss_0):\n"
        f"  memory-map: delta=0x{delta:08x}\n" +
        "\n".join(f"  {why}: @0x{a:08x} expected=0x{e:08x} got=0x{g:08x}"
                  for why, a, e, g in fails))

    tb.log.info("[shapeA] PASS: read MAC MODER/PACKETLEN/MIIMODER/TX_BD_NUM "
                "known-constants AND write/readback HA1588 SCRATCH across the "
                "TideLink pair -- a register INSIDE the MAC and inside HA1588 is "
                "reachable via eth_ss_0 through the subsystem AHB matrix "
                "(narrow Shape-A; no full multicore SoC needed).")

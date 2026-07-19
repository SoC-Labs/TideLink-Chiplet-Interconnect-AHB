"""Ethernet-over-TideLink M1 relay — real `ethernet_ss_ahb` behind ahb_mng.

M1 first substep of docs/ETHERNET_CHIPLET_INTEGRATION.md (and the M0 README's
"Next steps" #1): swap the M0 single-slave scratch RAM for the WHOLE ethernet
subsystem, attached to die_b's ahb_mng through its external AHB slave port
`eth_ss_0`. A frame written into die_a's peer window now transits the
subsystem's OWN AHB matrix (eth_ss_interconnect) into eth_scratch_rx
(0x3000_0000) — exercising the real matrix hready / hprot[3:0] / hsize / burst
bus contract that the M0 zero-wait BRAM could not.

    die_a peer window (ahb_sub) WRITE @ T - delta
      -> XHB500 AHB->AXI -> chiplet controller -> FC -> link -> die_b
      -> die_b XHB500 AXI->AHB -> die_b ahb_mng (presents addr T)
      -> ethernet_ss_ahb.eth_ss_0 -> eth_ss_interconnect (matrix decode)
      -> u_region_eth_scratch_rx_0 (eth_scratch_rx @ 0x3000_0000)
    READ-back @ the same peer addr returns the frame byte-exact, and a
    hierarchical peek into the eth_scratch_rx BRAMs confirms it landed in the
    subsystem's scratch (not a bus echo / not the MAC region).

`delta` is the peer-window -> ahb_mng address transform, DERIVED empirically at
run time from the tb's ahb_mng address monitor (s_mng_haddr_seen) so the test
targets eth_scratch_rx by construction rather than by assumption.

Run:
    cd cocotb/eth_tidelink_pair_m1
    source ../../set_env.sh
    source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
    export TIDELINK_PHY_V2=1
    make                       # EPOCH_PROFILE=zero -> THE M1 GATE
"""
import cocotb
from cocotb.triggers import ClockCycles

from eth_pair_common import (PairV2TB, run_bringup_full, EthAHBSubMaster,
                             make_eth_frame, eth_scratch_rx_peek,
                             ETH_SCRATCH_RX_BASE, ETH_SCRATCH_RX_OFF, ETHMAC_BASE)

WRITE_SETTLE = 8000
NWORDS = 16          # 64 B = minimum ethernet frame


def _u(sig):
    try:
        return int(sig.value)
    except ValueError:
        return -1


async def _probe_transform(tb, dut, m_ahb, peer_addr):
    """Drive one WRITE at `peer_addr` and read back the address die_b's ahb_mng
    presented to eth_ss_0 (captured by the tb monitor) to DERIVE the transform.
    Returns (observed_addr, delta) where observed = peer_addr + delta.

    A WRITE (not a read) is used deliberately: the cmsdk_fpga_sram eth_scratch_rx
    model is X-initialised (vendor-SRAM-faithful, not zero-init), so READING an
    UNWRITTEN scratch word returns X, and that X rides the XHB500 AXI R-channel
    back onto die_a's hreadyout, stalling the round-trip. Writes carry no
    read-data, complete cleanly, AND initialise the probed word. (This is the
    same X-init trait noted in the tapeout memory — read-before-write on scratch
    is undefined; the relay always writes before it reads.)"""
    await m_ahb.write(peer_addr, 0xA5A50100)
    await ClockCycles(dut.hclk, 5)
    observed = _u(dut.s_mng_haddr_seen)
    delta = (observed - peer_addr) & 0xFFFF_FFFF
    return observed, delta


@cocotb.test()
async def test_eth_relay_m1(dut):
    """die_a peer-window frame -> die_b ethernet_ss_ahb eth_scratch_rx, byte-exact."""
    tb = PairV2TB(dut)
    m_ahb = EthAHBSubMaster(dut)

    # --- 1. Bring the V2 pair link up + wait bilateral CR/CRACK. --------------
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("[m1] link up (cal+CR/CRACK); eth subsystem behind die_b ahb_mng")

    # --- 2. DERIVE the peer-window -> ahb_mng address transform. --------------
    #     Probe with an address that (under identity) lands in eth_scratch_rx.
    probe_peer = ETH_SCRATCH_RX_BASE + 0x100
    observed, delta = await _probe_transform(tb, dut, m_ahb, probe_peer)
    tb.log.info(f"[m1] MEMORY-MAP DERIVATION: peer 0x{probe_peer:08x} -> "
                f"ahb_mng presented 0x{observed:08x}  (delta=0x{delta:08x}; "
                f"{'IDENTITY' if delta == 0 else 'FIXED-OFFSET window'})")
    obs_region = ("eth_scratch_rx" if ETH_SCRATCH_RX_BASE <= observed < ETH_SCRATCH_RX_BASE + 0x0800_0000
                  else "ethmac" if ETHMAC_BASE <= observed < ETHMAC_BASE + 0x0800_0000
                  else "OTHER/undecoded")
    tb.log.info(f"[m1] ahb_mng address decodes into subsystem region: {obs_region}")

    # peer address that makes ahb_mng present target T (in eth_scratch_rx).
    def peer_for(target):
        return (target - delta) & 0xFFFF_FFFF

    # --- 3. Relay a 16-word frame into eth_scratch_rx via the peer window. ----
    frame = make_eth_frame(NWORDS)
    for i, w in enumerate(frame):
        target = ETH_SCRATCH_RX_BASE + ETH_SCRATCH_RX_OFF + i * 4
        await m_ahb.write(peer_for(target), w)
    tb.log.info(f"[m1] wrote {NWORDS}-word frame -> eth_scratch_rx "
                f"0x{ETH_SCRATCH_RX_BASE + ETH_SCRATCH_RX_OFF:08x}+ "
                f"(peer 0x{peer_for(ETH_SCRATCH_RX_BASE + ETH_SCRATCH_RX_OFF):08x}+)")

    # Report the bus contract die_b's ahb_mng actually drove into the matrix.
    tb.log.info(f"[m1] eth_ss_0 BUS CONTRACT observed on ahb_mng: "
                f"htrans={_u(dut.s_mng_htrans_seen)} hsize={_u(dut.s_mng_hsize_seen)} "
                f"hburst={_u(dut.s_mng_hburst_seen)} hwrite={_u(dut.s_mng_hwrite_seen)} "
                f"(hburst=0 => SINGLE-beat; the AHBSubMaster + XHB path emits "
                f"single NONSEQ transfers — a finding, not a failure)")
    await ClockCycles(dut.hclk, WRITE_SETTLE)

    # --- 4. Verify byte-exact: peer-window round-trip + eth_scratch_rx peek. --
    fails = []
    for i, w in enumerate(frame):
        target = ETH_SCRATCH_RX_BASE + ETH_SCRATCH_RX_OFF + i * 4
        got  = await m_ahb.read(peer_for(target))
        peek = eth_scratch_rx_peek(dut, target)
        peek_s = "n/a" if peek is None else f"0x{peek:08x}"
        tb.log.info(f"  [m1] w{i:2d} T=0x{target:08x} sent=0x{w:08x} "
                    f"read=0x{got:08x} eth_scratch_rx[{(target & 0x3FFF) >> 2}]={peek_s}")
        if got != w:
            fails.append((i, target, w, got, peek, "round-trip"))
        elif peek is None:
            fails.append((i, target, w, got, peek, "peek-unresolved"))
        elif peek != w:
            fails.append((i, target, w, got, peek, "peek-mismatch"))

    assert not fails, (
        "M1 ethernet frame relay FAILED (real ethernet_ss_ahb via eth_ss_0):\n"
        f"  memory-map: delta=0x{delta:08x}, ahb_mng region={obs_region}\n" +
        "\n".join(
            f"  w{i} T=0x{t:08x} sent=0x{s:08x} read=0x{g:08x} "
            f"scratch={'n/a' if p is None else f'0x{p:08x}'} [{why}]"
            for i, t, s, g, p, why in fails))

    tb.log.info(f"[m1] PASS: {NWORDS}/{NWORDS}-word frame relayed die_a peer "
                f"window -> link -> die_b ethernet_ss_ahb matrix -> eth_scratch_rx, "
                f"byte-exact (round-trip + hierarchical peek).")

"""Bug N11 sim repro — peer-mask read fidelity probe.

Silicon symptom (build v11, 2026-06-02 z2_02/z2_03 asymmetric-POR deploy):
    Direct APB probe of `0x44032214` returns 0x544C_0100 ("TL\\x01\\x00"
    TideLink magic) on BOTH dies, not the expected `swi_rx/tx_lane_mask`
    default `0x0000FFFF`. The user hypothesised Wlink's APB read mux is
    stubbing the lane_mask register the same way Bug N9 found
    `mask_hs_result_o = 2'b00` stubbed at Wlink.v:210.

Root-cause finding (this investigation):
    Wlink lives at SoC base `0x4403_0xxx` (apb_paddr[14:13]==00 →
    apb_sel_wlink, see tidelink_top.sv:652). The TideLink-config
    `tidelink_apb_regs` block lives at `0x4403_2xxx` (apb_paddr[14:13]==
    01 → apb_sel_tidelink). The user's probe address `0x44032214` lands
    in TideLink-config region 0 slot 5, which `tidelink_apb_regs.sv:492`
    intentionally returns as the `0x544C_0100` peripheral-ID magic.
    Wlink's REAL lane_mask register is at `0x4403_0214`. So the
    "lane_mask returns magic" report is a SW-probe-address bug, not an
    RTL stub.

    The autoneg FSM does NOT use the SoC-level paddr at all — its I²C
    bridge produces a 13-bit `slv_apb_paddr` that feeds the chiplet
    controller's slv_apb_to_wlink mux (see axi_chiplet_controller.sv:
    1607). For MSB=0x02/LSB=0x14 the bridge forms slv_apb_paddr=0x0214
    which lands directly inside Wlink (no SoC region decoder
    involvement). The TideLink-config aliasing therefore cannot poison
    the FSM's peer-mask read.

Test contract
-------------
1. POR both dies with BYPASS_AUTONEG=0.
2. After hresetn rises but before the master's NEGO_MASK_RD_DATA fires,
   force the SLAVE's `swi_tx_lane_mask = 8'hAA` (Wlink reg path:
   `u_slave.u_chiplet_controller.u_wlink.swi_tx_lane_mask`). Default is
   8'hFF so 0xAA is unambiguously distinguishable.
3. Wait until the master's autoneg FSM reaches the comparator-latching
   transition (`ST_NEGO_MASK_RES_TX → ST_NEGO_DONE`).
4. Read back `u_master.u_chiplet_controller.u_autoneg.peer_tx_lane_mask_r`
   (the byte the FSM captured from peer's link_lane_mask @ 0x214 byte 0).
5. Assert == 0xAA. If Wlink's mux returned magic the FSM would have
   captured 0x4C (TL_ID byte 1) instead.

Expected outcome
----------------
PASS — sim Wlink mux is not stubbed; peer_tx_lane_mask_r == 0xAA.

This confirms the FSM's read path is functionally correct and the
silicon-observed magic is a SW-side probe-address bug only. No RTL
change required for the lane_mask read path itself; the SW oracle in
`pynq_host/scripts/*` should probe `0x4403_0214` not `0x4403_2214`.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_21_bug_n11_mask_read_wrong_offset \\
        make MODULE=test_21_bug_n11_mask_read_wrong_offset
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotb.handle import Force


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

ST_NAMES = {
    0:  "ST_IDLE", 1: "ST_NEGO_INIT", 2: "ST_NEGO_WAIT", 3: "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL", 5: "ST_NEGO_DONE", 6: "ST_BYPASS", 7: "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX", 9: "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA", 11: "ST_NEGO_DONE_PRE", 12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN", 14: "ST_TRAIN_POLL_PEER", 15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE", 17: "ST_TRAIN_FAIL",
}

ST_NEGO_MASK_RD_DATA = 10
ST_NEGO_MASK_RES_TX  = 8
ST_NEGO_DONE_PRE     = 11
ST_TRAIN_ENTER       = 12
ST_TRAIN_DONE        = 16


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _wlink(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink


def _state_name(s):
    return ST_NAMES.get(s, f"ST_?({s})")


async def wait_for_state(dut, side, targets, max_cycles, poll=200):
    if isinstance(targets, int):
        targets = {targets}
    else:
        targets = set(targets)
    an = _autoneg(dut, side)
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        s = _safe_int(an.state_r)
        if s in targets:
            return s, waited
    return -1, waited


@cocotb.test()
async def test_21_bug_n11_mask_read_wrong_offset(dut):
    """Force slave's Wlink swi_tx_lane_mask to a non-default sentinel,
    then verify the master's autoneg FSM captures that sentinel via the
    I²C peer-mask read."""
    log = dut._log
    log.info("Bug N11 sim repro — peer-mask read fidelity probe")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    # ── Reset ────────────────────────────────────────────────────────
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Wait past the tb_top BYPASS_AUTONEG=0 force-release window (#5000 ns
    # initial-block) before applying our own forces.
    await ClockCycles(dut.hclk, 400)

    # ── Force slave's Wlink swi_tx_lane_mask to 8'hAA ───────────────
    # Using cocotb's Verilog $force action keeps the value stable across
    # the entire mask-handshake window. The default after POR is 8'hFF
    # (Wlink.v:2141), so 0xAA is unambiguously not the reset value AND
    # not the TL_ID magic bytes (0x54='T', 0x4C='L'). The slave is the
    # autoneg LOSER (priority=0x0002 vs master 0x0001), so the master is
    # the one that runs ST_NEGO_MASK_RD_DATA and captures the slave's
    # mask as peer_tx_lane_mask_r. The slave never overwrites our force
    # because its own POR assignment to 8'hFF already fired (we're well
    # past hresetn-rise + a few hundred cycles).
    SENTINEL_TX = 0xAA
    SENTINEL_RX = 0x55
    _wlink(dut, "s").swi_tx_lane_mask.set(Force(SENTINEL_TX))
    _wlink(dut, "s").out_prepend_swi_rx_lane_mask.set(Force(SENTINEL_RX))
    # Mirror the same forces on master so the comparator (which uses
    # local masks against captured peer masks) still has a chance of
    # matching after our perturbation. Specifically master's comparator
    # latches `mask_match_w` = (local_tx == peer_rx) && (local_rx ==
    # peer_tx). With sentinels:
    #   local_tx_m = peer_rx_s = SENTINEL_RX (rx mask of slave)
    #   local_rx_m = peer_tx_s = SENTINEL_TX (tx mask of slave)
    # so master's local_tx must = SENTINEL_RX, local_rx must = SENTINEL_TX.
    _wlink(dut, "m").swi_tx_lane_mask.set(Force(SENTINEL_RX))
    _wlink(dut, "m").out_prepend_swi_rx_lane_mask.set(Force(SENTINEL_TX))
    log.info(
        f"Forced slave swi_tx_lane_mask=0x{SENTINEL_TX:02x} "
        f"swi_rx_lane_mask=0x{SENTINEL_RX:02x}; mirrored on master."
    )

    # ── Wait for master to reach ST_NEGO_MASK_RD_DATA (state 10) ─────
    log.info("Waiting for master to enter ST_NEGO_MASK_RD_DATA...")
    s, w = await wait_for_state(
        dut, "m", {ST_NEGO_MASK_RD_DATA}, max_cycles=5_000_000
    )
    log.info(
        f"Master MASK_RD_DATA entry: matched={s}({_state_name(s)}) "
        f"after {w} cy ({w * CLK_PERIOD_NS / 1000:.1f} us)"
    )
    assert s == ST_NEGO_MASK_RD_DATA, (
        f"Master never reached ST_NEGO_MASK_RD_DATA — "
        f"final state={s}({_state_name(s)}). Autoneg likely stalled "
        f"earlier (CLAIM/POLL miss). Cannot test mask-read fidelity."
    )

    # ── Wait for ST_NEGO_MASK_RES_TX (state 8) on master, then read ──
    # peer_*_lane_mask_r is latched in the rd-data TXN_DATA loop before
    # the state transitions to MASK_RES_TX (autoneg.sv:842-847).
    log.info("Waiting for master to enter ST_NEGO_MASK_RES_TX...")
    s, w = await wait_for_state(
        dut, "m", {ST_NEGO_MASK_RES_TX}, max_cycles=2_000_000
    )
    log.info(
        f"Master MASK_RES_TX entry: matched={s}({_state_name(s)}) "
        f"after {w} cy ({w * CLK_PERIOD_NS / 1000:.1f} us)"
    )
    assert s == ST_NEGO_MASK_RES_TX, (
        f"Master never reached ST_NEGO_MASK_RES_TX from MASK_RD_DATA — "
        f"final state={s}({_state_name(s)}). Mask-read FIFO drain may "
        f"have hung."
    )

    # Snapshot the captured peer masks. Both bytes must reflect the
    # sentinels we forced into the slave's Wlink swi_*_lane_mask regs.
    m_an = _autoneg(dut, "m")
    peer_tx = _safe_int(m_an.peer_tx_lane_mask_r) & 0xFF
    peer_rx = _safe_int(m_an.peer_rx_lane_mask_r) & 0xFF
    mask_match = _safe_int(m_an.mask_hs_local_match_r)
    mask_fail  = _safe_int(m_an.mask_hs_local_fail_r)
    log.info(
        f"Master captured peer_tx=0x{peer_tx:02x} peer_rx=0x{peer_rx:02x} "
        f"mask_match_r={mask_match} mask_fail_r={mask_fail}"
    )

    # ── Verdict ──────────────────────────────────────────────────────
    # If Wlink's APB read mux were stubbing 0x214 to the TL_ID magic,
    # peer_tx would be 0x4C (low byte of magic) or 0x00 (if the 4-byte
    # rd captured zeros instead). The sentinel readback is THE
    # discriminator: pass means I²C → Wlink path is faithful.
    assert peer_tx == SENTINEL_TX, (
        f"Bug N11 RTL repro: master captured peer_tx=0x{peer_tx:02x}, "
        f"expected 0x{SENTINEL_TX:02x}. Wlink's APB read mux is "
        f"returning the wrong value at slot 0 (link_lane_mask @ "
        f"paddr[7:2]=5). If the captured byte is 0x4C or 0x54, Wlink "
        f"is leaking TL_ID magic into out_prepend_1."
    )
    assert peer_rx == SENTINEL_RX, (
        f"Bug N11 RTL repro: master captured peer_rx=0x{peer_rx:02x}, "
        f"expected 0x{SENTINEL_RX:02x} (byte 1 of link_lane_mask)."
    )

    # Core check above (peer_tx/peer_rx == sentinels) confirms Wlink's
    # APB read mux at link_lane_mask offset is NOT stubbed: the I²C
    # peer-mask read pulled back the exact bytes we forced into the
    # slave's Wlink regs. That is the discriminating Bug-N11 evidence.
    #
    # We deliberately do NOT assert on mask_hs_local_match_r here — that
    # latch fires only on the MASK_RES_TX → ST_NEGO_DONE transition
    # (autoneg.sv:465-468). With nego_force_lock=1 (autonomous path,
    # BYPASS_AUTONEG=0) the FSM walks MASK_RES_TX → ST_NEGO_DONE_PRE →
    # ST_TRAIN_ENTER and SKIPS ST_NEGO_DONE, so the comparator-latch
    # never fires. That's an orthogonal observation worth a separate
    # docs note but outside Bug N11's scope.

    log.info(
        "PASS: master correctly captured forced sentinels "
        f"(peer_tx=0x{peer_tx:02x}, peer_rx=0x{peer_rx:02x}) — "
        "Wlink APB read mux for link_lane_mask is not stubbed. "
        "Silicon-observed 0x544C_0100 at 0x44032214 is a SW probe "
        "aperture bug (should be 0x44030214 for Wlink)."
    )

"""HW-mirror reproduction — Angle 1: drive bench writes through APB.

Agent #4 attempt to reproduce the HW failure described in
project_tidelink_i2c_autonomy.md.

Unlike cocotb/wlink_pair/test_hw_repro_full.py which pokes the chiplet's
ctrl_reg_write/addr/wdata port directly, this test issues APB writes to
the full tidelink_top wrapper. Those APB writes flow through:

    apb_psel/paddr/penable  →  tidelink_top apb_sel_tidelink mux  →
    tidelink_fifo.u_apb_regs  →  ctrl_reg_write (region==100)  →
    axi_chiplet_controller.ctrl_reg_*

This mirrors the real silicon path that PYNQ /dev/mem writes follow.

Register map (matches deploy_pair.sh + nego_probe_fast.py):

  TL = 0x44032000 (base of axi_apb / tidelink_top external APB port)
  Within the chiplet, paddr = local-offset (15 bits, BD truncates 32→15):
    0x00 = PAIR_BASE_ADDR  (Region 0, addr 0)
    0x80 = ROLE_CFG        (Region 4, addr 0)
    0x88 = I2C_SLV_ADDR    (Region 4, addr 2)
    0x8C = I2C_PRESCALE    (Region 4, addr 3)
    0x90 = NEGO_CFG        (Region 4, addr 4)
    0x94 = NEGO_STATUS     (Region 4, addr 5, RO)
    0x98 = NEGO_PRIORITY   (Region 4, addr 6)
    0x9C = NEGO_TIMEOUT    (Region 4, addr 7)

  PYNQ also writes to 0x44030000 (Wlink region): paddr[14:13]==00 → Wlink.
    0x00       = swi_phase_offset
    0x208      = swreset toggle bits

paddr decode in tidelink_top:
    paddr[14:13] == 00  → apb_sel_wlink     (Wlink region)
    paddr[14:13] == 01  → apb_sel_tidelink  (TideLink/PTP/Region 4)
    paddr[14:13] == 10  → apb_sel_addr_xlat (address translator)

Bench's TL=0x44032000 within axi_apb base 0x44030000 → paddr=0x2000.
TL+0x80 → paddr=0x2080 → paddr[14:13]=01 (tidelink) → apb_regs decodes
paddr[7:5]=100 (Region 4), paddr[4:2]=0 (addr=0=ROLE_CFG) ✓.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


# Wlink region (paddr[14:13]=00)
WL_PHY_CTRL   = 0x0000
WL_SWRESET    = 0x0208

# TideLink/Chiplet-controller region (paddr[14:13]=01)
TL_PAIR_BASE  = 0x2000
TL_ROLE_CFG   = 0x2080
TL_I2C_PRESCALE = 0x208C
TL_NEGO_CFG   = 0x2090
TL_NEGO_STATUS= 0x2094
TL_NEGO_PRIORITY = 0x2098

# nego_probe_fast.py / deploy_pair.sh constants
PHY_CTRL_MASTER   = 0x00000000
PHY_CTRL_SLAVE    = 0x00060000
WL_SWRESET_ASSERT = 0x00027F08
WL_SWRESET_RELS   = 0x00027F00
WL_SWRESET_REENA  = 0x00027F07
ROLE_CFG_MASTER   = 0x2     # lock=1, role_cfg=0
ROLE_CFG_SLAVE    = 0x3     # lock=1, role_cfg=1
PAIR_BASE_VAL     = 0x44032000
NEGO_CFG_HW       = 0x61
PRESCALE_HW       = 200
PRIO_MASTER_HW    = 1
PRIO_SLAVE_HW     = 0xFFFF


async def _setup(dut):
    """Bring up clock + POR with mask_hs_bypass=1 (matches BD xlconst)."""
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())  # 50 MHz
    dut.m_apb_psel.value = 0
    dut.m_apb_penable.value = 0
    dut.m_apb_pwrite.value = 0
    dut.m_apb_paddr.value = 0
    dut.m_apb_pwdata.value = 0
    dut.s_apb_psel.value = 0
    dut.s_apb_penable.value = 0
    dut.s_apb_pwrite.value = 0
    dut.s_apb_paddr.value = 0
    dut.s_apb_pwdata.value = 0
    # Match BD xlconst (mask_hs_bypass=1)
    dut.m_mask_hs_bypass.value = 1
    dut.s_mask_hs_bypass.value = 1
    # Straps fixed at instantiation (master=0, slave=1) — no need to touch.
    dut.poresetn.value = 0
    dut.hresetn.value = 0
    await ClockCycles(dut.clk, 10)
    dut.poresetn.value = 1
    dut.hresetn.value = 1
    await ClockCycles(dut.clk, 10)


async def _apb_write(dut, side, addr, data, max_wait=64):
    """Issue a full APB write to the chiplet's external apb port. Mirrors
    the AXI-to-APB bridge protocol the BD's axi_apb generates."""
    psel  = getattr(dut, f"{side}_apb_psel")
    pen   = getattr(dut, f"{side}_apb_penable")
    pwr   = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwd   = getattr(dut, f"{side}_apb_pwdata")
    pready= getattr(dut, f"{side}_apb_pready")
    # Setup phase: psel high, penable low
    await RisingEdge(dut.clk)
    psel.value = 1
    pen.value = 0
    pwr.value = 1
    paddr.value = addr & 0x7FFF      # 15-bit
    pwd.value = data
    # Access phase: assert penable, wait for pready
    await RisingEdge(dut.clk)
    pen.value = 1
    for _ in range(max_wait):
        await RisingEdge(dut.clk)
        if int(pready.value):
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0


async def _apb_read(dut, side, addr, max_wait=64):
    """Issue a full APB read; return rdata as int."""
    psel  = getattr(dut, f"{side}_apb_psel")
    pen   = getattr(dut, f"{side}_apb_penable")
    pwr   = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pready= getattr(dut, f"{side}_apb_pready")
    prdata= getattr(dut, f"{side}_apb_prdata")
    await RisingEdge(dut.clk)
    psel.value = 1
    pen.value = 0
    pwr.value = 0
    paddr.value = addr & 0x7FFF
    await RisingEdge(dut.clk)
    pen.value = 1
    val = 0
    for _ in range(max_wait):
        await RisingEdge(dut.clk)
        if int(pready.value):
            val = int(prdata.value)
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0
    return val


def _snap(dut, tag):
    m_st = int(dut.u_master.u_chiplet_controller.u_autoneg.nego_state.value)
    s_st = int(dut.u_slave.u_chiplet_controller.u_autoneg.nego_state.value)
    busy_seen = int(dut.u_master.u_chiplet_controller.u_autoneg.busy_seen_r.value)
    txn_step = int(dut.u_master.u_chiplet_controller.u_autoneg.txn_step_r.value)
    m_scl_t = int(dut.m_i2c_scl_t.value)
    m_scl_o = int(dut.m_i2c_scl_o.value)
    m_sda_t = int(dut.m_i2c_sda_t.value)
    m_sda_o = int(dut.m_i2c_sda_o.value)
    dut._log.info(
        "[%s] m: state=%d txn=%d busy_seen=%d locked=%d is_mst=%d "
        "scl_t=%d scl_o=%d sda_t=%d sda_o=%d | s: state=%d locked=%d "
        "is_mst=%d | bus scl=%d sda=%d",
        tag, m_st, txn_step, busy_seen,
        int(dut.m_role_locked.value), int(dut.m_role_is_master.value),
        m_scl_t, m_scl_o, m_sda_t, m_sda_o,
        s_st, int(dut.s_role_locked.value), int(dut.s_role_is_master.value),
        int(dut.i2c_scl.value), int(dut.i2c_sda.value))


async def _observe(dut, max_us, tag):
    """Sample autoneg + I2C bus until nego_done or max_us elapses."""
    saw_scl_low = saw_sda_low = saw_busy = saw_post_claim = 0
    visited_states = set()
    iters = int(max_us * 50 / 1000) + 1
    for i in range(iters):
        m_st = int(dut.u_master.u_chiplet_controller.u_autoneg.nego_state.value)
        visited_states.add(m_st)
        if m_st == 4:
            saw_post_claim = 1
        if m_st >= 8:
            saw_post_claim = 1
        if int(dut.m_i2c_scl_t.value) == 0:
            saw_scl_low = 1
        if int(dut.m_i2c_sda_t.value) == 0:
            saw_sda_low = 1
        if int(dut.u_master.u_chiplet_controller.u_autoneg.busy_seen_r.value):
            saw_busy = 1
        if int(dut.u_master.u_chiplet_controller.u_autoneg.nego_done.value):
            break
        if i % 50 == 0:
            _snap(dut, f"{tag}@{i*1000//50}us")
        await ClockCycles(dut.clk, 1000)
    return {
        "m_state":         int(dut.u_master.u_chiplet_controller.u_autoneg.nego_state.value),
        "m_nego_done":     int(dut.u_master.u_chiplet_controller.u_autoneg.nego_done.value),
        "m_nego_won":      int(dut.u_master.u_chiplet_controller.u_autoneg.nego_won.value),
        "m_is_master":     int(dut.m_role_is_master.value),
        "saw_busy":        saw_busy,
        "saw_scl_low":     saw_scl_low,
        "saw_sda_low":     saw_sda_low,
        "saw_post_claim":  saw_post_claim,
        "visited_states":  sorted(visited_states),
    }


@cocotb.test()
async def test_hw_full_mirror_via_apb(dut):
    """Full HW-mirror reproduction with all bench writes routed through APB
    (the unified config port on tidelink_top). Brings the apb_regs →
    ctrl_reg bridge into the simulation that the wlink_pair tb bypasses."""
    await _setup(dut)

    # Step 0: AUTOCAL_ENABLE — tidelink_top instantiates the chiplet with
    # AUTOCAL_ENABLE(1'b1) so no force needed (mirrors HW BD exactly).
    _snap(dut, "post-reset")

    # Step 1: debug_unlock = 1 on BOTH sides (matches GPIO 0x44041000 write)
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.clk, 4)
    _snap(dut, "after-debug-unlock")

    # Step 2: PAIR_BASE_ADDR write to TideLink Region 0
    await _apb_write(dut, "m", TL_PAIR_BASE, PAIR_BASE_VAL)
    await _apb_write(dut, "s", TL_PAIR_BASE, PAIR_BASE_VAL)
    _snap(dut, "after-pair-base")

    # Step 3: PHY_CTRL — Wlink region offset 0
    await _apb_write(dut, "m", WL_PHY_CTRL, PHY_CTRL_MASTER)
    await _apb_write(dut, "s", WL_PHY_CTRL, PHY_CTRL_SLAVE)
    _snap(dut, "after-phy-ctrl")

    # Step 4: ROLE_CFG = 0x2/0x3 via APB → ctrl_reg path
    await _apb_write(dut, "m", TL_ROLE_CFG, ROLE_CFG_MASTER)
    await _apb_write(dut, "s", TL_ROLE_CFG, ROLE_CFG_SLAVE)
    await ClockCycles(dut.clk, 20)
    _snap(dut, "after-role-lock")

    # Sanity: role_locked + role_is_master should reflect the writes
    assert int(dut.m_role_locked.value) == 1, \
        f"master role_lock did not latch (mask_hs_gate_open issue?)"
    assert int(dut.s_role_locked.value) == 1, \
        f"slave role_lock did not latch"
    assert int(dut.m_role_is_master.value) == 1, "master role_is_master != 1"
    assert int(dut.s_role_is_master.value) == 0, "slave role_is_master != 0"

    # Step 5: Wlink swreset toggle (lines 162-166 of deploy_pair.sh)
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_ASSERT)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_ASSERT)
    await ClockCycles(dut.clk, 250)
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_RELS)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_RELS)
    await ClockCycles(dut.clk, 250)
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_REENA)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_REENA)
    _snap(dut, "after-wlink-swreset")

    # Step 6-8: nego_probe_fast.py — I2C_PRESCALE, NEGO_PRIORITY, NEGO_CFG
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _apb_write(dut, side, TL_I2C_PRESCALE,  PRESCALE_HW)
        await _apb_write(dut, side, TL_NEGO_PRIORITY, prio)
        await _apb_write(dut, side, TL_NEGO_CFG,      NEGO_CFG_HW)
    _snap(dut, "after-nego-cfg")

    # Verify the writes actually landed
    rb_prescale = await _apb_read(dut, "m", TL_I2C_PRESCALE)
    rb_nego_cfg = await _apb_read(dut, "m", TL_NEGO_CFG)
    rb_nego_prio = await _apb_read(dut, "m", TL_NEGO_PRIORITY)
    dut._log.info(
        "READBACK master: PRESCALE=0x%x NEGO_CFG=0x%x NEGO_PRIORITY=0x%x",
        rb_prescale, rb_nego_cfg, rb_nego_prio)
    assert rb_prescale == PRESCALE_HW, \
        f"PRESCALE readback = 0x{rb_prescale:x}, expected {PRESCALE_HW}"
    assert rb_nego_cfg == NEGO_CFG_HW, \
        f"NEGO_CFG readback = 0x{rb_nego_cfg:x}, expected 0x{NEGO_CFG_HW:x}"

    # Step 9: observe
    res = await _observe(dut, max_us=2000, tag="via-apb")
    _snap(dut, "final")
    dut._log.info("RESULT full-mirror-via-apb: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        # Bug reproduced — match HW POLL=4 stuck condition.
        assert False, (
            f"HW BUG REPRODUCED via APB path: master never went BUSY and "
            f"never drove scl/sda low. {res}. State stuck = expected POLL, "
            f"matching bridge1 NEGO_STATUS=0x004.")
    dut._log.info(
        "HW BUG DID NOT REPRODUCE via APB path either. The apb_regs → "
        "ctrl_reg bridge layer is NOT the source of the divergence.")


@cocotb.test()
async def test_hw_full_mirror_via_apb_no_swreset(dut):
    """Variant without the Wlink swreset toggle — to isolate whether the
    swreset cycle masks the bug. If this fails and the main test passes,
    the swreset is the trigger; otherwise it's not."""
    await _setup(dut)
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.clk, 4)

    await _apb_write(dut, "m", TL_PAIR_BASE, PAIR_BASE_VAL)
    await _apb_write(dut, "s", TL_PAIR_BASE, PAIR_BASE_VAL)
    await _apb_write(dut, "m", WL_PHY_CTRL, PHY_CTRL_MASTER)
    await _apb_write(dut, "s", WL_PHY_CTRL, PHY_CTRL_SLAVE)
    await _apb_write(dut, "m", TL_ROLE_CFG, ROLE_CFG_MASTER)
    await _apb_write(dut, "s", TL_ROLE_CFG, ROLE_CFG_SLAVE)
    await ClockCycles(dut.clk, 20)

    # NO swreset

    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _apb_write(dut, side, TL_I2C_PRESCALE,  PRESCALE_HW)
        await _apb_write(dut, side, TL_NEGO_PRIORITY, prio)
        await _apb_write(dut, side, TL_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=2000, tag="via-apb-noswr")
    dut._log.info("RESULT no-swreset-via-apb: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        assert False, f"HW BUG REPRODUCED (no-swreset via APB): {res}"
    dut._log.info("HW BUG DID NOT REPRODUCE (no-swreset, via APB).")


@cocotb.test()
async def test_hw_fc_apb_contention(dut):
    """FC adapter vs external APB contention probe.

    The cocotb wlink_pair tb bypasses tidelink_top entirely, so it cannot
    exercise the 2:1 APB mux inside tidelink_top:

        fc_cfg_apb_active = fc_cfg_apb_psel
        tl_apb_psel    = fc_cfg_apb_active ? fc_cfg_apb_psel    : apb_sel_tidelink
        tl_regs_pready = fc_cfg_apb_active ? 1'b0 : tl_apb_pready

    If during nego_probe writes an FC RX credit/doorbell packet arrives,
    fc_cfg_apb_active rises and pready=0 for the external APB, the BD's
    AXI-to-APB bridge sees pready=0, the AXI write stalls, the PYNQ
    /dev/mem write becomes a long bus-stall, and the next register write
    may race against subsequent FC arrivals. This is invisible in the
    wlink_pair tb.

    This test starts the bringup, then in parallel injects steady-state
    FC RX activity (by writing to the FIFO via ahb_fifo doorbells) to
    simulate the timing pressure. NOT a perfect mirror — we don't have a
    real remote peer driving real FC frames — but it stresses the mux.

    Implementation: We trigger continuous FC activity by repeatedly
    writing to the chiplet's PAIR_BASE doorbell register on the *slave*
    side while the master is doing nego writes. The doorbell increments
    its returner counter, which generates FC traffic on the link, which
    arrives at the master as FC RX → fc_cfg_apb_active pulses.
    """
    await _setup(dut)
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.clk, 4)

    await _apb_write(dut, "m", TL_PAIR_BASE, PAIR_BASE_VAL)
    await _apb_write(dut, "s", TL_PAIR_BASE, PAIR_BASE_VAL)
    await _apb_write(dut, "m", TL_ROLE_CFG, ROLE_CFG_MASTER)
    await _apb_write(dut, "s", TL_ROLE_CFG, ROLE_CFG_SLAVE)
    await ClockCycles(dut.clk, 20)

    # Inject "FC noise" by pulsing the slave's DOORBELL register repeatedly
    # in a background coroutine. The doorbell address is TL+0x14 in Region 0.
    async def fc_noise():
        for _ in range(40):
            await _apb_write(dut, "s", 0x2014, 1)   # DOORBELL pulse
            await ClockCycles(dut.clk, 50)

    cocotb.start_soon(fc_noise())

    # Now do the nego writes while FC noise is in flight
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _apb_write(dut, side, TL_I2C_PRESCALE,  PRESCALE_HW)
        await _apb_write(dut, side, TL_NEGO_PRIORITY, prio)
        await _apb_write(dut, side, TL_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=3000, tag="fc-contention")
    dut._log.info("RESULT fc-contention: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        assert False, f"HW BUG REPRODUCED under FC contention: {res}"
    dut._log.info("HW BUG DID NOT REPRODUCE under FC-mux contention.")

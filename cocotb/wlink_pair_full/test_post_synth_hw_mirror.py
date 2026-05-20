"""HW-mirror reproduction — Angle 2: post-synthesis netlist sim.

Agent #4 attempt to catch a Vivado-synth-only divergence that the RTL
sim doesn't see. Runs the same APB bringup sequence as
test_hw_full_mirror_via_apb but drives the post-synth funcsim netlist
exported from the chiplet IP's synth_1 DCP.

If RTL-sim passes but post-synth-sim fails, a Vivado synth optimisation
(resource sharing / retiming / FSM encoding / latch inference / SRL
shifting / BRAM init pattern) is masking or introducing the bug.

The post-synth netlist is the canonical input to place-and-route; if it
exhibits the failure, the bug is in synth output (not P&R). If post-synth
ALSO passes, the bug must be P&R-only — which points at SDF-back-annotated
gate-level sim or a placement-timing race that funcsim alone won't catch.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


# Register map — full 32-bit addresses now (post-synth wrapper takes paddr[31:0])
# Within the chiplet, paddr[14:0] is the local offset; upper bits ignored.
WL_PHY_CTRL     = 0x0000
WL_SWRESET      = 0x0208
TL_PAIR_BASE    = 0x2000
TL_ROLE_CFG     = 0x2080
TL_I2C_PRESCALE = 0x208C
TL_NEGO_CFG     = 0x2090
TL_NEGO_STATUS  = 0x2094
TL_NEGO_PRIORITY= 0x2098

PHY_CTRL_MASTER   = 0x00000000
PHY_CTRL_SLAVE    = 0x00060000
WL_SWRESET_ASSERT = 0x00027F08
WL_SWRESET_RELS   = 0x00027F00
WL_SWRESET_REENA  = 0x00027F07
ROLE_CFG_MASTER   = 0x2
ROLE_CFG_SLAVE    = 0x3
PAIR_BASE_VAL     = 0x44032000
NEGO_CFG_HW       = 0x61
PRESCALE_HW       = 200
PRIO_MASTER_HW    = 1
PRIO_SLAVE_HW     = 0xFFFF


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
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
    dut.m_mask_hs_bypass.value = 1
    dut.s_mask_hs_bypass.value = 1
    dut.poresetn.value = 0
    dut.hresetn.value = 0
    # Longer reset for post-synth (synth-only register init from UNISIM)
    await ClockCycles(dut.clk, 50)
    dut.poresetn.value = 1
    dut.hresetn.value = 1
    await ClockCycles(dut.clk, 50)


async def _apb_write(dut, side, addr, data, max_wait=64):
    psel  = getattr(dut, f"{side}_apb_psel")
    pen   = getattr(dut, f"{side}_apb_penable")
    pwr   = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwd   = getattr(dut, f"{side}_apb_pwdata")
    pready= getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.clk)
    psel.value = 1
    pen.value = 0
    pwr.value = 1
    paddr.value = addr & 0x7FFF
    pwd.value = data
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
    # Hierarchy in post-synth: ideally
    #   dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_state
    # but VPI access to submodule instances inside the Vivado-synth funcsim
    # netlist is blocked — dir(dut.u_master) lists only ports, not children.
    # The probe falls back to externally visible signals (role_locked,
    # role_is_master, i2c_*_o/t, bus). The hierarchy attempt below is
    # kept in case a future Vivado/VCS combination exposes children via VPI.
    try:
        m_st = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_state.value)
        s_st = int(dut.u_slave.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_state.value)
        busy_seen = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.busy_seen_r.value)
    except Exception as e:
        m_st = s_st = busy_seen = -1
        dut._log.warning("hierarchy probe failed: %s", e)
    m_scl_t = int(dut.m_i2c_scl_t.value)
    m_scl_o = int(dut.m_i2c_scl_o.value)
    m_sda_t = int(dut.m_i2c_sda_t.value)
    dut._log.info(
        "[%s] m: state=%d busy_seen=%d locked=%d is_mst=%d scl_t=%d scl_o=%d sda_t=%d | "
        "s: state=%d locked=%d is_mst=%d | bus scl=%d sda=%d",
        tag, m_st, busy_seen,
        int(dut.m_role_locked.value), int(dut.m_role_is_master.value),
        m_scl_t, m_scl_o, m_sda_t,
        s_st, int(dut.s_role_locked.value), int(dut.s_role_is_master.value),
        int(dut.i2c_scl.value), int(dut.i2c_sda.value))


async def _observe(dut, max_us, tag):
    saw_scl_low = saw_sda_low = saw_busy = 0
    visited_states = set()
    iters = int(max_us * 50 / 1000) + 1
    for i in range(iters):
        try:
            m_st = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_state.value)
            visited_states.add(m_st)
            if int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.busy_seen_r.value):
                saw_busy = 1
            done = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_done.value)
        except Exception:
            m_st = -1
            done = 0
        if int(dut.m_i2c_scl_t.value) == 0:
            saw_scl_low = 1
        if int(dut.m_i2c_sda_t.value) == 0:
            saw_sda_low = 1
        if done:
            break
        if i % 50 == 0:
            _snap(dut, f"{tag}@{i*1000//50}us")
        await ClockCycles(dut.clk, 1000)
    try:
        m_st = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_state.value)
        m_done = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_done.value)
        m_won = int(dut.u_master.u_tidelink_top.u_chiplet_controller.u_autoneg.nego_won.value)
    except Exception:
        m_st = m_done = m_won = -1
    return {
        "m_state":         m_st,
        "m_nego_done":     m_done,
        "m_nego_won":      m_won,
        "m_is_master":     int(dut.m_role_is_master.value),
        "saw_busy":        saw_busy,
        "saw_scl_low":     saw_scl_low,
        "saw_sda_low":     saw_sda_low,
        "visited_states":  sorted(visited_states),
    }


@cocotb.test()
async def test_post_synth_hw_full_mirror(dut):
    """Post-synth: run the full HW-mirror APB bringup against the synthesised
    chiplet netlist. If this fails where the RTL sim passes, a synth
    optimisation is breaking the design."""
    await _setup(dut)
    _snap(dut, "post-reset")

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
    _snap(dut, "after-role-lock")

    # If role_lock didn't latch in post-synth, that's the failure signature.
    if int(dut.m_role_locked.value) != 1:
        assert False, (
            f"POST-SYNTH master role_lock did NOT latch. "
            f"role_is_master={int(dut.m_role_is_master.value)}. "
            f"Synth may have broken the role_lock_reg latching condition.")
    if int(dut.s_role_locked.value) != 1:
        assert False, f"POST-SYNTH slave role_lock did NOT latch."

    # Swreset toggle
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_ASSERT)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_ASSERT)
    await ClockCycles(dut.clk, 250)
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_RELS)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_RELS)
    await ClockCycles(dut.clk, 250)
    await _apb_write(dut, "m", WL_SWRESET, WL_SWRESET_REENA)
    await _apb_write(dut, "s", WL_SWRESET, WL_SWRESET_REENA)

    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _apb_write(dut, side, TL_I2C_PRESCALE,  PRESCALE_HW)
        await _apb_write(dut, side, TL_NEGO_PRIORITY, prio)
        await _apb_write(dut, side, TL_NEGO_CFG,      NEGO_CFG_HW)
    _snap(dut, "after-nego-cfg")

    res = await _observe(dut, max_us=2000, tag="post-synth")
    _snap(dut, "final")
    dut._log.info("RESULT post-synth-mirror: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        assert False, (
            f"HW BUG REPRODUCED in POST-SYNTH sim: master never went BUSY "
            f"and never drove scl/sda low. {res}. This is the same failure "
            f"signature as the bench (NEGO_STATUS=0x004 stuck POLL).")
    dut._log.info(
        "POST-SYNTH bug NOT reproduced — synth output behaves like RTL. "
        "If HW is still broken, the divergence is P&R-only (SDF/timing) "
        "or a board-physical issue.")

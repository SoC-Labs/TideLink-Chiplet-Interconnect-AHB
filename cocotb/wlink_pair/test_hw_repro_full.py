"""HW-mirror reproduction: full deploy_pair.sh + nego_probe_fast.py sequence.

The user's bench observation on bridge1 (a657306 + sub 88fea5e):

    Master NEGO_STATUS=0x004 (POLL) from t=0, never advances.
    ila_i2c trigger on (scl_o|sda_o|scl_t|sda_t)==0 never fires (15 s).
    Master's i2c_master core absolutely does not drive the bus.

This means CLAIM's PRESCALE/DATA/COMMAND AXIL writes all *appeared* to
succeed (axl_done_r tick × 3 → txn_step advanced PRESCALE→DATA→COMMAND→
POLL, state advanced CLAIM→POLL), but in POLL TXN_CHECK the i2c_master
status read returns BUSY=0 forever, so `busy_seen_r` stays 0 and the
completion condition `!BUSY && busy_seen_r` is never true. POLL loops
forever.

Previous cocotb test_hw_repro_probe_seq.test_hw_probe_after_role_lock
sets ROLE_CFG=0x2 then NEGO_CFG=0x61 with mask_hs_bypass=1 — equivalent
on paper to the HW sequence — but locks within 380 µs sim time.

This test extends the mirror with EVERY observable side-effect from
deploy_pair.sh, in order, plus the AUTOCAL_ENABLE=1 BD parameter that
the cocotb-default axi_chiplet_controller does NOT have:

    1. STRAP=0 (master) / STRAP=1 (slave) — already POR in tb_top.
    2. apb_debug_unlock=1 on BOTH boards (matches GPIO 0x44041000).
    3. APB write PAIR_BASE_ADDR @ chiplet+0x00 (Wlink region — no-op
       on cocotb's wlink mux, but exercises the apb handshake).
    4. APB write PHY_CTRL @ wlink+0x00 (swi_phase_offset).
    5. ctrl_reg ROLE_CFG=0x2/0x3 (latches role_lock with mask_hs_bypass=1).
    6. APB Wlink swreset toggle at wlink+0x208 (matches deploy_pair lines
       162-166: 0x00027f08 → 0x00027f00 → 0x00027f07).
    7. ctrl_reg I2C_PRESCALE=200.
    8. ctrl_reg NEGO_PRIORITY=1/0xFFFF.
    9. ctrl_reg NEGO_CFG=0x61.
   10. autocal_force_enable_q=1 (the BD's AUTOCAL_ENABLE=1 hardwired param
       has no parallel in cocotb tb_top.sv's default instantiation; this
       force is the runtime override hook supplied by the RTL).
   11. Observe for 2 ms sim time. PASS=bug NOT reproduced (sim locks).
       FAIL=bug reproduced (matches HW).

If this still PASSES (cocotb locks), the residual sim/HW divergence is
something the RTL alone cannot model:
   * Placement-dependent path delay → cmd FIFO sample race.
   * Vivado synth optimisation of axis_fifo that diverges sim behaviour.
   * Glitch on i2c_mst_reset during role_lock→Wlink-out-of-reset window.
   * BRAM init pattern on cmd_fifo causing first-pop to return garbage.

The diagnostic Vivado build the user has in flight (mark_debug on more
internal signals, longer ila_i2c window) will narrow this further.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ctrl_reg offsets (3-bit, matches axi_chiplet_controller decode)
CR_ROLE_CFG      = 0
CR_ROLE_STATUS   = 1
CR_I2C_PRESCALE  = 3
CR_NEGO_CFG      = 4
CR_NEGO_STATUS   = 5
CR_NEGO_PRIORITY = 6
CR_NEGO_TIMEOUT  = 7

# NEGO_CFG bit fields (matches axi_chiplet_controller)
NCFG_EN          = 1 << 0
NCFG_START       = 1 << 1
NCFG_FALLBACK    = 1 << 4
NCFG_FORCE_LOCK  = 1 << 5
NCFG_AUTO_EN     = 1 << 6

# HW-observed values from nego_probe_fast.py + deploy_pair.sh
NEGO_CFG_HW       = 0x61
PRESCALE_HW       = 200
PRIO_MASTER_HW    = 1
PRIO_SLAVE_HW     = 0xFFFF

# Wlink APB offsets (paddr[12]=0 region)
WL_OFF_PHY_CTRL   = 0x0000   # swi_phase_offset etc.
WL_OFF_SWRESET    = 0x0208   # swi_enable/lltx_enable/swreset bits

# deploy_pair.sh PHASE values (master=0, slave gets 0x60000 → swi_phase_offset=3)
PHY_CTRL_MASTER   = 0x00000000
PHY_CTRL_SLAVE    = 0x00060000

# Wlink swreset toggle sequence (deploy_pair.sh lines 162-166)
WL_SWRESET_ASSERT = 0x00027F08
WL_SWRESET_RELS   = 0x00027F00
WL_SWRESET_REENA  = 0x00027F07


async def _setup(dut):
    """Bring up clocks + POR with mask_hs_bypass=1 (mirrors HW xlconst)."""
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  20000, unit="ps").start())
    for p in ("m", "s"):
        getattr(dut, f"{p}_apb_psel").value = 0
        getattr(dut, f"{p}_apb_penable").value = 0
        getattr(dut, f"{p}_apb_pwrite").value = 0
        getattr(dut, f"{p}_apb_paddr").value = 0
        getattr(dut, f"{p}_apb_pwdata").value = 0
        getattr(dut, f"{p}_apb_pprot").value = 0
        getattr(dut, f"{p}_apb_pstrb").value = 0
        getattr(dut, f"{p}_ctrl_reg_write").value = 0
        getattr(dut, f"{p}_ctrl_reg_addr").value = 0
        getattr(dut, f"{p}_ctrl_reg_wdata").value = 0
    # HW BD: mask_hs_bypass xlconst = 1
    dut.m_mask_hs_bypass.value = 1
    dut.s_mask_hs_bypass.value = 1
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    dut.m_hresetn.value = 1
    dut.s_poresetn.value = 1
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def _ctrl_write(dut, side, addr, data):
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    sig_d.value = data
    sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0
    await RisingEdge(dut.apb_clk)


async def _apb_write(dut, side, addr, data):
    """Issue a full APB transaction (setup+access phases) to the chiplet's
    external apb port. Used to exercise the SAME path the HW PYNQ writes
    take when targeting Wlink registers (paddr[12]=0 → Wlink). Note: in
    the BD, chiplet apb_paddr is sliced to [14:0] from a 32-bit AXI_APB
    M_PADDR; the BD only forwards paddr[14:13]==00 (apb_sel_wlink) to the
    chiplet apb port. ctrl_reg writes go via a separate path
    (apb_sel_tidelink → tidelink_apb_regs.u_apb_regs) that the cocotb tb
    doesn't model — so ROLE_CFG/NEGO_CFG must use _ctrl_write directly."""
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwdata = getattr(dut, f"{side}_apb_pwdata")
    pstrb = getattr(dut, f"{side}_apb_pstrb")
    pready = getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 1
    pwdata.value = data
    pstrb.value = 0xF
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    for _ in range(64):
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0


def _snap(dut, tag):
    m_st = int(dut.u_master.u_autoneg.nego_state.value)
    s_st = int(dut.u_slave.u_autoneg.nego_state.value)
    m_scl_t = int(dut.m_i2c_scl_t.value)
    m_scl_o = int(dut.m_i2c_scl_o.value)
    m_sda_t = int(dut.m_i2c_sda_t.value)
    m_sda_o = int(dut.m_i2c_sda_o.value)
    busy_seen = int(dut.u_master.u_autoneg.busy_seen_r.value)
    txn_step = int(dut.u_master.u_autoneg.txn_step_r.value)
    nego_drv = int(dut.u_master.u_chiplet_controller.nego_driving.value) \
        if hasattr(dut.u_master, 'u_chiplet_controller') else \
        (1 if m_st in (2,3,4,8,9,10) else 0)
    dut._log.info(
        "[%s] m: state=%d txn=%d busy_seen=%d nego_drv=%d locked=%d is_mst=%d "
        "scl_t=%d scl_o=%d sda_t=%d sda_o=%d | s: state=%d locked=%d "
        "is_mst=%d | bus scl=%d sda=%d",
        tag, m_st, txn_step, busy_seen, nego_drv,
        int(dut.m_role_locked.value), int(dut.m_role_is_master.value),
        m_scl_t, m_scl_o, m_sda_t, m_sda_o,
        s_st, int(dut.s_role_locked.value),
        int(dut.s_role_is_master.value),
        int(dut.i2c_scl.value), int(dut.i2c_sda.value))


async def _observe(dut, max_us, tag):
    """Sample master's POLL/CLAIM behaviour and i2c pad activity until
    nego_done or max_us elapses. Returns a dict for the test to interpret."""
    saw_scl_low = saw_sda_low = saw_busy = saw_post_claim = 0
    visited_states = set()
    iters = int(max_us * 50 / 1000) + 1   # 1000 cycles/step = 20 µs
    for i in range(iters):
        m_st = int(dut.u_master.u_autoneg.nego_state.value)
        visited_states.add(m_st)
        if 4 <= m_st < 5:                   # POLL = 4
            saw_post_claim = 1
        if m_st >= 8:
            saw_post_claim = 1
        if int(dut.m_i2c_scl_t.value) == 0:
            saw_scl_low = 1
        if int(dut.m_i2c_sda_t.value) == 0:
            saw_sda_low = 1
        if int(dut.u_master.u_autoneg.busy_seen_r.value):
            saw_busy = 1
        if int(dut.u_master.u_autoneg.nego_done.value):
            break
        if i % 50 == 0:
            _snap(dut, f"{tag}@{i*1000//50}us")
        await ClockCycles(dut.master_clk, 1000)
    return {
        "m_state":         int(dut.u_master.u_autoneg.nego_state.value),
        "m_nego_done":     int(dut.u_master.u_autoneg.nego_done.value),
        "m_nego_won":      int(dut.u_master.u_autoneg.nego_won.value),
        "m_is_master":     int(dut.m_role_is_master.value),
        "m_busy_seen_r":   int(dut.u_master.u_autoneg.busy_seen_r.value),
        "saw_busy":        saw_busy,
        "saw_scl_low":     saw_scl_low,
        "saw_sda_low":     saw_sda_low,
        "saw_post_claim":  saw_post_claim,
        "visited_states":  sorted(visited_states),
    }


@cocotb.test()
async def test_hw_full_mirror(dut):
    """Comprehensive HW mirror: every observable side-effect from
    deploy_pair.sh + nego_probe_fast.py, in order. mask_hs_bypass=1
    (matches xlconst), debug_unlock=1 on BOTH (matches GPIO writes),
    AUTOCAL force=1 (matches BD's .AUTOCAL_ENABLE(1'b1) param)."""
    await _setup(dut)

    # Step 0: AUTOCAL_ENABLE=1 via hierarchical-force hook (BD param
    # parallel). Defaults are AUTOCAL_ENABLE=0 in cocotb's instantiation.
    dut.u_master.autocal_force_enable_q.value = 1
    dut.u_slave.autocal_force_enable_q.value = 1
    await ClockCycles(dut.master_clk, 2)

    # Step 1: debug_unlock=1 on BOTH sides (mirrors GPIO 0x44041000=1).
    # Note: master's wl_apb mux unconditionally passes external APB through
    # when role_is_master=1, so debug_unlock is functionally a no-op on
    # master. We set it anyway to bit-mirror the HW.
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.master_clk, 2)
    _snap(dut, "after-debug-unlock")

    # Step 2: PAIR_BASE_ADDR write to TideLink config region. In HW the BD
    # routes this via apb_sel_tidelink (paddr[13]=1, offset 0x00), into
    # tidelink_fifo.u_apb_regs. The cocotb tb instantiates only
    # axi_chiplet_controller (no tidelink_top wrapper) so this register
    # doesn't exist here — we skip the write but log the omission. The
    # PAIR_BASE_ADDR is used for TideLink address translation only and
    # has no influence on the I2C/autoneg path under test.
    dut._log.info("SKIP: PAIR_BASE_ADDR write (cocotb tb has no tidelink_fifo)")

    # Step 3: PHY_CTRL write via APB → Wlink region (paddr 0x0000). The
    # chiplet's APB mux routes paddr[12]=0 to the Wlink. Master gets
    # PHY_CTRL_MASTER=0, slave gets PHY_CTRL_SLAVE=0x60000.
    await _apb_write(dut, "m", WL_OFF_PHY_CTRL, PHY_CTRL_MASTER)
    await _apb_write(dut, "s", WL_OFF_PHY_CTRL, PHY_CTRL_SLAVE)
    _snap(dut, "after-phy-ctrl")

    # Step 4: ctrl_reg ROLE_CFG=0x2 / 0x3 (W1S role_lock).
    await _ctrl_write(dut, "m", CR_ROLE_CFG, 0x2)
    await _ctrl_write(dut, "s", CR_ROLE_CFG, 0x3)
    await ClockCycles(dut.master_clk, 10)
    _snap(dut, "after-role-lock")

    assert int(dut.m_role_locked.value) == 1, "expected master role_lock to latch"
    assert int(dut.s_role_locked.value) == 1, "expected slave role_lock to latch"
    assert int(dut.m_role_is_master.value) == 1, "expected master role_is_master=1"
    assert int(dut.s_role_is_master.value) == 0, "expected slave role_is_master=0"

    # Step 5: Wlink swreset toggle (deploy_pair.sh lines 162-166).
    # 0x00027f08 → swreset on, lltx_enable off
    # 0x00027f00 → release swreset (still off)
    # 0x00027f07 → re-enable swi+lltx+lltx_1
    await _apb_write(dut, "m", WL_OFF_SWRESET, WL_SWRESET_ASSERT)
    await _apb_write(dut, "s", WL_OFF_SWRESET, WL_SWRESET_ASSERT)
    await ClockCycles(dut.master_clk, 250)   # ~5 µs at 50 MHz, matches sleep
    await _apb_write(dut, "m", WL_OFF_SWRESET, WL_SWRESET_RELS)
    await _apb_write(dut, "s", WL_OFF_SWRESET, WL_SWRESET_RELS)
    await ClockCycles(dut.master_clk, 250)
    await _apb_write(dut, "m", WL_OFF_SWRESET, WL_SWRESET_REENA)
    await _apb_write(dut, "s", WL_OFF_SWRESET, WL_SWRESET_REENA)
    _snap(dut, "after-wlink-swreset")

    # Step 6-8: nego_probe_fast.py — I2C_PRESCALE, NEGO_PRIORITY, NEGO_CFG.
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _ctrl_write(dut, side, CR_I2C_PRESCALE,  PRESCALE_HW)
        await _ctrl_write(dut, side, CR_NEGO_PRIORITY, prio)
        await _ctrl_write(dut, side, CR_NEGO_CFG,      NEGO_CFG_HW)
    _snap(dut, "after-nego-cfg")

    # Step 9: observe.
    res = await _observe(dut, max_us=2000, tag="full")
    _snap(dut, "final")
    dut._log.info("RESULT full-mirror: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        # Bug reproduced — assert with HW-matching message.
        assert False, (
            f"HW BUG REPRODUCED: master never went BUSY and never drove "
            f"scl/sda low. {res}. State stuck = expected POLL (4), "
            f"matching bridge1 NEGO_STATUS=0x004 observation.")
    # Sim does NOT reproduce — the divergence requires silicon-level
    # observability to close.
    dut._log.info(
        "HW BUG DID NOT REPRODUCE with full deploy_pair.sh + "
        "nego_probe_fast.py mirror + AUTOCAL=1 + debug_unlock=1 + "
        "Wlink swreset cycle. The remaining gap is synth/silicon-only.")


@cocotb.test()
async def test_hw_full_mirror_no_wlink_swreset(dut):
    """Same as test_hw_full_mirror but WITHOUT the Wlink swreset toggle.
    Differential isolates whether the swreset cycle (and its consequent
    Wlink re-training) is the trigger that masks the bug in sim. If this
    PASSES and the full-mirror also PASSES → swreset not relevant. If
    this FAILS and full-mirror PASSES → swreset IS the trigger."""
    await _setup(dut)
    dut.u_master.autocal_force_enable_q.value = 1
    dut.u_slave.autocal_force_enable_q.value = 1
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.master_clk, 2)

    await _apb_write(dut, "m", WL_OFF_PHY_CTRL, PHY_CTRL_MASTER)
    await _apb_write(dut, "s", WL_OFF_PHY_CTRL, PHY_CTRL_SLAVE)

    await _ctrl_write(dut, "m", CR_ROLE_CFG, 0x2)
    await _ctrl_write(dut, "s", CR_ROLE_CFG, 0x3)
    await ClockCycles(dut.master_clk, 10)

    # NO swreset cycle.

    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _ctrl_write(dut, side, CR_I2C_PRESCALE,  PRESCALE_HW)
        await _ctrl_write(dut, side, CR_NEGO_PRIORITY, prio)
        await _ctrl_write(dut, side, CR_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=2000, tag="noswr")
    dut._log.info("RESULT no-wlink-swreset: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        assert False, f"HW BUG REPRODUCED (no-swreset variant): {res}"
    dut._log.info("HW BUG DID NOT REPRODUCE without Wlink swreset.")


@cocotb.test()
async def test_hw_cfg_burst_no_pause(dut):
    """Variant: write I2C_PRESCALE, NEGO_PRIORITY, NEGO_CFG back-to-back
    on master BEFORE doing the same on slave. nego_probe_fast.py runs
    independently on each board so the writes are interleaved across the
    pair with arbitrary timing — the cocotb sequential helper might be
    masking a race where master starts CLAIM before slave's ROLE_CFG has
    propagated to its i2c_slave (NEGO_ADDR_DEFAULT=0x7E ACK). On real HW
    the two PYNQs run nego_probe_fast.py independently."""
    await _setup(dut)
    dut.u_master.autocal_force_enable_q.value = 1
    dut.u_slave.autocal_force_enable_q.value = 1
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.master_clk, 2)

    await _ctrl_write(dut, "m", CR_ROLE_CFG, 0x2)
    await _ctrl_write(dut, "s", CR_ROLE_CFG, 0x3)
    await ClockCycles(dut.master_clk, 10)

    # Master writes its 3 configs and IMMEDIATELY kicks nego_en before
    # slave writes anything.
    await _ctrl_write(dut, "m", CR_I2C_PRESCALE,  PRESCALE_HW)
    await _ctrl_write(dut, "m", CR_NEGO_PRIORITY, PRIO_MASTER_HW)
    await _ctrl_write(dut, "m", CR_NEGO_CFG,      NEGO_CFG_HW)

    # Then slave (50 cycles later — represents the latency between two
    # independent PYNQ ssh sessions doing the same write).
    await ClockCycles(dut.master_clk, 50)
    await _ctrl_write(dut, "s", CR_I2C_PRESCALE,  PRESCALE_HW)
    await _ctrl_write(dut, "s", CR_NEGO_PRIORITY, PRIO_SLAVE_HW)
    await _ctrl_write(dut, "s", CR_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=2000, tag="burst")
    dut._log.info("RESULT cfg-burst: %s", res)

    if not res["saw_busy"] and not res["saw_scl_low"]:
        assert False, f"HW BUG REPRODUCED (cfg-burst variant): {res}"
    dut._log.info("HW BUG DID NOT REPRODUCE with master-first cfg burst.")

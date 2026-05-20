"""HW-bug reproduction: minimal 3-write MMIO sequence from
pynq_host/scripts/nego_probe_fast.py.

On bridge1 (z2_02/z2_03) with the new P15/P16 I2C bitstreams, this exact
sequence drives the master autoneg FSM into ST_NEGO_CLAIM (NEGO_STATUS=0x003)
and it never advances — `done/err/won/lost` all stay 0, and ila_i2c captures
4096 samples with (scl_o/scl_t/scl_i/sda_o/sda_t/sda_i)=(1,1,1,1,1,1) i.e.
the master core never drives the bus low. The cocotb 3-test suite in
test_autoneg_i2c_e2e.py is fully green with NEGO_CFG=0x61, so something the
e2e test does is masking the HW failure.

The minimal-mirror test below issues ONLY the 3 writes the PS script does:
    I2C_PRESCALE  = 200  (ctrl_reg #3)
    NEGO_PRIORITY = 1    on master / 0xFFFF on slave (ctrl_reg #6)
    NEGO_CFG      = 0x61 (ctrl_reg #4)

NOTHING ELSE. In particular it does NOT:
  - lift apb_debug_unlock on the slave to write the Wlink lane mask,
  - touch the Wlink lane masks at all (the HW relies on POR defaults),
  - program NEGO_TIMEOUT (relies on POR default 131_082_000),
  - drive mask_hs_bypass to 0 explicitly (the wlink_pair tb defaults to 1,
    which is closer to the HW path the bug is actually exercising — see
    notes; we override to 0 in a parallel test to match the strap that the
    HW boards have).

If the master here ALSO sticks in CLAIM with _t high → bug reproduced and
the next step is to diff against test_autoneg_i2c_e2e.py to find which
extra write is the keeper. If autoneg locks anyway → the divergence is
something cocotb doesn't model (strap pins, BD IOBUF wiring, clock
domain etc.).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ctrl_reg offsets (3-bit)
CR_ROLE_CFG      = 0
CR_ROLE_STATUS   = 1
CR_I2C_PRESCALE  = 3
CR_NEGO_CFG      = 4
CR_NEGO_STATUS   = 5
CR_NEGO_PRIORITY = 6
CR_NEGO_TIMEOUT  = 7

# NEGO_CFG bit fields
NCFG_EN          = 1 << 0  # nego_en
NCFG_START       = 1 << 1
NCFG_FALLBACK    = 1 << 4
NCFG_FORCE_LOCK  = 1 << 5
NCFG_AUTO_EN     = 1 << 6

# HW probe values
NEGO_CFG_HW    = 0x61                # en | force_lock | auto_en
PRESCALE_HW    = 200                 # 100 MHz → ~125 kHz SCL
PRIO_MASTER_HW = 1
PRIO_SLAVE_HW  = 0xFFFF


async def _setup(dut):
    """Bring up clocks and POR exactly like the e2e setup."""
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
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
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


def _snap(dut, tag):
    m_st = int(dut.u_master.u_autoneg.nego_state.value)
    s_st = int(dut.u_slave.u_autoneg.nego_state.value)
    m_lm = int(dut.u_master.u_autoneg.mask_hs_local_match_r.value)
    m_lf = int(dut.u_master.u_autoneg.mask_hs_local_fail_r.value)
    s_mq = int(dut.u_slave.u_wlink.hs_result_match_q.value)
    s_fq = int(dut.u_slave.u_wlink.hs_result_fail_q.value)
    # Pad-mux outputs (what the IOBUF would drive):
    m_scl_t = int(dut.m_i2c_scl_t.value)
    m_scl_o = int(dut.m_i2c_scl_o.value)
    m_sda_t = int(dut.m_i2c_sda_t.value)
    m_sda_o = int(dut.m_i2c_sda_o.value)
    dut._log.info(
        "[%s] m: state=%d is_mst=%d won=%d lost=%d local_match=%d "
        "scl_t=%d scl_o=%d sda_t=%d sda_o=%d | s: state=%d is_mst=%d "
        "hs_mq=%d hs_fq=%d | bus scl=%d sda=%d",
        tag, m_st, int(dut.m_role_is_master.value),
        int(dut.u_master.u_autoneg.nego_won.value),
        int(dut.u_master.u_autoneg.nego_lost.value), m_lm,
        m_scl_t, m_scl_o, m_sda_t, m_sda_o,
        s_st, int(dut.s_role_is_master.value), s_mq, s_fq,
        int(dut.i2c_scl.value), int(dut.i2c_sda.value))


async def _arm_hw_mirror(dut, m_bypass, s_bypass):
    """Issue ONLY the 3 writes the HW probe does. No lane-mask writes,
    no NEGO_TIMEOUT, no debug_unlock. Bypass is a knob so we can test both
    the HW-strap value (=0) and the wlink_pair-default (=1) and observe
    how the bus behaves identically vs. differently in each."""
    await _setup(dut)

    dut.m_mask_hs_bypass.value = m_bypass
    dut.s_mask_hs_bypass.value = s_bypass
    await ClockCycles(dut.master_clk, 2)

    # Mirror nego_probe_fast.py EXACTLY:
    #   wr(I2C_PRESCALE, 200)
    #   wr(NEGO_PRIORITY, PRIO)
    #   wr(NEGO_CFG, 0x61)
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _ctrl_write(dut, side, CR_I2C_PRESCALE,  PRESCALE_HW)
        await _ctrl_write(dut, side, CR_NEGO_PRIORITY, prio)
    _snap(dut, "armed-pre-nego")
    for side in ("m", "s"):
        await _ctrl_write(dut, side, CR_NEGO_CFG, NEGO_CFG_HW)
    _snap(dut, "armed-post-nego")


async def _run_until(dut, cond, max_us=5000, step_cycles=2000):
    """Poll cond(dut) up to max_us of master-clk sim time. 50 cycles/µs.
    20 ns master period × 2000 cycles = 40 µs per step."""
    iters = int(max_us * 50 / step_cycles) + 1
    for i in range(iters):
        if cond(dut):
            return True
        if i % 10 == 0:
            _snap(dut, f"poll@{i*step_cycles//50}us")
        await ClockCycles(dut.master_clk, step_cycles)
    return cond(dut)


# ── HW-MIRROR (bypass=0, the actual HW strap) ───────────────────────────────


async def _observe(dut, max_us, tag):
    """Run for max_us and record (a) whether m_state ever advanced beyond
    CLAIM (3); (b) whether scl_t/sda_t was EVER driven low; (c) terminal
    state. Returns dict. Does NOT assert — caller picks an interpretation."""
    saw_scl_low = saw_sda_low = saw_post_claim = 0
    visited_states = set()
    iters = int(max_us * 50 / 1000) + 1   # 1000 cycles per step = 20 µs/step
    for i in range(iters):
        m_st = int(dut.u_master.u_autoneg.nego_state.value)
        visited_states.add(m_st)
        if m_st > 3 and m_st < 5:           # POLL or beyond, before DONE
            saw_post_claim = 1
        if m_st >= 8:                        # MASK_RES_TX / RD_*
            saw_post_claim = 1
        if int(dut.m_i2c_scl_t.value) == 0:
            saw_scl_low = 1
        if int(dut.m_i2c_sda_t.value) == 0:
            saw_sda_low = 1
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
        "saw_scl_low":     saw_scl_low,
        "saw_sda_low":     saw_sda_low,
        "saw_post_claim":  saw_post_claim,
        "visited_states":  sorted(visited_states),
    }


@cocotb.test()
async def test_hw_probe_bypass0(dut):
    """nego_probe_fast.py sequence — only I2C_PRESCALE=200, NEGO_PRIORITY,
    NEGO_CFG=0x61. Bypass=0 on both (matches HW strap). Wait 2 ms and
    record whether (a) m_state ever advances past CLAIM, (b) the master's
    scl/sda IOBUF-OE was EVER driven low. The HW captured all-1 across
    4096 ila_i2c samples → if cocotb sees scl_low at any point, it does
    NOT reproduce, and the divergence is something cocotb can't see.
    """
    await _arm_hw_mirror(dut, m_bypass=0, s_bypass=0)
    res = await _observe(dut, max_us=2000, tag="b0")
    _snap(dut, "final-bypass0")
    dut._log.info("RESULT bypass=0: %s", res)

    if not res["saw_post_claim"] and not res["saw_scl_low"]:
        # HW BUG REPRODUCED — fail so the diff against the e2e test
        # becomes the next action.
        assert False, (
            f"HW BUG REPRODUCED: master never advanced past CLAIM and "
            f"never drove scl/sda low. {res}. Now diff vs e2e test.")
    # If cocotb autonomously locks, this passes — meaning the HW bug
    # is something cocotb does not model.
    dut._log.info("HW BUG DID NOT REPRODUCE with minimal sequence — "
                  "cocotb autonomously locks with just the 3 writes.")


@cocotb.test()
async def test_hw_probe_bypass1(dut):
    """Same minimal sequence with bypass=1. Control to isolate whether
    the FSM advance vs. stall is sensitive to bypass."""
    await _arm_hw_mirror(dut, m_bypass=1, s_bypass=1)
    res = await _observe(dut, max_us=2000, tag="b1")
    _snap(dut, "final-bypass1")
    dut._log.info("RESULT bypass=1: %s", res)


@cocotb.test()
async def test_hw_probe_after_role_lock(dut):
    """Mirror the HW deploy ordering EXACTLY:
       1. deploy_pair.sh sets STRAP, debug_unlock, then writes
          ROLE_CFG = 0x2 (bit[0]=0 master, bit[1]=1 → role_lock W1S).
          With mask_hs_bypass_i=1 on the BD this LATCHES role_lock_reg.
       2. nego_probe_fast.py then writes I2C_PRESCALE / NEGO_PRIORITY /
          NEGO_CFG=0x61 *after* role_lock is already latched.

    Key observation in axi_chiplet_controller.sv:
        role_in_nego = nego_en && !role_locked;
        nego_driving = role_in_nego && (state ∈ {2,3,4,8,9,10});
        mst_axil_awvalid = nego_driving ? fsm_axil_awvalid : bridge_axil_awvalid;

    With role_locked=1, role_in_nego=0, nego_driving=0 — the autoneg
    FSM's AXIL writes to the i2c_master core are MUTED. The FSM enters
    CLAIM, drives fsm_axil_awvalid=1, but mst_axil_awvalid stays 0 →
    no awready, no bvalid, axl_done_r stays 0 → CLAIM stalls forever.

    Pad-side: role_is_master = ~role_cfg_reg = 1 (correct), so the pad
    mux selects mst_scl_t. mst_scl_t reflects the i2c_master's scl_o_reg
    which is held at 1 (idle) because the core never gets a START cmd
    (no AXIL writes). → external _t and _o both stay 1 forever. Exactly
    the ILA-captured behaviour.

    This test should FAIL (assert fires) because it reproduces the bug.
    Pin mask_hs_bypass=1 to match the BD.
    """
    await _setup(dut)
    dut.m_mask_hs_bypass.value = 1
    dut.s_mask_hs_bypass.value = 1
    await ClockCycles(dut.master_clk, 2)

    # Phase 1: deploy_pair.sh equivalent — write ROLE_CFG=0x2 to latch
    # role_lock on master, 0x3 on slave (both stay master/slave per
    # cfg[0], with cfg[1]=lock W1S).
    await _ctrl_write(dut, "m", CR_ROLE_CFG, 0x2)   # master + lock
    await _ctrl_write(dut, "s", CR_ROLE_CFG, 0x3)   # slave  + lock
    await ClockCycles(dut.master_clk, 5)
    m_locked = int(dut.m_role_locked.value)
    s_locked = int(dut.s_role_locked.value)
    m_is_mst = int(dut.m_role_is_master.value)
    s_is_mst = int(dut.s_role_is_master.value)
    dut._log.info("post-role-lock: m_locked=%d s_locked=%d "
                  "m_is_master=%d s_is_master=%d",
                  m_locked, s_locked, m_is_mst, s_is_mst)
    assert m_locked == 1, ("expected master role_lock to latch with "
                            "mask_hs_bypass=1 — gate should be open")
    assert m_is_mst == 1, "expected master role_is_master=1 post-lock"

    # Phase 2: nego_probe_fast.py equivalent.
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _ctrl_write(dut, side, CR_I2C_PRESCALE,  PRESCALE_HW)
        await _ctrl_write(dut, side, CR_NEGO_PRIORITY, prio)
        await _ctrl_write(dut, side, CR_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=2000, tag="locked")
    _snap(dut, "final-locked-then-nego")
    dut._log.info("RESULT locked-then-nego: %s", res)

    if not res["saw_post_claim"] and not res["saw_scl_low"]:
        # Bug reproduced — assert with a clear root-cause message.
        assert False, (
            f"HW BUG REPRODUCED: with role_lock latched BEFORE nego_en, "
            f"the autoneg FSM's AXIL writes are muted by nego_driving=0 "
            f"(nego_driving requires !role_locked). Master enters CLAIM "
            f"but TXN_PRESCALE never completes → stuck. {res}. "
            f"Root cause: axi_chiplet_controller.sv:299 "
            f"role_in_nego = nego_en && !role_locked.")


@cocotb.test()
async def test_hw_probe_plus_lane_mask(dut):
    """Hypothesis: maybe the HW relies on the lane-mask being programmed
    via Wlink APB. The HW doesn't do this (PS only writes ctrl_reg space)
    so the Wlink lane_mask stays at its POR default. This test programs
    the lane masks (like e2e does) BUT keeps everything else minimal,
    to isolate whether the lane-mask write is the keeper.
    """
    WL_LANE_MASK = 0x0214
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

    dut.m_mask_hs_bypass.value = 0
    dut.s_mask_hs_bypass.value = 0

    # NOT applied: no lane-mask APB writes. NOT applied: no
    # apb_debug_unlock. Just the bare 3 writes per side.
    for side, prio in (("m", PRIO_MASTER_HW), ("s", PRIO_SLAVE_HW)):
        await _ctrl_write(dut, side, CR_I2C_PRESCALE,  PRESCALE_HW)
        await _ctrl_write(dut, side, CR_NEGO_PRIORITY, prio)
        await _ctrl_write(dut, side, CR_NEGO_CFG,      NEGO_CFG_HW)

    res = await _observe(dut, max_us=2000, tag="nolm")
    _snap(dut, "final-nolanemask")
    dut._log.info("RESULT no-lane-mask: %s", res)

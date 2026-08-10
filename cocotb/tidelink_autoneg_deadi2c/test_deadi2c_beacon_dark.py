"""REPRODUCE-FIRST — dead-I2C NEGO bare-link never lights the SYNC beacon.

Bug under reproduction (HW-measured 2026-08-09, standalone bare-link kr260-pair)
-------------------------------------------------------------------------------
Master->slave cross-die AXI writes read ALL-ZEROS at the slave RX FIFO. Root
cause pinned by synthesis:

    The bare-link runs NEGO autonomy (NEGO_CFG_RESET=0x61, nego_en=1) with a
    DEAD I2C control plane (no peer I2C). With TRAIN_ENTRY_FALLBACK=0 and
    SELF_ARM_TRAIN_EN=0 (the shipping straps), the autoneg FSM's I2C peer
    transaction NACKs and it parks in the TERMINAL ST_NEGO_DONE (via the
    NEGO_POLL TXN_CHECK MISS_ACK arm, tidelink_autoneg.sv ~:997-1024) WITHOUT
    ever pulsing local_train_set. `local_training_mode_set` (== the ONLY
    enabler that raises swi_training_mode_r in the controller) therefore never
    fires, so the autonomous SYNC-config one-shot in
    axi_chiplet_controller.sv:2283 (armed on the swi_training_mode_r rise)
    never runs: swi_sync_insert_en_r stays 0 (SYNC beacon dark),
    swi_sync_lane_mask_r stays 0xFF, swi_sync_tol_r stays 0. No beacon =>
    RX deskew never re-anchors => delivery all-zeros.

    (Enabling AUTO_ANCHOR_EN=1 does NOT fix it: auto_anchor_pulse ORs only into
    insert/force/robust; the lane_mask/tol config and the insert *arm* still
    ride the training rise that never happens.)

This test exercises the CURRENT SHIPPING autoneg RTL
(src/rtl/local_overrides/tidelink_autoneg.sv, TRAIN_ENTRY_FALLBACK default 0)
with cocotb modelling the I2C master core as a DEAD bus (every peer transaction
NACKs / MISS_ACK). It is NON-VACUOUS: the FSM genuinely walks
NEGO_INIT -> NEGO_WAIT -> claims master -> NEGO_CLAIM -> NEGO_POLL, observes the
peer NACK, and parks in ST_NEGO_DONE (nego_lost=1, role locked). The reproduce
oracle then asserts what a healthy bring-up MUST do to deliver data — pulse
local_training_mode_set (light the beacon) — which FAILS on the current RTL.

The downstream half of the chain (a training rise DOES fire the SYNC-config
one-shot / insert_en=1) is proven by the complementary positive suite
cocotb/tidelink_top_pair_v2/test_v2_autonomous_sync_detect.py; together they
bracket the pinned mechanism.

Run
---
    cd cocotb/tidelink_autoneg_deadi2c
    source ../../set_env.sh
    rm -rf sim_build
    MODULE=test_deadi2c_beacon_dark make
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# FSM state encoding (tidelink_autoneg.sv). state_r is 5-bit; nego_state is the
# TRUNCATED 4-bit legacy view (aliases >=16), so we read state_r directly.
ST_IDLE          = 0
ST_NEGO_INIT     = 1
ST_NEGO_WAIT     = 2
ST_NEGO_CLAIM    = 3
ST_NEGO_POLL     = 4
ST_NEGO_DONE     = 5
ST_BYPASS        = 6
ST_ERROR         = 7
ST_NEGO_DONE_PRE = 11
ST_TRAIN_ENTER   = 12
ST_TRAIN_RUN     = 13
ST_TRAIN_POLL_PEER = 14
ST_TRAIN_EXIT    = 15
ST_TRAIN_DONE    = 16
ST_TRAIN_FAIL    = 17

# I2C master-core status register bits (tidelink_autoneg.sv localparams).
I2C_STS_BUSY     = 0            # bit 0
I2C_STS_MISS_ACK = 3           # bit 3
STS_BUSY         = 1 << I2C_STS_BUSY      # 0x01
STS_NACK         = 1 << I2C_STS_MISS_ACK  # 0x08 (BUSY cleared -> "done, NACKed")


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


async def _dead_i2c_axil_slave(dut):
    """Model the on-chip I2C master core's AXI-Lite register file with a DEAD
    bus. Every register WRITE completes (the core queues the command fine), but
    the STATUS reads report the peer NEVER acknowledged:

        read #1 (per transaction)  -> BUSY=1   (core is driving the bus)
        read #2..                  -> BUSY=0, MISS_ACK=1  (bus done, peer NACK)

    That is exactly what an absent/dead peer looks like to the core, and it is
    what drives the autoneg NEGO_POLL TXN_CHECK MISS_ACK arm. busy_seen_r needs
    to latch on a BUSY read before a !BUSY read is accepted as completion, so we
    always show BUSY first, then NACK.
    """
    c = dut
    # Idle all responses.
    c.m_axil_awready.value = 0
    c.m_axil_wready.value  = 0
    c.m_axil_bvalid.value  = 0
    c.m_axil_bresp.value   = 0
    c.m_axil_arready.value = 0
    c.m_axil_rvalid.value  = 0
    c.m_axil_rdata.value   = 0
    c.m_axil_rresp.value   = 0

    reads_since_busy = 0
    while True:
        await RisingEdge(c.clk)
        aw = _si(c.m_axil_awvalid)
        w  = _si(c.m_axil_wvalid)
        ar = _si(c.m_axil_arvalid)

        if aw or w:
            # --- accept a write (address+data together) ---
            c.m_axil_awready.value = 1
            c.m_axil_wready.value  = 1
            await RisingEdge(c.clk)
            c.m_axil_awready.value = 0
            c.m_axil_wready.value  = 0
            # write response
            c.m_axil_bresp.value  = 0
            c.m_axil_bvalid.value = 1
            while not _si(c.m_axil_bready):
                await RisingEdge(c.clk)
            await RisingEdge(c.clk)
            c.m_axil_bvalid.value = 0

        elif ar:
            # --- accept a read; only the STATUS register (addr 0x0) is read in
            # the NEGO claim/poll phase, so every read returns the dead-bus
            # status model. ---
            c.m_axil_arready.value = 1
            await RisingEdge(c.clk)
            c.m_axil_arready.value = 0
            if reads_since_busy == 0:
                data = STS_BUSY          # first poll: core is busy on the bus
            else:
                data = STS_NACK          # subsequent: bus done, peer NACKed
            reads_since_busy += 1
            c.m_axil_rdata.value  = data
            c.m_axil_rresp.value  = 0
            c.m_axil_rvalid.value = 1
            while not _si(c.m_axil_rready):
                await RisingEdge(c.clk)
            await RisingEdge(c.clk)
            c.m_axil_rvalid.value = 0


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    # ── Autonomy config = bare-link NEGO_CFG=0x61 posture ──
    dut.nego_en.value          = 1
    dut.nego_start.value       = 0
    dut.nego_pri_sel.value     = 0        # register-priority source
    dut.nego_priority_reg.value = 0x0000  # lowest priority => shortest backoff
    dut.nego_priority_i.value  = 0
    dut.nego_fallback.value    = 0        # fallback = master
    dut.nego_force_lock.value  = 1        # latch role_lock at nego completion
    dut.puf_seed.value         = 0
    dut.puf_ready.value        = 0
    dut.nego_timeout_reg.value = 5_000_000  # ample: claim happens ~2000cy first
    dut.role_strap_i.value     = 0        # strap MASTER (survives dead I2C)
    # Bus idle (no peer START -> this die wins arbitration & becomes I2C master)
    dut.i2c_sda_i.value        = 1
    dut.i2c_scl_i.value        = 1
    dut.i2c_prescale_reg.value = 4        # tiny prescale => fast sim
    # ── Training REQUESTED (the point: training is wanted, yet dead I2C never
    #    arms it) ──
    dut.train_auto_en.value    = 1
    dut.train_sw_step.value    = 0
    dut.train_retrain_req.value = 0
    dut.train_poll_timeout.value = 0
    dut.train_fsm_wait_hi.value  = 0
    dut.local_swi_lane_locked_i.value = 0xFF
    dut.local_swi_lane_fault_i.value  = 0x00
    dut.local_calibration_done_i.value = 1   # PHY calibrated (role_lock -> cal)
    # Mask handshake off (simple NEGO_POLL -> park flow)
    dut.mask_hs_auto_en.value  = 0
    dut.local_tx_lane_mask_i.value = 0xFF
    dut.local_rx_lane_mask_i.value = 0xFF
    # Start the dead-I2C AXI-Lite responder.
    cocotb.start_soon(_dead_i2c_axil_slave(dut))


async def _por(dut):
    dut.poresetn.value = 0
    await ClockCycles(dut.clk, 5)
    dut.poresetn.value = 1
    await ClockCycles(dut.clk, 2)


@cocotb.test()
async def test_deadi2c_beacon_never_arms(dut):
    """DEAD-I2C bare-link: autoneg NACK-parks, SYNC beacon (local_train_set)
    never arms — the pinned root cause of the master->slave all-zeros drop."""
    log = dut._log
    await _setup(dut)
    await _por(dut)

    st = dut.u_dut  # tidelink_autoneg instance (full 5-bit state_r)

    saw_train_set   = False   # local_training_mode_set ever pulsed?
    saw_train_inprog = False  # train_in_progress_o ever asserted?
    max_state       = 0
    saw_nego_poll   = False   # proof the FSM reached the I2C poll
    saw_claim       = False   # proof it claimed master

    MAX_CYCLES = 60_000
    for _ in range(MAX_CYCLES):
        await RisingEdge(dut.clk)
        if _si(dut.local_training_mode_set) == 1:
            saw_train_set = True
        if _si(dut.train_in_progress_o) == 1:
            saw_train_inprog = True
        s = _si(st.state_r)
        if s >= 0:
            max_state = max(max_state, s)
        if s == ST_NEGO_CLAIM:
            saw_claim = True
        if s == ST_NEGO_POLL:
            saw_nego_poll = True
        # Stop once the FSM has settled in a terminal park (DONE/ERROR) — but
        # keep going a while past it to catch any late training arm.
        if s in (ST_NEGO_DONE, ST_ERROR) and _si(dut.nego_done) == 1:
            # dwell 2000 more cycles to prove nothing re-arms training
            for _ in range(2000):
                await RisingEdge(dut.clk)
                if _si(dut.local_training_mode_set) == 1:
                    saw_train_set = True
                if _si(dut.train_in_progress_o) == 1:
                    saw_train_inprog = True
                max_state = max(max_state, _si(st.state_r))
            break

    final_state = _si(st.state_r)
    log.info(
        f"final: state_r={final_state} nego_done={_si(dut.nego_done)} "
        f"nego_lost={_si(dut.nego_lost)} nego_won={_si(dut.nego_won)} "
        f"nego_error={_si(dut.nego_error)} set_role_lock_seen(role_lock via "
        f"force_lock) | max_state={max_state} saw_claim={saw_claim} "
        f"saw_nego_poll={saw_nego_poll} saw_train_set={saw_train_set} "
        f"saw_train_inprog={saw_train_inprog}")

    # ── Non-vacuous context: the FSM genuinely ran the dead-I2C NEGO path ──
    assert saw_claim, (
        "FSM never reached ST_NEGO_CLAIM — it did not claim master, so the "
        "dead-I2C NACK path was never exercised (backoff/priority mis-set). "
        "This would make the reproduce vacuous.")
    assert saw_nego_poll, (
        "FSM never reached ST_NEGO_POLL — the I2C peer transaction never ran, "
        "so no NACK was observed. Reproduce would be vacuous.")
    assert final_state == ST_NEGO_DONE, (
        f"FSM did not park in ST_NEGO_DONE (got state_r={final_state}). The "
        f"dead-I2C NACK arm (tidelink_autoneg.sv ~:1024, TRAIN_ENTRY_FALLBACK=0 "
        f"-> ST_NEGO_DONE) is the modelled park; a different terminal means the "
        f"stimulus diverged from the bare-link mechanism.")
    assert _si(dut.nego_lost) == 1, (
        "nego_lost != 1 — the terminal was not reached via the peer-NACK arm.")

    # ── THE REPRODUCE ORACLE (must FAIL on current RTL) ──
    # A healthy autonomous bring-up MUST light the SYNC beacon to deliver data:
    # it pulses local_training_mode_set, which raises swi_training_mode_r, which
    # arms the SYNC-config one-shot (insert_en=1). On the dead-I2C bare-link
    # with TRAIN_ENTRY_FALLBACK=0 this NEVER happens -> beacon dark -> all-zeros.
    assert saw_train_set, (
        "BUG REPRODUCED: dead-I2C NEGO bare-link parked in ST_NEGO_DONE via the "
        "peer-NACK arm WITHOUT ever pulsing local_training_mode_set. "
        "swi_training_mode_r therefore never rises, the autonomous SYNC-config "
        "one-shot (axi_chiplet_controller.sv:2283) never fires, "
        "swi_sync_insert_en_r stays 0 (SYNC beacon DARK), lane_mask stays 0xFF "
        "and tol stays 0 -> RX deskew never re-anchors -> master->slave AXI "
        "writes read ALL-ZEROS. (train_auto_en was 1: training WAS requested.) "
        f"[train_in_progress_o ever asserted={saw_train_inprog}, "
        f"max state_r reached={max_state} < ST_TRAIN_ENTER({ST_TRAIN_ENTER})]")

    log.info("VERDICT: local_training_mode_set pulsed — beacon armed on the "
             "dead-I2C path (bug is FIXED / not present).")

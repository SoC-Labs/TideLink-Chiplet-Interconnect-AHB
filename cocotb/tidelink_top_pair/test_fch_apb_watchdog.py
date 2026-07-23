"""FAIL-FIRST regression lock — FCH APB watchdog + PS-APB arbitration (f1b3aac port).

Reproduces, in miniature, the silicon lockout the f1b3aac port fixes: with the
fch sequencer in FCH_ACCESS and wl_apb_pready held LOW (the Wlink LL never
acking — as when the FCH_LL_SWRESET_ON 0x27f09 write has parked it in
swi_swreset), the pre-fix RTL pinned the external (PS) apb_pready low FOR EVER
(no arbitration term + no timeout), so every PS access to the 0x2xxx region hung
the Zynq-7000 M_AXI_GP with a Bus error. This test asserts the three properties
of the fix:

  1. ARBITRATION MASK — while fch_active_r=1 the external apb_pready is masked to
     0 EVEN WITH wl_apb_pready=1: a concurrent PS access is STALLED (normal APB
     backpressure), not completed against the sequencer's transaction. On the
     pre-fix RTL apb_pready reads 1 here (the protocol violation) => this
     assertion is the fail-first discriminator.
  2. WATCHDOG FIRES — after FCH_WDOG_LIMIT cycles of a hung wl_apb_pready the
     sequencer RELEASES the bus (fch_active_r->0), returns to FCH_IDLE, and
     latches the sticky, software-visible fch_stall_err_q + the failing
     fch_stall_widx_q (surfaced at FCH_OBS 0x4403_21BC[0]/[2:1]).
  3. MASK LIFTS — once the bus is released apb_pready follows wl_apb_pready
     again, proving the mask is BOUNDED by the watchdog and can never become the
     permanent lockout it replaces.

On the PRE-FIX RTL the fch_wdog_r / fch_stall_err_q signals do not exist and the
apb_pready mask lacks the fch_active_r term, so this test cannot false-PASS.

Cost: the FCH_ACCESS entry and the watchdog counter are PRELOADED via Force
(wdog set to FCH_WDOG_LIMIT - a few) so the test costs ~tens of cycles instead
of the ~500k the real ~10 ms timeout would take — it NEVER hangs the sim.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 TB_TOP_NO_DUMP=1 COCOTB_RESOLVE_X=ZEROS \
      SIM_BUILD=sim_build_fchwdog SIM=vcs \
      make MODULE=test_fch_apb_watchdog
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from test_31_autonomous_training_exit import _ctrl, _si, _idle_stimulus, _reset

# fch FSM state encodings — MUST match axi_chiplet_controller.sv localparams.
FCH_IDLE, FCH_SETUP, FCH_ACCESS, FCH_GAP = 0, 1, 2, 3
# MUST match the FCH_WDOG_LIMIT localparam in axi_chiplet_controller.sv.
FCH_WDOG_LIMIT = 500_000


@cocotb.test()
async def test_fch_apb_watchdog_fires_and_masks(dut):
    log = dut._log
    tb = PairTB(dut)                      # starts hclk / ref_clk
    await _idle_stimulus(dut)             # both dies' APB/AHB idle (slv_apb inactive)
    await _reset(dut)
    await ClockCycles(dut.hclk, 20)

    mc = _ctrl(dut, "m")                  # die_a MASTER controller

    # ---- Phase 0: baseline — bus free, PS apb_pready passes wl_apb_pready ------
    mc.wl_apb_pready.value = Force(1)
    await ClockCycles(dut.hclk, 2)
    assert _si(mc.fch_active_r) == 0, \
        "precondition: the fch sequencer must be IDLE at boot"
    assert _si(mc.apb_pready) == 1, (
        f"baseline: with the bus free, apb_pready must pass wl_apb_pready=1 — "
        f"got {_si(mc.apb_pready)}")

    # ---- Phase 1: ARBITRATION MASK (the fail-first discriminator) --------------
    # Sequencer owns the bus (fch_active_r=1) with the LL 'acking' (pready=1).
    # apb_pready + apb_pslverr MUST be masked to 0 (a PS access is STALLED). The
    # pre-fix RTL (apb_pready = slv_apb_active ? 0 : wl_apb_pready) reads 1 here.
    mc.fch_active_r.value = Force(1)
    await ClockCycles(dut.hclk, 2)
    assert _si(mc.apb_pready) == 0, (
        f"ARBITRATION: apb_pready must be masked to 0 while fch_active_r=1 even "
        f"with wl_apb_pready=1 (the PS access must STALL, not complete against "
        f"the sequencer's transaction) — got {_si(mc.apb_pready)}. Pre-fix RTL "
        f"reads 1 = the silicon lockout's APB protocol violation.")
    assert _si(mc.apb_pslverr) == 0, \
        "ARBITRATION: apb_pslverr must also be masked to 0 while fch_active_r=1"
    mc.fch_active_r.value = Release()

    # ---- Phase 2: WATCHDOG FIRES on a hung wl_apb_pready in FCH_ACCESS ----------
    # Drive the sequencer INTO FCH_ACCESS with a hung LL (pready=0) and the wdog
    # counter preloaded near its limit; then let the FSM run. It must count to
    # FCH_WDOG_LIMIT, RELEASE the bus, return to FCH_IDLE, and latch the sticky
    # error + the failing write index — instead of pinning fch_active_r high.
    STALL_WIDX = 1                                   # pretend SWRESET_OFF (widx 1) hung
    mc.wl_apb_pready.value = Force(0)                # LL never acks (swi_swreset held)
    mc.fch_widx_r.value    = Force(STALL_WIDX)
    mc.fch_state_r.value   = Force(FCH_ACCESS)
    mc.fch_active_r.value  = Force(1)
    mc.fch_wdog_r.value    = Force(FCH_WDOG_LIMIT - 6)
    await ClockCycles(dut.hclk, 1)
    # release the FSM-driven regs; the hung pready + widx stay forced (stimulus).
    mc.fch_state_r.value  = Release()
    mc.fch_active_r.value = Release()
    mc.fch_wdog_r.value   = Release()
    assert _si(mc.fch_state_r) == FCH_ACCESS, "setup: sequencer not in FCH_ACCESS"
    assert _si(mc.fch_active_r) == 1, "setup: sequencer not owning the bus"
    assert _si(mc.fch_stall_err_q) == 0, \
        "setup: sticky error must be CLEAR before the watchdog fires"

    fired = False
    for _ in range(40):                              # << the ~500k real timeout
        await ClockCycles(dut.hclk, 1)
        if _si(mc.fch_stall_err_q) == 1:
            fired = True
            break
    assert fired, (
        "WATCHDOG: fch_stall_err_q never latched — the FCH_ACCESS watchdog did "
        "not fire on a hung wl_apb_pready. Pre-fix, the sequencer pins "
        "fch_active_r high for ever, taking the PS<->PL bus down = the lockout.")
    assert _si(mc.fch_active_r) == 0, \
        "WATCHDOG: the bus was NOT released (fch_active_r still 1) after firing"
    assert _si(mc.fch_state_r) == FCH_IDLE, \
        "WATCHDOG: sequencer did not return to FCH_IDLE after the abort"
    assert _si(mc.fch_stall_widx_q) == STALL_WIDX, (
        f"WATCHDOG: fch_stall_widx_q must capture the failing write index "
        f"{STALL_WIDX}, got {_si(mc.fch_stall_widx_q)}")

    # ---- Phase 3: MASK LIFTS once the bus is released (bounded, not permanent) --
    mc.wl_apb_pready.value = Force(1)
    await ClockCycles(dut.hclk, 2)
    assert _si(mc.fch_active_r) == 0, \
        "post-abort: sequencer must stay IDLE (no re-arm without autonomy)"
    assert _si(mc.apb_pready) == 1, (
        f"MASK-LIFT: apb_pready must follow wl_apb_pready again once the bus is "
        f"released (the mask is bounded by the watchdog) — got "
        f"{_si(mc.apb_pready)}")

    # ---- Phase 4: STICKY — the error survives further cycles (POR-cleared only) -
    await ClockCycles(dut.hclk, 50)
    assert _si(mc.fch_stall_err_q) == 1, \
        "STICKY: fch_stall_err_q must remain set (sticky until POR)"

    mc.wl_apb_pready.value = Release()
    mc.fch_widx_r.value    = Release()
    log.info("FCH APB watchdog regression lock PASSED: mask-while-active, "
             "watchdog fires+releases+latches widx, mask-lifts, sticky error.")

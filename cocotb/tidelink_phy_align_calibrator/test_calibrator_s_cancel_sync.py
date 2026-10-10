"""test_calibrator_s_cancel_sync -- H31 (2026-10-01): the S_CANCEL exit must use
the 2-flop-synchronised swreset (swreset_sync = swreset_s2), not the raw
apb-domain input.

Contract: after the calibrator has been cancelled by swreset (S_CANCEL), the
state must NOT leave S_CANCEL until swreset has deasserted AND propagated
through the 2-flop synchroniser.  Measured from the first rising clk edge that
samples swreset==0 (call it edge E1, the edge s1 captures 0):
  RAW (pre-H31):  nxt_state is decided from the raw pin at E1 -> state leaves
                  S_CANCEL at E1 (visible on the next sample).
  SYNC (H31):     s1 captures 0 at E1, s2 at E2, state leaves at E3, i.e. two
                  clocks later than RAW.
The test asserts the exit latency is >= RAW_LATENCY + 2 clocks, and that a
swreset deassert is still honoured eventually (S_CANCEL -> S_ARM).

Runs against the deployed v2 calibrator through tb_top_deps (CAL_RTL=v2).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

S_ARM    = 1
S_CANCEL = 5
# Edges between driving swreset=0 and the first sampled state != S_CANCEL when the
# exit is decided from the RAW pin (pre-H31). Pinned by the red run on base.
RAW_LATENCY = 2
SYNC_EXTRA  = 2     # two synchroniser flops


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.min_lock_dwells_i.value     = 0
    dut.eye_lane_sel.value          = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_s_cancel_exit_uses_synchronised_swreset(dut):
    await _start(dut)
    dut.role_locked.value = 1
    # let the sweep start, then cancel it with swreset (the compute path:
    # recal / autoneg hold drives swreset while the calibrator is mid-sweep)
    for _ in range(40):
        await RisingEdge(dut.clk)
    assert int(dut.state.value) not in (0, S_CANCEL), "calibrator never left S_IDLE"
    dut.swreset.value = 1
    seen = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.state.value) == S_CANCEL:
            seen = True
            break
    assert seen, "swreset=1 did not drive the FSM into S_CANCEL"
    # stays cancelled while swreset is held high
    for _ in range(10):
        await RisingEdge(dut.clk)
        assert int(dut.state.value) == S_CANCEL, "left S_CANCEL with swreset still high"

    # deassert; count edges until the FSM leaves S_CANCEL
    await RisingEdge(dut.clk)
    dut.swreset.value = 0
    lat = None
    for n in range(1, 20):
        await RisingEdge(dut.clk)
        if int(dut.state.value) != S_CANCEL:
            lat = n
            break
    assert lat is not None, "S_CANCEL never exited after swreset deassert"
    dut._log.info(f"[H31] S_CANCEL exit latency after swreset fall = {lat} clk "
                  f"(raw={RAW_LATENCY}, synchronised={RAW_LATENCY + SYNC_EXTRA})")
    assert lat >= RAW_LATENCY + SYNC_EXTRA, (
        f"H31 REPRODUCED: S_CANCEL exited {lat} clk after swreset fell; the "
        f"synchronised level needs >= {RAW_LATENCY + SYNC_EXTRA}. The exit is "
        f"reading the raw apb-domain swreset (bypassing swreset_s1/s2).")
    # and it still exits (to S_ARM and onward), not stuck
    assert int(dut.state.value) in (S_ARM, 2, 7, 0xA, 0xB), \
        f"unexpected state {int(dut.state.value)} after S_CANCEL exit"

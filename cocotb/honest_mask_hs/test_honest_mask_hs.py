"""PENDING-DECISION #4 — HONEST_MASK_HS: real peer-mask handshake + lockable APB.

Reads the mask-handshake nets AT THE CONTROLLER after reset, with BOTH top-level
straps driven to 0 (a production/ASIC posture):

  MODE=legacy (HONEST_MASK_HS=0): controller.apb_debug_unlock_i==1 and
        .mask_hs_bypass_i==1 despite top straps=0  -> mask_hs_gate_open==1
        (forced open: peer-mask handshake bypassed, APB debug permanently
        unlocked).  This is the chip-killer posture.
  MODE=honest (HONEST_MASK_HS=1): controller sees the real straps (==0) ->
        mask_hs_gate_open==mask_hs_match==0 (handshake genuinely gates; APB debug
        is LOCKED/lockable).
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE = os.environ.get("HONEST_MODE", "legacy")


def ctrl(dut):
    return dut.u_dut.u_chiplet_controller


@cocotb.test()
async def test_honest_mask_hs(dut):
    cocotb.start_soon(Clock(dut.hclk, 10, units="ns").start())

    # Drive BOTH straps to 0 (production posture: no bypass, debug locked)
    dut.apb_debug_unlock_i.value = 0
    dut.mask_hs_bypass_i.value = 0
    dut.hresetn.value = 0
    dut.poresetn.value = 0
    for _ in range(8):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    dut.poresetn.value = 1
    for _ in range(6):
        await RisingEdge(dut.hclk)

    c = ctrl(dut)
    unlock = int(c.apb_debug_unlock_i.value)
    bypass = int(c.mask_hs_bypass_i.value)
    gate = c.mask_hs_gate_open.value
    match = c.mask_hs_match.value
    dut._log.info(f"[{MODE}] top straps=0 -> controller: apb_debug_unlock_i={unlock}, "
                  f"mask_hs_bypass_i={bypass}, mask_hs_match={match}, gate_open={gate}")

    if MODE == "honest":
        # Real straps reach the controller (both 0)
        assert unlock == 0, f"HONEST: controller apb_debug_unlock_i must follow strap (0), got {unlock}"
        assert bypass == 0, f"HONEST: controller mask_hs_bypass_i must follow strap (0), got {bypass}"
        # Handshake genuinely gates: with no handshake run, match=0 -> gate closed
        assert gate.is_resolvable and int(gate) == 0, (
            f"HONEST: mask_hs_gate_open must follow the handshake (0 when no match), got {gate}")
        dut._log.info("HONEST confirmed: straps honoured, gate follows the peer-mask "
                      "handshake, APB debug is lockable.")
    else:  # legacy (default)
        # Straps are IGNORED — controller sees the historical 1'b1 ties
        assert unlock == 1, (
            f"LEGACY: controller apb_debug_unlock_i must be forced 1 (tie) despite "
            f"strap=0; got {unlock}")
        assert bypass == 1, (
            f"LEGACY: controller mask_hs_bypass_i must be forced 1 (tie) despite "
            f"strap=0; got {bypass}")
        assert int(gate) == 1, f"LEGACY: mask_hs_gate_open must be forced open (1), got {gate}"
        dut._log.info("LEGACY confirmed: straps ignored, gate FORCED open, APB debug "
                      "permanently unlocked (the chip-killer posture).")

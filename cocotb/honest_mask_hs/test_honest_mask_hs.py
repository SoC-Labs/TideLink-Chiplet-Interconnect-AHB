"""DECISION #2 (David, 2026-07-19) — debug UNLOCKED, peer-mask handshake HONEST.

Reads the mask-handshake nets AT THE CONTROLLER after reset, with BOTH top-level
straps driven to 0 (a production/ASIC posture).

THE SPLIT WORKS, BUT IT IS NOT SUFFICIENT — the headline finding of this file.
tidelink_top used to fold two selects into one param; they are now independent
(HONEST_MASK_HS / DEBUG_UNLOCK_DEFAULT). But there is a SECOND, deeper coupling
in the controller itself:

    axi_chiplet_controller.sv:658
      wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i;

apb_debug_unlock_i is OR'd straight into the gate. So "debug UNLOCKED" alone
forces mask_hs_gate_open=1 no matter what HONEST_MASK_HS does. The requested
combination — debug unlocked AND handshake honest — is therefore UNREACHABLE by
the parameter split alone. Proven by MODE=default below.

  MODE=legacy  (HONEST_MASK_HS=0, DEBUG_UNLOCK_DEFAULT=1) — the OLD folded
        default: controller sees unlock==1 AND bypass==1 despite straps=0,
        gate FORCED open. This is the RED reference.
  MODE=default (NO override; the SHIPPED defaults, 1/1) — the split has landed:
        bypass now follows the REAL strap (==0) while unlock stays 1 as David
        asked. But gate_open is STILL 1, via the apb_debug_unlock_i term. The
        handshake does NOT gate. This is the finding, asserted so it cannot
        silently change.
  MODE=honest_locked (HONEST_MASK_HS=1, DEBUG_UNLOCK_DEFAULT=0) — both straps
        reach the controller as 0 -> gate_open==0. Proves the handshake CAN
        genuinely gate once the debug-unlock term is out of the way, i.e. the
        split is correct and the residual blocker is purely the :658 OR.

CONSEQUENCE (why this is not a free change): mask_hs_gate_open also gates the SW
ROLE_CFG W1S role-lock (axi_chiplet_controller.sv:753,758) and the pending-lock
latch (:717). A genuinely-closed gate with mask_hs_match==0 means SW can never
latch role_lock -> role_locked never asserts -> Wlink held in reset -> link dead.
That is exactly why the strap was force-1 originally. Shipping a truly honest
handshake requires the autoneg mask_hs_local_match path to actually close on the
bring-up path first.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE = os.environ.get("HONEST_MODE", "default")


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

    if MODE == "default":
        # THE SHIPPED POSTURE — no parameter override; tidelink_top's own defaults.
        assert unlock == 1, (
            f"REGRESSION: David asked to ship debug UNLOCKED; controller "
            f"apb_debug_unlock_i must be 1, got {unlock}")
        assert bypass == 0, (
            f"SPLIT BROKEN: HONEST_MASK_HS=1 must let the real strap (0) reach "
            f"controller mask_hs_bypass_i; got {bypass}")
        # The finding, pinned so it cannot regress silently in either direction.
        assert int(gate) == 1, (
            f"gate_open expected 1 here: apb_debug_unlock_i is OR'd into it at "
            f"axi_chiplet_controller.sv:658. Got {gate} — if this is now 0 the "
            f":658 term was changed; re-check SW ROLE_CFG role-lock (:758).")
        dut._log.info(
            "DEFAULT confirmed: split landed (bypass follows the real strap) and "
            "debug stays UNLOCKED — but gate_open is STILL 1 via the "
            "apb_debug_unlock_i term at axi_chiplet_controller.sv:658, so the "
            "peer-mask handshake does NOT yet gate. Debug-unlocked AND "
            "handshake-honest is unreachable without changing that OR.")
    elif MODE == "honest_locked":
        # Both straps reach the controller as 0 -> the handshake genuinely gates.
        assert unlock == 0, f"HONEST_LOCKED: controller apb_debug_unlock_i must follow strap (0), got {unlock}"
        assert bypass == 0, f"HONEST_LOCKED: controller mask_hs_bypass_i must follow strap (0), got {bypass}"
        assert gate.is_resolvable and int(gate) == 0, (
            f"HONEST_LOCKED: mask_hs_gate_open must follow the handshake "
            f"(0 with no match), got {gate}")
        dut._log.info(
            "HONEST_LOCKED confirmed: with BOTH straps 0 the gate CLOSES "
            "(gate_open=0, match=0) — the handshake genuinely gates. Note this "
            "posture also blocks the SW ROLE_CFG W1S role-lock (:758).")
    elif MODE == "honest_unlocked":
        # PENDING (DECISION #2) — the combination that a single folded param
        # made UNREACHABLE: peer-mask handshake HONEST while APB debug stays
        # UNLOCKED. Proves the two selects are genuinely independent.
        assert unlock == 1, (
            f"HONEST_UNLOCKED: DEBUG_UNLOCK_DEFAULT=1 must keep controller "
            f"apb_debug_unlock_i tied 1; got {unlock}")
        assert bypass == 0, (
            f"HONEST_UNLOCKED: HONEST_MASK_HS=1 must let the real strap (0) "
            f"reach controller mask_hs_bypass_i; got {bypass}")
        dut._log.info("HONEST_UNLOCKED confirmed: handshake strap honoured while "
                      "APB debug stays unlocked — the two selects are independent.")
    elif MODE == "honest":
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

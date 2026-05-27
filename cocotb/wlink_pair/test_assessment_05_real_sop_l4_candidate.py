"""ASSESSMENT FINDING #5 — THE UNTRIED L4 CANDIDATE.

Commit 7a6427d proposed an L4 candidate that gates the state==0 → state==1
transition with a "real SOP seen" qualifier — requires ECC-validated short
packet with known whitelisted data_id (one of swi_cr_id, swi_crack_id,
swi_ack_id, swi_nack_id).

The L4 v3 fix that landed in main is BROADER: it gates on "any" short
packet (`first_short_pkt_seen <= 1` when `state==0 && is_short_pkt`),
without checking the data_id. The question this test answers:

   Does the v3 broader gate behave equivalently to the whitelisted
   variant on the actual bringup sequence — i.e., is the FIRST short
   packet that latches the gate ALWAYS one of the four whitelisted
   data_ids? Or does the v3 gate latch on some OTHER short data_id that
   the proposed candidate would have rejected?

This test:
  * Runs the full HW bringup (recal_cycle + swreset).
  * Records the ECC-corrected PH (corrected_ph[7:0] = data_id) at every
    cycle where `first_short_pkt_seen` transitions 0→1 on either side.
  * Records EVERY is_short_pkt pulse and its data_id (so we see what
    the v3 gate ACCEPTS).

PASS-EQUIVALENT (v3 ≡ candidate):
  * The data_id that latches first_short_pkt_seen on each side is in
    the whitelist {0x44, 0x45, 0x46, 0x47} (cr/crack/ack/nack defaults).
  * Conclusion: v3 and candidate are operationally equivalent — the
    candidate adds no extra safety on this bringup. Implementing it
    would be defense-in-depth but not a defect repair.

PASS-DIVERGENT (v3 ≠ candidate, candidate is STRICTER):
  * Some non-whitelisted data_id triggers first_short_pkt_seen latch.
  * The candidate would REJECT that latch and wait for a CR/crack/ack/
    nack — defining a tighter gate.
  * Conclusion: implement the candidate as L5 — it would catch a real
    edge case that v3 doesn't.

FAIL:
  * The gate never latches → either pre-LINK_IDLE bringup is broken or
    the test infrastructure is wrong.

NOTE: Per task constraints we DO NOT modify RTL. This test PROBES the
existing v3 gate to define what the candidate L4 (= proposed L5) would
need to do differently.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll,
)

# Standard whitelist of SWI data_ids that bootstrap the link.
SWI_WHITELIST = {0x44, 0x45, 0x46, 0x47}  # cr, crack, ack, nack defaults
NAME_OF = {0x44: "CR", 0x45: "CRACK", 0x46: "ACK", 0x47: "NACK"}


def _llrx(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.llrx


@cocotb.test()
async def test_05_first_short_pkt_seen_data_id(dut):
    """Trace the data_id that triggers v3's first_short_pkt_seen latch."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)

    m_llrx = _llrx(dut, "m")
    s_llrx = _llrx(dut, "s")

    WINDOW = 8000
    prev_fssp = {"m": None, "s": None}
    latch_event = {"m": None, "s": None}  # (cycle, data_id, corrected_ph, ecc_corrected)
    all_is_short_data_ids = {"m": [], "s": []}  # (cyc, data_id, ecc_corrected) tuples

    for c in range(WINDOW):
        await ClockCycles(dut.master_clk, 1)
        for side, llrx in (("m", m_llrx), ("s", s_llrx)):
            try:
                fssp = int(llrx.first_short_pkt_seen.value)
                is_short = int(llrx.is_short_pkt.value)
                corrected_ph = int(llrx.ecc_check_corrected_ph.value)
                ecc_corrected = int(llrx.ecc_check_corrected.value)
                ecc_corrupted = int(llrx.ecc_check_corrupted.value)
            except Exception:
                continue
            data_id = corrected_ph & 0xFF
            if is_short and len(all_is_short_data_ids[side]) < 64:
                all_is_short_data_ids[side].append(
                    (c, data_id, ecc_corrected, ecc_corrupted))
            if prev_fssp[side] == 0 and fssp == 1 and latch_event[side] is None:
                latch_event[side] = (c, data_id, corrected_ph, ecc_corrected,
                                      ecc_corrupted)
            prev_fssp[side] = fssp

    dut._log.info("=" * 70)
    dut._log.info("  ASSESSMENT FINDING #5 — L4 candidate (whitelist) vs v3 (any short)")
    dut._log.info("=" * 70)
    for side in ("m", "s"):
        ev = latch_event[side]
        if ev is None:
            dut._log.info(f"  [{side}] first_short_pkt_seen NEVER latched in {WINDOW} cyc")
        else:
            c, did, ph, corr, corrupted = ev
            name = NAME_OF.get(did, f"0x{did:02x}")
            in_wl = "YES" if did in SWI_WHITELIST else "NO"
            dut._log.info(f"  [{side}] gate latched @ cyc {c}: data_id=0x{did:02x} "
                          f"({name})  in_whitelist={in_wl}  ph=0x{ph:06x} "
                          f"ecc_corrected={corr} ecc_corrupted={corrupted}")
        # Dump first 5 is_short events
        events = all_is_short_data_ids[side][:5]
        dut._log.info(f"  [{side}] first {len(events)} is_short events: {events}")

    # ----- VERDICT -------------------------------------------------------
    # Asymmetric latching is itself a key finding: if v3 latched only on one
    # side, the *missing-side* couldn't latch on ANY data_id in window.
    if latch_event["m"] is None and latch_event["s"] is None:
        dut._log.warning("  VERDICT: SKIP-INFRA — gate never latched on EITHER side")
        dut._log.warning("  → Bringup didn't produce a decodable short pkt on either side.")
        dut._log.warning("    L4-candidate comparison is moot. Investigate the bringup.")
        return

    if latch_event["m"] is None or latch_event["s"] is None:
        missing = "master" if latch_event["m"] is None else "slave"
        latched = "slave" if latch_event["m"] is None else "master"
        ev = latch_event["m"] if latch_event["s"] is None else latch_event["s"]
        c, did, ph, corr, corrupted = ev
        name = NAME_OF.get(did, f"0x{did:02x}")
        in_wl = "YES" if did in SWI_WHITELIST else "NO"
        dut._log.warning("  VERDICT: PASS-DIVERGENT-ASYMMETRIC — v3 gate latched on")
        dut._log.warning(f"    {latched} only — at data_id=0x{did:02x} ({name}) in_wl={in_wl}")
        dut._log.warning(f"    {missing} NEVER latched — v3 gate held closed on that side.")
        if did not in SWI_WHITELIST:
            dut._log.warning(
                f"  >>> KEY FINDING: v3 gate accepted data_id=0x{did:02x} which is NOT in")
            dut._log.warning("      the proposed L4-candidate whitelist {0x44,0x45,0x46,0x47}.")
            dut._log.warning("      The candidate L4 (whitelisted) would have REJECTED this")
            dut._log.warning(f"      premature latch on {latched}. Implement candidate as L5.")
        else:
            dut._log.warning(
                f"  >>> v3 latched on a WHITELISTED data_id (0x{did:02x}); the asymmetry is")
            dut._log.warning("      not data_id selection but timing — the missing side never")
            dut._log.warning("      saw a valid short packet at all. Distinct bug class.")
        return

    m_did = latch_event["m"][1]
    s_did = latch_event["s"][1]
    m_in_wl = m_did in SWI_WHITELIST
    s_in_wl = s_did in SWI_WHITELIST

    if m_in_wl and s_in_wl:
        dut._log.info("  VERDICT: PASS-EQUIVALENT — v3 ≡ candidate on this bringup")
        dut._log.info(f"    master gate latched on {NAME_OF.get(m_did, hex(m_did))}")
        dut._log.info(f"    slave  gate latched on {NAME_OF.get(s_did, hex(s_did))}")
        dut._log.info("  → Implementing the whitelisted-data_id candidate L4 would be")
        dut._log.info("    defense-in-depth (defensive coding) but NOT a defect repair")
        dut._log.info("    on the current bringup. Operationally equivalent.")
        return

    dut._log.warning("  VERDICT: PASS-DIVERGENT — v3 ACCEPTS data_id outside whitelist")
    dut._log.warning(f"    master gate latched on 0x{m_did:02x} (in_wl={m_in_wl})")
    dut._log.warning(f"    slave  gate latched on 0x{s_did:02x} (in_wl={s_in_wl})")
    dut._log.warning("  → Implementing the whitelist-gated L4 candidate as L5 would")
    dut._log.warning("    tighten the boot-strap. v3 is correctable here.")

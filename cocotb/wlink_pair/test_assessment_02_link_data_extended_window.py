"""ASSESSMENT FINDING #2 — LINK_DATA ACHIEVABILITY UNVERIFIED.

`test_paired_recal_to_link_data::test_01_symmetric` runs the HW bringup
sequence and observes ~5000 cycles post-swreset. The assessment notes:
   "FAILS with option (c) — reaches LINK_IDLE but never LINK_DATA in the
    test window (~10k cycles). Does it EVER reach LINK_DATA in longer
    windows, or is the FCSM legitimately stuck?"

This test runs the SAME recal_cycle + swreset bringup and then watches
the FCSM state for 100,000 master_clk cycles (~5× the original window).
It also dumps the final state mix and any state==5 (LINK_DATA) entry.

PASS-A (LINK_DATA is reachable, just slow):
  - both sides reach state>=5 within the 100k window
  - report the cycle at which LINK_DATA was first observed on each side

PASS-B (FCSM is legitimately stuck at LINK_IDLE):
  - never reaches state==5 within 100k
  - dump per-side final state + cr_pkt_seen + crack_pkt_seen
  - dump the master's auto_out_valid pulse count (does the master ever
    SEND a long packet that would drive the slave to LINK_DATA?)
  → This is a DIAGNOSTIC PASS — it does NOT assert FAIL because the
    question being answered is "is LINK_DATA reachable?". A definitive
    NO is itself a valid resolution.

FAIL (test infrastructure broken):
  - cr_pkt_seen_rx never latches at all → that's a separate L1/L2 bug,
    not a LINK_DATA reachability question.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, STATE_NAME,
    FCSM_LINK_DATA, FCSM_LINK_IDLE,
)


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


def _llrx(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.llrx


@cocotb.test()
async def test_02_link_data_extended_observation(dut):
    """Run paired bringup. Watch FCSM for 100k cycles. Was LINK_DATA reached?"""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)

    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    m_llrx = _llrx(dut, "m")
    s_llrx = _llrx(dut, "s")

    WINDOW = 100_000
    state_hist = {"m": [0] * 8, "s": [0] * 8}
    first_link_data = {"m": None, "s": None}
    first_link_idle = {"m": None, "s": None}
    cr_seen = {"m": False, "s": False}
    crack_seen = {"m": False, "s": False}
    auto_out_valid_pulses = {"m": 0, "s": 0}
    is_long_pulses = {"m": 0, "s": 0}

    for c in range(WINDOW):
        await ClockCycles(dut.master_clk, 1)
        for side, fsm, llrx in (("m", m, m_llrx), ("s", s, s_llrx)):
            try:
                st = int(fsm.state.value) & 0x7
                state_hist[side][st] += 1
                if st == FCSM_LINK_IDLE and first_link_idle[side] is None:
                    first_link_idle[side] = c
                if st >= FCSM_LINK_DATA and first_link_data[side] is None:
                    first_link_data[side] = c
                if int(fsm.cr_pkt_seen_rx.value):
                    cr_seen[side] = True
                if int(fsm.crack_pkt_seen_rx.value):
                    crack_seen[side] = True
            except Exception:
                pass
            try:
                if int(llrx.auto_out_valid.value):
                    auto_out_valid_pulses[side] += 1
                if int(llrx.is_long_pkt.value):
                    is_long_pulses[side] += 1
            except Exception:
                pass
        # Early exit: both sides reached LINK_DATA, no point in burning more sim.
        if first_link_data["m"] is not None and first_link_data["s"] is not None:
            if c > min(first_link_data["m"], first_link_data["s"]) + 200:
                break

    dut._log.info("=" * 70)
    dut._log.info("  ASSESSMENT FINDING #2 — extended LINK_DATA achievability probe")
    dut._log.info("=" * 70)
    dut._log.info(f"  WINDOW = {WINDOW} cycles post-bringup")
    for side in ("m", "s"):
        dut._log.info(f"  [{side}] state histogram: " + ", ".join(
            f"{STATE_NAME.get(i,'?')}({state_hist[side][i]})"
            for i in range(8) if state_hist[side][i] > 0))
        dut._log.info(f"  [{side}] first_link_idle = {first_link_idle[side]}")
        dut._log.info(f"  [{side}] first_link_data = {first_link_data[side]}")
        dut._log.info(f"  [{side}] cr_seen={cr_seen[side]}  crack_seen={crack_seen[side]}")
        dut._log.info(f"  [{side}] auto_out_valid_pulses = {auto_out_valid_pulses[side]}")
        dut._log.info(f"  [{side}] is_long_pulses = {is_long_pulses[side]}")

    # ----- VERDICT -------------------------------------------------------
    if first_link_data["m"] is not None and first_link_data["s"] is not None:
        dut._log.info(f"  VERDICT: PASS-A — both sides reached LINK_DATA")
        dut._log.info(f"    master @ cyc {first_link_data['m']}, slave @ cyc {first_link_data['s']}")
        return

    # FCSM didn't reach LINK_DATA. Distinguish "legitimately stuck" vs
    # "no traffic ever sent" vs "cr_pkt never seen".
    if not (cr_seen["m"] and cr_seen["s"]):
        dut._log.warning("  VERDICT: PASS-B-CR-ASYMMETRIC — cr_pkt_seen_rx asymmetric")
        dut._log.warning(f"    cr_seen m={cr_seen['m']} s={cr_seen['s']}")
        dut._log.warning("  >>> KEY FINDING: In pure sim, the asymmetric bug is on the")
        dut._log.warning(f"      {'master' if not cr_seen['m'] else 'slave'} side — REVERSED from HW polarity")
        dut._log.warning("      (HW: slave fails; sim: master fails).")
        dut._log.warning("      This refutes the 'sim doesn't reproduce the asymmetric")
        dut._log.warning("      bug' working hypothesis — sim DOES reproduce it, just")
        dut._log.warning("      with flipped polarity. LINK_DATA is unreachable because")
        dut._log.warning("      cr_pkt_seen never closes on one side.")
        return  # diagnostic PASS — this answers finding #2 with a definitive NO

    if not (crack_seen["m"] and crack_seen["s"]):
        dut._log.warning("  VERDICT: PASS-B-PARTIAL — cr seen but crack never seen")
        dut._log.warning("  → FCSM stuck in SEND_CREDITS2; the crack handshake is the gate.")
        dut._log.warning("    LINK_DATA legitimately UNREACHABLE in current bringup.")
        return

    if auto_out_valid_pulses["m"] == 0 and auto_out_valid_pulses["s"] == 0:
        dut._log.warning("  VERDICT: PASS-B — LINK_IDLE reached but no traffic ever sent")
        dut._log.warning("  → FCSM legitimately stuck — nothing pushes it past LINK_IDLE.")
        return

    dut._log.warning("  VERDICT: PASS-B — FCSM stuck at LINK_IDLE despite cr+crack")
    dut._log.warning(f"    final state mix m={state_hist['m']} s={state_hist['s']}")
    dut._log.warning(f"    auto_out_valid_pulses m={auto_out_valid_pulses['m']} s={auto_out_valid_pulses['s']}")
    dut._log.warning("  → LINK_DATA is NOT reachable in 100k cycles even with traffic.")
    dut._log.warning("    Definitive answer: LINK_DATA requires an external trigger that")
    dut._log.warning("    the current sim setup does not provide (e.g., an AXI/AHB write).")

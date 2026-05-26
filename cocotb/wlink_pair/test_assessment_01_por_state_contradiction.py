"""ASSESSMENT FINDING #1 — DIAGNOSIS CONTRADICTION.

Phase0 docs/TIDELINK_PHASE0_OBS_20260524_2109.md §11 claims:
  "the link is half-handshaked with byte alignment intact at POR —
   bringup_pair_converge.sh actively breaks POR-aligned link via slot0=0x3 recal"

But the bisect log in src/rtl/local_overrides/WlinkRxLinkLayer.v lines 14-22
shows slave WlinkRxLinkLayer.state transitions 0→1 at sample-cycle 94 on a
"phony long packet expecting training filler" — and that observation was
made BEFORE swreset runs.

If both observations are literally true:
  - state goes 0→1 at POR window (bad — false latch on filler)
  - cr_pkt_seen_rx is intact at POR (good — implies framer recovered)
Then exactly one of: (a) the v3 first_short_pkt_seen gate now in main
prevents the 0→1-on-filler entirely, OR (b) §11's "alignment intact at
POR" is overstated, OR (c) the bisect's "before swreset" wording elides
that POR's own reset acts like a swreset.

This test drives ONLY POR (no slot0 writes, no swreset cycle, no
recal_cycle) and records every transition of the slave's WlinkRxLinkLayer
state register from t=0 onwards. It exits as soon as state leaves 0, OR
after a generous 5000-cycle observation window. Result table:

  - first_state1_cycle: master_clk cycle where slave state first == 1
  - first_state1_corrected_ph: ECC-corrected PH at that cycle
  - first_state1_is_short_pkt: 1 if first_short_pkt_seen gate held closed
  - first_state1_long_pkt_gate: state of the long_pkt_gate signal
  - cr_pkt_seen_rx after window: did slave latch CR-from-master at POR?

PASS criterion (CONFIRMS the L4 v3 RTL fix is doing its job at POR):
  - slave state stays at 0 for the ENTIRE 5000-cyc POR window, OR
  - if it leaves 0 → 1, the long_pkt_gate was OPEN (first_short_pkt_seen=1)
    indicating it was a real CR, not filler.

FAIL criterion (REFUTES one of §11's claims):
  - slave state transitions 0→1 while long_pkt_gate is closed
    (first_short_pkt_seen=0). That would mean the L4 v3 gate is bypassed
    by some other path and §11's "byte alignment intact at POR" is wrong.

NOTE: with the v3 fix in main, the EXPECTED result is the PASS branch —
which itself RESOLVES the contradiction: §11 is correct AT POR, but the
bisect observation in the RTL header was taken from a DIFFERENT RTL
(pre-v3) AND IS NO LONGER REPRODUCIBLE on current main.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


def _llrx(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.llrx


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


@cocotb.test()
async def test_01_por_only_slave_state_transition(dut):
    """POR-only window: no slot0 writes, no swreset. Watch slave state."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    s_llrx = _llrx(dut, "s")
    s_fcsm = _fcsm(dut, "s")

    first_state1_cycle = None
    first_state1_corrected_ph = None
    first_state1_long_pkt_gate = None
    first_state1_is_short_pkt = None
    first_state1_first_short_pkt_seen = None
    cr_seen_at_cycle = None
    max_state = 0
    transitions_log = []  # list of (cycle, old_state, new_state)
    prev_state = 0

    WINDOW = 5000
    for c in range(WINDOW):
        await ClockCycles(dut.master_clk, 1)
        try:
            state = int(s_llrx.state.value)
        except Exception:
            continue
        if state != prev_state:
            transitions_log.append((c, prev_state, state))
            prev_state = state
        if state > max_state:
            max_state = state
        if state == 1 and first_state1_cycle is None:
            first_state1_cycle = c
            try:
                first_state1_corrected_ph = int(s_llrx.ecc_check_corrected_ph.value)
            except Exception:
                first_state1_corrected_ph = -1
            try:
                first_state1_long_pkt_gate = int(s_llrx.long_pkt_gate.value)
            except Exception:
                first_state1_long_pkt_gate = -1
            try:
                first_state1_is_short_pkt = int(s_llrx.is_short_pkt.value)
            except Exception:
                first_state1_is_short_pkt = -1
            try:
                first_state1_first_short_pkt_seen = int(s_llrx.first_short_pkt_seen.value)
            except Exception:
                first_state1_first_short_pkt_seen = -1
        try:
            if int(s_fcsm.cr_pkt_seen_rx.value) and cr_seen_at_cycle is None:
                cr_seen_at_cycle = c
        except Exception:
            pass

    dut._log.info("=" * 70)
    dut._log.info("  ASSESSMENT FINDING #1 — POR-only contradiction probe")
    dut._log.info("=" * 70)
    dut._log.info(f"  WINDOW = {WINDOW} master_clk cycles, POR-only (no recal, no swreset)")
    dut._log.info(f"  slave max_state = {max_state}")
    dut._log.info(f"  slave state transitions: {transitions_log[:10]}{' ...' if len(transitions_log) > 10 else ''}")
    dut._log.info(f"  total slave transitions: {len(transitions_log)}")
    dut._log.info(f"  first_state1_cycle = {first_state1_cycle}")
    if first_state1_cycle is not None:
        dut._log.info(f"  @ first_state==1: corrected_ph=0x{first_state1_corrected_ph:06x}")
        dut._log.info(f"  @ first_state==1: long_pkt_gate={first_state1_long_pkt_gate}")
        dut._log.info(f"  @ first_state==1: is_short_pkt={first_state1_is_short_pkt}")
        dut._log.info(f"  @ first_state==1: first_short_pkt_seen={first_state1_first_short_pkt_seen}")
    dut._log.info(f"  slave cr_pkt_seen_rx_first_cycle = {cr_seen_at_cycle}")

    # ----- VERDICT -------------------------------------------------------
    if first_state1_cycle is None:
        # PASS-A: slave stays at state==0 the entire POR window.
        # This means §11's "byte alignment intact" is true in a vacuous
        # sense (no false latch occurs) AND the bisect's 0→1 at cyc 94
        # is not reproducible on current main.
        dut._log.info("  VERDICT: PASS-A — slave state stays at 0 for entire POR window")
        dut._log.info("  → §11 (POR-aligned link) and bisect (state==1 at cyc 94) are")
        dut._log.info("    reconciled: bisect was on PRE-v3 RTL; current v3 gate holds.")
        return

    if first_state1_first_short_pkt_seen == 1:
        # PASS-B: state==1 only after first_short_pkt_seen latched, i.e.,
        # a REAL CR triggered it. This is the desired bootstrap path.
        dut._log.info("  VERDICT: PASS-B — slave state==1 latched AFTER real short-pkt")
        dut._log.info("    (first_short_pkt_seen=1 at the same cycle). This is the")
        dut._log.info("    desired bootstrap path: real CR seen → gate open → state→1.")
        assert cr_seen_at_cycle is not None, (
            f"state==1 latched after first_short_pkt_seen, but cr_pkt_seen_rx never "
            f"latched in the {WINDOW}-cycle window. Possible FCSM gate issue.")
        return

    # FAIL: state==1 with the gate still closed. This refutes the v3 fix.
    dut._log.error("  VERDICT: FAIL — slave state==1 with long_pkt_gate=%d (closed)" % first_state1_long_pkt_gate)
    dut._log.error("  → v3 first_short_pkt_seen gate is BYPASSED on some path.")
    dut._log.error("  → §11's 'POR-aligned' claim is REFUTED — POR alone causes")
    dut._log.error("    a spurious state==1 latch from filler.")
    assert False, (
        f"slave state==1 at cycle {first_state1_cycle} with "
        f"long_pkt_gate={first_state1_long_pkt_gate} "
        f"first_short_pkt_seen={first_state1_first_short_pkt_seen} "
        f"corrected_ph=0x{first_state1_corrected_ph:06x} — v3 gate bypassed.")

"""An election CLAIM arriving at a die that cannot consume it must not wedge
that die's whole cross-die RX path.

Sibling of `test_tc_pair_election_datamode.py`, which proves the G1 data-mode
gate works when BOTH dies are armed together. This test covers the case that one
deliberately avoids: a CLAIM arriving at a peer whose election FSM is NOT in
ST_LISTEN — either never armed (ST_IDLE) or already finished (ST_SETTLED).

WHY THAT IS REACHABLE. `tl_data_mode_o` gates the RELEASE of an election, not its
ARMING. `election_start` (TC_CTRL[0]) is an independent software write per die,
and on the shipping chiplet nothing arms it automatically at all
(`tidechart/src/sw/tidechart.h` has zero includers), so arming is debugger- or
host-driven per die. Both an un-armed die and a die that settled more than one
LISTEN timeout ago are therefore ordinary states, not corners.

THE MECHANISM UNDER TEST, link by link:
  1. tidechart_election_fsm asserts claim_rx_accept in exactly ONE place
     (ST_LISTEN, :370). In ST_IDLE and ST_SETTLED it is held low.
  2. tidechart_crossbar:215 drives tc_axis_rx_tready from that accept whenever
     the wire subtype is ELECTION — `is_elect` is the FIRST arm of the priority
     mux and the ONLY arm with no state qualification (is_puf_rsp, is_bcast and
     enum are all gated).
  3. tidechart_shim is purely combinational, so nothing absorbs the stall.
  4. tidelink_fc_adapter's RX FSM never leaves RX_ADDR_PHASE (:666), so
     tl_fc_l2a_accept (:622-624) stays deasserted — and tl_fc_l2a is SHARED
     (:612-619) by the D2D RX data FIFO, TideChart, and the FC sideband APB
     config path. One undrainable beat takes out the die's whole inbound
     cross-die path, including the sideband path recovery would need.

WHAT IS MEASURED. Not "was accept ever high" — in a quiet window there is no
inbound traffic at all, so that says nothing. The wedge signature is:
  * the fc_adapter RX FSM stops returning to RX_IDLE (stuck in RX_ADDR_PHASE),
  * an ELECTION beat is PRESENTED at tc_axis_rx but never handshaken, and
  * tl_fc_l2a_valid goes high with tl_fc_l2a_accept low, and stays that way.

BOTH DIES ARE POLICED, because both non-listening states are reachable:
  PHASE 1 arms die A only -> die A floods -> the beat lands on die B in ST_IDLE.
  PHASE 2 arms die B      -> die B floods -> the beat lands on die A in ST_SETTLED.

VACUITY. Each phase FAILS LOUDLY if no ELECTION beat was actually presented to
the victim die. Without the trigger every assertion below would pass for the
wrong reason, and a green run would be a false negative rather than a clean bill.

EXPECTED OUTCOME WITH THE FIX. The victim drains and discards the claim, so both
dies end up settled and both believe they are root: a DUAL-ROOT. That is the
known, separately-tracked protocol gap (a non-listening node has no defined
response to a late claim) and is NOT what this test polices. Draining converts a
hard wedge into a benign dual-root; closing the protocol gap is separate work.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import PairTB
from test_tc_pair_election_datamode import (
    TCApb, TC_STATUS, TC_CTRL, TC_TIMEOUT, TC_DEVICE_CLASS,
    ST_SETTLED, ST_NAMES, PKT_EXT, SUBTYPE_ELECTION,
    _election_state, _own_random, _best_claim,
)

# LISTEN window (cycles). Identical to the sibling test.
ELECTION_TIMEOUT = 0x0800


class FcRxHealth:
    """Per-die watch on the signals that go dead when the shared FC RX wedges."""

    RX_IDLE = 0

    def __init__(self, dut, clk, top, tvalid, tready, tdata, name):
        self.clk, self.name = clk, name
        self.accept = top.u_fc_adapter.tl_fc_l2a_accept
        self.l2a_valid = top.u_fc_adapter.tl_fc_l2a_valid
        self.rx_state = top.u_fc_adapter.rx_state_r
        self.tvalid, self.tready, self.tdata = tvalid, tready, tdata
        self.reset_counts()
        self._run = True

    def reset_counts(self):
        self.cycles = 0
        self.rx_idle = 0          # cycles the fc_adapter RX FSM sat in RX_IDLE
        self.l2a_valid_hi = 0     # cycles the shared channel presented a word
        self.l2a_stall = 0        # ...of those, cycles it was NOT accepted
        self.elect_presented = 0  # cycles an ELECTION beat was offered at tc_axis_rx
        self.elect_xfer = 0       # ELECTION beats actually handshaken

    async def run(self):
        while self._run:
            await RisingEdge(self.clk)
            self.cycles += 1
            try:
                if int(self.rx_state.value) == self.RX_IDLE:
                    self.rx_idle += 1
            except ValueError:
                pass
            try:
                if int(self.l2a_valid.value):
                    self.l2a_valid_hi += 1
                    if not int(self.accept.value):
                        self.l2a_stall += 1
            except ValueError:
                pass
            try:
                v = int(self.tvalid.value)
                d = int(self.tdata.value)
            except ValueError:
                continue
            if v and ((d >> 46) & 0b11) == PKT_EXT and \
                     ((d >> 32) & 0x3FFF) == SUBTYPE_ELECTION:
                self.elect_presented += 1
                try:
                    if int(self.tready.value):
                        self.elect_xfer += 1
                except ValueError:
                    pass

    def stop(self):
        self._run = False

    def summary(self):
        return (f"{self.name}: rx_idle={self.rx_idle}/{self.cycles} "
                f"l2a_valid={self.l2a_valid_hi} l2a_stall={self.l2a_stall} "
                f"elect_presented={self.elect_presented} elect_xfer={self.elect_xfer}")


def _check_not_wedged(h, victim_state, log):
    """Assert a die that was offered an ELECTION beat is still draining."""
    assert h.elect_presented > 0, (
        f"VACUOUS: no ELECTION beat was ever presented to {h.name}'s tc_axis_rx "
        f"while it was in {victim_state}, so the wedge trigger never occurred and "
        f"this phase proves NOTHING. Do not read a pass here as the bug being "
        f"absent — investigate the crossing first. ({h.summary()})")

    assert h.elect_xfer > 0, (
        f"WEDGE ({h.name}, {victim_state}): {h.elect_presented} ELECTION beat-cycles "
        f"were presented and NONE were handshaken. tc_axis_rx_tready is stuck low — "
        f"tidechart_election_fsm asserts claim_rx_accept only in ST_LISTEN, and "
        f"tidechart_crossbar:215 routes election beats to that dead accept "
        f"unconditionally. ({h.summary()})")

    assert h.rx_idle > 0, (
        f"WEDGE ({h.name}, {victim_state}): the fc_adapter RX FSM never returned to "
        f"RX_IDLE in {h.cycles} cycles — it is stuck in RX_ADDR_PHASE waiting on a "
        f"tc_axis_rx_tready that will never come (tidelink_fc_adapter.sv:666). "
        f"tl_fc_l2a_accept is therefore dead, and with it the D2D RX data FIFO, "
        f"TideChart, and the FC sideband APB config path. ({h.summary()})")

    log.info(f"  [{h.name} @ {victim_state}] NOT WEDGED — {h.summary()}")


async def _arm_and_settle(tc, dut, prefix, log, tries=400):
    await tc.write(TC_CTRL, 0x1)
    done = root = 0
    for _ in range(tries):
        await ClockCycles(dut.hclk, 100)
        st = await tc.read(TC_STATUS)
        done, root = st & 1, (st >> 1) & 1
        if done:
            break
    log.info(f"[arm {prefix}] done={done} is_root={root} "
             f"FSM={ST_NAMES.get(_election_state(dut, prefix))} "
             f"best=0x{_best_claim(dut, prefix):08x} own=0x{_own_random(dut, prefix):04x}")
    return done, root


@cocotb.test()
async def test_tc_pair_late_claim(dut):
    log = dut._log
    tb = PairTB(dut)
    m_tc = TCApb(dut, dut.hclk, "m")
    s_tc = TCApb(dut, dut.hclk, "s")

    await tb.reset()
    tb.force_calibrator_sim_bypass()

    dev = await m_tc.read(TC_DEVICE_CLASS)
    assert (dev & 0xFFFF) == 0x0001, f"shim APB dead? DEVICE_CLASS=0x{dev:08x}"

    # -------------------------------------------------------------------------
    # Bring the pair to DATA MODE with NEITHER election armed.
    #
    # Data mode is read off the real RTL strobe (tl_data_mode_o == FCSM >= 4),
    # NOT a backdoor FCSM read: PairTB.fcsm_state() does not resolve in this
    # build (returns -1), and asserting on that would be asserting on nothing.
    # -------------------------------------------------------------------------
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "pair failed to role_lock"
    m_st, s_st = await tb.wait_cal_done(max_cycles=500000)
    assert (m_st >> 16) & 1 and (s_st >> 16) & 1, "cal_done not set on both dies"
    await tb.do_to_data_mode()

    for _ in range(400):
        await ClockCycles(dut.hclk, 100)
        if int(dut.m_data_mode.value) and int(dut.s_data_mode.value):
            break
    assert int(dut.m_data_mode.value) and int(dut.s_data_mode.value), (
        f"pair never reached data mode (tl_data_mode_o m={int(dut.m_data_mode.value)} "
        f"s={int(dut.s_data_mode.value)}) — nothing below would mean anything")
    log.info("[data-mode] tl_data_mode_o m=1 s=1 (both dies in the FC data region)")

    await m_tc.write(TC_TIMEOUT, ELECTION_TIMEOUT)
    await s_tc.write(TC_TIMEOUT, ELECTION_TIMEOUT)

    h_a = FcRxHealth(dut, dut.hclk, dut.u_master, dut.m_tc_rx_tvalid,
                     dut.m_tc_rx_tready, dut.m_tc_rx_tdata, "die_a")
    h_b = FcRxHealth(dut, dut.hclk, dut.u_slave, dut.s_tc_rx_tvalid,
                     dut.s_tc_rx_tready, dut.s_tc_rx_tdata, "die_b")
    cocotb.start_soon(h_a.run())
    cocotb.start_soon(h_b.run())

    # -------------------------------------------------------------------------
    # CONTROL — both dies' RX FSMs must be healthy (cycling through RX_IDLE)
    # before any election traffic exists, or a dead-looking result later could
    # not be attributed to the claim.
    # -------------------------------------------------------------------------
    h_a.reset_counts(); h_b.reset_counts()
    await ClockCycles(dut.hclk, 2000)
    log.info(f"[control] pre-election — {h_a.summary()} | {h_b.summary()}")
    assert h_a.rx_idle > 0 and h_b.rx_idle > 0, (
        f"a die's fc_adapter RX FSM was ALREADY stuck before any election traffic "
        f"({h_a.summary()} | {h_b.summary()}) — cannot attribute anything to a claim")

    # -------------------------------------------------------------------------
    # PHASE 1 — arm DIE A only. Its CLAIM lands on die B, which is in ST_IDLE
    # (never armed). This is the state a shipping die sits in permanently,
    # because nothing in firmware ever arms TideChart.
    # -------------------------------------------------------------------------
    h_a.reset_counts(); h_b.reset_counts()
    log.info("[phase 1] arming die_a — its CLAIM will land on die_b in ST_IDLE")
    m_done, m_root = await _arm_and_settle(m_tc, dut, "m", log)
    await ClockCycles(dut.hclk, 5000)
    log.info(f"[phase 1] {h_a.summary()} | {h_b.summary()}")
    assert m_done, "die_a election never settled — cannot set up phase 2"
    assert _election_state(dut, "m") == ST_SETTLED, (
        f"die_a not in ST_SETTLED (FSM={ST_NAMES.get(_election_state(dut,'m'))})")

    phase1 = (h_b.elect_presented, h_b.elect_xfer, h_b.rx_idle, h_b.cycles)

    # -------------------------------------------------------------------------
    # PHASE 2 — arm DIE B. Its CLAIM lands on die A, which is now ST_SETTLED.
    # -------------------------------------------------------------------------
    h_a.reset_counts(); h_b.reset_counts()
    log.info("[phase 2] arming die_b — its CLAIM will land on die_a in ST_SETTLED")
    s_done, s_root = await _arm_and_settle(s_tc, dut, "s", log)
    await ClockCycles(dut.hclk, 20000)
    h_a.stop(); h_b.stop()
    await ClockCycles(dut.hclk, 10)
    log.info(f"[phase 2] {h_a.summary()} | {h_b.summary()}")

    # -------------------------------------------------------------------------
    # THE PROPERTIES.
    # -------------------------------------------------------------------------
    log.info("=" * 70)
    log.info("LATE-CLAIM RESULT")

    # (2) die A was SETTLED when die B's claim arrived — the headline case.
    _check_not_wedged(h_a, "ST_SETTLED", log)

    # (1) die B was in ST_IDLE when die A's claim arrived. Reported from the
    #     phase-1 window; on the shipping die this is the permanent state.
    log.info(f"  [die_b @ ST_IDLE, phase 1] presented={phase1[0]} xfer={phase1[1]} "
             f"rx_idle={phase1[2]}/{phase1[3]}")
    assert phase1[0] > 0, (
        "VACUOUS: no ELECTION beat reached die_b in phase 1 while it was in "
        "ST_IDLE, so that half of the test proves nothing.")
    assert phase1[1] > 0 and phase1[2] > 0, (
        f"WEDGE (die_b, ST_IDLE): {phase1[0]} ELECTION beat-cycles presented, "
        f"{phase1[1]} handshaken, RX_IDLE seen {phase1[2]}/{phase1[3]} cycles. "
        f"An UN-ARMED die is wedged by a peer's claim — and un-armed is the "
        f"shipping die's permanent state, since no firmware arms TideChart.")

    log.info(f"  NOTE: die_a root={m_root} die_b root={s_root} — a dual-root here is "
             f"the KNOWN protocol gap (a non-listening node has no defined response "
             f"to a late claim), NOT what this test polices.")
    log.info("=" * 70)

"""H-A4 hypothesis test — Wlink FCSM asymmetric end state (Bug A diagnosis,
session 2026-05-29).

Background
==========
Earlier sim repro snapshots (`docs/SIM_REPRO_RESULTS_2026_05_29.md`) showed that
after `to_data_mode`:

    M: fcsm.state = 5
    S: fcsm.state = 4

The question being tested here: is M=5/S=4 an asymmetric WEDGE (master's TX
scheduler held off the LINK_IDLE→LINK_DATA transition for slave but allowed
itself), or is it a *benign symmetric* state where M happened to be observed
mid-packet (state 5 = LINK_DATA = actively emitting a data packet, transient)
and S happened to be observed in LINK_IDLE (steady-state idle, returns to 4
between every data emission)?

State encoding (from `src/rtl/local_overrides/WlinkGenericFCSM_6.v`)
-------------------------------------------------------------------
The FCSM `state` is a 3-bit register at line 276 ("reg [2:0] state").
Decoded from the state-transition `always` block (lines 762-780) and the
comments at the top of the file (lines 11-13, 25-32, 46, 71-110):

  0  RESET / WAIT_ENABLE
       Power-on reset state. Exits to 1 once io_app_enable is sampled high
       through en_ff2_tx_demet_io_out (i.e. the application layer asserts
       enable). See lines 764-770.

  1  CR_TX (credit-request transmit)
       Emit CR(0x44) packets every (auto_tx_out_advance & sop) cycle.
       Exits to 2 once peer's cr_pkt OR crack_pkt has been seen
       (cr_pkt_seen_tx_demet_io_out | crack_pkt_seen_tx_demet_io_out) AND
       the SoC Labs L6 minimum-CR-emit gate is satisfied
       (socl_l6_cr_emit_count >= 32). See _GEN_34, lines 388-392.

  2  CRACK_TX (credit-request-ack transmit)
       Emit CRACK(0x45) packets. Exits to 3 once peer's crack has been seen
       on the tx-demet line. See _GEN_45 line 400.

  3  LINK_ENABLE_WAIT
       Count down swi_link_en_wait cycles (line 399). Exits to 4 when count
       reaches 0. See _GEN_52, line 404.

  4  LINK_IDLE
       Steady-state idle. The FCSM parks here between data emissions and
       between ack/nack emissions.  TX scheduler arbitrates the three
       outbound packet types:
         * send_ack_req & count==0 →  state 6 (ACK_TX)        line 444
         * send_nack_req           →  state 7 (NACK_TX)       line 444
         * a2l_fc_replay_link_valid & ~fe_rx_is_full → state 5 (LINK_DATA)
                                                              line 430
       So state==4 is "idle BUT able to leave for state 5 if app data
       appears and not full"; conversely state==5 means "the FCSM IS
       currently emitting a data packet on auto_tx_out_*".

  5  LINK_DATA (data-packet transmit, "transient" steady state)
       Emit data packet to peer.  L7's "reached_link_data" sticky latches
       here (lines 376-378). After auto_tx_out_advance fires, returns
       to state 4. See _GEN_85/_GEN_92/_GEN_100, line 448-452.

  6  SEND_ACK (ack-packet transmit)
       Emit ACK(0x46) packet. Returns to state 4. See lines 463/464.

  7  SEND_NACK (nack-packet transmit)
       Emit NACK(0x47) packet. Returns to state 4. The L7 forgive gate
       drains spurious bringup-window send_nack_req latches; see header
       comment lines 33-69.

THE CRITICAL CHECK for H-A4: which transition's enable is gated by which
signal:

  state==4 → state==5  requires  a2l_fc_replay_link_valid & ~fe_rx_is_full
                                 (line 430)

  If M.state was observed at 5 immediately and S.state stuck at 4 across
  multiple snapshots, master's a2l replay buffer must have valid app data
  AND the master's nearend rx-pointer is not full. If S stays at 4 and the
  app drives traffic the OTHER way, slave's a2l_fc_replay_link_valid never
  asserts because the application returner has no packet queued — that's
  expected, NOT a wedge.

  Conversely, if BOTH dies see app traffic (e.g. both send doorbells, both
  send AHB packets), and one side's state stays at 4 while the other side's
  state visits 5 N times, that side IS wedged at the TX scheduler level.

LL_RX byte-align FSM (separate state machine, RX path)
------------------------------------------------------
Per `src/rtl/local_overrides/WlinkRxLinkLayer.v` line 141:
  `reg [1:0] state;`  // 2'h0=hunt 2'h1=long_pkt_inflight 2'h2=error

This is the byte-align FSM at the heart of the 2026-05-24 bug
(project_tidelink_interface_fcsm_bug_2026_05_24.md). After the L4+L5
fixes (hunt_holdoff counter + first_short_pkt_seen whitelist) it should
stay at 2'h0 throughout bringup and arm to 2'h1 transiently on real long
packets. A RECURRENCE of the 2026-05-24 bug would show the FSM stuck at
2'h1 on slave indefinitely after to_data_mode.

Path in tb_top hierarchy
------------------------
  FCSM:    dut.u_{master,slave}.u_chiplet_controller.u_wlink
              .tl2wl.wlink_tidelinktl.state         (3b, io_tx_clk domain)
  LL_RX:   dut.u_{master,slave}.u_chiplet_controller.u_wlink
              .llrx.state                            (2b, llrx_clock domain)
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the established testbench harness rather than re-deriving the bringup
# helpers.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_through_phase1,
    run_bringup_full,
    APB_R8_SLOT0,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_PAIR_CREDIT_COUNTER,
    R8_SLOT0_OFF,
)


# ---------------------------------------------------------------------------
# Decoded state-name dictionaries (per WlinkGenericFCSM_6.v / WlinkRxLinkLayer.v)
# ---------------------------------------------------------------------------
FCSM_STATE_NAMES = {
    0: "RESET_WAIT_EN",
    1: "CR_TX",
    2: "CRACK_TX",
    3: "LINK_ENABLE_WAIT",
    4: "LINK_IDLE",
    5: "LINK_DATA",
    6: "SEND_ACK",
    7: "SEND_NACK",
}

LLRX_STATE_NAMES = {
    0: "HUNT",
    1: "LONG_PKT_IN_FLIGHT",
    2: "ERROR",
}


def _fcsm_name(s):
    if s < 0:
        return f"?<{s}>"
    return FCSM_STATE_NAMES.get(s, f"?{s}")


def _llrx_name(s):
    if s < 0:
        return f"?<{s}>"
    return LLRX_STATE_NAMES.get(s, f"?{s}")


# ---------------------------------------------------------------------------
# Hierarchical-reference helpers
# ---------------------------------------------------------------------------
def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    """Handle to WlinkGenericFCSM_6 inside the side's Wlink (tl2wl)."""
    return _top(dut, side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _llrx(dut, side):
    """Handle to WlinkRxLinkLayer (byte-align framer)."""
    return _top(dut, side).u_chiplet_controller.u_wlink.llrx


def _safe_int(handle, attr):
    """Read a sub-attribute as int, swallow X-during-bringup -> -1."""
    try:
        h = getattr(handle, attr)
    except AttributeError:
        return -1
    try:
        return int(h.value)
    except (ValueError, AttributeError):
        return -1


def fcsm_state(dut, side):
    return _safe_int(_fcsm(dut, side), "state")


def fcsm_a2l_valid(dut, side):
    """The TX-scheduler enable for state 4→5: a2l_fc_replay_link_valid AND
    ~fe_rx_is_full.  When this combo is 1 and state==4, the next cycle
    must advance to state==5; if it stays at 4 across many cycles with
    the gate high, the scheduler is wedged."""
    return _safe_int(_fcsm(dut, side), "a2l_fc_replay_link_valid")


def fcsm_fe_rx_is_full(dut, side):
    return _safe_int(_fcsm(dut, side), "fe_rx_is_full")


def fcsm_tx_out_advance(dut, side):
    # auto_tx_out_advance is an INPUT port; cocotb can still read it.
    return _safe_int(_fcsm(dut, side), "auto_tx_out_advance")


def fcsm_send_nack_req(dut, side):
    return _safe_int(_fcsm(dut, side), "send_nack_req")


def fcsm_send_ack_req(dut, side):
    return _safe_int(_fcsm(dut, side), "send_ack_req")


def fcsm_l7_reached(dut, side):
    return _safe_int(_fcsm(dut, side), "socl_l7_reached_link_data")


def llrx_state(dut, side):
    return _safe_int(_llrx(dut, side), "state")


def llrx_in_error(dut, side):
    return _safe_int(_llrx(dut, side), "io_in_error_state")


def llrx_valid(dut, side):
    # Output port carrying obs_valid mirror.
    return _safe_int(_llrx(dut, side), "io_obs_valid")


# ---------------------------------------------------------------------------
# Test 1 — symmetric end state expected
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fcsm_state_post_bringup_symmetric(dut):
    """After to_data_mode + 100 cy settle, M.fcsm and S.fcsm should both be
    in steady-state idle (LINK_IDLE=4).  A residual M==5 / S==4 split for
    more than a few cycles indicates either:
        * master is stuck mid-LINK_DATA (TX did not advance), or
        * slave never reached LINK_DATA (no inbound app data — benign), or
        * scheduler asymmetry per H-A4.

    The assertion is loose: we sample state across 200 cy and require that
    M visits state==4 at least once.  A *permanent* M.state==5 is the wedge
    case; a single observation of M==5 amongst many M==4 is benign.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)

    await ClockCycles(dut.hclk, 100)

    m0 = fcsm_state(dut, "m")
    s0 = fcsm_state(dut, "s")
    tb.log.info(
        f"  [post-bringup +100cy] M.fcsm={m0}/{_fcsm_name(m0)}  "
        f"S.fcsm={s0}/{_fcsm_name(s0)}"
    )

    # Sample for 200 cycles; collect histogram of state values per side.
    m_hist = {k: 0 for k in range(8)}
    s_hist = {k: 0 for k in range(8)}
    for _ in range(200):
        await RisingEdge(dut.hclk)
        m_hist[fcsm_state(dut, "m")] = m_hist.get(fcsm_state(dut, "m"), 0) + 1
        s_hist[fcsm_state(dut, "s")] = s_hist.get(fcsm_state(dut, "s"), 0) + 1

    tb.log.info(f"  M.fcsm histogram over 200cy: {dict(sorted(m_hist.items()))}")
    tb.log.info(f"  S.fcsm histogram over 200cy: {dict(sorted(s_hist.items()))}")

    # H-A4 falsification: master MUST visit LINK_IDLE in the 200cy window.
    # If master is wedged at LINK_DATA (state==5) for every single cycle,
    # the scheduler did NOT advance.
    m_at_idle = m_hist.get(4, 0)
    s_at_idle = s_hist.get(4, 0)
    assert m_at_idle > 0, (
        f"H-A4 SUSPECTED: master FCSM never visited LINK_IDLE in 200cy. "
        f"Histogram = {dict(sorted(m_hist.items()))}. "
        f"Probable cause: TX scheduler held in state==5 (LINK_DATA) without "
        f"auto_tx_out_advance ever firing, OR send_nack_req latched and "
        f"state stuck at 7."
    )
    assert s_at_idle > 0, (
        f"H-A4 SUSPECTED: slave FCSM never visited LINK_IDLE in 200cy. "
        f"Histogram = {dict(sorted(s_hist.items()))}."
    )


# ---------------------------------------------------------------------------
# Test 2 — log trace POR → 1000cy post bringup
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fcsm_state_log_trace(dut):
    """Trace M.fcsm and S.fcsm every 50 cycles through the entire bringup
    sequence so divergence points are explicit in the log.  Also tracks
    LL_RX byte-align state on the same timeline.

    No hard assertions — produces a side-by-side timeline for human triage.
    Divergence is logged with [DIVERGE] tag for grep-ability.
    """
    tb = PairTB(dut)

    # Spin up a continuous probe coroutine BEFORE the bringup so we catch
    # state==0 → state==1 → ... transitions instead of just the steady-state.
    trace = []

    async def _probe():
        cy = 0
        last_div_cy = -1000
        prev_m = -1
        prev_s = -1
        while True:
            await ClockCycles(dut.hclk, 50)
            cy += 50
            m = fcsm_state(dut, "m")
            s = fcsm_state(dut, "s")
            mr = llrx_state(dut, "m")
            sr = llrx_state(dut, "s")
            if m != prev_m or s != prev_s:
                tag = "[DIVERGE]" if m != s else "         "
                tb.log.info(
                    f"  cy={cy:6d} {tag} "
                    f"M.fcsm={m}/{_fcsm_name(m):16s}  "
                    f"S.fcsm={s}/{_fcsm_name(s):16s}  "
                    f"M.llrx={mr}/{_llrx_name(mr)}  "
                    f"S.llrx={sr}/{_llrx_name(sr)}"
                )
                prev_m, prev_s = m, s
            trace.append((cy, m, s, mr, sr))

    cocotb.start_soon(_probe())

    # Run the full bringup using the established harness.
    await run_bringup_full(tb)

    # Then settle 1000 more cycles past to_data_mode so steady-state is
    # captured in the trace.
    await ClockCycles(dut.hclk, 1000)

    # Final summary — what fraction of the trace was symmetric?
    sym = sum(1 for (_cy, m, s, _, _) in trace if m == s and m >= 0)
    asy = sum(1 for (_cy, m, s, _, _) in trace if m != s and m >= 0 and s >= 0)
    tb.log.info(
        f"  TRACE SUMMARY: {sym} symmetric samples, {asy} asymmetric samples, "
        f"over {len(trace)} total"
    )
    if asy > 0:
        # Sample the last few asymmetric points so the divergence pattern is
        # surfaced in the log even when the trace was truncated upstream.
        asy_tail = [(cy, m, s) for (cy, m, s, _, _) in trace[-50:] if m != s]
        tb.log.info(f"  Last 50-sample asymmetric points: {asy_tail}")

    # Pass unconditionally — this test exists to TRACE, not to gate.
    assert True


# ---------------------------------------------------------------------------
# Test 3 — FCSM state during master AHB-N=1 write
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fcsm_state_during_ahb_write(dut):
    """Bring the link up, write ONE AHB packet from master, and log both
    dies' FCSM state every 10 cy through the write + 2000cy after.

    The hypothesis under test: when master attempts to drive an AHB packet,
    master's FCSM must transition state 4 → 5 (LINK_IDLE → LINK_DATA) at
    least once to emit the packet on the wire.  If master's FCSM never
    leaves state==4 during the AHB write, the TX scheduler is wedged --
    H-A4 is the candidate root cause (master a2l_fc_replay_link_valid
    asserts but state-4→5 transition gate `a2l_fc_replay_link_valid &
    ~fe_rx_is_full` fails).  If master's FCSM DOES visit state 5 but the
    packet doesn't arrive on slave, the bug is downstream of the TX
    scheduler (the focus of Bug A: rx_pkt_type misdecode at slave).
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    # Trace probe — every 10 cy.
    samples = []

    async def _probe():
        cy = 0
        while True:
            await ClockCycles(dut.hclk, 10)
            cy += 10
            samples.append((
                cy,
                fcsm_state(dut, "m"),
                fcsm_state(dut, "s"),
                fcsm_a2l_valid(dut, "m"),
                fcsm_a2l_valid(dut, "s"),
                fcsm_fe_rx_is_full(dut, "m"),
                fcsm_fe_rx_is_full(dut, "s"),
                fcsm_tx_out_advance(dut, "m"),
                fcsm_tx_out_advance(dut, "s"),
            ))

    cocotb.start_soon(_probe())

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    tb.log.info(f"  master TX packet: {[f'0x{w:08x}' for w in words]}")
    await tb.ahb_tx_write_packet("m", words)

    # Settle.
    await ClockCycles(dut.hclk, 2000)

    # Aggregate: did master ever leave state==4?  Did a2l_valid ever
    # assert?  Did auto_tx_out_advance ever fire?  Did slave's state
    # change at all (it should at least toggle to state==6 (ACK_TX) on
    # receipt of a data packet)?
    m_states_seen = set(m for (_cy, m, _s, *_rest) in samples if m >= 0)
    s_states_seen = set(s for (_cy, _m, s, *_rest) in samples if s >= 0)
    m_a2l_high_cy = sum(1 for (_cy, _m, _s, ma, _sa, *_r) in samples if ma == 1)
    m_full_cy = sum(1 for (*_a, mf, _sf, _ma, _sa) in samples if mf == 1)
    m_adv_high_cy = sum(1 for (*_a, _mf, _sf, ma, _sa) in samples
                        if ma == 1)
    # Recompute the master-advance more carefully (positional unpack above
    # is fragile; redo with index).
    m_adv_high_cy = sum(1 for row in samples if row[7] == 1)
    s_adv_high_cy = sum(1 for row in samples if row[8] == 1)

    tb.log.info(f"  master FCSM states visited during AHB+settle: "
                f"{sorted(m_states_seen)}  "
                f"({[_fcsm_name(s) for s in sorted(m_states_seen)]})")
    tb.log.info(f"  slave  FCSM states visited during AHB+settle: "
                f"{sorted(s_states_seen)}  "
                f"({[_fcsm_name(s) for s in sorted(s_states_seen)]})")
    tb.log.info(f"  master a2l_fc_replay_link_valid==1 in "
                f"{m_a2l_high_cy}/{len(samples)} samples")
    tb.log.info(f"  master fe_rx_is_full==1 in {m_full_cy}/{len(samples)} samples")
    tb.log.info(f"  master auto_tx_out_advance==1 in "
                f"{m_adv_high_cy}/{len(samples)} samples")
    tb.log.info(f"  slave  auto_tx_out_advance==1 in "
                f"{s_adv_high_cy}/{len(samples)} samples")

    # Look for FIRST sample after the AHB write where state changes from 4
    # to anything else on master.  If none, log explicitly.
    first_leave_idle = None
    for (cy, m, s, ma, sa, mf, sf, mA, sA) in samples:
        if m >= 0 and m != 4:
            first_leave_idle = (cy, m)
            break
    tb.log.info(f"  first sample with master.state != LINK_IDLE: "
                f"{first_leave_idle}")

    # The smoking-gun test: master must visit LINK_DATA (state==5) OR
    # SEND_ACK (state==6) OR SEND_NACK (state==7) at least once during the
    # AHB write window — otherwise the FCSM TX scheduler is wedged and the
    # packet never leaves master.
    productive_states = m_states_seen & {5, 6, 7}
    assert productive_states, (
        f"H-A4 CONFIRMED: master FCSM never left LINK_IDLE during AHB write "
        f"+ 2000cy settle.  States visited = {sorted(m_states_seen)}.  "
        f"m_a2l_valid samples high = {m_a2l_high_cy}; m_full samples high = "
        f"{m_full_cy}; m_adv samples high = {m_adv_high_cy}.  "
        f"This indicates the TX scheduler IS the gate, not credits."
    )


# ---------------------------------------------------------------------------
# Test 4 — TX data-path enable probe (state==4 → state==5 gate)
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fcsm_tx_data_path_enable(dut):
    """Probe master FCSM's state-4→5 enable signal during an AHB write:

        _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full   (FCSM_6 line 422)

    When state==4 and _T_59==1, the next cycle MUST transition to state==5
    (per the GEN_60 mux on FC.scala 523:63).  Counts the cycles where this
    pre-condition holds AND state==4 stays at 4 (i.e. the supposed-to-fire
    transition did not fire). Any such count > 0 is a smoking gun for an
    FCSM scheduler wedge.
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    # Start probe BEFORE driving the AHB packet.
    wedge_hits = 0
    fire_hits = 0
    total_obs = 0
    stop = [False]

    async def _probe():
        nonlocal wedge_hits, fire_hits, total_obs
        prev_state = -1
        prev_t59 = -1
        cy = 0
        while not stop[0]:
            await RisingEdge(dut.hclk)
            cy += 1
            state = fcsm_state(dut, "m")
            a2l = fcsm_a2l_valid(dut, "m")
            full = fcsm_fe_rx_is_full(dut, "m")
            if state < 0 or a2l < 0 or full < 0:
                prev_state = state
                continue
            t59 = a2l & (1 - full)
            # If last cycle we had state==4 AND t59==1, this cycle's state
            # MUST be 5 (per FCSM mux).  If it stays at 4 the gate was
            # observed and did NOT progress -> wedge candidate.
            if prev_state == 4 and prev_t59 == 1:
                total_obs += 1
                if state == 5:
                    fire_hits += 1
                elif state == 4:
                    wedge_hits += 1
                    if wedge_hits <= 5:
                        tb.log.info(
                            f"  cy={cy}: state stayed at 4 despite "
                            f"a2l_valid=1 & ~full=1 (wedge candidate)"
                        )
            prev_state = state
            prev_t59 = t59

    cocotb.start_soon(_probe())

    # Drive ONE AHB packet from master.
    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    await tb.ahb_tx_write_packet("m", words)

    await ClockCycles(dut.hclk, 2000)
    stop[0] = True
    await ClockCycles(dut.hclk, 2)

    tb.log.info(
        f"  Master state-4→5 gate observations: total={total_obs}  "
        f"fired={fire_hits}  wedged={wedge_hits}"
    )

    # Diagnosis output:
    #   wedge_hits>0 -> FCSM scheduler is the gate (H-A4 CONFIRMED).
    #   wedge_hits==0 & total_obs==0 -> gate condition never held, so
    #       a2l_valid never asserted; the bug is UPSTREAM of FCSM TX
    #       scheduler (e.g. tidelink_top returner / fc_adapter not pushing
    #       packet into a2l replay).
    #   wedge_hits==0 & fire_hits>0 -> FCSM TX scheduler is healthy; the
    #       packet IS being emitted on auto_tx_out_* — bug is downstream
    #       (PHY corruption or slave RX demux misdecode).
    if total_obs == 0:
        tb.log.warning(
            "  diagnostic: a2l_fc_replay_link_valid never asserted on master "
            "during AHB write window.  Bug is UPSTREAM of FCSM TX scheduler "
            "(FC-adapter / returner / a2l_replay enqueue).  H-A4 is NOT the "
            "root cause for this symptom."
        )
    elif wedge_hits > 0:
        tb.log.error(
            f"  diagnostic: state-4→5 gate observed {total_obs} times, "
            f"fired {fire_hits}, WEDGED {wedge_hits}.  H-A4 is the candidate."
        )
    else:
        tb.log.info(
            f"  diagnostic: state-4→5 gate observed {total_obs} times, "
            f"all fired ({fire_hits}).  FCSM TX scheduler is healthy; bug "
            f"is DOWNSTREAM of state-4→5 transition."
        )

    # The assertion: if state-4→5 EVER fired during the test, H-A4 is
    # falsified.  If it never even had the chance (total_obs==0), the
    # bug is upstream of FCSM (also falsifies H-A4).  Only wedge_hits>0
    # (state==4, t59==1, did not progress to 5) CONFIRMS H-A4.
    assert wedge_hits == 0, (
        f"H-A4 CONFIRMED: master FCSM observed state==4 with "
        f"a2l_valid & ~full but did NOT transition to LINK_DATA in "
        f"{wedge_hits}/{total_obs} samples."
    )


# ---------------------------------------------------------------------------
# Test 5 — LL_RX byte-align FSM regression (2026-05-24 bug recurrence check)
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_ll_rx_byte_align_recurrence(dut):
    """The 2026-05-24 bug was loss of byte alignment on slave LL_RX framer
    at the WavD2DGpioTx mid-word mux flip (commit 5477e60 +
    src/rtl/local_overrides/WavD2DGpioTx.v WORD_ALIGN_MUX gate). The fix
    is now in place; this test gates against recurrence.

    Expected steady state after bringup: both LL_RX FSMs at state==0 (HUNT)
    receiving short packets (CR/CRACK).  If either side gets stuck at
    state==1 (LONG_PKT_IN_FLIGHT) or state==2 (ERROR), the bug recurred.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)

    # Sample for 1000 cycles, count how often each side spent in each LL_RX
    # state.
    m_llrx_hist = {0: 0, 1: 0, 2: 0, -1: 0}
    s_llrx_hist = {0: 0, 1: 0, 2: 0, -1: 0}
    m_err_seen = 0
    s_err_seen = 0
    for _ in range(1000):
        await RisingEdge(dut.hclk)
        ms = llrx_state(dut, "m")
        ss = llrx_state(dut, "s")
        m_llrx_hist[ms] = m_llrx_hist.get(ms, 0) + 1
        s_llrx_hist[ss] = s_llrx_hist.get(ss, 0) + 1
        m_err_seen |= llrx_in_error(dut, "m") == 1
        s_err_seen |= llrx_in_error(dut, "s") == 1

    tb.log.info(f"  master LL_RX state histogram: "
                f"{ {_llrx_name(k): v for k, v in m_llrx_hist.items() if v} }")
    tb.log.info(f"  slave  LL_RX state histogram: "
                f"{ {_llrx_name(k): v for k, v in s_llrx_hist.items() if v} }")
    tb.log.info(f"  master io_in_error_state ever asserted = {bool(m_err_seen)}")
    tb.log.info(f"  slave  io_in_error_state ever asserted = {bool(s_err_seen)}")

    # ERROR state is fatal.
    assert m_llrx_hist.get(2, 0) == 0, (
        f"master LL_RX entered ERROR state in {m_llrx_hist[2]}/1000 samples. "
        f"2026-05-24 bug RECURRED or a new framer corruption exists."
    )
    assert s_llrx_hist.get(2, 0) == 0, (
        f"slave LL_RX entered ERROR state in {s_llrx_hist[2]}/1000 samples. "
        f"2026-05-24 bug RECURRED."
    )

    # A *brief* visit to LONG_PKT_IN_FLIGHT is normal during AHB packet RX
    # but with no AHB traffic in this test it should be ~0.  Threshold:
    # >50 samples (>5% of window) stuck at state==1 with no AHB driver =
    # WORD_ALIGN_MUX regression.
    assert m_llrx_hist.get(1, 0) < 50, (
        f"master LL_RX stuck at LONG_PKT_IN_FLIGHT in {m_llrx_hist[1]}/1000 "
        f"samples (>5%). WavD2DGpioTx byte-align regression candidate. "
        f"Check src/rtl/local_overrides/WavD2DGpioTx.v WORD_ALIGN_MUX param."
    )
    assert s_llrx_hist.get(1, 0) < 50, (
        f"slave LL_RX stuck at LONG_PKT_IN_FLIGHT in {s_llrx_hist[1]}/1000 "
        f"samples (>5%). WavD2DGpioTx byte-align regression candidate."
    )

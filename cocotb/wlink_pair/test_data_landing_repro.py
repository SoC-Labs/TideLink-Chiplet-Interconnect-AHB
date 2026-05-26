"""Data-landing repro test — does master->slave payload actually land?

CONTEXT (2026-05-26 overnight, tdif-16 HW)
------------------------------------------
On a17f694 (feat/td-interface-debug-l9-tidelink-fc-asym), the FPGA pair
reaches bilateral LINK_IDLE (FCSM state 4), cr_pkt_seen + crack_pkt_seen
are symmetric, and master's a2l TX FIFO DRAINS when a host issues
    tt_devmem_write 192.168.4.101 0x44010000 0xDEADBEEF
but the slave's storage at 0x44010000 does NOT take the value. The
FIFO bytes have left the master — they're either:
    (a) consumed by NACK / retry path (acked-zero on the link)
    (b) corrupted on the wire (slave framer drops)
    (c) decoded into a CR/CRACK/PTP packet (wrong data_id), not data
    (d) decoded as a data packet but not surfaced at io_app_l2a_*
    (e) routed to the wrong place inside the slave (FC-internal mis-route)

THE TEST STRATEGY
-----------------
The wlink_pair TB ties `tidelink_in(50'h0)` and `tidelink_out()` on both
sides, so there's NO modelled AHB initiator/target performing the
peer-write. The existing test_link_idle_advance_with_payload test
short-circuits this by FORCING `u_*.u_wlink.tl_in_wire` to drive a
canned 48-bit payload on the app-side a2l interface — which is exactly
what the master's AHB↔Wlink bridge would do on a real peer-write.

This test:
  1. Replays the full bringup_pair_converge.sh sequence so both FCSMs
     reach LINK_IDLE (the HW state we observe before the peer-write).
  2. Forces master's `tl_in_wire` to drive a SINGLE 48-bit packet with a
     known sentinel (0xDEADBEEFCAFE), then releases.
  3. Snapshots end-to-end signals every cycle for 4000 cycles:
       * master `io_app_a2l_valid/ready/data`   (TX side intake)
       * master `auto_tx_out_*`                  (LL TX wire)
       * slave  `auto_rx_in_valid/sop/data`      (LL RX wire)
       * slave  `pkt_is_data_pkt`                (framer says "data")
       * slave  `io_app_l2a_valid/data`          (RX side delivery)
       * both   FCSM states + cr/crack/nack flags
  4. Asserts the sentinel arrives in slave's io_app_l2a_data at least
     once. If yes -> sim DOES land data, HW vs sim diverges. If no ->
     sim reproduces HW bug; inspect the cycle trace to find where the
     byte gets lost.

NOTE on AHB modelling: we deliberately do NOT model the AHB bridge.
This test asks the strictly-narrower question: "does the FCSM forward a
single forced a2l_valid packet across the wire and present it on the
slave's l2a output?". If sim says YES and HW says NO, the divergence is
EITHER in something the recal sequence specifically does (slot0 mid-word
mux flip — known v1 bug) OR in the AHB-side glue that the TB doesn't
model. If sim says NO too, we can iterate the fix in sim.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, ctrl_write, apb_write
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll,
    FCSM_LINK_DATA, FCSM_LINK_IDLE, FCSM_SEND_NACK, STATE_NAME,
)


SENTINEL_PAYLOAD_48 = 0xDEADBEEFCAFE   # arbitrary witness payload


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


def _wlink(dut, side):
    return _chiplet(dut, side).u_wlink


def _tl2wl(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl


def _force_app_packet(wlink, payload48):
    """Force the internal app-side a2l bus inside Wlink.tl_in_wire.
    bore_1 / tl_in_wire encoding: {a2l_valid, a2l_data[47:0], l2a_accept}.
    Sets l2a_accept=1 so the slave-receiving direction also accepts."""
    tl_in = (1 << 49) | ((payload48 & ((1 << 48) - 1)) << 1) | 1
    wlink.tl_in_wire.value = Force(tl_in)


def _release_app_packet(wlink):
    wlink.tl_in_wire.value = Release()


async def _bringup_to_link_idle(dut):
    """Replay the HW bringup sequence and wait until BOTH FCSMs are at
    state>=LINK_IDLE (4). Returns (m_state, s_state) at that point."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    m_state_h = _fcsm(dut, "m").state
    s_state_h = _fcsm(dut, "s").state
    for _ in range(8000):
        await ClockCycles(dut.master_clk, 1)
        if int(m_state_h.value) >= FCSM_LINK_IDLE and \
           int(s_state_h.value) >= FCSM_LINK_IDLE:
            break
    return int(m_state_h.value), int(s_state_h.value)


def _safe_int(handle):
    """Return int(handle.value) or None if not resolvable / X-valued."""
    try:
        return int(handle.value)
    except Exception:
        return None


# -----------------------------------------------------------------------
# TEST 1 — KEY TEST. After bringup_pair_converge replay, force master a2l
# valid with sentinel and confirm the sentinel arrives on slave's
# io_app_l2a_data. PASS == data lands; FAIL == HW bug reproduced in sim.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_master_peer_write_lands_on_slave(dut):
    """Forces master a2l_valid with 0xDEADBEEFCAFE and asserts the slave's
    io_app_l2a_data eventually carries it. If this asserts in sim, the
    sim model diverges from HW (HW shows FIFO drain but no land). If
    this fails, sim reproduces HW and we can iterate on the fix here."""
    m_state, s_state = await _bringup_to_link_idle(dut)
    dut._log.info(
        f"  pre-force: m.state={m_state}({STATE_NAME.get(m_state,'?')}) "
        f"s.state={s_state}({STATE_NAME.get(s_state,'?')})")
    assert m_state >= FCSM_LINK_IDLE and s_state >= FCSM_LINK_IDLE, (
        f"prerequisite: both sides must reach LINK_IDLE (state>=4); got "
        f"m={m_state} s={s_state}")

    # Resolve all observation handles in advance, with graceful fallbacks
    # for signals that may have different generated names.
    m_fc = _fcsm(dut, "m"); s_fc = _fcsm(dut, "s")
    m_tl = _tl2wl(dut, "m"); s_tl = _tl2wl(dut, "s")

    # Master-side intake.  These live inside TideLinkToWlink (tl2wl).
    m_a2l_valid = m_tl.wlink_tidelinktl_io_app_a2l_valid
    m_a2l_data  = m_tl.wlink_tidelinktl_io_app_a2l_data
    m_a2l_ready = m_tl.wlink_tidelinktl_io_app_a2l_ready
    # Slave-side delivery (the equivalent of "data arrives at AHB target").
    s_l2a_valid = s_tl.wlink_tidelinktl_io_app_l2a_valid
    s_l2a_data  = s_tl.wlink_tidelinktl_io_app_l2a_data

    # Force master's a2l interface with the sentinel BEFORE counting cycles.
    _force_app_packet(_wlink(dut, "m"), SENTINEL_PAYLOAD_48)

    # Cycle-by-cycle trace. We log only "interesting" cycles to keep noise
    # down: master a2l fires, slave l2a fires, FCSM-state change, NACK seen.
    OBS_CYCLES = 6000
    prev_m_state = -1; prev_s_state = -1
    a2l_fires = 0
    l2a_fires = 0
    sentinel_seen = False
    sentinel_cycle = -1
    nack_m = False; nack_s = False
    m_data_pkt_seen = False; s_data_pkt_seen = False
    first_a2l_fire_cycle = -1

    for cyc in range(OBS_CYCLES):
        await ClockCycles(dut.master_clk, 1)

        ms = int(m_fc.state.value); ss = int(s_fc.state.value)
        if ms != prev_m_state or ss != prev_s_state:
            dut._log.info(
                f"  cyc={cyc:5d} state change: m={prev_m_state}->{ms}"
                f"({STATE_NAME.get(ms,'?')}) "
                f"s={prev_s_state}->{ss}({STATE_NAME.get(ss,'?')})")
            prev_m_state = ms; prev_s_state = ss

        if ms == FCSM_SEND_NACK: nack_m = True
        if ss == FCSM_SEND_NACK: nack_s = True

        # Master a2l handshake firing?
        v = _safe_int(m_a2l_valid); r = _safe_int(m_a2l_ready)
        if v and r:
            a2l_fires += 1
            if first_a2l_fire_cycle < 0:
                first_a2l_fire_cycle = cyc
                d = _safe_int(m_a2l_data)
                dut._log.info(
                    f"  cyc={cyc:5d} MASTER a2l fire #1: data=0x{d:012x}")
            if a2l_fires <= 4:
                d = _safe_int(m_a2l_data)
                dut._log.info(
                    f"  cyc={cyc:5d} MASTER a2l fire (count={a2l_fires}): "
                    f"data=0x{d:012x}")

        # Slave l2a delivery?
        v = _safe_int(s_l2a_valid)
        if v:
            l2a_fires += 1
            d = _safe_int(s_l2a_data)
            if l2a_fires <= 6:
                dut._log.info(
                    f"  cyc={cyc:5d} SLAVE l2a fire (count={l2a_fires}): "
                    f"data=0x{d:012x}")
            if d == SENTINEL_PAYLOAD_48:
                sentinel_seen = True
                sentinel_cycle = cyc
                dut._log.info(
                    f"  cyc={cyc:5d} *** SENTINEL 0x{SENTINEL_PAYLOAD_48:012x} "
                    f"LANDED on slave l2a *** ")
                break

        # Probe framer "this is a data packet" latches (where resolvable).
        try:
            if int(m_fc.pkt_is_data_pkt.value): m_data_pkt_seen = True
            if int(s_fc.pkt_is_data_pkt.value): s_data_pkt_seen = True
        except Exception:
            pass

    final_m = int(m_fc.state.value); final_s = int(s_fc.state.value)
    final_m_cr = int(m_fc.cr_pkt_seen_rx.value)
    final_s_cr = int(s_fc.cr_pkt_seen_rx.value)
    final_m_crack = int(m_fc.crack_pkt_seen_rx.value)
    final_s_crack = int(s_fc.crack_pkt_seen_rx.value)

    dut._log.info("-" * 70)
    dut._log.info(
        f"  SUMMARY after {OBS_CYCLES} cycles of forced master a2l valid:")
    dut._log.info(
        f"    a2l_fires (master)  = {a2l_fires} "
        f"(first_fire_cycle={first_a2l_fire_cycle})")
    dut._log.info(
        f"    l2a_fires (slave)   = {l2a_fires}")
    dut._log.info(
        f"    sentinel_seen       = {sentinel_seen} "
        f"(landed_cycle={sentinel_cycle})")
    dut._log.info(
        f"    final m.state={final_m}({STATE_NAME.get(final_m,'?')}) "
        f"s.state={final_s}({STATE_NAME.get(final_s,'?')})")
    dut._log.info(
        f"    cr_pkt_seen_rx  m={final_m_cr} s={final_s_cr}    "
        f"crack_pkt_seen_rx m={final_m_crack} s={final_s_crack}")
    dut._log.info(
        f"    pkt_is_data_pkt seen  m={m_data_pkt_seen} s={s_data_pkt_seen}")
    dut._log.info(
        f"    NACK seen during window  m={nack_m} s={nack_s}")
    dut._log.info("-" * 70)

    _release_app_packet(_wlink(dut, "m"))

    # Hypothesis classification — log loudly for the report.
    if a2l_fires == 0:
        dut._log.error(
            "  HYPOTHESIS: master never accepted the forced a2l packet "
            "(a2l_fires=0). The FIFO did NOT drain in sim. This contradicts "
            "the HW observation that the FIFO DOES drain — sim model misses "
            "the HW path.")
    elif l2a_fires == 0:
        dut._log.error(
            "  HYPOTHESIS: master a2l drained but slave NEVER saw an l2a "
            "fire. Either the wire bytes are lost, or the slave framer "
            "rejects all packets, or the FC adapter routes them somewhere "
            "other than io_app_l2a. This REPRODUCES the HW bug shape.")
    elif not sentinel_seen:
        dut._log.error(
            "  HYPOTHESIS: slave saw some l2a fires but NONE carried the "
            "sentinel value. Either the data field is corrupted on the wire "
            "or the wrong packet kind (e.g. zeros) is being delivered.")
    else:
        dut._log.info(
            "  RESULT: SENTINEL LANDED in sim. Sim model and HW DIVERGE on "
            "this specific test. The HW bug must therefore live in something "
            "this TB does not model: e.g. the AHB↔Wlink bridge glue, the "
            "real chiplet-controller FC packetiser path, or a recal-induced "
            "asymmetric corruption that the deterministic shared-clock TB "
            "does not trigger. Next step: instrument FPGA ILA to capture "
            "io_app_l2a on slave at the same instant the master FIFO drains.")

    assert sentinel_seen, (
        f"sentinel 0x{SENTINEL_PAYLOAD_48:012x} did NOT land on slave "
        f"io_app_l2a_data after {OBS_CYCLES} cycles "
        f"(a2l_fires={a2l_fires} l2a_fires={l2a_fires} "
        f"nack_m={nack_m} nack_s={nack_s} "
        f"final m.state={final_m} s.state={final_s})")


# -----------------------------------------------------------------------
# TEST 2 — diagnostic: no recal, just LINK_IDLE → peer-write. This
# isolates whether the recal sequence is the bug-trigger. If TEST 1 fails
# but TEST 2 passes, the recal sequence corrupts the data path; if both
# fail, the data path is broken regardless of recal.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_master_peer_write_lands_without_recal(dut):
    """Same as test_01 but SKIPS recal_cycle. Just sets up POR + lock and
    waits for the natural FCSM convergence (which test_link_idle_advance
    confirms reaches LINK_IDLE). If THIS lands the sentinel but test_01
    does not, the recal sequence specifically corrupts the data path."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m_state_h = _fcsm(dut, "m").state; s_state_h = _fcsm(dut, "s").state
    reached = False
    for _ in range(8000):
        await ClockCycles(dut.master_clk, 1)
        if int(m_state_h.value) >= FCSM_LINK_IDLE and \
           int(s_state_h.value) >= FCSM_LINK_IDLE:
            reached = True
            break
    assert reached, (
        f"prerequisite: both sides must reach LINK_IDLE without recal; got "
        f"m={int(m_state_h.value)} s={int(s_state_h.value)}")

    m_tl = _tl2wl(dut, "m"); s_tl = _tl2wl(dut, "s")
    s_l2a_valid = s_tl.wlink_tidelinktl_io_app_l2a_valid
    s_l2a_data  = s_tl.wlink_tidelinktl_io_app_l2a_data

    _force_app_packet(_wlink(dut, "m"), SENTINEL_PAYLOAD_48)

    sentinel_seen = False
    l2a_fires = 0
    for cyc in range(4000):
        await ClockCycles(dut.master_clk, 1)
        v = _safe_int(s_l2a_valid)
        if v:
            l2a_fires += 1
            d = _safe_int(s_l2a_data)
            if l2a_fires <= 4:
                dut._log.info(
                    f"  cyc={cyc:5d} (no-recal) slave l2a fire: data=0x{d:012x}")
            if d == SENTINEL_PAYLOAD_48:
                sentinel_seen = True
                dut._log.info(
                    f"  cyc={cyc:5d} (no-recal) SENTINEL landed")
                break

    _release_app_packet(_wlink(dut, "m"))

    dut._log.info(
        f"  (no-recal) sentinel_seen={sentinel_seen} l2a_fires={l2a_fires}")
    assert sentinel_seen, (
        f"sentinel did not land on slave even WITHOUT recal "
        f"(l2a_fires={l2a_fires}). The data path itself is broken in sim "
        f"on this branch, independent of recal.")

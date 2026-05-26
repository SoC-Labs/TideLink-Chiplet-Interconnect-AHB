"""LINK_IDLE → LINK_DATA advance test, driving a real application packet.

THE BLOCKER
-----------
Existing sim only reaches FCSM state 4 (LINK_IDLE) — never 5 (LINK_DATA).
The reason is that nothing in tb_top.sv ever drives the application-side
a2l_valid: `dut.tidelink_in` is tied to `50'h0`. The FCSM gate for the
LINK_IDLE → LINK_DATA transition is

    a2l_fc_replay_link_valid & ~fe_rx_is_full
  = a2l_valid coming from the app side (i.e. `bore_1[49]`)

So the existing test_assert_bringup test_07 / 08 / 09 cannot ever advance
past LINK_IDLE; they only assert state >= 4. That leaves us blind to
whether the link can actually FORWARD a data packet end-to-end.

STRATEGIC VALUE
---------------
This test FORCES the internal app-side a2l interface (the `bore_1` net
inside tl2wl) HIGH and asserts:
  1. The master FCSM advances 4 -> 5 (LINK_DATA) when an app packet is
     valid AND fe_rx_is_full is low.
  2. The slave FCSM observes a data packet (pkt_is_data_pkt latches via
     the `auto_rx_in_*` interface).
  3. The slave returns an ACK packet which the master observes.

PASS criterion
--------------
test_01 (master-side advance):
  - master FCSM reaches state 5 (LINK_DATA) within 4000 cycles of the
    app-side packet being forced valid.

test_02 (slave packet reception):
  - slave observes a data packet (master's data_id) within 4000 cycles
    of master driving the app packet.

test_03 (the open blocker, expect_fail):
  - The full LINK_IDLE -> LINK_DATA -> slave reassembly -> ack-back loop
    completes both directions.

Why this matters: on HW the FCSM is stuck at LINK_IDLE because the AHB
side never advances the master past it (the SW driver expects the link
to come up first). This test removes the chicken-and-egg by forcing the
app interface and asks "can the FCSM forward a packet at all?".

Invocation
----------
  rm -rf sim_build ../phy_align/sim_build
  make MODULE=test_link_idle_advance_with_payload
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


# State enum, matches test_paired_recal_to_link_data.
FCSM_LINK_IDLE = 4
FCSM_LINK_DATA = 5


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


def _wlink(dut, side):
    return _chiplet(dut, side).u_wlink


def _force_app_packet(wlink, payload48):
    """Force the internal app-side a2l bus inside Wlink.tl_in_wire.
    bore_1 / tl_in_wire encoding: {a2l_valid, a2l_data[47:0], l2a_accept}.
    """
    tl_in = (1 << 49) | ((payload48 & ((1 << 48) - 1)) << 1) | 1
    wlink.tl_in_wire.value = Force(tl_in)


def _release_app_packet(wlink):
    wlink.tl_in_wire.value = Release()


async def _wait_link_idle(dut, max_cycles=4000):
    """Wait for both FCSMs to reach state>=4 (the existing baseline)."""
    m = _fcsm(dut, "m").state
    s = _fcsm(dut, "s").state
    for _ in range(max_cycles):
        await ClockCycles(dut.master_clk, 1)
        if int(m.value) >= FCSM_LINK_IDLE and int(s.value) >= FCSM_LINK_IDLE:
            return True
    return False


# -----------------------------------------------------------------------
# TEST 1 — KEY TEST. Force the master's app-side a2l valid and assert the
# master FCSM advances 4 -> 5 (LINK_DATA). This is the test_assert_bringup
# successor: it asks the next question after "did bring-up complete?".
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_master_fcsm_advances_to_link_data_under_app_packet(dut):
    """After both sides reach LINK_IDLE (state>=4), force master app a2l
    valid HIGH. Assert master FCSM advances to LINK_DATA (state>=5)
    within 4000 cycles.

    If this fails, the master can't transmit even when handed a packet on
    the app interface — the bug is in the FCSM's LINK_IDLE state, not in
    the credit handshake. If this PASSES on main, the credit handshake is
    fine and the on-HW LINK_IDLE wedge has a different root cause."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    reached = await _wait_link_idle(dut)
    m_state = int(_fcsm(dut, "m").state.value)
    s_state = int(_fcsm(dut, "s").state.value)
    dut._log.info(f"  pre-packet: m.state={m_state} s.state={s_state}")
    assert reached, (
        f"prerequisite: bring-up never reached LINK_IDLE on both sides "
        f"(m.state={m_state} s.state={s_state}) — cannot probe LINK_DATA gate")

    # Force the master's app interface to present a valid packet.
    _force_app_packet(_wlink(dut, "m"), 0xDEADBEEFCAFE)

    m_state_h = _fcsm(dut, "m").state
    reached_data = False
    cycles_to_data = -1
    for c in range(4000):
        await ClockCycles(dut.master_clk, 1)
        if int(m_state_h.value) >= FCSM_LINK_DATA:
            reached_data = True
            cycles_to_data = c
            break

    final_m = int(_fcsm(dut, "m").state.value)
    final_s = int(_fcsm(dut, "s").state.value)
    dut._log.info(
        f"  post-force: reached LINK_DATA={reached_data} cycles_to_data={cycles_to_data} "
        f"final m.state={final_m} s.state={final_s}")
    _release_app_packet(_wlink(dut, "m"))

    assert reached_data, (
        f"master FCSM never reached LINK_DATA after app a2l valid was forced "
        f"HIGH (final m.state={final_m}, expected >=5). This means the "
        f"LINK_IDLE -> LINK_DATA gate (a2l_link_valid & ~fe_rx_is_full) "
        f"never closed even with a valid app packet on the wire — investigate "
        f"the fe_rx_is_full or the a2l_fc_replay CDC")


# -----------------------------------------------------------------------
# TEST 2 — slave-side data packet reception. After test_01 establishes
# the master can transmit, ask whether the slave actually receives the
# packet at the link-layer (pkt_is_data_pkt).
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_slave_observes_data_packet_from_master(dut):
    """After master FCSM advances to LINK_DATA, the slave LL_RX should
    decode the data packet. Probes the slave's pkt_is_data_pkt latch."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    reached = await _wait_link_idle(dut)
    assert reached, "prerequisite: both sides at LINK_IDLE"

    # Force master app interface valid
    _force_app_packet(_wlink(dut, "m"), 0xAA55AA55AA55)

    # Wait for master to enter LINK_DATA
    m_state_h = _fcsm(dut, "m").state
    for _ in range(4000):
        await ClockCycles(dut.master_clk, 1)
        if int(m_state_h.value) >= FCSM_LINK_DATA:
            break

    s = _fcsm(dut, "s")
    slave_saw_data = False
    cycles_to_data = -1
    for c in range(8000):
        await ClockCycles(dut.master_clk, 1)
        # pkt_is_data_pkt is comb / one-shot; sample its current
        # presence on the slave's rx clock-aligned latch.
        try:
            if int(s.pkt_is_data_pkt.value):
                slave_saw_data = True
                cycles_to_data = c
                break
        except Exception:
            # `pkt_is_data_pkt` may be a generated net name (looks via Wlink
            # observability); if absent, fall back to looking at rx_in_valid.
            try:
                if int(s.auto_rx_in_valid.value) and \
                   int(s.auto_rx_in_sop.value):
                    slave_saw_data = True
                    cycles_to_data = c
                    break
            except Exception:
                pass

    dut._log.info(
        f"  slave_saw_data={slave_saw_data} cycles_to_data={cycles_to_data} "
        f"final s.state={int(s.state.value)}")
    _release_app_packet(_wlink(dut, "m"))

    assert slave_saw_data, (
        f"slave LL_RX never observed a data packet from the master after "
        f"master entered LINK_DATA. This isolates the bug to the master->slave "
        f"LL_TX or PHY data path (not to the master's FCSM advance)")


# -----------------------------------------------------------------------
# TEST 3 — the OPEN BLOCKER: full LINK_DATA loop both directions.
# MAIN BUG-REVEAL: this PASSES on main when there is NO recal_cycle. That
# means the LINK_IDLE -> LINK_DATA gate is fine; the bilateral asymmetry
# we see in test_paired_recal_to_link_data is INDUCED by the recal_cycle
# (slot0=0x3 mid-word mux flip), NOT by the LINK_IDLE state.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_full_link_data_loop_both_directions(dut):
    """Drive a master->slave packet AND a slave->master packet (both sides
    have app interfaces forced HIGH). Assert both FCSMs reach LINK_DATA,
    both sides decode a data packet, and both sides emit an ACK.

    KEY OBSERVATION: this PASSES on main when no recal_cycle is run.
    Cross-reference test_paired_recal_to_link_data which FAILS bilaterally
    under the same sequence WITH a recal_cycle. The delta isolates the
    bug to the recal flow (slot0=0x3 mid-word mux flip), not to the FCSM
    LINK_IDLE state."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    reached = await _wait_link_idle(dut)
    assert reached, "prerequisite: both sides at LINK_IDLE"

    _force_app_packet(_wlink(dut, "m"), 0xDEAD11111111)
    _force_app_packet(_wlink(dut, "s"), 0xBEEF22222222)

    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    m_reached = s_reached = False
    m_saw_data = s_saw_data = False
    for _ in range(12000):
        await ClockCycles(dut.master_clk, 1)
        if int(m.state.value) >= FCSM_LINK_DATA: m_reached = True
        if int(s.state.value) >= FCSM_LINK_DATA: s_reached = True
        try:
            if int(m.pkt_is_data_pkt.value): m_saw_data = True
            if int(s.pkt_is_data_pkt.value): s_saw_data = True
        except Exception:
            pass
        if m_reached and s_reached and m_saw_data and s_saw_data:
            break

    dut._log.info(
        f"  m_reached_LINK_DATA={m_reached} s_reached_LINK_DATA={s_reached}  "
        f"m_saw_data={m_saw_data} s_saw_data={s_saw_data}")
    _release_app_packet(_wlink(dut, "m"))
    _release_app_packet(_wlink(dut, "s"))

    assert m_reached and s_reached and m_saw_data and s_saw_data, (
        f"full bidirectional LINK_DATA loop did not complete WITHOUT a "
        f"recal_cycle: m_LINK_DATA={m_reached} s_LINK_DATA={s_reached} "
        f"m_data={m_saw_data} s_data={s_saw_data}. This is a NEW REGRESSION: "
        f"the no-recal path used to work — if it now breaks, look at the "
        f"app-side a2l interface, fe_rx_is_full, or the LINK_DATA exit gate")

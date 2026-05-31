"""Bug A localisation: pin down where the master TX path stalls after an
AHB write.

Prior agents established:
  * tl_fc_a2l_valid (master) stays 0 for 500 cy after an AHB write to AHB_TX.
  * Not a credit gate (FCSM fe_rx_credit_max = 0x1f on both dies).
  * Not slave-RX misdecode (unit test 10/10 PASS on 0x002400005000).

Probable next-cause candidates (rank order):
  R1. TX aperture   : tx_data_phase_r never latches  (tidelink_fc_adapter.sv:175-225)
  R2. Skid+arbiter  : skid_can_accept stuck low      (tidelink_fc_adapter.sv:262-400)
  R3. Wlink FCSM    : asymmetric data-mode end state (WlinkGenericFCSM_6.v state)

Each test below pins down one signal in one of those regions and reports the
last-cycle / cycle-count value as the verdict probe. All tests reuse the
PairTB harness and bringup helpers from test_tidelink_pair_doorbell.

NOTE — DO NOT edit existing tests.  This file imports the harness from the
sibling module.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the full bringup machinery from the doorbell test.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ----------------------------------------------------------------------------
# Hierarchical helpers — master side, internal to tidelink_fc_adapter
# ----------------------------------------------------------------------------

def _fc(dut):
    """Handle to master's tidelink_fc_adapter."""
    return dut.u_master.u_fc_adapter


def _safe_read(sig):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


# ----------------------------------------------------------------------------
# Common: drive a 4-word PKT_WR_REQ packet from master, return for analysis
# ----------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


async def _settle_post_bringup(tb):
    """Drop SWI training after the LL bootstrap to mirror HW data-mode and
    give the FCSM credit handshake a chance to settle."""
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


# ============================================================================
# T1 — AHB→FC adapter handoff: does tx_valid_addr_phase pulse at all?
# ============================================================================

@cocotb.test()
async def test_tx_addr_phase_fires(dut):
    """Assert master's tx_valid_addr_phase pulses high during the AHB write.

    tx_valid_addr_phase = ahb_tx_hsel & htrans[1] & hready & hwrite
    (tidelink_fc_adapter.sv:175). If this never fires, the AHB→FC adapter
    handoff is broken — rule out before looking deeper.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig = fc.tx_valid_addr_phase
    pulses = 0

    async def watcher():
        nonlocal pulses
        while True:
            await RisingEdge(dut.hclk)
            if _safe_read(sig) == 1:
                pulses += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    tb._log = dut._log
    dut._log.info(f"  T1 tx_valid_addr_phase pulse-cycles = {pulses}")
    assert pulses > 0, (
        "tx_valid_addr_phase never pulsed — AHB→FC adapter handoff broken "
        "(check ahb_tx_hsel / htrans / hready wiring at fc_adapter port)."
    )


# ============================================================================
# T2 — tx_data_phase_r latches after the AHB write
# ============================================================================

@cocotb.test()
async def test_tx_data_phase_latches(dut):
    """Assert master's tx_data_phase_r goes high within 64 cy of AHB write.

    Set by tx_valid_addr_phase in the FF at tidelink_fc_adapter.sv:181-194.
    If 0, the address-phase handshake failed (T1 must have passed first).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig = fc.tx_data_phase_r
    saw_high = 0
    high_cycles = 0

    async def watcher():
        nonlocal saw_high, high_cycles
        while True:
            await RisingEdge(dut.hclk)
            if _safe_read(sig) == 1:
                saw_high = 1
                high_cycles += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    dut._log.info(
        f"  T2 tx_data_phase_r: ever_high={saw_high} high_cycles={high_cycles}"
    )
    assert saw_high == 1, (
        "tx_data_phase_r never asserted — address-phase handshake failed "
        "(tx_valid_addr_phase fired but the FF didn't latch). "
        "Check skid_can_accept / sideband_grant at fc_adapter.sv:189."
    )


# ============================================================================
# T3 — skid_can_accept high during the test window
# ============================================================================

@cocotb.test()
async def test_skid_can_accept_high(dut):
    """Probe master's skid_can_accept for the full 500 cy post-bringup.

    skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready (fc_adapter.sv:380)
    If always 0, the skid backpressure is permanently asserted — Wlink isn't
    draining (fc_a2l_ready=0 AND skid_valid_r stuck high). That points at
    Wlink not advancing into data-mode (R3) rather than the adapter itself.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig = fc.skid_can_accept
    high_cycles = 0
    total = 500
    for _ in range(total):
        await RisingEdge(dut.hclk)
        if _safe_read(sig) == 1:
            high_cycles += 1

    dut._log.info(
        f"  T3 skid_can_accept high {high_cycles}/{total} cy "
        f"({100.0 * high_cycles / total:.1f}%)"
    )
    assert high_cycles > 0, (
        "skid_can_accept stuck low for full 500 cy — Wlink not draining the "
        "skid (tl_fc_a2l_ready stuck low AND skid_valid_r stuck high). "
        "Inspect Wlink FCSM state next."
    )


# ============================================================================
# T4 — skid_valid_r rises AND tl_fc_a2l_valid follows
# ============================================================================

@cocotb.test()
async def test_skid_valid_advances(dut):
    """After AHB write, master's skid_valid_r must rise; tl_fc_a2l_valid is
    a direct alias of skid_valid_r (fc_adapter.sv:399) so both should pulse.

    If skid_valid_r never rises despite tx_data_phase_r=1, the arbiter is
    starving FIFO_DATA (sideband_grant / ext_grant always wins).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    skid_v = fc.skid_valid_r
    a2l_v  = fc.tl_fc_a2l_valid
    tx_dp  = fc.tx_data_phase_r

    skid_high = 0
    a2l_high = 0
    tx_dp_high = 0

    async def watcher():
        nonlocal skid_high, a2l_high, tx_dp_high
        while True:
            await RisingEdge(dut.hclk)
            if _safe_read(skid_v) == 1: skid_high += 1
            if _safe_read(a2l_v)  == 1: a2l_high  += 1
            if _safe_read(tx_dp)  == 1: tx_dp_high += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 500)

    dut._log.info(
        f"  T4 skid_valid_r high={skid_high} cy, "
        f"tl_fc_a2l_valid high={a2l_high} cy, tx_data_phase_r high={tx_dp_high} cy"
    )
    # The packet is 4 words; each should pulse skid_valid_r for at least 1 cy
    # (more if Wlink is slow to accept). We're checking the LOAD side.
    assert skid_high > 0, (
        "skid_valid_r never rose — arbiter starvation suspected "
        f"(tx_data_phase_r high {tx_dp_high} cy but no skid load). "
        "Inspect arb_valid / sideband_grant / ext_grant at fc_adapter.sv:368-373."
    )
    # tl_fc_a2l_valid is a direct alias, so it MUST follow skid_valid_r.
    assert a2l_high == skid_high, (
        f"tl_fc_a2l_valid ({a2l_high}) != skid_valid_r ({skid_high}); "
        "alias broken — RTL aliasing bug?"
    )


# ============================================================================
# T5 — Wlink FCSM state progression: symmetric data-mode entry?
# ============================================================================

@cocotb.test()
async def test_fcsm_state_progression(dut):
    """Probe the Wlink FCSM `state` reg on both dies. Both MUST reach the
    same steady data-traffic state after to_data_mode.

    Per WlinkGenericFCSM_6.v, state 4 = data-mode (FC.scala 501). Asymmetric
    M=4/S=5 or sticky state=2/3 indicates the byte-align FCSM bug class
    (same family as the 2026-05-24 WavD2DGpioTx.v:43 bug).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")

    # Track the unique state values seen on each side over 1500 cy. The
    # final state and the dominant state are the verdict probes.
    m_states = {}
    s_states = {}
    m_last = -1
    s_last = -1
    for _ in range(1500):
        await RisingEdge(dut.hclk)
        mv = _safe_read(m_fcsm.state)
        sv = _safe_read(s_fcsm.state)
        m_states[mv] = m_states.get(mv, 0) + 1
        s_states[sv] = s_states.get(sv, 0) + 1
        m_last = mv
        s_last = sv

    dut._log.info(f"  T5 master FCSM state histogram = {sorted(m_states.items())}")
    dut._log.info(f"  T5 slave  FCSM state histogram = {sorted(s_states.items())}")
    dut._log.info(f"  T5 final states M={m_last} S={s_last}")

    # Pass conditions:
    #   1. Both sides reached state >= 4 at some point (data-mode entry).
    #   2. Final state is symmetric (M_last == S_last).
    m_reached_data = any(s >= 4 for s in m_states.keys() if s >= 0)
    s_reached_data = any(s >= 4 for s in s_states.keys() if s >= 0)

    assert m_reached_data, f"master FCSM never reached state>=4 (data-mode): histogram={m_states}"
    assert s_reached_data, f"slave  FCSM never reached state>=4 (data-mode): histogram={s_states}"
    assert m_last == s_last, (
        f"FCSM end-state asymmetry — M={m_last} vs S={s_last}. "
        "Byte-align bug class recurrence; cross-check WavD2DGpioTx.v:43."
    )


# ============================================================================
# T6 — direct probe of fc_a2l valid/ready handshake on master
# ============================================================================

@cocotb.test()
async def test_wlink_a2l_handshake(dut):
    """Probe master's tl_fc_a2l_valid + tl_fc_a2l_ready directly.

    Verdict:
      - ready=1 cycles ≫ valid=1 cycles  →  fc_adapter is the block (no TX data offered)
      - valid=1 cycles ≫ ready=1 cycles  →  Wlink is the block (refusing to drain)
      - both 0                            →  full pipeline frozen — most likely R3
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    a2l_v = fc.tl_fc_a2l_valid
    a2l_r = fc.tl_fc_a2l_ready

    valid_cy = 0
    ready_cy = 0
    handshake_cy = 0

    async def watcher():
        nonlocal valid_cy, ready_cy, handshake_cy
        while True:
            await RisingEdge(dut.hclk)
            v = _safe_read(a2l_v)
            r = _safe_read(a2l_r)
            if v == 1: valid_cy += 1
            if r == 1: ready_cy += 1
            if v == 1 and r == 1: handshake_cy += 1

    cocotb.start_soon(watcher())

    # Drive a packet so something WANTS to transmit.
    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 1000)

    dut._log.info(
        f"  T6 master  a2l_valid={valid_cy} cy  a2l_ready={ready_cy} cy  "
        f"handshakes={handshake_cy} cy"
    )

    # The packet is 4 words; we expect at least 4 handshake cycles.
    assert handshake_cy >= 4, (
        f"a2l handshake failed — only {handshake_cy} v&r cycles in 1000 cy "
        f"(valid={valid_cy}, ready={ready_cy}). "
        + (
            "ready high but valid low → fc_adapter is the block."
            if ready_cy > 50 and valid_cy < 4
            else "valid high but ready low → Wlink FCSM is the block."
            if valid_cy > 50 and ready_cy < 4
            else "both stalled → upstream Wlink FCSM not in data-mode."
        )
    )

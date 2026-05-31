"""Bug A H-A1 verdict tests — master AHB → tidelink_fc_adapter handoff.

Prior agents established:
  * master AHB writes to AHB_TX @ 0x44000000 return HREADY in 0.17 ms
  * slave AHB RX FIFO stays empty 500 cy after the writes
  * tl_fc_a2l_valid stays 0 on the master for 500 cy
  * NOT credit-gated (fe_rx_credit_max = 0x1f on both dies)
  * NOT slave-RX misdecode (FC-adapter unit test 10/10 PASS for the symptom)
  * Bug is on the master TX side, UPSTREAM of Wlink.

H-A1: master `tx_data_phase_r` never latches when AHB writes to AHB_TX,
which would break the AHB → FC adapter handoff.

This file walks the handoff signal chain in `tidelink_fc_adapter.sv`:

  ahb_tx_hsel & ahb_tx_hwrite & ahb_tx_hready          (port-level entry)
    -> tx_valid_addr_phase   (combinational, line 175)
       = ahb_tx_hsel & htrans[1] & hready & hwrite
    -> tx_data_phase_r       (FF, lines 181-194; THIS is the H-A1 signal)
    -> tx_fc_valid           (combinational, line 198, == tx_data_phase_r)
    -> arbiter / skid load   (lines 387-396)
    -> skid_valid_r          (FF, line 389)
    -> tl_fc_a2l_valid       (combinational alias, line 399)

Hier path (master): `dut.u_master.u_fc_adapter.<signal>` (no generate scope).

DO NOT touch other agents' test files. DO NOT touch RTL.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the bringup machinery from the doorbell test.
from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Probe helpers
# ---------------------------------------------------------------------------

def _fc(dut):
    """Master tidelink_fc_adapter handle."""
    return dut.u_master.u_fc_adapter


def _safe(sig):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


# ---------------------------------------------------------------------------
# Stimulus — 4-word PKT_WR_REQ packet (length=2 payload, matches handoff spec)
# ---------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    # word1 = dest_addr (0x0 — slave RX FIFO base). words 2..n = payload.
    return [word0, 0x0] + PAYLOAD


async def _settle_post_bringup(tb):
    """Drop SWI training after LL bootstrap so the data-mode FCSM handshake
    settles, mirroring the HW environment."""
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


# ===========================================================================
# Test 1 — AHB ever reaches fc_adapter at all?
# ===========================================================================

@cocotb.test()
async def test_ahb_tx_aperture_pulses(dut):
    """Probe `ahb_tx_hsel & ahb_tx_hwrite & ahb_tx_hready` on the master
    fc_adapter for a 4-word PKT_WR_REQ (1 length word + 1 dest_addr + 2
    payload). Expect at least 3 distinct fully-handshaken cycles where AHB
    is presenting a valid write the slave is ready for.

    Note: the prior agent's prompt refers to `htx_*`. The actual fc_adapter
    port names are `ahb_tx_*` (see tidelink_fc_adapter.sv:175 and
    tidelink_top.sv:1126-1135).

    If zero, AHB never reaches the fc_adapter — wiring is broken at the
    tidelink_top port level.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    pulses = 0

    async def watcher():
        nonlocal pulses
        while True:
            await RisingEdge(dut.hclk)
            hs = _safe(fc.ahb_tx_hsel)
            hw = _safe(fc.ahb_tx_hwrite)
            hr = _safe(fc.ahb_tx_hready)
            if hs == 1 and hw == 1 and hr == 1:
                pulses += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    dut._log.info(
        f"  T-AHB ahb_tx_hsel&hwrite&hready handshake cycles = {pulses}"
    )
    assert pulses >= 3, (
        f"AHB write handshake cycles ({pulses}) < 3 — AHB never reaches "
        "fc_adapter for the 4-word packet. Wiring at the tidelink_top port "
        "level is broken (tidelink_top.sv:1126-1135)."
    )


# ===========================================================================
# Test 2 — Address phase latches: tx_valid_addr_phase pulses
# ===========================================================================

@cocotb.test()
async def test_tx_addr_phase_latches(dut):
    """Probe master `tx_valid_addr_phase` (combinational, fc_adapter.sv:175).

    There is NO `tx_addr_phase_r` register (the design relies on the
    combinational `tx_valid_addr_phase` driving the FF that sets
    tx_data_phase_r). So the closest proxy for "address phase observed"
    is the combinational gate itself.

    Pass: tx_valid_addr_phase pulses at least once after the AHB write.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    addr_pulses = 0
    tx_addr_r_values = set()

    async def watcher():
        nonlocal addr_pulses
        while True:
            await RisingEdge(dut.hclk)
            if _safe(fc.tx_valid_addr_phase) == 1:
                addr_pulses += 1
                tx_addr_r_values.add(_safe(fc.tx_addr_r))

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    dut._log.info(
        f"  T-ADDR tx_valid_addr_phase pulses = {addr_pulses}, "
        f"tx_addr_r values observed = {sorted(tx_addr_r_values)}"
    )
    assert addr_pulses > 0, (
        "tx_valid_addr_phase never pulsed — AHB address-phase signal "
        "(hsel & htrans[1] & hready & hwrite) never co-aligned. "
        "Check ahb_tx_htrans wiring (PairTB._ahb_tx_write_word sets "
        "htrans=2 during the address phase)."
    )


# ===========================================================================
# Test 3 — *** H-A1 VERDICT *** tx_data_phase_r latches
# ===========================================================================

@cocotb.test()
async def test_tx_data_phase_latches(dut):
    """**H-A1 verdict test.**

    `tx_data_phase_r` is set by the FF at fc_adapter.sv:186-188 whenever
    `tx_valid_addr_phase` is high. If `tx_valid_addr_phase` pulses (proven
    by test_tx_addr_phase_latches) but `tx_data_phase_r` never goes high,
    the FF itself is failing to latch — H-A1 is CONFIRMED.

    Most likely root causes for an H-A1 fail:
      * `hresetn` stuck low on the fc_adapter clock domain
      * The FF's `else` clause (line 189-191) firing in the SAME cycle as
        the set, because skid_can_accept && !sideband_grant && data_phase_r
        was already true (a self-clearing race).

    Probe both `tx_data_phase_r` and the load enable (`tx_valid_addr_phase`)
    on the SAME edges so we can reason about cause/effect.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    data_phase_high_cycles = 0
    ever_high = 0
    addr_pulses = 0

    async def watcher():
        nonlocal data_phase_high_cycles, ever_high, addr_pulses
        while True:
            await RisingEdge(dut.hclk)
            if _safe(fc.tx_data_phase_r) == 1:
                data_phase_high_cycles += 1
                ever_high = 1
            if _safe(fc.tx_valid_addr_phase) == 1:
                addr_pulses += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    dut._log.info(
        f"  T-DATA tx_data_phase_r ever_high={ever_high} "
        f"high_cycles={data_phase_high_cycles} "
        f"(addr_phase_pulses={addr_pulses})"
    )

    assert ever_high == 1, (
        f"H-A1 CONFIRMED: tx_data_phase_r never latched in 200+ cy after "
        f"AHB write, despite tx_valid_addr_phase pulsing {addr_pulses} "
        f"times. The FF at tidelink_fc_adapter.sv:181-194 is failing to "
        "set on its load signal. Inspect hresetn on the fc_adapter clock "
        "domain and the self-clearing race at line 189."
    )


# ===========================================================================
# Test 4 — Returner busy clears (sim mirrors HW handoff report)
# ===========================================================================

@cocotb.test()
async def test_tx_returner_busy_clears(dut):
    """HW handoff report says master returns HREADY in 0.17 ms after the
    AHB write — i.e. the returner pending state pulses then clears.

    Proxy in sim: master fc_adapter's `rtn_pending_r`. (The returner module
    itself lives in `tidelink.sv` and exposes `returner_busy`; fc_adapter
    sees the resulting AHB-master writes via `rtn_*` ports and tracks them
    with `rtn_pending_r` at line 224.)

    Pass: rtn_pending_r either stays low (no returner activity in the test
    window) OR pulses and clears. Sticky-high is the failure mode.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    high_cycles = 0
    last_low_cy = 0
    final_value = 0

    await tb.ahb_tx_write_packet("m", _packet_words())

    for cy in range(500):
        await RisingEdge(dut.hclk)
        v = _safe(fc.rtn_pending_r)
        if v == 1:
            high_cycles += 1
        else:
            last_low_cy = cy
        final_value = v

    dut._log.info(
        f"  T-RTN rtn_pending_r high_cycles={high_cycles}/500 "
        f"last_low_cy={last_low_cy} final={final_value}"
    )
    # Failure shape: sticky-high. Sim mirrors HW if it eventually clears.
    assert final_value == 0, (
        f"rtn_pending_r STUCK HIGH for the full window (last_low_cy="
        f"{last_low_cy}, high_cycles={high_cycles}/500). "
        "Returner side of fc_adapter is wedged — skid_can_accept stuck low "
        "OR the AHB-master returner is repeatedly re-asserting a write that "
        "the fc_adapter can't drain. See tidelink_fc_adapter.sv:226-238."
    )


# ===========================================================================
# Test 5 — Full handoff timing trace (always runs, ALWAYS produces evidence)
# ===========================================================================

@cocotb.test()
async def test_tx_addr_data_handshake_timing(dut):
    """Log the full handoff sequence cycle-by-cycle over 200 cy after the
    AHB write starts. Produces a timing trace whether the link is healthy
    or wedged.

    Columns logged per cycle (only when something changes):
      cy : hready_pulse, addr_phase, data_phase_r, tx_fc_valid,
           arb_valid, skid_can_accept, skid_valid_r, a2l_valid, a2l_ready

    The assertion at the end is the verdict roll-up: at least one cycle
    must have a2l_valid high AND ready high (i.e. one FC word handed off
    to Wlink). If the sequence stops at any stage the trace shows where.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)

    counts = dict(
        ahb_handshake=0,
        addr_phase=0,
        data_phase=0,
        tx_fc_valid=0,
        arb_valid=0,
        skid_can_accept=0,
        skid_valid_r=0,
        a2l_valid=0,
        a2l_ready=0,
        a2l_full_handshake=0,
    )

    # Start sampling on a background task BEFORE issuing the AHB write so
    # we don't miss the first address-phase pulse.
    sampling = True

    async def trace():
        prev = None
        cy = 0
        while sampling:
            await RisingEdge(dut.hclk)
            cy += 1
            row = (
                _safe(fc.ahb_tx_hsel) & _safe(fc.ahb_tx_hwrite) & _safe(fc.ahb_tx_hready),
                _safe(fc.tx_valid_addr_phase),
                _safe(fc.tx_data_phase_r),
                _safe(fc.tx_fc_valid),
                _safe(fc.arb_valid),
                _safe(fc.skid_can_accept),
                _safe(fc.skid_valid_r),
                _safe(fc.tl_fc_a2l_valid),
                _safe(fc.tl_fc_a2l_ready),
            )
            counts["ahb_handshake"]    += 1 if row[0] == 1 else 0
            counts["addr_phase"]        += 1 if row[1] == 1 else 0
            counts["data_phase"]        += 1 if row[2] == 1 else 0
            counts["tx_fc_valid"]       += 1 if row[3] == 1 else 0
            counts["arb_valid"]         += 1 if row[4] == 1 else 0
            counts["skid_can_accept"]   += 1 if row[5] == 1 else 0
            counts["skid_valid_r"]      += 1 if row[6] == 1 else 0
            counts["a2l_valid"]         += 1 if row[7] == 1 else 0
            counts["a2l_ready"]         += 1 if row[8] == 1 else 0
            if row[7] == 1 and row[8] == 1:
                counts["a2l_full_handshake"] += 1
            if row != prev:
                dut._log.info(
                    f"  cy+{cy:03d} "
                    f"ahb_hs={row[0]} addr={row[1]} data_r={row[2]} "
                    f"tx_fc_v={row[3]} arb_v={row[4]} "
                    f"sk_can={row[5]} sk_v={row[6]} "
                    f"a2l_v={row[7]} a2l_r={row[8]}"
                )
                prev = row

    cocotb.start_soon(trace())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 500)
    sampling = False
    await ClockCycles(dut.hclk, 2)

    dut._log.info(
        f"  T-TRACE counts: ahb_hs={counts['ahb_handshake']} "
        f"addr={counts['addr_phase']} data_r={counts['data_phase']} "
        f"tx_fc_v={counts['tx_fc_valid']} arb_v={counts['arb_valid']} "
        f"sk_can={counts['skid_can_accept']} sk_v={counts['skid_valid_r']} "
        f"a2l_v={counts['a2l_valid']} a2l_r={counts['a2l_ready']} "
        f"a2l_handshake={counts['a2l_full_handshake']}"
    )

    # Roll-up verdict: at least one FC word must be handed off (4 expected).
    assert counts["a2l_full_handshake"] >= 1, (
        f"NO FC handshakes in the trace window. Stage histogram: "
        f"ahb_hs={counts['ahb_handshake']} -> addr={counts['addr_phase']} "
        f"-> data_r={counts['data_phase']} -> tx_fc_v={counts['tx_fc_valid']} "
        f"-> arb_v={counts['arb_valid']} -> sk_v={counts['skid_valid_r']} "
        f"-> a2l_v={counts['a2l_valid']} (ready={counts['a2l_ready']}). "
        "Locate the first '0' stage to find the break point."
    )

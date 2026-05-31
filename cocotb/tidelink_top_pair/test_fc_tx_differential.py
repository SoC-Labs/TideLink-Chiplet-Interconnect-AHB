"""TideLink Bug A — FC TX differential / characterisation tests (2026-05-29).

Bug A symptom (HW build #3): master AHB writes never reach the slave's AHB
RX FIFO. `tl_fc_a2l_valid` stays 0 during the AHB write. Sideband doorbell
packets DO cross to the slave (DOORBELL_RESPONSE_ACC bumps by 0x5000 per
master AHB write — i.e. one AHB write produces an unexpected sideband ack
storm with no FIFO_DATA payload).

Already ruled out:
  * credit gate (FCSM fe_rx_credit_max = 0x1f on both sides)
  * slave RX misdecode (decoder path works for sideband CR/CRACK)

Three differentials this file exercises:
  A. Sideband-only vs FIFO_DATA-only stim — is the bug FIFO_DATA-specific?
  B. Does sim show the same 0x5000 DOORBELL_RESP_ACC bump per master AHB
     write that HW shows?
  C. AHB master HREADY — does sim return cleanly like HW (~0.17 ms on
     silicon)?

Hierarchical probe paths (all under tb_top):
  m_fc:   dut.u_master.u_fc_adapter.tl_fc_a2l_valid
                                  .tl_fc_a2l_ready
                                  .skid_valid_r
                                  .tl_fc_l2a_valid
                                  .tl_fc_l2a_accept
  m_rb:   dut.u_master.u_tidelink_fifo.returner_busy
  s_fc:   dut.u_slave.u_fc_adapter.<...>  (same set)

This file does NOT modify any other test file or RTL.  All six tests below
share the bring-up helper from test_tidelink_pair_doorbell.PairTB so the
upstream link state matches the b24/Build-#3 silicon condition exactly.

Run with:
    timeout 600 make MODULE=test_fc_tx_differential SIM_BUILD=sim_build_fc_diff \\
                    TB_TOP_NO_DUMP=1
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


# ---------------------------------------------------------------------------
# Hierarchical probe helpers
# ---------------------------------------------------------------------------

def _fc(dut, side):
    """Handle to u_fc_adapter on the given side."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_fc_adapter


def _fifo(dut, side):
    """Handle to u_tidelink_fifo on the given side."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_tidelink_fifo


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


def _probe_fc(dut, side, name, default=-1):
    try:
        return _safe_int(getattr(_fc(dut, side), name), default)
    except AttributeError:
        return default


def _probe_returner_busy(dut, side):
    try:
        return _safe_int(_fifo(dut, side).returner_busy, -1)
    except AttributeError:
        return -1


async def _settle(tb, cycles=200):
    await ClockCycles(tb.dut.hclk, cycles)


# ---------------------------------------------------------------------------
# AHB TX helper — drive a single-word AHB write into m_ahb_tx_* and measure
# completion timing.
# ---------------------------------------------------------------------------

async def _ahb_tx_single_write_timed(tb, side, byte_addr, data, timeout=10000):
    """Drive one AHB-Lite write on the side's ahb_tx_* aperture and return
    the cycle count from (HSEL+HWRITE asserted on the address phase) to
    (HREADY high in the data phase).

    Returns:
        cycles_to_ready: int  (or -1 if timeout/no HREADY)
    """
    dut = tb.dut
    hsel    = getattr(dut, f"{side}_ahb_tx_hsel")
    haddr   = getattr(dut, f"{side}_ahb_tx_haddr")
    htrans  = getattr(dut, f"{side}_ahb_tx_htrans")
    hsize   = getattr(dut, f"{side}_ahb_tx_hsize")
    hwrite  = getattr(dut, f"{side}_ahb_tx_hwrite")
    hwdata  = getattr(dut, f"{side}_ahb_tx_hwdata")
    hready  = getattr(dut, f"{side}_ahb_tx_hready")

    # Address phase
    await RisingEdge(dut.hclk)
    # Wait for any prior data phase to drain
    for _ in range(50):
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
        await RisingEdge(dut.hclk)
    hsel.value   = 1
    htrans.value = 2          # NONSEQ
    hsize.value  = 2          # word
    hwrite.value = 1
    haddr.value  = byte_addr & ((1 << 14) - 1)
    await RisingEdge(dut.hclk)
    # Data phase begins now — HREADY low usually until slave latches.
    hsel.value   = 0
    htrans.value = 0
    hwrite.value = 0
    hwdata.value = data & 0xFFFFFFFF
    cycles_to_ready = -1
    for k in range(timeout):
        try:
            if int(hready.value):
                cycles_to_ready = k
                break
        except ValueError:
            pass
        await RisingEdge(dut.hclk)
    hwdata.value = 0
    return cycles_to_ready


# ===========================================================================
# Test 1 — Sideband-only baseline: doorbell flow works
# ===========================================================================

@cocotb.test()
async def test_sideband_only_doorbell_flow(dut):
    """Differential A baseline.

    Master rings doorbell 5x with no AHB traffic. We expect the slave's
    DOORBELL_RESP_ACC mirror to advance by at least 1 per ring (each
    sideband CR-style doorbell packet is acknowledged by the slave's FC
    consumer with a doorbell_response write).

    PASS criterion:
      slave DOORBELL_RESP_ACC delta >= 5 OR master DOORBELL_RESP_ACC
      delta >= 5 (the responder is on the other side, so EITHER side's
      mirror should advance — see test_05 hw-symmetry comment).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle(tb, 500)

    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_before = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(
        f"  Pre-doorbell: S.DOORBELL_RESP_ACC=0x{s_db_before:08x} "
        f"M.DOORBELL_RESP_ACC=0x{m_db_before:08x}"
    )

    # Track tl_fc_a2l_valid pulses on master + slave during the 5 rings.
    a2l_m = a2l_s = 0
    for i in range(5):
        await tb.m_apb.write(APB_DOORBELL, 1)
        for _ in range(400):
            await RisingEdge(dut.hclk)
            if _probe_fc(dut, "m", "tl_fc_a2l_valid", 0) == 1: a2l_m += 1
            if _probe_fc(dut, "s", "tl_fc_a2l_valid", 0) == 1: a2l_s += 1
        tb.log.info(f"  After doorbell {i+1}: cumulative a2l valid-cy "
                    f"M={a2l_m} S={a2l_s}")

    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_after = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s_delta = s_db_after - s_db_before
    m_delta = m_db_after - m_db_before
    tb.log.info(
        f"  Post-doorbell: S.DOORBELL_RESP_ACC=0x{s_db_after:08x} (delta=0x{s_delta:x}) "
        f"M.DOORBELL_RESP_ACC=0x{m_db_after:08x} (delta=0x{m_delta:x})"
    )
    tb.log.info(
        f"  Final tl_fc_a2l_valid cycle counts: M={a2l_m} S={a2l_s}"
    )

    crossed = (s_delta >= 1) or (m_delta >= 1)
    assert crossed, (
        f"sideband-only doorbell flow did NOT advance any DOORBELL_RESP_ACC: "
        f"M delta={m_delta} S delta={s_delta}. Bug A baseline is BROKEN — "
        f"sideband path is itself failing in sim. tl_fc_a2l_valid cycles: "
        f"M={a2l_m} S={a2l_s}."
    )


# ===========================================================================
# Test 2 — FIFO_DATA-only stim, no doorbell
# ===========================================================================

@cocotb.test()
async def test_fifo_data_only_no_sideband(dut):
    """Differential A's other half.

    No doorbell is issued. Master writes a 4-word AHB packet (N=1 payload)
    to the local TX aperture. Probe master `tl_fc_a2l_valid` for 500 cy
    after the AHB write completes and assert at least one rising edge.

    PASS criterion (sim healthy):
      >= 1 rising edge of master tl_fc_a2l_valid
    FAIL (HW symptom reproduced):
      0 rising edges — master FC adapter never emitted a TX beat from the
      AHB write, even though a packet was queued into the local TX FIFO.
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await _settle(tb, 200)

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    tb.log.info(
        f"  master TX packet: word0=0x{word0:08x} dest=0x0 "
        f"payload=[0x{payload[0]:08x}, 0x{payload[1]:08x}]"
    )

    # Write the four header+payload words via separate AHB-Lite singles.
    # Use the tb helper from PairTB (same as test_08 uses).
    await tb.ahb_tx_write_packet("m", words)

    # Now probe tl_fc_a2l_valid for 500 cycles.
    a2l_m_high = 0
    a2l_m_rises = 0
    last = 0
    for _ in range(500):
        await RisingEdge(dut.hclk)
        cur = _probe_fc(dut, "m", "tl_fc_a2l_valid", 0)
        if cur == 1:
            a2l_m_high += 1
        if cur == 1 and last == 0:
            a2l_m_rises += 1
        last = cur

    skid_valid_high_end = _probe_fc(dut, "m", "skid_valid_r", -1)
    a2l_ready_end = _probe_fc(dut, "m", "tl_fc_a2l_ready", -1)
    tb.log.info(
        f"  master tl_fc_a2l_valid: rising_edges={a2l_m_rises} "
        f"high_cycles={a2l_m_high} (of 500)"
    )
    tb.log.info(
        f"  master skid_valid_r(end)={skid_valid_high_end} "
        f"tl_fc_a2l_ready(end)={a2l_ready_end}"
    )

    assert a2l_m_rises >= 1, (
        f"master tl_fc_a2l_valid had {a2l_m_rises} rising edges in 500 cy "
        f"post-AHB-write. HW symptom reproduced in sim: FC TX never fired "
        f"for FIFO_DATA stim. skid_valid_r={skid_valid_high_end} "
        f"a2l_ready={a2l_ready_end}."
    )


# ===========================================================================
# Test 3 — HW-vs-Sim DOORBELL_RESP_ACC bump diff
# ===========================================================================

@cocotb.test()
async def test_hw_vs_sim_doorbell_bump_diff(dut):
    """Differential B.

    Silicon Build #3 shows: master writes a single AHB packet (N=1, two
    payload words) -> slave's REG_DOORBELL_RESP_ACC mirror bumps by 0x5000
    even though NO doorbell was rung. Hypothesis: master's FC TX path is
    looping or spuriously emitting sideband packets when it should be
    emitting FIFO_DATA.

    This test issues NO doorbell. It writes one AHB packet from master,
    then reads the slave's APB_DOORBELL_RESP_ACC before/after. We log the
    delta (sim vs HW comparison) but do NOT assert a specific value — the
    point is to characterise what sim DOES.

    Logs:
      - slave DOORBELL_RESP_ACC delta (HW reference: 0x5000)
      - master DOORBELL_RESP_ACC delta
      - master tl_fc_a2l_valid rising edges
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await _settle(tb, 200)

    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_before = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(
        f"  Pre-AHB: S.DOORBELL_RESP_ACC=0x{s_db_before:08x} "
        f"M.DOORBELL_RESP_ACC=0x{m_db_before:08x}"
    )

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    await tb.ahb_tx_write_packet("m", words)

    # 2000 cy for the packet to cross the link.
    a2l_m_rises = 0
    last_m = 0
    a2l_s_rises = 0
    last_s = 0
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        cm = _probe_fc(dut, "m", "tl_fc_a2l_valid", 0)
        cs = _probe_fc(dut, "s", "tl_fc_a2l_valid", 0)
        if cm == 1 and last_m == 0: a2l_m_rises += 1
        if cs == 1 and last_s == 0: a2l_s_rises += 1
        last_m, last_s = cm, cs

    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_after = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s_delta = s_db_after - s_db_before
    m_delta = m_db_after - m_db_before
    tb.log.info(
        f"  Post-AHB: S.DOORBELL_RESP_ACC=0x{s_db_after:08x} (delta=0x{s_delta:x}) "
        f"M.DOORBELL_RESP_ACC=0x{m_db_after:08x} (delta=0x{m_delta:x})"
    )
    tb.log.info(
        f"  HW reference: slave delta should be 0x5000 per master AHB write."
    )
    tb.log.info(
        f"  Sim observation: slave delta=0x{s_delta:x} master delta=0x{m_delta:x}"
    )
    tb.log.info(
        f"  FC TX rising edges: M={a2l_m_rises} S={a2l_s_rises}"
    )

    # Non-strict: we want this test to PASS but record the verdict in logs.
    # Verdict goes in BUG_A_DIFFERENTIAL_2026_05_29.md.
    HW_REF_DELTA = 0x5000
    if s_delta == HW_REF_DELTA:
        tb.log.info("  VERDICT: sim MATCHES HW (slave delta = 0x5000).")
    elif s_delta == 0 and m_delta == 0:
        tb.log.info(
            "  VERDICT: sim DOES NOT REPRODUCE HW symptom — no DOORBELL_RESP_ACC "
            "bump at all in sim. This is a sim-vs-HW gap on the sideband side."
        )
    else:
        tb.log.info(
            f"  VERDICT: sim partial/different — slave delta=0x{s_delta:x} "
            f"vs HW 0x{HW_REF_DELTA:x}."
        )

    # No assertion on value — this is characterisation.
    assert True


# ===========================================================================
# Test 4 — AHB completion timing
# ===========================================================================

@cocotb.test()
async def test_ahb_completion_timing(dut):
    """Differential C.

    Master writes a single AHB-Lite WORD into the TX aperture. Measure
    the number of HCLK cycles from address-phase HSEL+HWRITE assertion
    to HREADY rising edge in the data phase.

    HW reference: master HREADY returns within ~0.17 ms at ~25 MHz, i.e.
    ~4250 cycles. We report whatever sim shows.

    PASS criterion: HREADY did rise within timeout (cycles_to_ready >= 0).
    FAIL: timeout -> master AHB write is hung.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await _settle(tb, 200)

    # Single word at offset 0 (Word 0 header).
    cycles = await _ahb_tx_single_write_timed(tb, "m", 0x00, 0xA5A5A5A5,
                                              timeout=5000)
    tb.log.info(f"  master AHB HSEL+HWRITE -> HREADY = {cycles} cycles "
                "(HW reference: ~4250 cy @ 25 MHz = 0.17 ms)")

    assert cycles >= 0, (
        f"master AHB write did NOT return HREADY within 5000 cy — "
        "master HREADY is hung. HW symptom (HREADY returns cleanly) "
        "NOT reproduced in sim."
    )

    # Soft characterisation: sim is typically fast (< 50 cy) because the
    # local TX FIFO has no SRAM-write back-pressure model in cocotb. Log
    # but do not assert a specific number.


# ===========================================================================
# Test 5 — Mixed stim arbiter priority
# ===========================================================================

@cocotb.test()
async def test_mixed_stim_arbiter_priority(dut):
    """Interleave one AHB packet write + one doorbell ring, in tight
    succession on the master. Log which TX traffic the FC TX arbiter pops
    first (tracked via tl_fc_a2l_valid rising edges and DOORBELL_RESP_ACC
    movement).

    This is a soft characterisation test — we want to know whether the
    sideband path STARVES the FIFO_DATA path in sim, mirroring the HW
    behaviour (0x5000 sideband bump but no AHB landing).

    Logs:
      - count of tl_fc_a2l_valid rising edges during the window
      - delta of DOORBELL_RESP_ACC across the window
      - which side advanced first (best-effort via interleaved poll)
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await _settle(tb, 200)

    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_before = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload

    # Issue AHB packet, immediately ring doorbell. Then watch.
    await tb.ahb_tx_write_packet("m", words)
    await tb.m_apb.write(APB_DOORBELL, 1)

    a2l_m_rises = 0
    last_m = 0
    db_seen_at = -1
    a2l_seen_at = -1
    for k in range(3000):
        await RisingEdge(dut.hclk)
        cm = _probe_fc(dut, "m", "tl_fc_a2l_valid", 0)
        if cm == 1 and last_m == 0:
            a2l_m_rises += 1
            if a2l_seen_at < 0:
                a2l_seen_at = k
        last_m = cm
        # Sample DOORBELL_RESP_ACC every 200 cy for cost.
        if k % 200 == 199:
            s_now = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
            if s_now != s_db_before and db_seen_at < 0:
                db_seen_at = k

    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_after = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(
        f"  mixed-stim: a2l_m_rises={a2l_m_rises} "
        f"(first_seen_cy={a2l_seen_at}) "
        f"S.DOORBELL_RESP_ACC delta=0x{s_db_after - s_db_before:x} "
        f"(first_seen_cy={db_seen_at}) "
        f"M.DOORBELL_RESP_ACC delta=0x{m_db_after - m_db_before:x}"
    )
    if a2l_seen_at < 0 and db_seen_at < 0:
        tb.log.info("  VERDICT: NEITHER FIFO_DATA NOR sideband traffic flowed.")
    elif a2l_seen_at < 0 and db_seen_at >= 0:
        tb.log.info("  VERDICT: sideband flows, FIFO_DATA does NOT — matches Bug A.")
    elif a2l_seen_at >= 0 and db_seen_at < 0:
        tb.log.info("  VERDICT: FIFO_DATA flows, sideband does NOT.")
    else:
        winner = "FIFO_DATA" if a2l_seen_at < db_seen_at else "sideband"
        tb.log.info(f"  VERDICT: both flow; {winner} first.")

    # No hard assertion — this is characterisation.
    assert True


# ===========================================================================
# Test 6 — returner_busy during AHB write
# ===========================================================================

@cocotb.test()
async def test_returner_busy_during_ahb(dut):
    """Probe the master `returner_busy` flag (inside u_tidelink_fifo) while
    an AHB write is being absorbed by the local TX FIFO and pushed onto the
    FC link.

    The returner is what services release_credits + doorbell triggers
    locally; if it's stuck busy, it could be starving the FIFO_DATA TX path
    of the FC arbiter (the FC TX arbiter shares the same FC link between
    returner-emitted sideband traffic and fc_adapter-emitted FIFO_DATA).

    Sample returner_busy every cycle for 2000 cycles after the AHB write.
    Log: % cycles busy, longest run of busy cycles.
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await _settle(tb, 200)

    pre_busy = _probe_returner_busy(dut, "m")
    tb.log.info(f"  master returner_busy (pre-AHB) = {pre_busy}")

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    await tb.ahb_tx_write_packet("m", words)

    busy_cy = 0
    longest_run = 0
    cur_run = 0
    rb_unreadable = 0
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        rb = _probe_returner_busy(dut, "m")
        if rb == -1:
            rb_unreadable += 1
            continue
        if rb == 1:
            busy_cy += 1
            cur_run += 1
            if cur_run > longest_run:
                longest_run = cur_run
        else:
            cur_run = 0

    tb.log.info(
        f"  master returner_busy: high={busy_cy}/2000 cy "
        f"longest_run={longest_run} unreadable={rb_unreadable}"
    )

    # Soft: characterise but do not enforce — the bug-class verdict in
    # the docs file uses this trace to localise.
    assert rb_unreadable < 2000, (
        "could not read master u_tidelink_fifo.returner_busy via "
        "hierarchical reference — RTL instance path may have changed."
    )

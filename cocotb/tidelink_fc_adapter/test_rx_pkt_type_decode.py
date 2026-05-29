"""Cocotb unit tests for FC RX rx_pkt_type decode and routing — Bug A localiser.

Silicon symptom (docs/HANDOFF_REPORT_2026_05_29.md §A-1, 60% hypothesis):
  Master → slave AHB packets fail. Master FC adapter never asserts
  tl_fc_a2l_valid. PAIR_CREDIT_COUNTER stays at 0 on both sides.
  Slave REG_DOORBELL_RESP_ACC (0x024) bumps by 0x5000 per master AHB write
  while slave AHB RX FIFO stays empty.

Leading RTL hypothesis: the slave FC adapter's RX FSM mis-decodes
  rx_pkt_type = rx_fc_word_r[47:46]  (tidelink_fc_adapter.sv:433)
picking SIDEBAND (01) instead of FIFO_DATA (00) — routing AHB
payload words to the APB cfg port (0x024 doorbell) instead of the
direct-write FIFO port.

This file isolates the RX FSM and tries every input sequence I can think
of that might produce a mis-decode:
  - clean type=00 (FIFO_DATA)              → FIFO port write
  - clean type=01 (SIDEBAND, addr 0x024)   → APB cfg write
  - back-to-back SIDEBAND→FIFO             → no aliasing
  - SIDEBAND addr=0x024 doorbell-only form → only APB, no FIFO
  - races to provoke misdecode:
      * type bits glitching during the cycle of l2a_accept
      * valid asserted before stable type bits
      * tearing pkt_type vs rest of word on the same FC bus
      * payload bits looking like a SIDEBAND header
      * back-to-back FIFO_DATA without inter-packet gap
      * a 0x5000-shaped payload that matches the silicon symptom
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from cocotb.queue import Queue

# Re-use the helpers/monitors from the main test file
from test_tidelink_fc_adapter import (
    CLK_PERIOD_NS,
    PKT_FIFO_DATA, PKT_SIDEBAND, PKT_EXT,
    HTRANS_IDLE, HTRANS_NONSEQ, HSIZE_WORD,
    FCMonitor, FCDriver, DirectWriteMonitor, APBMasterMonitor,
    setup, do_reset,
)


# =============================================================================
# Local helpers
# =============================================================================

def encode_fc_word(pkt_type, addr_offset, payload):
    """Build a 48-bit FC word.  [47:46]=type [45:32]=addr [31:0]=payload."""
    return ((pkt_type & 0x3) << 46) | \
           ((addr_offset & 0x3FFF) << 32) | \
           (payload & 0xFFFFFFFF)


async def drain_monitors(fifo_mon, cfg_mon, cycles=20):
    """Idle the bus and let any in-flight transactions land."""
    await ClockCycles(fifo_mon.dut.hclk, cycles)


def collect_writes(mon):
    """Drain everything queued on a monitor and return as a list."""
    out = []
    while not mon.writes.empty():
        out.append(mon.writes.get_nowait())
    return out


# =============================================================================
# Baseline routing tests
# =============================================================================

@cocotb.test()
async def test_pkttype_fifo_data_routes_to_fifo(dut):
    """type=00 (FIFO_DATA) must drive fc_rx_fifo_* — and ONLY that."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0100
    test_data = 0xCAFEBABE

    await fc_drv.send(PKT_FIFO_DATA, test_addr, test_data)
    await drain_monitors(fifo_mon, cfg_mon, 10)

    # FIFO port should have one write with the correct addr+data
    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    assert len(fifo_writes) == 1, \
        f"Expected 1 FIFO write, got {len(fifo_writes)}: {fifo_writes}"
    assert fifo_writes[0]["addr"] == test_addr, \
        f"FIFO addr mismatch: expected 0x{test_addr:04X}, got 0x{fifo_writes[0]['addr']:04X}"
    assert fifo_writes[0]["data"] == test_data, \
        f"FIFO data mismatch: expected 0x{test_data:08X}, got 0x{fifo_writes[0]['data']:08X}"

    # APB cfg port MUST stay quiet
    assert len(cfg_writes) == 0, \
        f"BUG: FIFO_DATA leaked to APB cfg port: {cfg_writes}"


@cocotb.test()
async def test_pkttype_sideband_routes_to_cfg(dut):
    """type=01 (SIDEBAND) must drive fc_rx_cfg_* — and ONLY that."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x024   # doorbell response acc — the silicon victim register
    test_data = 0x0000_0005

    await fc_drv.send(PKT_SIDEBAND, test_addr, test_data)
    await drain_monitors(fifo_mon, cfg_mon, 10)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    assert len(cfg_writes) == 1, \
        f"Expected 1 APB cfg write, got {len(cfg_writes)}: {cfg_writes}"
    assert cfg_writes[0]["addr"] == test_addr, \
        f"APB addr mismatch: expected 0x{test_addr:03X}, got 0x{cfg_writes[0]['addr']:03X}"
    assert cfg_writes[0]["data"] == test_data, \
        f"APB data mismatch: expected 0x{test_data:08X}, got 0x{cfg_writes[0]['data']:08X}"

    assert len(fifo_writes) == 0, \
        f"BUG: SIDEBAND leaked to FIFO direct-write port: {fifo_writes}"


# =============================================================================
# Sequencing / aliasing
# =============================================================================

@cocotb.test()
async def test_pkttype_back_to_back_no_aliasing(dut):
    """SIDEBAND immediately followed by FIFO_DATA — second packet must route
    to FIFO, not be misrouted because rx_fc_word_r still holds the prior type
    when l2a_valid asserts on the next edge."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # SIDEBAND first
    sb_addr = 0x024
    sb_data = 0x0000_AAAA
    await fc_drv.send(PKT_SIDEBAND, sb_addr, sb_data)

    # NO inter-packet idle: drive the next word the cycle after accept
    fifo_addr = 0x0040
    fifo_data = 0xFADE_F00D
    await fc_drv.send(PKT_FIFO_DATA, fifo_addr, fifo_data)
    await drain_monitors(fifo_mon, cfg_mon, 20)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    # Expect exactly one of each, no cross-routing
    assert len(cfg_writes) == 1, \
        f"Expected 1 cfg write (SIDEBAND), got {len(cfg_writes)}: {cfg_writes}"
    assert cfg_writes[0]["addr"] == sb_addr and cfg_writes[0]["data"] == sb_data, \
        f"SIDEBAND payload mismatch: {cfg_writes}"

    assert len(fifo_writes) == 1, \
        f"BUG: FIFO_DATA second-in-sequence got LOST or misrouted. cfg={cfg_writes}"
    assert fifo_writes[0]["addr"] == fifo_addr, \
        f"FIFO addr mismatch: expected 0x{fifo_addr:04X}, got 0x{fifo_writes[0]['addr']:04X}"
    assert fifo_writes[0]["data"] == fifo_data, \
        f"FIFO data mismatch: expected 0x{fifo_data:08X}, got 0x{fifo_writes[0]['data']:08X}"


@cocotb.test()
async def test_pkttype_doorbell_only(dut):
    """Doorbell sideband form (addr=0x024 + count) must hit ONLY the APB
    doorbell register. FIFO direct-write port must stay silent — that's the
    silicon symptom inverted (silicon sees FIFO drops AND doorbell bumps)."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Simulate the slave receiving credit/doorbell sideband
    await fc_drv.send(PKT_SIDEBAND, 0x024, 0x0000_0001)
    await drain_monitors(fifo_mon, cfg_mon, 10)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    assert len(cfg_writes) == 1, f"Doorbell didn't reach APB: {cfg_writes}"
    assert cfg_writes[0]["addr"] == 0x024, \
        f"Doorbell at wrong APB offset: 0x{cfg_writes[0]['addr']:03X}"
    assert len(fifo_writes) == 0, \
        f"BUG: Doorbell leaked to FIFO port: {fifo_writes}"


# =============================================================================
# Misdecode reproduction attempts
# =============================================================================

@cocotb.test()
async def test_pkttype_misdecode_pre_accept_glitch(dut):
    """Drive type=01 (SIDEBAND) for one cycle, then change to type=00
    (FIFO_DATA) BEFORE l2a_accept fires. After the FSM latches, rx_pkt_type
    should match the value at the clock edge of accept — not the pre-edge one.

    If the FSM mis-samples (e.g. uses non-latched pkt_type derived
    combinatorially from tl_fc_l2a_data), we'd see a misroute.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Stall accept by holding fifo_ready low? No — accept depends on
    # rx_state_r==IDLE and l2a_valid, not the destination port ready.
    # So drive a glitch on tl_fc_l2a_data while valid is high.
    target_addr = 0x0200
    target_data = 0xC0DE_C0DE

    # Drive SIDEBAND first (will be the "bad" decode if FSM is buggy)
    bad_word  = encode_fc_word(PKT_SIDEBAND, 0x024, target_data)
    good_word = encode_fc_word(PKT_FIFO_DATA, target_addr, target_data)

    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = bad_word
    await RisingEdge(dut.hclk)
    # Before next edge (i.e. before accept can capture), flip type bits.
    # Accept will only fire while valid is high; if the FSM is IDLE and
    # valid was already 1 last edge, accept asserted last edge — too late.
    # So we don't expect this to mis-decode; this test asserts that.
    dut.tl_fc_l2a_data.value = good_word
    # Wait until accept actually fires
    for _ in range(10):
        if int(dut.tl_fc_l2a_accept.value) == 1:
            break
        await RisingEdge(dut.hclk)
    await RisingEdge(dut.hclk)
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value  = 0
    await drain_monitors(fifo_mon, cfg_mon, 20)

    # Whichever word was on the bus at the accept rising edge is what got
    # latched. Verify the latched type produced consistent routing.
    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    # Must be exactly ONE write — either FIFO or APB, never both.
    total = len(fifo_writes) + len(cfg_writes)
    assert total == 1, \
        f"BUG (split routing): fifo={fifo_writes} cfg={cfg_writes}"

    # The routing must match the latched word — verify by payload.
    if fifo_writes:
        # Decoded as FIFO_DATA
        assert fifo_writes[0]["data"] == target_data
        # If decoded as FIFO, addr must match the FIFO_DATA word
        assert fifo_writes[0]["addr"] == target_addr, \
            f"FIFO decoded but addr=0x{fifo_writes[0]['addr']:04X} " \
            f"(expected 0x{target_addr:04X} from FIFO_DATA word)"
    else:
        # Decoded as SIDEBAND
        assert cfg_writes[0]["data"] == target_data
        assert cfg_writes[0]["addr"] == 0x024, \
            f"SIDEBAND decoded but addr=0x{cfg_writes[0]['addr']:03X} " \
            f"(expected 0x024 from SIDEBAND word)"


@cocotb.test()
async def test_pkttype_payload_looks_like_sideband_header(dut):
    """Send a FIFO_DATA word whose payload (low 32b), if shifted into
    [47:46], would decode as SIDEBAND. The FSM must use the actual word's
    [47:46], not bit-twiddle on the payload. This protects against barrel
    shifter / wire ordering bugs upstream of rx_pkt_type."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # If a buggy decoder used payload[31:30] as the type, this would
    # decode as SIDEBAND (0b01). The correct decode is FIFO_DATA (0b00).
    payload_with_sb_top = 0x4000_0000   # bit[30] set
    test_addr = 0x0080
    await fc_drv.send(PKT_FIFO_DATA, test_addr, payload_with_sb_top)
    await drain_monitors(fifo_mon, cfg_mon, 10)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)
    assert len(fifo_writes) == 1, \
        f"BUG: payload-shaped-as-SIDEBAND misrouted: cfg={cfg_writes}"
    assert fifo_writes[0]["data"] == payload_with_sb_top
    assert len(cfg_writes) == 0


@cocotb.test()
async def test_pkttype_back_to_back_fifo_burst(dut):
    """Burst of FIFO_DATA packets back-to-back. None should leak to APB.

    Catches a stuck-rx_fc_word_r issue or partial latch where consecutive
    FIFO words inherit stale type bits."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    burst = [
        (0x0000, 0x1111_1111),
        (0x0004, 0x2222_2222),
        (0x0008, 0x3333_3333),
        (0x000C, 0x4444_4444),
        (0x0010, 0x5555_5555),
        (0x0014, 0x6666_6666),
        (0x0018, 0x7777_7777),
        (0x001C, 0x8888_8888),
    ]

    for addr, data in burst:
        await fc_drv.send(PKT_FIFO_DATA, addr, data)
        # Gap of 2 cycles to let the direct-write port latch the prev word
        await ClockCycles(dut.hclk, 2)
    await drain_monitors(fifo_mon, cfg_mon, 20)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    assert len(cfg_writes) == 0, \
        f"BUG: FIFO_DATA burst leaked {len(cfg_writes)} writes to APB cfg: {cfg_writes}"
    assert len(fifo_writes) == len(burst), \
        f"Expected {len(burst)} FIFO writes, got {len(fifo_writes)}"
    for i, (addr, data) in enumerate(burst):
        assert fifo_writes[i]["addr"] == addr, \
            f"Burst[{i}] addr mismatch: expected 0x{addr:04X}, got 0x{fifo_writes[i]['addr']:04X}"
        assert fifo_writes[i]["data"] == data, \
            f"Burst[{i}] data mismatch: expected 0x{data:08X}, got 0x{fifo_writes[i]['data']:08X}"


@cocotb.test()
async def test_pkttype_misdecode_repro_5000_doorbell(dut):
    """Direct attempt to reproduce the silicon symptom.

    Silicon: each master AHB write produces a slave doorbell bump of 0x5000.
    Hypothesis: master FIFO_DATA word lands on slave's APB cfg path with
    addr=0x024 and data=0x5000.

    Construct an FC word with type=00, addr=0x024 (matching doorbell
    address in the address field), payload=0x5000. If the slave's RX FSM
    correctly samples [47:46]=00, this MUST hit fc_rx_fifo_*, NOT
    fc_rx_cfg_paddr=0x024.

    If this test fails — i.e. the data lands at APB 0x024 with value 0x5000
    — that is the smoking gun for the A-1 hypothesis."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # The interesting payload from the silicon bug
    SYMPTOM_PAYLOAD = 0x0000_5000
    # Make the FIFO addr collide with the APB doorbell address — if the FSM
    # decoded SIDEBAND incorrectly, this would land at APB 0x024.
    AMBIGUOUS_ADDR  = 0x024

    raw = encode_fc_word(PKT_FIFO_DATA, AMBIGUOUS_ADDR, SYMPTOM_PAYLOAD)
    dut._log.info(f"Injecting raw FC word = 0x{raw:012X} "
                  f"(type={(raw>>46)&3:02b}, addr=0x{(raw>>32)&0x3FFF:04X}, "
                  f"payload=0x{raw & 0xFFFFFFFF:08X})")
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw
    for _ in range(10):
        await RisingEdge(dut.hclk)
        if int(dut.tl_fc_l2a_accept.value) == 1:
            break
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value  = 0
    await drain_monitors(fifo_mon, cfg_mon, 20)

    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)

    # The smoking-gun condition: cfg port saw 0x5000 at 0x024.
    smoking_gun = any(w["addr"] == 0x024 and w["data"] == 0x5000
                      for w in cfg_writes)

    dut._log.info(
        f"RESULT: fifo_writes={fifo_writes}  cfg_writes={cfg_writes}  "
        f"smoking_gun={smoking_gun}")

    assert not smoking_gun, (
        "SMOKING GUN reproduced in unit sim: FIFO_DATA word "
        f"(type=00, addr=0x024, data=0x5000) landed on APB cfg port at "
        f"0x024 with value 0x5000 — slave FC adapter mis-decoded "
        f"rx_pkt_type. cfg_writes={cfg_writes}"
    )
    assert len(fifo_writes) == 1, \
        f"FIFO_DATA disappeared entirely (no fifo, no cfg): " \
        f"fifo={fifo_writes} cfg={cfg_writes}"
    assert fifo_writes[0]["data"] == SYMPTOM_PAYLOAD
    assert fifo_writes[0]["addr"] == AMBIGUOUS_ADDR


@cocotb.test()
async def test_pkttype_observe_internal_decode(dut):
    """Drive a FIFO_DATA word and read the internal rx_pkt_type wire while
    the FSM is in RX_ADDR_PHASE. Confirms the latched value matches what
    was driven. This gives us a direct check of the latch path
    (rx_fc_word_r[47:46]) independent of the routing observation, so we
    can attribute any future divergence to either the latch or the route."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Stall the FIFO ready so the FSM lingers in ADDR_PHASE for one cycle
    dut.fc_rx_fifo_ready.value = 0

    raw = encode_fc_word(PKT_FIFO_DATA, 0x0040, 0xDEAD_BEEF)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw
    for _ in range(10):
        await RisingEdge(dut.hclk)
        if int(dut.tl_fc_l2a_accept.value) == 1:
            break
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value  = 0

    # Next cycle, FSM enters RX_ADDR_PHASE; rx_pkt_type should be 0b00.
    await RisingEdge(dut.hclk)
    try:
        latched_type = int(dut.u_dut.rx_pkt_type.value)
        latched_word = int(dut.u_dut.rx_fc_word_r.value)
    except Exception as e:
        latched_type = None
        latched_word = None
        dut._log.warning(f"Could not probe u_dut.rx_pkt_type: {e}")

    if latched_type is not None:
        assert latched_type == PKT_FIFO_DATA, (
            f"BUG: rx_pkt_type latched as 0b{latched_type:02b}, "
            f"expected 0b00. rx_fc_word_r=0x{latched_word:012X}")
        # The full word should also match what we drove
        assert latched_word == raw, (
            f"BUG: rx_fc_word_r=0x{latched_word:012X}, expected 0x{raw:012X}")
    else:
        dut._log.info("Skipped internal probe (no hierarchy access)")

    # Release the stall, let the FIFO write complete and verify
    dut.fc_rx_fifo_ready.value = 1
    await drain_monitors(fifo_mon, cfg_mon, 20)
    fifo_writes = collect_writes(fifo_mon)
    cfg_writes  = collect_writes(cfg_mon)
    assert len(cfg_writes) == 0, \
        f"BUG: latched FIFO_DATA leaked to cfg port: {cfg_writes}"
    assert len(fifo_writes) == 1 and fifo_writes[0]["data"] == 0xDEAD_BEEF


@cocotb.test()
async def test_pkttype_all_four_type_codes(dut):
    """Every possible type-code value [00,01,10,11] must route to a
    deterministic destination. Code 11 (RESERVED) currently routes as
    SIDEBAND (the else-leg of rx_is_fifo / rx_is_ext); this test documents
    that behaviour and catches any silent change."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Hold tc_axis_rx_tready high so PKT_EXT can drain to the AXI port
    dut.tc_axis_rx_tready.value = 1

    cases = [
        (0b00, 0x0100, 0x1111_1111, "FIFO_DATA"),
        (0b01, 0x024,  0x2222_2222, "SIDEBAND"),
        (0b10, 0x0007, 0x3333_3333, "PKT_EXT"),
        (0b11, 0x028,  0x4444_4444, "RESERVED"),
    ]

    routes = {}
    for ptype, addr, data, name in cases:
        await fc_drv.send(ptype, addr, data)
        await ClockCycles(dut.hclk, 8)
        fifo_writes = collect_writes(fifo_mon)
        cfg_writes  = collect_writes(cfg_mon)
        routes[name] = {
            "type": ptype,
            "fifo": fifo_writes,
            "cfg":  cfg_writes,
        }
        dut._log.info(
            f"type=0b{ptype:02b} ({name}) → fifo={fifo_writes} cfg={cfg_writes}")

    # FIFO_DATA → fifo only
    assert len(routes["FIFO_DATA"]["fifo"]) == 1 and \
           len(routes["FIFO_DATA"]["cfg"])  == 0, routes["FIFO_DATA"]
    # SIDEBAND → cfg only
    assert len(routes["SIDEBAND"]["cfg"])  == 1 and \
           len(routes["SIDEBAND"]["fifo"]) == 0, routes["SIDEBAND"]
    # PKT_EXT → neither port (routed to tc_axis_rx) — documents the carve-out
    assert len(routes["PKT_EXT"]["cfg"])  == 0 and \
           len(routes["PKT_EXT"]["fifo"]) == 0, routes["PKT_EXT"]
    # RESERVED → currently lands on cfg port (rx_is_fifo=0, rx_is_ext=0)
    # If this changes, the test will flag it.
    assert len(routes["RESERVED"]["cfg"])  == 1 and \
           len(routes["RESERVED"]["fifo"]) == 0, routes["RESERVED"]

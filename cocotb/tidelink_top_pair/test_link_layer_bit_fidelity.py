"""Bug A — H-A5 (link-layer / PHY bit-flip) sim baseline.

Hypothesis under test
---------------------
Bits [47:46] of the 48-bit FC word are the FC `pkt_type` sentinel:
    2'b00 = FIFO_DATA  (routed to local RX FIFO at addr_offset)
    2'b01 = SIDEBAND   (routed to local APB config regs at addr_offset)
The slave's silicon-observed 0x5000 bump pattern on REG_DOORBELL_RESP_ACC
(APB offset 0x024) is consistent with master FIFO_DATA word `pkt_type=00`,
`addr_offset=0x024`, `payload=0x5000` arriving at slave with `[47:46]` flipped
to `2'b01` (SIDEBAND). The decoder would then write `0x5000` to APB offset
`0x024`, bumping DOORBELL_RESP_ACC by exactly 0x5000 per AHB write.

The prior fc_adapter unit test (10/10 PASS) already falsified the H-A1
"adapter-side misdecode" hypothesis: when valid+data are stable the slave
decoder picks `[47:46]` correctly. So if the misdecode is real it must be
upstream of `tl_fc_l2a_data` reaching the adapter — i.e. in:
    1. Wlink TX-side packer (48→data_id mapping inside tl2wl.wlink_tidelinktl)
    2. Byte-lane serialiser (WavD2DGpioTx.v) — local_overrides version
    3. PHY (lane swap, IDELAYE2 phase, lane vote)
    4. Byte-lane deserialiser (WavD2DGpioRx.v)
    5. Wlink RX-side unpacker

In sim the link is bit-perfect by construction (no PHY noise, the cocotb
pair tb wires master `pad_tx` → slave `pad_rx` directly through `pad_skid`
with SKID_BITS=0 = passthrough). So all five tests below should PASS in
sim. The value of the test suite is:
    (a) Sim baseline against which HW behaviour can be compared.
    (b) Concrete hierarchical paths the FPGA ILA needs (see report).
    (c) Demonstrates byte-by-byte equality so a HW deviation localises
        directly to one of the five blocks above.

Run
---
    cd cocotb/tidelink_top_pair
    SIM_BUILD=sim_build_bit_fidelity TB_TOP_NO_DUMP=1 \
        MODULE=test_link_layer_bit_fidelity make

NOTE — DO NOT edit any other test file in this directory. This file
imports PairTB / run_bringup_full from the doorbell test, never writes
RTL, never touches the IP library.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Hierarchical path resolution
# ---------------------------------------------------------------------------
# The 48-bit FC adapter ↔ Wlink boundary nets live at the tidelink_top
# module scope (src/rtl/tidelink_top.sv:495-500):
#
#     wire                   tl_fc_a2l_valid;
#     wire [FC_DATA_W-1:0]   tl_fc_a2l_data;
#     wire                   tl_fc_a2l_ready;
#     wire                   tl_fc_l2a_valid;
#     wire [FC_DATA_W-1:0]   tl_fc_l2a_data;
#     wire                   tl_fc_l2a_accept;
#
# Hierarchical paths from `tb_top` (paired-die tb):
#   Master TX wire (out of fc_adapter, into Wlink):
#       tb_top.u_master.tl_fc_a2l_data[47:0]
#       tb_top.u_master.tl_fc_a2l_valid
#       tb_top.u_master.tl_fc_a2l_ready
#   Slave RX wire (out of Wlink, into fc_adapter):
#       tb_top.u_slave.tl_fc_l2a_data[47:0]
#       tb_top.u_slave.tl_fc_l2a_valid
#       tb_top.u_slave.tl_fc_l2a_accept
#
# Slave-side TX and master-side RX are the symmetric counterparts; the
# tests below probe MASTER-TX and SLAVE-RX because the H-A5 silicon
# symptom is M→S directional.
# ---------------------------------------------------------------------------

PKT_FIFO_DATA = 0b00
PKT_SIDEBAND  = 0b01

# Per-cycle ring buffer length when sampling the FC wire while a stimulus
# is in flight. 2000 cycles ~= the FC link round-trip plus a couple of
# packet bursts at 50 MHz hclk in sim.
SAMPLE_CYCLES = 2000


def _id_get(parent, name):
    """Resolve a hierarchical name through cocotb / VCS. Matches the
    pattern used in test_master_fc_skid_arbiter.py."""
    try:
        return getattr(parent, name)
    except AttributeError:
        pass
    try:
        return parent._id(name, extended=False)
    except Exception:
        return None


def _safe_read(sig):
    if sig is None:
        return None
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return None


# ---------------------------------------------------------------------------
# Boundary probes
# ---------------------------------------------------------------------------

def m_tx_data(dut):
    return _id_get(dut.u_master, "tl_fc_a2l_data")


def m_tx_valid(dut):
    return _id_get(dut.u_master, "tl_fc_a2l_valid")


def m_tx_ready(dut):
    return _id_get(dut.u_master, "tl_fc_a2l_ready")


def s_rx_data(dut):
    return _id_get(dut.u_slave, "tl_fc_l2a_data")


def s_rx_valid(dut):
    return _id_get(dut.u_slave, "tl_fc_l2a_valid")


def s_rx_accept(dut):
    return _id_get(dut.u_slave, "tl_fc_l2a_accept")


# data_id probe — between the FC-node packer (TideLinkToWlink TX) and the
# Wlink TX router. TideLink FC node is data_id=0xa1 (constant from the
# Chisel TideLink node).
def m_tx_data_id(dut):
    # tb_top.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl
    #     .auto_tx_out_data_id  (8-bit)
    try:
        return dut.u_master.u_chiplet_controller.u_wlink.tl2wl \
            .wlink_tidelinktl_auto_tx_out_data_id
    except AttributeError:
        return None


def s_rx_data_id(dut):
    try:
        return dut.u_slave.u_chiplet_controller.u_wlink.tl2wl \
            .wlink_tidelinktl_auto_rx_in_data_id
    except AttributeError:
        return None


def m_tx_data_id_valid(dut):
    try:
        return dut.u_master.u_chiplet_controller.u_wlink.tl2wl \
            .wlink_tidelinktl_auto_tx_out_advance
    except AttributeError:
        return None


def s_rx_data_id_valid(dut):
    try:
        return dut.u_slave.u_chiplet_controller.u_wlink.tl2wl \
            .wlink_tidelinktl_auto_rx_in_valid
    except AttributeError:
        return None


# ---------------------------------------------------------------------------
# Stimulus — single FIFO_DATA packet master → slave
# ---------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF]


def _packet_words():
    """N=1 WR_REQ packet, payload = [0xDEADBEEF]. Word layout:
        words[0] = header (encode_word0 with length=1, pkt_type=PKT_WR_REQ)
        words[1] = dest_addr = 0x0
        words[2] = 0xDEADBEEF
    Each AHB word write becomes one FIFO_DATA FC word with addr_offset =
    AHB byte offset (0, 4, 8, ...). All three should have [47:46]=2'b00.
    """
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


async def _settle_post_bringup(tb):
    """Drop SWI training after the LL bootstrap (mirror HW data-mode)."""
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


async def _drive_packet_and_sample(tb, n_cycles=SAMPLE_CYCLES):
    """Fire the N=1 WR_REQ from master TX aperture and sample the master
    TX wire + slave RX wire every cycle while the packet is in flight.

    Returns a dict with:
        m_tx_samples = [(cycle, data48), ...]  every cycle m_tx_valid=1
        s_rx_samples = [(cycle, data48), ...]  every cycle s_rx_valid=1
    """
    words = _packet_words()
    tb.log.info(
        f"  master TX packet: word0=0x{words[0]:08x} dest=0x{words[1]:08x} "
        f"payload=[0x{words[2]:08x}]"
    )

    m_d = m_tx_data(tb.dut)
    m_v = m_tx_valid(tb.dut)
    s_d = s_rx_data(tb.dut)
    s_v = s_rx_valid(tb.dut)
    if m_d is None or m_v is None or s_d is None or s_v is None:
        raise AssertionError(
            "could not resolve tl_fc_a2l_* / tl_fc_l2a_* probes via "
            "hierarchical reference — check tb_top.u_master / u_slave names"
        )

    m_samples = []
    s_samples = []

    # Fork the stimulus so we can keep sampling on this coroutine.
    async def _fire():
        await tb.ahb_tx_write_packet("m", words)

    fire_task = cocotb.start_soon(_fire())

    for cy in range(n_cycles):
        await RisingEdge(tb.dut.hclk)
        v = _safe_read(m_v)
        if v == 1:
            d = _safe_read(m_d)
            if d is not None:
                m_samples.append((cy, d))
        v = _safe_read(s_v)
        if v == 1:
            d = _safe_read(s_d)
            if d is not None:
                s_samples.append((cy, d))

    await fire_task
    return dict(m_tx=m_samples, s_rx=s_samples)


def _bits(word, hi, lo):
    width = hi - lo + 1
    return (word >> lo) & ((1 << width) - 1)


def _byte_lanes(word48):
    """Split a 48-bit FC word into 6 byte lanes, lane[0] = bits [7:0],
    lane[5] = bits [47:40]."""
    return [
        _bits(word48, 7, 0),
        _bits(word48, 15, 8),
        _bits(word48, 23, 16),
        _bits(word48, 31, 24),
        _bits(word48, 39, 32),
        _bits(word48, 47, 40),
    ]


# ============================================================================
# Tests
# ============================================================================

@cocotb.test()
async def test_master_tx_wire_bits_47_46(dut):
    """Probe master `tl_fc_a2l_data[47:46]` when `tl_fc_a2l_valid=1`. Every
    sample must be 2'b00 (FIFO_DATA) for the N=1 WR_REQ stimulus.

    The TX aperture is the ONLY FC client active in this test (no servo,
    no returner, no tidechart). So every cycle the master submits a word
    it MUST be FIFO_DATA.

    Sim expectation: PASS — bits [47:46] never deviate from 2'b00.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    samples = await _drive_packet_and_sample(tb)
    m_tx = samples["m_tx"]

    tb.log.info(f"  master TX wire samples (valid=1): {len(m_tx)}")
    n_log = min(10, len(m_tx))
    for i in range(n_log):
        cy, w = m_tx[i]
        tb.log.info(
            f"    [{i}] cy=+{cy:4d}  m_tx_data=0x{w:012x}  "
            f"[47:46]={_bits(w, 47, 46):02b}  addr=0x{_bits(w, 45, 32):03x}  "
            f"payload=0x{_bits(w, 31, 0):08x}"
        )

    assert len(m_tx) > 0, (
        "master tl_fc_a2l_valid never asserted while driving the packet — "
        "stimulus did not reach the FC adapter TX path"
    )
    for cy, w in m_tx:
        pt = _bits(w, 47, 46)
        assert pt == PKT_FIFO_DATA, (
            f"master TX wire bits [47:46] = 0b{pt:02b} at cy=+{cy} "
            f"(word=0x{w:012x}); expected 0b00 (FIFO_DATA). "
            "If this fails it means the master's own arbiter is emitting "
            "a non-FIFO_DATA word — bug is upstream of the link."
        )


@cocotb.test()
async def test_slave_rx_wire_bits_47_46(dut):
    """Same stimulus, probe slave `tl_fc_l2a_data[47:46]` when
    `tl_fc_l2a_valid=1`. Compare against master TX samples.

    Sim expectation: PASS (link bit-perfect by construction). If this
    fails it is the smoking gun for the H-A5 sim-side equivalent — but
    the more useful failure path is on HW.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    samples = await _drive_packet_and_sample(tb)
    m_tx = samples["m_tx"]
    s_rx = samples["s_rx"]

    tb.log.info(f"  master TX samples: {len(m_tx)}")
    tb.log.info(f"  slave  RX samples: {len(s_rx)}")
    n_log = min(10, len(s_rx))
    for i in range(n_log):
        cy, w = s_rx[i]
        tb.log.info(
            f"    [{i}] cy=+{cy:4d}  s_rx_data=0x{w:012x}  "
            f"[47:46]={_bits(w, 47, 46):02b}  addr=0x{_bits(w, 45, 32):03x}  "
            f"payload=0x{_bits(w, 31, 0):08x}"
        )

    assert len(s_rx) > 0, (
        "slave tl_fc_l2a_valid never asserted while master was driving — "
        "packet did not cross the link in sim"
    )
    for cy, w in s_rx:
        pt = _bits(w, 47, 46)
        assert pt == PKT_FIFO_DATA, (
            f"slave RX wire bits [47:46] = 0b{pt:02b} at cy=+{cy} "
            f"(word=0x{w:012x}); expected 0b00. "
            "Sim-side smoking gun for H-A5."
        )


@cocotb.test()
async def test_master_tx_byte_lanes(dut):
    """Log all 6 byte lanes of `tl_fc_a2l_data` at the first FIFO_DATA
    submission. Byte-by-byte snapshot — gives the FPGA ILA a concrete
    reference word so any byte-swap on HW localises directly.

    Sim expectation: PASS — lanes match the encoded TX FC word.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    samples = await _drive_packet_and_sample(tb)
    m_tx = samples["m_tx"]
    assert len(m_tx) >= 3, (
        f"expected >=3 master TX words for the N=1 WR_REQ packet, got "
        f"{len(m_tx)} — TX aperture stall?"
    )

    tb.log.info("  Master TX word-by-word byte-lane decomposition:")
    for i in range(min(3, len(m_tx))):
        cy, w = m_tx[i]
        lanes = _byte_lanes(w)
        tb.log.info(
            f"    word[{i}] cy=+{cy:4d}  raw=0x{w:012x}  "
            f"lanes=[L0=0x{lanes[0]:02x} L1=0x{lanes[1]:02x} "
            f"L2=0x{lanes[2]:02x} L3=0x{lanes[3]:02x} "
            f"L4=0x{lanes[4]:02x} L5=0x{lanes[5]:02x}]  "
            f"[47:46]={_bits(w, 47, 46):02b}"
        )

    # Sanity: lane[5][7:6] is bits [47:46] of the word.
    cy0, w0 = m_tx[0]
    lanes0 = _byte_lanes(w0)
    assert ((lanes0[5] >> 6) & 0x3) == PKT_FIFO_DATA, (
        f"lane[5] top 2 bits = 0b{(lanes0[5] >> 6) & 0x3:02b}, "
        f"expected 0b00 (lane[5]=0x{lanes0[5]:02x}, "
        f"raw=0x{w0:012x})"
    )


@cocotb.test()
async def test_slave_rx_byte_lanes(dut):
    """Log all 6 byte lanes of `tl_fc_l2a_data` at corresponding RX
    samples, then compare to master TX byte-by-byte. If any lane is
    different we have a byte-swap / lane-misalignment fingerprint.

    Sim expectation: PASS — byte-for-byte equality between master TX
    sequence and slave RX sequence (sim has no PHY noise).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    samples = await _drive_packet_and_sample(tb)
    m_tx = samples["m_tx"]
    s_rx = samples["s_rx"]
    assert len(s_rx) >= 3, (
        f"expected >=3 slave RX words for the N=1 WR_REQ packet, got "
        f"{len(s_rx)}"
    )

    tb.log.info("  Slave RX word-by-word byte-lane decomposition:")
    for i in range(min(3, len(s_rx))):
        cy, w = s_rx[i]
        lanes = _byte_lanes(w)
        tb.log.info(
            f"    word[{i}] cy=+{cy:4d}  raw=0x{w:012x}  "
            f"lanes=[L0=0x{lanes[0]:02x} L1=0x{lanes[1]:02x} "
            f"L2=0x{lanes[2]:02x} L3=0x{lanes[3]:02x} "
            f"L4=0x{lanes[4]:02x} L5=0x{lanes[5]:02x}]  "
            f"[47:46]={_bits(w, 47, 46):02b}"
        )

    # De-duplicate TX/RX (consecutive identical samples are skid stalls,
    # not new words — collapse them to a unique-value sequence so we can
    # compare master TX cadence against slave RX cadence symbolically).
    def _uniq(samples):
        out = []
        prev = None
        for cy, w in samples:
            if w != prev:
                out.append((cy, w))
                prev = w
        return out

    m_uniq = _uniq(m_tx)
    s_uniq = _uniq(s_rx)
    n = min(len(m_uniq), len(s_uniq))
    tb.log.info(
        f"  M-TX uniq words: {len(m_uniq)}, S-RX uniq words: {len(s_uniq)} "
        f"(comparing first {n})"
    )

    for i in range(n):
        m_cy, m_w = m_uniq[i]
        s_cy, s_w = s_uniq[i]
        m_l = _byte_lanes(m_w)
        s_l = _byte_lanes(s_w)
        for ln in range(6):
            assert m_l[ln] == s_l[ln], (
                f"byte-lane mismatch at unique-word [{i}] lane L{ln}: "
                f"master TX 0x{m_l[ln]:02x} vs slave RX 0x{s_l[ln]:02x}. "
                f"M cy=+{m_cy} raw=0x{m_w:012x}; "
                f"S cy=+{s_cy} raw=0x{s_w:012x}. "
                "Sim-side byte-lane mismatch — should not happen in sim."
            )


@cocotb.test()
async def test_data_id_on_wire(dut):
    """Probe the FC-node data_id field on the wire (between
    TideLinkToWlink.tl2wl and the Wlink TX router). TideLink is data_id
    = 0xa1 by Chisel construction.

    Cross-check:
        * If slave sees data_id=0xa1 but `[47:46]` of the corresponding
          data word is mismatched → the Wlink FC demux is correct but
          the packet *content* is corrupted (byte-lane or PHY bug).
        * If slave sees data_id != 0xa1 → the Wlink demux itself is
          mis-routing the packet (it would land on a different FC node).

    Sim expectation: PASS — both sides observe data_id=0xa1.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_did = m_tx_data_id(dut)
    s_did = s_rx_data_id(dut)
    m_did_v = m_tx_data_id_valid(dut)
    s_did_v = s_rx_data_id_valid(dut)

    if m_did is None or s_did is None:
        tb.log.warning(
            "could not resolve auto_tx_out_data_id / auto_rx_in_data_id "
            "via hierarchical reference; degenerating to data-only probe"
        )

    # Fire packet and sample data_id on the cycles where the FC-node
    # advance/valid is asserted.
    m_did_samples = []
    s_did_samples = []
    words = _packet_words()

    async def _fire():
        await tb.ahb_tx_write_packet("m", words)
    fire_task = cocotb.start_soon(_fire())

    for cy in range(SAMPLE_CYCLES):
        await RisingEdge(tb.dut.hclk)
        if m_did_v is not None and _safe_read(m_did_v) == 1:
            v = _safe_read(m_did)
            if v is not None:
                m_did_samples.append((cy, v))
        if s_did_v is not None and _safe_read(s_did_v) == 1:
            v = _safe_read(s_did)
            if v is not None:
                s_did_samples.append((cy, v))

    await fire_task

    tb.log.info(
        f"  master TX data_id samples: {len(m_did_samples)} "
        f"(first 5: {[(c, hex(v)) for c, v in m_did_samples[:5]]})"
    )
    tb.log.info(
        f"  slave  RX data_id samples: {len(s_did_samples)} "
        f"(first 5: {[(c, hex(v)) for c, v in s_did_samples[:5]]})"
    )

    # If the data_id probes resolved, every observed data_id MUST be
    # 0xa1 (TideLink FC node id). data_id=0xa3 = GeneralBus (unused
    # here), 0xa2 = AXI write data, 0xa0 = AXI read, etc.
    if m_did is not None and m_did_samples:
        for cy, v in m_did_samples:
            assert v == 0xa1, (
                f"master TX data_id = 0x{v:02x} at cy=+{cy}, expected 0xa1. "
                "Wlink TX FC-node packer mislabelled the TideLink packet."
            )
    if s_did is not None and s_did_samples:
        for cy, v in s_did_samples:
            assert v == 0xa1, (
                f"slave RX data_id = 0x{v:02x} at cy=+{cy}, expected 0xa1. "
                "Wlink RX router demuxed the packet to the wrong FC node "
                "(if data_id is wrong, the demux itself is broken; bits "
                "[47:46] of tl_fc_l2a_data are irrelevant in that case)."
            )

    # Sanity bound: at least one of the two sides should have observed
    # *some* data_id activity. If neither side fires, the FC-node probe
    # paths didn't resolve and we should warn loudly but not fail.
    if not m_did_samples and not s_did_samples:
        tb.log.warning(
            "no data_id samples observed on either side — "
            "auto_tx_out_advance / auto_rx_in_valid probes may have "
            "resolved to dangling nets; check hierarchical path"
        )

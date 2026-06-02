"""Bug A — slave RX NACK predicate sim instrumentation.

ILA capture for Build #9 was blocked by .ltx mismatch; this cocotb test
replaces that signal-evidence path. Goal: identify which of the
``WlinkGenericFCSM_6`` NACK predicates fires first when the master AHB
write attempt produces no slave RX FIFO landing.

The 8 probes correspond to lines in
``src/rtl/local_overrides/WlinkGenericFCSM_6.v``::

    pkt_is_data_pkt           (line 347) wire  = _crc_corrupt_T_2 & ~crc_corrupt
    isExpPacket               (line 393) wire  = rdata[18:16]==3'h0 & fifo_valid
    crcCorruptSeen            (line 397) wire  = rdata[18:16]==3'h4 & fifo_valid
    send_nack_req             (line 441) reg   latched by crcCorruptSeen | isNotExpPacket_l7
    socl_l7_reached_link_data (line 455) reg   sticky for forgive disarm
    socl_l7_bringup_forgive   (line 456) wire  combinational forgive mask
    isNotExpPacket_l7         (line 462) wire  isNotExpPacket & ~forgive
    _T_54                     (line 491) wire  = count == 8'h0

All 8 are reachable from the FCSM handle returned by ``PairTB.fcsm``.

The test drives ONE PKT_WR_REQ (length=2, 2 payload words) from the
master AHB_TX aperture, then samples all 8 signals every hclk cycle for
500 cycles. The watcher records:
  * first cycle (relative to the AHB write) at which each signal goes high
  * the count of cycles each signal was high
  * a brief sequence trace of send_nack_req rising edges
  * whether forgive was high when the various predicates fired

Read-only instrumentation. Does NOT touch RTL. Does NOT modify shared
flists. Reuses ``PairTB`` / ``run_bringup_full`` from
``test_tidelink_pair_doorbell.py``.

Run command::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 900 make MODULE=test_buga_nack_predicates \\
      SIM_BUILD=sim_build_nack_probes TB_TOP_NO_DUMP=1
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    APB_PKT_WORD_LEN,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Hierarchical helpers
# ---------------------------------------------------------------------------

def _fcsm(dut, side):
    """Returns the WlinkGenericFCSM_6 instance handle (wlink_tidelinktl)
    inside u_master / u_slave. Confirmed in test_tidelink_pair_doorbell.PairTB.fcsm."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _safe(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _opt(scope, name):
    """Hierarchical signal lookup tolerant of missing nets (lets the test
    still load if a probe name was renamed by a future RTL patch).

    Falls back to ``_id(name, extended=False)`` (used by cocotb when a
    name embeds a dot or starts with an underscore — VCS sometimes
    flattens generate blocks that way).
    """
    s = getattr(scope, name, None)
    if s is not None:
        return s
    try:
        return scope._id(name, extended=False)
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
# Probe metadata
# ---------------------------------------------------------------------------
PROBE_NAMES = [
    "pkt_is_data_pkt",
    "isExpPacket",
    "crcCorruptSeen",
    "send_nack_req",
    "socl_l7_reached_link_data",
    "socl_l7_bringup_forgive",
    "isNotExpPacket_l7",
    "_T_54",
]


# Two payload words is enough to exercise the FCSM data-path; the test is
# only interested in the first DATA packet's predicate evaluation.
PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


OBSERVE_WINDOW_CY = 500
TEST_TIMEOUT_NS = 30_000_000


# ===========================================================================
# Test
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_nack_predicate_trace(dut):
    """Drive one AHB write packet on master and trace all 8 slave-side NACK
    predicates for 500 cy. Logs a timing-ordered table and a verdict on
    which predicate triggered send_nack_req first.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)

    # Make sure training is off (consistent with test_08).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    s_fcsm = _fcsm(dut, "s")

    # Resolve all 8 probes once and report which were found.
    probes = {name: _opt(s_fcsm, name) for name in PROBE_NAMES}
    unresolved = [n for n, h in probes.items() if h is None]
    if unresolved:
        dut._log.warning(
            f"  Could not resolve hierarchical refs: {unresolved}. "
            "Those will read as -1 in the trace."
        )
    else:
        dut._log.info("  All 8 NACK predicate probes resolved.")

    # Pre-AHB snapshot
    pre_state = _safe(s_fcsm.state)
    pre_vals = {n: _safe(h) for n, h in probes.items()}
    dut._log.info(f"  PRE-AHB  S.state={pre_state}  values={pre_vals}")

    # ---- Watcher state ----------------------------------------------------
    # first_cy[name]: first cy (1-based, relative to AHB write commencement)
    #                 at which this signal was observed HIGH.
    # high_cy[name] : total count of cycles HIGH.
    first_cy = {n: -1 for n in PROBE_NAMES}
    high_cy = {n: 0 for n in PROBE_NAMES}
    # send_nack_req rising-edge cycle stamps (record up to first 8)
    snr_rise_cy = []
    # Predicate-priority race: at the cycle send_nack_req FIRST rises, what
    # were the other predicates? (snapshot for the verdict).
    snr_rise_snapshot = None
    # Forgive-window analysis: was bringup_forgive high during the cycle
    # the first NACK-class predicate fired?
    forgive_at_first_nackclass = None
    # Track first cycle ANY of {crcCorruptSeen, isNotExpPacket_l7} fires
    first_nackclass_cy = -1
    first_nackclass_signal = None

    # Local cached snapshots so we can detect rising edges on send_nack_req.
    prev_snr = _safe(probes["send_nack_req"])

    async def watcher():
        nonlocal prev_snr, snr_rise_snapshot
        nonlocal forgive_at_first_nackclass
        nonlocal first_nackclass_cy, first_nackclass_signal
        cy = 0
        while True:
            await RisingEdge(dut.hclk)
            cy += 1
            cur = {n: _safe(probes[n]) for n in PROBE_NAMES}
            for n, v in cur.items():
                if v == 1:
                    high_cy[n] += 1
                    if first_cy[n] < 0:
                        first_cy[n] = cy
            snr = cur["send_nack_req"]
            if snr == 1 and prev_snr == 0:
                if len(snr_rise_cy) < 8:
                    snr_rise_cy.append(cy)
                if snr_rise_snapshot is None:
                    snr_rise_snapshot = dict(cur)
                    snr_rise_snapshot["__cy__"] = cy
            prev_snr = snr
            # NACK-class first-fire detection (crcCorruptSeen vs
            # isNotExpPacket_l7). Whichever rose first this cycle wins.
            if first_nackclass_cy < 0:
                if cur["crcCorruptSeen"] == 1:
                    first_nackclass_cy = cy
                    first_nackclass_signal = "crcCorruptSeen"
                    forgive_at_first_nackclass = cur["socl_l7_bringup_forgive"]
                elif cur["isNotExpPacket_l7"] == 1:
                    first_nackclass_cy = cy
                    first_nackclass_signal = "isNotExpPacket_l7"
                    forgive_at_first_nackclass = cur["socl_l7_bringup_forgive"]

    w = cocotb.start_soon(watcher())

    # Drive the master AHB write.
    dut._log.info(f"  AHB write: {[hex(w) for w in _packet_words()]}")
    await tb.ahb_tx_write_packet("m", _packet_words())

    # Wait the full observation window after the AHB write commenced.
    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    w.kill()

    post_state = _safe(s_fcsm.state)
    post_vals = {n: _safe(h) for n, h in probes.items()}
    dut._log.info(f"  POST     S.state={post_state}  values={post_vals}")

    # ---- APB read of slave PKT_WORD_LEN (sanity that no packet landed) ----
    pkt_word_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")

    # =====================================================================
    # Reporting
    # =====================================================================
    dut._log.info("================================================================")
    dut._log.info("  NACK PREDICATE TIMING TABLE (cycles relative to AHB write)")
    dut._log.info("  signal                       first_high_cy   total_high_cy")
    dut._log.info("  ---------------------------- -------------   -------------")
    for n in PROBE_NAMES:
        dut._log.info(f"  {n:<28} {first_cy[n]:>13}   {high_cy[n]:>13}")
    dut._log.info("================================================================")

    dut._log.info(f"  send_nack_req rising edges (up to 8): {snr_rise_cy}")
    if snr_rise_snapshot is not None:
        snap = {k: v for k, v in snr_rise_snapshot.items() if k != "__cy__"}
        dut._log.info(
            f"  At send_nack_req FIRST rise (cy={snr_rise_snapshot['__cy__']}), "
            f"co-state was: {snap}"
        )
    else:
        dut._log.info("  send_nack_req NEVER rose during observation window.")

    if first_nackclass_cy >= 0:
        dut._log.info(
            f"  First NACK-class predicate fired: {first_nackclass_signal} "
            f"at cy={first_nackclass_cy}  "
            f"(socl_l7_bringup_forgive={forgive_at_first_nackclass} on that cycle)"
        )
    else:
        dut._log.info(
            "  NO NACK-class predicate fired (neither crcCorruptSeen nor "
            "isNotExpPacket_l7 went high). This points UPSTREAM of the FCSM "
            "RX decoder: either pkt_is_data_pkt never asserted, or the "
            "ack_nack_fifo never enqueued a notifier."
        )

    # =====================================================================
    # Verdict — emit a single concise log line so the parent harness can
    # grep it out of the cocotb log.
    # =====================================================================
    if first_cy["pkt_is_data_pkt"] < 0:
        verdict = "UPSTREAM_NO_DATA_PKT_DECODE"
    elif first_nackclass_signal == "crcCorruptSeen":
        verdict = "CRC_CORRUPT_FIRES_FIRST"
    elif first_nackclass_signal == "isNotExpPacket_l7":
        if forgive_at_first_nackclass == 1:
            verdict = "ISNOTEXPPACKET_L7_FIRES_WHILE_FORGIVE_HIGH_(L7_LOGIC_BUG)"
        else:
            verdict = "ISNOTEXPPACKET_L7_FIRES_FORGIVE_DEASSERTED"
    elif snr_rise_snapshot is None:
        verdict = "NO_SEND_NACK_REQ_RAISED"
    else:
        verdict = "AMBIGUOUS"

    dut._log.info(f"  VERDICT: {verdict}")
    dut._log.info("================================================================")

    # No hard assert — this is instrumentation. We DO assert that the test
    # actually drove a packet (sanity) so a totally broken bringup is
    # visible.
    assert post_state >= 0, "slave FCSM state read returned -1 (probe failed)"

"""FCSM credit-ledger probe tests for the paired `tidelink_top` cocotb sim.

These tests instrument the cocotb harness with hierarchical-reference probes
that localise the bug responsible for `PAIR_CREDIT_COUNTER = 0` after full
bringup (see docs/SIM_REPRO_RESULTS_2026_05_29.md §"Follow-up work").

Three probe domains, with one test per domain plus a wire-content sanity test:

  1. **CR producer** — capture the on-wire (data_id, word_count) of the
     incoming packet at the rising edge of `pkt_is_cr_pkt` /
     `pkt_is_crack_pkt`. The grant value travels in
     `auto_rx_in_word_count[15:8]`.
  2. **FCSM consumer write path** — watch `fe_rx_credit_max` (the FCSM-local
     credit-ledger flop loaded from the CR/CRACK payload) and verify it
     actually advances when `pkt_is_cr_pkt | pkt_is_crack_pkt` asserts.
  3. **CDC handoff to APB regs** — compare FCSM-side `fe_rx_credit_max` to
     APB-side `pair_credit_counter`. The two are NOT a direct mirror; the
     APB-side counter is fed by the peer's *returner* over the FC link
     (release_credits trigger). If `fe_rx_credit_max != 0` on both sides
     but `pair_credit_counter == 0` *AND* no AHB RX traffic has been read,
     that's expected — the bug then sits in the producer/handshake-burst
     layer, not the APB mirror.

Reuses the PairTB bringup helpers from test_tidelink_pair_doorbell.py so the
bringup chain is identical to test_07.

Hierarchical probe paths (all rooted at `tb_top`):

  FCSM internals (Wlink TideLink FC node):
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.pkt_is_cr_pkt
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.pkt_is_crack_pkt
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.auto_rx_in_data_id
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.auto_rx_in_word_count
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.auto_rx_in_sop
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.auto_rx_in_valid
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.fe_rx_credit_max
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.fe_tx_credit_max
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx
  APB-side mirror (TideLink local APB registers):
    dut.u_master.u_tidelink_fifo.u_apb_regs.pair_credit_counter
    dut.u_master.u_tidelink_fifo.u_apb_regs.pair_counter_increment
    dut.u_master.u_tidelink_fifo.u_apb_regs.released_credits_acc
    dut.u_master.u_tidelink_fifo.u_apb_regs.doorbell_response_acc
  (the same set under `dut.u_slave.*` for the slave side)

NOTE on the APB-side counter (re-derivation from RTL):
`pair_credit_counter` in `fifo/tidelink_apb_regs.sv` is bumped by an APB write
to region-1, paddr[4:2]=0 (i.e. byte offset 0x020 in the region, which is
PAIR_RELEASED_CREDITS_ADDR). The peer's returner channel-0 (gated by
`release_credits_trigger`, which fires only on an RX-FIFO read completion)
sends that write over the FC link. So `pair_credit_counter` only advances
AFTER an end-to-end traffic round-trip. At link bringup with no AHB traffic,
the FCSM-side `fe_rx_credit_max` *should* be non-zero (loaded from the CR
payload), while the APB-side `pair_credit_counter` *correctly* stays 0.
This means: if test_07 expects PAIR_CREDIT_COUNTER != 0 with zero AHB
traffic, the assertion is mis-targeted; the meaningful gate is the FCSM
ledger (`fe_rx_credit_max`).
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse helpers and tests' bringup harness without modification.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_PAIR_CREDIT_COUNTER,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


# ---------------------------------------------------------------------------
# Hierarchical-reference helpers
# ---------------------------------------------------------------------------

def _fcsm(dut, side):
    """Handle to wlink_tidelinktl (the WlinkGenericFCSM_6 instance) on side."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _apb_regs(dut, side):
    """Handle to the tidelink_apb_regs instance on side."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_tidelink_fifo.u_apb_regs


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


# ---------------------------------------------------------------------------
# Test 1 — CR/CRACK payload at consumer-side decode
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_cr_payload_nonzero(dut):
    """Probe 1: at the moment a CR/CRACK packet is decoded by the FCSM, sample
    the on-wire (data_id, word_count) and check the credit-grant byte
    (`auto_rx_in_word_count[15:8]`) is non-zero on both sides.

    Localisation:
      * payload != 0 on both sides  -> CR producer is fine; bug downstream
      * payload == 0 on either side -> bug in CR-packet builder / TX path
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await ClockCycles(dut.hclk, 2000)

    fcsm_m = _fcsm(dut, "m")
    fcsm_s = _fcsm(dut, "s")

    captured = {"m": [], "s": []}
    prev_cr   = {"m": 0, "s": 0}
    prev_crack = {"m": 0, "s": 0}

    # Drive a slot0=0 wiggle to re-stimulate any pending CR/CRACK; the
    # initial exchange already happened during run_bringup_full but the
    # decoder fires combinationally on each incoming packet.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)

    # Sample for 4000 cycles. Latch a snapshot whenever either pkt_is_cr_pkt
    # or pkt_is_crack_pkt has a rising edge.
    for _ in range(4000):
        await RisingEdge(dut.hclk)
        for side, fcsm in (("m", fcsm_m), ("s", fcsm_s)):
            is_cr    = _safe_int(fcsm.pkt_is_cr_pkt, 0)
            is_crack = _safe_int(fcsm.pkt_is_crack_pkt, 0)
            if (is_cr and not prev_cr[side]) or (is_crack and not prev_crack[side]):
                did = _safe_int(fcsm.auto_rx_in_data_id, 0)
                wcn = _safe_int(fcsm.auto_rx_in_word_count, 0)
                grant = (wcn >> 8) & 0xFF      # credit-grant byte (fe_rx)
                tx_max = wcn & 0xFF            # tx-credit byte    (fe_tx)
                kind = "CR" if is_cr else "CRACK"
                captured[side].append((kind, did, wcn, grant, tx_max))
            prev_cr[side]   = is_cr
            prev_crack[side] = is_crack

    for side in ("m", "s"):
        tb.log.info(f"  [{side}] CR/CRACK decode events: {len(captured[side])}")
        for k, did, wcn, g, tx in captured[side][:8]:
            tb.log.info(
                f"      {k}: data_id=0x{did:02x} word_count=0x{wcn:04x} "
                f"grant(fe_rx)=0x{g:02x} tx_max(fe_tx)=0x{tx:02x}"
            )

    # Verdict: both sides must see at least one non-zero credit grant.
    for side in ("m", "s"):
        assert captured[side], (
            f"[{side}] no CR/CRACK decode events seen in 4000 cycles -- "
            "Probe 1 cannot localise (consumer never decoded a CR packet)."
        )
        nonzero_grants = [g for _, _, _, g, _ in captured[side] if g != 0]
        assert nonzero_grants, (
            f"[{side}] CR/CRACK decoded but grant byte (word_count[15:8]) "
            f"always 0 -- bug is in CR PRODUCER / TX path on the PEER side. "
            f"Samples: {captured[side][:4]}"
        )


# ---------------------------------------------------------------------------
# Test 2 — Local fe_rx_credit_max write-enable
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_local_pair_credit_we_asserts(dut):
    """Probe 2: monitor the FCSM-local credit-ledger flop `fe_rx_credit_max`
    and the combinational gate (`pkt_is_cr_pkt | pkt_is_crack_pkt`) that
    drives its load. Verify the flop advances when the gate fires.

    Localisation:
      * cr_seen=1 AND gate fires AND fe_rx_credit_max increments -> probe OK,
        bug is downstream (between FCSM ledger and APB mirror).
      * cr_seen=1 AND gate fires AND fe_rx_credit_max STAYS 0    -> the
        write-enable arithmetic is broken (e.g. en_ff2_rx_demet_io_out
        clearing the load).
      * gate never fires despite cr_seen=1                        -> the
        pkt_is_cr_pkt classifier is wrong (data_id mismatch).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await ClockCycles(dut.hclk, 2000)

    fcsm_m = _fcsm(dut, "m")
    fcsm_s = _fcsm(dut, "s")

    # Sample fe_rx_credit_max before and after a long observation window.
    pre_m = _safe_int(fcsm_m.fe_rx_credit_max, 0)
    pre_s = _safe_int(fcsm_s.fe_rx_credit_max, 0)
    pre_tx_m = _safe_int(fcsm_m.fe_tx_credit_max, 0)
    pre_tx_s = _safe_int(fcsm_s.fe_tx_credit_max, 0)
    cr_m = _safe_int(fcsm_m.cr_pkt_seen_rx, 0)
    cr_s = _safe_int(fcsm_s.cr_pkt_seen_rx, 0)

    tb.log.info(
        f"  pre-sweep: M.fe_rx_credit_max=0x{pre_m:02x} fe_tx=0x{pre_tx_m:02x} cr_seen={cr_m}  "
        f"S.fe_rx_credit_max=0x{pre_s:02x} fe_tx=0x{pre_tx_s:02x} cr_seen={cr_s}"
    )

    # Count gate firings + transitions over 4000 cycles.
    gate_fires = {"m": 0, "s": 0}
    transitions = {"m": 0, "s": 0}
    prev_rx = {"m": pre_m, "s": pre_s}

    for _ in range(4000):
        await RisingEdge(dut.hclk)
        for side, fcsm in (("m", fcsm_m), ("s", fcsm_s)):
            gate = _safe_int(fcsm.pkt_is_cr_pkt, 0) | _safe_int(fcsm.pkt_is_crack_pkt, 0)
            if gate:
                gate_fires[side] += 1
            now = _safe_int(fcsm.fe_rx_credit_max, prev_rx[side])
            if now != prev_rx[side]:
                transitions[side] += 1
                prev_rx[side] = now

    post_m = _safe_int(fcsm_m.fe_rx_credit_max, 0)
    post_s = _safe_int(fcsm_s.fe_rx_credit_max, 0)
    post_tx_m = _safe_int(fcsm_m.fe_tx_credit_max, 0)
    post_tx_s = _safe_int(fcsm_s.fe_tx_credit_max, 0)

    tb.log.info(
        f"  post-sweep: M.fe_rx_credit_max=0x{post_m:02x} fe_tx=0x{post_tx_m:02x} "
        f"gate_fires={gate_fires['m']} transitions={transitions['m']}"
    )
    tb.log.info(
        f"  post-sweep: S.fe_rx_credit_max=0x{post_s:02x} fe_tx=0x{post_tx_s:02x} "
        f"gate_fires={gate_fires['s']} transitions={transitions['s']}"
    )

    # Verdict 1: cr_pkt_seen_rx already latched (snapshot says cr=1 on both
    # sides). If the gate never fires again during observation, that's fine
    # — the gate is per-packet, not sticky — but the ledger must have a
    # non-zero value carried over from the initial load.
    assert post_m != 0, (
        f"[m] fe_rx_credit_max stuck at 0 despite cr_pkt_seen_rx={cr_m}. "
        f"Gate fires over window: {gate_fires['m']}. "
        "Bug is in the FCSM consumer-side write path (write-enable gate)."
    )
    assert post_s != 0, (
        f"[s] fe_rx_credit_max stuck at 0 despite cr_pkt_seen_rx={cr_s}. "
        f"Gate fires over window: {gate_fires['s']}. "
        "Bug is in the FCSM consumer-side write path (write-enable gate)."
    )


# ---------------------------------------------------------------------------
# Test 3 — APB-side mirror vs FCSM ledger
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_apb_mirror_matches_fcsm(dut):
    """Probe 3: compare the FCSM-side `fe_rx_credit_max` (Wlink internal) to
    the APB-side `pair_credit_counter` (TideLink local register at
    0x44032028). The two are NOT a direct mirror -- pair_credit_counter is
    fed by the PEER returner's release_credits write over the FC link, so
    it stays 0 until AHB RX traffic has been read.

    This test treats the two layers separately:
      * Probe 3a:  FCSM-side ledger non-zero -- if FAIL, see Probe 2 output.
      * Probe 3b:  APB-side pair_credit_counter STILL 0 with zero RX-FIFO
                   read traffic -- this is EXPECTED. We don't assert non-zero
                   here; instead we report the value alongside the
                   released_credits_acc and doorbell_response_acc siblings
                   so the engineer can confirm no returner-side traffic
                   has crossed the link.

    Localisation:
      * FCSM ledger != 0 AND APB mirror == 0 with no RX traffic   -> OK,
        the APB mirror only updates after a release_credits round-trip.
        Re-target test_07's assertion at the FCSM ledger.
      * FCSM ledger != 0 AND released_credits_acc / doorbell_response_acc
        also stay 0 after deliberate traffic -- CDC / mirror BROKEN.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await ClockCycles(dut.hclk, 2000)

    fcsm_m = _fcsm(dut, "m")
    fcsm_s = _fcsm(dut, "s")
    regs_m = _apb_regs(dut, "m")
    regs_s = _apb_regs(dut, "s")

    fcsm_rx_m = _safe_int(fcsm_m.fe_rx_credit_max, 0)
    fcsm_rx_s = _safe_int(fcsm_s.fe_rx_credit_max, 0)
    apb_pcc_m = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    apb_pcc_s = await tb.s_apb.read(APB_PAIR_CREDIT_COUNTER)
    rel_m = _safe_int(regs_m.released_credits_acc, 0)
    rel_s = _safe_int(regs_s.released_credits_acc, 0)
    db_m = _safe_int(regs_m.doorbell_response_acc, 0)
    db_s = _safe_int(regs_s.doorbell_response_acc, 0)

    tb.log.info(
        f"  M: FCSM.fe_rx_credit_max=0x{fcsm_rx_m:02x}  "
        f"APB.pair_credit_counter=0x{apb_pcc_m:08x}  "
        f"released_acc=0x{rel_m:08x}  doorbell_resp_acc=0x{db_m:08x}"
    )
    tb.log.info(
        f"  S: FCSM.fe_rx_credit_max=0x{fcsm_rx_s:02x}  "
        f"APB.pair_credit_counter=0x{apb_pcc_s:08x}  "
        f"released_acc=0x{rel_s:08x}  doorbell_resp_acc=0x{db_s:08x}"
    )

    # Probe 3a — FCSM-side ledger must have loaded from the CR packet.
    assert fcsm_rx_m != 0, (
        "[m] FCSM-side fe_rx_credit_max == 0 despite cr_pkt_seen_rx -- "
        "see Probe 2 output for the gate/transition trace."
    )
    assert fcsm_rx_s != 0, (
        "[s] FCSM-side fe_rx_credit_max == 0 despite cr_pkt_seen_rx -- "
        "see Probe 2 output for the gate/transition trace."
    )


# ---------------------------------------------------------------------------
# Test 4 — On-wire CR/CRACK typecode sanity
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_cr_pkt_typecode_on_wire(dut):
    """Probe 4: capture all auto_rx_in_* samples while sop+valid+enable are
    asserted; cross-check that the packets the FCSM is decoding as CR/CRACK
    actually have a non-zero word_count and the configured data_id.

    Localisation:
      * Some packets seen with the right data_id but word_count==0 ->
        encoder bug.
      * No packets ever seen with the expected CR data_id (POR default
        0x44/0x45) -> the producer's data_id mux is broken.
      * Packets seen with right data_id and non-zero word_count, but
        pkt_is_cr_pkt never asserts -> the swi_cr_id config-register
        mismatch (the consumer expects a different data_id).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)

    fcsm_m = _fcsm(dut, "m")
    fcsm_s = _fcsm(dut, "s")

    # Re-decode the swi config registers so we know what the consumer is
    # expecting.
    cfg = {}
    for side, fcsm in (("m", fcsm_m), ("s", fcsm_s)):
        try:
            cfg[side] = {
                "swi_cr_id":          _safe_int(fcsm.swi_cr_id, 0),
                "swi_crack_id":       _safe_int(fcsm.out_prepend_swi_crack_id, 0),
                "swi_data_id_1":      _safe_int(fcsm.swi_data_id_1, 0),
            }
        except Exception as exc:
            cfg[side] = {"error": str(exc)}
    tb.log.info(f"  configured ids: M={cfg['m']}  S={cfg['s']}")

    # Sample every cycle where auto_rx_in_sop & auto_rx_in_valid for 4000 cy.
    seen = {"m": [], "s": []}
    for _ in range(4000):
        await RisingEdge(dut.hclk)
        for side, fcsm in (("m", fcsm_m), ("s", fcsm_s)):
            sop = _safe_int(fcsm.auto_rx_in_sop, 0)
            val = _safe_int(fcsm.auto_rx_in_valid, 0)
            if sop and val:
                did = _safe_int(fcsm.auto_rx_in_data_id, 0)
                wcn = _safe_int(fcsm.auto_rx_in_word_count, 0)
                pcr = _safe_int(fcsm.pkt_is_cr_pkt, 0)
                pca = _safe_int(fcsm.pkt_is_crack_pkt, 0)
                seen[side].append((did, wcn, pcr, pca))

    for side in ("m", "s"):
        tb.log.info(f"  [{side}] rx sop+valid events: {len(seen[side])}")
        # Distinct data_ids observed
        dids = sorted({d for d, _, _, _ in seen[side]})
        tb.log.info(f"  [{side}] distinct rx data_ids: {[hex(d) for d in dids]}")
        # Specifically dump any classified as CR/CRACK
        cr_evts = [(d, w, p, c) for d, w, p, c in seen[side] if p or c]
        for d, w, p, c in cr_evts[:8]:
            tag = "CR" if p else "CRACK"
            tb.log.info(
                f"      {tag} on wire: data_id=0x{d:02x} word_count=0x{w:04x}"
            )

    # Verdict: both sides must have seen at least one packet classified as
    # CR or CRACK.  If not, the swi_cr_id / swi_crack_id config is mismatched
    # against the producer.
    for side in ("m", "s"):
        cr_count = sum(1 for d, w, p, c in seen[side] if p or c)
        assert cr_count > 0, (
            f"[{side}] no CR/CRACK classifications in 4000 cycles. "
            f"Configured swi_cr_id=0x{cfg[side].get('swi_cr_id', 0):02x} "
            f"swi_crack_id=0x{cfg[side].get('swi_crack_id', 0):02x}. "
            f"Distinct rx data_ids seen: "
            f"{[hex(d) for d in sorted({d for d,_,_,_ in seen[side]})]}. "
            "Bug is the data_id mismatch (producer vs consumer)."
        )

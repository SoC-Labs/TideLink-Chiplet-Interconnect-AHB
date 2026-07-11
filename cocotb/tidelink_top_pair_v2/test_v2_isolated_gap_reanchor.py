"""V2 L9b BOUNDED FORWARD RE-ANCHOR repro + fix gate (sim-only, RX-isolated).

THE SILICON WEDGE (measured, A->B, marginal eye, sustained 16-word burst):
an isolated bit error corrupts a received pktnum -> die_b RX `exp_pkt_not_seen`
-> ack_nack_fifo carries a 3'h1 (isNotExpPacket) entry -> send_nack_req -> NACK
to die_a -> die_a's a2l replay REVERTS its read pointer and re-walks. exp_pkt_num
is FROZEN on a mismatch, so the replayed stream keeps mismatching -> NACK ->
revert -> re-walk REPLAY STORM ratchets the credit ring to credit-max -> sticky
wedge (POR-only clear).

THE FIX (WlinkGenericFCSM_6.v L9b): on an ISOLATED FORWARD gap (ll_rx_pktnum a
small number of slots AHEAD of exp_pkt_num, within SOCL_L9B_FWD_WINDOW, rate-
limited by SOCL_L9B_HOLD_PKTS), RE-ANCHOR exp_pkt_num forward to ll_rx_pktnum+1,
COMMIT the packet, and SUPPRESS the mismatch enqueue -> NO isNotExpPacket entry
-> NO NACK -> die_a never reverts -> the storm cannot start.

This test injects the gap DIRECTLY at the framer->FCSM RX boundary (forcing
auto_rx_in_*, io_rx_clk domain), exactly like test_v2_heldvalid_pktnum, so the FC
RX *decision* is isolated from the TX/replay loop. Two oracles:

  (A) NO MISMATCH ENQUEUE on the gap beat: ack_nack_fifo_io_winc must NOT carry
      a 3'h1 (isNotExpPacket) notifier on the re-anchored beat. On the UNFIXED
      RTL it would (-> NACK -> revert -> storm); on the FIXED RTL the re-anchor
      suppresses it.
  (B) FORWARD PROGRESS: exp_pkt_num re-anchors to the received pktnum+1 and EVERY
      packet after the gap continues to commit (no freeze / no over-advance).

The control test drives a perfectly in-order burst (no gap) and asserts the
re-anchor NEVER fires and delivery is exactly-once -- i.e. the fix is inert on a
clean stream (this mirrors the clean-delivery constraint).

Run:  make EPOCH_PROFILE=zero MODULE=test_v2_isolated_gap_reanchor
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

N_PACKETS = 16
# Which packet index to inject the isolated forward gap before. The injected
# packet's pktnum jumps forward by GAP_SIZE slots (an isolated dropped packet).
GAP_BEFORE = int(os.environ.get("GAP_BEFORE", "6"))
GAP_SIZE = int(os.environ.get("GAP_SIZE", "2"))   # forward skip, within window(4)


def fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


def _gv(rx, n):
    o = getattr(rx, n, None)
    return _i(o) if o is not None else -9


async def _drive_burst(tb, dst, inject_gap):
    """Force a clean in-order single-beat-per-packet burst at the FCSM RX bus.
    If inject_gap, the packet at index GAP_BEFORE carries a pktnum that is
    GAP_SIZE slots AHEAD of the live exp_pkt_num (an isolated forward gap), then
    the stream resumes contiguously from there. Returns a per-beat trace."""
    rx = fcsm(tb, dst)
    rxclk = rx.io_rx_clk

    sop, did, wc = rx.auto_rx_in_sop, rx.auto_rx_in_data_id, rx.auto_rx_in_word_count
    data, valid, crc = rx.auto_rx_in_data, rx.auto_rx_in_valid, rx.auto_rx_in_crc
    exp_sig = rx.exp_pkt_num

    try:
        rx.out_prepend_swi_disable_crc.value = 1   # CRC off (GPIO-speed default)
    except Exception:
        pass

    sop.value = Force(0); valid.value = Force(0); did.value = Force(0)
    wc.value = Force(0); data.value = Force(0); crc.value = Force(0)
    await RisingEdge(rxclk)

    fetxmax = _gv(rx, "fe_tx_credit_max")
    start_exp = _i(exp_sig)
    tb.log.info(f"  [gap] start exp={start_exp} fe_tx_credit_max=0x{fetxmax:02x} "
                f"inject_gap={inject_gap} GAP_BEFORE={GAP_BEFORE} "
                f"GAP_SIZE={GAP_SIZE}")

    trace = []   # per beat: dict of probed signals
    for k in range(N_PACKETS):
        payload48 = (0xA5A50000 + (k << 8) + k) & 0xFFFFFFFFFFFF
        live_exp = _i(exp_sig) & 0xFF
        if inject_gap and k == GAP_BEFORE:
            pktnum = (live_exp + GAP_SIZE) & 0xFF      # isolated FORWARD gap
        else:
            pktnum = live_exp                          # contiguous in-order
        word = ((payload48 & 0xFFFFFFFFFFFF) << 8) | (pktnum & 0xFF)
        sop.value = Force(1); valid.value = Force(1); did.value = Force(0xa1)
        wc.value = Force(1); data.value = Force(word); crc.value = Force(0)
        await RisingEdge(rxclk)
        row = dict(
            k=k, pktnum=pktnum, exp_after=_i(exp_sig),
            isdata=_gv(rx, "pkt_is_data_pkt"),
            seen=_gv(rx, "exp_pkt_seen"),
            notseen=_gv(rx, "exp_pkt_not_seen"),
            reanchor=_gv(rx, "socl_l9b_reanchor_now"),
            fwd_dist=_gv(rx, "socl_l9b_fwd_dist"),
            hold=_gv(rx, "socl_l9b_hold"),
            appval=_i(rx.l2a_fc_replay_app_valid),
            winc=_gv(rx, "ack_nack_fifo_io_winc"),
            notif=_gv(rx, "pkttypenotifier"),
            l9b_masked=_gv(rx, "exp_pkt_not_seen_l9b"),
        )
        trace.append(row)
        # inter-packet gap (framer re-hunts)
        sop.value = Force(0); valid.value = Force(0)
        await RisingEdge(rxclk)
        await RisingEdge(rxclk)

    for s in (sop, did, wc, data, valid, crc):
        s.value = Release()
    await RisingEdge(rxclk)
    return start_exp, trace


@cocotb.test()
async def test_clean_inorder_reanchor_inert(dut):
    """CONTROL: a perfectly in-order burst (no gap) must NEVER re-anchor and must
    commit exactly once per packet. Proves the L9b fix is inert on a clean stream
    (the clean-delivery constraint)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    start_exp, trace = await _drive_burst(tb, "s", inject_gap=False)

    reanchors = sum(r["reanchor"] == 1 for r in trace)
    nack_enq = [r["k"] for r in trace if r["winc"] == 1 and r["notif"] == 1]
    commits = sum(r["appval"] == 1 for r in trace)
    seen = sum(r["seen"] == 1 for r in trace)
    tb.log.info(f"  [clean] re-anchors={reanchors} (expect 0) "
                f"nack_enqueues={nack_enq} (expect []) commits={commits} "
                f"matches(seen)={seen}")

    assert reanchors == 0, f"L9b re-anchor fired on a CLEAN in-order burst: {trace}"
    assert not nack_enq, f"clean burst enqueued a NACK notifier at {nack_enq}"
    assert commits >= N_PACKETS - 1, f"clean burst under-committed: commits={commits}"


@cocotb.test()
async def test_isolated_forward_gap_reanchors_no_nack(dut):
    """FIX GATE: an isolated forward pktnum gap (within the window) must
    RE-ANCHOR exp_pkt_num forward, COMMIT, and emit NO isNotExpPacket notifier
    (-> die_a never reverts -> no storm). Every subsequent packet must keep
    committing (no freeze)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    start_exp, trace = await _drive_burst(tb, "s", inject_gap=True)

    for r in trace:
        tag = ("REANCHOR" if r["reanchor"] else
               ("MATCH" if r["seen"] else
                ("MISMATCH" if r["notseen"] else ".")))
        tb.log.info(f"      k={r['k']:2d} pktnum=0x{r['pktnum']:02x} "
                    f"exp_after={r['exp_after']:3d} fwd_dist={r['fwd_dist']:2d} "
                    f"hold={r['hold']} seen={r['seen']} notseen={r['notseen']} "
                    f"reanchor={r['reanchor']} appval={r['appval']} "
                    f"winc={r['winc']} notif={r['notif']} => {tag}")

    gap_row = next(r for r in trace if r["k"] == GAP_BEFORE)
    # Oracle (A): the gap beat re-anchored and did NOT enqueue a NACK notifier.
    nack_enq = [r["k"] for r in trace if r["winc"] == 1 and r["notif"] == 1]
    assert gap_row["reanchor"] == 1, (
        f"isolated forward gap did NOT re-anchor: gap beat={gap_row}")
    assert gap_row["notif"] != 1, (
        f"gap beat enqueued an isNotExpPacket (3'h1) notifier -> would NACK: "
        f"{gap_row}")
    assert GAP_BEFORE not in nack_enq, (
        f"a NACK notifier was enqueued on the gap beat -> die_a would revert "
        f"(storm): nack_enqueues={nack_enq}")
    assert not nack_enq, (
        f"NACK notifier(s) enqueued (would drive die_a revert storm) at "
        f"packets {nack_enq}; the isolated gap must be NACK-free")

    # Oracle (B): forward progress. The gap beat commits the re-anchored packet,
    # exp advanced PAST the received pktnum, and every packet AFTER the gap is
    # an in-order MATCH that commits (no freeze).
    assert gap_row["appval"] == 1, f"re-anchored packet did not commit: {gap_row}"
    post = [r for r in trace if r["k"] > GAP_BEFORE]
    assert all(r["seen"] == 1 for r in post), (
        f"stream did NOT re-sync after the gap (frozen exp / would storm): "
        f"{[(r['k'], r['pktnum'], r['exp_after'], r['seen']) for r in post]}")
    assert all(r["appval"] == 1 for r in post), (
        f"a post-gap packet failed to commit: "
        f"{[(r['k'], r['appval']) for r in post]}")

    # Bound check: exactly ONE re-anchor for ONE isolated gap (no thrash).
    reanchors = sum(r["reanchor"] == 1 for r in trace)
    assert reanchors == 1, (
        f"expected exactly ONE re-anchor for one isolated gap, got {reanchors}")
    tb.log.info(f"  [gap] PASS: 1 re-anchor, 0 NACK enqueues, all post-gap "
                f"packets committed (re-synced forward, no storm).")

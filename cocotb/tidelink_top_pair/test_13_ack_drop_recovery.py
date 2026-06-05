"""S3-B — single dropped credit-return ACK: does the FCSM RECOVER or WEDGE?

Context (docs/MEMORY + DEBUG_PLAN_CREDIT_RETURN_DATA_TRANSFER):
  The chiplet link comes up bilaterally and crosses initial data, but SUSTAINED
  M->S traffic decays on silicon: the sender's `fe_rx_ptr` freezes,
  `fe_rx_is_full` latches, the credit ring fills, delivery stops. test_12 proved
  the credit-return LOGIC is sound in sim (80/80 delivered, ring replenishes)
  under zero-skew AND under differential per-lane bit skew. So the HW failure is
  a RARE LOST credit-return ACK on the S->M return link (a timing/CDC event).

Decisive question (independent of the rare HW cause): does the Wlink FCSM
RECOVER from a SINGLE dropped credit-return ACK, or does it wedge permanently?

Recovery-machinery map (src/rtl/local_overrides/WlinkGenericFCSM_6.v):
  * The ACK is CUMULATIVE. The receiver tracks `last_good_pkt` = the highest
    IN-ORDER data packet number received (:975-976, advances only on
    `exp_pkt_seen`). When it has pending data it emits an ACK in state 6 carrying
    `last_good_pkt_from_rx` (:470-472, :553).
  * The sender sets `fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8]` ABSOLUTELY on any
    ACK/NACK (:1205-1206) — NOT incrementally. So a LATER cumulative ACK jumps
    `fe_rx_ptr` straight to the latest value, catching up past a dropped one.
  * `send_ack_req` is (re)armed by every fresh in-order data packet
    (`isExpPacket | l2a_fifo_raddr_txclk_update`, :1233-1241). So while the
    master keeps sending data, the slave keeps generating FRESH cumulative ACKs.
  * There is NO timeout / NO retransmit-on-ACK-timeout / NO periodic credit-sync
    for a silently-dropped ACK. (NACK has a replay path via
    a2l_fc_replay_link_revert :875, but a vanished ACK produces no NACK.)

  => Therefore recovery from a single dropped ACK is POSSIBLE *only if* a later
     cumulative ACK arrives BEFORE the ring fills. If the ring fills first
     (`fe_rx_is_full` latches at :464), the sender stops emitting data, the slave
     stops receiving new data, no fresh ACK is generated, and the link WEDGES
     with no escape until reset.

This test injects exactly ONE dropped ACK on the master's ACK-decode and then
keeps driving data, observing whether `fe_rx_ptr` resumes (RECOVER) or freezes
while `ne_rx_ptr` climbs to `fe_rx_is_full` (WEDGE).

Injection mechanism
-------------------
The master FCSM dequeues the ack_nack_fifo with
    ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0   (:862)
which is INDEPENDENT of the packet-type decode. So if we Force `isAckPacket`
(and `isNackPacket`) LOW for the single tx-clock the target ACK entry sits at
the fifo head, that entry is still DEQUEUED (rinc fires) but `fe_rx_ptr` is NOT
updated (:1205 condition false). That is a faithful single silently-dropped ACK:
one credit-return is consumed-and-ignored, link state otherwise untouched.

Run (VCS, ~15 min):
    export CMSDK_FPGA_SRAM_V=.../cmsdk_fpga_sram.v
    make SIM_BUILD=sim_build_ackdrop MODULE=test_13_ack_drop_recovery \
         TESTCASE=test_13_ack_drop_recovery TB_TOP_NO_DUMP=1 2>&1 | tail -60
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from test_12_sustained_data_skew_decay import (
    ring_probe,
    fmt_ring,
    drain_one_packet,
)


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except Exception:
        return default


@cocotb.test()
async def test_13_ack_drop_recovery(dut):
    """Drop exactly ONE credit-return ACK on the master, keep driving M->S
    data, and assert the link RECOVERS (fe_rx_ptr resumes, packets 20..40
    deliver). A WEDGE (fe_rx_ptr frozen, fe_rx_is_full latched, delivery dies)
    FAILS the test and demonstrates "no recovery from a lost ACK" = the HW
    root-cause class.
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)

    # ---- bring the pair up to a healthy data-mode link ----------------------
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    m0 = ring_probe(tb, "m")
    s0 = ring_probe(tb, "s")
    tb.log.info(f"  [bringup] M: {fmt_ring(m0)}")
    tb.log.info(f"  [bringup] S: {fmt_ring(s0)}")
    assert m0["cmax"] == 0x1f and s0["cmax"] == 0x1f, (
        f"link did not come up healthy: M.cmax=0x{m0['cmax']:02x} "
        f"S.cmax=0x{s0['cmax']:02x} (want 0x1f). Cannot evaluate ACK-drop.")

    mfcsm = tb.fcsm("m")
    # Handles to the master ACK-decode wires we will momentarily Force low.
    sig_isack  = mfcsm.isAckPacket
    sig_isnack = mfcsm.isNackPacket
    # The FCSM credit ring runs in the io_tx_clk (PHY link-clock) domain, NOT
    # hclk — fe_rx_ptr/isAckPacket are updated on io_tx_clk. We must hold the
    # force across the FCSM's own clock to faithfully drop exactly one ACK.
    sig_txclk  = mfcsm.io_tx_clk
    sig_fe_ptr = mfcsm.fe_rx_ptr

    # ---- driving parameters --------------------------------------------------
    N_PACKETS = 50          # >> ring depth (31): credit MUST replenish
    N_PAYLOAD = 2
    DROP_AT   = 10          # inject the single dropped ACK around this packet
    word0 = encode_word0(length=N_PAYLOAD, pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)

    delivered = 0
    first_fail_pkt = None
    is_full_latched = False
    drop_done = False
    fe_ptr_before_drop = None
    fe_ptr_advanced_after_drop = False

    # Track frozen fe_rx_ptr AFTER the drop (the WEDGE fingerprint).
    prev_fe_ptr = m0["fe_rx_ptr"]
    fe_ptr_frozen_at = None
    fe_ptr_stuck_count = 0

    drop_landed = {"ok": False, "fe_before": None, "fe_after": None}

    async def drop_one_ack():
        """Background: on the FCSM's OWN io_tx_clk, wait for the master's next
        ACK at the fifo head, then Force isAckPacket/isNackPacket low across
        that one tx-clock edge so the entry is dequeued (rinc fires,
        independent of the type-decode at :862) but fe_rx_ptr is NOT updated
        (:1205 condition false) => exactly one silently-dropped ACK.

        We capture fe_rx_ptr on the cycle the (un-forced) ACK is at the head
        and again after the forced edge; if the force truly dropped the ACK,
        fe_rx_ptr must NOT take the value the ACK carried this cycle. We log
        both so the drop is provably effective, not a no-op."""
        clk = sig_txclk          # io_tx_clk — the FCSM credit-ring clock
        # Wait until a real ACK sits at the fifo head AND it carries a NEW
        # cumulative ptr (one that would ADVANCE fe_rx_ptr). Dropping a
        # redundant ACK (carries the value fe_rx_ptr already holds) is an
        # invisible no-op — we want the drop to be observably effective so the
        # recover-vs-wedge verdict is meaningful.
        guard = 0
        ack_carried = -1
        while guard < 4000000:
            await RisingEdge(clk)
            guard += 1
            try:
                if int(sig_isack.value) != 1:
                    continue
                ack_carried = (int(mfcsm.ack_nack_fifo_io_rdata.value) >> 8) & 0xFF
                if ack_carried != _safe_int(sig_fe_ptr):
                    break   # this ACK would advance fe_rx_ptr — drop THIS one
            except ValueError:
                pass
        else:
            tb.log.info("  [drop] WARNING: never observed an advancing ACK to drop")
            return
        # ACK is at the head NOW and carries ack_carried != current fe_rx_ptr.
        # Force the decodes low, advance one tx-clock edge (rinc consumes the
        # head entry per :862; fe_rx_ptr update suppressed per :1205), release.
        fe_before = _safe_int(sig_fe_ptr)
        sig_isack.value  = Force(0)
        sig_isnack.value = Force(0)
        tb.log.info(f"  [drop] >>> ACK at head (carries fe_rx_ptr<-{ack_carried}); "
                    f"forcing master isAckPacket/isNackPacket=0 for one tx-clk; "
                    f"fe_rx_ptr before={fe_before}")
        await RisingEdge(clk)        # the forced edge — drop happens here
        fe_after = _safe_int(sig_fe_ptr)
        sig_isack.value  = Release()
        sig_isnack.value = Release()
        drop_landed["ok"] = (fe_after != ack_carried) or (ack_carried < 0)
        drop_landed["fe_before"] = fe_before
        drop_landed["fe_after"] = fe_after
        tb.log.info(f"  [drop] <<< released; fe_rx_ptr after forced edge={fe_after} "
                    f"(ACK would have written {ack_carried}); "
                    f"drop_landed={drop_landed['ok']}")

    drop_task = None

    tb.log.info(f"  ==== driving {N_PACKETS} back-to-back AHB DATA packets "
                f"M->S; dropping ONE return ACK at ~pkt {DROP_AT} ====")

    for pkt in range(N_PACKETS):
        base = 0xD0000000 | (pkt << 8)
        payload = [base | 0xEF, base | 0xBE]
        words = [word0, 0x0] + payload

        # Arm the single-ACK drop just before sending the trigger packet, so
        # the forced ACK is the one returning for this packet's data.
        if pkt == DROP_AT and not drop_done:
            mp_pre = ring_probe(tb, "m")
            fe_ptr_before_drop = mp_pre["fe_rx_ptr"]
            tb.log.info(f"  [pkt {pkt:02d}] arming single-ACK drop; "
                        f"M before: {fmt_ring(mp_pre)}")
            drop_task = cocotb.start_soon(drop_one_ack())
            drop_done = True

        await tb.ahb_tx_write_packet("m", words)
        await ClockCycles(tb.dut.hclk, 400)

        got = await drain_one_packet(tb, "s", N_PAYLOAD)
        ok = (got == payload)
        if ok:
            delivered += 1
        elif first_fail_pkt is None:
            first_fail_pkt = pkt

        mp = ring_probe(tb, "m")
        sp = ring_probe(tb, "s")
        if mp["is_full"] == 1:
            is_full_latched = True

        # After the drop, watch whether fe_rx_ptr resumes advancing.
        if drop_done and pkt > DROP_AT:
            if fe_ptr_before_drop is not None and \
               mp["fe_rx_ptr"] != fe_ptr_before_drop:
                fe_ptr_advanced_after_drop = True
            if mp["fe_rx_ptr"] == prev_fe_ptr:
                fe_ptr_stuck_count += 1
                if fe_ptr_stuck_count >= 8 and fe_ptr_frozen_at is None:
                    fe_ptr_frozen_at = pkt
            else:
                fe_ptr_stuck_count = 0
        prev_fe_ptr = mp["fe_rx_ptr"]

        if pkt < 4 or abs(pkt - DROP_AT) <= 3 or pkt % 8 == 0 or not ok:
            tag = "" if ok else "  <<< PAYLOAD FAIL"
            tb.log.info(f"  [pkt {pkt:02d}] sent=0x{payload[0]:08x}.. "
                        f"got={[f'0x{w:08x}' for w in got]}{tag}")
            tb.log.info(f"      M(sender): {fmt_ring(mp)}")
            tb.log.info(f"      S(recvr) : {fmt_ring(sp)}")

    if drop_task is not None:
        await drop_task

    mf = ring_probe(tb, "m")
    sf = ring_probe(tb, "s")
    tb.log.info("  ==== final state ====")
    tb.log.info(f"  M(sender): {fmt_ring(mf)}")
    tb.log.info(f"  S(recvr) : {fmt_ring(sf)}")
    tb.log.info(f"  fe_rx_ptr before drop: {fe_ptr_before_drop}")
    tb.log.info(f"  injection: drop_landed={drop_landed['ok']} "
                f"fe_rx_ptr at forced edge: {drop_landed['fe_before']} -> "
                f"{drop_landed['fe_after']}")
    tb.log.info(f"  delivered {delivered}/{N_PACKETS} packets intact M->S")
    tb.log.info(f"  fe_rx_ptr advanced AFTER drop: {fe_ptr_advanced_after_drop}")
    tb.log.info(f"  fe_rx_is_full ever latched on sender: {is_full_latched}")
    tb.log.info(f"  fe_rx_ptr frozen (>=8 stuck post-drop) first seen at pkt: "
                f"{fe_ptr_frozen_at}")

    # ---- count how many of packets 20..40 (well after the drop) delivered ---
    # (delivered is cumulative; here we assert the post-drop window recovered.)
    recovered = (delivered >= N_PACKETS - 1
                 and fe_ptr_advanced_after_drop
                 and not is_full_latched
                 and fe_ptr_frozen_at is None)
    if recovered:
        tb.log.info("  *** LINK RECOVERED from the single dropped ACK — a "
                    "later cumulative ACK caught fe_rx_ptr up. ***")
    else:
        tb.log.info("  *** LINK DID NOT RECOVER from the single dropped ACK "
                    "(WEDGE): fe_rx_ptr froze / ring filled / delivery died. "
                    "This is the HW root-cause class. ***")

    # ---- assertions: PASS == RECOVERS ---------------------------------------
    # First prove the injection was effective: a real ACK was dropped (the
    # forced edge did NOT write the value the ACK carried). Otherwise the
    # "recovery" verdict would be vacuous (no-op force).
    assert drop_landed["ok"], (
        f"injection was a NO-OP: fe_rx_ptr at the forced edge equals the value "
        f"the ACK carried ({drop_landed['fe_after']}) — no ACK was actually "
        f"dropped. Test cannot evaluate recovery. Re-tune the injection.")
    assert fe_ptr_advanced_after_drop, (
        f"WEDGE: master fe_rx_ptr never advanced after the dropped ACK "
        f"(stuck at {fe_ptr_before_drop}). No later ACK un-stuck it. "
        f"Final M ring: {fmt_ring(mf)}.")
    assert not is_full_latched, (
        f"WEDGE: sender fe_rx_is_full latched after the dropped ACK — ring "
        f"filled and never replenished. Final {fmt_ring(mf)}.")
    assert fe_ptr_frozen_at is None, (
        f"WEDGE: master fe_rx_ptr froze at pkt {fe_ptr_frozen_at} after the "
        f"dropped ACK while ne_rx_ptr advanced. Final {fmt_ring(mf)}.")
    assert delivered >= N_PACKETS - 1, (
        f"WEDGE: only {delivered}/{N_PACKETS} delivered after dropping ONE "
        f"ACK (first fail pkt {first_fail_pkt}). The link did not recover from "
        f"a single lost credit-return ACK. Final M ring: {fmt_ring(mf)}.")

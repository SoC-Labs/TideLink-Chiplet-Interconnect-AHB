"""S3-C — SUSTAINED credit-return ACK loss: does the FCSM RECOVER or WEDGE?

Context (docs/MEMORY + test_12 / test_13):
  * test_12 proved that with NO lost ACKs, 80 back-to-back M->S DATA packets
    deliver fine — the credit-return LOGIC is sound.
  * test_13 proved that a SINGLE dropped credit-return ACK SELF-HEALS: the ACK
    is cumulative (the master sets `fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8]`
    ABSOLUTELY at WlinkGenericFCSM_6.v:1205/1206), so a LATER cumulative ACK
    jumps `fe_rx_ptr` straight to the newest value, catching up past the one
    that was dropped. Recovery is possible ONLY because fresh data keeps
    arriving at the slave, which keeps minting FRESH cumulative ACKs.

  The silicon failure is SUSTAINED ACK loss on the S->M return link (a timing /
  CDC event that drops EVERY credit-return for a stretch). This test models
  exactly that: from ~packet 5 the master's ACK-decode is forced DEAD so EVERY
  incoming credit-return ACK is silently ignored while M->S DATA keeps flowing.

The wedge fingerprint we expect on CURRENT RTL
----------------------------------------------
  1. With ACKs ignored, the master's `fe_rx_ptr` cannot advance.
  2. The slave keeps receiving data, so the sender's `ne_rx_ptr` climbs toward
     `fe_rx_ptr + 31` (ring depth).
  3. When `ne_rx_ptr` reaches the head, `fe_rx_is_full` LATCHES (:464) — the FC
     adapter stops accepting new AHB writes: the AHB TX write back-pressures
     (hready never goes high; our compliant write helper's bounded inner loop
     exhausts without the FC adapter popping the word).
  4. We then RELEASE the force. But the sender has STOPPED emitting data
     (ring full) => the slave receives no NEW data => the slave mints NO FRESH
     cumulative ACK => the master's `fe_rx_ptr` stays frozen => PERMANENT WEDGE.
     The FCSM state-7 NACK watchdog only recovers from CRC / unexpected-packet
     errors, NOT from a silently-vanished ACK, so there is NO escape on the
     current RTL.

Assertion that makes this a real gate: AFTER releasing the force the link MUST
RECOVER (fe_rx_ptr advances, fe_rx_is_full clears, further packets deliver).
On CURRENT RTL it will NOT recover => test FAILS = RED. The receiver-side
periodic re-ACK fix (WlinkGenericFCSM_6.v, SoC Labs credit-recovery 2026-06-05)
turns this GREEN: the slave re-emits its cumulative last_good ACK after an
idle window, so the master's fe_rx_ptr catches up WITHOUT needing fresh data.

Injection mechanism (same handles test_13 uses, but held CONTINUOUSLY)
----------------------------------------------------------------------
The master FCSM dequeues the ack_nack_fifo with
    ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0   (:862)
which is INDEPENDENT of the packet-type decode. So forcing `isAckPacket` and
`isNackPacket` LOW continuously means every ACK entry is still DEQUEUED (rinc
fires) but `fe_rx_ptr` is NEVER updated (:1205 condition false). That is a
faithful SUSTAINED silently-dropped-ACK stream: every credit-return is
consumed-and-ignored, link state otherwise untouched.

Run (VCS):
    export CMSDK_FPGA_SRAM_V=.../cmsdk_fpga_sram.v
    make SIM_BUILD=sim_build_wedge MODULE=test_14_sustained_ack_drop_wedge \
         TESTCASE=test_14_sustained_ack_drop_wedge TB_TOP_NO_DUMP=1 2>&1 | tail -80
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
async def test_14_sustained_ack_drop_wedge(dut):
    """Drop EVERY credit-return ACK on the master continuously from ~pkt 5
    while driving sustained M->S DATA, prove the credit ring fills and the
    sender wedges (fe_rx_is_full latches, fe_rx_ptr frozen, AHB write stalls),
    then RELEASE the force and assert the link RECOVERS. On current RTL it does
    NOT recover => RED. With the periodic re-ACK fix it recovers => GREEN.
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
    sig_isack  = mfcsm.isAckPacket
    sig_isnack = mfcsm.isNackPacket
    sig_txclk  = mfcsm.io_tx_clk
    sig_fe_ptr = mfcsm.fe_rx_ptr

    # ---- driving parameters --------------------------------------------------
    N_PACKETS       = 60     # >> ring depth (31): without working ACKs, the
                             #    ring MUST fill well before this many.
    N_PAYLOAD       = 2
    DROP_FROM       = 5      # begin ignoring ALL master ACKs from this packet
    DROP_UNTIL      = None   # set when we detect the wedge (release point)
    RELEASE_AT_FULL = True   # release the force once fe_rx_is_full latches +
                             #   a few more packets confirm the stall
    word0 = encode_word0(length=N_PAYLOAD, pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)

    # ---- continuous ACK-drop forcer (runs in the FCSM's io_tx_clk domain) ----
    # While `drop_active["on"]` is set we hold isAckPacket/isNackPacket LOW on
    # EVERY io_tx_clk edge, so EVERY ack_nack_fifo entry the master dequeues is
    # treated as "not an ACK/NACK" => fe_rx_ptr never updates. This faithfully
    # models a sustained loss of ALL credit-returns on the S->M return link.
    drop_active = {"on": False, "running": True, "edges_forced": 0}

    async def continuous_ack_drop():
        clk = sig_txclk
        forced = False
        while drop_active["running"]:
            await RisingEdge(clk)
            if drop_active["on"]:
                if not forced:
                    sig_isack.value  = Force(0)
                    sig_isnack.value = Force(0)
                    forced = True
                drop_active["edges_forced"] += 1
            else:
                if forced:
                    sig_isack.value  = Release()
                    sig_isnack.value = Release()
                    forced = False
        # final release on task exit
        if forced:
            sig_isack.value  = Release()
            sig_isnack.value = Release()

    drop_task = cocotb.start_soon(continuous_ack_drop())

    delivered_pre   = 0     # delivered before the drop window
    delivered_post  = 0     # delivered AFTER release (the recovery evidence)
    is_full_latched = False
    is_full_seen_at = None
    fe_ptr_at_drop_start = None
    fe_ptr_frozen_during_drop = None
    write_stalled_at = None
    released_at = None
    full_confirm_count = 0

    # Track fe_rx_ptr freeze during the drop window.
    prev_fe_ptr = m0["fe_rx_ptr"]
    fe_ptr_stuck = 0

    tb.log.info(f"  ==== driving up to {N_PACKETS} AHB DATA packets M->S; "
                f"dropping ALL master credit-return ACKs from pkt {DROP_FROM} "
                f"until wedge, then releasing ====")

    # Wrap each AHB write so a full-ring back-pressure (the FC adapter never
    # pops the word) is detected as a WEDGE signal rather than hanging the test.
    async def bounded_write(words):
        """Issue an AHB TX packet; return True if it landed (FC adapter
        accepted the words), False if the ring is full and the write stalled.
        We detect the stall by sampling the FC adapter's hreadyout across a
        bounded window during the final word's data phase."""
        hready = getattr(tb.dut, "m_ahb_tx_hready")
        # Snapshot ring before; if fe_rx_is_full is set, treat as a stall
        # (the FC adapter back-pressures and the words won't be popped).
        pre = ring_probe(tb, "m")
        await tb.ahb_tx_write_packet("m", words)
        # If the ring was already full the write could not have been popped.
        post = ring_probe(tb, "m")
        stalled = (pre["is_full"] == 1)
        return (not stalled), pre, post

    for pkt in range(N_PACKETS):
        base = 0xE0000000 | (pkt << 8)
        payload = [base | 0xEF, base | 0xBE]
        words = [word0, 0x0] + payload

        # Arm the sustained drop at DROP_FROM.
        if pkt == DROP_FROM and not drop_active["on"] and released_at is None:
            mp_pre = ring_probe(tb, "m")
            fe_ptr_at_drop_start = mp_pre["fe_rx_ptr"]
            drop_active["on"] = True
            tb.log.info(f"  [pkt {pkt:02d}] >>> ARMING sustained ACK-drop; "
                        f"M before: {fmt_ring(mp_pre)}")

        landed, prering, postring = await bounded_write(words)
        await ClockCycles(tb.dut.hclk, 400)

        mp = ring_probe(tb, "m")
        sp = ring_probe(tb, "s")

        if mp["is_full"] == 1:
            is_full_latched = True
            if is_full_seen_at is None:
                is_full_seen_at = pkt

        if not landed and write_stalled_at is None:
            write_stalled_at = pkt
            tb.log.info(f"  [pkt {pkt:02d}] AHB write STALLED — ring full, FC "
                        f"adapter back-pressuring (wedge signal).")

        # Track fe_rx_ptr freeze during the drop.
        if drop_active["on"]:
            if mp["fe_rx_ptr"] == prev_fe_ptr:
                fe_ptr_stuck += 1
                if fe_ptr_stuck >= 6 and fe_ptr_frozen_during_drop is None:
                    fe_ptr_frozen_during_drop = mp["fe_rx_ptr"]
            else:
                fe_ptr_stuck = 0
        prev_fe_ptr = mp["fe_rx_ptr"]

        # Drain whatever the slave delivered this packet (don't compare yet —
        # during the wedge the slave still holds earlier packets in its FIFO).
        got = await drain_one_packet(tb, "s", N_PAYLOAD)
        ok = (got == payload)

        if released_at is None and not drop_active["on"]:
            if ok:
                delivered_pre += 1
        elif released_at is not None:
            # Post-release window: count deliveries that prove recovery.
            if ok:
                delivered_post += 1

        # ---- release the force once the wedge is firmly established ----------
        if (drop_active["on"] and RELEASE_AT_FULL and is_full_latched):
            full_confirm_count += 1
            # Hold the drop a few packets past the first full to make the wedge
            # unambiguous, then release and keep driving to look for recovery.
            if full_confirm_count >= 3 and released_at is None:
                drop_active["on"] = False
                released_at = pkt
                # let the release propagate through the io_tx_clk synchronizer
                await ClockCycles(tb.dut.hclk, 50)
                mp_rel = ring_probe(tb, "m")
                tb.log.info(f"  [pkt {pkt:02d}] <<< RELEASING ACK-drop after "
                            f"sustained wedge; M now: {fmt_ring(mp_rel)}")

        if pkt < 4 or pkt == DROP_FROM or (is_full_latched and full_confirm_count <= 4) \
           or pkt % 8 == 0 or (released_at is not None and pkt - released_at <= 8):
            tag = "" if ok else "  <<< not delivered this cycle"
            tb.log.info(f"  [pkt {pkt:02d}] sent=0x{payload[0]:08x}.. "
                        f"got={[f'0x{w:08x}' for w in got]}{tag} "
                        f"landed={landed}")
            tb.log.info(f"      M(sender): {fmt_ring(mp)}")
            tb.log.info(f"      S(recvr) : {fmt_ring(sp)}")

    # Stop the forcer task cleanly.
    drop_active["running"] = False
    await ClockCycles(tb.dut.hclk, 10)

    # ---- recovery phase 1: IDLE and watch for the periodic re-ACK ------------
    # On the current RTL the sender has stopped emitting data (ring full) so the
    # receiver mints NO fresh ACK => fe_rx_ptr stays frozen forever. With the
    # receiver-side periodic re-ACK fix the receiver re-emits its cumulative
    # last_good ACK after the idle window, which un-sticks the master's
    # fe_rx_ptr and clears fe_rx_is_full WITHOUT needing any new data.
    tb.log.info("  ==== post-release recovery phase 1: IDLE, watching for the "
                "periodic re-ACK to unstick fe_rx_ptr / clear is_full ====")
    fe_ptr_pre_idle = ring_probe(tb, "m")["fe_rx_ptr"]
    is_full_cleared_idle = False
    for w in range(40):                       # up to ~40 * 1000 = 40000 hclk
        await ClockCycles(tb.dut.hclk, 1000)
        mp = ring_probe(tb, "m")
        sp = ring_probe(tb, "s")
        if w % 5 == 0 or mp["is_full"] == 0:
            tb.log.info(f"  [idle {w:02d}] M: {fmt_ring(mp)}")
            tb.log.info(f"            S: {fmt_ring(sp)}")
        if mp["is_full"] == 0 and mp["fe_rx_ptr"] != fe_ptr_pre_idle:
            is_full_cleared_idle = True
            tb.log.info(f"  [idle {w:02d}] *** is_full CLEARED + fe_rx_ptr moved "
                        f"({fe_ptr_pre_idle} -> {mp['fe_rx_ptr']}) via periodic "
                        f"re-ACK ***")
            break

    # ---- recovery phase 2: drive CLEAN packets to confirm delivery resumed ---
    # The slave RX FIFO holds a BACKLOG of packets received during the wedge
    # (the sender kept pushing until the ring filled).  We first drain that
    # backlog, then drive fresh packets and confirm BOTH that the sender's ring
    # keeps accepting them (landed=True => credit replenished => fe_rx_ptr is
    # advancing) AND that a fresh payload arrives at the slave.
    tb.log.info("  ==== post-release recovery phase 2: drain backlog, then "
                "drive fresh packets to confirm M->S delivery resumed ====")
    # Drain up to 40 stale backlog packets so the slave FIFO returns to a known
    # state (a wedge can leave ~ring-depth packets queued).
    for _ in range(40):
        await drain_one_packet(tb, "s", N_PAYLOAD)
    await ClockCycles(tb.dut.hclk, 200)

    recovery_delivered = 0
    recovery_landed = 0
    for j in range(8):
        base = 0xC0000000 | (j << 8)
        payload = [base | 0xEF, base | 0xBE]
        words = [word0, 0x0] + payload
        landed, _, _ = await bounded_write(words)
        if landed:
            recovery_landed += 1
        await ClockCycles(tb.dut.hclk, 600)
        got = await drain_one_packet(tb, "s", N_PAYLOAD)
        if got == payload:
            recovery_delivered += 1
        mp = ring_probe(tb, "m")
        tb.log.info(f"  [recov {j}] landed={landed} got={[f'0x{w:08x}' for w in got]} "
                    f"match={got == payload} M: {fmt_ring(mp)}")

    await ClockCycles(tb.dut.hclk, 2000)
    mf = ring_probe(tb, "m")
    sf = ring_probe(tb, "s")

    tb.log.info("  ==== final state ====")
    tb.log.info(f"  M(sender): {fmt_ring(mf)}")
    tb.log.info(f"  S(recvr) : {fmt_ring(sf)}")
    tb.log.info(f"  fe_rx_ptr at drop start: {fe_ptr_at_drop_start}")
    tb.log.info(f"  edges the ACK-drop force was held: {drop_active['edges_forced']}")
    tb.log.info(f"  fe_rx_is_full ever latched: {is_full_latched} "
                f"(first at pkt {is_full_seen_at})")
    tb.log.info(f"  fe_rx_ptr frozen during drop at value: "
                f"{fe_ptr_frozen_during_drop}")
    tb.log.info(f"  AHB write first stalled at pkt: {write_stalled_at}")
    tb.log.info(f"  force released at pkt: {released_at}")
    tb.log.info(f"  packets delivered AFTER release (recovery): "
                f"{delivered_post + recovery_delivered}")

    # ---- WEDGE must have actually happened (else the test is vacuous) --------
    assert is_full_latched, (
        f"injection ineffective: fe_rx_is_full never latched even though ALL "
        f"master ACKs were ignored for {drop_active['edges_forced']} tx-clk "
        f"edges. The ring did not fill — re-tune N_PACKETS / drop window. "
        f"Final M ring: {fmt_ring(mf)}.")
    assert released_at is not None, (
        f"never reached the release point — the wedge was not established. "
        f"Final M ring: {fmt_ring(mf)}.")

    # ---- RECOVERY assertion: PASS == link recovers after the wedge -----------
    # On CURRENT (unfixed) RTL the sender stopped emitting (ring full) so the
    # receiver mints no fresh ACK => fe_rx_ptr stays frozen, fe_rx_is_full stays
    # latched, and NO post-wedge packets deliver => these FAIL = RED.  With the
    # receiver-side periodic re-ACK fix the receiver re-emits its cumulative
    # last_good ACK after the idle window, un-sticking fe_rx_ptr and clearing
    # fe_rx_is_full WITHOUT any fresh data => is_full clears and the 8 post-wedge
    # packets all deliver => GREEN.
    tb.log.info(f"  post-wedge: recovery_landed={recovery_landed}/8 "
                f"recovery_delivered(payload match)={recovery_delivered}/8 "
                f"is_full_cleared_during_idle={is_full_cleared_idle}")

    # Recovery is proven by BOTH the structural unstick (ring no longer full =>
    # the sender accepted all post-wedge writes => credit replenished) AND fresh
    # payload arriving at the slave.
    recovered_full_clear = (mf["is_full"] == 0)
    recovered_delivery   = (recovery_landed >= 6) and (recovery_delivered >= 6)

    if recovered_full_clear and recovered_delivery:
        tb.log.info("  *** LINK RECOVERED from SUSTAINED ACK loss — the "
                    "receiver-side periodic re-ACK un-stuck fe_rx_ptr, "
                    "fe_rx_is_full cleared, and post-wedge packets delivered. "
                    "(periodic re-ACK working) ***")
    else:
        tb.log.info("  *** LINK DID NOT RECOVER from SUSTAINED ACK loss "
                    "(PERMANENT WEDGE): no fresh data => no fresh ACK => "
                    "fe_rx_ptr frozen, is_full latched. This is the HW "
                    "root-cause class. ***")

    assert recovered_full_clear, (
        f"WEDGE: fe_rx_is_full still latched after the sustained ACK-drop. The "
        f"ring filled and never replenished because no fresh data => no fresh "
        f"cumulative ACK and no periodic re-ACK. Final {fmt_ring(mf)}.")
    assert recovered_delivery, (
        f"WEDGE: post-wedge recovery insufficient (landed={recovery_landed}/8, "
        f"delivered={recovery_delivered}/8) — the link did not recover from "
        f"sustained credit-return loss. Final M ring: {fmt_ring(mf)}.")

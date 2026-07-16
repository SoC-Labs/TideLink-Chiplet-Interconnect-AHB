"""V2 multi-packet pktnum-lockstep DIAGNOSIS + FIX GATE (sim-only).

Sends SIXTEEN distinct FC words (one app-word each -> one Wlink long packet,
pktnums 0..15) back-to-back, each carrying a UNIQUE dest byte offset so every
word lands at its own slot in the receiver RX FIFO. Two oracles:

  (1) END-TO-END exactly-once: read back all 16 RX-FIFO offsets and assert
      every sent payload lands at its own offset, byte-exact, no skips.
  (2) L2A replay-FIFO write-pointer NET ADVANCE == 16: the receiver's L2A
      replay buffer must be written exactly 16 times across the whole burst
      (no duplicate enqueues from a replay storm, no missing enqueues).

Plus a cycle-by-cycle trace of TX replay read-pointer (the stamped wire
pktnum) vs RX exp_pkt_num and the commit predicates, and the TX link_revert
storm, to localize any wedge.

This exposes the silicon A->B "only the first wave commits" bug: under a
skewed eye a NACK drives the TX to revert its replay read pointer and replay
from a lower pktnum, while the RX exp_pkt_num was frozen -> permanent
NACK/replay loop (or a double-committing replay storm). The RX-side revert
re-anchor fix (WlinkGenericFCSM_6.v exp_pkt_num always block) must make the
skewed direction deliver every packet exactly once.

Run (clean control, must PASS):  make EPOCH_PROFILE=zero    MODULE=test_v2_multipkt_pktnum
Run (skewed repro/fix gate):      make EPOCH_PROFILE=silicon MODULE=test_v2_multipkt_pktnum TESTCASE=test_s2m_multipkt_commit
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, APB_PKT_WORD_LEN

N_WORDS = 16

# SoC Labs PER-BEAT PKTNUM CAPTURE 2026-07-01 (beatcap) — Region D APB regs
# (SoC MMIO). CAP_CTRL write bit[0]=ARM (any write also resets rptr=0);
# CAP_CTRL read = {0xCB[31:24], frozen[23], wptr[22:17], rptr[16:12], 12'b0}.
# CAP_DATA read returns buffer[rptr] and auto-increments rptr (dump 32x).
APB_CAP_CTRL = 0x21B8
APB_CAP_DATA = 0x21BC
CAP_DEPTH    = 32


def decode_beat(entry):
    """Decode a beatcap 32-bit packed entry (see WlinkGenericFCSM_6.v)."""
    return {
        "pktnum":   (entry >> 24) & 0xFF,
        "exp":      (entry >> 16) & 0xFF,
        "seen":     (entry >> 15) & 1,
        "notseen":  (entry >> 14) & 1,
        "sop":      (entry >> 13) & 1,
        "valid":    (entry >> 12) & 1,
        "isdata":   (entry >> 11) & 1,
        "reanchor": (entry >> 10) & 1,
        "idx":      entry & 0xFF,
    }


async def beatcap_arm(tb, side):
    """Arm the per-beat capture ring on the RECEIVER (dst) side + reset rptr."""
    await tb.apb(side).write(APB_CAP_CTRL, 0x1)   # ARM=1, resets rptr


async def beatcap_dump(tb, side, label):
    """Read CAP_CTRL status then dump all 32 entries (auto-incrementing rptr).
    Returns the list of decoded entries."""
    ctrl = await tb.apb(side).read(APB_CAP_CTRL)
    marker = (ctrl >> 24) & 0xFF
    frozen = (ctrl >> 23) & 1
    wptr   = (ctrl >> 17) & 0x3F
    rptr   = (ctrl >> 12) & 0x1F
    tb.log.info(f"  [{label}] CAP_CTRL=0x{ctrl:08x} marker=0x{marker:02x} "
                f"frozen={frozen} wptr(fill)={wptr} rptr={rptr}")
    # Reset rptr to 0 before the dump (a CAP_CTRL write resets it; keep armed).
    await tb.apb(side).write(APB_CAP_CTRL, 0x1)
    entries = []
    for _ in range(CAP_DEPTH):
        raw = await tb.apb(side).read(APB_CAP_DATA)
        entries.append(raw)
    tb.log.info(f"  [{label}] PER-BEAT CAPTURE (marker=0x{marker:02x}, "
                f"frozen={frozen}, fill={wptr}):")
    decoded = []
    for i, raw in enumerate(entries):
        d = decode_beat(raw)
        decoded.append(d)
        flag = "MATCH" if d["seen"] else ("MISMATCH" if d["notseen"] else "-")
        tb.log.info(f"      beat[{i:2d}] raw=0x{raw:08x} idx={d['idx']:2d} "
                    f"pktnum={d['pktnum']:3d} exp={d['exp']:3d} "
                    f"sop={d['sop']} valid={d['valid']} isdata={d['isdata']} "
                    f"seen={d['seen']} notseen={d['notseen']} "
                    f"reanchor={d['reanchor']} => {flag}")
    return {"frozen": frozen, "wptr": wptr, "marker": marker, "entries": decoded}


def fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


def _g(obj, name):
    return getattr(obj, name, None)


async def trace_pktnum(tb, src, dst, cycles, label):
    """Cycle-by-cycle TX stamp-ptr vs RX exp_pkt_num + the L2A write pointer
    (exactly-once oracle) + the TX link_revert storm."""
    dut = tb.dut
    tx = fcsm(tb, src)
    rx = fcsm(tb, dst)

    tx_curaddr = _g(tx, "a2l_fc_replay_link_cur_addr")
    tx_state   = _g(tx, "state")
    tx_revert  = _g(tx, "a2l_fc_replay_link_revert")

    rx_pktnum  = _g(rx, "ll_rx_pktnum")
    rx_exp     = _g(rx, "exp_pkt_num")
    rx_isdata  = _g(rx, "pkt_is_data_pkt")
    rx_seen    = _g(rx, "exp_pkt_seen")
    rx_notseen = _g(rx, "exp_pkt_not_seen")
    rx_resync  = _g(rx, "socl_l9_resync_now")
    rx_l2aval  = _g(rx, "l2a_fc_replay_app_valid")
    rx_fetxmax = _g(rx, "fe_tx_credit_max")
    rx_lastgood = _g(rx, "last_good_pkt")

    # RX L2A replay-FIFO write side. fifo_io_winc fires on EVERY held-valid
    # cycle (app_ready & app_valid is level), but the FIFO write BINARY POINTER
    # only advances per DISTINCT enqueued word (held re-writes hit the same
    # slot, app_data constant). So the exactly-once oracle is the NET ADVANCE
    # of fifo_io_wbin_ptr (mod 32) over the whole burst, NOT the winc count.
    l2a = _g(rx, "l2a_fc_replay")
    l2a_wptr = _g(l2a, "fifo_io_wbin_ptr") if l2a is not None else None

    # RX framer (WlinkRxLinkLayer llrx): SOP/valid generation internals.
    llrx = _g(tb.top(dst).u_chiplet_controller.u_wlink, "llrx")
    fr_state = _g(llrx, "state") if llrx is not None else None
    fr_valid = _g(llrx, "valid") if llrx is not None else None       # == auto_out_valid == auto_out_sop
    fr_eop   = _g(llrx, "endOfPacket") if llrx is not None else None
    fr_bcnt  = _g(llrx, "byte_count") if llrx is not None else None
    fr_vbr   = _g(llrx, "valid_byte_reg") if llrx is not None else None
    fr_did   = _g(llrx, "auto_out_data_id") if llrx is not None else None

    rx_data = []           # (cyc, pktnum, exp, seen, notseen, resync, l2aval, lastgood)
    framer_rows = []       # (cyc, fr_state, fr_valid, fr_eop, fr_bcnt, fr_did)
    tx_curaddr_changes = []
    tx_revert_pulses = []
    l2a_wptr_advance = 0    # net mod-32 advance of the L2A write pointer
    prev_curaddr = -2
    prev_wptr = _i(l2a_wptr) if l2a_wptr is not None else -1
    for c in range(cycles):
        await RisingEdge(dut.hclk)
        ca = _i(tx_curaddr)
        if ca != prev_curaddr:
            tx_curaddr_changes.append((c, ca))
            prev_curaddr = ca
        if tx_revert is not None and _i(tx_revert) == 1:
            tx_revert_pulses.append(c)
        if l2a_wptr is not None:
            w = _i(l2a_wptr)
            if w != prev_wptr and prev_wptr >= 0 and w >= 0:
                l2a_wptr_advance += (w - prev_wptr) % 32
            prev_wptr = w
        # Capture framer whenever its valid is high (one row per asserted cycle).
        if fr_valid is not None and _i(fr_valid) == 1:
            framer_rows.append((c, _i(fr_state), _i(fr_valid), _i(fr_eop),
                                _i(fr_bcnt), _i(fr_did),
                                _i(rx_pktnum), _i(rx_exp), _i(rx_seen)))
        if rx_isdata is not None and _i(rx_isdata) == 1:
            rx_data.append((c, _i(rx_pktnum), _i(rx_exp), _i(rx_seen),
                            _i(rx_notseen), _i(rx_resync), _i(rx_l2aval),
                            _i(rx_lastgood)))

    tb.log.info(f"  [{label}] TX cur_addr(rbin_ptr) changes (cyc,val): "
                f"{tx_curaddr_changes}")
    tb.log.info(f"  [{label}] TX link_revert asserted at cyc: "
                f"{tx_revert_pulses[:40]} (total={len(tx_revert_pulses)})")
    tb.log.info(f"  [{label}] RX L2A write-ptr net advance (distinct enqueues) "
                f"={l2a_wptr_advance}")
    # DOUBLE-ADVANCE detector: within one contiguous framer valid-assert run
    # (SOP/valid held high continuously), how many distinct pktnums MATCHED
    # (seen=1)? The coordinator's hypothesised bug = the SAME held SOP window
    # accepts 2+ packets -> exp double-advances for one delivered word. Group
    # framer_rows into contiguous runs and count matched pktnums per run.
    if framer_rows:
        dbl = []
        run_start = framer_rows[0][0]
        run_matched_pktnums = set()
        prev_c = framer_rows[0][0] - 1
        for row in framer_rows:
            c, st, v, eop, bc, did, pn, ex, sn = row
            if c != prev_c + 1:
                if len(run_matched_pktnums) >= 2:
                    dbl.append((run_start, prev_c, sorted(run_matched_pktnums)))
                run_start = c
                run_matched_pktnums = set()
            if sn == 1:
                run_matched_pktnums.add(pn)
            prev_c = c
        if len(run_matched_pktnums) >= 2:
            dbl.append((run_start, prev_c, sorted(run_matched_pktnums)))
        tb.log.info(f"  [{label}] MULTI-MATCH-PER-VALID-RUN windows "
                    f"(start,end,matched_pktnums) [>=2 = held SOP consumed "
                    f"multiple packets]: {dbl[:20]}")
    # Framer valid-assert runs: group consecutive asserted cycles to see if any
    # packet's valid/SOP is held > 1 cycle.
    if framer_rows:
        runs = []
        run_start = framer_rows[0][0]
        prev_c = framer_rows[0][0] - 1
        for row in framer_rows:
            c = row[0]
            if c != prev_c + 1:
                runs.append((run_start, prev_c, prev_c - run_start + 1))
                run_start = c
            prev_c = c
        runs.append((run_start, prev_c, prev_c - run_start + 1))
        tb.log.info(f"  [{label}] FRAMER valid-assert runs (start,end,len) "
                    f"[len>1 = SOP held multi-cycle]: {runs[:40]}")
        # Within the held-valid window, does the WIRE pktnum change while
        # valid/SOP stays high? That is the harmful case (same SOP, many pktnums).
        tb.log.info(f"  [{label}] FRAMER detail (collapsed on pktnum change) "
                    f"(cyc,state,valid,eop,byte_count,data_id,pktnum,exp,seen):")
        prev_pn = None
        shown = 0
        for row in framer_rows:
            c, st, v, eop, bc, did, pn, ex, sn = row
            if pn == prev_pn:
                continue
            prev_pn = pn
            shown += 1
            if shown > 40:
                break
            tb.log.info(f"      cyc={c:5d} state={st} valid={v} eop={eop} "
                        f"byte_count={bc} data_id=0x{did:02x} "
                        f"pktnum={pn} exp={ex} seen={sn}")
    tb.log.info(f"  [{label}] RX data-pkt decodes "
                f"(cyc, pktnum, exp, lastgood, seen, notseen, resync, l2aval):")
    prev_key = None
    for c, pn, ex, sn, ns, rs, l2, lg in rx_data:
        key = (pn, ex, lg, sn, l2)
        if key == prev_key:
            continue
        prev_key = key
        flag = "MATCH" if sn else ("RESYNC" if rs else "MISMATCH")
        tb.log.info(f"      cyc={c:5d} pktnum={pn:3d} exp={ex:3d} lastgood={lg:3d} "
                    f"seen={sn} notseen={ns} resync={rs} l2a_valid={l2} => {flag}"
                    f"{' COMMIT' if l2 else ''}")
    return rx_data, tx_revert_pulses, l2a_wptr_advance


def fc_word(addr_offset, payload):
    """FC FIFO_DATA word: pkt_type(0)|addr_offset[13:0]|payload[31:0]."""
    return ((addr_offset & 0x3FFF) << 32) | (payload & 0xFFFFFFFF)


async def _multipkt_run(tb, src, dst, label, fault=None, settle=6000,
                        trace_cycles=8000, enable_crc=False, armcap=False):
    dut = tb.dut
    if enable_crc:
        # Force CRC checking ON at the receiver (default reset value is OFF,
        # disable_crc=1). With CRC on, a payload-corrupted word fails CRC ->
        # NACK -> clean replay.
        try:
            fcsm(tb, dst).out_prepend_swi_disable_crc.value = 0
            await ClockCycles(dut.hclk, 5)
            tb.log.info(f"  [{label}] receiver CRC checking ENABLED")
        except Exception as e:
            tb.log.warning(f"could not enable CRC on {dst}: {e}")

    # 16 distinct words, each at its OWN dest byte offset 0,4,..,0x3C, with a
    # unique payload -> each lands at a distinct RX-FIFO slot so end-to-end
    # delivery is checkable per word (no overwrite).
    payloads = [0xA5A50000 + (i << 8) + i for i in range(N_WORDS)]

    # SoC Labs beatcap: arm the RECEIVER's per-beat capture ring BEFORE the
    # burst so the first 32 valid RX beats of this A->B send are recorded.
    if armcap:
        await beatcap_arm(tb, dst)
        tb.log.info(f"  [{label}] per-beat capture ARMED on receiver '{dst}'")

    tracer = cocotb.start_soon(
        trace_pktnum(tb, src, dst, cycles=trace_cycles, label=label))

    # Optional transient fault driver, started concurrently with the burst.
    if fault is not None:
        cocotb.start_soon(fault(tb))

    # Drive the sender's AHB FC-TX aperture back-to-back (gap=0): the writer
    # maps AHB word i -> dest byte offset i*4, and the Wlink LL framer packs
    # adjacent FC words into back-to-back long packets (pktnums 0..N-1). Each
    # word carries its own dest offset so it lands at a distinct RX-FIFO slot.
    await tb.ahb_tx_write_packet_b2b(src, payloads)
    await ClockCycles(dut.hclk, settle)

    rx_data, revert_pulses, l2a_adv = await tracer

    # ---- beatcap: dump the per-beat capture ring + validate the instrument ----
    if armcap:
        cap = await beatcap_dump(tb, dst, label)
        # The instrument must have captured SOMETHING (buffer filled). On a clean
        # 16-word burst the receiver sees 16 held-valid data beats (+ any credit/
        # idle beats), so the 32-deep ring should FREEZE (wptr=32) with a
        # decodable, marker-correct sequence. This proves per-beat visibility;
        # it does NOT (and cannot) show the silicon 5x over-advance on clean sim.
        assert cap["marker"] == 0xCB, (
            f"{label}: beatcap CAP_CTRL marker=0x{cap['marker']:02x} != 0xCB "
            f"(instrument not wired / not V2)")
        # Count the distinct MATCH beats (seen=1): on a clean lockstep link every
        # data packet matches exp exactly once, so the matched pktnum sequence
        # should be 2,3,4,... (pktnums 0/1 are CR/CRACK bring-up; data starts ~2).
        matched = [d["pktnum"] for d in cap["entries"] if d["seen"]]
        tb.log.info(f"  [{label}] beatcap matched pktnum sequence (seen=1): "
                    f"{matched}")
        # Sanity: exp is monotonic non-decreasing across the captured data beats
        # (a clean link never walks exp backward). Report any regressions.
        data_beats = [d for d in cap["entries"] if d["isdata"]]
        exp_seq = [d["exp"] for d in data_beats]
        tb.log.info(f"  [{label}] beatcap exp sequence over data beats: {exp_seq}")
        assert cap["wptr"] > 0, (
            f"{label}: beatcap captured 0 beats (arm/valid wiring broken)")

    # ---- Oracle (1): END-TO-END exactly-once, read all 16 RX-FIFO offsets ----
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(N_WORDS)]
    tb.log.info(f"  [{label}] RX FIFO readback [0..{N_WORDS-1}]: "
                f"[{', '.join(f'0x{w:08x}' for w in got)}]")
    tb.log.info(f"  [{label}] expected payloads:                "
                f"[{', '.join(f'0x{w:08x}' for w in payloads)}]")
    missing = [i for i in range(N_WORDS) if got[i] != payloads[i]]

    # ---- Oracle (2): exactly-once via L2A write-pointer net advance ----
    # A clean delivery advances the L2A write pointer exactly N_WORDS slots. A
    # replay storm that double-enqueues advances MORE; a wedge advances FEWER.
    tb.log.info(f"  [{label}] SUMMARY: l2a_wptr_advance={l2a_adv} "
                f"(expect {N_WORDS}) revert_cy={len(revert_pulses)} "
                f"missing_offsets={missing}")

    # WEDGE detector (diagnosis aid): exp frozen while >=3 distinct pktnums miss.
    mism = set((r[1], r[2]) for r in rx_data if r[4] == 1 and r[5] == 0)
    frozen = {}
    for pn, ex in mism:
        frozen.setdefault(ex, set()).add(pn)
    wedged = {ex: sorted(p) for ex, p in frozen.items() if len(p) >= 3}
    if wedged:
        tb.log.info(f"  [{label}] WEDGE: exp_pkt_num frozen -> {wedged}")

    # ---- Assertions ----
    assert not missing, (
        f"{label}: end-to-end delivery FAILED at offsets {missing}: "
        f"got {[hex(got[i]) for i in missing]} "
        f"expected {[hex(payloads[i]) for i in missing]}")
    assert l2a_adv == N_WORDS, (
        f"{label}: L2A write-ptr advanced {l2a_adv} slots, expected EXACTLY "
        f"{N_WORDS} -> {'DUPLICATE enqueues (replay storm)' if l2a_adv > N_WORDS else 'MISSING enqueues (wedge)'}. "
        f"wedged={wedged}")


@cocotb.test()
async def test_a2b_multipkt_commit(dut):
    """M->S (the clean direction under EPOCH_PROFILE=silicon)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _multipkt_run(tb, "m", "s", "a2b-16w", armcap=True)


@cocotb.test()
async def test_s2m_multipkt_commit(dut):
    """S->M (the skewed direction under EPOCH_PROFILE=silicon — the repro)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _multipkt_run(tb, "s", "m", "s2m-16w")


# ---------------------------------------------------------------------------
# Isolation rig: EPOCH_PROFILE=zero + EYE_FAULT=1. A clean whole-word link
# (no offset/payload skew) with a cocotb-pulsed TRANSIENT eye corruption on
# the S->M path (u_eye_s2m), so we can force ONE early NACK -> TX revert/replay
# WITHOUT permanently mangling the data. This isolates the FC replay LOGIC
# (the pktnum-lockstep wedge / double-commit) from the eye. A correct link
# must self-heal: every word delivered byte-exact, exactly once.
#
# Build:  make EPOCH_PROFILE=zero EYE_FAULT=1 MODULE=test_v2_multipkt_pktnum \
#              TESTCASE=test_s2m_transient_nack_recovers
# ---------------------------------------------------------------------------
async def _transient_eye_burst(tb):
    """Pulse a few-cycle multi-lane corruption shortly after the burst starts,
    to corrupt the first long packet's content -> CRC/NACK on the consumer ->
    TX replay. Then go clean so the replay delivers correctly."""
    dut = tb.dut
    eye = getattr(dut, "u_eye_s2m", None)
    if eye is None:
        tb.log.warning("u_eye_s2m not present (build without EYE_FAULT=1)")
        return
    # wait until the first data words are on the wire
    await ClockCycles(dut.hclk, 60)
    eye.err_mask.value   = 0xFF      # all lanes
    eye.err_burst.value  = 6         # >EPOCH_MATCH_THRESH and >CRC tolerance
    eye.err_period.value = 8         # fire repeatedly...
    eye.err_en.value     = 1
    await ClockCycles(dut.hclk, 80)  # ...for a bounded window only
    eye.err_en.value     = 0
    eye.err_period.value = 0
    tb.log.info("  [transient] eye fault window closed; link now clean")


@cocotb.test()
async def test_s2m_transient_nack_recovers(dut):
    """LOGIC-isolation gate: a transient NACK/replay on a clean link must
    recover to byte-exact, exactly-once delivery of all 16 words."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _multipkt_run(tb, "s", "m", "s2m-transient",
                        fault=_transient_eye_burst, settle=12000,
                        trace_cycles=16000)


@cocotb.test()
async def test_s2m_transient_nack_recovers_crc(dut):
    """Same transient-NACK isolation rig but with receiver CRC ENABLED. A
    payload-corrupted word must fail CRC (not commit as valid), get NACK'd,
    and be replayed clean -> all 16 words byte-exact, exactly once."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _multipkt_run(tb, "s", "m", "s2m-transient-crc",
                        fault=_transient_eye_burst, settle=12000,
                        trace_cycles=16000, enable_crc=True)

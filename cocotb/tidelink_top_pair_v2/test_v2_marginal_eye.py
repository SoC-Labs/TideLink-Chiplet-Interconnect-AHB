"""MARGINAL-EYE anchor-ON reproduction (silicon condition).

The clean whole-word `pad_skid` skew is corrected by EPOCH_ANCHOR_EN=1 — the
silicon profile PASSES in sim. But deployed silicon (anchor ON) still loses
S->M data. The missing ingredient is the MARGINAL EYE: per-lane bit errors
that corrupt the TRAINING-EXIT CONTENT EDGE the anchor keys on (and/or
sustained data). This module drives the `eye_fault` injector (compile with
EYE_FAULT=1) to inject those bit errors WITH THE ANCHOR ON, and probes the
anchor internals (tidelink_lane_deskew.sv) during the failure.

Run:
  make EPOCH_PROFILE=silicon EYE_FAULT=1 MODULE=test_v2_marginal_eye

Lesson from sustained injection: corrupting lanes for the WHOLE bring-up
breaks the per-lane training CHECKER (cal_done never asserts) -> that's a
training failure, NOT the epoch class. The faithful marginal-eye model is a
SHORT error window placed at the training-exit edge: training stays green,
only the anchor's exit-detection is corrupted. These tests bring up CLEAN,
then fire a targeted error window across the data-mode (training-exit)
transition.

The anchor lives on the MASTER's RX (S->M skewed direction); we probe and
corrupt u_master's deskew.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, send_and_check, ST_LANE_LOCKED, ST_CAL_DONE, APB_PKT_WORD_LEN,
)


# ---- hierarchical paths to the injector + anchor internals -----------------
def eye(dut):
    return dut.u_eye_s2m


def deskew(tb):
    return tb.top("m").u_chiplet_controller.u_wlink.phy.gpio.u_deskew


_WALK_CACHE = {}


def _walk(h, depth=0, maxd=3):
    """Map full relative dotted leaf/array names -> handle. cocotb 2.0.1
    generate-array blocks are NOT reachable by getattr/_id with a bracketed
    name nor by int subscript on the array object, but ARE yielded by
    iteration with their full relative dotted ._name (e.g.
    'g_lane_write[1].g_epoch_capture.ep_anchor_idx'). Build that map once."""
    out = {}
    try:
        for c in h:
            out[c._name] = c
            if depth < maxd:
                out.update(_walk(c, depth + 1, maxd))
    except Exception:
        pass
    return out


def _map(tb):
    d = deskew(tb)
    key = id(d)
    if key not in _WALK_CACHE:
        _WALK_CACHE[key] = _walk(d)
    return _WALK_CACHE[key]


def anchor_probe(tb):
    m = _map(tb)
    d = deskew(tb)
    out = {}

    def rd(name):
        h = m.get(name)
        if h is None:
            return None
        try:
            return int(h.value)
        except Exception:
            return None

    def rd_arr(name, gi):
        h = m.get(name)
        if h is None:
            return None
        try:
            return int(h[gi].value)
        except Exception:
            return None

    # Top-level observable ports (direct on the deskew handle).
    for nm, key in (("epoch_anchored_o", "anchored"), ("epoch_span_o", "span")):
        try:
            out[key] = int(getattr(d, nm).value)
        except Exception:
            pass
    # Per-lane write-side capture.
    for gi in range(8):
        for nm, key in (("ep_streak", "streak"), ("ep_anchor_idx", "idx"),
                        ("ep_anchor_cnt", "cnt")):
            v = rd(f"g_lane_write[{gi}].g_epoch_capture.{nm}")
            if v is not None:
                out[f"{key}{gi}"] = v
    # Read-side application scalars.
    for nm, key in (("ep_all_fresh", "all_fresh"), ("ep_apply", "apply"),
                    ("ep_settle_ctr", "settle"), ("epoch_anchored", "anch2"),
                    ("ep_max_d", "maxd")):
        v = rd(f"g_epoch.{nm}")
        if v is not None:
            out[key] = v
    # Read-side application arrays.
    for arr, key in (("lane_off_e", "off"), ("ep_idx_sync1", "idxs"),
                     ("ep_delta", "dlt"), ("ep_applied_cnt", "acnt")):
        for gi in range(8):
            v = rd_arr(f"g_epoch.{arr}", gi)
            if v is not None:
                # ep_delta is signed PW-bit; interpret two's-complement (PW=6).
                if key == "dlt" and v >= (1 << 5):
                    v -= (1 << 6)
                out[f"{key}{gi}"] = v
    # ep_fresh is a per-lane bit vector (LANES wide), not an indexable array.
    v = rd("g_epoch.ep_fresh")
    if v is not None:
        out["fresh_mask"] = v
    return out


def log_anchor(tb, label):
    p = anchor_probe(tb)
    if not p:
        tb.log.info(f"  [anchor {label}] <not reachable>")
        return p
    g = lambda k: [p.get(f"{k}{i}", "-") for i in range(8)]
    fm = p.get('fresh_mask')
    fm_s = f"0x{fm:02x}" if isinstance(fm, int) else "?"
    tb.log.info(
        f"  [anchor {label}] anchored={p.get('anchored','?')} "
        f"span={p.get('span','?')} all_fresh={p.get('all_fresh','?')} "
        f"fresh_mask={fm_s} apply={p.get('apply','?')} "
        f"settle={p.get('settle','?')} max_d={p.get('maxd','?')}")
    tb.log.info(f"      WR ep_anchor_idx (per-lane wr idx of 1st data word) ={g('idx')}")
    tb.log.info(f"      WR ep_anchor_cnt (freshness counter)                ={g('cnt')}")
    tb.log.info(f"      WR ep_streak     (consec pattern matches)           ={g('streak')}")
    tb.log.info(f"      RD ep_idx_sync1  (synced anchor idx, read side)     ={g('idxs')}")
    tb.log.info(f"      RD ep_delta      (idx vs lane0)                     ={g('dlt')}")
    tb.log.info(f"      RD ep_applied_cnt(cnt consumed at last apply)       ={g('acnt')}")
    tb.log.info(f"      RD lane_off_e    (APPLIED per-lane backward offset) ={g('off')}")
    return p


def set_eye(dut, en, mask=0x00, burst=0, period=0):
    e = eye(dut)
    e.err_en.value = 1 if en else 0
    e.err_mask.value = mask & 0xFF
    e.err_burst.value = burst & 0xF
    e.err_period.value = period & 0xFFFF


# ---- bring-up that clean-trains, then injects across the training exit ------
async def bringup_with_exit_window(tb, mask, burst, period, pre_cycles=0,
                                    window_cycles=4000):
    """POR->role_lock->autocal(CLEAN)->[arm eye]->to_data_mode->[disarm].

    The eye is OFF through autocal (training stays green / cal_done=1). It is
    armed `pre_cycles` hclk before do_to_data_mode (the training-exit edge)
    and held `window_cycles` hclk, then disarmed. Returns the phase-1 snap."""
    from pair_v2_common import run_bringup_full  # not used; we inline below
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    set_eye(tb.dut, en=False)
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert"
    m_p1, s_p1 = await tb.wait_cal_done()
    tb.log.info(f"  post-autocal (CLEAN eye): M=0x{m_p1:08x} S=0x{s_p1:08x}")
    # Arm the eye just before the training-exit edge.
    if pre_cycles:
        await ClockCycles(tb.dut.hclk, pre_cycles)
    set_eye(tb.dut, en=True, mask=mask, burst=burst, period=period)
    tb.log.info(f"  [eye ARMED] mask=0x{mask:02x} burst={burst} period={period} "
                f"across training-exit / data window")
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, window_cycles)
    set_eye(tb.dut, en=False)
    tb.log.info("  [eye DISARMED]")
    snap = await tb.snapshot("after to_data_mode (eye window done)")
    snap["m_p1"], snap["s_p1"] = m_p1, s_p1
    return snap


@cocotb.test()
async def test_baseline_injector_off(dut):
    """Sanity: injector present but idle -> silicon profile still PASSES."""
    from pair_v2_common import run_bringup_full
    tb = PairV2TB(dut)
    set_eye(dut, en=False)
    snap = await run_bringup_full(tb)
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        assert ST_CAL_DONE(st) == 1, f"{name}: cal_done=0"
        assert ST_LANE_LOCKED(st) == 0xFF, f"{name}: locked!=0xFF"
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"
    log_anchor(tb, "injector-off post-bringup")
    await ClockCycles(dut.hclk, 500)
    ok, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                   ctx="eye-off s2m", expect_pass=False)
    log_anchor(tb, "injector-off post-data")
    assert ok, f"injector-off baseline FAILED (anchor should correct): {got}"
    tb.log.info("BASELINE OK: anchor corrects clean skew, S->M perfect")


async def _run_exit_window(dut, mask, burst, period, tag):
    tb = PairV2TB(dut)
    snap = await bringup_with_exit_window(tb, mask, burst, period)
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        tb.log.info(f"  {name} phase1 (clean autocal): cal_done={ST_CAL_DONE(st)} "
                    f"locked=0x{ST_LANE_LOCKED(st):02x}")
    cr = await tb.wait_cr_crack(max_cycles=20000)
    tb.log.info(f"  [{tag}] CR/CRACK bilateral={cr}")
    log_anchor(tb, f"{tag} post-bringup")
    await ClockCycles(dut.hclk, 500)
    ok, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                   ctx=f"{tag} s2m", expect_pass=False)
    p = log_anchor(tb, f"{tag} post-data")
    pkt_len = await tb.apb("m").read(APB_PKT_WORD_LEN)
    tb.log.info(f"  [{tag}] master PKT_WORD_LEN after S->M = 0x{pkt_len:x}")
    if not ok:
        tb.log.info(
            f"*** REPRODUCED [{tag}] (anchor ON): S->M corrupt/undelivered "
            f"under exit-window bit errors. got={['0x%08x'%w for w in got]} "
            f"anchored={p.get('anchored','?')} span={p.get('span','?')}")
    else:
        tb.log.info(f"[{tag}] anchor survived; S->M perfect "
                    f"(anchored={p.get('anchored','?')} span={p.get('span','?')})")
    return ok, got, p


# Clean-skew baseline anchor offsets (silicon profile, EPOCH_ANCHOR_EN=1).
# The whole-word epoch profile is S2M_L = [3,7,5,4,6,3,7,5]; the anchor
# measures deltas vs lane0 and applies lane_off_e = max_delta - delta.
CLEAN_OFFSETS = [4, 0, 2, 3, 1, 4, 0, 2]


@cocotb.test()
async def test_exit_window_1lane_burst5(dut):
    """REPRO (anchor ON): one lane (L1), 5-bit burst/word across the exit.
    >3 flips/word makes a LATE training word read as a NON-match while L1's
    streak is still >=8 -> L1 latches ep_anchor_idx EARLY -> wrong delta ->
    wrong lane_off_e -> garbled assembled FC word -> no commit."""
    ok, got, p = await _run_exit_window(dut, mask=0x02, burst=5, period=16,
                                        tag="1L-b5")
    assert not ok, ("anchor corrected the marginal-eye exit edge — repro "
                    "lost (expected mis-anchor garble)")
    offs = [p.get(f"off{i}") for i in range(8)]
    assert offs != CLEAN_OFFSETS, \
        f"offsets unchanged {offs}; the anchor was not mis-latched"
    assert p.get("anchored") == 1, "anchor must still report engaged (it THINKS it won)"
    dut._log.info(f"GATE 1L-b5: mis-anchored offsets={offs} (clean={CLEAN_OFFSETS})")


@cocotb.test()
async def test_exit_window_3lane_burst5(dut):
    """REPRO (anchor ON): three lanes (1,4,6), 5-bit burst/word across exit."""
    ok, got, p = await _run_exit_window(dut, mask=0x52, burst=5, period=16,
                                        tag="3L-b5")
    assert not ok, "anchor corrected 3-lane marginal eye — repro lost"
    offs = [p.get(f"off{i}") for i in range(8)]
    assert offs != CLEAN_OFFSETS, f"offsets unchanged {offs}"
    dut._log.info(f"GATE 3L-b5: mis-anchored offsets={offs} (clean={CLEAN_OFFSETS})")


@cocotb.test()
async def test_exit_window_1lane_burst4_sparse(dut):
    """SURVIVE-CONTROL: one lane, 4-bit burst every 4 words. A sparser BER
    that does NOT land a >3-flip word on the final training words ->
    anchor latches correctly -> S->M intact. Proves the failure is a genuine
    eye-margin effect, not a sledgehammer (the anchor is robust to light
    noise; it breaks specifically when the EXIT EDGE is corrupted)."""
    ok, got, p = await _run_exit_window(dut, mask=0x02, burst=4, period=64,
                                        tag="1L-b4-sp")
    assert ok, ("sparse BER also broke S->M — the failure is not specific to "
                "the exit-edge corruption (re-tune the margin)")
    dut._log.info("SURVIVE-CONTROL 1L-b4-sp: light BER tolerated, S->M intact")


# ---------------------------------------------------------------------------
# MECHANISM-2 repro: sustained DATA-WINDOW eye (the actual silicon blocker).
# Distinct from the anchor mis-latch above (which fix3 already corrects -> those
# exit-window tests now FAIL = data succeeds). Here the anchor latches CLEAN
# (eye OFF through bring-up), THEN the eye is armed DURING the data send so
# per-beat bit errors corrupt the DATA PACKET itself. On today's RAW link (ECC
# bypassed, CRC off, no replay) a corrupted data beat -> no commit -> the exact
# silicon symptom (die_b STATUS not committed, RX FIFO empty, sender fe_full).
#
# This is the GATE for the reliability re-enable (un-bypass ECC + disable_crc=0
# + working replay): with that layer ON this test should flip to PASS because
# the eye errors are SEC-corrected / NACK-retried. DO the re-enable sim-first
# against THIS test before any silicon build (a prior reliability change caused
# a PS kernel-hang — never deploy a reliability change unvalidated).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_data_window_eye_s2m(dut):
    """Anchor latches clean, then eye armed across the S->M data send: a RAW
    link must DROP the packet (no commit). Asserts the repro (not ok). When the
    Wlink reliability layer is re-enabled this should become PASS."""
    from pair_v2_common import run_bringup_full
    tb = PairV2TB(dut)
    set_eye(dut, en=False)
    await run_bringup_full(tb)                     # CLEAN bring-up -> anchor correct
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    # Arm sustained per-beat errors on active lanes DURING the send (not the
    # exit edge). Dense burst so the brief data window is reliably corrupted.
    set_eye(dut, en=True, mask=0x24, burst=3, period=4)
    tb.log.info("  [data-window-eye] eye ARMED across S->M data send "
                "(mask=0x24 burst=3 period=4)")
    ok, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                   ctx="data-window-eye s2m", expect_pass=False)
    set_eye(dut, en=False)
    tb.log.info(f"  [data-window-eye] ok={ok} got={['0x%08x' % w for w in got]}")
    if not ok:
        tb.log.info("*** MECHANISM-2 REPRODUCED: RAW link drops the data packet "
                    "under a data-window eye (= the silicon blocker). Re-enable "
                    "ECC+CRC+replay and re-run this test to verify the fix.")
    assert not ok, ("data survived the data-window eye on a RAW link — repro "
                    "lost (eye too light, OR reliability is somehow already "
                    "masking it). Re-tune mask/burst/period.")


def _mfcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _mwlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


async def _probe_rx_reliability(tb, dst, cycles, label):
    """Sample the receiver's framer + FCSM + commit while a packet crosses, to
    see WHERE a corrupted long packet dies: header mis-classify (no llrx valid /
    wrong data_id) vs payload CRC error (valid + crc_errors + NACK state)."""
    dut = tb.dut
    w = _mwlink(tb, dst)
    f = _mfcsm(tb, dst)
    llrx = getattr(w, "llrx", None)
    try:
        fc_ctrl = tb.top(dst).u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl
    except Exception:
        fc_ctrl = None

    def gi(obj, name):
        h = getattr(obj, name, None)
        if h is None:
            return None
        try:
            return int(h.value)
        except Exception:
            return None

    seen_did, seen_st = set(), set()
    max_crc, val_cy, wc_cy, nack_cy = 0, 0, 0, 0
    dcrc = None
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        if llrx is not None and gi(llrx, "auto_out_valid") == 1:
            val_cy += 1
            d = gi(llrx, "auto_out_data_id")
            if d is not None:
                seen_did.add(d)
        c = gi(f, "crc_errors")
        if c is not None and c > max_crc:
            max_crc = c
        s = gi(f, "state")
        if s is not None:
            seen_st.add(s)
            if s in (6, 7):
                nack_cy += 1
        dcrc = gi(f, "out_prepend_swi_disable_crc")
        if fc_ctrl is not None and gi(fc_ctrl, "write_complete") == 1:
            wc_cy += 1
    tb.log.info(
        f"  [{label}] PROBE: llrx_valid_cy={val_cy} "
        f"data_ids={[hex(x) for x in sorted(seen_did)]} max_crc_errors={max_crc} "
        f"fcsm_states={sorted(seen_st)} nack_state_cy={nack_cy} "
        f"write_complete_cy={wc_cy} disable_crc={dcrc}")


def set_disable_crc(tb, side, val):
    """Force the FCSM's disable_crc arm (APB bit16 path). val=0 turns CRC ON."""
    try:
        _mfcsm(tb, side).out_prepend_swi_disable_crc.value = val
        tb.log.info(f"  disable_crc[{side}]={val}")
    except Exception as e:                              # noqa: BLE001
        tb.log.warning(f"set disable_crc[{side}] failed: {e}")


@cocotb.test()
async def test_data_eye_crc_replay_s2m(dut):
    """RELIABILITY-FIX candidate (the actual fix experiment).

    Clean bring-up (anchor latches correct), enable CRC on BOTH dies
    (disable_crc=0), then corrupt ONLY the first transmission window with a
    one-shot eye and go clean. If the Wlink NACK->replay path works, the
    payload-corrupted first packet is detected by CRC, NACK'd, and retransmitted
    intact -> data DELIVERS. This models an intermittent marginal eye (the
    silicon reality: CR/CRACK get through, so some windows ARE clean). PASS here
    (ok=True) is the sim proof that re-enabling CRC+replay is the data fix and
    needs no ECC decoder fix."""
    from pair_v2_common import run_bringup_full
    tb = PairV2TB(dut)
    set_eye(dut, en=False)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"
    set_disable_crc(tb, "m", 0)
    set_disable_crc(tb, "s", 0)
    await ClockCycles(dut.hclk, 50)
    set_eye(dut, en=True, mask=0x24, burst=3, period=4)
    tb.log.info("  [crc-replay] CRC ON + one-shot eye over first transmit")

    async def _disarm_after(n):
        await ClockCycles(dut.hclk, n)
        set_eye(dut, en=False)
        tb.log.info(f"  [crc-replay] eye DISARMED after {n}cy -> retries clean")

    cocotb.start_soon(_disarm_after(500))
    cocotb.start_soon(_probe_rx_reliability(tb, "m", 2800, "crc-replay"))
    ok, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                   ctx="crc-replay s2m", expect_pass=False)
    set_eye(dut, en=False)
    tb.log.info(f"  [crc-replay] ok={ok} got={['0x%08x' % w for w in got]}")
    if ok:
        tb.log.info("*** CRC+REPLAY RECOVERS the data after a corrupted first "
                    "transmit -> reliability re-enable (CRC on, no ECC) is the FIX.")
    else:
        tb.log.info("XXX CRC+replay did NOT recover -> header ECC needed and/or "
                    "replay loop broken; next probe send_nack_req + replay FIFO.")

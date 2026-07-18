"""F14-B follow-up (lane Z-D) — FINE-GRAINED RECOVERY LADDER + WEDGE DETECTION.

Y-C's `classify_recovery` (errinj_common.py) has three rungs:

    no action  ->  SW re-bringup (to_data_mode + CR/CRACK)  ->  full POR of BOTH dies

and its last rung ALSO re-runs autocal, so it cannot separate "the power and
reset domain had to be cycled" from "the PHY merely had to retrain". That
distinction is the whole product question: a PHY retrain is reachable from
firmware over APB with the chiplet in the field; a POR is a bench trip.

This module inserts the missing rungs. It is additive — `errinj_common` is
untouched and its existing tests keep their verdict taxonomy.

R8 slot0 (APB 0x2100) bit map — src/rtl/local_overrides/axi_chiplet_controller.sv
  [0] SWI_TRAINING_MODE       drives the PHY training pattern
  [1] SWI_RECAL               LEVEL -> tidelink_phy_align_calibrator.swreset
                              (:1435). The FALLING edge re-triggers a fresh
                              sweep with role_locked still high (:575) — a PHY
                              retrain with no POR and no role_lock loss.
  [2] SWI_SYNC_INSERT_EN      enable the V2 PHY SYNC-beacon inserter
  [3] SWI_SYNC_FORCE_ALWAYS   drop the tx_idle gate so the beacon can fire in
                              DATA mode (otherwise it is idle-gated and
                              essentially never fires mid-stream)
  [4] SWI_SYNC_ROBUST_DETECT  let the mask-aware per-lane detector drive the
                              framer re-hunt (the legacy full-128 exact compare
                              does not fire on a real eye)
  [5] SWI_SYNC_OBS_CLR        W1 pulse: clear the sticky SYNC observation regs

CORRECTION TO THE F14-B MECHANISM (load-bearing for rung b):
docs/ERROR_INJECTION_FINDINGS.md §F14-B states "the deskew re-anchor is
compiled off (SYNC_REANCHOR_EN default 1'b0, tidelink_lane_deskew_v2.sv:201)".
:201 is the MODULE DEFAULT. The built V2 PHY overrides it — WavD2DGpio_v2.v:790
instantiates the deskew with `.SYNC_REANCHOR_EN(1'b1)` (and .SYNC_REANCHOR_TOL(5)),
and the surrounding comment says so explicitly ("SYNC_REANCHOR stays ON"). The
cross-lane re-anchor hardware is therefore PRESENT AND ARMED in every V2 build.
It is starved of beacon, not disabled. That is why rung (b) is worth testing at
all, and it changes the RTL proposal in the write-up.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    APB_R8_SLOT0, APB_R8_SWI_LANE_STATUS, APB_WL_LINK_ENABLE_RESET,
    LL_BOOTSTRAP_SWRESET_ON, LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE,
    ST_CAL_DONE, ST_CR_SEEN, ST_CRACK_SEEN,
)
from errinj_common import (
    link_healthy, ll_swreset_one_die, reset_one_die, rebringup_after_reset,
    full_por_rebringup, crc_snapshot,
)

R8_TRAIN        = 1 << 0
R8_RECAL        = 1 << 1
R8_SYNC_EN      = 1 << 2
R8_SYNC_FORCE   = 1 << 3
R8_SYNC_ROBUST  = 1 << 4
R8_SYNC_OBS_CLR = 1 << 5

# The on-silicon escape-hatch beacon word (the proven KR260 recipe is
# `0x210C=0` THEN `R8=0x1C`; 0x210C is autonomy-disarm and is already 0 here
# because this bench runs BYPASS_AUTONEG=1, so R8 writes are authoritative).
R8_BEACON_FULL = R8_SYNC_EN | R8_SYNC_FORCE | R8_SYNC_ROBUST      # 0x1C

# Region 9/10 observability — every one of these is APB-readable, i.e.
# firmware-reachable on silicon through the same 0x4403_2xxx (Z2) /
# 0x8403_2xxx (KR260) window the bring-up scripts already use.
APB_SYNC_OBS_TX    = 0x2120   # [15:0] TX SYNC-insert sat. count, [31:24]=0x5C
APB_SYNC_OBS_RX    = 0x2124   # [15:0] RX SYNC-detect count, [23:16] per-lane sticky
APB_SYNC_LANE_MASK = 0x2128   # RW [7:0] lane mask, [12:8] Hamming tol
APB_EPOCH_STATUS   = 0x2140   # [0] reanchored, [6:1] span
APB_SYNC_LANE_LIVE = 0x2144   # [7:0] live per-lane match — SATURATES, see doc


# ---------------------------------------------------------------------------
# Stale-proof health check
# ---------------------------------------------------------------------------
# errinj_common.link_healthy() sends the SAME fixed payloads every call. A word
# left in the RX FIFO by an earlier call can therefore be re-read and scored as
# a fresh delivery — the exact confound Y-C called out in
# docs/ERROR_INJECTION_FINDINGS.md §2.3 ("a stale RX-FIFO word can masquerade as
# a delivery"), and it was OBSERVED in the first ladder run: the W3 health check
# read back 0xbeef0001/0xf00d0002, W1's payload, from a previous test.
#
# For a ladder that walks rungs in order this matters enormously: a stale word
# would score a rung as "recovered" and stop the walk early, inventing a
# cheaper minimal recovery than the truth. Any load-bearing recovery claim must
# use THIS check, not the plain one.

_TAG_SEQ = [0]


async def drain_rx(tb, side, words=8):
    """Read the RX FIFO dry so no stale word can be scored as a delivery."""
    for i in range(words):
        await tb.ahb_fifo_read_word(side, i * 4)
    await ClockCycles(tb.dut.hclk, 200)


async def link_healthy_tagged(tb, src="m", dst="s"):
    """Stale-proof bidirectional health check: drain both RX FIFOs first, then
    send a payload carrying a tag unique to this call in EACH direction. A
    stale word cannot match a tag that has never been sent before.

    Returns (ok, detail) — same shape as errinj_common.link_healthy()."""
    from errinj_common import send_and_check           # local: avoid cycles
    _TAG_SEQ[0] += 1
    tag = _TAG_SEQ[0] & 0xFFFF

    await drain_rx(tb, "m")
    await drain_rx(tb, "s")

    okms, _ = await send_and_check(tb, "m", "s",
                                   [0xA5A50000 | tag, 0x5A5A0000 | tag],
                                   ctx=f"tagged-m2s#{tag}", expect_pass=False)
    oksm, _ = await send_and_check(tb, "s", "m",
                                   [0xB6B60000 | tag, 0x6B6B0000 | tag],
                                   ctx=f"tagged-s2m#{tag}", expect_pass=False)
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    return (okms and oksm), (f"tag={tag} m2s={okms} s2m={oksm} "
                             f"fcsm_m={fm} fcsm_s={fs}")


# ---------------------------------------------------------------------------
# Rung primitives
# ---------------------------------------------------------------------------

async def rung_a_recal(tb, sides=("m", "s"), dwell=400):
    """(a) RE-ARM THE CALIBRATOR ALONE — the cheapest conceivable intervention.

    Pulse R8[1] SWI_RECAL high then low WITHOUT touching training mode, so the
    datapath is never taken out of data mode. The falling edge re-triggers the
    align calibrator's sweep (tidelink_phy_align_calibrator.sv:575) with
    role_locked still asserted. One APB write per die; no reset of any kind."""
    for s in sides:
        await tb.apb(s).write(APB_R8_SLOT0, R8_RECAL)
    await ClockCycles(tb.dut.hclk, dwell)
    for s in sides:
        await tb.apb(s).write(APB_R8_SLOT0, 0)
    await ClockCycles(tb.dut.hclk, dwell)


async def rung_b_beacon(tb, word=R8_BEACON_FULL, sides=("m", "s"), dwell=6000):
    """(b) TRANSIENT SYNC BEACON IN DATA MODE — THE KEY EXPERIMENT.

    The named F14-B mechanism is "the SYNC beacon is OFF in data mode, so a
    framing slip has no re-anchor delimiter". This rung tests the converse
    directly: switch the beacon back ON for a bounded window while the link is
    wedged, then switch it OFF and see whether data crosses.

    Two consumers can re-anchor off that beacon — the Wlink RX framer re-hunt
    (WlinkRxLinkLayer.v:315-321, which needs R8[4] to be driven by the
    mask-aware detector) and the PHY cross-lane deskew re-anchor (armed; see
    the module docstring correction).

    The beacon is removed after `dwell` rather than left on, because
    SWI_SYNC_FORCE_ALWAYS is a known word-deleter over live traffic: a stuck
    autonomous force window beating SYNC over the payload is the silicon B->A
    corruptor this program already root-caused. A recovery routine must
    therefore be a BURST, not a mode."""
    for s in sides:
        await tb.apb(s).write(APB_R8_SLOT0, word)
    await ClockCycles(tb.dut.hclk, dwell)
    for s in sides:
        await tb.apb(s).write(APB_R8_SLOT0, 0)
    await ClockCycles(tb.dut.hclk, 2000)


async def rung_b4_beacon_tolerant(tb, sides=("m", "s"), tol=5, lane_mask=0xFF,
                                  dwell=6000):
    """(b4) BEACON BURST WITH THE SYNC MATCHER OPENED UP FIRST.

    Motivated by the W2 (clock-dropout) measurement: the transmitting die's
    tx_sync_ins_cnt climbed (0x2120 -> 0x...001d), proving the beacon physically
    reached the wire, yet the RECEIVING die's sync_seen count stayed flat at 0
    (0x2124 = 0x5d000000). The beacon was being sent and not recognised.

    The likely reason is in the register defaults: SWI_SYNC_TOL (0x2128[12:8])
    PORs to 5'h00 — EXACT match — chosen as a bit-identical zero-regression
    default (axi_chiplet_controller.sv, POR block). After a clock dropout the
    recovered word window is displaced, so the received SYNC slices are close to
    but not equal to the expected constant, and an exact matcher rejects every
    one of them. The whole re-anchor chain sits behind that compare.

    So: open the matcher (tol, full lane mask) BEFORE the beacon burst, then
    restore. tol=5 is the value the silicon bring-up already uses (0x2128=0x5e4)
    and the value the built deskew's SYNC_REANCHOR_TOL was raised to match."""
    saved = {}
    for s in sides:
        saved[s] = await tb.apb(s).read(APB_SYNC_LANE_MASK)
        await tb.apb(s).write(APB_SYNC_LANE_MASK,
                              ((tol & 0x1F) << 8) | (lane_mask & 0xFF))
    await ClockCycles(tb.dut.hclk, 200)
    await rung_b_beacon(tb, word=R8_BEACON_FULL, sides=sides, dwell=dwell)
    for s in sides:                      # restore the strap we borrowed
        await tb.apb(s).write(APB_SYNC_LANE_MASK, saved[s])
    await ClockCycles(tb.dut.hclk, 500)


async def rung_c_ll_swreset_one(tb, side="m"):
    """(c) LL swreset of ONE die (APB 0x208 bit[3])."""
    await ll_swreset_one_die(tb, side)


async def rung_d_ll_swreset_both(tb):
    """(d) LL swreset of BOTH dies together. Resets both FCSMs, both a2l replay
    FIFOs and both credit maxima in the same window, so the pair cannot desync
    the way a single-die swreset does — but it still does NOT retrain the PHY,
    which is exactly what makes it a useful discriminator between a link-layer
    wedge and a PHY/framing wedge."""
    for s in ("m", "s"):
        await tb.apb(s).write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_ON)
    await ClockCycles(tb.dut.hclk, 40)
    for s in ("m", "s"):
        await tb.apb(s).write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF)
    for s in ("m", "s"):
        await tb.apb(s).write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_ENABLE)
    await ClockCycles(tb.dut.hclk, 400)


async def rung_e_retrain_no_por(tb):
    """(e) FULL PHY RETRAIN WITHOUT POR — the rung Y-C's ladder was missing.

    Drive both dies back into the training pattern, re-run the calibrator sweep
    against a live peer pattern, then re-enter data mode. This does everything
    a POR does to the PHY, with NO reset of the power/reset domain and no loss
    of role_lock (W1S / POR-only clear, so it survives). If this rung recovers
    a wedge that Y-C's coarser ladder could only clear with a both-die POR,
    then the answer to "power domain or PHY retrain?" is PHY RETRAIN and the
    link is firmware-recoverable in the field."""
    for s in ("m", "s"):
        await tb.apb(s).write(APB_R8_SLOT0, R8_TRAIN)             # into training
    await ClockCycles(tb.dut.hclk, 2000)
    for s in ("m", "s"):
        await tb.apb(s).write(APB_R8_SLOT0, R8_RECAL | R8_TRAIN)  # cancel stale S_DONE
    await ClockCycles(tb.dut.hclk, 2000)
    for s in ("m", "s"):
        await tb.apb(s).write(APB_R8_SLOT0, R8_TRAIN)             # recal FALLING edge
    await tb.wait_cal_done()
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)
    return await tb.wait_cr_crack(max_cycles=40000)


async def rung_f_por_one(tb, side="s"):
    """(f) POR ONE die + SW re-bring-up (F14-C's class; kept for ordering)."""
    await reset_one_die(tb, side)
    return await rebringup_after_reset(tb)


async def rung_g_por_both(tb):
    """(g) POR BOTH dies + full bring-up (the power-cycle equivalent)."""
    return await full_por_rebringup(tb)


# ---------------------------------------------------------------------------
# The ladder
# ---------------------------------------------------------------------------
# (label, coroutine, firmware_reachable_in_the_field). Ordered cheapest-first.
# The walk stops at the first rung after which data is byte-exact in BOTH
# directions. `firmware_reachable` is False only for the POR rungs, which need
# a reset the chiplet cannot assert on itself.
LADDER = [
    ("a:recal-only (R8[1] pulse, never leaves data mode)", rung_a_recal, True),
    ("b1:beacon insert_en only (R8=0x04)",
     lambda tb: rung_b_beacon(tb, word=R8_SYNC_EN), True),
    ("b2:beacon +force_always (R8=0x0C)",
     lambda tb: rung_b_beacon(tb, word=R8_SYNC_EN | R8_SYNC_FORCE), True),
    ("b3:beacon +force +robust (R8=0x1C)",
     lambda tb: rung_b_beacon(tb, word=R8_BEACON_FULL), True),
    ("b4:beacon 0x1C with SYNC_TOL=5 opened first", rung_b4_beacon_tolerant, True),
    ("c:LL swreset ONE die (0x208[3])",   rung_c_ll_swreset_one,  True),
    ("d:LL swreset BOTH dies",            rung_d_ll_swreset_both, True),
    ("e:full PHY retrain, NO POR",        rung_e_retrain_no_por,  True),
    ("f:POR one die + SW re-bringup",     rung_f_por_one,         False),
    ("g:POR BOTH dies + full bringup",    rung_g_por_both,        False),
]


async def recovery_ladder(tb, src, dst, log_obs=True, rungs=None):
    """Walk the fine ladder. Returns (rung_label, firmware_reachable, trace),
    where trace is the per-rung [(label, healthy, detail)] record. The first
    rung after which BOTH directions are byte-exact wins."""
    trace = []
    # STALE-PROOF check, not errinj_common.link_healthy: a leftover RX-FIFO word
    # scoring as a delivery would stop the walk early and invent a cheaper
    # "minimal recovery" than the truth. Observed for real in run 1.
    ok, detail = await link_healthy_tagged(tb, src, dst)
    tb.log.info(f"  [ladder] rung-0 (no action): healthy={ok} {detail}")
    trace.append(("0:no action", ok, detail))
    if ok:
        return "0:no action", True, trace

    for label, rung, fw in (rungs or LADDER):
        try:
            await rung(tb)
        except Exception as exc:          # a rung must never abort the walk
            tb.log.warning(f"  [ladder] rung {label} raised {exc!r}")
        ok, detail = await link_healthy_tagged(tb, src, dst)
        obs = ""
        if log_obs:
            try:
                obs = " | " + fmt_liveness(await liveness_snapshot(tb))
            except Exception:
                pass
        tb.log.info(f"  [ladder] rung {label}: healthy={ok} {detail}{obs}")
        trace.append((label, ok, detail))
        if ok:
            return label, fw, trace

    return "NONE (hard wedge — not even a both-die POR recovered it)", False, trace


# ---------------------------------------------------------------------------
# Wedge detection / liveness
# ---------------------------------------------------------------------------
# Y-C's F14-B showed both FCSMs read state 4 (LINK_IDLE) on a wedged link, so
# `fcsm` is NOT a liveness indicator. These helpers sample every candidate
# replacement so the tests can report which ones actually discriminate healthy
# from wedged. Do not assume — measure, then quote only what separated.

def llrx_state(tb, side):
    """RX link-layer framer FSM state (Wlink.v:1560 `WlinkRxLinkLayer llrx`).

    Worth probing because the SYNC re-hunt is NOT unconditional: it is gated to
    a framer BOUNDARY —

        wire sync_resync_boundary = sync_resync & (state != 2'h1);   (:393)

    a deliberate 2026-07-03 fix so a forced beacon landing mid-body cannot
    silently discard a half-parsed long packet. Its rationale assumes "slipped
    state==1 still self-recovers via the wedge guard (word_count >
    LONG_PKT_WORD_MAX)". If a wedged framer is instead PARKED in state 1, that
    assumption fails and the beacon can never re-hunt — which would explain a
    wedge that survives a beacon burst even though the beacon demonstrably
    reached the wire and the deskew re-anchored. Not asserted; measured."""
    try:
        return int(tb.top(side).u_chiplet_controller.u_wlink.llrx.state.value)
    except (AttributeError, ValueError):
        return -1


async def liveness_snapshot(tb):
    """Sample every candidate liveness observable on both dies."""
    snap = {}
    for s in ("m", "s"):
        apb = tb.apb(s)
        st = await apb.read(APB_R8_SWI_LANE_STATUS)
        d = {
            "fcsm":        tb.fcsm_state(s),          # KNOWN LIAR (Y-C F14-B)
            "llrx":        llrx_state(tb, s),         # RX framer FSM (see llrx_state)
            "cal_done":    ST_CAL_DONE(st),
            "cr":          ST_CR_SEEN(st),
            "crack":       ST_CRACK_SEEN(st),
            "epoch":       await apb.read(APB_EPOCH_STATUS),
            "tx_sync_obs": await apb.read(APB_SYNC_OBS_TX),
            "rx_sync_obs": await apb.read(APB_SYNC_OBS_RX),
            "a2l_wptr":    tb.a2l_wptr(s),
            "a2l_ack":     tb.a2l_synced_ack(s),
            "a2l_full":    tb.a2l_full(s),
            "crc":         crc_snapshot(tb, s),
        }
        # The candidate that should work BY CONSTRUCTION: on a live link every
        # emitted FC word is eventually ACKed by the peer, so the a2l replay
        # write pointer and the peer-synced ACK pointer converge. On a wedged
        # link the TX still emits (wptr advances) but nothing is ever ACKed, so
        # they diverge and STAY diverged. 5-bit wrapping pointers.
        w, a = d["a2l_wptr"], d["a2l_ack"]
        d["a2l_outstanding"] = ((w - a) & 0x1F) if (w >= 0 and a >= 0) else -1
        snap[s] = d
    return snap


def fmt_liveness(snap):
    parts = []
    for s in ("m", "s"):
        d = snap[s]
        parts.append(
            f"{s}: fcsm={d['fcsm']} llrx={d['llrx']} cal={d['cal_done']} "
            f"cr/ck={d['cr']}{d['crack']} "
            f"epoch=0x{d['epoch']:08x} txsync=0x{d['tx_sync_obs']:08x} "
            f"rxsync=0x{d['rx_sync_obs']:08x} a2l w/a={d['a2l_wptr']}/{d['a2l_ack']} "
            f"out={d['a2l_outstanding']} crc={d['crc']['crc_errors']}")
    return " || ".join(parts)


def diff_liveness(healthy, wedged):
    """Return {field: (healthy_value, wedged_value)} for every per-die field
    that CHANGED. Only fields that appear here are candidate wedge detectors —
    a field with the same value in both states cannot discriminate."""
    out = {}
    for s in ("m", "s"):
        for k in healthy[s]:
            if k == "crc":
                hv = healthy[s][k].get("crc_errors")
                wv = wedged[s][k].get("crc_errors")
            else:
                hv, wv = healthy[s][k], wedged[s][k]
            if hv != wv:
                out[f"{s}.{k}"] = (hv, wv)
    return out


# MEASURED (not assumed): on a healthy idle link BOTH dies sit at
# a2l_outstanding == 1 — one emitted-but-not-yet-ACKed replay slot is the normal
# steady state, not a stall. Across the W1/W2/W3 wedges the receiving die's
# pointer ran to 9..16 and STAYED there. So the discriminating threshold is
# "more than a couple outstanding", not "any outstanding". The first version of
# this check used `> 0` and consequently reported the HEALTHY master as stalled
# in every W1/W2 log line in the first run — that false positive is the reason
# this constant exists and is quoted from measurement.
A2L_OUTSTANDING_HEALTHY_MAX = 2


async def is_link_alive(tb, src="m", dst="s", canary=True):
    """THE PROPOSED LIVENESS CHECK. Returns (alive, reason).

    Stage 1 is pure observation and costs no link bandwidth: is either die's a2l
    replay backlog above the healthy steady-state bound? Stage 2 is the
    definitive data canary. fcsm / cal_done / cr / crack / epoch / the SYNC
    counters are deliberately NOT consulted — measured, they do not move between
    healthy and wedged. See docs/LINK_RECOVERY_MECHANISM.md §3."""
    snap = await liveness_snapshot(tb)
    stalled = [s for s in ("m", "s")
               if snap[s]["a2l_outstanding"] > A2L_OUTSTANDING_HEALTHY_MAX]
    if stalled:
        return False, (f"a2l replay backlog above {A2L_OUTSTANDING_HEALTHY_MAX} "
                       f"on {stalled} ({fmt_liveness(snap)})")
    if not canary:
        return True, f"backlog within bound ({fmt_liveness(snap)})"
    ok, detail = await link_healthy(tb, src, dst)
    return ok, f"canary {'byte-exact' if ok else 'FAILED'}: {detail}"

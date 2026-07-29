"""TideLink register map + authoritative status decodes (pure functions).

Single source of truth for the throughput GUI. Address map and the
SWI_LANE_STATUS @ 0x44032108 bit packing follow
``pynq_host/scripts/tlchar.py`` (the authoritative decode — RTL, not
RDL; fcsm is THREE bits [19:17]) and the OBS_FC_CREDIT decode follows
``pynq_host/scripts/link_delivery_proof.sh``.

The jam-signature matrix is a Python port of
``pynq_host/scripts/unjam_fc_node.sh``; the criterion-A/B link-up gate
is a port of ``tt_verify_link_up`` in
``pynq_host/scripts/hwtest/lib/lib_hwtest.sh`` (with fcsm read 3-bit
per tlchar, not the stale 4-bit RDL packing).

Everything here is host-side (mapstone-dev) logic operating on raw
register values the on-board agent reports — no I/O in this module.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

# ── Address map (matches tlchar.py incl. the GP1-split env overrides) ────
PAGE = 4096


def tx_base() -> int:
    """AHB_TX aperture — NEVER written outside an admitted run."""
    return int(os.environ.get("TIDELINK_TX_BASE", "0x44000000"), 16)


def rxfifo_base() -> int:
    return int(os.environ.get("TIDELINK_RXFIFO_BASE", "0x44010000"), 16)


PAIR_BASE      = 0x44032000
R_REL_THRESH   = PAIR_BASE + 0x004
R_PKT_WORD_LEN = PAIR_BASE + 0x008
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO available credits
R_STATUS       = PAIR_BASE + 0x010
R_DOORBELL     = PAIR_BASE + 0x014
R_RELEASE_ACC  = PAIR_BASE + 0x018   # sub-threshold freed credits (RO)
R_CTRL         = PAIR_BASE + 0x01C
R_RELEASED_ACC = PAIR_BASE + 0x020   # read-clear
R_DB_RESP_ACC  = PAIR_BASE + 0x024   # read-clear
R_PAIR_CREDIT  = PAIR_BASE + 0x028   # credits available toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C   # WO: decrement pair counter by N
R_TRAINING     = PAIR_BASE + 0x100   # [0] swi_training_mode, [1] swi_recal
R_LANE_STATUS  = PAIR_BASE + 0x108   # SWI_LANE_STATUS
R_SYNC_DET     = PAIR_BASE + 0x114   # [31:16] sync_detected sat-count
R_PHY_ID       = PAIR_BASE + 0x11C   # PHYID runtime cross-check
R_EPOCH_STATUS = PAIR_BASE + 0x140   # SWI_EPOCH_STATUS (V2; Region 10 in V1)
R_OBS_MASK_HS  = PAIR_BASE + 0x194   # OBS_MASK_HS
R_OBS_CAL      = PAIR_BASE + 0x198   # OBS_CAL (M7 calibrator obs)
R_OBS_FCCRED   = PAIR_BASE + 0x19C   # OBS_FC_CREDIT (2026-06-12+ images)

MAX_CREDITS    = 4096
HDR_4WORD      = 0x00240000          # WR_REQ, 2 payload words (delivery proof)

REL_THRESHOLD_POR = 20               # RTL POR of RELEASE_THRESHOLD (0x004)
REL_THRESHOLD_MAX = 4095

FCSM_LINK_IDLE = 4
FCSM_LINK_DATA = 5
FCSM_HEALTHY   = {FCSM_LINK_IDLE, FCSM_LINK_DATA}

# ── Wlink FC-node CRC error counter ──────────────────────────────────────
# Wlink APB region base 0x4403_0000; the TideLink FC node sits at +0x1700
# and every FC node exposes "CRC Errors" [15:0] RO at node+0x20
# (docs/REGISTER_MAP.md:471). Accumulating, NOT read-clear.
WLINK_BASE          = 0x44030000
WLINK_TIDELINK_NODE = WLINK_BASE + 0x1700
WLINK_CRC_ERR_ADDR  = WLINK_TIDELINK_NODE + 0x20

# Three caveats make this read OPT-IN rather than part of the default poll:
#  1. The Wlink APB half has no stall timeout (tidelink_top.sv:815 is a bare
#     pready passthrough), unlike the TideLink half which force-completes
#     after 1024 cycles. This is the ONE monitor read on an unprotected bus:
#     a wedged Wlink sub-slave can pin pready low and take the PS with it.
#  2. crc_errors lives in the io_rx_clk domain and is muxed onto the APB
#     clock with no synchroniser, so a single sample can be torn. Require
#     two agreeing consecutive samples before believing a rise.
#  3. The read returns 0 whenever the FC node is disabled or in reset —
#     which is NOT the same as "no CRC errors".
WLINK_CRC_ERR_MASK  = 0xFFFF

# ── Data-mode bring-up (the writes deploy_pair.sh does NOT do) ──────────
#
# A plain deploy trains the link (fcsm=4, cal=1) but does not make it carry
# data: its whole post-load write-set is the strap GPIO. The flows that did
# deliver additionally applied a SYNC beacon, a pair-credit seed and the
# to_data_mode reset triplet. See
# pynq_host/scripts/tl_z2_data_bringup_repro.sh for the staged bisect.

# R1b — SYNC beacon, SWI_TRAINING_MODE (Region 8 slot 0).
#   [2] sync_insert_en  [3] sync_force_always  [4] sync_robust_detect
SYNC_BEACON_VALUE = 0x1C

# R3 — Wlink Link Registers "Enable/Reset" @ Wlink base + 0x200 + 0x08:
#   [0] swi_enable  [1] ll_tx_enable  [2] ll_rx_enable  [3] sw_reset
#   [15:8] max_short_pkt_id (0x7F)   [23:16] preq_data_id (0x02)
WLINK_LINK_BASE      = WLINK_BASE + 0x200
R_WLINK_ENABLE_RESET = WLINK_LINK_BASE + 0x08      # abs 0x4403_0208

# ⚠ swi_enable (bit 0) is held HIGH throughout. The ...08/...00/...07 form
# still used by unjam_fc_node.sh, bringup_pair_converge.sh and
# sw_coord_autocal_region8.sh drops bit 0, and while swi_enable is low the
# FCSM is forced to state 0 and fe_rx_ptr / fe_tx_credit_max / exp_pkt_num
# are HELD CLEARED — desyncing the credit ring and wedging the sender
# (axi_chiplet_controller.sv:3440-3462). Do not "simplify" these values.
DATA_MODE_TRIPLET = (
    0x00027F09,   # swi_enable + sw_reset          (LL tx/rx off)
    0x00027F01,   # swi_enable, reset released     (LL tx/rx still off)
    0x00027F07,   # swi_enable + ll_tx_en + ll_rx_en
)


# ── Poll whitelist — the ONLY offsets the monitor loop may read ──────────
#
# WHITELIST-DRIVEN, NOT "read a range": undecoded APB addresses can hang
# the PS, and several nearby offsets are read-clear. Every entry below is
# RO with no read side effect. Offsets are PAIR_BASE-relative; the string
# is the key used in the agent's NDJSON ``r`` map and in decode_monitor().
MONITOR_WHITELIST = (
    (0x008, "008"),   # PACKET_WORD_LENGTH
    (0x00C, "00c"),   # CREDIT_COUNT (free credits, not occupancy)
    (0x010, "010"),   # STATUS (sticky overrun/underrun/master_error)
    (0x018, "018"),   # RELEASE_ACC
    (0x01C, "01c"),   # CTRL — [2] LOCK readback (is REL_THRESHOLD writable?)
    (0x028, "028"),   # PAIR_CREDIT_COUNTER
    (0x100, "100"),   # SWI_TRAINING_MODE
    (0x108, "108"),   # SWI_LANE_STATUS  <- headline register
    (0x114, "114"),   # SYNC_DET  ([31:16] only; [15:0] is tied 0)
    (0x11C, "11c"),   # PHY_ALIGN_ID (liveness constant 0x50410100)
    (0x120, "120"),   # SYNC_OBS      V2 only, marker 0x5C
    (0x124, "124"),   # SYNC_DETECT   V2 only, marker 0x5D
    (0x140, "140"),   # SWI_EPOCH_STATUS (V2; V1 = eye SWI_EYE_CTRL, read-safe)
    (0x194, "194"),   # OBS_MASK_HS
    (0x198, "198"),   # OBS_CAL
    (0x19C, "19c"),   # OBS_FC_CREDIT (marker 0xFC)
)
MONITOR_OFFSETS = frozenset(off for off, _ in MONITOR_WHITELIST)

# Build-vintage presence markers. Several whitelist registers are V2-only
# and read 0 by construction on a V1 build (region9/10/D rdata is tied 0,
# axi_chiplet_controller.sv:2602-2604), which is indistinguishable from
# "the field is really zero". Gate any V2-only claim on its marker rather
# than on either document — the repo's own docs disagree about which of
# these are retired, and the deployed image's vintage is not knowable from
# the source tree.
MARKER_SYNC_OBS    = (0x120, 24, 0x5C)   # (offset, shift, expected byte)
MARKER_SYNC_DETECT = (0x124, 24, 0x5D)
MARKER_FC_CREDIT   = (0x19C, 24, 0xFC)
PHY_ALIGN_ID_EXPECT = 0x50410100

# Phase-B performance block (regions 5/6/7 of the APB space, implemented
# by src/rtl/tidelink_perf.sv). Read ONLY while frozen (PERF_CTRL[1]).
PERF_CTRL_OFF = 0x0A0
PERF_CTRL_ENABLE = 1 << 0
PERF_CTRL_FREEZE = 1 << 1
PERF_CTRL_CLEAR  = 1 << 2            # tidelink_perf.sv:240 clear_counters
PERF_ID_EXPECT   = 0x50460100        # "PF" v1.0 @ 0x0FC

PERF_WHITELIST = (
    (0x0AC, "0ac"),   # PERF_STATUS
    (0x0C8, "0c8"),   # TX_PKT_COUNT
    (0x0CC, "0cc"),   # RX_PKT_COUNT
    (0x0D0, "0d0"),   # TX_WORD_COUNT
    (0x0D4, "0d4"),   # RX_WORD_COUNT
    (0x0D8, "0d8"),   # TX_STALL_COUNT
    (0x0DC, "0dc"),   # RX_STALL_COUNT
    (0x0E0, "0e0"),   # LINK_BUSY_COUNT
    (0x0E4, "0e4"),   # CREDIT_STARVE_COUNT
    (0x0E8, "0e8"),   # SAMPLE_COUNT
    (0x0EC, "0ec"),   # PERF_DEBUG
    (0x0F0, "0f0"),   # TX_INFLIGHT
    (0x0F4, "0f4"),   # RX_INFLIGHT
    (0x0F8, "0f8"),   # PERF_CONG_STATE
    (0x0FC, "0fc"),   # PERF_ID
)
PERF_OFFSETS = frozenset(off for off, _ in PERF_WHITELIST)

# Offsets that must NEVER be read by any polling loop.
#   0x020 / 0x024  read-clear credit accumulators — reading corrupts the
#                  credit protocol the link depends on (drain path owns them)
#   0x038          PTP_RX_PAYLOAD — read clears PTP_CTRL.rx_valid
#   0x15C / 0x160  EYE_CRC_ERR_LANE_LO/HI — read-clears
#   0x168          EYE_SCORE_DATA — auto-increments the point index
#   0x1AC/0x1B0/   board-proven uninterruptible PS hang on read; recovery is
#   0x1B4          a power-cycle (docs/HANDOVER_2026_07_10.md:14)
FORBIDDEN_OFFSETS = frozenset({
    0x020, 0x024, 0x038, 0x15C, 0x160, 0x168, 0x1AC, 0x1B0, 0x1B4,
})


# ── SWI_LANE_STATUS decode (authoritative per tlchar.py) ─────────────────

def decode_lane_status(raw: int) -> dict:
    """Decode SWI_LANE_STATUS @ 0x44032108.

    [7:0] locked_mask  [15:8] fault_mask  [16] cal_done
    [19:17] fcsm (3 bits)  [20] a2l_replay_app_valid  [22:21] llrx_state
    [23] cr_seen  [24] crack_seen  [25] short  [26] long  [29] llrx_valid
    [30] a2l_fc_replay_link_valid  [31] fe_rx_is_full
    """
    return {
        "raw": raw,
        "lane_status": "0x%08x" % raw,
        "locked_mask": raw & 0xFF,
        "lock_count": bin(raw & 0xFF).count("1"),
        "fault_mask": (raw >> 8) & 0xFF,
        "cal_done": (raw >> 16) & 1,
        "fcsm": (raw >> 17) & 0x7,
        "a2l_replay_app_valid": (raw >> 20) & 1,
        "llrx_state": (raw >> 21) & 0x3,
        "cr_seen": (raw >> 23) & 1,
        "crack_seen": (raw >> 24) & 1,
        "llrx_valid": (raw >> 29) & 1,
        "a2l_fc_replay_link_valid": (raw >> 30) & 1,
        "fe_rx_is_full": (raw >> 31) & 1,
    }


def decode_obs_fc_credit(raw: int) -> dict:
    """OBS_FC_CREDIT @ 0x4403219C: [31:24]=0xFC marker, [16] full,
    [15:8] fe_rx_ptr, [7:0] fe_rx_credit_max. Old images read 0."""
    return {
        "fc_obs_raw": "0x%08x" % raw,
        "fc_obs_live": 1 if ((raw >> 24) & 0xFF) == 0xFC else 0,
        "fe_rx_credit_max": raw & 0xFF,
        "fe_rx_ptr": (raw >> 8) & 0xFF,
        "fe_rx_is_full_obs": (raw >> 16) & 1,
    }


# ── Jam-signature matrix (port of unjam_fc_node.sh) ──────────────────────

JAM_CLASSIC = "CLASSIC"          # CTRL-cycle recoverable
JAM_HELD_REPLAY = "HELD-REPLAY"  # reflash only
JAM_BUS_ERROR = "BUS-ERROR"      # probe dies/hangs — reflash only


def classify_jam(status: dict) -> Optional[str]:
    """Classify a decoded SWI_LANE_STATUS against the known jam
    signatures. Returns None when no known signature is present.

      CLASSIC     = fcsm=5 + a2l_fc_replay_link_valid=1 + fe_rx_is_full=0
      HELD-REPLAY = fcsm=4 + a2l_replay_app_valid=1     + fe_rx_is_full=1

    (BUS-ERROR is a channel-level failure — the probe itself dies — and
    is classified by the caller when the agent oneshot fails.)
    """
    fcsm = status["fcsm"]
    if (fcsm == FCSM_LINK_DATA
            and status["a2l_fc_replay_link_valid"] == 1
            and status["fe_rx_is_full"] == 0):
        return JAM_CLASSIC
    if (fcsm == FCSM_LINK_IDLE
            and status["a2l_replay_app_valid"] == 1
            and status["fe_rx_is_full"] == 1):
        return JAM_HELD_REPLAY
    return None


# ── Criterion-A/B link-up gate (port of tt_verify_link_up) ───────────────

@dataclass
class LinkVerdict:
    ok: bool
    criterion: Optional[str]     # "A" | "B" | None
    reason: str
    snapshot: dict               # embedded in run.json as gate_snapshot


def verify_link_up(master: dict, slave: dict) -> LinkVerdict:
    """Criterion A (training-mode): 8/8 lanes locked + cal_done on both
    dies. Criterion B (data-mode, post-M12): cal_done both + FCSM in
    {4,5} both — lane_locked=0 is EXPECTED once swi_training_mode
    clears (the checker only matches training patterns).

    ``master`` / ``slave`` are ``decode_lane_status()`` dicts.
    """
    snapshot = {
        "m_fcsm": master["fcsm"], "s_fcsm": slave["fcsm"],
        "m_cal_done": master["cal_done"], "s_cal_done": slave["cal_done"],
        "m_lock_count": master["lock_count"],
        "s_lock_count": slave["lock_count"],
        "m_lane_status": master["lane_status"],
        "s_lane_status": slave["lane_status"],
    }
    if (master["lock_count"] == 8 and slave["lock_count"] == 8
            and master["cal_done"] == 1 and slave["cal_done"] == 1):
        snapshot["criterion"] = "A"
        return LinkVerdict(True, "A", "8/8 lanes + cal_done both dies",
                           snapshot)
    if (master["cal_done"] == 1 and slave["cal_done"] == 1
            and master["fcsm"] in FCSM_HEALTHY
            and slave["fcsm"] in FCSM_HEALTHY):
        snapshot["criterion"] = "B"
        return LinkVerdict(
            True, "B",
            "cal_done both + FCSM=%d/%d (post-training lk=0 expected)"
            % (master["fcsm"], slave["fcsm"]),
            snapshot)
    snapshot["criterion"] = None
    return LinkVerdict(
        False, None,
        "link not up: master lk=%d/8 cal=%d fcsm=%d | "
        "slave lk=%d/8 cal=%d fcsm=%d"
        % (master["lock_count"], master["cal_done"], master["fcsm"],
           slave["lock_count"], slave["cal_done"], slave["fcsm"]),
        snapshot)


# ── Monitor decodes (whitelist registers -> flat display dict) ───────────
#
# Single source of truth for the Link Monitor: the browser renders these
# fields verbatim. NO bit-slicing in JS — if a field is missing here, add
# it here, not in the frontend.

def decode_status_reg(raw: int) -> dict:
    """STATUS @ 0x010 (docs/REGISTER_MAP.md region 0). Bits [1:3] are
    STICKY and are cleared only by CTRL.FLUSH — the monitor never clears
    them, it only reports them."""
    return {
        "status_raw": "0x%08x" % raw,
        "returner_busy": raw & 1,
        "overrun": (raw >> 1) & 1,
        "underrun": (raw >> 2) & 1,
        "master_error": (raw >> 3) & 1,
        "packet_committed": (raw >> 4) & 1,
    }


def decode_epoch_status(raw: int) -> dict:
    """SWI_EPOCH_STATUS @ 0x140 — V2 only. In V1 images Region 10 is the
    eye-visibility block and this reads whatever that block returns, so
    ``epoch_valid`` stays 0 unless the anchored bit or a span is set."""
    return {
        "epoch_raw": "0x%08x" % raw,
        "epoch_anchored": raw & 1,
        "epoch_span": (raw >> 1) & 0x3F,
    }


def decode_mask_hs(raw: int) -> dict:
    """OBS_MASK_HS @ 0x194 — mask-handshake genuineness.

    ``gate_open`` with ``mask_hs_match=0`` means the gate was forced open
    rather than earned; that distinction is the whole point of the
    register, so both bits are always reported."""
    return {
        "mask_hs_raw": "0x%08x" % raw,
        "mask_hs_match": (raw >> 19) & 1,
        "gate_open": (raw >> 20) & 1,
    }


def decode_obs_cal(raw: int) -> dict:
    """OBS_CAL @ 0x198 — M7 calibrator observability."""
    return {
        "cal_raw": "0x%08x" % raw,
        "cal_state": raw & 0xF,
        "cal_resweep_ctr": (raw >> 4) & 0xFFFF,
        "training_live": (raw >> 20) & 1,
    }


def decode_monitor(raw: dict) -> dict:
    """Decode one monitor poll.

    ``raw`` maps the MONITOR_WHITELIST key strings to plain ints (as the
    board agent emits them). Registers absent from ``raw`` simply omit
    their fields — this never raises, so a partial poll still renders.
    """
    def _get(key):
        val = raw.get(key)
        return None if val is None else int(val)

    out: dict = {}

    v = _get("008")
    if v is not None:
        out["pkt_word_len"] = v & 0x3FFF

    v = _get("00c")
    if v is not None:
        credit = v & 0x1FFF
        out["credit_count"] = credit
        out["occupancy"] = MAX_CREDITS - credit
        out["credit_frac"] = round(credit / float(MAX_CREDITS), 6)

    v = _get("010")
    if v is not None:
        out.update(decode_status_reg(v))

    v = _get("018")
    if v is not None:
        out["release_acc"] = v

    v = _get("01c")
    if v is not None:
        # CTRL.LOCK is write-once set-only with NO clear path but hresetn,
        # and a blocked RELEASE_THRESHOLD write raises no pslverr
        # (tidelink_apb_regs.sv:261,696) — this readback is the only way
        # to know a load-generator setting can be applied at all.
        out["ctrl_lock"] = (v >> 2) & 1

    v = _get("028")
    if v is not None:
        out["pair_credits"] = v

    v = _get("100")
    if v is not None:
        # SWI_TRAINING_MODE readback (V2): {robust[4], force[3], insert[2],
        # recal[1], train[0]}. sync_insert_en is THE beacon signal — it is
        # what autonomous training-entry sets and what the dead-I2C rig
        # never reaches (axi_chiplet_controller / tidelink_autoneg:1246).
        # Golden pins it via a since-fixed bug (R8=0x14); current builds
        # read R8=0x00 and cannot anchor. Surface it so the monitor shows
        # the beacon at a glance rather than only in the raw word.
        out["training"] = v & 1
        out["swi_recal"] = (v >> 1) & 1
        out["sync_insert_en"] = (v >> 2) & 1
        out["sync_force_always"] = (v >> 3) & 1
        out["sync_robust_detect"] = (v >> 4) & 1
        out["beacon_on"] = (v >> 2) & 1

    v = _get("108")
    if v is not None:
        out.update(decode_lane_status(v))
        out.pop("raw", None)

    v = _get("114")
    if v is not None:
        out["sync_detected"] = (v >> 16) & 0xFFFF

    v = _get("11c")
    if v is not None:
        out["phy_align_id"] = "0x%08x" % v
        out["phy_align_present"] = 1 if v == PHY_ALIGN_ID_EXPECT else 0

    v = _get("120")
    if v is not None:
        # V2-only. On a V1 build region 9 is tied 0, so an absent marker
        # means "this build has no sync observability", NOT "zero syncs".
        out["sync_obs_v2"] = 1 if ((v >> 24) & 0xFF) == 0x5C else 0
        if out["sync_obs_v2"]:
            out["tx_sync_ins_cnt"] = v & 0xFFFF
            out["tx_idle"] = (v >> 16) & 1
            out["tx_training"] = (v >> 17) & 1

    v = _get("124")
    if v is not None:
        out["sync_det_v2"] = 1 if ((v >> 24) & 0xFF) == 0x5D else 0
        if out["sync_det_v2"]:
            out["sync_seen_cnt"] = v & 0xFFFF
            out["sync_lane_mask"] = (v >> 16) & 0xFF

    v = _get("140")
    if v is not None:
        out.update(decode_epoch_status(v))

    v = _get("194")
    if v is not None:
        out.update(decode_mask_hs(v))

    v = _get("198")
    if v is not None:
        out.update(decode_obs_cal(v))

    v = _get("19c")
    if v is not None:
        out.update(decode_obs_fc_credit(v))

    v = _get("crc")
    if v is not None:
        out["crc_errors"] = v & 0xFFFF

    return out


def health(dec: dict) -> dict:
    """Per-die health verdict from a decode_monitor() dict.

    ``link_up`` here is the SINGLE-die view (cal_done + FCSM healthy);
    the criterion-A/B pair verdict still comes from verify_link_up().
    """
    reasons = []
    fcsm = dec.get("fcsm")
    cal = dec.get("cal_done")
    if cal is None or fcsm is None:
        return {"link_up": False, "criterion": None, "jam": None,
                "reasons": ["no SWI_LANE_STATUS in this poll"]}

    jam = classify_jam({
        "fcsm": fcsm,
        "a2l_replay_app_valid": dec.get("a2l_replay_app_valid", 0),
        "a2l_fc_replay_link_valid": dec.get("a2l_fc_replay_link_valid", 0),
        "fe_rx_is_full": dec.get("fe_rx_is_full", 0),
    })
    if jam is not None:
        reasons.append("jam signature %s — see unjam_fc_node.sh" % jam)
    if cal != 1:
        reasons.append("cal_done=0")
    if fcsm not in FCSM_HEALTHY:
        reasons.append("FCSM=%d outside {4,5}" % fcsm)
    if dec.get("overrun"):
        reasons.append("STICKY overrun — RX FIFO write dropped (no HW "
                       "backpressure); credit protocol was violated")
    if dec.get("underrun"):
        reasons.append("STICKY underrun — data window read with no packet")
    if dec.get("master_error"):
        reasons.append("STICKY master_error — AHB returner saw ERROR")
    if dec.get("gate_open") and dec.get("mask_hs_match") == 0:
        reasons.append("mask_hs gate open WITHOUT a match — gate forced, "
                       "autonomy not genuine")
    # A trained link (cal+fcsm healthy) with the SYNC beacon OFF cannot
    # carry data: no sync words are inserted, so no lane anchors and no
    # word reassembles. This is the exact bridge1 dead-I2C signature —
    # autonomous training-entry never set sync_insert_en. The fix is RTL
    # (TRAIN_ENTRY_FALLBACK); do NOT read criterion-B as "delivers".
    if "beacon_on" in dec and dec["beacon_on"] == 0:
        reasons.append("SYNC beacon OFF (R8 sync_insert_en=0) — link is "
                       "trained but cannot carry data; autonomous "
                       "training-entry did not complete (dead-I2C rig, "
                       "see TRAIN_ENTRY_FALLBACK)")

    criterion = None
    if cal == 1 and dec.get("lock_count") == 8:
        criterion = "A"
    elif cal == 1 and fcsm in FCSM_HEALTHY:
        criterion = "B"
    return {"link_up": jam is None and criterion is not None,
            "criterion": criterion, "jam": jam, "reasons": reasons}


# ── Phase-B performance block ────────────────────────────────────────────

def decode_perf(raw: dict) -> dict:
    """Decode a frozen perf-counter snapshot (PERF_WHITELIST keys)."""
    def _get(key):
        val = raw.get(key)
        return None if val is None else int(val)

    out: dict = {}
    for key, name in (("0c8", "tx_pkt_count"), ("0cc", "rx_pkt_count"),
                      ("0d0", "tx_word_count"), ("0d4", "rx_word_count"),
                      ("0d8", "tx_stall_count"), ("0dc", "rx_stall_count"),
                      ("0e0", "link_busy_count"),
                      ("0e4", "credit_starve_count"),
                      ("0e8", "sample_count"),
                      ("0f0", "tx_inflight"), ("0f4", "rx_inflight")):
        v = _get(key)
        if v is not None:
            out[name] = v

    v = _get("0ac")
    if v is not None:
        out["perf_status_raw"] = "0x%08x" % v
        out["tx_ts_valid"] = v & 1
        out["rx_first_valid"] = (v >> 1) & 1
        out["rx_done_valid"] = (v >> 2) & 1
        out["perf_frozen"] = (v >> 3) & 1

    v = _get("0ec")
    if v is not None:
        out["tx_router_idle"] = v & 1
        out["perf_credit_count"] = (v >> 1) & 0x1FFF
        out["fc_tx_valid"] = (v >> 14) & 1
        out["fc_rx_valid"] = (v >> 15) & 1

    v = _get("0f8")
    if v is not None:
        out["ewma_credit"] = v & 0x1FFF
        out["cong_level"] = (v >> 16) & 0x3
        out["cong_trend"] = (v >> 18) & 0x3
        out["credit_starve_sticky"] = (v >> 20) & 1

    v = _get("0fc")
    if v is not None:
        out["perf_id"] = "0x%08x" % v
        out["perf_block_present"] = 1 if v == PERF_ID_EXPECT else 0

    out["perf_vintage"] = perf_vintage(raw)
    return out


def perf_vintage(raw: dict) -> str:
    """Which perf-block decode the deployed bitstream has.

    Before the region-decode fix (tidelink_apb_regs.sv, 2026-07-17) the
    perf block computed ``perf_reg_region = apb_region[1:0]``, mapping
    regions {5,6,7} to {01,10,11}. Region 5 could therefore never produce
    2'b00, PERF_CTRL was physically unwritable, and the whole block reads
    one region low — so PERF_ID turns up at 0x0DC instead of 0x0FC.

    That makes the shift a free, unambiguous vintage probe, which the
    naive "read PERF_ID at 0x0FC" check is not: pre-fix it reads 0, and 0
    is exactly what a dead bus reads too.

      "post-fix"  PERF_ID at 0x0FC — counters usable (still confirm
                  PERF_CTRL by write/readback of 0x0A0 bit[0])
      "pre-fix"   PERF_ID at 0x0DC — block present, CTRL UNWRITABLE;
                  the counters cannot be cleared or frozen, so any
                  window derived from them is meaningless
      "absent"    neither — no perf block in this image
    """
    def _v(key):
        val = raw.get(key)
        return None if val is None else int(val)

    if _v("0fc") == PERF_ID_EXPECT:
        return "post-fix"
    if _v("0dc") == PERF_ID_EXPECT:
        return "pre-fix"
    return "absent"


def perf_window_cleared(cur: dict) -> dict:
    """Fractions from a single clear->run->freeze window.

    The sampling protocol clears the counters at the START of every window
    (PERF_CTRL=0x5) and freezes at the end (0x3), so each emitted snapshot
    is ALREADY a delta over win_s. Differencing two consecutive snapshots
    would give ~0 and make a perfectly healthy block read as dead — so a
    cleared window is scored against a zero baseline instead. The agent
    tags these records ``window_mode="cleared"``; use this function for
    them and perf_window() only for free-running cumulative counters.
    """
    if not cur:
        return {}
    zero = {name: 0 for name in
            ("sample_count", "tx_word_count", "rx_word_count",
             "tx_pkt_count", "rx_pkt_count", "link_busy_count",
             "tx_stall_count", "rx_stall_count", "credit_starve_count")}
    zero["perf_vintage"] = cur.get("perf_vintage", "post-fix")
    return perf_window(zero, cur)


def perf_window(prev: dict, cur: dict) -> dict:
    """Fractions over one frozen window, from two decode_perf() dicts.

    For counters read WITHOUT an intervening clear (free-running). If the
    agent cleared at the start of the window, use perf_window_cleared().

    Returns {} when SAMPLE_COUNT did not advance — which is exactly what a
    golden (pre-PERF_CTRL-fix) image looks like. An all-zero counter block
    must read as "no data", NEVER as "0% utilisation": PERF_ID proves the
    block exists, it does NOT prove PERF_CTRL is writable.
    """
    if not prev or not cur:
        return {}
    # A pre-fix image cannot freeze or clear the counters, so whatever the
    # registers hold is not a window over anything. Refuse rather than
    # dress it up as a measurement.
    if "pre-fix" in (prev.get("perf_vintage"), cur.get("perf_vintage")):
        return {}
    d_sample = cur.get("sample_count", 0) - prev.get("sample_count", 0)
    if d_sample <= 0:
        return {}

    def _d(name):
        return cur.get(name, 0) - prev.get(name, 0)

    return {
        "d_sample": d_sample,
        "d_tx_words": _d("tx_word_count"),
        "d_rx_words": _d("rx_word_count"),
        "d_tx_pkts": _d("tx_pkt_count"),
        "d_rx_pkts": _d("rx_pkt_count"),
        "utilisation": round(_d("link_busy_count") / float(d_sample), 6),
        "tx_stall_frac": round(_d("tx_stall_count") / float(d_sample), 6),
        "rx_stall_frac": round(_d("rx_stall_count") / float(d_sample), 6),
        "credit_starve_frac": round(
            _d("credit_starve_count") / float(d_sample), 6),
    }


# ── Framing efficiency (what the load-generator controls demonstrate) ────

def header_efficiency(payload_words: int) -> float:
    """Payload fraction of a TideLink packet: N payload words ride behind
    a 2-word header, so useful/total = N/(N+2)."""
    n = int(payload_words)
    if n <= 0:
        return 0.0
    return n / float(n + 2)

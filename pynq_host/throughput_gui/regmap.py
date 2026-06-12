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
R_CREDIT_COUNT = PAIR_BASE + 0x00C   # local FIFO available credits
R_STATUS       = PAIR_BASE + 0x010
R_DOORBELL     = PAIR_BASE + 0x014
R_RELEASED_ACC = PAIR_BASE + 0x020   # read-clear
R_DB_RESP_ACC  = PAIR_BASE + 0x024   # read-clear
R_PAIR_CREDIT  = PAIR_BASE + 0x028   # credits available toward peer
R_PAIR_CONSUME = PAIR_BASE + 0x02C   # WO: decrement pair counter by N
R_TRAINING     = PAIR_BASE + 0x100   # [0] swi_training_mode, [1] swi_recal
R_LANE_STATUS  = PAIR_BASE + 0x108   # SWI_LANE_STATUS
R_PHY_ID       = PAIR_BASE + 0x11C   # PHYID runtime cross-check
R_OBS_FCCRED   = PAIR_BASE + 0x19C   # OBS_FC_CREDIT (2026-06-12+ images)

MAX_CREDITS    = 4096
HDR_4WORD      = 0x00240000          # WR_REQ, 2 payload words (delivery proof)

FCSM_LINK_IDLE = 4
FCSM_LINK_DATA = 5
FCSM_HEALTHY   = {FCSM_LINK_IDLE, FCSM_LINK_DATA}


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

"""Safety interlocks — orchestrator-enforced, not advisory.

* ``link_gate``      criterion-A/B link-up check (port of
                     hwtest/lib/lib_hwtest.sh::tt_verify_link_up) from
                     live agent probes. Any test with hazard "ahb_tx"
                     refuses to start without it.
* ``delivery_proof`` Python port of
                     pynq_host/scripts/link_delivery_proof.sh — proves
                     an allegedly-up link actually DELIVERS one packet
                     before any sustained AHB_TX traffic (the ~40%
                     CR-credit-decode lottery makes "looks up" lie).
* ``ExperimentMutex``cross-toolkit advisory flock so the eye (:8088) /
                     stress (:8089) GUIs and CLI scripts can honour the
                     same single-experiment rule.
"""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
from typing import Optional, Tuple

from . import regmap
from .agent_channel import AgentError, _BaseChannel


class GateError(RuntimeError):
    """A safety gate failed — surfaces as HTTP 412."""


class MutexHeld(RuntimeError):
    """Another experiment holds the hardware — surfaces as HTTP 409."""


# ── Criterion-A/B link gate ───────────────────────────────────────────────

async def link_gate(master_ch: _BaseChannel, slave_ch: _BaseChannel
                    ) -> regmap.LinkVerdict:
    """Probe both dies and evaluate criterion A/B. AgentError from a
    probe (process dies / hangs) is the BUS-ERROR jam class — fail."""
    try:
        m = await master_ch.oneshot("probe")
        s = await slave_ch.oneshot("probe")
    except AgentError as exc:
        raise GateError("link probe failed (BUS-ERROR class): %s" % exc)
    m_dec = regmap.decode_lane_status(int(m["lane_status"], 16))
    s_dec = regmap.decode_lane_status(int(s["lane_status"], 16))
    verdict = regmap.verify_link_up(m_dec, s_dec)
    verdict.snapshot["m_training"] = m.get("training", 0)
    verdict.snapshot["s_training"] = s.get("training", 0)
    verdict.snapshot["m_phy_id"] = m.get("phy_id")
    verdict.snapshot["s_phy_id"] = s.get("phy_id")
    return verdict


# ── Delivery proof (port of link_delivery_proof.sh) ──────────────────────

async def delivery_proof(master_ch: _BaseChannel, slave_ch: _BaseChannel,
                         *, catch_timeout_s: float = 5.0
                         ) -> Tuple[dict, list]:
    """One verified 4-word M->S packet. Returns (detail, warnings) on
    success; raises GateError otherwise. The CLI reference
    implementation is pynq_host/scripts/link_delivery_proof.sh — keep
    the two in lockstep."""
    warnings: list = []
    try:
        m_obs = await master_ch.oneshot("probe")
        s_obs = await slave_ch.oneshot("probe")
    except AgentError as exc:
        raise GateError("delivery-proof obs failed: %s" % exc)

    # Pre-send state gate: fcsm=4 (LINK_IDLE) both, training released
    # both, fe_rx_is_full clear both.
    for side, obs in (("master", m_obs), ("slave", s_obs)):
        if obs["fcsm"] != regmap.FCSM_LINK_IDLE:
            raise GateError(
                "delivery-proof pre-send: %s FCSM=%d not LINK_IDLE(4)"
                % (side, obs["fcsm"]))
        if obs.get("training", 0) != 0:
            raise GateError(
                "delivery-proof pre-send: %s swi_training_mode still set "
                "— link not released" % side)
        if obs["fe_rx_is_full"] != 0:
            raise GateError(
                "delivery-proof pre-send: %s fe_rx_is_full=1 — no TX "
                "credits" % side)

    # Garbled-CR heuristic: suspiciously small nonzero credit_max is the
    # exact failure mode this proof exists for. Flag, don't gate.
    if m_obs.get("fc_obs_live") == 1 and m_obs.get("fe_rx_credit_max", 0) < 8:
        warnings.append(
            "master fe_rx_credit_max=%d (<8) — possible garbled CR credit"
            % m_obs["fe_rx_credit_max"])

    base_occ = int(s_obs["occupancy"])
    try:
        await master_ch.oneshot("send4")
        catch = await slave_ch.oneshot(
            "catch", base_occ, catch_timeout_s,
            timeout=catch_timeout_s + 20.0)
    except AgentError as exc:
        raise GateError("delivery-proof send/catch failed: %s" % exc)

    if int(catch.get("delta", 0)) <= 0:
        raise GateError(
            "delivery-proof: packet never landed in slave RX FIFO "
            "(occupancy delta=%s after %.1fs) — link cannot carry traffic"
            % (catch.get("delta"), catch_timeout_s))
    if int(catch.get("hdr_match", 0)) != 1:
        raise GateError(
            "delivery-proof: header mismatch — first popped word != "
            "0x%08x (got %s)" % (regmap.HDR_4WORD, catch.get("words")))

    return ({"base_occ": base_occ, "delta": catch["delta"],
             "words": catch["words"],
             "master_obs": {k: m_obs.get(k) for k in
                            ("fcsm", "fe_rx_credit_max", "fc_obs_live",
                             "pair_credits")},
             }, warnings)


# ── Jam sentinel (signature matrix per unjam_fc_node.sh) ─────────────────

def sample_excursion(sample: dict) -> Optional[str]:
    """Inspect one agent sample for an FCSM excursion or a known jam
    signature. Returns a FAIL reason string, or None when healthy."""
    fcsm = sample.get("fcsm")
    if fcsm is None:
        return None
    status = {
        "fcsm": fcsm,
        "a2l_replay_app_valid": sample.get("a2l_replay_app_valid", 0),
        "a2l_fc_replay_link_valid": sample.get(
            "a2l_fc_replay_link_valid", 0),
        "fe_rx_is_full": sample.get("fe_rx_is_full", 0),
    }
    jam = regmap.classify_jam(status)
    if jam is not None:
        return ("jam signature %s on %s (fcsm=%d a2l_app=%d a2l_lnk=%d "
                "fe_full=%d) — see unjam_fc_node.sh"
                % (jam, sample.get("board", "?"), fcsm,
                   status["a2l_replay_app_valid"],
                   status["a2l_fc_replay_link_valid"],
                   status["fe_rx_is_full"]))
    if fcsm not in regmap.FCSM_HEALTHY:
        return ("link_excursion: %s FCSM=%d left {4,5}"
                % (sample.get("board", "?"), fcsm))
    return None


# ── Cross-toolkit single-experiment mutex ─────────────────────────────────

class ExperimentMutex:
    """Advisory ``flock`` shared with the sibling toolkits + CLI.

    Default path ``~/.tidelink-hw.lock``. Held for the whole run; a
    second acquire (from this or any cooperating process) raises
    MutexHeld."""

    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path or
                         os.environ.get("TIDELINK_HW_LOCK",
                                        str(Path.home()
                                            / ".tidelink-hw.lock")))
        self._fd: Optional[int] = None

    @property
    def held(self) -> bool:
        return self._fd is not None

    def acquire(self, owner: str = "throughput_gui") -> None:
        if self._fd is not None:
            raise MutexHeld("this server already holds the mutex")
        fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise MutexHeld(
                "hardware mutex %s held by another experiment "
                "(eye/stress GUI or CLI?) — one experiment at a time"
                % self.path)
        os.ftruncate(fd, 0)
        os.write(fd, ("%s pid=%d\n" % (owner, os.getpid())).encode())
        self._fd = fd

    def release(self) -> None:
        if self._fd is None:
            return
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
            self._fd = None

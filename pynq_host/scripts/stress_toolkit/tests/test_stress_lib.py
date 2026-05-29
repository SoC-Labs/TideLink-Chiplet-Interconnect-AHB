"""Unit tests for the stress_toolkit shared library — parsers, packet
helpers, PHY health anomaly detection. No SSH, no FastAPI."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[4]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from pynq_host.scripts.stress_toolkit.stress_lib import (
    PhyHealth,
    expected_credits_after_write,
    offset_ns,
    packet_total_words,
    parse_ecc_counters,
    parse_lane_status,
    phy_health_anomalies,
    read_phy_health,
    wiring_status_name,
)


# ── parse_lane_status ────────────────────────────────────────────────────

def test_parse_lane_status_zeros():
    ls = parse_lane_status(0)
    assert ls.locked_mask == 0
    assert ls.lock_count == 0
    assert ls.fault_count == 0
    assert ls.fcsm_state == 0
    assert ls.link_idle
    assert not ls.cal_done


def test_parse_lane_status_link_up():
    # All 8 lanes locked, cal_done=1, FCSM=0 (LINK_IDLE)
    raw = 0x0001_00FF
    ls = parse_lane_status(raw)
    assert ls.locked_mask == 0xFF
    assert ls.lock_count == 8
    assert ls.cal_done
    assert ls.link_idle


def test_parse_lane_status_fcsm_wedge():
    # FCSM in state 1 ("wedges at 1 in the credit-path failure")
    raw = (1 << 17)
    ls = parse_lane_status(raw)
    assert ls.fcsm_state == 1
    assert not ls.link_idle


def test_parse_lane_status_packet_flags():
    raw = (1 << 23) | (1 << 24) | (1 << 29)
    ls = parse_lane_status(raw)
    assert ls.cr_pkt_seen and ls.crack_pkt_seen and ls.llrx_valid


# ── parse_ecc_counters ───────────────────────────────────────────────────

def test_parse_ecc_counters_packed():
    raw = (0x1234 << 16) | 0x0005
    d = parse_ecc_counters(raw)
    assert d["ecc_corrupted_cnt"] == 0x0005
    assert d["ecc_corrected_cnt"] == 0x1234
    assert not d["ecc_corrupted_saturated"]
    assert not d["ecc_corrected_saturated"]


def test_parse_ecc_counters_saturated():
    raw = (0xFFFF << 16) | 0xFFFF
    d = parse_ecc_counters(raw)
    assert d["ecc_corrupted_saturated"]
    assert d["ecc_corrected_saturated"]


# ── PHY health ───────────────────────────────────────────────────────────

def _phy_regs_clean(reg: dict) -> None:
    reg[0x00] = 0x33333333   # all lanes thresh=3
    reg[0x04] = reg[0x08] = 0  # raw 0
    reg[0x0C] = reg[0x10] = 0  # voted 0
    reg[0x14] = 0x2            # mode = mean
    reg[0x18] = 0x5555         # all 8 lanes -> 1 (OK)
    reg[0x1C] = 0xFFFF         # all canary_pass + canary_valid


def test_read_phy_health_clean():
    reg = {}
    _phy_regs_clean(reg)
    h = read_phy_health(lambda a: reg[a - 0x4403_2160],
                        base=0x4403_2160)
    assert all(t == 3 for t in h.thresh)
    assert all(n == 0 for n in h.noise_raw)
    assert all(n == 0 for n in h.noise_voted)
    assert all(w == 1 for w in h.wiring_status)
    assert all(h.canary_pass)
    assert all(h.canary_valid)
    assert h.noise_mode == 2  # mean
    assert phy_health_anomalies(h) == []


def test_phy_health_canary_fail_anomaly():
    reg = {}
    _phy_regs_clean(reg)
    # Clear canary_pass[3] but leave valid[3] set
    reg[0x1C] = (1 << 11) | (0xFF ^ (1 << 3))  # valid[3]=1, pass[3]=0
    # Actually rebuild explicitly: pass = 0xF7 (bit3 clear), valid = 0xFF.
    reg[0x1C] = (0xFF << 8) | 0xF7
    h = read_phy_health(lambda a: reg[a - 0x4403_2160],
                        base=0x4403_2160)
    anomalies = phy_health_anomalies(h)
    assert any("lane 3" in a and "canary" in a for a in anomalies)


def test_phy_health_wiring_swapped_anomaly():
    reg = {}
    _phy_regs_clean(reg)
    # Lane 0 -> SWAPPED (code 2), others OK
    # All lanes OK (code 1) = 0x5555; lane 0 to swapped (code 2) clears
    # bit0 and sets bit1: -> ...01 -> ...10
    reg[0x18] = 0x5556
    h = read_phy_health(lambda a: reg[a - 0x4403_2160],
                        base=0x4403_2160)
    anomalies = phy_health_anomalies(h)
    assert any("WIRING_SWAPPED" in a for a in anomalies)


def test_phy_health_structured_noise_alarm():
    reg = {}
    _phy_regs_clean(reg)
    # Force lane 2 raw=4 voted=4 — structured-noise (§5).
    reg[0x04] = (4 << 16)
    reg[0x0C] = (4 << 16)
    h = read_phy_health(lambda a: reg[a - 0x4403_2160],
                        base=0x4403_2160)
    anomalies = phy_health_anomalies(h)
    assert any("lane 2" in a and "structured-noise" in a
               for a in anomalies)


def test_wiring_status_name_codes():
    assert wiring_status_name(0) == "UNKNOWN"
    assert wiring_status_name(1) == "OK"
    assert wiring_status_name(2) == "SWAPPED"
    assert wiring_status_name(3) == "DEAD"


# ── Packet helpers ───────────────────────────────────────────────────────

def test_packet_total_words():
    assert packet_total_words([]) == 2  # header only
    assert packet_total_words([0xAA]) == 3
    assert packet_total_words([0]*256) == 258


def test_expected_credits_after_write():
    assert expected_credits_after_write(4096, [0xAA, 0xBB, 0xCC]) == 4091
    assert expected_credits_after_write(4096, []) == 4094


# ── PTP offset_ns ────────────────────────────────────────────────────────

def test_offset_ns_same_second():
    m = (100, 5_000_000, 0)
    s = (100, 5_000_200, 0)
    assert offset_ns(m, s) == 200


def test_offset_ns_seconds_diff():
    m = (100, 0, 0)
    s = (101, 500_000_000, 0)
    assert offset_ns(m, s) == 1_500_000_000


def test_offset_ns_negative():
    m = (100, 1_000_000, 0)
    s = (100, 500_000, 0)
    assert offset_ns(m, s) == -500_000

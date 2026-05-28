"""Deep-mode unit tests — mocked remote I/O.

These tests exercise the host-side protocol contract for Region 10
without touching live hardware. The remote register file is replaced
with an in-memory dict whose .read()/.write() record every access in
order, so we can assert sequencing, masking, and decode behaviour.

Keep these tests under 5 seconds wall-clock total — sleep is stubbed.
"""

import pytest

import eye_sweep
from eye_sweep import (
    EYE_BURST_DATA,
    EYE_BURST_READS,
    EYE_CTRL_AUTO_INCREMENT,
    EYE_CTRL_ENTER,
    EYE_CTRL_FORCE_FULL_SWEEP,
    EYE_CTRL_MODE_SINGLE,
    EYE_POINTS_PER_LANE,
    EYE_SCORE_IDX,
    EYE_SCORES_PER_WORD,
    EYE_STATE_DONE,
    EYE_STATE_SWEEPING,
    PEER_APERTURE_BASE,
    PEER_EYE_REGION10,
    RemoteIO,
    SWI_EYE_CTRL,
    SWI_EYE_DWELL_US,
    SWI_EYE_LANE_SEL,
    SWI_EYE_STATUS,
    _PeerApertureIO,
    collect_deep,
    decode_burst_word,
    sweep_deep_per_lane,
)


# ---------------------------------------------------------------------------
# Mock IO
# ---------------------------------------------------------------------------

class FakeIO(RemoteIO):
    """In-memory register file. Records every read/write in `log`.

    A `status_script` controls what successive reads of SWI_EYE_STATUS
    return — typically [SWEEPING, SWEEPING, DONE] to model the polling
    loop without depending on time. A `burst_script` does the same for
    EYE_BURST_DATA reads."""

    def __init__(self, status_script=None, burst_script=None):
        self.regs = {}
        self.log = []
        self.status_script = list(status_script or [EYE_STATE_DONE])
        self.burst_script = list(burst_script or [])
        self._status_idx = 0
        self._burst_idx = 0

    def read(self, addr: int) -> int:
        self.log.append(("R", addr))
        if addr == SWI_EYE_STATUS:
            i = min(self._status_idx, len(self.status_script) - 1)
            self._status_idx += 1
            return self.status_script[i]
        if addr == EYE_BURST_DATA:
            if self._burst_idx < len(self.burst_script):
                v = self.burst_script[self._burst_idx]
                self._burst_idx += 1
                return v
            return 0
        return self.regs.get(addr, 0)

    def write(self, addr: int, value: int) -> None:
        self.log.append(("W", addr, value))
        self.regs[addr] = value


def _no_sleep(_):
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_burst_word_decodes_five_six_bit_scores():
    # pack scores 1,2,3,4,5 into one 32-bit word
    w = 1 | (2 << 6) | (3 << 12) | (4 << 18) | (5 << 24)
    assert decode_burst_word(w) == [1, 2, 3, 4, 5]
    # max 6-bit value
    w = 63 | (63 << 6) | (63 << 12) | (63 << 18) | (63 << 24)
    assert decode_burst_word(w) == [63] * 5
    # bits 30..31 are reserved and must NOT leak into score 4
    w = (0b11 << 30) | (42 << 24)
    assert decode_burst_word(w)[4] == 42


def test_status_decode_fields():
    raw = (EYE_STATE_DONE        # state
           | (5 << 4)             # last_swept_lane_id
           | (1 << 7)             # capture_valid
           | (0xA << 8)           # cal_state_mirror
           | (0xC << 12)          # sweep_phase
           | (1234 << 16))        # dwell_remaining_ms
    st = eye_sweep.decode_eye_status(raw)
    assert st["state"] == EYE_STATE_DONE
    assert st["last_swept_lane_id"] == 5
    assert st["capture_valid"] == 1
    assert st["cal_state_mirror"] == 0xA
    assert st["sweep_phase"] == 0xC
    assert st["dwell_remaining_ms"] == 1234


def test_deep_mode_single_lane_register_sequence():
    io = FakeIO(status_script=[EYE_STATE_SWEEPING, EYE_STATE_DONE])
    events = list(sweep_deep_per_lane(io, dwell_us=100_000, lanes=[3],
                                      mode='single', sleep_fn=_no_sleep))
    assert len(events) == 1
    assert events[0]["lane"] == 3

    writes = [e for e in io.log if e[0] == "W"]
    # LANE_SEL → DWELL_US → CTRL → (poll loop) → EYE_SCORE_IDX
    assert writes[0] == ("W", SWI_EYE_LANE_SEL, 3)
    assert writes[1] == ("W", SWI_EYE_DWELL_US, 100_000)
    ctrl_write = writes[2]
    assert ctrl_write[1] == SWI_EYE_CTRL
    expected_ctrl = (EYE_CTRL_ENTER | EYE_CTRL_MODE_SINGLE
                     | EYE_CTRL_FORCE_FULL_SWEEP)
    assert ctrl_write[2] == expected_ctrl, (
        f"CTRL bits mismatch: got 0x{ctrl_write[2]:x}, "
        f"want 0x{expected_ctrl:x}")
    assert (EYE_CTRL_AUTO_INCREMENT & ctrl_write[2]) == 0, \
        "single mode must NOT set AUTO_INCREMENT_LANE"
    assert writes[3] == ("W", EYE_SCORE_IDX, 1 << 16)


def test_deep_mode_polls_status_until_done():
    # 4 SWEEPING reads then DONE — generator must keep polling
    io = FakeIO(status_script=[EYE_STATE_SWEEPING] * 4 + [EYE_STATE_DONE])
    list(sweep_deep_per_lane(io, dwell_us=100_000, lanes=[0],
                             mode='single', sleep_fn=_no_sleep))
    status_reads = [e for e in io.log if e == ("R", SWI_EYE_STATUS)]
    assert len(status_reads) == 5  # 4 SWEEPING + 1 DONE


def test_deep_mode_drains_26_burst_reads_per_lane():
    # Build a burst script where read i returns scores [i*5..i*5+4].
    # After 26 reads we get 130 values; toolkit must trim to 128.
    bursts = []
    for i in range(EYE_BURST_READS):
        base = i * EYE_SCORES_PER_WORD
        word = sum(((base + j) & 0x3F) << (6 * j) for j in range(5))
        bursts.append(word)
    io = FakeIO(status_script=[EYE_STATE_DONE], burst_script=bursts)
    events = list(sweep_deep_per_lane(io, dwell_us=1_000, lanes=[0],
                                      mode='single', sleep_fn=_no_sleep))
    assert len(events[0]["scores"]) == EYE_POINTS_PER_LANE
    burst_reads = [e for e in io.log if e == ("R", EYE_BURST_DATA)]
    assert len(burst_reads) == EYE_BURST_READS


def test_collect_deep_returns_dict_of_lists():
    io = FakeIO(status_script=[EYE_STATE_DONE] * 8)
    out = collect_deep(io, dwell_us=1_000, lanes=range(8),
                       mode='single', sleep_fn=_no_sleep)
    assert set(out.keys()) == set(range(8))
    for lane, scores in out.items():
        assert len(scores) == EYE_POINTS_PER_LANE


def test_auto_increment_mode_issues_one_enter_waits_eight_dones():
    # AUTO_INCREMENT: 1 ENTER, then 8 successive DONEs across 8 lanes.
    # Stub status to always be DONE so each poll exits immediately.
    io = FakeIO(status_script=[EYE_STATE_DONE])
    events = list(sweep_deep_per_lane(io, dwell_us=1_000, lanes=range(8),
                                      mode='auto_increment',
                                      sleep_fn=_no_sleep))
    assert len(events) == 8

    ctrl_writes = [e for e in io.log
                   if e[0] == "W" and e[1] == SWI_EYE_CTRL]
    assert len(ctrl_writes) == 1, \
        f"auto_increment must issue exactly one ENTER, got {len(ctrl_writes)}"
    ctrl_val = ctrl_writes[0][2]
    assert ctrl_val & EYE_CTRL_AUTO_INCREMENT, \
        "auto_increment must set AUTO_INCREMENT_LANE bit"
    assert ctrl_val & EYE_CTRL_ENTER, "must set ENTER"
    assert ctrl_val & EYE_CTRL_MODE_SINGLE, "must set MODE=SINGLE"
    assert ctrl_val & EYE_CTRL_FORCE_FULL_SWEEP, \
        "must set FORCE_FULL_SWEEP"

    lane_sel_writes = [e for e in io.log
                       if e[0] == "W" and e[1] == SWI_EYE_LANE_SEL]
    assert len(lane_sel_writes) == 1, \
        "auto_increment must write LANE_SEL only for the first lane"


def test_deep_mode_timeout_when_status_stays_sweeping():
    io = FakeIO(status_script=[EYE_STATE_SWEEPING])  # never reaches DONE
    # dwell_us=1 → timeout_s = max(1.0, 2e-6) = 1.0 s; with sleep stubbed
    # the polling loop spins until wall-clock exceeds 1.0 s.
    with pytest.raises(TimeoutError):
        list(sweep_deep_per_lane(io, dwell_us=1, lanes=[0],
                                 mode='single', sleep_fn=_no_sleep))


def test_peer_aperture_uses_0x40032140():
    """Explicit guard: peer aperture rebases Region 10 to 0x40032140.

    Anyone who 'fixes' this by routing through 0x44010000 (the LOCAL RX
    FIFO base — a well-documented gotcha in the address-map memory)
    fails this test loudly."""
    assert PEER_EYE_REGION10 == 0x40032140
    assert PEER_APERTURE_BASE == 0x40000000
    assert PEER_EYE_REGION10 != 0x44010000
    assert PEER_EYE_REGION10 != (0x44010000 + 0x22140)
    # And the rebase logic itself:
    assert _PeerApertureIO._rebase(SWI_EYE_CTRL) == 0x40032140
    assert _PeerApertureIO._rebase(SWI_EYE_LANE_SEL) == 0x40032144
    assert _PeerApertureIO._rebase(SWI_EYE_DWELL_US) == 0x40032148
    assert _PeerApertureIO._rebase(SWI_EYE_STATUS) == 0x4003214C
    assert _PeerApertureIO._rebase(EYE_BURST_DATA) == 0x4003216C
    # Non-Region-10 addresses pass through unchanged.
    assert _PeerApertureIO._rebase(0x44030000) == 0x44030000
    assert _PeerApertureIO._rebase(0x44032108) == 0x44032108


def test_peer_aperture_writes_hit_remote_addresses(monkeypatch):
    """Verify SSHRemoteIO + _PeerApertureIO route through remote_write/
    remote_read with the rebased addresses, not the local ones."""
    seen_writes = []
    seen_reads = []

    def fake_write(ip, addr, val, password=None):
        seen_writes.append((ip, addr, val))

    def fake_read(ip, addr, password=None):
        seen_reads.append((ip, addr))
        return EYE_STATE_DONE if addr == 0x4003214C else 0

    monkeypatch.setattr(eye_sweep, "remote_write", fake_write)
    monkeypatch.setattr(eye_sweep, "remote_read", fake_read)

    peer = _PeerApertureIO("10.0.0.1", "pw")
    peer.write(SWI_EYE_LANE_SEL, 2)
    peer.write(SWI_EYE_DWELL_US, 1234)
    peer.write(SWI_EYE_CTRL, EYE_CTRL_ENTER)
    peer.read(SWI_EYE_STATUS)

    addrs = [w[1] for w in seen_writes]
    assert addrs == [0x40032144, 0x40032148, 0x40032140], \
        f"peer-aperture writes hit {addrs}, expected 0x4003214x range"
    assert seen_reads == [("10.0.0.1", 0x4003214C)]


def test_global_mode_still_works(monkeypatch):
    """v1 sweep_global_phase API contract MUST not be disturbed by v2."""
    calls = []

    def fake_read(addr):
        calls.append(("R", addr))
        return 0xFF  # all lanes locked

    def fake_write(addr, shift, mask, val):
        calls.append(("W", addr, shift, mask, val))

    rows = list(eye_sweep.iter_sweep_global_phase(
        "1.2.3.4", settle_s=0,
        sleep_fn=_no_sleep,
        read_fn=fake_read,
        write_fn=fake_write))
    assert len(rows) == 16
    assert all(r["lock_count"] == 8 for r in rows)
    # PHY_CTRL phase field is restored on cleanup
    final_writes = [c for c in calls if c[0] == "W"]
    assert final_writes[-1][1] == eye_sweep.PHY_CTRL_ADDR

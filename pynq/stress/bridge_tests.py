#-----------------------------------------------------------------------------
# TideLink FPGA Stress Suite - 16-test bridge catalogue
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Each test is a plain (non-async) function:
#   test_fn(local_hw, peer) -> (ok: bool, errors: list[str], counters: dict)
#
# `local_hw`  : TidelinkHw instance for the local board.
# `peer`      : PeerProxy instance (pair tests) or None (solo tests).
#
# Tags:
#   "solo"          — runs with only the local board loaded.
#   "pair"          — requires peer_agent on the partner board.
#   "skip"          — skip by default (e.g. needs PHC hardware).
#
# 5 tests are fully implemented, drawing from pynq/test_loopback_pair.py:
#   smoke_pair_alive, sync_pair, bidirectional, credit_exhaustion,
#   doorbell_handshake.
#
# The remaining 11 are stubs returning (False, ["TODO: implement"], {}).
# Each stub has a comment pointing at its cocotb / UVM source.
#-----------------------------------------------------------------------------

import time

from tidelink.regs import MAX_CREDITS, REG_DOORBELL_RESP_ACC, REG_RELEASED_ACC
from .prbs import packet_words

# ── Registry helpers ─────────────────────────────────────────────────────────

_CATALOGUE = []   # list of dicts, order == display order


def _test(test_id, tags, description):
    """Decorator — registers a test function into the catalogue."""
    def _wrap(fn):
        _CATALOGUE.append({
            'id':          test_id,
            'tags':        tags,
            'description': description,
            'fn':          fn,
        })
        return fn
    return _wrap


# ── Peer proxy helpers ───────────────────────────────────────────────────────
# `peer` is a PeerProxy object (see runner.py). It exposes:
#   peer.call(method, **params) -> result
#   peer.get_credit_count() -> int
#   peer.flush()
#   peer.wait_returner_idle(timeout_ms)

def _peer_credits(peer):
    return peer.call('get_credit_count')


def _peer_flush(peer):
    peer.call('flush')


def _peer_wait_idle(peer, timeout_ms=200):
    peer.call('wait_returner_idle', timeout_ms=timeout_ms)


# ────────────────────────────────────────────────────────────────────────────
# Test 1: smoke_pair_alive  (pair)
# Mirrors: pynq/test_loopback_pair.py Test 1 + Test 2
# ────────────────────────────────────────────────────────────────────────────

@_test('smoke_pair_alive', ['pair'],
       'Both sides report MAX_CREDITS; doorbell exchange after reset')
def smoke_pair_alive(local_hw, peer):
    errors = []

    # Local credits
    local_c = local_hw.read_credit_count()
    if local_c != MAX_CREDITS:
        errors.append(f'local credits={local_c} expected {MAX_CREDITS}')

    # Peer credits via RPC
    peer_c = _peer_credits(peer)
    if peer_c != MAX_CREDITS:
        errors.append(f'peer credits={peer_c} expected {MAX_CREDITS}')

    # Doorbell exchange: local rings peer, peer should accumulate MAX_CREDITS
    local_hw.cfg_write(REG_RELEASED_ACC, 0)   # clear
    local_hw.ring_doorbell()
    local_hw.wait_returner_idle(timeout_ms=200)
    time.sleep(0.005)

    # Peer reads its doorbell response accumulator (read-clears)
    peer_db_resp = peer.call('mmio_read', aperture='apb',
                             offset=REG_DOORBELL_RESP_ACC)
    if peer_db_resp != MAX_CREDITS:
        errors.append(
            f'peer doorbell_resp_acc={peer_db_resp} expected {MAX_CREDITS}')

    counters = {'credits_a': local_c, 'credits_b': peer_c,
                'bridge_lane_errors': 0}
    return len(errors) == 0, errors, counters


# ────────────────────────────────────────────────────────────────────────────
# Test 2: sync_pair  (pair)
# Mirrors: uvm tidelink_single_packet_test.sv
# ────────────────────────────────────────────────────────────────────────────

@_test('sync_pair', ['pair'],
       'A -> B single packet; RX matches TX')
def sync_pair(local_hw, peer):
    errors = []
    pkt_data = packet_words(seed=0xABCD1234, n_words=4)

    # Set threshold=0 for immediate release
    local_hw.set_rel_threshold(0)
    # Clear peer's released accumulator
    peer.call('mmio_read', aperture='apb', offset=REG_RELEASED_ACC)

    # Write packet locally (goes through AHB TX -> returner -> peer RX FIFO)
    local_hw.write_packet(pkt_data)
    credits_after = local_hw.read_credit_count()
    expected_credits = MAX_CREDITS - (len(pkt_data) + 1)
    if credits_after != expected_credits:
        errors.append(
            f'credits after write={credits_after} expected {expected_credits}')

    # Read back locally (same FIFO for loopback config)
    rx_data = local_hw.read_packet()
    local_hw.wait_returner_idle()
    time.sleep(0.002)

    if rx_data != pkt_data:
        errors.append(f'rx mismatch: got {rx_data} expected {pkt_data}')

    # Peer's released_acc should have the credit delta
    released_at_peer = peer.call('mmio_read', aperture='apb',
                                 offset=REG_RELEASED_ACC)
    expected_delta = len(pkt_data) + 1
    if released_at_peer != expected_delta:
        errors.append(
            f'peer released_acc={released_at_peer} expected {expected_delta}')

    credits_restored = local_hw.read_credit_count()
    if credits_restored != MAX_CREDITS:
        errors.append(
            f'credits not restored: {credits_restored} expected {MAX_CREDITS}')

    counters = {
        'credits_a': credits_restored,
        'credits_b': _peer_credits(peer),
        'bridge_lane_errors': 0,
    }
    return len(errors) == 0, errors, counters


# ────────────────────────────────────────────────────────────────────────────
# Test 3: bidirectional  (pair)
# Mirrors: uvm tidelink_bidirectional_test (not yet in UVM tree — see plan)
# ────────────────────────────────────────────────────────────────────────────

@_test('bidirectional', ['pair'],
       'Concurrent A <-> B packets; no deadlock')
def bidirectional(local_hw, peer):
    errors = []
    pkt_a = packet_words(seed=0x11110000, n_words=3)
    pkt_b = packet_words(seed=0x22220000, n_words=3)

    local_hw.set_rel_threshold(0)
    peer.call('mmio_write', aperture='apb', offset=0x004, value=0)  # REG_REL_THRESHOLD

    # Write from both sides
    local_hw.write_packet(pkt_a)
    peer.call('mmio_write', aperture='ahb_tx', offset=0x0000, value=len(pkt_b))
    for i, w in enumerate(pkt_b):
        peer.call('mmio_write', aperture='ahb_tx', offset=(i + 1) * 4, value=w)

    time.sleep(0.010)

    # Read back on both sides
    rx_a = local_hw.read_packet()
    local_hw.wait_returner_idle()

    peer_pkt_len = peer.call('mmio_read', aperture='apb', offset=0x008)
    rx_b = [peer.call('mmio_read', aperture='ahb_fifo', offset=(i + 1) * 4)
            for i in range(peer_pkt_len)]

    if rx_a != pkt_a:
        errors.append(f'A->B rx mismatch: got {rx_a}')
    if rx_b != pkt_b:
        errors.append(f'B->A rx mismatch: got {rx_b}')

    ca = local_hw.read_credit_count()
    cb = _peer_credits(peer)
    counters = {'credits_a': ca, 'credits_b': cb, 'bridge_lane_errors': 0}
    return len(errors) == 0, errors, counters


# ────────────────────────────────────────────────────────────────────────────
# Test 4: credit_exhaustion  (pair)
# Mirrors: uvm tidelink_stall_test.sv / cocotb test_06_write_packets_then_pair_resets
# ────────────────────────────────────────────────────────────────────────────

@_test('credit_exhaustion', ['pair'],
       'TX blocks when credits=0; recovers when peer drains')
def credit_exhaustion(local_hw, peer):
    errors = []
    local_hw.set_rel_threshold(0)

    # Fill until credits are exhausted
    n_words_per_pkt = 8   # 9 words per packet (incl. length word)
    max_pkts = MAX_CREDITS // 9
    written = 0
    for i in range(max_pkts):
        pkt = packet_words(seed=i, n_words=8)
        local_hw.write_packet(pkt)
        written += 1
        if local_hw.read_credit_count() < 9:
            break

    credits_at_exhaustion = local_hw.read_credit_count()
    if credits_at_exhaustion >= 9:
        errors.append(
            f'expected near-zero credits, got {credits_at_exhaustion}')

    # Drain one packet on local side -> returner should release credits to peer
    rx = local_hw.read_packet()
    local_hw.wait_returner_idle(timeout_ms=300)
    time.sleep(0.005)

    credits_after_drain = local_hw.read_credit_count()
    if credits_after_drain <= credits_at_exhaustion:
        errors.append(
            f'credits did not recover after drain: {credits_after_drain}')

    ca = credits_after_drain
    cb = _peer_credits(peer)
    counters = {
        'credits_a': ca, 'credits_b': cb,
        'bridge_lane_errors': 0,
        'pkts_written': written,
    }
    return len(errors) == 0, errors, counters


# ────────────────────────────────────────────────────────────────────────────
# Test 5: doorbell_handshake  (pair)
# Mirrors: pynq/test_loopback_pair.py Test 4 + cocotb test_doorbell.py
# ────────────────────────────────────────────────────────────────────────────

@_test('doorbell_handshake', ['pair'],
       'Software doorbell A->B; B accumulator updated; IRQ implied')
def doorbell_handshake(local_hw, peer):
    errors = []

    # Clear peer's doorbell response accumulator first
    peer.call('mmio_read', aperture='apb', offset=REG_DOORBELL_RESP_ACC)

    # Ring the doorbell from local side
    local_hw.ring_doorbell()
    local_hw.wait_returner_idle(timeout_ms=200)
    time.sleep(0.003)

    # Peer reads its doorbell response — should equal local MAX_CREDITS
    db_resp = peer.call('mmio_read', aperture='apb',
                        offset=REG_DOORBELL_RESP_ACC)
    if db_resp != MAX_CREDITS:
        errors.append(
            f'peer doorbell_resp_acc={db_resp} expected {MAX_CREDITS}')

    # Reciprocal: peer rings local doorbell
    local_hw.read_doorbell_resp()   # clear local accumulator
    peer.call('mmio_write', aperture='apb', offset=0x014, value=1)  # REG_DOORBELL
    _peer_wait_idle(peer, timeout_ms=200)
    time.sleep(0.003)

    local_resp = local_hw.read_doorbell_resp()
    peer_credits = _peer_credits(peer)
    if local_resp != peer_credits and local_resp != MAX_CREDITS:
        errors.append(
            f'local doorbell_resp_acc={local_resp} expected {peer_credits}')

    counters = {
        'credits_a': local_hw.read_credit_count(),
        'credits_b': _peer_credits(peer),
        'bridge_lane_errors': 0,
    }
    return len(errors) == 0, errors, counters


# ────────────────────────────────────────────────────────────────────────────
# Tests 6-16: stubs
# ────────────────────────────────────────────────────────────────────────────

@_test('back_to_back', ['pair'],
       'Saturate TX with no inter-packet gap; no loss')
def back_to_back(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_random_test.sv back-to-back sequence.
    # Write N packets without waiting between them, drain all, verify credit balance.
    return False, ['TODO: implement back_to_back'], {}


@_test('max_packet', ['pair'],
       'Largest legal packet (MAX_CREDITS-1 data words)')
def max_packet(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_single_packet_test.sv with max payload.
    # Write one packet of MAX_CREDITS-1 data words (fills FIFO), read back, verify.
    return False, ['TODO: implement max_packet'], {}


@_test('credit_threshold_batching', ['pair'],
       'Set REL_THRESHOLD>0; verify credits batch before release')
def credit_threshold_batching(local_hw, peer):
    # TODO: implement — mirror cocotb tidelink_py_pair/test_credit_flow.py.
    # Set threshold=10, write 3 packets (acc<10 -> no release), 4th triggers.
    # See pynq/test_loopback_pair.py Test 5 for hardware equivalent.
    return False, ['TODO: implement credit_threshold_batching'], {}


@_test('sideband_stress', ['pair'],
       'Sideband traffic interleaved with main data')
def sideband_stress(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_random_test.sv sideband interleave.
    # Send doorbell rings while concurrent data packets are in flight; verify
    # neither channel stalls or corrupts the other.
    return False, ['TODO: implement sideband_stress'], {}


@_test('interleaved_types', ['pair'],
       'Mix transparent AHB + FIFO packet types in same window')
def interleaved_types(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_random_test.sv mixed-type sequence.
    # Use ahb_tx (transparent AHB) and ahb_fifo alternately; check ordering.
    return False, ['TODO: implement interleaved_types'], {}


@_test('error_injection', ['pair'],
       'Out-of-range AHB read; link recovers cleanly')
def error_injection(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_stall_test.sv error recovery path.
    # Issue an AHB read to an unmapped offset, verify STATUS.master_error asserts,
    # then clear and confirm subsequent valid transactions succeed.
    return False, ['TODO: implement error_injection'], {}


@_test('reset_recovery', ['pair'],
       'Toggle one board reset mid-traffic; traffic resumes')
def reset_recovery(local_hw, peer):
    # TODO: implement — mirror uvm tidelink_base_test.sv reset mid-sequence.
    # Start a burst of packets, soft-reset local side (REG_CTRL EN=0 then EN=1),
    # verify doorbell handshake re-establishes and credits return to MAX_CREDITS.
    return False, ['TODO: implement reset_recovery'], {}


@_test('long_running', ['pair'],
       '10-minute soak; credit drift == 0 at end (budget override honoured)')
def long_running(local_hw, peer):
    # TODO: implement — mirror uvm long-running soak (not yet in uvm/tidelink/).
    # Run repeated write/read cycles for args.budget seconds, accumulate credit
    # delta on both sides, assert == 0 at end. Use prbs.packet_words for payload.
    return False, ['TODO: implement long_running'], {}


@_test('congestion_estimator', ['solo', 'pair'],
       'Watch tl_local_link_state_o walk under load; log state transitions')
def congestion_estimator(local_hw, peer):
    # TODO: implement — mirror cocotb tidelink/test_tidelink.py congestion probe.
    # Fill FIFO to 80%, poll REG_LINK_STATE_MIRROR every 10 ms for 30 s,
    # record state histogram. Pass if state reaches >= 3 at peak load.
    return False, ['TODO: implement congestion_estimator'], {}


@_test('bridge_glitch', ['pair'],
       'Semi-manual: inject brief power wobble on link ribbon; log errors')
def bridge_glitch(local_hw, peer):
    # TODO: implement — FPGA-only test with no simulation equivalent.
    # Prompt operator to briefly pull/re-seat the SFP/ribbon cable, then
    # check STATUS.master_error count and REG_LINK_STATE_MIRROR transitions.
    # Gate on interactive flag --allow-manual.
    return False, ['TODO: implement bridge_glitch (semi-manual, operator required)'], {}


# ────────────────────────────────────────────────────────────────────────────
# Test 17: lane_mask_burnt_lane  (pair)
# Walks the lane mask through every "drop one lane" configuration on both
# ends, runs a single packet round-trip per configuration, and confirms
# the link still carries traffic. Restores mask=0xFF at the end so it
# doesn't poison other tests in the same session.
#
# Programs both sides via APB before each sub-iteration. The mismatch
# window between A's write and B's write is small (<5ms in practice);
# we then sleep 10ms before sending a probe packet so any in-flight
# bytes from the previous mask flush out.
# ────────────────────────────────────────────────────────────────────────────

@_test('lane_mask_burnt_lane', ['pair'],
       'Drop each physical lane in turn; verify link still ferries traffic')
def lane_mask_burnt_lane(local_hw, peer):
    errors = []
    counters = {'lanes_passed': 0, 'lanes_failed': 0}

    full_mask = 0xFF  # 8-lane build
    lane_mask_off = 0x214

    def _write_mask_both(mask):
        # Pack tx/rx fields into 32-bit register: tx=[15:0], rx=[31:16]
        word = (mask & 0xFFFF) | ((mask & 0xFFFF) << 16)
        local_hw.cfg_write(lane_mask_off, word)
        peer.call('mmio_write', aperture='apb', offset=lane_mask_off, value=word)
        time.sleep(0.010)  # let in-flight bytes drain

    try:
        for k in range(8):
            mask = full_mask & ~(1 << k)
            _write_mask_both(mask)

            # Verify both ends saw the write and active_lanes derives correctly.
            local_lm = local_hw.cfg_read(lane_mask_off)
            peer_lm  = peer.call('mmio_read', aperture='apb', offset=lane_mask_off)
            if (local_lm & 0xFFFF) != mask or (peer_lm & 0xFFFF) != mask:
                errors.append(
                    f'lane {k}: mask readback mismatch local=0x{local_lm:08x} '
                    f'peer=0x{peer_lm:08x} expected tx={mask:#x}')
                counters['lanes_failed'] += 1
                continue

            # Probe: send a packet from local, read it back on peer's FIFO.
            # Mirrors the bidirectional test pattern: peer reads packet length
            # from APB offset 0x008 then reads ahb_fifo word-by-word.
            pkt = packet_words(seed=0xBEEF_0000 | k, n_words=4)
            try:
                local_hw.write_packet(pkt, skip_link_check=True)
                time.sleep(0.010)
                local_hw.wait_returner_idle()
                peer_pkt_len = peer.call('mmio_read', aperture='apb',
                                          offset=0x008)
                rx = [peer.call('mmio_read', aperture='ahb_fifo',
                                 offset=(i + 1) * 4)
                       for i in range(peer_pkt_len)]
            except Exception as exc:  # noqa: BLE001
                errors.append(f'lane {k} masked: probe raised {exc!r}')
                counters['lanes_failed'] += 1
                continue

            if rx != pkt:
                errors.append(f'lane {k} masked: rx mismatch got {rx} expected {pkt}')
                counters['lanes_failed'] += 1
            else:
                counters['lanes_passed'] += 1
    finally:
        # Always restore the default mask so subsequent tests see the link
        # at full width.
        _write_mask_both(full_mask)

    return len(errors) == 0, errors, counters


@_test('ptp_sync', ['pair', 'skip'],
       'Two-message PTP exchange (gated: requires PHC hardware)')
def ptp_sync(local_hw, peer):
    # TODO: implement — mirror uvm phc/test_initial_offset.sv (ptp-hardware-clock-ahb).
    # Requires both boards to have PHC overlay loaded (ahb_ptp aperture present).
    # Skipped by default (tagged 'skip'). Enable with --run-skipped.
    return False, ['TODO: implement ptp_sync (requires PHC overlay — Wave C4)'], {}


# ── Public catalogue ─────────────────────────────────────────────────────────

ALL_TESTS = {entry['id']: entry for entry in _CATALOGUE}

DEFAULT_BUDGETS = {
    'smoke_pair_alive':          30,
    'sync_pair':                 60,
    'bidirectional':             60,
    'back_to_back':              120,
    'max_packet':                60,
    'credit_exhaustion':         90,
    'credit_threshold_batching': 60,
    'doorbell_handshake':        60,
    'sideband_stress':           120,
    'interleaved_types':         120,
    'error_injection':           90,
    'reset_recovery':            90,
    'long_running':              600,
    'congestion_estimator':      90,
    'bridge_glitch':             120,
    'lane_mask_burnt_lane':      120,
    'ptp_sync':                  90,
}

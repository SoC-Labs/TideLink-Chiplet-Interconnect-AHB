# =============================================================================
# P1 (RX long-packet acceptance-gate deadlock) — SIM REPRODUCTION IS NOT
# ACHIEVABLE in this paired-die environment. This file documents why, and
# where the real regression guard lives. (SoC Labs 2026-07-03.)
#
# THE BUG (silicon, RXCAP-proven): WlinkRxLinkLayer's long_pkt_gate
# (`first_short_pkt_seen`) opened once during bootstrap (a whitelisted
# CR/CRACK short crossed), then a post-bringup llrx reset cleared it and it
# could NEVER re-latch -- the old whitelist was tl-family 0x44-47 only, and
# steady-state wire traffic was bFC keepalives 0x10/0x12 (NOT whitelisted).
# Every isolated data long was then silently swallowed at the hunt-state
# acceptance guard (RXCAP0: GATE=0 BLOCKED=1 ph=0x07a1 clean header,
# long_start_cnt=0, no valid, FCSM blind). Monopolizing storms delivered only
# because a NACK/replay eventually re-armed the gate.
#
# WHY SIM CANNOT REPRODUCE IT (three principled attempts, all rejected):
#  1. Traffic/training-pulse: clearing the gate then sending a long -- the sim
#     has NO bFC node, so the only steady-state m->s shorts are tl-family
#     ACKs (0x44-47), which ARE whitelisted and re-open the gate at the decode
#     instant. The gate never stays closed. (Silicon's keepalives were the
#     non-whitelisted 0x10/0x12, the whole reason the bug existed.)
#  2. Hierarchical deposit of first_short_pkt_seen=0 (hclk-rate): loses the
#     race against the framer re-latching from those legitimate shorts.
#  3. Framer-clock-synced deposit: even pinned, the 8-lane sim delivers the
#     isolated long regardless of the fix -- the sim's gate is simply open
#     (bootstrap opened it, nothing forces it shut), which is exactly WHY the
#     existing suite never caught P1 and the bug was silicon-only.
# A faithful sim repro would require modelling the bFC keepalive stream (a
# non-whitelisted short source) so the gate can be driven closed and held.
#
# THE REGRESSION GUARD IS ON SILICON: the RXCAP0 instrument
# (axi_chiplet_controller.sv, APB 0x4403_21A0) exposes BLOCKED[17] + live
# GATE[16] + the dying header ph[15:0]. A single isolated send + RXCAP read
# names a P1 regression outright (GATE=0/BLOCKED=1). Proven fixed 2026-07-03:
# RXCAP GATE 0->1 recovery + 28/28 byte-exact sustained delivery.
#
# The pair-level isolated-delivery smoke tests remain in
# test_v2_isolated_word{,_masked}.py (they assert isolated words deliver in
# sim -- necessary but not sufficient for P1, per the above).
# =============================================================================
import cocotb


@cocotb.test(skip=True)
async def test_p1_isolated_long_selfopens_gate(dut):
    """SKIPPED: P1 (gate-deadlock) is not reproducible in this sim -- see the
    module docstring. Guard is the on-silicon RXCAP0 GATE/BLOCKED read."""
    pass

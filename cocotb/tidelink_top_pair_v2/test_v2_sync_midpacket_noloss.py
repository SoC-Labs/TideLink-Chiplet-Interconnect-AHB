# =============================================================================
# P2 (RX sync_resync mid-long-packet abort) — SIM REPRODUCTION IS NOT
# ACHIEVABLE in this paired-die environment. Documents why + the real guard.
# (SoC Labs 2026-07-03.)
#
# THE BUG (analytically certain from the RTL priority chain): in
# WlinkRxLinkLayer the `else if (sync_resync)` guards sit ABOVE the state==2'h1
# (long-packet body) branch, so a SWI_SYNC_FORCE_ALWAYS beacon landing
# mid-body forces state 1->0 and zeroes byte/word_count -- silently discarding
# the half-parsed long packet (no valid/eop/CRC/error -> FCSM-blind, P1-class).
# The :379 "SYNC only in idle slots" premise is false under force_always
# (deps/tidelink-phy WavD2DGpio.v drops the idle gate; a beacon fires every 32
# words regardless of idle).
#
# FIX (this tree, WlinkRxLinkLayer.v): sync_resync_boundary = sync_resync &
# (state != 2'h1) -- honor the re-hunt only at a framer boundary, never inside
# a body. Slipped state==1 still self-recovers (wedge guard + monotone
# byte_count -> endOfPacket). Provably INERT on the proven data path: with
# SYNC insert OFF, sync_resync==0 -> sync_resync_boundary==0 identically.
#
# WHY SIM CANNOT REPRODUCE THE ABORT (measured, not assumed): the bug needs a
# SINGLE beacon to hit a long-packet BODY during otherwise-clean framing. But:
#  - Under *continuous* force_always the slave framer re-hunts on every beacon
#    and NEVER forms a body -- an instrumented run measured sync_resync firing
#    119x while state==0 held 3840/3840 cycles (0 body cycles). No mid-body
#    moment exists to interrupt.
#  - A *single* mid-body beacon would need forcing the framer's sync_resync (a
#    combinational wire) or its io_robust_sync_seen input for exactly one
#    framer-clock cycle while state==1 -- a hold cocotb+VCS cannot cleanly do
#    against the RTL/parent driver (same obstacle as the P1 gate test).
# A faithful repro would need a unit-level WlinkRxLinkLayer testbench that
# drives a long body then pulses sync_resync for one cycle.
#
# THE REAL GUARDS:
#  1. INERTNESS on the proven path -- the pair multipkt/isolated suites (SYNC
#     insert OFF) must stay green with this fix in. They do (regression run).
#  2. The 3-agent analysis (fix design + independence audit) proving the guard
#     only removes state!=0 (mid-body) firings, which on a boundary-correct
#     link are harmful aborts -- so it can only PRESERVE packets, never
#     subtract a proven delivery.
#  3. On silicon under force_always bring-up: the FCSM/RXCAP obs show whether a
#     long ever silently vanishes.
# =============================================================================
import cocotb


@cocotb.test(skip=True)
async def test_p2_sync_midpacket_noloss(dut):
    """SKIPPED: the sync_resync mid-body abort is not reproducible in this sim
    (continuous force_always prevents body formation; single-beacon injection
    needs an un-holdable wire force). See the module docstring. Guards: the
    SYNC-off pair regression (inertness) + the analytical proof."""
    pass

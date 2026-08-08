"""V2 paired-die bring-up + bidirectional packet-delivery gate.

Profile-agnostic: the same three tests run under EPOCH_PROFILE=zero (first-
ever V2 pair sim coverage), =staircase (whole-word epoch staircase 0..7 both
directions) and =silicon (v37 fingerprint, 3..7 words on the master's RX).
With the epoch-deskew anchor in the datapath (deps/tidelink-phy c332722,
EPOCH_ANCHOR_EN=1 default) all profiles must pass; the EPOCH_ANCHOR_DIS=1
compile of the same module is the negative control (see
test_v2_pair_epoch_negctl.py for the signature-asserting variant).

Oracles:
  test_01  bilateral link-up: role_locked, cal_done=1 + calibrator terminal
           DONE state on both dies, sticky all-8-lanes-ever-locked (live
           lane_locked OR-accumulated across training, not a single racing
           post-cal APB sample), cr+crack latched on both FCSMs after
           to_data_mode, then a byte-exact BIDIRECTIONAL data crossing.
  test_02  M->S v33-style 4-word packet: header + payload byte-compare in
           the slave's RX FIFO.
  test_03  S->M, same oracle in the master's RX FIFO.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check,
    ST_CAL_DONE,
)


@cocotb.test()
async def test_01_bilateral_linkup(dut):
    tb = PairV2TB(dut)
    snap = await run_bringup_full(tb)
    # Phase-1 oracles. cal_done is a sticky terminal-state bit -> the single
    # post-cal APB sample is legitimate. lane_locked[7:0] is NOT: it is a LIVE
    # training-only signal the calibrator releases at S_DONE, so a single-sample
    # ==0xFF races that release (FIX1/e5bd29c min_lock_dwells 0->1 + full
    # sweep/eye-centre widened the gap). Replace it with (a) the calibrator's
    # terminal DONE state and (b) the sticky "all 8 lanes locked at some point
    # during training" accumulator captured every hclk by run_bringup_full.
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        assert ST_CAL_DONE(st) == 1, f"{name}: cal_done not set (0x{st:08x})"
    for side, name in (("m", "M"), ("s", "S")):
        assert tb.cal_state_name(side) == "DONE", \
            f"{name}: calibrator not in terminal DONE state " \
            f"(cur_state={tb.cal_state_name(side)})"
    assert snap["m_locked_seen"] == 0xFF, \
        f"M: not all 8 lanes ever locked during training " \
        f"(sticky lane_locked=0x{snap['m_locked_seen']:02x} != 0xFF)"
    assert snap["s_locked_seen"] == 0xFF, \
        f"S: not all 8 lanes ever locked during training " \
        f"(sticky lane_locked=0x{snap['s_locked_seen']:02x} != 0xFF)"
    ok = await tb.wait_cr_crack()
    snap2 = await tb.snapshot("post cr/crack wait")
    assert ok, ("CR/CRACK exchange did not complete bilaterally — "
                f"M(cr={tb.fcsm_cr_seen('m')},crack={tb.fcsm_crack_seen('m')}) "
                f"S(cr={tb.fcsm_cr_seen('s')},crack={tb.fcsm_crack_seen('s')})")
    # Both FCSMs must sit in data-mode idle (state 4 = LINK_IDLE post-CR/CRACK).
    # PAIR_CREDIT_COUNTER is logged by snapshot() but not asserted here: it
    # only advances on credit-release traffic (FIFO reads vs RELEASE_THRESHOLD),
    # which the data crossing below exercises end-to-end via real packets.
    for side, name in (("m", "M"), ("s", "S")):
        assert tb.fcsm_state(side) == 4, \
            f"{name}: FCSM state {tb.fcsm_state(side)} != 4 (LINK_IDLE) " \
            f"after bilateral CR/CRACK"
    # Byte-exact BIDIRECTIONAL data crossing: prove the link actually carries
    # data both ways, not merely that it trained. send_and_check asserts every
    # word (header + dest_addr + both payload words) lands byte-exact in the
    # peer RX FIFO.
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "m", "s", [0xA5A5F00D, 0x0BADC0DE], ctx="linkup_m2s")
    await send_and_check(tb, "s", "m", [0xC0FFEE11, 0xFEEDBEEF], ctx="linkup_s2m")
    _ = snap2


@cocotb.test()
async def test_02_packet_master_to_slave(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="m2s")


@cocotb.test()
async def test_03_packet_slave_to_master(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D], ctx="s2m")

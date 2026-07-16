"""NEGATIVE CONTROL — proves the epoch-skew suite detects the v37 defect.

Compile with:
    make EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl

EPOCH_ANCHOR_DIS defparams WlinkGPIOPHY.EPOCH_ANCHOR_EN=0 on both dies —
the pre-fix V2 baseline (occupancy-only "prime-and-continuous" deskew, which
cannot correct whole-word epoch offsets). Under the silicon profile (3..7
word epochs on the master's RX) this test asserts the measured pre-fix
failure signature, which is the v37 class observed end-to-end:

  1. Training stays GREEN on both dies (cal_done=1, lane_locked=0xFF):
     per-lane 16-bit framing is epoch-blind, so every legacy oracle is
     blind to the defect — the historical gap this suite closes.
  2. DIRECTIONAL data loss: the M->S payload (clean RX) lands byte-perfect
     while the S->M payload (epoch-skewed RX) NEVER reaches the master's
     RX FIFO — reads return all-zeros, PKT_WORD_LEN stays 0. Exact sim
     signature (silicon profile, anchor off, 2026-06-12):
         [s2m] hdr=0x00000000 (sent 0x00240000)
               rx=[0x00000000, 0x00000000, 0x00000000, 0x00000000]
     This is the v37 asymmetry: B->A broken, A->B fine, everything
     trained and framed.

  NOTE on CR/CRACK (documented sim-vs-silicon nuance): in this integrated
  sim the CR exchange SURVIVES whole-word epoch skew — the FCSM emits
  bit-identical CR packets back-to-back, so lane slices from DIFFERENT CR
  instances still assemble into a valid CR word (the same aliasing class
  as the V1 "CR-credit-decode lottery"). On v37 silicon the CR decode DID
  fail (different inter-packet background/spacing). The CR latch is
  therefore logged but NOT asserted; the unique-payload data packet is the
  alias-proof oracle.

If this test FAILS, the fixed-vs-broken discrimination is lost (anchor-
disable hook broken, or the stack started tolerating epoch skew some other
way) — re-validate the positive suite before trusting it.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check,
    ST_LANE_LOCKED, ST_CAL_DONE,
)


@cocotb.test()
async def test_negctl_epoch_skew_breaks_s2m_data(dut):
    tb = PairV2TB(dut)
    snap = await run_bringup_full(tb)

    # 1. Legacy oracles green — training/calibration must NOT see the defect
    #    (phase-1 sample: lane_locked drops by design after training release).
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        assert ST_CAL_DONE(st) == 1, \
            f"{name}: cal_done=0 — eye/training failure, NOT the epoch class"
        assert ST_LANE_LOCKED(st) == 0xFF, \
            f"{name}: lane_locked=0x{ST_LANE_LOCKED(st):02x} — training sees " \
            f"the skew, epoch class not isolated"

    # CR/CRACK: log only (repetition-aliasing tolerant in sim, see header).
    done = await tb.wait_cr_crack(max_cycles=10000)
    await tb.snapshot("negctl post cr/crack wait")
    tb.log.info(f"negctl: CR/CRACK bilateral={done} "
                f"(informational — alias-prone oracle, not asserted)")
    await ClockCycles(dut.hclk, 500)

    # 2. Clean direction must still work — pins the failure to the skewed RX.
    ok_m2s, _ = await send_and_check(tb, "m", "s", [0xDA7A0000, 0xCAFEBABE],
                                     ctx="negctl m2s", expect_pass=False)
    assert ok_m2s, ("M->S (clean RX) payload corrupt — failure is not the "
                    "directional v37 class (check the skew profile)")

    # 3. Skewed direction must FAIL — this is the defect detection.
    ok_s2m, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                       ctx="negctl s2m", expect_pass=False)
    assert not ok_s2m, (
        "S->M payload arrived byte-perfect across a 3..7-word epoch-skewed "
        "RX with EPOCH_ANCHOR_EN=0 — the defect class is NOT being detected")
    tb.log.info("NEGATIVE CONTROL CONFIRMED: training green, M->S intact, "
                "S->M lost across the epoch-skewed RX "
                f"(rx=[{', '.join(f'0x{w:08x}' for w in got)}]) — "
                "v37 defect class detected by the suite")

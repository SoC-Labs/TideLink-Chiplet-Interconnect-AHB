"""NEGATIVE CONTROL — proves the epoch-skew suite detects the v37 defect.

Compile with:
    make EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl

EPOCH_ANCHOR_DIS defparams WlinkGPIOPHY.EPOCH_ANCHOR_EN=0 on both dies —
the pre-fix V2 baseline (occupancy-only "prime-and-continuous" deskew, which
cannot correct whole-word epoch offsets). Under the silicon profile (3..7
word epochs on the master's RX) this test asserts the EXACT v37 silicon
failure signature (docs/V37_FINAL_DIAGNOSIS_2026_06_12.md):

  1. Training stays GREEN on both dies (cal_done=1, lane_locked=0xFF):
     per-lane 16-bit framing is epoch-blind, so the legacy oracles cannot
     see the defect — the historical blind spot.
  2. The master (skewed RX) receives the slave's CR packets framed but
     UNDECODABLE: cr_pkt_seen_rx stays 0 on the master while the slave
     (clean RX) decodes the master's CR instantly. Asymmetric, B->A-only.
  3. Consequently no bilateral CR/CRACK completion and S->M payload never
     lands intact in the master's RX FIFO.

If this test FAILS, the fixed-vs-broken discrimination is lost (either the
anchor-disable hook stopped working, or the integrated stack started
tolerating epoch skew some other way) — investigate before trusting the
positive suite.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check,
    ST_LANE_LOCKED, ST_CAL_DONE,
)


@cocotb.test()
async def test_negctl_epoch_skew_breaks_link(dut):
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

    # 2. CR decode asymmetry: give the FCSMs ample time, then check.
    done = await tb.wait_cr_crack(max_cycles=40000)
    await tb.snapshot("negctl post cr/crack wait")
    m_cr = tb.fcsm_cr_seen("m")
    s_cr = tb.fcsm_cr_seen("s")
    assert not done, "bilateral CR/CRACK completed — defect NOT detected"
    assert m_cr == 0, \
        f"master decoded CR over a 3..7-word epoch-skewed RX with the " \
        f"anchor OFF (cr={m_cr}) — defect NOT detected"
    assert s_cr == 1, \
        f"slave (clean RX) failed to decode CR (cr={s_cr}) — failure is " \
        f"not the asymmetric v37 class"

    # 3. S->M payload must NOT arrive intact.
    ok, got = await send_and_check(tb, "s", "m", [0xDEADBEEF, 0x5A17F00D],
                                   ctx="negctl s2m", expect_pass=False)
    assert not ok, ("S->M payload arrived byte-perfect across an epoch-skewed "
                    "RX with the anchor disabled — defect NOT detected")
    tb.log.info("NEGATIVE CONTROL CONFIRMED: training green, master cr=0 / "
                "slave cr=1, S->M payload corrupt — v37 signature reproduced "
                f"(rx=[{', '.join(f'0x{w:08x}' for w in got)}])")

"""NEGATIVE CONTROL for the sustained-burst oracle -- proves it has TEETH.

A sustained-data suite that PASSES is worthless until it is shown to FAIL on a
known-bad datapath. This compiles the eye-fault injector into the S->M lane bus
and corrupts real bits under a sustained burst; test_11's oracle
(send_and_check_burst, every-word compare) MUST report mismatches. If this test
fails, the sustained suite is passing vacuously and its PASS means nothing.

Run (REQUIRES the injector to be compiled in):
  make EPOCH_PROFILE=zero EYE_FAULT=1 MODULE=test_v2_sustained_negctl

Recorded evidence (2026-07-15): a SECOND, independent known-bad condition also
made the oracle fail correctly -- the pre-fix `ahb_tx_write_word` that silently
abandoned a beat after 50 cycles of legitimate AHB back-pressure and zeroed
HWDATA. Against that harness the len>=16 sweeps failed with
first_bad_idx=16 and a zero word injected mid-stream. Two independent
fault modes, both caught, both localized.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check_burst,
)


@cocotb.test()
async def test_30_negctl_eye_fault_must_corrupt_burst(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    try:
        inj = dut.u_eye_s2m
    except AttributeError:
        raise RuntimeError(
            "eye_fault injector not compiled in — rerun with EYE_FAULT=1. "
            "Without it this negative control proves nothing.")

    # Clean burst first: establishes that the ONLY difference below is the
    # injected corruption (not a broken bring-up).
    ok_clean, _, _ = await send_and_check_burst(
        tb, "s", "m", [(0x5EED << 16) | i for i in range(32)],
        ctx="negctl-clean", expect_pass=False)
    assert ok_clean, ("baseline burst was ALREADY corrupt with the injector "
                      "idle — the negative control cannot attribute anything "
                      "to the fault")

    # Now corrupt several lanes hard, continuously, under a sustained burst.
    inj.err_mask.value   = 0xFF
    inj.err_burst.value  = 8
    inj.err_period.value = 16
    inj.err_en.value     = 1
    await ClockCycles(dut.hclk, 200)

    ok_faulted, got, mism = await send_and_check_burst(
        tb, "s", "m", [(0xBAD0 << 16) | i for i in range(32)],
        ctx="negctl-faulted", expect_pass=False)

    inj.err_en.value = 0

    tb.log.info(f"  NEGCTL: clean_burst_ok={ok_clean} "
                f"faulted_burst_ok={ok_faulted} mismatches={len(mism)}")
    assert not ok_faulted, (
        "TEETH FAILURE: the sustained-burst oracle reported a byte-exact "
        "burst while every lane was being bit-flipped. The oracle is blind — "
        "its PASS on the clean path is therefore meaningless.")
    tb.log.info(f"  NEGCTL PASS: oracle caught {len(mism)} corrupted words "
                f"(first bad index {mism[0][0]}) => the sustained suite has "
                f"teeth.")

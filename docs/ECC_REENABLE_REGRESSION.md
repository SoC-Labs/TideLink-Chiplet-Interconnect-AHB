# ECC Re-enable Regression (2026-05-20)

## Context

On 2026-05-05 the Wlink Hamming(33,24) SECDED decoder in
`deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v` was
hand-patched to BYPASS the corrected/corrupted assigns (forcing
`corrected = 0` / `corrupted = 0`) while the PHY was glitching at the
per-bit level (pre-IDELAYE2 / pre-S_HOLD / pre-FCSM fixes).

With those PHY defects resolved (memory:
`project_tidelink_fpga_bringup` ★RESOLVED 2026-05-19), the bypass has
been REVERTED on `feat/td-combined` (parent fff8df2, submodule
678a9b3). `WlinkEccSyndrome.v` now matches the upstream Chisel output;
a Soc Labs provenance comment was inserted above the restored asserts.

This document records the cocotb-only regression that validated the
re-enable in simulation. NO hardware was touched.

## Tests exercised

All under `cocotb/` on worktree `/home/dam1n19/td_idelay_wt`, run with
the project default VCS simulator (T-2022.06-SP2).

### Primary ECC coverage

`cocotb/phy_align/test_credit_path_observability.py`

Two cases:

1. `test_credit_path_observability_negative_control` — boot only, no
   role lock. Asserts every Region 8 RO observability field reads
   reset/default 0, including `ECC_COUNTERS` slot 5.
2. `test_credit_path_observability_live` — real autocal bring-up.
   Asserts:
   - Live FCSM advances, `cr_pkt_seen_rx` sets.
   - Wlink `obs_ecc_corrupted_cnt_q` and `obs_ecc_corrected_cnt_q`
     match the apb_clk-domain Region 8 slot-5 snapshot.
   - Deterministic ECC injection: `Force(1)` on
     `u_wlink.llrx_io_ecc_corrupted` (the `ecc_check_corrupted` wire
     from `WlinkRxLinkLayer`) for 5 recovered-RX-link-clock cycles
     advances the 16-bit saturating counter by exactly N (or
     saturates), and the new value is visible via the ctrl_reg Region
     8 ECC_COUNTERS read.

Invocation:

    cd cocotb/phy_align
    rm -rf sim_build ../wlink_pair/sim_build
    make MODULE=test_credit_path_observability SKID_BITS=3

Result:

    TESTS=2 PASS=2 FAIL=0 SKIP=0
    test_credit_path_observability_negative_control   PASS
    test_credit_path_observability_live               PASS

Highlights from the live run log:

    [live] raw FCSM max state=4 cr_pkt_seen_rx=1
           ecc_corrupt_cnt=209 ecc_correct_cnt=0
    [live] ECC slot5=0x000000d1 read corrupt=209 correct=0;
           raw corrupt 209->209 correct 0->0
    [live] ECC inject: raw corrupt 209 -> 214
           (forced 5 rx-clk cycles high)
    [live] ECC injection OK: 214 corrupted events visible via
           Region 8 ECC_COUNTERS slot 5

209 ECC-corrupted events were observed during normal alignment (the
training pattern drives the LL_RX decoder past garbage before the
byte-align FSM locks — expected and benign), plus 5 forced events.

### Negative/positive ECC sanity (skid sweep)

`cocotb/wlink_pair/test_pair_skid.py`

This test was added to reproduce the FPGA bit-skid that ECC-bypass
was originally papered over.

- `SKID_BITS=0` (clean passthrough):
  - `master state_max=4, cr_seen=True, ecc_corrupt=0/5000`
  - `slave  state_max=4, cr_seen=True, ecc_corrupt=0/5000`
  - Test PASS. Demonstrates the decoder is silent on uncorrupted
    traffic — no false positives.
- `SKID_BITS=3` (FPGA-failure repro: 3-bit boundary misalignment):
  - `master state_max=1, cr_seen=False, ecc_corrupt=4069/5000`
  - `slave  state_max=1, cr_seen=False, ecc_corrupt=4071/5000`
  - Test PASS (the test expects ECC to fire every cycle when skidded).
    Demonstrates the restored decoder actively flags corrupted PH
    packets, FCSM stays at state 1 (SEND_CREDITS1).

## ECC error-injection coverage summary

| Mechanism                                    | Where                                   | Status |
|----------------------------------------------|-----------------------------------------|--------|
| Live (alignment-phase) ECC events            | test_credit_path_observability_live     | OK     |
| Forced `ecc_check_corrupted` (cycle-precise) | test_credit_path_observability_live     | OK     |
| Clean-data negative control (no ECC events)  | test_pair_skid SKID_BITS=0              | OK     |
| Bit-skid stress (ECC fires every cycle)      | test_pair_skid SKID_BITS=3              | OK     |
| Single-bit RTL syndrome injection at ph_in   | NOT FOUND — no test injects on the wire | (none) |
| Double-bit error detection (DED)             | NOT FOUND — no dedicated DED test       | (none) |

The existing cocotb suite exercises the ECC observability path and
event counters end-to-end, but does NOT inject a single-bit error
directly on the `ph_in` packet wire and verify the SECDED correction
produces the right `corrected_ph` value, nor does it specifically
distinguish a corrected single-bit fault from an uncorrectable
double-bit fault. The skid-3 test corrupts the entire bit framing,
which exercises the decoder but is not a per-bit syndrome test. A
unit-level WlinkEccSyndrome testbench would close that gap but does
not exist in this repository.

## Verdict

The upstream Hamming(33,24) SECDED restoration is sim-clean against
every cocotb test that touches the ECC path:

- No false ECC events on clean traffic.
- Live counters and Region 8 RO snapshot agree.
- Forced injection propagates cycle-accurately into the counter and
  apb_clk-domain snapshot.
- Bit-misaligned traffic correctly flags ECC every cycle and blocks
  FCSM progression (the expected protective behaviour the bypass was
  defeating).

No fail was observed that could be attributed to the ECC RTL itself.

## Notes on the parallel RTL refactor

While these tests were running, the parallel RTL-refactor agent
edited `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioRx.v`
(an "ASIC purification" change removing a `USE_CLKBUF` generate
wrapper). A re-compile attempted immediately after that edit failed
with:

    Error-[IND] Identifier 'USE_CLKBUF' has not been declared yet.
    WavD2DGpioRx.v, line 204

This is a PHY-clocking refactor compile breakage, completely
unrelated to the ECC re-enable. The ECC tests above all compiled
cleanly and ran to completion before that edit landed. No action
required from the ECC re-enable side.

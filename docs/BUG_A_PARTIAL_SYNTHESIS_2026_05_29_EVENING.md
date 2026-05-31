# Bug A — partial synthesis (2026-05-29 evening)

**Status**: H-A sweep timed out at 40min/test wall cap; 3-4 of 5-6 tests completed per file. F1/F2 simv still running at write time. F3 cross-env diff completed with disk artefact. **Multiple top hypotheses falsified.**

## Headline

The hot zone for Bug A is now extremely narrow: between **"arbiter grants FIFO_DATA"** and **"`tl_fc_a2l_valid` asserts on the master TX wire"** — a thin slice inside `tidelink_fc_adapter.sv`. AHB→adapter handoff works, skid can accept, Wlink ready signal is high, FCSM states are symmetric. Something between the arbiter grant decision and the valid output is suppressing the publish.

## Falsification table

| Hypothesis | Test (verdict) | Verdict | Source |
|---|---|---|---|
| H-A1: AHB→fc_adapter handoff broken | `test_ahb_tx_aperture_pulses` PASS, `test_tx_addr_phase_latches` PASS, `test_tx_data_phase_latches` **PASS** | **FALSIFIED** — handoff works, data phase latches | [test_master_fc_ahb_handoff.py](cocotb/tidelink_top_pair/test_master_fc_ahb_handoff.py) |
| H-A2: skid backpressure permanent | `test_skid_can_accept_initially_high` PASS, `test_tl_fc_a2l_ready_high` **PASS** | **FALSIFIED** — both high | [test_master_fc_skid_arbiter.py](cocotb/tidelink_top_pair/test_master_fc_skid_arbiter.py) |
| H-A3: arbiter starves FIFO_DATA | `test_arbiter_grants_fifo_data` **PASS** | **FALSIFIED on positive evidence** (FIFO_DATA was granted in test). `test_sideband_starvation_engages` incomplete | same |
| H-A4: Wlink FCSM asymmetric end-state (2026-05-24 byte-align recurrence) | `test_fcsm_state_post_bringup_symmetric` **PASS** | **FALSIFIED** — states ARE symmetric | [test_fcsm_state_asymmetry.py](cocotb/tidelink_top_pair/test_fcsm_state_asymmetry.py) |
| H-A5: link bit-flip [47:46] | `test_master_tx_wire_bits_47_46` PASS, `test_slave_rx_wire_bits_47_46` **FAIL** | **Confirmed slave never sees `tl_fc_l2a_valid` asserted** — packet doesn't cross link in sim | [test_link_layer_bit_fidelity.py](cocotb/tidelink_top_pair/test_link_layer_bit_fidelity.py) |
| F3 hypothesis: `tl_fc_a2l_ready` credit-gated in pair env | H-A2 directly probed `tl_fc_a2l_ready` — PASS HIGH | **REFUTED** by sim evidence | [BUG_A_CROSS_ENV_DIFF_2026_05_29.md](BUG_A_CROSS_ENV_DIFF_2026_05_29.md) |

## What we know is true

All probed values:
- `tx_valid_addr_phase` fires per AHB write
- `tx_addr_phase_r` latches
- `tx_data_phase_r` latches
- `skid_can_accept = 1` post-bringup
- `tl_fc_a2l_ready = 1` (Wlink → adapter ready)
- Arbiter does grant FIFO_DATA path
- Wlink FCSM states are symmetric M==S
- Master `tl_fc_a2l_valid` still = 0 (per prior test_08 and test_credit_ledger_probes results)
- Slave `tl_fc_l2a_valid` never asserts (per test_slave_rx_wire_bits_47_46 FAIL)

## Open hot zone — narrowed RTL slice

The bug is in the path: **arbiter grant → skid PUSH stage → `tl_fc_a2l_valid` generation** inside `tidelink_fc_adapter.sv`. Likely files/lines:
- [src/rtl/tidelink_fc_adapter.sv:262-400](src/rtl/tidelink_fc_adapter.sv#L262) — arbiter + skid push
- Specifically around `skid_valid_r` flop driver (~line 376-400) and any combinational gate between `arb_grant && tx_fc_valid` and `tl_fc_a2l_valid` output

Candidate sub-hypotheses (NOT YET TESTED):
- H-A6: `skid_valid_r` flop never sets because `arb_grant_decoded` and `tx_fc_valid` don't overlap in the same cycle (one-cycle skew)
- H-A7: `tl_fc_a2l_valid` is gated by a yet-undiscovered config bit (e.g. `tx_enable` reset-to-0)
- H-A8: The arbiter "grants FIFO_DATA" in test_arbiter_grants_fifo_data only via a relaxed predicate (e.g. "would grant if asked") — actual `arb_grant` may never assert for FIFO_DATA when an AHB packet is queued. The test's positive PASS may be vacuous.

## Sim infrastructure findings

- VCS sim with `TB_TOP_NO_DUMP=1` runs ~6-8 sim ms per cocotb test, ~10 min wall per test.
- 6 tests in one file blow through the 40-min sweep timeout. Future runs need ≤ 4 tests/file OR ≥ 60-min timeout.
- Existing `make sim` per-test sequential — no parallelism within a file. Could split into multiple files for parallel agents.

## F1/F2 status at write time

Both simv processes still running (PIDs 1950843, 1956481). Will produce results.xml + logs on completion (or timeout at ~18:53/18:56).

## Recommended next sim experiments (for tomorrow)

1. **Read [tidelink_fc_adapter.sv:262-400](src/rtl/tidelink_fc_adapter.sv#L262) line by line** — manual static analysis of the arb_grant → skid_valid_r → tl_fc_a2l_valid path. Smaller code surface than the prior tests assumed.
2. **Rerun H-A3 `test_sideband_starvation_engages` with longer timeout** — the only un-resolved arbiter test.
3. **Tighten `test_arbiter_grants_fifo_data` assertion** — currently PASSes; verify whether the grant signal asserts during a real AHB-write window, not just in steady state.
4. **New test: `test_skid_push_handshake_active`** — probe the exact handshake `arb_grant_decoded & skid_can_accept` cycle, log all overlap events, identify whether the push ever actually fires.
5. **Force `skid_valid_r = 1` mid-test** — definitive on "is the bug in skid load or downstream?"
6. **Cross-check with `cocotb/wlink_pair/` sim** — that env passes bidirectional traffic (per memory `project_tidelink_bug_isolated_2026_05_26`). What does ITS `tl_fc_a2l_valid` look like? If high there, fc_adapter is definitively the bug; if low there too, Wlink test harness differs from real chain.

## ILA probe list for next FPGA build (Bug A + Bug B combined)

Bug A (master TX hot zone):
- `u_fc_adapter.arb_grant` (decoded) — does arbiter actually grant during an AHB write?
- `u_fc_adapter.skid_can_accept`
- `u_fc_adapter.skid_valid_r`
- `u_fc_adapter.tx_fc_valid`
- `u_fc_adapter.tx_data_phase_r`
- `u_fc_adapter.sideband_grant`, `sideband_burst_r`
- `tl_fc_a2l_valid`, `tl_fc_a2l_ready`, `tl_fc_a2l_data[47:46]`
- Slave: `tl_fc_l2a_valid`, `tl_fc_l2a_data[47:46]`

Bug B (master PTP TX router):
- `u_ptp.hw_sync_state_r[1:0]` (NOT MARKED — add)
- `u_ptp.phc_time_reached`
- `u_ptp.target_ns_r[29:0]`, `target_seconds_r[7:0]`
- `u_ptp.phc_nanoseconds[29:0]` input
- `u_ptp.hw_sync_interval_r[29:0]`
- `u_ptp.tx_state_r[1:0]`

Total ~20 signals. Sized for a single ILA debug core with ≥ 16 probes. If budget is tighter, drop H-A4 / H-A5 probes (those are falsified) and keep the hot-zone probes.

## See also
- [BUG_A_CROSS_ENV_DIFF_2026_05_29.md](BUG_A_CROSS_ENV_DIFF_2026_05_29.md) — F3 cross-env diff
- [BUG_A_DIFFERENTIAL_2026_05_29.md](BUG_A_DIFFERENTIAL_2026_05_29.md) — F2 (TBD entries — F2 sim still running at write)
- [HANDOFF_ERRATA_2026_05_29.md](HANDOFF_ERRATA_2026_05_29.md) — 5 errata to HANDOFF_REPORT
- `project_tidelink_bugA_master_tx_block_2026_05_29.md` (memory)
- `project_tidelink_bugB_phc_time_reached_2026_05_29.md` (memory — DECISIVE)

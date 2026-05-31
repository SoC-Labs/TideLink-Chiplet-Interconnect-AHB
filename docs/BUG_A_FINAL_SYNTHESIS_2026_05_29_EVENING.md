# Bug A — final synthesis, 2026-05-29 evening session

**Status at write**: H-A sweep completed (timed out at 40min cap, 3-4 tests/file). F1/F2 sims timed out without results.xml. F3 cross-env diff complete. RTL audit of fc_adapter.sv:175-400 completed in-thread. **Bug A localised to a specific 30-line slice of RTL.**

## Headline

The bug lives in **[src/rtl/tidelink_fc_adapter.sv:189-191](src/rtl/tidelink_fc_adapter.sv#L189) (`tx_data_phase_r` clear gate) AND/OR lines 368-396 (sideband_grant / arbiter / skid)**. Confirmed RTL data flow:

```
ahb_tx_hsel & hwrite → tx_valid_addr_phase (l175) → tx_data_phase_r (l188) → tx_fc_valid (l198) → arb_valid (l369)
                                                                                 ↓
arb_data = sideband ? sideband_word : tx_fc_word (l370-373)
                                                                                 ↓
skid_valid_r ← (arb_valid && skid_can_accept) (l387)
                                                                                 ↓
tl_fc_a2l_valid = skid_valid_r (l399)
```

**The arbiter mux at line 370-373 selects sideband when `sideband_grant=1`, ignoring `tx_fc_word`.**
**`tx_data_phase_r` only clears on `!sideband_grant` (line 189).**

If sideband is winning every cycle, AHB FIFO_DATA is never published AND `tx_data_phase_r` stays latched. Sideband starvation should kick in after `MAX_SIDEBAND_BURST=4` grants (line 257-258), but the test that would have verified this (`test_sideband_starvation_engages`) DID NOT COMPLETE in the sweep timeout.

## Hypothesis ranking (post-evening)

| Hyp | Description | Evidence | Verdict |
|---|---|---|---|
| H-A1 | AHB→adapter handoff broken | `test_tx_data_phase_latches` PASS (high-confidence assertion) | **FALSIFIED** |
| H-A2 | skid backpressure permanent | `test_skid_can_accept_initially_high` PASS, `test_tl_fc_a2l_ready_high` PASS | **FALSIFIED** |
| H-A3 | arbiter never grants FIFO_DATA | `test_arbiter_grants_fifo_data` PASS (fd_g > 0) | **PARTIALLY FALSIFIED** — grants happen occasionally but possibly <<< sideband grants |
| H-A4 | Wlink FCSM asymmetric end-state | `test_fcsm_state_post_bringup_symmetric` PASS (M==S) | **FALSIFIED** |
| H-A5 | link bit-flip [47:46] | Master TX wire bits OK; slave RX `tl_fc_l2a_valid` never asserts | **Slave RX silent confirmed; bit-flip cannot be evaluated in sim** |
| F3 | `tl_fc_a2l_ready` credit-gated in pair env | H-A2 directly shows ready=HIGH | **REFUTED** |
| **H-A9 (NEW)** | Sideband grant continuously high; FIFO_DATA starved every cycle | RTL audit (l368-373); sideband_starving test incomplete | **PRIMARY CANDIDATE** |
| H-A10 (new) | `sideband_starving` gate broken (never engages despite ≥4 sideband grants) | Untested — `test_sideband_starvation_engages` timed out | **OPEN** — highest-ROI test for tomorrow |
| H-A11 (new) | `rtn_pending_r` stays high (returner feedback loop with peer) | Untested | **OPEN** |
| H-A12 (new) | `ext_wants = tc_tx_is_remote` stuck high (XHB500 path) | Untested | **OPEN** |

## RTL evidence (smoking-gun lines)

[src/rtl/tidelink_fc_adapter.sv:189-191](src/rtl/tidelink_fc_adapter.sv#L189) — the `tx_data_phase_r` clear gate:
```verilog
end else if (tx_data_phase_r && skid_can_accept && !sideband_grant) begin
    tx_data_phase_r <= 1'b0;
end
```
**If `sideband_grant=1` every cycle, `tx_data_phase_r` STAYS HIGH forever AND `tx_fc_word` is never selected by the arbiter mux. AHB write hangs indefinitely.**

[src/rtl/tidelink_fc_adapter.sv:368](src/rtl/tidelink_fc_adapter.sv#L368) — `sideband_grant`:
```verilog
assign sideband_grant = (rtn_fc_valid || servo_fc_valid || ext_grant) && !sideband_starving;
```
**If any of `rtn_fc_valid / servo_fc_valid / ext_grant` is continuously high AND `sideband_starving` is broken, sideband_grant stays 1, FIFO_DATA never wins.**

[src/rtl/tidelink_fc_adapter.sv:370-373](src/rtl/tidelink_fc_adapter.sv#L370) — `arb_data` mux:
```verilog
wire [FC_DATA_W-1:0] arb_data = (sideband_grant && rtn_fc_valid)   ? rtn_fc_word :
                                 (sideband_grant && servo_fc_valid) ? servo_fc_data :
                                 ext_grant                          ? tc_axis_tx_tdata :
                                 tx_fc_word;
```
**Sideband always wins when `sideband_grant=1`. tx_fc_word is the default fallthrough.**

[src/rtl/tidelink_fc_adapter.sv:399](src/rtl/tidelink_fc_adapter.sv#L399) — output:
```verilog
assign tl_fc_a2l_valid = skid_valid_r;
```
**No further gates — bug is upstream in skid load or arbiter.**

## Reconciliation with test_08 evidence

Prior sim repro doc (`docs/SIM_REPRO_RESULTS_2026_05_29.md` test_08) showed master `tl_fc_a2l_valid = 0` for 500 cy after AHB write. With MAX_SIDEBAND_BURST=4, sideband_starving SHOULD engage by cycle 5 and let FIFO_DATA through. The 500-cy continuous starvation is INCONSISTENT WITH a working starvation gate. So:

- Either `sideband_starving` is broken (H-A10), OR
- The starvation counter is reset every time FIFO_DATA briefly wins (1 cy fire, then sideband hogs again — net: AHB packet drips through too slowly to register), OR
- `rtn_pending_r` / `servo_fc_valid` / `ext_grant` create a self-sustaining loop where starvation never triggers a meaningful FIFO_DATA window

## Tomorrow's tests (priority order)

1. **Probe `sideband_starving`, `sideband_burst_r`, `rtn_pending_r`, `servo_fc_valid`, `ext_grant` continuously during AHB write** — measure how many cy each is high. RUN: `test_sideband_starvation_engages` from `test_master_fc_skid_arbiter.py` with `timeout 1800` (30 min).
2. **Static trace through `tidelink_returner`** — what holds `rtn_pending_r` high? Find the writer.
3. **Probe `ext_wants`/`tc_tx_is_remote`** — is the XHB500 path falsely asserting?
4. **`servo_fc_valid` audit** — is the servo emitting continuously?
5. **Cocotb force experiment**: force `sideband_grant = 0` mid-test; does FIFO_DATA flow? (definitive)

## ILA probe list for next FPGA build

**Bug A hot zone** (master):
- `u_fc_adapter.sideband_grant`
- `u_fc_adapter.sideband_starving`
- `u_fc_adapter.sideband_burst_r[2:0]`
- `u_fc_adapter.rtn_fc_valid` (= rtn_pending_r)
- `u_fc_adapter.servo_fc_valid`
- `u_fc_adapter.ext_wants`, `ext_grant`
- `u_fc_adapter.tx_fc_valid` (= tx_data_phase_r)
- `u_fc_adapter.arb_valid`
- `u_fc_adapter.skid_valid_r`
- `u_fc_adapter.skid_can_accept`
- `u_fc_adapter.tx_data_phase_r`
- `tl_fc_a2l_valid`, `tl_fc_a2l_ready`, `tl_fc_a2l_data[47:46]`

**Bug B** (master PTP TX router):
- `u_ptp.hw_sync_state_r[1:0]`
- `u_ptp.phc_time_reached`
- `u_ptp.target_ns_r[29:0]`, `target_seconds_r[7:0]`
- `u_ptp.phc_nanoseconds[29:0]` (confirm PHC ticking)
- `u_ptp.hw_sync_interval_r[29:0]` (confirm SW write)
- `u_ptp.tx_state_r[1:0]`

**Total**: ~18 signals. Single dbg_hub debug core, depth 4096 should be ample.

## Files / artefacts

Created tonight:
- [docs/BUG_A_PARTIAL_SYNTHESIS_2026_05_29_EVENING.md](BUG_A_PARTIAL_SYNTHESIS_2026_05_29_EVENING.md) (interim)
- [docs/BUG_A_FINAL_SYNTHESIS_2026_05_29_EVENING.md](BUG_A_FINAL_SYNTHESIS_2026_05_29_EVENING.md) (this doc)
- [docs/BUG_A_CROSS_ENV_DIFF_2026_05_29.md](BUG_A_CROSS_ENV_DIFF_2026_05_29.md) (F3 — top hypothesis REFUTED by H-A2)
- [docs/BUG_A_DIFFERENTIAL_2026_05_29.md](BUG_A_DIFFERENTIAL_2026_05_29.md) (F2 — sim timed out, TBD entries)
- [docs/HANDOFF_ERRATA_2026_05_29.md](HANDOFF_ERRATA_2026_05_29.md) (5 errata patched into handoff doc)
- 8 new cocotb test files in [cocotb/tidelink_top_pair/](../cocotb/tidelink_top_pair/):
  - `test_master_fc_ahb_handoff.py` (H-A1 — falsified)
  - `test_master_fc_skid_arbiter.py` (H-A2/A3 — falsified except starvation)
  - `test_fcsm_state_asymmetry.py` (H-A4 — falsified)
  - `test_link_layer_bit_fidelity.py` (H-A5 — slave RX silent confirmed)
  - `test_fc_tx_force_experiments.py` (F1 — sim didn't complete)
  - `test_fc_tx_differential.py` (F2 — sim didn't complete)
  - `test_credit_ledger_probes.py` (Phase 3a)
  - `test_master_ptp_tx_router.py` (Phase 3a — DECISIVE for Bug B)

Memory updated:
- `project_tidelink_bugB_phc_time_reached_2026_05_29.md` — DECISIVE Bug B root cause
- `project_tidelink_bugA_master_tx_block_2026_05_29.md` — updated with falsifications + new candidates
- `MEMORY.md` index — both new entries linked

Gitignore cleaned in both tidelink + tidelink-gpio-phy submodule.

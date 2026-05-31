# Bug A — FC TX Differential Sim Characterisation, 2026-05-29

## Scope

Bug A symptom (HW build #3): master AHB writes never reach the slave's
AHB RX FIFO. Master `tl_fc_a2l_valid` stays low during the AHB write.
Sideband doorbell control packets cross to the slave normally — and
*per HW*, every master AHB write produces a 0x5000 bump in slave
`REG_DOORBELL_RESP_ACC`, suggesting the master's FC TX arbiter is
emitting sideband packets in lieu of FIFO_DATA payloads.

Already ruled out:

* credit gate (FCSM `fe_rx_credit_max = 0x1f` on both sides)
* slave RX misdecode (sideband CR/CRACK decoder path works)

Three differentials run here:

* **A.** sideband-only vs FIFO_DATA-only stim — is the bug FIFO_DATA-specific?
* **B.** does sim show the same 0x5000 `DOORBELL_RESP_ACC` bump per master AHB write?
* **C.** AHB master HREADY — does sim return cleanly like HW (~0.17 ms on silicon)?

Test source: `cocotb/tidelink_top_pair/test_fc_tx_differential.py`.
Sim build: `SIM_BUILD=sim_build_fc_diff` with `TB_TOP_NO_DUMP=1`.

## Test Results Table

| # | Test | Purpose | Result | Key signal evidence |
|---|------|---------|--------|---------------------|
| 1 | `test_sideband_only_doorbell_flow` | baseline: 5 doorbell rings → slave/master `DOORBELL_RESP_ACC` ++ | _TBD_ | slave delta, master delta, master `tl_fc_a2l_valid` cy |
| 2 | `test_fifo_data_only_no_sideband` | 1 AHB write only → ≥1 master `tl_fc_a2l_valid` rising edge | _TBD_ | rising edges in 500 cy, `skid_valid_r`, `tl_fc_a2l_ready` |
| 3 | `test_hw_vs_sim_doorbell_bump_diff` | 1 AHB write, NO doorbell → slave `DOORBELL_RESP_ACC` delta vs HW 0x5000 | _TBD_ | slave & master `DOORBELL_RESP_ACC` delta |
| 4 | `test_ahb_completion_timing` | HSEL+HWRITE → HREADY rising-edge cycles | _TBD_ | cycles, HW ref ~4250 @ 25 MHz |
| 5 | `test_mixed_stim_arbiter_priority` | interleaved AHB + doorbell, which traffic flows first | _TBD_ | first-seen cycle for a2l_rises vs `DOORBELL_RESP_ACC` |
| 6 | `test_returner_busy_during_ahb` | master `returner_busy` during AHB write | _TBD_ | busy_cy/2000, longest run |

## Bug-class Verdict

_TBD_ — one of: **FIFO_DATA-specific** / **generic TX block** /
**sim-vs-HW gap** / **mixed**.

## AHB-side Verdict

_TBD_ — does sim show master HREADY return cleanly like HW (~0.17 ms
on silicon, ~4250 cy @ 25 MHz)?

## ILA probe list (suggested follow-up captures)

Probes are listed in priority order (i.e. add to the next pynq-z2-pair
ILA build). All names are hierarchical references that exist in the
post-elab netlist (verified via `mark_debug` attributes already present
in `tidelink_top.sv`).

1. **master `tl_fc_a2l_valid`** (already marked) — primary symptom
   signal: does silicon ever see it pulse during an AHB write?
2. **master `tl_fc_a2l_ready`** (already marked) — Wlink TL backpressure;
   if stuck low, FC arbiter is starved by Wlink.
3. **master `u_fc_adapter.skid_valid_r`** — the skid buffer that drives
   `tl_fc_a2l_valid` directly (tidelink_fc_adapter.sv:399). If high but
   `tl_fc_a2l_valid` low, broken combinational gate; if low, the FC TX
   FSM never advanced past the SRAM-read stage.
4. **master `u_tidelink_fifo.returner_busy`** — if continuously high
   while the AHB write is pending, the returner is holding the AHBM
   shared bus and starving the local TX FIFO write path (the path that
   feeds the FC adapter).
5. **master FC adapter TX state** (`u_fc_adapter` internal FSM, see
   tidelink_fc_adapter.sv ~line 380) — localises whether the FSM is
   stuck in IDLE (no SRAM read started), in SRAM_READ (read pending,
   never completes), or in PUSH_SKID (skid full).
6. **slave `u_fc_adapter.tl_fc_l2a_valid`** + **`tl_fc_l2a_accept`** —
   if M.a2l never pulses, the slave's L2A should also be silent. If S.l2a
   does pulse without M.a2l (a M→S detection-side fault), the bug is
   localised to the master observability/probe path.

## Constraints honoured

* No edits to other test files / RTL / `/research/AAA/ip_library/**`.
* `SIM_BUILD=sim_build_fc_diff`; `TB_TOP_NO_DUMP=1` (no VCD).
* `timeout 600 make` per run.
* `pad_skid.sv` left as-is (fix already in tree).

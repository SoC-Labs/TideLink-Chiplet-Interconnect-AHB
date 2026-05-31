# HANDOFF_REPORT_2026_05_29 — errata

**Issued:** 2026-05-29
**Applies to:** [docs/HANDOFF_REPORT_2026_05_29.md](HANDOFF_REPORT_2026_05_29.md)
**Source:** multi-agent audit of the handoff report against actual RTL

## Purpose

Errata captured during the 2026-05-29 multi-agent audit of `HANDOFF_REPORT_2026_05_29.md`. The handoff was reviewed by seven Phase 1+2 audit agents against the working tree RTL; five inaccuracies were found and corrected in-line in the handoff (each marked with an `<!-- errata 2026-05-29: ... -->` HTML comment for greppability). This document summarises the corrections and the bigger-picture re-framing of Bug A and Bug B that emerged from the synthesis.

## Errata table

| # | Section | Original claim | Correction | File:line citation |
|---|---|---|---|---|
| a | Appendix B (line ~351) | `AUTOCAL_ENABLE = 1'b1 ([tidelink_top.sv:1895])` | Line is **1812**, not 1895 | `src/rtl/tidelink_top.sv:1812` (Agent 4) |
| b | §9 Bug B "WRONG REGISTER" | `PTP_STATUS @ 0x03C bit[2] = ptp_rx_valid_r` | `ptp_rx_valid_r` lives at **`PTP_CTRL @ 0x034 bit[2]`**. `PTP_STATUS @ 0x03C` carries `{tx_pending, tx_router_idle}` | `src/rtl/tidelink_ptp.sv:545-548` (Agent 6) |
| c | §4.2 test list / §10 Q3 | `test_paircredit_nonzero_after_bringup` asserts `PAIR_CREDIT_COUNTER != 0` | Wrong target — that register is APB-mirror only. Assert **FCSM `fe_rx_credit_max != 0`** via cocotb hierarchical reference | FCSM `fe_rx_credit_max = 0x1f` on both dies in sim (Agent 7) |
| d | §9 Bug B "HW_SYNC_STATUS" | bit[0] is the "**initiator-side enable**" | Bit[0] is the **local-FSM-enable mirror of HW_SYNC_CTRL[0]**. If both nodes set it, both report it. Not specifically "initiator" | `src/rtl/tidelink_ptp.sv:535-539` (Agent 2) |
| e | §6.4 corrected understanding #4 | "Slave's lane_locked drops to 0 once training_mode clears" | Actual semantics: `match_count` + `locked_pre` reset on `training_mode` **RISING edge**, forcing `locked_o=0` for LOCK_CONSEC cycles. Falling edge disables `vote_enable` but `locked_o` only drops if `match_count` falls | `src/rtl/tidelink_lane_checker_single.sv:195-202` (Agent 4) |

## Big-picture corrections from Phase 2 synthesis

### PAIR_CREDIT_COUNTER — no contradiction with the report

Handoff §6.1 was **right**: `PAIR_CREDIT_COUNTER` is SW-managed observability only and does NOT gate TX. The §4.2 test name `test_paircredit_nonzero_after_bringup` is misleading because it appears to use that register as the assertion target. The real credit ledger is `fe_rx_credit_max` inside the FCSM (Wlink TideLink TL layer), reachable in cocotb via the hierarchical reference:

```
dut.u_{master,slave}.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.fe_rx_credit_max
```

Both dies report `0x1f` post-bringup in sim. The APB-mirror `PAIR_CREDIT_COUNTER` legitimately reads 0 because no SW driver has written it — that is fine and consistent with the §6.1 corrected understanding.

### Bug A root cause has SHIFTED

The handoff §2 + §9 ranked the leading Bug A candidate as **A-1: slave FC RX FSM `rx_pkt_type` misdecode** (60% confidence). Phase 1+2 audit agents found:

- A-1 falsified at the unit level — slave RX FSM correctly decodes the `pkt_type` field when fed a clean stream
- The bug is therefore NOT on the slave RX side (A-1) and NOT credit-gated (PAIR_CREDIT mis-framing)
- Most likely location is the **master TX side**: either
  - `tidelink_fc_adapter` master TX FSM, or
  - `Wlink FCSM` asymmetric end state on the master

This means the dispatch order recommended in handoff §9 (ILA for A-1 first, then sim for FCSM) should be **inverted**: probe master TX first.

### Bug B is REAL and localised to master `tidelink_ptp` TX router

Once erratum (b) is applied (slave RX visibility = `PTP_CTRL @ 0x034 bit[2]`, not `PTP_STATUS @ 0x03C`), the "wrong register" framing in the handoff §9 partially dissolves. But the bug still reproduces:

- Master sets HW_SYNC_CTRL and HW_SYNC_STATUS reflects the local enable (correct, per erratum d)
- Slave's `ptp_rx_valid_r` at the correct register address (`PTP_CTRL @ 0x034 bit[2]`) **stays low**
- This localises Bug B to the master `tidelink_ptp` TX router state machine — sync packets never leave the master

### Both bugs live on MASTER TX side

The synthesis is therefore: A and B are both **master TX-side** bugs, not slave RX-side bugs. The two channels (FC AHB and PTP short-packet) share that the master never emits, not that the slave fails to receive.

## Pointer to follow-up work

In-flight Phase 3a agents are probing the master TX side. New cocotb tests in `cocotb/tidelink_top_pair/` (sim_build conflict-safe — running in parallel worktrees):

- `test_master_fc_tx_block.py` — drives N=1 AHB packet on master, hierarchical probes inside `u_master.u_fc_adapter` and `u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl` to see whether the master FC TX FSM ever advances past skid + emits the first FC word
- `test_master_ptp_tx_router.py` — drives HW_SYNC_CTRL on master, hierarchical probes inside `u_master.u_ptp` TX router state machine to see whether the sync payload is staged for short-packet TX

If either agent localises the wedge in master TX, RTL fix candidates land on `feat/td-gpio-phy-integration` with sim-gate before any farm build.

## Cross-references

- [HANDOFF_REPORT_2026_05_29.md](HANDOFF_REPORT_2026_05_29.md) — the original handoff, with errata comments inline
- [BUG_DIAGNOSES_2026_05_29.md](BUG_DIAGNOSES_2026_05_29.md) — ranked hypothesis bank (Phase 0 input to the audit)
- [archive/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md](archive/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md) — Bug A + Bug B reproduction story
- [archive/SIM_REPRO_RESULTS_2026_05_29.md](archive/SIM_REPRO_RESULTS_2026_05_29.md) — recommended `s_status & 0x3FFFD` mask for test_09 (bit 18 = `phc_locked_i` is tied high in `tb_top.sv` and falsely satisfies the weak assertion)

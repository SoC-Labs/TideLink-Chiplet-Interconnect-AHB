# TideLink L6 producer-side fix — state==1 minimum CR-emit gate

**Date**: 2026-05-26
**Branch**: `feat/td-interface-debug-l6-producer-fix`
**Worktree**: `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c`
**Files changed**:
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — NEW (override of
  `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v`)
- `flist/tidelink_fpga.flist` — re-routed FCSM_6 entry to local override
- `cocotb/wlink_pair/test_l6_slave_tx_diag.py` — NEW diagnostic-only test
  (cycle-by-cycle trace of slave FCSM TX path; not a regression gate)

## TL;DR

L5 (RX whitelist) reduced spurious framer transitions but did not close the
6/12 asymmetric-CR fuzz scenarios. L6 closes them at the **producer side**:
the slave's FCSM state==1 → state==2 transition fires too aggressively (as
soon as it sees ANY CR/CRACK from master), so the slave stops emitting its
own CR(0x44) before the master's RX framer has finished byte-aligning. The
L6 fix adds an 8-bit counter (`socl_l6_cr_emit_count`) that requires a
minimum of 32 CR-emit cycles in state==1 before the state-exit gate is
allowed to fire. After L6: **fuzz 12/12 PASS, no regressions in
`test_assert_bringup`.**

## Bug class & evidence

### Failure signature (pre-L6)
- 6/12 `test_asymmetric_failure_fuzz` scenarios end with
  `master.cr_pkt_seen_rx == 0, slave.cr_pkt_seen_rx == 1, both FCSM stuck
  at state==4 (LINK_IDLE)`.
- Hypothesis from upstream L5 agent: "Slave correctly TXs 0x45 (CRACK) but
  never 0x44 (CR)". **Confirmed by cycle-by-cycle trace, but the producer
  is fine — the issue is timing.**

### Diagnostic trace (failing scenario `hold=300_settle=100_nrec=1`)
Captured by `test_l6_slave_tx_diag.py`:

| cyc | side | event |
|-----|------|-------|
| 65  | m | STATE 0→1 (data_id=0x44) — master enters state 1 FIRST |
| 67  | s | STATE 0→1 (data_id=0x44, cr_seen_rx=0) — slave enters state 1 next |
| 234..245 | s | TXRT_OUT data_id=0x08 (axi_aw CR), 0x0c (axi_w CR) — other channels arbitrate first |
| 323..325 | s | EMIT data_id=0x44 — slave's tidelink CR finally hits the wire |
| 462 | m | STATE 1→0 — master `en_ff2_tx_demet_io_out` drops |
| 563 | s | STATE 1→2 (cr_seen_tx=1, cr_seen_rx=1) — slave exits state 1 after seeing master's CR |
| 609 | m | STATE 0→1 — master re-enters bring-up post recal |
| 611+ | m | RX_SOP data_id=0x08, 0x0c — master's RX framer finally locks and starts decoding |
| (none) | m | RX of slave's tidelink CR (data_id=0x44) — never observed |
| 833 | m | STATE 1→2 (master sees slave's CRACK from state 2) |

Summary: slave's RX framer byte-aligns at ~cyc 200 (sees master's CR),
cr_pkt_seen_tx_demet_io_out latches by cyc 563. Slave immediately exits
state 1. Master's RX framer doesn't lock until ~cyc 611 — at which point
slave is in state 2 emitting only CRACK(0x45), no longer CR(0x44).

### Root cause (RTL pinpoint)

`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v:259`:

```verilog
wire [2:0] _GEN_34 = crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out
                     ? 3'h2 : state; // FC.scala 460:52
```

This is the next-state logic for state==1. It allows transition to state==2
as soon as EITHER cr_seen OR crack_seen latches on the tx-domain
synchronizer. There is no minimum-emit gate, so the slave can leave state 1
after a single CR has been on the wire — too few for the asymmetric peer's
RX framer (still byte-aligning) to catch.

The matching data_id mux at lines 791-797 also flips to `out_prepend_swi_crack_id`
on cr_seen|crack_seen, so even if state stays at 1 the slave would emit
CRACK instead of CR — both must be gated.

## L6 fix (this commit)

`src/rtl/local_overrides/WlinkGenericFCSM_6.v` (override):

```verilog
// New parameter
module WlinkGenericFCSM_6 #(
  parameter [7:0] SOCL_L6_MIN_CR_EMITS = 8'd32
) (...);

// New register: CR-emit counter in state==1
reg [7:0] socl_l6_cr_emit_count;
wire socl_l6_cr_emit_gate_ok =
       (socl_l6_cr_emit_count >= SOCL_L6_MIN_CR_EMITS);

always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset)
    socl_l6_cr_emit_count <= 8'h0;
  else if (state != 3'h1)
    socl_l6_cr_emit_count <= 8'h0;       // re-arm whenever we leave state 1
  else if (auto_tx_out_advance & sop) begin
    if (socl_l6_cr_emit_count != 8'hff)
      socl_l6_cr_emit_count <= socl_l6_cr_emit_count + 8'h1;
  end
end

// Patched _GEN_34 (state 1 next-state) — original kept as comment
wire [2:0] _GEN_34 = (crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out)
                     & socl_l6_cr_emit_gate_ok
                     ? 3'h2 : state;

// Patched data_id mux in state==1 (lines 791-797) — only flip to CRACK
// once the gate is met
end else if (state == 3'h1) begin
  if (auto_tx_out_advance) begin
    if ((crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out)
        & socl_l6_cr_emit_gate_ok)
      data_id <= out_prepend_swi_crack_id;
    else
      data_id <= swi_cr_id;
  end
end
```

### Why MIN=32 cycles

- The failing scenarios stay naturally in state==1 for ~496 master clks
  (cyc 67..563). 32 is comfortably within that window: adds <7% to the
  state==1 critical path on the worst-case bringup, but ensures the peer
  has had ≥32 chances to byte-align onto a CR packet.
- 32 master clks at 50 MHz = 640 ns — well above any reasonable RX framer
  byte-align latency.
- 32 also matches the `swi_almost_full` / fifo back-pressure granularity
  used elsewhere in the FCSM (count is 8-bit anyway).

### Why this does NOT deadlock

- Both sides start in state 1 emitting CR.
- The MIN gate only delays state==1 exit; it does NOT add a requirement to
  see anything new from the peer.
- After MIN cycles of CR emission, the gate becomes `(cr_seen|crack_seen)`
  — identical to the original Chisel code.
- In the symmetric (passing) scenarios, both sides naturally emit ≥32 CR
  before either's cr_seen_tx latches, so the gate is met by the time the
  original condition would have fired. **L6 is a no-op in the symmetric
  case.**
- In the asymmetric (failing) scenarios, the slow side gets a guaranteed
  emit window so its CR reaches the peer.

## Regression matrix

All runs use `cocotb/wlink_pair`, `CMSDK_FPGA_SRAM_V` exported as required.

| Test | Pre-L5 baseline | L5 (whitelist) | L6 (this fix) |
|---|---|---|---|
| `test_asymmetric_failure_fuzz.test_01` (12-scenario sweep) | FAIL (6 asymmetric) | FAIL (6 asymmetric) | **PASS (12/12, 0 asymmetric)** |
| `test_asymmetric_failure_fuzz.test_02` (signature search) | FAIL/PASS varies | PASS | **PASS** |
| `test_assert_bringup` (3 tests) | 3/3 PASS | 3/3 PASS | **3/3 PASS** |
| `test_paired_recal_to_link_data.test_01` (LINK_DATA expected) | FAIL (cr_asym + max<5) | FAIL (cr_asym + max<5) | FAIL — **but cr_asym now False**; remaining max<5 is a different gap (state 4→5 needs a2l_fc_replay_link_valid, unrelated to L6) |
| `test_paired_recal_to_link_data.test_02` (diagnostic) | PASS (logs only) | PASS, cr_asym=True | **PASS, cr_asym=False** — L6 closes the asymmetric signature |
| `test_link_idle_to_link_data` (4 tests) | 3/4 PASS | 3/4 PASS | **3/4 PASS** (test_02 fail is unrelated baseline gap) |
| `test_credit_handshake_end_to_end` | FAIL (baseline gap) | FAIL | **FAIL (same as baseline)** |

**Acceptance gate (per task): 12/12 fuzz PASS + no regression in
`test_assert_bringup`** — **MET**.

## Sim ↔ HW alignment hypothesis (tdif-05/09/11)

With L6 the slave's tidelink FCSM will emit at least 32 CR packets in
state==1 regardless of when peer's CR arrives at slave's RX. Expected HW
behavior:

- **tdif-05** (asymmetric LL_RX byte-align loss): The producer is now
  symmetric. ILA captures should show master's `cr_pkt_seen_rx` latching
  shortly after its framer locks, even on the slow side.
- **tdif-09** (FCSM stuck at state 1/2): Should resolve in the failing
  fuzz-equivalent scenarios. Slave will no longer "shut the door" on
  master's framer.
- **tdif-11** (future capture): On the next post-L6 HW build, expect
  `fcsm_state` to advance past 4 in both directions when there is app
  traffic to send.

Note: L6 changes producer behavior only. If HW also has a separate RX-side
issue (e.g. an even slower framer lock than sim models), some scenarios
may still need follow-up. But the asymmetric signature MUST be closed —
that's the only protocol-level fix point.

## Caveat — not a candidate for HW build until user signs off

Per task constraints: **NO FPGA build kicked**. Sim 12/12 passes; HW
deployment is the user's call.

## Commit reference

- Branch: `feat/td-interface-debug-l6-producer-fix`
- Parent: `06f257c` (`cocotb: cherry-pick test_05 assessment from
  feat/assessment-driven-tests`)
- Override added: `src/rtl/local_overrides/WlinkGenericFCSM_6.v`
  (1,235 lines — vs 1,188 in deps, +47 for the gate)
- Flist entry replaced: deps `WlinkGenericFCSM_6.v` → local override

## Next steps

1. User to review and decide on HW deploy.
2. If HW confirms fix, consider:
   - Promoting MIN parameter via APB SWI register (already a parameter,
     trivially exposable).
   - Mirroring same gate to other FC channel FCSMs
     (`WlinkGenericFCSM.v`, `_1.v` through `_5.v`) if their bring-up shows
     similar asymmetry under stress.
3. Run paired sim on the v1 ASIC target (100 MHz) to confirm MIN=32 is
   sufficient at the slower clock too.

# Mask-FSM logic-candidate fixes

Follow-up to the mask-FSM defaults audit (`docs/MASK_FSM_DEFAULTS.md`,
commit `91cdbde`). That audit flagged 3 candidates as potential
logic-level secondary causes of the Phase A regression (primary cause —
ILA hold-timing on `pad_clk_rx` — fixed in `65a3971`). This document
records the analysis and per-candidate disposition.

Worktree: `/home/dam1n19/td_idelay_wt`
Sub branch: `fix/mask-fsm-logic-candidates` (created off `a55d346`)
Sub tip: `a30b21b`
Parent bump script: `/tmp/mask_fsm_logic_proposed_bump.sh`
File touched: `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv`
Test touched: `cocotb/tidelink_autoneg/test_tidelink_autoneg.py`
  (AxilSlave model now sets DATA[8]=data_valid, mirroring the
  i2c_master_axil.v register spec; this is **not** a behaviour change —
  silicon already drives the bit.)

---

## Summary

| Candidate | Severity            | Action      | Sub commit |
|-----------|---------------------|-------------|------------|
| #1 busy_seen_nxt MASK_RD_ADDR/TXN_COMMAND reset | LATENT (defensive)  | FIXED       | `9b43676`  |
| #2 axl_done_r cleared on every state-edge       | DISPROVEN by trace  | NO CHANGE   | n/a        |
| #3 peer_lane_mask capture without data_valid    | LATENT (defensive)  | FIXED       | `a30b21b`  |

Both committed fixes are minimal (5 / 18 lines) and additive — they
extend existing protective gates rather than reshape FSM flow. The
worst case under the existing RTL is recoverable via the 1 s global
`nego_timeout_reg`; the fixes close the window before the timeout
fires.

---

## Candidate #1 — `busy_seen_nxt` reset chain

### What the audit flagged
> Missing MASK_RD_ADDR TXN_COMMAND from reset list. Stale
> `busy_seen=1` from a previous transaction could survive into the
> next TXN_CHECK and trigger early-completion of the mask-phase.

### File:line
`tidelink_autoneg.sv:432-441` (the `else if (… == ST_NEGO_CLAIM || …)`
reset chain inside the `always_comb` for `busy_seen_nxt`).

### Trace analysis
Original reset chain covers:
1. `ST_NEGO_CLAIM` (any txn_step) — entry to autoneg's first I²C txn.
2. `MASK_RES_TX && TXN_DATA && byte_cnt==0` — first byte of result write.
3. `MASK_RD_ADDR && TXN_DATA && byte_cnt==0` — first byte of address write.
4. `MASK_RD_DATA && TXN_COMMAND` — every byte read is its own txn.

Tracing the POLL→MASK_RD_ADDR transition (lines 567+ → 599):
- At the CHECK cycle, `busy_seen_r=1` (carried from POLL).
- Transition fires; one cycle later `state_r=MASK_RD_ADDR,
  txn_step_r=TXN_DATA, byte_cnt_r=0` → entry (3) fires → `busy_seen=0`.

So the entry is **functionally covered today** by the byte-0 gate. But
the audit's concern is that this gate is structurally asymmetric with
`MASK_RD_DATA`, which resets at every `TXN_COMMAND`. If a future
refactor adds a new transition that enters `MASK_RD_ADDR` at
`TXN_COMMAND` directly (e.g. skip-DATA optimisation), the byte-0 gate
no longer fires and `busy_seen` survives.

### Severity
**LATENT / defensive.** No always-firing failure today; the audit is
about hardening the structure.

### Fix (commit 9b43676)
Add `(state_r == ST_NEGO_MASK_RD_ADDR && txn_step_r == TXN_COMMAND)`
to the reset chain alongside the existing byte-0 gate.

### Cocotb signal that would catch the latent case
A new assertion `assert busy_seen_r == 0 when entering TXN_COMMAND in
MASK_RD_ADDR/MASK_RES_TX from a non-mask state` would catch any
refactor regression.

### Regressions
- verilator --lint-only: clean
- cocotb/tidelink_autoneg: 9/9 PASS
- sv_anti_pattern_lint: clean

---

## Candidate #2 — `axl_done_r` cleared on every state-edge

### What the audit flagged
> `axl_done_r <= (state_nxt != state_r) ? 1'b0 : axl_done_nxt;`
> clears on every state edge, including MASK_RD_ADDR→MASK_RD_DATA.
> The new state's TXN_COMMAND must re-trigger AXL.

### File:line
`tidelink_autoneg.sv:1240` (inside the main sequential `always_ff`).

### Trace analysis
The AXL machine at `tidelink_autoneg.sv:1126-1132` self-fires whenever
`(state_r ∈ master-driving-states) && (txn_step_r ∈ work-steps) &&
axl_state_r == AXL_IDLE && !axl_done_r`. So after a state transition
clears `axl_done_r`:
- Cycle N: state changes, `axl_done_r` forced to 0, `axl_state_r=IDLE`.
- Cycle N+1: trigger condition matches → AXL starts fresh transaction.
- Cycle N+k: AXL_WR_RESP / AXL_RD_DATA pulses `axl_done_nxt=1`.
- Cycle N+k+1: `axl_done_r=1` → FSM advances `txn_step_r`.

The FSM does NOT depend on `axl_done_r` being set when entering the
new state. Every state-entry path goes through a fresh AXL fire before
the FSM evaluates `if (axl_done_r)`.

Verified for all 4 mask-flow state transitions:
- POLL TXN_CHECK→MASK_RD_ADDR TXN_DATA: AXL fires for byte-0 write.
- MASK_RD_ADDR TXN_CHECK→MASK_RD_DATA TXN_COMMAND: AXL fires for cmd write.
- MASK_RD_DATA TXN_DATA byte-3→MASK_RES_TX TXN_DATA: AXL fires for byte-0 write.
- MASK_RES_TX TXN_CHECK→NEGO_DONE: terminal, no AXL required.

The forced-clear at line 1240 is also defensively redundant: in the
happy path `axl_done_nxt=0` next cycle anyway (because `AXL_IDLE: if
(!axl_done_r)` gates re-fire). The clear hardens against a hypothetical
glitch where AXL_WR_RESP/AXL_RD_DATA could re-pulse without going
through IDLE.

### Severity
**DISPROVEN.** The cited behaviour is intentional and correct. The
inline comment at lines 1237-1239 ("stale done from a previous
transaction's STATUS read doesn't get mistaken for a fresh-write
completion in the next state's TXN_DATA") matches the analysis.

### Disposition
**NO CHANGE.** Audit candidate is closed as not-a-bug. The audit
should be amended to remove this candidate.

### Regressions
n/a — no code touched.

---

## Candidate #3 — peer mask capture without data_valid check

### What the audit flagged
> `peer_*_lane_mask_r <= axl_rdata_r[7:0]` — no `data_valid` (bit [8])
> check before capture. If the I²C-master rd-data FIFO is empty when
> TXN_DATA reads it, garbage is latched into the peer mask, poisoning
> the verdict.

### File:line
`tidelink_autoneg.sv:993-1003` (the `peer_*_capture_en` always_comb).

### Spec reference
`logical/i2c/rtl/i2c_master_axil.v:181`:
```
| 0x08  | Data  | … | data_last | data_valid |
| 0x08  | Data  |       data[7:0]            |
data_valid: indicates valid read data
```
Implementation at `i2c_master_axil.v:668-674`:
```
4'h8: begin // data
    s_axil_rdata_next[7:0] = data_out;
    s_axil_rdata_next[8]   = data_out_valid;
    ...
```

If the rd-FIFO is empty (`data_out_valid=0`), `data_out[7:0]` is
garbage.

### Trace analysis
Current flow protects against this via the busy/busy_seen guard:
`TXN_CHECK` waits for `!busy && busy_seen_r=1` before advancing to
`TXN_DATA` (the DATA-register pop). The busy=0 transition means the
I²C state machine completed the round-trip, so the byte SHOULD be in
the rd-FIFO.

But the guard is timing-dependent. If the i2c master IP introduces a
1-cycle lag between busy-drop and FIFO-push (a plausible future change
in a re-pipelined version), or if a clock-domain glitch eats the
FIFO-push pulse, the DATA read returns `data_valid=0` and we latch
garbage.

### Severity
**LATENT / defensive.** Recoverable today by the busy guard. The
hardening provides:
- robustness against future I²C IP refactors
- a clear failure mode (peer_mask stays at last/init value → comparator
  fails → mask_fail latched → FSM falls through to global timeout)
  rather than a silent verdict corruption.

### Fix (commit a30b21b)
1. Add `localparam I2C_DATA_VALID = 8` (mirrors spec).
2. AND-in `axl_rdata_r[I2C_DATA_VALID]` to the `peer_*_capture_en`
   gate in the always_comb.

If `data_valid=0`, capture is skipped. The FSM still advances normally
(no infinite hang); the mask comparator simply produces `mask_fail`,
which writes the `fail` verdict to the peer and falls through to
NEGO_DONE with `mask_hs_local_match=0`.

### Test impact
The cocotb `AxilSlave` model (line 482) previously set
`m_axil_rdata = rd` with bit [8]=0 — i.e. it did NOT mirror the real
i2c master IP. The new RTL gate would refuse to capture, breaking the
existing tests.

Updated the model to OR in `(1 << 8)`. This is a **model bug-fix, not a
behaviour change** — silicon already drives the bit; the model was
incorrect. Confirmed by the `wlink_pair_full` regression (which uses
the real i2c_master_axil RTL) continuing to pass without any
testbench change.

### Cocotb signal that would catch the latent case
A new test that forces `data_valid=0` on the first DATA-register read
(simulating a FIFO race) and asserts `peer_tx_lane_mask_r` stays at
its init value. Easy to add by extending `AxilSlave` with a knob.

### Regressions
- verilator --lint-only: clean
- cocotb/tidelink_autoneg: 9/9 PASS (with AxilSlave model fix)
- cocotb/wlink_pair_full: 3/3 PASS (real i2c master drives bit [8])
- sv_anti_pattern_lint: clean

---

## Recommended integration order

1. **First**: bump parent to `a30b21b` (script:
   `/tmp/mask_fsm_logic_proposed_bump.sh`). Both fixes are
   independent, additive, and defensive — there is no ordering
   constraint between #1 and #3.

2. **Wait for**:
   - Sister-agent AUTOCAL_ENABLE verification (touches
     `src/rtl/ + deps/` READ-only — no conflict expected).
   - Sister-agent overlay.py decoder fix (touches
     `pynq_host/overlay.py` only — no conflict expected).
   - In-flight FPGA build `bqgb54p6r`.

3. **Update audit** (`docs/MASK_FSM_DEFAULTS.md`): mark candidate #2
   as disproven with reference to the trace analysis in this doc.

4. **Future hardening** (out of scope for this branch):
   - Add the two cocotb assertions outlined above.
   - Add an audit pass for the `mask_byte_cnt_nxt` reset on every
     state-edge (Item-2(b) re-arm path mentions this as next-rung
     defensive work).

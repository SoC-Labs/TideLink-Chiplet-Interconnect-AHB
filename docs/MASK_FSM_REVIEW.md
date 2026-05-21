# MASK FSM Phase A Review — Does state 9 enter in cocotb sim?

**Date**: 2026-05-21
**Worktree**: `/home/dam1n19/td_idelay_wt` (branch `feat/td-combined`)
**RTL**: `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` @ submodule sub-commit `a55d346`
**Cocotb**: `cocotb/tidelink_autoneg/test_tidelink_autoneg.py` (instrumentation added)

---

## TL;DR

**The bug does NOT reproduce in cocotb sim.** State 9 (`ST_NEGO_MASK_RD_ADDR`) is
entered cleanly after a master-win arbitration; the FSM walks
`POLL → MASK_RD_ADDR → MASK_RD_DATA → MASK_RES_TX → NEGO_DONE` in 132 cycles.
Both AXIL handshakes (the 2-byte address-pointer write and the 6-byte result
write) fire to completion. `mask_hs_local_match=1` is latched on the
RES_TX → DONE edge with `peer_tx_lane_mask=0xFF, peer_rx_lane_mask=0xFF`
captured.

**Hypothesis verdict (silicon symptoms vs sim):**
* (a) "FSM enters state 9 only momentarily and bails to DONE" → **REFUTED**.
  State 9 enters for 22 cycles, walks all 4 sub-steps (DATA, COMMAND, POLL,
  CHECK), and transitions cleanly to state 10.
* (d) "MASK_RES_TX AXIL sequence fails silently" → **REFUTED**.
  AXIL handshake fires, `axl_done_r` pulses, transaction completes, FSM
  transitions to NEGO_DONE with the verdict byte latched.

The remaining viable hypotheses for the silicon defect:
* **(b) Synth-only artifacts of `mask_byte_cnt_r` / `mask_retry_r`** (Class A or
  Class B SV anti-patterns) — handed to the lint-sweep agent.
* **(c) NEGO_TIMEOUT fires before state 9 can run** — handed to the
  NEGO_TIMEOUT agent.
* **Plus**: any silicon-only failure path (e.g. AXI-Lite slave / I²C master
  IP failing to ACK, fpgahub-side AXIL stall, or the master never actually
  reaching POLL→ACK at all on the bench — recall the I²C autonomy memo
  notes the master still inert post-strap-fix).

---

## Full state-by-state cycle trace (Phase A test)

Test: `test_phase_a_state9_enters` driving:
* `nego_en=1`, `nego_pri_sel=2` (PUF), `puf_seed=0`, `puf_ready=1`
* `mask_hs_auto_en=1`, `local_tx_lane_mask=0xFF`, `local_rx_lane_mask=0xFF`
* `nego_force_lock=1`, `nego_fallback=0`, `nego_timeout_reg=200_000`
* Cocotb-driven AXIL slave returning busy=1 on first STATUS poll, busy=0 on
  second, ACK on every transaction; MASK_RD_DATA pops return `[0xFF, 0xFF,
  0x00, 0x00]`.

```
cyc=     2  (init)         -> IDLE(0)            (POR end)
cyc=     7  IDLE(0)        -> NEGO_INIT(1)       nego_en=1 sampled
cyc=     8  NEGO_INIT(1)   -> NEGO_WAIT(2)       PUF ready, backoff loaded
cyc=  2009  NEGO_WAIT(2)   -> NEGO_CLAIM(3)      backoff timer expired
cyc=  2037  NEGO_CLAIM(3)  -> NEGO_POLL(4)       PRESCALE/DATA/CMD writes done
cyc=  2047  NEGO_POLL(4)   -> MASK_RD_ADDR(9)    POLL ACK, mask_hs_auto_en=1
cyc=  2069  MASK_RD_ADDR(9)-> MASK_RD_DATA(10)   2-byte addr write ACKed
cyc=  2141  MASK_RD_DATA(10)-> MASK_RES_TX(8)    4-byte mask read complete
cyc=  2179  MASK_RES_TX(8) -> NEGO_DONE(5)       6-byte result write ACKed
                                                  mask_hs_local_match=1
```

## Cycle counts per state

| State | Name            | Cycles | Entries | Sub-steps observed (txn_step_r values) |
|-------|-----------------|--------|---------|----------------------------------------|
| 0     | IDLE            | 5      | 1       | {PRESCALE}                             |
| 1     | NEGO_INIT       | 1      | 1       | {PRESCALE}                             |
| 2     | NEGO_WAIT       | 2001   | 1       | {PRESCALE} (backoff)                   |
| 3     | NEGO_CLAIM      | 28     | 1       | {PRESCALE, DATA, COMMAND}              |
| 4     | NEGO_POLL       | 10     | 1       | {POLL, CHECK}                          |
| 5     | NEGO_DONE       | 51     | 1       | {CHECK}                                |
| 8     | MASK_RES_TX     | **38** | 1       | {DATA, COMMAND, POLL, CHECK}           |
| 9     | MASK_RD_ADDR    | **22** | 1       | {DATA, COMMAND, POLL, CHECK}           |
| 10    | MASK_RD_DATA    | **72** | 1       | {DATA, COMMAND, POLL, CHECK}           |

Total master-side mask flow (states 9+10+8) = 132 cycles ≈ 1.3 µs @ 100 MHz.

## Final-state observables

| Signal                  | Value     | Meaning                          |
|-------------------------|-----------|----------------------------------|
| `nego_state`            | 5 (DONE)  | terminal state reached           |
| `nego_done`             | 1         | -                                |
| `nego_won`              | 1         | master role won                  |
| `nego_lost`             | 0         | -                                |
| `nego_error`            | 0         | no fault                         |
| `peer_tx_lane_mask_o`   | 0xFF      | byte 0 of MASK_RD_DATA captured  |
| `peer_rx_lane_mask_o`   | 0xFF      | byte 1 of MASK_RD_DATA captured  |
| `mask_hs_local_match`   | 1         | comparator latched on 8→5 edge   |
| `mask_hs_local_fail`    | 0         | -                                |

## Where the silicon trace diverges

The cocotb FSM transition log shows the **exact transition the JTAG ILA was
armed to capture** (state 9 entry, line `cyc=2047 NEGO_POLL(4) -> MASK_RD_ADDR(9)`)
fires deterministically and is observable for 22 cycles. The ILA never
triggering on bench means **either**:
1. The bench master never reached the precondition (`POLL → ACK + mask_hs_auto_en=1`).
   That precondition needs the I²C master IP to (a) finish a successful
   `cmd_start | cmd_write | cmd_stop` to the negotiation address, and
   (b) return STATUS busy=1 then busy=0 with `miss_ack=0`. Given the
   I²C-autonomy memo's note that the FSM advances IDLE → POLL but the bus
   stays inert, the master is **never escaping POLL → NACK / NEGO_DONE
   via the lost branch** — never the win-with-mask branch.
2. A synth-only artifact stops `mask_byte_cnt_r` from advancing past byte 0
   (Class B "collapsed case"), so even if state 9 *did* enter momentarily,
   `txn_step_r` cannot progress and the global NEGO_TIMEOUT then drops the
   FSM into ERROR before the JTAG capture-window ARMs.

## Recommendation (1 line)

**Hypothesis (b) — synth-only artifact in `mask_byte_cnt_r` / `mask_retry_r`
case statements** — is the leading candidate; pair with the sv_anti_pattern
lint sweep on `mask_*` registers and confirm at the bench by widening the
ILA trigger to `state_r >= 8 || state_r == 7` (any mask state OR ERROR) and
checking whether the master is even reaching POLL→ACK.

## Reproduction

```bash
cd /home/dam1n19/td_idelay_wt/cocotb/tidelink_autoneg
make TESTCASE=test_phase_a_state9_enters
make TESTCASE=test_phase_a_state8_to_done_transition
# or all 9 tests:
make
```

Trace output lives in `sim_build/` (waves.vcd) and on stdout.

## Files touched

* `cocotb/tidelink_autoneg/test_tidelink_autoneg.py` — added `FsmTracer` +
  `AxilSlave` helper classes, `test_phase_a_state9_enters`,
  `test_phase_a_state8_to_done_transition`.
* `cocotb/tidelink_autoneg/tb_top.sv` — removed unconnected `train_*` port
  bindings (train subsystem isn't on this branch's autoneg yet); tied tb_top
  train output pins to constants so harness ABI stays compatible with sister
  benches.
* `docs/MASK_FSM_REVIEW.md` — this file.
* No RTL changes.

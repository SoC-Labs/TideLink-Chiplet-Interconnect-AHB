# UVM Test Plan — I²C-Coordinated Training-Mode Protocol

**Status:** Design only. Tests are to be authored by the UVM-test author (PHY-Align integration as-built is in `docs/TIDELINK_SPECIFICATION.md §9.10`).
**Target testbench:** `uvm/tidelink_top_system/` (pair-back-to-back instantiation).
**Companion spec:** [`I2C_TRAIN_PROTOCOL.md`](I2C_TRAIN_PROTOCOL.md).
**RTL under test:** the extended `tidelink_autoneg` FSM with `ST_TRAIN_*` states (sketched in [`tidelink_autoneg_train_states.sv`](tidelink_autoneg_train_states.sv)), plus the autonomous calibration FSM (separate agent), plus the APB register block extensions at offsets `0x090..0x0A8`.

## Common setup

All tests instantiate the existing `tidelink_top_system` paired-DUT testbench from `uvm/tidelink_top_system/tb/top.sv`. Three pieces of additional infrastructure are needed:

### Common infrastructure A — I²C model

Two short Verilog files in `uvm/tidelink_top_system/tb/` (sit alongside existing `top.sv`):

- `i2c_bus_model.sv` — wired-OR open-drain model of the SCL/SDA pair. Two ports each side (`scl_o/scl_t`, `sda_o/sda_t`), one `scl_i/sda_i` input per side. Implementation: `assign scl = (a_scl_t == 1'b0 ? a_scl_o : 1'bz) & (b_scl_t == 1'b0 ? b_scl_o : 1'bz);` with `pulldown(scl)` for high-Z resolution to the bus pull-up. Same for SDA. Trivial. Connects to both peers' `i2c_*` ports.
- (Optional) `i2c_bus_probe.sv` — passive monitor that decodes transactions and reports them as UVM transactions on an analysis port. Useful for assertion writing; not strictly required.

### Common infrastructure B — Force-injection points

Tests need to inject lane skid (existing `pad_skid.sv` mechanism, the per-lane extension is captured in `docs/TIDELINK_SPECIFICATION.md §9.10.1` sub-step 2) and selectively force a lane checker to never lock. Two existing hierarchical-ref points:

- `top.dut_a.u_wlink.u_phy.lane_locked_r[k]` — force to 0 to simulate a stuck lane.
- `pad_skid_per_lane[k]` parameters — set at instantiation.

The test class encapsulates these via a `tidelink_align_skid_cfg` config object.

### Common infrastructure C — APB sequence helpers

Re-use the existing `tidelink_apb_seq` base sequence and add a few new sequences:

- `read_nego_train_status_seq` — reads `NEGO_TRAIN_STATUS @ 0x094` and packs the response into a typed struct.
- `wait_train_done_seq` — polls `NEGO_TRAIN_STATUS.train_in_progress` until 0, with a configurable timeout.
- `assert_train_ok_seq` — reads `NEGO_TRAIN_STATUS`, expects `train_ok = 1, train_fail = 0`, fails otherwise.

## Cross-cutting assertions

The following SVAs apply to all tests (lift into `uvm/tidelink_top_system/checkers/train_assertions.sv`):

1. `a_train_state_advances_monotonically`: `NEGO_TRAIN_STATUS.train_state` only increases (modulo retrain) while `train_in_progress = 1`.
2. `a_no_lltx_during_run`: while `train_state == 4'd2 (ST_TRAIN_RUN)`, the FCSM must remain stalled (not advance past SEND_CREDITS1 on either die) — the autonomous cal FSM is responsible for this gate; this assertion catches a regression.
3. `a_training_mode_symmetric`: when master's `train_state == 4'd2 (ST_TRAIN_RUN)`, both dice's `SWI_TRAINING_MODE.bit[0]` must be 1.
4. `a_train_ok_implies_fcsm_advance`: within 100 µs of master's `train_ok` rising edge, both peers' FCSM must reach state 4.
5. `a_train_fail_no_hang`: `train_fail = 1` does NOT cause the FSM to hang at the `ST_TRAIN_FAIL` state for more than 1 ms; the IRQ is asserted and SW visibility through `NEGO_TRAIN_STATUS` is intact.
6. `a_no_i2c_during_run`: during `ST_TRAIN_RUN`, no I²C traffic occurs (no START conditions on the bus). Confirms the per-lane cal FSMs run with no peer coordination.

## Coverage points (common)

- `cp_train_state`: bins for each `ST_TRAIN_*` state value (visited).
- `cp_train_poll_attempts`: bins {0, 1, 2-3, 4-7, 8-15, 16}. Tests that exercise non-zero attempts must hit the relevant bin.
- `cp_train_outcome`: bins {OK, FAIL_PEER_NACK, FAIL_PEER_LANE_FAULT, FAIL_LOCAL_LANE_FAULT, FAIL_TIMEOUT}.
- `cp_train_retrain_count`: bins {0, 1, 2-3, 4+}.
- `cp_lane_locked_pattern`: 8-bit `swi_lane_locked` value at exit; bins for `0xFF` (all locked), `0x00` (none), and 6 per-lane-fault patterns.

## Test 1 — `test_train_i2c_handshake` (happy path)

### Setup

- `pad_skid_per_lane = [3, 3, 3, 3, 3, 3, 3, 3]` (uniform 3-bit skid, the FPGA bring-up condition).
- `NEGO_CFG.mask_hs_auto_en = 1`, `NEGO_TRAIN_CFG.train_auto_en = 1`.
- `mask_hs_bypass_i = 0` (un-tied — testing the real autoneg + training path).
- I²C model connected, both peers driving the same wired-OR.
- `i2c_prescale_reg = 250` (100 kHz I²C, matching the FPGA default).
- No force-injection; all 8 lanes are healthy.

### Expected FSM walk (master side, observed via `NEGO_TRAIN_STATUS.train_state` waveform)

```
ST_IDLE (0) → ST_NEGO_* (existing autoneg, finishes with nego_won=1)
            → ST_NEGO_DONE_PRE (visible as train_state=0)
            → ST_TRAIN_ENTER (train_state=1)
              [I²C write to peer 0x098 := 0x01, ACK received]
            → ST_TRAIN_RUN (train_state=2)
              [hold 4096 cycles]
            → ST_TRAIN_POLL_PEER (train_state=3)
              [I²C read peer 0x0A0, returns 0xFF]
              [poll_attempt=0; all_locked=1 first try]
            → ST_TRAIN_EXIT (train_state=4)
              [I²C write peer 0x098 := 0x00, ACK]
              [local swreset hold 128 cycles]
            → ST_TRAIN_DONE (train_state=5)
              [train_ok=1, train_in_progress=0]
            → FCSM advances to state=4 on both peers
```

### Slave-side observations

- The slave's `NEGO_TRAIN_STATUS.train_state` stays at `0` (ST_TRAIN_IDLE / ST_NEGO_DONE_PRE) the whole time — the slave is a passive participant.
- The slave's `SWI_TRAINING_MODE.bit[0]` rises when the master's I²C write completes (in master's `ST_TRAIN_ENTER`), holds through `ST_TRAIN_RUN` and `ST_TRAIN_POLL_PEER`, and falls when the master's `ST_TRAIN_EXIT` I²C write completes.
- The slave's `SWI_LANE_LOCKED` transitions from `0x00` to `0xFF` during `ST_TRAIN_RUN` as the autonomous cal FSM converges.

### Assertions (in addition to common cross-cutting)

- `assert(master.train_state` visits {1, 2, 3, 4, 5} in order, each exactly once)
- `assert(master.train_ok == 1 && master.train_fail == 0 within 10ms of test start)`
- `assert(slave.SWI_LANE_LOCKED == 0xFF` at the moment master enters `ST_TRAIN_EXIT`)
- `assert(both peers' FCSM state == 4 within 100 µs of master.train_ok rising)`
- `assert(I²C transaction count == 3` over the whole test: 1 × ENTER-write, 1 × POLL_PEER-read, 1 × EXIT-write)
- `assert(no NACK observed on the bus)`

### Coverage points (test-specific)

- `cp_train_outcome` bin `OK` hit (this is the happy-path test, but coverage closure relies on this test exercising it).
- `cp_train_poll_attempts` bin `0` hit (single-poll success).
- `cp_lane_locked_pattern` bin `0xFF` hit.

## Test 2 — `test_train_lane_fault` (one lane's checker never locks)

### Setup

- `pad_skid_per_lane = [3, 3, 3, 3, 3, 3, 3, 3]`.
- `NEGO_CFG.mask_hs_auto_en = 1`, `NEGO_TRAIN_CFG.train_auto_en = 1`.
- **Force-injection:** `uvm_hdl_force("top.dut_b.u_wlink.u_phy.lane_locked_r[3]", 1'b0)` at simulation start — slave's lane 3 checker is stuck at 0. The slave's autonomous cal FSM exhausts its retries on lane 3 and asserts `swi_lane_fault[3] = 1`, `swi_calibration_done = 1` (with one bit unlocked).
- All other config same as Test 1.

### Expected FSM walk (master)

```
ST_NEGO_* → ST_NEGO_DONE_PRE
          → ST_TRAIN_ENTER (success)
          → ST_TRAIN_RUN (4096 cycles)
          → ST_TRAIN_POLL_PEER
            [poll 0: master.SWI_LANE_LOCKED=0xFF, slave.SWI_LANE_LOCKED=0xF7, all_locked=0]
            [poll 1..15: same (slave's lane 3 is dead)]
            [poll 16 (= timeout): give up]
          → ST_TRAIN_FAIL
            [Read peer's SWI_LANE_FAULT @ 0x0A4: returns 0x08]
            [train_peer_lane_fault_o = 0x08]
            [train_local_lane_fault_o = 0x00 (master's lanes are healthy)]
            [train_fail_irq fires]
```

### Slave-side observations

- Slave's `SWI_LANE_LOCKED` stalls at `0xF7` (lane 3 = 0).
- Slave's `SWI_LANE_FAULT` reaches `0x08` after the autonomous cal FSM exhausts retries.
- Slave's `SWI_CALIBRATION_DONE` asserts (calibration is "done", just with a fault).

### Assertions

- `assert(master.train_fail == 1, master.train_ok == 0 within 17ms)`
- `assert(master.NEGO_TRAIN_STATUS.train_peer_lane_fault == 8'h08)`
- `assert(master.NEGO_TRAIN_STATUS.train_peer_lane_locked == 8'hF7)`
- `assert(master.NEGO_TRAIN_STATUS.train_local_lane_fault == 8'h00)`
- `assert(master.NEGO_TRAIN_STATUS.train_peer_nack == 1'b0)` (peer was responsive; just had a lane fault)
- `assert(train_fail_irq asserted)`
- `assert(neither peer's FCSM advances to state 4)` (training failed; FCSM remains stuck)
- `assert(I²C transaction count between 17 and 18`: 1 × ENTER + 16 × POLL + 1 × FAULT_READ + 0 × EXIT — there is no exit because FAIL terminates without dropping training mode; SW handles cleanup. Integrator may decide to add an EXIT-on-FAIL transaction; if so, this assertion changes to 17-18.)

### Coverage points

- `cp_train_outcome` bin `FAIL_PEER_LANE_FAULT` hit.
- `cp_train_poll_attempts` bin `16` (timeout reached).
- `cp_lane_locked_pattern` bin `0xF7` (one-lane fault).

## Test 3 — `test_train_no_peer_response` (I²C times out)

### Setup

- `pad_skid_per_lane = [3, 3, 3, 3, 3, 3, 3, 3]`.
- `NEGO_CFG.mask_hs_auto_en = 1`, `NEGO_TRAIN_CFG.train_auto_en = 1`.
- **Force-injection:** disable the slave's I²C slave core. Two options:
  - Option A: hold the slave's `apb_debug_unlock_i` low so the slave's chiplet controller never powers up — its I²C slave is silent.
  - Option B: `uvm_hdl_force("top.dut_b.u_chiplet_ctrl.u_i2c_slave_core.enable", 1'b0)` — disables only the I²C slave, leaves the rest of the slave running. Cleaner but requires the hierarchical path to exist.
  - Recommendation: Option B.
- All other config same as Test 1.

### Expected FSM walk (master)

```
ST_NEGO_* → fails at ST_NEGO_CLAIM (peer doesn't ACK the mask negotiation either)
          OR completes via SDA early-exit (sda_start_seen=0; we won)
```

Note: this test partly exercises the existing autoneg failure paths too. The interesting failure is **during training**, so the test forces the I²C slave to fail AFTER the autoneg completes:

- Use a `uvm_hdl_force` race: keep slave's I²C slave enabled until master's `nego_done = 1`, then disable.
- Then:

```
          → ST_NEGO_DONE_PRE
          → ST_TRAIN_ENTER
            [I²C write to peer 0x098: master times out waiting for ACK]
            [I2C_STS_MISS_ACK = 1]
          → ST_TRAIN_FAIL
            [train_peer_nack = 1]
            [train_peer_lane_fault = 0xFF (poison sentinel)]
            [train_local_lane_fault = master's SWI_LANE_FAULT snapshot]
            [train_fail_irq fires]
```

### Assertions

- `assert(master.train_fail == 1, master.train_ok == 0 within 5ms)`
- `assert(master.NEGO_TRAIN_STATUS.train_peer_nack == 1'b1)`
- `assert(master.NEGO_TRAIN_STATUS.train_peer_lane_fault == 8'hFF)` (poison sentinel)
- `assert(slave.SWI_TRAINING_MODE == 1'b0)` (slave never entered training)
- `assert(neither peer's FCSM advances to state 4)`
- `assert(I²C bus shows START + slave address + no ACK + STOP)` (single failed transaction)
- `assert(master's FSM does NOT hang)` — train_fail latches, state reaches ST_TRAIN_FAIL, IRQ asserts

### Coverage points

- `cp_train_outcome` bin `FAIL_PEER_NACK` hit.
- `cp_train_state` bin `ST_TRAIN_FAIL` hit on master.

## Test 4 — `test_train_async_re_train` (link drops, retrain)

### Setup

- `pad_skid_per_lane = [3, 3, 3, 3, 3, 3, 3, 3]`.
- `NEGO_CFG.mask_hs_auto_en = 1`, `NEGO_TRAIN_CFG.train_auto_en = 1`.
- Test executes in two phases:
  - **Phase A — initial bring-up:** identical to Test 1. Wait for `train_ok = 1` and FCSM = 4.
  - **Phase B — induce link drop:** at `T_DROP = T_phase_A_done + 1 ms`, change the per-lane skid mid-simulation: drive `pad_skid_per_lane[3] = 5` (lane 3 now wrong by 2 extra bits). Observe `swi_lane_locked[3]` drops to 0 on at least one side.
  - **Phase C — retrain:** SW writes `NEGO_TRAIN_CFG.train_retrain = 1`. Observe the FSM walks `ST_TRAIN_DONE → ST_NEGO_DONE_PRE → ST_TRAIN_ENTER → ST_TRAIN_RUN → ST_TRAIN_POLL_PEER → ST_TRAIN_EXIT → ST_TRAIN_DONE` and `swi_lane_locked` is restored to `0xFF`. Final FCSM state = 4.

### Expected FSM walk

Two complete walks through `ST_TRAIN_ENTER → DONE`, separated by `T_DROP` of operation in `ST_TRAIN_DONE`.

### Assertions

- `assert(master visits ST_TRAIN_ENTER twice)` (initial + retrain)
- `assert(both train_ok pulses observed)`
- `assert(after retrain, both peers' FCSM state == 4)`
- `assert(during phase B, neither train_ok nor train_fail change state)` — the FSM only re-engages on explicit `train_retrain` request, not autonomously on lane-lock loss. (If a future iteration adds auto-retrain on persistent unlock, this assertion changes.)
- `assert(no double-pulse on train_retrain)` — the W1P bit self-clears; only one entry into `ST_NEGO_DONE_PRE` per write.

### Coverage points

- `cp_train_retrain_count` bin `1` hit.
- `cp_train_outcome` bin `OK` hit twice.

## Test 5 — `test_train_with_apb_override` (SW pre-loads bit_slip; FSM respects)

### Setup

- `pad_skid_per_lane = [3, 5, 0, 2, 7, 1, 4, 6]` (the asymmetric pattern from existing cocotb tests).
- `NEGO_CFG.mask_hs_auto_en = 1`, `NEGO_TRAIN_CFG.train_auto_en = 1`.
- **SW pre-load:** before triggering autoneg, the test writes `SWI_BIT_SLIP_LO @ 0x0A8` directly via APB on **both** dice with the known-correct values:
  - Master writes `0x00345210` (lane 7=6, 6=1, 5=7, 4=2, 3=0, 2=5, 1=3, 0=... wait, this is wrong, let me redo: lane K at bits [3K+2 : 3K]. For pattern `[3, 5, 0, 2, 7, 1, 4, 6]`, lane 0=3, 1=5, 2=0, 3=2, 4=7, 5=1, 6=4, 7=6. Packed: `[7=6][6=4][5=1][4=7][3=2][2=0][1=5][0=3]` = `0b110_100_001_111_010_000_101_011` = `0x68FA0AB`. The exact value isn't crucial; the test just needs to assert the value persists.)

- The pre-load is done via local APB writes, not via I²C. The test verifies the FSM's training cal does not overwrite the SW pre-load.

### Expected behaviour

There are two valid implementations of "SW override":

- **(a) The autonomous cal FSM honours a pre-loaded slip value if `SWI_LANE_LOCKED[k]` is already `1` for lane k.** I.e., the FSM tests for lock with the current slip before sweeping. Some lane k that's pre-loaded correctly will lock immediately, the FSM never modifies it.
- **(b) The autonomous cal FSM has an explicit `slip_override_en` bit in the PHY register block — if set, the cal FSM is a passive observer and never writes `swi_bit_slip`. Lock-test only.**

This test exercises whichever the cal-FSM agent chose. If neither implementation is present, this test serves as a feature request: the SW-override path must be available.

### Expected FSM walk

```
ST_NEGO_* → ST_NEGO_DONE_PRE → ST_TRAIN_ENTER → ST_TRAIN_RUN (immediate lock) → ST_TRAIN_POLL_PEER (poll 0 succeeds) → ST_TRAIN_EXIT → ST_TRAIN_DONE
```

### Assertions

- `assert(SWI_BIT_SLIP_LO post-test == SWI_BIT_SLIP_LO pre-load)` — FSM did not modify SW pre-load.
- `assert(master.train_ok == 1 within 5 ms)` (fast path because lock is immediate).
- `assert(both peers' FCSM state == 4 within 100 µs of train_ok)`.
- `assert(NEGO_TRAIN_STATUS.train_poll_attempts == 0)` (first-poll success).

### Coverage points

- `cp_train_poll_attempts` bin `0` hit (under non-uniform skid — distinct from Test 1).
- A new coverage point `cp_slip_pattern` with the asymmetric value hit, if the integrator wants per-lane coverage tracking.

## Test ordering and dependencies

```
test_train_i2c_handshake          (T1)  — baseline; gates everything else
test_train_with_apb_override      (T5)  — exercises the cal-FSM/SW interaction
test_train_async_re_train         (T4)  — depends on T1's bring-up working
test_train_lane_fault             (T2)  — exercises the FAIL path
test_train_no_peer_response       (T3)  — exercises the NACK path
```

Run T1 first; if it does not pass, none of the others is meaningful.

## Notes for the UVM-test author

1. **Reuse `tidelink_align_skid_cfg`** if it already exists (per `uvm/tidelink_top_system/tests/test_align_*.sv` precedents). Per-lane skid is set via the config DB.
2. **I²C transaction count assertion** is the cleanest way to detect "FSM did extra work" or "FSM did less work than expected". Count START conditions on the SDA model and compare against an expected number.
3. **The slave-side FSM is passive** — assertions on slave should focus on its register state (`SWI_TRAINING_MODE`, `SWI_LANE_LOCKED`, `SWI_LANE_FAULT`) and FCSM state, not on slave's `NEGO_TRAIN_STATUS.train_state` (which stays at 0).
4. **Coverage closure** for production sign-off requires all 5 tests to pass and all `cp_train_*` coverage points to be hit at 100%. Tests 1+4 cover OK; T2 covers lane fault; T3 covers NACK; T5 covers override. Add a regression-only test for `FAIL_LOCAL_LANE_FAULT` (force master's lane checker stuck) if completeness matters.
5. **Test 3's force-injection timing** is the trickiest — disabling the slave's I²C slave at the wrong moment can wedge the autoneg's mask-handshake mid-transaction. Recommend a UVM phase callback that fires `uvm_hdl_force` only after `master.nego_done = 1` is observed.
6. **Re-uses existing UVM infrastructure**: `tidelink_apb_seq`, `tidelink_align_pad_skid_drv`, `tidelink_align_checker_obs`, `tidelink_align_scoreboard`. No new UVM components needed for these tests.

## Out of scope for this test plan

- Performance characterisation (time-to-bring-up under varying I²C prescale values). Add later as `test_train_perf_sweep` if needed.
- Power state interactions (LP entry during training). Out of scope; defer to a separate power-state test plan.
- Multi-die scaling (>2 peers on the same I²C bus). Not in v1 of TideLink; defer.

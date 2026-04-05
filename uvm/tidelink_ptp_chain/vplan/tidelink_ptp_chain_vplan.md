# TideLink PTP Chain Verification Plan

## 1. Overview

This document describes the verification plan for the `tidelink_ptp_chain` UVM testbench, which verifies PTP clock synchronisation chaining across a 3-chiplet topology using 4 `tidelink_top` instances and 3 PHC (PTP Hardware Clock) instances.

### 1.1 Scope

The testbench verifies:
- **Lock gate mechanism**: `phc_locked_i` input gates the HW sync initiator FSM, preventing SYNC generation until the upstream servo has locked
- **Force-enable bypass**: `HW_SYNC_CTRL[2]` overrides the lock gate for testing/debug
- **Lock propagation**: `servo_locked` from one `tidelink_top` drives `phc_locked_i` on another
- **Cascaded PTP convergence**: A→B→C clock synchronisation through two Wlink links
- **Shared PHC**: Two `tidelink_top` instances share a single PHC (Chiplet B)
- **CDC Path 2**: Free-running PHC time propagation through the CDC bridge after reset

### 1.2 Testbench Topology

```
Chiplet A (GM)              Chiplet B (Sub→GM)           Chiplet C (Sub)
┌──────────────┐            ┌──────────────┐            ┌──────────────┐
│ tidelink_top │  PHY pad   │ tidelink_top │  PHY pad   │ tidelink_top │
│ + PHC_A      │ crossover  │ _link1       │ crossover  │ + PHC_C      │
│              ├───────────►│              │            │              │
│              │◄───────────┤  PHC_B       │            │              │
│              │            │ (shared)     │            │              │
│              │            │ tidelink_top │            │              │
│              │            │ _link2       ├───────────►│              │
│              │            │ (LOCK_GATE=1)│◄───────────┤              │
└──────────────┘            └──────────────┘            └──────────────┘

b1_servo_locked ──────────► b2.phc_locked_i (lock gate)
```

- PHC_A: free-running Grandmaster reference
- PHC_B: shared between B_link1 (Sub) and B_link2 (GM), disciplined by link1 servo
- PHC_C: disciplined by link2 servo
- B_link2 has `PHC_LOCK_GATE_EN=1`; all others have `PHC_LOCK_GATE_EN=0`

### 1.3 Out of Scope

- SerDes PHY electrical behaviour (using GPIO behavioural model)
- PLL/clock generation internals
- Scan/DFT chains
- Full PTP servo convergence to sub-microsecond accuracy (simulation speed limitation)

## 2. Feature List

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| CF1 | Lock gate blocks HW sync until phc_locked_i | P0 | HW sync FSM cannot transition IDLE→ARMED while phc_locked_i=0 and force_en=0 |
| CF2 | Lock gate rising-edge triggers arm | P0 | If hw_sync_en is already set when phc_locked_i rises, FSM arms on the rising edge |
| CF3 | force_en bypasses lock gate | P0 | HW_SYNC_CTRL[2]=1 allows arming regardless of phc_locked_i state |
| CF4 | Lock drop does not disrupt running FSM | P1 | Once FSM passes IDLE, phc_locked_i deassertion does not force return to IDLE |
| CF5 | HW_SYNC_STATUS[18] reflects phc_locked_i | P0 | Software-readable bit tracks the external lock input in real time |
| CF6 | Cascaded PTP convergence A→B→C | P0 | Both hops achieve servo lock with correct offset/delay computation |
| CF7 | Lock propagation delay | P1 | Measure cycles between B1 lock and B2 first SYNC generation |
| CF8 | PHC_B shared between two tidelink_top instances | P0 | hw_capture, timestamps, and adjustments correctly multiplexed |
| CF9 | CDC Path 2 time propagation after reset | P0 | PHC nanoseconds/seconds reach HW sync comparator within a few cycles of reset |
| CF10 | PTP short packets through Wlink GPIO PHY | P0 | SYNC (0x50) and DELAY_REQ (0x51) traverse full link layer |
| CF11 | Servo SIDEBAND timestamp exchange through FC | P1 | GM sends t1/t4 via FC SIDEBAND, Sub receives and computes offset |
| CF12 | Step recovery propagates through chain | P2 | Phase step on A recovers through B to C |
| CF13 | Background FIFO traffic during PTP | P2 | Concurrent mailbox packets do not disrupt PTP convergence |

## 3. Test Plan

| Test | Features | Description | Strategy |
|------|----------|-------------|----------|
| test_chain_convergence | CF6, CF8, CF9, CF10, CF11 | Full A→B→C cascaded lock with autonomous servos | Wait for real convergence (long sim) |
| test_chain_lock_propagation | CF1, CF2, CF5, CF7 | Verify lock gate blocks B2, then force b1_servo_locked=1 to trigger arming | Force-based (fast sim) |
| test_chain_force_enable | CF3, CF5 | Enable B2 HW sync with force_en=1 while phc_locked=0 | Force-based (fast sim) |
| test_chain_b_unlock_c_holds | CF1, CF4 | Lock→unlock→re-lock cycle on B1, verify B2 gate behaviour | Force-based (fast sim) |
| test_chain_step_recovery | CF12 | Inject phase step on PHC_A, observe recovery through chain | Requires convergence |
| test_chain_stress | CF13 | Background FIFO traffic concurrent with PTP exchanges | Requires convergence |

### 3.1 Cocotb Unit Tests (PHC_LOCK_GATE_EN=1)

These tests exercise the lock gate logic directly at the `tidelink_ptp` module level using `tb_top_gated.sv` (which sets `PHC_LOCK_GATE_EN=1`):

| Test | Features | Description |
|------|----------|-------------|
| LG-01: test_gate_blocks_arm | CF1 | phc_locked_i=0 prevents HW sync arming |
| LG-02: test_gate_allows_arm_when_locked | CF1, CF9 | phc_locked_i=1 allows normal operation |
| LG-03: test_enable_before_lock | CF2 | Enable first, lock later — arms on lock rising edge |
| LG-04: test_force_enable_overrides_gate | CF3 | force_en=1 bypasses lock gate |
| LG-05: test_lock_drop_while_armed | CF4 | Lock drop after arming does not disrupt FSM |
| LG-06: test_status_phc_locked_bit | CF5 | HW_SYNC_STATUS[18] tracks phc_locked_i |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_lock_gate_state | {locked_at_enable, enable_before_lock, force_en, lock_drop} | 100% |
| cg_phc_locked_transitions | {0→1, 1→0, stable_0, stable_1} | 100% |
| cg_hw_sync_fsm_with_gate | {idle_blocked, idle_to_armed, armed_lock_drop, fire_lock_drop} | 100% |
| cg_chain_convergence | {ab_locked, bc_locked, both_locked} | 100% |
| cg_force_enable | {force_with_lock_low, force_with_lock_high} | 100% |

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >90% |
| Condition coverage | >85% (especially hw_sync_gate conditions) |
| FSM coverage | 100% (all HW_SYNC states and transitions with gate) |
| Toggle coverage | >80% |
| Branch coverage | >85% |

### 4.3 Key Coverage Holes to Close

- `hw_sync_gate_rising` path (enable-before-lock ordering)
- `hw_sync_force_en_r` register write and readback
- HW_SYNC_STATUS bit [18] toggle coverage
- CDC Path 2 `time_req_toggle_h` kick-start after reset

## 5. Scoreboard Strategy

The chain scoreboard tracks:

1. **Per-hop convergence**: Exchange records (offset, delay) for A→B and B→C hops
2. **Lock propagation timing**: Cycle count between B1 lock and B2 first SYNC
3. **Cascade settling**: Exchange number when both hops are locked simultaneously
4. **Steady-state metrics**: Mean and standard deviation of offset per hop

## 6. Risks and Assumptions

### 6.1 Assumptions

- GPIO PHY provides link-up after reset without additional configuration
- Wlink short packet path (data_id 0x50-0x51) functions with default swi_short_packet_max
- PHC clock core counts with forced ns_incr=10 and ctrl_enable=1
- Both clock domains (hclk, phc_clk) use the same clock in testbench

### 6.2 Known Risks

| Risk | Mitigation |
|------|------------|
| 4-DUT simulation speed (~85 ns/s) | Force-based tests for gate logic; convergence test uses long timeout |
| CDC Path 2 deadlock (BUG-005) | Fixed by resetting time_req_toggle_h to 1'b1; tested in LG-02 |
| PHC time not reaching HW sync comparator | Testbench forces ctrl_enable and ns_incr; hierarchical assigns for nanoseconds/seconds |
| Wlink short packet configuration | Default swi_short_packet_max=0x7f covers 0x50/0x51 |
| Shared PHC hw_capture contention | B1 and B2 captures ORed; exchanges are interleaved, not concurrent |

### 6.3 Future Enhancements

- Full PTP convergence testing with realistic PI gains and longer simulation
- Multi-hop chain (4+ chiplets) scaling test
- Asymmetric link latency testing (different PHY delays per link)
- CDC with truly asynchronous phc_clk (frequency offset)
- Wlink CRC error injection during PTP exchange

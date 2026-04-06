# TideLink Verification Gaps Closure Plan

## 1. Overview

This document describes the verification plan for closing the verification gaps identified in SHORTCOMINGS.md items 28-35. Each gap maps to a specific test environment, test strategy, and set of checkers.

### 1.1 Scope

| Gap | Shortcoming | Primary Environment | Fallback Environment |
|-----|-------------|---------------------|----------------------|
| G28 | Error recovery path not tested E2E | UVM `tidelink_system` | cocotb `tidelink_py_pair` |
| G29 | CDC multi-clock ratio not exercised | cocotb `tidelink_ptp` | UVM `tidelink_ptp_chain` |
| G30 | Address translator not tested in integration | UVM `tidelink_top_system` | cocotb `tidelink_top` |
| G31 | Pair credit counter underflow not tested | UVM `tidelink_system` | cocotb `tidelink_py_pair` |
| G32 | Partial packet abandon not tested | UVM `tidelink_system` | cocotb `tidelink_system` |
| G33 | No throughput/latency characterisation | UVM `tidelink_system` + `tidelink_top_system` | cocotb `tidelink_system` |
| G34 | PTP multi-hop chaining not verified | UVM `tidelink_ptp_chain` | - |
| G35 | Coordinated chiplet reset not tested | UVM `tidelink_top_system` | UVM `tidelink_system` |

### 1.2 Dependencies

- G28 requires a modified AHB slave responder that can inject `hresp=1` on the returner master port. The existing `ahb_rx_responder.sv` always returns OKAY; a new error-injecting variant is needed.
- G29 requires testbench clock generation with independent, configurable `phc_clk` and `hclk` frequencies.
- G30 requires the `tidelink_top_system` environment, which includes the full Wlink stack and address translator.
- G34 uses the existing `tidelink_ptp_chain` 3-chiplet topology.
- G35 requires the `tidelink_top_system` paired DUT with PHY crossover.

### 1.3 Out of Scope

- Fixing the design shortcomings themselves (items 23-27)
- Formal verification of credit invariants
- Gate-level or post-synthesis simulation
- Power-aware verification

## 2. Feature List

| ID | Feature | Priority | Gap | Description |
|----|---------|----------|-----|-------------|
| VG1 | Returner AHB error injection | P0 | G28 | Force `hresp=1` on returner master, verify `master_error` flag |
| VG2 | Error detection via STATUS poll | P0 | G28 | Software reads STATUS, detects MASTER_ERROR bit |
| VG3 | FLUSH after master_error | P0 | G28 | FLUSH clears FIFO state, pointers reset, credits restore |
| VG4 | Post-error re-init and resume | P0 | G28 | After FLUSH + doorbell, normal packet flow resumes |
| VG5 | Credit accounting after error recovery | P0 | G28 | No credit drift between pair after error + recovery cycle |
| VG6 | CDC async ratio 0.5x phc:hclk | P1 | G29 | phc_clk = 0.5x hclk, PTP exchange completes |
| VG7 | CDC async ratio 0.7x phc:hclk | P1 | G29 | phc_clk = 0.7x hclk, PTP exchange completes |
| VG8 | CDC async ratio 1.3x phc:hclk | P1 | G29 | phc_clk = 1.3x hclk, PTP exchange completes |
| VG9 | CDC async ratio 2.0x phc:hclk | P1 | G29 | phc_clk = 2.0x hclk, PTP exchange completes |
| VG10 | CDC handshake back-to-back | P1 | G29 | Rapid hw_capture pulses at various ratios, no data loss |
| VG11 | CDC free-running time read under async | P1 | G29 | Path 2 handshake delivers consistent time at all ratios |
| VG12 | Addr translator single rule + data flow | P1 | G30 | Configure 1 rule, AHB sub write arrives at AHB mng with translated address |
| VG13 | Addr translator multi-rule under traffic | P1 | G30 | Multiple rules active during concurrent TideLink FIFO traffic |
| VG14 | Addr translator reconfigure mid-stream | P2 | G30 | Change rules while AHB sub traffic flowing, verify transition |
| VG15 | Addr translator disable passthrough | P1 | G30 | Global enable off, addresses pass through untranslated |
| VG16 | Pair credit consume beyond available | P1 | G31 | Write 0x02C more than pair_credit_counter value, observe wrap/saturate |
| VG17 | Pair credit counter recovery | P1 | G31 | After underflow, verify if FLUSH + re-init restores correct state |
| VG18 | Partial write abandon (3 of 10 words) | P1 | G32 | Write header + 3 words of 10-word packet, then stop |
| VG19 | FLUSH after partial write | P1 | G32 | FLUSH clears partial state, subsequent packet works |
| VG20 | New packet after partial write (no FLUSH) | P1 | G32 | Characterise failure: does new packet corrupt or succeed? |
| VG21 | Reset after partial write | P1 | G32 | Assert reset mid-write, verify clean recovery |
| VG22 | Throughput: packets/cycle single direction | P2 | G33 | Measure max sustained A->B packet rate at various sizes |
| VG23 | Throughput: bidirectional | P2 | G33 | Measure max sustained A<->B rate with concurrent traffic |
| VG24 | Latency: TX write to RX committed IRQ | P2 | G33 | Cycle-accurate measurement, single direction, idle bus |
| VG25 | Latency: credit return round-trip | P2 | G33 | Cycle count from read_complete to pair credit increment |
| VG26 | Throughput regression threshold | P2 | G33 | Assert minimum throughput (fail if below baseline) |
| VG27 | PTP lock gate blocks downstream | P0 | G34 | B2 HW sync does not fire until B1 servo_locked=1 |
| VG28 | PTP cascaded convergence A->B->C | P0 | G34 | Both hops achieve servo lock, C tracks A's time |
| VG29 | PTP lock propagation timing | P1 | G34 | Measure cycles from B1 lock to B2 first SYNC |
| VG30 | PTP chain step recovery | P1 | G34 | Phase step on A propagates through B to C |
| VG31 | PTP chain under FIFO traffic | P2 | G34 | Background mailbox packets do not disrupt PTP chain |
| VG32 | Unilateral reset during traffic | P0 | G35 | Reset side A while B has in-flight packets |
| VG33 | Bilateral simultaneous reset | P1 | G35 | Both sides reset at same cycle, verify clean recovery |
| VG34 | Staggered reset with drain | P1 | G35 | Side A drains TX, sends FLUSH, resets; B recovers |
| VG35 | Doorbell reset notification | P0 | G35 | Resetting side's doorbell reaches pair, pair re-inits |
| VG36 | Post-reset credit consistency | P0 | G35 | After coordinated reset, credits on both sides are consistent |

## 3. Test Plan

### 3.1 G28 — Error Recovery Path (UVM `tidelink_system`)

These tests require a new `ahb_rx_error_responder` component that can be configured to inject `hresp=1` on the returner's AHB master port after a programmable number of OKAY responses.

| Test | Features | Description |
|------|----------|-------------|
| test_returner_error_detection | VG1, VG2 | Send packet A->B, read on B (triggers credit return), inject hresp=1 on A's returner master response. Verify STATUS.MASTER_ERROR set on A. |
| test_error_flush_recovery | VG1, VG2, VG3, VG4, VG5 | Full cycle: send packet, inject returner error, detect via STATUS, FLUSH both sides, re-init with doorbell, send another packet, verify data integrity and credit balance matches. |
| test_error_credit_drift | VG1, VG5 | Send 10 packets, inject error on 5th credit return, FLUSH and recover, send 10 more packets. At end, verify `credit_count_a + credit_count_b == 2 * MAX_CREDITS` (no global credit leak). |

**Infrastructure needed:**
- `ahb_rx_error_responder.sv`: Configurable AHB slave that returns `hresp=1` after N OKAY responses. Extends existing `ahb_rx_responder.sv`.
- Testbench modification: Wire error responder to A's returner AHB master port instead of the default always-OKAY responder.
- Scoreboard extension: `expect_error` mode that tolerates in-flight packet loss during error injection window.

**Checkers:**
1. `STATUS.MASTER_ERROR == 1` after error injection
2. `STATUS.MASTER_ERROR == 0` after FLUSH
3. `CREDIT_COUNT == MAX_CREDITS` after FLUSH + doorbell on both sides
4. Post-recovery packet data matches (scoreboard compare)
5. No UVM_ERROR from scoreboard after recovery sequence

### 3.2 G29 — CDC Multi-Clock Ratio (cocotb `tidelink_ptp`)

These tests use a modified `tb_top.sv` (or parameterised clock generator) that drives `phc_clk` at a different frequency from `hclk`. The cocotb test controls the clock ratio via `cocotb.clock.Clock` with different periods.

| Test | Features | Description |
|------|----------|-------------|
| test_cdc_ratio_half | VG6, VG10, VG11 | phc_clk period = 2x hclk. Run PTP SYNC+DELAY_REQ exchange, verify timestamps captured correctly. Check free-running time readback is monotonic. |
| test_cdc_ratio_0p7 | VG7, VG10, VG11 | phc_clk period = 1.43x hclk (ratio 0.7). Same checks. |
| test_cdc_ratio_1p3 | VG8, VG10, VG11 | phc_clk period = 0.77x hclk (ratio 1.3). Same checks. |
| test_cdc_ratio_double | VG9, VG10, VG11 | phc_clk period = 0.5x hclk (ratio 2.0). Same checks. |
| test_cdc_rapid_captures | VG10 | At ratio 0.7, issue 10 back-to-back hw_capture pulses as fast as the handshake allows. Verify all 10 capture timestamps are distinct and monotonically increasing. No capture lost. |
| test_cdc_phase_step_async | VG6, VG8 | At ratio 0.5 and 1.3, issue a phase step command. Verify the PHC time jumps correctly on the phc_clk domain and the updated time propagates back to hclk domain. |

**Infrastructure needed:**
- Testbench modification: `tb_top.sv` must generate `phc_clk` from a separate `cocotb.clock.Clock` instance (not the same as `hclk`). Add a parameter or define to select independent clock generation.
- Ensure `BYPASS_CDC = 0` (CDC bridge active, not bypassed).
- Helper function: `verify_timestamp_monotonic(timestamps[])` — checks each timestamp > previous.

**Checkers:**
1. PTP exchange completes without timeout at all ratios
2. hw_capture timestamps are non-zero and distinct
3. Free-running time readback is monotonically increasing (no backwards jumps)
4. Phase step value appears correctly on phc_clk domain
5. No `X`/`Z` values on CDC bridge outputs at any ratio

### 3.3 G30 — Address Translator Integration (UVM `tidelink_top_system`)

These tests exercise the address translator through the full Wlink stack, verifying that translated addresses arrive correctly at the AHB manager output on the remote side.

| Test | Features | Description |
|------|----------|-------------|
| test_top_addr_translate_single | VG12, VG15 | Configure 1 translation rule on side A (e.g. 0x4000_xxxx -> 0x6000_xxxx). Write to A's `ahb_sub` at 0x4000_0000. Verify the write appears on B's `ahb_mng` at 0x6000_0000. |
| test_top_addr_translate_multi | VG13 | Configure 3 rules covering different address ranges. Interleave AHB sub writes to all 3 ranges with concurrent TideLink FIFO traffic. Verify all writes arrive at correct translated addresses on B's `ahb_mng`. |
| test_top_addr_translate_disable | VG15 | Configure rules, send a translated write (verify). Disable global enable. Send another write to the same address. Verify it arrives untranslated (passthrough). |
| test_top_addr_translate_reconfig | VG14 | Configure rule, start AHB sub traffic, mid-stream change the rule's destination. Verify writes before reconfiguration arrive at old address, writes after arrive at new address. |

**Infrastructure needed:**
- Address translator APB configuration sequence: writes to `ahb_adr` port to set up rules (base, mask, remap, enable).
- AHB manager monitor on B side: capture incoming write addresses and data for scoreboard comparison.
- Extend `tidelink_top_system_scoreboard` to track AHB passthrough addresses (not just TideLink FIFO data).

**Checkers:**
1. AHB manager write address == expected translated address
2. AHB manager write data == original AHB sub write data
3. No address translation applied when global enable is off
4. FIFO traffic unaffected by concurrent AHB passthrough (scoreboard data match)
5. No Wlink errors during mixed traffic (STATUS clean on both sides)

### 3.4 G31 — Pair Credit Counter Underflow (UVM `tidelink_system`)

| Test | Features | Description |
|------|----------|-------------|
| test_pair_credit_underflow | VG16 | Init both sides. Read PAIR_CREDIT_COUNTER on side A (expect MAX_CREDITS from doorbell). Write to PAIR_CREDIT_CONSUME N+1 times where N = PAIR_CREDIT_COUNTER value. Read back counter. Document whether it wraps (design bug) or saturates. |
| test_pair_credit_underflow_recovery | VG16, VG17 | Trigger underflow as above. FLUSH both sides. Re-init with doorbell. Verify PAIR_CREDIT_COUNTER returns to MAX_CREDITS on both sides. Send a packet to confirm normal operation. |

**Infrastructure needed:**
- Register access sequences for `PAIR_CREDIT_COUNTER` (0x028, RO) and `PAIR_CREDIT_CONSUME` (0x02C, WO).
- These registers are already accessible via the existing `write_cfg_reg`/`read_cfg_reg` helpers.

**Checkers:**
1. After over-consuming: `PAIR_CREDIT_COUNTER < 0` (unsigned wrap to large value) — document actual behaviour
2. After FLUSH + re-init: `PAIR_CREDIT_COUNTER == MAX_CREDITS`
3. Post-recovery packet flow succeeds (scoreboard compare)
4. No UVM_FATAL or hang during underflow (system remains responsive)

### 3.5 G32 — Partial Packet Abandon (UVM `tidelink_system`)

| Test | Features | Description |
|------|----------|-------------|
| test_partial_write_flush | VG18, VG19 | Write header (addr 0) with packet_word_length=10, then write 3 data words (addrs 4, 8, 12). Stop. Verify `write_complete` has NOT fired (packet_committed_irq absent). FLUSH. Re-init. Send a complete 4-word packet. Verify data integrity. |
| test_partial_write_no_flush | VG18, VG20 | Write header with length=10, then 3 data words. Stop. Immediately start a new 4-word packet (write header with length=4, then 4 data words). Document whether the new packet succeeds, corrupts, or hangs. |
| test_partial_write_reset | VG18, VG21 | Write header with length=10, then 3 data words. Assert reset. Wait for deassertion. Re-init both sides. Send a complete packet. Verify clean operation. Check CREDIT_COUNT == MAX_CREDITS after re-init. |

**Infrastructure needed:**
- New sequence `sys_partial_packet_sequence`: writes header + configurable number of data words (less than declared length), then returns without completing the packet.
- IRQ check helper: verify `packet_committed_irq` is NOT asserted within a timeout window.

**Checkers:**
1. `packet_committed_irq` does NOT fire after partial write
2. After FLUSH: `CREDIT_COUNT == MAX_CREDITS`, `PKT_WORD_LEN == 0`, `STATUS == 0`
3. Post-recovery packet arrives intact (scoreboard compare)
4. No hang during partial write (timeout watchdog catches infinite stalls)
5. Document: behaviour of new packet after partial (for characterisation, not pass/fail)

### 3.6 G33 — Throughput and Latency Characterisation (UVM `tidelink_system` + `tidelink_top_system`)

These are characterisation tests that measure and report performance metrics. They assert minimum thresholds to catch regressions.

| Test | Features | Environment | Description |
|------|----------|-------------|-------------|
| test_throughput_single_dir | VG22, VG26 | `tidelink_system` | Send 100 packets of size S (sweep S = 1, 4, 16, 64, 256 words). Measure total cycles. Report words/cycle. Assert > baseline. |
| test_throughput_bidir | VG23, VG26 | `tidelink_system` | Same as above but A->B and B->A concurrently. Report aggregate words/cycle. |
| test_latency_packet | VG24 | `tidelink_system` | Send single 4-word packet A->B on idle bus. Measure cycles from first TX AHB write to `packet_committed_irq` on B. Repeat 10 times, report min/max/mean. |
| test_latency_credit_return | VG25 | `tidelink_system` | After B reads packet, measure cycles from `read_complete` (B side) to `released_credits_irq` on A (or credit count increment). Report min/max/mean over 10 exchanges. |
| test_throughput_full_stack | VG22, VG26 | `tidelink_top_system` | Same as `test_throughput_single_dir` but through full Wlink + PHY stack. Reports will be slower; establishes full-stack baseline. |

**Infrastructure needed:**
- Cycle counter utility: `perf_counter` class with `start()`, `stop()`, `elapsed()` methods, wrapping `$time` or clock edge counting.
- Results reporting: Print a formatted table at end of test with metrics. Optionally write to a CSV file via `$fwrite`.
- Baseline thresholds: Initially set permissively (e.g. > 0.1 words/cycle for system, > 0.01 for full stack). Tighten after first characterisation run.

**Checkers:**
1. Throughput > minimum baseline (assert, not just report)
2. Latency < maximum ceiling (assert)
3. No data corruption during throughput tests (scoreboard compare on all packets)
4. No credit drift after sustained throughput (final credit check)
5. Metrics printed in UVM_LOW report for CI extraction

### 3.7 G34 — PTP Multi-Hop Chain (UVM `tidelink_ptp_chain`)

The `tidelink_ptp_chain` environment already has the 3-chiplet topology (A-GM, B-Sub/GM, C-Sub) with 4 `tidelink_top` instances and 3 PHCs. The existing tests (`test_chain_lock_propagation`, `test_chain_convergence`, etc.) use force-based shortcuts. These new tests exercise the actual PTP protocol end-to-end.

| Test | Features | Description |
|------|----------|-------------|
| test_chain_gate_functional | VG27 | Enable HW sync on B_link2 (PHC_LOCK_GATE_EN=1). Verify no SYNC packets on link 2 while `b1_servo_locked=0`. Force `b1_servo_locked=1`. Verify SYNC packets begin on link 2 within `hw_sync_interval` cycles. |
| test_chain_convergence_e2e | VG28 | Full end-to-end: PHC_A free-running as GM. B_link1 syncs to A (servo computes offset, adjusts PHC_B). B_link2 gated until B1 locks. After B1 lock, B_link2 syncs C to B. Verify both hops have `servo_locked=1`. Check PHC_C tracks PHC_A within tolerance. |
| test_chain_lock_timing | VG29 | Measure cycle count from `b1_servo_locked` rising edge to first SYNC FC packet on link 2. Verify it is within `hw_sync_interval +/- tolerance`. |
| test_chain_step_propagation | VG30 | Converge chain. Inject +1s phase step on PHC_A. Verify PHC_B step-corrects within N exchanges. Then PHC_C step-corrects within M exchanges after PHC_B re-locks. |
| test_chain_fifo_background | VG31 | During chain convergence, concurrently run 50 mailbox packets on link 1 and link 2. Verify PTP still converges (possibly with more exchanges). Verify FIFO data integrity unaffected. |

**Infrastructure needed:**
- The existing `tidelink_ptp_chain` testbench and environment provide the topology.
- Servo lock detection: monitor `servo_locked` output from each `tidelink_top` instance.
- PHC time readback: APB reads of PHC nanoseconds/seconds registers for convergence checking.
- Convergence tolerance: configurable parameter (e.g. `CONVERGENCE_NS = 1000` for 1us).

**Checkers:**
1. No SYNC on link 2 while `phc_locked_i=0` on B_link2
2. SYNC on link 2 starts within `hw_sync_interval + 10` cycles of `phc_locked_i` rising
3. `servo_locked` asserts on both hops within `MAX_CONVERGENCE_EXCHANGES` (configurable)
4. `|PHC_C_time - PHC_A_time| < CONVERGENCE_NS` in steady state
5. Phase step recovery completes within `STEP_RECOVERY_EXCHANGES` on each hop
6. FIFO scoreboard reports zero mismatches during background traffic

### 3.8 G35 — Coordinated Chiplet Reset (UVM `tidelink_top_system`)

These tests exercise reset scenarios across the paired `tidelink_top` instances connected via Wlink PHY crossover.

| Test | Features | Description |
|------|----------|-------------|
| test_unilateral_reset_traffic | VG32, VG35, VG36 | Init system. Start continuous A->B traffic (10 packets). Mid-stream (after 5th packet), assert `hresetn` on side A for 20 cycles. Release. Verify: (a) B receives doorbell reset notification, (b) B's in-flight RX completes or is discarded cleanly, (c) after A re-inits and both doorbell, subsequent packets flow correctly, (d) no credit leak. |
| test_bilateral_simultaneous_reset | VG33, VG36 | Init system. Send 1 packet each direction. Assert `hresetn` on BOTH sides simultaneously. Release. Re-init both. Send 1 packet each direction. Verify data integrity and credit consistency. |
| test_staggered_drain_reset | VG34, VG36 | Init system. Send 5 packets A->B. Side A: wait for `tx_router_idle` (link drained), send FLUSH, assert reset. Side B: detect doorbell, FLUSH, re-init. Side A: release reset, re-init, doorbell. Verify clean operation with next packet. |
| test_reset_doorbell_arrival | VG35 | Init system. Assert `hresetn` on A. Verify B's `DOORBELL_RESP_ACC` increments (doorbell reset notification arrived via FC sideband). Verify B's `released_credits_irq` or `doorbell_irq` fires. |
| test_post_reset_credit_audit | VG36 | After each reset test above, read `CREDIT_COUNT` and `PAIR_CREDIT_COUNTER` on both sides. Verify: `A.CREDIT_COUNT + B.PAIR_CREDIT_COUNTER == MAX_CREDITS` and vice versa (symmetric invariant holds). |

**Infrastructure needed:**
- Reset control: hierarchical force/release of `hresetn` per side (already demonstrated in `test_reset_recovery`).
- Wlink re-init sequence: after reset, re-run Wlink init + link training + role lock (from `top_sys_wlink_init_sequence`).
- Doorbell monitor: watch for `doorbell_irq` or `DOORBELL_RESP_ACC` increment on the non-resetting side.
- Credit audit task: reusable helper that reads all 4 credit-related registers on both sides and asserts the symmetric invariant.

**Checkers:**
1. Non-resetting side does not hang (no AHB bus timeout)
2. Doorbell reset notification arrives at pair within `phy_transit_wait` cycles
3. After re-init: `CREDIT_COUNT == MAX_CREDITS` on both sides
4. After re-init: `STATUS == 0` on both sides (no sticky errors)
5. Post-reset packet data matches (scoreboard compare)
6. Credit symmetric invariant holds: `A.credits + B.pair_credits == MAX_CREDITS`

## 4. Coverage Goals

### 4.1 Functional Coverage (New Covergroups)

| Covergroup | Bins | Target | Gap |
|------------|------|--------|-----|
| cg_returner_error | {error_injected, error_detected, error_recovered} | 100% | G28 |
| cg_error_recovery_sequence | {detect_flush_reinit, detect_flush_packet} | 100% | G28 |
| cg_cdc_clock_ratio | {0.5x, 0.7x, 1.0x, 1.3x, 2.0x} | 100% | G29 |
| cg_cdc_capture_rate | {single, back_to_back_2, burst_5, burst_10} | 100% | G29 |
| cg_addr_translate_rules | {0_rules, 1_rule, 2_rules, max_rules} | 100% | G30 |
| cg_addr_translate_concurrent | {fifo_only, passthrough_only, mixed} | 100% | G30 |
| cg_pair_credit_boundary | {normal_consume, exact_zero, underflow_attempt} | 100% | G31 |
| cg_partial_packet | {abandon_1_of_N, abandon_half, abandon_N_minus_1} | 100% | G32 |
| cg_partial_recovery | {flush, reset, new_packet_no_flush} | 100% | G32 |
| cg_packet_size_perf | {1w, 4w, 16w, 64w, 256w} | 100% | G33 |
| cg_ptp_chain_state | {a_locked, b_locked, both_locked, step_recovery} | 100% | G34 |
| cg_ptp_lock_gate | {blocked, gate_rising, force_en, lock_drop} | 100% | G34 |
| cg_reset_scenario | {unilateral_a, unilateral_b, bilateral, staggered} | 100% | G35 |
| cg_reset_traffic_state | {idle, mid_packet, mid_credit_return, mid_doorbell} | 100% | G35 |

### 4.2 Code Coverage Targets

| Metric | G28 | G29 | G30 | G31 | G32 | G33 | G34 | G35 |
|--------|-----|-----|-----|-----|-----|-----|-----|-----|
| Line | >95% | >90% | >90% | >95% | >95% | >95% | >90% | >90% |
| Condition | >90% | >85% | >85% | >90% | >90% | >90% | >85% | >85% |
| FSM | 100% | 100% | - | - | 100% | - | 100% | 100% |
| Toggle | >85% | >80% | >80% | >85% | >85% | >85% | >80% | >80% |

### 4.3 Key Coverage Holes to Close

- **G28**: `returner.sv` FSM in `ST_DATA_PHASE` with `hresp=1` (never exercised before)
- **G28**: `master_error` flag set→cleared→set cycle
- **G29**: `tidelink_phc_cdc.sv` all 6 CDC paths exercised with async clocks
- **G29**: `cap_trig_sync_p` shift register under different fill rates
- **G30**: Address translator CAM match/miss paths under Wlink backpressure
- **G31**: `pair_credit_counter` decrement from 0 (wrap detection)
- **G32**: `fifo_ctrl.sv` state where `packet_word_length != 0` but `write_ptr` has not advanced to final address
- **G34**: `hw_sync_gate_rising` edge detection in `tidelink_ptp.sv`
- **G35**: `returner.sv` channel 2 (reset doorbell) firing while channel 0 (credits) pending

## 5. Scoreboard Extensions

### 5.1 Error-Tolerant Mode (G28)

Extend `tidelink_system_scoreboard` with an `expect_error` flag:
- When set, the scoreboard allows in-flight packet data mismatches (packets may be lost during error window)
- Track number of packets lost during error window
- After `expect_error` is cleared, resume strict comparison
- At end of test, report: `packets_lost_during_error = N` (informational, not an error)

### 5.2 Performance Metrics Collector (G33)

New `tidelink_perf_collector` component:
- Subscribes to TX write and RX read analysis ports
- Records timestamps (`$time`) of first TX write and last RX read per packet
- Computes per-packet latency
- Computes aggregate throughput (total words / total cycles)
- Prints summary table in `report_phase`
- Asserts minimum thresholds via `UVM_ERROR` if below baseline

### 5.3 Credit Audit (G28, G31, G35)

New `tidelink_credit_auditor` task (callable from any test):
```
task credit_audit(side_t side_a, side_t side_b);
  // Read all 4 credit registers on both sides
  // Assert: a.credit_count + b.pair_credit_counter == MAX_CREDITS
  // Assert: b.credit_count + a.pair_credit_counter == MAX_CREDITS
  // Report all values at UVM_LOW
endtask
```

## 6. Implementation Priority

### Phase 1 — High Value, Low Risk (P0 features)

| Order | Tests | Gap | Environment | Rationale |
|-------|-------|-----|-------------|-----------|
| 1 | test_returner_error_detection, test_error_flush_recovery | G28 | tidelink_system | Most impactful untested failure mode |
| 2 | test_unilateral_reset_traffic, test_reset_doorbell_arrival | G35 | tidelink_top_system | Critical for deployment |
| 3 | test_chain_gate_functional | G34 | tidelink_ptp_chain | Validates existing but untested RTL feature |

### Phase 2 — Moderate Value, Moderate Effort (P1 features)

| Order | Tests | Gap | Environment | Rationale |
|-------|-------|-----|-------------|-----------|
| 4 | test_cdc_ratio_* (4 tests) | G29 | cocotb tidelink_ptp | New clock gen infra needed but tests are simple |
| 5 | test_partial_write_flush, test_partial_write_reset | G32 | tidelink_system | New sequence needed |
| 6 | test_top_addr_translate_single, _multi | G30 | tidelink_top_system | Uses existing infra, extends scoreboard |
| 7 | test_pair_credit_underflow, _recovery | G31 | tidelink_system | Straightforward register test |
| 8 | test_error_credit_drift | G28 | tidelink_system | Builds on phase 1 error infra |
| 9 | test_bilateral_simultaneous_reset, test_staggered_drain_reset | G35 | tidelink_top_system | Builds on phase 1 reset infra |
| 10 | test_chain_convergence_e2e, test_chain_step_propagation | G34 | tidelink_ptp_chain | Long simulation, but high value |

### Phase 3 — Characterisation and Stress (P2 features)

| Order | Tests | Gap | Environment | Rationale |
|-------|-------|-----|-------------|-----------|
| 11 | test_throughput_*, test_latency_* | G33 | tidelink_system | New perf_collector infra |
| 12 | test_throughput_full_stack | G33 | tidelink_top_system | Slowest simulation |
| 13 | test_partial_write_no_flush | G32 | tidelink_system | Characterisation only |
| 14 | test_chain_fifo_background | G34 | tidelink_ptp_chain | Stress test, long sim |
| 15 | test_cdc_rapid_captures, test_cdc_phase_step_async | G29 | cocotb tidelink_ptp | Edge case CDC stress |
| 16 | test_top_addr_translate_reconfig | G30 | tidelink_top_system | Low priority corner case |

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| AHB error responder breaks existing tests | Regression failure | Use factory override only in error tests; default responder unchanged |
| Async phc_clk causes simulation instability | False failures | Start with small ratio deltas (0.7, 1.3) before extremes (0.5, 2.0) |
| tidelink_ptp_chain convergence too slow for CI | CI timeout | Set generous timeout (10M cycles); mark as nightly-only if > 5min wall time |
| Reset during Wlink traffic leaves PHY in bad state | Hang | Add PHY-level watchdog in testbench; escalate to `UVM_FATAL` on link-down timeout |
| Partial packet write hangs AHB bus | Test hang | Timeout watchdog (already in base_test); characterise and document if hang occurs |
| Performance baselines are environment-dependent | False pass/fail | Set conservative initial baselines; tighten after 3+ clean CI runs |
| Address translator APB config format changes | Test breakage | Read `tl_addr_trans_cam` register map from RTL (parameterised offsets) |
| Credit audit invariant fails due to in-flight sideband | False failure | Add settling wait (50-100 cycles) before credit audit reads |

## 8. Additional Functional Gap Tests (cocotb `tidelink_system`)

Four additional tests were identified as high-value functional gaps not covered by the G28-G35 verification gaps. These are implemented in `cocotb/tidelink_system/test_verification_gaps.py`.

| Test | Feature | Description |
|------|---------|-------------|
| test_irq_packet_committed | IRQ-driven receive | Send packet A->B, wait for `b_packet_committed_irq` to assert (no polling), read packet, verify IRQ deasserts after read of address 0 |
| test_irq_released_credits | IRQ credit release | Send+read packet, wait for `a_released_credits_irq`, read RELEASED_ACC (clears IRQ), verify accumulator value matches expected credits |
| test_credit_threshold_sweep | Threshold edge cases | Test thresholds 0 (immediate), 1 (per-word), 20 (batched), MAX_CREDITS/2 (large); verify credit return for each |
| test_accumulator_race | Race characterisation | Rapid read of accumulator while sideband writes are in-flight; documents whether read gets old, new, or zero value |

### Coverage Goals

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_irq_lifecycle | {assert, read_clear, deassert} | 100% per IRQ type |
| cg_threshold_values | {0, 1, 20, MAX/2} | 100% |

## 9. Relationship to Existing Plans

This plan extends but does not replace the existing verification plans:
- `tidelink_system_vplan.md`: G28, G31, G32, G33 tests join the `tidelink_system` environment
- `tidelink_top_system_vplan.md`: G30, G35 tests join the `tidelink_top_system` environment
- `tidelink_ptp_chain_vplan.md`: G34 tests join the `tidelink_ptp_chain` environment
- G29 tests are new cocotb-only additions to `cocotb/tidelink_phc_cdc/`
- Section 8 tests are cocotb additions to `cocotb/tidelink_system/`

Existing tests are unaffected. New tests use factory overrides and optional components.

## 10. Test Run Results

| Test | Environment | Status | Key Finding |
|------|-------------|--------|-------------|
| G29: CDC multi-clock (15 tests) | cocotb `tidelink_phc_cdc` | **15/15 PASS** | All 6 CDC paths verified at 4 ratios |
| G31: Pair credit underflow | UVM `tidelink_system` | **PASS** | Counter saturates at 0 (safe); Shortcoming #7 less severe than documented |
| G32: Partial packet abandon | UVM `tidelink_system` | Pending | — |
| G28: Error recovery | UVM `tidelink_system` | Pending | — |
| G33: Throughput/latency | UVM `tidelink_system` | Pending | — |
| G35: Coordinated reset | UVM `tidelink_top_system` | Pending (TB needs same port fix) | — |
| G30: Addr translator | UVM `tidelink_top_system` | Pending (TB needs same port fix) | — |
| G34: PTP chain gate | UVM `tidelink_ptp_chain` | Pending | — |

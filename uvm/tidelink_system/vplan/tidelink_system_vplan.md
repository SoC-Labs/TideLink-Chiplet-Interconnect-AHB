# TideLink System Verification Plan

## 1. Overview

This document describes the verification plan for the TideLink paired-system testbench, which verifies end-to-end chiplet communication using two FC adapter + FIFO subsystems connected back-to-back via FC crossover.

### 1.1 Scope

The DUT consists of two identical chiplet subsystems (A and B), each containing:
- `tidelink_fc_adapter`: AHB-to-FC bridge with TX aperture, returner interception, and RX routing
- `tidelink_fifo_ahb`: RX FIFO with AHB data slave, AHB config slave (via AHB-to-APB bridge), and returner AHB master
- FIFO and config port mux logic (FC adapter RX has priority over CPU port)

The FC crossover connects A's TX to B's RX and B's TX to A's RX.

### 1.2 Out of Scope

- XHB500 AHB-to-AXI/AXI-to-AHB bridges (external IP)
- Wlink chiplet controller (external IP)
- Physical layer (SerDes, CRC/ECC)
- Address translator

## 2. Feature List

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| F1 | Single packet A->B | P0 | Write packet to A TX, verify arrival in B FIFO |
| F2 | Single packet B->A | P0 | Write packet to B TX, verify arrival in A FIFO |
| F3 | Bidirectional traffic | P0 | Simultaneous A->B and B->A without cross-contamination |
| F4 | Data integrity | P0 | TX write data matches RX read data for all packet sizes |
| F5 | Credit consumption | P0 | Credits decrease on B when A writes to B's FIFO |
| F6 | Credit release | P0 | Credits return to B after reading from B's FIFO (via FC sideband) |
| F7 | Credit recovery | P0 | Full credit count restores after write+read cycle |
| F8 | Credit exhaustion | P1 | System handles zero-credit condition gracefully |
| F9 | Release threshold | P1 | Batched credit release when threshold is crossed |
| F10 | FC TX arbitration | P0 | Returner sideband wins over TX aperture |
| F11 | FC RX routing | P0 | FIFO_DATA routed to FIFO, SIDEBAND routed to config |
| F12 | FIFO mux arbitration | P0 | FC adapter RX has priority over CPU on FIFO port |
| F13 | Config mux arbitration | P0 | FC adapter RX has priority over CPU on config port |
| F14 | Packet committed IRQ | P1 | packet_committed_irq fires after complete packet write |
| F15 | Doorbell mechanism | P1 | Doorbell register write propagates via FC sideband |
| F16 | Reset recovery | P1 | Clean state after mid-transfer reset |
| F17 | Back-to-back packets | P1 | No data loss with rapid consecutive packets |
| F18 | Max packet size | P1 | FIFO handles maximum-length packets |
| F19 | Variable packet sizes | P2 | Mix of 1-word, small, medium, large packets |
| F20 | Sustained operation | P2 | No credit drift or error accumulation over 1000+ packets |
| F21 | Error flag detection | P2 | STATUS.OVERRUN, UNDERRUN, MASTER_ERROR flags |

## 3. Test Plan

| Test | Features | Description |
|------|----------|-------------|
| test_single_packet | F1, F4, F5, F6, F7 | Single 4-word packet A->B, full credit lifecycle |
| test_bidirectional | F1, F2, F3, F4, F10 | Simultaneous A->B and B->A, verify no cross-contamination |
| test_back_to_back | F4, F7, F12, F17 | 10 rapid packets with minimal gaps, stress pipeline |
| test_max_packet | F4, F5, F18 | 256-word packet fills significant FIFO space |
| test_credit_exhaustion | F5, F6, F7, F8 | 20 packets without reading, then drain and verify recovery |
| test_credit_threshold | F9 | Non-zero threshold, verify batched release behavior |
| test_sideband_stress | F10, F11, F13, F15 | Doorbell + data traffic concurrently, stress TX arbitration |
| test_interleaved_types | F4, F11, F19 | Mix RD_REQ/WR_REQ/RD_RSP/WR_RSP descriptors |
| test_error_injection | F21 | Empty FIFO read, write to read-only registers |
| test_reset_recovery | F16 | Assert reset mid-transfer, re-init, verify clean operation |
| test_long_running | F4, F7, F20 | 500 packets per direction (1000 total), check for drift |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_packet_size | single(1), small(2-4), medium(5-16), large(17-255), very_large(256+) | 100% |
| cg_bidirectional | both_active, a_only, b_only, neither | 100% |
| cg_burst_pattern | single(1), back_to_back(2-5), sustained(6+) | 100% |
| cg_traffic_volume | low(1-10), medium(11-100), high(101-1000), stress(1001+) | 80% |

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >95% |
| Condition coverage | >90% |
| FSM coverage | 100% (all states and transitions) |
| Toggle coverage | >85% |
| Branch coverage | >90% |

### 4.3 Key Coverage Holes to Close

- FC adapter RX FSM: all state transitions exercised (IDLE->ADDR->DATA->IDLE)
- TX arbitration: both tx_fc_valid and rtn_fc_valid active simultaneously
- FIFO mux: fc_rx_fifo_active asserted while CPU read in progress
- Config mux: fc_rx_cfg_active asserted while CPU config access in progress
- Credit counter wrap-around (requires very long test or small FIFO)

## 5. Scoreboard Strategy

The system scoreboard tracks two independent data paths:

1. **A->B path**: Words written to A's TX aperture are queued; words read from B's FIFO are compared against the queue. Mismatches flag `UVM_ERROR`.

2. **B->A path**: Words written to B's TX aperture are queued; words read from A's FIFO are compared against the queue. Mismatches flag `UVM_ERROR`.

3. **Lost packet detection**: At end of simulation, non-empty TX queues indicate packets that were sent but never received.

4. **Credit accounting**: Tests explicitly read CREDIT_COUNT registers and compare against expected values based on packets sent and received.

## 6. Risks and Assumptions

### 6.1 Assumptions

- The CMSDK AHB-to-APB bridge and AHB-to-SRAM components are pre-verified
- The FC crossover has zero latency (direct wire connection)
- Both sides share a single clock domain (no clock domain crossing)
- SVT AHB VIP correctly implements AHB-Lite protocol

### 6.2 Known Risks

| Risk | Mitigation |
|------|------------|
| FIFO mux race: FC RX write and CPU read collide on same cycle | test_sideband_stress creates this scenario; mux gives FC priority |
| Credit release timing: sideband may arrive before/after expected | Tests use generous wait periods; future work could add exact timing checks |
| TX arbitration starvation: returner could starve TX aperture | test_sideband_stress monitors for TX timeout; returner writes are infrequent |
| Reset timing: metastability on async reset | Design uses synchronized reset; test_reset_recovery verifies clean recovery |
| FC crossover deadlock: A and B both trying to send simultaneously | test_bidirectional exercises this; FC accept/ready handshake prevents deadlock |

### 6.3 Future Enhancements

- Randomized packet sizes and timing with constrained random sequences
- Protocol checker for FC interface (valid/ready handshake rules)
- Formal verification of credit invariant: credits_consumed + credits_available = MAX_CREDITS
- Latency measurement: cycle count from TX write to RX FIFO commit
- Power-aware verification (clock gating during idle periods)

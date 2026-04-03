# TideLink Top System Verification Plan

## 1. Overview

This document describes the verification plan for the full `tidelink_top` paired-system testbench, which verifies end-to-end chiplet communication using two complete `tidelink_top` modules connected back-to-back via PHY pad crossover.

### 1.1 Scope

Each `tidelink_top` DUT instance contains the full chiplet communication stack:
- `tidelink_fifo_ahb`: RX FIFO with AHB data slave, config slave (via AHB-to-APB bridge), and returner AHB master
- `tidelink_fc_adapter`: AHB-to-FC bridge with TX aperture, returner interception, and RX routing
- FIFO and config port mux logic (FC adapter RX has priority over CPU port)
- `tidelink_addr_translator`: APB-configurable address remapping
- `xhb500_ahb_to_axi_bridge_chiplet_slv`: AHB→AXI bridge for subordinate path
- `xhb500_axi_to_ahb_bridge_chiplet_mst`: AXI→AHB bridge for manager path
- `Wlink` chiplet controller: link layer, flow control, CRC, GPIO PHY

The PHY pad crossover connects A's TX to B's RX and B's TX to A's RX.

### 1.2 Out of Scope

- SerDes PHY electrical behavior (using GPIO behavioural model)
- PLL/clock generation internals
- Scan/DFT chains
- Power management (Q-channel)

## 2. Feature List

| ID | Feature | Priority | Description |
|----|---------|----------|-------------|
| F1 | TideLink single packet A->B | P0 | Write packet to A TX, verify arrival in B FIFO via full Wlink path |
| F2 | TideLink single packet B->A | P0 | Write packet to B TX, verify arrival in A FIFO |
| F3 | Bidirectional TideLink traffic | P0 | Simultaneous A->B and B->A without cross-contamination |
| F4 | Data integrity through Wlink | P0 | TX write data matches RX read data after Wlink serialization |
| F5 | Credit consumption via FC | P0 | Credits decrease on receiver when sender writes via FC path |
| F6 | Credit release via FC sideband | P0 | Credits return after reading, via FC sideband through Wlink |
| F7 | Credit recovery | P0 | Full credit count restores after write+read cycle |
| F8 | Credit exhaustion | P1 | System handles zero-credit condition gracefully |
| F9 | Wlink initialization | P0 | APB-based Wlink controller init, link training, link-up |
| F10 | AHB passthrough A->B | P0 | AHB sub -> XHB500 -> Wlink -> XHB500 -> AHB mng path |
| F11 | AHB passthrough B->A | P0 | Reverse direction AHB passthrough |
| F12 | FC TX arbitration | P0 | Returner sideband wins over TX aperture in FC adapter |
| F13 | FC RX routing | P0 | FIFO_DATA routed to FIFO, SIDEBAND routed to config |
| F14 | FIFO mux arbitration | P0 | FC adapter RX has priority over CPU on FIFO port |
| F15 | Config mux arbitration | P0 | FC adapter RX has priority over CPU on config port |
| F16 | Back-to-back packets | P1 | No data loss with rapid consecutive packets through Wlink |
| F17 | Max packet size | P1 | FIFO handles maximum-length packets through full stack |
| F18 | Reset recovery | P1 | Clean state after flush/re-init cycle |
| F19 | Sustained operation | P2 | No credit drift over 100+ packets through Wlink |
| F20 | Mixed traffic | P1 | Concurrent TideLink FIFO + AHB passthrough traffic |
| F21 | PHY pad crossover integrity | P0 | No data corruption in serialization/deserialization |
| F22 | Wlink FC node | P0 | FC valid/ready/data handshake functions correctly |
| F23 | General bus crossover | P2 | gb_in/gb_out forwarding between sides |
| F24 | Interrupt propagation | P1 | IRQs fire correctly (credits, doorbell, packet committed, wlink) |

## 3. Test Plan

| Test | Features | Description |
|------|----------|-------------|
| test_top_single_packet | F1, F4, F5, F6, F7, F9, F21, F22 | Single 4-word packet A->B through full Wlink stack |
| test_top_bidirectional | F1, F2, F3, F4, F12, F21 | Simultaneous A->B and B->A packets |
| test_top_back_to_back | F4, F7, F14, F16, F21 | 10 rapid packets through Wlink |
| test_top_max_packet | F4, F5, F17, F21 | 256-word packet through full stack |
| test_top_credit_exhaustion | F5, F6, F7, F8 | 20 packets without reading, then drain |
| test_top_ahb_passthrough | F9, F10, F11, F21 | AHB write/read via XHB500 + Wlink path |
| test_top_reset_recovery | F18 | Flush and re-init, verify clean operation |
| test_top_long_running | F4, F7, F19, F21 | 100+ packets per direction, check for drift |
| test_top_mixed_traffic | F1, F2, F10, F20 | Concurrent TideLink FIFO + AHB passthrough |

## 4. Coverage Goals

### 4.1 Functional Coverage

| Covergroup | Bins | Target |
|------------|------|--------|
| cg_packet_size | single(1), small(2-4), medium(5-16), large(17-255), very_large(256+) | 100% |
| cg_bidirectional | both_active, a_only, b_only, neither | 100% |
| cg_traffic_volume | low(1-10), medium(11-100), high(101-1000), stress(1001+) | 80% |

### 4.2 Code Coverage

| Metric | Target |
|--------|--------|
| Line coverage | >90% |
| Condition coverage | >85% |
| FSM coverage | 100% (all states and transitions) |
| Toggle coverage | >80% |
| Branch coverage | >85% |

### 4.3 Key Coverage Holes to Close

- Wlink FC node: all valid/ready/accept handshake scenarios
- FC adapter TX arbitration: both tx_fc_valid and rtn_fc_valid active simultaneously
- AHB passthrough: concurrent with TideLink FIFO traffic
- PHY SerDes: all lanes active during transmission
- FIFO/config mux: FC priority assertion while CPU access in progress
- XHB500 bridge: back-pressure scenarios (AXI WREADY/ARREADY deasserted)

## 5. Scoreboard Strategy

The system scoreboard tracks three independent data paths:

1. **A->B TideLink path**: Words written to A's TX aperture queued; words read from B's FIFO compared.

2. **B->A TideLink path**: Words written to B's TX aperture queued; words read from A's FIFO compared.

3. **AHB passthrough**: Writes on A's SUB port tracked; responses on B's MNG port monitored (and vice versa).

4. **Lost packet detection**: Non-empty TX queues at end of simulation.

5. **Credit accounting**: Explicit register reads verify credit counts.

## 6. Risks and Assumptions

### 6.1 Assumptions

- CMSDK AHB-to-APB and AHB-to-SRAM components are pre-verified
- XHB500 AHB-AXI bridges are pre-verified (Arm IP)
- Wlink chiplet controller is pre-verified (Chisel-generated)
- GPIO PHY model provides immediate link-up after enable
- Both sides share a single clock domain
- SVT AHB VIP correctly implements AHB-Lite protocol

### 6.2 Known Risks

| Risk | Mitigation |
|------|------------|
| Wlink link training timing | Generous wait after enable; configurable timeout |
| PHY serialization latency | Longer wait periods than sub-component system test |
| XHB500 AXI protocol compliance | Disable protocol checks if needed; XHB500 is pre-verified |
| Mixed AXI/FC traffic contention in Wlink | test_top_mixed_traffic exercises this scenario |
| Credit release timing through full stack | Tests use generous waits; future: exact timing checks |

### 6.3 Future Enhancements

- SerDes PHY model with realistic latency and bit errors
- Wlink CRC error injection and recovery testing
- Clock domain crossing verification (independent clocks per side)
- Address translator configuration and remapping tests
- Power management Q-channel handshake testing
- Formal verification of credit invariant through Wlink path

# TideLink Verification Plan

This document defines the comprehensive verification plan for the TideLink
credit-based FIFO interface. It covers unit-level, integration-level, and
system-level tests required to fully verify the design.

## Architecture Overview

TideLink is a credit-based FIFO interface for two cooperating SoCs. Each
instance contains:
- **AHB Slave FIFO** (`tidelink_fifo_mem` + `tidelink_fifo_ctrl`): circular
  buffer with pointer management, packet metadata capture, and credit counting.
- **AHB Master Returner** (`tidelink_returner`): 3-channel priority
  arbiter that sends credit updates to the paired TideLink.
- **APB Register Interface** (`tidelink_apb_regs`): configuration, status,
  doorbell, credit accumulators, pair credit counter, and reset detection.
- **AHB Wrapper** (`tidelink_fifo_ahb`): wraps `tidelink_fifo` with a `cmsdk_ahb_to_apb`
  bridge so configuration registers are accessible via a second AHB slave port.

## Test Suites

### 1. tidelink_fifo (FIFO Control Unit Tests) — 33 tests

Tests target `tidelink_fifo_mem` which wraps `tidelink_fifo_ctrl` with
`cmsdk_ahb_to_sram` and `cmsdk_fpga_sram`.

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| AHB-01 | Reset defaults                        | hreadyout=1, hresp=0, credit_count=MAX after reset                          | Existing |
| AHB-02 | Single write/read                     | Write a word, read it back, verify data integrity                           | Existing |
| AHB-03 | Multiple addresses                    | Write to multiple addresses, read all back                                  | Existing |
| AHB-04 | Overwrite                             | Write, overwrite, verify latest value                                       | Existing |
| AHB-05 | Sequential burst                      | 16-word sequential burst write and readback                                 | Existing |
| AHB-06 | Pointers zero after reset             | write_ptr and read_ptr both 0 after reset                                   | Existing |
| AHB-07 | Write length capture                  | Writing to addr 0 captures hwdata as packet_word_length                     | Existing |
| AHB-08 | Write target addr calculation         | write_target_addr = packet_word_length * 4                                  | Existing |
| AHB-09 | Write complete fires                  | write_complete fires on last data beat                                      | Existing |
| AHB-10 | Single packet burst                   | 10-beat packet, write_complete fires on last beat                           | Existing |
| AHB-11 | Two packets no overwrite              | Two packets occupy separate SRAM regions                                    | Existing |
| AHB-12 | Three packets sequential              | Three variable-size packets stored without overlap                          | Existing |
| AHB-13 | Credit count tracks writes             | credit_count decrements by total_words on each write                         | Existing |
| AHB-14 | Read data integrity across packets    | Two packets write/read, exact data match (ptr_offset pipeline regression)   | Existing |
| AHB-15 | Read ptr_offset pipeline bug          | Targeted back-to-back read with no idle cycles                              | Existing |
| AHB-16 | Read interrupt and packet length      | read_complete fires, packet_word_length_out correct at that moment          | Existing |
| AHB-17 | Exhaustive FIFO write/read            | Random packets, fill and drain over multiple rounds, credit invariants       | Existing |
| AHB-18 | Circular buffer wrap-around           | Fill FIFO until pointers wrap past SRAM boundary, verify data integrity     | Existing |
| AHB-19 | Single-word packet                    | Minimal packet (1 data word), verify all signals correct                    | Existing |
| AHB-20 | Maximum-size packet                   | Packet using all available credits, verify completion and credit=0            | Existing |
| AHB-21 | Credit count after write+read cycle    | Write N packets, read N packets, verify credits restored to MAX              | Existing |
| AHB-22 | Back-to-back write packets            | Write packets with minimal gap, verify no pointer corruption                | Existing |
| AHB-23 | IRQ deasserted after reset            | `packet_committed_irq` is 0 after reset                                     | New      |
| AHB-24 | IRQ asserts on write_complete         | `packet_committed_irq` goes high after packet write completes               | New      |
| AHB-25 | IRQ clears on read addr 0             | `packet_committed_irq` clears when recipient reads FIFO address 0           | New      |
| AHB-26 | IRQ stays cleared without new write   | After clear, IRQ remains 0 until another `write_complete`                   | New      |
| AHB-27 | IRQ multi-cycle write/read toggle     | Multiple write/read cycles toggle IRQ correctly                             | New      |
| AHB-28 | EN gate blocks writes                 | AHB writes gated when enable=0 — no pointer/credit changes                  | New      |
| AHB-29 | EN gate blocks reads                  | AHB reads gated when enable=0 — no metadata capture                        | New      |
| AHB-30 | FLUSH resets state                    | FLUSH resets pointers, credits to MAX, packet metadata to 0                  | New      |
| AHB-31 | FLUSH clears overrun                  | Overrun sticky flag set on full write, cleared by FLUSH                     | New      |
| AHB-32 | Underrun on empty read                | Underrun sticky flag set on read from empty buffer, cleared by FLUSH        | New      |
| AHB-33 | Error flags clear after reset         | Both overrun and underrun are 0 after hardware reset                        | New      |

### 2. tidelink_returner (AHB Master Unit Tests) — 17 tests

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| RET-01 | Reset defaults                        | busy=0, htrans=IDLE after reset                                             | Existing |
| RET-02 | Single write on interrupt             | Pulse interrupt_0, verify slave RAM write                                   | Existing |
| RET-03 | Busy during transfer                  | busy asserted during addr+data phases                                       | Existing |
| RET-04 | No transfer without interrupt         | Bus stays idle, no spurious writes                                          | Existing |
| RET-05 | Second interrupt queued while busy    | Second pulse during active transfer is queued via pending register           | Existing |
| RET-06 | Back-to-back transfers                | Two consecutive interrupts produce two writes                               | Existing |
| RET-07 | htrans sequence                       | IDLE -> NONSEQ -> IDLE during transfer                                      | Existing |
| RET-08 | Priority channel 0 over 1             | Both pending, channel 0 serviced first                                      | Existing |
| RET-09 | Priority channel 0 over 2             | Both pending, channel 0 serviced first                                      | Existing |
| RET-10 | Priority channel 1 over 2             | Both pending, channel 1 serviced first                                      | Existing |
| RET-11 | All three channels pending            | All three pending, verify service order 0->1->2                             | Existing |
| RET-12 | Pending survives busy                 | Interrupt while busy, pending serviced after current completes              | Existing |
| RET-13 | Channel data isolation                | Each channel uses its own addr/data, verify no cross-contamination          | Existing |
| RET-14 | Held interrupt (level, not pulse)     | Interrupt held high, verify only one transfer fires                         | Existing |
| RET-15 | master_error clear after reset        | master_error is 0 after hardware reset                                      | New      |
| RET-16 | master_error stays 0 on success      | master_error remains 0 after a successful transfer (hresp=0)               | New      |
| RET-17 | flush clears master_error register   | flush input resets master_error even when already 0                          | New      |

### 3. tidelink_apb_regs (APB Register Unit Tests) — 35 tests

Tests target `tidelink_apb_regs` in isolation with sideband inputs driven
directly from cocotb.

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| APB-01 | Pair base default                     | Reads back TIDELINK_PAIR_BASE parameter after reset                         | Existing |
| APB-02 | Pair base RW                          | Write new value, read it back, verify output port                           | Existing |
| APB-03 | Pair base resets to param             | Write new value, reset, verify reverts to parameter                         | Existing |
| APB-04 | Packet word length RO                 | Sideband input reflected in APB read                                        | Existing |
| APB-05 | Credit count RO                        | Sideband input reflected in APB read                                        | Existing |
| APB-06 | Status returner busy                  | Status bit 0 reflects returner_busy input                                   | Existing |
| APB-07 | Doorbell trigger pulse                | Write to doorbell generates 1-cycle self-clearing pulse                     | Existing |
| APB-08 | Reset deassert pulse                  | Reset deassertion generates 1-cycle pulse                                   | Existing |
| APB-09 | Released credits acc add               | Multiple writes accumulate                                                  | Existing |
| APB-10 | Released credits read-clear            | Read returns total and clears to 0                                          | Existing |
| APB-11 | Released credits IRQ                   | IRQ asserts on non-zero, clears on read                                     | Existing |
| APB-12 | Doorbell response acc                 | Write-add and read-clear behaviour                                          | Existing |
| APB-13 | Doorbell IRQ                          | IRQ asserts on non-zero, clears on read                                     | Existing |
| APB-14 | Pair counter increment                | Increments on write to 0x020                                                | Existing |
| APB-15 | Pair counter consume                  | Decrements on write to 0x02C                                                | Existing |
| APB-16 | Pair counter no side-effect read      | Multiple reads return same value                                            | Existing |
| APB-17 | Pair counter disable                  | Disabled counter ignores increments and decrements                          | Existing |
| APB-18 | Pair counter re-enable                | Re-enabling resumes counting                                                | Existing |
| APB-19 | Pair counter enable readback          | Enable register reads back correctly                                        | Existing |
| APB-20 | Credit delta capture                   | Delta registered on read_complete pulse (threshold=0)                       | Existing |
| APB-21 | Credit count data passthrough          | current_credit_count reflected combinationally                               | Existing |
| APB-22 | pready always high                    | Zero wait-state slave                                                       | Existing |
| APB-23 | pslverr always low                    | No errors                                                                   | Existing |
| APB-24 | Unimplemented reads zero              | Reserved/unimplemented offsets return 0                                     | Existing |
| APB-25 | Threshold default readback            | Release threshold reads 20 after reset                                      | Existing |
| APB-26 | Threshold RW                          | Write new threshold, read it back                                           | Existing |
| APB-27 | Threshold resets to default           | After reset, threshold reverts to 20                                        | Existing |
| APB-28 | Accumulates below threshold           | Deltas accumulate without firing trigger when below threshold               | Existing |
| APB-29 | Trigger fires at threshold            | Trigger fires when accumulated credits cross threshold, clears accumulator   | Existing |
| APB-30 | Threshold zero immediate              | Threshold=0 passes read_complete through directly (backward compat)         | Existing |
| APB-31 | Release acc debug readback            | Release accumulator at 0x018 reflects pending unreleased credits             | Existing |
| APB-32 | STATUS[4] pkt_committed default       | STATUS bit 4 (packet_committed) is 0 after reset                           | New      |
| APB-33 | STATUS[4] pkt_committed reflects high | STATUS bit 4 reads 1 when packet_committed input is asserted               | New      |
| APB-34 | STATUS[4] pkt_committed reflects low  | STATUS bit 4 reads 0 when packet_committed input is deasserted             | New      |
| APB-35 | STATUS[4] independent of other bits   | STATUS bit 4 is independent of bits [3:0]                                  | New      |

### 4. tidelink (Top-Level Integration Tests) — 25 tests

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| TOP-01 | Reset and initial credits              | APB credit count = MAX_CREDITS after reset                                    | Existing |
| TOP-02 | APB pair base readback                | Offset 0x000 returns TIDELINK_PAIR_BASE parameter                           | Existing |
| TOP-03 | Write-read-returner flow              | Full cycle: write, track credits, read, verify returner delta                | Existing |
| TOP-04 | Multiple packets credit tracking       | Write/read several packets, verify sw model matches hw at each step         | Existing |
| TOP-05 | Returner delta data correctness       | Verify returner sends correct delta (not always 1)                          | Existing |
| TOP-06 | Cumulative credit drift                | Verify cumulative deltas match total credits consumed                        | Existing |
| TOP-07 | Separate accumulators                 | Channel 0 delta and channel 1 total use separate addresses                  | Existing |
| TOP-08 | Default threshold batching            | Small reads accumulate; returner fires batched delta when acc >= 20         | Existing |
| TOP-09 | Threshold register RW                 | Read default (20), write new value, read back                               | Existing |
| TOP-10 | Large packet exceeds threshold        | Single large packet delta exceeds threshold, immediate release              | Existing |
| TOP-11 | Threshold zero backward compat        | Threshold=0 gives per-read immediate release                                | Existing |
| TOP-12 | Packet committed IRQ propagation      | `packet_committed_irq` asserts on write, clears on read through hierarchy   | Existing |
| TOP-13 | STATUS[4] packet committed polling    | STATUS bit 4 mirrors `packet_committed_irq`, pollable via APB              | Existing |
| TOP-14 | Flush resets state                    | EN=0 then FLUSH resets pointers, credits to MAX, IRQ, release_acc to 0; re-enable works | New |
| TOP-15 | Region 1 released credits acc          | APB 0x020 W-add/R-clear behaviour + `released_credits_irq` assert/deassert  | New      |
| TOP-16 | Region 1 doorbell response acc        | APB 0x024 W-add/R-clear behaviour + `doorbell_irq` assert/deassert         | New      |
| TOP-17 | Region 1 pair credit counter           | Counter increment (0x020), decrement (0x02C), enable/disable (0x030)        | New      |
| TOP-18 | FIFO overrun                          | Fill FIFO to credit_count=0, extra write sets sticky STATUS[1], flush clears | New      |
| TOP-19 | FIFO underrun                         | Read from empty FIFO sets sticky STATUS[2], flush clears                    | New      |
| TOP-20 | APB pair base write                   | Write to offset 0x000, verify readback and returner targeting               | New      |
| TOP-21 | APB packet word length read           | Read offset 0x008 reflects FIFO sideband `packet_word_length`              | New      |
| TOP-22 | APB release acc read                  | Read offset 0x018 shows pending unreleased credits (debug register)          | New      |
| TOP-23 | Flush clears release acc              | Flush zeros `release_acc` even when non-zero                                | New      |
| TOP-24 | AHB master wait states                | AHB slave inserts back-pressure (hready=0); returner FSM stalls and completes | New   |
| TOP-25 | Master error flag                     | AHB ERROR response (hresp=1) sets sticky STATUS[3], flush clears            | New      |

### 5. tidelink_ahb (AHB Wrapper Tests) — 14 tests

Tests target `tidelink_ahb` which wraps `tidelink` with a `cmsdk_ahb_to_apb`
bridge. All APB register access goes through the AHB config slave port
(`ahbc_*`), verifying the full AHB-to-APB-to-register path.

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| AHBW-01| Credit count via AHB                   | Read credit count through AHB-to-APB bridge after reset                      | Existing |
| AHBW-02| Pair base readback via AHB            | Pair base register reads default 0 through bridge                           | Existing |
| AHBW-03| Pair base write-readback via AHB      | Write new pair base address via AHB, read it back                           | Existing |
| AHBW-04| Status register via AHB               | Status bit[0] (returner_busy) reads 0 when idle                            | Existing |
| AHBW-05| Accumulator W-add R-clear via AHB     | Released credits accumulator write-add / read-clear through bridge           | Existing |
| AHBW-06| Doorbell response acc via AHB         | Doorbell response accumulator write-add / read-clear through bridge         | Existing |
| AHBW-07| IRQ from accumulator via AHB          | Writing to accumulator via AHB asserts IRQ; reading clears it               | Existing |
| AHBW-08| Doorbell triggers returner via AHB    | Doorbell write through bridge triggers returner channel 1                   | Existing |
| AHBW-09| Write-read-return flow via AHB        | Full FIFO write/read/return flow with all register reads via AHB bridge     | Existing |
| AHBW-10| Separate accumulators via AHB         | Channel 0 and channel 1 target different addresses, verified via AHB        | Existing |
| AHBW-11| Pair credit counter via AHB            | Counter increment, decrement, disable, re-enable — all via AHB bridge       | Existing |
| AHBW-12| Threshold readback via AHB            | Release threshold register readable and writable via AHB config port        | Existing |
| AHBW-13| Threshold batching via AHB            | Small reads accumulate; batched release when acc >= threshold via AHB       | Existing |
| AHBW-14| Packet committed IRQ via AHB          | `packet_committed_irq` asserts/clears correctly at AHB wrapper level       | New      |

### 6. tidelink_py_pair (Dual TideLink System Tests) — 19 tests

Uses a Python model (`PairRegisterBank`) to simulate the paired TideLink's
register bank. The DUT's AHB master writes are monitored and routed to the
pair model, which generates response writes back to the DUT's APB interface.

| ID     | Test Name                             | Description                                                                 | Status   |
|--------|---------------------------------------|-----------------------------------------------------------------------------|----------|
| PAIR-01| Reset doorbell flow                   | DUT reset -> rings pair doorbell -> pair responds with credits               | Existing |
| PAIR-02| Software doorbell                     | CPU writes doorbell, returner sends total credits to pair                    | Existing |
| PAIR-03| Independent resets                    | Each side resets independently, handshake works both times                  | Existing |
| PAIR-04| Pair resets while DUT running         | Pair reset rings DUT doorbell, DUT responds with total credits              | Existing |
| PAIR-05| Simultaneous reset                    | Both sides reset together, exchange credit counts                            | Existing |
| PAIR-06| Write packets then pair resets        | DUT has reduced credits, pair reset gets correct (reduced) count            | Existing |
| PAIR-07| Write and read then pair resets       | Write+read, pair reset gets correct net credit count                        | Existing |
| PAIR-08| Metadata stable on idle bus           | Idle bus at haddr=0 doesn't corrupt packet_word_length                     | Existing |
| PAIR-09| Doorbell lost when returner busy      | Doorbell while returner busy, pending captures it                          | Existing |
| PAIR-10| Stale packet length spurious hit      | Stale target addr doesn't trigger false completion                         | Existing |
| PAIR-11| Hit fires on wrong direction          | write_complete doesn't fire during reads                                   | Existing |
| PTC-01 | Counter defaults after reset          | Counter=0, enable=1 after reset                                            | Existing |
| PTC-02 | Counter increments on released credits | Write to 0x020 increments counter                                          | Existing |
| PTC-03 | Counter decrements on consume         | Write to 0x02C decrements counter                                          | Existing |
| PTC-04 | Counter read no side effects          | Multiple reads return same value                                            | Existing |
| PTC-05 | Counter disable freezes               | Disabled counter ignores increments and decrements                          | Existing |
| PTC-06 | Counter re-enable resumes             | Re-enabling after disable resumes counting                                  | Existing |
| PTC-07 | Counter independent of accumulator    | Read-clearing accumulator doesn't affect counter                            | Existing |
| PTC-08 | Counter end-to-end with FIFO writes   | Write packets, simulate pair releasing credits, verify counter               | Existing |

## Known Bugs

### BUG-002: No credit underflow protection

**Location**: `tidelink_fifo_ctrl.sv`

**Description**: Credit count is decremented without checking that
sufficient credits are available. If software writes a packet larger
than `credit_count`, the unsigned counter wraps to a large value.

**Impact**: FIFO can overwrite unread data; credit accounting becomes
corrupt.

**Proven by**: (software protocol violation, not tested directly)

## Resolved Bugs

| Bug | Summary | Resolution |
|-----|---------|------------|
| BUG-001 | Stale `credit_delta_data` — returner always sent delta=1 | Fixed: deltas now accumulated in `release_acc` inside `tidelink_apb_regs` and registered on `release_credits_trigger`. Proven by TOP-05, TOP-06. |
| BUG-003 | Dead code — `ptr_offset` register computed but unused | Fixed: `ptr_offset` removed from `tidelink_fifo_ctrl`. |
| BUG-004 | Channel 0 delta and channel 1 total wrote to same address | Fixed: channel 0 targets `PAIR_RELEASED_CREDITS_ADDR` (0x020), channel 1 targets `PAIR_DOORBELL_RESPONSE_ADDR` (0x024) — separate accumulators. Proven by TOP-07, AHBW-10. |

## Running Tests

```bash
# Run all test suites (6 environments, 143 tests)
cd cocotb && make regression

# Run individual suites
cd cocotb/tidelink_fifo && make
cd cocotb/tidelink_returner && make
cd cocotb/tidelink_apb_regs && make
cd cocotb/tidelink && make
cd cocotb/tidelink_ahb && make
cd cocotb/tidelink_py_pair && make

# Run full regression with VCS code coverage collection
cd cocotb && make coverage

# Override coverage metrics (default: line+cond+fsm+tgl+branch)
cd cocotb && make coverage CM_METRICS=line+cond
```

## Code Coverage

VCS code coverage is collected via `make coverage` at the top-level cocotb
Makefile. Each environment is compiled and simulated with `-cm line+cond+fsm+tgl+branch`,
and per-environment reports are generated with `urg` under `coverage_report/<env>/`.

### Coverage Summary (as of 2026-03-29)

| Environment       | Score | Line   | Cond  | Toggle | FSM   | Branch |
|-------------------|-------|--------|-------|--------|-------|--------|
| tidelink_fifo     | 93.26 | 100.00 | 80.00 | 94.34  | N/A   | 98.72  |
| tidelink          | 81.42 | 97.75  | 79.66 | 58.21  | 75.00 | 96.49  |
| tidelink_returner | 75.71 | 98.55  | 70.00 | 48.91  | 75.00 | 86.11  |
| tidelink_apb_regs | 75.08 | 92.41  | 81.13 | 36.22  | N/A   | 90.57  |
| tidelink_py_pair  | 71.42 | 88.85  | 71.19 | 39.44  | 75.00 | 82.63  |
| tidelink_ahb      | 62.95 | 86.54  | 75.41 | 41.69  | 30.43 | 80.66  |

### Remaining Coverage Gaps

| Gap | Affected Module(s) | Improvement Strategy |
|-----|---------------------|----------------------|
| Toggle on upper data/address bits | All (especially `tidelink_returner`) | Randomised wide data patterns in packets |
| FSM `ST_ADDR_PHASE → ST_IDLE` | `tidelink_returner` | Unusual AHB error-abort edge case; low priority |
| `cmsdk_ahb_to_apb` bridge low coverage | `tidelink_ahb` | Add coverage tests to `tidelink_ahb` environment (wait states, error injection via AHB config port) |
| Condition coverage on `valid_transfer` sub-expressions | `tidelink_fifo_ctrl` | Tests with hsel=0, htrans=IDLE, or enable=0 mid-transfer |

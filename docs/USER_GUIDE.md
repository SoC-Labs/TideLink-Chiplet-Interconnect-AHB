# TideLink User Guide

## Introduction

TideLink is a credit-based FIFO interconnect for transferring variable-length packets between two chiplets over an AHB bus bridge. This guide covers how to integrate, configure, and operate TideLink in your system.

## Getting Started

### Choosing a Wrapper

| Wrapper | Use When |
|---------|----------|
| `fifo/tidelink_fifo.sv` | Your system already has an APB bus for register access |
| `fifo/tidelink_fifo_ahb.sv` | You need all interfaces on AHB (includes an AHB-to-APB bridge for registers) |

### Selecting an SRAM Variant

Include the appropriate file list for your target:

| Target | File List | SRAM |
|--------|-----------|------|
| Xilinx FPGA | `flist/tidelink.flist` | `cmsdk_fpga_sram` (block RAM) |
| Simulation | `flist/tidelink_generic.flist` | Register-based behavioural model |
| ASIC (TSMC 65nm) | `flist/tidelink_asic.flist` | `rf_16k` compiled macro |

### Setting Parameters

At instantiation, set the pair base address to point at the paired TideLink's register space:

```verilog
tidelink_fifo_ahb #(
    .TIDELINK_PAIR_BASE (32'h5000_1000)  // Paired instance's APB base
) u_tidelink_tx (
    .hclk       (hclk),
    .hresetn    (hresetn),
    // AHB slave - FIFO data window
    .ahbs_hsel  (...),
    // AHB slave - configuration registers
    .ahbc_hsel  (...),
    // AHB master - credit return path
    .ahbm_hready(...),
    // Interrupts
    .released_credits_irq (...),
    .doorbell_irq        (...),
    .packet_committed_irq(...)
);
```

The pair base address can also be changed at runtime by writing to register 0x000.

## Basic Operation

### Initialisation Sequence

After reset, the FIFO data window is immediately enabled. Follow this sequence to bring it up:

```
1. (Optional) Write pair base address to 0x000 if different from parameter default
2. (Optional) Write release threshold to 0x004 (default: 20)
3. Wait for doorbell_irq (pair's reset handshake response)
4. Read doorbell response accumulator (0x024) to get pair's available credits
5. TideLink is now ready for data transfer
```

### Writing a Packet (Transmit Side)

A write packet has a one-word header followed by the data payload:

```
 FIFO Address   Content
 ┌───────────┬────────────────────────────────┐
 │  0x0000   │  Length (N)                    │  ← Header: number of data words
 ├───────────┼────────────────────────────────┤
 │  0x0004   │  Data[0]                       │
 ├───────────┼────────────────────────────────┤
 │  0x0008   │  Data[1]                       │
 ├───────────┼────────────────────────────────┤
 │    ...    │  ...                           │
 ├───────────┼────────────────────────────────┤
 │  N × 4   │  Data[N-1]                      │  ← Final write triggers completion
 └───────────┴────────────────────────────────┘
              ◄──── All words are 32 bits ────►
```

The length word contains the number of **data** words only (0–4095) and does not count itself. The total FIFO occupancy is N + 1 credits (1 header + N data).

To send a packet of N data words:

```
1. Check pair credit counter (0x028) >= N + 1, OR
   maintain a software credit counter from released_credits_irq
2. Write N to FIFO address 0x000 (packet length)
3. Write data word 0 to FIFO address 0x004
4. Write data word 1 to FIFO address 0x008
5. ...
6. Write data word N-1 to FIFO address N*4
   → write_complete fires internally
   → packet_committed_irq asserts
7. Write N + 1 to pair credit consume register (0x02C)
   to decrement the pair credit counter
```

The write to the final address (N × 4) triggers completion — pointers advance and credits are consumed automatically.

### Reading a Packet (Receive Side)

To receive a packet:

```
1. Wait for packet_committed_irq, or poll STATUS[4] (packet_committed) until set
2. Read FIFO address 0x000 → returns packet length N
   → packet_committed_irq and STATUS[4] clear
3. Read FIFO address 0x004 → data word 0
4. Read FIFO address 0x008 → data word 1
5. ...
6. Read FIFO address N*4 → data word N-1
   → read_complete fires internally
   → credits are freed and release mechanism triggers
```

The read from the final address triggers completion — pointers advance, credits are restored, and the release accumulator is incremented.

### Interrupt-Driven Operation

TideLink provides three interrupts for efficient event-driven software:

**`packet_committed_irq`** — A new packet has been fully written to the FIFO and is ready to read. Cleared automatically when the receiver reads FIFO address 0 (the length word). Also exposed as STATUS register bit 4 (`packet_committed`) for polling-based designs that don't use interrupts.

**`released_credits_irq`** — The paired TideLink has freed credits (buffer space). Read register 0x020 to get the delta (read-to-clear). Use this to maintain a software credit budget for transmission.

**`doorbell_irq`** — The paired TideLink has responded to a doorbell or reset handshake. Read register 0x024 to get the pair's total free credit count (read-to-clear).

## Credit Flow Control

### How It Works

TideLink prevents buffer overflow through a credit-based credit scheme:

1. Each instance starts with `MAX_CREDITS` (4096) credits representing its FIFO capacity.
2. When chiplet A writes a packet to chiplet B's TideLink, B's local credit count decreases.
3. When chiplet B's software reads the packet, credits are freed and batched.
4. Once the accumulated freed credits reach the release threshold, B's returner autonomously writes the delta back to A's Released Credits Accumulator (0x020).
5. Chiplet A's software reads the accumulator (or uses the pair credit counter) to know it can send more data.

**Golden rule**: never write a packet unless you have confirmed the remote side has enough credits to receive it.

### Using the Pair Credit Counter

The hardware pair credit counter at 0x028 tracks the remote FIFO's available credits automatically:

```
1. After reset handshake, read 0x024 to get initial pair credits
2. The counter at 0x028 auto-increments when pair releases credits (0x020 writes)
3. Before sending a packet of size N+1:
   a. Read 0x028 and check value >= N + 1
   b. Write N + 1 to 0x02C to reserve (consume) the credits
   c. Write the packet to the FIFO data window
```

To disable the hardware counter (e.g. if managing credits in software), write 0 to 0x030.

### Release Threshold Tuning

The release threshold (register 0x004, default 20) controls how aggressively freed credits are returned:

| Threshold | Behaviour | Best For |
|-----------|-----------|----------|
| 0 | Immediate release on every `read_complete` | Low-latency, small packets |
| 1–19 | Batch small reads | Mixed traffic |
| 20 (default) | Moderate batching | General use |
| 100+ | Aggressive batching | Large bulk transfers, reduce bus traffic |

Higher thresholds reduce AHB master bus utilisation but increase latency before the transmitter learns about freed space.

## Doorbell

The doorbell is a software-initiated request/response mechanism. Use it when you need to query the remote side's current state.

**Sending a doorbell**:
```
Write any value to Doorbell register (0x014)
→ Returner channel 1 sends local credit_count to pair's 0x024
```

**Receiving a doorbell response**:
```
Wait for doorbell_irq
Read 0x024 → pair's total free credits (read-to-clear)
```

The doorbell is also used automatically during the reset handshake — you typically only need to use it explicitly for runtime re-synchronisation.

## Error Handling

### Detecting Errors

Read the Status register (0x010):

| Bit | Flag | Meaning |
|-----|------|---------|
| 0 | Returner Busy | Returner is mid-transfer (not an error, informational) |
| 1 | Overrun | A write occurred when the FIFO was full. Data may be corrupted. |
| 2 | Underrun | A read occurred when the FIFO was empty. Stale data returned. |
| 3 | Master Error | The returner received an AHB error response. Credit return was lost. |
| 4 | Packet Committed | A packet has been fully written and is ready to read. Cleared on read of FIFO address 0. |

Bits 1–3 are sticky — they remain set until cleared by FLUSH.

### Recovery Procedure

```
1. Detect error via STATUS register or system-level fault
2. Write 0x02 to CTRL (0x01C)         — FLUSH (self-clearing)
   → Pointers, credits, packet state, sticky flags all reset
3. Reconfigure if needed:
   - Pair base address (0x000)
   - Release threshold (0x004)
4. Re-establish credit counts with the pair (doorbell or reset handshake)
```

## Bidirectional Communication

For full duplex communication between two chiplets, deploy two TideLink instances per side:

```
  Chiplet A                           Chiplet B
  ┌────────────────┐                 ┌────────────────┐
  │ TL_A_TX ─(ahbm)──────────────►  │ TL_B_RX (ahbs) │
  │          ◄(0x020/024)──────────  │         (ahbm)─►│
  │                │                 │                 │
  │ TL_A_RX ◄(ahbs)──────────────── │ TL_B_TX (ahbm)─│
  │  (ahbm)─►(0x020/024)──────────► │                 │
  └────────────────┘                 └────────────────┘
```

- `TL_A_TX.PAIR_BASE` = base address of `TL_B_RX`'s APB registers
- `TL_B_TX.PAIR_BASE` = base address of `TL_A_RX`'s APB registers
- Each returner's AHB master must be routable to its pair's register slave port through the bus interconnect

## Register Quick Reference

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | Pair Base Address | RW | Target address for returner writes |
| 0x004 | Release Threshold | RW | Credit batching threshold (default 20) |
| 0x008 | Packet Word Length | RO | In-flight packet size (0 when idle) |
| 0x00C | Credit Count | RO | Local FIFO available credits |
| 0x010 | Status | RO | Busy, sticky error flags, packet_committed |
| 0x014 | Doorbell | WO | Trigger software doorbell (singlepulse, self-clearing) |
| 0x018 | Release Accumulator | RO | Pending unreleased credits (debug) |
| 0x01C | CTRL | RW | Bit 0: reserved. FLUSH (bit 1, self-clearing) |
| 0x020 | Released Credits Acc | W-add/R-clear | Incoming credit deltas. IRQ source. |
| 0x024 | Doorbell Response Acc | W-add/R-clear | Incoming doorbell responses. IRQ source. |
| 0x028 | Pair Credit Counter | RO | Remote FIFO available credits |
| 0x02C | Pair Credit Consume | WO | Reserve credits before sending |
| 0x030 | Pair Credit Counter En | RW | Enable/disable hardware counter |

## Running Tests

### Prerequisites

```bash
pip install -e python/    # Install shared Python package
```

Requires Synopsys VCS, cocotb, and cocotbext-ahb.

### Full Regression (126 tests)

```bash
cd cocotb
make regression
```

### Individual Test Suites

```bash
cd cocotb/tidelink_fifo     && make    # 33 FIFO unit tests
cd cocotb/tidelink_returner && make    # 17 returner unit tests
cd cocotb/tidelink_apb_regs && make    # 31 APB register tests
cd cocotb/tidelink          && make    # 12 integration tests
cd cocotb/tidelink_ahb      && make    # 14 AHB wrapper tests
cd cocotb/tidelink_py_pair  && make    # 19 dual-instance system tests
```

### Running a Specific Test

```bash
cd cocotb/tidelink_py_pair
make TESTCASE=test_ptc_01_defaults_after_reset
```

### Waveform Debug

```bash
cd cocotb/tidelink_fifo
make gui    # Opens Verdi with simulation database
```

## PTP Clock Synchronisation

TideLink includes a PTP subsystem (`tidelink_ptp.sv`) for precision clock synchronisation between chiplets. It uses a two-message protocol (SYNC + DELAY_REQ) with hardware timestamp capture for low-jitter time transfer. See `docs/PTP_PROTOCOL.md` for the full protocol specification.

### PTP Ports

The PTP subsystem adds the following ports to `tidelink_top`:

| Port | Direction | Description |
|------|-----------|-------------|
| `ahb_ptp_hsel` | Input | AHB slave select for PTP writes |
| `ahb_ptp_haddr` | Input | AHB address |
| `ahb_ptp_htrans` | Input | AHB transfer type |
| `ahb_ptp_hwrite` | Input | AHB write enable |
| `ahb_ptp_hwdata` | Input | AHB write data (msg_type in [35:32], payload in [31:0]) |
| `ahb_ptp_hready` | Input | AHB ready input |
| `ahb_ptp_hreadyout` | Output | AHB ready output |
| `ahb_ptp_hrdata` | Output | AHB read data (PTP_RX_PAYLOAD) |
| `phc_hw_capture` | Output | One-cycle pulse to PHC hw_capture input |
| `phc_nanoseconds` | Input | PHC current nanoseconds [29:0] (for HW sync initiator) |
| `phc_seconds` | Input | PHC current seconds [47:0] (for HW sync initiator) |
| `phc_pps` | Input | PHC pulse-per-second (reserved for future use) |
| `ptp_irq` | Output | Interrupt: PTP RX packet received |

### PHC Initialisation

Before using PTP, initialise the PTP Hardware Clock:

```
1. Write nominal nanosecond increment to PHC NS_INCR register
   (e.g. 0x8 for 125 MHz clock = 8 ns per cycle)
2. Write sub-nanosecond fractional increment to PHC NS_INCR_FRAC register
   (e.g. 0x0 for exact integer period)
3. (Optional) Set initial time via PHC SET_TIME registers
4. Enable PHC: write 1 to PHC CTRL.EN
```

### PTP Initialisation

```
1. Write 1 to PTP_CTRL (APB offset 0x034) to enable the PTP subsystem
2. Enable ptp_irq in the system interrupt controller
```

### Triggering a SYNC Exchange

**On the Grandmaster side:**

```
1. Write to the PTP AHB slave with msg_type=0x0 (SYNC)
   → tidelink_ptp waits for tx_router_idle
   → hw_capture fires (t1 captured in PHC HW_CAP registers)
   → SYNC packet sent via PTP FC node

2. Wait for ptp_irq (DELAY_REQ received from Subordinate)
   → t4 captured automatically in PHC HW_CAP registers

3. Read t1 and t4 from PHC HW_CAP registers:
   - HW_CAP_SEC_HI  (0x040)
   - HW_CAP_SEC_LO  (0x044)
   - HW_CAP_NS      (0x048)
   - HW_CAP_NS_FRAC (0x04C)
   Note: read t1 before DELAY_REQ arrives to avoid overwrite,
   or use Option B second capture bank if available

4. Send t1 to Subordinate via mailbox FIFO (Path 2) or AHB bridge (Path 1)
```

**On the Subordinate side:**

```
1. Wait for ptp_irq (SYNC received from Grandmaster)
   → t2 captured automatically in PHC HW_CAP registers

2. Read t2 from PHC HW_CAP registers (0x040-0x04C)

3. Write to the PTP AHB slave with msg_type=0x1 (DELAY_REQ)
   → tidelink_ptp waits for tx_router_idle
   → hw_capture fires (t3 captured in PHC HW_CAP registers)
   → DELAY_REQ packet sent via PTP FC node

4. Read t3 from PHC HW_CAP registers (0x040-0x04C)

5. Receive t1 from Grandmaster (via mailbox FIFO or AHB bridge)
```

### Computing Offset and Delay

With all four timestamps available on the Subordinate:

```
offset = ((t2 - t1) - (t4 - t3)) / 2
delay  = ((t2 - t1) + (t4 - t3)) / 2
```

- `offset` > 0 means the Subordinate clock is ahead of the Grandmaster
- `delay` is the one-way propagation delay through the die-to-die link

### Adjusting the PHC for Clock Discipline

**Phase correction (large offset):**
```
Write corrected time to PHC SET_TIME registers
```

**Frequency steering (small offset, steady state):**
```
Adjust PHC NS_INCR_FRAC register:
  - Subordinate behind → increase NS_INCR_FRAC (speed up clock)
  - Subordinate ahead  → decrease NS_INCR_FRAC (slow down clock)
```

A proportional-integral (PI) controller is recommended for the servo loop. Typical exchange intervals are 100 ms to 1 s depending on required accuracy.

### Hardware Sync Initiator

The PTP subsystem includes an optional hardware sync initiator that autonomously generates periodic SYNC messages without CPU intervention, using the PHC time outputs as its timing reference.

**Wiring the PHC time inputs:**

Connect the PHC's `seconds`, `nanoseconds`, and `pps` outputs to `tidelink_top`:

```verilog
tidelink_top #(...) u_tidelink (
    // ... other ports ...
    .phc_hw_capture    (phc_hw_capture),
    .phc_nanoseconds   (phc_nanoseconds),   // from phc_clock_core.seconds
    .phc_seconds       (phc_seconds),        // from phc_clock_core.nanoseconds
    .phc_pps           (phc_pps),            // from phc_clock_core.pps
    // ...
);
```

**Enabling the hardware sync initiator:**

```
1. Configure the sync interval (in nanoseconds):
   Write desired interval to HW_SYNC_INTERVAL (APB offset 0x044)
   Example: 0x3B9AC9FF (999,999,999) for ~1 Hz
   Example: 0x00773594 (7,812,500) for 128 Hz

2. Enable the initiator:
   Write 1 to HW_SYNC_CTRL (APB offset 0x040)

3. Monitor via HW_SYNC_STATUS (APB offset 0x048):
   Bit 0: active (FSM is running)
   Bit 1: busy (TX in progress)
   Bits [17:2]: current sequence number
```

The initiator generates SYNC messages (msg_type=0x0) with an auto-incrementing 16-bit sequence number in the payload. To reset the sequence number, write bit 1 of HW_SYNC_CTRL.

### PTP Interrupt Handling

The `ptp_irq` interrupt fires when the PTP FC RX path receives a packet:

```
ptp_irq handler:
  1. Read PTP_STATUS (APB offset 0x03C)
     - Bit 0: RX packet available
     - Bit 1: TX busy (waiting for tx_router_idle)
  2. Read PTP_RX_PAYLOAD (APB offset 0x038) for received msg_type and payload
  3. Read PHC HW_CAP registers for the captured timestamp
  4. Signal the software PTP state machine
```

### PTP Register Summary

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x034 | PTP_CTRL | RW | Bit 0: PTP enable |
| 0x038 | PTP_RX_PAYLOAD | RO | Last received PTP payload [31:0] |
| 0x03C | PTP_STATUS | RO | Bit 0: RX available, Bit 1: TX busy |
| 0x040 | HW_SYNC_CTRL | RW | Bit 0: HW sync enable, Bit 1: seq clear (W1C) |
| 0x044 | HW_SYNC_INTERVAL | RW | Sync interval in nanoseconds [29:0] |
| 0x048 | HW_SYNC_STATUS | RO | Bit 0: active, Bit 1: busy, [17:2]: seq_num |

## PYNQ Hardware Testing

For Pynq-Z2 boards with TideLink synthesised into the FPGA fabric:

```python
from tidelink.pynq_driver import PynqTidelinkDriver

tl = PynqTidelinkDriver(
    fifo_base_addr=0x4000_0000,
    cfg_base_addr=0x4001_0000
)

# Write a packet
tl.write_packet([0xDEAD, 0xBEEF, 0xCAFE])

# Read credit count
credits = tl.read_credit_count()

# Trigger doorbell
tl.doorbell()
```

Requires a Vivado bitstream with `tidelink_fifo_ahb` connected via `axi_ahblite_bridge` to the Zynq PS AXI GP port.

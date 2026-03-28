# TideLink User Guide

## Introduction

TideLink is a token-based FIFO interconnect for transferring variable-length packets between two chiplets over an AHB bus bridge. This guide covers how to integrate, configure, and operate TideLink in your system.

## Getting Started

### Choosing a Wrapper

| Wrapper | Use When |
|---------|----------|
| `tidelink.sv` | Your system already has an APB bus for register access |
| `tidelink_ahb.sv` | You need all interfaces on AHB (includes an AHB-to-APB bridge for registers) |

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
tidelink_ahb #(
    .TIDELINK_PAIR_BASE (32'h5000_1000)  // Paired instance's APB base
) u_tidelink_tx (
    .hclk       (hclk),
    .hresetn    (hresetn),
    // AHB slave - FIFO data window
    .ahbs_hsel  (...),
    // AHB slave - configuration registers
    .ahbc_hsel  (...),
    // AHB master - token return path
    .ahbm_hready(...),
    // Interrupts
    .released_tokens_irq (...),
    .doorbell_irq        (...),
    .packet_committed_irq(...)
);
```

The pair base address can also be changed at runtime by writing to register 0x000.

## Basic Operation

### Initialisation Sequence

After reset, TideLink is disabled. Follow this sequence to bring it up:

```
1. (Optional) Write pair base address to 0x000 if different from parameter default
2. (Optional) Write release threshold to 0x004 (default: 20)
3. Write 0x01 to CTRL register (0x01C) to set EN=1
4. Wait for doorbell_irq (pair's reset handshake response)
5. Read doorbell response accumulator (0x024) to get pair's available tokens
6. TideLink is now ready for data transfer
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

The length word contains the number of **data** words only (0–4095) and does not count itself. The total FIFO occupancy is N + 1 tokens (1 header + N data).

To send a packet of N data words:

```
1. Check pair token counter (0x028) >= N + 1, OR
   maintain a software token counter from released_tokens_irq
2. Write N to FIFO address 0x000 (packet length)
3. Write data word 0 to FIFO address 0x004
4. Write data word 1 to FIFO address 0x008
5. ...
6. Write data word N-1 to FIFO address N*4
   → write_complete fires internally
   → packet_committed_irq asserts
7. Write N + 1 to pair token consume register (0x02C)
   to decrement the pair token counter
```

The write to the final address (N × 4) triggers completion — pointers advance and tokens are consumed automatically.

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
   → tokens are freed and release mechanism triggers
```

The read from the final address triggers completion — pointers advance, tokens are restored, and the release accumulator is incremented.

### Interrupt-Driven Operation

TideLink provides three interrupts for efficient event-driven software:

**`packet_committed_irq`** — A new packet has been fully written to the FIFO and is ready to read. Cleared automatically when the receiver reads FIFO address 0 (the length word). Also exposed as STATUS register bit 4 (`packet_committed`) for polling-based designs that don't use interrupts.

**`released_tokens_irq`** — The paired TideLink has freed tokens (buffer space). Read register 0x020 to get the delta (read-to-clear). Use this to maintain a software token budget for transmission.

**`doorbell_irq`** — The paired TideLink has responded to a doorbell or reset handshake. Read register 0x024 to get the pair's total free token count (read-to-clear).

## Token Flow Control

### How It Works

TideLink prevents buffer overflow through a token-based credit scheme:

1. Each instance starts with `MAX_TOKENS` (4096) tokens representing its FIFO capacity.
2. When chiplet A writes a packet to chiplet B's TideLink, B's local token count decreases.
3. When chiplet B's software reads the packet, tokens are freed and batched.
4. Once the accumulated freed tokens reach the release threshold, B's returner autonomously writes the delta back to A's Released Tokens Accumulator (0x020).
5. Chiplet A's software reads the accumulator (or uses the pair token counter) to know it can send more data.

**Golden rule**: never write a packet unless you have confirmed the remote side has enough tokens to receive it.

### Using the Pair Token Counter

The hardware pair token counter at 0x028 tracks the remote FIFO's available tokens automatically:

```
1. After reset handshake, read 0x024 to get initial pair tokens
2. The counter at 0x028 auto-increments when pair releases tokens (0x020 writes)
3. Before sending a packet of size N+1:
   a. Read 0x028 and check value >= N + 1
   b. Write N + 1 to 0x02C to reserve (consume) the tokens
   c. Write the packet to the FIFO data window
```

To disable the hardware counter (e.g. if managing tokens in software), write 0 to 0x030.

### Release Threshold Tuning

The release threshold (register 0x004, default 20) controls how aggressively freed tokens are returned:

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
→ Returner channel 1 sends local token_count to pair's 0x024
```

**Receiving a doorbell response**:
```
Wait for doorbell_irq
Read 0x024 → pair's total free tokens (read-to-clear)
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
| 3 | Master Error | The returner received an AHB error response. Token return was lost. |
| 4 | Packet Committed | A packet has been fully written and is ready to read. Cleared on read of FIFO address 0. |

Bits 1–3 are sticky — they remain set until cleared by FLUSH.

### Recovery Procedure

```
1. Detect error via STATUS register or system-level fault
2. Write 0x00 to CTRL (0x01C)         — disable block (EN=0)
3. Write 0x02 to CTRL (0x01C)         — FLUSH (self-clearing)
   → Pointers, tokens, packet state, sticky flags all reset
4. Reconfigure if needed:
   - Pair base address (0x000)
   - Release threshold (0x004)
5. Write 0x01 to CTRL (0x01C)         — re-enable (EN=1)
6. Re-establish token counts with the pair (doorbell or reset handshake)
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
| 0x004 | Release Threshold | RW | Token batching threshold (default 20) |
| 0x008 | Packet Word Length | RO | In-flight packet size (0 when idle) |
| 0x00C | Token Count | RO | Local FIFO available tokens |
| 0x010 | Status | RO | Busy, sticky error flags, packet_committed |
| 0x014 | Doorbell | W1C | Trigger software doorbell |
| 0x018 | Release Accumulator | RO | Pending unreleased tokens (debug) |
| 0x01C | CTRL | RW | EN (bit 0), FLUSH (bit 1) |
| 0x020 | Released Tokens Acc | W-add/R-clear | Incoming token deltas. IRQ source. |
| 0x024 | Doorbell Response Acc | W-add/R-clear | Incoming doorbell responses. IRQ source. |
| 0x028 | Pair Token Counter | RO | Remote FIFO available tokens |
| 0x02C | Pair Token Consume | WO | Reserve tokens before sending |
| 0x030 | Pair Token Counter En | RW | Enable/disable hardware counter |

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

# Read token count
tokens = tl.read_token_count()

# Trigger doorbell
tl.doorbell()
```

Requires a Vivado bitstream with `tidelink_ahb` connected via `axi_ahblite_bridge` to the Zynq PS AXI GP port.

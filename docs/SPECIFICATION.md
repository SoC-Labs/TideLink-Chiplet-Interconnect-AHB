# TideLink Specification

**Version**: 1.0
**Date**: 2026-03-28
**Status**: Derived from RTL (commit 820d9fc)

## 1. Overview

TideLink is a hardware FIFO block designed for reliable, credit-based data transfer between chiplets connected via an AHB bus bridge. It provides variable-length packet ingress and egress with word-level flow control, ensuring that a transmitting chiplet never overflows the receiving chiplet's buffer.

Each TideLink instance handles one direction of data flow. For bidirectional communication, two instances are deployed — one on each side of the chiplet interconnect — with credit return paths crossing in opposite directions.

## 2. Features

- 16 KB circular FIFO buffer backed by SRAM (FPGA block RAM, ASIC compiled macro, or generic register file)
- Variable-length packet framing with word-level granularity
- Credit-based flow control with configurable release threshold batching
- 3-channel priority AHB Lite master for autonomous credit return and doorbell signalling
- Hardware pair credit counter for tracking remote buffer availability
- Software-triggered doorbell with hardware response path
- Automatic reset handshake between paired instances
- Sticky error flags (overrun, underrun, master error) with software flush recovery
- Three interrupt outputs: released credits, doorbell response, packet committed

## 3. Block Diagram

```
                         TideLink Instance (tidelink_fifo.sv)
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │  AHB Slave ──► tidelink_fifo_mem ──► SRAM (16 KB)               │
  │  (packets)     ┌─────────────────────┐                           │
  │                │ tidelink_fifo_ctrl   │                           │
  │                │ - circular pointers  │                           │
  │                │ - packet metadata    │                           │
  │                │ - credit counting     │                           │
  │                │ - address translation│                           │
  │                └──────────┬──────────┘                           │
  │                           │ read_complete, credit signals          │
  │                           ▼                                      │
  │  APB Slave ──► tidelink_apb_regs                                 │
  │  (software)    - pair base address (RW)                          │
  │                - release threshold (RW)                           │
  │                - credit accumulators (W-add / R-clear)             │
  │                - pair credit counter                               │
  │                - doorbell, status, CTRL                           │
  │                           │                                      │
  │                           │ interrupt triggers                    │
  │                           ▼                                      │
  │                tidelink_returner ──► AHB Master                  │
  │                (3-ch priority         (to paired instance)        │
  │                 arbiter + pending)                                │
  │                                                                  │
  │  Interrupts: released_credits_irq, doorbell_irq,                  │
  │              packet_committed_irq                                │
  └──────────────────────────────────────────────────────────────────┘
```

The `tidelink_fifo_ahb` wrapper adds a `cmsdk_ahb_to_apb` bridge, exposing three AHB ports:

| Port | Direction | Function |
|------|-----------|----------|
| `ahbs_*` | AHB Slave | FIFO data window (packet read/write) |
| `ahbc_*` | AHB Slave | Configuration registers (via AHB-to-APB bridge) |
| `ahbm_*` | AHB Master | Credit return and doorbell writes to paired instance |

## 4. Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SYS_ADDR_W` | 32 | System address bus width (bits) |
| `SYS_DATA_W` | 32 | System data bus width (bits) |
| `RAM_ADDR_W` | 14 | SRAM address width (bits). Buffer size = 2^RAM_ADDR_W bytes |
| `RAM_DATA_W` | 32 | SRAM data width (bits) |
| `APB_ADDR_W` | 12 | APB address width (bits) |
| `TIDELINK_PAIR_BASE` | 32'h0 | Default base address of the paired TideLink instance |

### Derived Constants

| Constant | Value | Derivation |
|----------|-------|------------|
| `MAX_CREDITS` | 4096 | 2^(RAM_ADDR_W - 2). One credit = one 32-bit word of SRAM capacity |
| Buffer size | 16,384 bytes | 2^RAM_ADDR_W |

## 5. Interfaces

### 5.1 AHB Slave — FIFO Data Window

Standard AHB Lite slave interface for packet read and write access.

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `hsel` | 1 | Input | Slave select |
| `hready` | 1 | Input | Previous transfer complete |
| `htrans[1:0]` | 2 | Input | Transfer type (IDLE=00, NONSEQ=10) |
| `hsize[2:0]` | 3 | Input | Transfer size |
| `hwrite` | 1 | Input | Write (1) or read (0) |
| `haddr[RAM_ADDR_W-1:0]` | 14 | Input | Byte address within FIFO |
| `hwdata[SYS_DATA_W-1:0]` | 32 | Input | Write data |
| `hreadyout` | 1 | Output | Slave ready |
| `hresp` | 1 | Output | Transfer response (always OK) |
| `hrdata[SYS_DATA_W-1:0]` | 32 | Output | Read data |

**Address space**: 0x0000 to 0x3FFF (16 KB).

**Transfer rules**:
- A valid transfer requires: `hsel=1`, `htrans[1]=1`, `hready=1`, `enable=1`, and `packet_word_length != 0`.
- Address 0x0000 has special metadata capture behaviour (see Section 7).
- All addresses are translated internally by adding the current read or write pointer.

### 5.2 APB Slave — Configuration Registers

Standard APB interface for software register access.

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `psel` | 1 | Input | Peripheral select |
| `penable` | 1 | Input | Enable phase |
| `pwrite` | 1 | Input | Write (1) or read (0) |
| `paddr[APB_ADDR_W-1:0]` | 12 | Input | Byte address |
| `pwdata[31:0]` | 32 | Input | Write data |
| `prdata[31:0]` | 32 | Output | Read data |
| `pready` | 1 | Output | Always 1 (zero wait states) |
| `pslverr` | 1 | Output | Always 0 (no errors) |

### 5.3 AHB Master — Returner

AHB Lite master interface for autonomous writes to the paired TideLink.

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `haddr[SYS_ADDR_W-1:0]` | 32 | Output | Target address |
| `htrans[1:0]` | 2 | Output | IDLE or NONSEQ |
| `hsize[2:0]` | 3 | Output | Always WORD (3'b010) |
| `hwrite` | 1 | Output | Always 1 (write-only) |
| `hwdata[SYS_DATA_W-1:0]` | 32 | Output | Write data |
| `hready` | 1 | Input | Slave ready |
| `hresp` | 1 | Input | Slave response |

**Transfer characteristics**: Single-beat, non-sequential, word-sized writes only. No burst or pipelined transfers.

### 5.4 Interrupts

| Signal | Source | Asserted When | Cleared By |
|--------|--------|---------------|------------|
| `released_credits_irq` | APB regs | Released credits accumulator (0x020) != 0 | CPU read of 0x020 (read-to-clear) |
| `doorbell_irq` | APB regs | Doorbell response accumulator (0x024) != 0 | CPU read of 0x024 (read-to-clear) |
| `packet_committed_irq` | FIFO ctrl | Packet fully written to FIFO (`write_complete`) | First read from FIFO address 0 (recipient starts reading) |

### 5.5 Clock and Reset

| Signal | Description |
|--------|-------------|
| `hclk` | System clock. All logic is synchronous to this clock. |
| `hresetn` | Active-low asynchronous reset. |

## 6. Register Map

### 6.1 Region 0 — Configuration and Status (0x000–0x01F)

| Offset | Name | Access | Reset Value | Description |
|--------|------|--------|-------------|-------------|
| 0x000 | Pair Base Address | RW | `TIDELINK_PAIR_BASE` | Base address of the paired TideLink's APB register space. The returner derives its target addresses from this value. |
| 0x004 | Release Threshold | RW | 20 | Minimum accumulated credits before triggering a release to the pair. Set to 0 for immediate per-packet release. |
| 0x008 | Packet Word Length | RO | 0 | In-flight packet's data word count, captured from FIFO sideband. Non-zero only while a packet write or read is in progress; cleared to 0 on `write_complete` or `read_complete`. Not suitable for polling to detect packet arrival — use `packet_committed_irq` instead. |
| 0x00C | Credit Count | RO | MAX_CREDITS | Available credits in the local FIFO. Decremented on write, incremented on read. |
| 0x010 | Status | RO | 0 | Bit 0: returner_busy. Bit 1: overrun (sticky). Bit 2: underrun (sticky). Bit 3: master_error (sticky). Bit 4: packet_committed (mirrors `packet_committed_irq`; pollable). |
| 0x014 | Doorbell | WO | 0 | Write any value to generate a one-cycle doorbell trigger pulse. Self-clearing (singlepulse). |
| 0x018 | Release Accumulator | RO | 0 | Pending unreleased credits (debug visibility). Cleared when release trigger fires. |
| 0x01C | CTRL | RW | 0 | Bit 0: EN (block enable). Bit 1: FLUSH (self-clearing, EN must be 0). |

### 6.2 Region 1 — Incoming Credit Receivers (0x020–0x03F)

| Offset | Name | Access | Reset Value | Description |
|--------|------|--------|-------------|-------------|
| 0x020 | Released Credits Accumulator | W-add / R-clear | 0 | Receives credit deltas from the paired instance's channel 0. Write adds to current value; read returns value and clears to 0. Generates `released_credits_irq`. Increments pair credit counter. |
| 0x024 | Doorbell Response Accumulator | W-add / R-clear | 0 | Receives doorbell responses from the paired instance's channel 1. Same W-add / R-clear semantics. Generates `doorbell_irq`. |
| 0x028 | Pair Credit Counter | RO | 0 | Running count of credits available on the paired TideLink. Incremented by writes to 0x020; decremented by writes to 0x02C. Read without side effects. |
| 0x02C | Pair Credit Consume | WO | — | Software writes the number of credits being consumed from the pair. Subtracted from pair credit counter at 0x028. |
| 0x030 | Pair Credit Counter Enable | RW | 1 | Bit 0: enable. When 0, the pair credit counter ignores all increments and decrements. |

### 6.3 Returner Target Addresses

The returner derives three target addresses from the Pair Base Address register (0x000):

| Channel | Target | Derived Address |
|---------|--------|-----------------|
| 0 | Pair's Released Credits Accumulator | `pair_base_addr + 0x020` |
| 1 | Pair's Doorbell Response Accumulator | `pair_base_addr + 0x024` |
| 2 | Pair's Doorbell Register | `pair_base_addr + 0x014` |

## 7. Functional Description

### 7.1 Packet Format

A TideLink packet consists of a length word followed by data words:

| Word Index | Content |
|------------|---------|
| 0 (address 0x000) | Packet word length N (number of data words that follow) |
| 1 (address 0x004) | Data word 0 |
| 2 (address 0x008) | Data word 1 |
| ... | ... |
| N (address N×4) | Data word N-1 |

Total FIFO occupancy per packet: N + 1 credits (1 length word + N data words).

### 7.2 FIFO Control Logic

The FIFO uses a circular buffer implemented in SRAM with read and write pointers.

**Metadata capture** (on data phase of AHB transfer to address 0):
- **Write to address 0**: `hwdata` is captured as the packet word length. The write target address is computed as `packet_word_length × 4`. The packet committed IRQ is armed.
- **Read from address 0**: A check flag is set; the read data from SRAM is captured on the next cycle as the packet word length. The read target address is computed as `packet_word_length × 4`.

**Address translation**: The AHB address presented to the SRAM is offset by the current pointer:
```
sram_addr = haddr + (hwrite ? write_ptr : read_ptr)
```

**Completion detection** (gated on `hready`):
```
valid_transfer = hsel & htrans[1] & hready & enable & (packet_word_length != 0)
write_complete = valid_transfer & (haddr == write_target_addr) & hwrite
read_complete  = valid_transfer & (haddr == read_target_addr)  & ~hwrite
```

**Pointer advancement**:
- On `write_complete`: `write_ptr += (packet_word_length + 1) × 4`
- On `read_complete`: `read_ptr += (packet_word_length + 1) × 4`

Pointers wrap naturally at the SRAM boundary (14-bit unsigned arithmetic).

### 7.3 Credit Counting

Each credit represents one 32-bit word of SRAM capacity. The local credit counter tracks available space:

| Event | Credit Change |
|-------|-------------|
| Reset | `credit_count = MAX_CREDITS` |
| Flush | `credit_count = MAX_CREDITS` |
| `write_complete` | `credit_count -= (packet_word_length + 1)` |
| `read_complete` | `credit_count += (packet_word_length + 1)` |

### 7.4 Credit Release Mechanism

When a packet is read from the FIFO, the freed credits must be communicated back to the transmitting chiplet so it can send more data. This is handled by the release threshold accumulator and the returner.

1. On `read_complete`, the delta `(packet_word_length + 1)` is added to the release accumulator.
2. The release trigger fires when `release_acc + pending_delta >= threshold` (or immediately if `threshold == 0`).
3. When the trigger fires, the accumulated delta is registered as `credit_delta_data`, the release accumulator is cleared, and the returner's channel 0 interrupt is asserted.
4. The returner performs an AHB write of `credit_delta_data` to the pair's Released Credits Accumulator (pair_base + 0x020).

**Default threshold**: 20 credits. This batches small reads to reduce bus traffic.

### 7.5 Returner

The returner is a 3-channel priority arbiter with an AHB Lite master interface. It performs single-beat writes when triggered.

| Channel | Priority | Trigger | Target Address | Write Data |
|---------|----------|---------|----------------|------------|
| 0 | Highest | Release trigger | `pair_base + 0x020` | Credit delta (freed credits) |
| 1 | Medium | Doorbell trigger | `pair_base + 0x024` | Total free credits (`credit_count`) |
| 2 | Lowest | Reset deassertion | `pair_base + 0x014` | 0x00000001 |

**State machine**:
```
ST_IDLE ──(any pending)──► ST_ADDR_PHASE
ST_ADDR_PHASE ──(hready)──► ST_DATA_PHASE
ST_DATA_PHASE ──(hready)──► ST_IDLE
```

**Pending registers**: Each channel has a pending latch set on the rising edge of its interrupt input. This ensures that pulse-width interrupts are never lost, even when the returner is busy servicing another channel. When transitioning from IDLE, the highest-priority pending channel is selected and its pending latch is cleared.

### 7.6 Doorbell Mechanism

The doorbell provides a software-initiated request/response handshake between paired TideLink instances.

**Transmit path**: Software writes any value to the Doorbell register (0x014). This generates a one-cycle pulse that triggers returner channel 1. The returner writes the local `credit_count` to the pair's Doorbell Response Accumulator (pair_base + 0x024).

**Receive path**: When the paired instance writes to the local Doorbell Response Accumulator (0x024), the value is added to the accumulator and `doorbell_irq` asserts. Software reads 0x024 to retrieve (and clear) the response.

### 7.7 Reset Handshake

When a TideLink instance comes out of reset, it automatically notifies its pair:

1. `hresetn` deasserts — a two-stage synchroniser detects the rising edge and generates a one-cycle `reset_deassert_pulse`.
2. The pulse triggers returner channel 2, which writes 0x1 to the pair's Doorbell register (pair_base + 0x014).
3. The pair's doorbell fires, causing it to respond with its total free credits via channel 1.
4. The resetting instance receives the response at its Doorbell Response Accumulator (0x024) and asserts `doorbell_irq`.
5. Software reads 0x024 to learn the pair's current credit availability.

This handshake allows a freshly reset chiplet to discover how much buffer space is available on the remote side without software intervention beyond reading the interrupt.

### 7.8 Pair Credit Counter

The pair credit counter (0x028) provides a hardware-maintained running count of credits available on the remote TideLink, avoiding the need for software to track this in a driver variable.

- **Incremented** when the paired instance releases credits (writes to local 0x020)
- **Decremented** when software writes a consume count to 0x02C
- **Disabled** by clearing bit 0 of Pair Credit Counter Enable (0x030)
- **Read** at 0x028 without side effects

Typical usage: before transmitting a packet of size N+1 credits, software checks that `pair_credit_counter >= N+1`, then writes N+1 to 0x02C to reserve the credits.

### 7.9 Block Enable and Flush

**Enable (CTRL bit 0)**: When EN=0 (default after reset), all AHB data window transfers are silently ignored — no pointer, credit, or metadata state changes occur. The APB register interface and AHB master remain functional. Software must set EN=1 before reading or writing packets.

**Flush (CTRL bit 1)**: Self-clearing. Resets:
- Read and write pointers to 0
- Packet word length to 0
- Credit count to MAX_CREDITS
- Release accumulator to 0
- All sticky error flags (overrun, underrun, master_error)

EN must be 0 before writing FLUSH. If EN is 1, the FLUSH write is silently ignored.

### 7.10 Error Handling

| Bit | Flag | Condition | Impact |
|-----|------|-----------|--------|
| 0 | Returner Busy | Returner mid-transfer | Informational (not an error) |
| 1 | Overrun (sticky) | Valid AHB write when `credit_count == 0` | Write data silently discarded; SRAM content may be corrupted |
| 2 | Underrun (sticky) | Valid AHB read when `credit_count == MAX_CREDITS` (buffer empty) | Read returns stale SRAM data |
| 3 | Master Error (sticky) | Returner receives `hresp == 1` during data phase | Credit return or doorbell write lost |
| 4 | Packet Committed | Packet fully written (`write_complete`) | Mirrors `packet_committed_irq`. Cleared when receiver reads FIFO address 0. Pollable alternative to the interrupt. |

Bits 1–3 are sticky — once set, they remain asserted until cleared by FLUSH or hardware reset. Bit 0 (returner_busy) reflects real-time state. Bit 4 (packet_committed) is cleared when the receiver reads FIFO address 0.

**Recovery sequence**:
1. Detect error (poll STATUS register or respond to system-level fault)
2. Write `CTRL.EN = 0` (disable data window)
3. Write `CTRL = 0x02` (FLUSH — self-clearing)
4. Reconfigure as needed (pair base address, threshold, etc.)
5. Write `CTRL.EN = 1` (re-enable data window)

## 8. SRAM Variants

The design supports three SRAM implementations selected at compile time via file list:

| Variant | File | Technology | Notes |
|---------|------|------------|-------|
| FPGA | `fpga/tidelink_sram.sv` | `cmsdk_fpga_sram` | Xilinx block RAM inference |
| Generic | `generic/tidelink_sram.sv` | Register array | Behavioural model for simulation |
| ASIC | `asic/tidelink_sram.sv` | `rf_16k` compiled macro | TSMC 65nm. Active-low CEN/WEN/GWEN. |

All variants expose the same interface: `CS`, `ADDR`, `WDATA`, `WREN[3:0]`, `RDATA`.

## 9. Timing

- All logic is synchronous to `hclk`.
- SRAM reads have a one-cycle latency (address registered, data available next cycle).
- The returner completes a write in 2 clock cycles (address phase + data phase), assuming `hready=1`.
- The release threshold accumulator adds combinational delay on the `read_complete` path for threshold comparison.

## 10. Constraints and Limitations

- Maximum packet size: `MAX_CREDITS - 1` data words (4095 words with default 16 KB SRAM).
- Only one packet may be in-flight (being written or being read) at a time. The next packet's metadata capture at address 0 overwrites the current packet's length.
- The FIFO data window does not generate AHB error responses. Overrun and underrun are indicated only via sticky status flags.
- The returner is write-only and performs only single-beat NONSEQ transfers.
- Credit count width is `RAM_ADDR_W - 1` bits (13 bits for default parameters), limiting MAX_CREDITS to 4096.
- The pair base address must be configured (or the `TIDELINK_PAIR_BASE` parameter set) before the returner can successfully deliver writes.

## 11. System Integration

### 11.1 Paired Deployment

A typical bidirectional link requires two TideLink instances:

```
  Chiplet A                                    Chiplet B
  ┌──────────────┐                            ┌──────────────┐
  │ TideLink TX  │──── AHB Master ──────────► │ TideLink RX  │
  │ (instance A) │◄─── APB regs (credits) ──── │ (instance B) │
  └──────────────┘                            └──────────────┘
  ┌──────────────┐                            ┌──────────────┐
  │ TideLink RX  │◄─── AHB Master ──────────  │ TideLink TX  │
  │ (instance C) │──── APB regs (credits) ───► │ (instance D) │
  └──────────────┘                            └──────────────┘
```

Instance A's `TIDELINK_PAIR_BASE` points to instance B's APB base, and vice versa. Instances C and D form the reverse channel.

### 11.2 AHB Bus Matrix Connection

When using `tidelink_fifo_ahb`, connect:
- `ahbs_*` to the bus matrix as a slave (FIFO data window)
- `ahbc_*` to the bus matrix as a slave (configuration registers)
- `ahbm_*` to the bus matrix as a master (routed to the paired instance's `ahbc_*` slave port)

The AHB master port must have routing access to the paired TideLink's APB register space through the bus interconnect.

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

TideLink uses a two-phase initialisation: first the chiplet controller role must be locked (releasing Wlink from reset), then the FIFO credit exchange completes link bring-up.

#### Phase 1: Chiplet Controller Role Selection

After power-on reset (`poresetn`), the Wlink core is held in reset until the controller role is locked. This allows the CPU to select master or slave mode before the link trains.

```
1. (Optional) Read ROLE_STATUS (0x2084) to check strap default
2. (Optional) Write ROLE_CFG (0x2080) bit[0] to override role (0=master, 1=slave)
3. Write ROLE_CFG (0x2080) bit[1] = 1 to lock the role
   → Wlink POR deasserts, link training begins automatically (swi_enable=1 default)
4. Wait for link-up (~10,000 cycles for GPIO PHY)
```

If no CPU intervention is needed, the role defaults from the `role_strap_i` pin. The CPU just needs to lock it: write `0x02` to `ROLE_CFG`.

The role lock bit is W1S (write-1-to-set) and survives warm reset (`hresetn`). Only a full power-on reset (`poresetn`) can change the role.

**C driver**: Use `tidelink_ctrl_link_bringup()` from `tidelink_chiplet_ctrl.h` for a single-call bring-up.

#### Phase 2: TideLink FIFO Credit Exchange

After the Wlink link is active:

```
1. (Optional) Write pair base address to 0x2000 if different from parameter default
2. (Optional) Write release threshold to 0x2004 (default: 20)
3. Enable pair credit counter: write 1 to 0x2030
4. Ring doorbell: write 1 to 0x2014 (sends initial credits to peer)
5. Wait for doorbell_irq (peer's reset handshake response)
6. Read doorbell response accumulator (0x2024) to get peer's available credits
7. TideLink is now ready for data transfer
```

#### I2C Remote Configuration (Slave Mode)

In slave mode, the remote master can configure Wlink registers via the I2C sideband. The I2C slave address defaults to `0x00` and can be changed by writing `I2C_SLV_ADDR` (0x2088). The local CPU retains read-only APB access to Wlink registers for diagnostics.

#### Routing Around Damaged Lanes (Lane Mask)

The Wlink physical link is striped across `numTxLanes`/`numRxLanes` parallel lanes (8 by default). If one lane is electrically damaged — for example a broken ribbon pin during bring-up — software can disable that lane and continue operating at reduced width by programming the `link_lane_mask` register at Wlink offset `0x214`:

| bits | field | reset (8-lane) | meaning |
|------|-------|----------------|---------|
| [15:0] | `tx_lane_mask` | `0x00FF` | bit[k]=1 enables physical TX lane k |
| [31:16] | `rx_lane_mask` | `0x00FF` | bit[k]=1 enables physical RX lane k |

The link striping width is `popcount(mask) << 1` bytes per cycle (recomputed live in hardware), and the legacy `link_active_lanes` register at offset `0x210` becomes a read-only echo of `popcount(mask) - 1` per direction.

**Programming rules:**
- Both ends of the link **must** program identical masks (or the corresponding cross-side fields, see below). Mismatch produces silent corruption — the hardware does not detect it today.
- Change the mask **with the link disabled** (`link_enable_reset.lltx_enable=0` and `llrx_enable=0`, offset `0x208`) to avoid corrupting in-flight bytes.
- `tx_lane_mask = 0` is rejected by the PYNQ helper but accepted by the hardware; the link will go inert.
- For an asymmetric ribbon fault (e.g. only A→B direction is broken on lane 5), set `A.tx_lane_mask = B.rx_lane_mask` together as one pair, and `B.tx_lane_mask = A.rx_lane_mask` separately. The TX↔RX direction-pair is what must agree, not the local TX/RX pair.

**Bring-up sequence to drop a damaged lane on both boards:**
```
On both boards, with the link disabled:
1. Write 0x00 to link_enable_reset.lltx_enable and llrx_enable (offset 0x208)
2. Write the new mask to link_lane_mask (offset 0x214)
   e.g. mask=0xFB drops lane 2: pack as 0x00FB_00FB
3. Re-enable LL: write the original value back to 0x208
4. Read link_active_lanes (0x210) and confirm both fields show popcount(mask)-1
5. Send a probe packet through TideLink and verify it arrives
```

**Python helper** (PYNQ):
```python
ol.set_lane_mask(0xFB)       # symmetric: same TX and RX
ol.set_lane_mask(0x7F, 0xFF) # asymmetric: drop top TX lane, keep all RX
tx, rx = ol.get_lane_mask()
tx_count, rx_count = ol.get_active_lanes()
ol.assert_link_safe_for_tx() # rejects mask=0 in addition to existing checks
```

See [`pynq/overlay.py`](../pynq/overlay.py) (`set_lane_mask`, `get_lane_mask`, `get_active_lanes`) for the full helper surface, and `pynq/scripts/wlink_probe.sh` for read-only diagnostics that show the active mask in a snapshot.

### Writing a Packet (Transmit Side)

A packet has a 2-word header followed by an optional data payload:

```
 FIFO Address   Content
 ┌───────────┬──────────────────────────────────────────────────────────┐
 │  0x0000   │  length[31:20] | pkt_type[19:18] | src_id[17:13] |      │
 │           │  dest_id[12:8] | tag[7:0]                               │
 ├───────────┼──────────────────────────────────────────────────────────┤
 │  0x0004   │  dest_addr[31:0]                                        │
 ├───────────┼──────────────────────────────────────────────────────────┤
 │  0x0008   │  Payload[0]        (type-specific, see below)            │
 ├───────────┼──────────────────────────────────────────────────────────┤
 │    ...    │  ...                                                    │
 ├───────────┼──────────────────────────────────────────────────────────┤
 │(N+1) × 4 │  Payload[N-1]       ← Final write triggers completion   │
 └───────────┴──────────────────────────────────────────────────────────┘
              ◄──────────────── All words are 32 bits ────────────────►
```

The `length` field (bits [31:20] of Word 0) contains the number of **payload** words only (0–4095). It does not count the 2-word header. The total FIFO occupancy is N + 2 credits (2 header + N payload).

Hardware extracts only the length field — all other fields (`pkt_type`, `src_id`, `dest_id`, `tag`) are opaque to the FIFO and interpreted by receiving software.

**Packet types** (`pkt_type`, bits [19:18]): RD_REQ (0b00), WR_REQ (0b01), RSP (0b10), Reserved (0b11).

**Payload meaning is defined per packet type:**

| Type | N | Payload | Total credits |
|------|---|---------|---------------|
| RD_REQ (single read) | 0 | None — read 1 word at dest_addr | 2 |
| RD_REQ (burst read) | 1 | `beat_count[31:3] \| size[2:0]` | 3 |
| WR_REQ | P | P data words to write at dest_addr | P + 2 |
| RSP (write ack / error) | 0 | None | 2 |
| RSP (read data) | P | P data words from dest_addr | P + 2 |

See `TIDELINK_SPECIFICATION.md` Section 7.1 for full field definitions, and `src/sw/tidelink_packet.h` (C) / `python/tidelink/packet.py` (Python) for software helpers.

To send a packet with N data payload words:

```
1. Check pair credit counter (0x028) >= N + 2, OR
   maintain a software credit counter from released_credits_irq
2. Write packed header to FIFO address 0x000
   (length N in bits [31:20], pkt_type, src_id, dest_id, tag)
3. Write dest_addr to FIFO address 0x004
4. Write data word 0 to FIFO address 0x008  (if N > 0)
5. ...
6. Write data word N-1 to FIFO address (N+1)*4
   → write_complete fires internally
   → packet_committed_irq asserts
7. Write N + 2 to pair credit consume register (0x02C)
   to decrement the pair credit counter
```

The write to the final address ((N+1) × 4) triggers completion — pointers advance and credits are consumed automatically. For a header-only packet (N=0), completion triggers on the write to address 0x0004 (dest_addr).

### Reading a Packet (Receive Side)

To receive a packet:

```
1. Wait for packet_committed_irq, or poll STATUS[4] (packet_committed) until set
2. Read FIFO address 0x000 → returns packed header (extract N from bits [31:20])
   → packet_committed_irq and STATUS[4] clear
3. Read FIFO address 0x004 → dest_addr
4. Read FIFO address 0x008 → data word 0  (if N > 0)
5. ...
6. Read FIFO address (N+1)*4 → data word N-1
   → read_complete fires internally
   → N + 2 credits are freed and release mechanism triggers
```

The read from the final address triggers completion — pointers advance, N + 2 credits are restored, and the release accumulator is incremented.

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
3. Before sending a packet with N payload words (N+2 total):
   a. Read 0x028 and check value >= N + 2
   b. Write N + 2 to 0x02C to reserve (consume) the credits
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

## TideChart Integration

TideLink provides an AXI-Stream interface (`tc_axis_*`) for connecting an external TideChart controller. TideChart handles chiplet-level orchestration protocols; TideLink transports PKT_EXT packets (FC pkt_type=2'b10) between TideChart and the die-to-die link.

### Wiring the TideChart Controller

Connect the `tc_axis_*` ports to your TideChart controller instance:

```verilog
tidelink_top #(...) u_tidelink (
    // ... other ports ...

    // TideChart AXI-Stream TX (TideLink -> TideChart controller)
    .tc_axis_tx_tvalid (tc_tx_tvalid),
    .tc_axis_tx_tdata  (tc_tx_tdata),    // 48-bit FC word
    .tc_axis_tx_tready (tc_tx_tready),

    // TideChart AXI-Stream RX (TideChart controller -> TideLink)
    .tc_axis_rx_tvalid (tc_rx_tvalid),
    .tc_axis_rx_tdata  (tc_rx_tdata),    // 48-bit FC word
    .tc_axis_rx_tready (tc_rx_tready),

    // ...
);
```

If TideChart is not used, tie the RX inputs to inactive:

```verilog
    .tc_axis_rx_tvalid (1'b0),
    .tc_axis_rx_tdata  (48'h0),
```

The TX outputs (`tc_axis_tx_tvalid`, `tc_axis_tx_tdata`) can be left unconnected.

### PKT_EXT Packet Format

PKT_EXT packets use the standard 48-bit FC word layout:

```
[47:46]  pkt_type    = 2'b10 (PKT_EXT)
[45:40]  subtype     (6 bits) — extension protocol identifier
[39:32]  reserved    (8 bits)
[31:0]   payload     (32 bits)
```

The TideChart controller is responsible for interpreting and generating the subtype and payload fields.

### PUF Boot Entropy

TideLink supports reading uninitialized SRAM data as a Physical Unclonable Function (PUF) entropy source. The TideChart controller (or boot firmware) issues PUF_READ_REQ packets to sample the SRAM power-up state before the FIFO is enabled.

**PUF read flow:**

1. TideChart controller sends a PUF_READ_REQ (subtype=0x0020, payload[7:0]=SRAM word address) via `tc_axis_rx_*`.
2. The FC adapter intercepts this packet locally and reads the addressed SRAM word.
3. A PUF_READ_RSP (subtype=0x0021, payload=SRAM data) appears on `tc_axis_tx_*`.

**Important constraints:**

- PUF reads are **local only** — they never cross the die-to-die link and do not consume FC node bandwidth or credits.
- PUF data is only valid before software writes to the SRAM. Once the FIFO is enabled and packets begin flowing, the SRAM contents are overwritten. Run PUF reads before FIFO initialisation (Phase 2 of the bring-up sequence).
- PUF reads have the lowest SRAM arbiter priority. Under heavy traffic they may be delayed, but this is not a concern at boot when the FIFO is idle.

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

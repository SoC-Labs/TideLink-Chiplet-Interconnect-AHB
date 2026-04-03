# TideLink Architecture Notes

## Project context

TideLink is a chiplet interconnect protocol layer developed by SoC Labs
(<https://git.soton.ac.uk/soclabs/tidelink>) that communicates via AHB (AMBA
Advanced High-performance Bus). It targets the megaSoC chiplet ecosystem where a
host chiplet (e.g. Cortex-A class CPU) communicates with device chiplets (e.g.
SRAM chiplets, accelerator chiplets) over a die-to-die link.

The PHY and link layer is provided by **Wlink**
(<https://wlink.readthedocs.io/en/latest/wlink.html>), an open-source
packet-based layered architecture for chiplet communication written in Chisel.
TideLink operates as the **application layer node** for Wlink, converting AHB
transactions into Wlink packets and vice versa.

## The core problem: AHB is a blocking protocol

AHB cannot issue outstanding transactions. A master must receive the response to
its current transaction before issuing the next one. This is particularly
devastating for reads over a chiplet link:

1. Host CPU issues AHB read (address phase).
2. TideLink proxy must hold `HREADY` LOW while the request traverses the link,
   hits the remote slave, and the response traverses back.
3. The entire host AHB bus is stalled for the link round-trip time (RTT).
4. At even modest latencies (e.g. 10 ns link latency at 100 MHz AHB), this
   wastes 20+ cycles per read.

AHB does have SPLIT/RETRY mechanisms, but these are rarely implemented in
Cortex-M peripherals and add significant arbiter complexity.

Writes are less problematic — they can be fire-and-forget with buffering — but
reads are the showstopper.

## Wlink architecture summary

Wlink has three layers:

- **Application layer**: Protocol-specific nodes (AXI, APB, TileLink exist;
  AHB does not yet exist — this is TideLink's role). Each node converts a
  specific protocol into Wlink packets.
- **Link layer**: ECC generation/checking (MIPI CSI/DSI SEC/DED), byte
  striping across lanes, TX/RX routing.
- **PHY layer**: GPIO, SerDes, Bunch-of-Wires, or custom. Configurable lane
  count (up to 256), asymmetric TX/RX supported.

Key Wlink component: **WlinkGenericFCSM** (flow control state machine). Each FC
node is independent — if one stalls, others proceed. It uses credit-based flow
control: each side advertises TX/RX credits (essentially FIFO depth). Data
packetisation and CRC are handled here.

Multiple FC nodes connect to a **WlinkTxRouter** (round-robin mux) and
**WlinkRxRouter** (broadcast to all nodes, future plans for topology-aware
routing).

## Proposed architecture: TideLink as a message-passing mailbox

Rather than attempting transparent AHB bridging (which requires solving the
blocking read problem in hardware), the proposed architecture treats TideLink as
a **packet FIFO / hardware mailbox** with software-mediated transactions.

### Read flow (8 steps)

1. **Host CPU writes request descriptor** into TideLink TX FIFO via
   memory-mapped AHB writes. Descriptor contains: packet type (`RD_REQ`),
   `dest_addr`, `src_id`, `dest_id`, read length, burst type.
2. **Packet traverses Wlink** (TX link layer → PHY → D2D → PHY → RX link
   layer) using credit-based flow control.
3. **Device-side TideLink RX FIFO** receives packet, fires **interrupt** to
   device CPU.
4. **Device CPU pops request descriptor**, parses fields.
5. **Device CPU performs local AHB read(s)** to the target (e.g. SRAM) using
   the address and length from the descriptor.
6. **Device CPU writes response** (read data + status) into device-side
   TideLink TX FIFO as a `RD_RSP` packet with matching `src_id`/tag.
7. **Response traverses Wlink** back to host chiplet.
8. **Host CPU receives interrupt**, pops response data from host-side TideLink
   RX FIFO.

### Write flow (simpler)

1. Host CPU writes descriptor (`WR_REQ`) + data payload into TideLink TX FIFO.
2. Packet traverses link.
3. Device CPU (or hardware engine) pops descriptor, performs local AHB
   write(s).
4. Optional: write acknowledgement sent back as `WR_RSP`.

### Why this works

- **No bus stalling**: Host CPU writes a few words to a local peripheral (the
  TideLink FIFO) and moves on. AHB bus is free immediately.
- **Natural Wlink fit**: TideLink FIFOs map directly to WlinkGenericFCSM
  credits. FIFO depth = credit count.
- **No HREADY nightmare**: TideLink is just a standard AHB slave with a
  register interface. No timing-critical wait-state management.
- **Software flexibility**: Device-side CPU can do address translation, access
  control, scatter-gather, error retry.

### Tradeoffs

- **Latency**: Adds CPU overhead on both sides (ISR entry ~20-50 cycles on
  Cortex-M, descriptor parsing, etc.). Single 32-bit read: ~100-200 cycle
  overhead on top of link RTT. Amortised well for bulk transfers.
- **Requires CPU on device side**: Device chiplet needs at least a small
  Cortex-M0 to service requests (nanoSoC-lite pattern).
- **Interrupt storm risk**: Many small reads → many interrupts. Mitigate with
  batching, polling mode, or interrupt coalescing.

## Proposed packet descriptor format

| Field        | Width     | Purpose                                    |
|--------------|-----------|--------------------------------------------|
| `pkt_type`   | 4 bits    | RD_REQ, WR_REQ, RD_RSP, WR_RSP, ERROR     |
| `src_id`     | 8 bits    | Requester ID (for response routing)        |
| `dest_id`    | 8 bits    | Target chiplet (for multi-hop daisy-chain) |
| `tag`        | 8 bits    | Transaction ID (match RSP to REQ)          |
| `dest_addr`  | 32 bits   | Remote address to access                   |
| `length`     | 16 bits   | Number of beats                            |
| `burst_type` | 2 bits    | SINGLE / INCR / WRAP (mirrors HBURST)      |
| `size`       | 3 bits    | Beat size (mirrors HSIZE)                  |
| `status`     | 2 bits    | OKAY / ERROR (in responses)                |

For write requests, the data payload follows the header words. For read
responses, the data payload follows the header with matching tag and status.

Total header: fits in 3× 32-bit words pushed to the FIFO.

## Two-tier implementation strategy

### Tier 1: Software-mediated (immediate goal)

CPU on each side, interrupt-driven. Maximum flexibility, lowest implementation
effort. Good for:

- Control plane traffic and configuration
- Small/infrequent reads
- Early prototyping and verification

### Tier 2: Hardware request engine (future optimisation)

Small FSM on device chiplet that autonomously services read/write descriptors
without CPU intervention. Essentially a micro-DMA engine programmable via the
descriptor format. Good for:

- Bulk SRAM reads (the primary megaSoC use case)
- Latency-sensitive data plane traffic
- Eliminating ISR overhead on device side

Both tiers use the same packet format and TideLink FIFO infrastructure — the
difference is who pops the descriptor on the device side.

## DMA acceleration path

For bulk transfers, the optimal flow is:

1. Host CPU writes single descriptor: "read 256 bytes starting at 0x20000"
2. Device CPU/engine burst-reads from SRAM, packs into Wlink long packet(s)
3. Host-side TideLink RX FIFO is configured as DMA source
4. Existing SLDMA-230 moves response data from TideLink RX FIFO into host SRAM
5. Single interrupt when complete

## Key modifications needed in TideLink RTL

When reviewing the existing `tidelink.sv`, check and likely modify:

1. **Register interface**: Needs memory-mapped descriptor push/pop registers,
   FIFO status (full/empty/level), interrupt status/enable/clear registers.
2. **FIFO implementation**: Async FIFOs (gray-coded CDC) if AHB clock ≠ Wlink
   clock. Depth should accommodate full burst (8-16 beats) + margin.
3. **Packet header encode/decode**: Hardware packing of descriptor fields into
   Wlink packet headers (or software does this — simpler but slower).
4. **Interrupt generation**: Configurable — on every packet, on threshold, or
   with coalescing timer.
5. **Wlink FC interface**: Connect FIFO signals to WlinkGenericFCSM TX/RX
   interfaces. Use separate FC nodes for request and response channels.
6. **Error handling**: Propagate AHB ERROR responses back through the link.
   Timeout detection for lost packets.

## Alternative considered: AHB → AXI bridge

The SRAM chiplet project uses Arm TLX-400 (part of NIC-450) which converts
AHB to AXI Stream. This eliminates the blocking problem since AXI supports
outstanding transactions natively, and Wlink already has AXI application nodes.

The argument for TideLink doing it directly at AHB level is **cost** — for
small Cortex-M class chiplets, the AXI bridge area overhead may be
unacceptable, and the existing AHB ecosystem (bus matrices, DMA, peripherals)
doesn't warrant the complexity. But both paths should be costed.

## Related SoC Labs resources

- megaSoC reference design: <https://soclabs.org/reference-design/megasoc>
- SRAM chiplet project: <https://soclabs.org/project/sram-chiplet>
- nanoSoC (Cortex-M0 baseline): <https://soclabs.org/project/nanosoc-baseline-cortex-m0-microcontroller-soc-2024-update>
- DMA infrastructure: <https://soclabs.org/project/dma-infrastructure-developments>
- AHB bus matrix generation: <https://soclabs.org/project/building-system-optimised-amba-interconnect>
- Wlink documentation: <https://wlink.readthedocs.io/en/latest/wlink.html>
- S-Link (Wlink predecessor, Verilog): <https://github.com/SLink-Protocol/S-Link>
- Bunch of Wires PHY spec: <https://opencomputeproject.github.io/ODSA-BoW/bow_specification.html>

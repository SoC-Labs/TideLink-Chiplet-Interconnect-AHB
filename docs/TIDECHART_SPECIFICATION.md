# TideChart — Dynamic Chiplet ID Assignment Protocol

**Version**: 0.1
**Date**: 2026-04-06
**Status**: Draft Proposal
**Authors**: David Mapstone (d.a.mapstone@soton.ac.uk), SoC Labs, University of Southampton
**License**: Joint work under Arm Academic Access license
**Copyright**: 2026, SoC Labs (www.soclabs.org)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Design Principles](#3-design-principles)
4. [Terminology](#4-terminology)
5. [Network Model](#5-network-model)
6. [Addressing Modes](#6-addressing-modes)
7. [Protocol Overview](#7-protocol-overview)
8. [Packet Formats](#8-packet-formats)
9. [Enumeration Procedure](#9-enumeration-procedure)
10. [Routing Table Structure](#10-routing-table-structure)
11. [Hot-Plug and Re-Enumeration](#11-hot-plug-and-re-enumeration)
12. [Integration with TideLink](#12-integration-with-tidelink)
13. [Hardware Requirements](#13-hardware-requirements)
14. [Software Driver Interface](#14-software-driver-interface)
15. [Security Considerations](#15-security-considerations)
16. [Prior Art and Rationale](#16-prior-art-and-rationale)
17. [Open Questions](#17-open-questions)

---

## 1. Executive Summary

TideChart is a lightweight protocol for dynamically assigning unique chiplet identifiers in a TideLink network. It solves the bootstrap problem: before any application-level TideLink packets can be routed, every chiplet must know its own identity and how to reach every other chiplet — yet at power-on, no chiplet has an identity and no routing state exists.

TideChart operates in two phases:

1. **Path-addressed bootstrap**: Packets are routed using a hop-by-hop port list that requires zero pre-configuration. This gives a designated root node the ability to reach any chiplet in the network before IDs exist.

2. **Sequential DFS enumeration**: The root walks the tree depth-first, assigning compact logical IDs and programming routing tables at each node.

The protocol requires no pre-assigned unique identifiers (no MAC-address equivalent), assumes a loop-free tree topology, and is designed for direct hardware implementation alongside the existing TideLink FC adapter and sideband mechanism.

The name "TideChart" evokes nautical cartography — mapping uncharted waters so that ships (packets) can navigate reliably.

---

## 2. Problem Statement

### 2.1 The Identity Bootstrap Problem

A TideLink packet header contains a 5-bit `src_id` and a 5-bit `dest_id` (see `tidelink_packet.h`). These endpoint IDs are meaningful only if every node in the network agrees on the mapping from ID to physical chiplet. At power-on, this mapping does not exist.

Unlike Ethernet, where each NIC has a factory-burned MAC address that serves as a stable identity during DHCP, TideLink chiplets have no pre-assigned unique identifier. The PHY link layer (Wlink) assigns a `data_id` to each FC node, but this is a *channel type* identifier (e.g., 0xa1 for TideLink FC), not a *node instance* identifier — every chiplet's TideLink FC has the same `data_id`.

### 2.2 The Routing Problem

In a multi-hop TideLink network (three or more chiplets), intermediate nodes must forward packets. A chiplet receiving a packet destined for `dest_id=5` must know which of its local TideLink ports leads toward chiplet 5. This requires a routing table, which must be populated before traffic can flow.

### 2.3 Requirements

| Requirement | Description |
|---|---|
| **R1** | Assign unique logical IDs to all chiplets with no pre-existing identity |
| **R2** | Populate routing tables for multi-hop forwarding |
| **R3** | Operate over existing TideLink FC sideband mechanism (no new PHY signals) |
| **R4** | Support tree topologies of up to 31 chiplets (5-bit ID space) |
| **R5** | Complete enumeration in bounded time with no deadlocks |
| **R6** | Support re-enumeration after hot-plug events |
| **R7** | Implementable in hardware with minimal gate overhead |

---

## 3. Design Principles

1. **No pre-assigned identity**: Chiplets are blank slates at power-on. Identity comes from topology position, not from fuses or ROM.

2. **Path addressing bootstraps everything**: Before IDs exist, packets carry an explicit list of port hops. Any node can be reached without any pre-configuration.

3. **Single root authority**: One chiplet (typically the host CPU complex) is the enumeration root. It drives the entire discovery process in software. There is no distributed consensus or election.

4. **Depth-first, one-at-a-time**: The root enables and enumerates one neighbour at a time, preventing address collisions. This is the same strategy USB uses.

5. **Separation of concerns**: TideChart handles identity and routing. TideLink handles data transport. The two are layered, not entangled.

---

## 4. Terminology

| Term | Definition |
|---|---|
| **Chiplet** | A single die in the TideLink network, containing one or more TideLink ports |
| **Port** | A single TideLink link interface on a chiplet. Each port connects to exactly one port on another chiplet. Ports are numbered 0..N-1 locally on each chiplet |
| **Port Number** | A small integer (0, 1, 2...) identifying a TideLink port *within* a single chiplet. Port numbers are only locally unique — port 0 on chiplet A is unrelated to port 0 on chiplet B |
| **Logical ID** (or **Chiplet ID**) | A globally unique 5-bit identifier (0–31) assigned by TideChart during enumeration. ID 0 is always the root |
| **Path Address** | An ordered list of port numbers describing a route from the sender to the destination, consumed hop-by-hop |
| **Root** | The chiplet that initiates and drives enumeration. Typically the host CPU complex. Always assigned ID 0 |
| **Leaf** | A chiplet with only one TideLink port (its uplink to the parent) |
| **Branch** | A chiplet with two or more TideLink ports |
| **Uplink Port** | The port on a chiplet that faces toward the root (toward the parent in the tree) |
| **Downlink Port** | A port on a chiplet that faces away from the root (toward a child in the tree) |

---

## 5. Network Model

### 5.1 Topology

TideChart assumes a **loop-free tree topology**. Every pair of chiplets is connected by exactly one path. The root chiplet is the tree root.

```
            ┌─────────┐
            │ Chiplet 0│  ← Root (ID 0)
            │ (Host)   │
            └──┬────┬──┘
         Port 0│    │Port 1
               │    │
        ┌──────┘    └──────┐
        │                  │
   ┌────┴────┐        ┌───┴─────┐
   │Chiplet 1│        │Chiplet 2│
   │(SRAM)   │        │(Accel)  │
   └──┬───┬──┘        └─────────┘
 P0(↑)│   │P1              Leaf
      │   │P2
      │   │
      │   └──────┐
      │          │
 ┌────┴────┐ ┌──┴──────┐
 │Chiplet 3│ │Chiplet 4│
 │(I/O)    │ │(Sensor) │
 └─────────┘ └─────────┘
   Leaf         Leaf
```

In this example:
- Chiplet 0 has 2 ports: port 0 → Chiplet 1, port 1 → Chiplet 2
- Chiplet 1 has 3 ports: port 0 → Chiplet 0 (uplink), port 1 → Chiplet 3, port 2 → Chiplet 4
- Chiplets 2, 3, 4 are leaves with 1 port each (their uplink)

### 5.2 Port Numbering

Each chiplet assigns consecutive integers starting from 0 to its local TideLink ports. The mapping from port number to physical pin/link is fixed at integration time (it is a wiring property, not a runtime property).

Port numbers are **only locally meaningful**. The statement "port 2" is ambiguous without specifying which chiplet. The tuple `(chiplet_id, port_number)` is globally unique.

### 5.3 Assumptions

- The network forms a connected tree (no partitions, no loops).
- All links are bidirectional and symmetric.
- Each TideLink port connects to exactly one remote port.
- A chiplet can have 1 to 8 ports (3-bit port number field).
- The maximum network diameter (longest path in hops) is 7.

---

## 6. Addressing Modes

TideChart defines two addressing modes that coexist:

### 6.1 Path Addressing (Bootstrap Mode)

A path address is an ordered list of port numbers: `[p0, p1, ..., pN]`. The packet is delivered to the node reached by exiting port `p0` on the sender, then port `p1` on the next node, and so on. Each intermediate node consumes (strips) the first entry and forwards the packet out the indicated port.

**Example**: From chiplet 0, the path address `[0, 2]` means: exit port 0 on chiplet 0 (arriving at chiplet 1), then exit port 2 on chiplet 1 (arriving at chiplet 4).

Path addressing requires **no routing tables** and **no node IDs**. It works at power-on with zero configuration. The cost is that the sender must know the physical route a priori, and the packet header grows with path length.

**Encoding**: A path address is packed into a 24-bit field (see §8), supporting up to 8 hops of 3 bits each.

### 6.2 Logical Addressing (Steady-State Mode)

After enumeration, each chiplet has a 5-bit logical ID and a populated routing table. Packets use the existing TideLink `dest_id` field. At each hop, the node looks up `dest_id` in its routing table to determine the egress port.

Logical addressing is compact (5 bits vs up to 24 bits) and sender-agnostic (the sender need not know the physical route), but it requires TideChart enumeration to have completed.

---

## 7. Protocol Overview

TideChart runs in three phases after power-on and link-layer training:

### Phase 0: Link Training (Wlink)

Handled by Wlink, not TideChart. Each point-to-point link undergoes PHY training, lane alignment, and flow-control initialisation. On completion, each TideLink port's FC node is operational and can send/receive 48-bit FC packets.

### Phase 1: Discovery (Path-Addressed)

The root chiplet explores the network topology using path-addressed TideChart packets:

1. Root queries each of its local ports: "Is anyone there? How many ports do you have?"
2. For each responding neighbour, the root recurses depth-first through downstream ports.
3. The result is a complete topology map held in root's memory.

### Phase 2: Enumeration (ID Assignment)

Using the topology map, the root assigns logical IDs and sends them to each chiplet via path-addressed packets:

1. Root assigns itself ID 0.
2. Root sends `ASSIGN_ID(id=1)` to the first discovered chiplet (via its path address).
3. That chiplet stores ID 1 in its TideChart ID register.
4. Continue depth-first until all chiplets have IDs.

### Phase 3: Route Programming

The root computes shortest-path routing tables (trivial in a tree — there is exactly one path between any two nodes) and sends routing entries to each chiplet:

1. For each chiplet C, for each destination D ≠ C, root sends a `PROGRAM_ROUTE(dest_id=D, egress_port=P)` packet to C.
2. Chiplet C stores the entry in its local routing table.
3. Once all tables are programmed, root sends a `GO` packet to each chiplet, enabling logical-address forwarding.

After Phase 3, regular TideLink traffic can flow using logical IDs.

---

## 8. Packet Formats

TideChart packets are carried over the existing TideLink FC sideband mechanism (48-bit FC packets with `pkt_type=SIDEBAND`). A dedicated TideChart register region in the APB address space handles these packets in hardware.

### 8.1 TideChart FC Packet (48 bits)

TideChart reuses the existing FC packet format:

```
[47:46]  pkt_type     = 2'b01 (SIDEBAND)
[45:32]  addr_offset  = TideChart register address (14 bits)
[31:0]   payload      = TideChart command/data (32 bits)
```

TideChart defines a dedicated APB register region (see §12) within the existing TideLink APB space. The `addr_offset` field targets these registers.

### 8.2 TideChart Command Word (32 bits)

The 32-bit payload encodes TideChart commands:

```
[31:28]  opcode       — 4-bit TideChart command type
[27:24]  hop_count    — 4-bit remaining hops (path-addressed packets only)
[23:0]   operand      — 24-bit command-specific data
```

### 8.3 Opcodes

| Opcode | Name | Direction | Operand | Description |
|---|---|---|---|---|
| `0x0` | `DISCOVER_REQ` | Root → Node | Path address (24 bits) | "Who are you? How many ports do you have?" |
| `0x1` | `DISCOVER_RSP` | Node → Root | `[23:21] port_count`, `[20:16] current_id`, `[15:0] device_class` | Response with port count and device class |
| `0x2` | `ASSIGN_ID` | Root → Node | `[23:0] path_address` in header; `[4:0] new_id` written to ID register | Assign a logical ID to the addressed chiplet |
| `0x3` | `ASSIGN_ACK` | Node → Root | `[4:0] assigned_id` | Acknowledgement of ID assignment |
| `0x4` | `PROGRAM_ROUTE` | Root → Node | `[20:16] dest_id`, `[14:12] egress_port`, `[4:0] hop_distance` | Add a routing table entry |
| `0x5` | `ROUTE_ACK` | Node → Root | `[4:0] node_id`, `[20:16] dest_id` | Acknowledgement of route entry |
| `0x6` | `GO` | Root → Node | Reserved | Enable logical-address forwarding |
| `0x7` | `RESET_ENUM` | Root → Node | Reserved | Clear ID and routing table, return to path-address mode |
| `0x8` | `PING` | Any → Any | `[4:0] sender_id`, `[15:8] sequence` | Liveness check (works in both addressing modes) |
| `0x9` | `PONG` | Any → Any | `[4:0] responder_id`, `[15:8] sequence` | Ping response |
| `0xA` | `ANNOUNCE` | Node → Root | `[4:0] node_id`, `[2:0] port` | Hot-plug announcement from intermediate node |
| `0xF` | `ERROR` | Any → Any | `[7:0] error_code` | Error response |

### 8.4 Path Address Encoding

A path address is packed into 24 bits as up to 8 hops of 3 bits each, consumed MSB-first:

```
[23:21]  hop 0 (first hop, consumed first)
[20:18]  hop 1
[17:15]  hop 2
[14:12]  hop 3
[11:9]   hop 4
[8:6]    hop 5
[5:3]    hop 6
[2:0]    hop 7
```

The `hop_count` field in the command word indicates how many hops remain. A node receiving a path-addressed packet:

1. Reads hop 0 (bits `[23:21]`) to determine the egress port
2. Shifts the path left by 3 bits (or equivalently, decrements hop_count and reads the next field)
3. Forwards the packet out the indicated port with `hop_count - 1`

When `hop_count = 0`, the packet has arrived at its destination and is processed locally.

### 8.5 Return Path

For response packets (e.g., `DISCOVER_RSP`, `ASSIGN_ACK`), the node must send a packet back to the root. Two mechanisms are available:

1. **Reverse path**: Each intermediate node records the ingress port when forwarding a path-addressed packet. The response traverses the reverse path. This requires per-node state (a small stack of ingress ports, max depth 7).

2. **Uplink forwarding**: Since the topology is a tree, the path to the root always goes via the uplink port. Each node stores its uplink port number (set during discovery). Responses are always sent out the uplink port; each intermediate node forwards toward root via its own uplink. This requires only one register per node and is the recommended approach.

**Recommended**: Uplink forwarding (option 2). Each node stores one register: `uplink_port`. All root-bound packets exit via `uplink_port`. This is trivially correct in a tree.

---

## 9. Enumeration Procedure

### 9.1 Preconditions

- All point-to-point Wlink links have completed PHY training.
- The root chiplet's firmware is executing.
- All chiplets are in **unenumerated** state: ID register = `0x1F` (invalid), routing table empty, forwarding disabled.

### 9.2 Root Initialisation

```
root.id = 0
root.uplink_port = NONE  (root has no parent)
next_id = 1
topology_map = empty
```

### 9.3 Discovery Walk (Recursive DFS)

The root executes the following procedure, starting with itself:

```
function discover(path_to_node, port_count):
    for port_num in 0..port_count-1:
        if port_num == uplink_port_of(path_to_node):
            continue  // don't walk back toward root

        child_path = append(path_to_node, port_num)

        // Send DISCOVER_REQ via path address
        send_tidechart(DISCOVER_REQ, path=child_path)
        response = wait_for(DISCOVER_RSP, timeout=ENUM_TIMEOUT)

        if response == timeout:
            // No chiplet on this port (or link down)
            mark_port_as_empty(path_to_node, port_num)
            continue

        child_port_count = response.port_count
        child_device_class = response.device_class

        // Assign ID
        send_tidechart(ASSIGN_ID, path=child_path, new_id=next_id)
        wait_for(ASSIGN_ACK)

        topology_map.add(next_id, child_path, child_port_count, child_device_class)
        next_id++

        // Recurse into child's downstream ports
        if child_port_count > 1:
            discover(child_path, child_port_count)
```

### 9.4 Handling the Uplink Port

When a chiplet receives a `DISCOVER_REQ`, it arrives on a specific port. That port is the **uplink port** (the direction toward root). The chiplet records this:

```
on receive DISCOVER_REQ on port P:
    my.uplink_port = P
    respond with DISCOVER_RSP(port_count=my.total_ports, device_class=my.class)
```

This means the root does not need to know which port is the uplink — the chiplet infers it from the direction the discovery packet arrived.

### 9.5 Worked Example

Using the topology from §5.1:

```
Step 1: Root (chiplet 0, ID=0) has 2 ports: [0, 1]
        Discover port 0 → send DISCOVER_REQ path=[0]
        Chiplet 1 responds: port_count=3, class=SRAM
        Assign ID 1 to chiplet 1 (path=[0])

Step 2: Recurse into chiplet 1's ports: [0, 1, 2]
        Port 0 is chiplet 1's uplink (where DISCOVER_REQ arrived) → skip

Step 3: Discover chiplet 1 port 1 → send DISCOVER_REQ path=[0, 1]
        Chiplet 3 responds: port_count=1, class=IO
        Assign ID 2 to chiplet 3 (path=[0, 1])
        Chiplet 3 is a leaf (port_count=1, and port 0 is uplink) → no recursion

Step 4: Discover chiplet 1 port 2 → send DISCOVER_REQ path=[0, 2]
        Chiplet 4 responds: port_count=1, class=SENSOR
        Assign ID 3 to chiplet 4 (path=[0, 2])
        Leaf → no recursion

Step 5: Back to root, discover port 1 → send DISCOVER_REQ path=[1]
        Chiplet 2 responds: port_count=1, class=ACCEL
        Assign ID 4 to chiplet 2 (path=[1])
        Leaf → no recursion

Result: Topology map at root:
  ID 0: Root     — ports: [0→ID1, 1→ID4]
  ID 1: SRAM     — ports: [0→uplink, 1→ID2, 2→ID3]
  ID 2: IO       — ports: [0→uplink]
  ID 3: SENSOR   — ports: [0→uplink]
  ID 4: ACCEL    — ports: [0→uplink]
```

### 9.6 Route Computation

In a tree, the route from any node A to any node B is unique: go up from A to the lowest common ancestor, then down to B. The root computes this for every (source, destination) pair and extracts the egress port at each hop.

For each chiplet C, the routing table maps: `dest_id → egress_port`

**Example routing table for chiplet 1 (ID 1):**

| dest_id | egress_port | Note |
|---|---|---|
| 0 | 0 | Root is via uplink (port 0) |
| 2 | 1 | IO is on port 1 |
| 3 | 2 | Sensor is on port 2 |
| 4 | 0 | Accel is via uplink → root → port 1 |

### 9.7 Route Programming

```
for each chiplet C in topology_map:
    for each dest_id D where D != C.id:
        egress = compute_egress_port(C, D)
        distance = compute_hop_distance(C, D)
        send_tidechart(PROGRAM_ROUTE, dest=C, dest_id=D, egress_port=egress, hop_distance=distance)
        wait_for(ROUTE_ACK)

for each chiplet C in topology_map:
    send_tidechart(GO, dest=C)
```

### 9.8 Timing

Discovery is sequential (one port at a time to avoid ambiguity). For a network of N chiplets, each with at most P ports:

- Discovery: N × (DISCOVER_REQ + RSP + ASSIGN_ID + ACK) = 4N FC round-trips
- Route programming: N × (N-1) PROGRAM_ROUTE packets + N GO packets
- Total FC packets: ~N² + 5N

At 100 MHz with ~10-cycle FC round-trip per packet, a 31-chiplet network completes enumeration in under 100 µs. This is a one-time startup cost.

---

## 10. Routing Table Structure

### 10.1 Per-Chiplet Hardware

Each chiplet that participates in multi-hop forwarding (i.e., branch nodes with >1 port) requires:

| Resource | Size | Description |
|---|---|---|
| **ID Register** | 5 bits | This chiplet's assigned logical ID |
| **Uplink Port Register** | 3 bits | Port number facing toward root |
| **Port Count Register** | 3 bits | Number of TideLink ports on this chiplet (read-only, set at integration time) |
| **Device Class Register** | 16 bits | Application-defined device type (read-only, set at integration time) |
| **Routing Table** | 31 entries × 3 bits | Maps dest_id → egress_port |
| **Forwarding Enable** | 1 bit | Set by `GO`, cleared by `RESET_ENUM` |
| **Enumeration State** | 2 bits | `UNENUMERATED`, `DISCOVERED`, `ASSIGNED`, `ACTIVE` |

### 10.2 Routing Table Lookup

On receiving a TideLink packet with `dest_id ≠ my_id`:

```
if forwarding_enable == 0:
    drop packet (or buffer until GO)
egress_port = routing_table[dest_id]
forward packet out egress_port
```

For leaf nodes (only one port), no routing table is needed — all non-local traffic goes out the single port (uplink). The hardware can optimise this case.

### 10.3 Memory Cost

- Routing table: 31 × 3 bits = 93 bits ≈ 12 bytes per chiplet
- Registers: ~30 bits
- Total per chiplet: < 16 bytes of configuration state

This is negligible compared to the 16 KB FIFO already present.

---

## 11. Hot-Plug and Re-Enumeration

### 11.1 Link-Down Detection

When a Wlink link goes down (cable removed, chiplet powered off), the local Wlink PHY detects loss of signal and asserts a link-down interrupt.

### 11.2 Partial Re-Enumeration

If a leaf node is removed, the parent chiplet:
1. Sends an `ANNOUNCE` packet to the root (via uplink forwarding) indicating the port and event type.
2. The root invalidates the removed chiplet's ID and routing entries.
3. The root re-programs routing tables for all affected nodes (only nodes that had routes through the removed link).

If a branch node is removed, all chiplets in the removed subtree are invalidated. The root may re-enumerate the entire network or just the affected subtree.

### 11.3 New Device Attachment

When a new Wlink link completes training on a port that was previously empty:
1. The parent chiplet sends an `ANNOUNCE` packet to root.
2. The root sends `DISCOVER_REQ` down the new port's path address.
3. The new chiplet is assigned the next available ID.
4. Routing tables are updated incrementally.

### 11.4 Full Re-Enumeration

The root can broadcast `RESET_ENUM` to all chiplets (using logical addresses if still valid, or path addresses as fallback), forcing a return to unenumerated state, then repeat the full Phase 1–3 procedure. This is the simplest recovery mechanism and is recommended for early implementations.

---

## 12. Integration with TideLink

### 12.1 FC Adapter Changes

The existing FC adapter (`tidelink_fc_adapter.sv`) routes sideband packets to APB registers. TideChart packets are sideband packets targeting a new TideChart register region.

**New APB register region** (suggested base offset `0x040` in the TideLink APB space):

| Offset | Name | R/W | Description |
|---|---|---|---|
| `0x040` | `TC_ID` | R/W | `[4:0]` Assigned chiplet ID. Reset value: `0x1F` (unenumerated) |
| `0x044` | `TC_UPLINK` | R/W | `[2:0]` Uplink port number. `[7]` Valid flag |
| `0x048` | `TC_PORT_COUNT` | RO | `[2:0]` Number of TideLink ports (integration constant) |
| `0x04C` | `TC_DEVICE_CLASS` | RO | `[15:0]` Device class (integration constant) |
| `0x050` | `TC_STATE` | R/W | `[1:0]` Enumeration state: 0=UNENUMERATED, 1=DISCOVERED, 2=ASSIGNED, 3=ACTIVE |
| `0x054` | `TC_FWD_EN` | R/W | `[0]` Forwarding enable. Set by GO, cleared by RESET_ENUM |
| `0x058` | `TC_CMD` | WO | Write a TideChart command word (triggers TX) |
| `0x05C` | `TC_CMD_STATUS` | RO | `[0]` CMD busy, `[1]` last CMD error |
| `0x060` | `TC_RT_ADDR` | R/W | `[4:0]` Routing table write address (dest_id) |
| `0x064` | `TC_RT_DATA` | R/W | `[2:0]` Routing table write data (egress_port), `[7:4]` hop_distance |
| `0x068` | `TC_RT_WEN` | WO | `[0]` Write-strobe: commit RT_ADDR/RT_DATA to routing table |
| `0x06C` | `TC_PATH_FWD` | R/W | `[23:0]` Path address for forwarding, `[27:24]` hop_count |
| `0x070` | `TC_RX_CMD` | RO | `[31:0]` Last received TideChart command word |
| `0x074` | `TC_RX_STATUS` | R/W1C | `[0]` RX command pending (IRQ source) |
| `0x078` | `TC_ANNOUNCE` | RO | `[2:0]` Port, `[7:4]` event type — hot-plug announcement |
| `0x07C` | `TC_ANNOUNCE_STATUS` | R/W1C | `[0]` Announcement pending (IRQ source) |

### 12.2 Path-Address Forwarding Hardware

A small hardware block sits between the FC RX path and the existing sideband/FIFO demux:

```
         FC RX (48-bit)
              │
              ▼
     ┌────────────────┐
     │  TideChart      │
     │  Path Forwarder │
     │                 │
     │  if SIDEBAND &&  │
     │  addr ∈ TC range │
     │  && hop_count>0: │
     │    strip hop     │──► FC TX (next port)
     │    forward        │
     │                   │
     │  else:            │
     │    deliver locally │──► APB / FIFO (existing path)
     └──────────────────┘
```

This block is ~50-100 gates and operates in a single cycle. It examines incoming sideband packets:

- If the packet targets the TideChart register region **and** `hop_count > 0`, it is a path-addressed transit packet. The forwarder reads hop 0, determines the egress port, shifts the path, decrements hop_count, and re-injects the packet into the FC TX path of the indicated port.
- If `hop_count == 0` or the packet does not target TideChart registers, it is delivered locally through the existing sideband path.

### 12.3 Multi-Port Arbitration

A chiplet with N TideLink ports has N instances of `tidelink_top` (one per port). The TideChart path forwarder must be able to route between these instances. This requires a small **crossbar or bus** connecting the FC TX/RX paths of all local ports:

```
    Port 0              Port 1              Port 2
  tidelink_top        tidelink_top        tidelink_top
   FC TX/RX            FC TX/RX            FC TX/RX
       │                   │                   │
       └───────┬───────────┼───────────────────┘
               │           │
          ┌────┴───────────┴────┐
          │  TideChart Crossbar  │
          │  (path-address       │
          │   forwarding +       │
          │   routing table      │
          │   lookup)            │
          └──────────────────────┘
```

This crossbar is shared and handles only TideChart management packets and forwarded TideLink data packets. It is low bandwidth (enumeration packets are infrequent; steady-state forwarding is one lookup per transit packet).

### 12.4 Backward Compatibility

Chiplets that do not implement TideChart (e.g., legacy single-link designs) continue to work in point-to-point configurations. The TideChart register region is simply absent, and the 5-bit `src_id`/`dest_id` fields in TideLink packets can be statically configured via APB as they are today.

---

## 13. Hardware Requirements

### 13.1 Per-Port Additions

| Block | Size Estimate | Description |
|---|---|---|
| Path forwarder | ~100 gates | Hop-strip, port-select, re-inject |
| TideChart APB registers | ~200 FFs | ID, uplink, state, RT address/data |
| Routing table | 31×3-bit SRAM or FFs | 93 bits |

### 13.2 Per-Chiplet Additions

| Block | Size Estimate | Description |
|---|---|---|
| TideChart crossbar | ~500 gates (for 4 ports) | FC packet mux between ports |
| Uplink forwarding logic | ~50 gates | Root-bound packet steering |

### 13.3 Total Overhead

For a 2-port chiplet: approximately 500 gates and 250 FFs — well under 1% of a Cortex-M0 core area.

---

## 14. Software Driver Interface

### 14.1 Root-Side Driver

The root chiplet runs the TideChart enumeration algorithm in firmware. The driver interface:

```c
/* Initialise TideChart on the root chiplet */
void tidechart_init(void);

/* Discover and enumerate all reachable chiplets.
   Returns the number of chiplets found (including root). */
uint32_t tidechart_enumerate(void);

/* Get the topology map (filled by enumerate) */
const tidechart_node_t* tidechart_get_topology(void);

/* Re-enumerate the entire network */
uint32_t tidechart_reenumerate(void);

/* Query a specific chiplet's status */
tidechart_status_t tidechart_ping(uint8_t chiplet_id);

/* Node descriptor returned by topology query */
typedef struct {
    uint8_t  id;             /* Assigned logical ID */
    uint8_t  port_count;     /* Number of TideLink ports */
    uint16_t device_class;   /* Application-defined type */
    uint8_t  parent_id;      /* Parent chiplet ID (0xFF for root) */
    uint8_t  parent_port;    /* Port on parent that connects to this node */
    uint8_t  path_hops;      /* Number of hops from root */
    uint32_t path_address;   /* Packed path address from root */
} tidechart_node_t;
```

### 14.2 Node-Side (All Chiplets)

Most TideChart operations are handled in hardware (path forwarding, routing table lookup). Firmware on non-root chiplets only needs to:

1. Read `TC_ID` to learn its assigned identity.
2. Optionally register an IRQ handler for `TC_ANNOUNCE_STATUS` (hot-plug events).
3. Use `TC_ID` as the `src_id` when constructing TideLink packets.

```c
/* Get this chiplet's assigned TideChart ID */
uint8_t tidechart_get_id(void);

/* Check if enumeration is complete */
bool tidechart_is_active(void);

/* Register hot-plug callback */
void tidechart_on_hotplug(void (*cb)(uint8_t port, uint8_t event));
```

---

## 15. Security Considerations

### 15.1 Trust Model

TideChart assumes all chiplets in the network are trusted. There is no authentication of DISCOVER_RSP or ASSIGN_ACK packets. A malicious chiplet could:
- Claim an arbitrary port count, causing the root to discover phantom nodes.
- Ignore its assigned ID and spoof traffic with another chiplet's ID.

For the target use case (a single multi-chiplet package or a small rack of trusted boards), this is acceptable. If untrusted chiplets must be supported in future, TideChart could be extended with a challenge-response authentication layer using shared secrets or a PKI.

### 15.2 Denial of Service

A chiplet that never responds to `DISCOVER_REQ` causes enumeration to time out on that port. The root skips it and continues. A chiplet that floods the network with TideChart packets could congest the FC path; rate-limiting on the TideChart register write interface mitigates this.

---

## 16. Prior Art and Rationale

TideChart draws from several existing protocols:

| Protocol | Borrowed Concept | Adaptation for TideChart |
|---|---|---|
| **USB enumeration** | Sequential DFS walk; one device at a time; no pre-assigned IDs | Same strategy, but using path addresses instead of hub port enable for isolation |
| **PCIe BDF** | Depth-first bus numbering; bridges define downstream ranges | Flat ID space instead of hierarchical Bus/Device/Function |
| **SpaceWire** | Path addressing for bootstrap; logical addressing for steady state | Direct inspiration for the two-phase addressing model |
| **HDMI CEC** | Topology-derived addresses | Rejected: hierarchical addresses waste bits and complicate routing |
| **ZigBee tree addressing** | Distributed address block allocation | Rejected: centralised (root-driven) is simpler and avoids coordination |
| **DHCP** | Dynamic address assignment with a central authority | Inspiration for the "lease" model, but TideChart has no lease expiry — IDs persist until RESET_ENUM |

### 16.1 Why Not Distributed?

A distributed protocol (each node picks its own ID, resolves conflicts) would eliminate the single-root bottleneck. However:
- Conflict resolution in hardware is complex and hard to verify.
- The tree topology guarantees the root can reach everyone — there is no need for distributed agreement.
- Enumeration is a one-time startup cost; simplicity and correctness outweigh throughput.

### 16.2 Why Not Topology-Based Addresses?

HDMI CEC–style addresses (e.g., `2.1.0.0`) encode the path directly. While elegant, they:
- Require wider address fields (3 bits per level × max depth).
- Change if the topology changes (adding a switch re-addresses everything downstream).
- Complicate routing table lookups (must parse hierarchical address at each hop).

Flat 5-bit IDs with explicit routing tables are more compact and flexible.

---

## 17. Open Questions

1. **ID space width**: 5 bits (32 chiplets) matches the current TideLink `src_id`/`dest_id` fields. Is this sufficient for all foreseeable deployments? Extending to 8 bits would support 256 chiplets but requires widening the packet header.

2. **Device class taxonomy**: What classes should be defined? Suggested starting set:
   - `0x0000`: Generic / unknown
   - `0x0001`: Host CPU complex
   - `0x0002`: SRAM / memory
   - `0x0003`: Accelerator
   - `0x0004`: I/O controller
   - `0x0005`: Sensor / ADC
   - `0x0006`: Network bridge

3. **Multicast / broadcast**: TideChart currently assigns unicast IDs only. Should a broadcast ID (e.g., `0x1F`) be reserved for network-wide announcements?

4. **Fragmented re-enumeration**: When a subtree is removed, should its IDs be recycled, or should the root maintain a monotonically increasing ID counter (simpler but wastes IDs)?

5. **Multiple roots**: Could two host chiplets coordinate as redundant roots for fault tolerance? This would require a root-election protocol, significantly increasing complexity.

6. **Loop detection**: TideChart currently assumes loop-free topology. If loops are possible in future, a spanning-tree protocol would need to run before enumeration.

---

*End of specification.*

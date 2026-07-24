# TideLink Chiplet Interconnect Subsystem — Specification and Design Justification

**Version**: 1.2
**Date**: 2026-04-05
**Status**: Draft — based on RTL in `src/rtl/tidelink_top.sv` and `src/rtl/tidelink_fc_adapter.sv`
**Authors**: David Mapstone (d.a.mapstone@soton.ac.uk), SoC Labs, University of Southampton
**License**: Joint work under Arm Academic Access license
**Copyright**: 2026, SoC Labs (www.soclabs.org)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Introduction and Motivation](#2-introduction-and-motivation)
3. [Architecture Overview](#3-architecture-overview)
4. [Component Descriptions](#4-component-descriptions)
5. [Interface Specification](#5-interface-specification)
6. [Configuration Parameters](#6-configuration-parameters)
7. [Data Flow and Protocol](#7-data-flow-and-protocol)
8. [Clocking and Reset Strategy](#8-clocking-and-reset-strategy)
9. [Design Justification](#9-design-justification)
10. [Integration Guide](#10-integration-guide)
11. [Constraints and Limitations](#11-constraints-and-limitations)

---

## 1. Executive Summary

TideLink is a chiplet interconnect application-layer subsystem developed by SoC Labs at the University of Southampton. It provides a complete, self-contained hardware module (`tidelink_top`) that connects an AMBA AHB SoC fabric to a die-to-die serial link, enabling reliable chiplet-to-chiplet communication for Cortex-M class systems.

The subsystem solves two complementary communication problems in a single integration point:

- **Transparent AHB bridging**: A CPU or DMA engine on one chiplet can issue AHB transactions that are transparently forwarded over the link and executed on the remote chiplet's bus fabric. This path uses the XHB500 AHB-to-AXI bridge, the AXI chiplet controller (Wlink), and an APB-configurable address translator.

- **Mailbox-style packet transfer**: A dedicated Wlink flow-control (FC) node bypasses the AXI bridging path entirely, carrying application-defined packets directly between paired software-managed FIFOs. This path is optimised for bulk data movement and is immune to the AHB blocking-bus problem that makes transparent read bridging impractical for long-latency links.

The two paths share a single die-to-die PHY and are independently flow-controlled, so mailbox traffic cannot starve or be starved by transparent AHB traffic.

The reference integration target is the SoC Labs nanosoc-chiplet-tech project (Cortex-M0 based).

---

## 2. Introduction and Motivation

### 2.1 The Chiplet Communication Problem

In the SoC Labs megaSoC ecosystem, a host chiplet (CPU complex) communicates with device chiplets (SRAM, accelerators, I/O) over a serial D2D link provided by Wlink. Both sides speak AMBA AHB, but AHB was designed for on-chip, nanosecond latencies. Extending it transparently across a chiplet link exposes two problems.

### 2.2 The AHB Blocking-Bus Problem

AHB is a blocking protocol: a manager must receive the current response before issuing the next transaction. For reads over a chiplet link, `HREADY` must be held low for the full round-trip — at 10 ns one-way latency and 100 MHz AHB, that is at least 20 frozen bus cycles per read, and the entire host bus stalls throughout. AHB SPLIT/RETRY can in principle release the bus during a long-latency response, but Cortex-M bus matrices do not implement these mechanisms, making them impractical.

### 2.3 The TideLink Solution: A Two-Path Architecture

TideLink provides two complementary paths:

**Path 1 — Transparent AHB bridge**: XHB500 (AHB→AXI) + Wlink AXI controller + XHB500 (AXI→AHB), with an APB-configurable address translator. AXI natively supports outstanding transactions. This path is used for infrequent control-plane writes and reads where latency is tolerable.

**Path 2 — Mailbox / packet FIFO**: A dedicated Wlink FC node carries software-constructed descriptor packets directly between paired FIFOs. The CPU writes a handful of words to the TX aperture and is immediately free — the bus is never held waiting for a remote response. This path is used for bulk and latency-sensitive data movement.

Both paths share one die-to-die PHY and are independently flow-controlled.

### 2.4 Relationship to Wlink

Wlink is a layered chiplet communication stack: application layer (protocol-specific FC nodes), link layer (flow control, ECC, byte striping), and a configurable PHY (up to 256 asymmetric lanes). Wlink natively provides AXI, APB, and TileLink application nodes; AHB is not supported natively. TideLink's mailbox path adds a new application node (WlinkGenericFCSM_6, data_id=0xa1) to carry FIFO words, and provides the FC adapter RTL that drives it. The transparent bridge path uses the existing AXI nodes unchanged.

---

## 3. Architecture Overview

### 3.1 Block Diagram

```
                        TideLink Top (tidelink_top.sv)
 ┌────────────────────────────────────────────────────────────────────────┐
 │                                                                        │
 │  AHB Subordinate 1: Regular AHB access to remote side                 │
 │  ahb_sub_* ──► tidelink_addr_translator ──► XHB500 AHB→AXI ──────────┐│
 │                (APB-configurable address        bridge               ││
 │                 remapping)                  xhb500_ahb_to_axi        ││
 │                                                                      ││
 │  AHB Subordinate 2: TideLink TX aperture                             ││
 │  ahb_tx_* ──────────────────────────────────────────────────────┐   ││
 │                                                                  ▼   ││
 │                                             tidelink_fc_adapter      ││
 │                                             tidelink_fc_adapter       ││
 │                                             (AHB ↔ FC node)          ││
 │                                              ┌─ fc_rx_fifo_* (int.)  ││
 │                                              │  (FIFO_DATA writes)   ││
 │                                    FC RX ────┤                       ││
 │                                              │  fc_rx_cfg_* (int.)   ││
 │                                              └─ (SIDEBAND writes)    ││
 │                                                   │           │      ││
 │  AHB Subordinate: Local RX FIFO                   │           │      ││
 │  ahb_fifo_* ──► FIFO Mux (2:1) ◄─────────────────┘           │      ││
 │                      │                                        │      ││
 │  APB config regs (via unified apb_* port)                      │      ││
 │  apb_*     ──► Config Mux (2:1) ◄───────────────────────────┘      ││
 │                      │                                               ││
 │                      ▼                                               ││
 │               tidelink_fifo_ahb                                      ││
 │               (RX FIFO + APB regs + returner)                        ││
 │                      │ returner AHB master (intercepted)             ││
 │                      └──────────────► FC adapter rtn slave ──────┐   ││
 │                                                                  │   ││
 │  ┌───────────────────────────────────────────────────────────────┘   ││
 │  │                 tidelink_chiplet_controller (modified Wlink)       ││
 │  │  FC Node (TideLink, data_id=0xa1, 48-bit) ◄──────────────────────┘│
 │  │    Short pkt IDs: 0x44–0x47 (CR, CRACK, ACK, NACK)                │
 │  │    Data ID: 0xa1, packed as 50-bit tidelink_in/tidelink_out        │
 │  │  FC Nodes (AXI: 0x80–0x84, General: 0xa0)  s_axi ◄───────────────┘│
 │  │                                             m_axi ─────────────────┐
 │  │  WlinkTxRouter (7 inputs)                                          │
 │  │  WlinkRxRouter (8 outputs)                                         │
 │  │  Link layer: ECC, CRC, byte striping                               │
 │  │  PHY: pad_clk_tx/rx, pad_tx[7:0], pad_rx[7:0]                     │
 │  └────────────────────────────────────────────────────────────────────┘
 │                                                                        │
 │  AHB Manager: Incoming from remote (XHB500 AXI→AHB)                   │
 │  m_axi ──► xhb500_axi_to_ahb ──► ahb_mng_*                            │
 │                                                                        │
 │  AXI-Stream TideChart Interface (PKT_EXT forwarding)                   │
 │  tc_axis_tx_tvalid/tdata/tready ──► To TideChart controller            │
 │  tc_axis_rx_tvalid/tdata/tready ◄── From TideChart controller          │
 │                                                                        │
 │  AHB Subordinate: Address translator config  ahb_adr_*                 │
 │  APB Subordinate: Unified config port  apb_* (Wlink + TideLink)        │
 │  I2C Sideband: i2c_scl/sda                                             │
 │  Interrupts: released_credits_irq, doorbell_irq,                       │
 │              packet_committed_irq, wlink_irq                           │
 └────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Hierarchical Organisation

The `tidelink_top` module instantiates six sub-components:

| Instance | Module | Role |
|---|---|---|
| `u_tidelink_fifo` | `tidelink_fifo_ahb` | RX FIFO packet buffer, APB config registers, credit returner |
| `u_fc_adapter` | `tidelink_fc_adapter` | AHB TX aperture, returner interception, FC RX to AHB master |
| `u_xhb_sub` | `xhb500_ahb_to_axi_bridge_chiplet_slv` | AHB → AXI for regular subordinate path |
| `u_xhb_mng` | `xhb500_axi_to_ahb_bridge_chiplet_mst` | AXI → AHB for regular manager path |
| `u_addr_translator` | `tidelink_addr_translator` | APB-configurable address remapping |
| `u_chiplet_controller` | `axi_chiplet_controller` | Generic chiplet controller: Wlink core + I2C master/slave + role selection + APB mux |

### 3.3 Internal AXI Bus

The XHB500 bridges and the chiplet controller are interconnected by two full AXI4 buses:

- **`s_axi_*`**: Subordinate path — XHB500 AHB→AXI bridge to chiplet controller AXI slave port. Carries outbound AHB transactions from `ahb_sub_*` toward the remote chiplet. AXI ID width 12 bits, address width 36 bits (upper 4 bits tied to zero), data width 32 bits.
- **`m_axi_*`**: Manager path — chiplet controller AXI master port to XHB500 AXI→AHB bridge. Carries inbound transactions from the remote chiplet toward `ahb_mng_*`.

### 3.4 Internal FC Wiring

The TideLink FC node application interface is connected entirely within `tidelink_top`:

```
tidelink_fc_adapter  ──tl_fc_a2l_valid/data/ready──►  tidelink_chiplet_controller
tidelink_fc_adapter  ◄─tl_fc_l2a_valid/data/accept──  tidelink_chiplet_controller
```

### 3.5 Returner Interception

The `tidelink_fifo_ahb` instance's AHB master (the returner) is not connected to the external AHB bus. Instead, its signals (`rtn_haddr`, `rtn_hwdata`, `rtn_htrans`, `rtn_hsize`, `rtn_hwrite`, `rtn_hready`, `rtn_hresp`, `rtn_hrdata`) are wired to the returner-interception slave port of `tidelink_fc_adapter`. The adapter presents a compliant AHB slave interface to the returner, captures its writes, and re-encodes them as SIDEBAND FC packets transmitted over the TideLink FC node.

### 3.6 Internal AHB Muxes

The FC adapter RX path uses two internal AHB master ports (`fc_rx_fifo_*` and `fc_rx_cfg_*`) rather than a single external AHB master. These internal masters are multiplexed with the external CPU-facing slave ports before reaching `tidelink_fifo_ahb`:

**FIFO Mux** (`fifo_mux_*`): Arbitrates access to the FIFO data window slave port of `tidelink_fifo_ahb` between:
- `fc_rx_fifo_*` — FC adapter RX FIFO master (writes incoming FIFO_DATA packets)
- `ahb_fifo_*` — External CPU port (reads received packets)

The FC adapter has priority (`fc_rx_fifo_active = fc_rx_fifo_htrans[1]`). When the FC adapter is active, `ahb_fifo_hreadyout` is driven low, stalling any concurrent CPU access.

**Config Mux** (`cfg_mux_*`): Arbitrates access to the APB config register slave port of `tidelink_fifo_ahb` between:
- `fc_rx_cfg_*` — FC adapter RX config master (writes incoming SIDEBAND packets: credit deltas, doorbells)
- `apb_*` — External CPU port (reads/writes config registers, unified APB)

The FC adapter has priority (`fc_rx_cfg_active = fc_rx_cfg_htrans[1]`). When the FC adapter is active, the config path stalls any concurrent CPU config access.

Both muxes are purely combinational and located in `tidelink_top`. There is no external `ahb_fc_rx_*` AHB master port -- all FC adapter RX traffic is routed internally through these muxes.

### 3.7 Traffic Plane Model

TideLink traffic separates into four planes, distinguished by **which FC node / `data_id` carries it across the link** and **which local interface sources it**. The planes are independently flow-controlled and, in the case of the time plane, ride a physically separate FC node so that timing traffic cannot be backpressured by bulk data.

| Plane | Local interface (chip-internal) | Link carrier (chip-to-chip) | `data_id` |
|---|---|---|---|
| **Data** | `ahb_sub_*` (remote mem access, addr-translated), `ahb_tx_*` (TX aperture), `ahb_fifo_*` (local RX FIFO read), `ahb_mng_*` (return path), `tc_axis_*` (TideChart `PKT_EXT`) | TideLink FC node (mailbox) + AXI FC nodes (transparent bridge via XHB500) | **0xa1** (TideLink, `PKT_FIFO_DATA`/`PKT_EXT`, 48-bit); **0x80–0x84** (AXI AW/W/B/AR/R) |
| **Control** | Returner logic + `fc_adapter` (credit return, doorbell); link bring-up FSM | `PKT_SIDEBAND` words on the TideLink node (credit deltas, doorbell triggers, peer-relative address offsets); CR/CRACK/ACK/NACK short packets for link training/handshake | **0xa1** (`PKT_SIDEBAND`); short pkts **0x44–0x47** (TideLink), **0x40–0x43** (GeneralBus) |
| **Management** | `apb_*` (unified config), `role_strap_i`/`nego_priority_i`/PUF, I2C sideband (`i2c_*`, `s_i2c_axi_*`), scan/DFT | **Does not cross the data link.** Local APB config only; cross-chiplet role negotiation uses the out-of-band I2C sideband | n/a (APB regions 0x2000 / 0x2080 / 0x2100; I2C bus) |
| **Time** | `ahb_ptp_*` (CPU triggers PTP messages), `phc_*` PHC integration (`phc_hw_capture` pulse, free-running time in, servo set/adjust out) | **Dedicated PTP FC node**: SYNC / DELAY_REQ short packets; servo (t1,t4) exchange as `PKT_SIDEBAND` | **0xa2** (PTP, 48-bit); short pkts **0x50** (SYNC) / **0x51** (DELAY_REQ) |

```
                          TideLink plane → carrier mapping
  ┌──────────────┬──────────────────────────────┬───────────────────────────┐
  │  PLANE       │  LOCAL INTERFACE             │  CROSSES LINK AS          │
  ├──────────────┼──────────────────────────────┼───────────────────────────┤
  │  DATA        │  ahb_sub_*  (transparent) ───┼─► AXI FC 0x80–0x84        │
  │              │  ahb_tx_*   (mailbox TX)  ───┼─┐                         │
  │              │  ahb_fifo_* (mailbox RX)  ◄──┼─┤ TideLink FC 0xa1        │
  │              │  tc_axis_*  (PKT_EXT)     ───┼─┘  (PKT_FIFO_DATA / EXT)  │
  ├──────────────┼──────────────────────────────┼───────────────────────────┤
  │  CONTROL     │  returner / fc_adapter    ───┼─► TideLink FC 0xa1        │
  │              │  (credits, doorbells)        │    (PKT_SIDEBAND)         │
  │              │  link bring-up FSM        ───┼─► short pkts 0x44–0x47    │
  │              │                              │    (CR/CRACK/ACK/NACK)    │
  ├──────────────┼──────────────────────────────┼───────────────────────────┤
  │  MANAGEMENT  │  apb_* (config regs)         │   ── does NOT cross the   │
  │              │  role straps / nego / PUF    │      data link ──         │
  │              │  i2c_* / s_i2c_axi_*      ───┼─► I2C sideband (OOB)      │
  ├──────────────┼──────────────────────────────┼───────────────────────────┤
  │  TIME        │  ahb_ptp_*  (msg trigger) ───┼─► PTP FC 0xa2             │
  │              │  phc_* (capture/servo)       │    short pkts 0x50/0x51   │
  │              │                              │    + servo PKT_SIDEBAND   │
  └──────────────┴──────────────────────────────┴───────────────────────────┘
        All four planes share one die-to-die PHY (pad_clk_tx/rx, pad_tx/rx[7:0]);
        each is independently flow-controlled. The TIME plane uses a separate FC
        node (0xa2) so PTP timing is isolated from DATA-plane backpressure.
```

**FC node inventory.** Per the canonical allocation in [`FC_NODE_REGISTRY.md`](FC_NODE_REGISTRY.md), ten long-packet FC nodes are allocated across the ecosystem. Of these, the Wlink instance inside `tidelink_top` (`u_chiplet_controller`) carries: 5× AXI (AW/W/B/AR/R, 0x80–0x84) and 1× APB initiator (0x90) for the transparent-bridge data plane; 1× GeneralBus (0xa0, present but tied off — TideLink's `gb_in`/`gb_out` were removed in `strip-generalbus-irq`); **1× TideLink (0xa1)** for the data/control planes; and **1× PTP (0xa2)** for the time plane. The Chiplet IRQC node (0xa3, 64-bit) is a separate IP (`ahb-chiplet-interrupt-controller`) and is not instantiated inside `tidelink_top`.

**TideLink itself owns two dedicated FC nodes — 0xa1 (data + control) and 0xa2 (time)** — layered on top of the AXI/APB/GeneralBus nodes inherited from the chiplet controller. The PTP node is what makes the time plane physically independent of the data plane.

> **Note on AXI credit IDs.** `REGISTER_MAP.md` describes the AXI channels as *sharing* credit `data_id` 0x80, whereas `FC_NODE_REGISTRY.md` (authoritative for ID allocation) lists distinct 0x80–0x84. The registry governs allocation; the per-channel credit-sharing behaviour should be confirmed against the Wlink Scala source (`AXI.scala`) before relying on it in a downstream spec.

---

## 4. Component Descriptions

### 4.1 tidelink_fifo_ahb — RX FIFO Subsystem

**File**: `src/rtl/fifo/tidelink_fifo_ahb.sv` (wraps `tidelink_fifo.sv`, `tidelink_apb_regs.sv`, `tidelink_returner.sv`, `tidelink_fifo_ctrl.sv`, `tidelink_sram.sv`)

`tidelink_fifo_ahb` is the receive-side FIFO subsystem. Within `tidelink_top` it functions as the local mailbox buffer into which incoming TideLink packets are written and from which the host CPU reads them.

**Subcomponents:**

- **FIFO memory (`tidelink_sram`)**: A 16 KB SRAM backing store, available in FPGA (block RAM), ASIC (compiled macro), and generic (register-based) variants.
- **FIFO control (`tidelink_fifo_ctrl`)**: Manages write and read pointers, packet-boundary framing (first word is a length field), credit counting, and overrun/underrun detection. Issues `packet_committed_irq` when a complete packet has been written.
- **APB registers (`tidelink_apb_regs`)**: APB slave register block providing configuration (pair base address, release threshold), status (FIFO level, error flags), credit accumulation (incoming released-credits and doorbell accumulators), and doorbell/flush control. Covered in detail in Section 7.3.
- **Returner (`tidelink_returner`)**: A 3-channel priority AHB Lite master. Each channel carries one type of outbound write: channel 0 (highest priority) sends credit deltas, channel 1 sends doorbell, channel 2 sends reset deassert pulse. In `tidelink_top`, the returner's AHB master interface is intercepted by the FC adapter rather than connected to the bus matrix.

**Ports exposed to `tidelink_top`:**

| Port group | Direction | Purpose |
|---|---|---|
| `ahbs_*` | In | AHB slave — FIFO data window (muxed from FC adapter RX FIFO master + CPU via FIFO mux) |
| `ahbc_*` | In | AHB slave — APB config registers (muxed from FC adapter RX config master + CPU via Config mux) |
| `ahbm_*` | Out/In | AHB master — returner writes (intercepted by FC adapter) |
| `released_credits_irq` | Out | Interrupt: remote released credits received |
| `doorbell_irq` | Out | Interrupt: remote doorbell received |
| `packet_committed_irq` | Out | Interrupt: inbound packet written to FIFO |

Note: The legacy `tidelink_ahb.sv` wrapper still uses the port name `released_tokens_irq`. The current `tidelink_fifo_ahb.sv` and all other modules (`tidelink_fifo.sv`, `tidelink_apb_regs.sv`, `tidelink.sv`, `tidelink_top.sv`) use the updated name `released_credits_irq` consistently.

### 4.2 tidelink_fc_adapter — AHB/FC Bridge

**File**: `src/rtl/tidelink_fc_adapter.sv`

The FC adapter bridges two AHB slave interfaces (TX aperture and returner interception) and two internal AHB master interfaces (RX FIFO writes and RX config writes) to the single 48-bit Wlink FC node application interface.

#### 4.2.1 FC Packet Format

Every FC transaction is a single 48-bit word with the following layout:

```
[47:46]  pkt_type    (2 bits)  — 00=FIFO_DATA, 01=SIDEBAND
[45:32]  addr_offset (14 bits) — Byte address within 16 KB aperture
[31:0]   payload     (32 bits) — Data word
```

Three packet types are defined:

- **FIFO_DATA (0b00)**: Carries one 32-bit word to be written into the remote RX FIFO. `addr_offset` is the byte address within the FIFO aperture (derived from the TX aperture AHB address). The RX adapter drives `addr_offset` directly on its `fc_rx_fifo_haddr` internal master port — no base address parameter is needed.
- **SIDEBAND (0b01)**: Carries a credit delta or doorbell write originating from the local returner. `addr_offset` is the lower 14 bits of the returner's target address (a TideLink APB register offset: 0x020 for credit delta, 0x024 for doorbell accumulator, 0x014 for reset doorbell). The RX adapter drives `addr_offset` directly on its `fc_rx_cfg_haddr` internal master port.
- **PKT_EXT (0b10)**: Extension protocol packet. Carries payloads for peer-integrated extension controllers (e.g. TideChart). `addr_offset[13:8]` encodes a subtype field; `addr_offset[7:0]` is reserved. PKT_EXT packets arriving on the FC RX path are forwarded to the `tc_axis_tx_*` AXI-Stream interface for processing by an external TideChart controller. PKT_EXT packets generated by the TideChart controller arrive on the `tc_axis_rx_*` interface and are transmitted over the FC node. One subtype is handled locally: PUF_READ_REQ (subtype=0x0020) triggers a local SRAM read and returns PUF_READ_RSP (subtype=0x0021) without crossing the die-to-die link.

The encoding is stateless on the RX side: each FC word carries its own destination address and routing tag (`pkt_type`), so no packet boundary tracking is required.

#### 4.2.2 TX Aperture Path (AHB Slave → FC TX)

An AHB slave sized to `RAM_ADDR_W` bits (16 KB). Each word write becomes one FIFO_DATA FC packet: address phase latches `ahb_tx_haddr` into `tx_addr_r`; data phase forms `tx_fc_word = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata}` and asserts `tl_fc_a2l_valid`. If `tl_fc_a2l_ready` is not asserted or the returner has priority, `ahb_tx_hreadyout` is held low until the FC word is accepted. The aperture is write-only (`ahb_tx_hrdata` tied to zero, `ahb_tx_hresp` always OKAY).

#### 4.2.3 Returner Interception Path (AHB Slave → FC TX, Sideband)

The adapter presents a compliant AHB slave to the write-only returner master. On address phase (`rtn_htrans[1]` and `rtn_hwrite`), `rtn_haddr[13:0]` is latched as `rtn_addr_latched_r` and `rtn_pending_r` is set. On data phase, `rtn_fc_word = {PKT_SIDEBAND, rtn_addr_latched_r, rtn_hwdata}` is driven on `tl_fc_a2l_data`; `rtn_hready` follows `tl_fc_a2l_ready`.

The sideband path has priority over the TX aperture: when `rtn_pending_r` is set, `tl_fc_a2l_data` carries the sideband word and `ahb_tx_hreadyout` is suppressed (`~rtn_fc_valid`).

#### 4.2.4 RX Path (FC RX → Two Internal AHB Masters)

Incoming 48-bit FC words arrive on `tl_fc_l2a_*` and are replayed as AHB master writes on two internal ports selected by `pkt_type`:

- **`fc_rx_fifo_*`** (address width `RAM_ADDR_W`): FIFO_DATA writes to the local FIFO data window.
- **`fc_rx_cfg_*`** (address width `APB_ADDR_W`): SIDEBAND writes to the local APB config registers.

These ports are internal to `tidelink_top` and feed into the FIFO mux and Config mux (Section 3.6).

FSM: `RX_IDLE` → `RX_ADDR_PHASE` → `RX_DATA_PHASE` → `RX_IDLE`.

- **RX_IDLE**: On `tl_fc_l2a_valid`, latch the FC word into `rx_fc_word_r`, set `rx_pending_r`, assert `tl_fc_l2a_accept`.
- **RX_ADDR_PHASE**: Drive `HTRANS_NONSEQ` and the `addr_offset` field on the selected internal master port (`fc_rx_fifo_haddr` or `fc_rx_cfg_haddr`); the inactive port stays at `HTRANS_IDLE`. Advance on `hready`.
- **RX_DATA_PHASE**: Drive `hwdata = rx_payload` on the active port. Complete on `hready`.

`addr_offset` is used directly as the AHB address (not added to a base), so no `RX_FIFO_BASE` or `RX_CFG_BASE` parameters exist.

### 4.3 XHB500 AHB-to-AXI Bridge (`xhb500_ahb_to_axi_bridge_chiplet_slv`)

ARM XHB500 is a configurable AHB-to-AXI protocol bridge. In TideLink's subordinate path it converts AHB transactions arriving on `ahb_sub_*` (after address translation) into AXI4 transactions on the `s_axi_*` bus toward the chiplet controller.

The bridge is instantiated as `u_xhb_sub`. AHB optional signals with no equivalents in the system (e.g., `hmastlock`, `hexcl`, `hnonsec`) are tied to safe defaults. The 36-bit AXI address extension bits `[35:32]` are tied to zero since only 32-bit addresses are required.

Power and clock quality-of-service handshake ports (`clk_qactive`, `pwr_qactive`, etc.) are present as required by the XHB500 interface but their accept/deny outputs are left unconnected and their request inputs are tied to inactive (`1'b1` for `_qreqn` signals).

### 4.4 XHB500 AXI-to-AHB Bridge (`xhb500_axi_to_ahb_bridge_chiplet_mst`)

The manager path bridge converts AXI4 transactions arriving from the chiplet controller (`m_axi_*`) into AHB transactions on `ahb_mng_*`. This carries traffic initiated by the remote chiplet destined for local AHB slaves.

Instantiated as `u_xhb_mng`. Optional AHB output signals (`hmastlock`, `hexcl`, `hwstrb`, `hqos`, `hregion`, `hnsaid`, `hnonsec`, `hmaster`) are left unconnected. The `hexokay` input (exclusive okay) is tied to zero.

### 4.5 Address Translator (`tidelink_addr_translator`)

**File**: `src/rtl/tidelink_addr_translator.sv` (derived from `nanosoc_ss_chiplet_addr.sv`)

The address translator remaps the AHB address presented on `ahb_sub_haddr` before it is passed to the XHB500 bridge. This allows the local CPU to use a local address range to target remote slaves without requiring manual software address translation.

The translation mapping is configurable via an AHB slave port (`ahb_adr_*`). Two translation ports are instantiated; the second is unused in the current configuration and its output is left unconnected.

Parameter `BE = 0` selects little-endian operation.

### 4.6 Chiplet Controller (`tidelink_chiplet_controller`)

**Files**: Modified Wlink Verilog generated from `wav-wlink-hw` Chisel source (in `axi-chiplet-controller` submodule)

The chiplet controller is a modified fork of the Wlink AXI chiplet controller. It incorporates all standard Wlink components plus a new TideLink FC node:

#### FC Node Table

| Instance | Module | data_id | App Data Width | Protocol |
|---|---|---|---|---|
| axiawFC | WlinkGenericFCSM | 0x80 | 101 bits | AXI Write Address channel |
| axiwFC | WlinkGenericFCSM_1 | 0x81 | 37 bits | AXI Write Data channel |
| axibFC | WlinkGenericFCSM_2 | 0x82 | 14 bits | AXI Write Response channel |
| axiarFC | WlinkGenericFCSM_3 | 0x83 | 101 bits | AXI Read Address channel |
| axirFC | WlinkGenericFCSM_4 | 0x84 | 47 bits | AXI Read Data channel |
| generalbusgb | WlinkGenericFCSM_5 | 0xa0 | 32 bits | General Bus (Wlink-internal; **unused by TideLink** — historic cross-chiplet IRQ path replaced by `ahb-chiplet-interrupt-controller` on FC `data_id = 0xa3`) |
| **TideLink FC** | **WlinkGenericFCSM_6** | **0xa1** | **48 bits** | **TideLink mailbox** |

The TideLink FC node is the only addition to the upstream Wlink configuration. The TX router is extended from 6 to 7 inputs and the RX router from 7 to 8 outputs to accommodate it.

**FC node ID assignments:**
- Short packet IDs: 0x44 (CR), 0x45 (CRACK), 0x46 (ACK), 0x47 (NACK)
- Data ID: 0xa1

The FC node's application-side interface is exposed on the chiplet controller's top-level as a packed 50-bit bus:

```
tidelink_in[49:0]  = {a2l_valid, a2l_data[47:0], l2a_accept}
tidelink_out[49:0] = {a2l_ready, l2a_valid, l2a_data[47:0]}
```

Within `tidelink_top`, these packed buses are decomposed into separate valid/ready/data/accept signals (`tl_fc_a2l_valid`, `tl_fc_a2l_data`, `tl_fc_a2l_ready`, `tl_fc_l2a_valid`, `tl_fc_l2a_data`, `tl_fc_l2a_accept`) for connection to the FC adapter.

**Other chiplet controller interfaces:**

- **APB slave** (via unified `apb_*` port, 0x0000-0x1FFF): Wlink internal configuration -- link training, PHY parameters, FC credit initialisation, interrupt status.
- **AXI slave** (`s_axi_*`): Outbound AXI from XHB500 bridge; packetised into FC nodes 0x80–0x84.
- **AXI master** (`m_axi_*`): Inbound AXI from FC nodes 0x80–0x84; driven into XHB500 bridge.
- **I2C sideband** (`i2c_scl_i/o/t`, `i2c_sda_i/o/t`): Out-of-band sideband channel for link bring-up and management.
- **PHY pads** (`pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]`): 8-lane plus clock die-to-die physical interface.
- **Reset sideband** (`sb_reset_in`, `sb_reset_out` / `d2d_reset_o`): Power-on reset coordination across the link.
- **Interrupts** (`wlink_irq`): Wlink internal interrupt (link error, training completion, etc.).

### 4.7 TideChart Integration Interface

**Files**: `src/rtl/tidelink_fc_adapter.sv` (PKT_EXT routing), `src/rtl/tidelink_top.sv` (tc_axis_* ports)

TideLink provides an AXI-Stream interface (`tc_axis_*`) for peer integration with a TideChart controller. TideChart is a separate module responsible for chiplet-level orchestration protocols; TideLink acts as the transport layer, forwarding PKT_EXT (pkt_type=2'b10) FC packets between the die-to-die link and the TideChart controller.

**FC RX path (remote chiplet to TideChart):** When the FC adapter receives a PKT_EXT packet on the FC RX interface, it routes the full 48-bit word to `tc_axis_tx_tdata` and asserts `tc_axis_tx_tvalid`. The word is held until the TideChart controller asserts `tc_axis_tx_tready`. One exception: PUF_READ_REQ packets (subtype=0x0020) are intercepted locally and never appear on the TX AXI-Stream interface.

**FC TX path (TideChart to remote chiplet):** The TideChart controller drives `tc_axis_rx_tvalid` and `tc_axis_rx_tdata` with a 48-bit PKT_EXT word. The FC adapter accepts the word when the TX arbiter grants the PKT_EXT path and asserts `tc_axis_rx_tready`. The TX arbiter priority order is: returner sideband > PTP > PKT_EXT (TideChart) > TX aperture.

### 4.8 PUF SRAM Read Mechanism

**File**: `src/rtl/tidelink_fc_adapter.sv`

The FC adapter contains a local FSM that intercepts PUF_READ_REQ packets (pkt_type=2'b10, subtype=0x0020). These packets request a read of uninitialized SRAM data for use as a Physical Unclonable Function (PUF) entropy source.

**Operation:**

1. A PUF_READ_REQ FC packet arrives on the FC RX path. The `addr_offset[7:0]` field encodes the SRAM word address to read.
2. The FC adapter's PUF FSM issues a read to the FIFO SRAM via the 3-way arbiter in `tidelink_fifo_mem` (lowest priority).
3. The SRAM returns the uninitialized (or previously written) data word.
4. The FC adapter constructs a PUF_READ_RSP packet (pkt_type=2'b10, subtype=0x0021, payload=SRAM read data) and presents it on `tc_axis_tx_*`.

PUF reads are strictly local. They never cross the die-to-die link and do not consume FC credits. PUF data is only meaningful before software writes to the SRAM (i.e., before FIFO enable), since FIFO writes overwrite the uninitialized SRAM contents.

### 4.9 3-Way SRAM Arbiter

**File**: `src/rtl/fifo/tidelink_fifo_mem.sv`

The FIFO SRAM has three access paths, arbitrated with fixed priority:

| Priority | Source | Access Type | Description |
|----------|--------|-------------|-------------|
| Highest | FC direct write | Write | Incoming FIFO_DATA packets from the remote chiplet (single-cycle path) |
| Middle | AHB (CPU) | Read/Write | Local CPU reads of received packets and diagnostic writes |
| Lowest | PUF read | Read | PUF SRAM reads triggered by PUF_READ_REQ (from FC adapter PUF FSM) |

When a higher-priority access is active, lower-priority requestors are stalled. FC direct writes complete in a single cycle. The CPU AHB path sees at most 1 wait state per FC write collision. PUF reads may be delayed by both FC writes and CPU AHB accesses; this is acceptable since PUF reads occur only during boot, before FIFO traffic begins.

---

## 5. Interface Specification

### 5.1 Clock and Reset

| Signal | Direction | Width | Description |
|---|---|---|---|
| `hclk` | In | 1 | AHB/application clock. All AHB, APB, and FC adapter logic is synchronous to this clock. |
| `hresetn` | In | 1 | Active-low synchronous reset for AHB and application logic. |
| `poresetn` | In | 1 | Active-low power-on reset. Drives Wlink `por_resetn` for PHY and link-layer reset. Distinct from `hresetn` to allow the PHY to remain held after fabric reset is released. |

### 5.2 Standard AHB-Lite Subordinate Signal Set

All AHB-Lite subordinate ports follow the standard signal set below. Each subsection notes only the deviations from this baseline.

| Signal suffix | Dir | Width | Description |
|---|---|---|---|
| `_hsel` | In | 1 | Slave select |
| `_haddr[A-1:0]` | In | A | Address (A = port-specific width) |
| `_hburst[2:0]` | In | 3 | Burst type |
| `_hprot[3:0]` | In | 4 | Protection attributes |
| `_hsize[2:0]` | In | 3 | Transfer size |
| `_htrans[1:0]` | In | 2 | Transfer type |
| `_hwdata[31:0]` | In | 32 | Write data |
| `_hwrite` | In | 1 | Write enable |
| `_hready` | In | 1 | Previous slave ready (from bus matrix) |
| `_hrdata[31:0]` | Out | 32 | Read data |
| `_hresp` | Out | 1 | Error response (0 = OKAY, 1 = ERROR) |
| `_hreadyout` | Out | 1 | This slave's ready signal |

### 5.3 AHB Subordinate — Regular Bridge (`ahb_sub_*`)

Standard AHB-Lite subordinate (Section 5.2, A=32). Carries transparent AHB transactions to the remote chiplet via XHB500 + AXI + Wlink. Address translation is applied before the bridge.

### 5.4 AHB Subordinate — TideLink TX Aperture (`ahb_tx_*`)

Standard AHB-Lite subordinate (Section 5.2, A=`RAM_ADDR_W`=14). Write-only; each word write is forwarded as a FIFO_DATA FC packet. `ahb_tx_hrdata` is always zero. `ahb_tx_hreadyout` is held low when the FC TX interface is not ready or the returner sideband path has priority. `hburst` and `hprot` are not used.

### 5.5 AHB Subordinate — Local RX FIFO Data Window (`ahb_fifo_*`)

Standard AHB-Lite subordinate (Section 5.2, A=`RAM_ADDR_W`=14). CPU read/write access to received packets. Internally multiplexed with the FC adapter RX FIFO master via the FIFO mux (Section 3.6); FC adapter has priority. `ahb_fifo_hreadyout` is held low when the FC adapter RX FIFO master is active.

### 5.6 APB Subordinate — Unified Config Port (`apb_*`)

Single APB3 subordinate (15-bit address). Address range 0x0000-0x1FFF is routed to Wlink chiplet controller registers. Address range 0x2000-0x203F is routed to TideLink FIFO config and PTP registers. TideLink config registers are internally multiplexed with the FC adapter RX config master via the Config mux (Section 3.6).

### 5.7 AHB Manager — Regular Bridge Incoming (`ahb_mng_*`)

AHB-Lite manager output. Carries transactions from the remote chiplet (via Wlink + XHB500) to local AHB slaves.

| Signal | Dir | Width | Description |
|---|---|---|---|
| `ahb_mng_haddr[31:0]` | Out | 32 | Address |
| `ahb_mng_hburst[2:0]` | Out | 3 | Burst type |
| `ahb_mng_hprot[3:0]` | Out | 4 | Protection attributes |
| `ahb_mng_hsize[2:0]` | Out | 3 | Transfer size |
| `ahb_mng_htrans[1:0]` | Out | 2 | Transfer type |
| `ahb_mng_hwdata[31:0]` | Out | 32 | Write data |
| `ahb_mng_hwrite` | Out | 1 | Write enable |
| `ahb_mng_hready` | Out | 1 | Manager drives ready to slave |
| `ahb_mng_hrdata[31:0]` | In | 32 | Read data from slave |
| `ahb_mng_hresp` | In | 1 | Slave error response |

### 5.8 FC Adapter RX — Internal AHB Masters (Not Externally Exposed)

Two internal AHB master ports wired entirely within `tidelink_top`; they do **not** require bus matrix master slots.

**`fc_rx_fifo_*`** — Writes FIFO_DATA payloads to the local FIFO data window (via FIFO mux):

| Signal | Width | Description |
|---|---|---|
| `fc_rx_fifo_haddr[RAM_ADDR_W-1:0]` | 14 | FIFO byte address (addr_offset from FC word) |
| `fc_rx_fifo_hwdata[31:0]` | 32 | Payload from FC word |
| `fc_rx_fifo_htrans[1:0]` | 2 | IDLE or NONSEQ |
| `fc_rx_fifo_hsize[2:0]` | 3 | Always HSIZE_WORD |
| `fc_rx_fifo_hwrite` | 1 | Always 1 when active |

**`fc_rx_cfg_*`** — Writes SIDEBAND payloads (credit deltas, doorbells) to the local APB config registers (via Config APB mux). This path uses APB natively, eliminating the need for an AHB-to-APB bridge:

| Signal | Width | Description |
|---|---|---|
| `fc_rx_cfg_paddr[APB_ADDR_W-1:0]` | 12 | APB register offset (addr_offset from FC word) |
| `fc_rx_cfg_pwdata[31:0]` | 32 | Payload from FC word |
| `fc_rx_cfg_psel` | 1 | APB select (active during setup + access) |
| `fc_rx_cfg_penable` | 1 | APB enable (active during access phase) |
| `fc_rx_cfg_pwrite` | 1 | Always 1 (write-only) |

The FIFO data port uses AHB; the config port uses APB directly, matching the downstream register interface protocol.

### 5.9 AHB Subordinate — Address Translator Config (`ahb_adr_*`)

Standard AHB-Lite subordinate (Section 5.2, A=32). Runtime configuration of the address translation mapping applied to `ahb_sub_haddr`.

### 5.10 APB Subordinate — Unified Config Port (`apb_*`)

Single APB3 subordinate for all TideLink and Wlink configuration. Internally decoded: 0x0000-0x1FFF routes to Wlink chiplet controller, 0x2000-0x203F routes to TideLink config/PTP registers.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `apb_paddr[14:0]` | In | 15 | Register address |
| `apb_penable` | In | 1 | APB enable phase |
| `apb_pwrite` | In | 1 | Write enable |
| `apb_pstrb[3:0]` | In | 4 | Byte strobes |
| `apb_pprot[2:0]` | In | 3 | Protection attributes |
| `apb_pwdata[31:0]` | In | 32 | Write data |
| `apb_psel` | In | 1 | Slave select |
| `apb_prdata[31:0]` | Out | 32 | Read data |
| `apb_pready` | Out | 1 | Slave ready |
| `apb_pslverr` | Out | 1 | Slave error |

### 5.11 Chiplet Controller Role Selection

Runtime master/slave role selection for the generic chiplet controller (`axi_chiplet_controller`). The role determines I2C bus direction and APB mux behaviour.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `role_strap_i` | In | 1 | Default role from strap pin (0=master, 1=slave) |
| `role_is_master_o` | Out | 1 | Effective role: 1=master, 0=slave |
| `role_locked_o` | Out | 1 | 1 when role is locked and Wlink is active |

Role configuration registers are accessible via the unified APB port at Region 4 (offsets 0x2080-0x208F). See REGISTER_MAP.md for details.

**Startup sequence**: After `poresetn` release, Wlink is held in reset until the CPU writes `role_lock=1` to ROLE_CFG (0x2080). The role defaults from `role_strap_i` and can be overridden by writing ROLE_CFG[0] before locking. Once locked, only `poresetn` can change the role — warm reset (`hresetn`) preserves it.

### 5.12 I2C Sideband

Tri-state I2C interface for Wlink out-of-band link management and bring-up. In master mode, the I2C master core drives SCL/SDA to configure the remote slave's Wlink registers. In slave mode, the I2C slave core responds on SCL/SDA (SCL forced high-Z since slaves don't drive clock).

| Signal | Direction | Width | Description |
|---|---|---|---|
| `i2c_scl_i` | In | 1 | SCL input (from open-drain bus) |
| `i2c_scl_o` | Out | 1 | SCL output (active drive, master mode only) |
| `i2c_scl_t` | Out | 1 | SCL tristate enable (1 = high-Z; always 1 in slave mode) |
| `i2c_sda_i` | In | 1 | SDA input |
| `i2c_sda_o` | Out | 1 | SDA output |
| `i2c_sda_t` | Out | 1 | SDA tristate enable |

The I2C master is controlled via the I2C sideband AXI port (`s_i2c_axi_*`). The I2C slave address is configurable via register I2C_SLV_ADDR (0x2088, default 0x00).

### 5.13 I2C Sideband AXI

AXI4 subordinate port for CPU access to the I2C master controller (master mode only).

| Signal | Direction | Width | Description |
|---|---|---|---|
| `s_i2c_axi_aw*` | In/Out | various | AXI write address channel (4-bit addr, 2-bit ID) |
| `s_i2c_axi_w*` | In/Out | various | AXI write data channel |
| `s_i2c_axi_b*` | In/Out | various | AXI write response channel |
| `s_i2c_axi_ar*` | In/Out | various | AXI read address channel |
| `s_i2c_axi_r*` | In/Out | various | AXI read data channel |
| `i2c_nbsy_irq` | Out | 1 | I2C bus not busy interrupt |
| `i2c_nrd_empty_irq` | Out | 1 | I2C read FIFO not empty interrupt |

### 5.14 General Bus (removed)

The legacy 32-bit `gb_in` / `gb_out` cross-link interrupt forwarding ports
have been removed from `tidelink_top`. Cross-chiplet interrupt delivery is
now handled by the dedicated `ahb-chiplet-interrupt-controller` IP on a
separate Wlink FC node (`data_id = 0xa3`), independently flow-controlled
from the TideLink mailbox so interrupt traffic cannot be starved by — and
cannot starve — bulk AHB / mailbox traffic. The Wlink GeneralBus FC node
itself (`data_id = 0xa0`) still exists inside `axi_chiplet_controller`
but its `generalbus_in` is tied to zero and `generalbus_out` is left
unconnected at the TideLink boundary.

### 5.15 PHY Pads

8-lane source-synchronous die-to-die interface.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `pad_clk_tx` | Out | 1 | Transmit clock |
| `pad_tx[7:0]` | Out | 8 | Transmit data lanes |
| `pad_clk_rx` | In | 1 | Receive clock (from remote chiplet) |
| `pad_rx[7:0]` | In | 8 | Receive data lanes |

### 5.14 Interrupt Outputs

| Signal | Direction | Width | Description |
|---|---|---|---|
| `released_credits_irq` | Out | 1 | Remote chiplet has returned FIFO credits (remote RX FIFO has space) |
| `doorbell_irq` | Out | 1 | Remote chiplet has sent a doorbell |
| `packet_committed_irq` | Out | 1 | An inbound packet has been written into the local RX FIFO |
| `wlink_irq` | Out | 1 | Wlink internal interrupt (link error, training, etc.) |

### 5.15 Reset Output

| Signal | Direction | Width | Description |
|---|---|---|---|
| `d2d_reset_o` | Out | 1 | Sideband reset signal from Wlink (`sb_reset_out`). Can be connected to the remote chiplet's reset input for cross-link reset coordination. |

### 5.16 AXI-Stream TideChart Interface (`tc_axis_*`)

AXI-Stream interface for forwarding PKT_EXT (pkt_type=2'b10) packets between TideLink and an external TideChart controller. The TideChart controller is a separate, peer-integrated module; TideLink does not contain TideChart logic.

**TX direction (TideLink to TideChart controller):**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `tc_axis_tx_tvalid` | Out | 1 | Valid: a PKT_EXT packet has been received from the remote chiplet via FC RX and is available |
| `tc_axis_tx_tdata[47:0]` | Out | 48 | Data: the full 48-bit FC word (pkt_type + addr_offset/subtype + payload) |
| `tc_axis_tx_tready` | In | 1 | Ready: TideChart controller can accept the packet |

**RX direction (TideChart controller to TideLink):**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `tc_axis_rx_tvalid` | In | 1 | Valid: TideChart controller has a PKT_EXT packet to send to the remote chiplet |
| `tc_axis_rx_tdata[47:0]` | In | 48 | Data: the full 48-bit FC word to transmit over the die-to-die link |
| `tc_axis_rx_tready` | Out | 1 | Ready: FC TX path can accept the packet (subject to TX arbiter priority) |

The `tc_axis_*` interface uses standard AXI-Stream valid/ready handshaking. There are no flow control credits on this interface; backpressure is provided by the `tready` signal. The TX arbiter priority for PKT_EXT is below returner sideband and PTP but above the TX aperture data path.

**PUF local intercept:** PKT_EXT packets with subtype=0x0020 (PUF_READ_REQ) are intercepted locally by the FC adapter and do not appear on `tc_axis_tx_*`. The adapter reads the addressed SRAM word and returns a PUF_READ_RSP (subtype=0x0021) on `tc_axis_tx_*`.

---

## 6. Configuration Parameters

All parameters are defined on the `tidelink_top` module and propagated to sub-instances.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `SYS_ADDR_W` | integer | 32 | System address width in bits. Must match the AHB bus address width. |
| `SYS_DATA_W` | integer | 32 | System data width in bits. Must be 32 for AHB-Lite compatibility with XHB500. |
| `RAM_ADDR_W` | integer | 14 | FIFO SRAM address width. Determines FIFO capacity: 2^`RAM_ADDR_W` bytes. Default 14 gives 16 KB. Also sets the TX aperture address width. |
| `RAM_DATA_W` | integer | 32 | FIFO SRAM data width in bits. |
| `APB_ADDR_W` | integer | 12 | APB register address width for TideLink config registers. |
| `FC_DATA_W` | integer | 48 | FC node data width. Must match the TideLink FC node in the chiplet controller (WlinkGenericFCSM_6). Do not change unless regenerating the Chisel. |
| `TIDELINK_PAIR_BASE` | `[SYS_ADDR_W-1:0]` | 0 | Default pair base address for the returner. This is the base address of the remote TideLink APB register block as seen from the local system address map. Used as the reset default for the pair base address register (APB offset 0x000). Can be overridden at runtime by writing to the register. |

Note: Earlier versions of TideLink included `RX_FIFO_BASE` and `RX_CFG_BASE` parameters for the FC adapter RX path. These have been eliminated. The RX path now uses two internal AHB master ports with narrowed address widths (`RAM_ADDR_W` and `APB_ADDR_W` respectively) that connect directly to the FIFO and Config muxes inside `tidelink_top`. The `addr_offset` from each FC word is used as the AHB address without adding a base, so no base address parameters are needed.

---

## 7. Data Flow and Protocol

### 7.1 TideLink Packet Format

TideLink packets are a software convention imposed on the raw FIFO word stream. Hardware is unaware of packet semantics — it transports each 32-bit word independently as a FIFO_DATA FC packet. The receiving CPU reconstructs the packet by reading the header word first, then popping the address and payload from the local RX FIFO.

A packet consists of a 2-word header followed by an optional data payload:

```
FIFO Addr   Content
┌──────────┬────────────────────────────────────────────────────────────────┐
│ 0x0000   │ Word 0: length[31:20] | pkt_type[19:18] | src_id[17:13] |     │
│          │         dest_id[12:8] | tag[7:0]                              │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x0004   │ Word 1: dest_addr[31:0]                                       │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x0008   │ Word 2: Data payload[0]  (WR_REQ / RSP only)                  │
├──────────┼────────────────────────────────────────────────────────────────┤
│   ...    │ ...                                                           │
├──────────┼────────────────────────────────────────────────────────────────┤
│(N+1) × 4 │ Word N+1: Data payload[N-1]  ← final write triggers completion│
└──────────┴────────────────────────────────────────────────────────────────┘
```

The `length` field (N) counts **data payload words only** — it does not include the 2-word header. Total FIFO occupancy per packet is N + 2 credits (2 header words + N data words). For header-only packets (RD_REQ), N = 0 and the total occupancy is 2 credits.

**Word 0 — Packed header (32 bits):**

| Bits | Width | Field | Description |
|------|-------|-------|-------------|
| [31:20] | 12 | `length` | Data payload word count (0–4095). Does not include the 2-word header. |
| [19:18] | 2 | `pkt_type` | Transaction type (see encoding below) |
| [17:13] | 5 | `src_id` | Source chiplet ID (0–31) |
| [12:8] | 5 | `dest_id` | Destination chiplet ID (0–31) |
| [7:0] | 8 | `tag` | Transaction tag (matches responses to requests) |

**Word 1 — Destination address (32 bits):**

| Bits | Width | Field | Description |
|------|-------|-------|-------------|
| [31:0] | 32 | `dest_addr` | Target address on the remote chiplet |

**Packet type encoding (2 bits):**

| Value | Type | Description |
|-------|------|-------------|
| 0b00 | RD_REQ | Read request — dest_addr specifies where to read |
| 0b01 | WR_REQ | Write request — dest_addr + data payload |
| 0b10 | RSP | Response — covers read data, write ack, and error |
| 0b11 | Reserved | Reserved for future use |

**FC packet type encoding (2 bits, in FC word [47:46]):**

| Value | Type | Description |
|-------|------|-------------|
| 0b00 | FIFO_DATA | FIFO mailbox data word |
| 0b01 | SIDEBAND | Credit delta / doorbell return |
| 0b10 | PKT_EXT | Extension protocol (TideChart, PUF) |
| 0b11 | Reserved | Reserved for future use |

**Per-type payload conventions:**

The payload meaning is defined per packet type. Hardware is unaware of these conventions — it transports words based on the length field alone. Software on the receiving side interprets the payload according to the packet type.

#### RD_REQ — Read Request

| Variant | N | Payload | Description |
|---------|---|---------|-------------|
| Single read | 0 | None | Read 1 word at `dest_addr`. Total: 2 credits. |
| Burst read | 1 | `beat_count[31:3] \| size[2:0]` | Read `beat_count` words starting at `dest_addr`. Total: 3 credits. |

For a single read (N=0), the responder reads one word at `dest_addr` and returns it in a RSP. For a burst read (N=1), payload word 0 encodes the beat count and transfer size (mirroring AHB HSIZE). The responder reads `beat_count` sequential words starting at `dest_addr` and returns them as a RSP with N = `beat_count`.

#### WR_REQ — Write Request

| N | Payload | Description |
|---|---------|-------------|
| P (≥ 1) | P data words | Write P words sequentially starting at `dest_addr`. Total: P + 2 credits. |

The payload length implicitly defines the burst length — no separate beat count field is needed. The responder writes the payload words to sequential addresses starting at `dest_addr`.

#### RSP — Response

| Variant | N | Payload | Description |
|---------|---|---------|-------------|
| Write ack | 0 | None | Acknowledges a completed WR_REQ. Total: 2 credits. |
| Error | 0 | None | Signals an error. `dest_addr` = 0xFFFFFFFF (reserved). Total: 2 credits. |
| Read data | P | P data words | Returns P words read from `dest_addr`. Total: P + 2 credits. |

The `tag` field matches the response to its originating request. For read data responses, the payload length matches the requested `beat_count` (or 1 for single reads). Write acknowledgements and errors carry no payload — the receiver distinguishes them by checking `dest_addr` (0xFFFFFFFF = error) or by application-specific convention.

**Hardware extraction**: The FIFO control logic (`tidelink_fifo_ctrl`) extracts bits [31:20] of Word 0 as the packet length. All other fields are opaque to hardware — only software on the receiving side interprets them.

Software constructs this structure in memory and writes it word-by-word to the TX aperture. The receiving software reconstructs the packet from the FIFO.

### 7.2 Write Request Flow (Host → Device)

```
Host CPU                        TideLink (Host)           Link          TideLink (Device)        Device CPU
    │                                │                      │                 │                       │
    │  AHB writes (WR_REQ + data)    │                      │                 │                       │
    │──────────────────────────────► TX aperture            │                 │                       │
    │                                │  FC FIFO_DATA pkts   │                 │                       │
    │                                │──────────────────────►                 │                       │
    │                                │                      │  FC FIFO_DATA   │                       │
    │                                │                      │─────────────────► FC adapter RX         │
    │                                │                      │                 │  AHB writes to FIFO   │
    │                                │                      │                 │───────────────────────►│
    │                                │                      │                 │                       │  packet_committed_irq
    │                                │                      │                 │                       │◄─────────────────────
    │                                │                      │                 │                       │  Pop descriptor
    │                                │                      │                 │                       │  Perform local write
    │                                │  (optional WR_RSP)   │                 │                       │
```

1. Host CPU writes the 2-word header (packed header + dest_addr) and data payload to TX aperture (`ahb_tx_*`). Total words: N + 2.
2. Each AHB write is converted by the FC adapter to a FIFO_DATA packet carrying `{00, haddr[13:0], hwdata}`.
3. Packets traverse the TideLink FC node (data_id=0xa1) through Wlink.
4. Remote FC adapter receives each packet and drives an internal AHB master write on `fc_rx_fifo_*` with `haddr = addr_offset`. The FIFO mux routes this to the `tidelink_fifo_ahb` FIFO data window slave port.
5. The remote `tidelink_fifo_ahb` FIFO accumulates words. When the final word of the packet is written (determined by the length field in bits [31:20] of the word at offset 0), `packet_committed_irq` fires.
6. Device CPU services the interrupt, reads the 2-word header, and performs the requested local AHB write using dest_addr and the payload.
7. Optionally, a WR_RSP (RSP with N=0) is constructed and sent back.

### 7.3 Read Request Flow (Host → Device → Host)

```
Host CPU                        TideLink (Host)           Link          TideLink (Device)        Device CPU
    │                                │                      │                 │                       │
    │  AHB writes (RD_REQ)           │                      │                 │                       │
    │──────────────────────────────► TX aperture            │                 │                       │
    │  (returns immediately)         │  FC FIFO_DATA pkts   │                 │                       │
    │◄─────────────────────────────── ahb_tx_hreadyout      │                 │                       │
    │                                │──────────────────────►                 │                       │
    │  [Host CPU free to do other     │                      │  FC FIFO_DATA   │                       │
    │   work while link is in flight] │                      │─────────────────► FC adapter RX         │
    │                                │                      │                 │  AHB writes to FIFO   │
    │                                │                      │                 │───────────────────────►│
    │                                │                      │                 │                       │  packet_committed_irq
    │                                │                      │                 │                       │◄─────────────────────
    │                                │                      │                 │                       │  Pop RD_REQ header
    │                                │                      │                 │                       │  Local AHB reads
    │                                │                      │                 │                       │  at dest_addr
    │                                │                      │                 │                       │
    │                                │                      │                 │  AHB writes (RSP)     │
    │                                │                      │                 │◄──────────── TX aperture
    │                                │                      │  FC FIFO_DATA   │                       │
    │                                │◄─────────────────────────────────────── FC adapter RX         │
    │                                │  AHB writes to FIFO  │                 │                       │
    │                                │ (fc_rx_fifo_* master) │                │                       │
    │                                │  packet_committed_irq│                 │                       │
    │◄─────────────────────────────── (host)                │                 │                       │
    │  Pop RSP + data                │                      │                 │                       │
    │  from ahb_fifo_*               │                      │                 │                       │
```

#### Single read (N=0, 2 credits)

1. Host CPU writes RD_REQ with N=0 (2 words: packed header + dest_addr) to TX aperture. AHB completes immediately.
2. FC adapter encodes each word as `{PKT_FIFO_DATA, haddr[13:0], hwdata}` and transmits via TideLink FC node (data_id=0xa1).
3. Remote FC adapter writes into device FIFO. When dest_addr (offset 0x0004) is written, `packet_committed_irq` fires.
4. Device CPU pops the 2-word header, reads 1 word at `dest_addr`.
5. Device CPU constructs RSP (N=1: header + 1 data word) and writes to device TX aperture.
6. RSP traverses the link; `packet_committed_irq` fires on the host.
7. Host CPU pops the RSP header and reads the returned data word.

#### Burst read (N=1, 3 credits)

1. Host CPU writes RD_REQ with N=1 (3 words: packed header + dest_addr + `beat_count|size`) to TX aperture.
2–3. Same as single read — FC adapter transmits, device FIFO receives, `packet_committed_irq` fires.
4. Device CPU pops the 2-word header and the burst descriptor payload. Reads `beat_count` sequential words starting at `dest_addr` using the specified transfer `size`.
5. Device CPU constructs RSP (N=`beat_count`: header + read data) and writes to device TX aperture.
6–7. Same as single read — RSP traverses link, host pops header and `beat_count` data words.

### 7.4 Credit Return Flow

When the device CPU pops a packet from its RX FIFO, the FIFO control logic eventually releases credits back to the host to signal that space is available. The credit return mechanism works as follows:

1. As packets are read, `tidelink_fifo_ctrl` accumulates freed word-counts.
2. When the accumulated count reaches the configurable release threshold (APB register 0x004), the returner's channel 0 is triggered with `write_addr_0 = TIDELINK_PAIR_BASE + 0x020` and `write_data_0 = credit_delta`.
3. The returner initiates an AHB write. This write is intercepted by the FC adapter's returner-interception slave.
4. The adapter encodes the write as `{01, 14'h020, credit_delta}` (SIDEBAND packet) and transmits it via the TideLink FC node.
5. The remote (host) FC adapter receives the SIDEBAND packet and drives `fc_rx_cfg_haddr = 12'h020`, `fc_rx_cfg_hwdata = credit_delta` on its internal config master port. The Config mux routes this write to the `tidelink_fifo_ahb` APB config slave port.
6. This write increments the host's released-credits accumulator register, firing `released_credits_irq`.
7. Host software tracks available remote buffer space and throttles transmission accordingly.

This mechanism keeps credit-return traffic fully within the TideLink FC node, requiring no additional AHB bus matrix master port.

### 7.5 Doorbell Flow

The doorbell mechanism allows the device side to signal the host asynchronously:

1. Software writes to the device-side APB doorbell register (0x014), asserting `doorbell_trigger`.
2. The returner's channel 1 is triggered with `write_addr_1 = TIDELINK_PAIR_BASE + 0x024`.
3. The write is intercepted by the FC adapter as a SIDEBAND packet `{01, 14'h024, doorbell_data}`.
4. Transmitted to the remote side; the FC adapter's internal config master writes to APB offset 0x024 via the Config mux.
5. The host's `doorbell_irq` accumulator fires `doorbell_irq`.

### 7.6 Regular AHB Bridge Flow

For transparent AHB access:

1. CPU issues AHB transaction to `ahb_sub_*`.
2. `tidelink_addr_translator` remaps the address to the remote chiplet's address space.
3. `xhb500_ahb_to_axi_bridge_chiplet_slv` converts AHB to AXI4.
4. AXI transaction is distributed across FC nodes 0x80–0x84 by the Wlink AXI application layer.
5. On the remote chiplet, Wlink AXI layer reconstructs the AXI transaction.
6. `xhb500_axi_to_ahb_bridge_chiplet_mst` converts AXI to AHB and drives `ahb_mng_*`.
7. For reads, the response traverses in reverse, ultimately completing the AHB read on the host.
8. `ahb_sub_hreadyout` remains low throughout the round-trip for read transactions. This stalling behaviour is acceptable for infrequent control-plane reads; it is the reason bulk data movement uses the mailbox path.

---

## 8. Clocking and Reset Strategy

### 8.1 Clock Domains

In the current implementation, TideLink operates in a single clock domain. The `apb_clk`, `app_clk`, and `hsclk` inputs of `tidelink_chiplet_controller` are all driven from `hclk`. This simplifies CDC considerations at the cost of requiring all logic to meet timing at the AHB clock frequency.

The PHY itself operates from recovered clocks derived from `pad_clk_rx` and internally generated from `pad_clk_tx`. These clock domains are internal to the Wlink PHY and are managed by Wlink's built-in CDC FIFOs and demetastabilisation circuits.

If future integrations require the Wlink link layer to run at a different frequency from the AHB fabric, the chiplet controller's `apb_clk` and `app_clk` inputs can be driven independently. In this case, CDC logic internal to Wlink handles the crossing between the application clock domain and the PHY clock domain.

### 8.2 Reset Domains

Two reset signals are distinguished:

- **`hresetn`**: Active-low synchronous reset for all AHB, APB, and FC adapter RTL in `tidelink_top`. Applied to `apb_resetn` and `app_clk_resetn` in the chiplet controller.
- **`poresetn`**: Active-low power-on reset, applied to `por_resetn` in the chiplet controller. This controls the Wlink PHY and link-layer reset sequence. In typical integration, `poresetn` is asserted until power supplies are stable and the external reference clock is valid, while `hresetn` may be released and re-asserted as needed by the SoC reset controller.

The `d2d_reset_o` output (Wlink `sb_reset_out`) can be connected to the remote chiplet's reset input to coordinate cross-chiplet reset sequencing. The reset deassert pulse mechanism in `tidelink_apb_regs` (APB register 0x014 bit mechanism) allows software to trigger a reset of the remote chiplet once the link is established.

### 8.3 CDC in Wlink

Wlink uses standard dual-flop demetastabilisation (`WavDemetReset`) and gray-code CDC FIFOs (`WavFIFO`) at all clock domain crossings between the application domain and the PHY domain. These are part of the Wlink IP and are not modified by TideLink.

---

## 9. Design Justification

### 9.1 Dedicated FC Node for the Mailbox Path

A dedicated FC node (WlinkGenericFCSM_6, data_id=0xa1) is added rather than reusing the existing AXI FC nodes (0x80–0x84). Using the AXI nodes would require generating full AXI write transactions from the TX aperture, coupling mailbox flow control to AXI credit accounting and requiring an AHB-to-AXI conversion layer. The dedicated node keeps mailbox credits independent, makes the FC adapter a simple FSM rather than an AXI master, and gives each FC word a self-contained address field that makes the RX side stateless. The one-time cost is forking the Chisel source and regenerating Wlink Verilog (see 9.5).

### 9.2 48-bit FC Data Width

48 bits is the minimum self-describing word: 2 bits (`pkt_type`) + 14 bits (`addr_offset` for the 16 KB aperture) + 32 bits (payload). This avoids per-packet boundary tracking on the RX side; each word routes itself. A wider word would waste PHY bandwidth on padding; the `addr_offset` field grows proportionally if `RAM_ADDR_W` is increased.

### 9.3 Returner Interception Rather Than Bus Matrix Routing

The returner's credit-return and doorbell writes could traverse `ahb_sub_*` → XHB500 → AXI → Wlink, but this ties credit-return latency to AXI path congestion and requires an additional AHB master slot in the bus matrix. Instead, the FC adapter intercepts the returner's AHB writes and re-encodes them as SIDEBAND FC packets on the TideLink FC node. The returner is unmodified; it sees a compliant AHB slave with correct HREADY handshaking. No bus matrix master slot is needed. The trade-off is additional multiplexer logic in the FC adapter TX path.

### 9.4 Sideband Priority Over TX Aperture

When `rtn_pending_r` is set, `tl_fc_a2l_data` carries the sideband word and `ahb_tx_hreadyout` is suppressed via `~rtn_fc_valid`. Credit returns are infrequent but time-critical: delayed credits stall the remote sender, potentially causing deadlock if the remote side is itself waiting for credit. TX aperture data words experience at most one extra cycle of stall — negligible for bulk transfers.

### 9.5 Internal RX Masters Rather Than an External `ahb_fc_rx_*` Port

An earlier design exposed a single external AHB master (`ahb_fc_rx_*`) with `RX_FIFO_BASE` and `RX_CFG_BASE` parameters, requiring a bus matrix master slot and a full 32-bit address computation on every received FC word. Misconfigured base addresses caused silent data corruption and were a common integration error. The current design splits the RX path into two internal masters (`fc_rx_fifo_*` and `fc_rx_cfg_*`) with narrowed address widths (`RAM_ADDR_W` and `APB_ADDR_W`), eliminating both parameters and the external master port. The trade-off is two combinational muxes in `tidelink_top`.

### 9.6 Combinational 2:1 Muxes for FC Write Arbitration

Adding second AHB slave ports to `tidelink_fifo_ahb` would increase the complexity of that submodule. Instead, two 2:1 combinational muxes (`fifo_mux_*`, `cfg_mux_*`) in `tidelink_top` arbitrate between the FC adapter internal masters and the CPU-facing external slave ports. FC adapter has priority on both; CPU access is stalled via `hreadyout`. The muxes are localised, leave `tidelink_fifo_ahb` unchanged, and correctly prevent incoming data and sideband from being dropped by CPU contention.

### 9.7 Mailbox Pattern for Data-Plane Traffic

Transparent AHB read bridging stalls the host bus for the link round-trip — at 10 ns one-way latency and 100 MHz AHB, practical stalls reach 20–100 cycles per read due to link FIFO buffering and protocol framing. AHB SPLIT/RETRY would theoretically release the bus, but Cortex-M bus matrices do not implement it. Routing via the AXI path does not help: the XHB500 bridge holds AHB until the AXI response returns, reintroducing the same stall. The mailbox bounds AHB stall to the local FIFO write time (a handful of cycles); the CPU is free while the transaction is in flight. The cost is software overhead (~100–200 cycles of ISR entry and descriptor parsing per transaction), which is amortised well over bulk transfers and requires a CPU on the device side — satisfied by the nanoSoC Cortex-M0 pattern.

### 9.8 Chisel Regen Rather Than Verilog Wrapper for Wlink Extension

The TideLink FC node must be connected inside Wlink's TX and RX routers (WlinkTxRouter 6→7, WlinkRxRouter 7→8). A Verilog wrapper cannot modify internal router connections. A Verilog shim multiplexing onto an existing node risks data_id conflicts and complicates credit management. Forking `wav-wlink-hw`, modifying the Chisel, and regenerating Verilog produces a clean, internally consistent chiplet controller with a correctly assigned data_id (0xa1) and properly extended routers. Upstream Wlink updates can be tracked by merging the Chisel fork.

### 9.9 Two-Tier Implementation Strategy

**Tier 1 — Software-mediated (current)**: CPU on each side services descriptors via interrupts. Handles all transaction types; appropriate for control-plane and infrequent data transfers.

**Tier 2 — Hardware request engine (planned)**: An autonomous FSM on the device side services descriptors without CPU intervention, eliminating ISR overhead for bulk data-plane transfers. The packet format is unchanged; Tier 2 differs only in descriptor servicing. Both tiers use identical TideLink RTL — tier selection is a software and integration choice, not a hardware parameter.

### 9.10 PHY-Align: Integration Notes

The §9 PHY-Align subsystem (`tidelink_phy_align_calibrator.sv` +
`tidelink_lane_checker.sv` + the `swi_bit_slip[23:0]` / `swi_phase_offset` /
`swi_training_mode` / `swi_lane_locked[7:0]` / `swi_lane_fault[7:0]` /
`swi_calibration_done` register surface) has landed on `main`. This
subsection captures the design decisions whose only previous home was
the 2026-05-14 PHY-Align integration plan and next-steps docs (both
removed; their novel content is folded here and superseded by the
as-built RTL + this spec entry + the FPGA bring-up artefacts
`docs/archive/PHC_PHASE1_HW_REPORT.md`, `docs/CDC_AUDIT_REPORT.md`,
`docs/reference/SPYGLASS_CDC_SIGNOFF.md`).

**9.10.1 Sub-step ordering and what it bought us.** The PHY-align work
was sequenced in five gates, in order, each one validated before the
next was started:

1. **Layer 1 RTL prototype** — soft-strap regs (`swi_bit_slip`,
   `swi_training_mode`) in `WavD2DGpio*.v`; per-lane 16-bit right-rotation
   in `WavD2DGpioRx.v`; per-lane training-pattern mux in
   `WavD2DGpioTx.v`. Period-8 training bytes
   `0xA3,0xB5,0xC9,0xD3,0x65,0x4B,0x59,0x2D` were chosen to avoid the
   period-4 aliasing that the originally-proposed `(N+1)*0x11`
   pattern produced (slip=k and slip=k+4 would have been
   indistinguishable). **Do not revert to the (N+1)*0x11 pattern.**
2. **Cocotb sandbox** (8 PASS scenarios incl. uniform / asymmetric /
   partial-failure / retraining / asymmetric master+slave). Hierarchical
   force on the soft-strap regs — sufficient for the alignment proof but
   not for production sequencing.
3. **UVM integration** — surfaced the production-sequencing finding
   (`BRINGUP_REPORT.md §9.8`): asserting `swi_training_mode=1` before
   `role_lock` blocks LL_RX clock recovery because the training
   pattern displaces the cr_pkt traffic the receiver-side LinkLayer
   needs. **Cocotb papered over this via backdoor POR/clock force; UVM
   exercises the real APB-driven `strap → role_lock → swreset → cr_pkt`
   chain and catches it.** Any future calibration-related change must
   re-walk the UVM sequence, not just cocotb.
4. **APB plumbing** for the 5 control/status registers (now in Region 8
   at MMIO `0x4403_2100..0x4403_211F` — `tidelink_apb_regs.sv` Region 8
   carve, `ctrl_reg_addr` widened 3→4, `tidelink_fifo.sv` truncation
   fix). The interim shim at `0x4403_1000` has been deleted; the
   `tidelink_fifo.sv` `ctrl_reg_addr` widening is **critical** — without
   it Region 8 writes alias to Region 4.
5. **Autonomous calibration FSM in a TideLink-level wrapper** (not
   inside `WavD2DGpio.v`) so the Wavious source remains diff-clean. The
   FSM fires on `role_lock` rising, holds `swi_lltx_enable` off until
   `swi_calibration_done` asserts, and re-triggers on `swreset`.

**9.10.2 Calibrator skew-window vs search-window split (rationale).**
The calibrator has two distinct knobs and they bound two different
things:

- **Bit-slip [0..7]** is whole-bit (whole-UI) realignment. One slip
  step = one `pad_clk_rx` period (40 ns at the validated 25 MHz FPGA
  bench / one UI on ASIC). This is the **search window** — the range of
  byte-boundary misalignment the calibrator can recover from. It
  determines how unaligned the layout is *allowed to be* at static.
- **Phase [0..15]** is sub-bit sample-point adjust (`swi_phase_offset`,
  4 bits/lane). One phase step ≈ `T_UI/16`. This is the **skew window**
  — the granularity at which the calibrator can centre the eye within
  one UI. It determines the maximum *spread* of per-lane skew that can
  be absorbed while still hitting a common operating point.

The constraint job (`docs/reference/ASIC_TIMING_CONSTRAINTS.md`) is to keep the
**static + PVT** spread inside one phase step (≤ `T_UI/16`) — the
calibrator centres the rest dynamically. The constraint job is **not**
to keep the absolute skew at zero, because the calibrator does that for
free; it is to keep the *variance* small enough that one (slip,phase)
solution survives PVT corners and build-to-build re-runs. The
2026-05-14 finding `swi_phase_offset proven insufficient` refers to the
fact that on the *FPGA* the DLL is a pass-through placeholder
(`WavD2DRxDLL: assign clk_o = clk_i`), so phase is currently quantised
to whole `pad_clk_rx` periods — bit-slip carries the alignment, phase
re-indexes. On ASIC, phase must be a real sub-UI tap; otherwise the
skew window collapses to the slip step and the determinism requirement
is unmet. See §9.10.3.

**9.10.3 IDELAYE2 vs MMCM decision.** Two structural options were
considered for the per-lane phase tap:

- **MMCM-based per-lane phase shift**: rejected. An MMCM can produce 8
  phase-shifted versions of the recovered clock, but the per-lane phase
  becomes a *clock* selection, not a *data-tap* selection: 8 lane
  capture domains each on a different clock phase explode the CDC
  surface and require 8 independent synchroniser trees back to the
  Wlink core. The implementation cost is large and the result is harder
  to characterise across PVT.
- **IDELAYE2 per `pad_rx[n]` driven by the calibrator** (FPGA;
  characterised programmable-delay-cell equivalent on ASIC): selected.
  The clock remains single-domain (one `pad_clk_rx` capture clock for
  all 8 lanes — keeps the CDC count constant); the calibrator's
  per-lane `swi_phase_offset[4*N +: 4]` drives an explicit, characterised
  delay line per data lane. This is the structure documented in
  `docs/reference/ASIC_TIMING_CONSTRAINTS.md` Part A §4.3 (ASIC analogue) and the
  disabled-stanza Part B §3.5 (FPGA hook, pending the RTL-driver
  finalisation).

The decision is not negotiable for the determinism argument: an MMCM
phase-fanout structure would force `set_clock_groups -asynchronous`
between every lane and the others, re-creating exactly the
async-everything defect the constraint document warns against (see
`docs/reference/ASIC_TIMING_CONSTRAINTS.md` Part A §3). The per-lane data delay
keeps the source-sync `pad_rx[*] → capture` arc intact.

**9.10.4 What we will NOT do (preserved invariants).** From the
2026-05-14 plan, still binding:

- Do not rewrite the GPIO PHY with `ISERDESE2` — Xilinx-specific, does
  not translate to ASIC.
- Do not change the Wlink wire protocol — breaks the Wavious contract.
- Do not replace `swi_phase_offset` — it composes with bit-slip and is
  the ASIC-target lever for sub-UI margin (see §9.10.3).
- Do not drive calibration over the high-speed link itself
  (chicken-and-egg — the link is what we are aligning).
- Do not extract the PHY into its own repo preemptively. Wait for a
  concrete trigger (another consumer / Wavious upgrade / IP delivery).
- Do not gate the `LOCK_THRESHOLD` constant. Keep it at **16** — validated
  across the cocotb scenarios; bump only if hardware shows bit errors.

---

## 10. Integration Guide

### 10.1 Prerequisites

1. **tidelink-fifo submodule**: The `tidelink_fifo_ahb`, `tidelink_fifo.sv`, `tidelink_fifo_ctrl.sv`, `tidelink_apb_regs.sv`, `tidelink_returner.sv`, and `tidelink_sram.sv` modules from the `tidelink-fifo` repository (or local `src/rtl/fifo/` directory).
2. **axi-chiplet-controller submodule**: The modified Wlink fork including `tidelink_chiplet_controller`, `xhb500_ahb_to_axi_bridge_chiplet_slv`, `xhb500_axi_to_ahb_bridge_chiplet_mst`, and all Wlink-generated Verilog files.
3. **tidelink_addr_translator**: Available in `src/rtl/tidelink_addr_translator.sv`.
4. **CMSDK AHB-to-APB bridge**: `cmsdk_ahb_to_apb` (ARM Cortex-M System Design Kit). Used internally by `tidelink_fifo_ahb`.
5. A SoC bus matrix with sufficient master and slave ports (see below).

### 10.2 Bus Matrix Requirements

Connect the following TideLink ports to the SoC bus matrix:

**AHB Slaves (TideLink is a subordinate):**

| Port | Suggested address range | Notes |
|---|---|---|
| `ahb_sub_*` | Any range (e.g., 0x60000000–0x7FFFFFFF) | Regular remote AHB access. Decode must select this slave when targeting remote addresses. |
| `ahb_tx_*` | 16 KB (e.g., 0x50000000–0x50003FFF) | TideLink TX aperture. Must be exactly `2^RAM_ADDR_W` bytes. Align to `RAM_ADDR_W`-bit boundary. |
| `ahb_fifo_*` | 16 KB (e.g., 0x50004000–0x50007FFF) | RX FIFO data window. Internally muxed with FC adapter RX FIFO writes. |
| `ahb_adr_*` | Any (e.g., 0x40021000) | Address translator configuration. |

**AHB Masters (TideLink is a manager):**

| Port | Targets | Notes |
|---|---|---|
| `ahb_mng_*` | All local AHB slaves | Regular incoming remote AHB. Must have access to all addressable local slaves. |

Note: Unlike earlier versions, there is no external `ahb_fc_rx_*` AHB master port. The FC adapter RX path uses two internal masters (`fc_rx_fifo_*` and `fc_rx_cfg_*`) that are multiplexed inside `tidelink_top` with the `ahb_fifo_*` external slave port and the internal config path respectively. This eliminates the need for an additional bus matrix master slot for FC RX traffic.

**APB Slave:**

| Port | Suggested address range | Notes |
|---|---|---|
| `apb_*` | 32 KB APB region (e.g., 0x40020000) | Unified config: 0x0000-0x1FFF Wlink, 0x2000-0x203F TideLink |

### 10.3 Parameter Configuration

For a typical 32-bit Cortex-M0 SoC with the following address map:

```
0x50000000  TideLink TX aperture    (ahb_tx_*)     16 KB
0x50004000  TideLink RX FIFO        (ahb_fifo_*)   16 KB
0x50008000  Address translator cfg  (ahb_adr_*)     4 KB
0x50010000  Unified APB config      (apb_*)        32 KB
            ├─ 0x0000-0x1FFF  Wlink chiplet controller
            └─ 0x2000-0x203F  TideLink config + PTP
```

Instantiate as follows (illustrative — adjust to match your address map):

```systemverilog
tidelink_top #(
    .SYS_ADDR_W        (32),
    .SYS_DATA_W        (32),
    .RAM_ADDR_W        (14),      // 16 KB FIFO
    .RAM_DATA_W        (32),
    .APB_ADDR_W        (12),
    .FC_DATA_W         (48),
    .TIDELINK_PAIR_BASE(32'h5xxx4000)  // Remote chiplet's config register base
) u_tidelink (
    .hclk              (hclk),
    .hresetn           (hresetn),
    .poresetn          (poresetn),
    // ... connect bus matrix ports ...
);
```

**Important**: `TIDELINK_PAIR_BASE` must be set to the address of the **remote** chiplet's config register block as seen from the **local** system address map. No `RX_FIFO_BASE` or `RX_CFG_BASE` parameters are needed — the FC adapter RX path routes internally via muxes.

### 10.4 Interrupt Connections

Connect the four interrupt outputs to the CPU interrupt controller:

| Interrupt | Priority recommendation | Description |
|---|---|---|
| `packet_committed_irq` | High | New data available in RX FIFO. Service quickly to avoid FIFO backpressure. |
| `released_credits_irq` | Medium | Remote buffer space available. Use to resume transmission after a stall. |
| `doorbell_irq` | Medium | Remote-initiated signal. Application-defined semantics. |
| `wlink_irq` | Low | Wlink internal events (link error, training). Handle in link management task. |

### 10.5 Software Initialisation Sequence

1. **Assert reset**: Hold `hresetn` low. Ensure `poresetn` is also low initially.
2. **Release power-on reset**: Assert `poresetn` high once supplies and reference clock are stable.
3. **Configure Wlink via APB**: Write to the unified `apb_*` port (offsets 0x0000-0x1FFF) to configure PHY parameters, lane count, and link training as required by the Wlink APB register map.
4. **Wait for link training**: Poll Wlink status registers until the link is up and FC credits are initialised.
5. **Configure address translator**: Write the address translation mapping to `ahb_adr_*`.
6. **Configure TideLink FIFO**: Via the unified `apb_*` port (offsets 0x2000-0x203F):
   - Write `pair_base_addr` register (0x2000) if different from `TIDELINK_PAIR_BASE` default.
   - Write `release_threshold` (0x2004) to set credit batching granularity.
7. **Release system reset**: Assert `hresetn` high.
8. **Enable interrupts**: Enable `packet_committed_irq`, `released_credits_irq`, `doorbell_irq`, `wlink_irq` in the CPU interrupt controller.
9. **Exchange initial credits**: The remote chiplet must have also completed initialisation. Initial FC credits are established by Wlink during link training.

### 10.6 Reference Integration

The reference integration is the `nanosoc-chiplet-tech` project, which integrates TideLink as a replacement for `nanosoc_ss_chiplet_mng`. The nanosoc project provides a complete Cortex-M0 SoC with bus matrix, DMA, and interrupt controller, demonstrating the bus matrix connections and software driver structure.

---

## 11. Constraints and Limitations

### 11.1 AHB Subordinate Path — Read Latency

Read transactions on `ahb_sub_*` stall the AHB bus for the full link round-trip. At moderate link latencies (>10 ns at 100 MHz), practical stalls reach 20–100 cycles. Use the mailbox path (`ahb_tx_*`) with RD_REQ descriptors for bulk or latency-sensitive reads; reserve the transparent bridge for infrequent control-plane reads.

### 11.2 Single Clock Domain

All three clock inputs of `tidelink_chiplet_controller` (`apb_clk`, `app_clk`, `hsclk`) are driven from `hclk`, coupling link-layer timing to the AHB fabric clock. If independent frequencies are required, the Wlink clock inputs must be driven separately and CDC must be re-verified.

### 11.3 FC Adapter RX: Single Word in Flight

The RX FSM processes one FC word at a time. For FIFO_DATA packets, the FC adapter uses a direct valid/addr/data write interface to the FIFO memory, completing in a single cycle (vs. the previous 2-cycle AHB path). At 100 MHz, maximum RX FIFO throughput is 100 MWords/s (400 MB/s). SIDEBAND packets still use the 2-cycle APB path. The FIFO memory contains a simple SRAM arbiter that gives FC direct writes priority over CPU AHB reads, inserting at most 1 wait state per FC write on the CPU path.

### 11.4 TX Aperture: Write-Only

`ahb_tx_*` does not support reads; any read returns zero with an OKAY response. Declare the aperture non-readable in the system MPU configuration and do not issue DMA pre-fetches to this range.

### 11.5 Internal Mux Stalls During FC RX Writes

When `fc_rx_fifo_htrans[1]` is asserted, `ahb_fifo_hreadyout` is held low (FIFO mux). When `fc_rx_cfg_htrans[1]` is asserted, the config path stalls (Config mux). Stalls are typically 2 cycles and are transparent to software. Avoid cache or DMA pre-fetch from the FIFO (`ahb_fifo_*`) or config (`apb_*` at 0x2000+) address ranges.

### 11.6 Signal Naming: released_credits_irq

`tidelink_top.sv`, `tidelink_fifo_ahb.sv`, `tidelink_fifo.sv`, `tidelink_apb_regs.sv`, and `tidelink.sv` all use `released_credits_irq`. The legacy `tidelink_ahb.sv` wrapper retains the old name `released_tokens_irq`. Integrators using `tidelink_top` see the updated name at the top-level boundary.

### 11.7 TIDELINK_PAIR_BASE Default of Zero

`TIDELINK_PAIR_BASE` defaults to `'0`. An unconfigured instance targets address 0x00000000 on the remote chiplet for credit returns and doorbells, which is almost certainly incorrect. Always set this parameter explicitly. The removed `RX_FIFO_BASE` and `RX_CFG_BASE` parameters (see Section 6) are no longer needed.

### 11.8 Tier 2 Hardware Request Engine Not Yet Implemented

The Tier 2 autonomous descriptor engine is planned but absent from the current RTL. All servicing is software-mediated (Tier 1). The packet format is Tier 2 compatible; the verification suite (131 cocotb FIFO tests) is compatible with both tiers.

### 11.9 Address Translator Second Port Unused

`tidelink_addr_translator` provides two translation ports. The second port (`chp1_ahb_haddr_i/o`) is tied to zero and its output is left unconnected, available for a future second translated address region.

### 11.10 PTP Hardware Sync Initiator — PHC Time Inputs Required

The PTP hardware sync initiator requires the PHC's `seconds`, `nanoseconds`, and `pps` outputs to be wired to `tidelink_top`'s `phc_seconds`, `phc_nanoseconds`, and `phc_pps` input ports. These are in addition to the existing `phc_hw_capture` output. If the hardware sync initiator is not used, these inputs should be tied to zero.

The hardware sync initiator adds three registers in a new APB Region 2 (offsets 0x040–0x048): `HW_SYNC_CTRL`, `HW_SYNC_INTERVAL`, and `HW_SYNC_STATUS`. The APB address decode has been expanded from 1-bit (`paddr[5]`) to 2-bit (`paddr[6:5]`) to support this region, matching the PHC's decode pattern. Existing registers in Region 0 and Region 1 are unaffected.

### 11.11 Timing and Area Optimisations (v1.2)

Several architectural changes have been made to improve timing closure and reduce area:

**Address translator pipeline register** (`tidelink_top.sv`): A registered pipeline stage is inserted between the `address_translation` combinational output and the XHB500 AHB-to-AXI bridge. This breaks the 256:1 segment mux + adder critical path. Each new NONSEQ transfer incurs one additional wait state; SEQ beats within a burst pass through without stalling.

**FC adapter TX skid buffer** (`tidelink_fc_adapter.sv`): A single-entry skid buffer (48 flops) decouples the Wlink FC node's `tl_fc_a2l_ready` signal from the AHB HREADY critical path. In the common case (skid empty), AHB writes complete without any dependency on Wlink timing. The arbiter priority order (returner > servo > TX aperture) is preserved.

**Pipelined release threshold comparison** (`fifo/tidelink_apb_regs.sv`): The `read_complete` signal and `effective_acc` accumulator value are registered by one cycle before the 32-bit threshold comparison. `release_credits_trigger` fires one cycle after `read_complete` instead of combinationally. This is transparent at system level since the returner takes 3+ cycles per credit return transaction.

**APB-native FC RX config path** (`tidelink_fc_adapter.sv`, `tidelink_top.sv`): The FC adapter's RX config master now outputs APB signals directly (psel/penable/pwrite/paddr/pwdata) instead of AHB. This eliminates the `cmsdk_ahb_to_apb` bridge instance that previously sat between the FC adapter and the TideLink config APB mux, saving approximately 200-300 gates.

**Unused APB mux ports disabled** (`tidelink_addr_translator.sv`): The `cmsdk_apb_slave_mux` instance now has `PORT2_ENABLE` through `PORT15_ENABLE` set to 0, eliminating decode logic for the 14 unused ports.

**Big-endian byte swap gated by generate** (`tidelink_addr_translator.sv`): The byte-swap logic in the address translator is wrapped in `generate if (BE != 0)`. When `BE=0` (the only configuration in use), the swap registers and muxes are eliminated entirely.

**Direct FC-to-FIFO write path** (`tidelink_fc_adapter.sv`, `tidelink_fifo_mem.sv`, `tidelink_top.sv`): The FC adapter's RX FIFO path now uses a single-cycle valid/addr/data interface instead of a 2-cycle AHB master. This eliminates the 2:1 AHB mux in `tidelink_top`, removes the AHB address-phase overhead, and doubles RX FIFO throughput from 200 MB/s to 400 MB/s at 100 MHz. The FIFO memory includes a simple SRAM arbiter that prioritises FC writes over CPU AHB reads. The CPU read path remains AHB. Approximate gate savings: ~950 gates (AHB mux + write-path buffers in cmsdk_ahb_to_sram).

### 11.12 PHC Clock Domain Crossing (`tidelink_phc_cdc`)

When the external PHC runs on a separate clock (`phc_clk`) from TideLink (`hclk`), the `tidelink_phc_cdc` module provides safe clock domain crossing for all PHC ↔ TideLink signals. It is instantiated inside `tidelink_top.sv` and adds two new top-level ports: `phc_clk` and `phc_resetn`.

**Signal paths and mechanisms:**

| Path | Direction | Width | Mechanism | Latency |
|------|-----------|-------|-----------|---------|
| HW capture trigger | hclk→phc | 1b | Toggle pulse sync | 2-3 phc_clk |
| HW capture timestamps | phc→hclk | 110b | Quasi-static capture (done flag sync) | 2-3 hclk |
| Free-running PHC time | phc→hclk | 78b | Continuous req/ack handshake snapshot | 4-6 hclk |
| PPS pulse | phc→hclk | 1b | Toggle pulse sync | 2-3 hclk |
| Phase step command | hclk→phc | 79b | Data + req/ack handshake | 4-6 phc_clk |
| Frequency adjust | hclk→phc | 33b | Data + req/ack handshake | 4-6 phc_clk |

**Hardware cost:** ~526 FFs (~3,200 gates). Parameterizable synchronizer depth (`SYNC_STAGES`, default 2).

**Single-clock operation:** When `phc_clk = hclk`, the module adds benign pipeline latency (2-6 cycles per path). All existing functionality is preserved. This is the recommended configuration for systems where the PHC shares the AHB clock.

**Timestamp accuracy:** The CDC latency does not affect timestamp accuracy. The PHC captures the correct moment atomically via `hw_capture`; the CDC only delays delivery of the captured value to the servo. PTP offset computation uses the captured timestamps, not the transfer time.

---

## 12. Performance Profiling and Congestion Telemetry (`tidelink_perf`)

The `tidelink_perf` module passively observes the FC adapter and FIFO signals to produce saturating counters, event timestamps (sourced from the free-running PHC), and — as of the congestion-aware placement feature — a quantised per-link congestion signal exported to TideChart.

### 12.1 Congestion estimator

Three new local signals are derived from `credit_count`:

- **EWMA** over `credit_count`, `alpha = 1/16` (shift-and-add; tau approx 16 cycles).
- **Windowed derivative**, sampled every 256 cycles (`DERIV_WINDOW_LOG = 8`).
- **Credit-starve sticky flag**, latched on `credit_count == 0`, cleared by `bcast_ack_i`.

**Semantic convention:** `credit_count` high means the *remote* FIFO has room. Growing `credit_count` (positive derivative) means the remote side is draining (healthy). Shrinking `credit_count` means the remote FIFO is filling (congestion building). The quantiser encodes this directly — see [CONGESTION_AWARE_ROUTING.md](../../tidechart/docs/CONGESTION_AWARE_ROUTING.md) for the full trend and level tables.

### 12.2 Sideband interface

`tidelink_top` exports four new signals for TideChart:

| Signal | Direction | Width | Purpose |
|---|---|---|---|
| `tl_local_link_state_o`   | out | 5  | `{starve, trend[1:0], level[1:0]}` |
| `tl_link_state_change_o`  | out | 1  | one-cycle pulse on any quantised transition |
| `tl_ewma_credit_o`        | out | 13 | debug only; raw integer EWMA value |
| `tl_bcast_ack_i`          | in  | 1  | clears the credit-starve sticky after TideChart broadcasts |

All signals are combinational in `hclk` — no CDC is required between TideLink and TideChart.

### 12.3 Debug readback

The APB register space exposes the estimator state via `PERF_CONG_STATE` at Region 7 offset `3'h6`:

```
[12:0]  ewma_q_r (13-bit smoothed credit count)
[17:16] level
[19:18] trend
[20]    credit_starve_sticky
```

### 12.4 Parameter defaults

| Parameter | Default | Tuning range |
|---|---|---|
| `EWMA_ALPHA_SHIFT`   | 4   | 2..8 |
| `DERIV_WINDOW_LOG`   | 8   | 6..12 |
| `LOCAL_LINK_STATE_W` | 5   | fixed |

---

*End of TideLink Chiplet Interconnect Subsystem Specification and Design Justification*

*For questions about this specification contact SoC Labs at soclabs.org or open an issue in the TideLink repository.*

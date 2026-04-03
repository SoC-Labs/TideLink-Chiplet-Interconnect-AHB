# TideLink Chiplet Interconnect Subsystem — Specification and Design Justification

**Version**: 1.1
**Date**: 2026-04-03
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
 │  AHB Subordinate: TideLink config regs                        │      ││
 │  ahb_cfg_*  ──► Config Mux (2:1) ◄───────────────────────────┘      ││
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
 │  AHB Subordinate: Address translator config  ahb_adr_*                 │
 │  APB Subordinate: Chiplet controller config  apb_ctrl_*                │
 │  I2C Sideband: i2c_scl/sda                                             │
 │  General Bus: gb_in[31:0], gb_out[31:0]                                │
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
| `u_chiplet_controller` | `tidelink_chiplet_controller` | Modified Wlink: link layer, FC nodes, CRC/ECC, PHY |

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
- `ahb_cfg_*` — External CPU port (reads/writes config registers)

The FC adapter has priority (`fc_rx_cfg_active = fc_rx_cfg_htrans[1]`). When the FC adapter is active, `ahb_cfg_hreadyout` is driven low, stalling any concurrent CPU config access.

Both muxes are purely combinational and located in `tidelink_top`. There is no external `ahb_fc_rx_*` AHB master port — all FC adapter RX traffic is routed internally through these muxes.

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

Two packet types are defined:

- **FIFO_DATA (0b00)**: Carries one 32-bit word to be written into the remote RX FIFO. `addr_offset` is the byte address within the FIFO aperture (derived from the TX aperture AHB address). The RX adapter drives `addr_offset` directly on its `fc_rx_fifo_haddr` internal master port — no base address parameter is needed.
- **SIDEBAND (0b01)**: Carries a credit delta or doorbell write originating from the local returner. `addr_offset` is the lower 14 bits of the returner's target address (a TideLink APB register offset: 0x020 for credit delta, 0x024 for doorbell accumulator, 0x014 for reset doorbell). The RX adapter drives `addr_offset` directly on its `fc_rx_cfg_haddr` internal master port.

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
| generalbusgb | WlinkGenericFCSM_5 | 0xa0 | 32 bits | General Bus (interrupt forwarding) |
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

- **APB slave** (`apb_ctrl_*`): Wlink internal configuration — link training, PHY parameters, FC credit initialisation, interrupt status.
- **AXI slave** (`s_axi_*`): Outbound AXI from XHB500 bridge; packetised into FC nodes 0x80–0x84.
- **AXI master** (`m_axi_*`): Inbound AXI from FC nodes 0x80–0x84; driven into XHB500 bridge.
- **General bus** (`gb_in[31:0]`, `gb_out[31:0]`): 32-bit interrupt forwarding via FC node 0xa0.
- **I2C sideband** (`i2c_scl_i/o/t`, `i2c_sda_i/o/t`): Out-of-band sideband channel for link bring-up and management.
- **PHY pads** (`pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]`): 8-lane plus clock die-to-die physical interface.
- **Reset sideband** (`sb_reset_in`, `sb_reset_out` / `d2d_reset_o`): Power-on reset coordination across the link.
- **Interrupts** (`wlink_irq`): Wlink internal interrupt (link error, training completion, etc.).

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

### 5.6 AHB Subordinate — TideLink Config Registers (`ahb_cfg_*`)

Standard AHB-Lite subordinate (Section 5.2, A=`APB_ADDR_W`=12). Access to TideLink FIFO config and status registers via a CMSDK AHB-to-APB bridge inside `tidelink_fifo_ahb`. Internally multiplexed with the FC adapter RX config master via the Config mux (Section 3.6). `ahb_cfg_hreadyout` is held low when the FC adapter RX config master is active.

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

**`fc_rx_cfg_*`** — Writes SIDEBAND payloads (credit deltas, doorbells) to the local APB config registers (via Config mux):

| Signal | Width | Description |
|---|---|---|
| `fc_rx_cfg_haddr[APB_ADDR_W-1:0]` | 12 | APB register offset (addr_offset from FC word) |
| `fc_rx_cfg_hwdata[31:0]` | 32 | Payload from FC word |
| `fc_rx_cfg_htrans[1:0]` | 2 | IDLE or NONSEQ |
| `fc_rx_cfg_hsize[2:0]` | 3 | Always HSIZE_WORD |
| `fc_rx_cfg_hwrite` | 1 | Always 1 when active |

Both ports use narrowed address widths (not full 32-bit system addresses) since they connect directly to the internal muxes in front of `tidelink_fifo_ahb` slave ports.

### 5.9 AHB Subordinate — Address Translator Config (`ahb_adr_*`)

Standard AHB-Lite subordinate (Section 5.2, A=32). Runtime configuration of the address translation mapping applied to `ahb_sub_haddr`.

### 5.9 APB Subordinate — Chiplet Controller Config (`apb_ctrl_*`)

APB3 subordinate for Wlink/chiplet controller configuration. Drives the APB slave port of `tidelink_chiplet_controller` directly.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `apb_ctrl_paddr[12:0]` | In | 13 | Register address |
| `apb_ctrl_penable` | In | 1 | APB enable phase |
| `apb_ctrl_pwrite` | In | 1 | Write enable |
| `apb_ctrl_pstrb[3:0]` | In | 4 | Byte strobes |
| `apb_ctrl_pprot[2:0]` | In | 3 | Protection attributes |
| `apb_ctrl_pwdata[31:0]` | In | 32 | Write data |
| `apb_ctrl_psel` | In | 1 | Slave select |
| `apb_ctrl_prdata[31:0]` | Out | 32 | Read data |
| `apb_ctrl_pready` | Out | 1 | Slave ready |
| `apb_ctrl_pslverr` | Out | 1 | Slave error |

### 5.10 I2C Sideband

Tri-state I2C interface for Wlink out-of-band link management and bring-up.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `i2c_scl_i` | In | 1 | SCL input |
| `i2c_scl_o` | Out | 1 | SCL output (active drive) |
| `i2c_scl_t` | Out | 1 | SCL tristate enable (1 = high-Z) |
| `i2c_sda_i` | In | 1 | SDA input |
| `i2c_sda_o` | Out | 1 | SDA output |
| `i2c_sda_t` | Out | 1 | SDA tristate enable |

### 5.11 General Bus

32-bit bus for cross-link interrupt forwarding via Wlink FC node 0xa0.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `gb_in[31:0]` | In | 32 | Interrupts to send to remote chiplet |
| `gb_out[31:0]` | Out | 32 | Interrupts received from remote chiplet |

### 5.12 PHY Pads

8-lane source-synchronous die-to-die interface.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `pad_clk_tx` | Out | 1 | Transmit clock |
| `pad_tx[7:0]` | Out | 8 | Transmit data lanes |
| `pad_clk_rx` | In | 1 | Receive clock (from remote chiplet) |
| `pad_rx[7:0]` | In | 8 | Receive data lanes |

### 5.13 Interrupt Outputs

| Signal | Direction | Width | Description |
|---|---|---|---|
| `released_credits_irq` | Out | 1 | Remote chiplet has returned FIFO credits (remote RX FIFO has space) |
| `doorbell_irq` | Out | 1 | Remote chiplet has sent a doorbell |
| `packet_committed_irq` | Out | 1 | An inbound packet has been written into the local RX FIFO |
| `wlink_irq` | Out | 1 | Wlink internal interrupt (link error, training, etc.) |

### 5.14 Reset Output

| Signal | Direction | Width | Description |
|---|---|---|---|
| `d2d_reset_o` | Out | 1 | Sideband reset signal from Wlink (`sb_reset_out`). Can be connected to the remote chiplet's reset input for cross-link reset coordination. |

---

## 6. Configuration Parameters

All parameters are defined on the `tidelink_top` module and propagated to sub-instances.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `SYS_ADDR_W` | integer | 32 | System address width in bits. Must match the AHB bus address width. |
| `SYS_DATA_W` | integer | 32 | System data width in bits. Must be 32 for AHB-Lite compatibility with XHB500. |
| `RAM_ADDR_W` | integer | 14 | FIFO SRAM address width. Determines FIFO capacity: 2^`RAM_ADDR_W` bytes. Default 14 gives 16 KB. Also sets the TX aperture address width. |
| `RAM_DATA_W` | integer | 32 | FIFO SRAM data width in bits. |
| `APB_ADDR_W` | integer | 12 | APB register address width. Determines the address range of the `ahb_cfg_*` port. |
| `FC_DATA_W` | integer | 48 | FC node data width. Must match the TideLink FC node in the chiplet controller (WlinkGenericFCSM_6). Do not change unless regenerating the Chisel. |
| `TIDELINK_PAIR_BASE` | `[SYS_ADDR_W-1:0]` | 0 | Default pair base address for the returner. This is the base address of the remote TideLink APB register block as seen from the local system address map. Used as the reset default for the pair base address register (APB offset 0x000). Can be overridden at runtime by writing to the register. |

Note: Earlier versions of TideLink included `RX_FIFO_BASE` and `RX_CFG_BASE` parameters for the FC adapter RX path. These have been eliminated. The RX path now uses two internal AHB master ports with narrowed address widths (`RAM_ADDR_W` and `APB_ADDR_W` respectively) that connect directly to the FIFO and Config muxes inside `tidelink_top`. The `addr_offset` from each FC word is used as the AHB address without adding a base, so no base address parameters are needed.

---

## 7. Data Flow and Protocol

### 7.1 TideLink Packet Format

Software on the sending side constructs packets by writing sequential 32-bit words to the TideLink TX aperture (`ahb_tx_*`). The first word at address offset 0x0000 is a framing word specifying the number of payload words that follow. Words 1–3 form the packet descriptor header. Subsequent words are the payload.

```
FIFO Addr   Content
┌──────────┬────────────────────────────────────────────────────────────────┐
│ 0x0000   │ FIFO Length (N) — count of words following this word           │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x0004   │ pkt_type[31:28], src_id[27:20], dest_id[19:12],                │
│          │ tag[11:4], status[3:2], burst_type[1:0]                        │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x0008   │ dest_addr[31:0]                                                │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x000C   │ length[15:3], size[2:0]                                        │
├──────────┼────────────────────────────────────────────────────────────────┤
│ 0x0010+  │ Data payload (WR_REQ data / RD_RSP data)                       │
└──────────┴────────────────────────────────────────────────────────────────┘
```

**Header field definitions:**

| Field | Width | Description |
|---|---|---|
| `pkt_type` | 4 bits | Transaction type: RD_REQ, WR_REQ, RD_RSP, WR_RSP, ERROR |
| `src_id` | 8 bits | Requester chiplet ID (for response routing) |
| `dest_id` | 8 bits | Target chiplet ID (for multi-hop daisy-chaining) |
| `tag` | 8 bits | Transaction tag (matches response to request) |
| `status` | 2 bits | Response status: OKAY / ERROR |
| `burst_type` | 2 bits | AHB burst type mirror: SINGLE / INCR / WRAP |
| `dest_addr` | 32 bits | Target address on remote chiplet |
| `length` | 13 bits | Number of beats in burst |
| `size` | 3 bits | Beat size (mirrors AHB HSIZE) |

Software constructs this structure in memory and writes it word-by-word to the TX aperture. Hardware transports each word as a separate FIFO_DATA FC packet. The receiving software reconstructs the packet from the FIFO.

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

1. Host CPU writes FIFO length word, descriptor (3 words), and data payload to TX aperture (`ahb_tx_*`).
2. Each AHB write is converted by the FC adapter to a FIFO_DATA packet carrying `{00, haddr[13:0], hwdata}`.
3. Packets traverse the TideLink FC node (data_id=0xa1) through Wlink.
4. Remote FC adapter receives each packet and drives an internal AHB master write on `fc_rx_fifo_*` with `haddr = addr_offset`. The FIFO mux routes this to the `tidelink_fifo_ahb` FIFO data window slave port.
5. The remote `tidelink_fifo_ahb` FIFO accumulates words. When the final word of the packet is written (determined by the length field at offset 0), `packet_committed_irq` fires.
6. Device CPU services the interrupt, pops the descriptor, and performs the requested local AHB write.
7. Optionally, a WR_RSP packet is constructed and sent back.

### 7.3 Read Request Flow (Host → Device → Host)

1. Host CPU writes RD_REQ descriptor to TX aperture (no data payload).
2. Descriptor traverses link as described above.
3. Device CPU services interrupt, pops descriptor, performs local AHB reads at `dest_addr`.
4. Device CPU constructs RD_RSP packet: writes RD_RSP header + read data to device TX aperture.
5. RD_RSP traverses back to host chiplet.
6. Host RX FIFO accumulates RD_RSP. `packet_committed_irq` fires on host.
7. Host CPU pops response data. Bus is never stalled; host CPU was free between steps 1 and 7.

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

### 9.1 Why a Dedicated FC Node for the Mailbox Path?

**Problem**: The mailbox path requires a direct FIFO-to-FIFO transport that carries application-defined data without address translation, AXI protocol framing, or the overhead of the AXI bridge path.

**Alternative considered**: Using existing AXI FC nodes (0x80–0x84). This would require generating AXI write transactions from the TX aperture, which implies an AHB-to-AXI conversion layer for what is conceptually a simple FIFO push. The remote side would receive AXI write transactions and would need additional logic to detect and store them in the correct FIFO location. Credit accounting would be shared with AXI FC credits, coupling mailbox flow control to AXI traffic.

**Chosen approach**: Add a dedicated FC node (WlinkGenericFCSM_6, data_id=0xa1) with a 48-bit data width. Each FC word carries both a data payload and an address, making the RX adapter stateless. Mailbox credits are independent of AXI credits, preventing credit starvation between the two traffic classes. The implementation is also simpler: the FC adapter is a small combinational/FSM block rather than a full AXI master.

**Trade-off accepted**: Requires modifying the Chisel source of `wav-wlink-hw` and regenerating the Wlink Verilog. This is a non-trivial one-time cost but produces a maintainable, versioned fork that can track Wlink releases.

### 9.2 Why 48-bit FC Data Width?

**Problem**: The FC word must carry a 32-bit FIFO payload plus enough addressing information to let the RX adapter write to the correct FIFO location without maintaining state.

**Chosen**: 48 bits = 2 bits (pkt_type) + 14 bits (addr_offset for 16 KB aperture) + 32 bits (payload).

**Alignment**: 48 bits matches the data width of the existing axiwFC node (WlinkGenericFCSM_1, 37 bits as measured from RTL — the plan document quoted 48 bits reflecting the target for the new TideLink node). Using a width that maps cleanly to Wlink's internal packet alignment avoids padding overhead.

**Why not wider**: 48 bits is the minimum necessary. A wider word would waste PHY bandwidth on padding for most transactions.

### 9.3 Why Intercept the Returner Rather Than Route It to the Bus Matrix?

**Problem**: The returner needs to write credit delta and doorbell values to registers on the remote chiplet. In a naive implementation this would require an additional AHB master port on the bus matrix, with routing to the remote side via the regular AXI bridge path.

**Alternative**: Connect returner AHB master to bus matrix. The returner's writes would traverse `ahb_sub_*` → XHB500 → AXI → Wlink → remote. This pollutes the AXI path with small, latency-sensitive control writes. It also creates a dependency between credit-return responsiveness and AXI path congestion: if the AXI FC nodes are stalled by data traffic, credit returns are delayed, causing the sending side to back off. It also requires an additional AHB master slot in the bus matrix.

**Chosen**: Intercept the returner's AHB master writes within the FC adapter and re-encode them as SIDEBAND packets on the dedicated TideLink FC node. The returner sees a compliant AHB slave (the FC adapter presents correct HREADY handshaking) and is unchanged. Credit returns and doorbells ride the same FC node as FIFO data, but with a distinct pkt_type field ensuring correct routing at the RX side. No bus matrix master port is needed.

**Trade-off accepted**: The FC adapter is more complex: it must present a synthesisable AHB slave to the returner and multiplex its sideband packets with TX aperture FIFO data onto the single FC TX interface. The priority scheme (sideband > TX aperture) adds a small timing dependency. This is justified because credit-return delays cause backpressure on the sending side; prioritising sideband over data minimises this.

### 9.4 Why Sideband Priority Over TX Aperture?

**Problem**: When the returner needs to send a credit return simultaneously with the CPU streaming data through the TX aperture, one must yield.

**Chosen**: Returner sideband takes priority. When `rtn_pending_r` is set, `tl_fc_a2l_data` is driven with the sideband word and `ahb_tx_hreadyout` is suppressed (by the `~rtn_fc_valid` term).

**Justification**: Credit returns are infrequent (fire at most once per credit-release threshold) but time-sensitive: delaying credit return causes the remote sender to stall when it exhausts its credit allocation, potentially deadlocking the system if the remote sender is also waiting for credit before it can write to its own TX aperture. Data words in the TX aperture, by contrast, experience only a single-cycle stall — negligible for bulk transfers.

### 9.5 Why Internal RX Masters Rather Than an External `ahb_fc_rx_*` Port?

**Problem**: Received FC data must reach two distinct targets: the FIFO data window (for FIFO_DATA packets) and the APB config registers (for SIDEBAND packets). An earlier design exposed a single external AHB master (`ahb_fc_rx_*`) that computed full system addresses from `RX_FIFO_BASE`/`RX_CFG_BASE` parameters and required a bus matrix master slot.

**Chosen**: Split the RX path into two internal AHB masters (`fc_rx_fifo_*` and `fc_rx_cfg_*`) with narrowed address widths. Each feeds into a 2:1 mux inside `tidelink_top` that arbitrates with the corresponding external CPU-facing slave port. No external AHB master port is needed.

**Justification**: This eliminates the `RX_FIFO_BASE` and `RX_CFG_BASE` parameters entirely — a common source of integration errors (misconfigured base addresses causing silent data corruption). It also removes the need for an additional bus matrix master slot, simplifying SoC integration. The trade-off is two internal muxes, but these are small combinational blocks with well-defined priority (FC always wins).

### 9.6 Why 2:1 Muxes Rather Than Dedicated Slave Ports for FC Writes?

**Problem**: Both the FIFO data window and the config register block must be accessible by two sources: the FC adapter RX internal masters (writing incoming packets and sideband) and the external CPU ports (reading packets, reading/writing config). The `tidelink_fifo_ahb` module exposes a single AHB slave for each.

**Alternative**: Add second AHB slave ports to `tidelink_fifo_ahb` for FC writes, eliminating the muxes.

**Chosen**: Two 2:1 combinational muxes in `tidelink_top` — one for the FIFO data window (`fifo_mux_*`) and one for the config registers (`cfg_mux_*`). FC adapter RX has priority on both; CPU access is stalled via `hreadyout` when the FC adapter is active.

**Justification**: Modifying `tidelink_fifo_ahb` to add second slave ports would increase the size and complexity of the FIFO submodule. The muxes are clean, localised additions in the top-level that leave the FIFO module unchanged. Priority for FC writes is correct: incoming data and credit/doorbell sideband must not be dropped due to CPU contention.

### 9.7 Why a Mailbox Pattern Rather Than Transparent AHB Bridge for Data Plane Traffic?

**Problem**: Transparent AHB bridging stalls the CPU bus for the full round-trip time of every read transaction. For chiplet link latencies of 5–20 ns at 100 MHz AHB, this is 1–4 additional cycles per read in the ideal case, but practical latencies (link negotiation, FIFO buffering, protocol framing) are higher, easily reaching 20–100 cycles.

**Alternative**: AHB SPLIT/RETRY. Theoretically allows the bus to be released during a long-latency response. Not implemented in Cortex-M bus matrices; requires bus arbiter changes incompatible with existing SoC infrastructure.

**Alternative**: Use only the AXI path. AXI supports outstanding transactions, mitigating the blocking problem. But Wlink's AXI path still imposes end-to-end latency, and the XHB500 bridge does not provide zero-latency completion: the bridge holds the AHB bus until the AXI response is received, which reintroduces the stall on the AHB side.

**Chosen**: Software-mediated mailbox. CPU writes a descriptor and is immediately free. AHB bus stalling is bounded by the local FIFO write time (a handful of cycles), not the link RTT. This is the correct solution for a Cortex-M class system where link latency dominates and the CPU has other work to do while waiting for remote data.

**Trade-off accepted**: Adds software overhead (ISR entry, descriptor parsing, buffer management). Single 32-bit reads incur ~100–200 cycles of overhead on top of link latency. This is acceptable and amortised well for bulk transfers (one descriptor covers any burst length). It requires a CPU on the device side to service requests — the nanoSoC pattern (Cortex-M0 on each chiplet) satisfies this requirement.

### 9.8 Why Modify Wlink via Chisel Regen Rather Than Adding a Verilog Wrapper?

**Problem**: The TideLink FC node must be integrated into Wlink's TX and RX routers (WlinkTxRouter 6→7, WlinkRxRouter 7→8). A Verilog wrapper cannot extend internal router connections.

**Alternative**: Write a Verilog shim that muxes a new FC node onto the existing `generalbusgb` FC node or onto an unused channel. This is fragile, data_id conflicts are difficult to avoid, and it complicates credit management.

**Chosen**: Fork `wav-wlink-hw`, modify the Chisel source, and regenerate Verilog. This produces a clean, internally consistent Wlink instance with a proper data_id assignment (0xa1) and correctly extended routers. Future Wlink upstream updates can be tracked by merging the Chisel fork.

### 9.9 Two-Tier Implementation Strategy

TideLink defines two implementation tiers:

**Tier 1 — Software-mediated (current implementation)**: CPU on each side services transaction descriptors via interrupts. Maximum flexibility, correct for control-plane traffic, small/infrequent reads, and early prototyping.

**Tier 2 — Hardware request engine (planned)**: A small autonomous FSM on the device side that can service read and write descriptors without CPU intervention. Equivalent to a micro-DMA engine, it eliminates ISR overhead for data-plane traffic. Planned for bulk SRAM read use cases in the megaSoC reference design. The packet format is unchanged — Tier 2 differs only in who services the descriptor on the device side.

The two tiers share the same hardware: all TideLink RTL supports both. Tier selection is a software and SoC integration decision, not a hardware parameter.

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
| `ahb_cfg_*` | 4 KB (e.g., 0x50008000–0x50008FFF) | TideLink config registers. Internally muxed with FC adapter RX sideband writes. |
| `ahb_adr_*` | Any (e.g., 0x40021000) | Address translator configuration. |

**AHB Masters (TideLink is a manager):**

| Port | Targets | Notes |
|---|---|---|
| `ahb_mng_*` | All local AHB slaves | Regular incoming remote AHB. Must have access to all addressable local slaves. |

Note: Unlike earlier versions, there is no external `ahb_fc_rx_*` AHB master port. The FC adapter RX path uses two internal masters (`fc_rx_fifo_*` and `fc_rx_cfg_*`) that are multiplexed inside `tidelink_top` with the `ahb_fifo_*` and `ahb_cfg_*` external slave ports respectively. This eliminates the need for an additional bus matrix master slot for FC RX traffic.

**APB Slave:**

| Port | Suggested address range |
|---|---|
| `apb_ctrl_*` | Any 8 KB APB region (e.g., 0x40023000) |

### 10.3 Parameter Configuration

For a typical 32-bit Cortex-M0 SoC with the following address map:

```
0x50000000  TideLink TX aperture    (ahb_tx_*)     16 KB
0x50004000  TideLink RX FIFO        (ahb_fifo_*)   16 KB
0x50008000  TideLink config regs    (ahb_cfg_*)     4 KB
0x50009000  Address translator cfg  (ahb_adr_*)     4 KB
0x5000A000  Chiplet controller APB  (apb_ctrl_*)    8 KB
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
3. **Configure Wlink via APB**: Write to `apb_ctrl_*` to configure PHY parameters, lane count, and link training as required by the Wlink APB register map.
4. **Wait for link training**: Poll Wlink status registers until the link is up and FC credits are initialised.
5. **Configure address translator**: Write the address translation mapping to `ahb_adr_*`.
6. **Configure TideLink FIFO**: Via `ahb_cfg_*`:
   - Write `pair_base_addr` register (0x000) if different from `TIDELINK_PAIR_BASE` default.
   - Write `release_threshold` (0x004) to set credit batching granularity.
   - Set CTRL EN bit (0x01C bit [0]) to enable the FIFO.
7. **Release system reset**: Assert `hresetn` high.
8. **Enable interrupts**: Enable `packet_committed_irq`, `released_credits_irq`, `doorbell_irq`, `wlink_irq` in the CPU interrupt controller.
9. **Exchange initial credits**: The remote chiplet must have also completed initialisation. Initial FC credits are established by Wlink during link training.

### 10.6 Reference Integration

The reference integration is the `nanosoc-chiplet-tech` project, which integrates TideLink as a replacement for `nanosoc_ss_chiplet_mng`. The nanosoc project provides a complete Cortex-M0 SoC with bus matrix, DMA, and interrupt controller, demonstrating the bus matrix connections and software driver structure.

---

## 11. Constraints and Limitations

### 11.1 AHB Subordinate Path — Read Latency

Read transactions on `ahb_sub_*` stall the AHB bus for the full link round-trip time. At moderate link latencies (>10 ns at 100 MHz), this causes significant throughput degradation for read-intensive workloads. Use the mailbox path (`ahb_tx_*`) with RD_REQ descriptors for latency-tolerant reads or bulk read transfers. The transparent bridge is appropriate only for infrequent control-plane reads.

### 11.2 Single Clock Domain

The current implementation drives all three clock inputs of `tidelink_chiplet_controller` from `hclk`. This couples the link-layer timing to the AHB fabric clock. If the AHB fabric and link layer must operate at different frequencies, the Wlink clock inputs must be driven independently and CDC must be verified. This is a planned enhancement for future integration into higher-performance systems.

### 11.3 FC Adapter RX: Single Word in Flight

The FC adapter RX FSM processes one FC word at a time (latch → AHB write → next). Back-to-back FC words stall in the Wlink FC FIFO while the AHB write is in progress. For high-rate mailbox transfers, the link-side FC credits limit throughput to at most one AHB write cycle per FC word. At 100 MHz AHB with a two-cycle AHB write, this gives a maximum RX throughput of 50 MWords/s (200 MB/s). This is sufficient for Cortex-M0 class applications; higher-performance systems would require a pipelined RX path.

### 11.4 TX Aperture: Write-Only

The TX aperture slave (`ahb_tx_*`) does not support reads. Any AHB read transaction to this address range will receive zero data and an OKAY response. The aperture should be declared non-readable in the system MPU configuration.

### 11.5 Internal Muxes: CPU Access Stall During FC RX Writes

Two internal 2:1 muxes arbitrate access to `tidelink_fifo_ahb` slave ports:

- **FIFO Mux**: When the FC adapter RX FIFO master is active (`fc_rx_fifo_htrans[1]`), `ahb_fifo_hreadyout` is held low. CPU reads from the RX FIFO stall for the duration of each incoming AHB write (typically 2 cycles).
- **Config Mux**: When the FC adapter RX config master is active (`fc_rx_cfg_htrans[1]`), `ahb_cfg_hreadyout` is held low. CPU access to config registers stalls for the duration of each incoming sideband write.

This is a correctness requirement (FC writes must not be dropped) and is transparent to software provided the CPU handles it as a normal wait-state extension. Cache or DMA pre-fetch from the FIFO or config address ranges should be avoided.

### 11.6 Signal Naming: released_credits_irq

The interrupt naming has been aligned across most of the design. `tidelink_fifo_ahb.sv`, `tidelink_fifo.sv`, `tidelink_apb_regs.sv`, `tidelink.sv`, and `tidelink_top.sv` all use `released_credits_irq`. The legacy `tidelink_ahb.sv` wrapper still uses the old name `released_tokens_irq`. Integrators using `tidelink_top` see `released_credits_irq` consistently at the top-level boundary.

### 11.7 No Read Data from TX Aperture or Returner Interception

Both the TX aperture slave and the returner interception slave return zero on `hrdata`. The TX aperture is write-only by design. The returner never issues reads (it is a write-only master), so the interception slave's read data path is unused. If diagnostic access to these paths is needed, it must be implemented at a higher level.

### 11.8 TIDELINK_PAIR_BASE Default of Zero

The default value of `TIDELINK_PAIR_BASE` is `'0` (all zeros). If the parameter is not set by the integrator, the returner will target address 0x00000000 on the remote chiplet, which is almost certainly incorrect. Integrators must always set `TIDELINK_PAIR_BASE` explicitly. Leaving the default in place will result in incorrect credit return and doorbell behaviour. (The former `RX_FIFO_BASE` and `RX_CFG_BASE` parameters have been removed — see Section 6.)

### 11.9 Tier 2 Hardware Request Engine Not Yet Implemented

The Tier 2 hardware request engine (autonomous descriptor servicing without CPU intervention) is planned but not yet part of the TideLink RTL. All transaction servicing is currently software-mediated (Tier 1). The packet format supports Tier 2 operation and the existing verification infrastructure (131 cocotb FIFO tests) is compatible with both tiers.

### 11.10 Address Translator Second Port Unused

`tidelink_addr_translator` is instantiated with two translation ports. The second port (`chp1_ahb_haddr_i/o`) is tied to zero input and its output is left unconnected. It is available for future extension if a second translated address region is required.

---

*End of TideLink Chiplet Interconnect Subsystem Specification and Design Justification*

*For questions about this specification contact SoC Labs at soclabs.org or open an issue in the TideLink repository.*

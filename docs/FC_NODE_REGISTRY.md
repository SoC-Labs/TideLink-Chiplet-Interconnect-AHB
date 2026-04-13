# Wlink FC Node `data_id` Registry

Canonical allocation table for Wlink flow-control (FC) `data_id` values
across the SoC Labs chiplet ecosystem. When adding a new FC node, pick
an unallocated ID from the free list below and add an entry here in
the same PR that introduces the node.

**Version**: 1.0
**Date**: 2026-04-13
**Maintainer**: SoC Labs (www.soclabs.org)

---

## Allocated IDs

### Short-packet IDs

| data_id     | Purpose                                     | Source / owner                                  |
|-------------|---------------------------------------------|-------------------------------------------------|
| 0x08 - 0x27 | AXI short-packet IDs (20 IDs across 5 channels) | `axi-chiplet-controller/wav-wlink-hw/src/main/scala/AXI.scala` |
| 0x30 - 0x37 | APB short-packet IDs                        | `axi-chiplet-controller/wav-wlink-hw/src/main/scala/APB.scala` |
| 0x40 - 0x43 | GeneralBus short-packet IDs (CR / CRACK / ACK / NACK) | `axi-chiplet-controller/wav-wlink-hw/src/main/scala/GeneralBus.scala` |
| 0x44 - 0x47 | TideLink short-packet IDs (CR / CRACK / ACK / NACK) | `axi-chiplet-controller/wav-wlink-hw/src/main/scala/TideLink.scala` |

### Long-packet (data) IDs

| data_id | Purpose                 | Width  | Source / owner                                          |
|---------|-------------------------|--------|---------------------------------------------------------|
| 0x80    | AXI AW                  | —      | `axi-chiplet-controller/.../scala/AXI.scala`            |
| 0x81    | AXI W                   | —      | `axi-chiplet-controller/.../scala/AXI.scala`            |
| 0x82    | AXI B                   | —      | `axi-chiplet-controller/.../scala/AXI.scala`            |
| 0x83    | AXI AR                  | —      | `axi-chiplet-controller/.../scala/AXI.scala`            |
| 0x84    | AXI R                   | —      | `axi-chiplet-controller/.../scala/AXI.scala`            |
| 0x90    | APB initiator           | —      | `axi-chiplet-controller/.../scala/APB.scala`            |
| 0xa0    | GeneralBus (deprecated) | 32     | `axi-chiplet-controller/.../scala/GeneralBus.scala` — scheduled for retirement once IRQC lands (previous cross-chiplet IRQ forwarding path via `gb_in[31:0]` / `gb_out[31:0]`). |
| 0xa1    | TideLink                | 48     | `axi-chiplet-controller/.../scala/TideLink.scala`        |
| 0xa2    | PTP                     | 48     | TideLink README §FC Nodes (PTP integration)             |
| 0xa3    | **Chiplet IRQC**        | **64** | `ahb-chiplet-interrupt-controller` (this IP)            |

---

## Free IDs

The following data_id values are currently unallocated. New FC nodes
should pick from this list and update the table above.

- **Long-packet IDs**: 0x85 - 0x8F, 0x91 - 0x9F, 0xa4 - 0xFF
- **Short-packet IDs**: 0x00 - 0x07, 0x28 - 0x2F, 0x38 - 0x3F, 0x48 - 0x7F

---

## Process for Adding a New FC Node

1. Open an issue describing the new node's purpose, width, and
   expected throughput.
2. Reserve a data_id by editing this file in the same branch as the
   new node's Scala / SystemVerilog source.
3. Update the relevant SoC Labs spec document (e.g. your IP's
   `docs/SPECIFICATION.md`) referencing the assigned ID.
4. Check for collisions with short-packet IDs if your node uses any.

## Notes

- **Width 48 vs 64**: Wlink FC nodes can be configured for any width
  that fits within the link layer's credit unit. TideLink and PTP
  use 48-bit words; the IRQC uses 64-bit words to carry a full 32-bit
  chiplet bitmap in a single TREE_BCAST packet.
- **0xa0 GeneralBus retirement**: This node was used by `tidelink_top`
  (`gb_in` / `gb_out`) as a lightweight cross-chiplet interrupt
  forwarding path. It is scheduled for removal once the dedicated
  Chiplet IRQC (`data_id = 0xa3`) is validated. Track the deprecation
  in the IRQC repo's STATUS.md.

# TideLink Register Map

This document describes the complete register map for the TideLink subsystem,
covering TideLink-specific registers, PTP registers, PHC registers, address
translator registers, and the Wlink chiplet controller registers.

## Address Space Overview

TideLink exposes a single unified APB port (`apb_*`, 15-bit address) for all
configuration registers, plus a separate AHB port for the address translator:

| Interface | Protocol | Address Width | Description |
|---|---|---|---|
| `apb_*` | APB | 15-bit | Unified config port (Wlink + TideLink registers) |
| `ahb_adr_*` | AHB (bridged to APB) | 32-bit | Address translator configuration |

### Unified APB Address Map

| Address Range | Region |
|---|---|
| 0x0000 - 0x1FFF | Wlink chiplet controller registers |
| 0x2000 - 0x203F | TideLink configuration + PTP registers |
| 0x2040 - 0x207F | PTP HW Sync, Servo config, Servo status, Timestamp mailbox |
| 0x2080 - 0x208F | Chiplet controller role configuration |

> **Note:** PHC registers are external to tidelink_top and accessed via their
> own APB port on the `ptp-hardware-clock-ahb` IP.

---

## 1. TideLink Configuration Registers (APB base 0x2000)

**Module:** `tidelink_apb_regs`
**RDL Source:** `src/rdl/tidelink_regs.rdl`, `src/rdl/tidelink_ptp_regs.rdl`
**Access:** Unified APB port (`apb_*`), base offset 0x2000

Address decoding uses `paddr[5]` as the region select and `paddr[4:2]` as
the register select within each region.

### Region 0: Configuration and Status (paddr[5] = 0)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2000 | PAIR_BASE_ADDR | RW | `TIDELINK_PAIR_BASE` param | Base address of the paired TideLink's APB register space. Used by the returner to derive target addresses. |
| 0x2004 | RELEASE_THRESHOLD | RW | 0x14 (20) | Minimum credits to accumulate before the returner fires a release-credits packet. 0 = release immediately. |
| 0x2008 | PACKET_WORD_LENGTH | RO | 0 | Current packet word length from FIFO controller (0 when idle). |
| 0x200C | CREDIT_COUNT | RO | 0 | Current free credit count in the local FIFO. |
| 0x2010 | STATUS | RO | 0 | Status and sticky fault flags (see below). |
| 0x2014 | DOORBELL | WO | 0 | Write any value to trigger a doorbell. Self-clearing. |
| 0x2018 | RELEASE_ACC | RO | 0 | Debug: credits freed but not yet released (below threshold). |
| 0x201C | CTRL | RW | 0 | Block enable and flush control (see below). |

#### STATUS Register (0x2010) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [0] | RETURNER_BUSY | 1 when the AHB returner master is mid-transfer. |
| [1] | OVERRUN | Sticky. Data window write discarded (credit count == 0). Cleared by FLUSH. |
| [2] | UNDERRUN | Sticky. Data window read with no packet available. Cleared by FLUSH. |
| [3] | MASTER_ERROR | Sticky. AHB master received ERROR response. Cleared by FLUSH. |
| [4] | PACKET_COMMITTED | Set on write_complete, cleared on FIFO address 0 read. Mirrors packet_committed_irq. |

#### CTRL Register (0x201C) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [0] | EN | Block enable. When 0, AHB data window accesses are gated. |
| [1] | FLUSH | Write 1 to reset pointers, packet state, and sticky errors. Self-clearing. EN must be 0. |

### Region 1: Incoming Credit Receivers (paddr[5] = 1)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2020 | RELEASED_CREDITS_ACC | W-add / R-clear | 0 | Receives credit delta values from paired TideLink. Writes accumulate; reads return total and clear. IRQ: `released_credits_irq`. |
| 0x2024 | DOORBELL_RESPONSE_ACC | W-add / R-clear | 0 | Receives doorbell responses from paired TideLink. Writes accumulate; reads return total and clear. IRQ: `doorbell_irq`. |
| 0x2028 | PAIR_CREDIT_COUNTER | RO | 0 | Running count of available credits on paired side. Incremented by writes to RELEASED_CREDITS_ACC, decremented by PAIR_CREDIT_CONSUME. |
| 0x202C | PAIR_CREDIT_CONSUME | WO | 0 | Write the number of credits being consumed. Subtracted from PAIR_CREDIT_COUNTER. |
| 0x2030 | PAIR_CREDIT_COUNTER_EN | RW | 1 | Bit[0]: enable pair credit counter updates. When 0, counter freezes. |

### Region 1 (continued): PTP Registers

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2034 | PTP_CTRL | RW/RO | 0 | PTP subsystem control and status (see below). |
| 0x2038 | PTP_RX_PAYLOAD | RO | 0 | 32-bit payload from last received PTP FC word. Reading clears PTP_CTRL.rx_valid. |
| 0x203C | PTP_STATUS | RO | 0 | PTP TX path status (see below). |

#### PTP_CTRL Register (0x2034) Fields

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| [0] | enable | RW | PTP enable. When 1, captures timestamps on FC TX/RX handshakes. |
| [1] | clear | RW (self-clearing) | Write 1 to clear rx_valid and tx_pending. |
| [2] | rx_valid | RO | Set by hardware on PTP FC word reception. Cleared by clear or reading PTP_RX_PAYLOAD. |
| [6:3] | rx_msg_type | RO | Message type from last PTP FC word. 0x0 = SYNC, 0x1 = DELAY_REQ. |

#### PTP_STATUS Register (0x203C) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [0] | tx_idle | Mirror of tx_router_idle. 1 = no in-flight FC packet. |
| [1] | tx_pending | 1 = PTP TX word waiting, stalled on tx_router_idle. |

### Region 4: Chiplet Controller Role Configuration (paddr[7:5] = 100)

These registers control the master/slave role selection of the generic
chiplet controller (`axi_chiplet_controller`). They are passed through from
`tidelink_apb_regs` to the controller via the `ctrl_reg_*` interface.

**Important:** The role registers are reset only by `poresetn` (power-on
reset). System reset (`hresetn`) preserves them, allowing warm reset
without re-negotiating the link role.

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2080 | ROLE_CFG | RW | 0 | Role select and lock (see below). |
| 0x2084 | ROLE_STATUS | RO | strap | Live role status and I2C state. |
| 0x2088 | I2C_SLV_ADDR | RW | 0x00 | 7-bit I2C slave device address. |
| 0x208C | I2C_PRESCALE | RW | 0x0001 | 16-bit I2C master clock prescaler. |

#### ROLE_CFG Register (0x2080) Fields

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| [0] | role | RW | 0 = master, 1 = slave. Only writable while role_lock == 0. |
| [1] | role_lock | W1S | Write-1-to-set. Locks the role and releases Wlink POR. Cleared only by poresetn. |

#### ROLE_STATUS Register (0x2084) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [0] | effective_role | Current effective role. Before lock: reflects role_strap_i pin. After lock: reflects ROLE_CFG.role. |
| [1] | locked | 1 when role_lock has been set. Wlink link is training or active. |
| [2] | i2c_busy | I2C slave core busy (slave mode only). |
| [3] | i2c_addressed | I2C slave has been addressed on the bus. |

#### Startup Sequence

1. `poresetn` released — system active, Wlink held in reset (`role_locked = 0`)
2. CPU reads ROLE_STATUS to check strap default (optional)
3. CPU writes ROLE_CFG to override role if needed (optional)
4. CPU writes `ROLE_CFG.role_lock = 1` — Wlink POR deasserts, link training begins
5. `swi_enable` is high by default, so FC credit exchange starts automatically

### Region 8: Chiplet Extended — PHY Alignment & I²C Training (paddr[8:5] = 1000)

These registers absorb the §9 PHY-alignment soft-strap controls (formerly
interim-shim'd at MMIO 0x4403_1000) and the I²C-coordinated training
protocol registers (per `docs/archive/proposals/i2c_train/I2C_TRAIN_PROTOCOL.md`). They
reside in a 4-bit region-select decode (`paddr[8:5]=1000`) — the existing
3-bit decode for Regions 0..7 is unchanged.

These registers are also pass-through via the same `ctrl_reg_*` interface
to `axi_chiplet_controller`; the controller's `ctrl_reg_addr[3]`
distinguishes Region 4 (bit 3 = 0, slots 0..7) from Region 8 (bit 3 = 1,
slots 0..7 remapped to 0x100..0x11C).

| Offset | Name              | Access | Reset       | Description                                                    |
|--------|-------------------|--------|-------------|----------------------------------------------------------------|
| 0x2100 | SWI_TRAINING_MODE | RW     | 0           | bit[0] = training-mode enable                                  |
| 0x2104 | SWI_BIT_SLIP_LO   | RW     | 0           | bits[23:0] = per-lane bit-slip (8 lanes × 3 bits)              |
| 0x2108 | SWI_LANE_STATUS   | RO     | 0           | [7:0] lane_locked, [15:8] lane_fault, [16] calibration_done; [31:17] = CREDIT_PATH_STATUS (see below) |
| 0x210C | NEGO_TRAIN_CFG    | RW     | 0           | I²C training handshake config (auto/sw_step/retrain + timing)  |
| 0x2110 | NEGO_TRAIN_STATUS | RO     | 0           | Training FSM live status + last-captured peer values           |
| 0x2114 | ECC_COUNTERS      | RO     | 0           | [15:0] ecc_corrupted sat-cnt, [31:16] ecc_corrected sat-cnt (was NEGO_TRAIN_STEP RO=0; W1P write path unchanged & still ignored) |
| 0x2118 | SWI_PHASE_OFFSET  | RW     | 0           | bits[31:0] = per-lane sub-bit phase (8 lanes × 4 bits) — §9.7  |
| 0x211C | PHY_ALIGN_ID      | RO     | 0x5041_0100 | "PA" v1.0 — SW probes for Region 8 presence                    |

See `staging/apb_redesign/PROPOSAL.md` for the full design rationale and
the migration history from the interim shim at MMIO 0x4403_1000.

#### Credit-Path Observability (RO) — replaces the ILA debug core

Read-only visibility into the Wlink `LL_RX → cr_pkt → FCSM` credit path so
`wlink_probe` can diagnose a wedged credit path with a 1-second APB read
instead of a Vivado ILA capture. Region 8 has only 8 physical slots
(`paddr[4:2]`, all assigned), so the observability bits are packed into
two slots whose read paths were otherwise dead bits / a dead word — **no
pre-existing live field moves**:

* **CREDIT_PATH_STATUS** is packed into the free upper bits `[31:17]` of
  `SWI_LANE_STATUS` (0x2108). The legacy `[16:0]`
  (`lane_locked`/`lane_fault`/`calibration_done`) are byte-for-byte
  unchanged.

  | Bit     | Name              | Source (Wlink hierarchy)                              |
  |---------|-------------------|------------------------------------------------------|
  | [16:0]  | (legacy)          | lane_locked / lane_fault / calibration_done          |
  | [20:17] | fcsm_state        | `WlinkGenericFCSM_6.state` (3b; bit[20] always 0)    |
  | [22:21] | llrx_state        | `WlinkRxLinkLayer.state` (byte-align FSM, ==2 → err) |
  | [23]    | cr_pkt_seen_rx    | `WlinkGenericFCSM_6.cr_pkt_seen_rx` (sticky, 0e126b0)|
  | [24]    | crack_pkt_seen_rx | `WlinkGenericFCSM_6.crack_pkt_seen_rx` (sticky)      |
  | [25]    | is_short_pkt      | `WlinkRxLinkLayer.is_short_pkt`                      |
  | [26]    | is_long_pkt       | `WlinkRxLinkLayer.is_long_pkt`                       |
  | [27]    | pkt_is_cr_pkt     | `WlinkGenericFCSM_6.pkt_is_cr_pkt`                   |
  | [28]    | pkt_is_crack_pkt  | `WlinkGenericFCSM_6.pkt_is_crack_pkt`                |
  | [29]    | llrx_valid        | `WlinkRxLinkLayer.valid`                             |
  | [31:30] | reserved          | 0                                                    |

* **ECC_COUNTERS** repurposes the read path of slot 5 (0x2114, was
  `NEGO_TRAIN_STEP` which read a constant `32'h0`; its W1P write path is
  untouched and still ignored, so no functional change). Two 16-bit
  saturating counters in the recovered-RX-link-clock domain, counting the
  `WlinkRxLinkLayer.ecc_check_corrupted` / `ecc_check_corrected` event
  pulses (saturate at 0xFFFF):

  | Bit     | Name              | Description                                  |
  |---------|-------------------|----------------------------------------------|
  | [15:0]  | ecc_corrupted_cnt | saturating count of ECC-corrupted words      |
  | [31:16] | ecc_corrected_cnt | saturating count of ECC-corrected words      |

All sources cross from the FCSM (`io_tx_clk`) / recovered-RX-link
(`phy_link_rx_rx_link_clk`) domains into `apb_clk` via a 2-flop
synchroniser in `axi_chiplet_controller.sv` (`sync_obs_*`, identical
pattern to `sync_lane_locked_*`). The signals are surfaced as new
`output` ports on `WlinkGenericFCSM_6` / `WlinkRxLinkLayer` →
`TideLinkToWlink` → `Wlink` (mirrors the existing
`phy_link_rx_rx_link_*_o` / `mask_hs_result_o` SoC-Labs port pattern in
the Chisel-generated wrappers). The ECC saturating counters live in
`Wlink.v` in the `phy_link_rx_rx_link_clk` domain.

#### SWI_TRAINING_MODE Register (0x2100) Fields

| Bit | Name              | Access | Description |
|-----|-------------------|--------|-------------|
| [0] | swi_training_mode | RW     | When 1, drives the Wlink GPIO PHY's training pattern + lane checker. |

POR-only reset domain — survives warm `hresetn` so training state persists
across system reset cycles. Writable from both local APB and the I²C-slave
AXIL bridge (peer-driven).

#### SWI_BIT_SLIP_LO Register (0x2104) Fields

| Bits  | Name      | Access | Description |
|-------|-----------|--------|-------------|
|[23:0] | bit_slip  | RW     | 8 lanes × 3-bit right-rotation amount (lane K at bits [3K+2:3K]). |

SW override of the autonomous calibration FSM's per-lane slip value. When
`NEGO_TRAIN_CFG.train_auto_en = 1` AND `swi_calibration_done = 0`, the cal
FSM owns slip; otherwise SW override applies. Both contributions are
OR-merged into the Wlink port.

#### SWI_LANE_STATUS Register (0x2108) Fields

| Bits   | Name             | Description |
|--------|------------------|-------------|
|[7:0]   | lane_locked      | Per-lane lock status from `wlink_lane_checker`. |
|[15:8]  | lane_fault       | Per-lane sticky fault from cal FSM. |
|[16]    | calibration_done | Set by cal FSM at convergence. Cleared by swreset / train_retrain. |

Packed so an I²C 4-byte read captures all three signals in a single
transaction.

#### SWI_PHASE_OFFSET Register (0x2118) Fields

| Bits   | Name         | Access | Description |
|--------|--------------|--------|-------------|
|[31:0]  | phase_offset | RW     | 8 lanes × 4-bit sub-bit sample-point phase (lane K at bits [4K+3:4K]). |

§9.7 per-lane phase. SW override of the autonomous calibrator's per-lane
phase sweep (slip 0..7 × phase 0..15). OR-merged with the calibrator's
`phase_offset` bus into the Wlink `swi_phase_offset_in` port; further
OR-merged *per-lane* inside `WavD2DGpio` with the legacy single-global
APB phase reg (Wlink PHY-ctrl reg bits[20:17]) so a lane left at 0 here
still inherits the global phase (bit-slip and phase compose; the global
path is not broken). This slot was the reserved `SWI_BIT_SLIP_HI`
(16-lane builds); repurposed for the 8-lane FPGA bring-up. Defaults 0 →
behaviour bit-exact to the pre-§9.7 single-global-phase design.

---

## 2. Wlink Chiplet Controller Registers (APB base 0x0000)

**Module:** `Wlink` (Chisel-generated)
**Documentation Source:** `deps/axi-chiplet-controller/docs/source/register_map.rst`
**Access:** Unified APB port (`apb_*`), address range 0x0000-0x1FFF

### Address Regions

| Address Range | Region |
|---|---|
| 0x0000 - 0x01FF | PHY Registers |
| 0x0200 - 0x03FF | Wlink Link Registers |
| 0x1000 - 0x10FF | AXI2WL AW FC Node |
| 0x1100 - 0x11FF | AXI2WL W FC Node |
| 0x1200 - 0x12FF | AXI2WL B FC Node |
| 0x1300 - 0x13FF | AXI2WL AR FC Node |
| 0x1400 - 0x14FF | AXI2WL R FC Node |
| 0x1600 - 0x16FF | GeneralBus FC Node |
| 0x1700 - 0x17FF | TideLink FC Node |

### 2.1 PHY Registers (base + 0x0000)

| Offset | Name | Bits | Reset | Access | Description |
|--------|------|------|-------|--------|-------------|
| 0x00 | General Controls | [7:0] | 1 | RW | PRE Count |
| | | [15:8] | 7 | RW | Post Count |
| | | [16] | 1 | RW | RX Polarity |
| 0x04 | Pre Divider | [3:0] | 4 | RW | SerDes PLL pre divider |
| 0x08 | Post Divider | [3:0] | 0 | RW | SerDes PLL post divider |
| 0x0C | PLL Enable/Lock | [0] | 0 | RW | PLL Enable |
| | | [8] | 0 | RO | PLL Locked |

### 2.2 Wlink Link Registers (base + 0x0200)

| Offset | Name | Bits | Reset | Access | Description |
|--------|------|------|-------|--------|-------------|
| 0x00 | Link Capabilities | [15:0] | 8 | RO | Max TX Lanes |
| | | [31:16] | 8 | RO | Max RX Lanes |
| 0x04 | PHY Version | [31:0] | - | RO | PHY Version |
| 0x08 | Enable/Reset | [0] | 1 | RW | SWI Enable |
| | | [1] | 1 | RW | LL TX Enable |
| | | [2] | 1 | RW | LL RX Enable |
| | | [3] | 0 | RW | SW Reset |
| | | [15:8] | 0x7F | RW | Max Short Packet ID |
| | | [23:16] | 0x02 | RW | PREQ Data ID |
| 0x10 | Active Lanes | [15:0] | 7 | RO | Active TX Lanes - 1 (derived: `popcount(tx_lane_mask) - 1`) |
| | | [31:16] | 7 | RO | Active RX Lanes - 1 (derived: `popcount(rx_lane_mask) - 1`) |
| 0x14 | Lane Mask | [15:0] | 0xFF | RW | TX Lane Mask: bit[k]=1 enables physical TX lane k |
| | | [31:16] | 0xFF | RW | RX Lane Mask: bit[k]=1 enables physical RX lane k |
| 0x30 | P-State Control | [15:0] | 1700 | RW | Delay Cycles |
| | | [18:16] | 0 | RW | Number P Reqs |
| | | [31:24] | 255 | RW | Cycles post Reqs |
| 0x34 | Link Status | [0] | 0 | RW | SB Reset |
| | | [1] | 0 | RW | SB Reset MUX |
| | | [2] | 0 | RO | In Error State |
| | | [3] | 0 | RO | TX Ready |
| | | [4] | 1 | RO | RX Data Valid |
| 0x3C | Error Injection | [7:0] | 0 | RW | Error Inject Data ID |
| | | [15:8] | 0 | RW | Error Inject Byte |
| | | [18:16] | 0 | RW | Error Inject Bit |
| | | [24] | 0 | RW | Error Inject Enable |
| 0x40 | Link Interrupts | [0] | 0 | RW | CRC Errors (W1C) |
| | | [1] | 1 | RW | CRC Errors Int Enable |
| | | [8] | 0 | RW | ECC Corrected (W1C) |
| | | [9] | 0 | RW | ECC Corrected Int Enable |
| | | [16] | 0 | RW | ECC Corrupted (W1C) |
| | | [17] | 1 | RW | ECC Corrupted Int Enable |

### 2.3 FC Node Registers (common layout per node)

Each FC node (AW, W, B, AR, R, GeneralBus, TideLink) has the same register
layout at offsets relative to the node's base address:

| Offset | Name | Bits | Reset | Access | Description |
|--------|------|------|-------|--------|-------------|
| 0x00 | ID Control | [7:0] | varies | RW | Credit ID |
| | | [15:8] | varies | RW | Credit Ack ID |
| | | [23:16] | varies | RW | Ack Data ID |
| | | [31:24] | varies | RW | Nack Data ID |
| 0x04 | Data ID Control | [7:0] | varies | RW | Data ID |
| 0x08 | TX FC FIFO | [0] | 1 | RO | FIFO Empty |
| 0x10 | Ack Nack FIFO | [0] | 1 | RO | Empty |
| | | [1] | 0 | RO | Full |
| | | [2] | 0 | RO | Half Full |
| | | [3] | 0 | RO | Almost Empty |
| | | [4] | 0 | RO | Almost Full |
| | | [10:8] | 6 | RW | Almost Full Level |
| | | [18:16] | 2 | RW | Almost Empty Level |
| 0x14 | SM Control | [7:0] | 8 | RW | No. Cycles IDLE after credit negotiation |
| | | [15:8] | 7 | RW | No. Cycles between ACK packets |
| | | **[16]** | **0** | **RW** | **Disable CRC Check** |
| 0x20 | CRC Errors | [15:0] | 0 | RO | Number of CRC errors seen |

> **Key register for GPIO-speed deployments:** SM Control bit [16]
> (`disable_crc`) in each FC node disables CRC checking, saving 2 bytes per
> long packet (~9-20% bandwidth depending on payload size). At GPIO speeds
> the bit error rate is negligible, making CRC overhead unnecessary.

### FC Node Data ID Defaults

| FC Node | Base | Credit ID | Credit Ack | Ack | Nack | Data |
|---------|------|-----------|------------|-----|------|------|
| AXI AW | 0x1000 | 0x08 | 0x09 | 0x0A | 0x0B | 0x80 |
| AXI W | 0x1100 | 0x0C | 0x0D | 0x0E | 0x0F | 0x81 |
| AXI B | 0x1200 | 0x08 | 0x09 | 0x0A | 0x0B | 0x80 |
| AXI AR | 0x1300 | 0x08 | 0x09 | 0x0A | 0x0B | 0x80 |
| AXI R | 0x1400 | 0x08 | 0x09 | 0x0A | 0x0B | 0x80 |
| GeneralBus | 0x1600 | - | - | - | - | - |
| TideLink | 0x1700 | - | - | - | - | - |

---

## 3. PHC (PTP Hardware Clock) Registers

**Module:** `phc_apb_regs` (external IP: `ptp-hardware-clock-ahb`)
**RDL Source:** `src/rdl/phc_regs.rdl`
**Access:** Own APB port (external to tidelink_top)

### Region 0: Core Configuration (0x000-0x01F)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x000 | CTRL | RW | 0 | [0] en: clock enable. [1] set_time: load SET_* values (self-clearing). [2] capture: latch timestamp to CAP_* (self-clearing). |
| 0x004 | STATUS | RO | 0 | [0] running. [1] pps_sticky (read-to-clear). [2] alarm_hit. |
| 0x008 | NS_INCR | RW | `DEFAULT_NS_INCR` | Integer nanosecond increment per clock cycle (e.g. 4 for 250 MHz). |
| 0x00C | NS_INCR_FRAC | RW | 0 | 32-bit sub-nanosecond fractional increment for fine PTP servo adjustment. |
| 0x010 | SET_SECONDS_LO | RW | 0 | Lower 32 bits of seconds to load on set_time. |
| 0x014 | SET_SECONDS_HI | RW | 0 | Upper 16 bits of seconds to load on set_time. |
| 0x018 | SET_NANOSECONDS | RW | 0 | 30-bit nanoseconds (0-999,999,999) to load on set_time. |
| 0x01C | INT_EN | RW | 0 | [0] pps_irq_en. [1] alarm_irq_en. |

### Region 1: Software Capture and Alarm (0x020-0x03C)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x020 | CAP_SECONDS_LO | RO | 0 | Lower 32 bits of captured seconds. |
| 0x024 | CAP_SECONDS_HI | RO | 0 | Upper 16 bits of captured seconds. |
| 0x028 | CAP_NANOSECONDS | RO | 0 | 30-bit captured nanoseconds. |
| 0x02C | CAP_NS_FRAC | RO | 0 | 32-bit captured sub-nanoseconds. |
| 0x030 | ALARM_SECONDS_LO | RW | 0 | Lower 32 bits of alarm match seconds. |
| 0x034 | ALARM_SECONDS_HI | RW | 0 | Upper 16 bits of alarm match seconds. |
| 0x038 | ALARM_NANOSECONDS | RW | 0 | 30-bit alarm match nanoseconds. |
| 0x03C | ALARM_CTRL | RW | 0 | [0] arm: enable comparator. [1] auto_disarm: clear arm on match. |

### Region 2: Hardware Capture (0x040-0x04C)

Independent of Region 1 capture. Used by TideLink PTP for timestamps
captured at FC TX/RX handshake moments.

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x040 | HW_CAP_SECONDS_LO | RO | 0 | Lower 32 bits of hw-captured seconds. |
| 0x044 | HW_CAP_SECONDS_HI | RO | 0 | Upper 16 bits of hw-captured seconds. |
| 0x048 | HW_CAP_NANOSECONDS | RO | 0 | 30-bit hw-captured nanoseconds. |
| 0x04C | HW_CAP_NS_FRAC | RO | 0 | 32-bit hw-captured sub-nanoseconds. |

---

## 4. Address Translator Registers (`ahb_adr_*`)

**Module:** `tidelink_addr_translator`
**RDL Source:** `src/rdl/tidelink_addr_translator_regs.rdl`
**Access:** AHB subordinate, bridged internally via `cmsdk_ahb_to_apb`

Two independent channels, each with this register layout. High address bits
select the channel.

### Per-Channel Registers

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x000 | BASE_OFFSET | RW | 0 | 32-bit value subtracted from input address before segment lookup. |
| 0x004-0x100 | SEGMENT_TABLE[64] | RW | identity | 64 registers, each packing 4 x 8-bit segment entries. seg[k] maps input addr[31:24]=k to the stored value. Reset: seg[k]=k. |
| 0xFD0-0xFDC | PIDR4-7 | RO | 0x00 | ARM PrimeCell peripheral ID (upper). |
| 0xFE0-0xFEC | PIDR0-3 | RO | varies | ARM PrimeCell peripheral ID (lower). PIDR0=0x59, PIDR1=0x16, PIDR2=0x15. |
| 0xFF0-0xFFC | CIDR0-3 | RO | varies | ARM PrimeCell component ID. CIDR0=0x50, CIDR1=0x51, CIDR2=0x4C, CIDR3=0x54. |

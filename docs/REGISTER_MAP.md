# TideLink Register Map

This document describes the complete register map for the TideLink subsystem,
covering TideLink-specific registers, PTP registers, PHC registers, address
translator registers, and the Wlink chiplet controller registers.

## Address Space Overview

TideLink exposes a single unified APB port (`apb_*`, 15-bit address) for all
configuration registers — including the address translator. The decode in
`tidelink_top.sv` (lines 660-667) routes by `paddr[14:13]`:

| `paddr[14:13]` | Address Range | Region |
|---|---|---|
| `00` | 0x0000 - 0x1FFF | Wlink chiplet controller registers (`paddr[12:0]`) |
| `01` | 0x2000 - 0x3FFF | TideLink config / PTP / role / extended registers (`paddr[8:2]` decoded) |
| `10` | 0x4000 - 0x5FFF | Address translator configuration (`paddr[12:0]`) |
| `11` | 0x6000 - 0x7FFF | Reserved |

### Unified APB Address Map (TideLink region, base 0x2000)

| Address Range | Region |
|---|---|
| 0x2000 - 0x201F | Region 0: TideLink configuration + status |
| 0x2020 - 0x203F | Region 1: Incoming credit receivers + PTP basic |
| 0x2040 - 0x205F | Region 2: PTP HW Sync + Servo config |
| 0x2060 - 0x207F | Region 3: Servo status + Timestamp mailbox |
| 0x2080 - 0x209F | Region 4: Chiplet controller role + autoneg config |
| 0x20A0 - 0x20FF | Regions 5-7: Performance profiling |
| 0x2100 - 0x211F | Region 8: Chiplet extended — PHY alignment + I²C training |
| 0x2140 - 0x217F | Region 10: Eye-visibility v2 (`tidelink_eye_regs`) — V1 only. In V2 (`TIDELINK_PHY_V2`) Region 10 is retired (eye-vis AUDIT #17); the single word at **0x2140** is repurposed as **SWI_EPOCH_STATUS** (RO) from the `tidelink_gpio_phy_apb_regs` slave: `[0]`=epoch_anchored, `[6:1]`=epoch_span (words, 0..24). The rest of 0x2140-0x215F reads 0. |
| 0x2160 - 0x217F | Region 11: tidelink-gpio-phy APB slave (`tidelink_gpio_phy_apb_regs`, slave-paddr 0x20-0x3F) |
| 0x2180 - 0x219F | Region C: Autoneg silicon observability (RO) |

> **Note:** PHC registers are external to tidelink_top and accessed via their
> own APB port on the `ptp-hardware-clock-ahb` IP.

> **FPGA BD apertures (GP1 control/data split, 2026-06-12):** on the PYNQ-Z2
> `pair-all`/`pair-flip-all` block designs the PS-visible apertures are:
> APB config 0x4403_0000 (TideLink region at 0x4403_2000) and peer window
> 0x4000_0000 on `M_AXI_GP0` (unchanged); the data apertures moved to
> `M_AXI_GP1` — **AHB_TX 0x8400_0000** (was 0x4400_0000) and
> **RX FIFO 0x8401_0000** (was 0x4401_0000). Zynq-7000 GP windows are hard
> (GP1 = 0x8000_0000..0xBFFF_FFFF), hence the relocation. Host scripts:
> `TIDELINK_TX_BASE` / `TIDELINK_RXFIFO_BASE` env overrides (old defaults).

---

## 1. TideLink Configuration Registers (APB base 0x2000)

**Module:** `tidelink_apb_regs`
**RDL Source:** `src/rdl/tidelink_regs.rdl`, `src/rdl/tidelink_ptp_regs.rdl`
**Access:** Unified APB port (`apb_*`), base offset 0x2000

Address decoding uses `paddr[8:5]` as the 4-bit region select (`apb_region`)
and `paddr[4:2]` as the register select within each region
(`tidelink_apb_regs.sv:163`). Regions 0..7 are reachable with `paddr[8]=0`
(3-bit `paddr[7:5]`); Regions 8/10/C use `paddr[8]=1`.

### Region 0: Configuration and Status (apb_region = 0)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2000 | PAIR_BASE_ADDR | RW | `TIDELINK_PAIR_BASE` param | Base address of the paired TideLink's APB register space. Used by the returner to derive target addresses. Writes blocked once CTRL.LOCK is set. |
| 0x2004 | RELEASE_THRESHOLD | RW | 0x14 (20) | Minimum credits to accumulate before the returner fires a release-credits packet. 0 = release immediately. Writes blocked once CTRL.LOCK is set. |
| 0x2008 | PACKET_WORD_LENGTH | RO | 0 | Current packet word length from FIFO controller (0 when idle). 14-bit. |
| 0x200C | CREDIT_COUNT | RO | 0 | Current free credit count in the local FIFO. 13-bit. |
| 0x2010 | STATUS | RO | 0 | Status and sticky fault flags (see below). |
| 0x2014 | DOORBELL / ID | WO (write) / RO (read) | — | **Write** any value triggers a doorbell (self-clearing). **Read** returns the peripheral ID `0x544C_0100` ("TL" v1.0) — Shortcoming #11 (`tidelink_apb_regs.sv:492`). |
| 0x2018 | RELEASE_ACC | RO | 0 | Debug: credits freed but not yet released (below threshold). |
| 0x201C | CTRL | RW | 0 | Flush and write-once lock control (see below). |

#### STATUS Register (0x2010) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [0] | RETURNER_BUSY | 1 when the AHB returner master is mid-transfer. |
| [1] | OVERRUN | Sticky. Data window write discarded (credit count == 0). Cleared by FLUSH. |
| [2] | UNDERRUN | Sticky. Data window read with no packet available. Cleared by FLUSH. |
| [3] | MASTER_ERROR | Sticky. AHB master received ERROR response. Cleared by FLUSH. |
| [4] | PACKET_COMMITTED | Set on write_complete, cleared on FIFO address 0 read. Mirrors packet_committed_irq. |

#### CTRL Register (0x201C) Fields

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| [0] | EN | RO (reads 0) | **Reserved.** Formerly gated AHB data window accesses; the RTL no longer implements an enable (`tidelink_apb_regs.sv:173`). Reads back 0. |
| [1] | FLUSH | W1P | Write 1 to reset pointers, packet state, release accumulator, and sticky errors. Self-clearing. Reads back 0. |
| [2] | LOCK | W1S | Write-once lock (Shortcoming #25). Once set, blocks further writes to PAIR_BASE_ADDR (0x2000) and RELEASE_THRESHOLD (0x2004). Cleared only by reset (`tidelink_apb_regs.sv:191-196`). |

### Region 1: Incoming Credit Receivers (apb_region = 1)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2020 | RELEASED_CREDITS_ACC | W-add / R-clear | 0 | Receives credit delta values from paired TideLink. Writes saturating-add (16-bit, clamps at 0xFFFF); reads return total and clear. IRQ: `released_credits_irq`. A write to this register also increments PAIR_CREDIT_COUNTER. |
| 0x2024 | DOORBELL_RESPONSE_ACC | W-add / R-clear | 0 | Receives doorbell responses from paired TideLink. Writes saturating-add (16-bit, clamps at 0xFFFF); reads return total and clear. IRQ: `doorbell_irq`. |
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

### Region 2: PTP HW Sync Initiator + Servo Config (apb_region = 2)

Slots 0..2 pass through to `tidelink_ptp` (HW sync initiator FSM); slots 3..7
pass through to the servo register block (`servo_reg_*` interface,
`tidelink_apb_regs.sv:435-437`).

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2040 | HW_SYNC_CTRL | RW | 0 | [0] enable, [1] seq_clear (W1C), [2] force_en (bypasses `phc_locked` gate). See `tidelink_ptp.sv:353`. |
| 0x2044 | HW_SYNC_INTERVAL | RW | 0 | [29:0] sync interval in nanoseconds. |
| 0x2048 | HW_SYNC_STATUS | RO | 0 | [0] active, [1] busy, [17:2] seq_num, [18] phc_locked (`tidelink_ptp.sv:355`). |
| 0x204C-0x205C | SERVO_CFG[0..4] | RW | 0 | Servo configuration (servo_reg_addr 0..4). Pass-through to servo block. |

### Region 3: Servo Status + Timestamp Mailbox (apb_region = 3)

Reads return servo status (`servo_reg_rdata`). Writes are the timestamp
mailbox path, written by the FC SIDEBAND node (`mbox_reg_*` interface,
`tidelink_apb_regs.sv:440-442`).

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2060-0x2064 | SERVO_STATUS[0..1] | RO | 0 | Servo status (servo_reg_addr 5..6 on read). |
| 0x2060-0x207C | TS_MAILBOX[0..7] | WO (FC sideband) | 0 | Timestamp mailbox slots, written by the FC SIDEBAND node. |

### Region 4: Chiplet Controller Role Configuration (apb_region = 4, paddr[8:5] = 0100)

These registers control the master/slave role selection of the generic
chiplet controller (`axi_chiplet_controller`). They are passed through from
`tidelink_apb_regs` to the controller via the `ctrl_reg_*` interface.

**Important:** The role registers are reset only by `poresetn` (power-on
reset). System reset (`hresetn`) preserves them, allowing warm reset
without re-negotiating the link role.

Slot select is `paddr[4:2]`; in the controller these reach `ctrl_reg_addr`
with `ctrl_reg_addr[4:3] = 2'b01` (`axi_chiplet_controller.sv:443-446`).

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2080 | ROLE_CFG | RW | 0 | Role select and lock (see below). |
| 0x2084 | ROLE_STATUS | RO | strap | Live role status and I2C state (see below). |
| 0x2088 | I2C_SLV_ADDR | RW | 0x7E | 7-bit I2C slave device address. RTL POR default `7'h7E` (autoneg slave address) — `axi_chiplet_controller.sv:584`. |
| 0x208C | I2C_PRESCALE | RW | 0x007D (125) | 16-bit I2C master clock prescaler. RTL POR default `16'd125` → 100 kHz SCL at 50 MHz apb_clk (Bug N1 fix, `axi_chiplet_controller.sv:603`). |
| 0x2090 | NEGO_CFG | RW | 0x61 | Auto-negotiation config. [0] nego_en, [5] nego_force_lock, [6] mask_hs_auto_en. POR default `7'h61` (`NEGO_CFG_RESET`, `axi_chiplet_controller.sv:68`). |
| 0x2094 | NEGO_STATUS | RO | 0 | Autoneg FSM live status: [3:0] state, [4] done, [5] error, [6] won, [7] lost, [8] sda_start_seen, [9] mask_mismatch (`axi_chiplet_controller.sv:774`). |
| 0x2098 | NEGO_PRIORITY | RW | 1 or 2 (strap) | 16-bit autoneg priority (lower wins). POR default is strap-derived: master/strap=0 → `0x0001`, slave/strap=1 → `0x0002` (Bug N7, `axi_chiplet_controller.sv:616`). |
| 0x209C | NEGO_TIMEOUT | RW | 131082000 | 32-bit autoneg FSM cycle-count timeout (`axi_chiplet_controller.sv:617`). |

> **Note:** The RDL (`tidelink_regs.rdl:367`) lists NEGO_PRIORITY reset as
> `0xFFFF`, but the instantiated RTL overrides it to the strap-derived 1/2 at
> POR. RTL wins.

#### ROLE_CFG Register (0x2080) Fields

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| [0] | role | RW | 0 = master, 1 = slave. Only writable while role_lock == 0 (`axi_chiplet_controller.sv:671-672`). |
| [1] | role_lock | W1S | Write-1-to-set. Locks the role and releases Wlink POR. Latches only when the mask-handshake gate is open (or via the autoneg FSM / lost-side workaround). Cleared only by poresetn (`axi_chiplet_controller.sv:668-674`). |

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
| 0x210C | NEGO_TRAIN_CFG    | RW     | 0           | [15:0] training handshake config (auto/sw_step/retrain + timing); [16] train_fail_irq (sticky, W1C via wdata[16]); [23:20] MIN_LOCK_DWELLS override (M11b, 0=param). See `axi_chiplet_controller.sv:1084-1088` |
| 0x2110 | NEGO_TRAIN_STATUS | RO     | 0           | [0] train_ok, [1] train_fail, [2] train_in_progress, [3] train_peer_nack, [7:4] train_state, [15:8] train_peer_lane_locked, [23:16] train_peer_lane_fault, [31:24] train_local_lane_fault (`axi_chiplet_controller.sv:1089-1096`) |
| 0x2114 | SYNC_DET / ECC    | RO     | 0           | [31:16] **sync_detected** sat-cnt (cross-lane-deskew health; SoC Labs 2026-06-08; replaces the DEAD ecc_corrected field), [15:0] ecc_corrupted sat-cnt (also DEAD/0). Was ECC_COUNTERS / NEGO_TRAIN_STEP RO=0; W1P write path unchanged & still ignored. |
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

  Current silicon packing (`axi_chiplet_controller.sv:1069-1083`,
  SEND-GATE-OBS, SoC Labs 2026-06-09 — note bits [20] and [31:30] were
  repurposed from the earlier "reserved/always-0" layout):

  | Bit     | Name                      | Source (Wlink hierarchy)                              |
  |---------|---------------------------|------------------------------------------------------|
  | [16:0]  | (legacy)                  | lane_locked / lane_fault / calibration_done          |
  | [19:17] | fcsm_state                | `WlinkGenericFCSM_6.state` (3b)                       |
  | [20]    | a2l_replay_app_valid      | app-side replay valid (skid-empty vs CDC-stuck)      |
  | [22:21] | llrx_state                | `WlinkRxLinkLayer.state` (byte-align FSM, ==2 → err) |
  | [23]    | cr_pkt_seen_rx            | `WlinkGenericFCSM_6.cr_pkt_seen_rx` (sticky, 0e126b0)|
  | [24]    | crack_pkt_seen_rx         | `WlinkGenericFCSM_6.crack_pkt_seen_rx` (sticky)      |
  | [25]    | is_short_pkt              | `WlinkRxLinkLayer.is_short_pkt`                      |
  | [26]    | is_long_pkt               | `WlinkRxLinkLayer.is_long_pkt`                       |
  | [27]    | pkt_is_cr_pkt             | `WlinkGenericFCSM_6.pkt_is_cr_pkt`                   |
  | [28]    | pkt_is_crack_pkt          | `WlinkGenericFCSM_6.pkt_is_crack_pkt`                |
  | [29]    | llrx_valid                | `WlinkRxLinkLayer.valid`                             |
  | [30]    | a2l_fc_replay_link_valid  | FCSM 4→5 SEND app-valid gate (link side)             |
  | [31]    | fe_rx_is_full             | FCSM 4→5 SEND credit gate (SoC Labs 2026-06-09). Only flags `fe_rx_credit_max == 0`; for the garbled-to-small-nonzero credit case read OBS_FC_CREDIT @ 0x219C. |

  > **RTL/RDL divergence:** the RDL (`tidelink_regs.rdl:437-470`) still
  > documents the older packing (fcsm_state at [20:17], bits [31:30]
  > reserved). The instantiated RTL above is authoritative.

* **SYNC_DET / ECC** is the read path of slot 5 (0x2114, was `NEGO_TRAIN_STEP`
  which read a constant `32'h0`; its W1P write path is untouched and still
  ignored, so no functional change). 16-bit saturating counters in the
  recovered-RX-link-clock domain (saturate at 0xFFFF):

  | Bit     | Name               | Description                                                                                   |
  |---------|--------------------|-----------------------------------------------------------------------------------------------|
  | [15:0]  | ecc_corrupted_cnt  | saturating count of ECC-corrupted words. **DEAD** — `WlinkEccSyndrome.v:299-308` ties corrupted=0; reads 0. |
  | [31:16] | sync_detected_cnt  | **SoC Labs 2026-06-08.** Saturating count of `WlinkRxLinkLayer.sync_detected` (assembled 128-bit RX bus == PHY SYNC_WORD). A HW read **>0 proves the RX assembled a COHERENT SYNC word**, i.e. the cross-lane lane-deskew is delivering aligned words; **=0** means the RX never sees a coherent SYNC (lanes still mis-aligned / link dead). Replaces the equally-DEAD ecc_corrected field. |

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
| [1] | swi_recal         | RW     | Recalibration request strobe. Read path `{swi_recal_r, swi_training_mode_r}` (`axi_chiplet_controller.sv:1067`). |

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

### Region 10: Eye Visibility v2 (paddr[8:5] = 1010, offsets 0x140-0x17F)

**Module:** `tidelink_eye_regs` (instantiated in `tidelink_top.sv`, routed by
`eye_shim_sel = tl_apb_paddr[8:5] == 4'b1010`, `tidelink_top.sv:736`).
The parent OR-mux substitutes this block's `prdata`/`pready`/`pslverr`; the
`tidelink_apb_regs` read mux returns 0 for region 10. Slot = `paddr[5:2]`.

| Offset | Name              | Access     | Reset       | Description |
|--------|-------------------|------------|-------------|-------------|
| 0x2140 | SWI_EYE_CTRL      | RW (W1P [0]/[1]) | 0     | [0] ENTER (W1P), [1] RESET (W1P), [5:4] MODE, [8] FORCE_FULL_SWEEP, [9] AUTO_INCREMENT_LANE, [16] capture_arm alias→ENTER. MODE=2'b10 → pslverr. |
| 0x2144 | SWI_EYE_LANE_SEL  | RW         | 0           | [2:0] lane select, [3] all-lanes (EYE_BUF_WIDE only). |
| 0x2148 | SWI_EYE_DWELL_US  | RW         | 0x2710 (10 ms) | Dwell us; writes floor-clamped to 6000 (§13.6). |
| 0x214C | SWI_EYE_STATUS    | RO         | 0           | Calibrator eye-sweep status (`eye_status_i`). |
| 0x2150 | SWI_FORCE_PHASE_EN| RW         | 0           | Per-lane force-phase enable mask. |
| 0x2154 | SWI_FORCE_PHASE_VAL | RW       | 0           | Per-lane force-phase value. |
| 0x2158 | SWI_FORCE_SLIP_VAL| RW         | 0           | Per-lane force-slip value. |
| 0x215C | EYE_CRC_ERR_LANE_LO | RC       | 0           | Lanes 0-3 saturating 8-bit CRC error counts. Read clears. |
| 0x2160 | EYE_CRC_ERR_LANE_HI | RC       | 0           | Lanes 4-7 saturating 8-bit CRC error counts. Read clears. |
| 0x2164 | EYE_SCORE_IDX     | RW         | 0           | [6:0] point index, [16] auto-increment after EYE_SCORE_DATA read. |
| 0x2168 | EYE_SCORE_DATA    | RO         | 0           | [5:0] score, [8] lane_passed, [15:10] best score, [18:16] best_slip, [22:19] best_phase. |
| 0x216C | EYE_BURST_DATA    | RO         | 0           | Five packed 6-bit scores; read increments idx by 5. |
| 0x2170 | EYE_LAST_LATCHED  | RO         | 0           | [23:0] last slip vector, [31:24] last lane_fault. |
| 0x2174 | PHY_EYE_ID        | RO         | 0x5045_0200 | "PE" v2.0 block ID. |
| 0x2178 / 0x217C | reserved (v2.1 DDR) | RAZ/WI | 0       | Reserved. |

### Region C: Autoneg Silicon Observability (paddr[8:5] = 1100, offsets 0x180-0x19F)

Read-only mirror of internal `tidelink_autoneg` counters/state + `i2c_master`
STATUS (Bug N7/N8 silicon probes). Pass-through via `ctrl_reg_*` with
`ctrl_reg_addr[4:3] = 2'b11`; all slots RO (writes → pslverr).
See `axi_chiplet_controller.sv:1103-1140`.

| Offset | Name              | Access | Description |
|--------|-------------------|--------|-------------|
| 0x2180 | OBS_DELAY_CTR     | RO     | `autoneg.delay_ctr_r[31:0]`. |
| 0x2184 | OBS_TIMEOUT_CTR   | RO     | `autoneg.timeout_ctr_r[31:0]`. |
| 0x2188 | OBS_FSM_SUBSTATE  | RO     | [17:13] init_wait, [12:10] axl_state, [9:7] txn_step (nibble-packed). |
| 0x218C | OBS_I2C_MST_STATUS| RO     | [3] missed_ack, [2] bus_active, [1] bus_cont(0), [0] busy. |
| 0x2190 | OBS_OBS_ID        | RO     | "OB" v1.0 marker = 0x4F42_0100. |
| 0x2194 | OBS_MASK_HS       | RO     | Packed mask-handshake internals (peer masks, local match/fail, lock_pending, gate_open, wlink result). |
| 0x2198 | OBS_CAL           | RO     | M7 calibrator obs (2026-06-05): [3:0] cal_state, [19:4] cal_resweep_ctr, [20] live training_mode (cal OR SW). (Was documented "reserved"; live since M7.) |
| 0x219C | OBS_FC_CREDIT     | RO     | FE credit obs (2026-06-12): [7:0] `fe_rx_credit_max` (captured from CR/CRACK `word_count[15:8]`; catches credit garbled to small NONZERO — `fe_rx_is_full` @0x2108[31] only flags ==0), [15:8] `fe_rx_ptr` (credit-return pointer from ACK/NACK), [16] `fe_rx_is_full` mirror, [23:17] reserved, [31:24] presence marker 0xFC (reads 0x0000_0000 on older images). All fields 2-flop apb-synced. MMIO 0x4403219C. |

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
| AXI B | 0x1200 | 0x10 | 0x11 | 0x12 | 0x13 | 0x82 |
| AXI AR | 0x1300 | 0x14 | 0x15 | 0x16 | 0x17 | 0x83 |
| AXI R | 0x1400 | 0x18 | 0x19 | 0x1A | 0x1B | 0x84 |
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

## 4. Address Translator Registers (unified APB region 0x4000)

**Module:** `tidelink_addr_translator` → per-channel `tl_addr_trans_regs`
**RDL Source:** `src/rdl/tidelink_addr_translator_regs.rdl`
**Access:** Unified APB port, `paddr[14:13] == 2'b10` (0x4000-0x5FFF) — **not**
a separate `ahb_adr_*` AHB port. Routed in `tidelink_top.sv:667` /
`tidelink_top.sv:1741` (`tidelink_addr_translator` with `NUM_CHANNELS=1`).

The translator is **CAM-based rule matching** (not a 256/64-entry segment
table). The decode subtracts BASE_OFFSET from the input address, then compares
`addr[31:24]` against each enabled rule's match byte; the lowest-index matching
rule replaces `addr[31:24]` with its replace byte. `addr[23:0]` always passes
through. With `enable=0`, all addresses pass through unchanged.

Channel select is `paddr[15:12]`: `4'h0` = channel 0, `4'h1` = channel 1
(`tidelink_addr_translator.sv:89`). Only channel 0 is instantiated in
`tidelink_top` (NUM_CHANNELS=1); channel 1 returns pslverr.

### Per-Channel Registers (`tl_addr_trans_regs.sv`)

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x000 | BASE_OFFSET | RW | 0 | 32-bit value subtracted from the input address before rule matching. |
| 0x004 | CTRL | RW | 0 | [0] global_enable. 0 = identity passthrough, 1 = rule matching active. |
| 0x010-0x02C | RULE[0..7] | RW | 0 | 8 match/replace rules. Per rule: [0] enable, [15:8] match byte, [23:16] replace byte; [7:1] and [31:24] reserved. Rule 0 has highest priority. |
| 0xFD0-0xFDC | PIDR4-7 | RO | 0x00 | ARM PrimeCell peripheral ID (upper). All 0x00. |
| 0xFE0-0xFEC | PIDR0-3 | RO | varies | ARM PrimeCell peripheral ID (lower). PIDR0=0x59, PIDR1=0x16, PIDR2=0x15, PIDR3=0x00. |
| 0xFF0-0xFFC | CIDR0-3 | RO | varies | ARM PrimeCell component ID. CIDR0=0x50, CIDR1=0x51, CIDR2=0x4C, CIDR3=0x54. |

> Unmapped reads in the 0x030-0xFCC gap return `0xCAFECAFE`
> (`tl_addr_trans_regs.sv:190`).

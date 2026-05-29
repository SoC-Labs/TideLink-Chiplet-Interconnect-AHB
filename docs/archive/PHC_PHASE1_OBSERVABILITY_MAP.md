# TideLink — PHC Phase-1 Observability Map

**Purpose.** Every APB-readable observation point in the design grouped by
purpose, so the next HW debug session knows exactly which addresses to read
when triaging the build #11/#13 slave-RX bug
(`HW_SYNC_STATUS slave = 0x0`, no `PTP_RX_PAYLOAD`, no `ecc_corrected/corrupted`
on slave). See `docs/PHC_PHASE1_HW_REPORT.md` for the latest evidence and
`docs/SIM_HW_GAP_ANALYSIS.md` for the three remaining HW-only hypotheses
(P&R skew past IDELAY tap range, clock-recovery race, `set_bus_skew`
exhaustion).

**Bus topology (FPGA bring-up).** Two AMBA windows are reachable from PYNQ
`/dev/mem`:

| Window | Base on FPGA | Backing module |
|---|---|---|
| Unified APB (Wlink + TideLink) | `0x4403_0000` | `axi_chiplet_controller` + `tidelink_apb_regs` + `tidelink_addr_translator` |
| PHC (ptp-hardware-clock-ahb IP) | `0x4405_0000` | `phc_apb_regs` |

Unified APB internal decode (`tidelink_top.sv:601-603`):
- `paddr[14:13]=00` → Wlink chiplet controller (`0x4403_0000..0x4403_1FFF`)
- `paddr[14:13]=01` → TideLink config regs (`0x4403_2000..0x4403_3FFF`)
- `paddr[14:13]=10` → Address-translator regs (`0x4403_4000..0x4403_5FFF`)

Inside `0x4403_2000` the decode is `paddr[8:5]` selects Region (0..8), and
`paddr[4:2]` selects slot (8 slots per region of 4 bytes each).

**Safety rail (do not violate).** Per `_ptp_common.sh` header: never touch
AHB_TX (`0x4400_0000`) — that is the wedge hazard. All probes below are APB
reads only.

---

## Region 0 — Core TideLink status

Source: `src/rtl/tidelink_apb_regs.sv:264-296`. Decoded as `apb_region=0`,
`paddr[4:2]=N`. All addresses are `APB_BASE+0x2000+offset`.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2000` PAIR_BASE_ADDR | 32 | `tidelink_apb_regs.sv:268,131` | RW: programmed paired-die base addr (for returner) | runtime-mutable | N (config, not status) |
| `0x4403_2004` RELEASE_THRESHOLD | 32 | `tidelink_apb_regs.sv:269,133` | RW: credits batched before release pkt | runtime-mutable | N |
| `0x4403_2008` PACKET_WORD_LENGTH | 14 | `tidelink_apb_regs.sv:270` | Current packet word length from FIFO ctrl | runtime-mutable | N (PHC sync uses short pkts, not FIFO) |
| `0x4403_200C` CREDIT_COUNT | 15 | `tidelink_apb_regs.sv:271,259` | Free credits in local FIFO | runtime-mutable | N |
| `0x4403_2010` STATUS | 5 | `tidelink_apb_regs.sv:272-279` | `[4]packet_committed [3]master_error [2]fifo_underrun [1]fifo_overrun [0]returner_busy` | **bits[3:1] sticky, cleared by CTRL.FLUSH** | **Y** — sticky error flags. If `master_error/fifo_overrun/fifo_underrun` ever asserted during HW_SYNC test, RTL data plane saw a fault. |
| `0x4403_2018` RELEASE_ACC | 32 | `tidelink_apb_regs.sv:280,232` | Pending unreleased credits (debug) | runtime-mutable | N |
| `0x4403_201C` CTRL | 2 | `tidelink_apb_regs.sv:281,107-127` | RW: `[1]FLUSH (self-clearing W1P) [0]EN` | RW | N (config) |

---

## Region 1 — Credit accumulators + PTP basic

Source: `src/rtl/tidelink_apb_regs.sv:285-292` + `src/rtl/tidelink_ptp.sv:520-545`.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2020` RELEASED_CREDITS_ACC | 32 | `tidelink_apb_regs.sv:287,167-177` | W-add / **R-clear**. Receives credit deltas from peer. IRQ when != 0. | **clear-on-read** | Y (low) — any value > 0 proves the *credit* return path delivers from peer; PHC sync is short-pkt not credits, but a non-zero value confirms RX FC path is alive at all. |
| `0x4403_2024` DOORBELL_RESPONSE_ACC | 32 | `tidelink_apb_regs.sv:288,181-193` | W-add / **R-clear**. Doorbell responses from peer. | **clear-on-read** | Y (low) — same logic as above. |
| `0x4403_2028` PAIR_CREDIT_COUNTER | 32 | `tidelink_apb_regs.sv:289,197-222` | Running peer credit total | runtime-mutable | N |
| `0x4403_2030` PAIR_CREDIT_COUNTER_EN | 1 | `tidelink_apb_regs.sv:290,208-210` | RW: pair credit counter enable | RW | N |
| `0x4403_2034` PTP_CTRL | 7 | `tidelink_ptp.sv:538-539,333-339` | `[6:3]rx_msg_type [2]rx_valid [1]clear(W1P) [0]enable` | bit[2] **clear-on-write-clear or on RX_PAYLOAD read** | **Y, CRITICAL** — slave bit[2] = "did the slave ever latch ANY PTP RX packet?" Per build-#13 retry #3: slave reads `0x1` (enable only) mid-test → RX never fires. |
| `0x4403_2038` PTP_RX_PAYLOAD | 32 | `tidelink_ptp.sv:540,293-310` | Last received PTP FC word payload; reading **clears** `rx_valid`. | **read clears `PTP_CTRL.rx_valid`** | **Y, CRITICAL** — slave should see incrementing 16-bit seq num; build #11 saw `0x0` after 60 s. |
| `0x4403_203C` PTP_STATUS | 2 | `tidelink_ptp.sv:541` | `[1]tx_pending [0]tx_router_idle` | runtime-mutable | Y — slave `[0]` = is the local Wlink TX router idle? Sanity check. |

---

## Region 2 — PTP HW_SYNC initiator + Servo config

Source: `src/rtl/tidelink_ptp.sv:520-534` + `src/rtl/tidelink_ptp_servo.sv:120-182`.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2040` HW_SYNC_CTRL | 3 | `tidelink_ptp.sv:525,466-479` | `[2]force_en [1]seq_clear(W1P) [0]enable` | RW | Y (config) — master usually `0x5`. |
| `0x4403_2044` HW_SYNC_INTERVAL | 30 | `tidelink_ptp.sv:527` | Sync interval (ns), default `999_999_999` | RW | N |
| `0x4403_2048` HW_SYNC_STATUS | 19 | `tidelink_ptp.sv:528-532` | `[18]phc_locked [17:2]seq_num [1]busy [0]active` | runtime-mutable | **Y, PRIMARY** — master typically reads `0x47f5/0x4815/0x4831` (FSM advancing, seq incrementing). **Slave reading `0x0` is the headline bug** — confirms slave RX FSM never advances. |
| `0x4403_204C` SERVO_CTRL | 2 | `tidelink_ptp_servo.sv:172,156-159` | `[1]mode(0=GM,1=Sub) [0]enable` | RW | N |
| `0x4403_2050` SERVO_KP | 32 | `tidelink_ptp_servo.sv:173` | Proportional gain Q0.32 | RW | N |
| `0x4403_2054` SERVO_KI | 32 | `tidelink_ptp_servo.sv:174` | Integral gain Q0.32 | RW | N |
| `0x4403_2058` SERVO_STEP_THRESH | 32 | `tidelink_ptp_servo.sv:175` | Step threshold (ns) | RW | N |
| `0x4403_205C` SERVO_STATUS | 2 | `tidelink_ptp_servo.sv:176` | `[1]active(gm_active\|sub_active) [0]locked` | runtime-mutable | **Y, PRIMARY** — slave `[0]locked` is the PASS criterion. Stuck `0x0` means no `sync_rx_done` events arriving. |

---

## Region 3 — PTP servo extended status + RX_DIAG (build #11 / parked)

Region 3 is `paddr[8:5] = 011`. Slots 5..7 are servo status (per
`tidelink_ptp_servo.sv:126-128, 177-179`); slots 1..3 were the **parked
`feat/phc-rx-counters` RX_DIAG counters** which read nonsense on slave (per
`PHC_PHASE1_HW_REPORT.md` §"Build #11"). On `main` build #13 / #14 these
counters are NOT present.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2060` SERVO_DELAY | 32 | `tidelink_ptp_servo.sv:177` | Last one-way delay (ns) | runtime-mutable | Y — if non-zero on slave, sync IS arriving. If `0x0` throughout test, no `sync_rx_done` ever pulsed. |
| `0x4403_2064` SERVO_NS_FRAC | 32 | `tidelink_ptp_servo.sv:178` | Current `NS_INCR_FRAC` driven into PHC | runtime-mutable | Y — slave non-zero proves the integrator has accumulated at least one measurement. |
| `0x4403_2068` SERVO_OFFSET (alias for `last_offset_r`) | 32 | `tidelink_ptp_servo.sv:179,138` | Signed last computed offset (ns) | runtime-mutable | Y |
| `0x4403_2070-207C` — | — | (mailbox region; written by FC SIDEBAND not by CPU) | MBOX timestamp area | — | N (write-only from FC) |
| `0x4403_2074 RX_DIAG.LL_VALID_CNT` (build #11 only) | 32 | parked branch `feat/phc-rx-counters` | Slave decode known broken — master reads plausible, slave reads `0x800000` constant. | parked | **N** until slave-side address decode fixed. |
| `0x4403_2078 RX_DIAG.SHORT_PKT_CNT` (build #11 only) | 32 | parked | Same parked status | parked | N |
| `0x4403_207C RX_DIAG.PHC_ACCEPT_CNT` (build #11 only) | 32 | parked | Same parked status | parked | N |

> **NOTE for next session:** the design intent of RX_DIAG was the right
> instrument — what failed was the slave-side address decode, not the
> counters themselves. Until that wiring is fixed, use the sim
> `cocotb/phc_pair/test_phc_diag.py` for equivalent per-cycle counts in
> sim only.

---

## Region 4 — Chiplet controller (role / I²C / autoneg)

Source: `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:506-518`.
Decode `ctrl_reg_addr[3]=0`, `ctrl_reg_addr[2:0]=N` → `0x4403_2080+0x4*N`.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2080` ROLE_CFG | 2 | `axi_chiplet_controller.sv:508,425-430` | `[1]role_lock(W1S, POR-only clear) [0]role(0=master,1=slave)` | W1S | N (config) |
| `0x4403_2084` ROLE_STATUS | 4 | `axi_chiplet_controller.sv:509-510` | `[3]i2c_addressed [2]i2c_busy [1]locked [0]effective_role` | runtime-mutable | Y — confirms slave is in slave role after autoneg. |
| `0x4403_2088` I2C_SLV_ADDR | 7 | `axi_chiplet_controller.sv:511` | I²C slave 7-bit address | RW | N |
| `0x4403_208C` I2C_PRESCALE | 16 | `axi_chiplet_controller.sv:512` | I²C clock prescaler | RW | N |
| `0x4403_2090` NEGO_CFG | 7 | `axi_chiplet_controller.sv:513` | Autoneg cfg | RW | N |
| `0x4403_2094` NEGO_STATUS | 10 | `axi_chiplet_controller.sv:514` | `[9]mask_mismatch [8]sda_start_seen [7:6]nego_lost/won [5]nego_error [4]nego_done [3:0]nego_state` | runtime-mutable | Y — verifies autoneg completed cleanly on slave. |
| `0x4403_2098` NEGO_PRIORITY | 16 | `axi_chiplet_controller.sv:515` | Tie-break priority | RW | N |
| `0x4403_209C` NEGO_TIMEOUT | 32 | `axi_chiplet_controller.sv:516` | Autoneg timeout | RW | N |

---

## Region 8 — PHY-align observability (lane lock + ECC counters)

Source: `axi_chiplet_controller.sv:524-657` + RDL doc
`docs/REGISTER_MAP.md:158-220`. Decode `ctrl_reg_addr[3]=1`,
`ctrl_reg_addr[2:0]=N` → `0x4403_2100+0x4*N`.

| Addr | Width | Source RTL file:line | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_2100` SWI_TRAINING_MODE | 2 | `axi_chiplet_controller.sv:540-551` | `[1]swi_recal [0]swi_training_mode` (POR-only clear) | RW (POR reset) | N |
| `0x4403_2104` SWI_BIT_SLIP_LO | 24 | `axi_chiplet_controller.sv:553` | Per-lane bit-slip override (8×3b) | RW | Y (debug) — non-zero means calibrator or SW has overridden default. |
| `0x4403_2108` SWI_LANE_STATUS | 32 | `axi_chiplet_controller.sv:524 + REGISTER_MAP.md:186-198` | `[31:30]rsv [29]llrx_valid [28]pkt_is_crack [27]pkt_is_cr [26]is_long_pkt [25]is_short_pkt [24]crack_pkt_seen_rx [23]cr_pkt_seen_rx [22:21]llrx_state [20:17]fcsm_state [16]calibration_done [15:8]lane_fault [7:0]lane_locked` | bits[24:23] **sticky** (rx-seen flags) | **Y, PRIMARY** — this is the single highest-information word. Per `_ptp_common.sh` `check_link_up` it's the link-up gate. On slave in the bug state: `lane_locked=0xff cal_done=1` BUT we expect `[29]llrx_valid` to pulse high during master TX and `[25]is_short_pkt` to assert on each SYNC. If both stay 0 → RX deserialiser frame-boundary never fires (clock-recovery hypothesis). If `[25]` pulses but `[23]cr_pkt_seen_rx` stays 0 → ECC silently drops every packet (P&R skew past IDELAY hypothesis). **Reading this slot discriminates the two top-ranked SIM_HW_GAP_ANALYSIS root causes**. |
| `0x4403_210C` NEGO_TRAIN_CFG | 16 | `axi_chiplet_controller.sv:568` | I²C training handshake config | RW | N |
| `0x4403_2110` NEGO_TRAIN_STATUS | — | `axi_chiplet_controller.sv` (training FSM block) | Training FSM live state + last peer values | runtime-mutable | Y (low) — confirms training-handshake closed cleanly. |
| `0x4403_2114` ECC_COUNTERS | 32 | `axi_chiplet_controller.sv:500-501,611-612 + REGISTER_MAP.md:201-210` | `[31:16]ecc_corrected_cnt (sat@0xffff) [15:0]ecc_corrupted_cnt (sat@0xffff)` | saturating counters, no clear path on this build | **Y, PRIMARY** — this is the ECC sat-counter. Slave reading `[15:0]>0` proves ll_rx saw frames but ECC failed (P&R skew hypothesis). Slave reading `0x0000_0000` while master shows `LinkInterrupts=0x00020202` (`ecc_corrected` set) is consistent with slave RX never firing a frame at all. |
| `0x4403_2118` SWI_PHASE_OFFSET | 32 | `axi_chiplet_controller.sv:564` | Per-lane phase override (8×4b) | RW | Y (debug) |
| `0x4403_211C` PHY_ALIGN_ID | 32 | RDL doc | RO constant `0x5041_0100` ("PA" v1.0) | RO | Y (presence probe) — read once at start to confirm Region 8 is responding at all. |

---

## Wlink internals (via chiplet-controller register exports)

Source: `deps/axi-chiplet-controller/docs/source/register_map.rst` (mirrored
in `docs/REGISTER_MAP.md:272-381`). All offsets are **`APB_BASE + offset`**
(in the unified APB window; `paddr[14:13]=00` selects Wlink).

### Wlink Link Registers — `0x4403_0200..0x4403_024F`

| Addr | Width | Source | Meaning | Sticky? | Slave-RX-debug useful? |
|---|---|---|---|---|---|
| `0x4403_0208` EnableReset | 24 | `Wlink.v` LinkRegs | `[23:16]preq_data_id [15:8]short_pkt_max [3]sw_reset [2]llrx_en [1]lltx_en [0]swi_enable` | RW | **Y** — already used as evidence in PHC report: slave `0x00027f07` = LLRX enabled, short_pkt_max=0x7f. If slave LLRX bit cleared → entire short-pkt RX path dead. |
| `0x4403_0210` ActiveLanes | 32 | LinkRegs | `[31:16]rx_lanes-1 [15:0]tx_lanes-1` | RO | Y — confirms RX side counted full 8 lanes. |
| `0x4403_0214` LaneMask | 32 | LinkRegs | `[31:16]rx_lane_mask [15:0]tx_lane_mask` | RW | Y — verify slave's RX mask is `0xff`. |
| `0x4403_0234` LinkStatus | 5 | LinkRegs | `[4]rx_data_valid [3]tx_ready [2]in_error_state [1]sb_reset_mux [0]sb_reset` | runtime-mutable (W1C on `in_error_state`?) | **Y** — slave `[4]rx_data_valid=0` would be the smoking gun for clock-recovery failure. `[2]in_error_state=1` would be the smoking gun for ECC catastrophic. |
| `0x4403_0240` LinkInterrupts | 32 | LinkRegs | `[16]ecc_corrupted(W1C) [17]ecc_corrupted_int_en [8]ecc_corrected(W1C) [9]ecc_corrected_int_en [0]crc_errors(W1C) [1]crc_errors_int_en` | **W1C** | **Y, PRIMARY** — per PHC report build #9 retry #2: master shows `0x00020202` (corrected set, ints enabled) confirming master→slave→master loop is alive on the slave-TX side; **slave shows `0x0` confirming slave's RX side sees nothing.** The single most diagnostic register after `HW_SYNC_STATUS`. |

### Wlink PHY Registers — `0x4403_0000..0x4403_001F`

| Addr | Width | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x4403_000C` PLL Enable/Lock | 9 | `[8]pll_locked(RO) [0]pll_enable(RW)` | Y (low) — slave PLL locked? sanity. |

### Wlink FC Node Registers — common layout per node

Per `docs/REGISTER_MAP.md:340-381`. Node bases: AW=0x1000, W=0x1100,
B=0x1200, AR=0x1300, R=0x1400, GeneralBus=0x1600, **TideLink=0x1700**.

| Offset | Meaning | Slave-RX-debug useful? |
|---|---|---|
| `+0x08` TX_FC_FIFO `[0]empty` | TX FC FIFO empty | Y (low) |
| `+0x10` AckNack_FIFO `[0]empty [1]full [2]half_full [3]almost_empty [4]almost_full` | RX-side ack/nack FIFO levels | **Y** — `+0x10` on TideLink node (0x1710) → slave reading `full=1` would mean the slave-side FC adapter is back-pressuring. |
| `+0x14` SM Control `[16]disable_crc` | Bit[16] disables CRC | Y — verify slave has same CRC setting as master. |
| `+0x20` CRC_Errors | 16-bit CRC error count | **Y, PRIMARY** — per-FC-node CRC error count. Slave TideLink-node `0x4403_1720` non-zero would be definitive proof of corrupted FC packet payload. **NOT yet read by any pynq_host script — add to next session's read-set.** |

**Per-FC-node `CRC_Errors` absolute addresses (TideLink-relevant):**
- `0x4403_1620` GeneralBus CRC_Errors
- `0x4403_1720` **TideLink FC node CRC_Errors** ← read on slave
- `0x4403_1020/1120/1220/1320/1420` AXI AW/W/B/AR/R CRC_Errors (less
  relevant in the FPGA bring-up which doesn't route AXI traffic).

---

## PHC IP registers — `PHC_BASE = 0x4405_0000`

Source: `~/SoCLabs/ptp-hardware-clock-ahb/src/rtl/phc_apb_regs.sv:106-357`.
Already extensively wired in `pynq_host/scripts/_ptp_common.sh:31-50`.

### Region 0 — Core (0x000-0x01F)

| Offset | Addr | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x000` CTRL | `0x4405_0000` | `[2]capture(self-clear) [1]set_time(self-clear) [0]en` | Y (control) |
| `0x004` STATUS | `0x4405_0004` | `[2]alarm_hit [1]pps_sticky(R-clear) [0]running` | Y — slave PHC running? bit[0] should be 1 after `phc_init_50mhz`. |
| `0x008` NS_INCR | `0x4405_0008` | Integer ns increment per cycle | Y (config) |
| `0x00C` NS_INCR_FRAC | `0x4405_000C` | Fractional ns increment | Y (config) |
| `0x010/0x014` SET_SECONDS_LO/HI | `0x4405_0010/14` | Set-time seconds | RW |
| `0x018` SET_NANOSECONDS | `0x4405_0018` | Set-time ns | RW |
| `0x01C` INT_EN | `0x4405_001C` | `[1]alarm_irq_en [0]pps_irq_en` | RW |

### Region 1 — SW Capture / Alarm (0x020-0x03C)

| Offset | Addr | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x020/0x024` CAP_SECONDS_LO/HI | `0x4405_0020/24` | SW-captured seconds | Y (control) — used by `phc_sw_capture` for sanity reads. |
| `0x028` CAP_NANOSECONDS | `0x4405_0028` | SW-captured ns | Y |
| `0x02C` CAP_NS_FRAC | `0x4405_002C` | SW-captured sub-ns | Y |
| `0x030-0x03C` ALARM_* | `0x4405_0030..3C` | Alarm comparator | N |

### Region 2 — HW Capture (0x040-0x04C)

This is the **PHC observation point used by `tidelink_ptp` on every PTP TX
handshake / RX accept** (`tidelink_ptp.sv:315`: `phc_hw_capture =
tx_handshake | rx_accept`). Already wired into `_ptp_common.sh:40-43`.

| Offset | Addr | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x040/0x044` HW_CAP_SECONDS_LO/HI | `0x4405_0040/44` | HW-captured seconds | **Y, PRIMARY** — on slave, if no RX accept ever fires, `HW_CAP_*` should stall at `0x0` (or whatever was there from boot). Compare master vs slave at intervals during HW_SYNC test. |
| `0x048` HW_CAP_NANOSECONDS | `0x4405_0048` | HW-captured ns | Y |
| `0x04C` HW_CAP_NS_FRAC | `0x4405_004C` | HW-captured sub-ns | Y |

### Region 4 — Servo control (0x0A0-0x0AC) — PHC-internal servo

Source: `phc_apb_regs.sv:143-145,338-357`. This is the PHC IP's INTERNAL
servo (ha1588) — separate from `tidelink_ptp_servo` which lives in
TideLink's APB at `0x4403_204C`.

| Offset | Addr | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x0A0` SERVO_CTRL | `0x4405_00A0` | `[1]ha1588_servo_en [0]servo_src_sel (0=external)` | N (production uses external = TideLink servo) |
| `0x0A4` SYNC_INTERVAL | `0x4405_00A4` | Sync interval (ns) | N |
| `0x0A8` SERVO_STATUS | `0x4405_00A8` | `[1]phase_step_active [0]locked` | N (this is the ha1588 lock, not the TideLink servo lock) |

---

## Address translator registers — `0x4403_4000..`

`paddr[14:13]=10`. Two channels, identity map at reset. Per
`docs/REGISTER_MAP.md:430-447`. Not relevant to the PHC short-packet path —
short packets bypass the address translator entirely.

| Addr | Width | Meaning | Slave-RX-debug useful? |
|---|---|---|---|
| `0x4403_4000` BASE_OFFSET | 32 | Channel-0 base offset | N |
| `0x4403_4004-4100` SEGMENT_TABLE[64] | 32×64 | Channel-0 segment LUT | N |
| `0x4403_4FD0-4FFC` PIDR/CIDR | 32×8 | ARM PrimeCell IDs | Y (low) — presence probe. |

---

## "Mystery / undocumented" registers

What's reachable today but **not** used by any bringup script:

| Addr | Why interesting for slave-RX-bug |
|---|---|
| `0x4403_0234` Wlink LinkStatus | `rx_data_valid` bit not in any script. Direct read of slave Wlink's view of "am I seeing valid RX data". |
| `0x4403_0240` LinkInterrupts | Already known-useful from PHC report; `_ptp_common.sh` does NOT expose a helper — every script that wants this hand-rolls it. |
| `0x4403_1720` TideLink FC-node CRC_Errors (offset 0x20 of FC node base 0x1700) | Per-FC-node CRC error count. Zero script reads it. |
| `0x4403_1710` TideLink FC-node AckNack FIFO status | Per-node FIFO flags. Zero script reads it. |
| `0x4403_2114` ECC_COUNTERS (Region 8 slot 5) | Already in RDL; no script reads it. Critical for discriminating "frame seen but corrupted" vs "no frame seen at all". |
| `0x4403_2108` SWI_LANE_STATUS bits[29:17] (credit-path observability) | `check_link_up` only reads `[16:0]`. Upper 13 bits encode `fcsm_state`, `llrx_state`, `is_short_pkt`, `cr_pkt_seen_rx`, etc. — exactly the slave-RX bug observation surface. **Highest-value untapped read.** |
| `0x4403_211C` PHY_ALIGN_ID | Region-8 presence probe; not used. |

---

## Recommended read-set for next HW debug session

Copy-pasteable bash function. Drop into `pynq_host/scripts/` or source from
an interactive session. Reads every "slave-RX-debug useful" address and
prints `name = 0xNNNN` lines. Designed to be run on master AND slave, then
diff'd.

```bash
#!/bin/bash
# phc_observability_dump.sh — read every PHC Phase-1 useful observation
# point and print `name = 0xNNNN`. Run via:
#   . pynq_host/scripts/_ptp_common.sh
#   dump_observability "$MASTER_IP" master
#   dump_observability "$SLAVE_IP"  slave
# Then diff master.dump slave.dump.

dump_observability() {  # IP TAG
    local IP=$1 TAG=$2
    {
        # --- Region 0/1 — TideLink core + PTP basic ---
        printf 'TL_STATUS               = 0x%08x\n' "$(apb_r "$IP" 0x2010)"
        printf 'TL_RELEASED_CREDITS_ACC = 0x%08x\n' "$(apb_r "$IP" 0x2020)"
        printf 'TL_DOORBELL_RESPONSE    = 0x%08x\n' "$(apb_r "$IP" 0x2024)"
        printf 'PTP_CTRL                = 0x%08x\n' "$(apb_r "$IP" 0x2034)"
        printf 'PTP_RX_PAYLOAD          = 0x%08x\n' "$(apb_r "$IP" 0x2038)"
        printf 'PTP_STATUS              = 0x%08x\n' "$(apb_r "$IP" 0x203C)"
        # --- Region 2 — HW_SYNC + servo ---
        printf 'HW_SYNC_CTRL            = 0x%08x\n' "$(apb_r "$IP" 0x2040)"
        printf 'HW_SYNC_STATUS          = 0x%08x\n' "$(apb_r "$IP" 0x2048)"
        printf 'SERVO_CTRL              = 0x%08x\n' "$(apb_r "$IP" 0x204C)"
        printf 'SERVO_STATUS            = 0x%08x\n' "$(apb_r "$IP" 0x205C)"
        # --- Region 3 — servo extended ---
        printf 'SERVO_DELAY             = 0x%08x\n' "$(apb_r "$IP" 0x2060)"
        printf 'SERVO_NS_FRAC           = 0x%08x\n' "$(apb_r "$IP" 0x2064)"
        printf 'SERVO_OFFSET            = 0x%08x\n' "$(apb_r "$IP" 0x2068)"
        # --- Region 4 — role / autoneg ---
        printf 'ROLE_STATUS             = 0x%08x\n' "$(apb_r "$IP" 0x2084)"
        printf 'NEGO_STATUS             = 0x%08x\n' "$(apb_r "$IP" 0x2094)"
        # --- Region 8 — PHY-align observability (the BIG one) ---
        printf 'SWI_LANE_STATUS         = 0x%08x\n' "$(apb_r "$IP" 0x2108)"
        printf 'ECC_COUNTERS            = 0x%08x\n' "$(apb_r "$IP" 0x2114)"
        printf 'PHY_ALIGN_ID            = 0x%08x\n' "$(apb_r "$IP" 0x211C)"
        # --- Wlink link/PHY ---
        printf 'WL_EnableReset          = 0x%08x\n' "$(apb_r "$IP" 0x0208)"
        printf 'WL_ActiveLanes          = 0x%08x\n' "$(apb_r "$IP" 0x0210)"
        printf 'WL_LaneMask             = 0x%08x\n' "$(apb_r "$IP" 0x0214)"
        printf 'WL_LinkStatus           = 0x%08x\n' "$(apb_r "$IP" 0x0234)"
        printf 'WL_LinkInterrupts       = 0x%08x\n' "$(apb_r "$IP" 0x0240)"
        printf 'WL_PLL_Lock             = 0x%08x\n' "$(apb_r "$IP" 0x000C)"
        # --- Wlink FC-node TideLink (0x1700) — CRC + AckNack ---
        printf 'FC_TIDELINK_AckNack     = 0x%08x\n' "$(apb_r "$IP" 0x1710)"
        printf 'FC_TIDELINK_CRC_Errors  = 0x%08x\n' "$(apb_r "$IP" 0x1720)"
        # --- PHC ---
        printf 'PHC_STATUS              = 0x%08x\n' "$(phc_r "$IP" 0x004)"
        printf 'PHC_HW_CAP_SECONDS_LO   = 0x%08x\n' "$(phc_r "$IP" 0x040)"
        printf 'PHC_HW_CAP_NANOSECONDS  = 0x%08x\n' "$(phc_r "$IP" 0x048)"
    } > "/tmp/obs_${TAG}.dump"
    echo "wrote /tmp/obs_${TAG}.dump  ($(wc -l < /tmp/obs_${TAG}.dump) probes)"
}
```

### Top-5 read addresses to inspect FIRST on slave (for the build-#11/#13 bug)

| Rank | Addr | Why |
|---|---|---|
| 1 | `0x4403_2108` SWI_LANE_STATUS | Single 32-bit word that encodes lane-lock + `llrx_valid` + `is_short_pkt` + `cr_pkt_seen_rx` + `fcsm_state`. Discriminates "clock-recovery dead" vs "ECC silently drops" vs "FSM wedged" without further reads. |
| 2 | `0x4403_2114` ECC_COUNTERS | If `[15:0]ecc_corrupted_cnt > 0` on slave → P&R-skew hypothesis (frames decoded but ECC fails). If `0x0000_0000` → clock-recovery hypothesis (no frames decoded at all). |
| 3 | `0x4403_0240` LinkInterrupts | Already gold-standard: slave `0x0000_0000` vs master `0x0002_0202` = the unambiguous existing slave-RX bug signature. Re-read after each HW_SYNC run to detect any change. |
| 4 | `0x4403_2048` HW_SYNC_STATUS | The PASS/FAIL gate. Master `0x47f5/0x4815` (FSM advancing); slave `0x0` (silent) is the bug. |
| 5 | `0x4403_1720` TideLink FC-node CRC_Errors | Currently UNREAD by any script. Non-zero on slave would be a definitive hardware-corruption signal at the FC-node layer. |

---

## Holes in observability — what we'd want to add

Cross-referencing `docs/SIM_HW_GAP_ANALYSIS.md` §4 hypotheses with the
addresses above:

| Hypothesis | What we can read TODAY | What we CANNOT read (the hole) | Minimal RTL addition |
|---|---|---|---|
| **(1) P&R skew past IDELAY tap range** | `SWI_LANE_STATUS[16:0]` (lane_locked / lane_fault / cal_done) — but only a binary "in window / out of window" verdict from the calibrator. | **Per-lane IDELAY tap value the calibrator settled on.** The calibrator owns the 5-bit tap per lane (`tidelink_phy_align_calibrator.sv`) but the value is never surfaced through APB. If the calibrator landed at tap 0 or tap 31 (range edges) on any lane → strong P&R hypothesis evidence. | **8 × 5-bit tap register at a new Region 8 slot 7 alias** (0x2120, since the PA_ID at 0x211C is the last slot in the region today, this needs a Region-9 carve-out OR repurpose the unused upper bits of PHY_ALIGN_ID). One-flop snapshot of the calibrator's per-lane tap output, 2-FF synced into apb_clk. ~30 lines. |
| **(2) Clock-recovery race on first master-TX edge** | `SWI_LANE_STATUS[29]llrx_valid` is a snapshot of "is RX valid RIGHT NOW" — but if it goes high once then back low we miss the event. | **Sticky "ll_rx ever saw a frame boundary" + recovered-RX-clock cycle counter** so we can tell "RX clock is dead" from "RX clock is alive but data is garbage". | Two new bits in Region 8: `[30]ll_rx_ever_valid_sticky` (set on first `obs_llrx_valid` rising edge, clear on `swi_recal`), and a **`[31:0]rx_clock_tick_count`** at a new slot (16-bit saturating, set in recovered-RX-clock domain, 2-FF synced — same pattern as ECC counters). ~40 lines. |
| **(3) `set_bus_skew` constraint margin exhaustion** | Nothing — this is a P&R-time property, fully invisible at runtime. | **Per-lane bit-error event counter** (each lane independently). Today only `ecc_corrupted/corrected` aggregate counters exist; with per-lane breakdown a single offending lane shows up as the dominant contributor. | **8 × 16-bit per-lane bit-error count** sourced from the per-lane comparator in the GPIO PHY's `wlink_lane_checker`. Region 9 (new) at 0x2140..0x215C, four slots of two 16-bit lanes each. ~80 lines + 8 sync pairs. |
| **(4) Slave FIFO stuck-pointer at link-active edge** | `STATUS[1]fifo_overrun` / `[2]fifo_underrun` are sticky for the *data-plane* FIFO only. The short-packet RX FIFO (`sp2wl.rx_fifo`) has no APB surface. | **Short-packet RX FIFO write-count + drop-count + wfull-sticky on slave side.** This is precisely what `feat/phc-rx-counters` tried to do but the slave-side address decode was broken. | Re-do `feat/phc-rx-counters` Region 3 wiring but place the counters in Region 8 (which has working slave-side decode per the §9 ECC_COUNTERS that already work) — slots 7/0x211C is the PA_ID, but if we sacrifice PA_ID we could land 4 × 16-bit counters there. ~50 lines + revalidate. |
| **General — no "last-data_id" sticky** | `PTP_CTRL[6:3]rx_msg_type` is the last *accepted* PTP RX msg type — but only one msg-type bit (sync vs delay_req). No way to know if a non-PTP short pkt was received. | **Last received short-pkt `data_id` register on slave** (sticky until cleared) plus a "saw a short pkt with data_id != 0x50/0x51" counter. | 8-bit sticky reg + 16-bit counter in `tidelink_ptp.sv` exposed via Region 3 (0x206C, currently unused). ~20 lines. |
| **General — no APB-burst wedge metric** | Nothing — board wedge is a Zynq PS-side phenomenon. | Out of scope for an APB-readable observation point. | Coalesce the script-side SSH bursts (per `PHC_PHASE1_HW_REPORT.md` §"Process notes for the next agent") instead. |

### Prioritised additions for next RTL pass

If the next session adds *one* observability point: **per-lane IDELAY tap
value (hole #1)** — it discriminates the highest-ranked SIM_HW_GAP root
cause and is the cheapest add (one snapshot per lane, no new clock domain).

If the next session adds *two*: add **sticky `ll_rx_ever_valid`** (hole
#2). The two together split the bug into "RX clock alive" × "IDELAY in
range" — 4 quadrants, each pointing at a different fix.

---

## References

- `src/rtl/tidelink_apb_regs.sv` — Region 0/1 primary register file
- `src/rtl/tidelink_ptp.sv` — Region 1/2 PTP regs
- `src/rtl/tidelink_ptp_servo.sv` — Region 2/3 servo regs
- `src/rtl/tidelink_phy_align_regs.sv` — alternate phy-align shim (legacy
  0x4403_1xxx MMIO; now absorbed into Region 8)
- `src/rtl/tidelink_top.sv:594-664` — unified APB decode (paddr[14:13])
- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:485-657`
  — Region 4 + Region 8 decode + credit-path observability sync
- `~/SoCLabs/ptp-hardware-clock-ahb/src/rtl/phc_apb_regs.sv` — PHC IP
- `docs/REGISTER_MAP.md` — canonical full register map
- `docs/PHC_PHASE1_HW_REPORT.md` — incident log (build #7 .. #13)
- `docs/SIM_HW_GAP_ANALYSIS.md` — three remaining HW-only hypotheses
- `pynq_host/scripts/_ptp_common.sh` — existing `apb_r/apb_w/phc_r/phc_w`
  helpers

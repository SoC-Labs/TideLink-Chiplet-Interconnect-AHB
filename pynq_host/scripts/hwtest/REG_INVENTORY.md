# TideLink HW Test Suite — Register Inventory

Authoritative source: `src/rtl/fifo/tidelink_apb_regs.sv` (region header comment).
APB base on PYNQ-Z2: `0x4403_2000`. Reads/writes go via `/dev/mem` mmap, identical
to existing `wlink_probe.sh` / `bringup_pair_converge.sh` patterns.

Wlink APB base (sibling region): `0x4403_0000`, lane mask at `0x4403_0214`.

Strap GPIO (`debug_unlock`): `0x4404_1000` — must be written `1` before any
non-trivial Region-4/8 access on the slave side. See `set_slot0()` in existing
bringup scripts.

`AHB_TX` aperture: `0x4400_0000` (32 KB). **WEDGE HAZARD** — see safety section.

---

## Coverage matrix

| Cat. | Script | Regs touched (region/offset) | Access |
|-----:|--------|------------------------------|--------|
| 1 | `01_wlink_layer.sh` | Wlink `0x000`, `0x200`, `0x1000-0x1700`, `0x0210`, `0x0214`; R8 `0x108`, `0x114` | R, lane mask RW (restored) |
| 2 | `02_tidelink_top_regs.sh` | R0 `0x000-0x01C` (full sweep) | R/W |
| 3 | `03_ahb_sub_e2e.sh` | R0 status, AHB_SUB aperture (slave-side region exposed via FC) | R/W |
| 4 | `04_ahb_mng_incoming.sh` | R0 `0x00C` credits, R1 `0x028` PAIR_CREDIT_COUNTER, R1 `0x020`/`0x024` | R/W |
| 5 | `05_ahb_tx_storm.sh` | AHB_TX `0x4400_0000+` (GATED) | W/R (verified-up only) |
| 6 | `06_ahb_fifo.sh` | R0 STATUS `0x010`, R1 `0x020`/`0x024`, R0 `0x008`/`0x00C`/`0x018` | R/W, doorbell ring |
| 7 | `07_addr_translation.sh` | R0 `0x000` PAIR_BASE_ADDR, CAM via R4 ctrl pass-through | R/W |
| 8 | `08_ptp_basic.sh` | R1 `0x034` PTP_CTRL, `0x038` PTP_RX_PAYLOAD, `0x03C` PTP_STATUS | R/W |
| 9 | `09_ptp_hw_sync.sh` | R2 `0x040` HW_SYNC_CTRL, `0x044` INTERVAL, `0x048` STATUS | R/W (gated on PHC image) |
| 10 | `10_servo_mailbox.sh` | R2 `0x04C-0x05C` servo cfg, R3 `0x060-0x07C` mailbox | R/W |
| 11 | `11_perf_counters.sh` | R5/R6/R7 `0x0A0-0x0FC` perf | R |
| 12 | `12_chiplet_phyalign.sh` | R8 `0x100-0x11C` (full sweep) | R/W |
| 13 | `13_long_soak.sh` | mixed; safe-ops only | mixed |

---

## Register-by-register inventory

All offsets relative to APB base `0x4403_2000` unless noted.

### Region 0 — Configuration and Status (paddr[7:5]=000)

| Offset | Name | R/W | Reset | Bits | Test method | Expected |
|-------:|------|:----|------:|------|-------------|----------|
| `0x000` | `PAIR_BASE_ADDR` | RW | `TIDELINK_PAIR_BASE` (param) | [31:0] peer APB base | write a few alt values, read back, **then restore** | round-trip |
| `0x004` | `RELEASE_THRESHOLD` | RW | `20` | [31:0] credit threshold | write 0/1/20/255 sweep | round-trip; 0 = immediate-release |
| `0x008` | `PACKET_WORD_LENGTH` | RO | 0 | [13:0] sideband from FIFO | read-only sanity | non-negative; write→`pslverr` |
| `0x00C` | `CURRENT_CREDITS` | RO | full | [12:0] from FIFO | watch under traffic | decrements during writes |
| `0x010` | `STATUS` | RO | 0 | [0] returner_busy, [1] fifo_overrun, [2] fifo_underrun, [3] master_error, [4] packet_committed | read at idle + under stress | sticky errors stay until FLUSH |
| `0x014` | `DOORBELL` / `TIDELINK_VERSION` | W1C / RO | `0x544C_0100` | W: trigger doorbell; R: ID/version | read returns `0x544C_0100`; write triggers doorbell pulse | ID = TL v1.0 |
| `0x018` | `RELEASE_ACC` | RO | 0 | [31:0] pending unreleased credits | read-only sanity | bounded by `RELEASE_THRESHOLD` |
| `0x01C` | `CTRL` | RW | 0 | [0] reserved, [1] FLUSH (W1P), [2] LOCK (W1S) | write FLUSH=1, confirm self-clear; do **not** set LOCK (write-once permanent) | FLUSH self-clears; sticky errs cleared |

### Region 1 — Incoming Credits + PTP basic (paddr[7:5]=001)

| Offset | Name | R/W | Reset | Bits | Test method | Expected |
|-------:|------|:----|------:|------|-------------|----------|
| `0x020` | `RELEASED_CREDITS_ACC` | W-add / R-clear | 0 | [15:0] sat-16 | drive doorbell flow; read clears | IRQ asserts when non-zero |
| `0x024` | `DOORBELL_RESP_ACC` | W-add / R-clear | 0 | [15:0] sat-16 | doorbell→peer→response | IRQ asserts; clears on read |
| `0x028` | `PAIR_CREDIT_COUNTER` | RO | 0 | [31:0] | read after credit storm | matches expected delta |
| `0x02C` | `PAIR_CREDIT_CONSUME` | WO | — | [31:0] consume value | write decrements counter | saturates at 0 (Bug #7) |
| `0x030` | `PAIR_CREDIT_COUNTER_EN` | RW | 1 | [0] enable | toggle and observe | counter freezes when 0 |
| `0x034` | `PTP_CTRL` | RW (passthrough) | impl-defined | per RDL | write+read | round-trip via `tidelink_ptp` |
| `0x038` | `PTP_RX_PAYLOAD` | RO (passthrough) | 0 | — | read | — |
| `0x03C` | `PTP_STATUS` | RO (passthrough) | 0 | — | read | — |

### Region 2 — PTP HW Sync + Servo cfg (paddr[7:5]=010)

| Offset | Name | R/W | Reset | Bits | Test method | Gate |
|-------:|------|:----|------:|------|-------------|------|
| `0x040` | `HW_SYNC_CTRL` | RW | 0 | [0] enable, [1] seq_clear (W1C), [2] force_en | toggle enable | PHC image |
| `0x044` | `HW_SYNC_INTERVAL` | RW | impl-def | period | program 100us..1s | PHC image |
| `0x048` | `HW_SYNC_STATUS` | RO | 0 | [0] active, [1] busy, [17:2] seq_num, [18] phc_locked | observe during sync | PHC image |
| `0x04C..0x05C` | servo KP/KI/STEP_THRESH/... | RW (servo passthrough) | impl-def | servo cfg | poke values, read back | PHC image |

### Region 3 — Servo status + Timestamp Mailbox (paddr[7:5]=011)

| Offset | Name | R/W | Reset | Bits | Test method |
|-------:|------|:----|------:|------|-------------|
| `0x060..0x064` | servo status (offset, freq adj) | RO | 0 | servo state | read during PTP soak |
| `0x068..0x07C` | timestamp mailbox slots | RO (W via FC sideband) | 0 | per-direction TS | check non-zero after sync |

### Region 4 — Chiplet controller role/role-cfg (paddr[7:5]=100)

| Offset | Name | R/W | Reset | Bits | Test method | Expected |
|-------:|------|:----|------:|------|-------------|----------|
| `0x080` | `ROLE_CFG` | RW (W1S role_lock) | 0 | [0] cfg, [1] role_lock | read-only here (deploy_pair sets it) | role_lock=1 after deploy |
| `0x084..0x09C` | misc chiplet ctrl | RW | impl-def | see chiplet doc | read all | non-faulting |

### Region 5/6/7 — Performance counters (paddr[7:5]=101/110/111)

Pass-through to `tidelink_perf`. Each region has 8 × 32-bit slots. Region 5 = TX,
Region 6 = RX, Region 7 = debug/link status. **Bug #23 caveat**: R7
`DBG_LINK_STATUS` was 33→32-bit truncated; ensure build has the fix. Read all
slots in sequence; under traffic the counters should increment.

| Offset | Region | Name | R/W | Notes |
|-------:|:------:|------|:----:|-------|
| `0x0A0+i*4` | R5 | TX packet count, byte count, retries, ... | RO | counts up under TX |
| `0x0C0+i*4` | R6 | RX packet count, byte count, errors, ... | RO | counts up under RX |
| `0x0E0+i*4` | R7 | link state, FCSM observability, dbg | RO | R7 has Bug #23 fix-or-not |

### Region 8 — Chiplet Extended PHY-align + I2C-training (paddr[8]=1)

| Offset | Name | R/W | Reset | Bits | Test method | Expected |
|-------:|------|:----|------:|------|-------------|----------|
| `0x100` | `SWI_TRAINING_MODE` | RW | 0 | [0] train, [1] recal | observed via existing recal | toggleable; recal is W1P-like |
| `0x104` | `SWI_BIT_SLIP_LO` | RW | 0 | [23:0] per-lane bit-slip | write alt values, read back, restore | round-trip |
| `0x108` | `SWI_LANE_STATUS` | RO | 0 | [7:0] locked, [15:8] fault, [16] cal_done, [20:17] FCSM, [22:21] LL_RX, [23] cr_pkt_seen, [24] crack, [25] short, [26] long, [27] is_cr, [28] is_crack, [29] llrx_valid | poll during convergence | 0xFF locked, fault=0, cal_done=1 |
| `0x10C` | `NEGO_TRAIN_CFG` | RW | impl-def | training handshake config | write 0, write nominal | round-trip; **handle with care** (autoneg behaviour) |
| `0x110` | `NEGO_TRAIN_STATUS` | RO | 0 | FSM state | read | reflects autoneg FSM |
| `0x114` | `NEGO_TRAIN_STEP` (alias `ECC_COUNTERS`) | RW (step W1P) / RO (ecc) | 0 | [15:0] ecc_corrupted, [31:16] ecc_corrected | read at idle vs under traffic | counters stable at idle |
| `0x118` | `SWI_PHASE_OFFSET` | RW | 0 | 8×4-bit per-lane phase | read current; do **not** modify (set pre-role_lock) | observed only |
| `0x11C` | `PHY_ALIGN_ID` | RO | `0x5041_0100` | "PA01" + ver | read | exact match required |

### Wlink APB regs (sibling base `0x4403_0000`)

| Offset | Name | R/W | Notes |
|-------:|------|:----|-------|
| `0x0000` | PHY ctrl | RW | swi_phase_offset bits[20:17]; do not modify post-role_lock |
| `0x0200` | Link CRC/FCSM | RO | error counters live here |
| `0x0210` | ActiveLanes | RO | tx=[15:0], rx=[31:16] popcount(mask)-1 |
| `0x0214` | LaneMask | RW | tx=[15:0], rx=[31:16] — **safe to mask in test 1f**, restore after |
| `0x1000+0x100*k` | FC channel header | RO | k=0..7: AR/AW/R/W/B/GenBus/TideLnk |

### Safety notes (must read before running anything)

1. `AHB_TX` (`0x4400_0000`) **wedges the board** if the link isn't up. Every
   script that touches `AHB_TX` must call `verify_link_up()` first and abort if
   `popcount(locked) < 16` or `cal_done == 0`. Bench: bench-confirmed 2026-04-27
   on z2_02.
2. `ROLE_CFG.role_lock` and `CTRL.LOCK` are write-once (POR-only clear). Do not
   set them in tests; deploy_pair already sets `role_lock`.
3. `SWI_PHASE_OFFSET` (`0x118`) is latched at `role_lock` — writing it
   post-deploy has no effect except on a re-deploy boundary.
4. Lane mask `0x4403_0214` writes are safe but must be restored before exit.

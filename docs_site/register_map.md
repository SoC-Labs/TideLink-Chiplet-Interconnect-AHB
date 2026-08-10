# Register Map

TideLink exposes **one unified APB subordinate port** (`apb_*`, 15-bit address)
for every configuration and observability register in the subsystem — the
Wlink chiplet controller, the TideLink core, PTP, the role/autoneg block and
the address translator. There is no second configuration bus.

Primary source: `docs/REGISTER_MAP.md`, cross-checked against the instantiated
RTL. Where the two disagree, **the RTL is authoritative** and the divergence is
called out inline.

:::{danger}
Read [Registers that must never be probed](#registers-that-must-never-be-probed)
before scripting any register sweep. Several offsets hard-stall the CPU, several
are read-to-clear, and one aperture pops a FIFO entry on read. A "read a range
and see what is there" loop **will** break a live link or hang the host.
:::

## Top-level decode

The decode in `tidelink_top.sv:825-827` routes on `paddr[14:13]`:

| `paddr[14:13]` | Range | Region | Forwarded as |
|---|---|---|---|
| `00` | `0x0000`–`0x1FFF` | Wlink chiplet controller | `paddr[12:0]` |
| `01` | `0x2000`–`0x3FFF` | TideLink core / PTP / role / extended | `paddr[8:2]` decoded |
| `10` | `0x4000`–`0x5FFF` | Address translator | `paddr[12:0]` |
| `11` | `0x6000`–`0x7FFF` | **Reserved** | — |

The reserved quadrant is not a bus hole: the response mux returns
`prdata = '0`, `pready = 1'b1`, `pslverr = 1'b0` (`tidelink_top.sv:845-853`), so
it is safe to touch.

### TideLink region sub-decode

Inside `0x2000`–`0x3FFF`, `apb_region = paddr[8:5]`
(`src/rtl/fifo/tidelink_apb_regs.sv:210`) and the slot within a region is
`paddr[4:2]`.

| Region | Range | Contents |
|---|---|---|
| 0 | `0x2000`–`0x201F` | TideLink configuration + status |
| 1 | `0x2020`–`0x203F` | Incoming credit receivers + PTP basic |
| 2 | `0x2040`–`0x205F` | PTP hardware-sync initiator + servo config |
| 3 | `0x2060`–`0x207F` | Servo status (read) / timestamp mailbox (write) |
| 4 | `0x2080`–`0x209F` | Chiplet controller role + autoneg config |
| 5–7 | `0x20A0`–`0x20FF` | Performance profiling |
| 8 | `0x2100`–`0x211F` | Chiplet extended — PHY alignment + I²C training |
| 10 | `0x2140`–`0x215F` | Eye visibility v2 — **V1 only**. `tidelink_eye_regs` declares a 16-slot map up to `0x217F`, but the top-level select (`tidelink_top.sv:1069`) only reaches `0x215F`; see the note below. |
| 11 | `0x2160`–`0x217F` | `tidelink_gpio_phy_apb_regs` lane-checker slave |
| C | `0x2180`–`0x219F` | Autoneg silicon observability (RO) |
| D | `0x21A0`–`0x21BF` | RX-framer / FCH sticky observability (RO, V2) — **hazardous** |
| F | `0x21E0`–`0x21FF` | AXI data-node observability (RO) |

:::{note}
**Region 10 is version-dependent.** Under `TIDELINK_PHY_V2` the eye-visibility
block is retired; the single word at `0x2140` is repurposed as
**`SWI_EPOCH_STATUS`** (RO) from the gpio-phy slave — `[0]` epoch_anchored,
`[6:1]` epoch_span in words (0–24). The rest of `0x2140`–`0x215F` reads 0.
:::

---

## Region 0 — Configuration and status

Module: `tidelink_apb_regs`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2000` | `PAIR_BASE_ADDR` | RW | `TIDELINK_PAIR_BASE` param | Base address of the paired TideLink's APB space; the returner derives target addresses from it. Blocked once `CTRL.LOCK` is set. |
| `0x2004` | `RELEASE_THRESHOLD` | RW | `0x14` (20) | Credits to accumulate before the returner fires a release packet. 0 = release immediately. Blocked once `CTRL.LOCK` is set. |
| `0x2008` | `PACKET_WORD_LENGTH` | RO | 0 | Current packet word length from the FIFO controller (0 when idle), 14-bit. |
| `0x200C` | `CREDIT_COUNT` | RO | 0 | Free credits in the local FIFO, 13-bit. |
| `0x2010` | `STATUS` | RO | 0 | Status and sticky faults — see below. |
| `0x2014` | `DOORBELL` / `ID` | WO / RO | — | **Write** any value fires a doorbell (self-clearing). **Read** returns `0x544C_0100` ("TL" v1.0). |
| `0x2018` | `RELEASE_ACC` | RO | 0 | Debug: credits freed but not yet released (below threshold). |
| `0x201C` | `CTRL` | RW | 0 | Flush and write-once lock — see below. |

**`STATUS` (`0x2010`)**

| Bit | Name | Description |
|---|---|---|
| `[0]` | `RETURNER_BUSY` | AHB returner master is mid-transfer. |
| `[1]` | `OVERRUN` | Sticky. Data-window write discarded (credit count == 0). Cleared by FLUSH. |
| `[2]` | `UNDERRUN` | Sticky. Data-window read with no packet available. Cleared by FLUSH. |
| `[3]` | `MASTER_ERROR` | Sticky. AHB master got an ERROR response. Cleared by FLUSH. |
| `[4]` | `PACKET_COMMITTED` | Set on write_complete, cleared on FIFO address-0 read. Mirrors `packet_committed_irq`. |

**`CTRL` (`0x201C`)**

| Bit | Name | Access | Description |
|---|---|---|---|
| `[0]` | `EN` | RO, reads 0 | **Reserved.** The RTL no longer implements an enable (`tidelink_apb_regs.sv:173`). |
| `[1]` | `FLUSH` | W1P | Reset pointers, packet state, release accumulator and sticky errors. Self-clearing. |
| `[2]` | `LOCK` | **W1S, write-once** | Blocks further writes to `0x2000` and `0x2004`. Cleared only by reset (`tidelink_apb_regs.sv:191-196`). |

## Region 1 — Credit receivers and PTP basic

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2020` | `RELEASED_CREDITS_ACC` | W-add / **R-clear** | 0 | Credit deltas from the peer. Writes saturating-add (16-bit, clamps `0xFFFF`); **reads return the total and clear it**. Drives `released_credits_irq`. A write also increments `PAIR_CREDIT_COUNTER`. |
| `0x2024` | `DOORBELL_RESPONSE_ACC` | W-add / **R-clear** | 0 | Doorbell responses from the peer. Same saturating-add / read-clear semantics. Drives `doorbell_irq`. |
| `0x2028` | `PAIR_CREDIT_COUNTER` | RO | 0 | Running count of credits available on the peer side. |
| `0x202C` | `PAIR_CREDIT_CONSUME` | WO | 0 | Write the number of credits consumed; subtracted from `PAIR_CREDIT_COUNTER`. |
| `0x2030` | `PAIR_CREDIT_COUNTER_EN` | RW | 1 | `[0]` enable pair-credit updates. 0 freezes the counter. |
| `0x2034` | `PTP_CTRL` | RW/RO | 0 | `[0]` enable, `[1]` clear (self-clearing), `[2]` rx_valid (RO), `[6:3]` rx_msg_type (RO; `0x0` SYNC, `0x1` DELAY_REQ). |
| `0x2038` | `PTP_RX_PAYLOAD` | RO, **read-clears** | 0 | 32-bit payload of the last received PTP FC word. **Reading clears `PTP_CTRL.rx_valid`.** |
| `0x203C` | `PTP_STATUS` | RO | 0 | `[0]` tx_idle (mirror of `tx_router_idle`), `[1]` tx_pending. |

## Region 2 — PTP hardware sync + servo config

Slots 0–2 reach `tidelink_ptp`; slots 3–7 pass through to the servo register
block (`tidelink_apb_regs.sv:435-437`).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2040` | `HW_SYNC_CTRL` | RW | 0 | `[0]` enable, `[1]` seq_clear (W1C), `[2]` force_en — bypasses the `phc_locked` gate (`tidelink_ptp.sv:353`). |
| `0x2044` | `HW_SYNC_INTERVAL` | RW | 0 | `[29:0]` sync interval, nanoseconds. |
| `0x2048` | `HW_SYNC_STATUS` | RO | 0 | `[0]` active, `[1]` busy, `[17:2]` seq_num, `[18]` phc_locked (`tidelink_ptp.sv:355`). |
| `0x204C`–`0x205C` | `SERVO_CFG[0..4]` | RW | 0 | Servo configuration, pass-through (`servo_reg_addr` 0–4). |

:::{warning}
`HW_SYNC_STATUS[18]` (`phc_locked`) reads **0 on every current FPGA bitstream**:
the block design never connects `phc_locked_i` and `PHC_LOCK_GATE_EN = 0`.
Treating it as a pass criterion re-imports a known spurious-pass defect that
the sim test `test_phc_locked_is_real_not_tied` exists to kill
(`docs/PTP_DEMO_RUNBOOK.md:365-369`).
:::

## Region 3 — Servo status / timestamp mailbox

Reads return servo status; **writes are the timestamp-mailbox path**, driven by
the FC SIDEBAND node (`tidelink_apb_regs.sv:440-442`).

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x2060`–`0x2064` | `SERVO_STATUS[0..1]` | RO | Servo status (`servo_reg_addr` 5–6 on read). |
| `0x2060`–`0x207C` | `TS_MAILBOX[0..7]` | WO, FC sideband | Timestamp mailbox slots written by the SIDEBAND node. |

:::{note}
**The mailbox is write-protected against external APB.** Since 2026-07-31,
`mbox_reg_write_fc_only = mbox_reg_write && fc_cfg_apb_active`
(`tidelink_top.sv:917`) qualifies mailbox writes by source. Before that fix a
plain external write to `0x4403_2068` could overwrite an assembled cross-die
PTP timestamp, because `tidelink_apb_regs` derived `mbox_reg_write` from the
raw shared-bus `psel && penable && pwrite` with no source qualifier. Gated by
`sim_gate_v2_mbox_writeprotect`.
:::

## Region 4 — Role and autoneg configuration

These reach `axi_chiplet_controller` through the `ctrl_reg_*` interface with
`ctrl_reg_addr[4:3] = 2'b01`.

:::{important}
**Region 4 is reset only by `poresetn`.** A warm `hresetn` preserves the
negotiated role, so a system reset does not force re-negotiation.
:::

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2080` | `ROLE_CFG` | RW | 0 | Role select and lock — see below. |
| `0x2084` | `ROLE_STATUS` | RO | strap | `[0]` effective_role, `[1]` locked, `[2]` i2c_busy, `[3]` i2c_addressed. |
| `0x2088` | `I2C_SLV_ADDR` | RW | `0x7E` | 7-bit autoneg slave address (`axi_chiplet_controller.sv:726`). |
| `0x208C` | `I2C_PRESCALE` | RW | `0x007D` (125) | I²C master prescaler → 100 kHz SCL at 50 MHz `apb_clk` (`axi_chiplet_controller.sv:745`). |
| `0x2090` | `NEGO_CFG` | RW | **see divergence note** | `[0]` nego_en, `[5]` nego_force_lock, `[6]` mask_hs_auto_en. |
| `0x2094` | `NEGO_STATUS` | RO | 0 | `[3:0]` state, `[4]` done, `[5]` error, `[6]` won, `[7]` lost, `[8]` sda_start_seen, `[9]` mask_mismatch. |
| `0x2098` | `NEGO_PRIORITY` | RW | strap-derived | 16-bit priority, **lower wins**. strap=0 → `0x0001`, strap=1 → `0x0002`. |
| `0x209C` | `NEGO_TIMEOUT` | RW | 131082000 | Autoneg FSM cycle-count timeout. |

**`ROLE_CFG` (`0x2080`)**

| Bit | Name | Access | Description |
|---|---|---|---|
| `[0]` | `role` | RW | 0 = master, 1 = slave. Writable only while `role_lock == 0`. |
| `[1]` | `role_lock` | **W1S, POR-only clear** | Locks the role and releases Wlink POR. Latches only when the mask-handshake gate is open. Cleared only by `poresetn`. |

:::{warning}
**Doc-vs-RTL divergence — `NEGO_CFG` reset value.** `docs/REGISTER_MAP.md`
states a POR default of `7'h61`. That is true only of the **FPGA IP wrapper**
(`fpga/vivado_ip/tidelink_vivado_wrapper.v:147`). The RTL default in
`tidelink_top.sv:141` and in `axi_chiplet_controller` is **`7'h00`** — autoneg
is opt-in and OFF in simulation and ASIC builds. Check the parameter on your
build, not the document.
:::

Two further divergences worth knowing:

- `docs/reference/AUTONEG_PROTOCOL.md` is still marked "RTL not yet
  implemented" against 2418 lines of shipping `src/rtl/local_overrides/tidelink_autoneg.sv`.
- The RDL (`tidelink_regs.rdl:367`) gives `NEGO_PRIORITY` reset as `0xFFFF`;
  the instantiated RTL overrides it to the strap-derived 1/2.

## Region 8 — PHY alignment and I²C training

The workhorse region for bring-up. Also reachable from the peer over the
I²C-slave AXIL bridge, and POR-only reset so training state survives a warm
reset.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2100` | `SWI_TRAINING_MODE` | RW | 0 | `[0]` training-mode enable, `[1]` recal strobe. See the bring-up bit map below. |
| `0x2104` | `SWI_BIT_SLIP_LO` | RW | 0 | `[23:0]` per-lane bit-slip, 8 lanes × 3 bits (lane K at `[3K+2:3K]`). |
| `0x2108` | `SWI_LANE_STATUS` | RO | 0 | `[7:0]` lane_locked, `[15:8]` lane_fault, `[16]` calibration_done, `[31:17]` credit-path observability. |
| `0x210C` | `NEGO_TRAIN_CFG` | RW | 0 | `[15:0]` training handshake config, `[16]` train_fail_irq (sticky, W1C), `[23:20]` `MIN_LOCK_DWELLS` override (0 = use parameter). |
| `0x2110` | `NEGO_TRAIN_STATUS` | RO | 0 | `[0]` train_ok, `[1]` train_fail, `[2]` train_in_progress, `[3]` train_peer_nack, `[7:4]` train_state, `[15:8]` peer_lane_locked, `[23:16]` peer_lane_fault, `[31:24]` local_lane_fault. |
| `0x2114` | `SYNC_DET / ECC` | RO | 0 | `[31:16]` **sync_detected** saturating count, `[15:0]` ecc_corrupted (**dead**) — see below. |
| `0x2118` | `SWI_PHASE_OFFSET` | RW | 0 | `[31:0]` per-lane 4-bit sub-bit phase (lane K at `[4K+3:4K]`). **Latched at role_lock — read-only in practice.** |
| `0x211C` | `PHY_ALIGN_ID` | RO | `0x5041_0100` | "PA" v1.0 — probe for Region 8 presence. |

**`SWI_TRAINING_MODE` (`0x2100`) — the R8 bring-up word**

| Bit | Name |
|---|---|
| `[0]` | training |
| `[1]` | recal |
| `[2]` | insert_en |
| `[3]` | force_always |
| `[4]` | robust |
| `[5]` | sync_obs_clr (W1) |

Common bring-up values used by the runbooks: `SYNC = 0x1C`, `RECAL = 0x1E`,
`DATA = 0x10` (`docs/KR260_FIRST_SESSION_RUNBOOK.md`;
`fpga/hw_regression/td_v2_channels.sh:280`).

**`SWI_LANE_STATUS` (`0x2108`) — credit-path observability**

Packed into bits that were previously dead, so no pre-existing live field
moved (`axi_chiplet_controller.sv:2716-2738`).

| Bits | Name | Source |
|---|---|---|
| `[16:0]` | legacy | lane_locked / lane_fault / calibration_done |
| `[19:17]` | `fcsm_state` | `WlinkGenericFCSM_6.state` (3 bit) |
| `[20]` | `a2l_replay_app_valid` | app-side replay valid |
| `[22:21]` | `llrx_state` | `WlinkRxLinkLayer.state` (== 2 → error) |
| `[23]` | `cr_pkt_seen_rx` | FCSM sticky |
| `[24]` | `crack_pkt_seen_rx` | FCSM sticky |
| `[25]` | `is_short_pkt` | `WlinkRxLinkLayer` |
| `[26]` | `is_long_pkt` | `WlinkRxLinkLayer` |
| `[27]` | `pkt_is_cr_pkt` | FCSM |
| `[28]` | `pkt_is_crack_pkt` | FCSM |
| `[29]` | `llrx_valid` | `WlinkRxLinkLayer.valid` |
| `[30]` | `a2l_fc_replay_link_valid` | FCSM 4→5 send gate, app-valid side |
| `[31]` | `fe_rx_is_full` | FCSM 4→5 send gate, credit side |

:::{warning}
**`fe_rx_is_full` at `0x2108[31]` only flags `fe_rx_credit_max == 0`.** A credit
value garbled to a small *non-zero* passes the send gate and then exhausts after
1–4 packets — the documented CR-credit-decode lottery. Always read the credit
**value** at `OBS_FC_CREDIT` (`0x219C[7:0]`), not just this bit.
:::

:::{note}
**RTL/RDL divergence:** the RDL (`tidelink_regs.rdl:437-470`) still documents
`fcsm_state` at `[20:17]` with `[31:30]` reserved, and
`docs/BOARD_DEPLOY_RUNBOOK.md` repeats the `[20:17]` figure. The instantiated
RTL packs `[19:17]`. **RTL wins.**
:::

**Measured-dead and repurposed fields at `0x2114`**

| Bits | Name | Reality |
|---|---|---|
| `[15:0]` | `ecc_corrupted_cnt` | **Dead.** `WlinkEccSyndrome.v:299-308` ties `corrupted = 0`; always reads 0. |
| `[31:16]` | `sync_detected_cnt` | **Live and useful.** Saturating count of coherent 128-bit SYNC words assembled by the RX. **> 0 proves cross-lane deskew is delivering aligned words; 0 means lanes are still misaligned or the link is dead.** |

The former `ecc_corrected` counter is dead for the same reason and was replaced
by `sync_detected_cnt` (SoC Labs, 2026-06-08).

## Region 10 — Eye visibility (V1 only)

Module `tidelink_eye_regs`, instantiated under `` `ifndef TIDELINK_PHY_V2 ``
(`tidelink_top.sv:1123`). Slot = `paddr[5:2]`, a **4-bit** slot, so the module's
own header claims offsets `0x140`–`0x17F`
(`src/rtl/tidelink_eye_regs.sv:25,105-125`).

:::{warning}
**The module declares 16 slots; only the first 8 are selected.** The top-level
shim select is `eye_shim_sel = tl_apb_psel && (tl_apb_paddr[8:5] == 4'b1010)`
(`tidelink_top.sv:1069`), which is `0x2140`–`0x215F` only. Slots `0x8`–`0xF`
(`0x2160`–`0x217C`, greyed below) are declared inside `tidelink_eye_regs` but
are **not reachable** through that select on this build — `0x2160`+ decodes as
Region 11 instead. They are listed here because the module defines them and
older material quotes them; do not expect them to respond.
:::

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x2140` | `SWI_EYE_CTRL` | RW (W1P `[0]`/`[1]`) | 0 | `[0]` ENTER, `[1]` RESET, `[5:4]` MODE, `[8]` FORCE_FULL_SWEEP, `[9]` AUTO_INCREMENT_LANE, `[16]` capture_arm alias. `MODE = 2'b10` → `pslverr`. |
| `0x2144` | `SWI_EYE_LANE_SEL` | RW | 0 | `[2:0]` lane select, `[3]` all-lanes. |
| `0x2148` | `SWI_EYE_DWELL_US` | RW | `0x2710` | Dwell µs; writes floor-clamped to 6000. |
| `0x214C` | `SWI_EYE_STATUS` | RO | 0 | Calibrator eye-sweep status. |
| `0x2150` | `SWI_FORCE_PHASE_EN` | RW | 0 | Per-lane force-phase enable mask. |
| `0x2154` | `SWI_FORCE_PHASE_VAL` | RW | 0 | Per-lane force-phase value. |
| `0x2158` | `SWI_FORCE_SLIP_VAL` | RW | 0 | Per-lane force-slip value. |
| `0x215C` | `EYE_CRC_ERR_LANE_LO` | **RC** | 0 | Lanes 0–3 saturating CRC error counts. **Read clears.** |
| `0x2160` | `EYE_CRC_ERR_LANE_HI` | **RC** | 0 | Lanes 4–7 saturating CRC error counts. **Read clears.** |
| `0x2164` | `EYE_SCORE_IDX` | RW | 0 | `[6:0]` point index, `[16]` auto-increment on data read. |
| `0x2168` | `EYE_SCORE_DATA` | RO, **auto-inc** | 0 | `[5:0]` score, `[8]` lane_passed, `[15:10]` best score, `[18:16]` best_slip, `[22:19]` best_phase. |
| `0x216C` | `EYE_BURST_DATA` | RO, **auto-inc** | 0 | Five packed 6-bit scores; read advances the index by 5. |
| `0x2170` | `EYE_LAST_LATCHED` | RO | 0 | `[23:0]` last slip vector, `[31:24]` last lane_fault. |
| `0x2174` | `PHY_EYE_ID` | RO | `0x5045_0200` | "PE" v2.0 block ID. |
| `0x2178`, `0x217C` | reserved | RAZ/WI | 0 | Reserved for v2.1 DDR. |

:::{caution}
**`0x2144` saturates and lies.** The live-match counter is a documented
misleading instrument — do not use it as a liveness signal. Likewise `0x215C`
reads 0 by construction in V2 (Region 10 retired), which is *not* evidence of a
healthy link. Use the wedge-detection recipe in {doc}`known_issues` instead.
:::

## Region 11 — GPIO-PHY lane checker (`0x2160`–`0x217F`)

APB slave `tidelink_gpio_phy_apb_regs` (region select `4'b1011`,
`tidelink_top.sv:1242-1263`), exposing the lane checker's per-lane lock
threshold and noise statistics at slave-paddr `0x20`–`0x3F`.

:::{warning}
**`0x2160` collides across PHY versions and is load-bearing during bring-up.**
In a V1 build it is the read-clearing `EYE_CRC_ERR_LANE_HI`. In a V2 build it is
the **per-lane Hamming lock threshold**, set to `0x5555_5555` by the bring-up
scripts (`fpga/hw_regression/td_v2_channels.sh:216,382`). It is *not* free
scratch on a live link: the instrument preamble writes, reads and then
**restores it exactly** (`instrument_preamble.sh:307-339`).
:::

## Region C — Autoneg silicon observability (`0x2180`–`0x219F`)

Read-only mirror of `tidelink_autoneg` internals and the I²C master status.
Read data is assembled at `axi_chiplet_controller.sv:2866`; all slots are RO and
a write raises `pslverr` (`src/rtl/fifo/tidelink_apb_regs.sv:767-769`).

| Offset | Name | Description |
|---|---|---|
| `0x2180` | `OBS_DELAY_CTR` | `autoneg.delay_ctr_r[31:0]`. |
| `0x2184` | `OBS_TIMEOUT_CTR` | `autoneg.timeout_ctr_r[31:0]`. |
| `0x2188` | `OBS_FSM_SUBSTATE` | `[17:13]` init_wait, `[12:10]` axl_state, `[9:7]` txn_step. |
| `0x218C` | `OBS_I2C_MST_STATUS` | `[3]` missed_ack, `[2]` bus_active, `[1]` bus_cont, `[0]` busy. |
| `0x2190` | `OBS_OBS_ID` | "OB" v1.0 marker = `0x4F42_0100`. |
| `0x2194` | `OBS_MASK_HS` | Packed mask-handshake internals: peer masks, local match/fail, lock_pending, gate_open, Wlink result. |
| `0x2198` | `OBS_CAL` | `[3:0]` cal_state, `[19:4]` cal_resweep_ctr, `[20]` live training_mode. |
| `0x219C` | `OBS_FC_CREDIT` | `[7:0]` `fe_rx_credit_max`, `[15:8]` `fe_rx_ptr`, `[16]` `fe_rx_is_full` mirror, `[31:24]` presence marker `0xFC` (reads `0x0000_0000` on older images). |

`OBS_FC_CREDIT` is the register that catches credit garbled to a small non-zero
value — the case `0x2108[31]` cannot see.

## Region D — RX-framer / FCH observability (`0x21A0`–`0x21BF`, V2)

:::{danger}
**Treat `0x21A0`–`0x21B8` as quarantined.** `0x21AC`, `0x21B0` and `0x21B4`
**hard-stall the CPU on read** — a board-proven, uninterruptible AXI hang that
needs a power cycle to clear. See the hazard section below.
:::

| Offset | Name | Access | Notes |
|---|---|---|---|
| `0x21A0`–`0x21A8` | RX-framer / FCH stickies | RO | V2. |
| `0x21AC` | `SYNC_DIST_OBS` | RO | **NEVER READ — CPU hard-stall.** |
| `0x21B0` | winscan lane select | RW | **NEVER TOUCH — CPU hard-stall.** `[2:0]` lane select once the on-chip winscan FSM owns it. |
| `0x21B4` | winscan per-lane result | RW | **NEVER TOUCH — CPU hard-stall.** `[7:0]`, lane N at bit N. |
| `0x21B8` | `WINSCAN_OBS` | RO | Fully packed `[23:0]` on this branch. |
| `0x21BC` | `FCH_OBS` | RO | FC-handshake observability. |

## Region F — AXI data-node observability (`0x21E0`–`0x21FF`)

Silicon-feedback item **I4**, live in both V1 and V2. Built by
`src/rtl/tidelink_axinode_obs.sv` — a pure tapped fan-out, no datapath change.
All slots RO; a write raises `pslverr`
(`src/rtl/fifo/tidelink_apb_regs.sv:778-780`).

`OBS_FC_CREDIT` only surfaces the FCSM_6 **sideband** node. The AXI2WL **data**
nodes — the paths that actually wedge on silicon — had no APB-visible health
field until this region was added.

| Offset | Name | Description |
|---|---|---|
| `0x21E0` | `OBS_AXI_NODES` | `[4:0]` target live-stall `{r,ar,b,w,aw}`; `[9:5]` initiator live-stall; `[14:10]` target wedge-sticky (channel stalled ≥ 2¹² `app_clk` cycles — a real wedge, not back-pressure); `[19:15]` initiator wedge-sticky; `[20]` target B/R response-error sticky; `[21]` initiator response-error sticky; `[22]` any-live-stall; `[23]` **`data_nodes_healthy`**; `[31:24]` presence marker `0xAD` (reads 0 on older images). |
| `0x21E4`–`0x21FC` | reserved | Read 0. |

---

## Wlink chiplet controller (`0x0000`–`0x1FFF`)

Chisel-generated `Wlink`. Upstream reference:
`deps/axi-chiplet-controller/docs/source/register_map.rst`.

| Range | Region |
|---|---|
| `0x0000`–`0x01FF` | PHY registers |
| `0x0200`–`0x03FF` | Wlink link registers |
| `0x1000`–`0x10FF` | AXI2WL AW FC node |
| `0x1100`–`0x11FF` | AXI2WL W FC node |
| `0x1200`–`0x12FF` | AXI2WL B FC node |
| `0x1300`–`0x13FF` | AXI2WL AR FC node |
| `0x1400`–`0x14FF` | AXI2WL R FC node |
| `0x1600`–`0x16FF` | GeneralBus FC node (instantiated, tied off) |
| `0x1700`–`0x17FF` | TideLink FC node |

### PHY registers (base `0x0000`)

| Offset | Name | Bits | Reset | Access | Description |
|---|---|---|---|---|---|
| `0x00` | General Controls | `[7:0]` | 1 | RW | PRE count |
| | | `[15:8]` | 7 | RW | Post count |
| | | `[16]` | 1 | RW | RX polarity |
| `0x04` | Pre Divider | `[3:0]` | 4 | RW | SerDes PLL pre divider |
| `0x08` | Post Divider | `[3:0]` | 0 | RW | SerDes PLL post divider |
| `0x0C` | PLL Enable/Lock | `[0]` | 0 | RW | PLL enable |
| | | `[8]` | 0 | RO | PLL locked |

:::{note}
`swi_delay_cycles = 0` forces `postcount ≡ 7`, which stops the SYNC beacon ever
firing — the root cause of the "all zeros" bring-up saga. The beacon-starvation
failure mode is documented in {doc}`known_issues`.
:::

### Wlink link registers (base `0x0200`)

| Offset | Name | Bits | Reset | Access | Description |
|---|---|---|---|---|---|
| `0x00` | Link Capabilities | `[15:0]` | 8 | RO | Max TX lanes |
| | | `[31:16]` | 8 | RO | Max RX lanes |
| `0x04` | PHY Version | `[31:0]` | — | RO | PHY version |
| `0x08` | Enable/Reset | `[0]` | 1 | RW | SWI enable |
| | | `[1]` | 1 | RW | LL TX enable |
| | | `[2]` | 1 | RW | LL RX enable |
| | | `[3]` | 0 | RW | SW reset |
| | | `[15:8]` | `0x7F` | RW | Max short packet ID |
| | | `[23:16]` | `0x02` | RW | PREQ data ID |
| `0x10` | Active Lanes | `[15:0]` | 7 | RO | Active TX lanes − 1 |
| | | `[31:16]` | 7 | RO | Active RX lanes − 1 |
| `0x14` | Lane Mask | `[15:0]` | `0xFF` | RW | TX lane mask, bit k enables lane k |
| | | `[31:16]` | `0xFF` | RW | RX lane mask |
| `0x30` | P-State Control | `[15:0]` | 1700 | RW | Delay cycles |
| | | `[18:16]` | 0 | RW | Number of P-reqs |
| | | `[31:24]` | 255 | RW | Cycles post reqs |
| `0x34` | Link Status | `[0]` | 0 | RW | SB reset |
| | | `[1]` | 0 | RW | SB reset mux |
| | | `[2]` | 0 | RO | In error state |
| | | `[3]` | 0 | RO | TX ready |
| | | `[4]` | 1 | RO | RX data valid |
| `0x3C` | Error Injection | `[7:0]` | 0 | RW | Inject data ID |
| | | `[15:8]` | 0 | RW | Inject byte |
| | | `[18:16]` | 0 | RW | Inject bit |
| | | `[24]` | 0 | RW | Inject enable |
| `0x40` | Link Interrupts | `[0]` | 0 | RW | CRC errors (W1C) |
| | | `[1]` | 1 | RW | CRC error interrupt enable |
| | | `[8]` | 0 | RW | ECC corrected (W1C) — **dead field** |
| | | `[9]` | 0 | RW | ECC corrected interrupt enable |
| | | `[16]` | 0 | RW | ECC corrupted (W1C) — **dead field** |
| | | `[17]` | 1 | RW | ECC corrupted interrupt enable |

:::{caution}
**Writing `0x0208` is a chip-level hazard.** A write of `{swreset = 1,
swi_enable = 0}` returns all seven FCSMs to IDLE and loses their sticky CR/CRACK
state. The `HARDEN_SWI_ENABLE` parameter (default `1'b1`) forces
`swi_enable = 1` on any write that asserts `swreset`, which is why some KR260
targets deliberately set it to 0 — they need the bootstrap triplet
`0x00027f09`, `0x00027f01`, `0x00027f07` to land. Never hand-drive this triplet
on a board you have not read the runbook for.
:::

### FC node registers (identical layout per node)

| Offset | Name | Bits | Reset | Access | Description |
|---|---|---|---|---|---|
| `0x00` | ID Control | `[7:0]` | varies | RW | Credit ID |
| | | `[15:8]` | varies | RW | Credit ack ID |
| | | `[23:16]` | varies | RW | Ack data ID |
| | | `[31:24]` | varies | RW | Nack data ID |
| `0x04` | Data ID Control | `[7:0]` | varies | RW | Data ID |
| `0x08` | TX FC FIFO | `[0]` | 1 | RO | FIFO empty |
| `0x10` | Ack/Nack FIFO | `[0]` | 1 | RO | Empty |
| | | `[1]` | 0 | RO | Full |
| | | `[2]` | 0 | RO | Half full |
| | | `[3]` | 0 | RO | Almost empty |
| | | `[4]` | 0 | RO | Almost full |
| | | `[10:8]` | 6 | RW | Almost-full level |
| | | `[18:16]` | 2 | RW | Almost-empty level |
| `0x14` | SM Control | `[7:0]` | 8 | RW | Idle cycles after credit negotiation |
| | | `[15:8]` | 7 | RW | Cycles between ACK packets |
| | | **`[16]`** | **0** | **RW** | **Disable CRC check** |
| `0x20` | CRC Errors | `[15:0]` | 0 | RO | CRC errors seen |

:::{tip}
**`SM Control[16]` is the key knob for GPIO-speed deployments.** Disabling the
CRC check saves 2 bytes per long packet — roughly 9–20 % of bandwidth depending
on payload size. At GPIO speeds the bit error rate is low enough that the CRC
overhead is usually not worth paying.
:::

### FC node data-ID defaults

| FC node | Base | Credit ID | Credit ack | Ack | Nack | Data |
|---|---|---|---|---|---|---|
| AXI AW | `0x1000` | `0x08` | `0x09` | `0x0A` | `0x0B` | `0x80` |
| AXI W | `0x1100` | `0x0C` | `0x0D` | `0x0E` | `0x0F` | `0x81` |
| AXI B | `0x1200` | `0x10` | `0x11` | `0x12` | `0x13` | `0x82` |
| AXI AR | `0x1300` | `0x14` | `0x15` | `0x16` | `0x17` | `0x83` |
| AXI R | `0x1400` | `0x18` | `0x19` | `0x1A` | `0x1B` | `0x84` |
| GeneralBus | `0x1600` | — | — | — | — | — |
| TideLink | `0x1700` | — | — | — | — | `0xA1` |

The five AXI channels have **distinct** data IDs — they are not a shared
`0x80`. Short-packet IDs used by the link layer: `0x44` CR, `0x45` CRACK,
`0x46` ACK, `0x47` NACK; PTP uses `0x50` SYNC and `0x51` DELAY_REQ.

:::{note}
**Error-injection byte semantics** (`0x023C`): byte 0 is the `data_id` and is
CRC-gated, so injecting there produces a **silent drop**; byte 4 is `pktnum`
and is detectable; byte 5 is payload and is CRC-only.
:::

---

## Address translator (`0x4000`–`0x5FFF`)

Module `tidelink_addr_translator` → per-channel `tl_addr_trans_regs`. This is
**CAM-based rule matching**, not a segment table: subtract `BASE_OFFSET`, then
compare `addr[31:24]` against each enabled rule's match byte; the
lowest-index match replaces `addr[31:24]` with its replace byte. `addr[23:0]`
always passes through. With `enable = 0` everything passes unchanged.

Channel select is `paddr[15:12]`. Only channel 0 is instantiated
(`NUM_CHANNELS = 1`); channel 1 returns `pslverr`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x000` | `BASE_OFFSET` | RW | 0 | Subtracted from the input address before matching. |
| `0x004` | `CTRL` | RW | 0 | `[0]` global_enable. 0 = identity passthrough. |
| `0x010`–`0x02C` | `RULE[0..7]` | RW | 0 | Per rule: `[0]` enable, `[15:8]` match byte, `[23:16]` replace byte. Rule 0 has highest priority. |
| `0xFD0`–`0xFDC` | `PIDR4-7` | RO | `0x00` | Arm PrimeCell peripheral ID, upper. |
| `0xFE0`–`0xFEC` | `PIDR0-3` | RO | varies | `PIDR0=0x59`, `PIDR1=0x16`, `PIDR2=0x15`, `PIDR3=0x00`. |
| `0xFF0`–`0xFFC` | `CIDR0-3` | RO | varies | `0x50`, `0x51`, `0x4C`, `0x54`. |

Unmapped reads in the `0x030`–`0xFCC` gap return `0xCAFECAFE`
(`tl_addr_trans_regs.sv:190`) — a useful liveness marker for the block.

## PHC registers (external IP)

The PTP hardware clock lives in the sibling `ptp-hardware-clock-ahb` IP and has
its **own** APB port, outside `tidelink_top`.

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x000` | `CTRL` | RW | `[0]` en, `[1]` set_time (self-clearing), `[2]` capture (self-clearing). |
| `0x004` | `STATUS` | RO | `[0]` running, `[1]` pps_sticky (**read-to-clear**), `[2]` alarm_hit. |
| `0x008` | `NS_INCR` | RW | Integer ns increment per cycle (e.g. 4 at 250 MHz). |
| `0x00C` | `NS_INCR_FRAC` | RW | 32-bit sub-ns fractional increment for the servo. |
| `0x010`–`0x018` | `SET_SECONDS_LO/HI`, `SET_NANOSECONDS` | RW | Values loaded on `set_time`. |
| `0x01C` | `INT_EN` | RW | `[0]` pps_irq_en, `[1]` alarm_irq_en. |
| `0x020`–`0x02C` | `CAP_*` | RO | Software-capture snapshot. |
| `0x030`–`0x03C` | `ALARM_*` | RW | Alarm match values and `ALARM_CTRL`. |
| `0x040`–`0x04C` | `HW_CAP_*` | RO | **Hardware** capture — the timestamps TideLink PTP latches at FC TX/RX handshake moments. |

---

## Registers that must never be probed

This list is field-proven. Every entry cost someone a board, a power cycle or a
corrupted link.

### CPU hard-stall on access

| Address (APB offset / Z2 absolute) | Effect |
|---|---|
| `0x21AC` / `0x4403_21AC` | **Uninterruptible AXI hang.** Power cycle to recover. |
| `0x21B0` / `0x4403_21B0` | Same. |
| `0x21B4` / `0x4403_21B4` | Same. |
| Any undecoded `0x4403_xxxx` on **ZynqMP** | Hangs the PS. |

Sources: `docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:101`,
`docs/PTP_DEMO_RUNBOOK.md:371`, `docs/HANDOVER_Z2_PICKUP_2026_07_30.md:343`.
The instrument preamble refuses these offsets by name
(`PRE_WEDGE_OFFSETS`, `instrument_preamble.sh:87,193-202`). **Treat the whole
`0x21A0`–`0x21B8` band as quarantined.**

### Destructive side effects on read

| Address | Effect |
|---|---|
| `0x2020` `RELEASED_CREDITS_ACC` | **Read-clears.** Destroys the credit bookkeeping the link depends on. Only the drain path may read it. |
| `0x2024` `DOORBELL_RESPONSE_ACC` | **Read-clears.** Same. |
| `0x2038` `PTP_RX_PAYLOAD` | Read clears `PTP_CTRL.rx_valid`. |
| `0x215C`, `0x2160` (V1) | Read-clearing eye CRC error counters. |
| `0x2168`, `0x216C` (V1) | Auto-incrementing score index. |
| RX FIFO aperture (`ahb_fifo_*`) | **Pop-on-read.** Only the drain role may touch it. |

### Write hazards

| Target | Rule |
|---|---|
| `ahb_tx_*` aperture | **Wedges the board** if the link is not fully up. Bench-confirmed on z2_02; physical power cycle required. Gate every write behind `tt_gate_ahb_tx()` (requires 16/16 lanes + `cal_done`) and wrap it in `timeout`. |
| `ROLE_CFG.role_lock` (`0x2080[1]`) | W1S, cleared only by POR. The hardware test suite never writes it — the deploy script already has. |
| `CTRL.LOCK` (`0x201C[2]`) | Write-once. The suite reads but never sets it. |
| `SWI_PHASE_OFFSET` (`0x2118`) | Latched at role_lock. Read only. |
| Wlink `0x0208` triplet | Never hand-drive it; it wedges the PS and is unnecessary on builds with `HARDEN_SWI_ENABLE = 1`. |
| `0x2160` on a live V2 link | The per-lane lock threshold. Set `0x5555_5555` for bring-up and leave it; do not use as scratch. |
| Lane mask (`0x0214`) | If you must inject a lane fault, restore the original on exit — the hwtest suite uses `trap restore_mask EXIT`. |

:::{important}
**Monitoring loops must be whitelist-driven.** Read a frozen tuple of known-safe
offsets. Never sweep a range: undecoded APB addresses can hang the PS, and the
read-clearing registers above sit interleaved with harmless ones.
:::

## Board apertures

The APB base differs per platform. All offsets in this page are relative to the
TideLink APB base.

| Platform | APB base | TideLink region | Notes |
|---|---|---|---|
| PYNQ-Z2 (GP1-split BDs, 2026-06-12+) | `0x4403_0000` | `0x4403_2000` | On `M_AXI_GP0`. Peer transparent window `0x4000_0000`, also GP0 — **must stay on GP0**. Data apertures moved to GP1: AHB_TX `0x8400_0000`, RX FIFO `0x8401_0000`. |
| KR260 (ZynqMP) | `0x8403_0000` | `0x8403_2000` | On-chip pair: die_a `0x8403_0000`, die_b `0x8C03_0000` (uniform `+0x0800_0000`). |

For Z2 host scripts against a GP1-split image:

```bash
export TIDELINK_TX_BASE=0x84000000
export TIDELINK_RXFIFO_BASE=0x84010000
```

A read or write to `0x4400_xxxx` on a GP1-split image hits an unmapped GP0 hole
(DECERR/SIGBUS), and vice versa. GP0 and GP1 are independent PS7 ordering
domains, which is exactly why a wedged AHB_TX write on GP1 cannot stall APB
polls on GP0.

:::{warning}
**The KR260 data aperture is ambiguous in the repo and unresolved.** The target
tcl header lists AHB_TX `0x8400_0000` / AHB_FIFO `0x8401_0000`, while the
validated data-crossing note gives `0xA400_0000` / `0xA401_0000` and warns that
writing the wrong base **wedges the PS**
(`docs/KR260_FIRST_SESSION_RUNBOOK.md`). Disambiguate cheaply before writing:
the RX FIFO window is also a local SRAM, so write-then-read one word locally on
the slave and use whichever base round-trips. **Do not assume.**
:::

## See also

- {doc}`parameters` — the reset values behind `TIDELINK_PAIR_BASE`,
  `NEGO_CFG_RESET`, `HARDEN_SWI_ENABLE` and the rest.
- {doc}`bringup` — the register sequences that actually bring a link up.
- {doc}`known_issues` — dead fields, misleading instruments, and the
  wedge-detection recipe.

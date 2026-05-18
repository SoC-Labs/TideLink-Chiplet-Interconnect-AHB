# TideLink APB Register-Map Redesign Proposal

**Status:** Design-only. No RTL/RDL changes applied. Diffs and migration plan
in this directory.
**Author:** Claude Code under dam1n19's design brief, 2026-05-14.
**Scope:** Absorb the §9 PHY-alignment register set (currently interim-shim'd
at MMIO `0x4403_1000+`) and the I²C-coordinated training-mode register set
(`staging/i2c_train/I2C_TRAIN_PROTOCOL.md` §3) into the long-term
chiplet-controller APB region, without disturbing existing
addresses/semantics for ROLE/I²C/NEGO/PTP/perf-profiling registers.

---

## 1. Constraints summary

| Constraint | Source | Impact |
|---|---|---|
| Region 4 (0x080..0x09C, 8 slots × 4B) is **full**: ROLE_CFG, ROLE_STATUS, I2C_SLV_ADDR, I2C_PRESCALE, NEGO_CFG, NEGO_STATUS, NEGO_PRIORITY, NEGO_TIMEOUT | `axi_chiplet_controller.sv:413-423` | Cannot append §9 or I²C-train regs here. |
| Regions 5-7 (0x0A0..0x0FC, 24 slots) are **fully populated** by `tidelink_perf_regs.rdl` (PERF_CTRL, TX_*, RX_*, counters, DBG_*, PERF_ID) | `src/rdl/tidelink_perf_regs.rdl` | Cannot reclaim any slot without breaking the perf profile, which has external SW consumers (`src/sw/tidelink_perf.c`, `cocotb/wlink_pair/test_perf*`). |
| `tidelink_apb_regs` decodes only `paddr[7:5]` → 3-bit region select; uses `paddr[4:2]` for the slot within a region. | `tidelink_apb_regs.sv:132` | A 4th region-select bit (`paddr[8]`) is currently ignored. Promoting it adds a new "upper bank" at offsets 0x100..0x1FF with no conflict. |
| The TideLink top-level APB block (`tidelink_apb_regs` at MMIO `0x4403_2000`) has a 12-bit local paddr → 4KB of addressable space; the existing register file occupies the bottom 256 bytes only. | `tidelink_top.sv:577-579` | Plenty of headroom in the upper half. |
| I²C agent's spec at `I2C_TRAIN_PROTOCOL.md §3.1` proposed offsets `0x090, 0x094, 0x098, 0x09C, 0x0A0, 0x0A4, 0x0A8` — **all conflict** with existing NEGO_* (0x090..0x09C) and PERF_* (0x0A0..0x0A8). | I²C agent | Must re-offset the I²C-train spec; published RTL sketch (`tidelink_autoneg_train_states.sv:140-146`) needs corresponding update. |
| The §9 spec lists 5 registers: `SWI_BIT_SLIP[23:0]`, `SWI_TRAINING_MODE`, `SWI_LANE_LOCKED[7:0]`, `SWI_LANE_FAULT[7:0]`, `SWI_CALIBRATION_DONE`. The interim shim packs only the first two. | `docs/PHY_ALIGN_NEXT_STEPS.md §2.1`, `BRINGUP_REPORT.md §9` | Need 4-5 RW/RO slots. The I²C-train spec adds `NEGO_TRAIN_CFG`, `NEGO_TRAIN_STATUS`, `NEGO_TRAIN_STEP`, and reuses `SWI_TRAINING_MODE/LANE_LOCKED/LANE_FAULT/BIT_SLIP_LO`. After dedup: 4 §9 + 3 I²C-train-specific = **7 new slots**. |

---

## 2. Recommended approach — Approach 2 with a single new region

**Promote `paddr[8]` to a 4th region-select bit and define a new Region 8
("Chiplet Extended", offsets `0x100..0x11F`, 8 slots × 4B).** All seven new
registers fit in this single region. The existing 3-bit region-select world
(0x000..0x0FF) is **unchanged**.

### Why this approach

| Criterion | Approach 1 (widen ctrl_reg_addr) | **Approach 2 (paddr[8] carve)** | Approach 3 (perf to new slave) | Approach 4 (nibble carve-outs) |
|---|---|---|:-:|---|
| Existing offsets unchanged | NO (perf clashes at 0x0A0) | **YES** | YES, but BD changes | YES |
| Perf profiling untouched | NO | **YES** | NO (whole block moves) | YES |
| Single contiguous block for the new regs | YES | **YES** | n/a | NO (scattered) |
| Touches BD / fabric | No | **No** | YES (new AXI slave) | No |
| RTL change surface | `tidelink_apb_regs.sv` + `chiplet_controller.sv` | **`tidelink_apb_regs.sv` (1 case branch widened) + `chiplet_controller.sv` (1 new sub-block)** | New module + BD + flist + XDC | `tidelink_apb_regs.sv` (many places) |
| Future-extensibility (room for more §9/I²C regs) | Limited (16 slots − existing 8 = 8 new) | **Huge (paddr[9..11] still free → 56 more slots without further redesign)** | Huge | Poor |
| Documentation churn | `REGISTER_MAP.md` Region 4 redrawn; perf section bumped | **`REGISTER_MAP.md` adds Region 8 only; perf untouched** | Perf MMIO base changes (SW + docs) | Many small edits |
| Risk of regression | Medium (perf SW breaks) | **Low (additive only)** | High (BD verification needed) | Medium (offset scatter is error-prone) |

Approach 2 is **additive-only**, costs one extra address bit in the decode,
and gives a contiguous block for the new registers. Pick it.

---

## 3. New register layout

### 3.1 Region 8 — Chiplet Extended (offsets `0x100..0x11F`)

All eight slots in a new 32-byte region selected by `paddr[8]=1` AND
`paddr[7:5]=000` (i.e. `paddr[8:5] == 4'b1000`). The wider region-select
becomes `paddr[8:5]`:

| paddr[8:5] | Region | Offsets |
|---|---|---|
| `0000` | Region 0: Config & Status | 0x000-0x01F |
| `0001` | Region 1: Credit RX + PTP Basic | 0x020-0x03F |
| `0010` | Region 2: PTP HW Sync + Servo Config | 0x040-0x05F |
| `0011` | Region 3: Servo Status + Mailbox | 0x060-0x07F |
| `0100` | Region 4: Chiplet Controller (ROLE/I²C/NEGO) | 0x080-0x09F |
| `0101` | Region 5: Perf — Control & TX Timestamps | 0x0A0-0x0BF |
| `0110` | Region 6: Perf — RX Timestamps & Counters | 0x0C0-0x0DF |
| `0111` | Region 7: Perf — Link Counters & Debug | 0x0E0-0x0FF |
| `1000` | **Region 8: Chiplet Extended (NEW)** | **0x100-0x11F** |
| `1001..1111` | Reserved (RAZ/WI) | 0x120-0x1FF |

### 3.2 Region 8 register layout

| paddr[4:2] | Offset | Name | Width | R/W | Reset | Owner | Purpose |
|:-:|:-:|---|:-:|:-:|---|---|---|
| `0` | `0x100` | `SWI_TRAINING_MODE` | 32 | RW | `0x0000_0000` | chiplet_controller | bit[0] = `swi_training_mode` (drives the Wlink GPIO PHY's training pattern + checker enable). Writable from both local APB and I²C-slave AXIL bridge. |
| `1` | `0x104` | `SWI_BIT_SLIP_LO` | 32 | RW | `0x0000_0000` | chiplet_controller | bits[23:0] = `swi_bit_slip[7:0]` packed 8 × 3-bit (lane K at bits `[3K+2:3K]`). bits[31:24] reserved. SW override of the autonomous cal FSM's per-lane slip. |
| `2` | `0x108` | `SWI_LANE_STATUS` | 32 | RO | `0x0000_0000` | chiplet_controller | bits[7:0] = `swi_lane_locked` (per-lane lock status from the Wlink lane checker). bits[15:8] = `swi_lane_fault` (sticky after cal abandons). bit[16] = `swi_calibration_done`. bits[31:17] reserved. **Replaces** the two-register split (`SWI_LANE_LOCKED` + `SWI_LANE_FAULT`) in the I²C-spec — packs all three RO PHY signals into a single 32-bit slot, saving one slot. |
| `3` | `0x10C` | `NEGO_TRAIN_CFG` | 32 | RW | `0x0000_0000` | autoneg FSM | bit[0] = `train_auto_en`. bit[1] = `train_sw_step`. bit[2] = `train_retrain` (W1P, self-clearing). bits[7:4] = `train_poll_timeout` (4-bit, 0 → use default 16 polls). bits[15:8] = `train_fsm_wait_hi` (high 8 bits of `T_TRAIN_FSM` ÷ 16; full wait = `{train_fsm_wait_hi, 4'h0}`). bits[31:16] reserved. |
| `4` | `0x110` | `NEGO_TRAIN_STATUS` | 32 | RO | `0x0000_0000` | autoneg FSM | bit[0] = `train_ok`. bit[1] = `train_fail`. bit[2] = `train_in_progress`. bit[3] = `train_peer_nack`. bits[7:4] = `train_state[3:0]` (re-encoded 0..6, see I²C protocol §3.4). bits[15:8] = `train_peer_lane_locked` (last value read from peer). bits[23:16] = `train_peer_lane_fault`. bits[31:24] = `train_local_lane_fault` (snapshot on `ST_TRAIN_FAIL` entry). |
| `5` | `0x114` | `NEGO_TRAIN_STEP` | 32 | RW | `0x0000_0000` | autoneg FSM | bit[0] = step pulse, W1P, self-clearing. Only effective when `NEGO_TRAIN_CFG.train_sw_step = 1`. |
| `6` | `0x118` | `SWI_BIT_SLIP_HI` | 32 | RW | `0x0000_0000` | reserved for >8-lane future builds | bits[23:0] = `swi_bit_slip[15:8]` for a 16-lane PHY variant. Reads-as-zero in 8-lane builds. Held as RW-zero so SW probing for capability sees the slot exists. |
| `7` | `0x11C` | `PHY_ALIGN_ID` | 32 | RO | `0x5041_0100` | chiplet_controller | "PA" (0x5041) ASCII + version 1.00. Per the existing `PERF_ID` convention at 0x0FC. SW uses this to confirm Region 8 exists (writes to it RAZ/WI; reads should match). |

### 3.3 Field-level details

#### 3.3.1 `SWI_TRAINING_MODE` (0x100)

```
 31                                                    1   0
+------------------------------------------------------+---+
|                       reserved                       | M |
+------------------------------------------------------+---+
```
- `M = swi_training_mode`. Active-high; when 1, the Wlink GPIO PHY TX serialiser
  emits the per-lane training pattern and the RX-side `wlink_lane_checker`
  begins evaluating.
- Dual-write source: local APB and I²C-slave AXIL bridge. Priority resolution:
  local APB wins on simultaneous (one-cycle race). Reads are dual-ported (both
  paths can read).
- Reset on `poresetn` only (POR-only domain — survives warm `hresetn` so
  training state persists across system reset).

#### 3.3.2 `SWI_BIT_SLIP_LO` (0x104)

```
 31      24 23  21 20  18 17  15 14  12 11   9  8   6  5   3  2   0
+----------+------+------+------+------+------+------+------+------+
| reserved | lane | lane | lane | lane | lane | lane | lane | lane |
|          |  7   |  6   |  5   |  4   |  3   |  2   |  1   |  0   |
+----------+------+------+------+------+------+------+------+------+
```
- 3-bit per-lane slip values. Lane K occupies bits `[3K+2:3K]`. Matches the
  existing `tidelink_phy_align_regs.swi_bit_slip_o[23:0]` packing.
- When the autonomous cal FSM (Layer 1, separately delivered) drives slip
  per-lane internally, this register acts as a **SW debug override**: the cal
  FSM logic must read this back via a mux selected by either
  `NEGO_TRAIN_CFG[31]` or a hard-mux on whether the cal FSM has converged
  (`swi_calibration_done`). Recommended: when `swi_calibration_done==0` and
  `NEGO_TRAIN_CFG.train_auto_en==1`, the cal FSM owns slip; otherwise SW
  override applies.

#### 3.3.3 `SWI_LANE_STATUS` (0x108) — **packs three RO fields into one slot**

```
 31              17 16            8  7              0
+------------------+--+--------------+----------------+
|     reserved     |CD| lane_fault   |  lane_locked   |
+------------------+--+--------------+----------------+
```
- `CD = swi_calibration_done` (bit 16). Set by the cal FSM at convergence,
  cleared by `swreset` or `NEGO_TRAIN_CFG.train_retrain`.
- `lane_fault[7:0]` (bits 15:8). Sticky.
- `lane_locked[7:0]` (bits 7:0). Live.

**Departure from the I²C-spec:** the I²C-spec separated lane_locked (0x0A0)
and lane_fault (0x0A4) into two registers. Packing them saves one slot and
the I²C-train protocol's 4-byte reads still work — the master reads 4 bytes
starting at `0x108`: byte 0 = lane_locked, byte 1 = lane_fault, byte 2 = CD,
byte 3 = reserved. This is **strictly better** than the I²C-spec because it
halves the number of I²C reads needed during `ST_TRAIN_POLL_PEER` (one read
suffices to assess both lock and fault) and the `ST_TRAIN_FAIL` path can
report fault from the same response without a second read.

I²C-train RTL sketch (`tidelink_autoneg_train_states.sv`) needs corresponding
updates — see §6 below.

#### 3.3.4 `NEGO_TRAIN_CFG` (0x10C) and `NEGO_TRAIN_STATUS` (0x110)

Field encodings preserved from I²C-train spec §3.1 and §3.4. Address change
only.

#### 3.3.5 `NEGO_TRAIN_STEP` (0x114)

W1P self-clearing. Pulses the autoneg FSM's `train_step_pulse` input when
`NEGO_TRAIN_CFG.train_sw_step` is 1. No semantic change from I²C spec.

---

## 4. Where the §9 registers live

| §9 register | New offset | Notes |
|---|---|---|
| `SWI_BIT_SLIP[23:0]` | `0x104` (`SWI_BIT_SLIP_LO[23:0]`) | Was at MMIO `0x4403_1000` in interim shim |
| `SWI_TRAINING_MODE` | `0x100` bit[0] | Was at MMIO `0x4403_1004` in interim shim |
| `SWI_LANE_LOCKED[7:0]` | `0x108[7:0]` | New (not present in interim shim) |
| `SWI_LANE_FAULT[7:0]` | `0x108[15:8]` | New (not present in interim shim) |
| `SWI_CALIBRATION_DONE` | `0x108[16]` | New (not present in interim shim) |

MMIO addresses with the master at `0x4403_2000` (TideLink config APB base):

- `SWI_TRAINING_MODE` MMIO: `0x4403_2100`
- `SWI_BIT_SLIP_LO`   MMIO: `0x4403_2104`
- `SWI_LANE_STATUS`   MMIO: `0x4403_2108`

(Note: the TideLink config block lives at `0x4403_2000`, not `0x4403_0000`.
The `0x4403_0000+` MMIO space is the Wlink chiplet-controller APB; the
TideLink-internal config APB is decoded by `paddr[14:13]==01` and lives at
the +0x2000 offset. See `tidelink_top.sv:572-579`.)

---

## 5. Where the I²C-train registers live

| I²C spec name | I²C spec offset (conflicting) | **New offset** | Notes |
|---|:-:|:-:|---|
| `NEGO_TRAIN_CFG` | 0x090 ❌ collides with NEGO_CFG | **0x10C** | Region 8 slot 3 |
| `NEGO_TRAIN_STATUS` | 0x094 ❌ collides with NEGO_STATUS | **0x110** | Region 8 slot 4 |
| `SWI_TRAINING_MODE` | 0x098 ❌ collides with NEGO_PRIORITY | **0x100** | Region 8 slot 0 |
| `NEGO_TRAIN_STEP` | 0x09C ❌ collides with NEGO_TIMEOUT | **0x114** | Region 8 slot 5 |
| `SWI_LANE_LOCKED` | 0x0A0 ❌ collides with PERF_CTRL | **0x108[7:0]** | merged into SWI_LANE_STATUS |
| `SWI_LANE_FAULT` | 0x0A4 ❌ collides with TX_ORIGIN_NS | **0x108[15:8]** | merged into SWI_LANE_STATUS |
| `SWI_BIT_SLIP_LO` | 0x0A8 ❌ collides with TX_ORIGIN_SEC | **0x104** | Region 8 slot 1 |

All seven I²C-train regs land in Region 8 with no conflicts. The
`SWI_LANE_*` merge into `SWI_LANE_STATUS` is documented in §3.3.3 — net
one fewer slot used, and the master FSM's I²C-poll pattern simplifies.

---

## 6. Impact on `tidelink_autoneg_train_states.sv` reference sketch

`staging/i2c_train/tidelink_autoneg_train_states.sv` (Section C, lines
140-146) hardcodes the I²C-spec offsets:

```
localparam [7:0] TRAIN_MODE_ADDR_LSB     = 8'h98;  // → 0x00
localparam [7:0] TRAIN_LANE_LOCKED_ADDR_LSB = 8'hA0;  // → 0x08
localparam [7:0] TRAIN_LANE_FAULT_ADDR_LSB  = 8'hA4;  // → 0x08 (merged into SWI_LANE_STATUS)
```

New values for the integrator:

```
localparam [7:0] TRAIN_MODE_ADDR_MSB     = 8'h01;  // upper byte of 0x100
localparam [7:0] TRAIN_MODE_ADDR_LSB     = 8'h00;  // SWI_TRAINING_MODE
localparam [7:0] TRAIN_LANE_STATUS_ADDR_MSB = 8'h01;
localparam [7:0] TRAIN_LANE_STATUS_ADDR_LSB = 8'h08;  // SWI_LANE_STATUS (replaces split LOCKED+FAULT)
```

The `ST_TRAIN_POLL_PEER` 4-byte read now captures
`{train_peer_calibration_done, train_peer_lane_fault, train_peer_lane_locked}`
in one shot — see §3.3.3. `ST_TRAIN_FAIL` no longer needs a separate
`SWI_LANE_FAULT` read; the snapshot is already captured.

`all_locked_w` comparator (Section E, line 211) becomes:
```
wire all_locked_w = (peer_lane_locked_r == 8'hFF) &&
                    (local_swi_lane_locked_i == 8'hFF) &&
                    peer_calibration_done_r &&
                    local_calibration_done_i;
```

---

## 7. Migration steps from the interim shim at `0x4403_1000+`

**Pre-condition:** the interim shim at MMIO `0x4403_1000` (in
`axi_chiplet_controller.sv:895-939` + `src/rtl/tidelink_phy_align_regs.sv`)
has been validated on FPGA pair-board. The bringup test reports
`swi_lane_locked == 0xFF` on both peers.

### Step 1 — Add Region 8 alongside the interim shim (parallel)
- Apply the diffs in `apb_regs.sv.diff` and `chiplet_controller.sv.diff` to
  add Region 8 decode and new register slots.
- Wire the new register-block outputs to the **same** signals that the
  interim shim currently drives (`swi_bit_slip_w`, `swi_training_mode_w`).
- OR-merge the new and the interim register outputs (the same trick
  `WavD2DGpio.v` uses internally for soft-strap vs APB).

This step is purely **additive**; nothing existing breaks. The interim shim
still works in parallel.

### Step 2 — Migrate SW to new addresses
- Update `pynq_host/scripts/deploy_pair.sh` and `wlink_probe.sh` to read/write
  the new MMIO offsets (`0x4403_2100` etc.) **in addition to** the legacy
  shim addresses. Cross-check both report the same value.
- Update UVM tests in `uvm/tidelink_top_system/tests/` that drive `swi_*`
  via hierarchical reference. Recommend keeping hierarchical-ref drives
  alongside the new APB drives for one regression cycle, then removing
  hierarchical refs.
- Update cocotb tests in `cocotb/phy_align/test_apb_drive.py` to target the
  new offsets.

### Step 3 — Delete the interim shim
**Only after Step 2 confirms parity.**
- Delete `src/rtl/tidelink_phy_align_regs.sv`.
- Delete the instantiation block at `axi_chiplet_controller.sv:895-939`.
- Delete the `paddr[12]` mux at `axi_chiplet_controller.sv:928-934`.
- Remove `pa_apb_*` wires and the `wl_apb_psel_gt` gating.
- Restore the Wlink APB to its full 8KB region (no longer split by `paddr[12]`).
- Remove the entry from `flist/tidelink_top_full_asic.flist`.

### Step 4 — Add the autonomous cal FSM and I²C-train autoneg extension
This is the work of `staging/i2c_train/I2C_TRAIN_PROTOCOL.md`. With Region 8
now in place, that integration drops in cleanly at the offsets given here.

### Step 5 — Documentation
- Update `docs/REGISTER_MAP.md` with Region 8 added; perf section unchanged.
- Update `docs/PHY_ALIGN_NEXT_STEPS.md` §2.1 to point at the new offsets.
- Add a short note to `BRINGUP_REPORT.md` §9 referencing the final
  register-map location.

---

## 8. Backward-compatibility statement

### 8.1 Unchanged

- All Region 0..7 register addresses and field semantics
  (`ctrl @ 0x01C`, `release_threshold @ 0x004`, `released_credits_acc @ 0x020`,
  PTP @ 0x034-0x048, servo @ 0x04C-0x064, mailbox @ 0x068-0x07C,
  ROLE_CFG @ 0x080, ..., NEGO_TIMEOUT @ 0x09C, PERF_CTRL @ 0x0A0,
  ..., PERF_ID @ 0x0FC).
- Existing PYNQ host scripts that drive ROLE_CFG, I2C_*, NEGO_* registers.
- All UVM tests targeting Region 0..7 addresses.
- All cocotb tests targeting Region 0..7 addresses.
- `tidelink_perf.c` (SW driver) and `tidelink_perf.h`.

### 8.2 Changed

- The MMIO address of `SWI_BIT_SLIP` and `SWI_TRAINING_MODE` moves from the
  interim shim's `0x4403_1000` / `0x4403_1004` to the TideLink config block
  `0x4403_2104` / `0x4403_2100`. **This is a one-time breaking change for
  scripts and tests that target the interim shim addresses.** No production
  SW or external consumer depends on the interim addresses (they were
  internal-only, added on `feat/fpga-flow` for FPGA bring-up).
- `tidelink_apb_regs` region-select widens from `paddr[7:5]` (3-bit) to
  `paddr[8:5]` (4-bit). Region 0..7 keep their decode unchanged
  (`paddr[8]=0`); Region 8 is `paddr[8]=1, paddr[7:5]=000`. The 16-region
  space (`paddr[8:5]`) keeps Region 9..15 reserved for future use.

### 8.3 New

- Seven new register addresses in Region 8 (`0x100`, `0x104`, `0x108`,
  `0x10C`, `0x110`, `0x114`, `0x11C`). Slot 6 (`0x118`,
  `SWI_BIT_SLIP_HI`) is reserved-future.
- One new RDL register definition file (`tidelink_chiplet_ext_regs.rdl`,
  or as an addition to `tidelink_regs.rdl`).

---

## 9. Impact on PYNQ host scripts

### `pynq_host/scripts/deploy_pair.sh`

Currently writes the Wlink-bus base at `0x4403_0000`. The interim shim
exposes `SWI_BIT_SLIP` at `0x4403_1000` and `SWI_TRAINING_MODE` at
`0x4403_1004`. After migration:

- `SWI_BIT_SLIP_LO` moves to `0x4403_2104`.
- `SWI_TRAINING_MODE` moves to `0x4403_2100`.
- `SWI_LANE_STATUS` (new) read at `0x4403_2108`.
- `NEGO_TRAIN_CFG` at `0x4403_210C`.
- `NEGO_TRAIN_STATUS` at `0x4403_2110`.
- `NEGO_TRAIN_STEP` at `0x4403_2114`.

Recommend a transition window where deploy_pair.sh accepts both the legacy
shim addresses and the new ones — guarded by a `--legacy-phy-align` flag —
to make the cut-over independent of bitstream re-flashing.

### `pynq_host/scripts/wlink_probe.sh`

Already probes `0x4403_0000+` (Wlink) and prints aliases. Add probes for
`0x4403_2100..0x4403_211C` (Region 8). Format: hex dump 8 × 32-bit words
labelled by register name.

### Other impact
- `pynq_host/python/tidelink_pair.py` (if present) — update class
  constants for SWI/NEGO_TRAIN offsets.
- `uvm/tidelink_ptp_chain/tb/top.sv`, `uvm/tidelink_top_system/tb/top.sv` —
  scoreboard-side address constants in SystemVerilog defines.

---

## 10. Impact on `docs/REGISTER_MAP.md`

Add a new section between current §1.5 (Region 4) and §2 (Wlink chiplet
controller). Skeleton:

```
### Region 8: Chiplet Extended — PHY Alignment & I²C Training (paddr[8:5] = 1000)

These registers absorb the §9 PHY-alignment soft-strap controls (formerly
interim-shim'd at MMIO 0x4403_1000) and the I²C-coordinated training
protocol registers (per docs/I2C_TRAIN_PROTOCOL.md). They reside in a
newly-decoded "upper bank" of the TideLink-internal APB.

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2100 | SWI_TRAINING_MODE | RW | 0 | bit[0] = training-mode enable |
| 0x2104 | SWI_BIT_SLIP_LO   | RW | 0 | bits[23:0] = per-lane bit-slip (8 × 3) |
| 0x2108 | SWI_LANE_STATUS   | RO | 0 | [7:0] locked, [15:8] fault, [16] cal_done |
| 0x210C | NEGO_TRAIN_CFG    | RW | 0 | bits[0..2] auto/sw_step/retrain; [7:4] poll_to; [15:8] wait_hi |
| 0x2110 | NEGO_TRAIN_STATUS | RO | 0 | bits[3:0] flags; [7:4] state; [15:8] peer_locked; [23:16] peer_fault; [31:24] local_fault |
| 0x2114 | NEGO_TRAIN_STEP   | RW | 0 | bit[0] = W1P step pulse |
| 0x2118 | SWI_BIT_SLIP_HI   | RW | 0 | reserved for >8-lane builds |
| 0x211C | PHY_ALIGN_ID      | RO | 0x50410100 | "PA" + version 1.0 |
```

Update §1.5 to note that the interim PHY-align shim is removed in this
release.

---

## 11. Honest trade-offs and risks

### 11.1 What this proposal touches

- **`tidelink_apb_regs.sv` decode widens.** One extra address bit; one new
  `case` branch for Region 8 write/read; the existing region read mux is
  extended with one more arm. **Risk: low** — the change is local and
  syntactically minor.
- **`axi_chiplet_controller.sv` gains a second register sub-block.** The
  new sub-block handles writes/reads for `ctrl_reg_addr[3]==1`. The
  existing region (slots 0..7) is unchanged. **Risk: low** — the existing
  `case (ctrl_reg_addr)` mux at lines 412-423 just gets a default branch
  that routes to the new sub-block. Alternatively, widen `ctrl_reg_addr`
  to 4 bits and add slots 8..15 to the same case — same effect, slightly
  cleaner. **Recommended: widen `ctrl_reg_addr` from 3 to 4 bits.**
- **The `wlink_phy_align_regs` interim shim gets deleted.** ~95 LOC
  removed. **Risk: low** — covered by Step 2 cross-check.

### 11.2 What this proposal does **not** touch

- **`tidelink_perf.sv` and `tidelink_perf_regs.rdl`.** Region 5-7
  completely unchanged.
- **The PTP / servo / mailbox plumbing in Region 1-3.** Unchanged.
- **The Wlink internal register block** (in
  `deps/axi-chiplet-controller/wav-wlink-hw`). Unchanged.
- **FPGA BD.** No new ports added at the chiplet-controller top.

### 11.3 Risks called out

1. **Cocotb tests that drive `swi_bit_slip` via hierarchical reference**
   (`cocotb/phy_align/test_pair_align*.py`) will keep working — the
   hierarchical path lands in the same internal regs that
   `tidelink_phy_align_regs` writes. The transition window in §7 Step 2
   keeps both drive paths alive.
2. **The autoneg FSM extension** (per
   `staging/i2c_train/tidelink_autoneg_train_states.sv`) hardcodes the
   I²C-spec offsets. Integration must update the localparams per §6
   above. **This proposal explicitly resolves the I²C agent's offset
   conflict** but the integrator must mechanically apply the resulting
   address change.
3. **The slave-side I²C-to-APB bridge** in `axi_chiplet_controller.sv`
   (the `wl_apb_*` mux at line 870ff) currently routes I²C writes to
   the Wlink APB range. Region 8 lives in the TideLink-internal APB,
   not the Wlink range. The slave's `SWI_TRAINING_MODE` write from the
   master's I²C arrives at the slave's chiplet-controller AXI slave,
   which writes the slave's Wlink APB at the master-specified address
   — so for the master-side I²C write to reach the slave's Region 8
   register, the slave-side AXIL-to-APB path must reach the TideLink
   config APB (offset `0x4403_2100`), not the Wlink APB (offset
   `0x4403_0xxx`). **This is unchanged from the I²C spec's original
   design** — the I²C-spec assumed peer writes already reach the
   TideLink config region. Verify with the integrator that the
   slave's AXIL-to-APB bridge can address the full 64KB chiplet APB,
   not just the 8KB Wlink window. If it can't, an additional fan-out
   widening at the slave's AXI-Lite slave is needed; cheap (one route
   change), but worth flagging.
4. **POR-only reset for `SWI_TRAINING_MODE`.** This is intentional: the
   register must survive a warm `hresetn` so training state is not lost
   on a SW-driven system reset cycle. The existing POR-only domain in
   `axi_chiplet_controller.sv:344-409` (`role_cfg_reg` etc.) is the
   correct place to put it.

---

## 12. Summary

**Recommended approach:** Approach 2 (paddr[8]-carve), adding a new
contiguous Region 8 at offsets `0x100..0x11F`. Eight 4-byte slots; seven
used, one ID register, future-extensibility via paddr[9:5] (24 more
regions × 32 bytes = 768 bytes of headroom without further redesign).

**Concrete offset table for §9 + I²C-train:**

| Register | Offset | MMIO (master) |
|---|---|---|
| SWI_TRAINING_MODE  | 0x100 | 0x4403_2100 |
| SWI_BIT_SLIP_LO    | 0x104 | 0x4403_2104 |
| SWI_LANE_STATUS    | 0x108 | 0x4403_2108 |
| NEGO_TRAIN_CFG     | 0x10C | 0x4403_210C |
| NEGO_TRAIN_STATUS  | 0x110 | 0x4403_2110 |
| NEGO_TRAIN_STEP    | 0x114 | 0x4403_2114 |
| SWI_BIT_SLIP_HI    | 0x118 | 0x4403_2118 |
| PHY_ALIGN_ID       | 0x11C | 0x4403_211C |

**Files changed at integration:**

| File | Change |
|---|---|
| `src/rdl/tidelink_regs.rdl` | Add Region 8 register declarations (see `tidelink_regs.rdl.diff`) |
| `src/rtl/fifo/tidelink_apb_regs.sv` | Widen region select to `paddr[8:5]`; add Region 8 read mux; widen `ctrl_reg_addr` output to 4 bits (see `apb_regs.sv.diff`) |
| `src/rtl/tidelink_top.sv` | Update `ctrl_reg_addr` width param (1-line tweak) |
| `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` | Add Region 8 register sub-block (SWI_TRAINING_MODE, SWI_BIT_SLIP_LO, SWI_LANE_STATUS, NEGO_TRAIN_*, PHY_ALIGN_ID); delete interim shim (see `chiplet_controller.sv.diff`) |
| `src/rtl/tidelink_phy_align_regs.sv` | **Delete** (interim shim replaced) |
| `pynq_host/scripts/deploy_pair.sh` | Migrate `swi_*` offsets to `0x4403_2100+` |
| `pynq_host/scripts/wlink_probe.sh` | Add Region 8 probes |
| `cocotb/phy_align/test_apb_drive.py` | Retarget APB writes to new offsets |
| `uvm/tidelink_top_system/tests/*` | Retarget APB-driven training tests |
| `docs/REGISTER_MAP.md` | Add Region 8 section |
| `docs/PHY_ALIGN_NEXT_STEPS.md` | §2.1 final-state addresses |
| `staging/i2c_train/tidelink_autoneg_train_states.sv` | Update localparams (one-step before merge) |
| `staging/i2c_train/I2C_TRAIN_PROTOCOL.md` | §3.1 offset table updated |
| `flist/tidelink_top_full_asic.flist` | Remove `tidelink_phy_align_regs.sv` entry (after Step 3) |

**Backward-incompatibility:** the interim shim addresses `0x4403_1000` and
`0x4403_1004` become invalid after Step 3 of migration. No external SW
depends on these. The interim shim was introduced on `feat/fpga-flow` and
has not been merged to `main`.

**Recommendation on the interim shim:** **delete** it during Step 3 of
migration, not keep it as a v1 alias. Reasons:
1. The interim shim is genuinely interim — it was added because the
   chiplet-controller register region was full, with an explicit comment
   ("once the chiplet-controller register map redesign lands, this module
   can be deleted") at `tidelink_phy_align_regs.sv:23-24`.
2. Keeping it as an alias adds maintenance burden (two address paths to
   verify on each future change) and increases the surface area for the
   slave-side I²C-to-APB bridge to handle.
3. The only consumer is `feat/fpga-flow` debugging scripts; the migration
   step explicitly walks the SW retarget before deletion.

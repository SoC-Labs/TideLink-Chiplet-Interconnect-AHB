# I²C Bring-Up → GPIO PHY Refactor — Feasibility & Implementation Plan

**Date:** 2026-06-03
**Branch:** `feat/td-autonomy` (HEAD `a21af5e` at time of writing)
**Status:** Plan — not yet implemented. Hand-off document.
**Owner:** TBD (next agent / engineer to pick this up)

---

## 0. Reader pre-flight — what you need to know to pick this up cold

This document is self-contained. If you are reading this as a hand-off:

- The TideLink chiplet interconnect is a layered design. Bottom-up:
  1. **GPIO PHY** — vendor `WavD2DGpio` inside `WlinkGPIOPHY`, both in `deps/axi-chiplet-controller/logical/wlink/`. Per-lane TX/RX serialisers, pad-clock domain.
  2. **Wlink** — protocol layer above the PHY. Lives partly in `deps/axi-chiplet-controller/`, with overrides in `src/rtl/local_overrides/Wlink.v`.
  3. **TideLink controller** — `src/rtl/local_overrides/axi_chiplet_controller.sv`. Owns autoneg FSM, calibrator wiring, role-lock, register file, FCSM glue.
  4. **TideLink top** — `src/rtl/tidelink_top.sv`. AHB/AXI bridges, FC node, address translation.

- **Today** the I²C sideband (control/status bus that runs over dedicated GPIO pins on the chiplet cable) is implemented inside `axi_chiplet_controller.sv` (controller layer, item 3). It is used by `tidelink_autoneg.sv` (also at controller scope) to do all the cross-die bring-up handshakes.

- **The question** this document answers: should the I²C sideband and the autoneg FSM move *down* into the PHY layer (a new sibling wrapper around the vendor PHY)? If yes, what's the plan?

- **The answer:** **Yes, partially.** A two-tier refactor is sensible: phase 1 moves the I²C *instances*, phase 2 moves the autoneg FSM + register file. A phase 3 full refactor (calibrator + IDELAYE2 also descend) is deferred. There is **one blocking interface decision** (the slave-AXIL→APB bridge fanout) that must be resolved before phase 2.

- Memory entries that may help (private to user dam1n19, paths under `~/.claude/`):
  - `project_tidelink_wlink.md` — overall subsystem map
  - `project_tidelink_asic_fpga_autonomy_plan_2026_05_29.md` — current 8-phase autonomy plan; this refactor *accelerates* it
  - `reference_tidelink_role_lock.md` — POR-default semantics
  - `reference_tidelink_address_map.md` — what lives at which APB region

---

## 1. Executive summary

**Verdict: partially feasible — proceed with phases 1–2 only.**

Every I²C transaction that `tidelink_autoneg.sv` issues is a PHY bring-up operation (lane-mask handshake, training-mode set/clear, peer cal_done poll, role-claim arbitration). Architecturally the I²C belongs in the PHY, and moving it there **accelerates** the in-flight ASIC=FPGA Autonomy Plan rather than fighting it.

The biggest blocker is the **slave-AXIL→APB bridge fanout** at `axi_chiplet_controller.sv:1612-1678`: today the same bridge writes into Region 4/8 (controller-owned register file) **and** Wlink's internal APB space. Either both must move down with the I²C, or the I²C stays where it is. There is no clean intermediate. **Resolve this decision before starting phase 2.**

Recommended phasing:

| Phase | Wall-clock | Net change | Risk |
|------:|-----------:|:-----------|:-----|
|   1   | ~0.5–1 day | Move I²C master/slave *instances* into a thin `WlinkGPIOPHY_brup.sv` wrapper. FSM stays at controller. No-op refactor that validates the wrapper pattern. | Low |
|   2   |    ~2–3 d  | Move `tidelink_autoneg.sv` + slave-AXIL→APB bridge + Region 4/8/C registers into the PHY shim. Controller shrinks ~800 lines. | Medium |
|   3   |    ~5–7 d  | Full move: calibrator + lane_checker + IDELAYE2 + RX BUFG also descend. Deferred to v2 cycle. | High |

Phase 1 is risk-free and can be done immediately after silicon validation of v15. Phase 2 is conditional on resolving the bridge-fanout decision (§7). Phase 3 should not start until phase 2 is silicon-validated.

---

## 2. Problem statement

The user's question, verbatim:

> "How feasible would it be to move the I²C work into the GPIO PHY instead of having it within TideLink, so it can be used as part of the PHY layer and TideLink sits above it? What functionality would be lost and what would need to be restructured?"

Motivation:
- The PHY is currently a vendor submodule (`deps/axi-chiplet-controller/logical/wlink/`).
- The I²C plumbing lives one layer up in TideLink-controller code.
- If the I²C bring-up handshake belongs to the *PHY's* bring-up problem (not TideLink's), then giving the PHY ownership makes the PHY self-contained: any future controller (not just TideLink) can sit above it and inherit autonomous bring-up.
- TideLink becomes a thinner controller layer focused on FCSM / FC-node / AHB/AXI / address translation.

---

## 3. Background — what I²C does at TideLink level today

### 3.1 Every I²C transaction the autoneg FSM issues

From `src/rtl/local_overrides/tidelink_autoneg.sv` (FSM) and `src/rtl/local_overrides/axi_chiplet_controller.sv` (instance):

| FSM state (decimal) | Target (peer register) | Direction | Purpose |
|--------------------:|:-----------------------|:----------|:--------|
| `ST_NEGO_CLAIM` (3), `ST_NEGO_POLL` (4) | I²C slave addr `0x7E` (claim byte + SDA-START detect) | write | Role priority arbitration |
| `ST_NEGO_MASK_RES_TX` (8) | Wlink `0x021C` (`link_lane_mask_hs_result`) | write | Mask-handshake response |
| `ST_NEGO_MASK_RD_ADDR` (9), `ST_NEGO_MASK_RD_DATA` (10) | Wlink `0x0214` (`link_lane_mask`), 4 bytes | read | Mask-handshake — read peer's mask |
| `ST_TRAIN_ENTER` (12) | Region 8 `0x2100` (`SWI_TRAINING_MODE`) := 1 on peer | write | Kick peer's calibrator into training |
| `ST_TRAIN_POLL_PEER` (14) | Region 8 `0x2108` (`SWI_LANE_STATUS`), 3 bytes | read | Poll peer's `lane_locked`, `lane_fault`, `cal_done` |
| `ST_TRAIN_EXIT` (15) | Region 8 `0x2100` (`SWI_TRAINING_MODE`) := 0 on peer | write | Release peer's training mode |

File:line citations:
- FSM state encoding: `tidelink_autoneg.sv:185-202`
- Mask handshake transactions: `tidelink_autoneg.sv:247-261`
- Training-mode transactions: `tidelink_autoneg.sv:268-285`
- Peer cal_done poll: `tidelink_autoneg.sv:286-296`
- I²C master/slave instances: `axi_chiplet_controller.sv:1385`, `:1422`

**Every one of these is PHY-class.** None touch FCSM, AHB/AXI, FC-node, address translation, or anything above the lane-up boundary.

### 3.2 What stays at TideLink-controller scope

| Function | File:line | Reason it's controller-class |
|----------|-----------|------------------------------|
| `role_lock_reg` latch | `axi_chiplet_controller.sv:425-430, 433-470` | Gates Wlink reset; consumed by FCSM |
| FC node arbitration | `tidelink_top.sv` + FC adapter | Above the lane-up boundary |
| Address translation | `tidelink_addr_translation.sv` (dormant) + active variant | Application-layer |
| AHB/AXI bridges (XHB500) | `axi_chiplet_controller.sv:2156-2162` | Application-layer |

### 3.3 Ambiguous

| Function | File:line | Tension |
|----------|-----------|---------|
| `i2c_slv_addr_reg` POR `0x7E` + SW-overridable post-lock | `axi_chiplet_controller.sv:5, 1137, 1358` | PHY needs `0x7E` for bring-up; post-lock the bus is repurposed as CPU→peer-APB sideband |
| `mask_hs_local_match` → `mask_hs_gate_open` | `axi_chiplet_controller.sv:425-470` | Match decision is PHY (lane masks match); consumer is controller (role-lock latch) |
| `local_training_mode_set/clr` + `local_swreset_pulse` | `axi_chiplet_controller.sv:1901` (OR'd into `u_calibrator.swreset`) | PHY-class consumer, controller-class register |

---

## 4. Current architecture — PHY today

```
┌────────────────────────────────────────────────────────────────┐
│ tidelink_top.sv                                                │
│  - AHB/AXI bridges, FC node, address translation               │
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ axi_chiplet_controller.sv (Tier-2)                         │ │
│ │  - Region 4 / 8 / C register file                          │ │
│ │  - role_lock_reg latch                                     │ │
│ │  - calibrator + lane_checker instances                     │ │
│ │  - tidelink_autoneg.sv  ◀─── autoneg FSM here              │ │
│ │  - i2c_master_axil + i2c_slave_axil_master  ◀─── I²C here  │ │
│ │ ┌────────────────────────────────────────────────────────┐ │ │
│ │ │ Wlink.v (vendor + local_overrides)                     │ │ │
│ │ │ ┌────────────────────────────────────────────────────┐ │ │ │
│ │ │ │ WlinkGPIOPHY.v (vendor)                            │ │ │ │
│ │ │ │ ┌────────────────────────────────────────────────┐ │ │ │ │
│ │ │ │ │ WavD2DGpio.v (vendor — generated from Chisel)  │ │ │ │ │
│ │ │ │ │  - 8× WavD2DGpioTx + 8× WavD2DGpioRx           │ │ │ │ │
│ │ │ │ │  - pad_clk_tx, pad_clk_rx                      │ │ │ │ │
│ │ │ │ └────────────────────────────────────────────────┘ │ │ │ │
│ │ │ └────────────────────────────────────────────────────┘ │ │ │
│ │ └────────────────────────────────────────────────────────┘ │ │
│ └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

**Existing PHY ↔ controller boundary** = `Wlink` top-level, instantiated at `axi_chiplet_controller.sv:2039`, ported at `Wlink.v:1-220`.

Signals crossing this boundary that bring-up touches:

**PHY-domain inputs from controller** (`Wlink.v:140-154`, `axi_chiplet_controller.sv:2204-2217`):
- `swi_bit_slip_in[23:0]`, `swi_phase_offset_in[31:0]`, `swi_training_mode_in` — calibrator outputs OR'd with Region 8 SW-override regs
- `peer_tx_lane_mask_i[7:0]`, `peer_rx_lane_mask_i[7:0]` — populated by the autoneg FSM after I²C read

**PHY-domain outputs to controller** (`Wlink.v:140-144, 161-162`):
- `tx_lane_mask_o[7:0]`, `rx_lane_mask_o[7:0]` — local lane masks
- `mask_hs_result_o[1:0]` — currently tied to `2'b00` in `local_overrides/Wlink.v:210`
- `phy_link_rx_rx_link_data_o[127:0]`, `phy_link_rx_rx_link_clk_o` — used by calibrator + lane_checker (which currently live in the controller)

**Reset / clock domains:**
- `apb_clk` — controller, ~50–100 MHz
- `pad_clk_rx` — recovered, post-`tidelink_rxclk_buf` BUFG (`axi_chiplet_controller.sv:2028-2034`)
- `user_hsclk` — high-speed lane domain
- `wlink_por_reset` — gated by `role_locked` in controller (`axi_chiplet_controller.sv:2045`)

---

## 5. Target architecture — PHY post-refactor

```
┌────────────────────────────────────────────────────────────────┐
│ tidelink_top.sv                                                │
│  - AHB/AXI bridges, FC node, address translation (unchanged)   │
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ axi_chiplet_controller.sv (Tier-2) — SHRUNK ~800 lines     │ │
│ │  - role mux for downstream FCSM                            │ │
│ │  - calibrator + lane_checker (phase 2; descends in ph.3)   │ │
│ │ ┌────────────────────────────────────────────────────────┐ │ │
│ │ │ WlinkGPIOPHY_brup.sv  ◀────── NEW SIBLING WRAPPER       │ │ │
│ │ │  - tidelink_autoneg.sv          (was at controller)    │ │ │
│ │ │  - i2c_master_axil + slave      (was at controller)    │ │ │
│ │ │  - Region 4 / 8 / C register file  (was at controller) │ │ │
│ │ │  - slave-AXIL→APB bridge        (was at controller)    │ │ │
│ │ │ ┌────────────────────────────────────────────────────┐ │ │ │
│ │ │ │ Wlink.v (vendor + local_overrides) — unchanged     │ │ │ │
│ │ │ │ ┌────────────────────────────────────────────────┐ │ │ │ │
│ │ │ │ │ WlinkGPIOPHY.v (vendor) — UNCHANGED            │ │ │ │ │
│ │ │ │ │ ┌────────────────────────────────────────────┐ │ │ │ │ │
│ │ │ │ │ │ WavD2DGpio.v (vendor) — UNCHANGED          │ │ │ │ │ │
│ │ │ │ │ └────────────────────────────────────────────┘ │ │ │ │ │
│ │ │ │ └────────────────────────────────────────────────┘ │ │ │ │
│ │ │ └────────────────────────────────────────────────────┘ │ │ │
│ │ └────────────────────────────────────────────────────────┘ │ │
│ └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

**Key design choices:**

1. **Do NOT fork the vendor PHY.** `WlinkGPIOPHY.v` and `WavD2DGpio.v` stay untouched in `deps/axi-chiplet-controller/logical/wlink/`. The new `WlinkGPIOPHY_brup.sv` is a sibling **wrapper** that contains `WlinkGPIOPHY` as a sub-instance. Pattern precedent: `local_overrides/Wlink.v` already wraps the vendor Wlink for similar reasons.

2. **`WlinkGPIOPHY_brup` lives in `src/rtl/local_overrides/`.** Consistent with the existing pattern.

3. **`Wlink` stays where it is** (instantiated inside `WlinkGPIOPHY_brup` would invert the hierarchy; instead `WlinkGPIOPHY_brup` is *peer* of Wlink — the wrapper exposes I²C/autoneg as a sideband, while Wlink stays as the protocol-link). **NOTE:** there is an alternate hierarchy choice here — see §7.

4. **Proposed TideLink-facing `WlinkGPIOPHY_brup` interface** (post-phase 2):
   ```sv
   module WlinkGPIOPHY_brup (
     // Clocks / resets / straps
     input  poresetn, apb_clk,
     input  role_strap_i,
     input  apb_debug_unlock_i, mask_hs_bypass_i,
     // Sideband pads
     inout  i2c_scl, i2c_sda,
     // Bring-up outputs to TideLink controller
     output link_up_o,                    // = role_locked & cal_done & mask_match
     output role_master_o,                // resolved role after autoneg
     output role_locked_o,                // gates downstream Wlink reset
     output [7:0] peer_tx_lane_mask_o, peer_rx_lane_mask_o,
     output [7:0] local_tx_lane_mask_o, local_rx_lane_mask_o,
     output       train_done_o, train_fail_o,
     output       bringup_err_irq_o,
     // Bring-up management AXI/APB (slimmed mgmt-only interface)
     // ...
     // External CPU I²C sideband (post-lock CPU→peer-APB tunnel)
     // s_i2c_axi_*  passed through to internal i2c_master
     // Existing PHY data path (unchanged passthrough)
     input  link_tx_*, output link_rx_*, pad_*
   );
   ```

5. **APB register-space partition (post-refactor):**

   | Region | Today | Post-phase-2 owner | Notes |
   |--------|-------|--------------------|-------|
   | Region 4 (`0x080-0x09C`) — ROLE_CFG, I²C cfg, NEGO_CFG, NEGO_PRIORITY, NEGO_TIMEOUT | controller `axi_chiplet_controller.sv:745-757` | **PHY shim** — all bring-up |
   | Region 8 (`0x100-0x11C`) — SWI_TRAINING_MODE/RECAL/BIT_SLIP/PHASE, SWI_LANE_STATUS, NEGO_TRAIN_CFG/STATUS, EYE_* | controller `axi_chiplet_controller.sv:780-1029` | **Mostly PHY shim** (EYE_* could go either way) |
   | Region C (`0x180-0x19C`) — autoneg observability | controller `axi_chiplet_controller.sv:1035-1101` | **PHY shim** — required for silicon debug |
   | AHB/AXI-mapped Wlink config (`0x4403_0000` + Wlink internal regs) | controller passthrough | **Stays in controller** (Wlink config is application-layer) |

---

## 6. What is LOST or needs redesign

1. **Region C observability (Bug N7/N8 probes).** Must be mirrored into the PHY shim's APB to preserve silicon debug. The autonomy plan's Phase 7 verification harnesses *require* Region C — see `project_tidelink_asic_fpga_autonomy_plan_2026_05_29`.
2. **Region 8 SWI registers** — the peer-I²C-write path lands these via the slave AXIL→APB bridge (`axi_chiplet_controller.sv:1485-1496, 1612-1678`). If autoneg moves down, the bridge and register file move with it. The OR-merge of `local_training_mode_set/clr` (FSM-internal) with peer-I²C-writes at `axi_chiplet_controller.sv:947-949, 973` either stays internal to the PHY shim, or is exposed as a clean external `training_mode_force_i` port.
3. **`role_lock_reg` latch** depends on `nego_set_role_lock_w` + `mask_hs_local_match` (autoneg outputs) **and** `apb_debug_unlock_i` + `mask_hs_bypass_i` (straps). Straps can move to PHY (production silicon) or stay at top with feed-back.
4. **Per-lane IDELAYE2 + RX BUFG** (`axi_chiplet_controller.sv:1995-2034`, `tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`) — PHY-adjacent FPGA primitives. Phase 3 candidate.
5. **Calibrator + lane_checker** (`tidelink_phy_align_calibrator.sv`, `axi_chiplet_controller.sv:1870-1954`) — PHY-class already. Phase 3 candidate; deferred because they consume `phy_link_rx_rx_link_data_o` exposed through Wlink and moving them touches `wlink_por_reset` gating.
6. **`s_i2c_axi_*` external AXI sideband** (`axi_chiplet_controller.sv:260-303`) — the CPU's MMIO path to drive I²C post-lock. Re-export through the PHY shim, ideally bundled into one packed-struct AXI4 port to keep the shim readable (~40 ports otherwise).
7. **PUF / `nego_priority`** (`axi_chiplet_controller.sv:119-121`) — TideChart PUF inputs. Cross-repo contract; either move with autoneg or stay as top-level pins on the PHY shim. Memory: `project_tidechart.md`.

**No I²C usage beyond bring-up/post-lock SW exists today** — the bus is dual-purpose (autoneg + post-lock CPU sideband). Both stay in the PHY shim if the PHY shim exposes a slave AXI port at top level.

---

## 7. THE BLOCKER — slave-AXIL→APB bridge fanout

This is the single biggest architectural decision and it gates phase 2.

**Today, the slave-AXIL→APB bridge at `axi_chiplet_controller.sv:1485-1496, 1612-1678` writes into:**
- Region 4 (controller-owned register file)
- Region 8 (controller-owned register file)
- **Wlink's internal APB space** (Wlink config registers @ `0x4403_0000`)

The bridge is **one master** with cross-region routing logic at `axi_chiplet_controller.sv:415-470` ("Bug N2 fix" — peer-I²C-write to local Region 4/8). This routing is non-trivial.

**Options:**

| Option | Description | Cost | Recommendation |
|-------:|:------------|:-----|:---------------|
| **A** | Bridge moves down + Region 4/8 move with it. Wlink config writes route back up via a new port from PHY shim to controller. | Invasive but clean separation. ~1 extra port pair on the PHY shim boundary. | **PREFERRED** if you want phase 2 to land cleanly. |
| **B** | Bridge stays at controller scope + autoneg also stays at controller scope. No phase 2. | Zero refactor — just abandon the move. | Falls back to "phase 1 only" — still useful. |
| **C** | Bridge moves down, Region 4/8 stay above, the PHY shim's bridge re-exports an APB master upward to write the controller's regs. | Creates a cross-hierarchy APB master — regresses observability (Region C reads from PHY would need a downward-then-upward round trip). Complicates the autonomy plan's Phase 1/G2 closure. | **REJECT.** |

**Decision required before phase 2 starts.** Default recommendation: **Option A.**

The cross-hierarchy implication of Option A: the PHY shim exposes a `m_apb_to_wlink_*` master port that the controller wires to Wlink's existing APB inbound. This is purely a routing addition; Wlink's interface doesn't change.

---

## 8. Phased implementation plan

### Phase 1 — I²C instances → wrapper (no-op refactor)

**Goal:** Create `WlinkGPIOPHY_brup.sv` and move the `i2c_master_axil` and `i2c_slave_axil_master` instances into it. Everything else stays at controller scope. Validates the wrapper pattern. Functionally a no-op.

**Files added:**
- `src/rtl/local_overrides/WlinkGPIOPHY_brup.sv` (new) — initial body: pad-pass-through + I²C instances + I²C signal ports.

**Files modified:**
- `src/rtl/local_overrides/axi_chiplet_controller.sv`:
  - Replace the two I²C instances (~lines 1385, 1422) with a single `WlinkGPIOPHY_brup` instance.
  - Plumb every signal that previously crossed from the controller into the I²C instances out to ports on the new wrapper.
  - Keep autoneg, register file, calibrator unchanged.

**Files NOT modified:**
- `deps/axi-chiplet-controller/logical/wlink/` — vendor untouched.
- `src/rtl/local_overrides/tidelink_autoneg.sv` — FSM unchanged.
- `src/rtl/local_overrides/Wlink.v` — unchanged.
- Cocotb tests — hierarchical-force paths to `u_i2c_master_axil.*` must be updated to `u_phy_brup.u_i2c_master_axil.*`. Scripted sed pass over `cocotb/tidelink_top_pair/test_*.py` and `cocotb/tidelink_autoneg/*`.

**Verification:**
- Lint clean (`make -C lint`).
- Sim regression `cocotb/tidelink_top_pair/`: 18 tests, BYPASS_AUTONEG=0 — all pass identically to pre-refactor baseline.
- Cocotb hierarchy force test: verify a known-good force path still hits the same signal.

**Deliverable:** branch `feat/phy-brup-phase1` with one commit per logical change, PR'd against `feat/td-autonomy` (or whatever silicon-validated baseline exists by then).

**Effort:** 0.5–1 day. Mostly mechanical.

**Rollback:** Revert the commits. No silicon impact (phase 1 should not require a rebuild; pre/post bitstreams should be byte-identical or near-identical).

---

### Phase 2 — autoneg FSM + register file → PHY shim

**Pre-requisite:** Phase 1 merged. **Decision on §7 (Option A vs B vs C) made.** Assuming Option A.

**Goal:** Move `tidelink_autoneg.sv`, the slave-AXIL→APB bridge, and Region 4/8/C registers into `WlinkGPIOPHY_brup.sv`. Controller shrinks ~800 lines.

**Files moved/added:**
- `src/rtl/local_overrides/WlinkGPIOPHY_brup.sv` — grows to host autoneg + bridge + register file.
- New: `src/rtl/local_overrides/wlink_gpio_phy_brup_apb.sv` — APB shim hosting `SWI_*`, `NEGO_*`, `OBS_*` registers (carved out of `axi_chiplet_controller.sv:780-1100`).

**Files modified:**
- `src/rtl/local_overrides/axi_chiplet_controller.sv`:
  - Remove autoneg instance, bridge instance, Region 4/8/C declarations.
  - Add new ports for the post-refactor PHY-shim interface (§5).
  - Add the `m_apb_to_wlink_*` master routing (Option A).
  - Keep `role_lock_reg` consumption (FCSM enable) — `role_locked_o` now comes from PHY shim.
- `src/rtl/tidelink_top.sv` — port-list reshape if the controller's external interface widened.
- `flist/tidelink.flist`, `flist/tidelink_top.flist`, `flist/tidelink_fpga.flist` — add new files.

**Files NOT modified:**
- Vendor PHY — untouched.
- `Wlink.v` — untouched.
- Calibrator, lane_checker — stay at controller scope (phase 3).

**Verification:**
- Lint clean.
- Sim regression `cocotb/tidelink_top_pair/`: all 18 tests pass. Hierarchical-force paths re-pathed (`u_controller.u_autoneg.*` → `u_controller.u_phy_brup.u_autoneg.*`).
- Sim regression `cocotb/tidelink_autoneg/` — unit-level autoneg TB should be **easier** to run because the autoneg now sits in a smaller scope.
- New sim: instantiate `WlinkGPIOPHY_brup` standalone with stub Wlink, confirm autoneg cycles complete in isolation (~1 day to write).
- Silicon validation: rebuild v16 + bridge1 deploy + `probe_autoneg_obs.sh` + confirm bilateral `role_lock=1, train_ok=1`. Same regression cadence as v15.

**Deliverable:** branch `feat/phy-brup-phase2` PR'd against silicon-validated baseline.

**Effort:** 2–3 days, plus a silicon validation cycle.

**Rollback:** Revert the commits. Silicon revert: re-deploy v15 (or whichever validated bitstream exists).

---

### Phase 3 — calibrator + lane_checker + IDELAYE2 → PHY shim

**Pre-requisite:** Phase 2 silicon-validated.

**Goal:** Absorb the remaining PHY-class blocks into the shim. Controller becomes a thin FCSM/FC/AXI layer.

**Files moved:**
- `src/rtl/tidelink_phy_align_calibrator.sv` → reference inside `WlinkGPIOPHY_brup.sv`.
- `src/rtl/tidelink_idelay_rx.sv`, `src/rtl/tidelink_rxclk_buf.sv` → reference inside `WlinkGPIOPHY_brup.sv`.

**Open issue:** `wlink_por_reset` gating by `role_locked` at `axi_chiplet_controller.sv:2045`. Wlink is below role_lock today. If autoneg + role_lock are inside the PHY shim, the PHY shim needs to gate Wlink's reset **from below**, which inverts the current hierarchy. Two resolutions:
- (a) `WlinkGPIOPHY_brup` sits **above** Wlink — clean, but renames "PHY shim" → "PHY+protocol shim". Pragmatic.
- (b) Add `wlink_por_release_o` port out of the PHY shim that drives Wlink's reset directly.

**Verification:** as phase 2, plus full eyemap sim and the `cocotb/wavd2d_gpiorx_*` suite.

**Effort:** 5–7 days, plus silicon validation.

**Deferred — do not start until phase 2 is silicon-validated.**

---

## 9. Compatibility with the ASIC=FPGA Autonomy Plan

Memory entry: `project_tidelink_asic_fpga_autonomy_plan_2026_05_29.md`. Doc: `docs/ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md`.

| Gap | Today | Post-phase-2 |
|----:|:------|:-------------|
| G1/G2 — `local_swreset_pulse_w` through Tier-2 AND-mask | Hack in `tidelink_top.sv:1751-1791` AND-masks bit[3] of `0x208` | **Intra-PHY** connection — no Tier-2 hack |
| G3 — `NEGO_TRAIN_CFG_RESET=16'h0001` | Already landed (`axi_chiplet_controller.sv:60`) | Moves with autoneg |
| G4–G7 — retire `deploy_pair.sh` MMIO writes | SW pokes Region 4/8 from PYNQ side | Region 4/8 are PHY-internal; deploy_pair.sh end-state ("one role_strap GPIO write + readback") is more naturally reachable |
| Strap policy | `role_strap_i`, `apb_debug_unlock_i`, `mask_hs_bypass_i` at controller | Already PHY-shim-class ports |

**The move accelerates the plan rather than blocking it.** Phase 7 verification harnesses (`test_10_autonomous_train_post_por.py` etc.) become PHY-shim unit tests after phase 2.

---

## 10. Risk register

| # | Risk | Phase | Likelihood | Impact | Mitigation |
|--:|:-----|:-----:|:----------:|:------:|:-----------|
| 1 | Slave-AXIL→APB bridge fanout — §7 decision is wrong | 2 | Med | High | Make Option A decision before starting; prototype the bridge move in phase 2.0 |
| 2 | Cocotb hierarchical-force paths break tests | 1, 2 | High | Low | Scripted sed pass; ~18 test files |
| 3 | Vendor submodule update collides with `WlinkGPIOPHY_brup` (vendor renames `WlinkGPIOPHY` ports) | All | Low | Low | Document the wrapper assumption in the new file's header |
| 4 | `wlink_por_reset` hierarchy inversion | 3 | High | Med | Decide §8.Phase3 resolution before starting phase 3 |
| 5 | TideChart PUF cross-repo contract breaks | 2 | Med | Med | Coordinate with TideChart owner before changing `nego_priority_i` semantics |
| 6 | Silicon regression in phase 2 — bring-up doesn't converge after move | 2 | Med | High | Strict pre/post silicon comparison; rollback path is well-defined |
| 7 | Region C silicon-probe paths break — silicon debug regresses | 2 | Med | High | Region C must move with autoneg; tested in §11 |
| 8 | `s_i2c_axi_*` AXI4 sideband — ~40 ports inflate the shim boundary | 2 | High | Low | Bundle into one packed-struct AXI4 port |
| 9 | Lint regression from new SystemVerilog modules in a Verilog-dominated tree | All | Low | Low | Run `make -C lint` per phase |
| 10 | Memory entries reference paths that move | After phase 2 | Med | Low | Audit and update memory files post-phase-2 |

---

## 11. Verification per phase

### Phase 1
- [ ] `make -C lint` clean
- [ ] Cocotb regression `cocotb/tidelink_top_pair/` 18 tests PASS
- [ ] Cocotb regression `cocotb/tidelink_autoneg/` unit tests PASS
- [ ] Sample hierarchical-force test: bit-exact signal hit pre/post
- [ ] Synthesis QoR: no regression in cells/area

### Phase 2
- [ ] All of phase 1
- [ ] New standalone `WlinkGPIOPHY_brup` TB: autoneg cycles to completion
- [ ] Region C probe script `pynq_host/scripts/probe_autoneg_obs.sh` works against new register addresses (or they're unchanged)
- [ ] Silicon: v16 builds (master local + slave srv04936), bilateral deploy on bridge1
- [ ] Silicon: `role_lock=1` on both dies, `train_ok=1` on winner — same as v15 baseline
- [ ] Silicon: `nego_train_status` and `swi_lane_status` MMIO reads at the same offsets as pre-refactor

### Phase 3
- [ ] All of phase 2
- [ ] Eyemap sim suite passes (`cocotb/eyemap_*`)
- [ ] `cocotb/wavd2d_gpiorx_*` regression PASSES
- [ ] `wlink_por_reset` hierarchy inversion handled — confirmed no deadlock on cold-boot

---

## 12. Open questions for the owner

1. **§7 Option A vs B vs C** — confirm Option A.
2. **TideChart PUF interface** — does `nego_priority_i` move with autoneg, or stay as PHY-shim top-level pin? Coordinate with TideChart owner (separate repo `~/SoCLabs/tidechart`).
3. **`s_i2c_axi_*` packing** — single packed-struct port (cleaner) vs 40 separate ports (easier to grep)?
4. **Memory-file updates** — after phase 2, the project memory entries (`project_tidelink_wlink.md`, `reference_tidelink_address_map.md`) reference Region 4/8/C as living in `axi_chiplet_controller.sv`. Plan to update them as part of the phase 2 commit.
5. **Branch naming** — `feat/phy-brup-phase1`, `feat/phy-brup-phase2`, `feat/phy-brup-phase3`? Or one long-lived branch `feat/phy-brup` with squash-merged phases? Owner's preference.

---

## 13. Hand-off checklist for the next agent

When you pick this up:

- [ ] Re-read §0 — verify you have full context cold.
- [ ] Confirm the silicon baseline you're refactoring against — is v15 or later validated? **Phase 1 can start without silicon validation. Phase 2 should not.**
- [ ] Make the §7 Option decision (default A).
- [ ] Cut branch `feat/phy-brup-phase1`.
- [ ] Implement phase 1, verify against §11.
- [ ] Open PR, sit on it until phase 1 is silicon-validated (run a quick build to confirm no synth regression — it should be a no-op).
- [ ] Decide whether to merge to `main` after phase 1, or keep on a long-lived feature branch through phase 2.
- [ ] Start phase 2 only when phase 1 is silicon-validated.

---

## 14. References

- This document: `docs/I2C_TO_PHY_REFACTOR_PLAN_2026_06_03.md`
- Architecture reference: `docs/PHY_ARCHITECTURE_REFERENCE.md`
- HW validation runbook: `docs/HW_VALIDATION_RUNBOOK_GPIO_PHY_INTEG.md`
- ASIC=FPGA autonomy plan: `docs/ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md`
- I²C pin analysis: `docs/I2C_PIN_ANALYSIS_2026_05_31.md`

Source files cited in this plan:
- `src/rtl/local_overrides/axi_chiplet_controller.sv`
- `src/rtl/local_overrides/tidelink_autoneg.sv`
- `src/rtl/local_overrides/Wlink.v`
- `src/rtl/local_overrides/WavD2DGpio.v`
- `src/rtl/tidelink_phy_align_calibrator.sv`
- `src/rtl/tidelink_idelay_rx.sv`
- `src/rtl/tidelink_rxclk_buf.sv`
- `src/rtl/tidelink_top.sv`
- `deps/axi-chiplet-controller/logical/wlink/WlinkGPIOPHY.v`
- `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v`

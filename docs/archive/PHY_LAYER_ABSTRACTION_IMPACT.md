# PHY Layer Abstraction — Impact Assessment

**Date:** 2026-05-23
**Author:** pre-implementation audit
**Companion doc:** `docs/PHY_LAYER_ABSTRACTION.md` (the proposal)
**HEAD at assessment:** `034376f` on `main`
**Last known-good HW state:** bridge1 build #7 (2026-05-23 08:08), 16/16 lock,
GPIO PHY, `USE_CLKBUF=1`, `USE_IDELAY=1`, `USE_T3A=1`

This document does **not** propose RTL changes. It maps the proposal in
`PHY_LAYER_ABSTRACTION.md` onto the actual code in this tree, scores the cost
and risk of each phase, and recommends a path forward.

---

## 1. Ground truth — where the PHY boundary actually lives today

The proposal doc says `WavD2DGpio` is instantiated *inside* `Wlink.v`. That is
almost true but slightly misleading; verifying against the RTL:

* `deps/axi-chiplet-controller/logical/wlink/Wlink.v` line 1054 instantiates
  **`WlinkGPIOPHY`** (not `WavD2DGpio` directly). `WlinkGPIOPHY` is itself the
  thin wrapper around `WavD2DGpio`. The `link_tx_*` / `link_rx_*` ports of
  `WlinkGPIOPHY` are exactly the proposed PHY interface — they are already a
  module port list, not just internal wires.
* `Wlink.v` already exposes `phy_link_rx_rx_link_data_o` and
  `phy_link_rx_rx_link_clk_o` as top-level outputs (lines 161–162), and accepts
  the calibration sideband as `swi_bit_slip_in` / `swi_training_mode_in` /
  `swi_phase_offset_in` inputs (lines 149–154). These are SoC Labs patches.
* The `pad_clk_tx` / `pad_tx_N` / `pad_clk_rx` / `pad_rx_N` lines come out of
  `Wlink.v` (lines 115–132) and pass straight up through
  `axi_chiplet_controller.sv` and `tidelink_top.sv:184–187`.
* `tidelink_idelay_rx` and `tidelink_rxclk_buf` are instantiated **inside**
  `axi_chiplet_controller.sv` (lines 1392 / 1425) — the IDELAY sits in the
  controller, not in `tidelink_top` and not in `Wlink`.
* `tidelink_lane_checker` and `tidelink_phy_align_calibrator` are also
  instantiated inside `axi_chiplet_controller.sv` (lines 1305 / 1327), driving
  the OR-merged `swi_*_w` signals into Wlink's `swi_*_in` ports.

**Consequence:** the actual lift is shorter than the proposal implies. The PHY
boundary signals are already module ports of `WlinkGPIOPHY` and partially of
`Wlink`. The bulk of "PHY-specific glue" is in `axi_chiplet_controller.sv`,
not in `Wlink.v`. A proper `tl_phy_gpio.sv` is mainly a re-packaging of code
that already exists in `axi_chiplet_controller.sv`.

---

## 2. Scope — files that change vs. files that don't

### 2.1 Would change (any phase)

| File | Change class | Notes |
|---|---|---|
| `deps/axi-chiplet-controller/logical/wlink/Wlink.v` | Generated Verilog edit | Need to promote `phy_link_tx_tx_*` (en, ready, link_data, lane_mask, link_clk) to top-level ports and **delete** the `WlinkGPIOPHY phy (...)` instance plus the `pad_*` and `swi_*_in` ports. Risk: this file is regenerated from Chisel; the existing SoC Labs patches (mask handshake, swi_bit_slip_in, phy_link_rx_*_o, obs_*) are already applied by-hand. One more by-hand edit is consistent with current practice but increases the diff that has to be re-applied on next Chisel regen. |
| `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` | FSM rewiring + boundary move | The calibrator/lane-checker/idelay/rxclk_buf moves out into `tl_phy_gpio.sv`; the file becomes pure link-layer wrapper. The Region 8 SW override regs (`swi_training_mode_r`, `swi_bit_slip_lo_r`, `swi_phase_offset_r`, etc. around lines 540–706) either move into the PHY wrapper APB or stay here and feed in via the new PHY ports. |
| `src/rtl/tidelink_top.sv` | Structural — adds PHY instance | Gains `PHY_TYPE` parameter and a generate-if PHY instance. The pad ports stay; they now route to the PHY wrapper, not down through ACC. |
| **New** `src/rtl/phy/gpio/tl_phy_gpio.sv` | New module | Wraps `WlinkGPIOPHY` + `tidelink_idelay_rx` + `tidelink_rxclk_buf` + `tidelink_lane_checker` + `tidelink_phy_align_calibrator`. |
| **New** `src/rtl/phy/tl_phy_if.sv` (optional) | New interface | Only if we adopt SV interface ports rather than a flat port list. |
| `flist/tidelink_fpga.flist` (and ASIC equivalent) | Filelist split | Compose `tidelink_common.flist` + `tidelink_phy_gpio.flist`. Mechanical. |
| FPGA XDC constraints | **Likely no change** | Pad locations and IDELAY/IODELAY assignments target the same physical pins; only the SV hierarchical path changes. Net-name-based constraints (`get_pins`, `get_cells *u_phy_align*`) would need path updates. **TBD — see Open Questions §7.** |
| `cocotb/tidelink/` Region 8 register tests | Address may change | If Region 8 regs move into a PHY APB, their address offset shifts. Tests that poke `SWI_BIT_SLIP_LO` etc. break unless we keep the same APB tree. |

### 2.2 Would NOT change

* `deps/axi-chiplet-controller/logical/wlink/WlinkGPIOPHY.v` — already has the
  right interface; gets re-instantiated under a new parent.
* `deps/.../WavD2DGpio.v`, `WavD2DGpioRx.v`, `WavD2DGpioTx.v` — untouched.
* `src/rtl/tidelink_phy_align_calibrator.sv`, `tidelink_lane_checker.sv`,
  `tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`, `tidelink_phy_align_regs.sv`
  — instantiated inside the new wrapper unchanged. (Optional: rename for
  namespace cleanliness — see §7 Q3.)
* All non-PHY TideLink RTL: `tidelink_ahb.sv`, `tidelink_apb_regs.sv`,
  `tidelink_fc_adapter.sv`, `tidelink_ptp*.sv`, address translator, FIFO,
  returner, perf, clkfreq_check.
* Wlink TL/LL Chisel internals (`txrouter`, `lltx`, `llrx`, `tl2wl`, FCSM).

---

## 3. Risk assessment by change category

### 3.1 Interface boundary changes (HIGH risk if rushed, LOW if staged)

* Promoting `phy_link_tx_tx_*` to Wlink.v ports is structurally simple — the
  wires already exist (lines 305–312) and the RX-side promotion (already
  landed) is the precedent. **Risk:** any later Chisel regen will silently
  re-bury them. **Mitigation:** document the patch in the deps tree's SoC Labs
  diff log (same place the obs_* and mask handshake patches live).
* Deleting the `WlinkGPIOPHY phy(...)` instance from `Wlink.v` is destructive
  to the existing HW-validated artefact. Anything that synthesised through
  this file before (bridge1 build #7) sees a different hierarchy after.
  **Risk:** synth-time constant propagation, `dont_touch` net loss, or
  Vivado's habit of inferring different clock-domain crossings can shift
  timing. The IDELAY/T3A/CLKBUF parameter trio is set on `WlinkGPIOPHY`
  (`USE_CLKBUF`, `USE_T3A`); these must thread cleanly through the new
  wrapper. **Mitigation:** Phase 1 is a no-op pass-through wrapper —
  identical synthesis result on the first fold.

### 3.2 FSM rewiring (MEDIUM)

The calibrator (`u_calibrator`) drives `swi_bit_slip_w` / `swi_phase_offset_w`
/ `swi_training_mode_w` into Wlink. These signals are OR-merged with the APB
override path (`swi_bit_slip_lo_r | cal_bit_slip_w`, etc.). If the SW override
regs migrate into the PHY wrapper's APB while the calibrator stays where it
is, the OR-merge has to either:

* be carried out at the PHY wrapper top (so the regs and the calibrator output
  meet there before going into `WlinkGPIOPHY`), **or**
* the calibrator also moves into the wrapper (cleaner — this is what the
  proposal recommends).

**Risk:** if the OR-merge boundary is wrong, autocal still runs but the APB
escape hatch (used by cocotb tests and during silicon bring-up to force a
known phase) goes dead. This regresses debug-ability without an obvious sim
failure. **Mitigation:** include an APB-forced-phase sanity check in the
Phase-1 cocotb suite before fold.

### 3.3 Clock-domain considerations (MEDIUM-HIGH on FPGA, LOW on ASIC)

* `phy_link_rx_rx_link_clk` is the recovered RX link clock. It is currently
  driven into `axi_chiplet_controller`, fed to `tidelink_rxclk_buf` (BUFG on
  FPGA, passthrough on ASIC), then redistributed. Moving the BUFG into the
  PHY wrapper means **the BUFG insertion point relative to the global clock
  network changes hierarchy**. Vivado is generally hierarchy-agnostic for
  BUFG inference but **constraint files reference net names** — both the
  master XDC and any timing exceptions on `phy_link_rx_rx_link_clk` need
  audit.
* `phy_link_tx_tx_link_clk` is sourced inside `WlinkGPIOPHY` (the TX
  serializer's link clock); promoting it as a port is structurally trivial.
* `user_hsclk` (input to `WlinkGPIOPHY`) is currently passed in by ACC.
  Routing it into the new PHY wrapper from the ACC wrapper adds one extra
  level of hierarchy on a critical clock pin. **Risk:** trivial in sim,
  watch for clock buffer insertion / promotion changes in FPGA P&R.

### 3.4 Constraint file impact (MEDIUM)

We avoid touching constraint files in this assessment, but the FPGA path
(`USE_IDELAY=1`, `USE_CLKBUF=1`, IDELAY group, IDELAY control instance, RX
clock IBUFG and BUFG) has hierarchical references in `*.xdc` files we have
*not* enumerated here. The proposal's directory restructure (`src/rtl/phy/...`)
also changes the `get_cells` paths used in `set_max_delay`, `set_false_path`,
and `IODELAY_GROUP` constraints. **This is the single biggest source of
hidden cost** — the post-fold build will look syntactically green but fail
timing if a `set_false_path -through` loses its target.

### 3.5 Generated-file maintenance (LOW-MEDIUM)

`Wlink.v` is Chisel output. The SoC Labs tree already carries patches against
it (peer-mask handshake, `phy_link_rx_*_o`, `swi_*_in`, `obs_*`). One more
patch increases regen burden but is not categorically new risk. **Mitigation:**
keep the changes minimal and document them in the same SoC Labs diff register
the previous patches use.

---

## 4. Validation plan

### 4.1 Sim coverage required per phase

| Phase | Sim suite | New tests required | Existing tests that must still pass |
|---|---|---|---|
| 1 (no-op wrapper) | `cocotb/tidelink/*` | none | full regression: addr_trans, FC, PTP, FIFO, autoneg, lane lock |
| 2 (model PHY) | `cocotb/link_layer/` *new* | LL TX→RX loopback via model | Phase 1 regression unchanged |
| 3 (Wlink port-promote + WavD2DGpio relocation) | `cocotb/phy_gpio/` *new* + tidelink regression | calibration convergence, lane fault inject, APB-forced phase | full tidelink regression including autoneg |
| 4 (Region 8 reg relocation) | regression | register accessor address update | all `cocotb/phy_align/*` |

### 4.2 HW build cycles required per phase

Each cycle = ~50 min (build + deploy + lease + observe = ~40 min build + 10
min validate). Plan assumes srv04936 farm available and `bridge1` pair as
golden.

| Phase | HW cycles | What's checked |
|---|---|---|
| 1 — no-op wrapper | 1 cycle | bit-identical bitstream digest? if not, 16/16 lane lock + autoneg + lane-checker reports |
| 2 — model PHY (sim-only) | 0 | sim-only; no HW |
| 3 — Wlink port-promote | 1 cycle on bridge1, then 1 cycle cross-bridge | 16/16 lock; verify ECC counters unchanged; autoneg cycle |
| 4 — Region 8 reg relocation | 1 cycle | poke each register from PYNQ AHB and read back; sanity-check phase forcing |
| 5 — SerDes (V2 only) | DEFERRED to V2 program | requires V2 ASIC tape-out target before any cycle is justified |

**Total bring-up cost just to land Phases 1–4 cleanly:** ~4–5 HW cycles
(some may need redo if 16/16 lock regresses). Allowing for one cycle of
constraint-file recovery per phase, budget **6–7 cycles** worst case.

### 4.3 Acceptance criteria for "safe to merge"

A fold is safe to merge only when:

1. `cocotb/tidelink` full regression is green (existing tests, no new
   skips).
2. The corresponding HW build hits **≥ 16/16 lane lock on bridge1** within
   the same calibration timeout as build #7.
3. Autoneg cycle (CLAIM → POLL → granted) completes within the same wall-
   clock window as the baseline.
4. Vivado timing summary shows no new failing endpoints relative to the
   previous merged build.
5. Bitstream digest difference is explainable from RTL diff (i.e. not a
   spurious P&R drift).

---

## 5. Effort estimate (build-cycle-equivalents)

Cycle = ~50 min (RTL edit + sim + farm build + deploy + observe). Estimates
are upper bounds with reasonable buffer.

| Phase | Effort (cycles) | Comment |
|---|---|---|
| 1 — `tl_phy_gpio.sv` pass-through wrapper | 2 | 1 cycle to write + sim, 1 to HW-validate |
| 2 — `tl_phy_model.sv` + `cocotb/link_layer/` | 2 | sim only; no HW build |
| 3 — Wlink.v TX-side port promotion + WavD2DGpio relocation | 3 | the destructive step; allow 1 cycle for constraint chase |
| 4 — Region 8 reg migration into PHY APB | 2 | trivial RTL, mostly test-update cost |
| 5 — SerDes wrapper (`tl_phy_serdes.sv`) | DEFERRED | depends on V2 target — out of scope until V2 PHY plan exists |
| **Total to GPIO-only abstraction** | **9 cycles** | ~7.5 wall-clock hours of pipeline time, more elapsed for HW lease windows |

For comparison: the 65472ff calibrator-collapse refactor that was reverted
cost roughly 4 cycles of pipeline time before being abandoned. The
abstraction is **2–3× more invasive** than that revert.

---

## 6. Recommendation: **SPLIT** (lean toward DEFER on Phase 3+)

**TL;DR — proceed with Phases 1 and 2 only; defer Phases 3 and 4 until a
concrete V2 PHY requirement (SerDes target, V2 ASIC tape-out plan) is in
hand. Phase 5 stays deferred unconditionally.**

### Reasoning

1. The 16/16 lock on bridge1 build #7 is the result of three independent
   bring-up wins (IDELAYE2 + slave-clock + `USE_CLKBUF` + I2C autonomy +
   Bug #3 fix candidates) consolidated into `main` only yesterday. The
   blast radius of Phase 3 (`Wlink.v` TX port promotion + `WlinkGPIOPHY`
   relocation) overlaps the same hierarchy that produced the timing
   regressions in 65472ff. Doing it **before HW characterisation is locked
   in** is premature.
2. Phases 1 and 2 are pure additive — a wrapper that contains nothing yet
   and a sim-only model. Neither touches the synthesis hierarchy of the
   known-good bitstream. They de-risk *future* phases without exposing
   the link to regression.
3. The proposal's stated motivation is **V2 SerDes PHY support**. There is
   currently no V2 SerDes RTL drop, no V2 ASIC tape-out target date, and no
   V2 verification flow. Building the abstraction now to support a PHY that
   doesn't exist yet is speculative — and the abstraction will almost
   certainly need to bend when the real SerDes interface details are known.
4. The proposal's directory restructure (`src/rtl/phy/...`) gains a *real*
   unit-testable benefit (the model PHY → link-layer cocotb suite). That
   benefit is fully available from Phases 1 + 2 alone, without ever
   touching `Wlink.v` or the bring-up-validated hierarchy.

### Proposed sub-task split

* **Sub-task A — "PHY wrapper, no-op"** *(2 cycles)*
  Create `src/rtl/phy/gpio/tl_phy_gpio.sv` as a pass-through that
  instantiates `axi_chiplet_controller` unchanged (or wraps it 1:1 from
  `tidelink_top`). Update `tidelink_top.sv` to instantiate `tl_phy_gpio`
  in place of the direct ACC call. Validate: full sim regression + 1 HW
  cycle on bridge1. **GO** if delta-free.
* **Sub-task B — "Model PHY for sim-only LL testing"** *(2 cycles, sim-only)*
  Add `src/rtl/phy/model/tl_phy_model.sv` (loopback). Add
  `cocotb/link_layer/` suite that exercises Wlink LL/TL framing through
  the model. **GO** as long as it doesn't change any synthesised RTL.
* **Sub-task C — "Wlink.v PHY-port promotion + WlinkGPIOPHY lift"**
  *(3 cycles, blast radius high)* — **DEFER** until either
  (a) V2 SerDes PHY drop arrives, or (b) someone needs the link-layer unit
  test to exercise *more* than what the model PHY supports.
* **Sub-task D — "Region 8 reg migration"** *(2 cycles)* — **DEFER**.
  This is a maintenance refactor; the current ACC-hosted Region 8 regs are
  working as designed and the test suite already targets them.

A + B together cost ~4 cycles, deliver the unit-test benefit, and do not
touch the synthesis hierarchy of the validated bitstream. That is the right
fold size for the current rule "validate every fold with HW".

---

## 7. Open questions for the user

These should be resolved **before** any of A/B/C/D lands.

1. **Interface form — SV `interface` vs. flat port list.** A SV `interface`
   is cleaner but historically has caused trouble with vendor tools (some
   Synplify/DC versions, Verilator strict modes). The proposal lists it as
   "optional but recommended". *Recommendation: flat port list with a
   `tl_phy_if.svh` header for the signal-set definition. Confirm?*
2. **V2 PHY reality.** Is there a concrete V2 SerDes PHY drop on the
   roadmap that this abstraction is paving the way for, or is this a
   future-proofing exercise? If the latter, **DEFER all of C/D** is the
   right call. The proposal-doc lists `WavD2DSerdesRx/Tx` in
   `deps/.../PHY/serdes/`; do they exist in this tree today, and what is
   their interface compatibility versus the GPIO PHY?
3. **Namespace.** The existing files are `tidelink_phy_align_calibrator.sv`,
   `tidelink_lane_checker.sv`, etc. The proposal introduces `tl_phy_gpio*`.
   Are we standardising on `tl_*` going forward (matching the proposal),
   keeping `tidelink_*`, or living with both? *Recommendation: stay on
   `tidelink_*` for existing modules; new PHY wrappers can be
   `tidelink_phy_gpio.sv` / `tidelink_phy_model.sv` for consistency.*
4. **Constraint file ownership.** Who owns the FPGA XDC updates that go
   with hierarchy changes (Sub-task A is hierarchy-changing — adds one
   level)? Need a baseline diff before the first HW cycle.
5. **APB address-map stability.** If Region 8 regs ever move into a PHY
   APB (Sub-task D), the software-visible address map of `tidelink_apb_regs`
   changes. Confirm this is acceptable, or pick "Sub-task D is forbidden,
   the address map is frozen".
6. **Wlink Chisel regen plan.** Sub-task C requires editing the generated
   `Wlink.v` again. Is there any planned Chisel regen in the next 1–2
   release cycles that would clobber the patch, or are we frozen on the
   current Chisel output for v1?

---

## 8. One-line verdict

**SPLIT — proceed with A+B (PHY wrapper no-op + model PHY for sim-only LL
testing), DEFER C and D until V2 SerDes PHY requirements are concrete, and
defer E (SerDes wrapper itself) unconditionally until a V2 PHY drop lands.**

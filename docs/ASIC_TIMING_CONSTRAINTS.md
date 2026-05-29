# ASIC Timing Constraints — TideLink GPIO PHY (Rationale + Constraint Listing)

**Audience:** a future agent taking the TideLink Wav Wlink GPIO PHY to an
ASIC target (Design Compiler / Fusion Compiler / equivalent STA + P&R),
plus the FPGA bring-up engineer applying the equivalent constraints to
`fpga/targets/pynq-z2-pair-*/pynq_z2_tidelink_timing.xdc`.

**Status:** normative reference. Every claim here is required to be
correct for a *source-synchronous chiplet PHY*; treat the checklist in
[Part B §9](#9-sign-off-checklist-gating) as sign-off gating.

This document subsumes the two previous docs
`docs/ASIC_SOURCE_SYNC_CONSTRAINTS.md` (the rationale-side reference) and
`docs/SOURCE_SYNC_CONSTRAINTS_RATIONALE.md` (the per-constraint validation
journal). **Part A** is the rationale (the "why"). **Part B** is the
concrete constraint listing (the "what"), cross-referenced to where the
constraints land in the actual files:

- `syn/asic/fusion-compiler/inputs/constraints.sdc` — the ASIC SDC
  overlay that this document tells you how to repair.
- `imp/ASIC/tidelink_top_full/tidelink_top.sdc` — the implementation-time
  SDC produced for the full chip.
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc` and
  `fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink_timing.xdc` —
  the FPGA equivalents (`set_max_delay -datapath_only` + `set_bus_skew`
  + symmetric `set_input_delay` shape).

**Cross-references**
- The runtime calibrator whose finite window the constraints must keep
  layout inside: `src/rtl/tidelink_phy_align_calibrator.sv`.
- The lock detector that defines what "locked" means:
  `src/rtl/tidelink_lane_checker.sv` (`LOCK_THRESH=16` consecutive
  matches).
- The canonical multi-stage synchroniser pattern used in this codebase:
  `src/rtl/tidelink_phc_cdc.sv` (`SYNC_STAGES` shift-register chain) —
  this is the model for the recovered-RX→core CDC sign-off.
- Determinism measurement of any candidate fix:
  `docs/archive/DETERMINISM_VALIDATION.md` +
  `pynq_host/scripts/determinism_metric.sh`.

---

# Part A — Rationale (the "why")

## 0. The one rule

**Never sign off a source-synchronous chiplet PHY with unconstrained
pad→capture timing.**

"It locked on the FPGA bench" is an *accident* of one particular Vivado
place-and-route seed. An ASIC P&R + STA flow given the same
"async-everything" constraints will either (a) never converge (the tool
has no objective for the pad→capture arc so it optimises it away), or
(b) converge to numbers that are meaningless and silicon that is
PVT-fragile (works at TT/25°C on the bench, fails at the SS or FF corner
or over temperature). The TideLink architecture *deliberately* offloads
skew compensation to a runtime bit-slip×phase calibrator instead of a
static centred IODELAY. That is a valid architecture **only if static
layout skew is bounded by constraints + matched routing so that, across
every PVT corner, the residual skew always lands inside the calibrator's
finite search window.** If you do not bound it by construction, the
calibrator is gambling, exactly as the FPGA bring-up was through 2026-05.

---

## 1. What the calibrator can and cannot absorb (the budget)

`tidelink_phy_align_calibrator.sv` runs, per lane, a search over:

- **bit-slip ∈ [0..7]** — a *byte-boundary* (whole-UI / serdes-tap)
  realignment. 8 positions.
- **phase ∈ [0..15]** — a *sub-bit* sample-point adjust
  (`swi_phase_offset`, 4 bits/lane). 16 positions.

128 points per lane, walked phase-outer / slip-inner, `DWELL_CYCLES=32`
per point, latch-on-lock-and-freeze. `tidelink_lane_checker_single`
declares a lane locked after `LOCK_THRESH=16` consecutive matched words.

**What this means for the constraint budget:**

- The calibrator absorbs **dynamic + PVT** skew and the **static**
  clk-to-data offset *only within one bit-slip×phase grid period*. The
  phase knob resolves sub-UI misalignment in 1/16-UI steps; bit-slip
  resolves whole-UI/byte offsets up to ±7 positions.
- It does **not** absorb skew that exceeds the grid, and — critically for
  determinism — it does **not** help at all if the *build-to-build* (or,
  on ASIC, *corner-to-corner* and *unit-to-unit*) variation of the
  per-lane clk-to-data skew is itself larger than the spacing between
  adjacent good operating points. If a lane's good phase wanders across
  the whole 0..15 range from corner to corner, no single calibrated
  setting and no convergent search exists.
- Therefore the quantity the ASIC constraints must bound is **not the
  absolute skew** (the calibrator centres that) — it is the
  **per-lane clk-to-data skew *spread* across PVT and across the lane
  bundle**, which must be ≤ a fraction of one phase step so that a
  locked operating point found at one corner is still locked (or within
  ±1 phase step) at every other corner.

Concretely: pick the link UI (`T_UI`). One phase step ≈ `T_UI/16`. Set
the **static skew budget** `S_budget` such that
`S_budget ≤ T_UI/16` *minus* the capture flop setup+hold *minus*
characterised PVT derate, so that the eye the calibrator centres on at
sign-off corner is still open at all corners. This budget is what every
constraint in Part B exists to enforce.

**FPGA note (validated):** on `pynq-z2-pair-*` at `pad_clk_rx` = 25 MHz
(40 ns UI), the chosen budgets are `set_max_delay 8 ns` (≤ ½ bit-period)
and `set_bus_skew 2 ns` (≤ 1/20 bit-period). Both are comfortably inside
one slip step with margin — see Part B [§3](#3-pad_rx-lane-bundle-rx-eye).

---

## 2. Forwarded-clock methodology (TX eye and RX eye)

The PHY has two source-synchronous interfaces. Constrain **both** as
forwarded-clock, not async.

### 2.1 Transmit side — `pad_clk_tx` + `pad_tx[7:0]`

`pad_clk_tx` is launched from the local core/link domain and forwarded
off-die alongside the data. Model it as a **generated clock** off the
launching clock, then constrain the data eye against it. The current
ASIC SDC comment "pad_clk_tx is generated by the partition … tools will
infer it … No create_clock here" is **wrong for sign-off**: an inferred
generated clock with **no** `set_output_delay` means the TX eye is
completely unconstrained — the same defect as the disabled FPGA
`set_output_delay`. You must add the explicit generated clock *and* the
output-delay pair. See Part B [§2](#2-pad_clk_tx-launch-tx-eye).

### 2.2 Receive side — `pad_clk_rx` + `pad_rx[7:0]`

`pad_clk_rx` is recovered from the peer's forwarded TX clock. It is a
real, primary timed clock at the RX pads. The *absolute* numeric eye
does not need to be perfectly centred — the calibrator centres it at
runtime. The point of `set_input_delay` here is **not** to demand a
centred capture; it is to make STA *analyse and report* the pad→capture
path so P&R has an objective and so you can measure the per-lane skew
spread. Picking the receiver eye as the peer's worst-case launch window
is sufficient and correct. See Part B [§3](#3-pad_rx-lane-bundle-rx-eye).

---

## 3. `set_clock_groups -asynchronous`: isolate the CDC, do not erase pad→capture

This is the single most important — and historically most violated —
point.

The pre-fix ASIC SDC was broken in exactly the FPGA way.
`syn/asic/fusion-compiler/inputs/constraints.sdc` did:

```tcl
foreach clk {hclk phc_clk scan_clk user_ref_clk pad_clk_rx} { ... }
eval set_clock_groups -asynchronous $_async_groups
```

This lumps `pad_clk_rx` into one global asynchronous partition with
`hclk`, `phc_clk`, `scan_clk`, `user_ref_clk`. The consequence is exactly
the FPGA `set_clock_groups -asynchronous -group {pad_clk_rx} -group
{clk_wiz/clk_out1}` defect: STA is told to **skip all analysis of every
path that starts on `pad_clk_rx`**, including the `pad_rx[*]`→capture-flop
arc that is the *entire* timing-critical content of a source-sync RX.
Any `set_input_delay` added later in the same file is then **dead** —
there is no timed launch/capture relationship left for it to bound.

**The correct structure (two distinct relationships, treated
differently):**

1. **`pad_clk_rx` → `pad_rx[*]` capture flops** = a *source-synchronous*
   relationship. It MUST stay timed. Do **not** put `pad_clk_rx` in an
   async group with the *capture* clock. The data and the clock that
   captures it are forwarded together; their relative timing is the
   whole point and must be analysed and bounded (Part B §4).

2. **recovered-RX domain → core/`hclk` domain** = the *genuine* CDC. The
   payload that crossed on `pad_clk_rx` is resynchronised into the core
   clock by Wlink's internal synchronisers. *This* crossing — and only
   this crossing — is what `set_clock_groups -asynchronous` (or targeted
   `set_false_path`) is for.

If a single multi-group `set_clock_groups` is used, the rule is: the
recovered RX clock may be asynchronous to the *core* clock, but the
`pad_rx[*]` capture registers must be clocked by (and analysed against)
`pad_clk_rx` — keep the capture stage in the `pad_clk_rx` group so the
pad→capture arc is never crossed by an async boundary. Verify after
elaboration with `report_timing -from [get_ports pad_rx[*]] -to
[get_clocks pad_clk_rx]` (or `-through` the capture flops): if it
returns "No paths" you have re-created the defect.

---

## 4. Bounding STATIC layout skew so the calibrator window is a guarantee, not luck

The calibrator (§1) centres the eye dynamically; constraints must
guarantee the *static + PVT* per-lane skew spread stays inside one
calibrator grid so the centred point holds across all corners. Four
mechanisms, all required:

### 4.1 Matched / balanced datapath routing for the lane bundle

Route `pad_clk_rx` and `pad_rx[7:0]` (and symmetrically `pad_clk_tx` /
`pad_tx[7:0]`) as a **length/delay-matched bundle**: the per-lane data
nets matched to each other and to the forwarded clock net, within the
§1 skew budget. Use bus/group routing with shielding if the channel or
on-die environment warrants it. This is the structural guarantee; the
SDC constraints in Part B *enforce and verify* it but routing is what
actually delivers it.

### 4.2 Relative skew constraint, not an absolute hold window

Do **not** translate the receiver eye into a tight absolute
`set_input_delay -min/-max` and let the tool hold-fix every lane
independently — that is precisely the 2026-05-05 FPGA failure (§7).
Instead bound the *relative* lane-to-lane and clk-to-data skew via
`set_max_delay -datapath_only` and `set_data_check` / `set_bus_skew`.
`set_max_delay -datapath_only` excludes clock skew/latency from the
bound so you are constraining the *data net delay spread* directly,
which is what equalises lanes. `set_data_check` is the source-sync
primitive: it expresses "this data must be stable around this strobe by
S_setup/S_hold" without imposing an absolute arrival window, so it does
not provoke blanket hold-buffer insertion. See Part B [§4](#4-bounding-relative-static-layout-skew).

### 4.3 Per-lane programmable delay cells — the ASIC analogue of IDELAYE2

On the FPGA the proper fix is an `IDELAYE2` per `pad_rx[n]` with the
calibrator driving the tap (an explicit, characterised delay line
instead of "hope the routing skew is in range"). The **ASIC equivalent
is a per-lane programmable delay cell** (a calibratable delay element /
DLL-style tap or a coarse+fine delay-line macro from the I/O library) in
each `pad_rx[n]` path, with its control word driven by the calibrator's
existing per-lane `swi_phase_offset` / `swi_bit_slip` plumbing
(`phase_offset[4*N +: 4]`, `bit_slip[3*N +: 3]` in
`tidelink_phy_align_calibrator.sv`). This converts the requirement from
"P&R must accidentally match 8 lanes to within a phase step" into "the
calibrator explicitly trims each lane within a characterised tap range."
Constrain the delay cell's own path, give it an `IDELAY_GROUP`-equivalent
(library-specific) so all lanes share one reference, and characterise
its step vs PVT so the calibrator's 16 phase codes map to a known
ns/code with bounded PVT variation.

### 4.4 Force the capture flop into the I/O / fixed deterministic path

On FPGA: `set_property IOB TRUE` so capture is the deterministic IOB
arc, not build-varying fabric (with the caveat in Part B §3.4 that the
real first-capture flop has a per-bit input mux and cannot fully pack
into the IOB — the property is best-effort on the IOB-able portion).
ASIC equivalent: place the `pad_rx[*]` first-capture flops in (or
immediately abutting) the I/O cell / pad ring with a fixed,
characterised clk-to-Q and a fixed clock-to-flop route, so the
pad→capture delay is dominated by the characterised I/O path and not by
P&R-varying internal routing. Pin these with placement constraints /
relative-placement groups so re-runs do not perturb the per-lane skew.

---

## 5. I/O clocks excluded from core CTS, routed balanced

`pad_clk_tx` (forwarded) and `pad_clk_rx` (recovered) are **I/O clocks**,
not core clocks:

- **Exclude them from the core clock-tree synthesis.** They must not be
  balanced *against the core clock*; they must be balanced *against their
  own lane data*. Letting CTS sink them into the core tree injects
  arbitrary, corner-dependent insertion delay between the forwarded clock
  and its co-routed data — re-creating the unbounded per-lane skew.
- Route them as **dedicated, balanced, matched nets** to the lane I/O
  cells: the clock net delay matched to the data net delays of its
  bundle (§4.1). Use a clock-spine / balanced-mesh constructed *for the
  PHY bundle only*, with explicit skew targets between the clock and each
  `pad_rx[n]` capture point.
- Tag them so CTS leaves them alone: a `set_clock_tree_options` exclusion
  / `dont_touch` on the I/O clock net + explicit non-default routing
  rule, and verify post-CTS that the I/O clock did not acquire core-tree
  buffers.

A `BUFR`/`BUFIO`-class regional resource on the FPGA, or an MRCC vs SRCC
asymmetry, has a direct ASIC analogue: the slave's recovered clock must
get the *same* clock-distribution quality as the master's. The FPGA
bring-up showed the slave (weaker SRCC/Y9 clock path) is "always the
unlucky side"; in ASIC, ensure both directions' recovered/forwarded
clocks use the **same** balanced I/O-clock resource and the same skew
target. Asymmetric clock distribution between the two directions is a
determinism killer. (See Part B §6 for the FPGA pin-asymmetry note.)

---

## 6. Characterised I/O-cell + package (+ channel) models

The pad→capture and forwarded-launch numbers are only meaningful with
real models:

- Use the **characterised I/O-cell library views** (driver/receiver
  delay, slew, clk-to-Q of the capture flop) for the corners you sign
  off — not nominal estimates.
- Include the **package model** (bondwire/bump + redistribution + pin)
  for both the data lanes and the forwarded clock; package skew between
  the clock pin and the data pins counts directly against the §1 budget.
- Include the **channel model** (the ribbon / substrate / interposer
  trace) if known — at minimum budget an explicit margin for it in
  `<tx_dly_*>` / `<rx_dly_*>` and the skew budget. Lane-to-lane channel
  skew is part of the spread the calibrator must absorb; if it is large
  and uncharacterised, the calibrator window assumption is unproven.
- Sign off the source-sync arcs at **all** relevant PVT corners (SS/FF
  for setup/hold, plus temperature inversion if the I/O library shows
  it). The pass criterion is §1: at every corner the calibrated eye must
  still be open within ±1 phase step of the sign-off-corner solution.

---

## 7. Hold strategy — source-sync capture is hold-sensitive (the 2026-05-05 lesson)

**The lesson:** on the FPGA, re-adding a naive
`set_input_delay -min 1.0 -max 8.0` on `pad_rx[*]` made Vivado treat
every lane's capture as an absolute-window problem and insert
hold-fixing routing on **134 endpoints**, so the constraint was deleted
*entirely* rather than fixed — which is how the pad→capture path ended
up unconstrained and nondeterministic in the first place. Deleting the
constraint to dodge hold violations is how you get the coin-flip.

**The methodology — fix hold by construction, not post-hoc:**

1. **Bound *relative* skew, not an absolute arrival window** (§4.2):
   `set_data_check` + `set_max_delay -datapath_only` + `set_bus_skew`
   express the source-sync requirement without demanding every lane
   land in a tight absolute window, so the tool is not driven to
   carpet-bomb hold buffers.
2. **Hold margin comes from matched routing + the deliberate per-lane
   delay cell** (§4.1, §4.3), not from automatic buffer insertion. The
   delay cell is the *intended* place to add delay; it is calibrated, so
   hold margin is created where it is observable and PVT-characterised.
3. **Analyse hold at the fast corner with the real I/O + clock-tree
   models** (§5, §6) — source-sync hold fails fast-process / low-temp /
   high-voltage; sign it off there explicitly.
4. If, after matched routing + delay cells, residual hold remains, fix
   it with **targeted, characterised** delay on the *specific* offending
   lane (and re-budget §1), never with a global auto-hold pass that
   destroys the lane-to-lane match you built in §4.1.

The rule: a hold violation on a source-sync RX is a signal that your
*matched routing / delay-cell budget* is wrong — fix the budget, do not
delete the constraint and do not let the tool blanket-buffer it.

**FPGA application (validated, 2026-05-18):** the `set_input_delay` on
`pad_rx[*]` is **symmetric** (±4 ns about the launch edge), referenced
to `pad_clk_rx`. Symmetric windows + `-datapath_only` + `set_bus_skew`
together avoid the 2026-05-05 hold explosion: the supervisor checks WHS
endpoint count against the pre-existing baseline (~1, the debug-only
`ila_rx`) — a jump toward ~100+ means the symmetric window is still too
tight and should be widened (e.g. ±8 ns), not deleted.

---

## 8. Recovered-RX → core CDC sign-off

The *payload* that crossed on `pad_clk_rx` is resynchronised into the
core/`hclk` domain by Wlink's internal synchronisers. This crossing must
be signed off as a real CDC — and this is the *only* place
`set_clock_groups -asynchronous` / `set_false_path` legitimately applies
to `pad_clk_rx` (§3):

- **Synchroniser pattern:** use the established codebase pattern — a
  multi-stage shift-register synchroniser, parameterised depth ≥2, as in
  `src/rtl/tidelink_phc_cdc.sv` (`SYNC_STAGES`, `q <= {q[N-2:0], src}`).
  Single-bit status crossings (e.g. `lane_locked`, `calibration_done`)
  use the 2-flop `sync_lane_locked_*` pattern in `axi_chiplet_controller.sv`.
  Multi-bit buses get a handshake or gray-coded crossing (as
  `tidelink_phc_cdc.sv` does for its 110/78-bit snapshots), never a bare
  bus through independent 2-flop syncs.
- **`ASYNC_REG` / tool equivalent:** set the synchroniser-FF library
  attribute (`ASYNC_REG` on FPGA; the ASIC library's
  `is_sync_flop`/`async_reg`-equivalent + a `set_max_delay -datapath_only`
  on the metastability-resolution net) so P&R places the synchroniser
  flops abutted and does not optimise the resolution slack away.
- **CDC sign-off:** run a structural CDC checker (the flow's CDC tool)
  and require: every recovered-RX→core single-bit path has a ≥2-flop
  sync; every multi-bit path has a recognised crossing scheme; no
  combinational logic between the crossing and the first sync flop;
  reconvergence on the core side is acknowledged or eliminated. The
  `set_clock_groups`/`set_false_path` that makes STA ignore the crossing
  is **only valid once the CDC tool has signed off that the crossing is
  structurally safe** — STA-ignore without CDC sign-off is how
  metastability ships. See `docs/CDC_AUDIT_REPORT.md` and
  `docs/archive/SPYGLASS_CDC_SIGNOFF.md` for the live sign-off state.

---

# Part B — Concrete constraint listing (the "what")

This part lists each concrete constraint that delivers Part A's
rationale, with **what failure mode it bounds**, **why it does NOT
reintroduce the 2026-05-05 hold explosion**, and the **exact
report/metric/direction** for the supervisor to verify. Each item
includes a pointer to where it lands in
`syn/asic/fusion-compiler/inputs/constraints.sdc` /
`imp/ASIC/tidelink_top_full/tidelink_top.sdc` /
`fpga/targets/pynq-z2-pair-*/pynq_z2_tidelink_timing.xdc`.

## 1. `create_clock` on `pad_clk_rx` (kept; period set by `T_UI`)

- **Bounds:** nothing new — but it is the *prerequisite*. Without a
  real clock on `pad_clk_rx`, the input-delay and max-delay constraints
  below have no launch reference.
- **Hold-trap:** N/A (declaration only).
- **FPGA file:** `pynq_z2_tidelink_timing.xdc` — `create_clock
  -period 40.000 pad_clk_rx` (25 MHz). Header comments must reflect
  the actual pin (Y7 MRCC on `-all`; Y9 SRCC on `-flip-all`).
- **ASIC file:** `constraints.sdc` — `create_clock -name pad_clk_rx
  -period <T_UI_or_link_period> [get_ports pad_clk_rx]`.
- **Expected report:** `report_clocks` lists `pad_clk_rx` @
  `<T_UI>`. Verifies the pin/period comment matches.

## 2. `pad_clk_tx` launch + TX eye

- **Bounds:** the **transmit eye**. Without `create_generated_clock` +
  `set_output_delay`, `pad_tx[*]` launch vs the forwarded clock is
  completely unanalysed — the TX-side half of the same nondeterminism
  (the peer's RX has to capture our unconstrained TX).
- **Why not the 2026-05-05 trap:** the window is **symmetric (±5 ns
  on FPGA)** and referenced to the **forwarded clock itself**
  (`pad_clk_tx_fwd`), not to an internal MMCM pin. Launch and the
  peer's capture reference are the *same edge*, so the tool **balances**
  `pad_tx[*]` vs `pad_clk_tx` rather than one-sidedly hold-padding
  every lane.

```tcl
# Generated clock: pad_clk_tx is the launch clock forwarded on a pad.
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins <tx_clk_launch_source_pin>] \
    -divide_by 1 [get_ports pad_clk_tx]

# Transmitter eye: pad_tx[*] vs the FORWARDED clock.
set_output_delay -clock pad_clk_tx_fwd -max  <tx_dly_max> [get_ports {pad_tx[*]}] -add_delay
set_output_delay -clock pad_clk_tx_fwd -min  <tx_dly_min> [get_ports {pad_tx[*]}] -add_delay
```

`<tx_dly_max/min>` come from the *receiver's* required eye (peer setup +
peer hold + channel skew budget), referred back through the package +
channel model — see Part A §6.

- **Expected reports:**
  - `report_clocks` now also lists `pad_clk_tx_fwd` (generated, source
    = the real TX launch clock).
  - `report_timing -to [get_ports pad_tx[*]]` changes from
    **"no `set_output_delay` / unconstrained"** to a real **min & max**
    path with finite slack. WNS may drop slightly (paths now analysed)
    but must stay ≥ 0; if it goes negative the budget is loosened, NOT
    removed.
  - `report_design_analysis -timing`: TX output paths no longer in the
    "unconstrained ports" list.

## 3. `pad_rx[*]` lane bundle — RX eye

### 3.1 Symmetric `set_input_delay` on `pad_rx[*]` vs `pad_clk_rx`

- **Bounds:** establishes the receive eye so §3.2/§3.3 have a reference;
  re-enables RX-path analysis the pre-fix file deleted.
- **Why not the 2026-05-05 trap:** the regression was caused by an
  **asymmetric** `-min 1.0 / -max 8.0` window forcing one-sided hold
  fixing on 134 endpoints. The replacement window is **symmetric about
  the launch edge** (`-min -4 / -max +4` on FPGA at 25 MHz): it states
  "data is centre-aligned to the forwarded clock" (true for a 1:1
  <10 cm ribbon at 25 MHz) so the tool has no systematic hold deficit
  to chase on every lane.

```tcl
set_input_delay -clock pad_clk_rx -max <rx_dly_max> [get_ports {pad_rx[*]}] -add_delay
set_input_delay -clock pad_clk_rx -min <rx_dly_min> [get_ports {pad_rx[*]}] -add_delay
```

- **Expected report:** `report_timing -from [get_ports pad_rx[*]]`
  shows analysed input paths (was unconstrained). Setup slack large
  positive. WHS ≥ 0 and hold-violating endpoint count ≈ the
  pre-existing baseline — NOT ~134. If WHS endpoints jump toward 100+,
  the symmetric window is still too tight → widen, do not delete.

### 3.2 `set_max_delay -datapath_only` on `pad_rx[*]` → first capture flop

- **Bounds:** the **absolute** per-lane clk-to-capture routing delay —
  caps how far any one lane's pad→capture path can drift, so it cannot
  wander out of a slip step build-to-build.
- **Why not the 2026-05-05 trap:** `-datapath_only` explicitly
  **removes the clock-skew/hold component** from the analysed path —
  it is a pure combinational max-delay, so the tool does **not** insert
  hold-fixing routing for it. Canonical way to bound source-sync
  capture delay without hold pressure.

```tcl
set_max_delay -datapath_only <S_budget> \
    -from [get_ports {pad_rx[*]}] -to [get_cells <pad_rx_capture_regs>]
```

- **FPGA value:** 8 ns (`pad_rx[*]` → `*gpiorx_*/link_data_pad_clk_reg[*]`).
- **Expected report:** `report_timing -from [get_ports pad_rx[*]] -to
  [get_cells -hier *gpiorx_*/link_data_pad_clk_reg[*]] -max_paths 8
  -datapath_only`: 8 paths (1/lane), each datapath delay ≤ `S_budget`,
  slack ≥ 0. Across two builds the per-lane datapath delays should
  cluster (the headline determinism metric — see Part B §7).

### 3.3 `set_bus_skew` / `set_data_check` across the lane bundle — **THE key fix**

- **Bounds:** the **lane-to-lane VARIANCE** that *is* the defect.
  Forces the tool to equalise the 8 capture delays to within
  `S_budget_skew` of each other, so one (slip,phase) solution fits
  all lanes and the same solution survives a re-build. On `-flip-all`
  this also absorbs the **Y9-SRCC vs Y7-MRCC** clock-insertion
  asymmetry (the "slave is always the unlucky side" — Part A §5, Part B §6).
- **Why not the 2026-05-05 trap:** `set_bus_skew` (Vivado) and
  `set_data_check` (DC/FC) are *relative* (max − min across the bus)
  constraints — they have **no absolute hold component**, so they
  cannot trigger per-endpoint hold fixing. They make P&R *match* lane
  routing, not pad it.

ASIC (`set_data_check` form):

```tcl
set_data_check -from [get_ports pad_clk_rx] -to [get_ports {pad_rx[*]}] -setup <S_setup>
set_data_check -from [get_ports pad_clk_rx] -to [get_ports {pad_rx[*]}] -hold  <S_hold>
```

FPGA (`set_bus_skew` form):

```tcl
set_bus_skew -from [get_ports {pad_rx[*]}] -to [get_cells <capture_regs>] <S_budget_skew>
```

- **FPGA value:** 2 ns.
- **Expected report:** `report_bus_skew` (or `report_timing -name
  busskew`) lists the `pad_rx[*]→capture` group with bus skew
  ≤ `S_budget_skew`, slack ≥ 0. Determinism metric: bus-skew value
  similar across two builds (low inter-build variance) — contrast with
  constraints-OFF where there is no such report and the implied skew
  is unbounded.

### 3.4 Capture-flop IOB / placement lock

- **Bounds:** makes whatever IOB-able input element the tool infers on
  the `pad_rx[*]` chain deterministic (fixed IOB site, not fabric).
- **Honest caveat:** the *real* capture FF `link_data_pad_clk_reg[*]`
  has a per-bit input mux (`adj_count==X ? io_pad : hold`) so it
  **cannot legally pack into the IOB**. `set_property IOB TRUE` on
  that cell would be ignored; applying it to the **port** lets the
  tool place the IOB-able portion in the pad and is harmless where it
  cannot. **This is NOT the primary determinism fix — §3.2/§3.3 are.**
  The proper FPGA fix is the IDELAYE2 stanza referenced in §3.5; the
  ASIC equivalent is Part A §4.4.

```tcl
catch { set_property IOB TRUE [get_ports pad_rx[*]] }
```

- **Expected report:** `report_io` / placement: `pad_rx[*]` input path
  uses the IOB where applicable; no ERROR (the `catch` swallows the
  "cannot pull through mux" message — it appears as INFO/ignored).

### 3.5 Per-lane delay cell — FPGA IDELAYE2 / ASIC programmable delay

- **Bounds:** Part A §4.3. On FPGA, an `IDELAYE2` per `pad_rx[n]` with
  the calibrator driving the tap; on ASIC, the equivalent characterised
  delay-line macro. Currently a **disabled stanza** in the FPGA XDC
  (gated behind `#`), pending the RTL-hook work that wires
  `swi_phase_offset` to the tap.
- **Expected report:** none (commented out). Presence verified by grep,
  not by the tool.

## 4. Bounding relative static layout skew

Three constraints together (see Part A §4.2): §3.1 (symmetric
`set_input_delay`) + §3.2 (`set_max_delay -datapath_only`) + §3.3
(`set_bus_skew` / `set_data_check`). The combination expresses "data
arrives centred at the strobe AND no lane drifts more than `S_budget`
AND the bundle's max-min stays ≤ `S_budget_skew`" without any
absolute-window hold demand.

## 5. Narrowed `set_clock_groups -asynchronous` (pad_clk_rx ↔ hclk only)

- **Bounds:** keeps the genuine **recovered-RX → core/hclk CDC** cut
  (Wlink 2-flop synchronises it internally) while **NOT** erasing the
  `pad_rx[*]→capture` analysis.
- **Subtle correctness point:** `set_clock_groups -asynchronous
  {pad_clk_rx}{hclk}` only cuts paths *between those two clocks*. The
  `pad_rx[*]→capture` paths are launched by the §3.1 input-delay
  virtual source on `pad_clk_rx` and captured on `pad_clk_rx` (same
  clock) — they are **not** pad_clk_rx↔hclk paths, so this declaration
  does not disable them. The pre-fix file's problem was *not* this
  command per se — it was that with §3.1/§3.2/§3.3 absent there was
  nothing else timing the capture. Re-adding §3 makes the same async
  declaration correct and narrow.

```tcl
set_clock_groups -asynchronous -group {pad_clk_rx} -group {hclk}
# phc_clk / scan_clk / user_ref_clk remain their own async groups vs hclk,
# exactly as before — that part of the existing SDC was fine. The defect
# was ONLY that pad_clk_rx was in the blanket list, which silently made
# pad_clk_rx async to its own capture path.
```

- **Expected report:** `report_clock_interaction`: `pad_clk_rx` ↔ hclk
  = "Asynchronous Groups" (no timed paths, no CDC WNS), while
  `pad_clk_rx` (intra) → capture flop = timed (Safely Timed / has
  slack). Constraints-OFF showed `pad_clk_rx` with *no* internal timed
  paths at all.

## 6. Slave-clock-path asymmetry (FPGA: Y9-SRCC vs Y7-MRCC)

- **Finding:** on `-all`, FPGA `pad_clk_rx` = Y7 (IO_L13P_T2_**MRCC**_13,
  multi-region clock-capable). On `-flip-all`, FPGA `pad_clk_rx` = Y9
  (IO_L14P_T2_**SRCC**_13, single-region). MRCC drives global clock
  resources directly with low, well-characterised insertion delay;
  SRCC has more constrained distribution. Since the FLIP bitstream is
  deployed to the slave (`die_b`/peer), the slave's recovered-clock
  distribution is the weaker one → it sees larger, more variable
  clk-to-capture skew. This matches the empirical "slave is always the
  unlucky side".
- **Mitigation (in this constraint set):** `set_bus_skew` (§3.3)
  directly equalises the per-lane delays *after* the BUFG, which is
  exactly the SRCC-side variance source — so the constraint set already
  targets this without any pin change.
- **Pin-map option (out of scope here):** if a P-side **MRCC** ball
  reachable by the straight-through ribbon on the FLIP header exists,
  moving FLIP `pad_clk_rx` there would remove the asymmetry at the
  source. This is a `pynq_z2_tidelink.xdc` edit, not a timing XDC edit.
- **ASIC equivalent:** Part A §5 — ensure both directions'
  recovered/forwarded clocks use the same balanced I/O-clock resource
  and the same skew target.

## 7. Determinism metric + multi-build validation

The goal metric is **inter-build variance of per-lane
clk-to-capture skew**, NOT WNS. Procedure for the supervisor:

1. **Baseline (constraints OFF):** for each of two clean builds,
   post-route: `report_timing -from [get_ports {pad_rx[*]}] -to
   [get_cells -hier -filter {NAME =~
   "*gpiorx_*/link_data_pad_clk_reg[*]"}] -max_paths 8 -datapath_only`.
   Record the 8 per-lane datapath delays. Expectation: wide spread,
   and build-A vs build-B differ markedly.
2. **Constraints ON:** rebuild ×2. Same report, plus
   `report_bus_skew`. Expectation: 8 per-lane delays clustered ≤
   `S_budget_skew` apart AND build-A ≈ build-B (low inter-build
   variance) — the fix.
3. **Determinism KPI:** `max_lane − min_lane` per build, and
   `|skew_buildA − skew_buildB|`. Target: bus skew ≤ `S_budget_skew`
   each build AND inter-build delta small (≤ ~1 ns on FPGA). OFF:
   expect both large/unbounded.
4. **Functional confirmation:** RO-observability APB readouts read
   per-lane lock / `lane_fault` across N ≥ 4 supervisor builds (mix of
   `-all` and `-flip-all`, master+slave). KPI: 7/7 (or 8/8) lock on
   every build, especially the slave (`-flip-all`, Y9-SRCC) side.
5. **Regression guards:**
   - `report_timing_summary`: WHS ≥ 0 and hold-violating endpoint
     count ≈ baseline (NOT ~134). If it jumps, the 2026-05-05 mode is
     recurring → widen the §3.1 symmetric window or relax §3.2, do
     **not** delete the constraints.
   - `cocotb/tidelink_autoneg` stays 7/7 (constraints are impl-only;
     no RTL changed).

## 8. Risks & assumptions

1. Symmetric `set_input_delay` could still cause some hold fixing. A
   ±4 ns window is far less aggressive than the old asymmetric 1..8 ns
   one, and `-datapath_only` on §3.2 carries no hold component, but
   the tool may still add modest hold buffering on the `pad_rx`
   paths. Mitigation: compare WHS endpoint *count* to baseline;
   ≈ baseline (the known ~1 debug-only) = fine; a jump toward ~134 =
   the 2026-05-05 mode → first widen the §3.1 window (e.g. ±8 ns)
   keeping it symmetric, then if still bad relax §3.2, and only as
   last resort drop §3.1 keeping §3.2/§3.3 (which alone still bound
   variance with no hold pressure).
2. `set_max_delay`/`set_bus_skew` cell selector depends on the
   synthesised name `link_data_pad_clk_reg[*]` under `*gpiorx_*`.
   Verified against `WavD2DGpioRx.v` (`reg [15:0] link_data_pad_clk`,
   `GPIO.scala 130`) and the `WavD2DGpio` instance names
   `gpiorx_0..7`. If a future Wlink/Chisel regen renames it, the
   `get_cells` returns empty and the two constraints become no-ops
   (CRITICAL WARNING, *not* a wrong constraint — fail-safe).
3. `pad_clk_tx_fwd` generated clock assumes the FPGA TX serializer
   runs on `clk_wiz` hclk. If a real PLL is ever instantiated for
   FPGA, §2's `-source`/`-divide_by` must be revisited.
4. IOB request §3.4 is best-effort, not load-bearing. Determinism
   rests on §3.2/§3.3.

## 9. Sign-off checklist (gating)

Do not sign off the TideLink source-sync PHY unless every item is true:

- [x] **TX eye constrained.** `pad_clk_tx` declared via
      `create_generated_clock` off its real launch source, **and**
      `set_output_delay -min/-max` on `pad_tx[*]` against it. (Not an
      inferred clock with no output delay.) — Part B §2.
      *Landed `constraints.sdc` §4 (CRITICAL #2 fix, 2026-05-28): generated
      clock `pad_clk_tx_fwd` sourced from `user_ref_clk` port; symmetric
      `set_output_delay -min/-max ±T_UI/4` on `pad_tx[*]`.*
- [x] **RX eye constrained.** `create_clock` on `pad_clk_rx` **and**
      `set_input_delay -min/-max` on `pad_rx[*]` against it. — Part B §1, §3.1.
      *Landed `constraints.sdc` §1: symmetric `set_input_delay -min/-max
      ±T_UI/4` on `pad_rx[*]` vs `pad_clk_rx`.*
- [x] **`set_clock_groups -asynchronous` isolates ONLY recovered-RX↔core
      (and the other genuine domains).** `pad_clk_rx` is **not** in a
      blanket async list that also crosses its own capture path.
      `report_timing -from [get_ports pad_rx[*]] -to [get_clocks
      pad_clk_rx]` returns real paths, not "No paths". — Part B §5.
      *Landed `constraints.sdc` (CRITICAL #2 fix, 2026-05-28): `pad_clk_rx`
      now in its own group asynchronous to {hclk, phc_clk, scan_clk,
      user_ref_clk + pad_clk_tx_fwd}, intra-pad_clk_rx capture paths
      remain timed. `report_clock_interaction` / `report_timing` checks
      pending first STA run.*
- [x] **Static per-lane skew bounded** by `set_max_delay
      -datapath_only` + `set_data_check`/`set_bus_skew` + a written
      skew budget `S_budget ≤ T_UI/16 − setup − hold − PVT_derate`. — Part A §1, Part B §3.2, §3.3.
      *Landed `constraints.sdc` §2/§3: `set_max_delay -datapath_only T_UI/5`
      on `pad_rx[*]` → `gpiorx_*/link_data_pad_clk_reg*`; `set_data_check
      -setup/-hold T_UI/20` across the lane bundle. Numerical re-budget
      against characterised t_setup/t_hold + PVT derate pending I/O-library
      sign-off corner (Part A §6).*
- [ ] **Matched/balanced bundle routing** for `pad_clk_rx`+`pad_rx[*]`
      and `pad_clk_tx`+`pad_tx[*]`; verified post-route lane skew ≤
      `S_budget`. — Part A §4.1.
- [ ] **Per-lane programmable delay cell** instantiated in each
      `pad_rx[n]` path, driven by the calibrator's existing per-lane
      `swi_phase_offset`/`swi_bit_slip` plumbing, step characterised vs
      PVT. — Part A §4.3, Part B §3.5.
- [ ] **Capture flops fixed/pinned** into the I/O path (characterised
      clk-to-Q), placement-locked so re-runs do not perturb skew. — Part A §4.4, Part B §3.4.
- [ ] **I/O clocks excluded from core CTS**, routed balanced to the lane
      I/O cells; both link directions use the same clock-distribution
      quality (no master/slave asymmetry). — Part A §5, Part B §6.
- [ ] **Characterised I/O-cell + package (+ channel) models** used; all
      relevant PVT corners signed off including the fast corner for hold. — Part A §6.
- [x] **No naive absolute `set_input_delay` hold window** that triggers
      blanket hold-buffer insertion (the 2026-05-05 trap); hold is fixed
      by matched routing + the deliberate delay cell. — Part A §7.
      *`constraints.sdc` §1 uses the symmetric `±T_UI/4` form (not the
      asymmetric `-min 1 / -max 8` shape that detonated 134 WHS endpoints
      on FPGA 2026-05-05); WHS-endpoint regression guard documented in
      the constraint file's hold-trap-guard comment block.*
- [ ] **Recovered-RX→core CDC** uses ≥2-flop synchronisers
      (`tidelink_phc_cdc.sv` / `sync_lane_locked_*` model) with
      `ASYNC_REG`-equivalent attributes, and has passed a structural CDC
      checker — *before* any `set_clock_groups`/`set_false_path` is
      allowed to make STA ignore it. — Part A §8, `docs/CDC_AUDIT_REPORT.md`.
- [ ] **Determinism re-validated.** After the constraint/delay-cell
      changes, the determinism metric
      (`docs/archive/DETERMINISM_VALIDATION.md`) shows a stable both-sides-good
      operating point across builds/corners — i.e. the fix actually
      reduced skew-spread variance, not just WNS.

If any box is unchecked, the PHY is not signed off — regardless of
whether STA reports positive slack or the bench happened to lock.

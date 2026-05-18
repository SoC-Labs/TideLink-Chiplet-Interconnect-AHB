# ASIC Source-Synchronous Constraint Guidance — TideLink GPIO PHY

**Audience:** a future agent taking the TideLink Wav Wlink GPIO PHY to an
ASIC target (Design Compiler / Fusion Compiler / equivalent STA + P&R).

**Status:** normative reference. Every claim here is required to be
correct for a *source-synchronous chiplet PHY*; treat the checklist at
the end as sign-off gating.

**Cross-references**
- FPGA root-cause brief: `/tmp/timing_determinism_investigation_brief.md`
  (the "ASIC constraint guidance" section is the seed of this document;
  this expands it into an actionable sign-off reference).
- The runtime calibrator whose finite window the constraints must keep
  layout inside: `src/rtl/tidelink_phy_align_calibrator.sv`.
- The lock detector that defines what "locked" means:
  `src/rtl/tidelink_lane_checker.sv` (`LOCK_THRESH=16` consecutive
  matches).
- The canonical multi-stage synchroniser pattern used in this codebase:
  `src/rtl/tidelink_phc_cdc.sv` (`SYNC_STAGES` shift-register chain) —
  this is the model for the recovered-RX→core CDC sign-off.
- The existing (deficient) ASIC SDC overlay that this document tells you
  how to repair: `syn/asic/fusion-compiler/inputs/constraints.sdc`.
- Determinism measurement of any candidate fix:
  `docs/DETERMINISM_VALIDATION.md` +
  `pynq_host/scripts/determinism_metric.sh`.

---

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
calibrator is gambling, exactly as the FPGA bring-up is today.

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
constraint below exists to enforce.

---

## 2. Forwarded-clock methodology (TX eye and RX eye)

The PHY has two source-synchronous interfaces. Constrain **both** as
forwarded-clock, not async.

### 2.1 Transmit side — `pad_clk_tx` + `pad_tx[7:0]`

`pad_clk_tx` is launched from the local core/link domain and forwarded
off-die alongside the data. Model it as a **generated clock** off the
launching clock, then constrain the data eye against it:

```tcl
# Generated clock: pad_clk_tx is the launch clock forwarded on a pad.
# Derive it from whatever core/link net actually toggles the TX clock
# output (the Wlink TX router clock division). Use the real source pin.
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins <tx_clk_launch_source_pin>] \
    -divide_by 1 [get_ports pad_clk_tx]

# Transmitter eye: constrain pad_tx[*] relative to the FORWARDED clock,
# not relative to the internal core clock. This is what tells STA/P&R
# what the receiver will see and forces matched TX launch timing.
set_output_delay -clock pad_clk_tx_fwd -max  <tx_dly_max> [get_ports {pad_tx[*]}] -add_delay
set_output_delay -clock pad_clk_tx_fwd -min  <tx_dly_min> [get_ports {pad_tx[*]}] -add_delay
```

`<tx_dly_max/min>` come from the *receiver's* required eye (peer setup +
peer hold + channel skew budget), referred back through the package +
channel model — see §5. The current ASIC SDC comment "pad_clk_tx is
generated by the partition … tools will infer it … No create_clock here"
is **wrong for sign-off**: an inferred generated clock with **no
`set_output_delay`** means the TX eye is completely unconstrained — the
same defect as the disabled FPGA `set_output_delay`. You must add the
explicit generated clock *and* the output-delay pair.

### 2.2 Receive side — `pad_clk_rx` + `pad_rx[7:0]`

`pad_clk_rx` is recovered from the peer's forwarded TX clock. It is a
real, primary timed clock at the RX pads:

```tcl
create_clock -name pad_clk_rx -period <T_UI_or_link_period> [get_ports pad_clk_rx]

# Receiver eye: constrain pad_rx[*] against the recovered clock so STA
# analyses the pad->capture-flop arc. min/max define the eye the
# calibrator will then centre within.
set_input_delay -clock pad_clk_rx -max <rx_dly_max> [get_ports {pad_rx[*]}] -add_delay
set_input_delay -clock pad_clk_rx -min <rx_dly_min> [get_ports {pad_rx[*]}] -add_delay
```

Note: the *absolute* numeric eye does not need to be perfectly centred —
the calibrator centres it at runtime. The point of `set_input_delay`
here is **not** to demand a centred capture; it is to make STA *analyse
and report* the pad→capture path so P&R has an objective and so you can
measure the per-lane skew spread (§6). Picking the receiver eye as the
peer's worst-case launch window is sufficient and correct.

---

## 3. `set_clock_groups -asynchronous`: isolate the CDC, do not erase
pad→capture

This is the single most important — and currently most violated — point.

**The existing ASIC SDC is broken in exactly the FPGA way.**
`syn/asic/fusion-compiler/inputs/constraints.sdc` does:

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
The `set_input_delay` added later in the same file is then **dead** —
there is no timed launch/capture relationship left for it to bound.

**The correct structure (two distinct relationships, treated
differently):**

1. **`pad_clk_rx` → `pad_rx[*]` capture flops** = a *source-synchronous*
   relationship. It MUST stay timed. Do **not** put `pad_clk_rx` in an
   async group with the *capture* clock. The data and the clock that
   captures it are forwarded together; their relative timing is the
   whole point and must be analysed and bounded (§4).

2. **recovered-RX domain → core/`hclk` domain** = the *genuine* CDC. The
   payload that crossed on `pad_clk_rx` is resynchronised into the core
   clock by Wlink's internal synchronisers. *This* crossing — and only
   this crossing — is what `set_clock_groups -asynchronous` (or targeted
   `set_false_path`) is for.

So the fix is:

```tcl
# Async ONLY between the recovered RX clock and the core/link clock
# (the true CDC, resynchronised in RTL). pad_clk_rx is NOT lumped with
# everything; the pad_rx[*] -> capture arc stays timed against
# pad_clk_rx (see create_clock + set_input_delay in §2.2).
set_clock_groups -asynchronous \
    -group {pad_clk_rx} \
    -group {hclk}

# phc_clk / scan_clk / user_ref_clk remain their own async groups vs the
# core, exactly as before — that part of the existing SDC was fine. The
# defect is ONLY that pad_clk_rx was in the same blanket list, which
# also (silently) made pad_clk_rx async to its own capture path.
```

If a single multi-group `set_clock_groups` is used, the rule is: the
recovered RX clock may be asynchronous to the *core* clock, but the
`pad_rx[*]` capture registers must be clocked by (and analysed against)
`pad_clk_rx` — keep the capture stage in the `pad_clk_rx` group so the
pad→capture arc is never crossed by an async boundary. Verify after
elaboration with `report_timing -from [get_ports pad_rx[*]] -to
[get_clocks pad_clk_rx]` (or `-through` the capture flops): if it returns
"No paths" you have re-created the defect.

---

## 4. Bounding STATIC layout skew so the calibrator window is a
guarantee, not luck

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
SDC constraints below *enforce and verify* it but routing is what
actually delivers it.

### 4.2 Relative skew constraint, not an absolute hold window

Do **not** translate the receiver eye into a tight absolute
`set_input_delay -min/-max` and let the tool hold-fix every lane
independently — that is precisely the 2026-05-05 FPGA failure (§7).
Instead bound the *relative* lane-to-lane and clk-to-data skew:

```tcl
# Equalise per-lane pad -> capture delay (attacks the variance that the
# calibrator cannot absorb, without an absolute-window hold explosion).
set_max_delay -datapath_only <S_budget> \
    -from [get_ports {pad_rx[*]}] -to [get_cells <pad_rx_capture_regs>]

# Source-sync data-vs-clock check: bound how far each pad_rx[n] may move
# relative to pad_clk_rx (both setup and hold side of the check).
set_data_check -from [get_ports pad_clk_rx] -to [get_ports {pad_rx[*]}] \
    -setup <S_setup>
set_data_check -from [get_ports pad_clk_rx] -to [get_ports {pad_rx[*]}] \
    -hold  <S_hold>
```

`set_max_delay -datapath_only` excludes clock skew/latency from the
bound so you are constraining the *data net delay spread* directly,
which is what equalises lanes. `set_data_check` is the source-sync
primitive: it expresses "this data must be stable around this strobe by
S_setup/S_hold" without imposing an absolute arrival window, so it does
not provoke blanket hold-buffer insertion. The chosen numbers derive
from §1: total per-lane spread (data mismatch + clock mismatch +
PVT derate) ≤ one phase step minus capture setup/hold.

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
arc, not build-varying fabric. ASIC equivalent: place the `pad_rx[*]`
first-capture flops in (or immediately abutting) the I/O cell / pad ring
with a fixed, characterised clk-to-Q and a fixed clock-to-flop route, so
the pad→capture delay is dominated by the characterised I/O path and not
by P&R-varying internal routing. Pin these with placement constraints /
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
determinism killer.

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

## 7. Hold strategy — source-sync capture is hold-sensitive (the
2026-05-05 lesson)

**The lesson:** on the FPGA, re-adding a naive
`set_input_delay -min 1.0 -max 8.0` on `pad_rx[*]` made Vivado treat
every lane's capture as an absolute-window problem and insert
hold-fixing routing on **134 endpoints**, so the constraint was deleted
*entirely* rather than fixed — which is how the pad→capture path ended
up unconstrained and nondeterministic in the first place. Deleting the
constraint to dodge hold violations is how you get the current coin-flip.

**The ASIC methodology — fix hold by construction, not post-hoc:**

1. **Bound *relative* skew, not an absolute arrival window** (§4.2):
   `set_data_check` + `set_max_delay -datapath_only` express the
   source-sync requirement without demanding every lane land in a
   tight absolute window, so the tool is not driven to carpet-bomb hold
   buffers.
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
  The brief calls out the 2-flop `sync_lane_locked_*` pattern in
  `axi_chiplet_controller.sv` (Wlink/chiplet-controller submodule) as the
  reference for single-bit status crossings (e.g. `lane_locked`,
  `calibration_done`) into the core domain — keep that discipline; every
  single-bit control/status that crosses recovered-RX→core gets a ≥2-flop
  synchroniser, multi-bit buses get a handshake or gray-coded crossing
  (as `tidelink_phc_cdc.sv` does for its 110/78-bit snapshots), never a
  bare bus through independent 2-flop syncs.
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
  metastability ships.

---

## 9. Sign-off checklist (gating)

Do not sign off the TideLink source-sync PHY unless every item is true:

- [ ] **TX eye constrained.** `pad_clk_tx` declared via
      `create_generated_clock` off its real launch source, **and**
      `set_output_delay -min/-max` on `pad_tx[*]` against it. (Not an
      inferred clock with no output delay.)
- [ ] **RX eye constrained.** `create_clock` on `pad_clk_rx` **and**
      `set_input_delay -min/-max` on `pad_rx[*]` against it.
- [ ] **`set_clock_groups -asynchronous` isolates ONLY recovered-RX↔core
      (and the other genuine domains).** `pad_clk_rx` is **not** in a
      blanket async list that also crosses its own capture path.
      `report_timing -from [get_ports pad_rx[*]] -to [get_clocks
      pad_clk_rx]` returns real paths, not "No paths". (Repair
      `syn/asic/fusion-compiler/inputs/constraints.sdc` accordingly —
      currently it lumps `pad_clk_rx` with hclk/phc/scan/user_ref.)
- [ ] **Static per-lane skew bounded** by `set_max_delay
      -datapath_only` + `set_data_check` + a written skew budget
      `S_budget ≤ T_UI/16 − setup − hold − PVT_derate` (§1).
- [ ] **Matched/balanced bundle routing** for `pad_clk_rx`+`pad_rx[*]`
      and `pad_clk_tx`+`pad_tx[*]`; verified post-route lane skew ≤
      `S_budget`.
- [ ] **Per-lane programmable delay cell** instantiated in each
      `pad_rx[n]` path, driven by the calibrator's existing per-lane
      `swi_phase_offset`/`swi_bit_slip` plumbing, step characterised vs
      PVT.
- [ ] **Capture flops fixed/pinned** into the I/O path (characterised
      clk-to-Q), placement-locked so re-runs do not perturb skew.
- [ ] **I/O clocks excluded from core CTS**, routed balanced to the lane
      I/O cells; both link directions use the same clock-distribution
      quality (no master/slave asymmetry).
- [ ] **Characterised I/O-cell + package (+ channel) models** used; all
      relevant PVT corners signed off including the fast corner for hold.
- [ ] **No naive absolute `set_input_delay` hold window** that triggers
      blanket hold-buffer insertion (the 2026-05-05 trap); hold is fixed
      by matched routing + the deliberate delay cell.
- [ ] **Recovered-RX→core CDC** uses ≥2-flop synchronisers
      (`tidelink_phc_cdc.sv` / `sync_lane_locked_*` model) with
      `ASYNC_REG`-equivalent attributes, and has passed a structural CDC
      checker — *before* any `set_clock_groups`/`set_false_path` is
      allowed to make STA ignore it.
- [ ] **Determinism re-validated.** After the constraint/delay-cell
      changes, the determinism metric
      (`docs/DETERMINISM_VALIDATION.md`) shows a stable both-sides-good
      operating point across builds/corners — i.e. the fix actually
      reduced skew-spread variance, not just WNS.

If any box is unchecked, the PHY is not signed off — regardless of
whether STA reports positive slack or the bench happened to lock.

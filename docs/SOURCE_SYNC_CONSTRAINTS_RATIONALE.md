# TideLink GPIO-PHY Source-Synchronous Constraints — Rationale & Validation

**Branch:** `feat/td-xdc-source-sync`
**Author:** dam1n19 with Claude Code (Opus 4.7) assistance
**Date:** 2026-05-18
**Files rewritten:**
`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc`
`fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink_timing.xdc`
**Companion docs:** [`BRINGUP_REPORT.md`](../BRINGUP_REPORT.md),
[`PHY_ALIGN_NEXT_STEPS.md`](PHY_ALIGN_NEXT_STEPS.md),
[`ASIC_SOURCE_SYNC_CONSTRAINTS.md`](ASIC_SOURCE_SYNC_CONSTRAINTS.md)

This doc maps **each new constraint → the failure mode it bounds → how it
avoids the 2026-05-05 hold-violation regression**, and gives the supervising
session the **precise expected timing-report effect** to verify in one build
(no Vivado run was done here — proposal only).

---

## 0. The defect, in one paragraph

TideLink's Wlink GPIO PHY is source-synchronous: the peer forwards
`pad_clk_rx` alongside `pad_rx[7:0]`; a runtime calibrator
(`tidelink_phy_align_calibrator.sv`, `AUTOCAL_ENABLE=1`) sweeps per-lane
bit-slip (0..7) × phase (0..15) to find each lane's capture point. The
first-stage pad-capture register is `gpiorx_*/link_data_pad_clk` in
`WavD2DGpioRx` (`GPIO.scala 130`), clocked by a `pad_clk_rx`-derived net.
The old XDC commented out **both** `set_input_delay`/`set_output_delay` and
declared `pad_clk_rx` fully asynchronous to hclk, so Vivado did **zero**
analysis of `pad_clk_rx → pad_rx[n]` capture skew and routed the 8 lanes
with arbitrary, build-varying delay. The calibrator's finite window covered
that skew only by luck → v5 locked 7/7, v6/v7 left the slave at ~0. A
12.5 MHz (2× margin) build reproduced the failure byte-for-byte ⇒ the
defect is **build-to-build skew VARIANCE**, not setup margin.

The 2026-05-05 trap: a naive absolute `set_input_delay -min 1.0 -max 8.0`
on `pad_rx[*]` was tried and made Vivado hold-fix 134 endpoints, so it was
deleted wholesale. The rewrite bounds **relative** skew and **equalises**
lane delay instead of chasing an absolute window — same determinism gain,
none of the hold pressure.

---

## 1. Calibrator skew window (the budget the constraints must stay inside)

From `tidelink_phy_align_calibrator.sv` + `WavD2DGpioRx.v`:

- **Bit-slip** = 16-bit right-rotation of the *deserialised word* (`io_link_data
  = {link_data_reg,link_data_reg}[bit_slip +: 16]`). One slip step = one
  PHY-bit = one `pad_clk_rx` period. At 25 MHz that is **40 ns** per step,
  range 0..7 ⇒ **0..280 ns** of coarse alignment. Slip corrects whole-bit /
  byte-boundary misalignment.
- **Phase** (`io_phase_offset`, 0..15) rotates the *bit-position selector*
  `adj_count = count + phase_offset` (`GPIO.scala`), i.e. it moves which
  `pad_clk_rx` edge writes which of the 16 word bits. On FPGA the DLL is a
  pass-through placeholder (`WavD2DRxDLL: assign clk_o = clk_i`), so phase
  does **not** add sub-bit analog delay — it only re-indexes the capture
  window in whole `pad_clk_rx`-period units (this is exactly the
  `PHY_ALIGN_NEXT_STEPS.md` §1.1 "swi_phase_offset proven insufficient"
  finding).
- **Net usable budget the constraints must keep STATIC layout skew inside:**
  the alignment is quantised to whole 40 ns bit-periods; the calibrator
  cannot correct **intra-bit** clk-to-data skew at all. So the constraint
  job is to keep per-lane clk-to-capture skew **« 40 ns and, critically,
  build-to-build STABLE** so the same (slip,phase) solution that locked
  one build still lands the next build. The chosen budgets — `set_max_delay
  8 ns`, `set_bus_skew 2 ns` — are ≤ ½ bit-period and ≤ 1/20 bit-period
  respectively, i.e. comfortably inside one slip step with margin.

> Cocotb cannot test routing skew. The complementary cocotb task (separate
> deliverable) is a guard test that pins this documented window so a future
> RTL change that shrinks it (e.g. fewer slip bits) is caught — see
> `PHY_ALIGN_NEXT_STEPS.md` and the autoneg 7/7 suite.

---

## 2. Per-constraint rationale + expected timing-report effect

For every constraint: **what failure mode it bounds**, **why it does NOT
reintroduce the 2026-05-05 hold explosion**, and the **exact report/metric/
direction** for the supervisor to verify.

### [1] `create_clock -period 40.000 pad_clk_rx` (kept; comment fixed)
- **Bounds:** nothing new — but it is the *prerequisite*. Without a real
  clock on `pad_clk_rx`, constraints [3]/[4] have no launch reference.
- **Hold-trap:** N/A (declaration only).
- **Stale-comment fix:** header now says 25 MHz / 40 ns (was 50/20),
  `pad_clk_tx` = Y9 SRCC on `-all` / Y7 MRCC on `-flip-all` (was "Y6").
- **Expected report:** `report_clocks` lists `pad_clk_rx` @ 40.000 ns
  (25 MHz). Unchanged vs today; verifies the pin/period comment matches.

### [2] `create_generated_clock pad_clk_tx_fwd` + symmetric `set_output_delay`
- **Bounds:** the **transmit eye**. Old `set_false_path -to pad_clk_tx` +
  no `set_output_delay` meant `pad_tx[*]` launch vs the forwarded clock was
  completely unanalysed — the TX-side half of the same nondeterminism (the
  peer's RX has to capture our unconstrained TX).
- **Why not the 2026-05-05 trap:** the window is **symmetric (±5 ns)** and
  referenced to the **forwarded clock itself** (`pad_clk_tx_fwd`), not to
  an internal MMCM pin. Launch and the peer's capture reference are the
  *same edge*, so Vivado **balances** `pad_tx[*]` vs `pad_clk_tx` rather
  than one-sidedly hold-padding every lane (which is what the old
  asymmetric `-min 1.0 -max 8.0` vs an unrelated clock did).
- **Expected report:**
  - `report_clocks` now also lists `pad_clk_tx_fwd` (generated, 40 ns,
    source = clk_wiz clk_out1).
  - `report_timing -to [get_ports pad_tx[*]]` changes from **"no
    set_output_delay / unconstrained"** to a real **min & max** path with
    a finite slack. WNS may drop slightly (paths now analysed) but must
    stay ≥ 0; if it goes negative the budget is loosened, NOT removed.
  - `report_design_analysis -timing`: TX output paths no longer in the
    "unconstrained ports" list.

### [3a] `set_input_delay` symmetric ±4 ns on `pad_rx[*]` vs `pad_clk_rx`
- **Bounds:** establishes the receive eye so [3b]/[3c] have a reference;
  re-enables RX-path analysis the old file deleted.
- **Why not the 2026-05-05 trap:** the regression was caused by an
  **asymmetric** `-min 1.0 / -max 8.0` window forcing one-sided hold fixing
  on 134 endpoints. Here the window is **symmetric about the launch edge**
  (`-min -4 / -max +4`): it states "data is centre-aligned to the forwarded
  clock" (true for a 1:1 <10 cm ribbon at 25 MHz) so Vivado has no
  systematic hold deficit to chase on every lane.
- **Expected report:** `report_timing -from [get_ports pad_rx[*]]` now
  shows analysed input paths (was unconstrained). **Setup slack large
  positive** (40 ns period, ±4 ns window). **Hold (WHS) ≥ 0 and the number
  of hold-violating endpoints must be ≈ the pre-existing baseline (the
  known debug-only `ila_rx` WHS = −0.56 ns, BRINGUP_REPORT §line117) — NOT
  ~134.** If WHS endpoints jump toward 100+, the symmetric window is still
  too tight → widen, do not delete.

### [3b] `set_max_delay -datapath_only 8 ns` `pad_rx[*]` → `link_data_pad_clk_reg[*]`
- **Bounds:** the **absolute** per-lane clk-to-capture routing delay — caps
  how far any one lane's pad→capture path can drift, so it cannot wander
  out of a slip step build-to-build.
- **Why not the 2026-05-05 trap:** `-datapath_only` explicitly **removes
  the clock-skew/hold component** from the analysed path — it is a pure
  combinational max-delay, so Vivado does **not** insert hold-fixing
  routing for it. This is the canonical Xilinx way to bound source-sync
  capture delay without hold pressure.
- **Expected report:** `report_timing -from [get_ports pad_rx[*]] -to
  [get_cells -hier *gpiorx_*/link_data_pad_clk_reg[*]] -max_paths 8
  -datapath_only`: 8 paths (1/lane), each **datapath delay ≤ 8 ns, slack ≥
  0**. Across two builds the **per-lane datapath delays should now cluster**
  instead of ranging freely (this is the headline determinism metric — see
  §3).

### [3c] `set_bus_skew 2 ns` across `pad_rx[*]` → capture  ← **THE key fix**
- **Bounds:** the **lane-to-lane VARIANCE** that *is* the defect. Forces
  Vivado to equalise the 8 capture delays to within 2 ns of each other, so
  one (slip,phase) solution fits all lanes and the same solution survives a
  re-build. On `-flip-all` this also absorbs the **Y9-SRCC vs Y7-MRCC**
  clock-insertion asymmetry (the "slave is always the unlucky side" — §4).
- **Why not the 2026-05-05 trap:** `set_bus_skew` is a *relative* (max −
  min across the bus) constraint — it has **no absolute hold component**, so
  it cannot trigger per-endpoint hold fixing. It makes P&R *match* lane
  routing, not pad it.
- **Expected report:** `report_bus_skew` (or `report_timing -name
  busskew`) lists the `pad_rx[*]→capture` group with **bus skew ≤ 2 ns,
  slack ≥ 0**. **Determinism metric:** the reported bus-skew value should
  be similar across two builds (low inter-build variance) — contrast with
  constraints-OFF where there is no such report and the implied skew is
  unbounded.

### [3d] `catch { set_property IOB TRUE [get_ports pad_rx[*]] }`
- **Bounds:** makes whatever IOB-able input element Vivado infers on the
  `pad_rx[*]` chain deterministic (fixed IOB site, not fabric).
- **Honest caveat (also in the XDC):** the *real* capture FF
  `link_data_pad_clk_reg[*]` has a per-bit input mux (`adj_count==X ? io_pad
  : hold`) so it **cannot legally pack into the IOB**. `set_property IOB
  TRUE` on that cell would be ignored; applying it to the **port** lets
  Vivado place the IOB-able portion in the pad and is harmless where it
  cannot. **This is NOT the primary determinism fix — [3b]/[3c] are.** The
  proper fix is the disabled IDELAYE2 stanza [5], owned by the RTL-hook
  agent.
- **Expected report:** `report_io` / placement: `pad_rx[*]` input path uses
  the IOB where applicable; **no ERROR** (the `catch` swallows the
  "cannot pull through mux" message — it appears as INFO/ignored).

### [4] Narrowed `set_clock_groups -asynchronous` (pad_clk_rx ↔ hclk only)
- **Bounds:** keeps the genuine **recovered-RX → core/hclk CDC** cut
  (Wlink 2-flop synchronises it internally — `sync_lane_locked_*` pattern)
  while **NOT** erasing the `pad_rx[*]→capture` analysis.
- **Subtle correctness point (in the XDC too):** `set_clock_groups
  -asynchronous {pad_clk_rx}{hclk}` only cuts paths *between those two
  clocks*. The `pad_rx[*]→capture` paths are launched by the [3a]
  input-delay virtual source on `pad_clk_rx` and captured on `pad_clk_rx`
  (same clock) — they are **not** pad_clk_rx↔hclk paths, so this declaration
  does not disable them. The old file's problem was *not* this command per
  se — it was that with [3a]/[3b]/[3c] absent there was nothing ELSE timing
  the capture. Re-adding [3] makes the same async declaration correct and
  narrow.
- **Expected report:** `report_clock_interaction`: `pad_clk_rx` ↔ hclk =
  **"Asynchronous Groups" (no timed paths, no CDC WNS)**, while
  `pad_clk_rx` (intra) → `link_data_pad_clk_reg` = **timed** (Safely Timed
  / has slack), i.e. the source-sync group is analysed and the CDC is not.
  Constraints-OFF showed pad_clk_rx with *no* internal timed paths at all.

### [5] DISABLED IDELAYE2 stanza
- **Bounds:** nothing yet — intentionally inert. Documents the proper FPGA
  per-lane delay line for the separate RTL-hook agent (IDELAYCTRL + 200 MHz
  ref + IDELAY_GROUP + calibrator tap). Gated behind `#` so it has zero
  build effect.
- **Expected report:** none (commented out). Presence verified by grep, not
  by Vivado.

### [6]/[7] LED false_path + combinational-loop waiver
- **Unchanged in intent.** Kept intact per the task. The `-flip-all` waiver
  was *widened* from a single auto-generated net name to the
  `*u_xhb_sub/u_core/u_resp/*` subtree to **match the `-all` target and the
  `*_tidelink_drc.xdc`** (auto-generated net names drift between Vivado
  runs; the subtree match is the robust form already proven on `-all`).
  This relaxes only that one already-waived loop.
- **Expected report:** `report_drc`: LUTLP-1 still downgraded/ waived
  (no new combinational-loop ERROR); LED ports still false-pathed.

---

## 3. Determinism metric + multi-build validation plan (supervisor-run)

The goal metric is **inter-build variance of per-lane clk-to-capture skew**,
NOT WNS. Proposed procedure for the supervising session:

1. **Baseline (constraints OFF):** check out `feat/credit-path-observability`
   (pre-this-branch), build `pynq-z2-pair-all` ×2 (different seeds or just
   two clean runs). For each, post-route:
   `report_timing -from [get_ports {pad_rx[*]}] -to [get_cells -hier -filter
   {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}] -max_paths 8
   -datapath_only -name base`. Record the 8 per-lane datapath delays.
   Expectation: wide spread, and **build-A vs build-B differ markedly**
   (this is the documented v5-vs-v6 nondeterminism, now quantified).
2. **Constraints ON (this branch):** rebuild ×2. Same report, plus
   `report_bus_skew`. Expectation: 8 per-lane delays **clustered ≤ 2 ns
   apart** and **build-A ≈ build-B** (low inter-build variance) — the fix.
3. **Determinism KPI:** `max_lane − min_lane` per build, and
   `|skew_buildA − skew_buildB|`. Target: bus skew ≤ 2 ns each build AND
   inter-build delta small (≤ ~1 ns). OFF: expect both large/unbounded.
4. **Functional confirmation (no ILA needed):** use the RO-observability
   APB readouts (`docs/CREDIT_PATH_DEBUG_PLAN.md`,
   `feat/credit-path-observability`) to read per-lane lock/`lane_fault`
   across **N ≥ 4** supervisor builds (mix of `-all` and `-flip-all`,
   master+slave). KPI: **7/7 (or 8/8) lock on every build**, especially the
   slave (`-flip-all`, Y9-SRCC) side which was the unlucky one. OFF
   baseline: lock count varies build-to-build (v5=7/7, v6/v7≈0).
5. **Regression guards:**
   - `report_timing_summary`: **WHS ≥ 0** and **hold-violating endpoint
     count ≈ baseline (the known debug-only ~1, NOT ~134)**. If it jumps,
     the 2026-05-05 mode is recurring → widen the [3a] symmetric window or
     relax [3b], do **not** delete the constraints.
   - `cocotb/tidelink_autoneg` stays 7/7 (constraints are impl-only XDC; no
     RTL changed, so this is expected unaffected — run as a guard).

---

## 4. Slave-clock-path (Y9-SRCC) asymmetry assessment

- **Finding:** on `-all`, `pad_clk_rx`=Y7 (IO_L13P_T2_**MRCC**_13,
  multi-region clock-capable). On `-flip-all`, `pad_clk_rx`=Y9
  (IO_L14P_T2_**SRCC**_13, single-region). MRCC drives global clock
  resources directly with low, well-characterised insertion delay; SRCC has
  more constrained distribution. Since the FLIP bitstream is deployed to the
  slave (`die_b`/peer), the slave's recovered-clock distribution is the
  weaker one → it sees larger, more variable clk-to-capture skew. This
  matches the empirical "slave is always the unlucky side".
- **Quantified contribution:** the difference is the **BUFG/clock-net
  insertion-delay delta between an MRCC-sourced and an SRCC-sourced BUFG**
  on this device, plus the routing from the BUFG to the 8 `gpiorx_*`
  capture flops. On 7-series this is typically a few hundred ps to ~1 ns of
  *extra, less-balanced* insertion — small in absolute terms but, when
  **unconstrained**, enough to push the SRCC side's per-lane spread outside
  the quantised slip window on some builds while the MRCC side stays in.
- **Recommendation (does not need a rebuild to decide):**
  1. **Primary (this branch):** `set_bus_skew 2 ns` [3c] **directly
     equalises** the per-lane delays *after* the BUFG, which is exactly the
     SRCC-side variance source — so the constraint set already targets this
     without any pin change.
  2. **Pin-map option (separate change, NOT done here — it is a
     `pynq_z2_tidelink.xdc` edit, out of this task's XDC scope):** if a
     P-side **MRCC** ball reachable by the straight-through ribbon on the
     FLIP header exists, moving FLIP `pad_clk_rx` there would remove the
     asymmetry at the source. The current Y7/Y9 split exists because
     Vivado's PLIO-9 DRC rejects clock inputs on N-side pins so both
     clocks must be P-side; re-deriving a symmetric MRCC/MRCC pair is a
     pin-map study for the pin-XDC owner.
  3. **Belt-and-braces (RTL-hook agent):** the disabled IDELAYE2 [5] would
     give the SRCC side an explicit, characterised per-lane tap the
     calibrator drives — the robust long-term answer.
- **Conclusion:** the asymmetry is real and explains the slave bias, but it
  is a **second-order amplifier of the unbounded-skew root cause**, not an
  independent defect. `set_bus_skew` neutralises it; a symmetric MRCC pin
  pair and/or IDELAYE2 are follow-on hardening, owned elsewhere.

---

## 5. Risks & assumptions (be rigorous)

1. **Symmetric `set_input_delay` could still cause some hold fixing.** A ±4
   ns window is far less aggressive than the old asymmetric 1..8 ns one, and
   `-datapath_only` on [3b] carries no hold component, but Vivado may still
   add modest hold buffering on the `pad_rx` paths. **Mitigation/criterion:**
   the supervisor must compare WHS endpoint *count* to baseline; ≈ baseline
   (the known ~1 debug-only) = fine; a jump toward ~134 = the 2026-05-05
   mode → first widen the [3a] window (e.g. ±8 ns) keeping it symmetric,
   then if still bad relax [3b], and only as last resort drop [3a] keeping
   [3b]/[3c] (which alone still bound variance with no hold pressure).
2. **`set_max_delay`/`set_bus_skew` cell selector depends on the synthesised
   name `link_data_pad_clk_reg[*]` under `*gpiorx_*`.** Verified against
   `WavD2DGpioRx.v` (`reg [15:0] link_data_pad_clk`, `GPIO.scala 130`) and
   the `WavD2DGpio` instance names `gpiorx_0..7`. If a future Wlink/Chisel
   regen renames it, the `get_cells` returns empty and the two constraints
   become no-ops (Vivado CRITICAL WARNING, **not** a wrong constraint —
   fail-safe). **Mitigation:** the supervisor should eyeball the
   `set_max_delay`/`set_bus_skew` line in the impl log for a non-empty
   object count; the build's own `report_bus_skew` having the group is the
   positive confirmation. (Synthesis-time `12-4739` is expected & benign —
   the file is impl-only.)
3. **`pad_clk_tx_fwd` generated clock assumes the FPGA TX serializer runs on
   clk_wiz hclk.** Established from RTL: `WavD2DSerdesPLL`/`WavD2DGpio`'s PLL
   is behavioural sim-only (non-synthesisable), and the BD ties
   `user_ref_clk` → `clk_wiz_0/clk_out1`; `WavD2DGpioTx` does `assign
   pad_clk = clk`. If a real PLL is ever instantiated for FPGA, [2]'s
   `-source`/`-divide_by` must be revisited. Low risk for current bring-up.
4. **IOB request [3d] is best-effort, not load-bearing.** Explicitly
   documented; determinism rests on [3b]/[3c]. No risk of silent
   over-claim — the `catch` and the in-file caveat make the limitation
   explicit for reviewers.
5. **No Vivado was run.** Every effect above is a *predicted* report delta
   for the supervisor to confirm in one build per target. If a prediction
   is contradicted (e.g. `report_bus_skew` shows no group), treat the
   `get_cells` selector (risk 2) as the first suspect.
6. **`-flip-all` combinational-loop waiver widened.** This is a deliberate
   relaxation to match the proven `-all` form; it only ever affected the
   one intentional AHB HREADY loop. Risk: if some *other* net under
   `*u_xhb_sub/u_core/u_resp/*` ever had a real (unintended) loop it would
   also be waived — but that subtree is the IP-Integrator AHB-Lite response
   path, the loop there is the known-intentional one, and `-all` + the DRC
   xdc already use this exact form in production.

# UG903 Forwarded-Clocks Audit — TideLink Pair Design

**Date:** 2026-05-28
**Branch:** `feat/ug903-audit` (off `feat/target-a-bd` @ 63c2f10)
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/`
**Author:** David Mapstone (audit compiled by Claude)
**Scope:** READ-ONLY. No RTL, BD, or XDC modified — recommendations only.

**Subject under audit:**
`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc` and the BD
`tidelink_design.tcl` that drives `pad_clk_tx` straight from
`clk_wiz_0/clk_out1` with no ODDR.

**Pin/rate clarifications versus the prompt:**
The prompt phrased the link as 50 MHz with `pad_clk_tx` on Y9 and
`pad_clk_rx` on Y9. The current XDC in this worktree actually runs the GPIO
PHY at **25 MHz / 40 ns** (`create_clock -period 40.000`) with
`pad_clk_tx → Y9 (SRCC P)` and `pad_clk_rx → Y7 (MRCC P)`. The audit below
is faithful to the XDC, not the prompt phrasing. The conclusions transfer
verbatim if the link is later re-clocked to 50 MHz (period halves, the
asymmetric vs symmetric window argument is identical).

---

## 1. UG903 — Recommended Forwarded-Clock Pattern (citations)

The canonical AMD/Xilinx pattern for a clock that is forwarded out of an
FPGA in a source-synchronous interface is documented in **UG903 (Vivado
Using Constraints), "Forwarded Clocks"** and the worked example **"Example
Six: Forwarded Clock Driven by ODDR"**.

The four-point pattern UG903 expects:

1. **Launch the forwarded clock through an `ODDR` primitive**, not through
   an `OBUF` driven by the user clock.
   - UG903 ("Forwarded Clocks", intro): *"The Timing Constraints wizard
     recommends generated clock constraints on output ports that are
     driven by double data-rate registers with constant inputs."*
   - For an **edge-aligned** forward, the ODDR is tied `D1=1, D2=0` — the
     output port toggles on the **rising edge of the launching clock**,
     i.e. the forwarded clock edges are aligned with the **launch edges**
     of the data flops. (This is the same edge that launches `pad_tx[*]`,
     hence the receiver will sample at the worst-case eye position unless
     the receiver re-shifts.)
   - For a **centre-aligned** forward, the ODDR is tied `D1=0, D2=1` so
     the output toggles on the **falling edge** of the launching clock —
     i.e. the forwarded clock edges sit in the **middle** of each data
     bit, giving the receiver a centred eye out of the box.

2. **Declare the forwarded clock with `create_generated_clock` at the
   output port**, sourced from the ODDR's clock pin. Verbatim from
   Example Six:

   ```tcl
   create_generated_clock -name ck_vsf_clk_2 \
       -source [get_pins ODDRE1_vsfclk2_inst/CLKDIV] \
       -divide_by 1 \
       [get_ports vsf_clk_2]
   ```

   UG903 notes the generated clock "references the master clock driving
   the ODDR/CLKDIV pin and has the same period as the master clock
   (`-divide_by 1`)." This is the only correct way to make the forwarded
   clock and the data lanes timed against the same launching edge.

3. **Reference `set_output_delay` to the forwarded (generated) clock, not
   to the internal MMCM/PLL output.** This is what makes Vivado balance
   pad_tx[*] launch and pad_clk_tx forward together — both depart through
   IOBs on the same clock, so Vivado is free to add matching insertion
   delay rather than hold-pad each lane.

4. **On the receiver, declare the input clock with `create_clock` on the
   input port and use `set_input_delay` referenced to it.** UG903 places
   `pad_clk_rx`-style inputs in the source-synchronous input category
   where `set_input_delay -min/-max` defines the data valid window at the
   pad relative to that received clock.

UG903's relationship between the forwarded clock and the internal source
clock is **NOT "asynchronous"** — they are physically the same clock,
just observed at different points. The UG903/UG949 guidance is to either
(a) leave Vivado to derive them as related (which Example Six does
implicitly via `create_generated_clock -source`) or (b) bound them with
`set_max_delay`/`set_min_delay` if a manual cut is needed. A blanket
`set_clock_groups -asynchronous` between a forwarded clock and its
launching domain is a code smell — it tells Vivado the two clocks are
unrelated, which contradicts the physical reality and lets analysis
silently drop the pad_tx → forwarded-clock launching relationship.

---

## 2. What We Do Today (current XDC + BD facts)

From `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc` and
`tidelink_design.tcl`:

| Topic | UG903 recommended | TideLink today |
|---|---|---|
| TX clock-forward primitive | **ODDR** (D1=1,D2=0 edge-aligned **or** D1=0,D2=1 centred) | **Plain combinational forward** — `WavD2DGpioTx.v:97` `assign io_pad_clk = hs_clk_gated_wcg_io_clk_out;` → OBUF on `pad_clk_tx` |
| Master clock pin sourcing the forward | `ODDR/CLKDIV` (or `ODDR/C` for 7-series) | `clk_wiz_0/clk_out1` (post-WavClockGate) |
| `create_generated_clock` at `pad_clk_tx` | Yes — sourced from ODDR clock pin | **Yes** — sourced from `clk_wiz_0/clk_out1` (constraint [2] in `_timing.xdc`). The constraint is structurally right; the **source pin is wrong** because there is no ODDR in the path. |
| `set_output_delay` on `pad_tx[*]` | Referenced to the generated (forwarded) clock | **Yes** — referenced to `pad_clk_tx_fwd`. Window is symmetric ±5 ns. |
| RX clock declared via `create_clock` on input port | Yes | **Yes** — `create_clock -period 40 -name pad_clk_rx [get_ports pad_clk_rx]` |
| `set_input_delay` on `pad_rx[*]` | Referenced to RX clock, window from skew budget | **Yes** — symmetric ±4 ns window. **Asymmetric 1.0/8.0 ns numbers from the prompt are stale** — the actual file uses ±4.0 ns (see §3.4). |
| Relationship between `pad_clk_rx` and internal `hclk` | Vivado-derived OR bounded with `set_max_delay` | **`set_clock_groups -asynchronous`** between `pad_clk_rx` and `hclk` |
| Relationship between `pad_clk_tx_fwd` and `hclk` | Same physical clock, leave related | Implicit: not explicitly grouped in this file (good) |

### Key deviation: no ODDR

`WavD2DGpioTx.v` continuous-assigns `io_pad_clk = hs_clk_gated_wcg_io_clk_out`
where `hs_clk_gated_wcg` is a `WavClockGate` instance whose output is
ultimately `user_ref_clk` = `clk_wiz_0/clk_out1`. After synthesis this
becomes an `OBUF` driven directly by the global clock net. The forwarded
edge therefore lands at the pad **at the same time** as the data flops
clock their D-input through to Q (modulo OBUF vs ODDR delay — which on
7-series is typically the OBUF being *faster* than an ODDR path by
500 ps — 1 ns of clock-tree-to-IOB-mux skew). Net effect: the forwarded
clock edge arrives at the receiver pad **slightly before** the data lane
transitions — i.e. the launcher does not give the receiver any margin to
sample.

This is exactly why our `tidelink_phy_align_calibrator` exists: it
forcibly shifts each RX lane's capture phase so the sampling moment is
not at the launch edge. **The calibrator is compensating for a missing
ODDR.**

---

## 3. Diff: UG903 vs. Our XDC, line by line

### 3.1 `create_generated_clock` source — STRUCTURAL ✓, PIN ✗

Today:

```tcl
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}] \
    -divide_by 1 \
    [get_ports pad_clk_tx]
```

UG903 Example Six:

```tcl
create_generated_clock -name ck_vsf_clk_2 \
    -source [get_pins ODDRE1_vsfclk2_inst/CLKDIV] -divide_by 1 [get_ports vsf_clk_2]
```

We are sourcing from the MMCM output pin instead of from an ODDR clock
pin **because we have no ODDR**. Structurally the constraint is valid
Vivado XDC, but it omits the IOB launch flop, so:

- Vivado treats the entire combinational path from `clk_out1` → through
  the WavClockGate → through global routing → out the OBUF as "clock
  insertion delay" instead of "launch flop CK-to-Q + IOB delay". This is
  *much* larger and more variable across builds than an ODDR's CK-to-Q
  + IOB-MUX → pad delay.
- The `pad_clk_tx_fwd` insertion delay therefore tracks build-to-build
  routing variance to a *different* pad than `pad_tx[*]`, even though
  both are launched by the same `clk_out1`. ODDR forces the launch into
  the IOB right next to the OSERDES/OBUF for the data, equalising the
  paths.

### 3.2 No ODDR on the TX clock — UG903 PATTERN VIOLATED

UG903 / UG471 are unambiguous: a synchronous forwarded clock on 7-series
should be launched through an `ODDR` instance, with one of:

- `D1 = 1'b1, D2 = 1'b0` → edge-aligned forwarded clock (toggles on the
  same edge that launches data). Use this when the receiver has phase
  shift (IDELAYE2 / MMCM phase shift) to recover the centre of the eye.
- `D1 = 1'b0, D2 = 1'b1` → centre-aligned (90°-shifted forwarded clock).
  Receiver can latch directly on the rising edge of the recovered clock
  and sample near the centre of the data eye.

We currently have neither. The `WavD2DGpioTx` macro hard-codes a
combinational `assign io_pad_clk = ...`. This is a synthesised
**combinational OBUF launch** — equivalent to an `OBUF` driven by a
global-clock buffer net. It works in simulation (no insertion-delay
modelling), but on real silicon the clock-vs-data skew is whatever P&R
gives that build, which is *exactly the build-to-build variance signature
documented in `_timing.xdc` §[WHY THIS FILE WAS REWRITTEN]*.

### 3.3 `set_clock_groups -asynchronous` between forwarded RX and core

Today:

```tcl
set_clock_groups -asynchronous \
    -group [get_clocks pad_clk_rx] \
    -group [get_clocks -of_objects $hclk_pin]
```

For the **recovered RX clock → core CDC** this is defensible — Wlink
internally 2-flop synchronises the cross. UG903 doesn't forbid
`set_clock_groups -asynchronous` for genuine CDCs.

For the **TX side** (`pad_clk_tx_fwd` and `hclk`) we are *not* declaring
them async (good) — they are kept implicitly related via the
`create_generated_clock` source link. That's right.

The historical reason this file documents the async group narrowly is
that an older revision used a blanket `pad_clk_rx ↔ hclk` async group
that ate the `pad_rx[*] → capture` analysis too. The current scope is
correct.

### 3.4 `set_input_delay` window (corrects the prompt)

The prompt cited `-min 1.0 -max 8.0` on `pad_rx[*]`. The **actual** XDC
in this worktree uses `±4.0 ns` symmetric:

```tcl
set_input_delay -clock [get_clocks pad_clk_rx] -max  4.000 [get_ports {pad_rx[*]}]
set_input_delay -clock [get_clocks pad_clk_rx] -min -4.000 [get_ports {pad_rx[*]}]
```

This was the deliberate 2026-05-18 fix for the 2026-05-05 trap that the
asymmetric absolute window created (134 hold-violating endpoints, file
header §[WHY THIS FILE WAS REWRITTEN]). The symmetric window is also
what UG903 effectively recommends when the receiver re-shifts internally,
because it lets the calibrator absorb the residual without Vivado
hold-padding every lane.

**Verdict:** the current `±4 ns` is correct for a calibrated receiver.
**Do not revert to the asymmetric 1.0/8.0 window the prompt referenced.**

### 3.5 `set_false_path -to pad_clk_tx` (the prompt asked about this)

The current XDC file no longer contains `set_false_path -to
[get_ports pad_clk_tx]`. It was replaced with the `create_generated_clock
pad_clk_tx_fwd` + `set_output_delay` pair on 2026-05-18. The prompt's
description of the constraint set is **out of date** on this point. The
new pattern is the UG903-correct one (structurally — see §3.1 for the
remaining issue around the source pin).

---

## 4. Concrete Recommended Changes

### R1 (HIGH IMPACT — RTL change required): Insert an ODDR on `pad_clk_tx`

This is the single biggest gap versus UG903. Two ways to do it:

**Option A (preferred, BD-level):** add an `ODDR` primitive between
`tidelink_0/pad_clk_tx` and the BD output port `pad_clk_tx`, all inside
the BD. Same Verilog source for `WavD2DGpioTx` stays untouched.

Add to `tidelink_design.tcl` (after the `tidelink_0` instance is
created):

```tcl
# UG903 §"Forwarded Clocks" — launch the forwarded clock through an
# ODDR primitive so the IOB launch matches the data lanes and a true
# generated clock can be declared at the output port.
#
# Edge-aligned: D1=1, D2=0 (toggles on rising edge of CK, same as data).
# Centre-aligned: D1=0, D2=1 (toggles on falling edge, 180-degree shift
# → 90 degree relative to centred data eye in SDR mode).
#
# For TideLink today we want CENTRE-ALIGNED — the calibrator already
# compensates for per-lane skew but starts from the edge of the eye, so
# giving it a centred clock removes ~10 ns of useless calibrator phase
# sweep.
create_bd_cell -type module -reference ODDR_clk_fwd tx_clk_oddr
# (or: instantiate via xilinx.com:ip:util_ds_buf with the ODDR template)
```

**Option B (RTL):** add a tiny Verilog shim around `tidelink_top` in
`tidelink_design_wrapper.v` that swaps `pad_clk_tx` for an ODDR:

```verilog
wire pad_clk_tx_int;   // existing internal net from tidelink_0

ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),   // SDR centre-align via D1=0, D2=1
    .INIT(1'b0),
    .SRTYPE("ASYNC")
) u_tx_clk_oddr (
    .Q  (pad_clk_tx),       // -> OBUF -> pad
    .C  (user_ref_clk),     // same clock that launches pad_tx[*]
    .CE (1'b1),
    .D1 (1'b0),             // centred: clock edge mid-bit
    .D2 (1'b1),
    .R  (1'b0),
    .S  (1'b0)
);
```

Then update XDC to source the generated clock from the ODDR's `C` pin,
matching UG903 Example Six verbatim:

```tcl
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins u_tx_clk_oddr/C] \
    -divide_by 1 \
    [get_ports pad_clk_tx]
```

### R2 (XDC-only, no RTL change): Tighten the existing generated-clock source

Even without an ODDR, the **closest IOB-side launch point** for
`clk_out1` → `pad_clk_tx` is the OBUF input pin. Sourcing the generated
clock from there (instead of from the MMCM output pin) makes the
forwarded-clock delay relative to the **same point** in the timing graph
as where the data OBUFs are evaluated. Concretely:

```tcl
# Replace the get_pins ... clk_wiz_0/clk_out1 with the OBUF input pin
# feeding pad_clk_tx (post-impl). The exact pin name only resolves after
# synthesis, so this needs USED_IN_IMPLEMENTATION (already the case).
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins -hier -filter {NAME =~ "*pad_clk_tx_OBUF_inst/I"}] \
    -divide_by 1 \
    [get_ports pad_clk_tx]
```

This is a milder fix than R1 — it improves the launch-point modelling
without an RTL change, but it does **not** solve the actual physical
edge-alignment problem (the OBUF still launches the clock on the data
edge). R2 is a stopgap; R1 is the proper fix.

### R3 (XDC): Make `pad_clk_rx` declaration UG903-style explicit

The current `create_clock` is fine. UG903 additionally recommends adding
a `set_property CLOCK_DEDICATED_ROUTE BACKBONE` (or just leaving Vivado
to infer BUFG) on the input clock to guarantee global-buffer routing.
Vivado 2024.1 does this automatically for an MRCC clock input, but
adding the explicit constraint removes one source of build-to-build
variance:

```tcl
# Optional: lock clock-dedicated routing for the recovered RX clock.
set_property CLOCK_BUFFER_TYPE BUFG [get_nets -of_objects [get_ports pad_clk_rx]]
```

### R4 (XDC): Replace the async group on `pad_clk_rx ↔ hclk` with a bounded one

The current async group is defensible (Wlink's RX-to-core boundary is
2-flop sync'd), but UG903 prefers an explicit `set_max_delay
-datapath_only` over `set_clock_groups -asynchronous` for cases where
the two clocks are **frequency-related** (here, `pad_clk_rx` and `hclk`
are both 25 MHz, derived from the same physical FPCLK on different
boards). If we ever need to recover the timing relationship (e.g. for
PHC sub-clock-period determinism), the async group throws away
information we will want.

Suggested replacement (lower priority — only if PHC alignment becomes
unstable):

```tcl
# Replace the set_clock_groups async with bounded CDC paths:
set_max_delay -datapath_only -from [get_clocks pad_clk_rx] -to [get_clocks -of_objects $hclk_pin] 40.000
set_max_delay -datapath_only -from [get_clocks -of_objects $hclk_pin] -to [get_clocks pad_clk_rx] 40.000
```

This costs Vivado a few percent of P&R effort but preserves the option
of analysing PHC paths across the CDC boundary later.

### R5 (XDC): Optional — explicit `set_clock_latency` for forwarded clocks

UG949 (Design Methodology) suggests setting a non-zero clock latency on
the forwarded clock at the output port to model the off-chip insertion
delay (ribbon + IBUF on the other board). Since we are paired-board
self-mirroring, this is symmetric and falls out — skip for now.

---

## 5. Should We Add an ODDR? (the prompt asked this explicitly)

**Yes — absolutely.** Reasons in priority order:

1. **UG903 Example Six requires it** for the generated-clock pattern to
   reference a real launch flop. Without an ODDR, we have a structurally
   valid `create_generated_clock` whose source pin is *not* the actual
   launching cell — Vivado fudges this by treating the global clock net
   as the launch reference, which adds large + build-variable insertion
   delay between the generated clock and the data OBUFs.

2. **Edge-aligned vs centre-aligned matters here.** With our current
   no-ODDR forward, the clock edge arrives at the receiver pad *roughly
   at the same time as the data transition* (give or take OBUF vs OBUF
   IOB delay). The calibrator then has to phase-shift each lane until it
   samples mid-bit. If we centre-align via `D1=0, D2=1` ODDR, the
   receiver sees a clock edge that's already ~10 ns offset from the data
   edge at 25 MHz — i.e. the data eye is *already centred on the
   rising edge of `pad_clk_rx`* before the calibrator runs. The
   calibrator's job changes from "find the eye" to "track residual lane
   skew" — much smaller window, much more robust.

3. **Build-to-build determinism.** ODDR moves the launch into the IOB
   tile next to the OBUF. P&R no longer has freedom to route the
   `clk_out1 → OBUF/I` path differently each build. This directly
   attacks the build-variance defect the `_timing.xdc` header describes
   (§[WHY THIS FILE WAS REWRITTEN]).

4. **Opinion on whether lack of ODDR is contributing to current
   symptoms.** Almost certainly yes. The calibrator-bug-fix
   (`f900e07`, 2026-05-27) added a `S_PROBE` state that biases initial
   sweep to `(0,0)` because the AUTOCAL=1 master-to-slave asymmetric
   corruption was hard to recover from a random start. That asymmetric
   corruption is exactly what an edge-aligned (no-ODDR) forward looks
   like: the clock-vs-data phase at the RX pad is not centred on any
   eye, and the calibrator has to walk the whole 40 ns period to find
   one. If R1 lands and centre-aligns the clock, the AUTOCAL=1 path
   should converge on iteration 1 instead of needing the bias.

---

## 6. Interaction with Target A (slave-side load reduction)

Target A proposes replacing the current 8× per-instance BUFG fanout on
`pad_clk_rx` (~48 pF total load) with a single IBUFG → BUFG → fanout
network at the BD level. This is **complementary** to R1, not in
conflict:

- **R1 (TX-side ODDR)** centres the clock edge in the data eye *as it
  arrives at the receiver pad*. It does nothing about the *electrical*
  load on that pad.
- **Target A (RX-side single BUFG)** reduces the capacitive load on
  `pad_clk_rx`, sharpening the edge and pushing the realised swing
  closer to the full 3.3 V rail at 25 MHz. It does nothing about *when*
  the edge arrives relative to the data.

Both fixes attack different terms in the eye equation:

```
eye_open = bit_period − (skew_max − skew_min) − slew_rise − slew_fall
```

R1 reduces `skew_max − skew_min` (data-vs-clock launch alignment).
Target A reduces `slew_rise + slew_fall` (electrical edge speed). They
multiply.

**Sequencing recommendation:** land Target A first (BD-only, no RTL
change, lowest risk). Then land R1 (RX wrapper RTL + XDC source-pin
correction). Verify each in isolation on `pynq-z2-pair-flip-ila` before
combining. The calibrator's `S_PROBE` initial bias should be left in
place across both — it costs nothing and is the right starting point
even with both fixes applied.

---

## 7. Summary Table

| ID | Change | RTL? | XDC? | BD? | Priority | Risk |
|----|---|---|---|---|---|---|
| R1 | Add ODDR(D1=0,D2=1) on `pad_clk_tx` launch | yes (wrapper or BD) | yes (re-source generated clock from ODDR/C) | yes (Option A) | HIGH | low–medium |
| R2 | Re-source `pad_clk_tx_fwd` from OBUF/I instead of MMCM/clk_out1 | no | yes | no | MEDIUM (stopgap) | low |
| R3 | Explicit `CLOCK_BUFFER_TYPE BUFG` on `pad_clk_rx` net | no | yes | no | LOW | none |
| R4 | Replace `set_clock_groups -async` with `set_max_delay -datapath_only` for `pad_clk_rx ↔ hclk` | no | yes | no | LOW (defer until PHC needs it) | low |
| R5 | `set_clock_latency` on `pad_clk_tx_fwd` for off-chip insertion delay | no | yes | no | SKIP (symmetric pair) | none |

---

## Sources

- UG903 (Vivado Using Constraints, 2024.1) — **Forwarded Clocks** chapter,
  including **Example Six: Forwarded Clock Driven by ODDR**. Verbatim
  snippet reproduced in §1 above.
  <https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Forwarded-Clocks>
  <https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Example-Six-Forwarded-Clock-Driven-by-ODDR>
- UG471 (7 Series SelectIO Resources) — ODDR primitive `DDR_CLK_EDGE`,
  `D1`/`D2` tie patterns, OPPOSITE_EDGE vs SAME_EDGE modes.
- UG949 (Vivado Design Methodology) — methodology preference for
  `set_max_delay -datapath_only` over `set_clock_groups -asynchronous`
  when two clocks are frequency-related but functionally async.
- Local `docs/CLOCK_FORWARDING_REFERENCE_RESEARCH_2026_05_28.md` — ADI
  source-synchronous reference, XAPP585/XAPP1064 historical examples.
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc` — current
  TideLink XDC under audit.
- `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v:97` — site
  of the missing ODDR (`assign io_pad_clk = hs_clk_gated_wcg_io_clk_out`).

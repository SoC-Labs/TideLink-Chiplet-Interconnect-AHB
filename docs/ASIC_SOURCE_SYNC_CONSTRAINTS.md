# TideLink GPIO-PHY — ASIC Source-Synchronous Constraint Guidance

**Audience:** future agents bringing TideLink up on an ASIC P&R + STA flow
(the existing ASIC stubs live under `src/rtl/asic/` and
`deps/axi-chiplet-controller/logical/PHY/serdes/syn/serdes.sdc`).
**Status:** guidance / required reading — no ASIC SDC is committed yet.
**Companion:** [`SOURCE_SYNC_CONSTRAINTS_RATIONALE.md`](SOURCE_SYNC_CONSTRAINTS_RATIONALE.md)
(the FPGA implementation this generalises), [`BRINGUP_REPORT.md`](../BRINGUP_REPORT.md).

> **Rule for agents (do not violate):** never sign off a source-synchronous
> chiplet PHY with **unconstrained pad→capture timing**. "It locked on the
> bench" is an FPGA accident born of unbounded routing skew that happened to
> land in the calibrator window. An ASIC P&R/STA flow will neither converge
> nor yield PVT-robust silicon under that non-methodology. The calibrator
> handles **dynamic + PVT** skew; **static** layout skew must be **bounded
> by construction** so the calibrator's finite (bit-slip × phase) search
> range is a *guarantee*, not luck.

---

## 1. Why the FPGA "leave it unconstrained" state must NOT be carried to ASIC

On FPGA the failure was *intermittent* (build-to-build P&R lottery). On ASIC
the same unconstrained source-sync paths give you, additionally:

- STA cannot classify `pad_rx[*] → capture` (no launch/capture relationship)
  → either falsely-met (ignored) or non-convergent.
- No PVT coverage: the one layout you taped out has *one* clk-to-data skew;
  silicon sees SS/FF/temp/voltage spread with no budget proving the
  calibrator window still covers it.
- Hold is silently violated (source-sync capture is inherently
  hold-sensitive — the 2026-05-05 FPGA lesson, amplified by OCV on ASIC).

So the ASIC flow must use the **forwarded-clock methodology** end to end.

---

## 2. The methodology (TX eye, RX eye, the one legitimate async cut)

### 2.1 Transmit side (our `pad_tx[*]` + forwarded `pad_clk_tx`)
- Define the forwarded clock as a **generated clock** at the output
  pad/cell, derived from the serializer clock:
  `create_generated_clock -name pad_clk_tx_fwd -source <serializer_clk_pin>
  -divide_by <N> [get_ports pad_clk_tx]` (N per the PHY's bit/serializer
  ratio; FPGA used 1 because the FPGA serializer == hclk — on ASIC it is the
  real high-speed PLL output, set N accordingly).
- Analyse `pad_tx[*]` with `set_output_delay` **against
  `pad_clk_tx_fwd`**, modelling the *peer's* receiver setup/hold + the
  channel. Use a **symmetric, centre-aligned** window (SDR centred-edge
  launch), `-max`/`-min` about the forwarded edge — never an asymmetric
  absolute window vs an internal clock (that is the 2026-05-05 hold trap).
- Include the I/O-cell + package + (if known) board/ribbon model in the
  output-delay budget; the transmitter eye is the peer's input eye.

### 2.2 Receive side (our `pad_rx[*]` + received `pad_clk_rx`)
- `create_clock` on `pad_clk_rx` (the received forwarded clock — a **real,
  timed I/O clock**, not async-everything).
- `set_input_delay` for `pad_rx[*]` **against `pad_clk_rx`**, symmetric
  centred window, modelling the channel + the *peer transmitter* launch.
- Bound the per-lane capture path the way the FPGA file does, generalised:
  - `set_max_delay -datapath_only <≤ ½ bit-period>` from `pad_rx[*]` to the
    first-stage capture FF (ASIC equivalent of
    `gpiorx_*/link_data_pad_clk_reg[*]`). `-datapath_only` keeps it a pure
    delay cap (no hold-fix insertion).
  - A **lane-to-lane skew budget** across the `pad_rx[*]` bundle (the ASIC
    analogue of `set_bus_skew`): use `set_data_check` and/or a matched
    `set_max_delay` group + an explicit skew spec so P&R **equalises**
    lane delay rather than chasing an absolute window. **Variance, not WNS,
    is the metric** — the calibrator absorbs a *bounded, balanced* skew but
    not an unbounded or lane-divergent one.

### 2.3 The ONE legitimate async cut
- `set_clock_groups -asynchronous` (or `set_false_path`) **only** between
  the **recovered-RX clock** and the **core clock** — the genuine CDC that
  Wlink internally synchronises (2-flop `sync_lane_locked_*` pattern in
  `axi_chiplet_controller.sv`; keep that discipline and CDC sign-off it).
- **Never** let that async declaration also erase `pad_rx[*] → capture`
  timing. That conflation was the FPGA root cause. The async group is
  between *clocks*; the source-sync group is *intra* the RX clock and stays
  timed.

---

## 3. Bounding static skew so the calibrator window always covers PVT

The bit-slip/phase calibrator's range is **finite and quantised to whole
bit-periods** (FPGA: 8 slips × 40 ns; on ASIC scale to the bit-period). It
corrects *dynamic + PVT* misalignment **only if static lane-to-lane and
clk-to-data skew stays inside that window across ALL corners**. Enforce by
construction:

1. **Matched / balanced datapath routing** for the lane bundle: length-
   (and, if the channel demands, impedance-/shield-) match `pad_clk_rx`
   vs each `pad_rx[n]`, and the 8 `pad_rx[n]` to each other. Treat the
   bundle as a matched group in the router.
2. **Skew budget in SDC** (`set_data_check` / grouped `set_max_delay
   -datapath_only` + explicit skew) so STA *fails* if layout exceeds the
   budget — sign-off gate, not advisory.
3. **Per-lane programmable delay cells** (the ASIC equivalent of the FPGA
   IDELAYE2): instantiate a characterised delay line per `pad_rx[n]` driven
   by the calibrator tap, mirroring the existing per-lane
   `swi_phase_offset` / `swi_bit_slip` plumbing
   (`tidelink_phy_align_calibrator.sv` already produces per-lane vectors).
   This converts "hope static skew is in range" into an explicit, swept,
   characterised delay — the proper answer the FPGA disabled-IDELAYE2
   stanza points at.
4. **Budget margin explicitly** for the I/O cell, package, and ribbon/
   channel; the calibrator window minus the worst-case static + PVT skew
   must remain > 0 at every corner, with margin.

---

## 4. Clock tree

- The **forwarded TX clock** and the **recovered RX clock** are **I/O
  clocks**, not core clocks. **Exclude them from core CTS.** Route them as
  **balanced, matched** nets straight to the lane I/O cells. Do not let CTS
  buffering inject per-lane skew into the per-lane sample clock — that
  reintroduces exactly the unbounded skew this whole document exists to
  prevent.
- The recovered RX clock fans out to the 8 capture FFs: that fan-out must be
  balanced (equalised insertion to all 8 lanes) — this is the ASIC analogue
  of the FPGA `set_bus_skew` and of the **MRCC-vs-SRCC asymmetry** that made
  the FPGA *slave* (weaker clock distribution) the unlucky side. On ASIC the
  equivalent mistake is an unbalanced recovered-clock sub-tree; balance it
  by construction and constrain it.

---

## 5. I/O-cell characterisation & hold strategy

- clk-to-data and capture setup/hold **must** use **characterised I/O-cell +
  package + (if known) board** models, not default wire-load. The eye is
  defined at the pad, through the real I/O cell.
- **Hold is a first-class part of the methodology**, designed in via matched
  routing + deliberate delay — **not** post-hoc buffer insertion. The
  2026-05-05 FPGA event (134 hold-violating endpoints from a naive absolute
  input-delay window) is the cautionary tale: bound *relative* skew and use
  `-datapath_only` caps; do not let the tool hold-pad every lane chasing an
  absolute window. Plan hold across OCV/AOCV corners.

---

## 6. CDC sign-off

- The recovered-RX → core crossing needs proper synchronisers +
  `set_clock_groups` / `set_false_path` **and** a CDC sign-off pass. The
  existing 2-flop syncs (`sync_lane_locked_*` in
  `axi_chiplet_controller.sv`, and the calibrator's own `role_locked_q` /
  `swreset_q` edge-detect) are the model — keep that discipline; add
  `ASYNC_REG`-equivalent (don't-touch / synchroniser) attributes on those
  FFs and verify with a CDC tool.

---

## 7. Quick checklist for the ASIC-target agent

- [ ] `pad_clk_rx`: `create_clock` (real I/O clock, NOT async-everything).
- [ ] `pad_clk_tx`: `create_generated_clock` from the serializer clock; set
      `-divide_by` to the real PHY ratio (≠ 1 if a true HS PLL exists).
- [ ] `pad_tx[*]`: `set_output_delay` vs `pad_clk_tx_fwd`, symmetric window,
      channel + peer-RX modelled.
- [ ] `pad_rx[*]`: `set_input_delay` vs `pad_clk_rx`, symmetric window;
      `set_max_delay -datapath_only` to first-stage capture FF; explicit
      lane-to-lane skew budget (`set_data_check`/grouped max_delay).
- [ ] `set_clock_groups -asynchronous` **only** recovered-RX ↔ core.
- [ ] Per-lane programmable delay cells wired to the calibrator tap.
- [ ] I/O clocks excluded from core CTS, routed balanced/matched.
- [ ] Characterised I/O + package (+ board) models in the budgets.
- [ ] Hold designed in (matched routing + deliberate delay), checked across
      OCV/AOCV; **no** naive absolute input-delay window.
- [ ] CDC sign-off on the recovered-RX → core crossing.
- [ ] Sign-off gate: (calibrator window) − (worst static + PVT lane skew) >
      margin at **every** corner. If not provable, layout is not done.

# Sim-Guard Feasibility — Can cocotb catch the XDC/clock-saga bug class?

**Date:** 2026-05-22  •  **Scope:** the 2026-05 "0/16 lane-lock" regression
(see `docs/LANE_LOCK_ROOT_CAUSE.md`).  •  **Verdict up front:** the two root
defects are PHYSICAL / CONSTRAINT-domain — **cocotb (event-driven RTL sim)
cannot see them directly.** What cocotb *can* guard is the FUNCTIONAL contract
around them, plus the parameter/generate plumbing that the regressor stripped.
The picosecond/placement layer must stay a **build-time** and **lint** guard.

---

## The two bugs, and which domain each lives in

| # | Bug | Domain | Visible in cocotb RTL sim? |
|---|-----|--------|----------------------------|
| A | `USE_CLKBUF`/`USE_IDELAY` stripped (`51b5169`): recovered capture clock placed on a LUT-driven net (`Place 30-568`) → hold violation → `cal_done=0` → 0/16 | **Placement / static-timing** | **NO** — sim has no routed clock network, no hold check |
| B | XDC procedural Tcl silently dropped (`Designutils 20-1307`): `IODELAY_GROUP`, pad_rx capture-skew bounds, TX-eye constraint vanished | **Constraint-domain** | **NO** — sim never reads XDC; a dropped constraint is invisible |

Both are *false-PASS* failures: the build reported PASSED and produced a
working-*looking* bitstream that locked 0/16. The danger is not "sim disagrees
with hardware" — it is "nothing flagged anything at all." That is why the
correct guards are at the layers that **do** model the missing domain.

---

## What cocotb fundamentally CANNOT model (state this plainly)

cocotb drives an event-driven HDL sim (VCS here). It has **no notion** of:

- routed clock topology — BUFG vs LUT2 vs general fabric routing are all just
  `assign clk_o = clk_i` once elaborated; `tidelink_rxclk_buf` / `tidelink_idelay_rx`
  are *bit-exact passthrough* in every non-Vivado flow (proven in their unit TBs);
- picosecond clk→data skew at an IOB, setup/hold windows, jitter, or a sub-UI
  "eye";
- the existence of an XDC file, an `IODELAY_GROUP`, or a dropped constraint.

The repo's own `cocotb/phy_align/test_phase_sweep.py` already documents the
sharpest consequence: *"in a zero-jitter RTL sim with the period-8 training
byte, ANY integer pad misalignment is correctable by bit-slip ALONE … a test
of the form 'a lane locks ONLY when phase is swept' is NOT physically
achievable."* There is no capture *eye* in RTL sim to be narrow or off-center.
Any cocotb test claiming to reproduce the hold violation would be **theatre**.

The closest the existing pair model gets to "timing" is `pad_skid.sv` /
`pad_skid_lanes.sv`, which delay data vs the forwarded clock by **integer
bit-periods** — and they forward the clock *unchanged* on purpose
(*"the bug being modelled is data-vs-clock skew, not a clock dropout"*).
Integer-bit skew is the only timing axis available; sub-cycle phase/skew is not.

---

## What cocotb CAN genuinely guard (the honest wins)

### 1. The parameter/generate plumbing the regressor actually stripped — ALREADY COVERED
Bug A was, at source level, the removal of the `USE_CLKBUF=1` / `USE_IDELAY=1`
hooks. cocotb **can** assert those generate branches still *elaborate and are
bit-exact*, and that the FPGA-only arms exist and are selectable. This already
exists and is good:
- `cocotb/tidelink_rxclk_buf/test_rxclk_buf.py` — pins `USE_CLKBUF=0` passthrough
  AND `USE_CLKBUF=1`+`TIDELINK_RXCLK_NO_PRIMITIVE` opt-out, bit-exact.
- `cocotb/tidelink_idelay_rx/test_idelay_optout_passthrough.py` — same for IDELAY.

**Gap these do NOT close:** they prove the *RTL* hooks survive; they do **not**
prove the FPGA *wrapper* still sets them to 1, nor that the packaged IP
`component.xml` still carries the default — which is *exactly* where `51b5169`
did the damage. **Recommendation:** add a tiny **build/lint check** (grep/XML
assert) that `fpga/vivado_ip/tidelink_vivado_wrapper.v` instantiates the PHY
with `USE_IDELAY(1'b1)`/`USE_CLKBUF(1'b1)` and that `component.xml` default = 1.
That is the real regressor signature, and it is a *text* check, not a sim.

### 2. The calibrator's FUNCTIONAL robustness under per-lane misalignment
The functional *consequence* the silicon bug produced — lanes failing to align —
**is** modelable as integer per-lane skew. A regression that breaks the
calibrator's per-lane independence (e.g. collapsing per-lane slip to a global
value, the `swi_phase_offset` global-broadcast regression `test_phase_sweep.py`
already guards) would re-surface as non-convergence in seconds. The prototype
adds an explicit *asymmetric-skew → must reach 16/16* assertion and a
*dead-lane → must be reported un-locked* negative control (false-PASS shape).

### 3. The wrong-bitstream / mismatched-clock class — ALREADY COVERED
`cocotb/tidelink_clkfreq_check/` (on `origin/main`) drives `local_clk` vs
`link_clk` at matched and 2:1-mismatched periods and asserts
`freq_mismatch_sticky` latches. This is the runtime guard for the
"wrong clk_wiz / wrong bitstream" provenance class and it works as designed.
No extension needed; optionally add a *slow-drift just-outside-tolerance* case
to pin the `TOL_COUNTS` boundary, but value is marginal.

---

## Best realistic guard layer per bug class

| Bug class | Best guard | Status |
|-----------|-----------|--------|
| LUT-on-clock / hold violation (Bug A, *physical*) | **Build-time** static timing + the Vivado **msg gate** (`57c2810`) escalating `Place`/`Constraints` CRITICAL WARNINGs to ERROR | **Exists** |
| Dropped XDC procedural Tcl (Bug B, *constraint*) | **Build-time** `fpga/scripts/verify_xdc.tcl` (static XDC lint) + in-build msg gate on Designutils 20-1307 | **Exists** |
| `USE_CLKBUF`/`USE_IDELAY` RTL hooks deleted/mutated | **Sim** generate/bit-exact unit TBs (rxclk_buf, idelay_rx) | **Exists** |
| FPGA wrapper / `component.xml` stops setting `USE_*`=1 (the actual `51b5169` signature) | **Build/text check** (grep wrapper + assert XML default) | **GAP — recommend adding** |
| Calibrator loses per-lane alignment robustness | **Sim** (asymmetric per-lane skid → 16/16) | partial (`test_phase_sweep`); prototype strengthens |
| Dead/uncalibratable lane silently reported good | **Sim** negative control | prototype adds |
| Wrong bitstream / mismatched recovered clock | **Sim** `tidelink_clkfreq_check` | **Exists** |
| Synth-class RTL defects (latch, incomplete case, width) | **Lint** `lint/verilator` + `cocotb/lint/sv_anti_pattern_lint.py` | **Exists** |

---

## Prototype delivered

`cocotb/phy_align/test_capture_timing_margin.py` — **DRAFT, not committed, not
in CI.** Two tests on the existing wlink_pair model:
- `test_calibrator_converges_under_asymmetric_skew` — POSITIVE: hostile
  asymmetric per-lane `pad_skid` skew must still autocal to 16/16 both ways.
- `test_dead_lane_is_reported_not_silently_passed` — NEGATIVE CONTROL: a
  `STUCK_LANES_MASK` lane must report un-locked (guards the false-PASS shape).

The file's docstring states, in-band, that it does **not** and **cannot** see
the LUT-on-clock hold violation or the dropped XDC — those stay build/lint
guards. It reuses `pad_skid` integer-bit skew (the only timing axis sim has);
it does not invent a fake picosecond eye.

**Why no cocotb test for Bug A/Bug B themselves:** infeasible by construction
(see "What cocotb CANNOT model"). The correct guards already exist at the
build/lint layer. The one *new* recommendation is a **text/XML assertion** that
the FPGA wrapper + packaged IP keep `USE_CLKBUF=1`/`USE_IDELAY=1` — that catches
the literal `51b5169` regressor far more directly than any sim could.

---

## Bottom line

- **Catchable in cocotb:** generate-branch survival + bit-exactness of the
  `USE_*` paths; calibrator per-lane alignment robustness; dead-lane
  observability; wrong-clock/mismatched-bitstream detection. (Most already
  covered; prototype adds the robustness + dead-lane assertions.)
- **NOT catchable in cocotb (do not overclaim):** the LUT-on-clock hold
  violation and the silently-dropped XDC constraint. These are
  placement/constraint-domain and are correctly guarded at **build time**
  (`57c2810` msg gate + `verify_xdc.tcl`) and **lint** (`lint/verilator`).
- **One real gap worth closing, and it is NOT a sim:** a build/text check that
  `tidelink_vivado_wrapper.v` and the packaged IP `component.xml` still set
  `USE_CLKBUF=1`/`USE_IDELAY=1`. That is the precise signature of the regressor.

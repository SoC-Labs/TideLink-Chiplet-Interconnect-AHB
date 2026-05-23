# PHY Repository Split — Design & Migration Proposal

**Status:** DESIGN ONLY. No RTL/build files modified by this document.
**Author:** dam1n19 with Claude Code assistance · 2026-05-15
**Branch context:** `feat/fpga-flow`
**Builds on (extends, does not duplicate):**
[`deps/axi-chiplet-controller/logical/phy-align/README.md`](../../deps/axi-chiplet-controller/logical/phy-align/README.md),
[`PATCHES.md`](../../deps/axi-chiplet-controller/logical/phy-align/PATCHES.md),
[`docs/TIDELINK_SPECIFICATION.md §9.10.4` (don't extract preemptively)](../../docs/TIDELINK_SPECIFICATION.md),
[`BRINGUP_REPORT.md §8.3 / §8.3b / §9`](../../BRINGUP_REPORT.md)

---

## 0. Why the old extraction sketch is now out of date (corrections to `phy-align/README.md`)

The `phy-align/README.md` sketch was written 2026-05-14 11:53, *before* the §9
APB plumbing + autonomous calibrator landed in trunk. Three of its assumptions
are now wrong and the new repo design must correct them:

| `phy-align/README.md` assumption | Reality as of 2026-05-15 | Consequence for the split |
|---|---|---|
| §9 is "in-place edits to `WavD2DGpio*.v` only", to be replaced by one wrapper `wlink_phy_align_top.v` | §9 is now **three-way entangled**: (a) in-place edits in submodule `WavD2DGpio*.v` + `WlinkGPIOPHY.v` + `Wlink.v`; (b) §9 wrapper logic (`tidelink_phy_align_regs`/`_lane_checker`/`_calibrator` instances + OR-mux) wired into submodule `logical/top/axi_chiplet_controller.sv` lines 932–1032; (c) the three `tidelink_phy_align_*.sv` source files living in **TideLink's** `src/rtl/` | The seam is no longer "one wrapper". The split must cut **two** boundaries: the Link2PHY contract (Wlink↔PHY) and the calibrator-attach contract (chiplet-controller↔PHY) |
| Control signals are "sim-only soft-strap regs driven by cocotb hierarchical force" | Real APB block (`tidelink_phy_align_regs`, 0x1000 sub-region) + autonomous FSM (`tidelink_phy_align_calibrator`, `AUTOCAL_ENABLE=1` in `tidelink_top.sv`) now exist | The new repo owns *more* than slip/training: it owns the entire calibration subsystem incl. its APB face |
| `swi_bit_slip[7:0][2:0]` is RX-only, training is TX-only | Confirmed correct, but the calibrator FSM (`state[3:0]`, `lane_fault[7:0]`, `calibration_done`) and the lane-checker (consumes `phy_link_rx_rx_link_data[127:0]` + recovered `rx_link_clk`) are new contract surface the README never enumerated | Interface spec (§1) must add the calibration/status bundle as a first-class part of the contract |

This proposal therefore **supersedes** the layout block in
`phy-align/README.md` lines 26–43 and the interface tables lines 58–98, while
keeping its core insight intact: *the `Link2PHY` bundle is the right seam, and
the §9 value-add is the new repo's property.*

---

## 1. The abstraction boundary

There are **two** contracts, not one. Naming them precisely is the whole game.

### 1.A The Link2PHY contract (Wlink-mandated — must match exactly)

Traced from `WlinkGPIOPHY.v` ports + `Wlink.v:969–1016` (`WlinkGPIOPHY phy`)
and cross-checked against `WlinkSerdesPHY.v` (the SERDES variant). Signals that
appear in **both** GPIO and SERDES wrappers are the immutable Wlink contract:

| Signal (Wlink-side net name) | Dir (PHY view) | Width | GPIO | SERDES | Notes |
|---|---|---|---|---|---|
| `clock`, `reset` | in | 1 | ✓ | ✓ | PHY APB/config clock + active-high reset |
| `auto_in_psel/penable/pwrite/pwdata/pstrb` | in | 1/1/1/32/4 | ✓ | ✓ | PHY-local APB (Wavious register block). **SERDES adds `auto_in_paddr[3:0]`; GPIO omits it** — see §3 wart |
| `auto_in_pready/prdata` | out | 1/32 | ✓ | ✓ | |
| `scan_*` (mode/asyncrst_ctrl/clk/out) | in/out | 1 | ✓ | ✓ (+`scan_shift`,`scan_in`) | DFT — pass-through |
| `por_reset` | in | 1 | ✓ | ✓ | Power-on reset |
| `link_tx_tx_en` | in | 1 | ✓ | ✓ | TX path enable |
| `link_tx_tx_ready` | out | 1 | ✓ | ✓ | PHY ready for LL_TX data |
| `link_tx_tx_link_data` | in | 128 | ✓ | ✓ | LL_TX data, 8 lanes × 16 bit |
| `link_tx_tx_lane_mask` | in | 8 | ✓ | **absent** | Per-lane TX mask (GPIO only) |
| `link_tx_tx_link_clk` | out | 1 | ✓ | ✓ | TX-side link clock |
| `link_rx_rx_link_data` | out | 128 | ✓ | ✓ | Deserialised RX data (post-slip in our GPIO) |
| `link_rx_rx_lane_mask` | in | 8 | ✓ | **absent** | Per-lane RX mask (GPIO only) |
| `link_rx_rx_link_clk` | out | 1 | ✓ | ✓ | **Recovered RX clock** — drives LL_RX domain *and* our lane-checker/calibrator |
| `user_hsclk` (GPIO) / `user_ref_clk` (SERDES) | in | 1 | ✓ | ✓ (renamed) | High-speed serial clock source |
| pad bundle: `pad_clk_tx`, `pad_tx_0..7`, `pad_clk_rx`, `pad_rx_0..7` | out/out/in/in | 1 each | ✓ | ✓ | Identical pad bundle both variants |

> Note: the README's "`link_rx_lp_entry`" signal does **not** exist on the
> generated `WlinkGPIOPHY.v` — it was speculative. The real low-power path is
> internal to Wlink's pstate ctrl, not a PHY port. Correcting the README here.

### 1.B The SoC-Labs §9 calibration contract (our value-add — optional/defaulted)

These are **not** Wavious signals. On the *pristine* GPIO PHY they do not
exist; on our patched PHY they enter via two ports added to `WlinkGPIOPHY.v` /
`Wlink.v` (`swi_bit_slip_in[23:0]`, `swi_training_mode_in`) plus the
deserialised-data tap the lane-checker reads. The new repo formalises this as a
named **`phy_align_if`** bundle so a vanilla Wavious PHY still works when it is
**tied off / absent**:

| Signal | Dir (PHY view) | Width | Default (vanilla Wavious) | Owner |
|---|---|---|---|---|
| `phy_swi_bit_slip` | in | 24 | tie `24'h0` → bit-exact passthrough | new repo |
| `phy_swi_training_mode` | in | 1 | tie `1'b0` → LL data passthrough | new repo |
| `phy_rx_link_data` (tap of `link_rx_rx_link_data`) | out | 128 | n/a (mirror) | new repo |
| `phy_rx_link_clk` (tap of `link_rx_rx_link_clk`) | out | 1 | n/a (mirror) | new repo |
| `phy_lane_locked` | out | 8 | `8'h0` if checker absent | new repo |
| `phy_lane_fault` | out | 8 | `8'h0` | new repo |
| `phy_calibration_done` | out | 1 | tie `1'b1` (SERDES self-aligns → "always done") | new repo |
| `phy_cal_state` | out | 4 | `4'h0` (ILA visibility) | new repo |
| `phy_align_apb_*` (psel/penable/pwrite/paddr[11:0]/pwdata/pstrb/prdata/pready/pslverr) | in/out | — | optional 4-reg APB slave; absent → no decode at `paddr[12]=1` | new repo |

**Design rule:** every §9 signal has a defined safe default such that *not
wiring it* yields bit-exact pristine Wavious behaviour. This is what lets the
same repo serve both "GPIO + our calibration" and "vendor SERDES BlackBox, no
calibration" with zero TideLink/Wlink changes (§3, §8).

### 1.C The contract diagram

```
                 ┌─────────────────────── wlink-phy repo ───────────────────────┐
 Wlink core ─────┤ Link2PHY (1.A, immutable)                                     │
 (axi-chiplet-   │   ┌──────────────┐      ┌──────────────────────────────────┐  │
  controller)    │   │ wlink_phy_top│      │  variant: GPIO  | SERDES(BBox)   │  │
                 │   │  PHY_VARIANT ├─────►│  WavD2DGpio*    | WavD2DSerdes*   │  │
 chiplet-ctrl ───┤   │  param       │      │  + §9 slip/train| (self-aligning)│  │
 calibrator  ◄───┤ phy_align_if     │      └──────────────────────────────────┘  │
 attach (1.B)    │ (optional, def.) │   §9: tidelink_phy_align_{regs,checker,cal} │
                 └──────────────────┴───────────────────────────────────────────┘
                                            pad bundle ──► chiplet bumps / FPGA pads
```

The §9 calibrator/checker/regs **move into the repo** and are *instantiated
inside* `wlink_phy_top` (GPIO variant only). Today they sit one level up in
`axi_chiplet_controller.sv` — the migration (§6) pulls them down across the
seam so the chiplet controller only ever sees `phy_align_if`, never the
calibrator internals.

---

## 2. Repo structure

Recommended name: **`wlink-phy`** (not `wlink-phy-align` from the old sketch —
the repo owns the *whole PHY*, GPIO + SERDES + calibration, not just the align
layer; the align layer is one feature of it).

```
wlink-phy/
  README.md                         # what this is, the two contracts, variant matrix
  CHANGELOG.md                      # SemVer log; TideLink pins a tag
  src/
    rtl/
      wlink_phy_top.sv              # NEW. Variant-selecting wrapper. Presents
                                    #   Link2PHY (1.A) + phy_align_if (1.B).
                                    #   `parameter PHY_VARIANT = "GPIO"` ("SERDES")
      gpio/
        WavD2DGpio.v                # PRISTINE Wavious (patch reverted) +
        WavD2DGpioRx.v              #   §9 applied as build-time patch (§9 wart, §3)
        WavD2DGpioTx.v
        WlinkGPIOPHY.v              # PRISTINE Wavious wrapper, unpatched
        wlink_phy_gpio_align.sv     # NEW. Glue: instantiates pristine WlinkGPIOPHY +
                                    #   the three §9 modules + OR-mux. This is the
                                    #   wrapper PATCHES.md always promised.
      serdes/
        WlinkSerdesPHY.v            # Wavious SERDES wrapper (pristine)
        WavD2DSerdes.v              # references BlackBox primitives below
        wav_serdes_bbox_stubs.sv    # NEW. Sim/lint stubs for WavD2DSerdesTx/Rx/
                                    #   PLL/RxDLL (undefined in Wavious deliverable)
      align/                        # §9, MOVED from tidelink/src/rtl/
        tidelink_phy_align_regs.sv      → rename: wlink_phy_align_regs.sv
        tidelink_lane_checker.sv        → rename: wlink_phy_lane_checker.sv
        tidelink_phy_align_calibrator.sv→ rename: wlink_phy_align_calibrator.sv
    patches/
      wavd2dgpio-bitslip-training.patch # MOVED from phy-align/, the §9 in-place diff
      apply_patches.sh              # NEW. Idempotent: applies patch to gpio/ tree
      PATCHES.md                    # MOVED + updated from phy-align/PATCHES.md
  flist/
    wlink_phy_gpio.flist            # gpio/ + align/ + wlink_phy_top
    wlink_phy_serdes.flist          # serdes/ + bbox stubs + wlink_phy_top
    wlink_phy_serdes_asic.flist     # serdes/ WITHOUT bbox stubs (integrator fills)
  cocotb/
    phy_only/                       # NEW. Pad-bundle stimulus → observe Link2PHY
      Makefile
      tb_phy_top.sv                 # drives pad_rx*, observes link_rx_rx_link_data
      pad_skid.sv                   # MOVED from tidelink/cocotb/wlink_pair/
      test_phy_align.py             # ports tidelink/cocotb/phy_align/test_pair_align*
      test_phy_passthrough.py       # vanilla: slip=0, training=0, bit-exact
      test_phy_autocal.py           # calibrator end-to-end, no SW
  fpga/
    constraints/
      wlink_phy_gpio.xdc            # any PHY-local IO/timing fragments (today: none
                                    #   PHY-specific in tidelink xdc; placeholder)
  docs/
    interface_spec.md               # §1.A + §1.B formalised, the export surface
    calibration_protocol.md         # ported from BRINGUP_REPORT.md §9.3/§9.6
    serdes_integration.md           # the "day we swap" runbook (§8 of this doc)
    upstream_regen.md               # how to re-cut Wavious + re-apply §9 (§9 risk)
```

The three `tidelink_phy_align_*.sv` are renamed `wlink_phy_*` on the move to
drop the TideLink coupling in the module names (they have **zero** TideLink
dependencies today — verified: pure SV, parameterised, no TideLink package
imports — so the rename is mechanical).

---

## 3. GPIO ↔ SERDES substitution mechanism

### Decision: **single `wlink_phy_top.sv` wrapper with `parameter PHY_VARIANT`,
backed by per-variant flist selection.** Both layers, deliberately.

Why both, not one:

- **The parameter** gives a single synthesizable top with a clean
  `generate`-`case (PHY_VARIANT)` body. TideLink/Wlink instantiate exactly one
  module name forever; switching variant is a one-line parameter override.
- **The flist** is *also* required because the GPIO and SERDES variants pull in
  **disjoint, non-coexisting** Verilog sets (`WavD2DGpio*` vs `WavD2DSerdes*` +
  BlackBox stubs), and SERDES drags `WavD2DSerdesPLL`/`WavD2DRxDLL` BlackBoxes
  that **must not** be compiled in a GPIO build (they're undefined). A pure
  parameter with both trees in one flist would fail elaboration on the absent
  SERDES primitives. So: `PHY_VARIANT` selects the `generate` arm; the matching
  `flist/wlink_phy_<variant>.flist` selects which RTL set is even read.

Trade-offs considered and rejected:

| Mechanism | Verdict | Reason |
|---|---|---|
| File-list swap only (no param) | reject | Two different top module names → TideLink/Wlink instantiation differs per variant. Breaks "zero TideLink change" goal |
| Parameter only (one flist, both trees) | reject | SERDES BlackBoxes undefined → GPIO build won't elaborate. Also doubles compile of dead RTL |
| `define`-based `ifdef WLINK_PHY_SERDES` | reject | Global defines leak across the whole TideLink compile; fragile with mixed cocotb/UVM/FPGA front-ends. Parameter is locally scoped |
| **Parameter + per-variant flist (chosen)** | **accept** | One module name; clean elaboration; dead RTL never read; variant is a 1-line override + 1 flist line |

### The §9 calibration layer under SERDES

The SERDES variant **self-aligns internally** (BRINGUP_REPORT §8.3: the
proprietary primitive does CDR + bit-slip + eye calibration; the Wavious SERDES
APB map has no `swi_phase_offset`, no bit-slip — confirmed: no `swi_*` ports on
`WlinkSerdesPHY.v`/`WavD2DSerdes.v`). So §9 must be a **no-op shim, not deleted
code**, when `PHY_VARIANT="SERDES"`:

- `wlink_phy_top` `generate` SERDES arm **does not instantiate** the
  calibrator/checker/regs.
- It **ties the `phy_align_if` outputs to safe constants**:
  `phy_lane_locked = 8'hFF`, `phy_calibration_done = 1'b1`,
  `phy_lane_fault = 8'h0`, `phy_cal_state = 4'h0`.
- `phy_swi_bit_slip`/`phy_swi_training_mode` inputs are simply **unconnected**
  inside the SERDES arm.
- The optional `phy_align_apb_*` slave still answers (returns `done=1`,
  `locked=0xFF`, RO) so existing bring-up firmware that polls
  `SWI_CALIBRATION_DONE` **works unchanged** against SERDES — it just sees
  "instantly calibrated". This is the key to "zero firmware change on swap".

So the chiplet-controller / TideLink always sees the same `phy_align_if`; with
SERDES it reports permanent lock. The calibration RTL is *bypassed by
construction* (not compiled in the SERDES flist), not gated at runtime.

---

## 4. Dependency wiring

### Decision: **`wlink-phy` is a git submodule of TideLink** (matching the
existing `deps/axi-chiplet-controller` pattern), with the Wlink protocol
**staying in `axi-chiplet-controller`**.

Rationale:

- TideLink already uses git submodules for `deps/axi-chiplet-controller` and
  `deps/xhb500` (verified `.gitmodules`). FuseSoC is **not** in use anywhere in
  this build (the FPGA flow is flist→`filelist.tcl`→Vivado `read_verilog`; ASIC
  is flist→synth). Introducing FuseSoC purely for the PHY would add a build
  system the rest of the repo doesn't speak. Submodule is consistent.
- Vendored copy rejected: the whole point is independent versioning + a clean
  upstream-Wavious-regen story (§9). A vendored copy reintroduces the
  entanglement we're removing.

### De-entanglement (the hard part)

Today the Wlink protocol and the GPIO PHY are **the same Chisel elaboration**:
`Wlink.v` *instantiates* `WlinkGPIOPHY phy` directly (line 969), and the §9
in-place edits touch `Wlink.v` (the `swi_*_in` pass-through ports lines
143–144, 1014–1015), `WlinkGPIOPHY.v`, and `WavD2DGpio*.v` — **all inside the
axi-chiplet-controller submodule**. Plus the §9 *wrapper* logic is in that
submodule's `axi_chiplet_controller.sv`.

The de-entanglement establishes the Link2PHY bundle as a true module boundary:

1. **Wlink protocol stays** in `axi-chiplet-controller`. Its generated `Wlink.v`
   keeps instantiating a module *named* `WlinkGPIOPHY` (no Chisel change), but
   that name is **resolved by flist order** to the `wlink-phy` repo's
   `wlink_phy_top` (wrapped/aliased), **not** the submodule's copy.
2. The submodule's `logical/wlink/WlinkGPIOPHY.v` + `WavD2DGpio*.v` are
   **removed from TideLink's flists** and the canonical copies live in
   `wlink-phy/src/rtl/gpio/`. The submodule retains them only as Chisel-regen
   artefacts (not compiled by TideLink).
3. The §9 wrapper logic currently in submodule
   `axi_chiplet_controller.sv:932–1032` **moves into `wlink_phy_top`**. The
   chiplet controller is reduced to driving the `phy_align_if` bundle (or
   ignoring it). This is the single biggest code move and is migration step M4
   (§6).
4. The seam is then literally: `axi-chiplet-controller` exports the Link2PHY +
   `phy_align_if` port list; `wlink-phy` implements it. Two repos, one
   documented contract (`wlink-phy/docs/interface_spec.md`).

> Open question for the human (§9 #1): step 1 requires the submodule's
> `Wlink.v` to *not* also supply a `WlinkGPIOPHY` definition (else duplicate
> module). Options: (a) keep the submodule's `WlinkGPIOPHY.v` out of TideLink
> flists (chosen — least invasive, flist-only); (b) post-regen script strips it.
> (a) is in the migration plan.

---

## 5. Build-flow impact

All changes are **flist indirection**, no logic changes. Concretely:

### 5.1 `flist/tidelink_fpga.flist` (and `tidelink_top_full_asic.flist`)

Today (verified):
- lines ~68–110: enumerate `deps/.../logical/wlink/*.v` incl.
  `WlinkGPIOPHY.v`, `WavD2DGpio*.v`
- `flist/tidelink_fpga.flist:209`–212: the three `src/rtl/tidelink_phy_align_*.sv`
- `tidelink_top_full_asic.flist:183`–185: same three

Change to: replace the `WlinkGPIOPHY.v` + `WavD2DGpio*.v` lines and the three
`tidelink_phy_align_*.sv` lines with **one include of the PHY repo's flist**:

```
// ── Wlink GPIO PHY + §9 alignment (extracted: deps/wlink-phy) ──────────────
-f ${TIDELINK_HOME}/deps/wlink-phy/flist/wlink_phy_gpio.flist
```

`filelist.tcl` already `[subst]`s `${VAR}` and skips `//` comments
(verified lines 49–90) — but it does **not** today handle `-f <flist>`
recursion. **One small `filelist.tcl` change is required**: when a parsed line
matches `-f *`, recurse into that flist. ~6 lines of Tcl. This is the only
non-flist build change. (UVM/cocotb Makefiles use plain flists with the same
`${TIDELINK_HOME}` convention; they need the same recursive-`-f` handling or a
pre-flattened flist — recommend a `make flatten-flist` helper that inlines
`-f` for tools without recursion.)

### 5.2 `fpga/filelist.tcl`

Add the `-f` recursion (~6 lines, §5.1). No other change — it already resolves
`${TIDELINK_HOME}` via `[subst]`; the PHY flist uses the same placeholder set.

### 5.3 `fpga/Makefile` `package_ip`

No change. `package_ip` consumes `filelist.tcl`; once that recurses into the
PHY flist the packaged IP picks up the PHY automatically. `FPGA_COMPONENT_FILELIST`
stays pointed at `fpga/filelist.tcl`.

### 5.4 cocotb / UVM Makefiles

- `cocotb/wlink_pair/Makefile`, `cocotb/phy_align/Makefile`,
  `uvm/tidelink_top_system/*/Makefile`: swap the explicit
  `tidelink_phy_align_*.sv` + `WavD2DGpio*.v` source lines for
  `-f $(TIDELINK_HOME)/deps/wlink-phy/flist/wlink_phy_gpio.flist` (or the
  flattened variant for simulators without `-f` recursion — Verilator/cocotb
  supports `-f`; check the UVM compile script's front-end).
- New: `wlink-phy/cocotb/phy_only/` is **self-contained** (no TideLink deps) so
  the PHY repo CI runs it standalone (§7).

### 5.5 The §9 patch application

`flist/...` references `gpio/WavD2DGpio*.v` which are **pristine** in the repo;
the §9 behaviour comes from `gpio/wlink_phy_gpio_align.sv` (the wrapper) — so
**no patch application at build time** in the chosen end-state. The
`patches/wavd2dgpio-bitslip-training.patch` is retained only for the *legacy
in-place* path and for Wavious-regen reconciliation (§9), not for normal builds.

---

## 6. Migration sequence (validation-gated, rollback at each step)

**Hard constraint:** must not block or conflict with the in-flight §9
integration captured in `docs/TIDELINK_SPECIFICATION.md` §9.10
(APB plumbing 2.1, autocal FSM 2.2 — *already partly landed*: regs+calibrator
exist in trunk). The §9 work and the extraction are **sequenced, not parallel**:
finish §9 functional acceptance *first* on the entangled tree, then extract
without behaviour change. The split is a **refactor with a bit-exact gate**, not
a feature.

| Step | What moves | Validates it | Rollback |
|---|---|---|---|
| **M0. Gate** | nothing | §9 acceptance met on entangled tree: `docs/TIDELINK_SPECIFICATION.md §9.10` as-built criteria — UVM `test_align_uniform_skew` PASS end-to-end, cocotb autocal PASS, FPGA pair links up. **Do not start M1 until this is green.** | n/a (precondition) |
| **M1. Create repo, copy-only** | New `wlink-phy` repo; **copy** (not move) pristine `WlinkGPIOPHY.v`+`WavD2DGpio*.v` + the three `tidelink_phy_align_*.sv` (renamed). Write `wlink_phy_top.sv` + `wlink_phy_gpio_align.sv` wrapper replicating exactly the `axi_chiplet_controller.sv:932–1032` wiring. TideLink **still uses its own copies** (flists unchanged). | `wlink-phy/cocotb/phy_only` passes standalone (ports of existing `cocotb/phy_align` tests). Bit-exact vs trunk RTL sim. | Delete repo. TideLink untouched. |
| **M2. Add submodule, dual-build** | Add `wlink-phy` as `deps/wlink-phy` submodule. Add `filelist.tcl` `-f` recursion. Create `flist/tidelink_fpga.flist.phy_split` (a *copy* pointing at the PHY flist) — do **not** switch the default flist yet. | Build TideLink FPGA + run full cocotb/UVM with the `.phy_split` flist; diff against the default-flist run: **identical pass set + identical waveforms on the Link2PHY bundle**. | Use default flist; `.phy_split` is inert. |
| **M3. Cut over flists** | Switch `flist/tidelink_fpga.flist` + `tidelink_top_full_asic.flist` + cocotb/UVM Makefiles to the PHY-repo `-f` line. Remove the now-dead `WlinkGPIOPHY.v`/`WavD2DGpio*.v`/`tidelink_phy_align_*.sv` lines from TideLink flists (files still physically present in submodule, just not compiled). | Full regression: cocotb `wlink_pair`+`phy_align` (14 tests), UVM align suite, ASIC synth+LEC (the `tidelink_top_full_asic.flist` path — LEC must show **zero new** non-equivalence vs M2). FPGA pair deploy. | `git revert` the flist commit; submodule stays, harmless. |
| **M4. Pull §9 wrapper down across the seam** | Delete the §9 wrapper block from submodule `axi_chiplet_controller.sv:932–1032`; it now lives only in `wlink_phy_top`. Chiplet controller drives/ignores `phy_align_if`. Restore submodule `WavD2DGpio*.v`/`Wlink.v`/`WlinkGPIOPHY.v` to **pristine Wavious** (revert the in-place §9 patch in the submodule). | Identical full regression as M3. This is the step that actually *removes the entanglement* — gate is again bit-exact behaviour + LEC clean. | Revert the submodule + chiplet-controller commits together (they're coupled — tag both). |
| **M5. Versioning live** | Tag `wlink-phy v1.0.0`. Pin submodule to the tag. Document the contract in `interface_spec.md`. | TideLink CI pins+builds the tag; green. | Pin to previous submodule SHA. |

Each step's validation is the **same regression suite**; the invariant is
"behaviour is bit-exact across the boundary move". The split never changes
function — if any step changes a waveform on the Link2PHY bundle, that step is
wrong, not the gate.

---

## 7. Versioning + CI

- **Versioning:** `wlink-phy` uses **SemVer tags** (`v1.0.0`). MAJOR =
  Link2PHY or `phy_align_if` contract change (forces TideLink work); MINOR =
  new variant / new optional `phy_align_if` signal with a default / calibration
  algo improvement; PATCH = bugfix, no contract change. `CHANGELOG.md` records
  which contract (1.A vs 1.B) moved.
- **TideLink pins** the PHY by **submodule SHA pinned to a release tag** (same
  as `axi-chiplet-controller` today). TideLink records the expected tag in
  `flist/tidelink_fpga.flist.md` (the existing flist-doc convention) so a human
  reviewing a bump sees the version delta.
- **PHY-repo CI** (`wlink-phy/.gitlab-ci.yml`): runs `cocotb/phy_only`
  standalone on **both** flists — `wlink_phy_gpio.flist` (full functional incl.
  autocal sweep `SKID_BITS ∈ {0,1,3,5,7}` + asymmetric) and
  `wlink_phy_serdes.flist` (elaboration + passthrough with bbox stubs:
  `phy_calibration_done==1`, `phy_lane_locked==0xFF`). Lint (`verilator
  --lint-only -Wall`) on `align/` + `wlink_phy_top` + `gpio_align` wrapper.
- **Bump validation in TideLink:** a PHY tag bump opens a TideLink MR that runs
  the **full** cocotb `wlink_pair`+`phy_align` + UVM align suite + one FPGA
  pair-board smoke (deploy_pair) against the new tag *before* the submodule
  pointer merges. A PHY MINOR/PATCH that fails TideLink regression is not
  adopted; MAJOR triggers a tracked TideLink integration task.

---

## 8. The SERDES future — "the day we swap" runbook

Goal restated: **zero TideLink change, zero Wlink-protocol change, zero
bring-up-firmware change.** Concretely, on swap day:

1. **`wlink-phy` side:** ensure `serdes/` tree is present (it is, copied from
   `deps/.../wav-wlink-hw/output_tidelink/`). Fill the four BlackBoxes
   (`WavD2DSerdesTx`, `WavD2DSerdesRx`, `WavD2DSerdesPLL`, `WavD2DRxDLL` —
   **all undefined in the Wavious deliverable**, confirmed) with the vendor
   macro: either real PDK macros in `serdes/vendor/` or, for sim,
   `wav_serdes_bbox_stubs.sv` (loopback model). `WlinkSerdesPHY.v`/
   `WavD2DSerdes.v` are pristine and need no edit.
2. **`wlink_phy_top` change:** none to the wrapper logic — the SERDES
   `generate` arm already exists from M1 (it instantiates `WlinkSerdesPHY` and
   ties `phy_align_if` to "always calibrated", §3). The *only* change is the
   **instantiating parameter**: `PHY_VARIANT="SERDES"`.
3. **TideLink side:** **one line** — the FPGA/ASIC flist swaps
   `-f .../wlink_phy_gpio.flist` → `-f .../wlink_phy_serdes_asic.flist`, and
   the `wlink_phy_top` instantiation parameter override flips to `"SERDES"`
   (this override lives in `axi-chiplet-controller`'s Wlink wrapper, not
   TideLink RTL — so arguably *zero* TideLink-repo change; it's a PHY-repo +
   chiplet-controller-flist change). The chiplet controller's `phy_align_if`
   wiring is **unchanged** — it still reads `phy_calibration_done` (now
   constant 1) and `phy_lane_locked` (now constant 0xFF).
4. **§9 disable mechanism:** by **construction, not runtime gate** — the
   `wlink_phy_serdes*.flist` does not include `align/` at all, so the
   calibrator/checker/regs are *not compiled*. `phy_align_if` is sourced from
   the SERDES arm's constant ties. No `AUTOCAL_ENABLE`-style flag needed; the
   feature is simply absent in the SERDES build. Bring-up firmware that polls
   `SWI_CALIBRATION_DONE`/`SWI_LANE_LOCKED` over the optional `phy_align_apb_*`
   slave still gets sane RO values (done=1, locked=0xFF) so **the deploy
   scripts and UVM tests run unmodified**.
5. **New PHY-repo tests required:** `cocotb/phy_only/test_phy_serdes_loopback.py`
   (bbox loopback model: data integrity through the SERDES path),
   `test_phy_serdes_passthrough.py` (asserts `phy_align_if` constants),
   and an elaboration-only CI job for `wlink_phy_serdes_asic.flist` (no stubs —
   catches integrator-fill port-mismatch early). No new TideLink-side tests.

The whole swap is then: fill 4 BlackBoxes + flip 1 flist line + 1 parameter.
That is the entire payoff of doing the extraction with the right seam now.

---

## 9. Risks + open questions for the human

| # | Risk / question | Analysis | Recommended decision |
|---|---|---|---|
| 1 | **Upstream Wavious Wlink regen overwrites the §9 in-place mods** (PATCHES.md states this explicitly: regen rewrites `WavD2DGpio*.v`/`Wlink.v`). **THE single biggest risk.** | After extraction, TideLink's flists no longer compile the submodule's `WavD2DGpio*.v`, so a Wavious regen in the submodule **cannot silently break TideLink's PHY** — TideLink uses the `wlink-phy` copy. The risk moves to: *how does `wlink-phy` adopt a new Wavious generation without losing §9?* | **Mitigation = the wrapper, not the patch.** End-state §9 lives in `wlink_phy_gpio_align.sv` (a *wrapper* around pristine `WlinkGPIOPHY`), **not** as in-place edits — so a Wavious regen drops in as new pristine `gpio/*.v` and the wrapper is untouched. The `.patch` is kept only as the *legacy* path + a `docs/upstream_regen.md` runbook: regen → diff ports → if Link2PHY unchanged, wrapper just works; if changed, that's a MAJOR PHY version. **This is why M4 (wrapper-ise) is mandatory, not optional.** |
| 2 | M4 reverts in-place edits in the **submodule** (`axi-chiplet-controller`) — a submodule the human may not control write access to | The §9 in-place edits and the `axi_chiplet_controller.sv` wrapper block are *committed in the submodule's working tree* (`git status` shows `m deps/axi-chiplet-controller`). M4 needs a submodule branch/MR. | Confirm push rights / fork strategy for `axi-chiplet-controller` before M4. If no write access: keep the submodule's `Wlink.v` pass-through ports (they're harmless tie-able inputs) and only remove the *wrapper block*; accept the pass-through ports as permanent benign Wavious-fork delta documented in `upstream_regen.md`. |
| 3 | `Wlink.v` instantiates `WlinkGPIOPHY` by **name**; flist-order module resolution to substitute the `wlink-phy` copy is fragile across tools | Verilator/Vivado/synth resolve duplicate module names differently; some error on duplicate, some take first-in-flist. | Make it explicit, not order-dependent: M3 *removes* the submodule's `WlinkGPIOPHY.v` from TideLink flists entirely (one definition only). Tested per-tool at M2/M3 gates. Documented as open verification item per front-end. |
| 4 | SERDES BlackBox fill is **vendor-proprietary and not in hand** | All 4 SERDES primitives undefined in the Wavious deliverable. The "swap day" runbook is unexecutable until a real SERDES IP exists. | Accept: the proposal makes the *structure* ready (M1 builds the SERDES arm + stubs now), so the swap is a 1-day integration when IP arrives — not an architecture change. Track as a dependency, not a blocker. |
| 5 | Repo name: `wlink-phy` couples it to Wlink; a future non-Wlink protocol consumer (README's stated extraction trigger) would find the name misleading | The Link2PHY contract *is* Wlink-shaped; honest to name it so. | Keep `wlink-phy`. If a non-Wlink consumer appears, that's a contract generalisation (new MAJOR), nameable then. Don't over-abstract pre-emptively (matches `docs/TIDELINK_SPECIFICATION.md §9.10.4`: don't extract preemptively). |
| 6 | Timing: `docs/TIDELINK_SPECIFICATION.md §9.10.4` says don't extract until a real trigger (~1 day work in the original plan) | This proposal is bigger than 1 day because the entanglement grew (§0). The trigger discipline still applies. | **This document is the plan, not the trigger.** Hold execution until a trigger fires (Wavious upgrade arriving / second PHY consumer / SERDES IP delivery / IP release). Then M0–M5 is ~3–4 days, not 1. |

---

## 10. Summary of decisions

| Topic | Decision |
|---|---|
| Repo name | `wlink-phy` (owns GPIO + SERDES + §9 calibration; align is one feature) |
| Substitution mechanism | `parameter PHY_VARIANT` in `wlink_phy_top.sv` **+** per-variant flist (`wlink_phy_gpio.flist` / `wlink_phy_serdes*.flist`) |
| Dependency wiring | git **submodule** `deps/wlink-phy`, pinned to SemVer tag; Wlink protocol stays in `axi-chiplet-controller`; Link2PHY + `phy_align_if` is the seam |
| §9 under SERDES | **bypassed by construction** — SERDES flist omits `align/`; SERDES `generate` arm ties `phy_align_if` to "always calibrated" (`done=1`, `locked=0xFF`); firmware unchanged |
| §9 in-place wart | replaced by a **wrapper** (`wlink_phy_gpio_align.sv`) around pristine Wavious; `.patch` retained only as legacy + regen-reconciliation aid |
| Biggest risk | Wavious regen vs §9 → mitigated by the wrapper (M4 makes it mandatory) + `docs/upstream_regen.md` |
| Sequencing | Gated *after* §9 functional acceptance; M0–M5 is a bit-exact refactor, never a behaviour change |

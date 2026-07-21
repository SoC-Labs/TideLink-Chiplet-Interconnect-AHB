# KR260 RX capture-clock tree — status, the real fix, and what R3 could do (2026-07-17)

Lane **R3** of the KR260 recovery plan (`docs/KR260_RECOVERY_PLAN_2026_07_17.md`).
Scope: `fpga/targets/kr260-pair-*/` (tcl+xdc) and `fpga/docs/`. This lane may **not**
edit `src/rtl`.

## TL;DR

- The **proven** capture-clock-tree fix is **RTL, not a constraint**, and it is **not on
  `integ/consolidation-2026-07`**. It cannot be ported by editing XDC/tcl.
- Therefore R3 delivered the **safe, in-lane** parts only: documentation of the situation
  inside the constraint file, a **DORMANT** (opt-in) placement mitigation, and a **post-route
  structural check** (`verify_capture_clock_kr260.tcl`) that fails loudly when the clock tree
  is defective.
- **Action for the RTL/flist lane (out of R3's scope):** cherry-pick `2c32c2b` onto integ and
  re-`package_ip`. No kr260 BD/XDC change is then needed.

## The defect (unchanged from the root-cause assessment)

The 8 per-lane RX capture mux chains are **lane-identical by construction** in
`WavD2DGpio_v2` (`io_pad_clk`, `io_pol = out_prepend_swi_polarity`, scan nets are all
common). Vivado legally **merges** them into one LUT and drives all 8 lanes' capture flops
(`gpiorx_*/link_data_pad_clk_reg[*]`) from its output — a **fanout-372 general-routing** net
(routed name `...g_word_pin_auto.wpa_gap_q[*]_i_*`, the `pad_clk_inv_scan_mux`). Its
placement varies every build → few-hundred-ps inter-lane capture-clock skew → the
all-lanes-AND SYNC commit gate turns that into a **bring-up lottery** (measured on KR260,
2026-07-17: die_a 1/4 vs die_b 4/4; KR260 inherits the z2 defect). It is **physical /
placement**, not logic.

## What EXISTS (surveyed) — separated by whether it has landed

| Item | What it is | On `integ`? | Attacks the capture **clock** LUT? |
|---|---|---|---|
| `b5f3c8c` "pblock the RX capture logic" | XDC: `pblock_rx_act` confines the capture **flops** to `X0Y0:X0Y1`; deletes the dead `set_bus_skew`; `set_max_delay 8 ns`; `IOB FALSE` | **YES** (already in the 4 kr260 pair XDCs) | **No** — pins the loads, not the clock driver |
| `4b5cee1` mirror `pblock_rx_act` into die_a (z2) | z2-only pblock symmetrization | yes (z2 only) | No |
| **`2c32c2b` "hoist the RX capture-clock mux chain into the parent + 2 shared BUFGs"** | **RTL**: new `src/rtl/local_overrides/WavD2DGpioRx_v2.v` + edits to `WavD2DGpio_v2.v`; new param **`USE_SHARED_CAP_BUFG`** (defaults to `USE_CLKBUF=1`); flist re-point. **Touches ZERO xdc/tcl.** | **NO** — only on `phaseB/attack` | **YES — this is the fix** |
| `84355b7` | cherry-pick of `2c32c2b` onto `wip/rate-ladder` (rung0) | NO (`wip/rate-ladder` only) | YES |
| `83a531b` / `bccd96f` `USE_CAP_CLKBUF` | **REJECTED** — bypasses the `io_pol` mux; inverts the deliberate mid-cell sample; **kills the link** | n/a | — (booby-trapped) |

Measured effect of the real fix (routed z2 DCPs, from `84355b7`): inter-lane capture-clock
skew **1.781 ns → 0.244 ns (7.3×)**; driver **LUT2 → BUFG**; BUFG usage 15→17/32.

### Why it can't be a constraint

A constraint can neither **un-merge** the lane-identical mux nor **insert a BUFG** on the
LUT-output clock net. The only two behavioral routes are (a) the RTL hoist [correct] or (b) a
post-synth netlist edit that inserts a BUFG on the *post-mux* net [fragile, unmeasurable here,
and out of R3's constraint-only lane]. Bypassing the mux (`USE_CAP_CLKBUF`) is fatal because
`out_prepend_swi_polarity` resets to `1'b1`, so the capture flops are meant to sample on the
**inverted** edge. **Do not enable `USE_CAP_CLKBUF`.**

## What R3 IMPLEMENTED (all in-lane, all inert for z2)

Files changed: the **shared** `kr260_tidelink_timing.xdc` (edited in the source-of-truth
`kr260-pair-ptp`, then copied byte-identically into `-nptp`, `-flip-ptp`, `-flip-nptp`; all
four md5-match) + two new files under `fpga/docs/`. **No z2 target file was touched.**
`kr260-pair-onchip` has **no timing XDC** and wires the two dies PL-internally (no ribbon, no
pad capture) — the constraint fix does not apply; it would still benefit from the RTL fix.

1. **Documentation inside the constraint file** — replaced the stale "residual suspect …
   tracked separately" note (which predated the fix) with the current root cause, the RTL
   fix + its measured numbers, the "constraint cannot replicate it" reasoning, the
   `USE_CAP_CLKBUF` warning, and a pointer to the verify script.

2. **`(3c-iii)` DORMANT capture-clock-driver co-location** — a commented, opt-in
   `add_cells_to_pblock` that would pull the merged clock-driver LUT into the same
   clock-region column as the flops it feeds (shorter clock net → less placement-varying
   skew). It is **disabled** and mirrors the existing disabled-block convention of section
   `[5]`. It is a **partial** mitigation only, and disabled because: (i) the real fix is the
   RTL BUFG; (ii) the exact driver cell name is only reliable from a **routed** report, and a
   guessed `-quiet` filter would **silently no-op** — and the `xdc_lint` no-procedural-Tcl
   rule forbids an inline fail-loud guard; (iii) pinning a fanout-372 clock LUT into a narrow
   column can route **worse** and must be validated before/after. The block carries the
   enable recipe.

3. **`verify_capture_clock_kr260.tcl`** (post-route structural check) — reports the
   capture-clock net's **driver ref-name** (BUFG* = fixed, LUT/general route = defective),
   fanout, best-effort per-lane route-delay spread, and dumps `report_clock_utilization` +
   `report_route_status` for the net. **Exit 0 = fixed, exit 1 = defective / flops not
   found.** This is the acceptance gate for the recovery build and for confirming the RTL fix
   when it lands. (It lives in `fpga/docs/` to stay in R3's lane; promote it to `fpga/scripts/`
   with the tooling lane, R5.)

## Risk assessment

| Change | Could it break a build? | How to detect at build time |
|---|---|---|
| XDC comment rewrite | No — comments only. | `xdc_lint` clean (verified: `OK — no XDC anti-patterns`). |
| Dormant `(3c-iii)` block | No — fully commented; stripped by `xdc_lint` and ignored by Vivado. | If someone **enables** it: the build log should show `pblock_rx_act` gaining the driver cell; run the verify script and compare per-lane skew before/after. A wrong cell name → `-quiet` matches nothing → **silent no-op** (this is exactly why it ships disabled). |
| verify tcl | No — read-only queries; not run in the build flow. | Its own exit code (0/1) and `PASS:`/`FAIL:` strings. |
| Cross-lane hazard | R1 edits `tidelink_design.tcl` in the same targets. R3 touched **only** `kr260_tidelink_timing.xdc`, and deliberately did **NOT** run `kr260_resync.sh` (which would rewrite `tidelink_design.tcl` from the source-of-truth and could clobber R1). | `git diff --stat` should show only the timing XDC + `fpga/docs/*` for R3. |

**Build-log strings to check** (recovery build, per G2): the capture-clock defect is *not*
detectable from WNS/WHS (it is source-synchronous relative skew that Vivado does not report as
a violation). The **only** reliable signal is the post-route verify script's driver ref-name.
Secondary sanity from the existing constraints: `report_bus_skew` says "No bus skew
constraints" (expected — `set_bus_skew` is deliberately deleted on KR260) and `pblock_rx_act`
should report ~8 cells (if 0, the `link_data_pad_clk_reg[*]` pattern drifted and both the
pblock and the verify script are inert).

## Recommended path (ordered)

1. **Land the RTL fix (preferred, out of R3's lane).** RTL/flist lane: cherry-pick `2c32c2b`
   onto `integ`, `export TIDELINK_PHY_V2=1`, `make -C fpga package_ip`, rebuild the four
   `kr260-pair-*`. `USE_SHARED_CAP_BUFG` auto-tracks `USE_CLKBUF=1`, so **no kr260 BD/XDC
   change is needed**. Then run `verify_capture_clock_kr260.tcl` on each routed design →
   expect `PASS` (BUFG driver).
2. **If the RTL fix cannot land for the recovery build:** accept lottery bring-up, run
   bring-up statistics at N≥8/die (per G3), and only then consider enabling the dormant
   `(3c-iii)` co-location with a routed-report cell name + a measured before/after. Never
   enable `USE_CAP_CLKBUF`.

# TideLink FPGA bring-up — CONVERGED diagnosis + the fix decision

_2026-05-19. The problem is no longer "not converging." It is netlist-proven,
physical causes are ruled out by a HW swap test, and the fix is specified.
This supersedes all earlier next-steps._

## The fully converged causal chain (each step evidence-backed)

1. **PHY is sound; not a lottery, not a deadlock, not the bitstream.**
   v1 HW (consolidated b_combined, S_HOLD+T3+IDELAYE2+FCSM-sticky, md5-unique,
   IDELAYE2 in routed netlist): NOT converged, best 9/16, but a *stable
   structural directional asymmetry*, fault=0x00 (calibrator healthy).
2. **Deploy methodology fixed (v2).** v1 did one deploy + 20 recals; but
   `WavD2DGpioRx.count` (the word-skew = the real lottery variable) is frozen
   at role_lock and `swreset`/recal does NOT re-sync it. v2 re-deploys both
   boards in parallel per iteration (re-rolls the skew) + best-of-N read.
3. **SWAP test → physical RULED OUT, failure is LOGICAL.** Dead side =
   die_a / non-flip target / `pad_clk_rx`=Y7-MRCC, `cal_done=0` always,
   0–3 lanes. Alive side = die_b / flip / Y9-SRCC, `cal_done=1`, up to 7/8.
   The dead side **followed the bitstream/role, not the board or ribbon**
   (NORMAL and SWAPPED). Not a damaged conductor, not a bad pin.
4. **Netlist-proven root cause (from the routed impl reports, not theory).**
   `pad_clk_rx` is NOT on a dedicated clock network. It is
   `IBUF → BUFG → fabric-LUT2 (io_pol/scan clock-mux) → BUFG`, and lanes
   **1–7's `link_data_reg` capture stage is clocked by a LUT through general
   routing** — 7× `Place 30-568` "a LUT is driving the clock pin of 16
   registers … large hold violations". The 8 capture sites span 5 clock
   regions. **This structure is byte-identical in both targets** (the flip
   build has the same 4 BUFGs + same 7 LUT-clock warnings) — so MRCC-vs-SRCC
   was always a red herring; Y7 vs Y9 merely lands that LUT-clock's *fixed*
   insertion skew inside (Y9) vs outside (Y7) the calibrator window. Stable
   per bitstream ⇒ exactly the swap-test result. Every XDC comment ("Vivado
   infers a BUFG / dedicated clock network", "SRCC weaker than MRCC") is
   **false against the implemented netlist** and tuned with the asymmetry
   sign backwards.
5. **The clock-mux selects are static — bypassing them is SAFE.**
   `io_pol` = `out_prepend_swi_polarity` (APB SW reg, reset 0, never written
   by the calibrator or `deploy_pair.sh`); `scan_mode`=0 on FPGA. Both are
   constant 0 in the bring-up flow, so removing them from the clock path does
   not change functional behaviour.

## The fix (specified; this is the remaining work)

Goal: the recovered RX clock must reach all 8 lane capture/IDELAYE2 regs on
a **clean global-buffer network**, not via per-lane fabric LUTs. Three
options, increasing robustness / blast-radius:

- **(A) XDC-mitigation only** (lowest risk, may be insufficient):
  new `pynq_z2_tidelink_clk.xdc` in both targets (wired impl-only like
  `_drc.xdc`): `set_property CLOCK_DEDICATED_ROUTE BACKBONE` + force
  `CLOCK_BUFFER_TYPE BUFG` on the recovered-clock + per-lane mux nets,
  `set_clock_uncertainty` to bound 8-site skew. Caveat: `set_case_analysis`
  is an *impl-time STA* directive and will NOT remove a synthesis-created
  LUT — so XDC alone likely cannot collapse the per-lane clock-mux LUTs;
  it can only improve their routing. ~19-min farm build + lease retest.
- **(B) Structural RTL (recommended, deterministic):** mirror the
  established `tidelink_idelay_rx.sv` pattern — an FPGA-only, param/macro-
  guarded clean-clock path that takes `pad_clk_rx`, puts it on a single
  `BUFG`, and feeds all 8 lanes' capture directly, with `io_pol`/`scan_mode`
  tied 0 on the FPGA path (proven safe by step 5). Removes the LUT-in-clock
  entirely. Larger change to the Wav PHY clock path (hand-patched SoC Labs
  Verilog, so edits persist), sim/ASIC guarded.
- **(C) Defer to a clock-architecture redesign** of the Wav GPIO PHY RX
  recovered-clock distribution (out of scope for a bring-up fix).

After whichever fix: rebuild `feat/td-combined` (farm), then
`bringup_pair_converge.sh` (v2, `MAX_RETRIES≈8`). Expected if correct:
die_a (Y7-MRCC) `cal_done` 0→1, `locked`→~0xfe, i.e. it behaves like the
currently-working die_b → full 16/16.

## Hard-won rules (do not relitigate)

- Work on `feat/td-combined` only (consolidated; submodule de-fragmented).
  NOT `feat/fpga-flow` (divergent §9 lineage).
- The fixes (S_HOLD/T3/IDELAYE2/FCSM-sticky) ARE in the b_combined silicon
  (md5-unique, IDELAYE2 in routed netlist) — proven, do not re-question.
- Physical (ribbon/pin/board) is ruled out by the swap test — do not chase.
- Lease discipline: acquire → verify `granted` + our holder on BOTH boards
  (else stop) → release with token → `pkill -9 -f` the tree → verify.
  `bringup_pair_converge.sh` is safe-ops only (no AHB_TX/doorbell).
- Logs: `td_campaign/bringup_converge_run1.log`, `bringup_swap_diag.log`.

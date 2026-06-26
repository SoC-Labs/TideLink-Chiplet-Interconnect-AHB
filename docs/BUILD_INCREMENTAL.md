# Incremental FPGA builds (fast iteration)

A full from-scratch flip build is ~3.4 hr (place-&-route on the ~97%-packed
xc7z020). For small, localized RTL changes (e.g. calibrator/eyescan tweaks),
**incremental implementation** reuses the prior routed checkpoint and re-routes
only the delta → typically **~20–40 min**. Synthesis is *not* the bottleneck and
the flip/non-flip targets do NOT share a netlist (the flip carries the
`clk_rx_buf` BUFG in its BD), so per-target incremental is the right lever.

## How to run an incremental build
Each target self-references its own prior routed DCP via `INCR_REF=auto`:

```bash
cd <worktree>
INCR_REF=auto fpga/scripts/build_farm.sh \
  pynq-z2-pair-all@srv04936 pynq-z2-pair-flip-all@srv04936
```

- `INCR_REF=auto` → use THIS target's prior routed DCP (`imp/fpga/output/<TARGET>/tidelink_design_wrapper_routed.dcp`, on the build host).
- `INCR_REF=<path>` → an explicit reference DCP (abs, or relative to the per-target build cwd).
- `INCR_REF` **unset (default)** → full from-scratch build, flow byte-unchanged.

Mechanism: project mode, so the hook is `set_property INCREMENTAL_CHECKPOINT <dcp> [get_runs impl_1]` (`fpga/build_design.tcl` STEP 9a). Each successful build overwrites its own routed DCP → becomes the next iteration's reference automatically.

## Prerequisites / pitfalls
- **Seed the reference:** `auto` needs a prior build's routed DCP for that target *on the build host*. The current full builds leave one. If a host never built the target (or `imp/` was wiped), `auto` warns and does a full build.
- **Low reuse silently full-fallbacks.** If cell reuse < ~75%, Vivado abandons incremental and runs full P&R — correct bitstream, **no speedup, no error**. Always grep the reuse number (below); never trust wall-clock alone.
- **Re-baseline (run one full build, unset INCR_REF) when:** reuse < 90%; you changed a **clock / clock constraint** (`tidelink_clk_rx_buf.v`, the clk_wiz freq, `CLOCK_DEDICATED_ROUTE`, `create_*clock`/`set_clock_groups`/`set_max_delay` in the timing XDC); a **pin/IOB** changed; the **PRBS instrument footprint** changed materially (new MMIO / CDC / wider PRBS); or after ~5–8 incremental hops on one reference. Clock edits across an incremental run are the historical 0/16-lock failure mode — never do it.
- **Keep `phys_opt_design` ON and the read directive at default (`TimingClosure`), NOT `RuntimeOptimized`.** The AggressiveExplore phys_opt (`build_design.tcl:349-352`) is what makes the RX-capture eye deterministic; skipping it route-matches but regresses the eye (silent on-silicon lottery). `RuntimeOptimized` can leave WNS worse than baseline on this marginal design — it's for "does it route" smoke runs only, not a shipping bitstream.

## Reuse expectations for the eyescan iterations
- **SMALL calibrator edits (param flip, a few lines of logic — e.g. FIX-R b081e4d's min-hold counter):** localized, arm=0-gated → **>90% reuse, fast, incremental-safe.** The sweet spot.
- **STRUCTURAL calibrator edits (new register banks, FSM restructure, OUTPUT-MUX rewiring — e.g. FIX-CENTER fdd460a, +172 lines, new esync_run/best_* regs + routing pin_phase live to the PHY):** OBSERVED to drop reuse below Vivado's auto-threshold → **"Incremental flow is disabled. No incremental reuse Info to report." → silent FULL P&R fallback (~3.4hr, correct bitstream, NO speedup).** "Calibrator-internal" is NOT a reliable proxy for high reuse — line count + new sequential cells + mux/output changes are what matter. Grep the log for `Incremental flow is disabled` / `report_incremental_reuse` to confirm whether it actually engaged.
- **PRBS instrument (WI-1/WI-3 5eef2c3):** RIPPLE — adds link-tx-clock sequential logic + CDC syncs + MMIO → **lower reuse, verify-before-trust.** Once it's in the reference, subsequent PRBS-internal tweaks return to high reuse.

## "Safe to deploy" gate for an incremental bitstream
Baseline (the shipping reference) timing: **WNS −1.36, WHS −25.85** with 16 failing-hold endpoints = the benign `pad_clk_tx_fwd` TX-forwarding group (the bitstream is "timing NOT met" by design — equivalence test is *"no worse,"* not *"clean"*). An incremental bitstream is safe to deploy ONLY if ALL hold:

1. **Sim gate passes** (policy: integrated paired-die cocotb before any HW deploy); `arm=0` = the proven path.
2. **Reuse ≥ 90%** — `grep -iE "reuse|fully reused|full implementation" <build log>`; must NOT say it fell back to full unless intended.
3. **WNS ≥ −1.40** (no worse than baseline by > ~0.05 noise).
4. **WHS ≥ −25.9** AND the failing-hold endpoints still confined to `pad_clk_tx_fwd` (a new violator on `pad_clk_rx`/capture = REJECT — that's the eye).
5. **`pad_clk_rx` still on a real BUFG** (`clk_rx_buf`, CLOCK_DEDICATED_ROUTE honored) — no LUT-as-clock.
6. **Both phys_opt steps ran**; 0 CRITICAL WARNINGs; post-route DRC clean (only the known waived combinatorial loop).
7. **Silicon sanity:** first incremental bit — confirm `arm=0` reproduces the proven B→A before testing any armed feature.

Any miss → fall back to a full `INCR_REF`-unset build and re-baseline the reference DCP. Keep the reference DCP versioned next to the bitstream md5 so an incremental result is always traceable to its baseline.

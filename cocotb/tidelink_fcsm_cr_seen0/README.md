# tidelink_fcsm_cr_seen0 — faithful `cr_seen=0` repro (I1 bring-up)

Scaffolding for the plan in `docs/I1_SIM_REPRO_PLAN.md`. Goal: a sim that actually reaches the silicon
signature **`cr_seen=0 crack_seen=0 cal_done=0 fcsm=0`** (`SWI_LANE_STATUS=0x00100000`) with the
`local_overrides` AXI FCSMs, and flips **GREEN** (`cr_seen=1`, `cal_done=1`) with the `deps` FCSMs — so
candidate fixes triage in sim, not on the bench.

## Why the two existing envs are BLIND (do not reuse their stimulus)

- `cr_seen` (`cr_pkt_seen_rx`) is a **sticky latch set by one intact peer CR**. On a zero-BER,
  shared-clock, `SKID_BITS=0` wire an intact CR always lands ⇒ `cr_seen` latches 1. **No emit-gate
  tuning can hold it at 0 on a clean synchronous wire.**
- `cocotb/tidelink_fcsm_bringup_race` and `cocotb/tidelink_fcsm_silicon_ratio` both
  **`force_calibrator_sim_bypass()`** (forces `cal_done`, severing the cal↔cr coupling), do a **clean
  bring-up first** (latching `cr_seen=1`), model the "marginal link" by **toggling the APB LL-enable**
  (never drops wire words), and **assert on `state==4`, never on `cr_seen`**.

## What this env changes (the fidelity ladder)

See `docs/I1_SIM_REPRO_PLAN.md §4.2`. In short: **cold** bring-up, **un-bypassed** calibrator
(shrink `HOLD_CYCLES` via `defparam`, do NOT set `tb_early_exit_force_q`), **async 2-die clocks + reset
skew + wire skew**, the **~40 ns ratio without the APB crutch**, and an oracle on the **silicon
4-tuple**. The RED lever is the L6 state-1 CR-emit hold (`SOCL_L6_MIN_CR_EMITS`, made overridable here).

## Status

**Not yet run** — `deps/axi-chiplet-controller` + `deps/tidelink-phy` are un-checked-out in this
worktree, so VCS cannot elaborate. Rungs 0-1 reuse the shared-clock `tb_top.sv` from
`../tidelink_fcsm_silicon_ratio`; **rung 2+ (per-die clocks) needs a split-clock `tb_top` variant** —
marked TODO in the Makefile. Populate submodules, then follow the recipe in the plan §6.

## Instrument-trust (mandatory before trusting any RED) — plan §5

1. GREEN must show `cr_seen` 0→1 (positive control).
2. RED must flip with `FCSM_SRC` alone (deps↔local), all else identical.
3. `pkt_is_cr_pkt` must **pulse** on RX in GREEN, **never** in RED.
4. Router grant log: RED starves sideband `auto_in_6`, GREEN grants it.
5. The refuted emit-gate fix (`SOCL_FCSM_BRINGUP_HOLD_ALWAYS` unset) must **stay RED**.
6. `SWI_LANE_STATUS` reads clean `0x00100000`, no X.

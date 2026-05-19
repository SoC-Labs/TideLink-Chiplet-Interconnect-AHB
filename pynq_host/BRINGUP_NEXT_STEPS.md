# TideLink FPGA bring-up — the actual state, and exactly what to do next

_2026-05-19. This supersedes the months of "HW/runtime nondeterminism"
investigation. Read this before touching RTL or running another phase sweep._

## The one-paragraph truth

The link was never failing for a mysterious or architectural reason. Four
independent RTL/FPGA/methodology audits converged: the PHY architecture is
sound (real closed-loop word-boundary recovery via per-lane training byte +
`bit_slip` hunt; the cable at 50 Mb/s is not the wall). There were exactly
three real defects — **all three already diagnosed and fixed in this repo's
history** — plus a deploy-script race that was misattributed to silicon and
never fixed. The reason it never "converged" is process, not engineering:
the fixes were scattered across ~12 branches and 6 worktrees, the one branch
that has all of them (`feat/td-combined`) was trapped in a worktree whose
submodule objects existed in exactly one place, and every HW metric
(`7.5/16`, `D_score=0`, "byte-identical bits diverge") was measured through a
deploy harness that races `role_lock` by *seconds* against a *microsecond*
alignment window.

## What is now consolidated and hardened (done)

- **`feat/td-combined`** is THE branch. It contains, verified wired:
  - **S_HOLD / T3.2** (`50f7869`) + **T3 re-sweep** (`1e5f4e0`) in
    `src/rtl/tidelink_phy_align_calibrator.sv` (`S_HOLD = 4'd6`,
    `sweep_success`, `HOLD_CYCLES`) — defeats the first-to-succeed deadlock.
  - **IDELAYE2** (`fff8df2` + `1b2e87e`/`54b5879`/`a4f0605`):
    `u_idelay_rx` instantiated at
    `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1382`,
    `USE_IDELAY` threaded through `tidelink_top.sv`, BD `clk_wiz` CLKOUT3 =
    200 MHz → `idelay_ref_clk` wired in both pair targets.
  - **FCSM sticky** credit-path fix: submodule `678a9b3` ⊇ `0e126b0`.
- Built + HW-tested already (memory: bitstream `b012827f`, mean 7.5/16,
  best 12/16) — but tested *through the raced deploy*, so those numbers are
  a lower bound measured wrong, not the RTL's real ceiling.
- **Submodule de-fragmented**: the `678a9b3` chain is now redundant in the
  main submodule clone (`deps/axi-chiplet-controller/.git`), pinned by
  `refs/heads/bringup/consolidated-td-combined`. The consolidated branch can
  no longer become unbuildable by removing a worktree.
- **New deploy tool**: `pynq_host/scripts/bringup_pair_converge.sh` — the
  piece that never existed. Parallel deploy (role_lock skew → SSH-launch
  jitter, not seconds), then a closed loop of *coordinated parallel recal*
  (re-arm BOTH calibrators near-simultaneously; S_HOLD bridges residual
  skew) + *settle-then-read* (poll `SWI_LANE_STATUS` until stable — never a
  single snapshot), looped until both ends genuinely lock 16/16. Safe-ops
  only (no AHB_TX, no doorbell → cannot trip the board-wedge hazard).

## What to actually do next (in order)

1. **Build `feat/td-combined`** if a fresh bitstream is wanted (else reuse
   the staged `b012827f` bins). Build from the worktree
   `/home/dam1n19/td_idelay_wt` (submodule already at `678a9b3`). The farm
   path is unchanged (`make build_pair_farmed`).
2. **Acquire the bridge1 lease and VERIFY it is `granted`, not `queued`.**
   Confirm both boards reachable (`z2_02` master 192.168.4.101, `z2_03`
   slave 192.168.6.101) before launching anything.
3. **Run the closed-loop bring-up** from a board-network host (mapstone-dev),
   bins staged in `/tmp/tidelink_deploy`:
   ```
   MAX_RETRIES=20 STABLE=3 bringup_pair_converge.sh
   ```
   Expected with the consolidated RTL: lock climbs across iterations and
   converges to 16/16 (exit 0). This is the first time the RTL fixes and a
   deploy method that exploits them are in the same place at the same time.
4. **Interpret per the script's own guide.** If it plateaus high (12–15/16)
   that residual is a *genuine, now-isolable* per-lane sub-UI / IDELAYE2-tap
   ceiling — characterise the named stuck lane(s) (the `fault` byte names
   them); that is the *first* point at which a new RTL hypothesis is
   warranted. If it bounces uncorrelated with no upward trend, the bitstream
   is NOT from `feat/td-combined` (re-check S_HOLD is in the calibrator).

## Stop doing these (they are why it didn't converge)

- **Do not** run phase/slip sweeps through `deploy_pair_with_retry.sh` /
  `phase_recal_sweep.sh` and draw conclusions: each point is a fresh raced
  deploy, so the sweep measures per-deploy timing luck convolved with phase.
  Every "best op-point" / `D_score=0` / "byte-identical bits diverge"
  conclusion came from this confounded measurement.
- **Do not** invent new RTL determinism mechanisms before step 3. The
  diagnosis is closed; the fixes exist; they just had never been run
  together through a non-broken deploy.
- **Do not** trust `redeploy_repeatability.sh`'s verdict as a bring-up
  signal — it is a one-shot characteriser whose heuristic was written to
  *prove* the lottery (one recal, one snapshot). Use
  `bringup_pair_converge.sh` for bring-up.
- **Do not** consolidate onto `feat/fpga-flow`: it is a *divergent* line
  (shares only ancestor `86ce6fa`) with a different §9 RTL lineage. Merging
  the fixes onto it is the conflict mess that ate months. Work on
  `feat/td-combined`.

## If step 3 still doesn't give 16/16

Then — and only then — you have a real, isolated, single residual to chase,
measured honestly for the first time. The ranked candidates (now testable
because the lottery and the deadlock are out of the way):
IDELAYE2 tap precision (x2 scaling 0..15→0..30, IDELAYCTRL `RDY` is left
unconnected by design — `tidelink_idelay_rx.sv:138`), single-ended
forwarded-clock jitter on the unterminated ribbon, and the unconstrained
pad→capture path (the source-sync XDC `5ad4b0c` is present; verify it
actually constrained the build vs being overridden by an async clock-group).

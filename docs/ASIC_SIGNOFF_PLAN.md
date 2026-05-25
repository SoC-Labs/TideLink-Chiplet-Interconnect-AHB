# TideLink — ASIC Sign-off Plan

**Author:** auto-generated handoff
**Last revised:** 2026-05-25
**Purpose:** Single canonical checklist of *everything* that must pass before TideLink can be signed off for ASIC tape-out. Assumes the open PHC-Phase-1 / FC-credit / training-mode-stuck bug class is RESOLVED first (separate doc: [PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md)).

This doc is organised in two parts:

- **Part A** — the sign-off gate matrix (what passes / what's outstanding).
- **Part B** — the ramp plan once the bugs are fixed (the linear sequence of steps from "fix lands" to "tape-out tag").

Cross-reference: [SIGN_OFF_STATUS.md](SIGN_OFF_STATUS.md) (the dated snapshot of where the project was at the last commit). This doc supersedes that for the **forward plan**.

---

## Part A — Sign-off Gate Matrix

Twelve gates, grouped into five tiers. Each gate has a one-line acceptance criterion, an evidence requirement, and a status hint. Gates marked **★ blocker** must be GREEN before tape-out.

### Tier 1 — Functional correctness

| # | Gate | ★ | Acceptance criterion | Evidence required |
|---|---|---|---|---|
| 1 | **Cocotb regression (full suite)** | ★ | All cocotb tests in `cocotb/*` pass on the tip of `main` with the latest submodule SHA | CI job `cocotb-regression` green; individual jobs `cocotb-fc-adapter`, `cocotb-ptp`, `cocotb-top`, `cocotb-system`, `cocotb-wlink-pair` all green |
| 2 | **UVM regression (full)** | ★ | All UVM testbenches pass including the previously-excluded `tidelink_fc_adapter_full_test` | CI jobs `uvm-regression`, `uvm-fc-adapter`, `uvm-integration`, `uvm-top-system`, `uvm-system`, `uvm-ptp-stress`, `uvm-ptp-chain` all green |
| 3 | **C-driver / register-map sync** | ★ | The C-side `TIDELINK_REGS_TypeDef` struct sizeof matches the RTL register layout; all docs match the `.rdl` source of truth | CI job `cdriver-regression` green; `docs/REGISTER_MAP.md` regen from `src/rdl/tidelink_regs.rdl` is byte-identical |

### Tier 2 — Lint, CDC, structural quality

| # | Gate | ★ | Acceptance criterion | Evidence required |
|---|---|---|---|---|
| 4 | **HAL lint (Spyglass)** |  | Every module in `lint/Makefile`'s STANDALONE + CMSDK list passes Spyglass HAL with zero unwaived violations | CI job `hal-lint` green; the documented exclusions (`tidelink_ahb`, `tidelink_fifo_ahb` — port-chain drift per Makefile comment) remain the only ones |
| 5 | **Verilator strict-lint** |  | `make -C lint/verilator` clean | Wire this into `.gitlab-ci.yml` as a per-push job (currently on-demand only); 1 commit |
| 6 | **CDC sign-off (Spyglass CDC)** | ★ | Zero unwaived real CDC violations on TideLink-authored RTL; SGDC port-clock additions complete (Finding #1/#3/#5 closed); waiver file deltas complete | `docs/SPYGLASS_CDC_SIGNOFF.md` + `docs/CDC_AUDIT_REPORT.md`; current status is **GO (conditional)** — need to apply the §3.1 SGDC and §3.2 waiver deltas; both zero-risk constraint-only changes. Finding #2 `set_multicycle_path` (`link_clk → pad_clk_rx`) only required if `axi_chiplet_controller` is run un-blackboxed in CDC |

### Tier 3 — HW validation on FPGA proxy (bridge1)

| # | Gate | ★ | Acceptance criterion | Evidence required |
|---|---|---|---|---|
| 7 | **FPGA link layer (Wlink + autoneg)** | ★ | Both boards reach 16/16 lane lock + cal_done within ≤ 2 deploy attempts. `bringup_pair_converge.sh` PASSes reliably (10/10 consecutive runs) | Last build's HW log + `docs/LINK_DECAY_BISECT.md` |
| 8 | **FPGA FC layer (doorbell + credits)** | ★ | Doorbell round-trip succeeds: master writes `0x4403_2014`, slave's interrupt fires, master's `DOORBELL_RSP_ACC (0x2024)` increments. `RELEASED_CREDITS_ACC` tracks expected delta. **Currently FAILS** (see PHC_PHASE1_HANDOFF.md §10c — FC TX FIFO accumulates but never drains; training-mode-stuck candidate root cause) | Pass on bridge1 with b26 or later candidate fix |
| 9 | **FPGA PHC Phase-1 (HW_SYNC slave RX)** | ★ | Slave's `PTP_CTRL[2] rx_valid` latches to 1 within ≤ 1 sync interval of master HW_SYNC_CTRL=0x5; `SERVO_STATUS.locked` becomes 1 within 5 s; sustained `|offset| < 500 ns` for 10 consecutive samples; long-term soak (`bringup_ptp_soak.sh`) passes 10 minutes | Pass on bridge1; **CURRENTLY THE PRIMARY OPEN BLOCKER** |
| 10 | **FPGA stress / soak / repeatability** |  | `bringup_reliability.sh` runs 20+ pair-deploys back-to-back with ≥ 95% convergence; `redeploy_repeatability.sh` quantifies per-iter convergence stats | Last soak log + `docs/REDEPLOY_REPEATABILITY_REPORT.md` |

### Tier 4 — ASIC backend

| # | Gate | ★ | Acceptance criterion | Evidence required |
|---|---|---|---|---|
| 11 | **ASIC synthesis + Formality LEC** | ★ | Fusion Compiler synthesis produces routable netlist; Formality LEC sweep (`init→synth→cts→route→signoff→abstract → LEC`) passes with zero non-equiv points | CI job `formality-lec` green on the tape-out commit. `imp/ASIC/tidelink_top_full/tidelink_top.sdc` SDC is the SDC of record (clock groups: `hclk phc_clk scan_clk user_ref_clk pad_clk_rx` async). Currently **conditional** — need to trigger on the tape-out commit and archive `MANIFEST.md` + FC reports |
| 12 | **ASIC timing closure (post-route STA)** | ★ | All paths meet setup + hold at slow-slow / typical / fast-fast corners; CDC paths constrained per CDC sign-off; no `set_false_path`/`set_max_delay` regressions from CDC audit | Synopsys PrimeTime report on the routed DCP/netlist. Currently part of Tier-4 pipeline above |
| 13 | **ASIC physical sign-off (DRC + LVS + ANT + density)** | ★ | DRC clean, LVS clean, antenna check clean, density target met for the target process/library | Synopsys ICC2 / IC Validator report from the foundry PDK runs |
| 14 | **ASIC power sign-off** |  | IR-drop within budget at typical + max corners; EM (electromigration) reports clean; dynamic + leakage power within spec | Synopsys PrimeShield + Voltus reports |
| 15 | **DFT sign-off (scan + ATPG + BIST)** | ★ | Scan chain inserted with ≥ 99% scan coverage; ATPG stuck-at coverage ≥ 95%, transition-fault coverage ≥ 90%; memory BIST inserted for any SRAM macros | TestKompress / TetraMAX reports |

### Tier 5 — Documentation & repo hygiene

| # | Gate | ★ | Acceptance criterion | Evidence required |
|---|---|---|---|---|
| 16 | **Spec + register map** |  | `docs/SPEC.md` / `docs/REGISTER_MAP.md` / `src/rdl/tidelink_regs.rdl` mutually consistent; auto-gen check in CI is green | CI gate `register-map-regen-check` (to be added if not present) |
| 17 | **Architecture + integration guide** |  | `docs/ARCHITECTURE.md` (or equivalent) describes block diagram, clock domains, reset domains, FC channels, sp2wl bypass; `docs/INTEGRATION_GUIDE.md` covers chiplet-side instantiation, pin map, SoC-side integration notes | One-time review by ARM Academic Access reviewer |
| 18 | **Errata / known issues** |  | All open issues filed with severity + workaround. Currently-open items captured in `docs/V2_DEFERRALS.md` + this doc + `PHC_PHASE1_HANDOFF.md` | Final errata sweep, frozen at tag time |
| 19 | **CI pipeline overall green** | ★ | Latest pipeline on `main` is fully green for ≥ 3 consecutive commits (push-cancellation noise washed out) | `glab api projects/soclabs%2Ftidelink/pipelines?ref=main` shows 3 consecutive green |
| 20 | **Repo hygiene / branch cleanup** |  | Old per-build branches archived or deleted (per `cleanup_proposal.md`); no uncommitted load-bearing work in any worktree under `td-bisect/`; submodule pinned to a tagged release of `axi-chiplet-controller` | Final pre-tape-out audit |

---

## Part B — Post-bug-fix ramp plan

Assumes the PHC-Phase-1 / FC-credit / training-mode-stuck class is resolved and ★-blocker gates 7/8/9 are GREEN on bridge1.

### Phase 1 — Close out the HW validation (≈ 1 day)

1. **Lock in the bug-fix commit on `main`.** Whatever fix lands (b26 or successor — `(* keep *)` on `nego_cfg_reg[6]` + autoneg FSM regs, OR the WavD2DGpioTx word-aligned mux fix per `TIDELINK_TOMORROW_SESSION_HANDOFF.md`, OR something else), MERGE TO MAIN with a commit message that references the diagnosis trail in `PHC_PHASE1_HANDOFF.md`. Tag as `v1.0-rc4` or similar.
2. **Re-run `bringup_pair_converge.sh` + `bringup_ptp_sync.sh` + `bringup_ptp_soak.sh`** on the post-merge bitstream. Capture the HW logs into `docs/PHC_PHASE1_HW_REPORT.md` as the final entry.
3. **Run the FC stress tests** that have been blocked: `bringup_reliability.sh`, `bringup_ptp_track_freq.sh`, `bringup_ptp_track_offset.sh`. These were previously deferred because PHC Phase-1 wasn't working.
4. **Run the doorbell + AHB-TX round-trip tests**. Doorbell first (safe), then `bringup_autocal_i2c.sh` if appropriate. AHB-TX is the wedge hazard — only after the FC layer is confirmed working.
5. **Quantify repeatability**: `redeploy_repeatability.sh` 20 iterations, report convergence rate. Target ≥ 95%.

### Phase 2 — Close out the CI gates (≈ 2 days)

6. **Apply CDC sign-off deltas**: edit the SGDC port-clock additions (§3.1) and waiver file (§3.2) per `docs/CDC_AUDIT_REPORT.md`. Re-run Spyglass CDC; confirm unwaived count is zero or matches the documented blackbox-internal residual.
7. **Wire Verilator strict-lint into per-push CI**: 1-commit fix to `.gitlab-ci.yml`. Confirm green.
8. **Verify HAL-lint and cocotb-regression and cdriver-regression and uvm-fc-adapter** are all green in three consecutive CI pipelines. If any flake, root-cause and pin.
9. **Repo cleanup**: execute the proposals in `cleanup_proposal.md` (Agent L's output). Delete stale per-build branches, archive failed RTL attempts, remove obsolete worktrees. Verify submodule pinned to a tag of `axi-chiplet-controller`.

### Phase 3 — Trigger the ASIC backend (≈ 1-2 weeks wall, ≈ 3 days human)

10. **Trigger `formality-lec` on the tape-out commit.** Archive `MANIFEST.md`, FC reports, LEC log. Pass criteria: zero non-equivalent points. If failures, diagnose (almost always SDC issue or missing `dont_touch`).
11. **Trigger the foundry PDK runs** (Synopsys ICC2 init → synth → cts → route → DRC → LVS → ANT). Owner: typically Mike at SoC Labs or whoever owns the PDK queue. This is wall-time-bound by the foundry tool cluster.
12. **Sign-off STA**: PrimeTime report on the routed netlist, with `set_clock_groups -asynchronous` SDC as the source of truth. Confirm all paths meet setup/hold at all three corners. Address any violations with EITHER constraint refinement OR a targeted RTL re-spin.
13. **Sign-off DFT**: TestKompress / TetraMAX runs. ATPG stuck-at + transition-fault coverage reports.
14. **Sign-off power**: PrimeShield + Voltus IR/EM reports.

### Phase 4 — Final repo + spec sweep (≈ 1 day)

15. **Spec + register-map alignment**: regen `docs/REGISTER_MAP.md` from `src/rdl/tidelink_regs.rdl`; verify byte-identical; resolve any drift.
16. **Errata sweep**: collate every open issue from `docs/V2_DEFERRALS.md`, `docs/PHC_PHASE1_HANDOFF.md`, the cleanup proposals, and any unresolved CI flakes into a single `docs/ERRATA.md`. Each entry: severity, workaround, target-fix release.
17. **Architecture + integration guide review**: walk-through with the ARM Academic Access reviewer; sign off as fit-for-purpose.
18. **Tag the tape-out commit**: `v1.0-asic-tapeout` on `main`. Push to origin. Verify the tag points at a green pipeline.
19. **Archive the routed DCP**, the LEC reports, the PDK runs, the ATPG patterns, the SDC of record, and the spec into `releases/v1.0-asic/` (or whatever the convention is at SoC Labs). This is the artefact handed to the foundry.

### Phase 5 — Hand-off (≈ 0.5 day)

20. **Hand-off package** to the SoC integrator:
    - `releases/v1.0-asic/tidelink.lib` (timing models, slow/typical/fast)
    - `releases/v1.0-asic/tidelink.v` (synthesised netlist)
    - `releases/v1.0-asic/tidelink.gds` (layout)
    - `releases/v1.0-asic/tidelink.lef` (abstract)
    - `releases/v1.0-asic/tidelink.sdc` (constraints)
    - `releases/v1.0-asic/docs/` (spec, register map, integration guide, errata)
    - `releases/v1.0-asic/MANIFEST.md` (provenance, commit SHA, build host, build date, tool versions, hash of every artefact)

---

## What this plan deliberately does NOT cover

- **Per-customer chiplet integration** — that's downstream of TideLink sign-off, owned by the consumer of the IP.
- **Process migration / multi-foundry retarget** — sign-off here is for a single agreed foundry process. Migration is V2 scope per `docs/V2_DEFERRALS.md`.
- **Post-silicon bring-up** — once silicon arrives, that's a separate plan.
- **The PHC Phase-1 bug itself** — that's the immediate prerequisite for entering Phase 1 of this plan. See [PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md).

---

## Dependencies between gates (sequencing)

```
            ┌─ 1 cocotb ─┐
            ├─ 2 UVM ────┤
   functional│             │
            └─ 3 cdriver ┘
                          │
            ┌─ 4 HAL ────┐  ▼
            ├─ 5 verilator──── 6 CDC ─┐
   lint/CDC │             │           │
            └─────────────┘           ▼
                              ┌── 7 link ──┐
                              ├── 8 FC ────┤   ← BLOCKED by PHC fix
                              ├── 9 PHC ───┤
                              └── 10 stress┘
                                            │
                                            ▼
                                   ┌── 11 LEC ──┐
                                   ├── 12 STA ──┤   ← foundry queue
                                   ├── 13 phys──┤
                                   ├── 14 power┤
                                   └── 15 DFT ─┘
                                            │
                                            ▼
                                   ┌── 16 spec ─┐
                                   ├── 17 docs ─┤
                                   ├── 18 errata┤
                                   ├── 19 CI ───┤
                                   └── 20 hygiene
                                            │
                                            ▼
                                    TAG v1.0-asic-tapeout
```

The 8/9 (FC + PHC) gates are the *current* critical-path blocker. Everything from gate 11 onward depends on them being GREEN.

---

## Status snapshot (2026-05-25)

| Tier | Gates GREEN | Gates CONDITIONAL | Gates RED / BLOCKED |
|---|---|---|---|
| 1 — Functional | 2 (UVM, cdriver after `28654ae`) | 1 (cocotb-regression last red on pipeline 226) | — |
| 2 — Lint / CDC | 1 (Verilator clean per IMPLEMENTATION_STATUS) | 2 (HAL closed via `c547ed1`; CDC needs final delta) | — |
| 3 — HW validation | 1 (link layer) | — | **2 (FC, PHC) — current blockers** |
| 4 — ASIC backend | — | 1 (LEC needs trigger on tape-out commit) | 4 (waiting on HW validation upstream) |
| 5 — Docs / hygiene | 2 (docs, repo) | 1 (CI overall — needs 3 consecutive green) | — |

**The whole plan stalls behind FC + PHC.** Once those land, Phases 2-5 are largely procedural (≈ 1-2 weeks calendar time, mostly waiting on foundry tool queues).

---

## Open items not yet captured by any gate above

- The Vivado 2025.2 `wait_on_hw_ila` reliability issue (per `PHC_PHASE1_HANDOFF.md` §11 #5) — only affects FPGA debugging, not ASIC sign-off. Track in errata as "FPGA-only".
- Submodule branch hygiene — `deps/axi-chiplet-controller` currently has several per-build branches that should be cleaned up before tape-out.
- The `TIDELINK_INTERFACE_DEBUG_PLAN.md` open items (training-mode mux at `WavD2DGpioTx.v:43-45`) — fold into the PHC fix path.

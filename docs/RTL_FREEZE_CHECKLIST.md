# TideLink — Bug Status & RTL-Freeze Checklist

Generated 2026-05-22. Companion to `LANE_LOCK_ROOT_CAUSE.md` and `BUG_TRACKER.md`.

Legend: ✅ done · ⚠️ partial/caveat · ❌ not done · n/a not applicable

---

## A. Bug status — RTL fix / simulated / hardware-validated

### RTL bugs (these gate RTL freeze)

| # | Bug | RTL fix done? | Simulated + passed? | HW-validated? | Notes |
|---|---|---|---|---|---|
| **CLKBUF** | GPIO-PHY capture clock on LUT net (no `USE_CLKBUF`) → 0/16. **THE lane-lock root cause.** | ✅ `USE_CLKBUF`+`USE_IDELAY` in `72c280b`/`17160eb`; **stripped** by `51b5169` on later branches | ⚠️ params default OFF in sim (passthrough) — BUFG path not sim-exercised; only meaningful on FPGA | ✅ **`72c280b` = 16/16, WHS +0.051, 8 BUFG + 8 IDELAYE2 in netlist** | Must be re-applied to / not-stripped-from the freeze branch |
| 1 | `nego_driving` latch | ✅ sub `467b889` | ✅ cocotb autoneg | ✅ autoneg working on silicon (earlier) | in i2c-autoneg sub lineage |
| 2 | `txn_step_nxt` missing default (latch) | ✅ sub `be5eed2` | ✅ cocotb | ✅ silicon | |
| 3 | Mask FSM states 8/9/10 skipped on silicon | ✅ candidate sub `6a757e2` (default state_nxt) | ✅ cocotb 33/33 | ⚠️ **NOT specifically validated** — `72c280b` 16/16 lock implies mask phase ran (cal_done=1) but not ILA-instrumented | needs explicit silicon check |
| 4 | Mask-FSM defensive (busy_seen_nxt + peer_lane_mask) | ✅ sub `9b43676`+`a30b21b` | ✅ cocotb | ⚠️ tested in Exp F but on a 0/16 bitstream → not meaningful; **re-validate on locking build** | silicon-neutral-or-helpful |
| 9 | HAL VERCAS `LOCAL_LINK_STATE_W` rename | ✅ `2b5b6e5` | ✅ HAL clean | n/a (lint) | |
| 16 | Calibrator HAL cosmetics (PADMSB/ENMNFU/USEPAR) | ✅ `fix/bug16-hal-cosmetics e412289` | ✅ cocotb pass | n/a (cosmetic) | |
| 23 | `perf_reg_rdata` 33→32-bit truncation | ✅ `fix/perf-width-truncation cb2cd26` | ✅ Verilator clean | ❌ (debug reg `R7_DBG_LINK_STATUS`; not on a deployed build) | |
| 7 | Calibrator HAL (unique-case/REVROP) | ✅ `fix/calibrator-structural 4504861` | ✅ cocotb 5/5 | n/a | **MOOT on current HEAD** (calibrator already simple-FSM) |
| 22 | UVM masked-strobe FSM defects (5 CI reds) | ⚠️ partial `fix/bug22-uvm-mask-strobe-fsm 7ab9806` | ❌ regression run pending | n/a | root cause = header-width drift, not mask-FSM |
| 30 | `tidelink_phy_align_calibrator` TB/RTL port drift | ❌ | ❌ TB expects ports RTL lacks | n/a | testbench fix needed |

### Infra / process bugs (do NOT gate RTL freeze — listed for completeness)

| # | Bug | Fix | Status |
|---|---|---|---|
| 6 | Broken XDC (if/catch, multi-pin) | `fix/xdc-declarative c6375eb` | ✅ sim-clean; largely moot vs CLKBUF fix |
| 8 | overlay.py decoder field-split | `b03447b` (Python) | ✅ |
| 10 | SV anti-pattern (3rd-party IP) | `fix/bug10 7316a5f` (lint allow-list) | ✅ |
| 11 | CI `../fpgahub` pip install | `fix/ci-fpgahub-install 77df87d` | ✅ |
| 12/13/14 | deploy_pair / converge / watcher | `fix/deploy-script-robustness 9f2bbab` | ✅ |
| 17 | BD/XDC i2c-pin coupling | documented | ✅ |
| 18 | srv04936 OOM @≥3 concurrent | discipline rule | ✅ |
| 19 | /tmp ceiling | canonical home convention | ✅ |
| 20 | cocotb misses silicon defects | `feat/cocotb-robust-silicon-replication 8d27ebb` | ✅ |
| 21 | No Verilator strict-lint gate | `feat/verilator-lint-gate cb103ce` | ✅ (found #23) |
| 24 | watcher path migration | `fix/bug24 06720f2` | ✅ |
| 31/33 | v1 bundle wrong bitstream | rebuilt w/ 72c280b | ✅ |
| 32 | volatile staging no provenance | deploy-guard + artifact-store | ✅ |
| 34 | morning-v1 mislabel | artifact-store relabel | ✅ |

### Disproven hypotheses (not bugs)

| # | Hypothesis | Verdict |
|---|---|---|
| 15 | xhb500/generated rsync contamination | 🧊 disproven |
| 25 | srv04936 build-env regression | 🧊 disproven (commit, not env) |
| 26 | clk_wiz 50→25 MHz mutation | 🧊 disproven |
| 27 | slave board PS-eth fault | resolved (power cycle); HW was fine |
| 28 | post-cycle ribbon damage | 🧊 disproven (tl_v7 13/16 pre+post) |
| 35 | "true 14.40/16 build lost" | explained: pre-fix timing-lucky builds; 72c280b is the real 16/16 |

---

## B. The central RTL-freeze gap

**The 16/16-validated build (`72c280b`, 05-20) PREDATES most RTL bug-fixes**
(Bug #3/#4 final, #9, #23, all made 05-21/05-22 off `57c2810`). And the
bug-fix branch lineage (`feat/td-combined` → `release/v1.0-rc1`) had the
`USE_CLKBUF` fix **stripped by `51b5169`**.

So no single branch today has BOTH (a) the lane-lock `USE_CLKBUF`/`USE_IDELAY`
fix AND (b) the full set of RTL bug-fixes, built and HW-validated together.
Closing that is the core of RTL freeze.

---

## C. Jobs to reach RTL FREEZE

1. **Produce the unified RTL branch** — one branch with BOTH:
   - the `USE_CLKBUF`/`USE_IDELAY` clock-structure fix (from `72c280b`/`17160eb`; un-strip `51b5169` or re-base onto `72c280b`)
   - the RTL bug-fixes: #1, #2, #3 (`6a757e2`), #4 (`9b43676`+`a30b21b`), #9 (`2b5b6e5`), #23 (`cb2cd26`), #16 (`e412289`)
   - decision needed: re-base bug-fixes onto `72c280b`, OR cherry-pick `USE_CLKBUF` restore onto `feat/td-combined`.
2. **Rebuild the unified branch on srv03335/srv04936** and confirm clean netlist (Place 30-568 = 0, IDELAYE2 present, WHS > 0).
3. **HW-validate the unified branch = 16/16** on `bridge1` (this is the gate — fixes must not regress lane lock).
4. **Bug #3 explicit silicon validation** — instrument mask-FSM states 8/9/10 (ILA on `state_r`) on a locking bitstream; confirm mask phase completes.
5. **Bug #4 re-validation** on the locking build (prior F test was on a 0/16 bitstream).
6. **Bug #22** — run UVM regression; confirm the 5 masked-strobe reds clear (or land RTL/TB fix).
7. **Bug #30** — fix the `tidelink_phy_align_calibrator` TB/RTL port drift so its cocotb runs.
8. **AHB end-to-end on HW** — now unblocked (HW healthy, link locks); validate the AHB datapath (respect board-wedge: never write AHB_TX before link up).
9. **PTP single-phase silicon validation** — cocotb passing; confirm on HW.
10. **Integrate the `clkfreq-check` module + build-ID register** (`feat/clkfreq-check f88d4ba`) into `tidelink_top` + APB regs — the permanent guard against the wrong-bitstream/clock-mismatch class.
11. **Full regression green on the unified branch**: cocotb suite + UVM + HAL (0 errors) + Verilator strict-lint (0) + sv_anti_pattern.
12. **Reproducibility proof**: clean checkout of the frozen branch builds a 16/16 bitstream (no reliance on a preserved artifact).
13. **Freeze tag** — tag the unified, validated, reproducible commit as the RTL-freeze point; record canonical bitstream SHA256s.

### Not RTL-freeze gating (can land post-freeze)
- Verilator ≥5.x upgrade (LATCH/MULTIDRIVEN), CI integration phase 1 wiring,
  fpgahub CLI/daemon (#28a/#29), TideChart protocol, ASIC partition follow-through.

---

## D. Quick status roll-up

- **Lane lock: SOLVED & HW-validated** (`72c280b` 16/16). Root cause = `51b5169` stripped `USE_CLKBUF`.
- **RTL bug-fixes: mostly sim-validated, NOT yet HW-validated together with the lock fix** — that's the freeze work.
- **Most validated RTL fixes were never co-tested with a locking bitstream** because we lacked one until `72c280b`. Now we do, so HW validation can proceed.
- **Critical path to freeze:** unify `USE_CLKBUF` + bug-fixes on one branch → rebuild → HW-validate 16/16 → explicit mask/AHB/PTP silicon checks → reproducibility tag.

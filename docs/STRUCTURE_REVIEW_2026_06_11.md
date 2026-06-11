# Structural Review — tidelink + tidelink-gpio-phy — 2026-06-11

**Scope:** read-only review of `tidelink` (branch `feat/phy-v2-integration` @ `0f9a54e`,
plus the S3 worktree `~/SoCLabs/td-scratch/s3-swap` @ `feat/s3-phy-swap` `6199a2e`) and
`~/SoCLabs/tidelink-gpio-phy-deskew` (branch `feat/phy-refactor` @ `0af1668`, recommendations
only — another agent owns that tree).
**Companion docs:** [REPO_CLEANUP_ASSESSMENT_2026_06_11.md](REPO_CLEANUP_ASSESSMENT_2026_06_11.md)
(doc sprawl — now largely executed) and the untracked
`INTEGRATION_STATUS_2026_06_11.md` (V2 plan-vs-actual). This review covers the
*structural* dimensions those don't: submodules, local_overrides, RTL/flist/cocotb
dead weight, and the friction that will bite S6.

All "consumed-by" claims below were verified by grep against every Makefile,
`*.flist`, `*.tcl`, and `*.sh` in the repo (excluding `deps/`).

---

## 1. Submodule topology — two pins of the same remote

```
deps/axi-chiplet-controller  @ efe5623  (feat/l3-autonomy-merge)        — unchanged, fine
deps/tidelink-gpio-phy       @ 6ee8418  (feat/standalone-phy-bist)     — OLD line
deps/tidelink-phy            @ 3f6e7a0  (feat/s2-shared-component)     — NEW line, same remote repo
```

### 1.1 Exactly what each build consumes

**V1 consumes 5 RTL files + 1 incdir from `deps/tidelink-gpio-phy`** (the checker
stack only — everything else V1 needs is forked into `src/rtl/local_overrides/`):

| File | Consumed by |
|---|---|
| `rtl/tidelink_popcount16.sv` | `flists/tidelink_fpga.flist:290`, `tidelink_top_full_asic.flist:200`, `tidelink_top.flist:49`, `tidelink_lane_checker.flist:15` |
| `rtl/tidelink_lane_checker_single.sv` | same four flists |
| `rtl/tidelink_lane_checker.sv` | same four flists |
| `rtl/tidelink_gpio_phy_apb_regs.sv` | same four flists |
| `rtl/tidelink_lane_deskew.sv` | `cocotb/tidelink_deskew_bubble/Makefile` only |
| `rtl/` as incdir (`tidelink_training_patterns.svh`) | the four flists + `lint/Makefile:95` (`EXTRA_INCDIRS_tidelink_lane_checker`) |

**V2 consumes the whole component from `deps/tidelink-phy`** and nothing from the old pin:

| Group | Files (from `s3-swap/flists/tidelink_top_full_asic_v2.flist` + `flists/tidelink_phy_v2.flist`) |
|---|---|
| L1 vendor forks | `rtl/wav/WavD2DGpio.v`, `WavD2DGpioRx.v`, `WavD2DGpioTx.v` (v2:119-121), `WlinkGPIOPHY.v` (v2:166) |
| L2 TX | `tidelink_phy_tx_segmenter.sv`, `tidelink_phy_tx_mask.sv`, `tidelink_phy_sync_insert.sv` |
| L2 RX | `tidelink_phy_sync_detect.sv`, `tidelink_phy_rx_demask.sv`, `tidelink_lane_deskew.sv` |
| Wrappers | `tidelink_gpio_phy_tx.sv`, `tidelink_gpio_phy_rx.sv` (phy_v2.flist:44-45) |
| Checker/regs | `tidelink_popcount16.sv`, `tidelink_lane_checker{,_single}.sv`, `tidelink_gpio_phy_apb_regs.sv` (v2:245-248) |
| Calibrator | `rtl/tidelink_phy_align_calibrator.sv` (v2:254 — the **deps** copy, not `src/rtl`'s) |

Note the four checker files are the **same module names from both pins** — V1 flists
load the old pin's copies, the V2 flist loads the new pin's. No build loads both today,
but nothing structural prevents it (see §7.1).

### 1.2 End-state and what blocks it

**End-state: a single `deps/tidelink-phy` submodule.** The old pin exists *only* to keep
the silicon-validated V1 build bit-stable while V2 is validated. Blockers, in order:

1. **V2 validation ladder incomplete** — per INTEGRATION_STATUS: V2 full-stack pair sim
   not yet run, no V2 FPGA build, no V2 zero-poke silicon demo, no V5 long soak. Until
   then V1 is the shippable build and its pin must not move.
2. **Diverged content, same module names** — old-pin checker/deskew files are behind
   the Tier-2 rewrite happening on the new line; you cannot repoint V1 flists at
   `deps/tidelink-phy` and expect bit-stability (e.g. `tidelink_lane_deskew.sv` differs
   between all three copies in the workspace — see §3.3).
3. **No V2 FPGA flist yet** — `tidelink_fpga.flist` (303 L) is pure V1; the 25 MHz FPGA
   rig must stay alive (project policy), so retirement waits for a
   `tidelink_fpga_v2.flist` equivalent or a deliberate decision that the rig stays V1.
4. Four trivial repoints that must land in the retirement commit:
   `cocotb/tidelink_deskew_bubble/Makefile` (DESKEW_RTL path),
   `lint/Makefile:95` (EXTRA_INCDIRS), `flists/tidelink_lane_checker.flist`,
   and `docs/INTEGRATION_GUIDE.md` §submodules.

**Recommendation (low risk, do at V1 retirement, prepare the checklist now):** delete
`deps/tidelink-gpio-phy` + the four repoints above + the local_overrides deletions in §2.
Do **not** attempt an early "repoint V1 to the new pin" — that re-validates V1 for zero
benefit. (value: high / risk: low if sequenced after V5)

---

## 2. `src/rtl/local_overrides/` end-game

14 files, 15,549 lines total. Consumption matrix (line refs are flist line numbers):

| File | Lines | V1 FPGA (`tidelink_fpga`) | V1 ASIC (`top_full_asic`) | V2 ASIC (`..._v2`, s3-swap) | Fate |
|---|---:|---|---|---|---|
| `ShortPacketToWlink.v` | 185 | :98 | :78 | :110 | **KEEP** (both) |
| `TideLinkToWlink.v` | 194 | :103 | :79 | :111 | **KEEP** (both) |
| `WavD2DGpio.v` | 1231 | :127 | :84 | — (deps wav copy) | **DELETE @ V1 retirement** |
| `WavD2DGpioRx.v` | 609 | :134 | :85 | — | **DELETE — already 0-diff vs `deps/tidelink-gpio-phy/rtl/wav/` copy; can repoint now** |
| `WavD2DGpioTx.v` | 394 | :142 | :86 | — | **DELETE — also 0-diff vs submodule copy; can repoint now** |
| `Wlink.v` | 2559 | :250 | :178 | :223 (V2 arm, `7b38b76`) | **KEEP** (carries both arms) |
| `WlinkGPIOPHY.v` | 197 | :183 | :123 | — (deps `rtl/wav/WlinkGPIOPHY.v`) | **DELETE @ V1 retirement** |
| `WlinkGenericFCSM_6.v` | 1715 | :216 | :150 | :193 | **KEEP** (both) |
| `WlinkRxLinkLayer.v` | 1958 | :221 | :151 | :194 | **KEEP** (both) |
| `axi_chiplet_controller.sv` | 2380 | :278 | :221 | :267 (V2 arm, `f92c7c1`) | **KEEP** (carries both arms) |
| `i2c_master.v` | 902 | :264 | — (ASIC uses `deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master.v`) | — (same) | **RETIRE NOW (candidate)** — see below |
| `i2c_master_axil.v` | 785 | :260 | :188 | :233 | **KEEP** — functional fork (adds `status_o[3:0]` consumed by the controller; not just observability) |
| `tidelink_autoneg.sv` | 1781 | :282 | :192 | :237 | **KEEP** (both) |
| `tidelink_lane_deskew.sv` | 670 | :121 | :207 | — (deps copy :251) | **DELETE @ V1 retirement** (+ repoint `cocotb/tidelink_lane_deskew/Makefile`) |

**`i2c_master.v` special case:** the override adds only `(* mark_debug *)` attributes
(Bug N7/N8 observability). The *deps* copy has since gained the same observability
**properly gated behind `` `ifdef FPGA_DEBUG_ILA ``** — i.e. upstream superseded the
override. Repoint `tidelink_fpga.flist:264` at the deps copy after confirming the FPGA
flow defines `FPGA_DEBUG_ILA` (grep of `fpga/*.tcl` found no define at the top level —
check `fpga/targets/*/build_design.tcl` first; if absent, add the define rather than
keeping the fork). (value: medium / risk: low with the define check)

### Deletion schedule

| Phase | Trigger | Action | Net |
|---|---|---|---|
| **P0 — now** | none | Repoint `WavD2DGpioRx.v`/`WavD2DGpioTx.v` flist entries to `deps/tidelink-gpio-phy/rtl/wav/` (0-diff, bit-identical build); retire `i2c_master.v` override after the `FPGA_DEBUG_ILA` check | −1,905 L of duplicate text, no behavior change |
| **P1 — V2 FPGA flist exists** | S5/S6 | Decide FPGA rig fate (stay V1 forever vs migrate); if migrating, fpga flist drops the Wav*/deskew overrides | — |
| **P2 — V5 sign-off (V1 retirement)** | V2 silicon-validated | Delete `WavD2DGpio.v`, `WavD2DGpioRx.v`, `WavD2DGpioTx.v`, `WlinkGPIOPHY.v`, `tidelink_lane_deskew.sv` | −3,101 L |
| **P3 — same commit** | with P2 | Delete `deps/tidelink-gpio-phy` submodule + 4 repoints (§1.2.4); collapse the `TIDELINK_PHY_V2` ifdef arms in `Wlink.v` / `axi_chiplet_controller.sv` / `tidelink_top.sv` to V2-only | local_overrides drops to 8 files, all genuinely shared forks |

---

## 3. Duplicated / dead RTL in `src/rtl/` and orphan flists

(`tidelink_ahb.sv`, `tidelink.sv` wrapper, and `tidelink_addr_translation.sv` are
confirmed intentional — tb wrapper + alternative impl per `lint/Makefile:42-62` and
in-file notes — **not** flagged.)

### 3.1 Dead now (no instantiation anywhere)

| File | Lines | Evidence |
|---|---:|---|
| `tidelink_clkfreq_check.sv` | 176 | instantiated **nowhere** in `src/`, `fpga/`, `uvm/`, or deps; absent from all product flists; only its own unit flist + `cocotb/tidelink_clkfreq_check` + lint list + the regression ENVS line |
| `tidelink_apb_addr_ctrl.sv` | 188 | identical situation |

These are shelved features that still cost regression wall-clock (both are in the
cocotb `ENVS` list) and lint time. **Recommend:** either document why they're shelved
(one header line each, like `tidelink_addr_translation.sv` does) or move RTL+env to an
archive area and drop from `ENVS`/lint lists. (value: low-medium / risk: nil)

### 3.2 Retires with V1 (schedule with §2 P2)

| File | Lines | Why |
|---|---:|---|
| `src/rtl/tidelink_phy_align_calibrator.sv` | 1674 | V2 uses the `deps/tidelink-phy` copy (v2 flist :254). The two have **diverged hard** (1,521-line diff) — this is the "two diverged calibrators" risk on record. Until retirement, every fix must be assessed for double-landing. |
| `src/rtl/tidelink_eye_regs.sv` | 352 | V2 retires eye-vis (AUDIT #17; v2 flist :255 comment, s3 `6199a2e` ties off the slave). Retire together with `flists/tidelink_eye_regs.flist`, `flists/tidelink_eye_visibility.flist`, `cocotb/tidelink_eye_regs/`, and the eye surface ports in `tidelink_top.sv`. |
| `tidelink_idelay_rx.sv` / `tidelink_rxclk_buf.sv` | 219/93 | **NOT dead** — FPGA-quarantine via params, deliberately kept (project policy), and still listed in *both* ASIC flists (v2:263-264). Keep; see §7.7. |

### 3.3 Three copies of `tidelink_lane_deskew.sv`, two unit suites testing different ones

- `src/rtl/local_overrides/tidelink_lane_deskew.sv` (670 L) — built into V1 FPGA+ASIC; unit-tested by `cocotb/tidelink_lane_deskew/`.
- `deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv` — built into **nothing**; unit-tested by `cocotb/tidelink_deskew_bubble/`.
- `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv` — built into V2; unit-tested by **neither** tidelink-side suite (covered in the PHY repo).

So the bubble-bug regression (`tidelink_deskew_bubble`, the Bug-A artifact) currently
guards a copy no build consumes. **Recommend:** repoint `tidelink_deskew_bubble` at the
local_overrides copy now (the one actually shipped in V1), and at the `deps/tidelink-phy`
copy at retirement. (value: medium / risk: nil)

### 3.4 Flist inventory — 26 files: 2 orphans, 7 *missing*

Consumed (evidence abbreviated): `tidelink{,_ahb,_apb_addr_ctrl,_apb_regs,_fifo,_returner,_eye_regs}.flist`
(cocotb envs), `tidelink_fifo_ahb/clkfreq_check/idelay_rx/lane_checker/mul_iter/perf/phc_cdc/rxclk_buf/tl_addr_trans_{cam,regs}.flist`
(lint via `FLIST=flists/$(MODULE).flist`), `tidelink_eye_visibility.flist` (2 debug envs),
`tidelink_fpga.flist` (12 cocotb envs + `fpga/filelist.tcl` + `lint/verilator`),
`tidelink_netlist.flist` (gate-sim arm of `cocotb/tidelink`), `tidelink_asic.flist`
(`syn/asic/common.mk:28`), `tidelink_top_full_asic.flist` (`syn/asic/scripts/tidelink.FC.read_design.tcl`).

**Orphans (no Makefile/script consumer anywhere):**
- `flists/tidelink_generic.flist` — the only reference to `src/rtl/fifo/generic/tidelink_sram.sv`; both look like an abandoned "generic SRAM" build leg. Delete or wire up.
- `flists/tidelink_top.flist` — referenced only from docs. It duplicates the submodule
  checker block ("keep in sync" comment at :46) for no consumer. Either make it the
  canonical sim flist some env actually uses, or delete and let `tidelink_fpga.flist` be
  the sim source of truth. (value: low / risk: nil)
- (`flists/tidelink_phy_v2.flist` has no consumer yet either, but that's the live S3
  scaffold — not an orphan.)

**Missing — lint targets are broken:** `lint/Makefile` STANDALONE_MODULES names 7 modules
whose `flists/<module>.flist` **does not exist and never has** (verified with
`git log --all --follow`): `tidelink_fifo_ctrl`, `tidelink_fc_adapter`,
`tidelink_phy_align_calibrator`, `tidelink_ptp`, `tidelink_ptp_servo`,
`tidelink_addr_translation`, `tidelink_addr_translator`. `make -C lint lint-standalone`
fails on its **first** module (`tidelink_fifo_ctrl`). Fix = add the 7 small flists or
trim the list to reality. This silently weakens the "lint-clean" gate. (value: **high** / risk: nil)

---

## 4. `cocotb/` sprawl — 38 top-level + 12 `debug/` envs

### 4.1 Gated (do not touch)

- **`make regression` ENVS (cocotb/Makefile:7-10), 28 envs** — unit + system suites.
- **Root Makefile gates:** `sim-regression` → `cocotb/tidelink_top_pair/` (46 tests — the
  paired-die deploy gate); `sim-repro`/`sim-repro-skid3` → `cocotb/debug/wlink_pair/`
  (18 tests); `sim_robust` → `cocotb/debug/sim_robust/`; `xdc_lint`/`sim_synth_mode` →
  `cocotb/lint/`.

### 4.2 Ungated but live — recommend *wiring in*, not archiving

| Env | Why it matters |
|---|---|
| `tidelink_lane_deskew/`, `tidelink_deskew_bubble/` | The deskew unit suites that found the two silicon bugs integrated sim missed (read-controller stall, bubble dup). **Not reachable from any Makefile target.** Add them to `ENVS` or a `sim-deskew` gate. |
| `tidelink_top_pair_drift/`, `_skewed/`, `_wordskew/` | The drift suite is the only sim that reproduces the PPM-offset HW asymmetry class. Keep; consider folding into `sim-regression` as a second target. |
| `debug/phc_pair/` | PHC Phase-1 is still an open bug — keep until closed. |
| `debug/tidelink_phy_align_calibrator/` (11 tests), `debug/calibrator_force_bisect/` (7) | Active in the current calibrator campaign — keep until S3 lands, then they test the *retired* V1 calibrator → archive at P2. |
| `debug/tidelink_chiplet_pair_autocal/`, `debug/i2c_mask_selflock/` | Tied to autocal/I2C autonomy fixes that are merged; candidates to archive once V4 zero-poke passes on V2. |

### 4.3 Archive move list (forensic one-offs, all stale since ≤2026-05-29; move to `cocotb/archive/`, no deletions)

- `debug/bank_asymmetry/` (1 test) — bank-asymmetry hypothesis, closed.
- `debug/i2c_clkstretch/` (1) — one-off I2C clock-stretch repro.
- `debug/wlink_tx_pstate_ctrl/` (1) — PSTATE poke experiment.
- `debug/phy_align/` (16) — superseded by the PHY repo's own suites.
- `debug/tidelink_peer_aperture/` (1) — address-map oracle forensic (the 0x40000000 lesson is now in REGISTER_MAP).

### 4.4 Retires with V1 (flag now, move at P2)

- `wavd2d_gpiorx_t3a/`, `_t3a_off/`, `_t3a_timeout/` — these test the **compiled-out**
  T3A re-align path (`USE_T3A(1'b0)` everywhere, dead code on record). Three envs of
  regression time spent on dead code; archive candidates even *before* P2.
- `wav_d2d_gpio_tx/`, `wavd2d_gpiorx_clkbuf/` — old-PHY Wav-level units; superseded by
  the component repo's suites at P2.
- `tidelink_eye_regs/` — retires with the eye stack (§3.2).
- `tidelink_phy_align_calibrator/` (the non-debug one, 3 tests) — tests the V1 `src/rtl` calibrator; archive at P2.

(value: medium — regression minutes + cognitive load / risk: nil if archived not deleted)

---

## 5. `docs/` — consolidation held; V2 refresh list

State: 9 root files + `archive/` (118 files). The 5-doc product set + README + the
field-verified `BOARD_DEPLOY_RUNBOOK.md` are all current as of 2026-06-11. The
REPO_CLEANUP_ASSESSMENT's headline (134-file sprawl) has been executed. Issues found:

1. **`docs/INTEGRATION_STATUS_2026_06_11.md` is untracked** (`git status`: `??`). It's
   the V2 status of record — commit it (or it dies with a workspace wipe).
2. **`docs/INTEGRATION_GUIDE.md` is already factually stale:** line 64 says
   "`.gitmodules` declares only these two submodules" — there are **three** since
   `42f1cef` added `deps/tidelink-phy`. The submodule table at :62 also omits it.
   Small fix, do now.
3. **No committed product doc mentions `USE_PHY_V2` or `deps/tidelink-phy`** (only the
   untracked status doc does). Fine while V2 is non-default; becomes wrong the day
   USE_PHY_V2 flips. **V2-default doc checklist:**
   - `README.md` (docs index): "GPIO PHY consumed from `deps/tidelink-gpio-phy`" → tidelink-phy.
   - `INTEGRATION_GUIDE.md`: submodule table, flist names (`tidelink_top_full_asic_v2` story), build-target matrix.
   - `ARCHITECTURE.md`: PHY block decomposition (Segmenter/Mask/SyncInsert | SyncDetect/Demask/Deskew), L0/L1/L2 layering, align-contract VERSION=1.
   - `REGISTER_MAP.md`: retire eye Region 10; add the FIX-series calibrator surface.
   - `VERIFICATION_PLAN.md`: V0–V5 ladder, V2 pair-sim gate, drift/deskew suite roles.
   - `BOARD_DEPLOY_RUNBOOK.md`: already V2-era; re-verify tap values post-S3.
4. `REPO_CLEANUP_ASSESSMENT_2026_06_11.md` — once its remaining checkboxes close,
   move it to `archive/` per its own convention.

(value: medium / risk: nil)

---

## 6. PHY repo structure (recommendations for the other agent — no changes made)

### 6.1 BIST-vs-component split in `rtl/` (19 files)

**Shared component** (what tidelink consumes): `tidelink_gpio_phy_{tx,rx}.sv`,
`tidelink_phy_tx_segmenter.sv`, `tidelink_phy_tx_mask.sv`, `tidelink_phy_sync_insert.sv`,
`tidelink_phy_sync_detect.sv`, `tidelink_phy_rx_demask.sv`, `tidelink_lane_deskew.sv`,
`tidelink_lane_checker{,_single}.sv`, `tidelink_popcount16.sv`,
`tidelink_gpio_phy_apb_regs.sv`, `tidelink_phy_align_calibrator.sv`,
(`tidelink_phy_align_if.sv` on the S2 branch), `tidelink_sync_word.svh`,
`tidelink_training_patterns.svh`, `rtl/wav/` (L0 `upstream/` + L1 forks).

**BIST harness only** (must never leak into tidelink flists — currently doesn't):
`tidelink_phy_bist_core.sv`, `tidelink_phy_bist_prbs.sv`, `tidelink_phy_bist_regs.sv`.

**Recommend:** move the three BIST files to `rtl/bist/` (or at minimum publish a
component flist — see 6.2) so the component boundary is a directory boundary, not tribal
knowledge. The L0/L1 `rtl/wav/{upstream,}` split on the S2 branch already does this
correctly for the vendor layer. (value: high for S6 / risk: low — three `git mv`s + flist touch-ups)

### 6.2 Publish a canonical component flist

`flists/` contains only `phy_bist_fpga.flist`. The component's file list currently
lives in the *consumer* (`tidelink/flists/tidelink_phy_v2.flist` + inlined again in
`tidelink_top_full_asic_v2.flist`). Publish `flists/tidelink_phy_component.flist`
(relative to a `$(TIDELINK_PHY_HOME)` var) in the PHY repo and make tidelink's copies
generated or at least diff-checked in CI against it. This is the single highest-leverage
fix for the S6 keep-in-sync problem (§7.2). (value: **high** / risk: low)

### 6.3 Layout: `tb/` + `cocotb/` + `flows/`

The layout is sound: `flows/{cocotb,lint,uvm,fpga,format}` = harness policy,
`cocotb/<env>` = suites including `Makefile.common`. Two nits:
- The S2 branch adds a third test convention, top-level `tb/` (align-if smoke). Fold it
  into `cocotb/` (or `flows/uvm/`-style naming) before it accretes siblings.
- `results/` (pattern-search outputs) and `scripts/exp_*.sh` one-offs at top level —
  move under `docs/archive/` / `scripts/archive/` respectively; `scripts/build_tier2_calsimp.sh`
  is **untracked** — commit or delete.

### 6.4 sim_build dirs

83 `sim_build*`/`sim_run*` dirs, **78 of them under `cocotb/phy_bist/` totalling ~1.4 GB**
(per-experiment `sim_build_*` variants). All are gitignored — this is disk hygiene, not
repo hygiene: `rm -rf cocotb/*/sim_build_* cocotb/*/sim_run_*` when the current
campaign's artifacts are no longer needed. Same disease in tidelink (159 dirs) and
`imp/` (248 MB FPGA outputs). Consider a `make scrub` target that keeps the last run.
(value: low / risk: nil)

### 6.5 `docs/INTEGRATION_GUIDE.md` is the known-outdated doc — still ranked #4 in `docs/README.md`

It describes the **pre-S2 in-place migration** (delete `src/rtl/tidelink_lane_checker.sv`,
edit `local_overrides/WavD2DGpio.v`, `USE_NEW_CHECKER` guard) — the integration actually
shipped as *submodule consumption* per `archive/PLAN_TIDELINK_INTEGRATION.md`, which the
status doc explicitly calls authoritative. Rewrite INTEGRATION_GUIDE around: consume
`deps/tidelink-phy` @ pin, the align-contract (`tidelink_phy_align_if` VERSION=1), the
component flist (6.2), and the drift guard. (value: high / risk: nil)

---

## 7. Naming/layout friction that will bite S6 ("ASIC flist refresh from shared component")

1. **Same module names, three providers.** `tidelink_lane_deskew` ×3,
   `tidelink_phy_align_calibrator` ×2, the checker/popcount/apb_regs quartet ×2, and the
   `Wav*` files ×3 (local_overrides + both submodule pins). Any tool that reads two of
   these trees (or both `+incdir+…/rtl` lines) gets duplicate modules or, worse for
   `.svh`, *order-dependent header resolution*. S6 must end with **exactly one provider
   per module name** in the workspace; until then, never let a flist carry both incdirs.
2. **The V2 source list exists in three places** that must be hand-synced:
   `flists/tidelink_phy_v2.flist` (45 L), inlined into
   `tidelink_top_full_asic_v2.flist` (273 L), and the PHY repo's own file set. The V1
   flists already carry "Mirror of deps/… keep in sync" comments (`tidelink_top.flist:46`)
   — that pattern demonstrably rots. Root cause: flat tools (FC `read_design.tcl`,
   Vivado) can't nest `-f`. Fix: generate the flat flists from the component flist
   (small `scripts/gen_flists.py`), or CI-diff them (6.2).
3. **Three names for one PHY repo:** remote `tidelink-gpio-phy`, working clone
   `tidelink-gpio-phy-deskew`, submodule dirs `deps/tidelink-gpio-phy` *and*
   `deps/tidelink-phy`. After P3 the survivor should be `deps/tidelink-phy` everywhere,
   and the clone renamed to match. Also mixed module prefixes inside the component
   (`tidelink_gpio_phy_tx` vs `tidelink_phy_tx_segmenter`) — pick one prefix before the
   ASIC flist freezes the names into sign-off collateral.
4. **`WlinkGPIOPHY.v` ownership is split across repos in V2:** the Wlink-side PHY shim
   ships from `deps/tidelink-phy/rtl/wav/` while every other Wlink override stays in
   `tidelink/src/rtl/local_overrides/`. Defensible (it *is* the PHY-facing boundary) but
   undocumented — one sentence in both ARCHITECTURE docs prevents a future "who patches
   WlinkGPIOPHY" fork.
5. **HAL ignores `+incdir+` inside flists** (verified note at `lint/Makefile:86-94`), so
   include paths are duplicated as hardcoded `EXTRA_INCDIRS` — currently pointing at the
   **old** pin. After the swap, lint would silently compile V2 RTL against V1
   `tidelink_training_patterns.svh`. Grep for `deps/tidelink-gpio-phy` outside `flists/`
   as a retirement-commit gate (today: `lint/Makefile`, `cocotb/tidelink_deskew_bubble/Makefile`).
6. **Two ASIC flists with non-obvious roles:** `tidelink_asic.flist` (syn elaboration,
   `syn/asic/common.mk`) vs `tidelink_top_full_asic.flist` (FC PnR read_design). S6
   refreshes both or ships a split-brain — the exact failure mode of the 2026-06-03
   controller audit. Rename (`_syn`/`_pnr` suffixes) or cross-reference in headers.
7. **FPGA-quarantine modules ride in the ASIC flists** (`tidelink_idelay_rx.sv`,
   `tidelink_rxclk_buf.sv`, v2 flist :263-264, params tie them to passthrough). Policy
   says keep them — fine — but the S6 refresh should mark that section with an explicit
   `// FPGA-quarantine — passthrough in ASIC (USE_IDELAY/USE_CLKBUF=0)` banner so a
   future "cleanup" doesn't delete them (it's been attempted before) and sign-off
   reviewers don't chase Xilinx primitives.

---

## Top-10 recommendations (ranked by value/risk)

1. **Fix `lint/Makefile`: 7 STANDALONE_MODULES have no flist — `lint-standalone`/`lint-each` fail on the first module; add the 7 flists or trim the list (§3.4).**
2. **Adopt the local_overrides deletion schedule (§2): P0 repoints now (Wav Rx/Tx 0-diff dupes, i2c_master.v superseded fork), P2/P3 delete ~3.1 kL + the old submodule after V5.**
3. **Single-source the V2 file list: PHY repo publishes a component flist; tidelink's two V2 flists become generated/CI-diffed copies (§6.2, §7.2).**
4. **Prepare the `deps/tidelink-gpio-phy` retirement checklist (4 repoints + grep gate for stragglers, §1.2/§7.5) so the P3 commit is mechanical.**
5. **Wire the deskew unit suites (`tidelink_lane_deskew`, `tidelink_deskew_bubble`) into a Makefile gate, and repoint `deskew_bubble` at a copy a build actually ships (§3.3, §4.2).**
6. **Commit `docs/INTEGRATION_STATUS_2026_06_11.md` and fix the already-false "two submodules" line in `INTEGRATION_GUIDE.md`; queue the 6-doc V2-default refresh list (§5).**
7. **Move 5 dead `cocotb/debug/` one-offs to `cocotb/archive/` and archive the 3 `wavd2d_gpiorx_t3a*` envs that test compiled-out dead code (§4.3-4.4).**
8. **PHY repo: split `rtl/bist/` from the shared component and rewrite its INTEGRATION_GUIDE around submodule consumption (§6.1, §6.5) — for the other agent.**
9. **Resolve the dormant pair `tidelink_clkfreq_check.sv`/`tidelink_apb_addr_ctrl.sv` (document-why-shelved or archive) and delete orphan flists `tidelink_generic.flist`/`tidelink_top.flist` (§3.1, §3.4).**
10. **Rename for S6: one PHY repo name (`deps/tidelink-phy`), one module prefix, `_syn`/`_pnr` ASIC flist suffixes, and an FPGA-quarantine banner in the ASIC flists (§7.3, §7.6, §7.7).**

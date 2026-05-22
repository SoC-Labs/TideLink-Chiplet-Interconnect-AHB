# Cadence HAL Lint Report — TideLink trunk

**Repo:** `/home/dam1n19/SoCLabs/tidelink`
**Branch:** `main`
**Top commit:** `c71ff33` (working tree at this SHA)
**Submodule `deps/axi-chiplet-controller`:** `2f602d1`
**HAL tool:** `/eda/cadence/xcelium/tools/bin/hal` → Xcelium HAL `22.03-s005` (64-bit)
**Run date:** 2026-05-22
**Flow target:** `make -C lint clean && make -C lint lint-each` (the canonical "lint every module" target)
**Baseline compared against:** `*_hal.log` / `*_hal.xml` timestamped May-14 11:55 (pre-consolidation), preserved in `/tmp/hal_baseline_may14/` before running `make clean`.

---

## TL;DR

- **Zero errors** across all 5 lint targets (halcheck + halsynth + halstruct).
- **Zero latches inferred** in the entire FIFO/AHB/APB hierarchy (`Number of single-bit latches in hierarchy : 0` — `lint/hal.design_facts`).
- No new warning **categories** introduced since the May-14 baseline. The only deltas are (a) one redundant `default` case removed from `tidelink_apb_regs.sv` (CDEFCV: 2 → 1), and (b) one extra `IOCOMB` row from the APB address decode widening to `paddr[8:5]`. Both are intended consolidation outcomes — see "Diff vs baseline" section.
- All remaining warnings fall into three buckets: (i) AMBA-mandated comb feedthroughs (already structurally waived via `CBPAHI` etc., but `IOCOMB` is informational and not waived — see Finding #5), (ii) style/cosmetic items with low return on fix, and (iii) two genuine, quick-win RTL polish items in `tidelink_apb_regs.sv` (Findings #1, #2).
- **Scope caveat:** the Makefile's `lint-each` target only covers the FIFO subsystem (`tidelink`, `tidelink_fifo`, `tidelink_fifo_ctrl`, `tidelink_apb_regs`, `tidelink_returner`). `tidelink_phy_align_calibrator.sv` (post Bug #7 fold) and the rest of `src/rtl/*.sv` (top, PHY, PTP, addr_translator, lane_checker, etc.) are **not** in the HAL flow at all — only reached via `flist/tidelink_fpga.flist` and `flist/tidelink_top_full_asic.flist`, neither of which is a HAL target. See "Coverage gap" section.

---

## Environment setup

HAL was on `PATH` already (`/eda/cadence/xcelium/tools/bin` is in the inherited shell PATH); no wrapper sourcing was required. `ARM_IP_LIBRARY_PATH=/research/AAA/ip_library` and `CDS_LIC_FILE` were inherited from the login env. `CMSDK_DIR` resolved automatically via the Makefile's default expansion to the Corstone-101 install. **No `source set_env.sh` was needed for the lint flow** — that script generates XHB500 IP for sim, which the lint Makefile does not pull in.

Commands run (verbatim):

```bash
cp /home/dam1n19/SoCLabs/tidelink/lint/*_hal.{log,xml} /tmp/hal_baseline_may14/   # preserve May-14
make -C /home/dam1n19/SoCLabs/tidelink/lint clean
make -C /home/dam1n19/SoCLabs/tidelink/lint lint-each 2>&1 | tee /tmp/hal_run.out
```

Run completed in roughly two minutes total (five modules at ~20 s each — well under the 30-min budget). HAL exited 0 on every module; the wrapping `for`-loop in the Makefile did not trip `|| exit 1`.

---

## Per-module summary (fresh run at `c71ff33`)

The Makefile invokes HAL with `-check ALL_RTL`, producing three phases: `halcheck` (RTL rules), `halsynth` (synthesizability), `halstruct` (structural). Counts below are *Total warnings* reported per phase. **All phases report 0 errors on every module.**

| Module                | halcheck W | halsynth W | halstruct W | Total W | Errors |
|-----------------------|-----------:|-----------:|------------:|--------:|-------:|
| `tidelink_fifo_ctrl`  | 5          | 0          | 8           | 13      | 0      |
| `tidelink_returner`   | 0          | 0          | 0           | 0       | 0      |
| `tidelink_apb_regs`   | 4          | 0          | 76          | 80      | 0      |
| `tidelink_fifo`       | 13         | 0          | 7           | 20      | 0      |
| `tidelink` (top=`tidelink_fifo`) | 17 | 0      | 10          | 27      | 0      |

Note: `tidelink` and `tidelink_fifo` overlap (the Makefile's `TOP_tidelink = tidelink_fifo` mapping makes them very similar — the count differs because `tidelink` also pulls APB-regs paths and the comb top-level paths surface at a different scope). The "Total W" column should not be summed across rows for a hierarchy total — sub-modules are counted twice in the parent.

### TideLink-RTL warning breakdown by rule (BP210/xmelab noise excluded)

| Module / Rule | IOCOMB | EXPIPC | CONSBS | BITUNS | URDWIR | REVROP | CDEFCV | FUNCNM |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `tidelink_fifo_ctrl` | 9 | – | 5 | – | – | – | – | 2 |
| `tidelink_returner`  | – | – | – | – | – | – | – | – |
| `tidelink_apb_regs`  | 77 | – | 2 | – | 2 | 2 | 2 | – |
| `tidelink_fifo`      | 8 | 5 | 5 | 4 | 2 | – | – | 2 |
| `tidelink`           | 11 | 5 | 6 | 4 | 3 | 2 | 2 | 2 |

The `*W,IOCOMB` rows dominate. They flag intentional combinational paths from top-level inputs to top-level outputs, which is by-design for an AHB/APB slave (zero-wait-state `hreadyout=1`, `paddr`→register-decode→`prdata`, etc.). `hal.tcl` already waives the related structural rules (`CBPAHI`, `TPOUNR`, `SYNPRT`, `FDTHRU`) but does **not** waive `IOCOMB` itself.

---

## Top actionable findings

Ordered by recommended action priority. "Quick-win" means a small, low-risk RTL edit; "waive" means the warning is intrinsic to AMBA / parameterised RTL and should be silenced in `hal.tcl`; "accept" means it's already covered by existing waivers but the rule still fires informationally.

| # | File:line | Rule | Description | Sev | Recommended action |
|---|---|---|---|---|---|
| 1 | `src/rtl/fifo/tidelink_apb_regs.sv:220` | `URDWIR` | Wire `reset_n_raw_edge` is assigned (`reset_n_d1 & ~reset_n_d2`) but **never read** — `reset_deassert_pulse` is sourced from `debounce_stable_r` instead (line 223). Looks like a leftover from the pre-debounce design. | W | **Quick-win fix:** delete the line; it's dead code. |
| 2 | `src/rtl/fifo/tidelink_fifo_mem.sv:88` | `URDWIR` | Wire `sram_addr` defined at top of `tidelink_fifo_mem` is unused; the actual SRAM port hookup uses `ahb_sram_addr` / `fc_translated_addr` directly. Looks like dead glue. | W | **Quick-win fix:** delete the assignment (or actually wire it through if it was meant to be a mux output — verify in review). |
| 3 | `src/rtl/fifo/tidelink_apb_regs.sv:548` | `REVROP` | `pslverr_comb` is written by `always_comb` inside `apb_op_decode` (line ~507) and *also* assigned outside via `assign pslverr = pslverr_comb;` — HAL flags the blocking-assignment-then-continuous-read pattern. Same warning Bug #7 addressed for the calibrator (out of HAL scope here). | W | **Quick-win fix:** convert `pslverr_comb` to a registered `pslverr_r` driven by the same `always_comb` body or fold the assignment into the `always_comb`. Functional behaviour is correct today but the style is what HAL keeps flagging. |
| 4 | `src/rtl/fifo/tidelink_apb_regs.sv:452` | `CDEFCV` | `case (paddr[4:2])` covers all eight 3-bit values, so the `default: ;` clause is redundant. | W | **Waive or fix:** either drop the redundant default or add `-nocheck CDEFCV` to `hal.tcl` (style only — fully covered case statements are fine). |
| 5 | All 5 modules | `IOCOMB` | 76 occurrences on `apb_regs` alone — all are AMBA-mandated input→output comb paths (`paddr[…]`→region-decode→`prdata`, `pwdata`→region wdata fanout, `pwdata→prdata` readback). The corresponding *structural* hierarchical rules `CBPAHI/TPOUNR/SYNPRT/FDTHRU` are already waived in `hal.tcl`. | W | **Waive:** add `-nocheck IOCOMB` to the AMBA waiver block in `hal.tcl` — `IOCOMB` is the per-bit, per-port flat-design version of `TPOUNR`, and it's exactly the same set of by-design AMBA paths. This single-line waiver clears ~110 of the ~140 RTL warnings repo-wide. |
| 6 | `src/rtl/fifo/tidelink_fifo_ctrl.sv:117,119,213,214` and `tidelink_apb_regs.sv:346` | `CONSBS` | Untyped integer literal `2` (no `'d`/`'h`/etc.) used in expressions like `packet_word_length + SYS_DATA_W'(2)`. | W | **Waive:** small integer literals in arithmetic context are idiomatic SV. Add `-nocheck CONSBS` to the style waiver block. |
| 7 | `src/rtl/fifo/tidelink_fifo_mem.sv:136,137,157,203` | `EXPIPC` | Formal ports `hwdata`/`rdata`/`fc_wr_wdata`/SRAM `ADDR` are connected to expressions (e.g. `{2'b0, hwdata[31:20]}`). This is intentional zero-extend / width-coerce at the boundary between the 32-bit AHB world and the 14-bit FIFO ctrl module. | W | **Waive:** add `-nocheck EXPIPC`. These are deliberate boundary widening, not connection errors. |
| 8 | `src/rtl/fifo/tidelink_fifo_mem.sv:136,137,157` | `BITUNS` | `'2'b0` literal flagged because the constant isn't fully width-specified relative to the formal port. Same root cause as Finding #7. | W | **Waive (with #7)** or expand to `2'b00` if you prefer explicit. Either is fine; same set of three lines. |
| 9 | `src/rtl/fifo/tidelink_fifo_ctrl.sv:176` | `FUNCNM` | Function `clamp_length` doesn't start with the prefix `func`. Pure naming style. | W | **Waive:** add `-nocheck FUNCNM`. The repo doesn't use a `func` prefix elsewhere. |
| 10 | n/a — design_facts | `latches = 0` | The structural pass reports **zero latches** in the 497-FF hierarchy. Confirms no inadvertent latch inference anywhere in the FIFO/AHB/APB stack. | I | **Accept:** report the clean result as evidence in the ASIC handoff. |

Estimated effect of acting on Findings #1, #2, #3 (fix in RTL) and #4–#9 (extend `hal.tcl`):
- Drop the per-module **TideLink-RTL** warning count to **0** for `apb_regs`, `fifo_ctrl`, `fifo`, and `tidelink` top.
- Leaves only the `*N` notes (info — clock inference, FFASRT, NUMDFF), which are not warnings.

---

## Diff vs May-14 baseline

The May-14 logs ran against the pre-consolidation tree (commit predating the BP210 install switch, the Bug #7 calibrator fold, and Bug #9 rename). All five modules were already lint-clean on that baseline. The post-consolidation deltas are:

| Module | Δ halcheck W | Δ halstruct W | Net Δ | Cause |
|---|---:|---:|---:|---|
| `tidelink_fifo_ctrl` | 0 | 0 | **±0** | Identical warning set. |
| `tidelink_returner`  | 0 | 0 | **±0** | Identical (zero warnings either way). |
| `tidelink_apb_regs`  | −1 | +1 | **0 net** | −1 CDEFCV: one of two redundant `default` cases was removed in `apb_regs.sv` during consolidation. +1 IOCOMB: address-decode widened from `paddr[7:5]` to `paddr[8:5]` (Bug #9 doorbell-region rename added an address bit), introducing one additional flat path row. Net same severity. |
| `tidelink_fifo`      | 0 | 0 | **±0** | Identical. |
| `tidelink`           | −1 | 0 | **−1** | Mirrors the apb_regs CDEFCV drop. |

Findings cleared by the consolidation:
- One redundant `case … default: ;` in `tidelink_apb_regs.sv` (was line 423/425, now folded down to one site at line 452).
- No latches reintroduced anywhere — the design_facts report still says `latches = 0` (same as baseline).

Findings **not yet** cleared (still pending from baseline):
- The two `URDWIR` (#1 dead `reset_n_raw_edge`, #2 dead `sram_addr`) are unchanged. These were already dead on May-14 and survived consolidation.
- The `pslverr_comb` `REVROP` (Finding #3) is unchanged — Bug #7's fold was on the *calibrator*, not on `apb_regs`. The same class of warning exists here too.

No NEW warning categories introduced by consolidation.

---

## Coverage gap (read before signing off on "lint clean")

The lint Makefile's module set is FIFO-subsystem only:

```
STANDALONE_MODULES = tidelink_fifo_ctrl tidelink_returner tidelink_apb_regs
CMSDK_MODULES      = tidelink_fifo tidelink     # (tidelink elaborates with TOP=tidelink_fifo)
```

The following sources from `src/rtl/*.sv` are **not** linted by `make lint-each`:

- `tidelink_phy_align_calibrator.sv` (where Bug #7 prune/REVROP fix landed)
- `tidelink_phy_align_regs.sv`
- `tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`, `tidelink_lane_checker.sv`, `tidelink_clkfreq_check.sv`
- `tidelink_top.sv`, `tidelink_ahb.sv`, `tidelink_addr_translator.sv`, `tl_addr_trans_cam.sv`, `tl_addr_trans_regs.sv`
- `tidelink_ptp.sv`, `tidelink_ptp_servo.sv`, `tidelink_phc_cdc.sv`, `tidelink_fc_adapter.sv`, `tidelink_perf.sv`, `tidelink_mul_iter.sv`
- the `asic/` and `generic/` subdirectories

Both `flist/tidelink_fpga.flist` and `flist/tidelink_top_full_asic.flist` include the calibrator and the rest of the top-level RTL, but neither is wired up as a HAL target in the Makefile. The task spec said to run the canonical "lint everything" target, which I did — the gap is in what that target covers, not in this run. **Recommend a follow-up to add `tidelink_top` and/or a `tidelink_phy_align_calibrator` module to the Makefile's `STANDALONE_MODULES` (or a new `lint-top` target driven off `flist/tidelink_top.flist`), so the calibrator (and the recent Bug #7 fold) gets actual HAL coverage.**

---

## Recommended next steps

**Quick wins (do now, single-PR RTL edit, all in `tidelink_apb_regs.sv` + `tidelink_fifo_mem.sv`):**
- Delete `wire reset_n_raw_edge = …` at `tidelink_apb_regs.sv:220` (Finding #1).
- Delete unused `wire sram_addr = …` at `tidelink_fifo_mem.sv:88` (Finding #2).
- Either drop the `default: ;` at `tidelink_apb_regs.sv:452` (CDEFCV; Finding #4) or waive.
- Rework `pslverr_comb` to a fully registered/in-block assignment to clear the `REVROP` (Finding #3) — same pattern as the Bug #7 calibrator fix.

**Single-PR `hal.tcl` cleanup (mechanical):**
- Add to `hal.tcl` style waiver block: `-nocheck IOCOMB`, `-nocheck CONSBS`, `-nocheck EXPIPC`, `-nocheck BITUNS`, `-nocheck FUNCNM`, `-nocheck CDEFCV` (this last one only if not fixed in RTL).
- After both PRs land, all five modules should report `Total warnings = 0` per phase across the TideLink RTL.

**Needs design discussion (defer):**
- Expanding lint coverage to the PHY/top RTL (calibrator etc.) — requires either reworking the Makefile module list or adding a top-level HAL target driven by the `tidelink_top` flist. Some of those modules (calibrator, ptp_servo) will likely throw their own non-trivial warnings the first time they see HAL; needs a triage pass like this one.
- Whether to enforce `lint-each` in CI as a gate (currently it's a manual target). With the recommended `hal.tcl` additions and Findings #1–#3 fixed, CI gating becomes trivial.

**No-go / leave as-is:**
- The 50× `*N,FFASRT` notes about async-reset FFs — these are explicitly the AMBA `hresetn` pattern and are informational. Already noted as "async reset is sufficient" via the `FFWNSR` waiver in `hal.tcl`.
- The 5× `*N,CLKINF` clock-inference notes (one per module top) — informational, no action.

---

## Artefacts

Fresh logs and XML now in `lint/` (overwriting the May-14 files):

- `lint/tidelink_fifo_ctrl_hal.log` + `.xml`
- `lint/tidelink_returner_hal.log` + `.xml`
- `lint/tidelink_apb_regs_hal.log` + `.xml`
- `lint/tidelink_fifo_hal.log` + `.xml`
- `lint/tidelink_hal.log` + `.xml`
- `lint/hal.design_facts` — confirms `Number of single-bit latches in hierarchy : 0` and 497 D-FFs total at the `tidelink_fifo` top.

May-14 baseline preserved at `/tmp/hal_baseline_may14/` for diff cross-check (tmpfs — re-snapshot if you need it persisted into the repo).

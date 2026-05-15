# TideLink PHY Alignment — Fresh Plan from 2026-05-14 State

**Branch:** `feat/fpga-flow`
**Author:** dam1n19 with Claude Code assistance
**Supersedes (partially):** [`~/.claude/plans/tidelink-bit-slip-i2c-coordination.md`](../../../.claude/plans/tidelink-bit-slip-i2c-coordination.md)
**Companion docs:** [`BRINGUP_REPORT.md`](../BRINGUP_REPORT.md), [`deps/axi-chiplet-controller/logical/phy-align/README.md`](../deps/axi-chiplet-controller/logical/phy-align/README.md)

This plan picks up from the state of the code as of late 2026-05-14, after a substantial day of diagnosis (§3, §4 of `BRINGUP_REPORT.md`), prototype RTL (§9), cocotb validation (8 PASS scenarios), UVM integration (which surfaced §9.8), lint (clean), and a full FPGA build pair (both bitstreams produced clean). It does not re-state work that's already done; it identifies the remaining gaps and orders them.

## 1. Current state (what's already done)

### 1.1 Diagnosis (done)

- Root cause confirmed: deterministic 3-bit serial-to-parallel boundary misalignment in `WavD2DGpioRx`. Master `byte0_reg` distribution matches the seven FC channels' `cr_id` bytes right-shifted by 3 bits, in their expected 2+2+1+2 proportional grouping.
- `swi_phase_offset` proven insufficient: 256-combo sweep, 0 winners; the reg adjusts sub-bit-cell sample point only, not the 8-bit S/P boundary.
- Ruled out: cable, FPGA pin mapping (all 18 pins symmetric, verified), ILA routing congestion (revert build still stuck), the in-session FCSM_6 RTL "fix" (was actively broken — reverted to `git HEAD`).
- Wlink and Wavious do not provide a built-in alignment mechanism (confirmed against public Wlink docs and `wav-wlink-hw/` repo search).

### 1.2 Layer 1 RTL prototype (done — in-place edits)

Files modified in `deps/axi-chiplet-controller/logical/wlink/` (diff captured at `deps/axi-chiplet-controller/logical/phy-align/wavd2dgpio-bitslip-training.patch`):

- `WavD2DGpio.v` — added `swi_bit_slip[23:0]` (8 × 3-bit) and `swi_training_mode` as sim-only soft-strap regs (default 0 = bit-exact passthrough); wired to per-lane RX/TX instances.
- `WavD2DGpioRx.v` — added `io_bit_slip[2:0]` input, per-lane 16-bit right-rotation barrel mux.
- `WavD2DGpioTx.v` — added `io_training_mode` + `io_training_pattern[7:0]` inputs; mux selects training pattern over LL data when training_mode=1.

Per-lane training bytes: `0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D` (hand-picked period-8; the originally-spec'd `(N+1)*0x11` would alias slip=k vs k+4 because of period-4 symmetry — a real bug caught during validation, must not be reverted).

New module (currently in `cocotb/phy_align/` — should move to PHY repo on extraction):

- `wlink_lane_checker.sv` — 8-lane wrapper around a single-lane `match_count` FSM. Saturating 5-bit counter, threshold 16. Outputs `lane_locked[7:0]`.

### 1.3 Cocotb sandbox (done — 8 PASS scenarios)

Testbench: `cocotb/wlink_pair/tb_top.sv` plus `cocotb/wlink_pair/pad_skid.sv` (per-lane skid injector, post-extension by agent).

Tests in `cocotb/phy_align/`:

| Test | What it covers | Status |
|---|---|---|
| `test_pair_align.py` | Uniform skid 0/1/3/5/7 | PASS at all |
| `test_pair_align_asymmetric.py` | 5 patterns: `[3,5,0,2,7,1,4,6]`, `[1,1,1,1,5,5,5,5]`, `[0,7,0,7,0,7,0,7]`, `[7,6,5,4,3,2,1,0]`, `[0,0,0,0,0,0,0,0]` | PASS at all |
| `test_pair_align_partial_failure.py` | One lane stuck — expects fail-mode detection | PASS (correctly fails to lock) |
| `test_pair_align_retraining.py` | Calibrate → up → retrain → up | PASS |
| `test_pair_align_asymmetric_master_slave.py` | Different patterns each direction | PASS |
| 9 pre-existing `test_link_bringup`/`test_assert_bringup` | Regression | All PASS at SKID_BITS=0 (default) |

Calibration is driven from cocotb via hierarchical reference to `swi_bit_slip` and `swi_training_mode` — no APB, no in-RTL FSM yet.

### 1.4 UVM integration (done — surfaced sequencing issue)

UVM testbench: `uvm/tidelink_top_system/`. New per-lane pad-skid + lane-checker observers + hierarchical-ref drive for soft-strap regs. 4 alignment tests added.

Tests compile, elaborate, and run cleanly. Existing UVM regression intact. **But end-to-end calibration does not converge** under realistic bring-up sequencing. Root cause documented in `BRINGUP_REPORT.md §9.8`:

> Asserting `swi_training_mode=1` before `role_lock` blocks LL_RX's clock domain from spinning up properly, because the training pattern displaces the cr_pkt traffic that the receiver-side LinkLayer needs for clock recovery.

This is the **production-correctness gap**. The cocotb sandbox papers over it via backdoor force/release on clocks and POR; UVM exercises the real APB-driven `strap → role_lock → swreset → cr_pkt` chain and exposes it. Real hardware will see the same issue.

### 1.5 Lint (done)

Verilator `--lint-only -Wall` on the §9-modified files: one real WIDTH warning found on the slip-indexer (`{1'b0, io_bit_slip}` indexing `[31:0]` needed 5 bits, not 4). Fixed by zero-extending to `{2'b00, io_bit_slip}`. Remaining "missing module" errors are Wavious DFT cells (`WavClockMux`, `WavResetSync`, etc.) — pre-existing, not §9-related.

### 1.6 FPGA build (done — synthesises clean)

Both `pynq-z2-pair-all` (master) and `pynq-z2-pair-flip-all` (slave) bitstreams built with §9 RTL, total ~62 min. Output:
- `imp/fpga/output/pynq-z2-pair-all/tidelink.bit` (May 14 12:34)
- `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit` (May 14 13:01)

Both with positive WHS (timing met). No opt_design/impl errors. **However**, the §9 control signals are sim-only soft-strap regs with default values (slip=0, training_mode=0) — this bitstream behaves bit-exactly like the pre-§9 build on hardware. To actually exercise the §9 mechanism on the FPGA pair, the soft-strap regs need APB plumbing. That's the next gating step.

Side fix as part of this build: `fpga/filelist.tcl` was not exposing `CMSDK_FPGA_SRAM_V` as a Tcl variable for `[subst]` resolution against the flists. Now reads from `$env(CMSDK_FPGA_SRAM_V)` with a fallback to `${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v`.

### 1.7 Reorganisation (done — extraction-ready)

New directory layout designed for a future "wlink-phy-align" repo split:
- `cocotb/phy_align/` — alignment tests + checker module
- `deps/axi-chiplet-controller/logical/phy-align/` — README + PATCHES.md + the §9 diff against upstream

The in-place RTL edits in `WavD2DGpio*.v` are documented but not yet wrapped — that's a follow-up if/when the PHY moves to its own repo. See `deps/.../phy-align/README.md` for the extraction interface contract.

## 2. The remaining gaps, in order

### 2.1 GAP — APB plumbing for §9 control signals *(blocks all FPGA validation)*

The §9 soft-strap regs (`swi_bit_slip[23:0]`, `swi_training_mode`, plus new `swi_lane_locked[7:0]`, `swi_lane_fault[7:0]`, `swi_calibration_done`) must be reachable from PYNQ-host software via APB. Without this, the current FPGA bitstream is functionally identical to the broken pre-§9 build — we have no way to test §9 on real hardware.

**Scope:**
- Define APB offsets for the 5 new registers inside the Wlink PHY register block.
- Add register-bank logic in `Wlink.v` (or wherever `swi_phase_offset` lives — same address decode pattern).
- Plumb the regs from the Wlink instance up to the chiplet-controller APB region.
- Add the address-decode for the new registers in `tidelink_top.sv`.
- Update `src/rdl/tidelink_regs.rdl` with the new register definitions.

**Critical:** the existing cocotb tests must keep passing. They currently drive via hierarchical reference; if we replace the soft-strap regs with APB-driven ones, the hierarchical force may go away. Options: (a) keep the soft-strap regs alongside the new APB-driven ones (defaults flow through if APB never writes), or (b) update cocotb tests to drive via APB transactions. Recommendation: **(a) for now**, with a clean migration path; (b) for the long-term hardware-faithful version.

**Acceptance:** PYNQ-host script can read and write all 5 registers; values appear correctly in the RTL via APB; existing 9 cocotb regression tests still pass.

### 2.2 GAP — Autonomous calibration FSM *(plan §3.1.d, blocks reliable bring-up)*

A per-lane FSM that sweeps `swi_bit_slip[lane]` 0..7 until `lane_locked[lane]` asserts, then latches. Sketched in `BRINGUP_REPORT.md §9.6` but not yet implemented.

**Why it's gating:**
- The UVM bring-up failure (§1.4 above, §9.8 in report) is fundamentally about *when* training-mode is asserted. A SW-driven sequence in `deploy_pair.sh` can in principle work, but it's fragile (timing-sensitive across SSH-to-PYNQ → Linux mmap → APB write latency).
- In silicon (ASIC), there's no SW to drive the sweep; calibration must happen autonomously.
- An RTL FSM that fires on `role_lock` rising edge, runs the sweep over ~256 cycles, and signals `swi_calibration_done` is both production-correct and ASIC-portable.

**Scope:**
- ~80 LUT per-lane FSM (×8 = ~640 LUT) — sweep counter (3 bits) + dwell counter (5 bits, threshold 16+slack) + state register (2 bits). Or one shared FSM with 8 round-robin slots, same area.
- Inputs: `role_lock`, per-lane `lane_locked` from checker, `swreset` (re-trigger).
- Outputs: per-lane `swi_bit_slip` (mux'd with SW-writable APB value for debug override), `swi_calibration_done` (RO APB), per-lane `swi_lane_fault` (RO APB, sticky after sweep exhausts).
- Lives where? Two options:
  - **Inside the Wlink GPIO PHY** (`WavD2DGpio.v`). Pro: self-contained PHY component. Con: tightly couples to Wavious source — harder to upstream later.
  - **In a TideLink-level wrapper** between Wlink and the chiplet controller. Pro: SoC Labs-owned, doesn't modify Wavious internals. Con: extra level of hierarchy, slightly worse perf at the boundary.
  - **Recommended:** TideLink-level wrapper. Aligns with the plan-document recommendation and with the extraction-ready repo split.

**Bring-up sequencing requirement** (from §9.8 of report):
- Must run *between* `role_lock` rising edge and the cr_pkt handshake start.
- Specifically: hold off `swi_lltx_enable` until `swi_calibration_done` asserts.

**Acceptance:**
- Cocotb test `test_pair_autocal` runs end-to-end with no SW intervention; calibration finishes within 1000 cycles; FCSM advances to state=4.
- UVM test `test_align_uniform_skew` PASSes end-to-end (currently fails as documented in §1.4).

### 2.3 GAP — I²C-coordinated training-mode entry/exit *(plan §4, production sequencing)*

The §9.6 in-RTL FSM works for the symmetric case where both sides need the same sequencing. The §4 of the existing plan extends this with I²C coordination: master drives the protocol, polls peer status, can recover from peer-side faults with rich diagnostics.

**Scope:**
- Extend the existing autoneg FSM in `tidelink_autoneg` with `ST_TRAIN_*` states.
- Master writes peer's `SWI_TRAINING_MODE` over I²C, polls peer's `SWI_LANE_LOCKED`, drops peer's training mode.
- Add fallback handling: peer doesn't respond → timeout → fault report.
- BD changes: un-tie `mask_hs_bypass_i`; wire I²C SCL/SDA pads through to the top level.
- XDC changes: pin assignments for I²C, internal pull-ups.
- Physical: 2-jumper bridge between paired Pynq-Z2 boards (separate from the 40-pin ribbon).

**This is downstream of 2.1 and 2.2.** Can't be tested until APB regs exist (2.1) and the autonomous FSM works in sim (2.2). Defer.

### 2.4 GAP — Production deploy + diagnostic scripts

- `pynq_host/scripts/deploy_pair.sh`: pre-§9 sequence. Needs (a) wait for `swi_calibration_done` after `role_lock`, (b) read `swi_lane_locked` to confirm before checking FCSM, (c) dump `swi_lane_fault` if calibration fails.
- `pynq_host/scripts/wlink_probe.sh`: add reads for `swi_training_mode`, `swi_lane_locked`, `swi_lane_fault`, `swi_bit_slip[0..7]`, `swi_calibration_done`. These become the primary diagnostic surface.

### 2.5 GAP — `BRINGUP_REPORT.md` final update + memory note

Once the link comes up reliably on FPGA, the bring-up report needs:
- Update the §1 "current development phase" table to show all bring-up rows = Pass.
- Add an "as-built" section documenting the final design.
- A new memory note `project_tidelink_alignment_fix.md` capturing the design rationale.

### 2.6 OPTIONAL — Extract PHY into its own repo

Currently the §9 RTL lives as in-place edits to `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio*.v`. The extraction-ready structure exists (`deps/.../logical/phy-align/`) with documented patches. When a real trigger exists (another consumer of the PHY, a Wavious upgrade arriving, IP delivery), the in-place edits should be replaced by a wrapper module that lives in its own repo. ~1 day of work.

Don't do this preemptively. Wait for the trigger.

## 3. Recommended sequence

```
WEEK 1 (priorities 1 + 2: get FPGA working)
  Day 1-2  ─ Implement APB plumbing for §9 registers (2.1)
           ─ Validate via cocotb: tests use APB transactions (or via mixed
             APB + hierarchical-ref)
  Day 3-4  ─ Implement autonomous calibration FSM in TideLink wrapper (2.2)
           ─ Cocotb test_pair_autocal: end-to-end without SW intervention
           ─ Update existing UVM test_align_* to use the FSM (not hierarchical
             force), confirm UVM regression now PASSes end-to-end
  Day 5    ─ Update deploy_pair.sh + wlink_probe.sh for new regs (2.4 partial)
           ─ FPGA build with the new RTL (APB + FSM)
           ─ Deploy to pair-board, verify link comes up bidirectionally
             *** This is the BRINGUP_REPORT.md §2 "blocker" closure ***

WEEK 2 (priority 3: production sequencing via I²C)
  Day 1-2  ─ Extend autoneg FSM with ST_TRAIN_* states (2.3)
           ─ UVM I²C model + tests
  Day 3    ─ FPGA BD changes: un-tie mask_hs_bypass, wire I²C pads
           ─ XDC: pin assignment, pull-ups
  Day 4    ─ Solder/jumper I²C wiring between pair boards
           ─ FPGA build + deploy + verify autoneg-driven bring-up works
  Day 5    ─ Failure-mode tests (lane fault, peer non-response)

WEEK 3 (consolidation)
  Day 1-2  ─ Update BRINGUP_REPORT.md "as-built" section (2.5)
           ─ Write project_tidelink_alignment_fix.md memory note
  Day 3-4  ─ CI integration: regress cocotb + UVM in GitLab CI
  Day 5    ─ PR review, merge to feat/fpga-flow → main
```

## 4. Decisions needed up front

| # | Decision | Recommendation | Rationale |
|---|---|---|---|
| 1 | APB plumbing source-of-truth: SystemRDL or hand-written? | **SystemRDL** (already used for existing TideLink regs in `src/rdl/tidelink_regs.rdl`) | Consistent with existing patterns. PeakRDL-regblock can generate Verilog. |
| 2 | Cal FSM location: inside Wavious PHY vs TideLink wrapper? | **TideLink wrapper** | Keeps Wavious source diff-clean; easier to upstream the patch later as a separable module. |
| 3 | Cocotb tests: migrate to APB-driven now, or after Week 1? | **After Week 1** | Don't compound risk. APB plumbing + FSM is enough for Week 1. Hierarchical-ref tests remain valid as long as the soft-strap regs persist (option 2.1(a)). |
| 4 | I²C pin choice | Defer to Week 2 Day 3 | Need to inspect Pynq-Z2 RPi GPIO header and decide which 2 unused pins; not blocking earlier work. |
| 5 | When to extract the PHY into its own repo? | **Don't preemptively.** Wait for a concrete trigger (another consumer / Wavious upgrade / IP delivery). | Premature extraction increases coordination overhead with no payoff yet. |
| 6 | Training-mode re-entry trigger | **Any swreset** (matching existing FCSM swreset semantics) | Same trigger as the existing `WavD2DGpio.swi_swreset` path. SW can re-train without bitstream reload. |
| 7 | LOCK_THRESHOLD value | Keep at **16** | Already validated across 8 cocotb scenarios; no false locks observed. Bump up only if hardware shows bit errors. |
| 8 | Whether the production firmware drives bring-up or the in-RTL FSM does | **In-RTL FSM is primary; firmware reads `swi_calibration_done` to confirm** | Production silicon must work without firmware. Firmware path is for diagnostics and debug overrides only. |

## 5. Things we will NOT do (preserved from prior plan + new)

- Don't rewrite the GPIO PHY with `ISERDESE2`. Xilinx-specific, doesn't translate to ASIC.
- Don't change the Wlink wire protocol. Breaks the Wavious contract.
- Don't replace `swi_phase_offset` — it's still useful for sub-bit-cell margin; bit-slip and phase-offset compose.
- Don't drive calibration over the high-speed link itself (chicken-and-egg).
- Don't re-introduce the broken FCSM_6 RTL "fix" from `/tmp/WlinkGenericFCSM_6.v.brokenfix`.
- Don't merge `feat/fpga-flow` to `main` until §2.2 acceptance criteria are met (autocal converges in UVM end-to-end). The cocotb-only sandbox passing is not sufficient — UVM exposes the sequencing issue and is the gate.
- Don't extract the PHY repo preemptively. Wait for a real trigger.

## 6. Acceptance criteria for "the alignment work is done"

The blocker in `BRINGUP_REPORT.md` is closed when:

1. **FPGA pair-board test**: `deploy_pair.sh` runs to completion with no manual overrides; on both boards `swi_lane_locked == 0xff`, FCSM = state=4, `CURRENT_CREDITS` updates from peer (i.e. cr_pkt handshake completed), doorbell traffic from master ticks `DOORBELL_RESP_ACC` on slave.

2. **UVM regression**: `test_align_uniform_skew` and `test_align_asymmetric_skew` PASS end-to-end with no `force`/`uvm_hdl_deposit` calls bypassing the production bring-up sequence.

3. **Cocotb regression**: all current 14 `wlink_pair`/`phy_align` tests PASS at default `SKID_BITS=0`; the per-pattern tests PASS at their respective skids. New `test_pair_autocal` PASSes (autonomous bring-up).

4. **Fault injection**: forcing a single bad lane (one stuck bit) produces a clean diagnostic — `swi_lane_fault[bad_lane] == 1`, no infinite hangs, error reported up to SW.

5. **Documentation**: `BRINGUP_REPORT.md` is updated with the final design and the development-phase table shows all bring-up rows as Pass. A new memory note exists in `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/`.

## 7. References

- [`BRINGUP_REPORT.md`](../BRINGUP_REPORT.md) — full diagnosis, §6 root cause, §8 RTL options, §9 design, §9.8 sequencing finding
- [`~/.claude/plans/tidelink-bit-slip-i2c-coordination.md`](../../../.claude/plans/tidelink-bit-slip-i2c-coordination.md) — prior multi-week plan; this doc supersedes its "implementation order" section
- [`deps/axi-chiplet-controller/logical/phy-align/README.md`](../deps/axi-chiplet-controller/logical/phy-align/README.md) — future-repo extraction plan + interface contract
- [`deps/axi-chiplet-controller/logical/phy-align/PATCHES.md`](../deps/axi-chiplet-controller/logical/phy-align/PATCHES.md) — exact diff of in-place §9 RTL edits
- [`cocotb/phy_align/README.md`](../cocotb/phy_align/README.md) — sandbox usage
- [`uvm/tidelink_top_system/tests/README_align_tests.md`](../uvm/tidelink_top_system/tests/README_align_tests.md) — UVM alignment test usage

---

*Written 2026-05-14 ~13:05 BST, immediately after the §9 FPGA build completed clean and the UVM agent surfaced the sequencing finding. Captures the state-of-the-world before committing to APB plumbing + autonomous FSM as the next implementation steps.*

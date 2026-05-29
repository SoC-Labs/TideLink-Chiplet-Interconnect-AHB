# ASIC-Readiness Test Gap Analysis — TideLink GPIO PHY + Integrated TideLink

**Date:** 2026-05-28
**Author:** Independent assessment (post `feat/eye-visibility-v2` integration; HEAD `b9d1afc`)
**Target:** TSMC 65 nm, ~100 MHz GPIO PHY, v1 single-die chiplet tape-out
**Scope of design under review:** `deps/tidelink-gpio-phy/rtl/*` (new training subsystem)
plus `src/rtl/tidelink_top.sv`, `src/rtl/tidelink_phy_align_calibrator.sv`,
`deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` (integrated chiplet).

This document is an **independent** assessment of what additional verification
must land before the design is tape-out-grade. It reads the existing
`VERIFICATION_PLAN.md` and the project sign-off docs, then forms its own
view based on what TSMC 65 nm tape-out actually demands. Where the existing
plans are right, they are cited; where they are insufficient for tape-out,
that is called out explicitly.

**Headline verdict: NOT YET ASIC-READY.** Five tape-out blockers identified
(see [§8 Recommendation](#8-recommendation)). The new PHY training subsystem
has only paper unit tests (no RTL test directory exists on disk for it yet),
the calibrator's new `S_PROBE` state has zero coverage on the integrated
top, no DFT scan or MBIST flow exists, no UPF/low-power view exists, and
the ASIC SDC has the exact `set_clock_groups -asynchronous` defect that
`docs/ASIC_TIMING_CONSTRAINTS.md` declares "the single most important —
and historically most violated — point".

---

## 1. Current coverage snapshot

### 1.1 Test inventory by level

The repo's *as-built* test inventory. Counts are by directory, not by
`@cocotb.test` function, so the real test count is somewhat higher.

| Level | Location | Envs | Coverage focus |
|---|---|---|---|
| Unit (cocotb) | `cocotb/tidelink_apb_regs/`, `tidelink_fifo/`, `tidelink_fifo_ctrl` (in `formal`), `tidelink_returner/`, `tidelink_fc_adapter/`, `tidelink_addr_translator/`, `tidelink_phc_cdc/`, `tidelink_ptp_servo/`, `tidelink_mul_iter/`, `tidelink_popcount16` (none yet), `tidelink_clkfreq_check/`, `wav_d2d_gpio_tx/`, `wav_d2d_gpio_tx_prbs/`, `wavd2d_gpiorx_clkbuf/`, `wavd2d_gpiorx_t3a*/`, `tidelink_rxclk_buf/`, `tidelink_idelay_rx/`, `tidelink_lane_checker_prbs/` | 19 unit envs | Per-module datapath/FSM coverage, mostly pre-PHY-rewrite |
| Unit (xprop) | `xprop/tidelink/`, `tidelink_apb_regs/`, `tidelink_fifo/`, `tidelink_fifo_ctrl/`, `tidelink_returner/` | 5 envs (X-prop only) | `xprop.tcl` X-propagation checks; **no SVA/property-driven formal** |
| PHY align | `cocotb/phy_align/`, `cocotb/tidelink_phy_align_calibrator/`, `cocotb/tidelink_chiplet_pair_autocal/` | 3 envs, ~25 tests | Calibrator FSM, eye-centre, S_PROBE bias |
| Integration (cocotb) | `cocotb/tidelink_top/`, `tidelink_top_pair/`, `tidelink_top_pair_drift/`, `tidelink_top_pair_skewed/`, `tidelink_chiplet_pair_autocal/`, `wlink_pair/`, `phc_pair/`, `tidelink_perf*/`, `bank_asymmetry/`, `sim_robust/` | 10 envs | Bilateral link bring-up, calibrator probe dump, doorbell, autocal |
| System (UVM) | `uvm/tidelink_top_system/tests/*.sv` | 36 tests | Lane mask, align skew, autoneg, train_lane_fault, peer_mask, back-to-back, credit exhaustion, reset recovery |
| System (UVM) | `uvm/tidelink_system/tests/*.sv` | 15 tests | bidirectional, throughput/latency, max_packet, sideband_stress, error_recovery |
| System (UVM) | `uvm/tidelink_integration/`, `uvm/tidelink_ptp_chain/`, `uvm/tidelink_ptp_stress/`, `uvm/tidelink_fc_adapter/`, `uvm/tidelink/` | 5 envs | Integration handoffs, PTP servo soak |
| Lint | `cocotb/lint/` (sv_anti_pattern, xdc_lint, synth-mode self-tests), `lint/verilator/`, `lint/xcelium/` (HAL) | 3 flows | Verilator strict-lint, HAL, SV anti-pattern, XDC parse |
| CDC | `cdc/Makefile` → SpyGlass `tidelink_top.sgdc` + `axi_chiplet_controller.sgdc` + `xhb500.sgdc` + `waiver.swl` | 1 flow | Blackbox-mode SpyGlass run on `tidelink_top` only |
| Synthesis (FC) | `syn/asic/fusion-compiler/scripts/{1..7}_*.tcl` | 1 flow | Design Compiler + Fusion Compiler init→synth→cts→route→signoff→DRC |
| LEC | `syn/asic/formality/scripts/run_lec.tcl` (manual CI job `formality-lec`) | 1 flow | RTL↔gate equivalence with 2-pass skip strategy for Chisel auto-gen residuals |
| Static/STA | `syn/asic/primetime/scripts/extract_etm.tcl` | partial | Stub: ETM extract only — no full STA report-driven sign-off |
| DRC | `syn/asic/calibre/scripts/run_calibre_drc.sh`, `run_calibre_lvs.sh` | 1 each | DRC/LVS scripts present; no clean-run evidence in tree |
| FPGA HW | `pynq_host/scripts/*` (bringup, ILA, PTP test), `fpga/targets/pynq-z2-pair-*/` | runtime, manual | The real continuous truth-source — but not gating ASIC sign-off |

### 1.2 Coverage density per RTL block

A unit/integration matrix on every RTL file in the freeze tree. Cells:
- **U** = dedicated unit cocotb env exists with focused tests
- **I** = exercised by integration testbench (paired top, system UVM)
- **F** = formal (X-prop or SVA)
- **L** = lint-clean
- **—** = no coverage at this level

| RTL file | U | I | F | L | Comment |
|---|---|---|---|---|---|
| `deps/tidelink-gpio-phy/rtl/tidelink_popcount16.sv` | **—** | I (via lane_checker_prbs) | — | L | **NO standalone unit test directory exists.** `cocotb/tidelink_popcount16/` is not on disk. Spec demands "all 17 output values" (I12). |
| `deps/tidelink-gpio-phy/rtl/tidelink_lane_checker_single.sv` | **—** | I (via tidelink_top, tidelink_top_pair) | — | L | **NO dedicated cocotb/uvm env exists yet for the rewritten single-lane checker.** VERIFICATION_PLAN.md §1 lists U01-U18 as future work; none of them are committed RTL tests. |
| `deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv` | partial (prbs) | I | — | L | `cocotb/tidelink_lane_checker_prbs/` tests the old PRBS variant; new alternating-P/~P checker has no 8-lane env (I01-I12 in VERIFICATION_PLAN.md are paper). |
| `deps/tidelink-gpio-phy/rtl/tidelink_gpio_phy_apb_regs.sv` | **—** | I (via top APB sweep) | — | L | New register block; no dedicated cocotb env testing THIS file's CDC, read/write decode, packing functions, MODE selector. |
| `src/rtl/tidelink_phy_align_calibrator.sv` | U (`cocotb/tidelink_phy_align_calibrator/` 8 tests) | I (`phy_align/`, `tidelink_chiplet_pair_autocal/`) | — | L | S_PROBE state is the most recent change; `test_calibrator_probe_dump.py` exists but is a dump-only telemetry test, not an FSM-state-coverage test. **No assertion that S_PROBE → S_FINISH transition fires when `probe_all_locked` is true.** |
| `src/rtl/tidelink_top.sv` | U (`cocotb/tidelink_top/test_tidelink_top.py`) | I (top_pair*, chiplet_pair*) | — | L | Top-level wiring; no per-port toggle coverage; the new eye_outputs from `axi_chiplet_controller` are only probed by `eye-toolkit-web` `/pairs` + `/chassis` (HTTP, no RTL assertion). |
| `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` | — (blackbox in CDC, no cocotb) | I | — | L | 1734 LOC, **NO dedicated cocotb env**. Region-8 register decode, the eye-visibility port aggregation, and the new tl_calibration_cdc instance are only exercised via the integration tests. |
| `src/rtl/tidelink_returner.sv` | U | I | F (xprop) | L | OK coverage but no UVM scoreboard race test (see Shortcoming #5). |
| `src/rtl/tidelink_fifo*.sv` | U | I | F (xprop) | L | OK. Credit underflow (Shortcoming #1) NOT tested. |
| `src/rtl/tidelink_apb_regs.sv` | U | I | F (xprop) | L | OK. Reserved-bit reads, `pslverr` policy untested. |
| `src/rtl/tidelink_ptp.sv` + `tidelink_ptp_servo.sv` | U | I (ptp_pair, uvm/tidelink_ptp_*) | — | L | OK in sim; HW Phase-1 still red. |
| `src/rtl/tidelink_phc_cdc.sv` | U | I | — (waived SpyGlass) | L | Handshake provable by inspection; waived. |
| `src/rtl/tidelink_addr_translator.sv` | U (34 standalone tests) | **—** (Shortcoming #30) | — | L | Standalone strong; **never integration-tested** in `tidelink_top`. |
| `src/rtl/local_overrides/WavD2DGpio*.v` (Wlink overrides) | U (Tx/Rx separately) | I | — | L | The mid-word-mux bug history lives here. New `io_training_word[15:0]` port change has only the VERIFICATION_PLAN paper coverage. |
| `src/rtl/asic/tidelink_sram.sv` | **—** | I (via tidelink_fifo) | — | L | rf_16k macro wrapper. **NO MBIST** — see [§2.4 DFT](#24-dft). |
| `src/rtl/tidelink_perf*.sv` | U | I | — | L | Counters; no PrimePower-driven dynamic-power test |
| `src/rtl/tidelink_clkfreq_check.sv` | U | — (not yet instantiated in top) | — | L | Sign-off doc says "future-V2 instantiation". |

### 1.3 Assertion vs observation, by test

The most-cited integration test for the new PHY is `cocotb/tidelink_top_pair/`:

| Test | Asserts (machine-checked) | Observes (logs only) | Tape-out-grade? |
|---|---|---|---|
| `test_tidelink_pair_doorbell.py` | M→S, S→M doorbell delivery | Calibrator state, sweep coverage | Yes (one direction) |
| `test_calibrator_probe_dump.py` | None — telemetry dump | `(slip,phase)` per lane per dwell | **No — diagnostic only** |
| `test_eyemap_dump.py` | None — eye visualisation | Per-(slip,phase) lock map | **No — observability** |

Telemetry/dump tests are essential during bring-up but they do NOT count
toward functional sign-off because they make no machine-checkable claim.

---

## 2. Gaps against ASIC sign-off taxonomy

Every gap below has been cross-checked against `docs/SIGN_OFF_STATUS.md`,
`VERIFICATION_PLAN.md`, and `RTL_FREEZE_CHECKLIST.md`. Items called out
as `still open` or `future-V2` in those docs are listed here as gaps —
the project's own status tracker confirms them. New gaps not in those
trackers are flagged **NEW**.

### 2.1 Functional

| Gap | Severity | Notes |
|---|---|---|
| **NEW: New lane-checker rewrite has zero RTL unit tests on disk** | **CRITICAL** | `VERIFICATION_PLAN.md §1` lists 18 unit + 12 integration + 5 system tests for `tidelink_lane_checker_single.sv` / `tidelink_lane_checker.sv` / `tidelink_gpio_phy_apb_regs.sv`. **Zero of them exist as committed cocotb tests in the worktree** (no `cocotb/lane_checker_single/`, no `cocotb/lane_checker_8lane/`). The submodule's own `.github/workflows/ci.yml` runs lint only. |
| Calibrator FSM state-transition coverage | HIGH | Only `S_PROBE` probe-dump telemetry exists. The S_ARM→S_PROBE→{S_FINISH,S_SWEEP}, S_SWEEP→S_FINISH, S_FINISH→S_HOLD→S_DONE, S_DONE→S_CANCEL, S_HOLD→S_CANCEL transitions are not individually asserted. |
| Wiring-discriminator FSM transitions | HIGH | The 4-state UNKNOWN/OK/SWAPPED/DEAD FSM in `tidelink_lane_checker_single.sv:317-330` has no transition-coverage test. VERIFICATION_PLAN.md §2.3 documents the matrix as a target. |
| Credit underflow protection | HIGH | Shortcomings #1, #7, #31. No test deliberately under-runs. |
| Partial packet abandon | MEDIUM | Shortcoming #6, #32. |
| Returner retry on bus error | MEDIUM | Shortcoming #5. No test exercises the `master_error` end-to-end recovery path (Shortcoming #28). |
| PHC Phase-1 silicon | HIGH | Sign-off `CONDITIONAL` — slave-side HW_SYNC_STATUS stuck at 0x0; cocotb repro exists but no machine-checked silicon assertion. |
| Doorbell M→S vs S→M asymmetry | HIGH | The `project_autocal0_hw_workaround_2026_05_27` memory item shows the asymmetric M→S failure mode was only caught by `test_05_doorbell_master_to_slave`. We need both directions asserted as part of regression, not as a one-off bring-up test. |
| Configuration register lock | MEDIUM | Shortcoming #25 — no lock-bit test for `pair_base_addr`, `release_threshold`. |
| PTP multi-hop | MEDIUM | Shortcoming #34. Not in scope for v1 but called out as architectural untested. |

### 2.2 Coverage closure

| Coverage type | Status | What's missing |
|---|---|---|
| Line | **Not measured in CI** | No `-line` arg to VCS in `.gitlab-ci.yml`, no `coverage_merge` actually merging line coverage. The `coverage-merge` job exists but inputs are not produced by upstream jobs at line level. |
| Branch | **Not measured** | Same — no branch-coverage flag set. |
| Expression | **Not measured** | Same. |
| FSM | **Partial** | UVM has cov_hier.cfg in `uvm/tidelink/tb/`, `uvm/tidelink_fc_adapter/tb/` — but no coverage merge run published. |
| Toggle | **Not measured** | No `-cm tgl` in CI. |
| Functional | **Partial** | Covergroups exist in some UVM tests; no consolidated cov-closure report in `docs/`. |

`VERIFICATION_PLAN.md §3` specifies "100% line, 95% branch, 90% expression,
100% FSM transition, 90% toggle" as targets for the new lane checker
**but no flow exists to measure these**. This is a tape-out blocker:
TSMC65 sign-off requires a published coverage report with named
exclusions and justifications.

### 2.3 CDC

| Crossing | Status | Tape-out grade? |
|---|---|---|
| `swi_phase_offset_r` apb_clk → pad_clk_rx | Waived via `set_clock_groups -asynchronous` | OK for v1; SVA `no_phase_change_while_active` from CDC_AUDIT §2 **not yet added** |
| `cal_phase_offset_w` link_clk → pad_clk_rx | Not surfaced because `axi_chiplet_controller` blackboxed; **un-blackboxed SpyGlass run still outstanding** | NOT OK — must run full-RTL CDC at least once with MCP constraints |
| `tidelink_phc_cdc` handshake | Waived in `waiver.swl` (provable by inspection) | OK |
| Wlink internal hclk↔tx_link_clk, hclk↔rx_link_clk | Wlink-internal; recognised synchronisers | OK |
| **NEW: APB → link_rx_clk for `lock_thresh_o[23:0]`** in `tidelink_gpio_phy_apb_regs.sv:131-148` | 2-flop per-bit sync on a 24-bit quasi-static bus | **MARGINAL** — SpyGlass will flag as multi-bit reconvergence. Needs a `quasi_static` declaration in SGDC and/or an SVA bind to enforce no-change-while-locked. |
| **NEW: APB → link_rx_clk for `noise_mode_o[1:0]`** | 2-flop sync | OK if SGDC marks quasi_static |
| **NEW: APB → link_rx_clk clear pulse (toggle/XOR)** in `tidelink_gpio_phy_apb_regs.sv:153-173` | 3-FF toggle + XOR edge | OK pattern; needs SpyGlass to confirm recognition |
| **NEW: link_rx_clk → APB for noise/wire_status/canary readback** in `tidelink_gpio_phy_apb_regs.sv:179-211` | 2-flop per-bit on 5+5+5+5+5+5+2+1+1 = 34 bits × 8 lanes | **MARGINAL** — SpyGlass will flag the wide reconvergence. Must be declared as observability (data integrity not required). |

The new tidelink-gpio-phy `tidelink_gpio_phy_apb_regs.sv` introduces
**three new CDC paths** that the existing `cdc/tidelink_top.sgdc` does
not declare. A SpyGlass re-run with `axi_chiplet_controller` unboxed
**AND** the new submodule's APB regs visible is required for tape-out.

### 2.4 Reset

| Reset | Status |
|---|---|
| `poresetn` async PoR | OK; documented |
| `hresetn` AHB | OK |
| `apb_rst_n` | OK |
| `link_rx_rst_n` (= `~role_locked`) | NEW: feeds `tidelink_gpio_phy_apb_regs.sv:48,134-145` async-reset; no SVA that resetn deasserts cleanly when role_locked drops, leading to potential glitch on the synced threshold readout. Shortcoming #13 (reset bounce) hints at this class. |
| `phc_resetn` | OK |
| **Coordinated reset M↔S** | NOT tested — Shortcoming #27, #35 |
| Reset-domain crossings on the new clear_noise_pulse | **NOT exercised** | The toggle-sync on `clear_noise_pulse_o` crosses `apb_rst_n`→`link_rx_rst_n`. If they de-assert in different orders the pulse can be lost OR doubled. Need an explicit test. |
| **NEW: rst-then-glitch on link_rx_rst_n** | NOT tested | The link RX domain resets when role_locked drops — a brief loss of role_lock during recalibration must not cause the noise accumulators to corrupt or the canary to falsely fire. |

### 2.5 DFT

| Item | Status |
|---|---|
| Scan insertion | **NO FLOW** — `run_lec.tcl` pins `scan_mode`, `scan_shift`, `scan_asyncrst_ctrl`, `scan_in` to 0 in functional verification, but there is **no DFT script** that actually inserts scan chains. The TSMC65 ATPG flow (TestMAX/SpyGlass DFT/Tessent) is absent. |
| Scan coverage report | **NONE** | TSMC65 demands ≥99% stuck-at, ≥95% transition for sign-off. |
| MBIST for `rf_16k` SRAM | **NONE** — the SRAM wrapper in `src/rtl/asic/tidelink_sram.sv` instantiates the macro but there is no MBIST controller, no BIRA, no repair flow. TSMC65 rf_16k MBIST is provided as a separate macro and must be wired. |
| BIST register/results | **NONE** |
| JTAG / boundary scan | **NONE** in tree. The chiplet boundary has only APB; if the SoC integrator expects a boundary-scan TAP, it is not present. |
| Test compression | N/A | Single rf_16k macro is small enough that scan compression may not be needed for v1, but this must be a documented tape-out decision, not a silent omission. |

### 2.6 Low power / UPF

| Item | Status |
|---|---|
| UPF file | **NONE** — no `*.upf` in tree |
| Power domains | Implicitly one — no isolation/retention discussion in any doc |
| Clock gating | FC inserts CG cells (collapsed by `verification_clock_gate_hold_mode COLLAPSE_ALL_CG_CELLS` in `run_lec.tcl`) — but no architectural CG strategy document |
| Retention flops | **NONE** |
| Isolation cells | **NONE** |
| PrimePower analysis | **NONE** — `syn/asic/primetime/scripts/` has only ETM extract |

For a single-VDD v1 chiplet at 100 MHz, UPF is *desirable* but may not
be mandatory. **The decision must be documented**; currently it's silent.

### 2.7 Formal

| Item | Status |
|---|---|
| Equivalence (LEC) | Flow exists (`syn/asic/formality/scripts/run_lec.tcl`) with a 2-pass skip strategy for Chisel auto-gen Wlink residuals. CI job `formality-lec` is `when: manual` — never run on `b9d1afc`. |
| Assertion-based formal (SVA) | **NONE.** No `*.sva` files. No JG/Onespin/SymbiYosys flow. |
| Property files | **NONE** for any critical FSM: calibrator, lane-checker wire FSM, FCSM, autoneg. |
| X-prop | Partial: `xprop/*/xprop.tcl` for 5 modules. **Not on the new PHY RTL.** |
| Connectivity check | NONE |

Tape-out grade demands at minimum (a) a clean LEC run, (b) SVA on every
FSM (`tidelink_phy_align_calibrator.sv`, `tidelink_lane_checker_single`
wire FSM, autoneg FSM, FCSM, mask FSM), and (c) X-prop on the new PHY
modules.

### 2.8 Timing

| Item | Status |
|---|---|
| STA at SS / TT / FF, low/high V, hot/cold | NO REPORT in tree |
| Source-sync `pad_rx[*]` constraints | **BROKEN** per `docs/ASIC_TIMING_CONSTRAINTS.md §3` — current `syn/asic/fusion-compiler/inputs/constraints.sdc:48-53` puts `pad_clk_rx` in the blanket `set_clock_groups -asynchronous` list, which erases pad→capture analysis. This is the documented "single most important — and historically most violated — point". |
| Forwarded TX clock (`pad_clk_tx`) | **MISSING** — `constraints.sdc:69-70` comments "tools will infer it … No create_clock here" — the very wording that the timing doc says is wrong for sign-off. |
| `set_max_delay -datapath_only`, `set_bus_skew`/`set_data_check` on lane bundle | **MISSING** in ASIC SDC |
| Per-lane programmable delay cell (ASIC IDELAY analogue) | **MISSING** — flagged as Part A §4.3 sign-off gate, no IP instantiated |
| False paths / multi-cycle paths | Some via `set_clock_groups`; Finding #2 MCP (link_clk→pad_clk_rx) NOT added for un-blackboxed SDC |
| Hold sign-off at fast corner | NO REPORT |

This is the **most acute** tape-out gap on the design today. The
constraint file is in the state the timing doc explicitly calls out as
"the FPGA bring-up was through 2026-05 — gambling".

### 2.9 X-propagation

| Module | X-prop test |
|---|---|
| `tidelink/`, `tidelink_apb_regs/`, `tidelink_fifo/`, `tidelink_fifo_ctrl/`, `tidelink_returner/` | YES (`xprop/*/xprop.tcl`) |
| **`tidelink_lane_checker_single`** | **NO** — newest, async-reset, gated FFs — exactly the class X-prop catches |
| **`tidelink_phy_align_calibrator`** | **NO** — 8-state FSM with default cases |
| **`tidelink_gpio_phy_apb_regs`** | **NO** — has `unique case` (paddr decode) and `default` (mode select) |
| `tidelink_phc_cdc` | NO — async-reset handshake; should be on the list |

### 2.10 Protocol compliance

| Protocol | Compliance test status |
|---|---|
| AHB-Lite (XHB500-side) | Functionally exercised via UVM `tidelink_top_system`; no AMBA-protocol BFM (e.g. Synopsys VC VIP `svt_ahb_*`) running compliance scripts |
| APB3 | Same — no `svt_apb_*` VIP run |
| AXI4 (Wlink axiarFC / axiawFC etc.) | Inside Wlink, Chisel-generated; protocol-checked by Wlink's own test suite (not part of this repo) |
| Wlink FCSM | Tested in `cocotb/wlink_pair/` (~18 tests); no formal property file |
| I2C autoneg | Tested in cocotb; HW-validated; no formal property file |

Tape-out grade demands at minimum a VC-VIP AHB/APB protocol-compliance
run on `tidelink_top`'s boundary interfaces. The `VIP_HOME` is already
in the CI variables (`.gitlab-ci.yml:74`) so the licenses exist — no
compliance test job is wired in.

### 2.11 PHY-specific

| Item | Status |
|---|---|
| Pattern selection regression | YES — `scripts/run_search.sh` in the submodule regenerates `results/` byte-identically. Good. |
| Eye width measurement under jitter | NO — only the static `(slip, phase)` sweep exists |
| Voter resilience ≥4 bit errors per word | NO test — VERIFICATION_PLAN.md U05 only injects 1 bit; spec §3.2 claims "T-bit-flips per word survive, T=3 by default" — that boundary is not exercised |
| Canary fail propagation | NO — U16 in VERIFICATION_PLAN.md is paper |
| Wiring discriminator fail propagation | NO — U09 is paper; spec §4.3 covers all four states but no test |
| Threshold sweep 0..7 | NO — U02 is paper; cocotb `apb_regs` does not cover this |
| Noise accumulator overflow / saturation | NO — `noise_acc` saturates at 15 bits = 1024 × 16; needs a forced-saturation test |
| APB CDC stress (back-to-back writes during clock-rate corners) | NO — Shortcoming #29 |
| BER measurement | **NO BER SPEC** — the design has no documented BER target on the GPIO pad. Without one, no PHY validation is closeable. |

---

## 3. Specific new tests required

The new tests proposed below are *additions to* the VERIFICATION_PLAN.md
test list, focused on closing the ASIC tape-out gates rather than the
nominal feature coverage. Each gives a one-line stimulus + one-line
assertion + an effort and an impact rank.

### 3.1 CRITICAL — would catch a tape-out-blocker silicon bug

| ID | Name | Level | What | Stimulus | Assertion | LOC | Hours | Rank |
|---|---|---|---|---|---|---|---|---|
| C01 | `cocotb/lane_checker_single/*` — actually build it | Unit | The 18 tests in VERIFICATION_PLAN.md §1 (U01-U18) | Per VERIFICATION_PLAN.md | Per VERIFICATION_PLAN.md | 1500 | 40 | **CRITICAL** |
| C02 | `cocotb/lane_checker_8lane/*` — actually build it | Integration | The 12 tests in VERIFICATION_PLAN.md §1 (I01-I12) | Per VERIFICATION_PLAN.md | Per VERIFICATION_PLAN.md | 1200 | 32 | **CRITICAL** |
| C03 | `cocotb/gpio_phy_apb_regs/` — apb-driven CDC + decode | Unit | Build it from scratch | APB writes to all 8 register offsets, including reserved-bit ignores; toggle clear-pulse 1000× back-to-back | 32-bit read-back matches written threshold; clear pulse arrives in link_rx_clk domain once per write; readback returns zero for RO reg writes; reserved bits read as 0 | 600 | 16 | **CRITICAL** |
| C04 | `xprop/lane_checker_single/properties.sva` + JasperGold/SymbiYosys | Formal | Wire-FSM transition cover + lock-detector liveness | `assume` quiescent inputs; `cover` each of the 7 documented wire-FSM transitions; `assert` lock cannot drop with `dist_match ≤ thresh` and counter ≥ LOCK_CONSEC | 250 | 24 | **CRITICAL** |
| C05 | Spyglass re-run with `axi_chiplet_controller` UNboxed + new gpio_phy regs | CDC | Add SGDC for new APB regs (quasi-static thresh + noise_mode, observability sync for noise readback) | Run `make -C cdc cdc MODULE=tidelink_top NO_BLACKBOX=1` | Zero new CDC errors above the already-waived set; new APB regs recognised as quasi_static; toggle-sync recognised | 80 | 12 | **CRITICAL** |
| C06 | ASIC SDC fix-up + STA at TT/SS/FF | Timing | Repair `constraints.sdc` per `ASIC_TIMING_CONSTRAINTS.md` Part B (sections 1-7); add SS/FF corners and run `report_timing_summary` | After each repair item, `report_timing -from [get_ports pad_rx[*]] -to [get_clocks pad_clk_rx]` returns real paths; WHS ≥ 0; hold endpoint count ~ baseline | (SDC only) | 40 | **CRITICAL** |
| C07 | `cocotb/tidelink_top_pair/test_calibrator_sprobe_fsm.py` | Integration | Assertion-grade S_PROBE | Force `probe_all_locked = 1` (clean bilateral channel) at calibrator entry; force a single-lane fault and assert `S_PROBE→S_SWEEP` | Coverage of both transitions in a single run; per-lane `lane_done` correctly latched at (0,0) for the no-fault lanes; lane_done remains 0 for the faulted lane until S_SWEEP completes | 250 | 8 | **CRITICAL** |
| C08 | `formality-lec` on `b9d1afc` HEAD | LEC | Trigger the manual CI job, archive MANIFEST + report | Run pipeline | `FM_LEC_OK` for `tidelink_top_full` AND `tidelink_top` partition; zero failing/aborted points after the documented 2-pass skip | 0 (config only) | 8 | **CRITICAL** |

### 3.2 HIGH — would catch likely-silicon bugs, may not block tape-out alone

| ID | Name | Level | What | Stimulus | Assertion | LOC | Hours | Rank |
|---|---|---|---|---|---|---|---|---|
| H01 | `cocotb/tidelink_top_pair/test_threshold_relax_live.py` | System | Threshold relaxation during live link | Force one lane's `dist_voted` to 4 (above default 3) via cocotb backdoor on the link data; via APB raise that lane's threshold to 5; check lock survives | `lane_locked[i]` deasserts at default thresh, re-asserts at relaxed | 300 | 8 | HIGH |
| H02 | `cocotb/tidelink_top_pair/test_wire_discrim_swap.py` | System | Wire discriminator on a full top | Swap a lane-data input physically in the testbench between TX and RX; assert WIRE_SWAPPED + WIRE_OK matrix | `wire_status_o[lane_a] == WIRE_SWAPPED && wire_status_o[lane_b] == WIRE_SWAPPED` within one training window | 250 | 8 | HIGH |
| H03 | `cocotb/tidelink_top_pair/test_canary_reverse.py` | System | Bit-order canary fires on inverted serializer | Force `WavD2DGpioTx` to bit-reverse its data; expect canary fail across all 8 lanes within 1024 voted words | All `canary_pass[i] = 0` after `canary_valid[i] = 1` | 200 | 6 | HIGH |
| H04 | `xprop/tidelink_phy_align_calibrator/properties.sva` | Formal | Calibrator FSM SVA — all 8 state transitions + S_PROBE→S_FINISH liveness | JasperGold property bench with constrained inputs | All transitions cover; `S_ARM → ... → S_DONE` reachable in ≤ DWELL_CYCLES × (8 × 16 + 1) cycles | 300 | 20 | HIGH |
| H05 | `xprop/tidelink_lane_checker_single/properties.sva` | Formal | Lock-detector hysteresis, vote_enable contract | `assert (vote_enable && rst_n) |-> (training_mode_w_i && !sweep_active_i && locked_pre)` ; `cover` each of 7 wire-FSM transitions; X-prop on every output | All assertions hold; cover items hit | 200 | 12 | HIGH |
| H06 | `cocotb/tidelink_phy_align_calibrator/test_dwell_min_dist_continuous.py` | Unit | Per-spec §7.1: continuous scoring beats binary | Drive a sequence with single bit-flips at random phases; verify `dwell_min_dist` produces a tighter `best_phase` selection than the old `lane_locked` count would have | New best phase is within ±1 of the noise-free optimum | 300 | 8 | HIGH |
| H07 | `cocotb/tidelink_top_pair/test_credit_underflow.py` | System | Shortcoming #1, #7, #31 | Write a packet larger than `credit_count`; software writes past `pair_credit_counter`; expect saturate or error flag | Counter does not wrap; `overrun` flag asserts; subsequent traffic recovers | 250 | 6 | HIGH |
| H08 | `cocotb/tidelink_top_pair/test_doorbell_bidi_asymmetry.py` | System | M→S and S→M doorbell as part of CI | M→S, then S→M, then M+S simultaneous | Both directions deliver one doorbell; no double-fire; no drop | 200 | 6 | HIGH |
| H09 | `cocotb/tidelink_top_pair/test_apb_cdc_stress.py` | System | Back-to-back APB writes during heavy traffic | 1000 threshold writes interleaved with 1000 noise-mode toggles while link is locked | No lane drops; every threshold-write is visible in `lock_thresh_sync2` within 4 link_rx_clk; clear pulse is exactly one per write | 250 | 6 | HIGH |
| H10 | `uvm/tidelink_top_system/tests/test_top_addr_translate.sv` — extend to integration | System (UVM) | Shortcoming #30 | Address translator full sweep with traffic through Wlink | Translated addresses arrive at AHB manager unchanged from reference Python model | 200 | 8 | HIGH |
| H11 | DFT scan-insertion + ATPG coverage | DFT | TestMAX or Tessent flow | Synth + insert scan; run ATPG; report stuck-at + transition coverage | ≥ 99% stuck-at, ≥ 95% transition | (script) | 60 | HIGH |
| H12 | MBIST controller for rf_16k | DFT | Wire TSMC65 MBIST controller into `tidelink_sram.sv` parent | Run BIST in BIST mode | All cells pass; BIST status register reads PASS in APB | (RTL + script) | 40 | HIGH |
| H13 | UPF decision doc + (if domain split) UPF file | LP | Tape-out gate doc | n/a | UPF passes ConCurrent verification; UPF-CPF checks clean if applied | (config) | 16 | HIGH |
| H14 | Reset-domain glitch test on `link_rx_rst_n` | System | role_locked drop/regain | Force role_locked low for 1 link_rx_clk during traffic; verify accumulators reset and canary re-arms | No spurious `canary_pass=0` post-recovery; no stuck DEAD state | 200 | 4 | HIGH |

### 3.3 MEDIUM — coverage closure + ASIC sign-off bookkeeping

| ID | Name | Level | What | LOC | Hours | Rank |
|---|---|---|---|---|---|---|
| M01 | Code coverage flow enabled in CI | Process | Add `-line -cond -fsm -tgl` to VCS in cocotb-regression + uvm-* jobs; wire `coverage-merge` to consume them; gate `pages` job on coverage thresholds | (CI config) | 16 | MEDIUM |
| M02 | `cocotb/tidelink_popcount16/test_exhaustive.py` | Unit | I12 from VERIFICATION_PLAN.md | 100 | 2 | MEDIUM |
| M03 | `xprop/tidelink_lane_checker_single/xprop.tcl` + `xprop/tidelink_phy_align_calibrator/xprop.tcl` + `xprop/tidelink_gpio_phy_apb_regs/xprop.tcl` | Formal | X-prop on each new module | 50 each | 8 | MEDIUM |
| M04 | VC-VIP AHB protocol compliance on `tidelink_top` boundary | Compliance | Wire `svt_ahb_*` into uvm/tidelink_top_system | (config) | 24 | MEDIUM |
| M05 | VC-VIP APB compliance on `apb_intf` | Compliance | Wire `svt_apb_*` into apb regs env | (config) | 16 | MEDIUM |
| M06 | `uvm/tidelink_system/tests/test_partial_packet_recovery.sv` | System (UVM) | Shortcoming #32 | 200 | 6 | MEDIUM |
| M07 | `uvm/tidelink_top_system/tests/test_coordinated_reset.sv` (already on the list — extend to bilateral) | System (UVM) | Shortcoming #35 | 250 | 8 | MEDIUM |
| M08 | `uvm/tidelink_ptp_chain/` multi-hop run | System (UVM) | Shortcoming #34 | 300 | 12 | MEDIUM |
| M09 | PrimePower dynamic & leakage analysis | LP | Wire PrimePower in CI; run on FC outputs | (config) | 16 | MEDIUM |
| M10 | Calibre DRC + LVS clean-run evidence | DRC/LVS | Run the scripts already in tree; archive reports | (config) | 24 | MEDIUM |
| M11 | UVM `cov_hier.cfg` extended to new PHY + actual coverage merge | Coverage | Add coverage groups for thresh × dist_voted | 200 | 8 | MEDIUM |
| M12 | Eye toolkit HTTP-to-RTL handover assertion | Integration | Cocotb test exercising `eye-toolkit-web` `/pairs` `/chassis` endpoints against `axi_chiplet_controller` aggregated outputs | 200 | 8 | MEDIUM |

### 3.4 LOW — nice-to-have / post-silicon

| ID | Name | Notes |
|---|---|---|
| L01 | Throughput / latency characterisation (Shortcoming #33) | Useful for tape-out documentation, not blocking |
| L02 | PHC frequency-ratio sweep (Shortcoming #29) | Likely catches no silicon bug at v1 frequencies |
| L03 | Boundary scan TAP | Only if SoC integrator requires it |
| L04 | Fault injection / SEU robustness | Post-silicon validation |
| L05 | Eye width under jitter (PHY) | Useful but needs channel model first |

---

## 4. PHY-specific additions

The new training pattern + matcher + voter + canary + wiring
discriminator is the most-changed area and therefore deserves the
deepest focused attention. The tests above are organised by sign-off
category; here is the PHY-specific subset, rationalised against the
caller's list.

| Caller item | Coverage in proposed tests | Status |
|---|---|---|
| Pattern selection regression (via `run_search.sh`) | Submodule already has this; CI wires it up via `lint-standalone` | **PRESENT** |
| Eye width under jitter | NOT in current proposal; needs a channel/jitter model | **GAP** — out of scope for v1; recommend deferring to post-silicon characterisation, but **document the deferral** |
| Voter resilience to ≥4 bit errors | C01 (U05 from VERIFICATION_PLAN.md) covers 1-bit; we extend to a `test_vote_4bit_errors.py` to verify the voted-distance stays consistent with the matcher threshold semantics | Add as **U05b** in C01 batch |
| Canary fail propagation (bit-reverse input) | H03 | **CRITICAL** to land before tape-out; the canary is the only sentinel against TX-serializer wiring errors and the tests do not currently exercise it |
| Wiring discriminator fail propagation (all 4 states) | C02 covers I03/I04 + add `test_apb_wiring_status_dead_recovery.py` | **HIGH** |
| Threshold sweep 0..7 | C01 (U02) + C03 (APB-driven) + H01 (live link) | Add cross-product coverage in C02 (`test_independent_thresh.py`) |
| Noise accumulator overflow / saturation | Add `test_noise_acc_saturate.py` — run 2048 windows, verify `noise_sat` asserts at sample-count 1023→1024 boundary | New test, **MEDIUM** |
| APB CDC stress | H09 | **HIGH** |
| BER target | **NOT IN DESIGN DOCS.** Recommendation: define a per-lane BER target (e.g. `BER ≤ 1e-9` at nominal corner over 1 hour soak) before tape-out and add a corresponding HW soak test to `pynq_host/scripts/` and an ASIC-flow gate that requires the spec to be in the integration guide. |

---

## 5. Integrated tidelink (chiplet-level) additions

What does the integrated design need that the PHY alone doesn't cover?

| Item | Coverage today | Proposed |
|---|---|---|
| FCSM integration — credit handshake corners | `cocotb/wlink_pair/` ~18 tests + UVM `test_credit_exhaustion`, `test_pair_credit_underflow` | Add **H07 credit-underflow on integrated top** explicitly; UVM tests do not yet drive end-to-end recovery |
| Doorbell M→S and S→M | Per-test `test_tidelink_pair_doorbell.py` | Add **H08** bidi + simultaneous |
| PHC sync under temperature corner | Sim-only; Phase-1 silicon still red | Out of scope for ASIC-flow testing; but the LEC and STA must include `phc_clk` in the SS/FF corners |
| Address translator full sweep | 34 standalone cocotb; ZERO integration | **H10** integration-context test |
| I2C autoneg interaction with new training | `cocotb/tidelink_autoneg/` exists; new training has no interaction test | Add `test_autoneg_then_training.py` in the new lane-checker 8-lane env asserting: autoneg completes → training begins → first-lock fires within X cycles |
| Eye toolkit GUI handover (per INTEGRATION_GUIDE.md §6.2) | HTTP probe only (HEAD `b9d1afc`) | **M12** machine-checked assertion against `axi_chiplet_controller` eye_output ports |
| Doorbell + AHB write race | Not tested | Add a UVM stress that fires a doorbell at the same time as an AHB read of the noise registers; verify no APB readback corruption (asserts on the 2-FF CDC chain) |

---

## 6. ASIC-flow integration tests

Tests that run as part of the ASIC flow (gate-level + sign-off):

| Item | Status | Required action |
|---|---|---|
| Conformal/Formality LEC golden RTL vs gate | Flow exists (`formality-lec` job, manual) | **Run on b9d1afc and archive.** This is item 3 of `SIGN_OFF_STATUS.md`. |
| Spyglass CDC clean run on post-integration tree | Last run `dbf17d7`; new submodule integration NOT yet re-run | Re-run with new APB regs visible (`NO_BLACKBOX=1` mode) |
| PrimeTime STA report with no violations | NO REPORT in tree | New gate; flow stub exists in `syn/asic/primetime/scripts/extract_etm.tcl` — needs `report_timing` driver |
| DFT scan coverage | NO FLOW | New flow needed |
| BIST coverage | NO FLOW | New flow needed |
| Calibre DRC | Scripts exist (`run_calibre_drc.sh`); no run evidence | Run + archive |
| Calibre LVS | Scripts exist; no run evidence | Run + archive |
| Coverage merge + report | `coverage-merge` job exists but is downstream of jobs that don't produce coverage | Wire the upstream `-cm` flags and gate the `pages` artifact |

---

## 7. Effort estimate

### 7.1 Rolled-up effort by rank

| Rank | LOC (test code) | Hours (engineer) | Critical path |
|---|---|---|---|
| CRITICAL (C01-C08) | ~3,950 + flow config | ~180 | C01+C02 (paper-to-RTL conversion) is the long pole — 72 h. Calibrator FSM SVA (C04) is another 24 h. SDC + STA repair (C06) is 40 h but needs an ASIC engineer + tool licences. |
| HIGH (H01-H14) | ~3,150 | ~112 | DFT scan flow (H11) and MBIST (H12) are bring-up-grade tasks (60 + 40 h). |
| MEDIUM (M01-M12) | ~2,000 + flow config | ~168 | Most can run in parallel once tools are licensed. |
| LOW (L01-L05) | — | TBD | Post-silicon |
| **Total tape-out grade** | **~9,100** | **~460 engineer-hours (~3 person-months)** | C01+C02+C03+C04+C05+C06+C07+C08 = 152 h critical path |

### 7.2 Dependencies / critical path

1. **C01+C02** (cocotb tests for new lane checker) is the most independent
   and longest single task. Can start immediately. No tool dependency.
2. **C04+C05+H04+H05** (formal/SVA + SpyGlass full re-run) needs JG / SymbiYosys
   and SpyGlass licences. Licences already in CI vars.
3. **C06** (SDC repair) blocks **C08** (LEC) because LEC consumes FC outputs
   that change when SDC changes.
4. **H11+H12** (DFT + MBIST) need TSMC65 ATPG flow setup. Probably a separate
   ASIC engineer for ~1 week.
5. **C07+H01-H03** (integrated PHY tests) depends on C01+C02 patterns
   established.

### 7.3 What the project plan calls "future-V2" but is actually tape-out-gating

From `SIGN_OFF_STATUS.md`:

- "Calibrator `MAX_RESWEEPS` freeze decision" — must be locked before tape-out.
- "`clkfreq_check` instantiation + APB build-ID" — recommend deferring (not blocking).
- "CDC structural fix on `feat/cdc-fix-wip`" — agree it's not blocking IF the
  `set_clock_groups -asynchronous` is the chosen waiver AND C05 confirms no real
  violations on the un-blackboxed tree.

---

## 8. Recommendation

### 8.1 Top 5 CRITICAL gaps to close BEFORE tape-out

| # | Gap | Test ID | Effort | Why |
|---|---|---|---|---|
| 1 | **No RTL test for the new lane checker** | C01 + C02 + C03 | 88 h | The submodule has 1,500+ LOC of new RTL with zero committed cocotb tests. The paper plan exists; it must be code. |
| 2 | **ASIC SDC source-sync defect** | C06 | 40 h | `constraints.sdc:48-53` is precisely the failure mode `ASIC_TIMING_CONSTRAINTS.md` declares "the single most important and historically most violated point". Tape-out with this SDC = bench-only silicon. |
| 3 | **No DFT scan flow** | H11 + H12 | 100 h | TSMC65 requires ≥99% stuck-at coverage and MBIST for compiled memories. Neither exists. |
| 4 | **LEC never run on integrated tree** | C08 (depends on C06) | 8 h | Sign-off gate ASIC `CONDITIONAL`; depends on a passing LEC report. |
| 5 | **Full-RTL SpyGlass CDC not run with new APB regs** | C05 | 12 h | New `tidelink_gpio_phy_apb_regs.sv` adds 3 new CDC paths; the last SpyGlass run blackboxed `axi_chiplet_controller`. |

Total CRITICAL: **248 engineer-hours (≈ 6 weeks single-engineer / 3 weeks two-engineer).**

### 8.2 Top 5 HIGH follow-ups (concurrent with CRITICAL)

| # | Gap | Test ID | Effort |
|---|---|---|---|
| 1 | Calibrator FSM formal | C04 + H04 | 44 h |
| 2 | Lane-checker FSM formal | H05 | 12 h |
| 3 | Doorbell M→S + S→M as regression | H08 | 6 h |
| 4 | Threshold relax under live link | H01 | 8 h |
| 5 | Wire-discriminator + canary live tests | H02 + H03 | 14 h |

### 8.3 What can be deferred to post-silicon

- L01 throughput characterisation (use silicon)
- L02 PHC frequency ratio sweeps (Shortcoming #29; silicon is faster)
- L05 PHY eye width under jitter — needs real channel data
- M07 PTP multi-hop (Shortcoming #34) — not a v1 use case
- M06 partial packet recovery — silicon validation acceptable

### 8.4 Things the existing planning docs got right

- `VERIFICATION_PLAN.md` test list U01-U18 / I01-I12 / S01-S05 is
  well-scoped and ready to code. The plan is fine; the implementation is missing.
- `CDC_AUDIT_REPORT.md §9` correctly identifies that the `set_clock_groups
  -asynchronous` is acceptable for v1 if a `set_multicycle_path` is added
  for the unboxed flow.
- `ASIC_TIMING_CONSTRAINTS.md` Part B §9 sign-off checklist is exactly
  what we need — it's just not satisfied yet.
- `RTL_FREEZE_CHECKLIST.md` Section C jobs 1-13 capture the freeze gates
  honestly.

### 8.5 Things the existing planning docs got wrong or under-stated

- `VERIFICATION_PLAN.md` says "code coverage 100% line, 95% branch" but
  **no coverage flow exists in CI**. This is a process gap, not a
  measurement gap.
- `SIGN_OFF_STATUS.md` lists "GO (CONDITIONAL)" for RTL/CDC but the
  un-blackboxed CDC run with the new submodule regs has not been done.
  Verdict should be downgraded to `CONDITIONAL — re-run required`.
- The submodule's `VERIFICATION_PLAN.md` does not call out the absent
  cocotb directories — it treats them as TODO without flagging that
  zero tests exist on disk today.
- DFT and UPF are entirely absent from every sign-off doc; these are
  silent tape-out blockers.
- BER spec absent — a PHY without a BER number cannot be characterised.

---

## 9. Quick reference

### 9.1 Files this assessment recommends creating (test code only)

```
cocotb/lane_checker_single/                  # 18 tests, ~1500 LOC
cocotb/lane_checker_8lane/                   # 12 tests, ~1200 LOC
cocotb/gpio_phy_apb_regs/                    # 8 tests,  ~600 LOC
cocotb/tidelink_popcount16/                  # 1 test,   ~100 LOC
cocotb/tidelink_top_pair/test_threshold_relax_live.py
cocotb/tidelink_top_pair/test_wire_discrim_swap.py
cocotb/tidelink_top_pair/test_canary_reverse.py
cocotb/tidelink_top_pair/test_calibrator_sprobe_fsm.py
cocotb/tidelink_top_pair/test_credit_underflow.py
cocotb/tidelink_top_pair/test_doorbell_bidi_asymmetry.py
cocotb/tidelink_top_pair/test_apb_cdc_stress.py
cocotb/tidelink_phy_align_calibrator/test_dwell_min_dist_continuous.py
xprop/tidelink_lane_checker_single/        # xprop + SVA
xprop/tidelink_phy_align_calibrator/       # xprop + SVA
xprop/tidelink_gpio_phy_apb_regs/          # xprop
uvm/tidelink_system/tests/test_partial_packet_recovery.sv
uvm/tidelink_top_system/tests/test_coordinated_reset_bilateral.sv
```

### 9.2 Files this assessment recommends UPDATING (config / flow only — not RTL)

```
.gitlab-ci.yml                                # add -cm line/branch/expr/fsm/tgl
cdc/tidelink_top.sgdc                          # SGDC additions per CDC_AUDIT §3.1
cdc/waiver.swl                                 # waiver additions per CDC_AUDIT §3.2
syn/asic/fusion-compiler/inputs/constraints.sdc # repair per ASIC_TIMING §B
syn/asic/primetime/scripts/                    # add full STA driver
syn/asic/calibre/scripts/                      # run + archive
docs/SIGN_OFF_STATUS.md                        # downgrade CDC, add DFT/UPF rows
```

### 9.3 ASIC-readiness verdict

**NOT YET TAPE-OUT-READY.** The critical-path effort is ~6 engineer-weeks
(single engineer) to close C01-C08. After that, the design is plausibly
tape-out-grade for the new GPIO PHY training subsystem and integrated
chiplet, with the residual HIGH-rank items addressable in parallel by
a second engineer. Without C01-C08 done, tape-out exposes the project
to:

1. Untested matcher / voter / canary / wire-discriminator silicon — likely
   to show subtle bring-up bugs that the FPGA cannot reveal (e.g. SS-corner
   slack on the popcount tree, X-prop on reset of the noise accumulators).
2. Unconstrained `pad_rx[*]→capture` paths → coin-flip lane lock per
   silicon unit (the FPGA-equivalent failure was the entire 2026-05
   bring-up).
3. No scan / MBIST → silicon yield testing impossible, parts cannot be
   binned, returns cannot be diagnosed.
4. No LEC report → no machine-checked confirmation that the netlist
   matches the RTL.
5. No full-RTL CDC report → silent metastability risk on the new APB CDC.

The good news: every gap above is fixable with the people, tools, and
licences already in the project. None require new silicon prototypes or
new IP procurement.

---

## Document version

| Field | Value |
|---|---|
| Date | 2026-05-28 |
| Worktree | `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ` |
| Parent HEAD | `b9d1afc` |
| Submodule `tidelink-gpio-phy` | (latest committed) |
| Submodule `axi-chiplet-controller` | `feat/td-gpio-phy-integration` (post 68d625d) |
| Author | Independent assessment, opinionated where the sign-off docs are silent |

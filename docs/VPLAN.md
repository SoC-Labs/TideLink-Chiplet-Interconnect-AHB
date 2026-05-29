# TideLink Verification Plan

> Single canonical verification plan for **simulation coverage** of the TideLink
> chiplet-interconnect subsystem. For hardware bring-up testing on the PYNQ-Z2
> pair see [HW_TEST_SUITE.md](HW_TEST_SUITE.md). The earlier
> [PTP_HW_TEST_PLAN.md](archive/PTP_HW_TEST_PLAN.md) is archived (its plan was
> superseded by the PHC integration work in `~/SoCLabs/ptp-hardware-clock-ahb`).
>
> **Status:** Re-baselined 2026-05-29 against the live filesystem
> (`src/rtl/`, `src/rtl/fifo/`, `cocotb/`, `cocotb/debug/`, `uvm/`, `xprop/`).
> Numbers and module-to-env mappings reflect the tree as of that date and
> should be re-verified before any sign-off use.

---

## 1. Scope and architecture

TideLink is a chiplet-interconnect application-layer subsystem
(`src/rtl/tidelink_top.sv`) that bridges an AMBA AHB SoC fabric to a
die-to-die serial link. It provides **two independently flow-controlled
paths** sharing a single PHY:

1. **Transparent AHB bridging** via XHB500 (AHB↔AXI) + the AXI chiplet
   controller (Wlink) + a CAM-based APB-programmed address translator.
2. **Mailbox-style packet transfer** via a dedicated Wlink FC node, a
   credit-managed FIFO (`tidelink_fifo*`), an APB-visible register bank
   (`tidelink_apb_regs`), and a 3-channel credit returner
   (`tidelink_returner`).

A dedicated FC node also carries **PTP** (`tidelink_ptp`, `tidelink_ptp_servo`,
`tidelink_phc_cdc`), **performance telemetry** (`tidelink_perf`), and the
**PHY-align / autoneg / training / calibrator** family.

Authoritative module-level reference: `docs/TIDELINK_SPECIFICATION.md`.
Block diagram: §3.1 of that spec. Per-region register map:
`docs/REGISTER_MAP.md`.

The `src/rtl/` first-party RTL set has **19 SystemVerilog files** at the
chiplet level plus **6 FIFO-family files** under `src/rtl/fifo/`. Wlink,
XHB500, I²C, CMSDK and the GPIO PHY are vendor/submodule IP and are
exercised indirectly via the integration envs below.

---

## 2. Verification matrix

Health legend:
- **GREEN** — has a dedicated unit env AND is integration-exercised, with
  multiple `@cocotb.test`s or UVM tests covering normal + error paths.
- **YELLOW** — covered only by a single env, OR only via integration, OR
  the env is intentionally out of CI regression (debug-only).
- **RED** — no committed sim env exercises this module directly.

| RTL module | cocotb env(s) | UVM env(s) | xprop | Health |
|---|---|---|---|---|
| `tidelink_top` | `tidelink_top`, `tidelink_top_pair*`, `tidelink_system` | `tidelink_top_system`, `tidelink_integration` | — | GREEN |
| `tidelink` (legacy FIFO wrapper) | `tidelink`, `tidelink_ahb`, `tidelink_py_pair` | `tidelink` | `tidelink` | GREEN |
| `tidelink_ahb` (AHB-wrap of `tidelink`) | `tidelink_ahb` | — | — | GREEN |
| `tidelink_fc_adapter` | `tidelink_fc_adapter`, integ via `tidelink_top*` | `tidelink_fc_adapter` | — | YELLOW (`full_test` excluded from CI) |
| `tidelink_addr_translator` | `tidelink_addr_translator`, integ via `tidelink_top*` | integ via `tidelink_top_system` | — | GREEN |
| `tl_addr_trans_cam` | (via `tidelink_addr_translator`) | (integ) | — | YELLOW |
| `tl_addr_trans_regs` | (via `tidelink_addr_translator`) | (integ) | — | YELLOW |
| `tidelink_addr_translation` | — | — | — | RED (alternative impl — not instantiated; see header comment) |
| `tidelink_apb_addr_ctrl` | `tidelink_apb_addr_ctrl` | — | — | YELLOW |
| `tidelink_autoneg` (in chiplet-controller subtree) | `tidelink_autoneg`, integ via `tidelink_top_system` | `tidelink_top_system` (`test_top_autoneg_*`) | — | GREEN |
| `tidelink_ptp` | `tidelink_ptp` (incl. lock-gate variant), `debug/phc_pair`, integ via `tidelink_top*` | `tidelink_ptp_chain`, `tidelink_ptp_stress` | — | GREEN |
| `tidelink_ptp_servo` | `tidelink_ptp_servo` | (integ via chain/stress) | — | GREEN |
| `tidelink_phc_cdc` | `tidelink_phc_cdc` | — | — | YELLOW |
| `tidelink_perf` | `tidelink_perf`, `tidelink_perf_congestion` | — | — | YELLOW |
| `tidelink_phy_align_calibrator` | `debug/tidelink_phy_align_calibrator`, `debug/phy_align`, `debug/calibrator_force_bisect` | `tidelink_top_system` (`test_align_*`) | — | YELLOW (no CI-regressed unit env; covered in integ + debug) |
| `tidelink_idelay_rx` | `tidelink_idelay_rx` | — | — | YELLOW |
| `tidelink_rxclk_buf` | `tidelink_rxclk_buf` | — | — | YELLOW |
| `tidelink_clkfreq_check` | `tidelink_clkfreq_check` | — | — | YELLOW |
| `tidelink_mul_iter` | `tidelink_mul_iter` | — | — | YELLOW |
| `tidelink_eye_regs` | `tidelink_eye_regs` | — | — | GREEN |
| **`src/rtl/fifo/` family** | | | | |
| `tidelink_fifo` (and `tidelink_fifo_mem`) | `tidelink_fifo`, `tidelink`, `tidelink_ahb`, `tidelink_py_pair`, integ via `tidelink_top*` | `tidelink`, `tidelink_system`, `tidelink_integration` | `tidelink_fifo` | GREEN |
| `tidelink_fifo_ctrl` | (DUT of `tidelink_fifo_mem` in `tidelink_fifo` env) | (integ) | `tidelink_fifo_ctrl` | GREEN |
| `tidelink_fifo_mem` | `tidelink_fifo` (TOPLEVEL) | (integ) | (via `tidelink_fifo`) | GREEN |
| `tidelink_fifo_ahb` | `tidelink_ahb` | — | — | YELLOW (CI-excluded) |
| `tidelink_apb_regs` | `tidelink_apb_regs`, `tidelink`, `tidelink_ahb`, `tidelink_py_pair`, integ via `tidelink_top*` | (integ) | `tidelink_apb_regs` | GREEN |
| `tidelink_returner` | `tidelink_returner`, `tidelink`, `tidelink_ahb`, `tidelink_py_pair`, integ via `tidelink_top*` | (integ) | `tidelink_returner` | GREEN |

**Counts:** 12 GREEN, 11 YELLOW, 1 RED, **out of 24 first-party RTL
modules** covered above (19 chiplet-level + 5 FIFO-family standalone
modules; `tidelink_fifo_mem` is the unit testbench wrapper for the FIFO
ctrl).

---

## 3. Per-module entries

The intent here is **scope and pointers**, not test-by-test enumeration.
For the exhaustive list of FIFO-era IDs (AHB-01..AHB-33, RET-01..RET-17,
APB-01..APB-35, TOP-01..TOP-25, AHBW-01..AHBW-14, PAIR-01..PTC-08, PTP-01..27,
LG-01..06, MUL-001..010, SRV-001..015) see `cocotb/VERIFICATION_PLAN.md`,
which is now scope-banner'd as the FIFO-area test index.

### 3.1 `tidelink_top` — full chiplet integration

- **Purpose:** Top-level chiplet wrapper. Instantiates `tidelink_fifo_ahb`,
  `tidelink_fc_adapter`, `tidelink_addr_translator`, `tidelink_ptp`,
  `tidelink_ptp_servo`, `tidelink_perf`, the chiplet-controller (Wlink)
  subtree, XHB500 bridges, the GPIO PHY, and the unified APB region mux.
- **Spec ref:** TIDELINK_SPECIFICATION.md §3, §4, §5.
- **Test envs:**
  - cocotb: `tidelink_top` (single-die, FC-loopback), `tidelink_top_pair`
    (two-die pad-skid pair), `tidelink_top_pair_drift`,
    `tidelink_top_pair_skewed` (PHY-stress variants),
    `tidelink_system` (full-system integration).
  - UVM: `tidelink_top_system` (paired, 43 tests — autoneg, align, lane-mask,
    train, peer-mask, addr-translate, reset-recovery), `tidelink_integration`
    (4 tests — base, credit, loopback, stress).
- **Test IDs / files:** `cocotb/tidelink_top/test_tidelink_top.py` (14 tests:
  `test_01_single_fifo_data_word_loopback` … `test_14_*`),
  `cocotb/tidelink_system/test_tidelink_system.py` + `test_verification_gaps.py`
  (29 tests total); `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`,
  `test_calibrator_probe_dump.py`, `test_credit_ledger_probes.py`,
  `test_doorbell_with_new_phy.py`, `test_eyemap_dump.py`,
  `test_lane_swap_detection.py`, `test_master_fc_tx_block.py`,
  `test_master_ptp_tx_router.py`, `test_ptp_corrected_regs.py`,
  `test_bit_order_canary_fail.py`. UVM: `uvm/tidelink_top_system/tests/*.sv`.
- **Coverage status:** not measured per env (no recent `urg` snapshot for
  the post-2026-03-29 envs — re-run `make -C cocotb coverage`).
- **Known gaps:** PHY-side asymmetric faults beyond `test_align_*` and
  beyond the `debug/` AUTOCAL family are not in CI; `tidelink_top_pair*`
  envs are not in the `ENVS` regression list (driven manually).

### 3.2 `tidelink` (legacy FIFO wrapper) — FIFO + returner + APB regs

- **Purpose:** Pre-`tidelink_top` integration of `tidelink_fifo` +
  `tidelink_returner` + `tidelink_apb_regs`. Still instantiated by
  `tidelink_ahb` and exercised by the FIFO-era envs.
- **Spec ref:** TIDELINK_SPECIFICATION.md §4.1, §4.2.
- **Test envs:** cocotb `tidelink` (25 tests, IDs TOP-01..TOP-25),
  `tidelink_ahb` (14 tests via the AHB-to-APB bridge, IDs AHBW-01..AHBW-14),
  `tidelink_py_pair` (19 tests, IDs PAIR-01..PAIR-11 + PTC-01..PTC-08).
  UVM: `uvm/tidelink/` (5 tests).
- **xprop:** `xprop/tidelink/` (full hierarchy).
- **Coverage status:** stale 2026-03-29 snapshot in
  `cocotb/VERIFICATION_PLAN.md` §"Coverage Summary" — Score 81.42%, Line
  97.75% for the `tidelink` env; do not cite without re-running.
- **Known gaps:** see BUG-002 (credit underflow) in xprop/README.md
  future-work and the FIFO-era plan.

### 3.3 `tidelink_fifo` family (`tidelink_fifo`, `tidelink_fifo_ctrl`, `tidelink_fifo_mem`, `tidelink_fifo_ahb`)

- **Purpose:** Credit-based circular FIFO with packet metadata capture
  (`tidelink_fifo_ctrl`) wrapped with `cmsdk_ahb_to_sram` + `cmsdk_fpga_sram`
  in `tidelink_fifo_mem`; `tidelink_fifo_ahb` adds an AHB-to-APB bridge
  for register-port access.
- **Spec ref:** TIDELINK_SPECIFICATION.md §4.1 (RX FIFO Subsystem).
- **Test envs:** cocotb `tidelink_fifo` (40 tests, IDs AHB-01..AHB-33 plus
  added IRQ / flush / overrun / underrun cases). Integration coverage
  via every env in §3.2.
- **xprop:** `xprop/tidelink_fifo/`, `xprop/tidelink_fifo_ctrl/`.
- **Coverage status:** 2026-03-29 snapshot — Score 93.26% (line 100%,
  branch 98.72%) for `tidelink_fifo` env. Stale; re-run.
- **Known gaps:** BUG-002 — no credit-underflow guard. Hardware path
  covered by the FLUSH test family; no FPV proof.

### 3.4 `tidelink_apb_regs` — unified APB register file

- **Purpose:** APB slave for region 0/1/2 registers — pair base, status,
  flush, doorbell, credit accumulators, threshold, PTP/HW_SYNC control.
- **Spec ref:** REGISTER_MAP.md §"Region 0/1/2".
- **Test envs:** cocotb `tidelink_apb_regs` (49 tests; IDs APB-01..APB-35
  in the FIFO-era plan plus added STATUS/threshold cases). Integration
  exposure via every env in §3.2 and via `tidelink_top*`.
- **xprop:** `xprop/tidelink_apb_regs/` (standalone).
- **Coverage status:** stale 2026-03-29 — Score 75.08%, condition 81%,
  toggle 36% (low — sparse access pattern coverage).
- **Known gaps:** sparse reserved-offset toggle coverage.

### 3.5 `tidelink_returner` — 3-channel credit-return AHB master

- **Purpose:** Sends batched credit and doorbell-response writes back to
  the paired TideLink via the AHB master port. Priority arbiter: channel 0
  > channel 1 > channel 2.
- **Spec ref:** TIDELINK_SPECIFICATION.md §3.5, §4.1.
- **Test envs:** cocotb `tidelink_returner` (19 tests, IDs RET-01..RET-17
  plus added master_error cases). Integ via §3.2.
- **xprop:** `xprop/tidelink_returner/`.
- **Coverage status:** stale 2026-03-29 — Score 75.71%, FSM 75%; the
  `ST_ADDR_PHASE → ST_IDLE` edge is the known FSM gap.

### 3.6 `tidelink_fc_adapter` — FC TX/RX + sideband adapter

- **Purpose:** Bridges the FC packet stream (3 channels: FIFO data,
  sideband, PTP) between Wlink's FC interface and the internal
  AHB/APB consumers. Includes RX `pkttype` decode and TX router.
- **Spec ref:** TIDELINK_SPECIFICATION.md §4.2.
- **Test envs:** cocotb `tidelink_fc_adapter` (44 tests across
  `test_tidelink_fc_adapter.py` and `test_rx_pkt_type_decode.py`); UVM
  `tidelink_fc_adapter` (`base`, `tx`, `rx`, `sideband`, `full`).
- **Known gaps:** `tidelink_fc_adapter_full_test` (UVM) is excluded from
  CI — interleaved TX+RX+sideband stress produces ~31 scoreboard
  mismatches (see `cocotb/README.md` §"Known-excluded-from-CI"); the
  single-stream tests pass and are in regression.

### 3.7 `tidelink_addr_translator` + `tl_addr_trans_cam` + `tl_addr_trans_regs`

- **Purpose:** APB-programmed CAM-based address remap on the transparent
  AHB path. 8 match-replace rules with first-match-wins arbitration.
  Identity passthrough on no match.
- **Spec ref:** TIDELINK_SPECIFICATION.md §4.5.
- **Test envs:** cocotb `tidelink_addr_translator` (34 tests); integ via
  `tidelink_top_system` (UVM `test_top_addr_translate`).
- **Known gaps:** `tidelink_addr_translation` (segment-table alternative)
  is not instantiated and has no env — header comment marks it as opt-in.

### 3.8 `tidelink_apb_addr_ctrl` — APB regs for the segment translator

- **Purpose:** APB register bank backing `tidelink_addr_translation`
  (segment-table) — not instantiated in the active design path (CAM is
  used) but the regfile is wired for the alternative.
- **Test envs:** cocotb `tidelink_apb_addr_ctrl` (16 tests).
- **Known gaps:** no system-level coverage (consumer module is not
  instantiated).

### 3.9 `tidelink_autoneg` (chiplet-controller subtree) — autoneg FSM

- **Purpose:** Negotiates link role (master/slave) via I²C sideband + PUF
  arbitration; latches `role_locked`; gates training entry.
- **Spec ref:** AUTONEG_PROTOCOL.md.
- **Test envs:** cocotb `tidelink_autoneg` (7 tests: bypass / nego_init /
  PUF stall / SDA early exit / timeout / force-lock / PUF priority).
  Integ via `uvm/tidelink_top_system/test_top_autoneg_*` (basic / bypass /
  timeout) and `test_train_*` (i2c_handshake, lane_fault, no_peer_response,
  async_re_train, apb_override).
- **Known gaps:** silicon ground-truth (`bringup_pair_converge.sh` flow)
  diverges from sim — see project memory `feedback_sim_gate_before_hw_deploy.md`.

### 3.10 `tidelink_ptp` — PTP message TX/RX + hw_capture pulse

- **Purpose:** Issues SYNC / DELAY_REQ over the FC PTP node; generates a
  1-cycle `phc_hw_capture` pulse on TX and RX handshakes; idle-gates TX
  on `tx_router_idle`. Optional `PHC_LOCK_GATE_EN=1` startup guard.
- **Spec ref:** PTP_PROTOCOL.md.
- **Test envs:** cocotb `tidelink_ptp` (21 tests across
  `test_tidelink_ptp.py` and `test_tidelink_ptp_lock_gate.py`; FIFO-era
  IDs PTP-01..PTP-27 and LG-01..LG-06); UVM `tidelink_ptp_chain` (8
  tests — chain convergence, force-enable, gate-functional,
  lock-propagation, step-recovery, stress, unlock-c-holds, base); UVM
  `tidelink_ptp_stress` (3 tests — all_saturated, idle_baseline, base);
  debug `phc_pair` (slave-RX Phase-1 reproducer; not in CI).
- **Known gaps:** Phase-1 master→slave HW sync path is bug-tracked
  separately — see project memory `project_phc_phase1_*` and
  archived `SIM_HW_GAP_ANALYSIS.md`.

### 3.11 `tidelink_ptp_servo` — autonomous GM/Sub PI loop

- **Purpose:** Hardware servo for PTP — captures t1/t4 (GM) or t2/t3
  (Sub); phase-step + frequency-steer; emits FC SIDEBAND timestamps.
- **Spec ref:** PTP_PROTOCOL.md (servo section).
- **Test envs:** cocotb `tidelink_ptp_servo` (15 tests; IDs SRV-001..015
  per the FIFO-era plan §9 — covers 78-bit timestamps, iterative
  multiplier, anti-windup, phase-step). See
  `cocotb/tidelink_ptp_servo/SERVO_OPT_VPLAN.md` for the optimisation
  vplan carry-forward.
- **Integ:** exercised via `tidelink_ptp_chain` / `tidelink_ptp_stress` UVM.

### 3.12 `tidelink_phc_cdc` — PHC ↔ AHB CDC bridge (6 paths)

- **Purpose:** CDC between TideLink (`hclk`) and external PHC (`phc_clk`).
  Paths 1–6 cover hw_capture, free-running time, PPS, hw_capture trigger,
  set-time write, frequency adjust.
- **Test envs:** cocotb `tidelink_phc_cdc` (15 tests — ratio sweeps
  `0.5x/0.7x/1.3x/2x` on hw_capture and free-running time paths, plus
  PPS and trigger).
- **Coverage status:** not measured.
- **Known gaps:** Bug #5 (Path 2 handshake deadlock) fixed by toggle-reset
  asymmetry; see FIFO-era plan resolved-bugs table.

### 3.13 `tidelink_perf` / `tidelink_perf_congestion`

- **Purpose:** Passive performance counters and an EWMA-based congestion
  estimator. Tap-only; does not gate the datapath.
- **Spec ref:** TIDELINK_SPECIFICATION.md §12.
- **Test envs:** cocotb `tidelink_perf` (15 tests — enable/disable,
  TX/RX timestamps, origin-timestamp, saturation, freeze, etc.);
  cocotb `tidelink_perf_congestion` (9 tests — EWMA fast-seed, step
  convergence, quantiser thresholds, trend draining/growing, starve
  sticky-ack).
- **Known gaps:** R7 (DBG_LINK_STATUS) truncation Bug #23 fixed in
  `cb2cd26`; HW-side covered by HW_TEST_SUITE.md cat 11.

### 3.14 `tidelink_phy_align_calibrator` + lane checker (chiplet-controller subtree)

- **Purpose:** §9 best-of-sweep widest-eye per-lane bit-slip + phase
  calibration FSM. Replaces SW-driven calibration.
- **Spec ref:** TIDELINK_SPECIFICATION.md §9.6, §9.9, §9.10.
- **Test envs:**
  - **In CI regression:** none directly. Covered via the §3.1 integ envs
    and via `uvm/tidelink_top_system/test_align_*` (uniform skew,
    asymmetric skew, dead lane, recalibration-after-link-drop).
  - **Debug-only (not in CI):**
    - `cocotb/debug/tidelink_phy_align_calibrator/` — calibrator FSM unit
      harness (default `test_calibrator_t3` currently asserts on S_SWEEP
      cycles against the post-merge RTL — pending re-pin).
    - `cocotb/debug/phy_align/` — `test_autocal_integrated`,
      `test_best_of_sweep`, `test_calibrator_skew_window`,
      `test_capture_timing_margin`, `test_credit_path_observability`.
    - `cocotb/debug/calibrator_force_bisect/` — hierarchical-force bisect
      that isolated the AUTOCAL=1 M→S corruption (f900e07).
    - `cocotb/debug/tidelink_chiplet_pair_autocal/` — two-chiplet AUTOCAL=1
      sim used in the same investigation.
- **Known gaps:** no in-CI unit env; the debug envs are scenario-pinned.
  Calibrator regression for new structural fixes goes via paired
  `tidelink_top_pair*` runs.

### 3.15 `tidelink_idelay_rx` / `tidelink_rxclk_buf` / `tidelink_clkfreq_check`

- **Purpose:** FPGA-only PHY-side wrappers — per-lane IDELAYE2 (RX phase),
  BUFG on recovered RX clock, and a clk_wiz output sanity-check.
- **Test envs:** cocotb `tidelink_idelay_rx` (2 tests — opt-out branch
  selection + bit-exact passthrough); `tidelink_rxclk_buf` (4 tests —
  passthru/optout branch selection + bit-exact for each);
  `tidelink_clkfreq_check` (5 tests — matched, mismatch 2:1 / 1:2, ppm
  drift, link-down silence).
- **Known gaps:** ASIC build does not exercise these (FPGA-only).

### 3.16 `tidelink_mul_iter` — 32×32 iterative multiplier (PTP servo)

- **Purpose:** Shared 32-cycle signed-×-unsigned iterative multiplier used
  by the PTP servo.
- **Test envs:** cocotb `tidelink_mul_iter` (10 tests, IDs MUL-001..MUL-010
  — reset defaults / identity / small / large / signed / corner / B2B /
  busy flag / randomised stress).

### 3.17 PHY family: `wav_d2d_gpio_tx`, `wavd2d_gpiorx_clkbuf`, `wavd2d_gpiorx_t3a*`

- **Purpose:** §9 PHY refactor envs — TX training-pattern mux,
  `USE_CLKBUF=0` bit-exact restructure, T3a self-aligning RX comma-hunt
  (`_t3a`, `_t3a_off`, `_t3a_timeout` variants).
- **Test envs:** cocotb `wav_d2d_gpio_tx` (5 tests), `wavd2d_gpiorx_clkbuf`
  (2 tests), `wavd2d_gpiorx_t3a` (4 tests), `wavd2d_gpiorx_t3a_off` (2
  tests), `wavd2d_gpiorx_t3a_timeout` (1 test).

### 3.18 `tidelink_eye_regs` — v2 eye-visibility APB regfile

- **Purpose:** APB Region 10 regfile for the v2 PHY eye-sweep proposal
  (docs/EYE_VISIBILITY_RTL_PROPOSAL.md §5). Peer aperture maps Region 10
  to `0x40032140` on the remote die.
- **Test envs:** cocotb `tidelink_eye_regs` (19 tests — reset defaults /
  APB protocol smoke / RW slot coverage / RO write-ignore / §13.5
  MODE=10 pslverr / §13.6 DWELL_US floor-clamp / reserved-DDR RAZ-WI /
  back-to-back burst / CTRL W1P pulse + sticky bits / SCORE_IDX
  auto-increment / CRC RC clear-strobe). Related speculative-path sim
  remains in `cocotb/debug/tidelink_peer_aperture/`.

---

## 4. Regression and CI

### Canonical `ENVS` (from `cocotb/Makefile`, 2026-05-29 — 27 envs)

```
tidelink_fifo tidelink_returner tidelink_apb_regs tidelink_apb_addr_ctrl
tidelink tidelink_ahb tidelink_py_pair tidelink_fc_adapter tidelink_top
tidelink_system tidelink_perf tidelink_perf_congestion
tidelink_addr_translator tidelink_autoneg tidelink_mul_iter
tidelink_phc_cdc tidelink_ptp tidelink_ptp_servo tidelink_idelay_rx
tidelink_rxclk_buf tidelink_clkfreq_check tidelink_eye_regs wav_d2d_gpio_tx
wavd2d_gpiorx_clkbuf wavd2d_gpiorx_t3a wavd2d_gpiorx_t3a_off
wavd2d_gpiorx_t3a_timeout
```

Total in-tree cocotb test functions across all envs (in + out of CI):
**~635 `@cocotb.test` definitions** as of 2026-05-29.

### Envs intentionally NOT in regression

- All of `cocotb/debug/` (13 envs: `bank_asymmetry`,
  `calibrator_force_bisect`, `i2c_clkstretch`, `i2c_mask_selflock`,
  `phc_pair`, `phy_align`, `sim_robust`, `tidelink_chiplet_pair_autocal`,
  `tidelink_peer_aperture`, `tidelink_phy_align_calibrator`,
  `wav_d2d_gpio_tx_prbs`, `wlink_pair`, `wlink_tx_pstate_ctrl`). Reasons
  per env are tabulated in `cocotb/README.md` §"Debug envs".
- `cocotb/tidelink_top_pair`, `tidelink_top_pair_drift`,
  `tidelink_top_pair_skewed` — paired-die scenario envs driven by hand
  during PHY/cal investigation (not in `ENVS`).
- UVM `tidelink_fc_adapter_full_test` (within an otherwise-CI'd env) —
  see §3.6.

### CI loop locations

- `.gitlab-ci.yml` — `hal-lint`, `spyglass-cdc`, `cocotb-regression`,
  `coverage-merge`, `uvm-*` jobs. The cocotb-regression job calls
  `make -C cocotb coverage` and uploads `coverage_report/`.

### Coverage recipe

```sh
cd cocotb && make coverage                       # full ENVS w/ VCS -cm
cd cocotb && make coverage CM_METRICS=line+cond  # subset
# per-env reports → cocotb/coverage_report/<env>/dashboard.{txt,html}
```

The published 2026-03-29 coverage snapshot in `cocotb/VERIFICATION_PLAN.md`
covers only 6 of the 26 envs and is stale — do not cite without re-running.

### UVM envs (7)

- `uvm/tidelink/` (5 tests), `uvm/tidelink_fc_adapter/` (5),
  `uvm/tidelink_integration/` (4), `uvm/tidelink_ptp_chain/` (8),
  `uvm/tidelink_ptp_stress/` (3), `uvm/tidelink_system/` (16),
  `uvm/tidelink_top_system/` (43) — **84 UVM test files**.

---

## 5. Lint / CDC / XPROP

### Cadence HAL lint

- Driver: `lint/Makefile` (HAL via `hal.tcl` + `hal.design_facts`).
- 27 per-module HAL runs are checked in (one `<module>_hal.{log,xml}` per
  first-party RTL module). CI job: `hal-lint` (stage `lint`).
- Companion SV anti-pattern lint at `cocotb/lint/` guards against the
  bug #1 (latch from missing comb default) and bug #2 (collapsed case
  from missing default) silicon-discovered classes — runs in CI as
  `lint-standalone`.

### SpyGlass CDC

- Driver: `cdc/Makefile`; per-module `<module>_cdc_summary.rpt` produced
  under `cdc/<module>_spyglass/cdc_verify/spyglass_reports/`. Default
  module: `tidelink_top`.
- Waiver file: `cdc/waiver.swl`. Per-module SGDC files:
  `tidelink_top.sgdc`, `axi_chiplet_controller.sgdc`, `xhb500.sgdc`.
- Audited findings + accepted residuals: `docs/CDC_AUDIT_REPORT.md`
  (two real CDC violations: `swi_phase_offset_r`, `cal_phase_offset_w`).
- CI job: `spyglass-cdc` (stage `lint`).

### XPROP (Synopsys VC Formal — NOT FPV)

- 5 modules covered: `tidelink` (top, full hierarchy), `tidelink_fifo`,
  `tidelink_fifo_ctrl`, `tidelink_apb_regs`, `tidelink_returner`.
- Driver: `xprop/Makefile`. Per-module makefiles expose `make xprop`,
  `make gui`, `make clean`. Top-level: `make regression`, `make standalone`.
- **Explicit scope statement** from `xprop/README.md`: this is xprop only,
  **not assertion-based FPV**. The design has zero SVA proofs today. The
  natural first FPV target is BUG-002 (credit underflow) on the FIFO
  pointer logic — see xprop/README.md §"Future work".
- Modules with **no xprop coverage** (and no FPV): `axi_chiplet_controller`,
  `tidelink_phy_align_calibrator` + lane checker + wire FSM,
  `tidelink_fc_adapter`, `tidelink_addr_translator`, `tidelink_eye_regs`,
  `tidelink_ptp`. See `docs/archive/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`
  for the full gap list.

---

## 6. Sign-off criteria

### Per-module (sim)

- **GREEN-health modules** (§2): regression must pass; xprop must pass on
  the 5 modules listed in §5; coverage targets per VCS metric:
  line ≥ 95%, condition ≥ 80%, FSM ≥ 90%, branch ≥ 90%, toggle ≥ 60%.
  These are the targets implied by the FIFO-era snapshot (which already
  exceeds line and branch); raise to ≥ 95% on toggle once the test
  randomisation work in `cocotb/VERIFICATION_PLAN.md` §"Coverage Gaps"
  lands.
- **YELLOW-health modules** (§2): a sign-off block must list which gap
  (CI-excluded full test, debug-only env, integration-only coverage)
  applies and either close it or accept it with a waiver entry in
  `docs/SHORTCOMINGS.md`.
- **RED-health modules** (§2): block sign-off unless the module is
  explicitly marked dead code (e.g. `tidelink_addr_translation`'s
  "ALTERNATIVE IMPLEMENTATION — NOT INSTANTIATED" banner is the accepted
  waiver pattern).

### System-level (sim)

- `tidelink_system` and `tidelink_top` cocotb regressions: 0 FAIL.
- UVM `tidelink_top_system` (43 tests covering align, autoneg, lane-mask,
  train, peer-mask, addr-translate, reset-recovery): 0 FAIL.
- UVM `tidelink_ptp_chain` + `tidelink_ptp_stress`: 0 FAIL.
- One paired-die `tidelink_top_pair` run with `test_tidelink_pair_doorbell`
  PASS (driven by hand; not in `ENVS`).

### Tool clean

- `lint/Makefile` (HAL): all 27 module logs report 0 errors.
- `cocotb/lint` (SV anti-pattern): exit 0.
- `cdc/Makefile`: all SGDC modules clean modulo `cdc/waiver.swl` and the
  two accepted findings in `docs/CDC_AUDIT_REPORT.md`.
- `xprop/Makefile`: 5 modules pass.

### HW sign-off

HW bring-up acceptance is governed by `docs/HW_TEST_SUITE.md` cat 1–13
(13 categories on the PYNQ-Z2 pair). That is a sibling sign-off path
with a different gating set — sim sign-off above does **not** subsume HW
sign-off, and vice versa.

---

## 7. Glossary of test environments

### cocotb — in regression (`ENVS`, 26 envs)

| Env | DUT | One-liner |
|---|---|---|
| `tidelink_fifo` | `tidelink_fifo_mem` | FIFO mem + ctrl + APB regs as the FIFO subsystem |
| `tidelink_returner` | `tidelink_returner` | Credit-return AHB-master state machine |
| `tidelink_apb_regs` | `tidelink_apb_regs` | APB register file (standalone) |
| `tidelink_apb_addr_ctrl` | `tidelink_apb_addr_ctrl` | APB regfile for segment-table addr translator |
| `tidelink` | `tidelink` (legacy FIFO wrapper) | Pre-`tidelink_top` integration (TOP=`tidelink_fifo`) |
| `tidelink_ahb` | `tidelink_ahb` | `tidelink` + AHB-to-APB bridge (cocotb + HAL lint clean as of 2026-05-29) |
| `tidelink_py_pair` | `tidelink` + Python pair model | Python-driven paired-board sim |
| `tidelink_fc_adapter` | `tidelink_fc_adapter` | FC TX/RX + sideband adapter; single-stream only in CI |
| `tidelink_top` | `tidelink_top` | Top-level chiplet single-die FC-loopback |
| `tidelink_system` | `tidelink_top` ×2 paired | Full-system integration test |
| `tidelink_perf` | `tidelink_perf` | Perf counter block |
| `tidelink_perf_congestion` | `tidelink_perf` congestion estimator | EWMA / quantiser characterisation |
| `tidelink_addr_translator` | `tidelink_addr_translator` | CAM-based address translation |
| `tidelink_autoneg` | autoneg FSM in chiplet-controller | Role-lock + I²C arbitration |
| `tidelink_mul_iter` | `tidelink_mul_iter` | 32×32 iterative signed-×-unsigned multiplier |
| `tidelink_phc_cdc` | `tidelink_phc_cdc` | 6-path PHC ↔ AHB CDC bridge |
| `tidelink_ptp` | `tidelink_ptp` | PTP message TX/RX + hw_capture + lock-gate variant |
| `tidelink_ptp_servo` | `tidelink_ptp_servo` | Autonomous GM/Sub PI servo |
| `tidelink_idelay_rx` | `tidelink_idelay_rx` | Per-lane IDELAYE2 wrapper passthrough |
| `tidelink_rxclk_buf` | `tidelink_rxclk_buf` | Recovered-RX-clock BUFG wrapper |
| `tidelink_clkfreq_check` | clock-freq check helper | clk_wiz output sanity |
| `wav_d2d_gpio_tx` | `WavD2DGpioTx` | Training-pattern mux passthrough |
| `wavd2d_gpiorx_clkbuf` | `WavD2DGpioRx` | §9 in-PHY BUFG restructure (`USE_CLKBUF=0` bit-exact) |
| `wavd2d_gpiorx_t3a` | `WavD2DGpioRx` | §9 T3a self-aligning RX comma-hunt |
| `wavd2d_gpiorx_t3a_off` | `WavD2DGpioRx` | §9 T3a `USE_T3A=0` legacy-passthrough |
| `wavd2d_gpiorx_t3a_timeout` | `WavD2DGpioRx` | §9 T3a silent-peer MAX_HUNT timeout |

### cocotb — NOT in regression

- **`cocotb/tidelink_top_pair`**, **`_drift`**, **`_skewed`** — paired-die
  scenario envs (pad-skid TB) used by hand during PHY/cal/PTP investigation.
- **`cocotb/debug/`** — 13 bug-bisect / fault-injection / silicon-fingerprint
  envs (see `cocotb/README.md` §"Debug envs" for one-liners per env;
  examples: `wlink_pair` for the 2026-05-2x interface-FCSM family,
  `calibrator_force_bisect` for AUTOCAL=1 M→S corruption, `phc_pair`
  for PHC Phase-1 slave-RX, `i2c_mask_selflock` for autonomous SLAVE
  self-lock, `sim_robust` for adversarial Cat-3/Cat-6 silicon
  fingerprints).

### UVM (7 envs, 84 test files)

| Env | DUT | One-liner |
|---|---|---|
| `uvm/tidelink/` | `tidelink` (legacy FIFO wrapper) | base + random + register + single-packet + stall (5 tests) |
| `uvm/tidelink_fc_adapter/` | `tidelink_fc_adapter` | base + tx + rx + sideband + full (full excluded from CI) |
| `uvm/tidelink_integration/` | `tidelink` ×2 paired | base + credit + loopback + stress (4 tests) |
| `uvm/tidelink_ptp_chain/` | multi-hop PTP chain | convergence + force-enable + gate + lock-prop + step-recovery + stress + unlock-c-holds + base (8 tests) |
| `uvm/tidelink_ptp_stress/` | PTP saturation | all_saturated + idle_baseline + base (3 tests) |
| `uvm/tidelink_system/` | `tidelink` ×2 (legacy paired) | back_to_back / bidirectional / credit_* / error_* / interleaved / max_packet / pair_credit_underflow / long_running (16 tests) |
| `uvm/tidelink_top_system/` | `tidelink_top` ×2 paired | align_* / autoneg_* / lane_mask_* / peer_mask_* / train_* / addr_translate / ahb_passthrough / reset_recovery / etc. (43 tests; gate netlist supported via `sim_build_gate`) |

(`uvm/tidelink_addr_translator/` was removed pre-2026-05; the
`addr_translate` coverage now lives inside `tidelink_top_system`.)

### xprop (5 modules)

`xprop/tidelink/`, `xprop/tidelink_fifo/`, `xprop/tidelink_fifo_ctrl/`,
`xprop/tidelink_apb_regs/`, `xprop/tidelink_returner/`. Driven by
`xprop/Makefile`. **No SVA / FPV proofs in tree.**

---

## Appendix A — Doc cross-references

- HW sign-off (sibling): `docs/HW_TEST_SUITE.md` (13 categories on PYNQ-Z2).
- Architecture and module reference: `docs/TIDELINK_SPECIFICATION.md`.
- Register map: `docs/REGISTER_MAP.md`.
- Autoneg protocol: `docs/AUTONEG_PROTOCOL.md`.
- PTP protocol: `docs/PTP_PROTOCOL.md`.
- CDC findings + waivers: `docs/CDC_AUDIT_REPORT.md`.
- ASIC timing constraints: `docs/ASIC_TIMING_CONSTRAINTS.md`.
- Bug tracker (open + resolved): `docs/BUG_TRACKER.md`.
- Known limitations / waivers: `docs/SHORTCOMINGS.md`.
- FIFO-area test ID index: `cocotb/VERIFICATION_PLAN.md`.
- cocotb env directory + one-liners: `cocotb/README.md`.
- xprop honest-scope statement: `xprop/README.md`.
- Archived earlier vplans: `docs/archive/PTP_HW_TEST_PLAN.md`,
  `docs/archive/SIM_HW_GAP_ANALYSIS.md`,
  `docs/archive/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`.

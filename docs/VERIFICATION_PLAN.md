# TideLink Verification Plan

Single canonical verification strategy for the **TideLink chiplet-interconnect
subsystem** (`src/rtl/tidelink_top.sv`). Covers four levels: **unit** (per-module
cocotb), **integration** (paired-die cocotb + UVM), **system** (full chiplet),
and **HW bring-up** (PYNQ-Z2 pair). Includes the test matrices, the known-issue
backlog, and sign-off criteria.

Companion docs: [TIDELINK_SPECIFICATION.md](archive/TIDELINK_SPECIFICATION.md) (module
reference + block diagram), [REGISTER_MAP.md](REGISTER_MAP.md),
[AUTONEG_PROTOCOL.md](archive/AUTONEG_PROTOCOL.md), [PTP_PROTOCOL.md](archive/PTP_PROTOCOL.md),
[CDC_AUDIT_REPORT.md](archive/CDC_AUDIT_REPORT.md), [BUG_TRACKER.md](archive/BUG_TRACKER.md).

> **Re-baseline status:** Module-to-env mappings reflect the live tree as of
> 2026-05-29 and should be re-verified before any sign-off use. The deep
> FIFO-era test-ID index lives in `cocotb/VERIFICATION_PLAN.md`
> (AHB-/RET-/APB-/TOP-/PTP-/SRV- IDs); env one-liners in `cocotb/README.md`.

---

## 1. Scope and architecture

TideLink bridges an AMBA AHB SoC fabric to a die-to-die serial link, providing
**two independently flow-controlled paths** over a single GPIO PHY:

1. **Transparent AHB bridging** — XHB500 (AHB↔AXI) → AXI chiplet controller
   (Wlink) → CAM-based APB-programmed address translator.
2. **Mailbox packet transfer** — dedicated Wlink FC node → credit-managed FIFO
   (`tidelink_fifo*`) → APB register bank (`tidelink_apb_regs`) → 3-channel
   credit returner (`tidelink_returner`).

Dedicated FC nodes also carry **PTP** (`tidelink_ptp`, `_ptp_servo`, `_phc_cdc`),
**performance telemetry** (`tidelink_perf`), and the **PHY-align / autoneg /
training / calibrator** family. Wlink, XHB500, I²C, CMSDK and the GPIO PHY are
vendor/submodule IP, exercised indirectly through the integration envs.

First-party RTL: **19 SystemVerilog files** at chiplet level + **6 FIFO-family
files** under `src/rtl/fifo/`.

**Verification toolchain:** cocotb (functional unit + integration), UVM
(constrained-random integration), Synopsys VC Formal **xprop** (X-propagation,
*not* assertion-based FPV — zero SVA proofs in tree today), Cadence **HAL** lint
+ a standalone SV anti-pattern lint, SpyGlass **CDC**.

---

## 2. Coverage matrix (first-party RTL)

Health legend — **GREEN**: dedicated unit env AND integration-exercised;
**YELLOW**: single env / integration-only / debug-only; **RED**: no committed
sim env exercises the module directly.

| RTL module | cocotb env(s) | UVM env(s) | xprop | Health |
|---|---|---|---|---|
| `tidelink_top` | `tidelink_top`, `tidelink_top_pair*`, `tidelink_system` | `tidelink_top_system`, `tidelink_integration` | — | GREEN |
| `tidelink` (legacy FIFO wrapper) | `tidelink`, `tidelink_ahb`, `tidelink_py_pair` | `tidelink` | `tidelink` | GREEN |
| `tidelink_ahb` | `tidelink_ahb` | — | — | GREEN |
| `tidelink_fc_adapter` | `tidelink_fc_adapter`, integ via `tidelink_top*` | `tidelink_fc_adapter` | — | GREEN |
| `tidelink_addr_translator` | `tidelink_addr_translator`, integ | integ (`tidelink_top_system`) | — | GREEN |
| `tl_addr_trans_cam` / `tl_addr_trans_regs` | via `tidelink_addr_translator` | integ | both standalone | GREEN |
| `tidelink_addr_translation` | — | — | — | **RED (waived — alt impl, not instantiated)** |
| `tidelink_apb_addr_ctrl` | `tidelink_apb_addr_ctrl` | — | `tidelink_apb_addr_ctrl` | GREEN |
| `tidelink_autoneg` | `tidelink_autoneg`, integ | `tidelink_top_system` (`test_top_autoneg_*`) | — | GREEN |
| `tidelink_ptp` | `tidelink_ptp` (+ lock-gate), `debug/phc_pair`, integ | `tidelink_ptp_chain`, `tidelink_ptp_stress` | — | GREEN |
| `tidelink_ptp_servo` | `tidelink_ptp_servo` | integ (chain/stress) | — | GREEN |
| `tidelink_phc_cdc` | `tidelink_phc_cdc` | — | `tidelink_phc_cdc` | GREEN |
| `tidelink_perf` | `tidelink_perf`, `tidelink_perf_congestion` | — | `tidelink_perf` | GREEN |
| `tidelink_phy_align_calibrator` (+ lane checker) | `tidelink_phy_align_calibrator` (CI), `debug/*` | `tidelink_top_system` (`test_align_*`) | — | GREEN |
| `tidelink_idelay_rx` / `tidelink_rxclk_buf` / `tidelink_clkfreq_check` | one env each | — | each (ASIC-passthrough mode) | GREEN |
| `tidelink_mul_iter` | `tidelink_mul_iter` | — | `tidelink_mul_iter` | GREEN |
| `tidelink_eye_regs` | `tidelink_eye_regs` | — | — | GREEN |
| `tidelink_fifo` (+ `_ctrl`, `_mem`) | `tidelink_fifo`, + FIFO-era envs | `tidelink`, `tidelink_system`, `tidelink_integration` | `tidelink_fifo`, `_ctrl` | GREEN |
| `tidelink_fifo_ahb` | `tidelink_ahb` | — | — | GREEN |
| `tidelink_apb_regs` | `tidelink_apb_regs`, + FIFO-era envs | integ | `tidelink_apb_regs` | GREEN |
| `tidelink_returner` | `tidelink_returner`, + FIFO-era envs | integ | `tidelink_returner` | GREEN |

**Counts:** 24 GREEN, 1 RED, out of 25 first-party modules. The single RED
(`tidelink_addr_translation`) is an accepted waiver — its header banner reads
"ALTERNATIVE IMPLEMENTATION — NOT INSTANTIATED IN THE ACTIVE DESIGN".

---

## 3. cocotb unit + integration matrix

### 3.1 In-regression envs (`ENVS`, 28 — from `cocotb/Makefile`)

```
tidelink_fifo tidelink_returner tidelink_apb_regs tidelink_apb_addr_ctrl
tidelink tidelink_ahb tidelink_py_pair tidelink_fc_adapter tidelink_top
tidelink_system tidelink_perf tidelink_perf_congestion tidelink_addr_translator
tidelink_autoneg tidelink_mul_iter tidelink_phc_cdc tidelink_ptp
tidelink_ptp_servo tidelink_idelay_rx tidelink_rxclk_buf tidelink_clkfreq_check
tidelink_eye_regs tidelink_phy_align_calibrator wav_d2d_gpio_tx
wavd2d_gpiorx_clkbuf wavd2d_gpiorx_t3a wavd2d_gpiorx_t3a_off
wavd2d_gpiorx_t3a_timeout
```

| Env | DUT | Scope / test count |
|---|---|---|
| `tidelink_fifo` | `tidelink_fifo_mem` | FIFO mem+ctrl+regs (~40; AHB-01..33 + IRQ/flush/overrun) |
| `tidelink_returner` | `tidelink_returner` | Credit-return AHB master (19; RET-01..17 + error) |
| `tidelink_apb_regs` | `tidelink_apb_regs` | Unified APB regfile (49; APB-01..35 + STATUS/threshold) |
| `tidelink_apb_addr_ctrl` | `tidelink_apb_addr_ctrl` | Segment-translator APB regs (16) |
| `tidelink` | `tidelink` (legacy wrapper) | FIFO+returner+regs integration (25; TOP-01..25) |
| `tidelink_ahb` | `tidelink_ahb` | `tidelink` + AHB-to-APB bridge (14; AHBW-01..14) |
| `tidelink_py_pair` | `tidelink` + py pair model | Python paired-board (19; PAIR-01..11 + PTC-01..08) |
| `tidelink_fc_adapter` | `tidelink_fc_adapter` | FC TX/RX + sideband + pkttype decode (44) |
| `tidelink_top` | `tidelink_top` | Single-die FC-loopback (14; test_01..14) |
| `tidelink_system` | `tidelink_top` ×2 | Full-system integration (~29 incl. gap tests) |
| `tidelink_perf` / `_congestion` | `tidelink_perf` | Counters (15) + EWMA/quantiser (9) |
| `tidelink_addr_translator` | `tidelink_addr_translator` | CAM remap, first-match-wins (34) |
| `tidelink_autoneg` | autoneg FSM | Role-lock + I²C/PUF arbitration (7) |
| `tidelink_mul_iter` | `tidelink_mul_iter` | 32×32 iterative multiplier (10; MUL-001..010) |
| `tidelink_phc_cdc` | `tidelink_phc_cdc` | 6-path PHC↔AHB CDC, ratio sweeps (15) |
| `tidelink_ptp` | `tidelink_ptp` | PTP TX/RX + hw_capture + lock-gate (21; PTP-/LG-) |
| `tidelink_ptp_servo` | `tidelink_ptp_servo` | GM/Sub PI servo, 78-bit ts (15; SRV-001..015) |
| `tidelink_idelay_rx` / `_rxclk_buf` / `_clkfreq_check` | FPGA PHY wrappers | passthrough/optout branch + bit-exact (2 / 4 / 5) |
| `tidelink_eye_regs` | `tidelink_eye_regs` | v2 eye-visibility APB Region 10 (19) |
| `tidelink_phy_align_calibrator` | calibrator FSM | T3/T3.2 + S_PROBE-skip FSM (7; param-shrunk) |
| `wav_d2d_gpio_tx` | `WavD2DGpioTx` | Training-pattern mux passthrough (5) |
| `wavd2d_gpiorx_clkbuf` | `WavD2DGpioRx` | §9 BUFG restructure, `USE_CLKBUF=0` bit-exact (2) |
| `wavd2d_gpiorx_t3a` / `_off` / `_timeout` | `WavD2DGpioRx` | §9 T3a comma-hunt / legacy / silent-peer timeout (4 / 2 / 1) |

Total in-tree cocotb test functions across all envs (in + out of CI):
**~635 `@cocotb.test` definitions** (2026-05-29 snapshot).

### 3.2 On-disk envs NOT in `ENVS` (manual / experimental)

| Env | Status | Note |
|---|---|---|
| `tidelink_top_pair` | manual paired-die | Pad-skid two-die TB; doorbell / calibrator-probe / credit-ledger / lane-swap / bit-order-canary scenario tests, driven by hand during PHY/cal bring-up |
| `tidelink_top_pair_drift` | manual / PHY-stress | Slave on independent +500 ppm clock + phase offset (M→S/S→M asymmetry repro) |
| `tidelink_top_pair_skewed` | manual / PHY-stress | Cross-lane word-skew injection |
| `tidelink_top_pair_wordskew` | **experimental** | 12 tests (default `MODULE=test_tidelink_pair_doorbell`; a 1-test `test_calibrator_probe_dump` also present) + 8 `sim_build_*` scratch dirs and `.log` artifacts — calibrator/word-skew probe sandbox; **not pinned** |
| `tidelink_lane_deskew` | **experimental** | 8 tests; multiple `sim_build_{fix,gate,pipe,syncfix}` + `results_fix.xml` — cross-lane deskew FIFO bring-up sandbox (PHY-v2 work) |
| `tidelink_deskew_bubble` | **experimental** | 1 test — deskew bubble probe |
| `cocotb/debug/*` (12) | bug-bisect / fault-injection | `bank_asymmetry`, `calibrator_force_bisect`, `i2c_clkstretch`, `i2c_mask_selflock`, `phc_pair`, `phy_align`, `sim_robust`, `tidelink_chiplet_pair_autocal`, `tidelink_peer_aperture`, `tidelink_phy_align_calibrator`, `wlink_pair`, `wlink_tx_pstate_ctrl` — see `cocotb/README.md` §"Debug envs" |

> The `tidelink_top_pair*`, `tidelink_lane_deskew`, `tidelink_deskew_bubble` and
> `tidelink_top_pair_wordskew` envs exist on disk but are **not in the CI
> regression list** — treat their pass/fail as advisory only until pinned.

---

## 4. UVM testbench matrix (7 envs, ~84 test files)

| Env | DUT | Tests |
|---|---|---|
| `uvm/tidelink/` | `tidelink` (legacy wrapper) | base + random + register + single-packet + stall (5) |
| `uvm/tidelink_fc_adapter/` | `tidelink_fc_adapter` | base + tx + rx + sideband + full (5; full now CI-stable, see §6 B14) |
| `uvm/tidelink_integration/` | `tidelink` ×2 | base + credit + loopback + stress (4) |
| `uvm/tidelink_ptp_chain/` | multi-hop PTP chain | convergence / force-enable / gate / lock-prop / step-recovery / stress / unlock-c-holds / base (8) |
| `uvm/tidelink_ptp_stress/` | PTP saturation | all_saturated + idle_baseline + base (3) |
| `uvm/tidelink_system/` | `tidelink` ×2 (legacy paired) | back_to_back / bidirectional / credit_* / error_* / interleaved / max_packet / pair_credit_underflow / long_running (16) |
| `uvm/tidelink_top_system/` | `tidelink_top` ×2 | align_* / autoneg_* / lane_mask_* / peer_mask_* / train_* / addr_translate / ahb_passthrough / reset_recovery (43; gate netlist via `sim_build_gate`) |

(`uvm/tidelink_addr_translator/` was retired pre-2026-05; addr-translate
coverage now lives in `tidelink_top_system`.)

---

## 5. HW bring-up test suite + safety gates

HW acceptance runs on the **PYNQ-Z2 pair** (`bridge1`) via
`pynq_host/scripts/hwtest/run_all.sh`. All board I/O goes through one trust
boundary — `lib_hwtest.sh` (the `/dev/mem` mmap-from-Python pattern reused from
`wlink_probe.sh` / `bringup_pair_converge.sh`); category scripts must **not**
introduce a new transport. Detail in `archive/HW_TEST_SUITE.md`.

| Cat | Area | Pass criteria | Safety |
|---|---|---|---|
| 1 | Wlink layer | 8/8 lanes + cal_done; ECC idle; lane-mask popcount ≤7; retrain no drops | APB + lane-mask (restored on exit) |
| 2 | Region 0 regs | PAIR_BASE / RELEASE_THRESHOLD round-trip; FLUSH self-clears; RO rejects | APB-only |
| 3 | AHB SUB e2e | 100% local integrity; peer-visible if link up | SUB is documented-safe, no gate |
| 4 | AHB MNG accounting | DOORBELL_RESP_ACC in [1,N]; PAIR counter saturate-at-0 (Bug #7) | APB + doorbell |
| **5** | **AHB TX (wedge hazard)** | no timeout; sticky clears; link still 16/16 | **`tt_gate_ahb_tx()` mandatory + per-write `timeout`** |
| 6 | AHB FIFO | CREDIT_COUNT near-full idle; FLUSH + threshold + IRQ-acc clear | APB-only |
| 7 | Address translation | PAIR_BASE round-trip; CAM slots 1..7 RW/RO; restore | APB-only |
| 8 | PTP basic | PTP_CTRL round-trip; RX_PAYLOAD/STATUS RO | APB-only |
| 9 | PTP HW sync | seq_num advances; STATUS.active=1; soak no drops | **gated on PHC image** |
| 10 | Servo + mailbox | servo round-trip or RO-stable; mailbox readable | APB-only |
| 11 | Perf counters | all 24 readable; ≥1 advances; R7 ≠ 0xFFFFFFFF (Bug #23 sentinel) | APB + traffic |
| 12 | Chiplet ext (R8) | PHY_ALIGN_ID exact; round-trips; STEP not latched 0x1 | APB-only |
| 13 | Long soak | 0 drops, 0 sticky over `SOAK_SECS` (default 600 s) | safe-ops only |

**The Cat 5 wedge gate is the cardinal HW rule.** An AHB_TX write into a
down link never returns HREADY → the AXI-Lite-to-AHB bridge stalls →
SmartConnect blocks → the PS mmap hangs in kernel space → SSH dies → physical
power-cycle. Two-layer defence: (a) `tt_gate_ahb_tx()` aborts unless 16/16 +
cal_done both sides; (b) every write wrapped in `timeout`, exit rc=4 propagated
as a hard stop. **Project rule:** the paired-die cocotb sim must pass before any
FPGA build/deploy is kicked (sim-gate before HW).

Pre-conditions: bridge1 lease *granted* (not queued); unified-main bitstream
deployed + verified 16/16; PHC image present for Cat 9. HW-suite gaps
(deferred): thermal characterisation, PHC absolute-offset accuracy (needs GPS),
multi-pair stress.

---

## 6. Known-issue / shortcomings backlog

Full design-shortcoming inventory (locations + recommendations) in
`archive/SHORTCOMINGS.md`; open/resolved tracker in `BUG_TRACKER.md`. Condensed:

| # | Sev | Area | Issue | Status |
|---|---|---|---|---|
| 1 | Critical | fifo_ctrl | No credit-underflow guard (BUG-002): counter wraps, silent corruption | OPEN — candidate first FPV target |
| 2 | Critical | fifo_ctrl | Single packet in-flight; addr-0 metadata not queued | OPEN (architectural) |
| 3 | Moderate | fifo_ctrl | No HW packet-size validation vs MAX_CREDITS | OPEN |
| 4 | Moderate | fifo_mem/ctrl | No AHB ERROR response on overrun/underrun (silent sticky) | OPEN |
| 5 | Moderate | returner | No retry on `hresp=1`; credit/doorbell lost | OPEN |
| 6 | Moderate | fifo_ctrl | No partial-write recovery (only FLUSH) | OPEN |
| 7 | Moderate | apb_regs | Pair-credit counter no underflow guard | Mitigated (HW Cat 4 saturate-at-0) |
| 8 | Moderate | apb_regs | Accumulator R-clear/W-add same-cycle race drops freed credits | OPEN |
| 9–15 | Minor | apb_regs/fifo | 32-bit width hard-coded; no hreadyout back-pressure; no ID/version reg; `pslverr`≡0; reset-deassert glitch; burst SEQ accepted unhandled; threshold writable while enabled | OPEN (documented) |
| 14a | Resolved | autoneg | HW-driven peer lane-mask handshake (state 4→9→10→8→5) | RESOLVED — UVM `test_top_peer_mask_auto[_mismatch]` |
| 14b | Open(UVM) | top/Wlink | Autoneg-driven role-lock doesn't carry A→B in `test_top_autoneg_basic` (staggered POR / FCSM credit-grant); link_status=0x18 but scoreboard RX=0 | OPEN — deferred wave-debug |
| 16–17 | Moderate | ptp | PTP TX idle-gating unbounded wait; RX pipeline jitter not eliminated | OPEN (characterise via stress) |
| 18–22 | Minor | ptp/servo | SW-mediated servo (Tier 1); shared capture core; sub-ns dropped; +64-cy PI latency; large-offset phase-step | Accepted/by-design |
| 23 | Moderate | fc_adapter/fifo | No app-layer packet integrity (CRC/seq) on mailbox path | OPEN |
| 24 | Moderate | fifo/returner | No HW timeout for stalled credit flow (silent indefinite TX stall) | OPEN |
| 25 | Moderate | apb_regs | Config regs not lockable after init | OPEN |
| 26 | Minor | fc_adapter | TX arbitration can starve data path (returner unconditional priority) | OPEN |
| 27 | Moderate | top/returner | No coordinated paired-chiplet reset protocol | OPEN |
| 28–35 | Mod/Minor | **verification gaps** | E2E error-recovery; CDC ratio variations; addr-translate in top-integ; pair-credit underflow; partial-packet abandon; throughput/latency; PTP multi-hop; coordinated reset — all untested | OPEN test-debt |
| 36–38 | Mod/Minor | PUF/TideChart | PUF SRAM lowest arbiter priority; PUF valid only pre-FIFO-write; `tc_axis_*` no flow-control credits (HOL block) | OPEN |

Confirmed RTL caveats also tracked: `tidelink_fc_adapter.sv` lines 181-194 /
226-238 has an overlapping-address-phase corner that fires only under a
non-compliant master (does not fire under any master that observes `hready`).

---

## 7. Lint / CDC / XPROP

- **HAL lint** (`lint/Makefile`): 27 per-module runs checked in, CI job
  `hal-lint`. Companion SV anti-pattern lint (`cocotb/lint/`) guards the
  silicon-discovered latch-from-missing-default and collapsed-case-from-missing-default
  classes; CI job `lint-standalone`.
- **SpyGlass CDC** (`cdc/Makefile`, default `tidelink_top`): per-module
  summaries; waivers in `cdc/waiver.swl`; two accepted residuals
  (`swi_phase_offset_r`, `cal_phase_offset_w`) audited in
  `CDC_AUDIT_REPORT.md`; CI job `spyglass-cdc`.
- **XPROP** (`xprop/Makefile`, 14 modules): X-propagation only — **no SVA / FPV
  proofs in tree**. Not covered: `axi_chiplet_controller`, calibrator + lane
  checker, `tidelink_fc_adapter`, `tidelink_addr_translator` top,
  `tidelink_eye_regs`, `tidelink_ptp`. Natural first FPV target = BUG-002.

CI loop (`.gitlab-ci.yml`): `hal-lint`, `spyglass-cdc`, `cocotb-regression`
(`make -C cocotb coverage`), `coverage-merge`, `uvm-*`, plus a manual/scheduled
`hwtest` stage (acquires bridge1 lease, verifies bitstream manifest, runs
`HWTEST_INCLUDE=safe run_all.sh`, releases lease on trap).

---

## 8. Sign-off criteria

### Per-module (sim)
- **GREEN**: regression passes; xprop passes on its covered set; VCS coverage
  ≥ line 95 / condition 80 / FSM 90 / branch 90 / toggle 60 (%) — raise toggle to
  95 once randomisation debt (§6 #28–35) lands.
- **YELLOW**: a sign-off block must name the gap (CI-excluded test / debug-only /
  integration-only) and either close it or accept it with a `SHORTCOMINGS.md`
  waiver.
- **RED**: blocks sign-off unless explicitly dead code (the
  `tidelink_addr_translation` "NOT INSTANTIATED" banner is the accepted pattern).

### System (sim)
- `tidelink_system` + `tidelink_top` cocotb: 0 FAIL.
- UVM `tidelink_top_system` (43), `tidelink_ptp_chain` + `tidelink_ptp_stress`:
  0 FAIL.
- One manual `tidelink_top_pair` run with `test_tidelink_pair_doorbell` PASS.

### Tool clean
- HAL: 27 module logs, 0 errors. `cocotb/lint`: exit 0. CDC: clean modulo
  `waiver.swl` + the two accepted findings. xprop: covered modules pass.

### HW
- Governed by `archive/HW_TEST_SUITE.md` Cat 1–13 — a **separate** gating set.
  Sim sign-off does not subsume HW sign-off, nor vice versa. Sim-gate (paired-die
  cocotb green) is mandatory before any HW deploy.

> Coverage numbers from the 2026-03-29 snapshot in `cocotb/VERIFICATION_PLAN.md`
> cover only 6 envs and are **stale** — re-run `make -C cocotb coverage` before
> citing.

---

## Sources

Folded and archived under `docs/archive/`:
- `archive/VPLAN.md` — prior canonical verification plan (cocotb/UVM matrix, scope, per-module entries).
- `archive/SHORTCOMINGS.md` — design shortcomings / known-issue inventory (§6 backlog).
- `archive/HW_TEST_SUITE.md` — HW test orchestrator, 13-category matrix, safety gates (§5).

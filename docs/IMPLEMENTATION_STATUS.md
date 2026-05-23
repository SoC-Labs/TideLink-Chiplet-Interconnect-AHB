# TideLink — Implementation Status Report

Generated 2026-05-22. Anchored on `origin/main` @ `9e84ebe` (v1.0 candidate),
submodule `deps/axi-chiplet-controller` @ `2f602d1`. All claims below are read
from the `main` branch via git refs, **not** from the working tree (which is
mid branch-merge on `release/v1.0-rc1`, the pre-fix lineage).

This document covers **implementation / build / sign-off maturity** per domain
and the path to production. It is the complement of `docs/OUTSTANDING_WORK_REPORT.md`
(bugs/tests/HW-stress) and `docs/RTL_FREEZE_CHECKLIST.md` (bug-by-bug freeze
gating) — read those for the defect-level detail; this one is about how far each
implementation flow has matured toward tape-out / production.

Legend: ✅ complete · ⚠️ partial / caveated · ❌ not done · n/a not applicable

---

## 1. RTL implementation status

### 1.1 Module inventory + maturity

The design splits across two trees: the TideLink wrapper RTL in
`src/rtl/` (this repo) and the chiplet-controller / Wlink PHY in the submodule
`deps/axi-chiplet-controller` @ `2f602d1`. `tidelink_top` (`src/rtl/tidelink_top.sv`)
is the integration point and instantiates the FIFO, FC adapter, PTP, PHC-CDC,
perf, and address-translator blocks directly; the calibrator / lane-checker /
autoneg live one level down inside the submodule's `axi_chiplet_controller.sv`.

| Module | Path | Done | Stubbed / incomplete | Lint / HAL |
|---|---|---|---|---|
| `tidelink_top` | `src/rtl/tidelink_top.sv` | ✅ integration of FIFO, FC adapter, PTP, servo, PHC-CDC, perf, addr-translator (instantiations at lines 742/844/931/1002/1054/1115/1350) | ⚠️ does **not** instantiate `tidelink_clkfreq_check` (built but un-wired — see 1.2); calibrator/lane_checker/autoneg are in the submodule, not top | Verilator strict-lint gate clean (`feat/verilator-lint-gate cb103ce`) |
| `tidelink_fifo` (+ `_ctrl`/`_mem`/`_ahb`/`_apb_regs`/`_returner`) | `src/rtl/fifo/*` | ✅ functional, UVM-covered (lane-mask, addr-translate, bidirectional suites) | ⚠️ design limitations, not bugs: single packet in-flight, no credit-underflow saturation, no `hresp=ERROR` on overrun/underrun, no burst tracking (SHORTCOMINGS.md #1–#14) | clean |
| `tidelink_fc_adapter` | `src/rtl/tidelink_fc_adapter.sv` | ✅ four-AHB-interface FC node; `ahb_tx_hreadyout` skid-grant logic (line ~201) | `ahb_mng_hready` direction (slave→manager) is a known-and-fixed earlier-RTL hazard | clean |
| `tidelink_addr_translator` (+ `tl_addr_trans_cam`/`_regs`) | `src/rtl/tidelink_addr_translator.sv`, `tl_addr_trans_*.sv` | ✅ CAM-based aperture mapping, UVM `test_top_addr_translate` | — | clean |
| `tidelink_phy_align_calibrator` | `src/rtl/tidelink_phy_align_calibrator.sv` (instanced `axi_chiplet_controller.sv:1327`) | ✅ autonomous per-lane bit-slip FSM; `cal_done` proven on silicon (16/16 at `72c280b`) | ⚠️ `MAX_RESWEEPS=0` (single-shot/free-run, see 1.2); two `unique case` (lines 409, 541) — the structural-safety rewrite `4504861` is **NOT on main** (confirmed: `4504861` is not an ancestor of `main`); cocotb TB port-drift (Bug #30) blocks its unit bench | HAL cosmetics fixed `e412289` (Bug #16) |
| `tidelink_lane_checker` | `src/rtl/tidelink_lane_checker.sv` (instanced `axi_chiplet_controller.sv:1305`) | ✅ 8× single-lane training-pattern lock detectors | — | clean; HAL `LOCAL_LINK_STATE_W` rename `2b5b6e5` (Bug #9) |
| `tidelink_clkfreq_check` | `src/rtl/tidelink_clkfreq_check.sv` | ✅ module exists (dual-counter + Gray-CDC), has a unit cocotb bench | ❌ **NOT instantiated in `tidelink_top`** — built as a guard but un-wired; no APB build-ID register yet | clean |
| `tidelink_idelay_rx` / `tidelink_rxclk_buf` | `src/rtl/tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv` | ✅ the FPGA lane-lock fix lives here (BUFG + per-lane IDELAYE2) | ⚠️ `USE_CLKBUF`/`USE_IDELAY` default **OFF** at module level → the enabled (FPGA) path is **never sim-exercised** for elaboration/lock behaviour | clean |
| `tidelink_ptp` / `_ptp_servo` / `_phc_cdc` | `src/rtl/tidelink_ptp*.sv`, `tidelink_phc_cdc.sv` | ✅ single-phase PTP over a dedicated FC node, cocotb + UVM (`tidelink_ptp_stress`) passing | ⚠️ PTP TX idle-gating wait is unbounded under heavy link traffic (SHORTCOMINGS #16); silicon PTP not yet validated | clean |
| `tidelink_perf` | `src/rtl/tidelink_perf.sv` | ✅ APB-readable BW/latency counters | Bug #23 (`R7_DBG_LINK_STATUS` 33→32-bit truncation) fixed on `fix/perf-width-truncation cb2cd26` — **fold-in to main pending** | Verilator gate found it |
| Submodule Wlink / `WavD2DGpio*` / `axi_chiplet_controller` / `tidelink_autoneg` | `deps/axi-chiplet-controller` @ `2f602d1` | ✅ Wlink (Chisel-generated), GPIO D2D PHY, autoneg FSM; autoneg silicon-validated earlier (master-win CLAIM→POLL); submodule HEAD carries Bug #3 structural fix (`2f602d1` "add default to outer case(state_r)"), Bug #4 chain (`865d15c`/`f27f54e`) | ⚠️ autoneg mask-FSM states 8/9/10 not ILA-validated on silicon; `test_top_autoneg_basic` A→B traffic doesn't carry post-role-lock (SHORTCOMINGS #14b, deferred) | latches #1/#2 fixed (`467b889`/`be5eed2`); 3rd-party-IP lint allow-listed `7316a5f` |

### 1.2 Outstanding RTL work

- **`clkfreq_check` not integrated** — `src/rtl/tidelink_clkfreq_check.sv` exists
  with a unit bench but is not instantiated in `tidelink_top` and there is no APB
  build-ID register. This is the permanent guard against the wrong-bitstream /
  clock-mismatch class that cost the multi-day lane-lock rabbit hole. (Freeze
  job #10.)
- **Calibrator `MAX_RESWEEPS=0`** — `tidelink_phy_align_calibrator.sv:179`. Zero
  means "never exhausts, retry while role_locked" (single-shot per external
  trigger but free-running re-arm). The 16/16 determinism at `72c280b` was
  achieved with this default; whether single-shot vs a bounded converge count is
  the right v1 behaviour should be a conscious freeze decision (the `resweep_ctr`
  / `retry_exhausted` plumbing at lines 394–501 is present but inert at 0).
- **Calibrator `unique case` synth-safety NOT folded** — the structural fix
  `4504861` ("replace `unique case` with `case`+default; remove cross-process
  blocking assigns") is **confirmed not on main** (`git merge-base --is-ancestor`
  = false; `unique case` still present at lines 409 and 541). `unique case`
  without a default arm is a synth-prune / sim-vs-synth divergence hazard of the
  same class as the latch bugs (#1/#2) that bit silicon. **Decide: fold `4504861`
  or accept the risk** before freeze.
- **`USE_CLKBUF`/`USE_IDELAY` parameter discipline** — these default OFF for
  bit-exact passthrough (sim/ASIC/UVM elaborate no Xilinx primitive) and are
  enabled only in the FPGA wrapper. They are present on `main`
  (`fpga/vivado_ip/tidelink_vivado_wrapper.v`, both `fpga/targets/*/tidelink_design.tcl`,
  `src/rtl/tidelink_idelay_rx.sv`, `src/rtl/tidelink_rxclk_buf.sv`). The discipline
  rule (do not strip these — `51b5169` did and caused the 0/16 regression) must
  be carried forward; the FPGA path is never sim-exercised, so a regression on
  the enabled branch is invisible to simulation today.
- **Bug #23 fold-in** — `perf_reg_rdata` truncation fix (`cb2cd26`) needs folding
  to main + `R7` readback confirmation once a build exists.
- **Bug #30** — calibrator cocotb TB references `dut.resweep_ctr`, a signal the
  RTL does not expose; the T3 re-sweep property is currently un-asserted.
- **Latch / synth-prune residual risk**: latches #1/#2 fixed; the open items of
  this class are the calibrator `unique case` (above) and the OFF-path of
  `USE_CLKBUF`/`USE_IDELAY` never being elaborated in sim. Verilator strict-lint
  gate (`cb103ce`) is in place; a ≥5.x upgrade for LATCH/MULTIDRIVEN is a
  post-freeze item.

### 1.3 RTL-freeze gating (cross-ref `RTL_FREEZE_CHECKLIST.md`)

**The central freeze gap:** no single branch today carries BOTH (a) the
`USE_CLKBUF`/`USE_IDELAY` lock fix AND (b) the full set of RTL bug-fixes, built
and HW-validated together. The 16/16 build (`72c280b` / sub `17160eb`) *predates*
most bug-fixes (made 05-21/05-22 off `57c2810`); the bug-fix lineage had the lock
fix stripped by `51b5169`. Unifying these onto one branch, rebuilding, and
re-validating 16/16 on hardware **is** RTL freeze. Gating items per the checklist:
unify branch (#1), clean-netlist rebuild (#2), HW 16/16 (#3), Bug #30 (#4), Bug #22
UVM regression run (#5), missing sim tests / gates on unified branch (#6), Bug #3
ILA silicon check (#7), Bug #4 re-validate on locking build (#8), AHB e2e on HW
(#9), `clkfreq_check` integration (#10), full regression green (#11),
reproducibility proof (#12), freeze tag (#13).

**RTL status: NOT frozen.** Functionally mature and broadly verified; gated on
the unify-and-re-validate work above.

---

## 2. FPGA implementation status

### 2.1 Build-flow maturity

| Element | Status | Detail |
|---|---|---|
| Vivado msg-gate | ✅ solid | `57c2810` — fail-fast on the silent-XDC-drop CRITICAL-WARNING class (the exact failure mode that hid the lane-lock regressor for days). |
| Declarative XDC | ✅ solid | `c6375eb` rewrote the XDC to pass the msg-gate; `94d5f99` fixed two latent constraint bugs (the `lindex`/`CNTVALUEIN` issues) surfaced by the gate on both targets. |
| `FPGA_USE_IDELAY` gating | ✅ solid | `USE_CLKBUF=1`/`USE_IDELAY=1` enabled in `fpga/vivado_ip/tidelink_vivado_wrapper.v`; 200 MHz IDELAYCTRL ref wired as clk_wiz CLKOUT3 → `tidelink_0/idelay_ref_clk` in both `fpga/targets/*/tidelink_design.tcl`. **This is the lane-lock fix.** |
| Farm build | ✅ working | `fpga/scripts/farm_build.sh` — parallel targets across srv04936 (rsync, no NFS); discipline rule ≤2 concurrent (Bug #18 OOM). |
| Deploy-provenance guard | ✅ solid | `deploy_pair.sh` SHA256-verifies the bitstream before flashing (`--expect-sha256`/`--check-only`); aborts on mismatch (closes the stale-`/tmp`-clobber class). |
| Artifact store | ✅ built | `feat/td-artifact-store` content-addressed immutable blobs, deploy-by-label, lock-history. |
| **Fragile / risk** | ⚠️ | the lock fix is RTL-resident and OFF by default — a future strip (à la `51b5169`) re-breaks 0/16 silently; the msg-gate now catches the *constraint* symptom but not the RTL-param strip. The enabled BUFG/IDELAY path has no sim coverage. |

### 2.2 Netlist sign-off (the `72c280b` / sub `17160eb` build)

✅ **Sign-off-clean and HW-validated.** Verified on the `bridge1` z2_02/z2_03 pair
2026-05-22 (per `LANE_LOCK_ROOT_CAUSE.md`):

- `Place 30-568` ("LUT driving clock pin") count = **0**
- **8× capture BUFG** (`gpiorx_0..7/g_clkbuf.u_cap_bufg`) + **8× IDELAYE2** + **2× IDELAYCTRL** in the netlist
- Post-route **WNS +0.409 ns / WHS +0.051 ns** (setup + hold both met)
- **16/16 bidirectional**, `cal_done=1` both dies — **100% deterministic** on the converge harness
- canonical bitstreams: master `tidelink.bin` MD5 `e2bd4d9f…`, slave `tidelink-flip.bin` MD5 `0f752a05…`
- Reliability baseline: 16/16 converge; one-shot historical mean ~14.8/16

### 2.3 Outstanding FPGA work

- **Bug #3 ILA mask-FSM silicon check** — instrument `state_r` (states 8/9/10) on
  a *locking* bitstream; 16/16 implies the mask phase ran (`cal_done=1`) but it
  was not state-instrumented. (Freeze gate.)
- **AHB end-to-end on HW** — now unblocked (link locks). **Board-wedge hazard:**
  never write `AHB_TX` (0x4400_0000) or ring the doorbell before the link is
  verified UP (bench-confirmed wedge 2026-04-27); all new AHB harnesses must gate
  on a verified-up check.
- **PTP single-phase silicon validation** — cocotb/UVM green; not yet on HW.
- **`FPGA_DEBUG_ILA` path** — needs wiring for the Bug #3 state trace (see the
  `insert_debug_core.tcl` gotchas in project memory: bracketed names, `u_ila_int`
  collision, BD-port clock).
- **XDC / timing tech-debt** — minimal; the declarative XDC + msg-gate hardened
  this. The lock fix being RTL-param-resident (not constrainable) is the residual
  structural fragility.
- **25 MHz rig vs 100 MHz ASIC target** — the FPGA pair runs at 25 MHz (alive at
  that rate); the v1 ASIC target is ~100 MHz GPIO PHY. Do not delete the
  `USE_CLKBUF`/`USE_IDELAY` paths; quarantine via param. The FPGA rig validates
  *functionality/protocol*, not the ASIC clock rate.
- **Deployed-bundle caveat** — the `release/v1.0-rc1` bundle currently on `bridge1`
  is the *stripped* (0/16) bitstream; the `72c280b` (or unified-freeze) bitstream
  must be built + deployed (provenance-verified) before any HW run.

**FPGA status: v1 functionally DONE and sign-off-clean at `72c280b`** (16/16,
timing met). Remaining items are the unified-branch rebuild (RTL-freeze coupled)
plus the silicon validation checks (Bug #3 ILA, AHB e2e, PTP).

---

## 3. ASIC implementation status

The ASIC flow is well-developed: the `tidelink_top` partition has been taken
through Fusion-Compiler PnR to a **GDSII hard macro** with a full chip-top
hand-off drop. Three commits on `main` carry the bulk: `6f50f5c` (end-to-end FC
PnR → GDSII), `6e904c6` (SoC-Labs tech_paths + TT corner + chip-top README +
INTEGRATION_CHANGES), `8109561` (library swap → TSMC tcbn65lp 9-track + Calibre
DRC/LVS scaffolding).

### 3.1 What exists

| Deliverable | Status | Source |
|---|---|---|
| FC PnR netlist + GDSII hard macro | ✅ | `syn/asic/fusion-compiler/` flow (`1_init`→`7_drc` scripts); GDSII staged at `imp/ASIC/tidelink_top_full/tidelink_top.gds.gz` |
| Chip-top hand-off drop | ✅ | `imp/ASIC/README.md` + `imp/ASIC/tidelink_top_full/` — `.v`/`.pg.v`/`.sdc`/`.def`/`.lef`/`.upf`/`.sdf`/per-corner SPEF (×8)/ETM/SVF/reports |
| Delivery manifest + QoR | ✅ | `v1-release/asic/MANIFEST_fusion_compiler.md`, `v1-release/asic/BINARIES.md` (binaries off-git, ~116 MB, SHA256 in CHECKSUMS) |
| TSMC tcbn65lp cell substitution | ✅ | submodule `2f602d1`: `5d01901` (sc12→TSMC65 ifdef `ASIC_TSMC65` wrappers), `d81934d` (WavDemet*/WavClockMux re-target to tcbn65lp 9-track), `61ab890` (2× BUF_X1M_A12TR hold-fix chain in WavDemet); `logical/wlink/tsmc/WavClockMux_tsmc65.v` |
| Library swap in FC flow | ✅ | `8109561` — `syn/asic/common.mk` + `tech_paths.tcl`: TARGET_LIB `tcbn65lpwc.db`, TF `tsmcn65_9lmT2.tf`, TLU+ `cln65lp_1p09m+alrdl_*`, LEF `tcbn65lp_9lmT2.lef` |
| Calibre DRC/LVS scaffolding | ⚠️ scaffolding only | `syn/asic/calibre/` (Makefile + `run_calibre_drc.sh`/`run_calibre_lvs.sh`/`emit_runsets.sh`) — decks/foundry runsets not wired (deferred) |
| Formality LEC | ✅ SUCCEEDED | `syn/asic/formality/` — strict gate exits `FM_LEC_OK`; iterative don't-verify of Wlink Chisel auto-gen DFFs (≈256–264 residual), all downstream cones verify |
| PrimeTime ETMs | ✅ | `syn/asic/primetime/scripts/extract_etm.tcl` — slow (rcworst @125 °C) + fast (rcbest @ -40 °C) `.lib`/`.db` in `imp/ASIC/tidelink_top_full/etm/` |
| UPF / power intent | ✅ | single-domain `.upf` (PD_TOP, VDD 1.08 V / VSS 0 V) in the drop; submodule carries `axi_chiplet_controller.upf` (TSMC 28 dirs also present) |
| DFT | ⚠️ minimal | `scan_clk` declared as an async clock group in the partition `.sdc`; no dedicated scan-insertion/ATPG doc in this repo |
| Gate-level UVM (GATE=1) | ⚠️ partial | `uvm/tidelink_top_system/Makefile` GATE path runs the flattened FC netlist with a probe-free auto-derived `top_gate.sv`; **runs to `$finish`** but **OPEN**: A→B datapath delivers all-zeros at gate (zero-delay / no-SDF X-pessimism through Wlink Chisel CDC+demet; `+vcs+initreg+0` insufficient). LEC is the trusted equivalence proof |

### 3.2 QoR snapshot (`v1-release/asic/MANIFEST_fusion_compiler.md`)

| Metric | Value |
|---|---|
| Total cell area | **477 710.71 μm²** |
| Macros | 1 × rf_16k (312 × 285 μm), pinned bottom-right |
| Core utilisation / aspect | 0.70 / 1.0 |
| Primary clock `hclk` | 4.0 ns / **250.0 MHz** |
| Setup WNS / TNS (slow) | **−0.00 ns / −0.01 ns** (essentially closed) |
| Hold WNS (fast) | **0.00 ns** |
| Net DRC violations (in-block) | **0** |
| Route DRCs (`check_routes`) | **9** EOL-spacing residual (down from 99 via 3-pass route_eco) — chip-top ECO or foundry waiver |
| PG floating cells | ~4 622 — **PASS\*** (characterised trim:true stub artefact, 0 logical floats; `pg_deepdive.tcl`) |
| Formality LEC | **PASS** (18 531 / 0 / 0 / 0 verified; Wlink Chisel DFF residuals don't-verified) |

Note the manifest QoR was generated against `sc12_base_rvt` (the original Arm
12-track library); commit `8109561` then swapped the flow to TSMC `tcbn65lp`
9-track. **A QoR re-run on tcbn65lp is the open verification of the swap** (see 3.3).

### 3.3 Outstanding ASIC work

- **Foundry sign-off DRC/LVS** — deferred. The flow ships scaffolding
  (`syn/asic/calibre/`) but the foundry cln65lp deck / runsets are not wired.
  Explicitly listed as "NOT YET RUN, for tape-out" in `imp/ASIC/README.md` §8:
  ICV DRC, LVS, IR-drop/EM (RedHawk/Voltus), full SI delta-delay.
- **sc12 → tcbn65lp library re-run** — the QoR numbers in the manifest are the
  sc12_base_rvt build; the tcbn65lp swap (`8109561` + submodule cell-sub) needs a
  full PnR re-run to re-confirm area/timing/DRC on the foundry library before the
  drop is the production deliverable.
- **9 EOL route DRCs** — structural at this util/floorplan; need chip-top ECO at
  top-level assembly or a foundry waiver.
- **LEC don't-verify residuals** — ≈256–264 Wlink (FCSM / Chisel auto-gen DFF)
  points iteratively don't-verified. All downstream cones verify; `FC_PRESERVE_WLINK_FCSM=on`
  eliminates them at an area cost. Same pattern as the ahb_qspi reference partition.
- **Chip-top assembly / integration** — the partition is delivered as a hard
  macro; actual chip-top FC integration (place the block, propagate the 5 clocks
  `hclk`/`phc_clk`/`user_ref_clk`/`scan_clk`/`pad_clk_rx` + 3 async resets, merge
  the foundry library GDS at LVS) is downstream and not done here.
- **Hard-IP** — pads, PLL, SRAM, delay cells: the partition uses the rf_16k SRAM
  macro; pads/PLL/delay-cell hard-IP integration is a chip-top responsibility and
  outside the partition drop.
- **Gate-sim (GATE=1 UVM)** — runs but the A→B all-zeros X-pessimism issue is
  OPEN; needs SDF back-annotation (the per-scenario SDF is in the drop) and/or a
  better X-init strategy to add value beyond LEC. Currently LEC is the equivalence
  authority.
- **Clock-rate target** — partition closed at 250 MHz `hclk`; the v1 chiplet GPIO
  PHY runs ~100 MHz on ASIC (FPGA rig 25 MHz). The PHY path timing at the ASIC
  rate is covered by the TSMC cell-sub hold-fix work (`61ab890`) but not yet
  silicon-characterised.

**ASIC status: partition PnR-COMPLETE through GDSII + LEC-clean + ETM-produced**,
delivered as a chip-top hard macro. **NOT tape-out-ready**: foundry DRC/LVS/IR/EM
sign-off deferred, tcbn65lp QoR re-run pending, chip-top assembly downstream.

---

## 4. Cross-domain maturity matrix + path to production

### 4.1 Maturity matrix (feature/block × domain)

| Feature / block | RTL | FPGA-validated | ASIC-implemented |
|---|---|---|---|
| FIFO datapath (ctrl/mem/ahb/apb/returner) | ✅ mature, UVM-covered | ⚠️ AHB e2e on HW pending (wedge-gated) | ✅ in partition netlist/GDSII |
| FC adapter (4× AHB) | ✅ | ⚠️ via AHB e2e | ✅ |
| Address translator (CAM) | ✅ | ⚠️ HW CAM-coverage pending | ✅ |
| PHY align calibrator | ✅ (`unique case`/`MAX_RESWEEPS=0`/Bug #30 open) | ✅ `cal_done=1`, 16/16 | ✅ (TSMC cell-sub) |
| Lane checker | ✅ | ✅ 16/16 | ✅ |
| `clkfreq_check` | ⚠️ built, **un-wired in top** | ❌ not in build | ❌ not in partition |
| Wlink / GPIO D2D PHY (submodule) | ✅ autoneg silicon-proven earlier | ✅ 16/16 link, ⚠️ Bug #3 mask not ILA'd | ✅ tcbn65lp cell-sub + hold-fix; LEC don't-verify residuals |
| Autoneg FSM | ✅ (Bug #3/#4 fixes on submodule `2f602d1`) | ⚠️ mask states 8/9/10 not ILA-validated | ✅ |
| PTP (ptp/servo/phc-cdc) | ✅ cocotb+UVM | ❌ silicon not validated | ✅ in netlist |
| Perf counters | ⚠️ Bug #23 fix fold-in pending | ❌ (debug reg, never deployed) | ✅ |
| `USE_CLKBUF`/`USE_IDELAY` lock path | ✅ on main, OFF-default | ✅ enabled, 16/16 | n/a (FPGA-only; ASIC = passthrough) |
| Lane-lock (overall) | ✅ root-caused | ✅ **SOLVED 16/16** (`72c280b`) | n/a |
| Chip-top assembly | n/a | n/a | ❌ downstream |
| Foundry DRC/LVS/IR/EM | n/a | n/a | ❌ deferred |

### 4.2 Prioritized path to production

**(a) To RTL freeze** (gating; full bug-level list in `RTL_FREEZE_CHECKLIST.md` §C):
1. Unify one branch with BOTH `USE_CLKBUF`/`USE_IDELAY` (un-strip `51b5169` /
   rebase onto `72c280b`+sub `17160eb`) AND the bug-fixes (#1/#2, #3, #4, #9, #23,
   #16). **The core gate.**
2. Decide + apply the calibrator `unique case` structural fix (`4504861`, not on
   main) and the `MAX_RESWEEPS` policy.
3. Integrate `tidelink_clkfreq_check` + APB build-ID into `tidelink_top`.
4. Fix Bug #30 (calibrator TB port drift); run Bug #22 UVM regression green.
5. Rebuild → clean netlist (Place 30-568=0, 8 BUFG+8 IDELAYE2, WHS>0) → HW 16/16.
6. Silicon checks: Bug #3 ILA mask states, Bug #4 re-validate, AHB e2e on HW.
7. Full regression green (cocotb+UVM+HAL+Verilator+sv_anti_pattern) →
   reproducibility proof → **freeze tag** + canonical SHA256s.

**(b) To FPGA v1 done:**
- Build + provenance-deploy the unified-freeze (or `72c280b`) bitstream to
  `bridge1`; confirm 16/16 (already proven at `72c280b`).
- Bug #3 ILA mask-FSM state trace on a locking bitstream.
- AHB end-to-end on HW (verified-up gate, AHB_TX wedge safety).
- PTP single-phase silicon validation.
- (FPGA functionally done at 25 MHz; rate is rig-specific, not the ASIC target.)

**(c) To ASIC tape-out readiness:**
- Re-run PnR + QoR on TSMC `tcbn65lp` (confirm area/timing/DRC post library swap).
- Foundry sign-off: Calibre/ICV DRC, LVS, IR-drop/EM (RedHawk/Voltus), full SI —
  wire the foundry cln65lp deck into the `syn/asic/calibre/` scaffolding.
- Resolve the 9 EOL route DRCs (chip-top ECO or waiver); decide on the LEC
  Wlink-FCSM don't-verify residuals (`FC_PRESERVE_WLINK_FCSM=on`).
- Gate-sim: SDF-annotated GATE=1 UVM to clear the A→B X-pessimism, or accept LEC
  as the equivalence authority of record.
- Chip-top assembly: integrate the hard macro (5 clocks / 3 async resets / single
  PD), merge foundry library GDS, hard-IP (pads/PLL/SRAM/delay) at top.
- Characterise the ~100 MHz ASIC PHY rate (vs the partition's 250 MHz `hclk` and
  the FPGA rig's 25 MHz).

### 4.3 Headline

- **RTL:** functionally mature, broadly verified — **NOT frozen** (unify-and-revalidate gap).
- **FPGA:** **v1 sign-off-clean and HW-validated 16/16** at `72c280b` (WNS +0.409 / WHS +0.051); residual silicon checks + unified rebuild remain.
- **ASIC:** **partition complete through GDSII + LEC + ETM**, delivered as a chip-top hard macro — **NOT tape-out-ready** (foundry DRC/LVS/IR/EM deferred, tcbn65lp QoR re-run pending, chip-top assembly downstream).

---

## Addendum A — RTL optimisation and CDC work (2026-05-23)

The following items were completed in the 2026-05-22/23 analysis session:

### RTL fixes applied (commits pending)

| Fix | File | Change |
|---|---|---|
| Calibrator mux merge | `src/rtl/tidelink_phy_align_calibrator.sv` | Two-level `phase_offset` mux chain merged to single 3-input select; removes intermediate wire flagged by CDC tools |
| CAM priority encoder | `src/rtl/tl_addr_trans_cam.sv` | Ascending `!found` guard replaced with descending overwrite; allows parallel priority mux tree synthesis |
| Lint Makefile | `cocotb/lint/Makefile.synth` | Removed `tidelink_addr_translation.sv` (unused alternative — was accidental synthesis inclusion risk) |
| Alt-impl header | `src/rtl/tidelink_addr_translation.sv` | Marked as alternative (not active) with CAM area comparison |

### New analysis documents

| Document | Content |
|---|---|
| `docs/CDC_AUDIT_REPORT.md` | Full CDC audit: 2 quasi-static violations on `swi_phase_offset` (hclk/link_clk → pad_clk_rx); all Wlink-internal crossings found correct. Action plan: `set_false_path` waivers + SVA assertion |
| `docs/RESET_DISTRIBUTION_PLAN.md` | Reset tree analysis: AASD pattern is correct given integration contract; items to close = port documentation, `set_max_fanout` in DC script, SpyGlass reset run, ICG DFT audit |
| `docs/PHY_LAYER_ABSTRACTION.md` | PHY separation plan: updated §9 with "still needed?" evaluation — Phase 1+2 high value before next ASIC run |
| `docs/RTL_OPTIMISATION_ANALYSIS.md` | ASIC-primary optimisation analysis (FPGA Vivado timing used as proxy) |
| `docs/REPO_SIMPLIFICATION_ASSESSMENT.md` | Repository tidying guide (dead code, doc consolidation, structure) |

### ASIC pre-tapeout items added by this session

Added to the §4.2(c) tape-out list:
- Run SpyGlass CDC; apply `set_false_path` waivers for `swi_phase_offset` and `role_locked`; add SVA quasi-static assertion (CDC_AUDIT_REPORT.md §6)
- Add integration contract comment to `tidelink_top.sv` reset ports; verify `set_max_fanout` in DC synthesis script (RESET_DISTRIBUTION_PLAN.md §4)
- ICG DFT test-enable audit for `wav_latch_model.sv` cells (RESET_DISTRIBUTION_PLAN.md §4.4)

---

## Addendum B — branch fold-loop + reliability correction (autonomous closeout)

**Branch consolidation:** local branches 62 → 9. Deleted 28 folded + the
already-folded `feat/td-asic-determinism-docs` + 3 throwaway experiments
(`slow-clock-obs` 12.5 MHz, `td-bisect-a2-out` IDELAY-disable,
`worktree-agent-acec76b…` pin-swap diag).

**Calibrator fold (Bug #7, commit `a0df658`):** folded ONLY the synth-safety
change `unique case` → `case`+default (both calibrator FSM case statements
already have explicit defaults; `nxt_state` defaults to `cur_state`). The
regressive parts of `fix/calibrator-structural` (`4504861`) were REJECTED — it
predates the best-of-sweep calibrator and would have dropped the per-lane
`phase_offset_internal` / sweep-live path that drives IDELAY for lane lock.
The folded build's bitstream is **byte-identical** (md5 `976341f1`/`06d6a29a`,
sha256 `df0c5dbb`/`eb89d5ac`) to the validated build, confirming the change is
synth-neutral (zero netlist impact). HW: converges 16/16 (iter 1).

**Reliability characterization correction:** the FPGA build **converges to
16/16 deterministically** (closed-loop `bringup_pair_converge.sh`, reached at
iteration 1 in every run). The **single-shot, no-retry** rate has run-to-run
lottery variance (role_lock/count skew): observed means 14.80 / 15.05 / 16.00 /
15.30 across N=20/20/20/10 sweeps of byte-identical bitstreams; perfect-16/16
single-shot 20–100% per run. Earlier wording of "100% deterministic single-shot"
referred to one favourable N=20 run and is corrected here: deterministic =
converge-with-retries; single-shot = high-but-variable.

**Deferred unique-unmerged branches (not folded):**
- `feat/i2c-autonomous-lock` / `-integ` — autoneg core (`tidelink_autoneg.sv`,
  ST_TRAIN FSM) is already on main (submodule `2f602d1`); the branches are
  entangled pre-consolidation lineage, not cleanly separable. Functional gap
  audit pending before deletion.
- `feat/v1.1-fixes` — superseded (its only genuinely-unique piece was
  calibrator-structural, now folded); deletable.
- `fix/bug10-sv-anti-pattern-allow-list` — target lint files
  (`cocotb/lint/Makefile`, `sv_anti_pattern_lint.py`) were removed from main in
  consolidation; needs the lint tooling reintroduced or the allow-list
  re-authored before it can be folded.

# TideLink — Outstanding Work Report

Generated 2026-05-22. Companion to `docs/BUG_TRACKER.md`,
`docs/RTL_FREEZE_CHECKLIST.md`, `docs/LANE_LOCK_ROOT_CAUSE.md`,
`docs/SHORTCOMINGS.md` and `cocotb/VERIFICATION_PLAN.md`.

Content is read from the consolidated `main` branch (origin/main @ `35d248e`,
docs current to commits `bf203a8` / `5a9312a`). The working tree is checked out
on `release/v1.0-rc1`, which is the *pre-fix* lineage and intentionally lacks the
`USE_CLKBUF`/`USE_IDELAY` lane-lock fix — do not read RTL state from the working
tree.

**Headline status (per `LANE_LOCK_ROOT_CAUSE.md`):** the multi-day "0/16
lane-lock regression" is root-caused and *solved*. The regressor was commit
`51b5169`, which stripped the `USE_CLKBUF`/`USE_IDELAY` RTL clock-structure fix
from the FPGA build path. A reproducible **16/16** build exists at parent
`72c280b` + submodule `17160eb` (WHS +0.051 ns, 8 BUFG + 8 IDELAYE2 in netlist,
verified on the `bridge1` z2_02/z2_03 pair). The earlier "ribbon damage" (Bug
#28) and "srv04936 env regression" (Bug #25) narratives in the body of
`BUG_TRACKER.md` are **superseded / disproven** by the freeze-checklist update —
they were commit/bitstream/provenance confusion masking the one missing RTL fix.

**The central freeze gap:** no single branch today carries BOTH (a) the
`USE_CLKBUF`/`USE_IDELAY` lock fix AND (b) the full set of RTL bug-fixes,
built and HW-validated together. The `72c280b` 16/16 build *predates* most of
the bug-fixes (made 05-21/05-22 off `57c2810`), and the bug-fix lineage had the
lock fix stripped. **Unifying those two onto one branch, rebuilding, and
re-validating 16/16 on hardware is the core of RTL freeze.**

---

## 1. Outstanding bugs + fixes needed

Legend: gating = blocks RTL freeze; non-gating = can land post-freeze.

### RTL-freeze-gating

| # | Bug | RTL fix? | Sim? | HW? | Remaining action | Risk | Gate |
|---|---|---|---|---|---|---|---|
| **CLKBUF** | GPIO-PHY recovered capture clock on a LUT-driven net (no `USE_CLKBUF`) → `Place 30-568`, hold violated, `cal_done=0`, 0/16. **THE lane-lock root cause.** Fix lives in `fpga/rtl/tidelink_idelay_rx.sv`, `fpga/rtl/tidelink_rxclk_buf.sv`, `WavD2DGpioRx.v` (submodule `17160eb`) + the FPGA wrapper enables (`fpga/vivado_ip/tidelink_vivado_wrapper.v`, `fpga/targets/*/tidelink_design.tcl`). Stripped by `51b5169`; present & enabled at `72c280b`. | ✅ at `72c280b` | ⚠️ params default OFF in sim (bit-exact passthrough); the BUFG/IDELAY path is FPGA-only and is **never sim-exercised** for elaboration/lock behaviour | ✅ `72c280b` = 16/16 | Re-apply / un-strip onto the freeze branch and never let it drop again. The Vivado msg-gate (`57c2810`) now fails-fast on the silent-drop CRITICAL WARNING class. | HIGH — this is the lock. A regression here = 0/16. | **GATE** |
| 3 | Mask-FSM states 8/9/10 (`ST_NEGO_MASK_RES_TX`/`RD_ADDR`/`RD_DATA`, `deps/.../top/tidelink_autoneg.sv:132-134`) reported skipped on silicon | ✅ candidate sub `6a757e2` (default `state_nxt` arm) | ✅ cocotb `cocotb/tidelink_autoneg/test_tidelink_autoneg.py` asserts the master-win `4→9→10→8→5` flow (33/33); UVM `uvm/tidelink_top_system/tests/test_top_peer_mask_*` cover the mask handshake | ⚠️ **NOT ILA-validated.** `72c280b` 16/16 implies the mask phase ran (`cal_done=1`) but was not state-instrumented | Instrument `state_r` on an ILA on a *locking* bitstream; confirm 8/9/10 are entered on silicon | MED — sim+lock are strong circumstantial evidence; needs explicit confirmation | **GATE** |
| 4 | Mask-FSM defensive (`busy_seen_nxt`, `peer_lane_mask`) | ✅ sub `9b43676`+`a30b21b` | ✅ cocotb | ⚠️ tested in Exp F but on a **0/16** bitstream → meaningless | **Re-validate on the locking (16/16) build.** | LOW — silicon-neutral-or-helpful by construction | **GATE** |
| 22 | UVM tests stale vs 2-word FIFO header → 5 CI reds (credit-count, FC-TX scoreboard race, AHB `zero_wait_cycle_okay`). Root cause = test/RTL header-width drift (`packet_delta = length + 2`, `src/rtl/fifo/tidelink_fifo_ctrl.sv:89`), **not** a mask-FSM defect (original hypothesis wrong) | ⚠️ sim-only TB fix on `fix/bug22-uvm-mask-strobe-fsm @ 7ab9806` (10 UVM files updated to `length + 2`) | ❌ regression run **pending** | n/a (test issue) | Run the UVM regression; confirm the 5 reds clear, or land remaining TB/RTL fix | LOW–MED — a red CI suite blocks a clean freeze sign-off | **GATE** |
| 30 | `tidelink_phy_align_calibrator` TB/RTL port drift — `cocotb/tidelink_phy_align_calibrator/test_calibrator_t3.py` reads `dut.resweep_ctr`, a signal the RTL (`src/rtl/tidelink_phy_align_calibrator.sv`) does **not** expose (RTL has `MAX_RESWEEPS` param but no `resweep_ctr` reg/port; ports end at `state[3:0]`) | ❌ | ❌ TB cannot run as written | n/a | Either expose `resweep_ctr` as an ILA-visible output, or rewrite the test to assert on observable outputs (`training_mode`/`state`) | LOW — isolated unit TB, but the T3 re-sweep property is currently **un-asserted** | **GATE** (verification coverage) |
| 23 | `perf_reg_rdata` 33→32-bit truncation in `R7_DBG_LINK_STATUS` (silent `fc_rx_valid` drop), `src/rtl/tidelink_perf.sv` | ✅ `fix/perf-width-truncation @ cb2cd26` | ✅ Verilator-clean (gate found it) | ❌ debug reg, never on a deployed build | Fold into the unified branch; confirm via `R7` readback once a build exists | LOW — debug-only register | **GATE** (fold-in only) |

### Non-gating (resolved or post-freeze)

| # | Bug | Status | Note |
|---|---|---|---|
| 1, 2 | `nego_driving` / `txn_step_nxt` latches | ✅ sub `467b889` / `be5eed2` | Class-A latches, silicon-validated (earlier autoneg) — must be carried into the unified branch |
| 9, 16, 7 | HAL `LOCAL_LINK_STATE_W` rename / calibrator HAL cosmetics / unique-case | ✅ `2b5b6e5` / `e412289` / `4504861` | lint/cosmetic; #7 moot on current HEAD (calibrator already simple-FSM) |
| 5, 25 | "0/16 across rebuilds" / "srv04936 env regression" | 🧊 superseded | Both were the CLKBUF strip; freeze-checklist reframes #25 as "commit, not env" (`8bc6051` builds 0/16 on clean srv03335 too) |
| 28 | "post-cycle ribbon HW damage" | 🧊 disproven | `tl_v7` 13/16 pre+post cycle — HW was fine; the all-zero fingerprint was the stripped fix |
| 6, 8, 10, 11, 12/13/14, 17, 18, 19, 20, 21, 24, 31/33, 32, 34 | XDC, overlay.py, lint allow-list, CI, deploy/converge/watcher robustness, OOM/`/tmp` discipline, cocotb silicon-replication, Verilator gate, watcher paths, bundle/provenance guards | ✅ resolved | Infra/process — see `BUG_TRACKER.md`. Verilator ≥5.x for LATCH/MULTIDRIVEN is a post-freeze upgrade |

### Design shortcomings (not "bugs", but open RTL limitations — `docs/SHORTCOMINGS.md`)

These are catalogued, none currently gate freeze, but they are real and should
be on the v1.1/v2 backlog: (1) **no credit underflow protection** in
`tidelink_fifo_ctrl.sv` (unsigned 13-bit counter can wrap on oversized packet);
(2) **single packet in-flight** (metadata at addr 0 overwritten); (3) **no HW
packet-size validation**; (4) **no AHB `hresp=ERROR` on overrun/underrun** (silent
sticky flag only); (5) **returner has no retry** on `hresp=1` → credit drift after
a transient bus error. Items (1) and (4) are the strongest candidates to harden
before tape-out.

---

## 2. Simulation tests that need adding

Existing coverage is broad: `cocotb/*` has 30+ unit/pair benches and
`uvm/tidelink_top_system/tests/` has ~40 tests including a full lane-mask suite
(`test_top_lane_mask_*`, `test_top_peer_mask_*`) and align suite
(`test_align_*`). The gaps below are what is *missing* or *broken*.

| Test (proposed name) | DUT / level | Asserts | Why it matters |
|---|---|---|---|
| **`test_clkbuf_idelay_elaborate`** | `WavD2DGpioRx` + `tidelink_rxclk_buf` + `tidelink_idelay_rx`, cocotb, `USE_CLKBUF=1`/`USE_IDELAY=1` | With params ON, the BUFG/IDELAYE2 generate-branches elaborate and produce bit-exact behaviour vs the OFF passthrough path on a known stimulus | The lock fix path is **default-OFF and never sim-exercised** (per CLKBUF row above + `cocotb/wavd2d_gpiorx_clkbuf/`, `cocotb/tidelink_rxclk_buf/`, `cocotb/tidelink_idelay_rx/` which only test the *passthrough/opt-out* side). A regression that breaks the ON path is invisible to sim today |
| **`test_idelay_tap_to_capture`** | `tidelink_idelay_rx`, cocotb | Calibrator `bit_slip`/tap drives the modeled IDELAY tap and the capture-clock relationship is sane across taps | Closes the "BUFG path never sim-exercised" half on the IDELAY side; `cocotb/phy_align/test_idelay_tap_wiring.py` checks wiring but not the enabled datapath behaviour |
| **`test_calibrator_t3_resweep`** (Bug #30 fix) | `tidelink_phy_align_calibrator`, cocotb | T3 continuous re-sweep + T3.2 S_HOLD via **observable outputs** (`training_mode`, `state`, `calibration_done`) — drop the broken `dut.resweep_ctr` reference | The T3 re-sweep property is currently **un-asserted** because the bench can't elaborate against the real ports |
| **`test_top_mask_fsm_state_trace`** | `tidelink_top` (autoneg in-loop), cocotb/UVM | FSM enters states 8→9→10 and the I2C sub-transaction byte counts (`MASK_RES_BYTES=6`, `MASK_RD_ADDR_BYTES=2`, `MASK_RD_DATA_BYTES=4`) fire in order; mirrors what the silicon ILA must show for Bug #3 | Gives a sim oracle the HW ILA check (Bug #3) can be compared against; extends `cocotb/tidelink_autoneg/test_tidelink_autoneg.py` |
| **`test_ahb_e2e_tx_to_fc_rx`** | `tidelink_top` full datapath, cocotb | AHB write into `ahb_tx` aperture → FC node → Wlink → peer FC RX → FIFO commit → readback through `ahb_fifo`, end-to-end | `cocotb/tidelink_top/test_tidelink_top.py` does single-word FC loopback but **not** the full XHB500+Wlink+FC chain; this is the sim mirror of the HW AHB storm and would catch datapath breaks before silicon |
| **`test_ahb_hready_direction`** | `tidelink_ahb` + `tidelink_fc_adapter`, cocotb | The `*_hready` (slave-driven `hreadyout`) vs `*_hready` (master-sampled) **direction** is correct on all four interfaces (`ahbs_/ahbc_/ahbm_/ahb_tx_`), incl. the `ahb_tx_hreadyout` skid-grant logic (`tidelink_fc_adapter.sv:201`) | Directly targets the `ahb_mng_hready` direction class of bug — an easy wiring inversion that sim must pin |
| **`test_clkfreq_check_integration`** | `tidelink_clkfreq_check` instantiated in `tidelink_top` + APB readback, cocotb | The dual-counter + Gray-CDC link-clock cross-check flags a mismatched/wrong clock and surfaces via APB; a build-ID register reads back | `src/rtl/tidelink_clkfreq_check.sv` exists with a unit bench (`cocotb/tidelink_clkfreq_check/`) but is **not yet instantiated in `tidelink_top`** (freeze-checklist job #10). This is the permanent guard against the wrong-bitstream/clock-mismatch class that cost the multi-day rabbit hole |
| **`test_synth_no_latch_no_xdc_drop`** (extend existing) | RTL elaboration + Verilator strict + XDC lint, cocotb gate | Zero inferred latches, zero MULTIDRIVEN, zero silently-dropped constraints across the **unified** branch | `feat/cocotb-robust-silicon-replication @ 8d27ebb` + `feat/verilator-lint-gate @ cb103ce` already implement the categories that *would have caught* the latch + silent-XDC-drop silicon-only defects; the action is to **run them on the unified branch**, not write new ones |
| **`test_credit_underflow_guard`** | `tidelink_fifo_ctrl`, cocotb | Writing a packet larger than `credit_count` does NOT wrap the counter (covers SHORTCOMINGS #1) | Pins a real RTL hazard; pairs with a potential RTL hardening |
| **`test_ahb_error_on_overrun`** | FIFO AHB slave, cocotb | `hresp=ERROR` (or documented silent-flag behaviour) on overrun/underrun (SHORTCOMINGS #4) | Locks in the chosen behaviour before tape-out |

UVM note: the lane-mask + align UVM suites are extensive already. The Bug #22
work is a **fix to make them pass** (header-width drift), not new tests — running
that regression green is the action.

---

## 3. Hardware stress testing to create

**Regression baseline / reference:** the freeze target is the `72c280b` build
(master `tidelink.bin` MD5 `e2bd4d9f…`, slave `tidelink-flip.bin` MD5
`0f752a05…`), confirmed **16/16 bidirectional, cal_done=1, WHS +0.051 ns** on
the `bridge1` z2_02/z2_03 pair (2026-05-22). The one-shot reliability reference
(historical, `bringup_reliability.sh` distribution) is **~14.8/16 mean**; any
stress regime must report against the 16/16-converge and ~14.8 one-shot numbers.

**Universal safety constraint (applies to every TideLink-layer test):**
**NEVER write `AHB_TX` (0x4400_0000) or ring the doorbell until the link is
verified UP** (lane-lock + `cal_done=1` + FCSM running). A premature `AHB_TX`
write wedges the board (bench-confirmed 2026-04-27, z2_02 went offline) —
documented in `deploy_pair.sh:29-40`, `wlink_probe.sh:38-46`,
`bringup_pair_converge.sh:56-59`. The existing `bringup_*.sh` harnesses are
"safe-ops only" by construction; new AHB harnesses must gate on a verified-up
check before any TX.

**Pre-req for all HW stress:** the link is *currently down on `bridge1`* in the
sense that the deployed v1-RC bundle is the stripped (0/16) bitstream. **Build
and deploy the `72c280b` (or unified-freeze) bitstream first**, confirm 16/16
via `bringup_pair_converge.sh`, and verify the deployed SHA via the provenance
guard (`deploy_pair.sh --expect-sha256` / `--check-only`) before any stress run.

### (i) Wlink layer

| Test | Goal | Method / harness | Pass criteria | Safety |
|---|---|---|---|---|
| **Link-up skew lottery** | Quantify cold-bring-up convergence vs role-lock/word-boundary skew | `bringup_reliability.sh` with `N_DEPLOYS=50–100`, re-rolling skew each deploy; no early-exit | Distribution mean ≥ ~14.8/16, 16/16-converge rate ≥ historical; FCSM-running on ≥1 side every iter | Safe-ops (no AHB_TX) |
| **Re-train under perturbation** | Confirm calibrator re-sweep (T3) recovers after a forced link drop | New `bringup_retrain_perturb.sh`: link up → toggle PHY/swreset or inject reset glitch → assert re-converge to 16/16 | Re-lock to 16/16 within bounded cycles; `cal_done` returns to 1 | Safe-ops |
| **Sustained traffic soak** | Stability under continuous Wlink packet flow | New `wlink_soak.sh`: after verified-up, drive sustained FC packets (small, via FIFO doorbell path) for hours | Zero lane-drop, zero CRC/ECC error counter increments, link stays at 16/16 | Verified-up gate before any TX |
| **Credit / FC backpressure** | Exercise FC credit exhaustion + recovery on silicon | Drive RX faster than peer drains; watch `WlinkGenericFCSM_*` credit state + FCSM-wedge fingerprint (`wlink_probe.sh` reports FCSM state, wedges at 1 on credit-path failure) | No FCSM wedge-at-1, credit accounting returns to full, no silent drop | Verified-up gate |
| **ECC/CRC error injection** | Validate error detect/report on the wire | `WlinkCrcGen_*` / `WlinkEccSyndrome.v` exist; inject bit-flips via lane-mask or PHY tap perturbation; read error counters | Errors counted and surfaced (not silently dropped); link recovers | Verified-up gate |
| **Lane-by-lane fault injection** | Confirm per-lane masking + degraded-mode operation | Use the lane-mask path (mirror of UVM `test_top_lane_mask_damaged_lane`); mask one lane at a time on HW, confirm degraded lock | Link degrades gracefully to N-1 lanes, masks the faulted lane, no full drop | Safe-ops (mask is APB) |
| **Long-soak link stability** | Multi-hour drift/jitter endurance | `wlink_soak.sh` extended to 8–24 h with periodic lock + counter sampling | No spontaneous lane drop, no counter creep, `cal_done` stays 1 | Verified-up gate |

### (ii) TideLink layer

| Test | Goal | Method / harness | Pass criteria | Safety |
|---|---|---|---|---|
| **AHB write/read storm through FC node** | Validate the AHB datapath end-to-end on silicon (freeze job #8) | New `tidelink_ahb_storm.sh`: verified-up gate → bursts of AHB writes to `ahb_tx` → peer FIFO commit → readback via `ahb_fifo`/returner | Data integrity 100%, no wedge, credits balance | **Verified-up gate is mandatory** (AHB_TX wedge hazard) |
| **Address-translation coverage** | Exercise `tl_addr_trans_cam` / `tidelink_addr_translator` mappings on HW | Program CAM entries via APB, send packets across the mapped apertures, confirm landing address (mirror of UVM `test_top_addr_translate`) | Every programmed mapping lands at the correct peer address; misses handled per spec | Verified-up gate |
| **FIFO fill/drain extremes** | Stress FIFO at full/empty boundaries (SHORTCOMINGS #1/#3 hazards) | Drive to overrun and underrun on HW; watch STATUS overrun/underrun + credit counter | No credit-counter wrap, sticky flags set correctly, no data corruption | Verified-up gate |
| **PTP sync stress** | Single-phase PTP convergence + hold under load | HW PHC `hw_capture` recipe (sim mirror = `uvm/tidelink_ptp_stress`, `cocotb/tidelink_ptp`); run sync under concurrent AHB traffic | Offset converges and holds within spec bound; servo stable under load | Verified-up gate |
| **Bidirectional simultaneous traffic** | Both dies driving AHB at once (mirror of UVM `test_top_bidirectional`) | Two-sided storm harness, both boards TX concurrently | No deadlock, no credit drift, integrity 100% both directions | Verified-up gate, both sides |
| **Throughput / latency characterization** | Measure achieved BW + round-trip latency vs theoretical | Instrument `tidelink_perf` counters (read via APB; note Bug #23 `R7` fix must be in the build) across packet sizes | Reproducible BW/latency curve; no `R7` truncation | Verified-up gate |
| **Thermal / long-duration soak** | Endurance + thermal margin | 8–24 h mixed AHB+PTP load; sample temp + lock + error counters | Zero lane drop / data error over the soak; no thermal runaway | Verified-up gate |

---

## 4. Prioritized roadmap

### Path to RTL FREEZE (each item gates the freeze)

1. **Unify the RTL branch** (freeze job #1). One branch with BOTH the
   `USE_CLKBUF`/`USE_IDELAY` lock fix (un-strip `51b5169` / re-base onto
   `72c280b` + sub `17160eb`) AND the RTL bug-fixes #1, #2, #3 (`6a757e2`),
   #4 (`9b43676`+`a30b21b`), #9 (`2b5b6e5`), #23 (`cb2cd26`), #16 (`e412289`).
   **GATE — this is the whole game.**
2. **Rebuild + clean-netlist check** (job #2): `Place 30-568 = 0`, 8 BUFG + 8
   IDELAYE2 present, post-route WHS > 0. **GATE.**
3. **HW-validate the unified branch = 16/16** on `bridge1` (job #3). Fixes must
   not regress lane lock. **GATE.**
4. **Fix Bug #30** (calibrator TB port drift) so `test_calibrator_t3` runs and
   the T3 re-sweep property is asserted. **GATE (cheap, do early).**
5. **Run Bug #22 UVM regression** → confirm 5 reds clear. **GATE.**
6. **Add the missing sim tests** that cover the silicon-only classes: CLKBUF/IDELAY
   ON-path elaboration, AHB e2e through XHB500+Wlink+FC, `ahb_hready` direction,
   and run the existing Verilator/silicon-replication gates on the unified
   branch. **GATE (coverage).**
7. **Bug #3 explicit ILA silicon validation** (job #4) on the locking bitstream:
   confirm mask-FSM states 8/9/10. **GATE.**
8. **Bug #4 re-validation** on the locking build (job #5). **GATE.**
9. **AHB end-to-end on HW** (job #8) — now unblocked once the link locks; respect
   the AHB_TX wedge hazard. **GATE.**
10. **Integrate `tidelink_clkfreq_check` + build-ID register** into `tidelink_top`
    + APB regs (job #10) — permanent guard against the wrong-bitstream/clock class.
    **GATE.**
11. **Full regression green** on the unified branch: cocotb + UVM + HAL +
    Verilator strict + sv_anti_pattern, all zero errors (job #11). **GATE.**
12. **Reproducibility proof** (job #12): a clean checkout of the frozen branch
    builds a 16/16 bitstream with no reliance on a preserved artifact. **GATE.**
13. **Freeze tag** (job #13): tag the unified, validated, reproducible commit;
    record canonical bitstream SHA256s. **GATE — the finish line.**

### v1.1 / v2 backlog (does NOT gate freeze)

- **HW stress program** (Section 3) beyond the freeze-gating AHB e2e + 16/16
  reliability run: Wlink error-injection, credit-backpressure, lane-fault,
  long-soak; TideLink throughput/latency characterization, FIFO extremes,
  bidirectional storm, thermal soak. (PTP single-phase HW validation, job #9,
  sits at the freeze/v1.1 boundary — do it if the link is up and time allows.)
- **RTL hardening** from `SHORTCOMINGS.md`: credit underflow saturation (#1),
  AHB `hresp=ERROR` on overrun/underrun (#4), packet-size validation (#3),
  returner retry (#5), multi-packet-in-flight descriptor ring (#2).
- **Tooling**: Verilator ≥5.x upgrade (LATCH/MULTIDRIVEN), CI integration
  phase-1 wiring, fpgahub CLI/daemon.
- **Protocol/feature**: TideChart dynamic chiplet-ID protocol, ASIC partition
  follow-through (Calibre signoff DRC/LVS deferred to chip-top assembly).
- **`td-artifact` content-addressed store** roll-out (already built on
  `feat/td-artifact-store`) to make stale-bitstream confusion structurally
  impossible.

---

## Quick roll-up

- **Lane lock: SOLVED & HW-validated** at `72c280b` (16/16). Root cause was
  `51b5169` stripping `USE_CLKBUF`/`USE_IDELAY` — not env, not ribbon.
- **RTL bug-fixes: mostly sim-validated, NOT yet HW-validated together with the
  lock fix.** Unifying them onto one branch + re-validating 16/16 is the freeze.
- **Open & gating:** CLKBUF carry-forward, Bug #3 (HW ILA), #4 (HW re-validate),
  #22 (UVM regression run), #30 (TB port drift), #23 (fold-in), plus the
  clkfreq-check integration and the missing CLKBUF/AHB-e2e/hready sim tests.
- **HW stress (Section 3)** is mostly v1.1/v2 backlog; only the 16/16 reliability
  re-run and AHB e2e are freeze-gating, both subject to the AHB_TX wedge safety
  rule and a verified-up gate.

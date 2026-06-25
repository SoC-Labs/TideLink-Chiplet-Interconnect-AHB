# Production RX Eyescan Integration — Design & Implementation Plan

**Status:** DESIGN / FOR REVIEW · 2026-06-25
**Goal:** make A→B (and therefore *sustained* bidirectional) delivery RELIABLE on the bridge1 V1 silicon pair, by giving the production RX a per-lane sample-point auto-calibration (the BIST's PRBS eyescan), which production currently has dead-wired OFF.
**Branch:** `fix/word-window` (worktree `td-bisect/v1-word-window`) · deployed die_b = `8ab846ba` · proven backup = `314bc0e6`
**Source:** synthesis of a 4-agent design pass (PRBS instrumentation · calibrator integration · cadence · verification/rollout).

---

## 1. Problem statement (what we proved overnight 2026-06-25)

- **The hardware is capable:** a clean bidirectional capture hit **B→A 12/12 AND A→B 12/12** on one good-phase POR, word_pin OFF. Bidirectional works.
- **But it is a per-POR lottery + the held link can lose lock:** across 4 PORs A→B was 15/15, 6/15, 1/6, 0/16; a "roll-until-bidirectionally-clean + hold" SW approach (`pynq_host/scripts/td_bringup_bidir.sh`) found clean PORs but they **degraded within ~1–2 min** (even a 3/3-each-way POR fell to B→A 0/10, A→B 4/10).
- **Root cause:** production free-runs the RX deserializer **sample phase**. Each POR lands on a random point across a marginal eye → on/off-eye lottery. The BIST eliminates this by sweeping each lane's sample point against a real per-lane BER and **pinning it on its eye centre** — production has the *same* calibrator but the eyescan is hard-tied OFF (`axi_chiplet_controller.sv:2770-2772`).
- **The SW roll-and-hold path is exhausted** (proven not robust); the RTL eyescan is the only robust fix.

## 2. The de-risking finding: a ONE-TIME park is sufficient

The cadence analysis resolved the critical question — **is one-time calibration enough, or do we need continuous tracking?** — in favour of one-time, with hard evidence:

1. The BIST's clean eye was a **one-time override park** (`exp_park_basin.sh` writes `BIT_SLIP_OVR`/`PHASE_OVR` once; `hold` mode only `errclr()`s, never re-writes) that **held at sustained ~9e-6 BER**.
2. The FPGA `phase_offset` is a **digital oversample-point selector** (`adj_count = count + io_phase_offset`, `WavD2DGpioRx.v:330`) — **not** an analog IDELAYE2 tap (`USE_IDELAY=0`; IDELAYE2 removed). There is **no voltage/temperature drift mechanism** in the parked path, and all lanes are frequency-locked (÷16 off one recovered `pad_clk_rx`).
3. The calibrator's `S_DONE` has **no background re-track** by design — yet the eye held.

⇒ Our SW-test "drift" was the **~15 re-POR churn** (marginal-eye lottery re-landing on different basins), **not inherent eye drift**. A one-time eye-centre park (which involves *no* re-roll churn) is stable.

**Cadence decision:** one-time eye-centre park at bring-up. **No** periodic timer re-cal (it would re-assert `training_mode`, drop the carrier, and starve the bilateral rendezvous — the FIX-H failure). Optional cheap safety net: a **rare, FC-coordinated, error-TRIGGERED** re-cal on a sustained CRC/PRBS-error burst (covers the unproven multi-hour-drift residual).

## 3. Architecture of the fix

Three additive pieces, **all gated behind a chicken-bit that is OFF at POR** so the build is bit-identical to the proven `8ab846ba` until armed:

```
  [die_a TX] --PRBS-15 (cal window)--> [die_b RX: 8x PRBS-15 checkers] --lane_synced[7:0]-->
        FIX-J eyescan in calibrator: sweep each lane's sample phase WITH PRBS live,
        pin each lane on confirmed lane_synced (FIX-L debounce), park at eye centre.
  (symmetric for B->A: die_b TX gen -> die_a RX checkers)
```

The eyescan FSM ("brain") already exists and is silicon-proven in the BIST; production simply never connected (a) a per-lane PRBS-sync source, and (b) the eyescan in the deployed calibrator.

## 4. Work items

### WI-1 — PRBS instrument in the production datapath  (~150–200 LOC, mostly reuse)
The deployed path produces only `lane_locked` (training-pattern lock), **not** per-lane PRBS sync. Source `lane_synced[7:0]` by reusing the BIST modules verbatim:
- Add `deps/tidelink-phy/rtl/tidelink_phy_bist_prbs.sv` to the flist (gen + checker; **0 new modules**).
- **TX:** mux the 128-bit PRBS-15 word onto the link TX during the calibration window — a *separate* path from the existing per-lane PRBS-7 *training* mux at `WavD2DGpioTx.v:254`. Insert in `axi_chiplet_controller.sv` (preferred, keeps the Chisel-derived PHY files clean) or `WlinkGPIOPHY.v:25`.
- **RX:** instantiate the 8× `tidelink_phy_bist_prbs_check` generate-loop (copy `tidelink_phy_bist_core.sv:994-1022`) on the post-deskew word `phy_link_rx_rx_link_data_w[16*L +: 16]` (the bus the lane_checker already taps, `:2591`), clocked on `rx_link_clk` → `lane_synced_w[7:0]`.
- **⚠ The one real hazard — clock domain:** the generator MUST advance on `link_tx_tx_link_clk` per accepted beat, **never hclk** (hclk decimates PRBS to garbage while a constant training word survives — the historical "training locks, payload never syncs" trap). Copy the BIST CDC exactly (`tidelink_phy_bist_core.sv:875-888, 966-992`).
- **Cal window:** `cal_window = (cal_state == S_VALIDATE) & ~cal_done`. S_VALIDATE already drops `training_mode` and runs *before* `calibration_done` gates FC traffic, so **PRBS never collides with live data by construction**. Optionally also expose an APB `CAL_PRBS_EN` strap for on-silicon BER/winscan debug.
- **Symmetry:** each die needs a TX gen + 8 RX checkers (A→B uses die_b RX, B→A uses die_a RX). The existing bilateral calibrator handshake (`swi_training_hold`, both dies enter S_VALIDATE together) coordinates them — no new cross-die protocol.

### WI-2 — Port the FIX-J eyescan into the V1 (`src/`) calibrator  (~150–200 LOC, additive, default-off)
The deployed build (`TIDELINK_PHY_V2=0`) uses `src/rtl/tidelink_phy_align_calibrator.sv`, which has **no eyescan**. The FIX-J/L/M cure lives only in `deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv`.
- **Chosen option (c): port FIX-J/L into `src/`** — additive params (`LANE_PIN_CONVERGE`, `PRBS_EYESCAN`, `EYESCAN_DWELL`, `PIN_CONFIRM`, `VAL_TIMEOUT_TO_DONE`) + inputs (`lane_synced_i`, `lane_pin_converge_en_i`) + the eyescan cursor / pin-debounce blocks (`deps:1080-1137, 1319-1342, 1525-1574`). With all new params `=0` the module is **bit-identical to the proven image**. It grafts onto the existing `S_VALIDATE` without touching `S_PROBE/S_SWEEP/S_FINALIZE`, and keeps the V1 surfaces silicon bring-up relies on (`dwell_min_dist`, `resweep_ctr`, eye MMIO).
- **Rejected:** (a) swapping in the deps calibrator (re-plumbs every port; loses V1 surfaces; high regression) and (b) moving to `TIDELINK_PHY_V2=1` (enables the epoch-anchor [known sim-green/silicon-misfire], SYNC beacon, deskew, FIX-N..R serdes simultaneously — high regression to the proven B→A — *and* still leaves `lane_synced_i` unsourced).

### WI-3 — Chicken-bit + bounded timeout/fallback  (small)
- **`eyescan_arm` at SoC `0x4403_215C`** (Region 10 slot 7 — currently unused/reads 0 in both muxes; no `tidelink_apb_regs.sv` change needed). Mirror the `swi_word_pin_perlane_*` plumbing (`axi_chiplet_controller.sv:966, 1387, 1405, 1508`). Route it to the controller by adding `tl_apb_paddr[4:0]==5'h1C` to the existing **b4e2d0e** `wp_cfg_sel` exclusion mux in `src/rtl/tidelink_top.sv`.
- Gate the calibrator oracle with it (replacing the `:2770-2772` ties):
  ```
  .sync_seen_i            (eyescan_arm_r ? obs_sync_seen_rx_w    : 1'b0),
  .lane_synced_i          (eyescan_arm_r ? lane_synced_w[7:0]    : 8'h00),
  .lane_pin_converge_en_i (eyescan_arm_r),
  ```
  `eyescan_arm_r==0` (POR default) ⇒ inputs identical to today ⇒ datapath bit-identical to `8ab846ba`.
- **Bounded terminal:** `VAL_TIMEOUT_TO_DONE=1` **and** `MAX_RESWEEPS=32` (NOT 0). On timeout the FSM is forced to `S_DONE`; lanes not confirmed-synced fall back to the **coarse-park** (slip,phase) and `calibration_done` asserts. Never leave a lane `lane_done`/pinned at an unconfirmed phase. (`MAX_RESWEEPS=0` is forbidden: thrashes forever, or with the timeout latches S_DONE on the first timeout pinning only N-1 lanes.)

### WI-4 — Cadence wiring
- One-time eye-**centre** park at bring-up (force the full sweep + centre-select, *not* the (0,0) probe edge). Per-die, per-lane (die_a basin ≈ (1,15), die_b ≈ (13,3) — different and narrow).
- (Optional, later) error-triggered re-cal safety net: on a sustained CRC/PRBS error burst, FC drains-then-pauses (the dedicated FC node already halts on `training_mode`), re-cal (S_ARM→S_DONE, ~33µs sweep), resume credits. The occupancy deskew (`tidelink_lane_deskew.sv`) is prime-once/cal-independent and survives this cleanly; ensure the read side drains before the carrier drops.

## 5. Correctness guards — how this avoids the prior FIX-H bug
FIX-H pinned each lane on a *training-mode-guessed* phase **before** PRBS hit the wire, then re-armed and dropped the peer's carrier → `lane_pinned=1`/`lane_synced=0` forever (permanent `S_HOLD↔S_VALIDATE` thrash, no link-up). The FIX-J/L cure — which WI-2 ports verbatim — structurally prevents it:
1. **Scan WITH PRBS live, inside one held `S_VALIDATE`** (training_mode LOW; carrier never dropped mid-scan).
2. **FIX-L pin-debounce:** pin only on `lane_synced` held `PIN_CONFIRM` cycles; an overshoot drops sync and resets the counter → "pinned-but-never-synced" is impossible.
3. **`lane_synced_i` MUST be the PRBS-sync bus, never the training-pattern `lane_locked`** (feeding `lane_locked` *is* the FIX-H bug).
4. **Bounded timeout → coarse-park fallback** (WI-3) so a non-converging lane can never hang the link.

## 6. Verification + de-risk sequence (each gate blocks the next)

1. **RTL port + Verilator lint** clean.
2. **Sim Gate A — FSM correctness (catches the FIX-H class in sim).** Run the existing deps regression: `bilateral_eyescan` must give `centre`=FAIL, `naiveH`=FAIL, `eyescan`=PASS; `escan_pin_skew` catches the FIX-L off-by-one; the timeout-terminal control passes. **Add** two unit tests against the *ported `src/` calibrator*: `test_eyescan_pin_converge.py` (pins each lane at its modeled good phase, reaches S_DONE, no `lane_done`-without-`lane_synced`) and `test_eyescan_timeout_fallback.py` (a never-syncing lane times out to S_DONE + coarse-park, `validation_timed_out=1`).
3. **Sim Gate B — no-regression.** `cocotb/tidelink_top_pair`: `test_tidelink_pair_doorbell` 11/11 + `test_wordpin_plumbing` 2/2 with the chicken-bit **OFF and ON**; add `test_eyescan_arm_default_off.py` (unwritten `0x4403_215C` ⇒ byte-identical link-up to today). **Policy gate:** all of Gate A + Gate B must pass before any farm build.
4. **Standalone single-die PHY-BIST bench** — run the armed eyescan on `pynq-z2-phy-bist-pair` to confirm the FSM pins on a **real** eye (the one thing sim cannot show) before touching the production pair.
5. **Production pair, chicken-bit ON, supervised** — build the flip half, deploy to bridge1, run the §7 acceptance soak. Keep `314bc0e6` staged.
6. **Bake** at arm=1 across repeated re-POR rolls; only then fold the SW arm-latch into the standard bring-up.

## 7. Silicon acceptance — *sustained* reliable bidirectional
Extend `pynq_host/scripts/td_bringup_bidir.sh` (it already rolls to a bidir-clean POR + holds) to arm the eyescan during the per-roll latch and to soak:
- **Link integrity, sustained:** both dies hold `cal_done=1, fcsm=4, cr=1, crack=1` (`0x44032108`) for the entire soak — zero drops.
- **Data, sustained:** **B→A 500/500 AND A→B 500/500** byte-exact (fresh-unique words), i.e. 100%/100% over `--sends 500`.
- **Drift proof:** a second 500-send burst after a ≥60 s idle dwell with no re-POR/re-latch passes.
- **No-regression:** armed B→A ≥ un-armed baseline (run armed and un-armed holds back-to-back).
- **Stall-watch:** `validation_timed_out==0` on all lanes throughout (a 1 is the FIX-H signature leaking through ⇒ fail).

## 8. Safety / rollback
- Chicken-bit **OFF = bit-identical to `8ab846ba`** ⇒ cannot regress B→A.
- Rollback ladder: **disarm live** (`0x4403_215C ← 0` + recal, **no reflash**) → if still bad, **reflash `314bc0e6`** (`tidelink-flip.bit.bufgonly-bak`) and confirm the known-good bilateral baseline.

## 9. Effort, risk, and the key caveat
- **Effort:** ~300–400 LOC total, overwhelmingly reuse/integration (0 new RTL modules for the PRBS instrument).
- **Risk:** MEDIUM, concentrated in (i) the PRBS generator clock domain (§WI-1 hazard) and (ii) the calibrator port. Both are caught by Sim Gate A before any build; the default-off chicken-bit removes regression risk.
- **THE caveat to gate hardest:** the `src/` and `deps/` calibrators have **diverged** — the FIX-J/L cure exists only in `deps/`. It must be **ported into `src/`** (not merely enabled), and the deps A/B regression (`bilateral_eyescan`) **re-run against the ported `src/` calibrator** to prove the port did not reintroduce `naiveH` behaviour. This is the single highest-risk step.

## 10. Key file references
- Calibrator oracle tie-offs to gate: `src/rtl/local_overrides/axi_chiplet_controller.sv:2770-2772` (V1 inst `:2807-2810`); word_pin reg pattern to mirror `:966, 1387, 1405, 1508`.
- Port target (V1 calibrator, no eyescan today): `src/rtl/tidelink_phy_align_calibrator.sv` (`MAX_RESWEEPS :227,786`; `validation_timed_out :1007-1031`; output park `:1626-1638`).
- FIX-J/L donor: `deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv` (params `:327-364`; eyescan FSM `:1080-1137, 1319-1342`; pin-debounce `:1525-1574`).
- PRBS instrument: `deps/tidelink-phy/rtl/tidelink_phy_bist_prbs.sv` (gen+checker); template `deps/tidelink-phy/rtl/tidelink_phy_bist_core.sv:875-1022`.
- TX mux model / point: `src/rtl/local_overrides/WavD2DGpioTx.v:254`; `WavD2DGpio.v:289-303`; `WlinkGPIOPHY.v:25`. RX sample-point: `WavD2DGpioRx.v:330`.
- Chicken-bit route mux: `src/rtl/tidelink_top.sv` (the b4e2d0e `wp_cfg_sel` exclusion).
- FSM regression TBs: `deps/tidelink-phy/cocotb/phy_bist/{tb_cal_bilateral_eyescan.sv, tb_cal_escan_pin_skew.sv}` (+ Makefile targets `bilateral_eyescan`, `escan_pin_skew`).
- No-regression tests: `cocotb/tidelink_top_pair/{test_tidelink_pair_doorbell.py, test_wordpin_plumbing.py}`.
- Cadence evidence: `deps/tidelink-phy/scripts/exp_park_basin.sh` (one-time park that held); `tidelink_lane_deskew.sv:14-25` (prime-once, cal-independent).
- Silicon harness: `pynq_host/scripts/td_bringup_bidir.sh`.

## 11. Proposed implementation order
1. WI-2 port (FIX-J/L into `src/` calibrator, params off) → lint → **Sim Gate A** (incl. deps A/B re-run against ported `src/`). ← *gate hardest here*
2. WI-1 PRBS instrument → wire `lane_synced` → re-run Sim Gate A with the real oracle path.
3. WI-3 chicken-bit + timeout/fallback → **Sim Gate B** (ON/OFF no-regression).
4. Standalone single-die BIST bench (real-eye FSM proof).
5. Build flip half → production pair acceptance soak (chicken-bit ON) → bake.

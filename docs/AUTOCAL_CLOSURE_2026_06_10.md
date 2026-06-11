# Autocal Closure — 2026-06-10

**Status: CLOSED for the v1 (current) GPIO PHY.** The auto-calibration subsystem
(`tidelink_phy_align_calibrator.sv` + lane checker + lane deskew + SW bootstrap)
achieves autonomous bilateral link bring-up and a verified master→slave
application data crossing on silicon. Remaining limitations are documented
below and are superseded by the new PHY
(`~/SoCLabs/tidelink-gpio-phy-deskew`, `feat/phy-refactor`), which replaces
this calibrator/checker stack at integration time — see
`PLAN_TIDELINK_INTEGRATION.md` in that repo.

This document is the closure ledger: what was fixed, what the evidence is,
and what is deliberately **not** being fixed in the old stack.

---

## 1. Closure evidence (bridge1: z2_02 die_a master / z2_03 die_b slave)

| Date | Build | Result |
|---|---|---|
| 2026-06-10 ~02:00 | v33 (`e2fefd4` + deskew pipeline `c5f24b6`, M12 bootstrap `7702f07`) | **M→S DATA CROSSED**: 4-pkt AHB_TX burst landed byte-perfect in slave RX FIFO (`hdr=0x00240000 p0=0xDA7A0000`). Master IDELAY tap16 / slave tap7, both `fe_full=0`. |
| 2026-06-10 17:16 | v33 re-converge (`bringup_pair_converge.sh` with M12) | **Bilateral 16/16 cal+lock at iteration 1**; after `sync_bootstrap`: `die_a FCSM=4 die_b FCSM=4 — LINK_IDLE BILATERAL`. CR/CRACK exchanged (`ck=1` both sides). |
| nightly (sim) | `cocotb/tidelink_phy_align_calibrator` | 7/7 PASS (T3 re-sweep ×4, S_PROBE skip ×3) |
| 2026-06-10 (sim) | `cocotb/tidelink_lane_deskew` | 7/7 PASS incl. `index_skew_large` (7-word worst case) with the 4-stage pipelined offset computation |

**Reproducibility run (2026-06-10 ~22:30, boards freed):**

| Step | Result |
|---|---|
| Full re-converge (`bringup_pair_converge.sh`, M12) | **16/16 at iteration 1, FCSM=4 bilateral** — second clean converge of the day; M12 path is 2-for-2 |
| hwtest 5a — single AHB_TX word M→S | **PASS** (write completed inside the 5 s gate) |
| Slave RX FIFO readback (0x44010000) | **`0xc0ffee00`, `0xc0ffee01` byte-perfect** — M→S crossing REPRODUCED; slave healthy after (cal=1 fcsm=4 cr=1 ck=1) |
| hwtest 5b — 8-word storm | Stalled at word 4; master AHB write blocked → **z2_02 PS hard-wedged** (SSH dead, needs JTAG `rst -system` via xsdb on mapstone-dev:3121, target `*Z2_02*`) |
| hwtest 4b — doorbell M→S | **Run 2026-06-11 after board reboot + fresh converge (16/16 it-1, cr=1 both): FAIL — doorbell sideband inert on HW.** Both dies read `DOORBELL_RESP_ACC=0x1000` once post-link-up (residue = the 4096 credit grant echoed into the acc); after read-clear, 8 master rings accumulate nothing on either die. Sim is green on the same RTL (doorbell suite 11/11 incl. test_04/test_10 sustained replenish), so this is an HW-only sideband TX/RX gap — same family as the historical sideband-consumer findings. Needs ILA on the sideband path. Logged as residual #6. Other 4x sub-tests: 6/7 pass (credit counter mechanics + master CURRENT_CREDITS=4096 healthy). |

The storm result is a clean characterization of residual #1/#5 below: the
~4-word budget matches the initial credit allocation; S→M credit return does
not replenish reliably, so sustained M→S traffic back-pressures into the
Bug-A wedge. Single-word and small-burst M→S traffic crosses fine. The
hwtest link-up gate was updated to accept the post-M12 data-mode state
(criterion B: cal_done + FCSM∈{4,5}; `lk=0` is expected — residual #2).

Note on hwtest `03_ahb_sub_e2e.sh` test 3d: it pokes `0x44010000`, which on
the current build is **local SRAM on each die** (not FC-forwarded). The real
M→S path is `0x44000000` (AHB_TX FIFO) → FC node → peer `0x44010000` (RX
FIFO). Test 3d fails by construction on this address map and is not evidence
of a link fault.

---

## 2. Fix ledger (M-series)

| Fix | Commit | Area | Summary |
|---|---|---|---|
| M1+M2+M7 | `2c6d8bf` | CDC/observability | calibrator CDC sync + `autocal_force_enable` hook |
| M4b/M4e | (v18 era) | training FSM | peer_unreach_timeout + relaxed primary-success (lane_locked-only) — 80% bilateral at v18 |
| M8 | `328233d` | S_VALIDATE | training_mode=1 during S_VALIDATE — **REVERTED by M10** (held LL_RX in reset on the peer) |
| M9 | `6ce0827` | S_VALIDATE | one-shot timeout deadlock → `MAX_VALIDATE_RETRIES=8` retry loop to S_ARM |
| M10 | `0ffbbb6` | S_HOLD | revert M8; `HOLD_CYCLES` 1024→32768 so peers' validation windows overlap |
| M11 | `e2fefd4` | S_SWEEP | `MIN_LOCK_DWELLS` 4→2 (die_a marginal eye has 2–3 tap windows); APB override `NEGO_TRAIN_CFG[7:4]` |
| M12 | `7702f07` | SW bootstrap | `sync_bootstrap()` clears `swi_training_mode` (0x44032100) after CTRL_FULL — the OR-merge otherwise holds `training_mode=1` → LL_RX reset → no CR/CRACK → FCSM stuck at 1/2. Plus skip-if-already-up guard. |
| deskew | `cec82c9`, `e6ccc0b`, `c5f24b6` | lane deskew | DEPTH 8→16 + offset clamp; fix `.DEPTH_LOG(3)` override back to 4; 4-stage pipelined offset computation for FPGA timing |

Earlier foundational fixes (S_PROBE `f900e07`, cr-OR-crack `f99ec48`, XDC port
`45a13fe`, R1+R3 SI set) are covered in `docs/archive/` and the git history.

## 3. Final calibrator parameters (RTL defaults)

| Parameter | Value | Notes |
|---|---|---|
| `DWELL_CYCLES` | 64 | |
| `LOCK_THRESH` | 16 | consecutive-match lock criterion |
| `MIN_LOCK_DWELLS` | 2 | M11; runtime-overridable via `NEGO_TRAIN_CFG[7:4]` |
| `HOLD_CYCLES` | 65,536 | M10 (8·128·DWELL) |
| `VALIDATION_TIMEOUT` | 4,096 | |
| `MAX_VALIDATE_RETRIES` | 8 | M9 |
| `MAX_RESWEEPS` | 0 | retry while role_locked |
| `AUTOCAL_ENABLE` | 1'b1 | the 2026-05-27 `=0` workaround is retired |

## 4. Known residuals — documented, NOT being fixed in the old stack

1. **S→M credit decode is intermittent (~97%).** The master's RX occasionally
   garbles the slave's CR credit word (marginal eye on die_a + exact-match
   checker). Symptom: `fe_rx_credit_max=0` until a clean decode lands. The new
   PHY's Hamming-threshold checker + PHY-owned deskew + sync beacon addresses
   exactly this class; hardening the old exact-match checker is wasted effort.
2. **`lk=0x00` after `training_mode=0` is expected**, not a fault: the lane
   checker only matches training patterns. Link health post-training is judged
   by FCSM state + cr/ck, not `lk`.
3. **MIN_LOCK_DWELLS=2 is at the margin** for die_a's eye. The APB override
   exists for per-die tuning; new-die bring-up should log `SWI_LANE_STATUS` +
   eye registers as early warning.
4. **v33 master WNS=-1.16 ns is a phantom** — chronic PHY RX XDC
   double-count; the deskew path itself has +9.46 ns slack post-pipeline.
5. **Peer-aperture writes to `0x40000000` can still wedge AHB_TX (Bug A
   correctness)** when `fe_full=1`; the safe M→S path is the AHB_TX mailbox
   with an `fe_full` check. FC-side rework lands with the new PHY/link-mgmt
   refactor, not here.
6. **Doorbell sideband is inert on HW** (2026-06-11): rings accumulate no
   response on either die despite the cocotb doorbell suite passing 11/11
   on identical RTL; both dies show a one-shot `0x1000` link-up residue in
   `DOORBELL_RESP_ACC`. HW-only sideband TX/RX gap — needs ILA. Data-plane
   M→S (AHB_TX) is unaffected (crossing reproduced same night).

## 5. Hand-off to the new PHY

- The new PHY repo carries its **own calibrator lineage** (FIX-C…FIX-R,
  WORD_PIN_AUTO, ~3000 lines) which is the HW-validated one for the new
  datapath. **Do not port M-series fixes forward**; they solve problems of the
  old observer-only checker topology (M8 was already proven harmful).
- Integration sequencing, layer model (L0–L4) and gates (V5 30-min soak, CDC
  F2, vendor-fork extraction) live in the PHY repo's
  `PLAN_TIDELINK_INTEGRATION.md` (2026-06-10) — authoritative over the older
  `INTEGRATION_GUIDE.md` (2026-06-03, checker-only era).

# TideLink chiplet autonomous bringup via I2C — detailed report

**Date:** 2026-05-29
**Investigation scope:** Current `feat/td-gpio-phy-integration` build #3 (dda0a0e) + historical `feat/i2c-autonomous-lock-integ` (a657306) + axi-chiplet-controller (2f602d1 Bug #3 fix)
**Target:** ASIC chiplet autonomous bring-up with zero SW intervention

## Executive summary

TideLink's I2C autonomy stack has three operational layers:
1. **Autoneg FSM** (`tidelink_autoneg.sv`) — negotiates master/slave roles over I2C sideband. **Operational on silicon.**
2. **Mask handshake** — verifies peer lane masks match. **Operational on silicon** after Bug #3 fix.
3. **I2C-coordinated training** — synchronizes `SWI_TRAINING_MODE` entry/exit. **Design-only, not in RTL.**

Build #3 today still requires three SW pokes after deploy: `SWI_TRAINING_MODE=1` on each side, wait for cal, then `SWI_TRAINING_MODE=0` + swreset. For ASIC autonomy, the missing piece is **automated training-mode entry/exit on both sides within bounded I2C-coordinated skew** — the protocol is fully designed in [staging/i2c_train/I2C_TRAIN_PROTOCOL.md](staging/i2c_train/I2C_TRAIN_PROTOCOL.md), the reference state RTL is in [staging/i2c_train/tidelink_autoneg_train_states.sv](staging/i2c_train/tidelink_autoneg_train_states.sv), but the state machine is not yet integrated into `axi_chiplet_controller.sv`.

## 1. What exists today

### 1.1 I2C controller
- **Files:** `deps/axi-chiplet-controller/logical/i2c/rtl/{i2c_master_axil.v,i2c_master.v,i2c_slave.v}`
- I2C master with START/STOP, byte transactions, ACK/NACK
- I2C slave with address decode and APB-write bridging
- Shared prescaler `NEGO_CFG@0x080[15:0] = i2c_prescale_reg` (default reset = 1, runtime = 128 per commit 467b889 → 100 kHz SCL @ 100 MHz)
- **Status:** P15/P16 ribbon wired, autoneg transactions silicon-validated

### 1.2 Autoneg FSM (roles + mask handshake)
- **File:** `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` (~1K LOC)
- Outer states: `ST_IDLE → ST_NEGO_INIT → ST_NEGO_WAIT → ST_NEGO_CLAIM → ST_NEGO_POLL → ST_NEGO_MASK_RD_ADDR → ST_NEGO_MASK_RD_DATA → ST_NEGO_MASK_RES_TX → ST_NEGO_DONE`
- Outputs: `nego_done`, `nego_won`/`nego_lost`, `mask_hs_local_match`
- **Status:** Cocotb regression `autoneg_i2c_e2e 3/3 PASS`. On silicon (build #5): master `NEGO_STATUS=0x055` (DONE/won), slave `0x195` (DONE/lost).
- **Limitation:** `ST_NEGO_DONE` is terminal — no auto-transition to training coordination.

### 1.3 Training mode (GPIO PHY)
- Wired in `src/rtl/tidelink_top.sv` + `deps/tidelink-gpio-phy/rtl/`
- `SWI_TRAINING_MODE` register at chiplet APB offset 0x098
- When asserted: GPIO PHY emits per-lane 0x12EB / 0xED14 training pattern (commit e2a9393); calibrator FSM sweeps per-lane bit-slip
- **FPGA today:** Written manually via PYNQ SSH (`bringup_pair_converge.sh`)
- **ASIC:** No on-chip mechanism — would need embedded controller or external BMC

### 1.4 FCSM & credit handshake (current bug)
- **Symptom (build #3, 2026-05-29):** `PAIR_CREDIT_COUNTER = 0x00` on both sides after bringup; AHB packet RX at slave stuck empty; PTP HW_SYNC RX at slave stuck at 0x0; doorbells work (sideband)
- **Hypothesis:** CR packet exchange stalls; FCSM never exits state 1 (SEND_CREDITS1)
- **Orthogonal to training autonomy** — see [DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md](docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md)

## 2. What `feat/i2c-autonomous-lock-integ` adds

Branch tip a657306 (2026-05-20) is a submodule mark_debug bump. The real work is earlier:

| Commit | Purpose |
|---|---|
| d06d495 | **Bug #3 structural fix** — missing `default: state_nxt = state_r;` on outer case in `tidelink_autoneg.sv`. Vivado was optimising away the `if(mask_hs_auto_en)` branch. Ported to `feat/td-gpio-phy-integration` at 85f0e48. |
| 6c38103 | "2026-05-20 evening — autoneg WORKS" — documents full FSM traverse on silicon |
| 9f81947 | mask_hs_auto_en `(* keep *)` mitigation (pre-d06d495) |
| 910b5c7 | HW-bug reproducer + sub-bump for nego_driving fix |

### "2 RTL fixes" in memory entry
1. **Fix A** (axi-chiplet-controller 467b889): I2C slave `scl_t` decode when `role_is_master=0`. Master's SDA START detection needs clean slave clock-stretch.
2. **Fix B** (axi-chiplet-controller be5eed2): Missing `default` on `txn_step_nxt` latch (Synth 8-327).

Bug #3 (d06d495) was a **third** fix that surfaced after the memory entry was written.

### Training-mode coordination (designed, not RTL)
- **Spec:** [staging/i2c_train/I2C_TRAIN_PROTOCOL.md](staging/i2c_train/I2C_TRAIN_PROTOCOL.md)
- Master-driven FSM: `ST_TRAIN_ENTER → ST_TRAIN_RUN → ST_TRAIN_POLL_PEER → ST_TRAIN_EXIT → ST_TRAIN_DONE`
- 1. ENTER: master I2C-writes peer's `SWI_TRAINING_MODE := 1` AND writes own locally
- 2. RUN: calibrator FSMs sweep; master dwells `T_TRAIN_FSM = 4096 apb_clk ≈ 41 µs`
- 3. POLL_PEER: master I2C-reads peer's `SWI_LANE_LOCKED`, ANDs with local; if both `0xFF` proceed; retry up to 16 times
- 4. EXIT: master I2C-writes peer's `SWI_TRAINING_MODE := 0`, writes own locally, pulses local `swreset`, I2C-writes peer's swreset
- 5. DONE: terminal, `train_ok = 1`
- **Timing:** ~2.8 ms typical, ~17 ms worst-case. Well below 5-second deploy budget.
- **New registers (§3.1):** `NEGO_TRAIN_CFG@0x090`, `NEGO_TRAIN_STATUS@0x094`, `SWI_TRAINING_MODE@0x098` (dual-write), `SWI_LANE_LOCKED@0x0A0` (dual-read), `SWI_LANE_FAULT@0x0A4`, `SWI_BIT_SLIP_LO@0x0A8`
- **Cocotb scaffolding:** `cocotb/i2c_mask_selflock/`, `cocotb/i2c_clkstretch/`
- **Reference RTL skeleton:** [staging/i2c_train/tidelink_autoneg_train_states.sv](staging/i2c_train/tidelink_autoneg_train_states.sv) — defines `ST_TRAIN_*` states but not wired into main FSM

## 3. Gap analysis — FPGA pokes vs ASIC autonomy

| Layer | FPGA today | ASIC autonomous need | Status |
|---|---|---|---|
| (a) Role resolution | Strap GPIO + `NEGO_CFG=0x61` APB | Autoneg FSM (`nego_force_lock=1`) | ✅ DONE |
| (b) Training-mode entry | 2 APB pokes (`SWI_TRAINING_MODE=1` each side) | I2C-coordinated dual-write within bounded skew | ❌ **NOT DONE** (port ST_TRAIN_ENTER) |
| (c) Calibrator sweep | Autonomous once training=1 | Autonomous (same) | ✅ DONE |
| (d) Training-mode exit | 2 APB pokes (`SWI_TRAINING_MODE=0`) | I2C-coordinated dual-write + local swreset | ❌ **NOT DONE** (port ST_TRAIN_EXIT) |
| (e) FCSM swreset | 2-3 APB pokes on `WLINK.EnableReset@0x208` | I2C peer write + local APB write | ❌ **PARTIAL** (local can pulse; peer needs I2C) |
| (f) PTP servo (post-linkup) | `bringup_ptp_track_*.sh` writes PTP_CTRL, HW_SYNC_CTRL | Requires on-chip controller; defer | ❌ **DEFERRED** (not on critical path) |
| (g) Lane mask handshake | `NEGO_CFG[6]=1` gates handshake | Same (autoneg state ST_NEGO_MASK_RES_TX) | ✅ DONE |

**Minimum autonomous path for ASIC link-up:** (a) + (c) + (g) ✅ already autonomous. **(b) + (d) + (e) need I2C-coordinated training FSM integration.** That's the gap.

## 4. Bug #3 (mask-phase prune class)

**Root cause:** Synth 8-155 — outer `case(state_r)` in `tidelink_autoneg.sv` was incomplete (only decoded 11 of 16 possible 4-bit values). Missing `default` caused Vivado to collapse downstream branches it deemed "unreachable."

**Manifestation:** Master `NEGO_DONE` with `nego_won=1`; slave `NEGO_DONE` with `nego_lost=1`; state never advanced into mask handshake region.

**Fix (commit 2f602d1):** `default: state_nxt = state_r;` — keeps state latched, allows synth to see all transitions.

**Family:** Same as txn_step_nxt latch bug (be5eed2) — Synth 8-xxx incomplete logic. **Likely NOT the same family** as the current `PAIR_CREDIT_COUNTER=0` bug (credit bug is in FC adapter CR packet detection, not state encoding) — UNLESS `tidelink_fc_adapter.sv` itself has an incomplete case statement that synth is collapsing similarly. Worth a one-pass audit.

## 5. Recommended path to ASIC autonomy

### Phase A — Stabilise build #3 (1-2 days)
- Add the 3 cocotb tests from [DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md](docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md) (paircredit non-zero, AHB M→S, PTP HW_SYNC slave status)
- Instrument FCSM to find where CR packet stops
- Fix → cocotb regression → FPGA re-validate
- **Unblocks training-mode exit and FCSM state advance**

### Phase B — Port training FSM to RTL (3-5 days)
1. Extend `tidelink_autoneg.sv` with `ST_NEGO_DONE_PRE` + 5 `ST_TRAIN_*` states (copy skeleton from `staging/i2c_train/tidelink_autoneg_train_states.sv`)
2. Update register block (`tidelink_regs.rdl`) — new registers per protocol §3.1
3. Gate on `train_auto_en` from `NEGO_TRAIN_CFG[0]` for backward compatibility
4. Cocotb regression:
   - Existing `wlink_pair` / `tidelink_top_pair` tests with `train_auto_en=0` must still pass
   - New `test_i2c_train_e2e()` with `train_auto_en=1` must assert `train_ok=1` AND `PAIR_CREDIT_COUNTER != 0`
5. FPGA validation with `train_auto_en=1` hardcoded → expect no APB pokes needed
- **Merge path:** straight cherry-pick from `feat/i2c-autonomous-lock-integ` commits 6c38103, 3607c4f, 8c407bc

### Phase C — ASIC hardening (1-2 weeks)
- UVM regression: `test_autoneg_train_both_sides()` with `train_auto_en=1`
- No on-chip timer dependency (FSM uses I2C poll loop, not PLL-derived clocks)
- CDC audit: new cross-domain paths are quasi-static (`training_mode`, `lane_locked`, `lane_fault` stay stable during sweep)
- Wall-clock POR→`nego_done & train_ok` measurement (~50-100 ms typical FPGA cocotb)
- Document 3 fallback levels:
  - **L1 (autonomous):** `train_auto_en=1`, ~50 ms
  - **L2 (hybrid):** `train_auto_en=0`, roles auto, training manual
  - **L3 (manual):** all APB pokes external (fallback if I2C fails)

### Phase D — Tape-out (separate team)
- LEC (Formality) RTL before/after training FSM
- DFT (scan, MBIST)
- Final timing closure at nominal 1.8V

## 6. Open risks

| Risk | Impact | Mitigation |
|---|---|---|
| `PAIR_CREDIT_COUNTER=0` not solved before Phase B | Training FSM exits but app traffic still doesn't flow | Phase A is gate to Phase B |
| Training FSM peer-poll timeout (16 retries, ~14 ms worst-case) | Link doesn't come up; firmware must retry / fallback | Add `train_fail_irq`; SoC-level retry logic |
| I2C prescaler misconfigured on ASIC | SCL bus never clocks; FSM → `ST_TRAIN_FAIL` | Verify `i2c_prescale_reg` reset value; document for integrator |
| Slave I2C slave core hung (E-pole wedge) | Master writes NACK; FSM times out | `ST_TRAIN_FAIL` documented (§4.1 protocol spec); firmware fault recovery |
| PHC Phase-1 bug | HW_SYNC RX still stuck at slave | Independent of linkup; can write PTP_CTRL post-linkup |

## 7. ASIC-specific concerns

### Which APB pokes can be eliminated by the I2C training FSM?

| Poke today | ASIC path | Feasibility |
|---|---|---|
| Strap GPIO + `ROLE_CFG` | Autoneg FSM | ✅ Eliminable |
| `PAIR_BASE_ADDR` write | Hardcoded at POR | ✅ Eliminable if deterministic |
| `SWI_TRAINING_MODE=1/0` × 2 | I2C-coordinated FSM | ✅ Eliminable |
| `swi_phase_offset` | Hardcoded 0; calibrator handles per-lane | ✅ Eliminable |
| `swreset` toggle × 2 | FSM pulses locally; I2C-writes peer | ✅ Eliminable |
| `PTP_CTRL` for HW_SYNC | Post-linkup firmware servo | ❌ Requires controller |
| Doorbell (test only) | Autonomous credit path once FCSM fixed | ✅ Autonomous |

### RTL-autonomous vs firmware-controlled vs BMC

- **RTL-autonomous (no controller needed):** autoneg, training coord, calibrator sweep, FCSM/credit handshake
- **Firmware-controlled (needs on-chip CPU):** PTP servo loop, post-linkup error recovery, telemetry
- **External BMC (if no on-chip CPU):** same as firmware via off-die I2C

**For ASIC v1 chiplet recommendation:** assume **no on-chip controller**. Linkup is autonomous. Post-linkup servo defers to v2 — not on critical path for tape-out.

## 8. Concrete next-step decision tree

If user wants ASIC autonomy:
1. **Block on Phase A** (resolve PAIR_CREDIT_COUNTER bug). Sim regression tests now dispatched in parallel agent.
2. **Once Phase A green: dispatch Phase B port agent** with explicit cherry-pick list from `feat/i2c-autonomous-lock-integ`.
3. Phase A + B together should produce an FPGA bitstream that brings up the link from pure deploy with zero APB pokes — proof-of-concept for ASIC.

## Files investigated

- `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` (autoneg FSM)
- `deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master_axil.v` (I2C master)
- `staging/i2c_train/I2C_TRAIN_PROTOCOL.md` (training spec)
- `staging/i2c_train/tidelink_autoneg_train_states.sv` (state skeleton)
- `pynq_host/scripts/deploy_pair.sh` (current APB pokes)
- `docs/BRINGUP_DETERMINISM_I2C_PLAN_2026_05_28.md` (original proposal)
- Memory: `project_tidelink_i2c_autonomy.md`

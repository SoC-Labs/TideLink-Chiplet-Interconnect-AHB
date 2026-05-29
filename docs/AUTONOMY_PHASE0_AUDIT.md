# Phase 0 — Autonomy plan audit (sim baseline + static)

**Branch:** `feat/td-autonomy` @ parent `fc2bbb9` (worktree `/home/dam1n19/SoCLabs/td-bisect/td-autonomy/`)
**Date:** 2026-05-29
**Scope:** Phase 0 of [ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md](ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md). Read-only audit + sim baseline. **No RTL changes performed.**

## 0a — Static audit of `tidelink_autoneg.sv` ST_TRAIN_* arms

### Files examined

- [deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv](../deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv) (1676 lines)
- [src/rtl/local_overrides/axi_chiplet_controller.sv](../src/rtl/local_overrides/axi_chiplet_controller.sv) (lines 616-617 wire decls, 1213-1243 instance + dead-end)

### State encoding (lines 187-193)

```
ST_NEGO_DONE_PRE  = 5'd11
ST_TRAIN_ENTER    = 5'd12
ST_TRAIN_RUN      = 5'd13
ST_TRAIN_POLL_PEER= 5'd14
ST_TRAIN_EXIT     = 5'd15
ST_TRAIN_DONE     = 5'd16
ST_TRAIN_FAIL     = 5'd17
```

All states present. `ST_NEGO_DONE` (5'd5) remains as the legacy terminal for `train_auto_en=0`.

### Per-state functional audit

#### ST_NEGO_DONE_PRE (lines 887-907)
- Decides between training mode (`train_auto_en=1` → ST_TRAIN_ENTER) and legacy bypass (→ ST_NEGO_DONE).
- Clears `train_ok_r`, `train_fail_r`, `train_peer_nack_r`, `peer_lane_locked_r`, `peer_lane_fault_r`.
- **Verdict: clean.**

#### ST_TRAIN_ENTER (lines 911-953)
- I²C-writes 6 bytes to peer's `SWI_TRAINING_MODE @ 0x2100`, payload bit[0]=1.
- On peer NACK → `train_peer_nack_nxt=1`, `peer_lane_fault_nxt=8'hFF` (poison sentinel), `train_fail_nxt=1`, `state_nxt=ST_TRAIN_FAIL`.
- On peer ACK → `local_train_set_pulse_r=1'b1`, dwell timer = `T_TRAIN_FSM_DEFAULT` (4095 cycles) or override, `state_nxt=ST_TRAIN_RUN`.
- **Verdict: clean. The local strobe is paired with the peer write so the two SWI_TRAINING_MODE asserts are bounded in skew.**

#### ST_TRAIN_RUN (lines 955-965)
- Countdown on `train_wait_r`. No I²C traffic. Calibrators on both sides converge in parallel.
- Dwell defaults to 4095 cycles ≈ 41 µs @ 100 MHz apb_clk.
- **Verdict: clean.**

#### ST_TRAIN_POLL_PEER (lines 967-1084) — the critical state

Two sub-phases:

**Phase 0 — address-write** (set peer's I²C read pointer to lane-status register, 2 bytes, no STOP). NACK → ST_TRAIN_FAIL. ACK → switch to Phase 1.

**Phase 1 — 4-byte read** of peer's `SWI_LANE_STATUS` block:

| Byte | Capture target | Enable strobe |
|---|---|---|
| 0 | `peer_lane_locked_r` | `peer_lane_locked_capture_en` |
| 1 | **`peer_lane_fault_r`** | `peer_lane_fault_capture_en` |
| 2 | `peer_cal_done_r` (bit 0) | `peer_cal_done_capture_en` |
| 3 | (reserved padding, not used) | — |

> **Plan concern RESOLVED:** the autonomy plan said the upstream skeleton "noted `peer_lane_fault` was approximated by `peer_lane_locked_r ^ 8'hFF` — confirm whether the integrated version got a real fault-read sub-state or kept the crude derivation." It is a **real per-byte read**. No derivation.

**6-condition success check** at lines 1047-1052:
```systemverilog
if ((peer_lane_locked_r == 8'hFF) &&
    peer_cal_done_r &&
    (local_swi_lane_locked_i == 8'hFF) &&
    local_calibration_done_i &&
    (peer_lane_fault_r == 8'h00) &&
    (local_swi_lane_fault_i == 8'h00)) begin
    state_nxt = ST_TRAIN_EXIT;
}
```

**Retry path** (lines 1059-1066): on `poll_attempt_r == train_poll_timeout`, snapshot `local_swi_lane_fault_i` and transition to ST_TRAIN_FAIL. Default `T_POLL_TIMEOUT_DEFAULT = 4'd15` (16 polls).

**Verdict: clean. This is the rigorous version, not a skeleton.**

#### ST_TRAIN_EXIT (lines 1086-1122)
- I²C-writes peer's `SWI_TRAINING_MODE := 0` (6 bytes).
- NACK → `train_peer_nack_nxt=1`, `train_fail_nxt=1`, but **still pulses** `local_train_clr_pulse_r=1` (local side cleared regardless). → ST_TRAIN_FAIL.
- ACK → `local_train_clr_pulse_r=1'b1` + `swreset_hold_nxt = T_SWRESET_HOLD` (7'd127 cycles) + `train_ok_nxt=1'b1` → ST_TRAIN_DONE.
- **Verdict: clean. Note the failure-but-local-clear handling — important for graceful retry.**

#### ST_TRAIN_DONE (lines 1124-1136)
- Drains `swreset_hold_r` counter (so `local_swreset_pulse_w` falls cleanly after T_SWRESET_HOLD cycles).
- On `train_retrain_req` (W1P from APB) → re-enter ST_NEGO_DONE_PRE.
- **Verdict: clean.**

#### ST_TRAIN_FAIL (lines 1138-...)
- Terminal sticky-fail. Allows retrain via `train_retrain_req`.
- **Verdict: clean.**

### Timer values

| Constant | Value | Wall-time @ 100 MHz | Where |
|---|---|---|---|
| `T_TRAIN_FSM_DEFAULT` | 12'd4095 | ~41 µs | line 291 |
| `T_POLL_TIMEOUT_DEFAULT` | 4'd15 | up to ~9.6 ms total (worst case) | line 296 |
| `T_SWRESET_HOLD` | 7'd127 | ~1.27 µs | line 300 |

**Total autonomous bring-up budget** (matches the I2C report's ~17 ms worst-case estimate):
- Nego (role + mask): ~10 ms (I²C dominated)
- ST_TRAIN_ENTER + RUN + POLL_PEER + EXIT: 0.6 + 0.04 + 9.6 + 0.6 = ~11 ms worst case
- Total bound: ~21 ms worst case; ~3 ms typical with first-poll success.

### Output port driving (lines 1667-1669)

```systemverilog
assign local_training_mode_set = local_train_set_pulse_r;
assign local_training_mode_clr = local_train_clr_pulse_r;
assign local_swreset_pulse     = (swreset_hold_r != '0);
```

All three FSM outputs are **alive** at the submodule. The "dead" status is in the integration wrapper.

### Integration wrapper status (`src/rtl/local_overrides/axi_chiplet_controller.sv`)

Lines 1213-1243 instantiate `tidelink_autoneg u_autoneg` with all training ports connected:

- `local_training_mode_set_w` → flows into `swi_training_mode_r` mux at lines 724-727 ✅
- `local_training_mode_clr_w` → same mux ✅
- **`local_swreset_pulse_w` → dead-ended at line 1241** as `_unused_phase3_a`. **This is gap G1.**
- **`train_fail_irq_w` → dead-ended at line 1242** as `_unused_phase3_b`. **This is a secondary gap not previously tracked.** It should surface as an APB-readable IRQ status bit so SW can detect train failure post-POR.

Comment at line 1238 explicitly acknowledges the deferral: *"via local_swreset_pulse_w → not currently wired through Wlink's swreset; future integration step"*.

### Plan corrections discovered

| Plan claim | Audit finding |
|---|---|
| G1: `local_swreset_pulse_w` dead | ✅ Confirmed at line 1241 |
| Concern about `peer_lane_fault` being derived | ❌ Refuted — real per-byte read at line 1036 |
| FSM reaches `ST_TRAIN_DONE` end-to-end | ✅ Code path verified |
| `train_fail_irq_o` exists | ✅ But **also dead-ended** at line 1242 — Phase 1 should wire this too |

### Plan amendments (not yet applied to the plan doc — flagged here)

- **Add G1b**: `train_fail_irq_w` is also unwired. Phase 1 should bring this out as an APB-readable status bit AND/OR an IRQ line to the host. Low effort (~30 min added to Phase 1).
- **Confirm Phase 0a clean**: no skeleton holes. The autonomy plan was conservative on this front — the FSM is production-quality.

---

## 0b — Sim baseline

### Approach

Run `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py::test_01_role_lock_and_cal_done` in the worktree. This is the smallest paired-die test (link bring-up, no FC traffic) and verifies the env compiles + tb_top is sane on the autonomy worktree.

### Env

- Sim: VCS 2022.06-SP2 at `/eda/synopsys/2022-23/RHELx86/VCS_2022.06-SP2/bin/vcs`
- TIDELINK_HOME = `/home/dam1n19/SoCLabs/td-bisect/td-autonomy`
- ARM_IP_LIBRARY_PATH = `/research/AAA/ip_library` (memory note: read-only)
- Cmd: `TB_TOP_NO_DUMP=1 TESTCASE=test_01_role_lock_and_cal_done make MODULE=test_tidelink_pair_doorbell`
- VCD dump disabled to avoid >4 GB output (per Makefile comment)

### Result

*[populated after sim completes]*

---

## Sequencing recommendation for Phase 1

Per the plan-revision note in [docs/ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md](ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md), Phase 1 should be sequenced behind a Bug-A credit-ledger baseline capture. Status update:

- Bug A debug is committed on main (`bd9646e`, `ebbde0e`). The probes are placed.
- Errata on `test_07` (uncommitted in main's working tree, not in this worktree) renames the credit assertion to target `fe_rx_credit_max` instead of the SW-managed `PAIR_CREDIT_COUNTER`.
- Phase 1 here can proceed safely because:
  1. The autonomy worktree is independent of main's working-tree state (the `test_07` errata edit doesn't perturb our env).
  2. The Phase 1 RTL changes are in distinct files (`axi_chiplet_controller.sv` integration wiring + `tidelink_top.sv` Tier-2 bypass) — no conflict with the Bug-A mark_debug attrs at `tidelink_top.sv:489-606`.
  3. The Phase 1 cocotb regression will diff the credit-ledger probe trajectory between `train_auto_en=0` (current) and `train_auto_en=1` (Phase 1) — this is the disentangling experiment.

### Effort estimate refinement

Original plan: Phase 1 = 1.5 days.
Audit-updated: Phase 1 = 2 days. Half-day added for `train_fail_irq_w` wiring + corresponding APB status bit + cocotb assertion.

---

## Decision needed before Phase 1 commences

- [ ] User approval to proceed to Phase 1 RTL changes on this branch
- [ ] Confirm whether to fold the `train_fail_irq_w` wiring into Phase 1 or defer (separate sub-phase)

No RTL has been touched on this branch yet.

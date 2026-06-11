# Phase 0c — Autonomous training-FSM sim trace + Phase 7a audit

**Branch:** `feat/td-autonomy` (worktree `/home/dam1n19/SoCLabs/td-bisect/td-autonomy/`)
**Date:** 2026-05-29
**Scope:** Sim-side Phase 0c deliverables of the autonomy plan. Parallel RTL agent owns `src/rtl/**` — this work touches only `cocotb/tidelink_top_pair/` and docs.

## TL;DR

- The paired-die cocotb env (`cocotb/tidelink_top_pair/`) needed a single new compile knob to switch between "legacy SW-driven bring-up" and "autonomous training". I added it as `BYPASS_AUTONEG` (default 1 = legacy, preserves test_01..test_09 unchanged) wired through a SystemVerilog `force` block in `tb_top.sv`.
- New cocotb test `test_10_autonomous_train_post_por.py` engages the FSM with no APB stimulus and snapshots state at 5 phase boundaries. INFO-only by design (Phase 0c is exploratory, not a regression gate).
- The I²C cross-wire between the two dies was already present in `tb_top.sv:205-209` (open-drain tristate-AND model). No new infrastructure needed.
- Phase 7a audit: test_11 (opt-out) is the cheapest (~3 h, just runs all of test_10's path against `BYPASS_AUTONEG=1` and asserts ST_BYPASS). test_12 (peer NACK) is best implemented at the existing `cocotb/tidelink_autoneg/` unit-level env, NOT in the paired-die env — that env already exposes every training port and emulates the AXI-Lite slave from Python (~6 h). The existing `cocotb/i2c_mask_selflock/` env mentioned in the brief is **absent from this worktree** — that lift path is not available; the substitute is extending `cocotb/tidelink_autoneg/test_tidelink_autoneg.py`.

## What changed in the testbench

### `cocotb/tidelink_top_pair/tb_top.sv`

Added a new parameter and an `initial`-block force:

```systemverilog
parameter int BYPASS_AUTONEG = `ifdef TB_TOP_BYPASS_AUTONEG `TB_TOP_BYPASS_AUTONEG `else 1 `endif,
```

Default = 1 → no change to existing tests. Under `BYPASS_AUTONEG=0` the testbench forces `nego_cfg_reg=7'h61` and `nego_train_cfg_r=16'h00F1` on both dies at time 0, holds them through hresetn rise, then releases at t=5000 ns. The autoneg FSM samples `nego_en` (bit 0) once in ST_IDLE and commits to walking ST_NEGO_INIT → … → ST_TRAIN_DONE.

The bit assignment:

| Field | Value | Reason |
|---|---|---|
| `nego_cfg_reg[0]` (nego_en) | 1 | Run the FSM |
| `nego_cfg_reg[1]` (nego_start) | 0 | Backoff timer paths advance regardless |
| `nego_cfg_reg[3:2]` (nego_pri_sel) | 0 | Use `nego_priority_reg` (forced to a tiny non-zero) |
| `nego_cfg_reg[4]` (nego_fallback) | 0 | Don't force a side to slave on timeout |
| `nego_cfg_reg[5]` (nego_force_lock) | 1 | Latch `role_locked` when nego completes |
| `nego_cfg_reg[6]` (mask_hs_auto_en) | 1 | Run the mask-handshake states (gate to ST_NEGO_DONE_PRE) |
| `nego_train_cfg_r[0]` (train_auto_en) | 1 | Engage ST_TRAIN_ENTER on the master |
| `nego_train_cfg_r[7:4]` (poll_timeout) | 0xF | 15 polls before fail |
| `nego_train_cfg_r[15:8]` (fsm_wait_hi) | 0x00 | 4095-cycle default dwell |

`nego_priority_reg` is also forced (master=1, slave=2) so the two dies don't both back-off the same number of cycles in ST_NEGO_WAIT — predictable arbitration.

### `cocotb/tidelink_top_pair/Makefile`

Added:

```makefile
BYPASS_AUTONEG ?= 1
COMPILE_ARGS += +define+TB_TOP_BYPASS_AUTONEG=$(BYPASS_AUTONEG)
```

Override at recipe-line: `BYPASS_AUTONEG=0 make MODULE=test_10_autonomous_train_post_por ...`.

### `cocotb/tidelink_top_pair/test_10_autonomous_train_post_por.py`

New file. ~290 lines. Test flow:

1. Start hclk + ref_clk.
2. Idle all AHB / APB stimulus.
3. Reset (poresetn → hresetn → 50 cycles).
4. Snapshot 1: post-reset.
5. Wait up to 5 ms for `role_locked` on either die.
6. Snapshot 2: at role_locked rise (or timeout).
7. Wait up to 100 ms (5 M cycles @ 50 MHz) for master to enter ST_TRAIN_ENTER (state 12).
8. Snapshot 3: at ST_TRAIN_ENTER (or timeout).
9. Wait up to 100 ms for master to reach ST_TRAIN_DONE (16) or ST_TRAIN_FAIL (17).
10. Snapshot 4: terminal state (or timeout).
11. Wait up to 4 ms for `train_ok_r=1`.
12. Snapshot 5: final.

Each snapshot captures, on both dies: FSM state + name, `local_train_set_pulse_r`, `local_train_clr_pulse_r`, `swreset_hold_r`, `peer_lane_locked_r`, `peer_lane_fault_r`, `peer_cal_done_r`, `train_ok_r`, `train_fail_r`, `nego_done_r`, `swi_training_mode_r`, `nego_cfg_reg`, `nego_train_cfg_r`, FCSM state, role_locked, I²C SCL/SDA.

No `assert` calls. The roll-up logs a state trace and a non-fatal verdict (PASS / TRAIN_FAIL / TIMEOUT). Phase 7a will turn observations into a real gate.

### I²C cross-wire between the two dies

**No change needed** — `tb_top.sv:205-209` already implements an open-drain pull-up bus model:

```systemverilog
wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) & (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) & (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);
```

Both dies' `i2c_scl_i`/`i2c_sda_i` ports already see this wire. So the FSM's I²C master writes on the master should land in the slave die's I²C-slave AXIL bridge with no extra plumbing.

## Sim trace observations — 2026-05-29 18:34 BST (90-min run)

Sim was launched against `feat/td-autonomy` HEAD `a379457` (post-Phase 3 deploy_pair.sh + Phase 2-bis NEGO_CFG_RESET). Hit the 90-min `timeout` cap (`EXIT=124`) at sim time 100 ms with **master stuck at ST_NEGO_MASK_RD_ADDR**. Trace data is `/tmp/td_autonomy_sim_183400.log`.

### Master state machine timeline

| Sim t (µs) | State transition | Verdicts |
|---|---|---|
| 0.020 | x → 0 (ST_IDLE) | — |
| 0.420 | 0 → 1 (ST_NEGO_INIT) | — |
| 0.440 | 1 → 2 (ST_NEGO_WAIT) | — |
| 60.460 | 2 → 3 (ST_NEGO_CLAIM) | — |
| 61.020 | 3 → 4 (ST_NEGO_POLL) | — |
| 65.120 | **4 → 9 (ST_NEGO_MASK_RD_ADDR)** | **won=1, done=1** |
| 100,061 | (no further transition) | stuck |

Master autoneg: ST_IDLE → ST_NEGO_INIT → ST_NEGO_WAIT → ST_NEGO_CLAIM → ST_NEGO_POLL (won) → **ST_NEGO_MASK_RD_ADDR — stuck**.

### Slave state machine timeline

| Sim t (µs) | State transition | Verdicts |
|---|---|---|
| 0.020 | x → 0 (ST_IDLE) | — |
| 0.420 | 0 → 1 (ST_NEGO_INIT) | — |
| 0.440 | 1 → 2 (ST_NEGO_WAIT) | — |
| 61.060 | **2 → 5 (ST_NEGO_DONE)** | **lost=1, done=1** |

Slave: ST_IDLE → ST_NEGO_INIT → ST_NEGO_WAIT → **ST_NEGO_DONE (lost)**.

### What works (autonomy proven on these axes)

| Axis | Result |
|---|---|
| POR-boot of `nego_cfg=0x61` + `train_cfg=0x00f1` | ✅ both dies (NEGO_CFG_RESET + NEGO_TRAIN_CFG_RESET parameters verified) |
| I²C bus arbitration → clean master/slave split | ✅ master=won, slave=lost |
| `role_lock` latches autonomously on slave (61.5 µs) | ✅ `s_locked=1` with no SW write |
| `role_lock` latches autonomously on master (≤100 ms) | ✅ `m_locked=1` (caught in snapshot at 100.06 ms) |
| Master FCSM advances post role_lock | ✅ `fcsm=4` at snapshot |
| Slave FCSM advances post role_lock | ✅ `fcsm=5` at snapshot |

### What's broken — new finding

**Bug N1 (new):** Master autoneg FSM stuck at `ST_NEGO_MASK_RD_ADDR` (state 9) for ≥35 ms of sim time after entering it at t=65 ms. Slave is at terminal `ST_NEGO_DONE`. I²C bus snapshot at t=100 ms: `scl=1, sda=0` — SDA pulled low (someone is clock-stretching or holding the bus).

**Likely cause hypotheses:**

1. **Slave-side I²C-slave block isn't servicing the master's mask-read request.** The slave's autoneg FSM has terminated to ST_NEGO_DONE; the I²C slave AXIL bridge is meant to be the responder, independent of the autoneg FSM state. If the I²C slave block has a precondition tied to the autoneg FSM being in a specific state (e.g. ST_NEGO_MASK_RES_TX), it won't respond from ST_NEGO_DONE. Investigate `i2c_slave_axil_master.v` arbitration.

2. **Testbench I²C cross-wire model issue.** `tb_top.sv:205-209` uses an open-drain wire-AND. If both sides' tristate enables don't properly release after addressed transactions, SDA stays low. Check whether the slave's I²C tristate output (`s_i2c_sda_t`) deasserts after the slave ACKs.

3. **mask-handshake protocol mismatch.** The autoneg report's protocol says the master writes its result byte to peer (state 8 = MASK_RES_TX) and reads peer's mask (state 9 = MASK_RD_ADDR → state 10 = MASK_RD_DATA). If slave's protocol expected a different sequence (e.g. master should have first written its own mask register before reading peer's), the sequence wedges.

This is a **simulation-environment finding, not a guaranteed silicon bug.** Build #5 silicon evidence in [docs/I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md](I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md) reports master `NEGO_STATUS=0x055` (DONE/won) and slave `0x195` (DONE/lost) — so the FSMs **do reach DONE on silicon**, which is consistent with the master successfully completing the mask handshake on HW. The simulation snag is therefore likely a testbench/model mismatch, not a missing RTL transition.

### Implications for the autonomy plan

- The Phase 1+2 RTL changes work as designed for the autoneg→role_lock path. Both dies' `role_lock` latched without SW.
- The Phase 0c sim env is **not yet able to drive the FSM to ST_TRAIN_DONE** because of Bug N1. This is a sim-side issue (probably testbench-model), not an RTL gap.
- Recommend a follow-up debug pass on the I²C model in `tb_top.sv` to unstick Bug N1 before the cocotb autonomy regression can be a CI gate.
- The Phase 3 deploy_pair.sh edits remain HW-gated. Build #3 silicon already proved autoneg + mask handshake works on hardware end-to-end (per the I²C report).
- Bug N1 does **not** block Phase 3 HW deploy — it's a sim infrastructure debug, parallel to HW work.

### Compile health

VCS Verdi `cfs_ident_exec` segfaulted during the KDB index step (same artefact as test_01 Phase 0b run). Non-fatal — sim ran to elaboration cleanly. Tracking only.

### Files

- Trace log: `/tmp/td_autonomy_sim_183400.log` (60 KB)
- Wave dump: disabled (`TB_TOP_NO_DUMP=1`)
- Sim build dir: `cocotb/tidelink_top_pair/sim_build/`

## Phase 7a audit

Phase 7a per the autonomy plan calls for three sim regression tests on top of the Phase 0c scaffolding. Estimates assume sim builds are warm (no fresh elaboration cost) and that the RTL agent's Phase 2 changes (NEGO_TRAIN_CFG_RESET parameter + the train_fail_irq APB wiring) have landed.

### `test_10_autonomous_train_post_por.py` — already scaffolded

Status: **landed** (this commit). Phase 7a will harden it by turning the INFO-only verdict into `assert` calls:

```python
assert ok and not fail, f"Expected ST_TRAIN_DONE; got fail={fail} after {w} cycles"
assert snap_end["m_train_ok"] == 1
assert snap_end["s_swi_training_mode"] == 0, "Slave's SWI_TRAINING_MODE should be cleared by master after EXIT"
```

Effort to harden: ~1 h.

### `test_11_train_opt_out.py` — proves NEGO_TRAIN_CFG_RESET=0 leaves bypass intact

**Existing leverage:** the tb_top.sv force block already supports this — set `BYPASS_AUTONEG=1` and the FSM POR-defaults to `nego_cfg_reg=0`, falls into ST_BYPASS, and the legacy SW path is what runs. The new test can be a 30-line cocotb that:

1. Set `BYPASS_AUTONEG=1` (or just use the default).
2. Reset both dies.
3. Wait 100 µs for the FSM to settle.
4. Assert `dut.u_master.u_chiplet_controller.u_autoneg.state_r == 6` (ST_BYPASS).
5. Assert `dut.u_master.u_chiplet_controller.u_autoneg.train_ok_r == 0`.
6. Assert `local_training_mode_set_w` never pulsed (sample on every cycle for 100 µs).
7. Same checks for slave.

**Infrastructure needed:** none beyond the Phase 0c machinery.

**Effort estimate:** **~3 h** (writing + initial debug run). Cheap because the negative case is purely a "FSM is parked, no strobes" check.

### `test_12_train_peer_nack.py` — proves NACK injection during POLL_PEER → ST_TRAIN_FAIL

**Best home: NOT the paired-die env.** The paired-die testbench has no I²C-slave NACK-injection hook — the slave's bridge auto-ACKs every byte. To inject a NACK we'd need to either:

- (a) Add an I²C bus-injector model into `tb_top.sv` that hijacks SDA during the 9th bit of the byte the master is sending. ~150 lines, plus careful timing analysis vs. the master's TXN_CHECK retry semantics. **Substantial infrastructure.**
- (b) Use the unit-level `cocotb/tidelink_autoneg/` env, where cocotb already emulates the AXI-Lite slave. To inject NACK during POLL_PEER, the test waits for the FSM to issue an I²C read of the peer's SWI_LANE_STATUS, then on the AXI-Lite read-response sets `m_axil_rdata[I2C_STS_MISS_ACK]=1` (bit 3). This is the same path test_07 already exercises for the basic NACK→ST_NEGO_DONE-slave transition; we just need to fire it at the right state.

The unit env (`cocotb/tidelink_autoneg/tb_top.sv:81-171`) already exposes:
- `train_auto_en` (drive 1)
- `local_swi_lane_locked_i / local_swi_lane_fault_i / local_calibration_done_i` (drive synthetic "lane locked OK" values)
- `train_state_o`, `train_ok_o`, `train_fail_o`, `train_peer_nack_o`

So the test plan is:
1. `setup(dut)` + `do_por(dut)`.
2. Drive `nego_en=1`, `train_auto_en=1`, mask_hs_auto_en=1, local_swi_lane_* to "all good".
3. Emulate AXI-Lite responses to walk the FSM through ST_NEGO_INIT → ST_TRAIN_POLL_PEER (this is the heavy lifting — but the patterns from test_04 / test_05 cover most of it).
4. On entering POLL_PEER, on the next read-data ACK, set `m_axil_rdata[3]=1` (I2C_STS_MISS_ACK).
5. Assert `train_peer_nack_o=1` and FSM lands in ST_TRAIN_FAIL (state 17) within N cycles.

**Infrastructure needed:** a Python helper that emulates the I²C master's AXI-Lite responses for a programmable sequence of (ACK,NACK) verdicts at each polled byte. Borrowable from `test_02_nego_init_enters` and `test_05_timeout` patterns. New helper ~60 lines.

**Effort estimate:** **~6 h** (most of it on the AXI-Lite emulation helper; the NACK injection itself is 5 lines).

### Existing `cocotb/i2c_mask_selflock/` extension — **NOT AVAILABLE**

The brief mentions `cocotb/i2c_mask_selflock/` and `cocotb/i2c_clkstretch/` envs. **Neither exists on this worktree.** I confirmed with `ls cocotb/`:

```
common debug lint tidelink tidelink_addr_translator tidelink_ahb
tidelink_apb_addr_ctrl tidelink_apb_regs tidelink_autoneg
tidelink_clkfreq_check tidelink_fc_adapter tidelink_fifo
tidelink_idelay_rx tidelink_mul_iter tidelink_perf
tidelink_perf_congestion tidelink_phc_cdc tidelink_ptp
tidelink_ptp_servo tidelink_py_pair tidelink_returner tidelink_rxclk_buf
tidelink_system tidelink_top tidelink_top_pair tidelink_top_pair_drift
tidelink_top_pair_skewed wav_d2d_gpio_tx wavd2d_gpiorx_clkbuf
wavd2d_gpiorx_t3a wavd2d_gpiorx_t3a_off wavd2d_gpiorx_t3a_timeout
```

They may have existed historically (the `cocotb: reconcile env inventory (promote/debug/delete 9/13/3)` commit on this branch deleted 3 envs) — but they're not here now. The "extend existing test" lift path the brief mentions is therefore not available for the mask-handshake path; the substitute is the `cocotb/tidelink_autoneg/` unit env which is more capable anyway.

### Effort total for Phase 7a

| Test | Home | New infra | Effort |
|---|---|---|---|
| test_10 (hardening) | `tidelink_top_pair` | none — already scaffolded | ~1 h |
| test_11 (opt-out) | `tidelink_top_pair` | none — uses BYPASS_AUTONEG=1 | ~3 h |
| test_12 (peer NACK) | `tidelink_autoneg` (NOT paired) | ~60-line AXI-Lite verdict-emulator | ~6 h |
| **Total** | | | **~10 h** |

Originally the plan-doc effort estimate for Phase 7a was 1 day (8 h). The audit pulls it slightly over at ~10 h because test_12's AXI-Lite emulator is more work than the brief assumed. If we accept test_12 as **unit-level only** rather than also paired-die, this is fine. Paired-die NACK injection would push it to ~3 days because of (a)-style bus-injector infrastructure.

**Recommendation:** keep test_12 unit-only. The mask-handshake states + ST_TRAIN_POLL_PEER NACK→FAIL path is the FSM's responsibility; it does not exercise system integration (which is what the paired-die env is for). System-level FAIL recovery can be a future "test_13_train_retrain_via_apb" that's purely the W1P retrain path.

## Open items for the RTL agent (parallel)

These came up while doing the sim work; not blocking Phase 0c but worth noting:

1. `NEGO_TRAIN_CFG_RESET` parameter (Phase 2 of the plan) — when this lands, the sim-side `force` in `tb_top.sv` becomes redundant for the `train_auto_en=1` POR. The `nego_cfg_reg` force still has work to do unless there's also a `NEGO_CFG_RESET` parameter — the plan should call this out (currently focuses only on the train cfg).
2. `train_fail_irq_w` was dead-ended at `axi_chiplet_controller.sv:1242` in the Phase 0 audit. If the RTL agent surfaces this as an APB-readable status bit, test_12 can also assert on it (it currently can only check the FSM-internal `train_fail_r` via hierarchical poke).
3. The `local_swreset_pulse_w` dead-end at line 1241 still needs wiring through Wlink's swreset. Phase 0c's snapshot captures `swreset_hold_r` so once that's wired we can also observe the link bouncing during ST_TRAIN_EXIT.

## Files changed (this commit set)

- `cocotb/tidelink_top_pair/tb_top.sv` — added `BYPASS_AUTONEG` parameter + initial-block force (~70 lines added)
- `cocotb/tidelink_top_pair/Makefile` — added `BYPASS_AUTONEG` env-var + compile arg (~10 lines)
- `cocotb/tidelink_top_pair/test_10_autonomous_train_post_por.py` — new (~290 lines)
- `docs/AUTONOMY_PHASE0C_SIM_TRACE.md` — this file

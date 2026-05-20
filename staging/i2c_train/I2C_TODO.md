# I²C Autonomous Lock — Open TODO

State as of 2026-05-20 (evening bench session).
Branch `feat/i2c-autonomous-lock-integ` @ `a657306` (pushed), submodule @ `88fea5e` (pushed).

## Today's headline (2026-05-20 evening)

- ✅ **Autoneg works on silicon.** Diagnostic bitstream with the two fixes (`467b889` decouple `nego_driving` + `be5eed2` default `txn_step_nxt`) and 11 `mark_debug` probes wired into `u_dbg_int`. Master wins, slave loses, both `role_locked=1`, `nego_done=1`.
- ✅ **Full I²C transaction observable via ILA**: PRESCALE/DATA/COMMAND AXIL writes handshake clean, cmd_fifo loads, i2c_master core enters busy, SDA pulled low (START), SCL clocks. `busy_seen_r` correctly latches.
- ⚠️ **NEW Bug #3 discovered**: Mask phase (states 8/9/10) **never enters on silicon** despite NEGO_CFG[6]=1 (read back from chip). ILA armed on `state_r==9` for 30 s after fresh POR + autoneg kick: never triggered. `hs_result=0` on slave confirms master never wrote it. Sim takes this path correctly (per agent #1's test). **Same class as latch bug** — likely synth optimization pruning `nego_cfg_reg[6]` fanout.

---

## Phase 1 — Verify the cocotb-agent RTL fix on silicon ✅ DONE

- [x] Build with `467b889`+`be5eed2` + 11 `mark_debug` attrs + `FPGA_INSERT_DEBUG_CORE=1` (build #4 @ 16:07, build #5 @ 18:00)
- [x] Convert + stage to mapstone, redeploy
- [x] `run_i2c_test_fast.sh` shows `EVER i2c_addr=1`, `EVER sda_start_seen=1`, `EVER nego_done=1` on slave
- [x] Master `NEGO_STATUS=0x055 (DONE, won=1)`; slave `NEGO_STATUS=0x195 (DONE, lost=1)`
- [x] Both `role_locked=1` with correct roles
- [x] ILA capture on `mst_axil_awvalid==1` showed the complete CLAIM→POLL sequence with all 13 internal signals correct

## Phase 2a — Fix bug #3: mask phase synth-pruned (CANDIDATE FIX APPLIED)

The autoneg FSM's `if (mask_hs_auto_en)` branch silently doesn't fire on silicon, even though `NEGO_CFG[6]` reads back as 1 and `nego_cfg_reg[6]` is in synth's source. Same class as the `txn_step_nxt` latch bug — sim tolerates, synth optimizes badly.

- [x] **Applied**: `(* keep = "true" *) wire mask_hs_auto_en_kept = mask_hs_auto_en;` in `tidelink_autoneg.sv` lines 137 + `if (mask_hs_auto_en)` → `if (mask_hs_auto_en_kept)` (sub `72bc582`, parent `9f81947`).
- [x] **Cocotb regression**: 33 tests green across 7 suites (wlink_pair 9/9 + 4/4 + 3/3, wlink_pair_full 3/3, autoneg_i2c_e2e 3/3, tidelink_autoneg 7/7, i2c_mask_selflock 3/3, i2c_clkstretch 1/1). No regression. State 4→9 transition visible in `wlink_pair_full` log.
- [x] **Build #5**: kicked off with `FPGA_INSERT_DEBUG_CORE=1` (background task `bh7pvmvyk`, ~30 min).
- [ ] **Bench verify (next cycle)**: rebuild + redeploy + autoneg kick. ILA armed on `state_r==9` should now trigger. `hs_result=0x01` on slave should appear after autoneg completes.

If the keep-attribute doesn't take on silicon, escalation paths:
- [ ] Add `(* dont_touch = "true" *)` on `nego_cfg_reg` declaration in chiplet controller.
- [ ] Add `(* mark_debug = "true" *)` on `mask_hs_auto_en_kept` (forces preservation AND gives bench observability).
- [ ] Restructure the FSM `if` to a `case (mask_hs_auto_en_kept)` block — synth tools sometimes optimize cases differently than ifs.
- [ ] Spawn a cocotb agent to look for OTHER similar synth-only artifacts in the same pattern.

## Phase 2b — If Phase 1 still shows the bus inert (SUPERSEDED — phase 1 done)

The deploy workaround (`deploy_pair_autoneg.sh`, role_lock=0) did NOT make the master drive even with the FSM in POLL. ILA triggered on `(scl_o|sda_o|scl_t|sda_t)==0` for 15 s never fired. Either (a) the workaround didn't actually achieve role_lock=0 on silicon (sim says it should), or (b) there's a second bug only on silicon.

- [ ] Add **PS-readable observability** for `role_is_master`, `nego_role_r`, `nego_driving`, `axl_state_r`, `axl_done_r`. Right now ROLE_STATUS only exposes the role_effective output; we can't tell whether the pad mux is actually selecting master vs slave outputs at the moment of CLAIM. Suggest adding a debug-mirror register that latches these on every CLAIM/POLL transition.
- [ ] Read `i2c_master_axil` STATUS register directly. Currently inaccessible from PS during autoneg (bridge_axil is MUXed away when nego_driving=1). Either:
  - Temporarily set NEGO_CFG=0 (disable autoneg → nego_driving=0 → bridge_axil enabled → read STATUS via the AXI4 bridge path)
  - Or add a parallel PS-side read path for the i2c_master_axil status reg.
- [ ] Manually drive a known-good I²C transaction via bridge_axil (write PRESCALE/DATA/COMMAND directly from PS, bypassing the autoneg FSM). If THIS doesn't drive the bus, the i2c_master_axil core has a deeper problem. If it DOES drive, the autoneg FSM's AXIL writes during nego_driving=1 are being lost somehow.
- [ ] Compare HW ROLE_STATUS / NEGO_STATUS sample-by-sample against the cocotb agent's sim trace to find where they diverge.

## Phase 3 — NEGO_PRIORITY semantics check

When the deploy_pair_autoneg.sh ran (role_lock=0), the **slave's ROLE_STATUS bit 0 flipped 1→0 mid-run** (slave→master). The probe script gives master=1, slave=0xFFFF — observation suggests 0xFFFF wins. Either the script's priority assignment is inverted, or this was just both-boards-timing-out-and-claiming-master because the bus was inert. After Phase 1/2 unblocks the bus, retest:

- [ ] Confirm master z2_02 with `NEGO_PRIORITY=1` becomes master, slave z2_03 with `NEGO_PRIORITY=0xFFFF` becomes slave.
- [ ] If inverted: swap the script's assignment, OR fix the RTL priority comparison (whichever is wrong). Document in `nego_probe_fast.py` header.

## Phase 4 — Test on-ribbon W9/V7 as alternative pinning

Once P15/P16 + RTL fix is fully validated, **retest the original W9/V7 ribbon pinning** to see if the autonomous flow works there too (it should, if W9/V7 has external pull-ups). This would let the project ship on a single ribbon cable with no external Arduino-header harness.

- [ ] Solder external 2.2–4.7 kΩ pull-ups from W9 and V7 each to 3.3 V on one board (J13_PIN_BUDGET option b). 3.3 V available at J13 pin 1.
- [ ] Make a `pynq-z2-pair-all-w9v7` (and -flip-all) target variant that pins i2c_sda_io=W9, i2c_scl_io=V7. Keep the existing P15/P16 target as primary.
- [ ] Build + deploy + test. Compare to P15/P16 result. If clean: document W9/V7 as the cleaner long-term choice (single ribbon, no off-ribbon harness).
- [ ] Confirm the lane-7 remap collision warning in `J13_PIN_BUDGET.md` is still flagged (superproject 5d34baf moves pad_tx[7]/pad_rx[7] onto W9/V7).

## Phase 5 — Cleanup + merge

- [ ] Decide deploy-script disposition: if the RTL fix makes vanilla `deploy_pair.sh` work, retire `deploy_pair_autoneg.sh` (or keep as a documented alternative for cleaner-startup-trace).
- [ ] Update `docs/SHORTCOMINGS.md` §14a / §14b — promote from "blocked" to "resolved" with bench evidence + RTL commits.
- [ ] Update `staging/i2c_train/HW_VALIDATION_RESULTS.md` with final pass evidence (ILA capture of a successful CLAIM transaction).
- [ ] Run UVM regression once more on parent `910b5c7` to confirm no top-system regression from the `nego_driving` decoupling.
- [ ] Open MR feat/i2c-autonomous-lock-integ → feat/fpga-flow once stable. Reference the issue, link cocotb test_hw_repro_probe_seq.py as the HW-bug reproducer.

## Phase 6 — Cocotb scope gap to fix in the test suite

The cocotb agent's reproducer (`test_hw_probe_after_role_lock`) is now the canonical HW-bug regression. Before merging, harden it:

- [ ] Add to `cocotb/wlink_pair/Makefile` so it runs in CI alongside `test_autoneg_i2c_e2e`.
- [ ] Add a positive variant: same setup, but assert the master DOES drive scl_t==0 within N µs (acts as the regression guard for the gating bug).
- [ ] Consider extending `test_autoneg_i2c_e2e` parameter matrix to cover the `ROLE_CFG-write-before-NEGO_CFG` ordering as a permutation.

---

## Quick reference — what's where right now

| Item | Location |
|---|---|
| Branch tip (parent) | `feat/i2c-autonomous-lock-integ` @ `910b5c7` |
| Submodule tip | `467b889` (autoneg: decouple nego_driving from role_locked) |
| Worktree | `/tmp/i2c_wt` |
| New cocotb HW-repro test | `cocotb/wlink_pair/test_hw_repro_probe_seq.py` |
| Bench artefacts (current) | `mapstone-dev:~/tidelink_hwval/{tidelink,tidelink-flip}.{bit,bin,hwh,ltx}` (built from `3de5ebe`, no RTL fix yet) |
| Bench artefacts (next) | Will overwrite same path once farm build `b6suzp3z0` completes |
| JTAG access | `mapstone-dev.ecs.soton.ac.uk` hw_server :3121, targets `Z2_0[1-4]_TULA` |
| Deploy script variants | `deploy_pair.sh` (vanilla, sets role_lock=1) / `deploy_pair_autoneg.sh` (workaround, leaves role_lock=0) |
| HW probe | `run_i2c_test_fast.sh` → orchestrates `nego_probe_fast.py` on both boards |
| ILA capture playbook | `staging/i2c_train/HW_VALIDATION_RESULTS.md` §4 (also Phase 1/2 here) |
| Lease | bridge1, still held by mapstone-dev as of writeup |

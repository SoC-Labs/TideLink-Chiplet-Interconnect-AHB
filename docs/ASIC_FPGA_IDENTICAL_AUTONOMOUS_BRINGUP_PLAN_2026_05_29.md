# Plan: ASIC = FPGA Identical Autonomous Bring-up

**Date:** 2026-05-29 (revised same-day after current-HEAD audit)
**Branch:** `main` HEAD `59e35e5` (post-cleanup; was authored against `feat/td-gpio-phy-integration` HEAD `93d78ef`, now FF'd into main)
**Scope:** Close the autonomous-need gaps in TideLink RTL so that **the bring-up flow is identical on ASIC and FPGA targets**. Goal: `deploy_pair.sh` reduces to bitstream load + bond-emulation strap + status readback. Zero runtime APB writes.

> **Revision note 2026-05-29 (post-audit):** Initial draft suggested cherry-picking `feat/i2c-autonomous-lock-integ` commits (`6c38103`, `3607c4f`, `8c407bc`) for the training FSM. That branch has since been retired — its content (including the Bug #3 mask-FSM fix at `3d62cc3` and the `ST_TRAIN_*` state skeleton) is already merged onto `main`. The plan is therefore "wire up what's already there + change a reset value + delete SW writes", not a cherry-pick exercise. Line citations have been corrected against current HEAD; see revised gap table below.

## Pre-flight: what's actually already done (the I2C report under-credits the current tree)

A thorough audit of `main` HEAD `59e35e5` finds the training FSM **already merged** at the submodule level, contrary to what [docs/I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md](I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md) implies:

- [deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv](../deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv) — defines `ST_NEGO_DONE_PRE=5'd11 ... ST_TRAIN_FAIL=5'd17`, has full ENTER/RUN/POLL_PEER/EXIT/DONE/FAIL case arms, declares `train_auto_en` etc. as inputs, drives `local_training_mode_set/clr`, `local_swreset_pulse`, `train_state_o`, `train_ok_o`, `train_fail_o`.
- [src/rtl/local_overrides/axi_chiplet_controller.sv:1213-1232](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1213-L1232) connects all the new ports at `u_autoneg`, and lines 723–727 OR-merge `local_training_mode_set/clr` into `swi_training_mode_r`.
- `src/rdl/tidelink_regs.rdl` already defines `nego_train_cfg @ 0x10C` and `nego_train_status @ 0x110`. Region 8 (paddr[8:5]=4'b1000) is already routed inside the local-override wrapper.

What is **not** done — the genuine gaps:

| Gap | Where | Symptom |
|---|---|---|
| **G1.** `local_swreset_pulse_w` is dead | [`local_overrides/axi_chiplet_controller.sv:617`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L617) declares it, [`:1223`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1223) wires into FSM, [`:1241`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1241) ties to `_unused_phase3_a` | FCSM swreset still requires SW `0x208` poke even though FSM tries to fire |
| **G2.** `HARDEN_SWI_ENABLE=1` blocks bit[3] of `0x208` writes | [tidelink_top.sv:1751-1791](../src/rtl/tidelink_top.sv#L1751-L1791) (added intentionally at commit `1b628da`) | Even if the FSM/SW asks for swreset, it gets AND-masked to 0 before reaching Wlink |
| **G3.** `train_auto_en` reset value = 0 | [`local_overrides/axi_chiplet_controller.sv:718`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L718) (`nego_train_cfg_r <= 16'h0`) | The training FSM never engages at POR — SW must write 0x10C bit[0]=1 first |
| **G4.** `apb_debug_unlock_i` strap drives FPGA-only bypass + slave APB unlock | input port at [`tidelink_top.sv:331`](../src/rtl/tidelink_top.sv#L331), instance wire at [`:1835`](../src/rtl/tidelink_top.sv#L1835); `axi_gpio_debug_unlock @ 0x4404_1000` in BD | Strap GPIO write at deploy_pair.sh:325 is FPGA-only; production ASIC ties to 0 → SW writes would never land on slave |
| **G5.** `role_strap_i` and the `0x44040000` GPIO write | deploy_pair.sh:318-319 | Strap GPIO is FPGA-only; ASIC bonds a pad. Needs role decided in a way that has an ASIC analog |
| **G6.** `PAIR_BASE_ADDR` (0x44032000) SW write | deploy_pair.sh:329 | This is `addr_translator` config; in identical-address topology, it must be hardcoded at integration via `TIDELINK_PAIR_BASE` parameter |
| **G7.** `swi_phase_offset` SW write (slave only) | deploy_pair.sh:343, PHASE=0x00060000 | Per ASIC silicon path the cal FSM should produce per-lane phase; if a residual integer offset is needed it must come from a pad/strap or eFuse |
| **G8.** swreset+lltx toggle (0x208 sequence) | deploy_pair.sh:356-360 | Currently SW-driven; ought to ride on `local_swreset_pulse_w` (G1) |
| **G9.** Cocotb test for `train_auto_en=1` POR→link | None in `cocotb/tidelink_top_pair/` | Required acceptance criterion |
| **G10.** Bug A (AHB packet RX empty at slave) | `tidelink_fc_adapter.sv` per BUG_DIAGNOSES_2026_05_29 §1 | Orthogonal to autonomy work but blocks the success criterion ("packet RX works") |

---

## Phase-by-phase plan

### Phase 0 — Sim baseline + audit (1 day)

**Goal:** lock down the current state. Before touching anything, prove the existing FSM works in sim with `train_auto_en=1` against the paired-die env.

**RTL changes:** none.

**SW changes:** none.

**Verification:**
- Run `cocotb/tidelink_top_pair/` baseline (current 6 tests). Document which pass / fail in `feat/td-gpio-phy-integration`.
- Write one exploratory cocotb that simply force-writes `nego_train_cfg @ 0x10C = 0x1` on both sides at POR and observes the train FSM. **No assertion** yet — capture `state_r` traces, `local_training_mode_set/clr` strobes, `local_swreset_pulse` window, and the I²C bus.
- Audit `tidelink_autoneg.sv:911-1141` (the ST_TRAIN_* arms) for any obvious holes: e.g. the upstream skeleton noted `peer_lane_fault` was approximated by `peer_lane_locked_r ^ 8'hFF` — confirm whether the integrated version got a real fault-read sub-state or kept the crude derivation.

**Definition of done:** baseline cocotb run logged; reproducible. One internal trace shows the FSM walking `ST_NEGO_DONE_PRE → ST_TRAIN_ENTER → ST_TRAIN_RUN → ST_TRAIN_POLL_PEER → ST_TRAIN_EXIT → ST_TRAIN_DONE` even if it doesn't yet leave a working FCSM downstream.

**Effort:** 0.5 day audit + 0.5 day cocotb.

**Gate to Phase 1:** the FSM reaches `ST_TRAIN_DONE` in sim. (If it doesn't — return to upstream submodule bug-fix; don't proceed.)

---

### Phase 1 — Wire the dead swreset pulse (1–2 days)

**Goal:** close G1 + G2. The `local_swreset_pulse_w` output of the autoneg FSM must reach Wlink's `swi_swreset` register (the same bit that 0x208[3] would write) so that `ST_TRAIN_EXIT` actually re-inits the FCSM autonomously.

**Sequencing note (added 2026-05-29 post-audit):** Bug A is actively being debugged via mark_debug ILA probes on the credit-counter path + the new `cocotb/tidelink_top_pair/test_credit_ledger_probes.py`. Phase 1 should be **sequenced behind** that test's baseline capture, so the credit-zero pathology observed today isn't conflated with the new FSM-driven swreset window. Concretely: hold Phase 1 until `test_credit_ledger_probes.py` has run with `train_auto_en=0` (current behavior) and the credit-pair trace is logged. Then Phase 1's cocotb regression re-runs the same probe test with FSM-swreset live and diffs the credit trajectory — both runs should still hit Bug A symptoms if Bug A is independent (expected), or diverge if Bug A turns out to be entangled with swreset timing (unexpected, but the test will say).

**RTL changes — single integration-level edit:**

File: [src/rtl/tidelink_top.sv](../src/rtl/tidelink_top.sv)

The current Tier-2 hardening (lines 1751-1791) intercepts pwdata and clears bit[3]. The fix is to inject the FSM's `local_swreset_pulse_w` **after** the harden masks — bring `local_swreset_pulse_w` up from `u_chiplet_controller` (currently buried as `_unused_phase3_a` — promote it to a real output), then either:

- **Option A (recommended):** Have `u_chiplet_controller` issue a self-bypassing synthetic write into its internal APB shadow of Wlink 0x208 when `local_swreset_pulse_w=1`. This keeps the `harden_swi_*` predicate intact for external SW writes (which is the bug it was protecting against) but lets the FSM directly assert `swi_swreset` on the Wlink side. Concretely: add a `wlink_fsm_swreset_o` output to `u_chiplet_controller` and OR it into `apb_pwdata_to_chip[3]` only when the FSM is active. Update `harden_swi_block_swreset` to NOT mask when `wlink_fsm_swreset_o=1`.

- **Option B:** Bypass the APB path entirely. Bring Wlink's `swi_swreset` net up as a top-level input to Wlink's `EnableReset` register block, OR it with the existing register output, and feed `local_swreset_pulse_w`. This is a Wlink-level edit — invasive. Defer.

Option A wins on minimality.

Concrete edit footprint:
- `axi_chiplet_controller.sv` (local override): replace `wire _unused_phase3_a = local_swreset_pulse_w;` with `assign wlink_fsm_swreset_o = local_swreset_pulse_w;` + a new output port + wiring through the Wlink APB write to 0x208 (write `0x09` = swi_enable | swreset for `T_SWRESET_HOLD` cycles, then back to `0x01`). This is essentially the deploy_pair.sh:356-360 sequence, in RTL.
- `tidelink_top.sv`: remove the `harden_swi_block_swreset` AND-mask when `wlink_fsm_swreset_o` is asserted. Equivalently: change `harden_swi_block_swreset` predicate to `... & !wlink_fsm_swreset_o`.

**SW changes — deploy_pair.sh:**
- Delete lines 356-360 (the `0x208` swreset toggle). The FSM now produces it.

**Verification:**
- Cocotb `tidelink_top_pair`: assert `wlink_fsm_swreset_o` pulses for exactly `T_SWRESET_HOLD` cycles during `ST_TRAIN_EXIT`, with `apb_pwdata_to_chip[3]` reaching Wlink high during that window (and bit[0] held high too).
- Existing `test_04_pair_credit_counter_nonzero` (currently FAIL) is **not** expected to flip green — this only handles the FCSM swreset half; Bug A (FC adapter demux) is what currently kills credit flow. Treat test_04/05 as red even after Phase 1 — that's Bug A's problem.

**Definition of done:** FSM-driven swreset reaches Wlink in cocotb; `harden_swi_*` still blocks any *external* SW write that tries to clear `swi_enable`; deploy_pair.sh:356-360 is deleted; cocotb sweep with `train_auto_en=0` still passes test_01..03 (legacy bypass).

**Effort:** 1.5 days.

**Gate to Phase 2:** the cocotb FSM trace shows full `ENTER → RUN → POLL → EXIT(swreset asserted) → DONE` window plus a clean `swi_swreset` pulse landing at Wlink.

---

### Phase 2 — Hardcode `train_auto_en=1` reset value behind a parameter (0.5 day)

**Goal:** close G3. The training FSM must engage at POR with **no SW write**. But we also need the opt-out path (`train_auto_en=0`) for sim sweeps and bench debug.

**RTL change — one parameter, one reset value:**

File: [src/rtl/local_overrides/axi_chiplet_controller.sv](../src/rtl/local_overrides/axi_chiplet_controller.sv)

- Add module parameter `parameter NEGO_TRAIN_CFG_RESET = 16'h0001` (default = `train_auto_en=1`).
- Change `nego_train_cfg_r <= 16'h0;` at line 718 to `nego_train_cfg_r <= NEGO_TRAIN_CFG_RESET;`.

File: [src/rtl/tidelink_top.sv](../src/rtl/tidelink_top.sv)

- Add the same parameter at module level (default 16'h0001) and forward to `u_chiplet_controller`.

Cocotb opt-out: override the parameter via `defparam` or testbench wrapper for tests that need `train_auto_en=0`.

**SW changes:**
- No deploy_pair.sh changes yet (this phase is RTL-only). The `0x10C` write that would have been required is now eliminated for the autonomous path; legacy paths can still write `0x10C` to disable.

**Verification:**
- cocotb `tidelink_top_pair` test that simply: POR → wait → check `train_ok_w=1` on master without any APB write to 0x10C. Should pass.
- cocotb legacy regression with parameter override `NEGO_TRAIN_CFG_RESET=16'h0000`: existing test_01/02/03/06 must still pass.

**Definition of done:** parameter exists, default = autonomous; cocotb proves POR→`train_ok` autonomously; opt-out parameter override preserves legacy behavior.

**Effort:** 0.5 day.

**Gate to Phase 3:** `train_auto_en` behavior gated by parameter; legacy tests unaffected.

---

### Phase 3 — Retire deploy_pair.sh APB writes (1 day)

**Goal:** with Phases 1+2 landed, prove that deploy_pair.sh's role/training/swreset writes are redundant. Strip them out and prove the FPGA still brings up.

**RTL changes:** none.

**SW changes — `pynq_host/scripts/deploy_pair.sh`:**

Delete from the `python3 -c` block at lines 312-367:
- `struct.pack_into("<I",r,ro+0x80,$CTRL)` (line 344) — ROLE_CFG write. The autoneg FSM produces `nego_set_role_lock_w` which latches role_lock autonomously **provided** `mask_hs_gate_open` opens. After Phase 4 below the strap will also be gone — but for Phase 3 the strap stays; autoneg still works.
- `struct.pack_into("<I",w,wo+0x208,0x00027f09)` / `0x00027f01` / `0x00027f07` swreset triplet (lines 356-360) — replaced by Phase 1's FSM-driven swreset.

Keep for now (retired in Phase 4):
- `0x44040000` strap GPIO (line 319). Still needed to disambiguate die_a vs die_b in sim.
- `0x44041000` debug_unlock GPIO (line 326). Still needed because `mask_hs_match` may not yet be reaching from autoneg → gate in this FPGA build (depends on whether Bug #3 fix is fully landed for production paths — verify in sim+HW).
- `0x44030000` swi_phase_offset (line 343). Retire when calibrator fully covers it (separate audit).
- `0x44032000` PAIR_BASE_ADDR (line 329). Retire in Phase 5.

**Verification:**
- FPGA: full deploy on `pynq-z2-pair-all` + `-flip-all` pair. Expectation: `role_locked=1`, `train_ok=1`, `cal_done=1` on both sides without the deleted writes. Doorbell M↔S still works. (AHB packet RX may still be broken by Bug A.)
- ASIC sim (UVM `uvm/tidelink_integration/`): same test, `apb_debug_unlock_i=0`, `mask_hs_bypass_i=0`. **Today** this will fail at the mask handshake gate because the autoneg FSM's `autoneg_mask_hs_local_match` path interacts with the I²C-driven slave-side `wlink_mask_hs_result[0]` write — sanity-check that the mask handshake is genuinely closing the gate without `mask_hs_bypass_i`.

**Definition of done:** deploy_pair.sh has no APB writes to `0x44030208`, `0x44032080`. Link comes up. Cocotb `train_auto_en=1` test passes with `wlink_mask_hs_bypass_i=0` tied.

**Effort:** 1 day (incl. FPGA re-deploy + verify).

**Gate to Phase 4:** FPGA link up without the 2 deleted writes; cocotb passes with bypass=0.

---

### Phase 4 — Retire debug straps from autonomous path (1 day)

**Goal:** close G4. Prove that `apb_debug_unlock_i=0` and `mask_hs_bypass_i=0` is the production-default behavior with the autonomous FSM. Remove the `0x44041000` GPIO write from deploy_pair.sh. Mark the debug straps "TEST mode only / debug fallback".

**RTL changes:** none — but documentation:

In `axi_chiplet_controller.sv` (local override) around lines 405-417 (the `mask_hs_gate_open` comment block), add a clear "debug mode only" annotation:

```
// `apb_debug_unlock_i` and `mask_hs_bypass_i` are DEBUG STRAPS, tied to 0
// in production silicon. They exist for bench bring-up debug ONLY, to be
// driven by JTAG/TAP in fault-isolation flow. The autonomous bring-up
// path NEVER requires them — autoneg's mask handshake (Phase 2B already
// integrated, see Bug #3 fix at 85f0e48) produces `mask_hs_match` from
// `autoneg_mask_hs_local_match`. If you find yourself reaching for these
// straps in a deploy script, the autonomy regression has failed — fix the
// FSM or hardware, do not re-enable the strap.
```

**SW changes — deploy_pair.sh:**

Delete lines 325-326 (the `0x44041000` debug_unlock GPIO write). After this, FPGA bringup runs with `apb_debug_unlock_i=0` natively.

Also delete the comment block at 320-324 referencing the bypass workaround.

**FPGA BD changes:**
- Optionally: simplify the BD by removing `axi_gpio_debug_unlock` entirely (or leave it tied to 0). The pad cell can stay for TAP-driven debug entry but the AXI GPIO that drives it can be retired. Defer this BD cleanup to a follow-on commit — it's not on the autonomy critical path.

**Verification:**
- FPGA: re-deploy, confirm link comes up with the `0x44041000` write removed.
- ASIC sim: same as Phase 3, all 4 modules of the chiplet wired with `apb_debug_unlock_i=0`, `mask_hs_bypass_i=0`.

**Definition of done:** deploy_pair.sh contains zero strap-debug writes; FPGA bringup works; comment block in the RTL flags both signals as debug-only.

**Effort:** 1 day.

**Gate to Phase 5:** zero debug-strap dependence in autonomous path.

---

### Phase 5 — Eliminate `PAIR_BASE_ADDR` and `swi_phase_offset` SW writes (1 day)

**Goal:** close G6 and G7.

**RTL changes:**

File: [src/rtl/tidelink_top.sv](../src/rtl/tidelink_top.sv)

`PAIR_BASE_ADDR`: the RDL already parameterizes via `TIDELINK_PAIR_BASE`. Confirm the FPGA top-level wrapper passes `TIDELINK_PAIR_BASE = 32'h44032000`. If not, plumb the parameter through. For ASIC, the value will be different and must come from the top-level integration (a parameter in `tidelink_top` is the right surface).

`swi_phase_offset`: deploy_pair.sh:343 writes `0x00060000` (phase=3) on slave. **This is the per-lane phase override that was a Build-#1 workaround for the deserialiser-count-vs-framing race.** The calibrator FSM is supposed to produce the per-lane phase autonomously, but the per-lane phase output (`cal_phase_offset_w`) currently isn't proven equivalent to a static phase=3 in slave-mode silicon. **Action:** keep a small slave-only constant-offset injection wired into `cal_phase_offset_w`'s feed-in, tied to `role_is_master_o` low. This becomes an integration-level parameter rather than a SW write. **Caveat:** ideally the calibrator absorbs this fully — but if Build #3 silicon shows it needs the bias, hardcoding via parameter is the FPGA=ASIC-identical answer.

**SW changes — deploy_pair.sh:**

Delete:
- Line 329 `struct.pack_into("<I",r,ro+0x00,0x44032000)` — PAIR_BASE_ADDR. Replaced by `TIDELINK_PAIR_BASE` parameter.
- Line 343 `struct.pack_into("<I",w,wo+0x00,$PHASE)` — swi_phase_offset. Replaced by either calibrator (preferred) or parameter override (fallback).

**Verification:**
- FPGA: link comes up with both writes deleted.
- cocotb: `test_calibrator_probe_dump` confirms `cal_phase_offset_w` reaches the same effective value on slave as Build #3.

**Definition of done:** deploy_pair.sh's `python3 -c` block is now empty except for status reads.

**Effort:** 1 day.

**Gate to Phase 6:** deploy_pair.sh has **zero** writes beyond status reads and stand-alone strap GPIO.

---

### Phase 6 — Retire `role_strap` GPIO write; bond-pad model (0.5 day)

**Goal:** close G5.

`role_strap_i` is a **legitimate** input pad in production silicon — bonded at packaging to either VSS (master) or VDD (slave). On FPGA, the cleanest analog is a board-level pin (DIP switch, jumper) routed to a top-level pin, **not** a SW-driven GPIO.

Two options:

- **6a:** Move strap from `axi_gpio_strap @ 0x44040000` to a dedicated FPGA pin tied through a board-level jumper or DIP switch. In the meantime, retain the GPIO in BD but stop deploying writes to it — initial GPIO reset value = 0 = master for die_a; need a second bitstream `tidelink-flip` with reset value = 1 for die_b.
- **6b (lazier):** Keep the GPIO write at deploy_pair.sh, but call it out explicitly as "this is the bond-time strap analog; on production silicon this is a packaging-time choice."

**Recommendation: 6b for now, 6a as a future BD-cleanup follow-on.** 6b is closer to the user's stated goal of "implemented in a way that has an ASIC analog (e.g., a tied/bonded pad)" — the FPGA GPIO IS the analog of the bond pad; deploying it via SW once at bitstream-load time isn't really an APB poke after the link comes up.

**Documentation:** Add at top of deploy_pair.sh:

```
# The 0x44040000 write is the FPGA emulation of the ASIC's role_strap_i
# bond pad. On the chiplet this is wired at packaging — one of:
#   - VSS bond = die_a (master)
#   - VDD bond = die_b (slave)
# On FPGA we emulate the bond decision once at bitstream-load via
# this GPIO. Calling deploy_pair.sh with role=die_a vs role=die_b
# corresponds to the bond choice. This is NOT a runtime poke.
```

**SW changes:** no deletion; just a docstring/banner clarifying the role GPIO is bond emulation.

**Definition of done:** deploy_pair.sh role GPIO documented as bond-pad emulation; everything else is gone.

**Effort:** 0.5 day.

**Gate to Phase 7:** deploy_pair.sh effective surface = `role_strap` GPIO bond emulation + bitstream load + status readbacks. **Zero runtime APB writes.**

---

### Phase 7 — Verification harness consolidation (2 days)

**Goal:** close G9 and produce the formal acceptance gates.

#### 7a. Cocotb — new tests in `cocotb/tidelink_top_pair/`

Add three new tests:

1. **`test_10_autonomous_train_post_por.py`**: POR → no APB stimulus → confirm `nego_train_status.train_ok=1` on master AND slave's `swi_training_mode_r` cycled (1→0) AND both sides' `cal_done=1` AND FCSM advances to state ≥ 4. Pass criterion = all four conditions.

2. **`test_11_train_opt_out.py`**: Override `NEGO_TRAIN_CFG_RESET=16'h0000` parameter (sim-time). POR → write ROLE_CFG manually (mirror existing test_01) → confirm legacy bypass path works. Pass criterion = `role_locked=1` without any `train_ok` assertion (verify `train_state` stays at `ST_NEGO_DONE`, doesn't enter `ST_TRAIN_*`).

3. **`test_12_train_peer_nack.py`**: Inject a fault on the I²C bus during `ST_TRAIN_POLL_PEER` (e.g., gate SDA to GND for one transaction); confirm FSM transitions to `ST_TRAIN_FAIL` with `train_peer_nack=1` AND `train_fail=1`. Pass = correct fail state, irq asserted.

Plus extend `i2c_mask_selflock/test_mask_selflock.py` with a train-coordination assertion: after mask handshake match, the train FSM advances within bounded I²C cycles (`< 17 ms` worth of cycles).

#### 7b. Cocotb — pair sim acceptance gate

Add a new make target `make sim-autonomy-gate`:
- Runs `tidelink_top_pair` with default parameters (autonomous).
- Asserts `train_ok=1` on master within `2.83 ms × clock-ratio` after `role_locked_rise`.
- Asserts existing tests 01/02/03 still pass on the autonomous path.

#### 7c. FPGA acceptance gate

Add `pynq_host/scripts/deploy_pair_autonomous.sh` (or repurpose deploy_pair.sh) that does ONLY:
1. Bitstream load (with provenance guard, unchanged).
2. `0x44040000` write (role strap bond emulation, per Phase 6).
3. Status readbacks after a 1-second wait: `NEGO_STATUS @ 0x094`, `NEGO_TRAIN_STATUS @ 0x110`, `SWI_LANE_STATUS @ 0x108`, FCSM state.

Success criteria printed by the script:
- `NEGO_TRAIN_STATUS.train_ok = 1` on both sides
- `SWI_LANE_STATUS.lane_locked = 0xFF` on both sides
- `SWI_LANE_STATUS.fcsm_state = 4` on both sides
- Doorbell M↔S exchange — exists as separate `wlink_probe.sh` step.

#### 7d. UVM acceptance gate

Add to `uvm/tidelink_integration/` a `tidelink_autonomous_bringup_test.sv`:
- Drives `apb_debug_unlock_i=0`, `mask_hs_bypass_i=0`, no APB stimulus until link is up.
- After `nego_done` AND `train_ok` rise, exercise an AHB packet write and verify slave RX FIFO contents.
- Pass criterion: full handshake completes within timeout; AHB packet round-trip works.

**Definition of done:** four named tests + acceptance script land. CI runs cocotb-sim-autonomy-gate green pre-merge.

**Effort:** 2 days (one for cocotb tests, one for FPGA script + UVM scaffold).

**Gate to Phase 8:** all verification harnesses pass at the autonomous default; legacy `train_auto_en=0` regression still green.

---

### Phase 8 — Documentation & memory entries (0.5 day)

Update:
- `BRINGUP_REPORT.md` §9.8: replace "SW-coordinated training-mode entry" prose with "autonomous training-mode entry via tidelink_autoneg's ST_TRAIN_* states".
- `docs/I2C_AUTONOMOUS_BRINGUP_REPORT_2026_05_29.md` §3 table: update FPGA-today column to reflect what's no longer pokes.
- `docs/IMPLEMENTATION_STATUS.md`: mark autonomy gaps closed.
- New file `docs/AUTONOMY_PRODUCTION_RUNBOOK.md`: 1-pager that says "for a working autonomous bring-up: build, deploy, observe `NEGO_TRAIN_STATUS.train_ok`. If 0 after 1s, refer to fallback levels L1/L2/L3 below." Include the SW-fallback path (re-enabling `apb_debug_unlock_i` via debug TAP for fault isolation only).

**Definition of done:** docs reflect new reality; CI passes; merge candidate ready.

**Effort:** 0.5 day.

---

## Bug A interaction — recommendation

**Recommendation: run Bug A in parallel, NOT block on it, but also NOT promote the autonomy work to "verified" until Bug A is resolved.**

**Status update 2026-05-29 (post-audit):** Bug A is **actively under debug** — mark_debug ILA probes are placed on the FC-adapter RX FSM (`rx_state_r`, `rx_pkt_type`, `rx_is_fifo`) and the pair-credit-counter path. New cocotb tests on disk targeting Bug A: [`cocotb/tidelink_fc_adapter/test_rx_pkt_type_decode.py`](../cocotb/tidelink_fc_adapter/test_rx_pkt_type_decode.py) (hypothesis A-1 reproducer) and [`cocotb/tidelink_top_pair/test_credit_ledger_probes.py`](../cocotb/tidelink_top_pair/test_credit_ledger_probes.py). Bug B re-test via [`cocotb/tidelink_top_pair/test_ptp_corrected_regs.py`](../cocotb/tidelink_top_pair/test_ptp_corrected_regs.py) (using the correct `PTP_STATUS[2]` and `PTP_RX_PAYLOAD` registers per the morning diagnosis). These streams are running **before** any autonomy phase lands — the Phase 1 sequencing note now requires capturing their baselines first.

Rationale:
- Bug A (FC-adapter RX demux per [docs/BUG_DIAGNOSES_2026_05_29.md §1](BUG_DIAGNOSES_2026_05_29.md)) is in `tidelink_fc_adapter.sv` and concerns the data path after the link is up. The autonomy work is entirely about the bring-up sequence — credit-counter behavior and packet-write success are independent observables.
- The autonomy plan's success criterion in Phase 7c includes "Doorbell M↔S exchange works" — which DOES work on Build #3 silicon. That's the strongest evidence we should accept for "link is up". AHB packet RX is a separate (broken) downstream consumer.
- **Sequencing decision:** spin Phase 1-3 in parallel with the Bug A bisect ILA build **after** the credit-ledger probe baseline is captured. They share no source files (mark_debug attrs are on tidelink_top.sv lines 489-606; the Tier-2 hardening Phase 1 edits are at lines 1751-1791 — different regions). The two streams converge at Phase 7's UVM acceptance gate, which requires AHB packet round-trip — so Bug A must close before Phase 7d can be claimed green. Phases 7a/7b/7c can claim green without Bug A.
- **Risk amplification check:** if Bug A's root cause turns out to be an autoneg-induced timing change (e.g., the new swreset pulse from FSM falls at a moment that re-resets the FC adapter mid-burst), the autonomy work could become entangled. Mitigation: in Phase 1, the FSM's swreset window is `T_SWRESET_HOLD = 128 apb_clk` and only fires once at link bring-up. Bug A symptoms occur **after** bring-up. Low risk — and the Phase 1 cocotb re-run of `test_credit_ledger_probes.py` with `train_auto_en=1` is the disentangling experiment.

---

## Strap handling for production silicon

| Strap signal | FPGA today | ASIC production | Autonomy path dependency |
|---|---|---|---|
| `role_strap_i` | `axi_gpio_strap @ 0x44040000`, deploy-time write | Bond pad: VSS or VDD at packaging | **Legitimate.** Autonomy uses autoneg which only consults strap as the tie-breaker; if peer-mask handshake reaches match, role_lock asserts regardless of strap. |
| `apb_debug_unlock_i` | `axi_gpio_debug_unlock @ 0x44041000`, deploy-time write | **Tied to 0** in production; TAP-driven in debug | **Debug only.** Autonomy does NOT depend on this signal. After Phase 4 deploy_pair.sh never writes it. RTL comment block explicitly marks "DEBUG STRAP / TEST mode only". |
| `mask_hs_bypass_i` | `xlconst_mask_hs_bypass=1` in some BD variants | **Tied to 0** in production; TAP-driven in debug | **Debug only.** Autonomy depends on `autoneg_mask_hs_local_match` driving the gate, NOT this bypass. After Phase 3 cocotb verifies bypass=0 brings the link up. |

**Production hookup:**
- Production chiplet pad list: `role_strap` only. The two debug straps are not pins; they are TAP-controlled signals into the chiplet controller.
- Optional addition: a one-bit `test_mode_i` strap (separate bond) that gates the existing `mask_hs_bypass_i` and `apb_debug_unlock_i` paths via internal AND. This gives a single production-time opt-in for debug mode without needing TAP infrastructure. **Recommend** this as a small RTL addition during Phase 4 — adds 2 LUTs, doesn't change autonomy behavior, gives fab-time opt-out.

---

## Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Bug A still red after Phase 7 → AHB RX never works | Medium | Phase 7d acceptance gate fails | Don't claim ASIC-readiness until Bug A green. Phase 7a/b/c can still ship. |
| FSM swreset window collides with deploy-time hresetn glitch | Low | Re-test boot ambiguous; phase-3 cocotb may pass but FPGA hangs | Phase 1 cocotb's `T_SWRESET_HOLD` assertion needs to also check `hresetn` stable through window. Test 12 should cover this. |
| Peer NACKs ST_TRAIN_ENTER (e.g. peer bitstream not loaded yet, peer I²C slave wedged) | Medium | `train_fail=1`, link doesn't come up | FSM emits `train_fail_irq`. Document a `deploy_pair_autonomous.sh` retry: if train_fail asserts, issue `NEGO_TRAIN_CFG.train_retrain=1` (W1P), wait, observe. Add a single SW-driven retry attempt in the deploy script as recovery (not bring-up critical-path). |
| I²C bus stuck low at deploy (cable issue, slave I²C in E-wedge) | Low | Autoneg never advances; link never comes up | Existing `nego_timeout_reg` (default ~1.31 s) fires `ST_ERROR`. SW retry path = power-cycle. For bench: TAP-enable `apb_debug_unlock_i` and revert to legacy SW bring-up path. **This is the documented L3 fallback.** |
| Phase 1's Option A breaks Tier-2 hardening for external SW writes | Low | Buggy external SW can still wedge the bus | Phase 1 cocotb should include a regression: external SW write of `{swreset=1, swi_enable=0}` to 0x208 still gets masked. The new bypass should engage **only** when `wlink_fsm_swreset_o` is asserted. |
| Calibrator phase needs slave-side bias and parameter approach fails | Medium | Slave never locks lanes; ST_TRAIN_FAIL with `train_peer_lane_locked != 0xFF` | Phase 5 keeps a fallback `swi_phase_offset` write inside deploy_pair.sh, gated by an env var. If autonomous path needs the bias, document the parameter setting; if it doesn't, retire. |
| `NEGO_TRAIN_CFG_RESET=1` causes the autoneg FSM to deadlock during initial bring-up of a brand-new ASIC sample (pure HW debug) | Low | Sample appears bricked | Provide a JTAG-driven `apb_debug_unlock_i` assertion path (debug strap) to override gate and let TAP write `NEGO_TRAIN_CFG=0` post-POR. This is the documented "fab-floor first-silicon debug" recovery. |
| BD edit retires `axi_gpio_debug_unlock` and a future debug session needs it | Low | Future ILA build needs SW unlock | Don't delete the BD cell yet — just stop writing to it from deploy_pair.sh. Keep it for `tidelink-ila` and `tidelink-debug` bitstream variants. |

---

## Fallback levels (production silicon document)

- **L1 (autonomous):** `train_auto_en=1` (RTL default), `apb_debug_unlock_i=0`, `mask_hs_bypass_i=0`. POR → link up in ≤ 17 ms worst-case. **This is the design intent.**
- **L2 (hybrid recovery):** L1 + post-bring-up SW writes `NEGO_TRAIN_CFG.train_retrain=1` on transient unlock. Useful for EMI events. SW intervention is permitted post-link-up.
- **L3 (debug only):** TAP-asserts `apb_debug_unlock_i` and/or `mask_hs_bypass_i`. SW then takes over the bring-up path entirely. **Only for fault isolation on first-silicon debug.** Document that L3 path is NOT in any production runbook; it requires JTAG access.

---

## Critical files for implementation

- [src/rtl/tidelink_top.sv](../src/rtl/tidelink_top.sv) — Tier-2 hardening edit (Phase 1), `NEGO_TRAIN_CFG_RESET` parameter (Phase 2), `TIDELINK_PAIR_BASE` parameter (Phase 5)
- [src/rtl/local_overrides/axi_chiplet_controller.sv](../src/rtl/local_overrides/axi_chiplet_controller.sv) — promote `local_swreset_pulse_w` from `_unused_phase3_a` to real output (Phase 1), change `nego_train_cfg_r` reset (Phase 2), wire `wlink_fsm_swreset_o` (Phase 1), debug-strap annotation (Phase 4)
- [deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv](../deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv) — Phase-0 audit of ST_TRAIN_* arms; confirm peer fault read is real, not derived; ensure FSM closes cleanly
- [pynq_host/scripts/deploy_pair.sh](../pynq_host/scripts/deploy_pair.sh) — delete 6 APB writes over Phases 3–5
- `cocotb/tidelink_top_pair/` — add 3 new tests (Phase 7a): `test_10_autonomous_train_post_por.py`, `test_11_train_opt_out.py`, `test_12_train_peer_nack.py`
- `uvm/tidelink_integration/tidelink_autonomous_bringup_test.sv` — new UVM acceptance test (Phase 7d)

---

## Total effort summary

| Phase | Effort | Cumulative |
|---|---|---|
| 0 — Sim baseline + audit | 1.0 d | 1.0 d |
| 1 — Wire dead swreset pulse | 1.5 d | 2.5 d |
| 2 — `train_auto_en=1` reset value parameter | 0.5 d | 3.0 d |
| 3 — Retire 0x208 + ROLE_CFG SW writes | 1.0 d | 4.0 d |
| 4 — Retire debug straps | 1.0 d | 5.0 d |
| 5 — Retire PAIR_BASE_ADDR + swi_phase_offset writes | 1.0 d | 6.0 d |
| 6 — Role strap as bond emulation | 0.5 d | 6.5 d |
| 7 — Verification harness consolidation | 2.0 d | 8.5 d |
| 8 — Documentation & memory entries | 0.5 d | 9.0 d |

**~9 engineer-days total.** Bug A runs in parallel; gates Phase 7d only.

---

## End state

After Phase 8:

- `deploy_pair.sh` reduces to: bitstream load + 1× `role_strap` GPIO write (bond emulation) + status readback.
- POR → working link in ≤ 17 ms worst-case, identical RTL flow on FPGA and ASIC.
- `apb_debug_unlock_i=0`, `mask_hs_bypass_i=0` in default config; debug straps are TAP-only.
- All cocotb regression green; new autonomous test asserts POR→`train_ok=1` without SW.
- UVM acceptance test green for ASIC sim (gated on Bug A).
- L1/L2/L3 fallback hierarchy documented for first-silicon debug.

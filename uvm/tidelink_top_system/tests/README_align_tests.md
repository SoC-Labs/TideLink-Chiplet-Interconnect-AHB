# §9 Per-lane Bit-Slip Alignment — UVM Tests

These tests exercise the per-lane bit-slip + training-pattern mechanism added
to the Wavious GPIO PHY (BRINGUP_REPORT.md §9) on top of the full TideLink
stack. They complement the cocotb `wlink_pair/phy_align/test_pair_align.py`
sandbox by covering realistic **asymmetric** per-lane skew patterns that the
cocotb `pad_skid.sv` (uniform-only) cannot.

## TB plumbing

- `tb/pad_skid_lanes.sv` — per-lane shift-register skid block. Sits between
  the existing perturb mux and the cross-wired RX. Per-lane skid driven via
  the new `tb_if.{a2b,b2a}_skid_bits_per_lane[7:0][2:0]` signals (defaults
  all-zero so existing tests are unaffected).
- `tb/top.sv` — instantiates `pad_skid_lanes` on each PHY direction and adds
  two in-band `wlink_lane_checker` instances driving
  `tb_if.{a,b}_lane_locked`.
- `tests/test_top_align_base.sv` — UVM base class with:
  - hierarchical-ref helpers for `swi_bit_slip` / `swi_training_mode` on
    each `WavD2DGpio`,
  - per-lane slip sweep / calibration routine,
  - high-level `align_and_init_system(a2b, b2a)` task that runs the full
    training-mode → calibrate → exit-training → live-init flow.

## Tests

### 1. `test_align_uniform_skew`

Skid pattern: `[3,3,3,3,3,3,3,3]` on both directions.

Pass conditions:
- `tb_if.{a,b}_lane_locked == 8'hFF` after calibration.
- `init_system()` completes; Wlink + doorbell handshake succeed.
- A 4-word packet round-trips A→B and the scoreboard A2B compare passes.

### 2. `test_align_asymmetric_skew`

Skid pattern: `[3,5,0,2,7,1,4,6]` on both directions.

Pass conditions:
- All 8 lanes lock on each side; each lane's calibrated slip is independent
  (logged at `UVM_LOW`).
- A 3-packet burst round-trips through the calibrated link.

### 3. `test_align_one_dead_lane`

Same skid pattern as test 1, but with the A→B perturb hook forcing lane 4
stuck-at-0 BEFORE link-up. The §9 RTL cannot lock a stuck line because the
training byte for lane 4 is `8'h65`.

Pass conditions:
- `tb_if.a_lane_locked == 8'hFF` (B→A path healthy).
- `tb_if.b_lane_locked == 8'hEF` (lane 4 unlocked, others locked).

This test does NOT proceed to `init_system()` — calibration cannot complete
on a dead lane and the FCSM never reaches state 4. It validates only that
the un-trainable lane is observable through the existing UVM hooks.

### 4. `test_align_recalibration_after_link_drop`

Brings the link up at uniform skid=3, sends a packet so `DOORBELL_RESP_ACC`
ticks, pulses `poresetn` to simulate a transient, then re-trains and sends
another packet.

Pass conditions:
- `tb_if.{a,b}_lane_locked == 8'hFF` after the re-calibration.
- Post-transient `DOORBELL_RESP_ACC > 0` on both sides (counter restarts
  from zero on the POR but advances on the new traffic).

Note: the original spec asked for "counters continue from where they left
off"; with a hardware POR that's impossible (counters are POR-reset). The
test demonstrates the *behavioural* equivalent: after the transient the
link bridges traffic again and the counter is observed advancing.

## How to run

From `uvm/tidelink_top_system/`:

```sh
source ../../set_env.sh        # sets DESIGNWARE_HOME, XHB500 paths, etc.

make run TEST=test_align_uniform_skew
make run TEST=test_align_asymmetric_skew
make run TEST=test_align_one_dead_lane
make run TEST=test_align_recalibration_after_link_drop
```

Add `SEED=<n>` for deterministic seed; `VERBOSITY=UVM_HIGH` for verbose
calibration logs. The full align suite is also exposed via the
`TESTS_ALIGN` Make variable.

## Limitations / follow-ups

- The hierarchical-reference writes to `swi_bit_slip` / `swi_training_mode`
  are simulation-only (matches the cocotb sandbox). When the autoneg block
  grows an APB-driven path for these registers, the base class should be
  switched to use APB writes instead.
- `test_align_one_dead_lane` stops at the lane-lock check. A natural
  follow-up (when autoneg auto-masks failed lanes) would re-run
  `init_system_with_lane_mask` and confirm traffic still bridges on the
  remaining 7 lanes.
- The in-band `wlink_lane_checker` cross-clock paths (the checkers run on
  each side's recovered RX link clock) intentionally don't have CDC
  hardening — they're observation-only, sampled by tests well after the
  link has stabilised.

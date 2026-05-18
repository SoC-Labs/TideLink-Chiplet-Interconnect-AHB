# Staggered Bring-up Autocal Reproducer — Findings

**Status:** Reproducer added; trunk `clk_en` fix partially solves the FPGA-reported
failure mode but a residual slave-side failure remains. Protocol-level Fix B
(I²C-coordinated training entry/exit) is still required for a full solution.

**Scope:** Single cocotb test `cocotb/phy_align/test_pair_align_staggered_bringup.py`
that exercises the §9 autocal FSM under staggered POR — the bring-up flow that
fails on the Pynq-Z2 pair after both bitstreams are loaded.

## 1. What the test does

`test_staggered_bringup_reproduces_fpga_failure` exercises the existing
`tb_top` with two `axi_chiplet_controller` instances cross-wired through
`pad_skid`, after forcing `autocal_force_enable_q = 1` on both sides (the
hierarchical-force hook the integration agent added to the controller). The
test sequence:

1. Clean POR on both sides.
2. Release **master** POR; lock master role. The calibrator's
   `role_locked` input rises.
3. Wait 4096 master-clocks (= 16× the worst-case 256-cycle sweep window).
   Slave is still held in POR, so the slave's TX clock pad is gated — and
   crucially the master's RX recovered link clock is therefore not toggling
   in a way that lets the master's calibrator FSM run.
4. Release **slave** POR; lock slave role. Slave's calibrator's role_locked
   input now rises.
5. Wait for slave's `cal_calibration_done` (or time out at 8000 apb_clk
   cycles).
6. Read APB status on both sides at the new `tidelink_phy_align_regs`
   offsets:
   * `0x1008  SWI_LANE_LOCKED`  (RO, live from lane checker)
   * `0x100C  SWI_LANE_FAULT`   (RO, sticky from calibrator)
   * `0x1010  SWI_CALIB_DONE`   (RO, [0]=cal_done, [11:8]=cal_state)
7. Classify each side's outcome and assert the failure mode.

## 2. Observed result

With the current trunk RTL (which includes both the autocal FSM **and** the
just-landed `gpiotx_N_io_clk_en` gating that OR's `effective_training_mode`
into the clk-en for all 8 lanes):

| Side   | SWI_LANE_LOCKED | SWI_LANE_FAULT | SWI_CAL_DONE | cal_state | Classification |
|--------|-----------------|----------------|--------------|-----------|----------------|
| master |       0x00      |      0x00      |    0x0401    |     4     | **CONVERGED**  (every lane locked, no faults; `lane_locked` is live and drops once training ends) |
| slave  |       0x00      |      0xFF      |    0x0401    |     4     | **FPGA FAILURE MODE**  (every lane exhausted its slip values without locking) |

This **partially reproduces** the FPGA-reported failure (`SWI_LANE_LOCKED =
0x00, SWI_LANE_FAULT = 0xff, SWI_CALIB_DONE = 0x0401, state field = S_DONE = 4`)
on the **slave** side. The FPGA flow reports it on the master because the
FPGA master comes up first; in the cocotb stagger we wake the master first
but the master ends up converging because of the new clk_en gating (see §3
below). The *sequencing* relationship is identical: **the side whose autocal
fires while the peer is no longer in training mode loses all 8 lanes**.

## 3. What changed once the clk_en fix landed

Before the trunk fix, `gpiotx_N_io_clk_en` was `io_link_tx_tx_en | postcount
!= 0 & ...`. With `io_link_tx_tx_en = 0` (the link layer hasn't enabled TX
yet because the FCSM is still in SEND_CREDITS1), the GPIO TX serialiser's
clock was gated off entirely. The peer's RX recovered link clock was
therefore not running, and the peer's calibrator FSM (which is clocked on
that recovered RX clock) was stalled in S_IDLE.

After the trunk fix (`gpiotx_N_io_clk_en = io_link_tx_tx_en | ... |
effective_training_mode`):

- While **master** is locked-but-pre-sweep and slave is still in POR,
  slave's `effective_training_mode = 0` and `io_link_tx_tx_en = 0`, so
  slave's TX pad clock stays gated. Master's RX recovered link clock
  doesn't toggle. **Master's calibrator FSM stalls in S_IDLE for the whole
  4096-cycle isolation window — the original master-side FPGA failure mode
  cannot occur because the master FSM literally cannot advance without a
  peer TX clock.** (The cocotb log confirms this: `cal_state=0`,
  `cal_done=0`, `cal_lane_fault=0x00` after 4096 cycles.)
- When **slave** wakes up and is locked, slave asserts `training_mode = 1`
  on its TX. That brings up slave's TX pad clock → master's RX recovered
  clock starts ticking → master's calibrator detects the role_locked rising
  edge it has been waiting for, enters S_ARM → both sides are now in
  training mode concurrently → master locks all 8 lanes.
- But master finishes its sweep first (master entered S_SWEEP first by a
  small margin) and goes to S_DONE → master's `training_mode` drops back
  to 0. Slave is still mid-sweep; slave's lane checker can no longer lock
  on master's now-not-training TX. Slave runs through all 8 slip values
  unsuccessfully → marks all 8 lanes faulted → goes to S_DONE with
  `lane_fault = 0xFF`.

So **the clk_en fix solves the master side** of staggered bring-up (the
master FSM naturally waits for peer TX to come up), but the **slave side
still fails** because the master's TX exits training mode as soon as its
own sweep completes, leaving the slave with no training pattern to lock to.

## 4. Recommended fixes

### Fix A — clk_en gating in WavD2DGpio (already landed in trunk)

Required, and has solved the master-side failure. Document this as the first
half of the bring-up alignment story. Without this fix, the master FSM would
have completed an isolated sweep and faulted all 8 lanes regardless of any
upper-layer protocol changes.

### Fix B — I²C-coordinated training entry/exit (recommended next)

The slave failure documented above cannot be solved by RTL changes inside the
autocal FSM alone — the fundamental problem is that the master has no way of
knowing when the slave has joined the training pattern, so it can't choose
to stay in training mode "until both peers see lock". The high-speed link is
not yet aligned at this point, so it cannot carry coordination traffic.
I²C is the natural sideband, and the autoneg FSM already has the AXI-Lite
I²C transaction primitives needed.

Land the design specified in `staging/i2c_train/I2C_TRAIN_PROTOCOL.md`:

* Master and slave both enter `swi_training_mode = 1` on the I²C-coordinated
  `ST_TRAIN_ENTER` state.
* Master polls slave's `SWI_LANE_LOCKED` (and `SWI_CALIBRATION_DONE`) over
  I²C, waiting until **both** local and peer report all 8 lanes locked.
* Master tells slave to exit training (`ST_TRAIN_EXIT`); both drop
  `swi_training_mode = 0` and proceed to FCSM bring-up.

Once Fix B lands, the test in this directory should be **flipped** to assert
the success condition (`s_lane_fault == 0x00 and m_lane_fault == 0x00`)
under staggered bring-up.

### Fix C — make the autocal FSM hold training_mode until peer is also done (alternative to Fix B)

A purely-RTL alternative: instead of going to S_DONE immediately after the
local sweep finishes, the FSM could **hold `training_mode = 1`** in a
"wait for peer locked" state until `lane_locked == 0xFF` for at least N
consecutive cycles after every lane has either locked or faulted. The
re-arm trigger on `swreset` toggle (already present in the FSM) lets SW
abort if the wait is taking too long.

This is simpler than Fix B (no I²C state machine extension) but trades off
a guaranteed bound on training-mode duration: a permanently broken peer
would leave one side stuck in training. The FSM would need a configurable
max-wait counter.

## 5. Recommendation

**Land Fix B (I²C-coordinated training)** first because it provides a
deterministic bound on the training window and reuses the existing autoneg
I²C transaction infrastructure. Keep Fix C in the back pocket as a fallback
for designs where the I²C sideband is not available.

The reproducer test in `cocotb/phy_align/test_pair_align_staggered_bringup.py`
should be promoted from "asserts the failure mode" to "asserts the success
mode" the moment Fix B's `ST_TRAIN_*` states are integrated into
`tidelink_autoneg.sv`.

## 6. Files added / modified in this worktree

* `cocotb/phy_align/test_pair_align_staggered_bringup.py` (new — the
  reproducer test).
* `staging/staggered_bringup/REPRODUCER_REPORT.md` (this file).

No RTL or trunk-test changes were made. Existing wlink_pair tests
(`test_link_bringup.test_01` … `test_06`, `test_assert_bringup.test_07` …
`test_09`) and phy_align tests (`test_pair_align`, `test_pair_align_asymmetric`,
`test_pair_align_retraining`) all still pass.

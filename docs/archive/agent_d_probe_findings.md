# Agent D probe findings — calibrator AUTOCAL=1 dump

**Test:** `cocotb/tidelink_top_pair/test_calibrator_probe_dump.py`
**Dump:** `docs/agent_d_probe_dump_autocal1.log` (2000 cycles)
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix`
**Date:** 2026-05-26

## TL;DR — the first observable asymmetry

The calibrator FSM reaches `S_DONE` on both sides with `cal_done=1` and
`cal_state=4` on both sides. BUT the latched per-lane `(phase, slip)`
values differ identically across all 8 lanes:

| lane | M phase | S phase | M slip | S slip |
|------|---------|---------|--------|--------|
| 0..7 | **0** | **1** | **0** | **1** |

This is the first asymmetry between master and slave in the post-bringup
window. Every downstream PHY-layer signal is symmetric on both sides
(`cal_training_mode_w` constant=0, `effective_training_mode` constant=0,
`lane_locked` constant=0, `lane_fault` constant=0) — i.e. the calibrator
believes both sides finished cleanly. The mismatch is **in the latched
per-lane (phase, slip) registers themselves**.

Master TX bytes show ~8 cycles of non-zero data starting at cy=35
(values `03 0a 09 01 02 08 18`) when the M->S doorbell packet is being
emitted. These bytes arrive at the slave's pad-RX bit-exact (skid is a
passthrough, `m_pad_tx == s_pad_rx_seen` throughout). But the slave's
deserialiser is configured with `phase=1, slip=1` while the master TX
was emitted under `phase=0, slip=0` calibration. The slave decodes the
M bytes through a different per-lane rotation than the master encoded
them with — the resulting bytes do not parse as a valid FC packet and
the slave's `tl_fc_l2a_valid` never asserts.

## Doorbell crossing

- Pre-doorbell  `DOORBELL_RESP_ACC`: M=0 S=0
- Post-doorbell `DOORBELL_RESP_ACC`: M=0 S=0
- Doorbell crossed: **False** (HW bug reproduced in sim)

## Calibrator latched per-lane state (after S_DONE)

| lane | M phase | S phase | M slip | S slip | phase ==? | slip ==? |
|------|---------|---------|--------|--------|-----------|-----------|
| 0 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 1 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 2 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 3 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 4 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 5 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 6 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |
| 7 | 0 | 1 | 0 | 1 | **DIFFER** | **DIFFER** |

Master latched at `(slip=0, phase=0)` → trivial / first sweep point.
Slave latched at `(slip=1, phase=1)` → near-trivial / second sweep
point.

## Pad activity (transitions per signal over window)

- `m_pad_tx` transitions: 8   (the M->S doorbell packet)
- `s_pad_rx_seen` transitions: 8   (skid passthrough — identical waveform)
- `s_pad_tx` transitions: 0
- `m_pad_rx_seen` transitions: 0

## Symmetric-signal first-divergence summary

Cycle at which M and S samples first disagree (None = stayed identical).

- `m_cal_state` vs `s_cal_state`: identical throughout window (both = S_DONE)
- `m_cal_done` vs `s_cal_done`: identical throughout window (both = 1)
- `m_cal_train_mode` vs `s_cal_train_mode`: identical throughout window (both = 0)
- `m_phy_train_in` vs `s_phy_train_in`: identical throughout window (both = 0)
- `m_phy_eff_train` vs `s_phy_eff_train`: identical throughout window (both = 0)
- `m_lane_locked` vs `s_lane_locked`: identical throughout window (both = 0)
- `m_lane_fault` vs `s_lane_fault`: identical throughout window (both = 0)
- `m_fc_a2l_v` vs `s_fc_a2l_v`: first diverge @ cy=4 M=1 S=0  ← master's FC adapter submits, slave's never does
- `m_fc_l2a_v` vs `s_fc_l2a_v`: identical throughout window (both = 0)  ← slave NEVER receives a packet
- `m_fcsm_state` vs `s_fcsm_state`: first diverge @ cy=29 M=5 S=4  ← master FCSM transitions to SEND_PKT state, slave stays in LINK_IDLE

## Pad-wire integrity

- `m_pad_tx` matches `s_pad_rx_seen` throughout (skid passthrough verified)
- `s_pad_tx` matches `m_pad_rx_seen` throughout (skid passthrough verified)

Skid is NOT the bug. The bytes the master emits arrive bit-exact at the
slave's pad pins. The asymmetry is purely in the deserialiser
configuration.

## FC adapter pulse counts (cycles asserted in window)

- M a2l_valid: 1   a2l_ready: 2000   l2a_valid: 0
- S a2l_valid: 0   a2l_ready: 2000   l2a_valid: 0

Master's FC adapter DID submit the doorbell packet for one cycle (cy=4).
Slave's FC adapter never sees a valid l2a packet — the Wlink RX stack
on the slave never decoded a valid packet out of the M->S bytes.

## Per-signal histograms (top entries)

- `m_cal_state`: constant=4 (S_DONE)
- `s_cal_state`: constant=4 (S_DONE)
- `m_cal_done`: constant=1
- `s_cal_done`: constant=1
- `m_cal_train_mode`: constant=0
- `s_cal_train_mode`: constant=0
- `m_phy_train_in`: constant=0  (chiplet_controller swi_training_mode_in to PHY = 0)
- `s_phy_train_in`: constant=0
- `m_phy_eff_train`: constant=0  (PHY effective_training_mode = 0)
- `s_phy_eff_train`: constant=0
- `m_lane_locked`: constant=0  (lane_checker is reset/idle once training drops)
- `s_lane_locked`: constant=0
- `m_lane_fault`: constant=0
- `s_lane_fault`: constant=0
- `m_pad_tx`: 0:1993, 3:1, 10:1, 9:1, 1:1, 2:1, 8:1, 24:1  ← 7 non-zero bytes (the doorbell packet)
- `s_pad_rx_seen`: 0:1993, 3:1, 10:1, 9:1, 1:1, 2:1, 8:1, 24:1  ← matches m_pad_tx
- `s_pad_tx`: constant=0  (slave is idle — has nothing to send)
- `m_pad_rx_seen`: constant=0
- `m_fc_a2l_v`: 0:1999, 1:1
- `m_fc_a2l_r`: constant=1
- `m_fc_l2a_v`: constant=0
- `s_fc_a2l_v`: constant=0
- `s_fc_a2l_r`: constant=1
- `s_fc_l2a_v`: constant=0
- `m_fcsm_state`: 4:1994, 5:6  ← LINK_IDLE -> SEND_PKT briefly
- `s_fcsm_state`: constant=4  ← stays in LINK_IDLE

## Probe-path validation

All hierarchical references resolved cleanly — no `x` cells in the CSV
for any probed signal. Adjustments from the starter map in the handoff:

- `dut.u_master.cal_state_w` → `dut.u_master.u_chiplet_controller.cal_state_w`
  (and the same `u_chiplet_controller.` prefix for every `cal_*_w`,
   `u_calibrator.*`, `u_lane_checker.*` and `u_wlink.*` access).
- The "PHY effective training" signal lives at
  `u_chiplet_controller.u_wlink.phy.gpio.effective_training_mode` (the
   PHY instance is named `phy`, not `u_phy`).
- The PHY pre-mux training input is `io_swi_training_mode_in`
  (Verilog port name — not `swi_training_mode_in`).
- Per-lane phase / slip are unpacked-array regs inside the calibrator —
  accessed as `u_calibrator.phase[lane]` / `u_calibrator.slip[lane]`
  via cocotb 2.x array indexing.

## Verdict — top concrete hypothesis

The bug is a **per-lane (phase, slip) latch asymmetry inside the
best-of-sweep calibrator**. With `EARLY_EXIT_ON_ALL_LOCKED=0` (silicon
default in `tidelink_top.sv` — `tb_early_exit_force_q` is never raised
in this paired-die testbench), the calibrator walks the full
128-point (phase, slip) sweep and at sweep-exhaustion latches the
per-lane `(phase, slip)` from whichever sweep point had the **longest
in-dwell run-length of `lane_locked=1`** (`best_score`, see
`src/rtl/tidelink_phy_align_calibrator.sv:604-664`).

Master and slave see DIFFERENT training byte sequences during the
training window (because each side rotates its own `(phase, slip)`
iterator over its OWN per-lane training pattern, and the lane_checker
on each side observes the **peer's** TX). With both sides sweeping
concurrently, the windows where the master's checker sees its
expected pattern at score `>= LOCK_THRESH` are at a DIFFERENT
`(phase, slip)` than the windows where the slave's checker does.
Result: both sides reach `cal_done=1` but with non-matching latched
values — and once `training_mode` deasserts, the two deserialisers
parse the live data through different per-lane rotations.

The crucial observation: **the latched values must be COMPATIBLE
across the pair, not just each "best" for its own side**. Either:

  (a) the calibration sweep needs to be sequential / staged so only
      one side is sweeping at a time; or
  (b) the latch criterion needs to favour `(phase=0, slip=0)` or
      another canonical fixed-point when both reach LOCK_THRESH; or
  (c) the post-DONE configuration needs to be negotiated/exchanged
      between the dies via the I²C sideband before training drops.

For the static auditors to investigate (in priority order):

1. **`tidelink_phy_align_calibrator.sv:604-664`** — the
   `best_score` capture and end-of-sweep latch. Verify whether two
   independent sweeps running concurrently on M and S can latch
   to NON-MATCHING `(phase, slip)` even though both reach
   `LOCK_THRESH` at their respective best points.
2. **The interaction with `T3.2 S_HOLD`** — note that
   `tb_early_exit_force_q` defaults to 0, so the calibrator should
   take the `S_HOLD` branch (8 sweep-periods of holding training
   high). But the test reports both sides at `cal_state=S_DONE` after
   bringup, suggesting the sim DID get through HOLD. Is the hold
   actually waiting long enough for the peer's sweep to ALSO settle?
   (`HOLD_CYCLES = 8 * 128 * DWELL_CYCLES = 65536` cycles by default
   — sims much shorter than this would exit prematurely.)
3. **The lane_checker's reference byte** — each lane has a different
   training byte (`8'hA3 / 0xB5 / 0xC9 / ...` per `WavD2DGpio.v`).
   The checker's lock criterion is byte-rotation-aware. But after
   the calibrator drops training, the deserialiser keeps the
   per-lane (phase, slip) rotation it latched. Verify that
   "lane_checker locked at (slip_i, phase_i) on training byte" is
   the SAME deserialiser configuration as "Wlink LL byte-aligned at
   the same (slip_i, phase_i) on a 16-bit data packet".

## Reproducer

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix
source set_env.sh > /dev/null 2>&1
cd cocotb/tidelink_top_pair
make MODULE=test_calibrator_probe_dump
# Wall time: ~12 minutes on a loaded host (10 GB VCD).
# Outputs to ../../docs/agent_d_probe_dump_autocal1.log + agent_d_probe_findings.md
```

The test PASSES regardless of whether the bug reproduces — its job is
to record evidence, not to assert. The verdict for the auditors lives
in this `.md` file and in the CSV dump.

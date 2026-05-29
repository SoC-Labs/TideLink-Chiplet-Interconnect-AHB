# Agent C — chiplet-controller-pair unit-level repro log

Date: 2026-05-26
Branch / worktree: `td-bisect/td-calibrator-fix`
New env: `cocotb/tidelink_chiplet_pair_autocal/`

## What I built

A new cocotb test env that pairs two `axi_chiplet_controller` instances with
`.AUTOCAL_ENABLE(1'b1)` parameter override on both, cross-wired through
the same `pad_skid` model used by `cocotb/wlink_pair/`. The TideLink wrapper
(fc_adapter / returner / fifo / ahb / ptp) is stripped — only the chiplet
controller (which already contains the calibrator + Wlink + PHY + autoneg
+ R8 SW regs) is in scope.

Files:
- `cocotb/tidelink_chiplet_pair_autocal/tb_top.sv` — pair tb with
  `AUTOCAL_ENABLE=1'b1` defparam, mirror wires for `m_/s_cal_cur_state`,
  `lane_locked_w`, `cal_training_mode`, `cal_calibration_done`,
  `cal_phase_offset_w`, `cal_bit_slip_w` to make cocotb-side probing easy.
- `cocotb/tidelink_chiplet_pair_autocal/pad_skid.sv` — copy of wlink_pair.
- `cocotb/tidelink_chiplet_pair_autocal/Makefile` — copies wlink_pair's
  shape; default MODULE = `test_calibrator_state_probe`.
- `cocotb/tidelink_chiplet_pair_autocal/test_calibrator_state_probe.py` —
  passive bring-up + 10k-cycle histogram of calibrator state, FCSM state,
  lane_locked_w, phase_offset on both M and S.
- `cocotb/tidelink_chiplet_pair_autocal/test_chiplet_pair_doorbell.py` —
  SW-coordinated bring-up (role_lock → wait cal_done → recal_cycle →
  drop training → LL swreset cycle) and asserts both sides latch
  `cr_pkt_seen_rx` (proxy for M→S / S→M crossing).

## Run outputs

### `make MODULE=test_calibrator_state_probe`
PASS in ~10 s sim wall (sim_time 201 µs, sample window 10 000 apb_clk cy).

```
cal cur_state @ M  = SWEEP, S = SWEEP
lane_locked_w  M = 0x00, S = 0x00
cal_training_mode M = 1, S = 1
cal_calibration_done M = 0, S = 0
phase_offset @ M = 0x00000000, S = 0x00000000   (initial)

Histogram over 10000 cycles:
  cal M: SWEEP=10000
  cal S: SWEEP=10000
  FCSM M: IDLE=15, SEND_CR1=9985
  FCSM S: IDLE=17, SEND_CR1=9983
  lane_locked M histogram: 0x00=8672, 0xff=1328
  lane_locked S histogram: 0x00=8686, 0xff=1314
  phase_offset M final 0x11111111
  phase_offset S final 0x11111111
  CAL DONE residency: M=0.0%  S=0.0%  (symmetric)
  max lane_locked seen: M=0xff  S=0xff
```

### `make MODULE=test_chiplet_pair_doorbell`
Wall time: 47 s for test_01, 89 s for test_02 — total ~3 min. (Compare
`tidelink_top_pair` ≈ 30 min.)

`test_01 test_chiplet_pair_cr_pkt_symmetric` — **FAIL** (intended; diag fail):

```
[post role_lock]            M: cal=SWEEP locked=0x00 done=0 train=1 phase=0x00000000
[post role_lock]            S: cal=SWEEP locked=0x00 done=0 train=1 phase=0x00000000
[after passive autocal]     M: cal=SWEEP locked=0x00 done=0 train=1 phase=0x66666666
[after passive autocal]     S: cal=SWEEP locked=0x00 done=0 train=1 phase=0x66666666
WARNING: passive autocal TIMED OUT before both done.
[after recal_cycle]         M: cal=SWEEP locked=0x00 done=0 train=1 phase=0x00000000
[after recal_cycle]         S: cal=SWEEP locked=0x00 done=0 train=1 phase=0x00000000
[after LL swreset cycle]    M: cal=SWEEP locked=0xff done=0 train=1 phase=0x00000000
[after LL swreset cycle]    S: cal=SWEEP locked=0xff done=0 train=1 phase=0x00000000

M: max_state=1 (SEND_CR1) cr=0 crack=0
S: max_state=1 (SEND_CR1) cr=0 crack=0

RESULT: at least one cr_pkt_seen_rx FAILED to latch — bug REPRODUCED at
        chiplet_pair scope (calibrator-PHY).
```

`test_02 test_chiplet_pair_cr_pkt_diagnostic` — PASS:
```
cr_m=0 cr_s=0 crack_m=0 crack_s=0 max_m=1 max_s=1 asym_cr=False
```

## Conclusion

> **M→S asymmetric repro at chiplet_controller pair level: NO. Instead the
> chiplet_pair with AUTOCAL_ENABLE=1 reproduces a *symmetric* failure** —
> both sides stick in calibrator SWEEP, never assert `cal_calibration_done`,
> and the FCSMs both stay in SEND_CR1 with `cr_pkt_seen_rx` never latched
> on either side.

This is still an extremely useful narrowing. It tells us:

1. The chiplet controller's calibrator + Wlink + PHY combo (which the
   wlink_pair tb runs with AUTOCAL_ENABLE=0 and PASSES) cannot complete
   the sweep in sim when AUTOCAL is turned on.
2. The asymmetric M→S failure observed in `tidelink_top_pair` is therefore
   the *visible* layer (TideLink layer over a broken calibrator) — the
   underlying problem is the calibrator never converging.
3. Concretely: `phase_offset` walks 0x00 → 0x11111111 → 0x66666666 (the
   per-lane nibble sweep value) and `lane_locked_w` flips between 0x00 and
   0xff while the FSM is in SWEEP, but `cal_calibration_done` never
   asserts. The sweep is observing a "good" lane_locked window (the 0xff
   bursts in the histogram) but the calibrator FSM isn't latching it.

## Hierarchical paths discovered (all mirrored at `tb_top.*` via wires)

| signal | M path | S path |
|---|---|---|
| `cur_state[3:0]` | `tb_top.u_master.u_calibrator.cur_state` | `tb_top.u_slave.u_calibrator.cur_state` |
| `cal_training_mode` | `tb_top.u_master.cal_training_mode_w` | `tb_top.u_slave.cal_training_mode_w` |
| `cal_calibration_done` | `tb_top.u_master.cal_calibration_done_w` | `tb_top.u_slave.cal_calibration_done_w` |
| `lane_locked_w[7:0]` | `tb_top.u_master.lane_locked_w` | `tb_top.u_slave.lane_locked_w` |
| `phase_offset[31:0]` | `tb_top.u_master.cal_phase_offset_w` | `tb_top.u_slave.cal_phase_offset_w` |
| `bit_slip[23:0]` | `tb_top.u_master.cal_bit_slip_w` | `tb_top.u_slave.cal_bit_slip_w` |
| FCSM `state` | `tb_top.u_master.u_wlink.tl2wl.wlink_tidelinktl.state` | `tb_top.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state` |
| `cr_pkt_seen_rx` | `tb_top.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx` | `tb_top.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx` |

## Smallest unit-level test for the asymmetry

The repro at this scope is **symmetric, not asymmetric** — so the right
fast-iteration loop for Agent D / the fix author is:

- **First** target the calibrator's `cal_calibration_done` symmetric
  failure in this new env (`test_chiplet_pair_doorbell`, ~3 min wall).
- Then re-run `tidelink_top_pair` with the calibrator fixed and check
  whether the M→S asymmetric symptom collapses to symmetric pass.

If the asymmetric symptom *persists* in `tidelink_top_pair` after the
calibrator is fixed here, then the tidelink_top wrapper has an additional
asymmetric bug on top of the calibrator (likely FC adapter / returner /
fifo glue, since `wlink_pair` AUTOCAL=0 passes and `tidelink_top_loopback_pair`
which is reported to pass excludes the calibrator+PHY combo).

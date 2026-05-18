# `staging/phy_align/` — Autonomous calibration FSM (DESIGN PROTOTYPE)

This directory contains a design-only prototype of the §9.6 / §2.2
autonomous PHY-align calibration FSM for the TideLink Wlink PHY. It is
**not yet wired into trunk RTL** and intentionally sits outside both
`cocotb/phy_align/` and `deps/axi-chiplet-controller/logical/` — the
integrator (dam1n19) will merge it after the APB plumbing for the §9
soft-strap registers lands and the FPGA pair is bringing the link up via
the current SW-driven sweep.

References:
- `BRINGUP_REPORT.md` §9.6 (FSM sketch) and §9.8 (sequencing requirement)
- `docs/PHY_ALIGN_NEXT_STEPS.md` §2.2 (gap definition)
- `deps/axi-chiplet-controller/logical/phy-align/README.md` (where this work
  lives architecturally once extracted into the PHY repo)

## Files

| File | Purpose |
|---|---|
| `wlink_phy_align_calibrator.sv` | The FSM RTL — replaces the SW-driven sweep |
| `tb_autocal.sv` | Tiny standalone testbench instantiating only the FSM |
| `test_autocal.py` | Cocotb tests (6 scenarios, all PASS) |
| `Makefile` | `make` runs the regression |

To run:

```
$ cd staging/phy_align
$ make
```

VCS + cocotb required (the same flow as `cocotb/phy_align/`).

## What the FSM does

On the rising edge of `role_locked`, the FSM:

1. Drops `calibration_done` and clears the per-lane `lane_fault` vector.
2. Asserts `training_mode=1` so the TX serialiser emits the per-lane
   training pattern and the Wlink stack holds off cr_pkt generation.
3. Starts a per-lane *parallel* slip sweep: every lane begins at slip=0.
4. For each slip value, dwells `DWELL_CYCLES` (default 32, twice the
   lane checker's `LOCK_THRESH=16`). During the dwell, any lane that
   asserts `lane_locked[i]` latches its current slip and is marked done.
5. After dwell expiry, each still-not-done lane advances to the next
   slip value. If a lane exhausts all 8 slip values without locking,
   `lane_fault[i]` is set sticky and the lane is treated as done.
6. Once all lanes are either locked or faulted, the FSM asserts
   `calibration_done=1` and deasserts `training_mode=0`.

Worst-case time: 8 slips × 32-cycle dwell = 256 cycles plus a couple of
state-transition cycles ≈ ~270 cycles. At a 250 MHz link clock that's
~1.1 µs from `role_locked` rising to `calibration_done`.

## Bring-up sequencing contract (CRITICAL — see §9.8)

The §9.8 finding is that the cocotb sandbox could paper over a real
sequencing requirement: `training_mode` must NOT be asserted before
`role_lock`, because the training pattern displaces the cr_pkt traffic
that the receiver-side Wlink LL_RX needs to recover its link clock.

This FSM fires *after* `role_locked` rises, so by the time `training_mode`
is asserted the link clock has already started. The integrator must also
ensure that the FCSM does not advance past `SEND_CREDITS1` while
`training_mode=1`. The cleanest hook is to gate `swi_lltx_enable` (or
equivalently `swreset` to Wlink) on `calibration_done`:

```verilog
// In tidelink_top.sv (or wherever the chiplet-controller's swreset path
// drives Wlink's LL_TX enable):
wire wlink_lltx_enable_gated = swi_lltx_enable_q & calibration_done;
```

A second supported trigger is the falling edge of `swreset` while
`role_locked` is still high: this lets SW issue a "recalibrate" without
dropping `role_locked` (e.g. a runtime bit-error counter exceeded a
threshold, fire `swreset` to re-run the sweep).

### Required wiring

```
                                       +---------------------------------+
   role_locked (level)  ─────────────► |                                 |
   swreset (level)      ─────────────► |                                 |
                                       |  wlink_phy_align_calibrator     |
   lane_locked[7:0] from              |                                 |
   wlink_lane_checker   ─────────────► |                                 |
                                       |                                 |
   apb_bit_slip_override[23:0]  ────► |                                 |
   apb_override_enable          ────► |                                 |
                                       |                                 |
                                       |  bit_slip[23:0]      ─────────► | swi_bit_slip in WavD2DGpio
                                       |  training_mode       ─────────► | swi_training_mode in WavD2DGpio
                                       |  calibration_done    ─────────► | gates swi_lltx_enable (see above)
                                       |  lane_fault[7:0]     ─────────► | APB read-only status reg
                                       |  state[3:0]          ─────────► | ILA debug
                                       +---------------------------------+
```

### Clock domain

The FSM runs in the **link-clock** domain — the same `clk` as
`wlink_lane_checker`. This is the recovered-clock domain that captures
the deserialised 16-bit lane words; on the integration side it's
`u_<side>.u_wlink.phy.gpio.io_link_rx_rx_link_clk`. Do NOT clock this on
`apb_clk` or `app_clk` — the lane_locked signal is in the link-clock
domain and would need a CDC handshake otherwise.

### Reset

Active-high. Tie to `~poresetn` from the chiplet controller. Do NOT tie
to `hresetn` alone — POR clears the FSM at every cold boot which is the
right behaviour.

## Interface for integration

```verilog
wlink_phy_align_calibrator #(
    .DWELL_CYCLES(32),   // > LOCK_THRESH (16) in the lane checker
    .NUM_LANES   (8)
) u_autocal (
    .clk                   (link_clk_rx),
    .rst                   (~poresetn),
    .role_locked           (role_locked_o_from_chiplet_ctrl),
    .swreset               (swi_swreset_from_chiplet_ctrl),
    .lane_locked           (lane_locked_from_checker),
    .apb_bit_slip_override (apb_swi_bit_slip_override),
    .apb_override_enable   (apb_swi_bit_slip_override_enable),
    .bit_slip              (swi_bit_slip_to_phy),
    .training_mode         (swi_training_mode_to_phy),
    .calibration_done      (calibration_done_to_status_reg_and_lltx_gate),
    .lane_fault            (lane_fault_to_status_reg),
    .state                 (state_to_ila)
);
```

The integrator should also:

1. Remove (or keep as a debug-only fallback) the `swi_bit_slip` /
   `swi_training_mode` soft-strap regs currently in `WavD2DGpio.v`
   lines 295–325. Replace with wires driven by `bit_slip` and
   `training_mode` from this FSM.
2. Add APB-readable status registers for `calibration_done`, `lane_fault`,
   and (optionally) `state` for debug.
3. Add an APB-writable register pair `swi_bit_slip_override[23:0]` and
   `swi_bit_slip_override_enable` for SW debug override.
4. Update `pynq_host/scripts/deploy_pair.sh` to read `calibration_done`
   after `role_lock` rather than driving its own sweep.

## Validation status

Run from this directory:

```
$ make
...
** TEST                                 STATUS
** test_autocal.test_uniform_slip        PASS
** test_autocal.test_asymmetric          PASS
** test_autocal.test_stuck_lane          PASS
** test_autocal.test_apb_override        PASS
** test_autocal.test_swreset_retrigger   PASS
** test_autocal.test_role_relock         PASS
** TESTS=6 PASS=6 FAIL=0 SKIP=0
```

Tests covered:
1. `test_uniform_slip` — all 8 lanes target slip=3 (the simplest case).
2. `test_asymmetric` — per-lane target `[3,5,0,2,7,1,4,6]`.
3. `test_stuck_lane` — lane 4 never locks; FSM sets `lane_fault[4]=1`
   and finishes with `calibration_done=1` (other 7 lanes locked at
   their targets).
4. `test_apb_override` — `apb_override_enable=1` bypasses the FSM
   entirely; `training_mode` stays low, `calibration_done` is forced
   high, `bit_slip` echoes the override register. Then disabling the
   override and pulsing `swreset` re-runs the sweep cleanly.
5. `test_swreset_retrigger` — after a successful sweep, pulsing
   `swreset` cancels-then-restarts the sweep with a fresh target.
6. `test_role_relock` — after a successful sweep, dropping and
   re-raising `role_locked` re-runs the sweep with a new target.

`verilator --lint-only -Wall -sv wlink_phy_align_calibrator.sv` is clean
(0 warnings).

## Design decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Parallel vs sequential sweep | Parallel | ~8× faster (~256 cycles vs ~2048). Logic cost is small (8 × 3-bit slip regs + 8 × 1-bit done regs). Per-lane state is independent. |
| 2 | Dwell cycles per slip | 32 (2× LOCK_THRESH) | Gives the lane checker time to ramp its match counter from 0 to 16 plus a safety margin. |
| 3 | What clears slip[]? | `cur_state==S_ARM` | The S_ARM state is held for exactly one cycle (entry pulse). Using `cur_state` (registered) means the clears happen on the first clock edge after the trigger fires, which matches the natural FSM timing. (An earlier draft used `nxt_state` and was wrong — the case branch never fired because by the time `cur_state==S_ARM`, `nxt_state` had already advanced to S_SWEEP.) |
| 4 | Trigger conditions | role_locked rising OR swreset falling-while-role_locked | Two distinct production scenarios: cold boot (role_locked rising) and runtime recalibrate (swreset cycle). Both reach S_ARM identically. |
| 5 | What happens on swreset mid-sweep? | S_CANCEL — wait for swreset deassert, then re-arm | Slip values are *not* cleared on entry to S_CANCEL (only on entry to S_ARM), so ILA shows the slip at point of cancel. Falling edge of swreset triggers fresh sweep from slip=0. |
| 6 | Stuck-lane handling | After exhausting slip=7, set `lane_fault[i]=1` and mark lane done; continue with the other lanes | Avoids hanging the link bring-up because of one bad lane; SW can read `lane_fault` to diagnose. |
| 7 | APB override semantics | When enabled: `bit_slip` driven from override reg, `training_mode=0`, `calibration_done=1` | Override gives SW a "pretend we already calibrated, here are the slip values to use" knob — useful for debug, characterisation, and as a fallback if the FSM is buggy. The forced `calibration_done=1` means the integrator's `swi_lltx_enable` gate doesn't block. |

## Open design decisions left for the integrator

1. **What signal exactly maps to `swreset`?** The chiplet controller has
   several reset-shaped signals (`hresetn`, `swi_swreset`, the synchronous
   bring-up sequencer's reset). The intended one is the SW-controllable
   `swi_swreset` register bit — the same one that today's
   `deploy_pair.sh` toggles. The integrator should confirm this against
   the actual register map.
2. **Should `calibration_done` qualify `swi_lltx_enable` directly, or
   should it post a "ready" signal to a higher-level bring-up FSM?** The
   simpler hook is direct gating (see README example). The more
   conservative approach is to expose `calibration_done` as a polled
   status register and have firmware drive `swi_lltx_enable` only after
   it observes calibration_done=1. Both work; the direct gate is the
   ASIC-target design (no firmware involvement), the polled approach is
   safer for the FPGA bring-up where you may want to manually inspect
   `lane_fault` first.
3. **APB override register layout.** Recommended: `swi_bit_slip_override`
   at one 32-bit reg (low 24 bits used), `swi_bit_slip_override_enable`
   as bit 0 of a 1-bit reg. Both live in the same APB region as
   `swi_phase_offset` today. Final byte addresses TBD by the RDL update.

## What the integrator should NOT change

- The `wlink_lane_checker.sv` interface — this FSM consumes its
  `lane_locked[7:0]` output unchanged.
- The per-lane training pattern bytes (`{0xA3, 0xB5, 0xC9, 0xD3, 0x65,
  0x4B, 0x59, 0x2D}`) — they are period-8 by construction and a real bug
  was caught by deviating from the spec's period-4 `(N+1)*0x11`. See
  `wlink_lane_checker.sv` comments.

## Lint, build, and waveforms

- `verilator --lint-only -Wall -sv wlink_phy_align_calibrator.sv` is
  clean (no warnings).
- VCS compiles with `-sverilog -timescale=1ns/1ps` — no special flags.
- The TB dumps `waves.vcd` on every run (in the current directory).

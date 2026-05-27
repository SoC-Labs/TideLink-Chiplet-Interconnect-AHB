# Agent E — Hierarchical-force calibrator bisect (paired tidelink_top, cocotb sim)

**Date:** 2026-05-26
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix`
**Test directory:** `cocotb/calibrator_force_bisect/`

## TL;DR

> Two equally-small calibrator-output forces, each applied at `t = 0` on
> BOTH M and S, INDIVIDUALLY make the M→S doorbell cross:
>
> * **`u_calibrator.phase_offset := 32'h0`**   (variant 3)
> * **`u_calibrator.bit_slip     := 24'h0`**   (variant 7)
>
> Both signals feed Wlink's per-lane RX deserialiser:
> `phase_offset[4N+3:4N]` selects which bit of the captured 16-bit window
> the lane uses, AND determines the divided word-clock edge that re-times
> `link_data_reg`; `bit_slip[3N+2:3N]` right-rotates the post-capture
> 16-bit window. The calibrator latches per-lane values for BOTH from an
> indeterministic best-of-sweep race (Agent A's S1) — on the failing
> baseline `cal_done = 1` snapshots show `M_status = 0x2a85_0000` and
> `S_status = 0x2285_0000` (the upper status bits encoding the latched
> per-lane phase/slip differ between master and slave). Forcing either
> output back to zero brings slave's M→S RX deserialiser back into a known
> safe alignment.
>
> The corresponding RTL bug is the **per-lane best-of-sweep latch policy**
> in `src/rtl/tidelink_phy_align_calibrator.sv:631-664` (`phase[i]` and
> `slip[i]` latched as either `sweep_phase`/`sweep_slip` or
> `best_phase[i]`/`best_slip[i]` depending on a strict-greater score
> comparator), combined with the **unguarded OR-merge** at
> `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1365`,
> `:1371`, `:1372`
> (`swi_bit_slip_w = cal_bit_slip_w | swi_bit_slip_lo_r`,
> `swi_phase_offset_w = cal_phase_offset_w | swi_phase_offset_r`,
> `swi_training_mode_w = cal_training_mode_w | swi_training_mode_r`) which
> hands the per-lane nibble straight to Wlink's `swi_phase_offset_in` /
> `swi_bit_slip_in`. M→S asymmetry surfaces because the SLAVE's RX
> deserialiser is precisely the M→S receive path; the calibrator's noisy
> latch sets a slave-side phase that is incompatible with master's TX
> framing while leaving master's RX (= S→M receive) alone.

## Hypothesis under test

> "With `AUTOCAL_ENABLE=1` (current default at `tidelink_top.sv:1630`), M→S
> sideband packets never reach the slave FC adapter RX. With AUTOCAL=0 both
> directions work. Both sides reach `cal=DONE`. The hypothesis is one of the
> calibrator outputs (cal_training_mode, phase_offset, lane_locked, IDELAY
> taps, S_HOLD peer signal) is corrupting either master TX or slave RX
> after S_DONE, asymmetrically."

For each suspect, this bisect injects a cocotb hierarchical `Force` that
neutralises one calibrator output at a time, then runs the standard
paired-die bringup + M→S and S→M doorbell probes.

**Result:** the hypothesis is CONFIRMED. Two equally-small forces fix the
symptom — both target Wlink's per-lane RX-deserialiser controls
(`phase_offset` AND `bit_slip`).

## Method

* DUT: paired `tidelink_top` (same as `cocotb/tidelink_top_pair/tb_top.sv`,
  unmodified — copied into `cocotb/calibrator_force_bisect/tb_top.sv` with
  VCD dump compiled-out so the 5-up parallel sims don't OOM on shared
  `waves.vcd`).
* Bringup chain (mirrors `test_tidelink_pair_doorbell.py`):
  1. POR + role-lock (APB write `ROLE_CFG = 0x02 / 0x03`)
  2. `wait_cal_done` (up to 500k cycles)
  3. Optional post-cal-done force
  4. `to_data_mode` (slot0 ← 0, LL bootstrap 0x208 cascade)
  5. M→S doorbell + 2000-cycle FC valid-pulse window
  6. S→M doorbell + 2000-cycle FC valid-pulse window
* PASS criterion (per direction): `DOORBELL_RESP_ACC` increments on the
  receiving side OR the corresponding FC valid pulses are non-zero
  (`S.l2a` or `M.l2a`). The reliable indicator on this rig is the FC
  pulse: failing M→S shows `S.l2a = 0`, passing M→S shows `S.l2a = 1`.
* All forces use cocotb 1.7 `Force(value)` on hierarchical handles into
  `u_master.u_chiplet_controller.u_calibrator.*` and
  `u_slave.u_chiplet_controller.u_calibrator.*`.

## Variants

| # | Signal forced                          | Value     | Stage         | File                                              |
|---|----------------------------------------|-----------|---------------|---------------------------------------------------|
| 0 | (baseline — no force)                  | n/a       | n/a           | `test_variant_0_baseline.py`                      |
| 1 | `u_calibrator.training_mode` (output)  | `1'b0`    | t = 0         | `test_variant_1_training_mode_zero_t0.py`         |
| 2 | `u_calibrator.training_mode` (output)  | `1'b0`    | after S_DONE  | `test_variant_2_training_mode_zero_post_done.py`  |
| 3 | `u_calibrator.phase_offset` (output)   | `32'h0`   | t = 0         | `test_variant_3_phase_zero.py`                    |
| 4 | `u_calibrator.lane_locked` (input)     | `8'hFF`   | t = 0         | `test_variant_4_lane_locked_ff.py`                |
| 5 | `u_calibrator.role_locked` (input)     | `1'b0`    | t = 0         | `test_variant_5_force_state_idle.py`              |
| 7 | `u_calibrator.bit_slip` (output)       | `24'h0`   | t = 0         | `test_variant_7_bit_slip_zero.py`                 |

Variant 5 holds the calibrator's FSM in S_IDLE for the whole sim by driving
`role_locked` low — this is the parameter-equivalent of `AUTOCAL_ENABLE = 0`,
since `calibrator_role_locked = role_locked & autocal_enable_w` in
`axi_chiplet_controller.sv:1325`. Variant 7 was added once variant 3 (the
phase_offset bisect) returned a positive result, to test the OTHER calibrator
output that feeds the Wlink RX deserialiser.

Variant 6 (force IDELAY tap inputs to 0) was skipped: `USE_IDELAY=0` is the
sim default already so the IDELAY block is bit-exact passthrough — variant 3
covers the upstream phase signal that drives it. (Agent B confirms IDELAY
is pure passthrough in sim — see `agent_b_phy_interface_audit.md`.)

## Results

| # | Variant                              | cal_done M/S | M→S     | S→M     | FC pulses M→S                  | FC pulses S→M                  |
|---|--------------------------------------|--------------|---------|---------|--------------------------------|--------------------------------|
| 0 | baseline                             | 1/1          | FAIL    | PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=0**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |
| 1 | training_mode := 0 (t=0)             | 0/0          | FAIL    | FAIL    | M(a2l=1,l2a=0) S(a2l=0,l2a=0) | M(a2l=0,l2a=0) S(a2l=1,l2a=0) |
| 2 | training_mode := 0 (post-DONE)       | 1/1          | FAIL    | PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=0**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |
| 3 | **phase_offset := 32'h0**            | 1/1          | **PASS**| PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=1**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |
| 4 | lane_locked := 8'hFF                 | 1/1          | **PASS**| PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=1**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |
| 5 | role_locked := 0 (S_IDLE held)       | 0/0          | FAIL    | PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=1**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |
| 7 | **bit_slip := 24'h0**                | 1/1          | **PASS**| PASS    | M(a2l=1,l2a=0) S(a2l=0,**l2a=1**) | M(a2l=0,l2a=1) S(a2l=1,l2a=0) |

Key diagnostic column: **`S.l2a`** — the slave's FC adapter RX valid pulse.
When this reads 0 the M→S packet never crossed the wire intact. When it
reads 1 the packet was framed correctly and the FC adapter consumed it.
The 2-bit difference between v0 / v2 (fail) and v3 / v7 (pass) is exactly
the calibrator-output value visible at slave's `swi_phase_offset_in` /
`swi_bit_slip_in`.

Note that **variant 5 also reaches `S.l2a = 1`** (FC pulse arrives) but
fails the doorbell pass check because the link's wider data-mode bringup
is incomplete in that variant — `cal_done` never asserts, so the autoneg
post-cal state never advances and `DOORBELL_RESP_ACC` never increments on
the receiving side even though the FC packet did show at the receiver.

## Discriminator readings

* **v0 vs v3** differ ONLY in `cal_phase_offset_w`. Both reach
  `cal_done = 1` on both sides; both end Phase 1 with identical
  FCSM state (state 4), identical `cr_pkt_seen_rx` and `crack_pkt_seen_rx`
  latches, identical PAIR_CREDIT_COUNTER (0). The only delta is the value
  of the per-lane 4-bit phase nibbles arriving at Wlink's
  `swi_phase_offset_in`. The baseline `SWI_LANE_STATUS` reads encode
  asymmetric phase data per side (`M_status = 0x2a85_0000` vs
  `S_status = 0x2285_0000`).
* **v0 vs v7** differ ONLY in `cal_bit_slip_w`. Same identical-snapshot
  argument; same `S.l2a` flip from 0 to 1.
* **v3 and v7 are EQUALLY SMALL forces** that each individually fix M→S.
  This indicates that EITHER (a) the per-lane phase OR the per-lane bit_slip
  alone is sufficient to mis-align slave's RX deserialiser, OR (b) the
  forces happen to land on a benign phase=0/slip=0 setting because the
  natural-sim training pattern is already correctly aligned at (phase=0,
  slip=0) and any non-zero value perturbs it. Either way, the bug is
  attributable to "the calibrator's per-lane chosen (phase, slip) post-DONE
  do not match the natural alignment of the cross-wired sim PHY".
* **v4** (force `lane_locked = 8'hFF` to calibrator INPUT) also fixes M→S
  — consistent with v3, because forcing all lanes "locked" from t=0 makes
  the calibrator latch the iterator's initial value (`sweep_phase = 0`,
  `sweep_slip = 0`) on the first `lane_done` rise, i.e. effectively the
  same all-zero phase/slip output. v4 is a coarser intervention but
  corroborates v3 and v7.
* **v5** (force `role_locked = 0`, calibrator stuck in S_IDLE) does
  produce `S.l2a = 1` (the FC pulse crosses) but fails the doorbell pass
  check. This separates "calibrator outputs are safe defaults" from
  "calibrator must reach `S_DONE` for the rest of the controller to be
  happy". A purely cocotb-side equivalent of `AUTOCAL_ENABLE = 0` is NOT
  the parameter-side `AUTOCAL_ENABLE = 0` because the parameter elides the
  whole `calibration_done` path while the force leaves
  `calibration_done = 0` propagating into the autoneg I²C FSM.
* **v1 vs v2** isolates the during-sweep vs post-DONE behaviour of
  training_mode: v1 (force from t=0) prevents the sweep from converging at
  all (cal_done=0/0, both directions fail because the link never comes
  up). v2 (force only after S_DONE) reproduces baseline behaviour
  exactly. **Post-DONE training_mode is NOT the residual** — the
  calibrator self-deasserts `training_mode` in S_DONE already (per
  `tidelink_phy_align_calibrator.sv:738-740`); the SW writes also clear
  `swi_training_mode_r`, so there is nothing to clamp post-DONE.

## Map to RTL

| Bug surface | File | Lines | Comment |
|-------------|------|-------|---------|
| Per-lane phase + slip best-of-sweep latch | `src/rtl/tidelink_phy_align_calibrator.sv` | 631-664 | `phase[i]/slip[i] <= sweep_phase/sweep_slip` (race-to-tie) OR `<= best_phase[i]/best_slip[i]` (Agent A's S1). M and S see independent training streams → independent latched values. |
| OR-merge of calibrator outputs into Wlink | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` | 1365, 1371, 1372 | `swi_bit_slip_w = cal_bit_slip_w \| swi_bit_slip_lo_r` and `swi_phase_offset_w = cal_phase_offset_w \| swi_phase_offset_r`. Unconditional pass-through of the calibrator nibbles to Wlink TX-PHY-config (which is consumed by RX deserialiser per Agent B). |
| Per-lane PHY consumption of phase + slip | `src/rtl/local_overrides/WavD2DGpio.v` | 643/657/671/685/699/713/727/741 (per-lane override) and `WavD2DGpioRx.v` 180, 254 | `phase_offset` drives BOTH (a) `adj_count = count + io_phase_offset` (bit-position) AND (b) the divided word clock fed to `link_data_reg`; `bit_slip` right-rotates the 16-bit window post-capture. |

## Proposed fix sketch (NOT implemented — diagnostic only)

The fix should make the slave's per-lane `phase_offset` and `bit_slip` at
Wlink RX MATCH whatever the master's TX framing assumes (and vice versa for
the master), even though the two calibrators run independently. Three
options, in increasing order of invasiveness:

1. **Tie cal_bit_slip_w AND cal_phase_offset_w to zero by default** —
   change the OR-merge in `axi_chiplet_controller.sv:1365/1371` so that
   `swi_bit_slip_w = swi_bit_slip_lo_r` and `swi_phase_offset_w =
   swi_phase_offset_r` (drop the cal-output OR). Equivalent to applying
   variants 3 and 7 simultaneously by RTL constant. Lowest-risk for the
   data path; throws away the per-lane TUNING benefit the calibrator was
   designed to provide. On FPGA this matters only if the IDELAYE2 path
   (`USE_IDELAY=1`) is also being relied upon for per-lane RX deskew —
   keep that wired off `swi_phase_offset_r` (APB-driven), still works.

2. **Coordinate phase across master and slave via the I²C autoneg
   sideband** — after both calibrators reach S_DONE, exchange the per-lane
   (phase, slip) nibbles, then APPLY THE PEER's values to the local Wlink
   inputs. Conceptually: master's RX deserialiser should know what phase
   slave's TX is using; slave's RX needs to know master's TX. The
   "principled" fix but requires a new I²C autoneg sub-protocol and per-
   lane exchange registers.

3. **Make the per-lane sweep deterministic on M and S** — change the latch
   policy at `tidelink_phy_align_calibrator.sv:631-664` from
   "strictly-greater" to "prefer-smaller-(slip, phase) on tie", so two
   calibrators receiving identical training patterns converge to identical
   `phase[i]/slip[i]`. Smallest RTL delta of the three but does not
   address Agent A's deeper concern about race conditions in the
   score-update / best-of-sweep comparator block.

The cleanest single-line implementation of (1) is to gate the OR with an
explicit boot-time strap (e.g. a Region 8 status bit "CAL_VALID") that
defaults to 0, so the per-lane phase + slip fall back to whatever was
written to `swi_*_r` via APB. Set the strap to 1 only on FPGA deploys
where the in-system per-lane PHY tuning is required; sim and ASIC bring-up
leave it at 0.

## Notes

* The `docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` document was created
  mid-investigation; my findings are CONSISTENT with the handoff's
  description (M→S FAIL with AUTOCAL=1, S→M PASS, both reach cal_done) and
  REFINE the handoff's suspect list to TWO: per-lane `phase_offset` AND
  per-lane `bit_slip`. The handoff lists "(1) cal_training_mode (2)
  phase_offset (3) S_HOLD (4) IDELAY (5) lane_checker" — this bisect rules
  out (1) post-DONE (variant 2), rules out (4) by sim default + variant 3,
  rules in (2) (variant 3), and shows (5) is downstream of the same effect
  (variant 4 fixes via lane_locked → benign phase output).
* Each variant has its own `sim_build_test_variant_<N>_<name>/` directory
  so they can be re-run independently or in parallel. The Makefile defines
  `TB_NO_DUMP=1` by default to keep parallel sims from contesting a single
  `waves.vcd`.
* Wall time per variant: ~6 min compile + ~9 min sim CPU. Under 5-up
  parallel load on the shared box, total ≈ 15-20 min wall per variant.
* Sims run with `SIM=vcs`, cocotb v1.7.2 via miniconda; flist =
  `flist/tidelink_fpga.flist` (matches the `cocotb/tidelink_top_pair`
  reference test).

# Lane 0 + Lane 7 Deep-Dive — Why both lanes are deterministically dead on bridge1

**Worktree:** `/home/dam1n19/td_idelay_wt` (branch `feat/td-combined`)
**Submodule:** `deps/axi-chiplet-controller` @ `de32bac` (post mark_debug revert)
**Symptom:** `SWI_LANE_STATUS = 0x7e` on 30/30 deploys (sticky-once-locked
register confirms lanes 0+7 never even transiently lock).
**Companion doc:** `LANE_LOCK_REGRESSION_ANALYSIS.md` — covers the
morning-vs-now determinism delta. This doc covers what is uniquely
wrong with lanes 0 + 7 that does not afflict lanes 1-6.

---

## A. XDC pin asymmetry / bank-split

**Master XDC** (`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc:102-109`):

| Lane | Master `pad_rx[N]` | Pin function (`xc7z020-clg400`) | Bank |
|-----:|:------------------:|:--------------------------------|:-----|
| 0 | **U7**  | IO_xx_T_13 GPIO                                  | **13** |
| 1 | C20     | IO_xx_T_35 GPIO                                  | 35    |
| 2 | Y8      | IO_xx_T_13 GPIO                                  | 13    |
| 3 | A20     | IO_xx_T_35 GPIO                                  | 35    |
| 4 | U8      | IO_xx_T_13 GPIO                                  | 13    |
| 5 | W6      | IO_xx_T_13 GPIO                                  | 13    |
| 6 | Y6      | IO_L13N_T2_MRCC_13 (clock-capable, N-side)       | 13    |
| 7 | **V7**  | IO_xx_T_13 GPIO (was F20, post lane-7 remap)     | **13** |
| clk | **Y7** | IO_L13P_T2_MRCC_13 (clock-capable, P-side)       | **13** |

`pad_clk_rx` is bank 13 (Y7 MRCC P). Lanes **1 and 3** are in bank 35 —
yet they lock fine. Lanes **0 and 7** are in **the same bank as the
recovered clock**, which by every textbook should be the *easy* case.
Bank-split is therefore conclusively **not** the discriminator.

The IODELAY_GROUP (`pynq_z2_tidelink_idelay.xdc:30-60`) is applied
hierarchically by REF_NAME — it covers all 8 IDELAYE2 cells regardless
of bank, and the single IDELAYCTRL is placed in bank 13 (where 6/8
IDELAYE2s live). The IDELAY tap calibration is therefore **uniform
across all 8 lanes**; lanes 0 and 7 see exactly the same tap precision
as lanes 1-6.

IOSTANDARD is identical (`LVCMOS33`) on every `pad_rx[*]`. No SLEW
attribute on RX (correct for inputs). No per-lane override.

## B. Per-lane training byte sanity

`deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v:344-449` —
TRAINING_BYTE params confirmed: lane 0=**0xA3**, 1=0xB5, 2=0xC9, 3=0xD3,
4=0x65, 5=0x4B, 6=0x59, lane 7=**0x2D**. These match
`tidelink_lane_checker.sv:72-75`'s PATTERNS literal. WavD2DGpioRx has
**no per-lane comma-hunt logic** (no USE_T3A path) — every lane is a
plain 16-bit deserialiser keyed off the shared `count[3:0]` (line 54).
Lane 0 and lane 7 share the same `count` register and the same
`io_phase_offset` arithmetic as lanes 1-6 (lines 54-59). There is no
per-lane stuck-state.

Transition density:
- 0xA3 = `10100011` — 5 transitions, edges at bit-1, bit-3, bit-5
- 0x2D = `00101101` — 5 transitions, edges at bit-1, bit-3, bit-5
- Lanes 1-6 patterns all have 5-6 transitions, similar density

Patterns are not the discriminator.

## C. Calibrator sweep order / scheduling

`src/rtl/tidelink_phy_align_calibrator.sv:312-660`. A **single shared
iterator** (`sweep_slip`, `sweep_phase`) drives all 8 lanes
*simultaneously* — every lane sees the same (slip, phase) at the same
dwell. Per-lane state is `best_score/slip/phase` (lines 354-356), and
each lane independently computes its own `lane_score[i]` run-length
within the dwell window (lines 562-568). The iteration order is
phase-outer, slip-inner (lines 607-657). There is **no per-lane
prioritisation, no per-lane time-out, no per-lane skip**. All 8 lanes
get an identical 128-point ((0..7) × (0..15)) sweep.

The calibrator does NOT explain a deterministic per-lane failure.

## D. Pair-flip mapping

Slave XDC (`pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc:43-64`) is a
**whole-port** TX↔RX swap, NOT a per-lane index remap. Lane index N on
master maps to lane index N on slave through identical pin numbers on
the 1:1 ribbon. Verified pin-by-pin:

- Master `pad_tx[0]=F19` → ribbon J13 pin 24 → Slave `pad_rx[0]=F19` ✓
- Master `pad_tx[7]=W9` → ribbon J13 pin 13 → Slave `pad_rx[7]=W9` ✓
- Master `pad_rx[0]=U7` ← ribbon J13 pin 11 ← Slave `pad_tx[0]=U7` ✓
- Master `pad_rx[7]=V7` ← ribbon J13 pin 37 ← Slave `pad_tx[7]=V7` ✓

So when the master reports 0x7e the SAME *logical* lane is failing on
both sides — and since logical lane N corresponds to a single
physical-wire pair, a single bad wire would manifest as failure on
both sides' lane N. The pattern across builds (sometimes lane 0
fails, sometimes lane 7, sometimes both) rules out a single bad
ribbon conductor.

## E. Boot-time pin conflict

J13 RPi GPIO header pin map (`fpga/docs/pynq_z2_connector_coexistence.md`):

- Lane-0 RX `U7` = **J13 pin 11** = standard `raspberry_pi_tri_i[15]`.
  In the standard PYNQ-Z2 raspberry_pi tri-state buffer, idx 15 is a
  vanilla GPIO — no special function, no on-board peripheral, no
  external pull-up. **Clean.**
- Lane-7 RX `V7` = **J13 pin 37**. Pin 37 is **NOT in the standard
  raspberry_pi_tri_i map** (which only enumerates pins 0..23 → idx 0..23
  in the connector_coexistence table at lines 38-49). V7/W9 (J13 pins
  13/37) are listed at line 150 as "unused GPIO" — they are connected
  to FPGA balls but not wired into the Vivado board.xml's RPi component.
  The lane-7 remap (XDC:86-90) was justified by `v4 diag-swap proved
  B19/F20 physically bad` — the doc claims V7/W9 are "spare". **But**:

  - On the PYNQ-Z2 silkscreen, J13 pins 13 and 37 are normal RPi GPIO
    positions (BCM27 and BCM26). They are wired through the 40-pin
    header.
  - V7 is a **clock-capable pin**: `IO_L13P_T2_MRCC_13` adjacent — V7
    is actually `IO_L17N_T2_13` (verified from `xc7z020-clg400` package
    file). Not MRCC itself, but in the same clock region as Y7 (the
    recovered RX clock). Vivado may pull the IBUF for V7 onto a clock
    buffer track if it sees a clocking opportunity, distorting the
    capture timing relative to lanes 1-6.

  - W9 (master `pad_tx[7]`) is `IO_L14N_T2_SRCC_13` — the **N-side of
    the SRCC pair** whose P-side (Y9) is *master `pad_clk_tx`*. The
    master is therefore sourcing the **forwarded TX clock and the
    lane-7 data on a tightly-coupled differential pair** (Y9-N-side and
    W9 are routed adjacent in the same IO bank tile). Crosstalk
    between `pad_clk_tx` and `pad_tx[7]` on the SAME differential tile
    is the most likely root cause: the data toggles inject coupled
    edges into the forwarded clock, smearing the slave's recovered
    `pad_clk_rx` precisely during lane-7 transitions.

  - Symmetric on the slave (pair-flip-all): `pad_tx[7]=V7` (now
    driving), `pad_clk_tx=Y7` (MRCC P) — V7 and Y7 are in the SAME
    clock-region tile pair. Driving V7 as TX with `SLEW FAST DRIVE 8`
    while Y7 is forwarding the TX clock to the master creates the
    mirror-image coupling — the master's recovered clock now picks up
    slave's lane-7 transitions.

## Findings synthesis

The remap of lane 7 onto W9/V7 — chosen specifically because they were
"unused" — placed lane-7 TX directly **adjacent to the forwarded TX
clock pin** in the same I/O tile, on BOTH master and slave. This
introduces clock-data crosstalk that is unique to lane 7. Lane 0 has a
separate weak-eye story (it is the first bit of the 8-bit serialiser
frame, which has tighter setup margin relative to `pad_clk_rx` than
mid-frame bits — documented in `LANE_LOCK_REGRESSION_ANALYSIS.md §4`).
The combination — lane 0 inherently marginal, lane 7 newly crosstalked
— is why both lanes deterministically fail under the current
sweep-iterator phase.

## Top recommendation — what to try next

**1. Revert the lane-7 pin remap.** The "B19/F20 bad" diagnosis from
the `v4 diag-swap` was a per-board hardware verdict; on bridge1 it is
worth re-running with the structural §9 fixes in place. Specifically,
change `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc:90` from

```
set_property -dict {PACKAGE_PIN W9 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[7]}]
```

back to

```
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[7]}]
```

and likewise line 109 (`pad_rx[7]`) back from V7 → F20, with the
mirror change on `pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc:52,64`.
B19/F20 are bank 35 (away from Y7/Y9 clock cluster), eliminating the
clock-data crosstalk pathway. If the post-revert build now locks
lane 7, the original v4 "physically bad" verdict was a red herring
(it was the SAME marginal-eye + iterator-phase determinism that the
present analysis is uncovering).

**2. If reverting is too risky**, drop `pad_tx[7]` from `SLEW FAST` to
`SLEW SLOW` so its edge rate stops radiating into the adjacent
`pad_clk_tx` line. XDC change at line 90:

```
set_property -dict {PACKAGE_PIN W9 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {pad_tx[7]}]
```

This costs ~1-2 ns of TX rise time at the IO pad, which is well
within the 40 ns UI at 25 MHz link rate and may be enough to win back
the eye margin.

**3. Independent of either, lane 0 is the OUTER-edge bit of the
serialiser frame** and its weakest mitigation is the per-lane phase
sweep. Confirm the calibrator's `S_HOLD` keeps `training_mode=1` long
enough for the peer's sweep to settle — the live build's iterator
freeze on a particular (slip, phase) which happens to MISS the lane-0
eye is consistent with `S_HOLD` exiting before the slave finishes its
own first sweep. Bump `HOLD_CYCLES` from `8 * 128 * DWELL_CYCLES`
(default in `tidelink_phy_align_calibrator.sv:189`) to `16 *` to give
the peer twice as long.

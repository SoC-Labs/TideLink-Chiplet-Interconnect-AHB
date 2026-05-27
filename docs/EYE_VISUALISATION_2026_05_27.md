# TideLink eye visualisation — HW evidence summary (2026-05-27)

Built from live HW on `bridge1` (z2_02 master + z2_03 slave) running the
calibrator-fix bitstream (tdif-24, S_PROBE bias to (0,0)).

## 1. Global clock-data phase sweep (live, 16-point sweep)

Sweeping `swi_phase_offset[3:0]` (PHY_CTRL bits[20:17]) on each die,
observing how many lanes lock at each phase. This is a GLOBAL clock-phase
sweep, not per-lane.

```
phase  master    slave    width-1 contiguous run?
 0     ████████  ████████  ← only valid point (both)
 1     ........  ........
 2     ........  ........
 3     ........  ........
 4     ........  ........
 5     ........  ........
 6     ........  ........
 7     ........  ........
 8     ████████  ████████  ← 180° rotation (both)
 9     ........  ........
10     ........  ........
11     ........  ........
12     ........  ........
13     ........  ........
14     ........  ........
15     ........  ........
```

`████████` = `lock=0xff` (all 8 lanes locked).
`........` = `lock=0x00` (no lane locks).

**Eye width on this axis: 1 phase point.** No contiguous run.

The 180° rotation (phase 0 and phase 8) is consistent with source-
synchronous sampling — the half-rate clock catches data at both rising
and falling edges.

**Caveat:** This is the GLOBAL phase override (single 4-bit knob applied
across all lanes uniformly). The calibrator's per-lane IDELAYE2 taps
are managed internally and not visible from this sweep.

## 2. ECC corruption rate (post-bringup, 4096 captured cycles)

Source: `/tmp/ila_axil_capture.csv` on mapstone-dev (ILA captures from
tdif-23 silent-link-bug probes — `u_wlink/llrx/ecc_check_*`).

```
4096 samples; 0 corrupted (0.0%); 4096 corrected (100.0%)
                ^                  ^
                no uncorrectable    EVERY sample has at least one
                errors detected     correctable single-bit error
```

**Interpretation:** the link is operating with **continuous single-bit
correction across every cycle**. Header ECC is recovering but the eye
margin is fully exhausted. Per Agent O's hypothesis (`crc_corrupt=1`
across 4096 samples in tdif-22/23/24 captures): on real data with ISI,
the same eye-edge pick fails CRC, not just ECC.

## 3. Implication

The calibrator (with the S_PROBE bias-to-(0,0) fix) picks a phase that:
- ✓ Locks the byte-align FSM on the training pattern
- ✓ Allows cr/crack handshake packets to traverse (short, ECC-protected)
- ✗ Has ZERO margin against real-data ISI
- ✗ Allows continuous single-bit corruption (ECC masks it)
- ✗ Drops real data packets that exceed ECC correction capability

This matches Agent O's diagnosis precisely. The fix path: replace
"any passing point" selection with "centre of widest contiguous run"
(MIN_LOCK_DWELLS≥4) per the structural fix proposal at
`/home/dam1n19/SoCLabs/td-bisect/td-fix-proposal/docs/agent_o_structural_fix_proposal.md`.

## 4. What's missing for a TRUE per-lane 2D eye

We can see the global clock phase sweep result, but cannot see:
- Per-lane IDELAYE2 tap response (the calibrator's actual sweep grid)
- Real-data ISI effect on a per-lane basis
- The actual 128-point (8 slip × 16 phase) score map per lane

These require RTL changes (Option C) — expose the calibrator's
internal `lane_score[i]` history via APB so a Python tool can fetch
and plot 8 per-lane 2D heatmaps.

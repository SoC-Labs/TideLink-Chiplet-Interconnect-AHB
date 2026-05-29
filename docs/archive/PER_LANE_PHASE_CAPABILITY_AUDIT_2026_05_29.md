# Per-Lane Phase Capability Audit — 2026-05-29

Read-only audit of the GPIO-PHY calibration chain on
`feat/td-gpio-phy-integration` at worktree
`/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ`. Sister doc to
`docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md`.

Question: **does the RTL structurally support automatically detecting
and setting per-lane phase offsets across all 8 lanes?** The eye-GUI
heatmap (captured 2026-05-29 morning) sweeps the single global PHY-CTRL
`swi_phase_offset` knob 0..15 and shows no row in which all 8 slave
lanes lock simultaneously — slave `{L0:6, L1:7, L2:7, L3:7, L4:3, L5:7,
L6:7, L7:7}` requires per-lane phase values. The question is whether
the RTL chain can resolve this without SW intervention once the
calibrator's scoring bug is repaired.

---

## Verdicts (per the six concrete sub-questions)

| # | Question | Verdict | Citation |
|---|----------|---------|----------|
| **A** | lane_checker reports per-lane evidence (per-lane lock + per-lane min-distance) | **YES, capable today** | `deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv:27` (`lane_locked_o[7:0]`), `:32` (`dwell_min_dist_o[39:0]` = 8 × 5b), `:42-110` per-lane generate of `tidelink_lane_checker_single` |
| **B** | calibrator iterates `(slip, phase)` globally but evaluates each lane independently | **YES, capable today** | `src/rtl/tidelink_phy_align_calibrator.sv:1027-1034` S_PROBE per-lane `if (lane_locked[i])` accumulator; `:1108-1117` S_SWEEP per-lane gating; `:1153-1205` per-lane run_len / best_run / any_pass tracking — all independently indexed by `[i]` |
| **C** | calibrator stores per-lane winning `(slip, phase)` independently | **YES, but currently broken because of the `dwell_min_dist_o` stickiness bug from CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md** (in code as Fix A2 reverted to `lane_locked[i]`, but Fix A2 has not been validated on silicon yet). Per-lane storage structure is correct: `src/rtl/tidelink_phy_align_calibrator.sv:579-580` (`slip[0:7]`, `phase[0:7]`), `:1049-1067` per-lane S_PROBE latch, `:1271-1310` per-lane S_FINALIZE latch. The fault is in the scoring predicate, not in the storage |
| **D** | calibrator output is per-lane packed (8 × 4b phase + 8 × 3b slip), not a single global value | **YES, capable today** | `src/rtl/tidelink_phy_align_calibrator.sv:327` (`bit_slip[23:0]`), `:331` (`phase_offset[31:0]`), `:1517-1531` per-lane output mux: `bit_slip_internal[3*i +: 3] = slip[i]`, `phase_offset_internal[4*i +: 4] = phase[i]` |
| **E** | WavD2DGpioRx consumes per-lane `io_phase_offset` (each instance independent) | **YES, capable today** | `src/rtl/local_overrides/WavD2DGpioRx.v:160` (`input [3:0] io_phase_offset`), `:205` (`adj_count = count + io_phase_offset`); `src/rtl/local_overrides/WavD2DGpio.v:718,733,748,763,778,793,808,823` eight per-instance `.io_phase_offset(effective_phase_offset[4*N +: 4])` connections |
| **F** | full path lane_checker → calibrator → axi_chiplet_controller OR-merge → WavD2DGpio → WavD2DGpioRx preserves per-lane independence end-to-end | **YES, capable today (modulo Fix A2 / Fix A1 to unblock scoring)** | end-to-end packed per-lane signals throughout: calibrator out → `src/rtl/local_overrides/axi_chiplet_controller.sv:1471,1477` OR-merge → `:1719` `.swi_phase_offset_in(swi_phase_offset_w)` → `src/rtl/local_overrides/WavD2DGpio.v:555-565` per-lane OR-merge with global suppression → per-instance Rx |

**Net verdict:** the chain is **already structurally capable** of
resolving the eye-GUI-observed per-lane heterogeneity automatically.
What blocks it today is **only** the calibrator's per-dwell scoring
bug (`dwell_min_dist_o` is sticky across dwells, see
CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md). Fix A2 (revert score
predicate to binary `lane_locked[i]`) is **sufficient** to unblock
automatic per-lane resolution — no additional RTL is required to
preserve per-lane bests because S_PROBE/S_SWEEP/S_FINALIZE already
latch `slip[i]` and `phase[i]` independently for each lane.

---

## Per-lane signal flow diagram

```
                       8 × 16-bit deserialised lanes
                            (per-lane data)
                                  │
                                  ▼
            ┌──────────────────────────────────────────┐
            │     tidelink_lane_checker                │
            │  ┌────────────────────────────────────┐  │
            │  │ tidelink_lane_checker_single  ×8   │  │
            │  │   (one independent instance per    │  │
            │  │    lane; own match_count, own      │  │
            │  │    dist_match, own dwell_min)      │  │
            │  └────────────────────────────────────┘  │
            └──────────────────────────────────────────┘
              │ lane_locked_o[7:0]     │ dwell_min_dist_o[39:0]
              │ (8 × 1b per-lane lock) │ (8 × 5b per-lane metric)
              ▼                        ▼
            ┌──────────────────────────────────────────┐
            │   tidelink_phy_align_calibrator          │
            │                                          │
            │   FSM iterator: sweep_slip[2:0],         │
            │                 sweep_phase[3:0]         │
            │   (one shared iterator — walks the grid) │
            │                                          │
            │   PER-LANE STORAGE (independent):        │
            │     slip[i][2:0]   ×8                    │
            │     phase[i][3:0]  ×8                    │
            │     lane_score[i]  ×8                    │
            │     run_len[i]     ×8                    │
            │     best_run[i]    ×8                    │
            │     best_run_start_phase[i] ×8           │
            │     best_run_slip[i]        ×8           │
            │     any_pass_*[i]           ×8           │
            │                                          │
            │   At each dwell expiry the iterator      │
            │   ADVANCES once; each lane INDEPENDENTLY │
            │   decides whether to extend its run /    │
            │   promote its best / latch its any_pass. │
            │   At S_FINALIZE each lane gets its OWN   │
            │   (slip[i], phase[i]) from its OWN       │
            │   per-lane best.                         │
            └──────────────────────────────────────────┘
              │ bit_slip[23:0] = {slip[7], ..., slip[0]}    (8 × 3b)
              │ phase_offset[31:0] = {phase[7], ..., phase[0]} (8 × 4b)
              ▼
            ┌──────────────────────────────────────────┐
            │   axi_chiplet_controller (Region 8 SW    │
            │   override regs OR-merged in)            │
            │                                          │
            │   swi_phase_offset_w = cal_phase_offset_w│
            │                       | swi_phase_offset_r│
            │   swi_bit_slip_w     = cal_bit_slip_w   │
            │                       | swi_bit_slip_lo_r│
            │                                          │
            │   Both contributions are per-lane packed.│
            │   OR-merge is per-nibble, so a SW write  │
            │   can set lane N's phase without         │
            │   disturbing lanes M (modulo OR semantics│
            │   — see §9.7 comment).                   │
            └──────────────────────────────────────────┘
              │ swi_phase_offset_w[31:0] (8 × 4b)
              │ swi_bit_slip_w[23:0]     (8 × 3b)
              ▼
            ┌──────────────────────────────────────────┐
            │   WavD2DGpio (per-lane effective phase   │
            │                 with global-suppression) │
            │                                          │
            │   wire any_per_lane_phase_set =          │
            │              |io_swi_phase_offset_in;    │
            │   wire effective_global_phase =          │
            │     any_per_lane_phase_set ? 4'h0        │
            │                            : swi_phase_offset;│
            │   for (gl=0..7):                         │
            │     effective_phase_offset[4*gl +: 4] =  │
            │       io_swi_phase_offset_in[4*gl +: 4]  │
            │       | effective_global_phase;          │
            └──────────────────────────────────────────┘
              │ effective_phase_offset[31:0] (8 × 4b)
              ▼
            ┌──────────────────────────────────────────┐
            │   8 × WavD2DGpioRx (one per lane)        │
            │                                          │
            │   instance N: .io_phase_offset(          │
            │       effective_phase_offset[4N +: 4]);  │
            │     adj_count = count + io_phase_offset; │
            │   (one independent count/adj_count chain │
            │    per lane — lane M's count_reg has no  │
            │    visibility of lane N's phase_offset)  │
            └──────────────────────────────────────────┘
```

End-to-end: at every layer the per-lane independence is preserved by
packing 8 × {3, 4, 5}-bit fields into a flat bus and indexing per-lane.

---

## MMIO addresses

These are absolute addresses inside the tidelink chiplet aperture
(`0x4403_2000` base for chiplet 0 — adjust for other peers via
APB-bridge address translation). Source: `axi_chiplet_controller.sv:88-89`
(Region 8 base 0x100) and the case decode at `:730-748` / `:753-781`.

| Address | Width | Name | Direction | Notes |
|--------:|:-----:|------|-----------|-------|
| `0x4403_2100` | 32b | SWI_TRAINING_MODE | RW | bit[0]=training_mode, bit[1]=SWI_RECAL (level into calibrator swreset) |
| `0x4403_2104` | 32b | SWI_BIT_SLIP_LO | RW | bits[23:0] = 8 × 3-bit per-lane bit_slip; OR-merged with calibrator `cal_bit_slip_w` into Wlink `swi_bit_slip_in` |
| `0x4403_2108` | 32b | SWI_LANE_STATUS / CREDIT_PATH_STATUS | RO | [7:0] lane_locked, [15:8] lane_fault, [16] cal_done, [22:17] FCSM/LLRX/obs |
| `0x4403_210C` | 32b | NEGO_TRAIN_CFG | RW | bits[15:0] |
| `0x4403_2110` | 32b | TRAIN_STATUS | RO | autoneg-train state |
| `0x4403_2114` | 32b | ECC_COUNTERS | RO | [31:16] corrected, [15:0] corrupted |
| `0x4403_2118` | 32b | **SWI_PHASE_OFFSET** | RW | **bits[31:0] = 8 × 4-bit per-lane phase**; OR-merged with calibrator `cal_phase_offset_w` into Wlink `swi_phase_offset_in` |
| `0x4403_211C` | 32b | PHY_ALIGN_ID | RO | constant `0x5041_0100` ("PA" v1.0) |

The Region 8 base address is documented inline at
`axi_chiplet_controller.sv:1712-1719` ("MMIO 0x4403_2104 / 0x4403_2100",
"MMIO 0x4403_2118").

**`SWI_PHASE_OFFSET` packing:** lane N's 4-bit phase lives at bits
`[4N+3 : 4N]` — L0 at `[3:0]`, L1 at `[7:4]`, ..., L7 at `[31:28]`.
Same packing as the calibrator's `phase_offset[31:0]` output and the
WavD2DGpio per-lane mux.

**`SWI_BIT_SLIP_LO` packing:** lane N's 3-bit slip at bits
`[3N+2 : 3N]` — L0 at `[2:0]`, L1 at `[5:3]`, ..., L7 at `[23:21]`.

**Note on the user's "+0x108" mention:** SWI_BIT_SLIP_LO is at **+0x104**
(decode 3'h1), not +0x108. +0x108 (decode 3'h2) is SWI_LANE_STATUS
(RO observability). The 24-bit per-lane bit_slip override register is
+0x104.

**tidelink-gpio-phy APB regs at 0x4403_2160-0x4403_217F** (Region 11,
spec deviation documented at `src/rtl/tidelink_top.sv:898-926`): this
slave carries the per-lane noise observability + SW-writable lock
threshold + wiring/canary status (THRESH at slave-paddr 0x20 through
CANARY at 0x3C, mapped into 0x160-0x17F). Not on the calibrator
output path — read-side only for the new lane_checker's noise/canary
metrics. Not required for per-lane phase selection.

---

## What the GUI should display post-Fix-A2

Once Fix A2 lands (`tidelink_phy_align_calibrator.sv:1014-1098` already
contains the reverted scoring path — needs HW validation), the
calibrator will choose per-lane `(slip[i], phase[i])` values that
genuinely reflect each lane's individual eye centre. The eye-tool GUI
should be extended to read **`SWI_PHASE_OFFSET` at +0x118** and
**`SWI_BIT_SLIP_LO` at +0x104** post-calibration, then display the
chosen per-lane mapping as a small 8-row table (one row per lane,
showing the 4-bit phase nibble and 3-bit slip nibble each lane was
latched to). The expected post-Fix-A2 output for the user's slave
board should look approximately like `{L0:phase=6, L1:phase=7, L2:7,
L3:7, L4:phase=3, L5:7, L6:7, L7:7}` (matching the per-lane lock
pattern from the eye-GUI heatmap), with the master showing
`{L0..L7:phase=0}`. The existing global-sweep heatmap should be
retained for diagnostic purposes — its FAILURE to find a single phase
locking all 8 slave lanes is itself the diagnostic signature of
per-lane heterogeneity, and confirms the calibrator's per-lane
resolution is necessary (not just decorative).

---

## Does the eye-GUI screenshot point to a second bug?

**No — the screenshot is fully consistent with the
`dwell_min_dist_o` stickiness bug from
CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md plus the fundamental
limitation that the GUI sweeps the **global** PHY-CTRL phase knob
(WavD2DGpio's `swi_phase_offset` register at bits[20:17], NOT the
per-lane `swi_phase_offset_r` at +0x118). The global knob is
broadcast to all 8 lanes (with the per-lane OR-merge suppressing it
only when at least one per-lane nibble is non-zero —
`WavD2DGpio.v:552-554`), so when the GUI sweeps it through 0..15 it is
asking "is there a single global phase that locks all 8 lanes?" The
heatmap answer is "no" — that is the EXPECTED result on a board whose
true per-lane eye centres are heterogeneous, and it does NOT indicate
a second bug. It does, however, demonstrate that a working calibrator
is required to set per-lane phases automatically (the slave board has
no single global phase that works — only a per-lane mapping does).
The master row 0 all-green at phase=0 is consistent with the master's
true per-lane eye centres being uniformly at phase=0 (i.e. the master's
RX path has a flat clock-to-data skew across all 8 lanes), which the
calibrator's existing S_PROBE bias to (0,0) is already optimal for. The
slave's heterogeneity is precisely what the calibrator's per-lane
sweep + per-lane S_FINALIZE latch was designed to resolve, and Fix A2
is the only remaining blocker.

---

## Files referenced

- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/tidelink_phy_align_calibrator.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/axi_chiplet_controller.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/WavD2DGpio.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/WavD2DGpioRx.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/tidelink_top.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker_single.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md`

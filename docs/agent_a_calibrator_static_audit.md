# Calibrator RTL static-audit findings

**Scope:** read-only static analysis of `tidelink_phy_align_calibrator.sv` and
its immediate integration. Bug under investigation: with `AUTOCAL_ENABLE=1`
sideband packets **M -> S** never reach the slave FC adapter RX; **S -> M**
works; both sides reach `cal=DONE`; `AUTOCAL_ENABLE=0` fixes both directions.

**Headline negative result:** `tidelink_phy_align_calibrator.sv` contains *no*
role-conditional code. There is no `role_is_master`/`role_strap_i` port, no
master-vs-slave branch, no role-aware reset, no role-aware latch. The
calibrator itself is a pure-symmetric FSM. **Any role asymmetry has to come
from (a) timing skew of role-symmetric inputs, (b) what the calibrator picks
when its score function is degenerate, or (c) the OR-merge it shares with the
autoneg-driven `swi_training_mode_r`.**

The handoff doc named in the task brief
(`docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md`) does not exist in the worktree
(checked `docs/` and `find . -iname CALIBRATOR*HANDOFF*`); the analysis below
is from RTL only.

---

## 1. TOP suspects (HIGH confidence)

### S1. Best-of-sweep "final-dwell tiebreak" latches (slip=7, phase=15) on any tied score — per-lane independent, can converge differently on M and S

**File:** `src/rtl/tidelink_phy_align_calibrator.sv`
**Lines:** 631-664 (sweep-exhaustion latch) and 604-612 (per-dwell best-of capture).

```systemverilog
if (lane_score[i] > best_score[i]) begin              // 647
    if (lane_score[i] >= lock_thresh_6b) begin
        slip[i]  <= sweep_slip;                       // = 7 (final iter)
        phase[i] <= sweep_phase;                      // = 15 (final iter)
    end else begin
        lane_fault_q[i] <= 1'b1;
    end
end else begin                                        // 654
    if (best_score[i] >= lock_thresh_6b) begin
        slip[i]  <= best_slip[i];
        phase[i] <= best_phase[i];
    end ...
end
```

The score is a 6-bit run-length of `lane_locked=1`, saturating at 63 — and any
(slip,phase) pair that gives a continuous `DWELL_CYCLES`-long lock window
saturates at the same maximum. The comparator at line 647 is **strictly
greater**. Combined with the score-update at line 604-612 (also strictly
greater), the policy "prefer earlier" holds, **except** at the final point
(15,7): the score-capture at 604-612 happens in the same `always_ff` block as
the latch at 647, so when the final dwell ties or marginally beats the running
best, line 647 picks the LIVE iterator (slip=7, phase=15). For a lane whose
eye is wide, the score saturates at the very first locking point and stays
saturated for every subsequent locking point — so the *only* way the final
point can be picked is if it's strictly greater than the running best, which
near-saturation is extremely sensitive to a 1-cycle noise bin. **In practice
the per-lane chosen (slip,phase) is whatever the comparator races picked,
which is independent on M and S** because their `lane_locked` traces are
independent (different physical RX paths). M and S can therefore converge to
different per-lane (slip,phase) choices even with identical training patterns
and identical RTL.

Why this could produce role-asymmetric corruption: the **slave's** calibrator
tunes the **slave's** RX capture, which is the **M -> S** datapath. If the
slave races to a worse-but-still-LOCK_THRESH-passing (slip,phase) than the
master picks for S -> M, M -> S is exactly the direction that breaks while
S -> M holds. The bug being one-directional and per-build (not random) fits
this exactly.

**Confidence:** HIGH (mechanism is concrete; bug symptom matches).

**Suggested fix (<10 lines):** make the comparator non-strict for the
tie-breaker so the *earliest* saturating point wins, and never latch the live
iterator at the final dwell. Replace 647-664 with:

```systemverilog
// At iter_at_end, fold this dwell's score into best_* using >= so
// earlier-equal wins, then ALWAYS latch from best_* (never from the live
// iterator). Removes the (15,7)-bias and ties M/S to the same policy.
logic [5:0] final_score;
logic [2:0] final_slip;
logic [3:0] final_phase;
final_score = (lane_score[i] > best_score[i]) ? lane_score[i] : best_score[i];
final_slip  = (lane_score[i] > best_score[i]) ? sweep_slip    : best_slip[i];
final_phase = (lane_score[i] > best_score[i]) ? sweep_phase   : best_phase[i];
if (final_score >= lock_thresh_6b) begin
    slip[i]  <= final_slip;
    phase[i] <= final_phase;
end else lane_fault_q[i] <= 1'b1;
lane_done[i] <= 1'b1;
```

(The structural simplification — single decision point — also removes the
NBA-ordering hazard called out in the comment at lines 642-646, which is
itself a smell.)

---

### S2. `swi_training_mode_w` deassert race: master holds TX training pattern for the full I2C round-trip *after* the slave has dropped it

**File:** `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`
**Lines:** 685-688 (Region-8 mode register), 1086-1122 in
`tidelink_autoneg.sv` (master EXIT sequence), 1372 (OR-merge to Wlink).

```systemverilog
// axi_chiplet_controller.sv:685
if (local_training_mode_set_w)        swi_training_mode_r <= 1'b1;
else if (local_training_mode_clr_w)   swi_training_mode_r <= 1'b0;
...
wire swi_training_mode_w = cal_training_mode_w | swi_training_mode_r;
```

`tidelink_autoneg.sv` runs the **master-only** I2C-coordinated training exit
(line 880-884: *"Only the master walks these states; the slave's autoneg
parks in ST_NEGO_DONE and observes its own SWI_TRAINING_MODE register being
toggled by master's I2C writes"*). The sequence at `ST_TRAIN_EXIT` (1086) is:

1. Master writes peer (slave) `SWI_TRAINING_MODE := 0` over I2C (6 bytes
   + STOP, ~hundreds of cycles)
2. On peer-ACK, master *then* pulses `local_train_clr_pulse_r` -> master's
   own `swi_training_mode_r <= 0`

So for the duration of the I2C-EXIT transaction, **slave has dropped
SWI_TRAINING_MODE but master is still asserting it**. During this window:

- Master TX continues to emit the training pattern (still `training_mode=1`)
- Slave RX is no longer in calibration; the calibrator-driven phase is
  latched and S_HOLD/S_DONE; slave's TX has dropped training_mode
- This produces a **persistent M->S training pattern overlay** while the
  slave is trying to interpret real packets

Even if the slave's calibrator latched the *right* phase, the data the slave
RX sees during this window is still the master's training pattern (not real
LL_TX packets), so the slave's FC adapter RX sees no real packets in this
window. That alone shouldn't be persistent — but combined with S1 above, if
the slave latched a marginal phase, the eye for *real data* (which has
different transition density than the period-8 training byte) may close on
exit-from-training, leaving M -> S permanently dead at the byte-align layer
while S -> M (slave -> master) is unaffected.

Why this is role-asymmetric: the master-only I2C-exit path is the *only*
mechanism that introduces a deterministic time window where the two sides'
`training_mode` levels disagree. With `AUTOCAL_ENABLE=0` neither the
calibrator nor the autoneg-coordinated training ever runs, so this window
doesn't exist — matching the bug's "0 fixes it" property.

**Confidence:** HIGH (asymmetry is structural, present on every build,
explains the directionality).

**Suggested fix (<10 lines):** either (a) move the local
`swi_training_mode_r <= 1'b0` to **before** the I2C transaction so the
master drops first (closing the window in the M->S direction), or (b) gate
the OR-merge with a `training_drain` counter so master holds for an extra
HOLD_CYCLES after the calibrator's S_HOLD has expired. The cleanest minimal
patch is (a):

```systemverilog
// tidelink_autoneg.sv ST_TRAIN_EXIT entry — drop local FIRST
ST_NEGO_DONE_PRE: begin
    ...
    local_train_clr_pulse_r = 1'b1;     // local := 0 BEFORE writing peer
    ...
end
```

(Touches `deps/`. Next agent: mirror under `src/rtl/local_overrides/` per
the project's read-only `deps/` policy.)

---

## 2. Secondary suspects (MED / LOW)

### S3. `tb_early_exit_force_q` undriven `reg` (line 296) — pure-RTL elaboration value of `x` in some sims; cocotb hierarchical force only works once driven

**File:** `tidelink_phy_align_calibrator.sv:296-298`
```systemverilog
/* verilator lint_off UNDRIVEN */
reg tb_early_exit_force_q = 1'b0;
/* verilator lint_on UNDRIVEN */
wire early_exit_en_w = EARLY_EXIT_ON_ALL_LOCKED | tb_early_exit_force_q;
```

Initialised at declaration, so silicon is fine. But if a sim flow ever
treats `reg` declaration-initialiser as time-0 only and a 4-state X-prop run
clobbers it, `early_exit_en_w` is X and the FSM path is undefined. The bug
report is for HW, so this is unlikely the silicon path — but it's worth
verifying with a cocotb force probe at S_FINISH entry to make sure
`early_exit_en_w` is the same on both sides.

**Confidence:** LOW (sim hygiene; not a silicon path).

### S4. CDC: calibrator outputs feed Wlink `swi_*_in` ports with no synchroniser

**File:** `axi_chiplet_controller.sv:1365-1372`, `1609-1613`.
`cal_bit_slip_w`, `cal_phase_offset_w`, `cal_training_mode_w` are in
`phy_link_rx_rx_link_clk_w` domain (calibrator clock = recovered RX link
clock). They are OR'd with apb_clk-domain regs (`swi_*_r`) and fed *raw*
into `Wlink.swi_*_in`. The Wlink soft-strap path samples them in apb_clk.
Multi-bit values (`swi_bit_slip_w[23:0]`, `swi_phase_offset_w[31:0]`) can
shear across the boundary at the moment the calibrator transitions
S_SWEEP -> S_FINISH -> S_DONE (when `lane_done[i]` flips, the output bundle
changes value in one calibrator-clock cycle).

This is role-symmetric in cause but the *captured* sheared value can differ
per side because the apb_clk vs link_rx_clk phase relationship is per-build.

**Confidence:** MED (real CDC defect; whether it produces the observed
M->S-only asymmetry needs a cocotb scan of `swi_phase_offset_w` value held
across the S_FINISH/S_DONE edge with the apb_clk sampling). Fix is a 2-flop
sync of the 8x4 phase bus into apb_clk before the OR-merge.

### S5. S_HOLD release on `!role_locked` (calibrator:478)

```systemverilog
S_HOLD: begin
    if (swreset)                   nxt_state = S_CANCEL;
    else if (!role_locked)         nxt_state = S_DONE;
    else if (hold_ctr >= HOLD_MAX) nxt_state = S_DONE;
end
```

If the slave's `role_locked` glitches low for one cycle after S_HOLD entry,
its calibrator drops to S_DONE early — *without* the HOLD_CYCLES wait —
while the master continues to hold training_mode high. This produces the
same asymmetric "master still in training, slave out" window as S2 but
without an I2C transaction in flight.

**Confidence:** LOW (`role_locked` is a level held by a controller reg and
unlikely to glitch). Worth a cocotb probe of `role_locked` continuity on
slave during S_HOLD.

### S6. lane_checker reset edge: `rst(~role_locked)`

**File:** `axi_chiplet_controller.sv:1307`.
The lane_checker is held in reset until `role_locked=1`. If the calibrator's
trigger sees `role_locked_rise` one cycle before the lane_checker's
flop-pipeline has cleared, the first ~1-2 dwells of the sweep score
**reset-residual zeros**, not real lane_locked, on the side whose role_locked
rises later (whichever that turns out to be — typically the master since
autoneg latches role_locked on the master first after I2C handshake). This
biases the **first** few dwells but the sweep continues through 128 points
so the impact is small.

**Confidence:** LOW. Easy cocotb probe.

---

## 3. Cleared (checked and ruled out)

- **Calibrator role-awareness.** No `role_is_master`, no `role_strap_i`,
  no master/slave branches in `tidelink_phy_align_calibrator.sv`. Pure
  symmetric.
- **Calibrator instantiation symmetry** (`axi_chiplet_controller.sv:1327`):
  every input wired identically on M and S except `role_strap_i` (which
  doesn't reach the calibrator instance — calibrator sees `role_locked`,
  same level on both sides post-handshake).
- **`swi_recal_r` retrigger asymmetry.** The autoneg FSM never writes
  `swi_recal_r` directly; only Region-8 APB writes do. Both sides have
  `swi_recal_r=0` throughout AUTOCAL flow. No spurious sweep restart on
  either side.
- **IDELAY tap mapping** (`tidelink_idelay_rx.sv:150-151`): identical
  `{phase, 1'b0}` scaling on both sides. No role-dependent tap range.
- **`tidelink_rxclk_buf.sv`**: pure passthrough or single-BUFG, no
  role-dependent logic. Generate-if on `USE_CLKBUF` only.
- **`tidelink_lane_checker.sv`**: per-lane PATTERNS array is hard-coded
  (same on both sides). LOCK_THRESH parameter identical via instantiation.
- **POR / `wlink_por_reset`** (`axi_chiplet_controller.sv:751`): symmetric
  formula `~poresetn | ~role_locked` on both sides.
- **`tidelink_top.sv:1629-1855` axi_chiplet_controller instantiation:**
  only `role_strap_i` differs between M and S; every calibrator-relevant
  parameter (`AUTOCAL_ENABLE=1'b1`, `USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`)
  is set unconditionally.
- **`local_swreset_pulse_w` from autoneg** is dead-end at
  `axi_chiplet_controller.sv:1202` (`wire _unused_phase3_a = ...`). Not
  wired to Wlink swreset. So the swreset_hold post-EXIT pulse has no RTL
  effect.

## 4. Open questions for the next (cocotb-probing) agent

1. **Score-tiebreak verification (S1).** Probe `slip[i]`, `phase[i]`,
   `best_slip[i]`, `best_phase[i]` at S_FINISH entry on both sides for the
   same sim seed. If S latches a (15, *) or (*, 15) pair while M latches an
   interior value, S1 is confirmed.
2. **Training-mode deassert window (S2).** Capture
   `swi_training_mode_w` on M and S during the I2C exit transaction. Measure
   the cycle count between slave's deassert and master's deassert. If the
   gap > 64 cycles (single byte slot), S2 is real.
3. **Phase-bus shear at S_DONE (S4).** Sample `swi_phase_offset_w` on the
   apb_clk side at the rising edge of `cal_calibration_done_w` on slave.
   Verify all 32 bits transition atomically (no shear).
4. **`role_locked` continuity during slave S_HOLD (S5).** If S_HOLD on the
   slave is shorter than HOLD_CYCLES, S5 is confirmed.
5. **Latched (slip, phase) vs real-data eye.** Even with correctly chosen
   training-pattern phase, does the slave's latched (slip, phase) actually
   work for *random* data? Force the slave's calibrator output to known
   good values from a passing M->S build and re-run — if M->S works, the
   calibrator choice itself is wrong (S1). If M->S still fails, the
   problem is downstream of the calibrator (PHY config or training-mode
   exit, i.e. S2).

---

## Note on `deps/` fixes

S2 lives in `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` —
out of project scope. The next agent should mirror the modified file under
`src/rtl/local_overrides/` and wire the flist to the local copy. S1 is in
`src/rtl/tidelink_phy_align_calibrator.sv` (in-scope, fix in-place).

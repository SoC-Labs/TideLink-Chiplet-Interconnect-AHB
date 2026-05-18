# `cocotb/phy_align/` — PHY-layer alignment tests

These tests exercise the per-lane bit-slip + training-pattern alignment
mechanism (BRINGUP_REPORT.md §9). They are physically separated from the
`cocotb/wlink_pair/` integration tests so the alignment work is *extraction-
ready* — see [`deps/axi-chiplet-controller/logical/phy-align/README.md`](../../deps/axi-chiplet-controller/logical/phy-align/README.md)
for the future repo split.

## Contents

| File | Purpose |
|---|---|
| `wlink_lane_checker.sv` | Per-lane training-pattern lock detector (8-lane wrapper + single-lane core). Inputs `lane_data[127:0]` (8 × 16-bit per-lane words from the deserialiser); outputs `lane_locked[7:0]`. Compares each lane against a period-8 byte pattern; asserts the lane's `locked` after 16 consecutive matches. Used by `tb_top.sv` to expose per-lane alignment status to the cocotb test. |
| `test_pair_align.py` | The §9 calibration test. Sweeps per-lane bit_slip 0..7 looking for `lane_locked` on each side, applies the calibrated slips, exits training mode, asserts FCSM advances to state=4 with cr_pkt_seen_rx on both sides. |
| `test_calibrator_skew_window.py` | **§9 calibrator skew-window CONTRACT.** Pins the autonomous calibrator's bit-slip × phase SEARCH WINDOW so a future RTL edit cannot silently shrink the skew margin the FPGA timing-determinism work depends on. See [§ Calibrator skew-window contract](#calibrator-skew-window-contract). |
| `Makefile` | Delegates to `../wlink_pair/Makefile` (which owns the testbench top compile) with the correct `MODULE` + `PYTHONPATH`. |

## Run

```sh
cd cocotb/phy_align
make SKID_BITS=3         # default test, skid amount 3 — the FPGA-observed shift
make SKID_BITS=5 MODULE=test_pair_align
```

Tested SKID_BITS values: 0, 1, 3, 5, 7 — all PASS (calibration converges, link
comes up with FCSM advancing to state=4).

## How this relates to the §9 RTL changes

`wlink_lane_checker.sv` here is **the receive-side checker** — a wrapper module
that watches the deserialiser's output. It works alongside the in-place edits to
`WavD2DGpio.v`, `WavD2DGpioRx.v`, `WavD2DGpioTx.v` in the Wavious Wlink generated
Verilog tree. Those edits add:

- `swi_bit_slip[23:0]` — 8 lanes × 3 bits, per-lane right-rotation amount.
- `swi_training_mode` — when high, TX serialiser sources fixed per-lane training
  bytes instead of LL data.
- Per-lane training byte selection (period-8 bytes, see `wlink_lane_checker.sv`
  inline comments for the rationale on rotational-period choice).

The current `cocotb/phy_align/` test reaches into the DUT hierarchy via cocotb
to drive `swi_bit_slip` and `swi_training_mode` directly; the production version
would drive these from APB. See BRINGUP_REPORT.md §9 for the full design.

## Extraction plan

When the PHY moves to its own repo (`wlink-phy-align/` or similar) this
directory becomes the PHY repo's cocotb entry point. The current
`test_pair_align.py` is a *pair-level* test (master+slave Wlink full stack) and
would live in the TideLink-side repo; PHY-only tests (drive pad bundle on one
side, observe Link2PHY bundle on the other) would be added here. The
`wlink_lane_checker.sv` module is fully self-contained and moves cleanly.

## Calibrator skew-window contract

`test_calibrator_skew_window.py` makes the §9 calibrator's
(`src/rtl/tidelink_phy_align_calibrator.sv`) bit-slip × phase search
window an **explicit, asserted contract**. The Pynq-Z2 FPGA bring-up is
blocked by build-to-build PHY routing-skew nondeterminism; the calibrator
can only rescue a lane if the build-time clk-to-data skew lands inside its
finite search window, and the whole timing-determinism remediation plan
(`/tmp/timing_determinism_investigation_brief.md`) assumes that window is a
known, stable size. A future RTL edit that shrinks it (fewer slips, fewer
phase steps, shorter dwell, narrower give-up criterion) would silently
break that plan with no existing test failing — `test_phase_sweep` /
`test_autocal_integrated` converge under a SKID that locks early and never
push the iterator to its edges.

### Documented window dimensions (read from the RTL on this branch)

| Dimension | Value | RTL line refs (`tidelink_phy_align_calibrator.sv`) |
|---|---|---|
| Bit-slip values | **8** (slip ∈ [0..7]) | `logic [2:0] sweep_slip` L245; wrap `sweep_slip == 3'd7` L353; header L99-103 |
| Phase values | **16** (phase ∈ [0..15]) | `logic [3:0] sweep_phase` L246; exhaust `sweep_phase == 4'd15` L355; `+ 4'd1` L366 |
| Per-(slip,phase) dwell | **`DWELL_CYCLES`=32** (≥ lane-checker LOCK_THRESH 16) | `parameter DWELL_CYCLES = 32` L147; `DWELL_MAX` L248; gate L347 |
| Fault criterion | only after **full 8×16=128** space exhausted | L353-364; header L122-123 |
| **Total search cardinality** | **8 × 16 = 128 points** | — |

### What the two tests assert

* `test_calibrator_skew_window_structural` — elaborated iterator widths
  (`sweep_slip`, `sweep_phase`) and the `DWELL_CYCLES` parameter must be
  ≥ the documented window. Catches width-narrowing / too-short dwell.
* `test_calibrator_skew_window_traversal` — enables the autocal
  calibrator, role-locks with lane 4 **stuck** (`STUCK_LANES_MASK=16`, its
  serial line pinned to 0 so it can never lock), and samples the
  calibrator's internal shared iterator (`u_calibrator.sweep_slip /
  .sweep_phase`) on every recovered **RX link clock** edge
  (`dut.s_rx_link_clk` — the divide-by-8 clock the calibrator actually
  runs on). The stuck lane forces a full window traversal; the test
  asserts the iterator reaches slip==7 **and** phase==15, that the stuck
  lane is **not** faulted until both maxima are reached (no early
  give-up), and that the observed cardinality == 128. `lane_fault_q` is a
  registered output so it is observed one RX edge after the
  `(phase==15,slip==7)` detection (slip wrapped 7→0); the contract is
  therefore register-stage-independent: *both maxima must already have
  been reached by the time the fault is first visible*.

### Run

```sh
cd cocotb/phy_align
rm -rf sim_build ../wlink_pair/sim_build      # cocotb does NOT auto-rebuild on RTL edits
make MODULE=test_calibrator_skew_window SKID_BITS=3 STUCK_LANES_MASK=16
```

Env: `CMSDK_DIR`, `CMSDK_FPGA_SRAM_V`, `SOCLABS_TIDELINK_DIR` /
`TIDELINK_HOME` set to the worktree root. Traversal runs to ~1.31 ms sim
time (full 128×32 link-clock window) ≈ 21 s wall.

### Negative control (demonstrated, RTL restored)

Shrinking the phase iterator in the RTL — `sweep_phase == 4'd15` →
`4'd7` (window 16→8 phases, a silent 2× shrink) — then
`rm -rf cocotb/*/sim_build` and rerun: the traversal test **FAILS** with
the contract message naming the dependency, while the structural test
still passes (iterator *width* unchanged), proving the dynamic test
catches what structural checks alone cannot:

```
TRAVERSAL: max_slip_seen=7 max_phase_seen=7 fault_seen=True (slip,phase)@fault=(7,7) ...
AssertionError: calibrator never drove sweep_phase to 15 (max seen=7). The PHASE
search window has been SHRUNK below the documented 16 values (phase ∈ [0..15]).
Sub-bit routing skew that lands beyond the truncated phase range would no longer
be rescued — silently breaking the FPGA timing-determinism plan.
** test_calibrator_skew_window_structural   PASS
** test_calibrator_skew_window_traversal    FAIL
```

Restoring the RTL (`4'd7` → `4'd15`) and rebuilding → both tests **PASS**:

```
TRAVERSAL: max_slip_seen=7 max_phase_seen=15 fault_seen=True (slip,phase)@fault=(7,15)
  cal_done_s=1 state_s=4 ... lane_fault_s=0x10
CONTRACT OK: calibrator traversed the FULL documented window — slip 0..7 (8 values)
  × phase 0..15 (16 values) = 128 points ...
** TESTS=2 PASS=2 FAIL=0 SKIP=0
```

### Assumptions / limitations

* The full window only gets traversed if some lane never locks; the test
  uses the existing `STUCK_LANES_MASK` TB knob (lane 4) to guarantee that.
  Without it the calibrator would lock all lanes during the phase=0 inner
  pass and never reach the window edges — that is exactly why the existing
  suites do not pin this contract.
* Honest scope: the test certifies the calibrator is **capable** of
  emitting the full slip=7 / phase=15 range and searches the whole 128-
  point space before giving up. It does not (and physically cannot in a
  zero-jitter RTL sim — see `test_phase_sweep.py` header) prove a specific
  skew is *rescued* by a specific (slip,phase); that is a hardware
  property. The contract guarded here is the **window size/shape**, which
  is the determinism dependency.
* If the window dimensions are ever changed deliberately, update the
  RTL, the `EXPECT_*` constants at the top of
  `test_calibrator_skew_window.py`, this section, and
  `/tmp/timing_determinism_investigation_brief.md` together — never
  silently.

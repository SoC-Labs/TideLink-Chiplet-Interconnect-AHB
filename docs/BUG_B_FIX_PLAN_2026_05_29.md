# Bug B Fix Plan — 2026-05-29

## Summary

**Bug B**: Master HW_SYNC FSM writes `HW_SYNC_CTRL = 0x05` (force_en | enable)
and wedges forever in `HW_SYNC_ARMED`. No SYNC short packet ever appears
on `ptp_sp_tx_valid`; slave `ptp_rx_valid_r` stays 0.

This document explains the root cause, picks one of three remediation
options, lists the proposed patch and cocotb test, and flags a related
silicon-level issue that this RTL patch does **not** fix on its own.

---

## Root cause

Two coupled defects produce the wedge:

### (1) RTL — `phc_time_reached` ignores `hw_sync_force_en_r`

[`src/rtl/tidelink_ptp.sv:399-401`](../src/rtl/tidelink_ptp.sv#L399):

```systemverilog
wire phc_time_reached = (phc_seconds > target_seconds_r) ||
                        (phc_seconds == target_seconds_r &&
                         phc_nanoseconds >= target_ns_r);
```

In the IDLE→ARMED transition at lines 494-500, `target_ns_r` is loaded
to `phc_nanoseconds + hw_sync_interval_r`. With:

* `hw_sync_interval_r = DEFAULT_INTERVAL = 30'd999_999_999` (line 359 reset)
* `phc_nanoseconds = 30'h0` (BD tie-off, see (2))

`target_ns_r` is loaded to `999_999_999`. `phc_nanoseconds (= 0) >=
target_ns_r (= 999_999_999)` is permanently false. ARMED → FIRE never
fires.

The HW_SYNC FSM already has two other gates that explicitly honour
`hw_sync_force_en_r`:

* **IDLE → ARMED** via `hw_sync_gate` (line 372)
* **TX_WAIT_IDLE → TX_SEND** via the `(tx_router_idle || hw_sync_force_en_r)`
  bypass (line 260)

The third gate (`phc_time_reached`) is the only one that **doesn't**
honour force_en, even though every other gate does. This is the bug.

### (2) BD — `phc_nanoseconds` tied to zero

[`fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl:43-44,480-481`](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl)
hard-ties:

```
phc_nanoseconds = 30'h0
phc_seconds     = 48'h0
```

The pair sim [`cocotb/tidelink_top_pair/tb_top.sv:315-317`](../cocotb/tidelink_top_pair/tb_top.sv#L315)
and `:526-528` do the same.

So even with a sensible HW_SYNC_INTERVAL (say, 100 ns), PHC time never
advances and `phc_time_reached` never trips by the time path. The RTL
patch makes `force_en` mode work today; (2) needs a BD-level fix for
the *non*-force_en time-scheduled path to ever work on silicon.

---

## Force-experiment / sim evidence

From `cocotb/tidelink_top_pair/test_master_ptp_tx_router.py` sample data
the user provided:

* `hw_sync_state_r` wedges in ARMED 199/200 cycles after the CTRL write.
* `tx_router_idle = 176/200` cycles — **not** the block (so this is not
  the link-idle CDC hypothesis).
* `ptp_sp_tx_valid` stays 0 throughout.

This is consistent only with the ARMED → FIRE gate being permanently
false — i.e. `phc_time_reached = 0` — which is exactly the case if
`force_en` is ignored at that gate.

---

## Recommendation: Option A

Three options were considered:

| Opt | What | Pros | Cons |
|-----|------|------|------|
| **A** | `phc_time_reached` honours `force_en` | Matches the documented force_en semantic ("fire-now / bypass gates"). Same idiom as lines 260 and 372. Zero impact on the existing eight `hw_sync_*` unit tests (all leave force_en=0). | Doesn't fix the silicon time-scheduled path. |
| **B** | Default `hw_sync_interval_r` to a small value at reset (e.g. 32 or 0) | Makes the natural enable path fire immediately at POR. | Changes behaviour for SW that depends on the documented ~1-second reset default. The `phc_nanoseconds=0` tie-off still means time-of-day scheduling never works — only the *first* fire is unblocked. Half-fix. |
| **C** | Wire a free-running ns counter into `phc_nanoseconds_i` at the BD level | Genuinely fixes silicon time-scheduled HW sync. RTL untouched. | Out of tonight's scope (BD edit + xlconstant→xlconcat→counter wiring + per-target TCL change). Also doesn't help sim until tb_top is updated similarly. |

### Why A wins

1. **It matches existing semantics.** Comments at lines 149-151 and
   252-259 already say `force_en` is the "bypass everything" knob.
   Lines 260 and 372 already implement this for the other two gates.
   The bug is that line 399 silently forgot. The fix is a one-line
   restoration of that policy.
2. **Zero test regression risk.** No existing test asserts that
   `force_en = 1` *requires* `phc_time_reached`. The eight
   `hw_sync_*` unit tests in `cocotb/tidelink_ptp/test_tidelink_ptp.py`
   all leave `force_en = 0`, so they still exercise the time-gated path.
3. **It is the smallest possible RTL change.** Two-line diff (one
   blank/comment + one logical OR term).
4. **It immediately unblocks the user's SW recipe** (`HW_SYNC_CTRL = 0x05`)
   on both sim and silicon without touching the BD.

Option C is the correct **long-term** silicon fix and should be tracked
separately — see "BD-level follow-up" below.

---

## Proposed patch

Saved as [`docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`](BUG_B_PROPOSED_FIX_2026_05_29.patch).

Core change:

```diff
-    // PHC time comparison: current time >= target time
-    wire phc_time_reached = (phc_seconds > target_seconds_r) ||
-                            (phc_seconds == target_seconds_r &&
-                             phc_nanoseconds >= target_ns_r);
+    // PHC time comparison: current time >= target time.
+    //
+    // hw_sync_force_en_r forces an immediate fire, mirroring the
+    // bypass behaviour of the TX_WAIT_IDLE→TX_SEND gate (line 260)
+    // and the IDLE→ARMED PHC-lock gate (line 372).
+    wire phc_time_reached = hw_sync_force_en_r ||
+                            (phc_seconds > target_seconds_r) ||
+                            (phc_seconds == target_seconds_r &&
+                             phc_nanoseconds >= target_ns_r);
```

Single-file, single-hunk, ~7 lines added (including the comment).

---

## New test

[`cocotb/tidelink_top_pair/test_bugb_fix_force_en.py`](../cocotb/tidelink_top_pair/test_bugb_fix_force_en.py).
Two tests:

1. **`test_force_en_bypasses_phc_time_reached`** — after full pair
   bringup + master `HW_SYNC_CTRL = 0x05`, master `ptp_sp_tx_valid`
   must pulse high within 500 cy. Pre-patch this fails (FSM wedges in
   ARMED). Post-patch it passes.
2. **`test_force_en_slave_receives_sync`** — end-to-end: after 5000 cy
   settle, slave `ptp_rx_valid_r` must be 1 with `ptp_rx_msg_type_r = 0`
   (SYNC).

**Not run** per session constraint (sim infrastructure busy from
earlier runs; user will run tomorrow).

---

## BD-level follow-up (Option C, separate workstream)

This RTL patch makes `force_en = 1` SW recipes work. The **non**-force_en
time-scheduled path remains broken on silicon and in pair-sim because
`phc_nanoseconds` is tied to `30'h0` in:

* [`fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl:43,480`](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl)
* [`cocotb/tidelink_top_pair/tb_top.sv:315,526`](../cocotb/tidelink_top_pair/tb_top.sv#L315)

The proper fix is to instance a small free-running ns counter (e.g.
30-bit counter incremented every `hclk`, wrapping at 999_999_999) and
wire its output into `phc_nanoseconds`. The `ptp-hardware-clock-ahb`
subsystem is the right home for this (per the TCL header note Q4) but
a stop-gap counter in the BD wrapper is fine for the time-scheduled
sync path bring-up.

Tracked items for that workstream:

* Add free-running counter sub-block to BD for each of the four target
  TCLs (`pynq-z2-pair-flip-ila`, `pynq-z2-pair`, `pynq-z2-loopback`,
  `pynq-z2-loopback-ext`).
* Add the same counter (or a `cocotb` task that increments
  `dut.u_master.phc_nanoseconds` every clock) in the pair tb_top so the
  existing `cocotb/tidelink_ptp/test_tidelink_ptp.py` time-gated tests
  also run at the pair level.

---

## Risks

* **PTP servo loop interaction.** The servo (if instantiated) consumes
  `sync_tx_done` / `dreq_tx_done` / `sync_rx_done` / `dreq_rx_done`
  pulses. These are produced one cycle after `ptp_sp_tx_valid` /
  `rx_accept` and are not time-gated themselves. A fire-now `force_en`
  produces the same pulse shapes the servo already expects — just
  sooner and back-to-back rather than spaced at `hw_sync_interval_r`.
  No functional regression expected, but if a servo unit test asserts
  a minimum spacing between sync events, it should be reviewed.
* **Backward compatibility.** No SW currently in the tree relies on
  `force_en = 1 AND time-gated firing`. The user's debug recipe writes
  `HW_SYNC_CTRL = 0x05` with the explicit expectation it fires now.
  The HW deploy script `sw_coord_autocal_region8.sh` and the eight
  `hw_sync_*` unit tests all either use `force_en = 0` or expect
  `force_en = 1` to fire immediately.
* **Sequence-number stepping rate.** With `force_en = 1` the FSM
  will repeatedly re-arm and re-fire as fast as TX_IDLE returns (about
  every 3-4 cycles in the pair sim). For a long-running deploy this
  could saturate the link and starve other traffic. Mitigation: SW
  clears `force_en` after the first observed `ptp_rx_valid_r` on the
  slave, then re-enables with `force_en = 0` once the BD-level PHC
  counter (Option C) is in place. Document this in the bring-up
  runbook.

---

## Validation plan (for tomorrow)

1. Apply the patch:
   `git apply docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`
2. Run the new pair test:
   `make -C cocotb/tidelink_top_pair MODULE=test_bugb_fix_force_en`
3. Re-run the existing PTP unit regression to confirm no regressions:
   `make -C cocotb/tidelink_ptp MODULE=test_tidelink_ptp`
4. If both pass, build for `pynq-z2-pair-flip-ila` and re-deploy. Look
   for `ptp_rx_valid_r` going high on the slave ILA within the first
   few microseconds after `HW_SYNC_CTRL = 0x05`.

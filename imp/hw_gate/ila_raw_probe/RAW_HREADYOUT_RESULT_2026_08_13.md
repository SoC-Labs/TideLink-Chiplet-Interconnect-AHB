# RESULT: `xhb_sub_hreadyout_raw` at the TL-042 wedge — die_a ILA, 2026-08-13

Answers the single pre-registered question in
`imp/hw_gate/PREREG_RAW_HREADYOUT_PROBE_2026_08_13.md`. Read that file first; the
predictions below are reported against it verbatim.

**HEADLINE: `xhb_sub_hreadyout_raw == 0` at the wedge. P1 CONFIRMED, P2 REFUTED.
TL-042 v2 is NECESSARY BUT NOT SUFFICIENT.**

---

## 1. VACUITY-GUARD VERDICT (read before any probe value)

Three captures were taken. The guard disposes of them as follows.

| run | window | `sub_stall_ctr_r` ramp | `wr_hold_r` | known-live cross-check | verdict |
|---|---|---|---|---|---|
| 1 | forced only | ABSENT (0, 1 distinct value) | 0 on all 4096 | fcsm=4, cr_seen=1 | **VOID** |
| 2 | forced only | ABSENT (0, 1 distinct value) | 0 on all 4096 | fcsm=4, cr_seen=1 | **VOID** |
| 3 | **triggered** (`wr_hold_r`==1) | PRESENT (0→3582, 3583 distinct) | 1 at samples 512–513 | fcsm=4, cr_seen=1 | **VALID (wedge onset)** |
| 3 | **forced** (~75 s later) | PRESENT (42398→46493, 4096 distinct) | **1 on all 4096** | fcsm=4, cr_seen=1 | **VALID (held wedge)** |

**Runs 1 and 2 are VOID and report nothing.** They are recorded here only because
they are instructive: both produced an all-idle window in which
`xhb_sub_hreadyout_raw` read **1** — the convenient P2 value — and had the guard
not been applied first, this campaign would have shipped "P2, v2 is a complete
fix" off a window that was never at the wedge. That is precisely the failure the
pre-registration was written to prevent, and it very nearly happened.

**Run 3 is VALID.** Its forced window satisfies every clause of the guard in the
strictest possible reading: `wr_hold_r` is 1 on all 4096 samples, the stall
counter ramps monotonically across 4096 distinct values, and both known-live
signals read their healthy values on every sample. Its triggered window
independently captures the *onset* of the same wedge.

Corroborating, non-probe evidence that run 3 is genuinely at the wedge:
- die_a was unresponsive to an obs read at capture time (`0x2010` timed out);
- die_b's local memory CHANGED across the inject in this run
  (`b0008000 b0008001 b0008002 b0008003` landed at idx 0–3, then the stream stops)
  — the write stream started and then died mid-flight. In runs 1 and 2 nothing
  landed at all, which is further reason to treat those two as not-at-the-wedge.

### The probe is not stuck

The single most important check on a "reads 0" result is whether the probe can
read anything else. It can, in this same build and this same run:
`xhb_sub_hreadyout_raw` reads **1** for 513 samples and **0** for 3583 within the
one triggered window, with exactly one clean transition; and it read 1 on all
4096 samples of the two VOID idle windows. It is also **exactly complementary to
`sub_stall_busy` on all 4096 samples (0 violations)**, which is the silicon
confirming `tidelink_top.sv:1543` (`sub_stall_busy = !xhb_sub_hreadyout_raw`)
directly. A stuck-at-0 probe is excluded.

---

## 2. THE ANSWER

**Frozen value of `xhb_sub_hreadyout_raw` at the held wedge: `0`, on all 4096
samples of the valid forced window.**

At the wedge onset (triggered window) it falls 1→0 at sample 513 and never
returns to 1 for the remaining 3582 samples.

### Full per-probe statistics, both valid windows (hex-parsed)

Vivado writes multi-bit probes as unprefixed hex; the CSV's own row 2 is a
literal `Radix - UNSIGNED,UNSIGNED,UNSIGNED,HEX,HEX,…` line confirming it. All
values below are parsed hex-first, hex-only.

**Run 3, TRIGGERED window (wedge onset), 4096 samples:**

| probe | min | max | ones | distinct |
|---|---|---|---|---|
| `xhb_sub_hreadyout_raw` | 0 | 1 | 513 | 2 |
| `sub_stall_busy` | 0 | 1 | 3583 | 2 |
| `sub_stall_ctr_r` | 0 | 3582 | 3583 | 3583 |
| `wr_hold_r` | 0 | 1 | 2 | 2 |
| `sub_rd_os_r` | 0 | 0 | 0 | 1 |
| `synth_b_pending` | 0 | 0 | 0 | 1 |
| `sub_err1_r` | 0 | 0 | 0 | 1 |
| `sub_err2_r` | 0 | 0 | 0 | 1 |
| `ext_is_nonseq` | 0 | 1 | 1 | 2 |
| `pipe_valid_r` | 0 | 1 | 1 | 2 |
| `rd_pipe_r` | 0 | 0 | 0 | 1 |
| `sub_wr_os_ctr` | 0 | 1 | 3583 | 2 |
| `dbg_fcsm_state` | 4 | 4 | 4096 | 1 |
| `dbg_cr_seen` | 1 | 1 | 4096 | 1 |

**Run 3, FORCED window (held wedge, ~75 s after the inject), 4096 samples:**

| probe | min | max | ones | distinct |
|---|---|---|---|---|
| `xhb_sub_hreadyout_raw` | 0 | 0 | 0 | 1 |
| `sub_stall_busy` | 1 | 1 | 4096 | 1 |
| `sub_stall_ctr_r` | 42398 | 46493 | 4096 | 4096 |
| `wr_hold_r` | 1 | 1 | 4096 | 1 |
| `sub_rd_os_r` | 0 | 0 | 0 | 1 |
| `synth_b_pending` | 0 | 0 | 0 | 1 |
| `sub_err1_r` | 0 | 0 | 0 | 1 |
| `sub_err2_r` | 0 | 0 | 0 | 1 |
| `ext_is_nonseq` | 0 | 0 | 0 | 1 |
| `pipe_valid_r` | 0 | 0 | 0 | 1 |
| `rd_pipe_r` | 0 | 0 | 0 | 1 |
| `sub_wr_os_ctr` | 0 | 0 | 0 | 1 |
| `dbg_fcsm_state` | 4 | 4 | 4096 | 1 |
| `dbg_cr_seen` | 1 | 1 | 4096 | 1 |

### Cycle-accurate onset (triggered window; trigger at sample 512)

```
idx   wr_hold_r  raw_hreadyout  stall_busy  stall_ctr  wr_os  nonseq  pipe_v
505      0            1              0           0        0      0       0     <- idle, bus READY
511      0            1              0           0        0      1       0     <- NONSEQ arrives
512      1            1              0           1        0      0       1     <- wr_hold_r asserts (TRIGGER)
513      1            0              1           0        1      0       0     <- raw hreadyout FALLS
514      0            0              1           1        1      0       0     <- wr_hold_r ALREADY CLEARED
600      0            0              1          87        1      0       0
1000     0            0              1         487        1      0       0
2000     0            0              1        1487        1      0       0
3000     0            0              1        2487        1      0       0
4095     0            0              1        3582        1      0       0     <- still stalled, still counting
```

`sub_stall_ctr_r` has exactly one non-monotonic step in the whole window: `1 → 0`
at sample 513. That is a genuine counter reset at the changeover from
`sub_stall_fill` to `sub_stall_busy` as the stall source, not a parse artefact —
the values `1` and `0` are identical in any base. Every other step is `+1`
(3583 of them). **This is stated explicitly because a base-10-first parse of hex
fabricated 100 fake counter drops earlier today; the single drop reported here
is real and is one drop, not a sawtooth.**

---

## 3. VERDICT AGAINST THE PRE-REGISTERED PREDICTIONS

### P1 (expected, from the derivation) — **CONFIRMED**

> `xhb_sub_hreadyout_raw == 0` at the wedge.

Confirmed twice over in the same valid run: 0 on all 4096 samples of the held
wedge, and 0 for 3582 consecutive samples after the onset.

The derivation in the pre-registration is confirmed **term by term** on silicon,
not merely in its conclusion. At the held wedge: `ext_is_nonseq = 0` (so
`sub_stall_fill = 0`), `sub_err1_r = sub_err2_r = 0`, `sub_stall_busy = 1`, and
the counter ramps. With `sub_stall_fill = 0` and both error terms 0, the only
surviving term that can keep `sub_ext_stalled` asserted is `sub_stall_busy`, and
`sub_stall_busy = !xhb_sub_hreadyout_raw` holds sample-for-sample with zero
violations. Every link in the chain is now measured rather than inferred.

**The consequence is stronger than the pre-registration anticipated.** The
onset window shows `wr_hold_r` asserting for **exactly 2 cycles** (samples
512–513) and then clearing, while `xhb_sub_hreadyout_raw` stays 0 and the stall
persists for the remaining **3582 cycles with the wrapper hold already
released**. Releasing `wr_hold_r` is therefore not merely insufficient to restore
the bus — for 3582 consecutive measured cycles the wedge persists in exactly the
state that releasing `wr_hold_r` would produce. XHB500 is stalling
independently of the wrapper hold, and the silicon shows it doing so.

Accordingly:
- **TL-042 v2 is NECESSARY BUT NOT SUFFICIENT.**
- A v2 bench run **will still show a wedge**. Per the pre-registration, that
  outcome must NOT be read as "another failed fix" — it is the predicted result,
  registered in advance of this measurement.
- The remaining defect is upstream in the bridge. The next target is the
  `ctr != 0` gate on `sub_wr_stuck_fire`, itself blocked behind converting
  `wr_hold_clr`'s `synth_b_pending` term from LEVEL to PULSE.

One observation worth carrying forward, reported as raw fact without a mechanism
claim: at the **held** wedge `sub_wr_os_ctr = 0` on all 4096 samples, while at the
**onset** it is 1. The bus is held stalled with no outstanding write counted.

### P2 (would overturn the derivation) — **REFUTED**

> `xhb_sub_hreadyout_raw == 1` at the wedge → v2 is a COMPLETE fix.

Not observed in any valid window. It *was* observed in both VOID windows, which
is exactly why the pre-registration flagged P2 as the outcome to be most
sceptical about. The scepticism was warranted: the convenient answer is what an
idle, not-at-the-wedge capture produces. **v2 is not a complete fix.**

### P3 (bonus, N1 evidence) — **NO COINCIDENCE OBSERVED**

`synth_b_pending`, `sub_err1_r` and `sub_rd_os_r` were probed together. Across
both valid windows (8192 samples), the number of samples showing
`synth_b_pending = 1` while `sub_err1_r` was suppressed and `sub_rd_os_r` cleared
is **0**. `synth_b_pending` never asserts at all: ones = 0 in every window
captured tonight, valid or void.

**ABSENCE OF THAT COINCIDENCE IS NOT EVIDENCE AGAINST N1.** The errinject
stimulus used here may simply not produce a coincident stuck read — `sub_rd_os_r`
and `rd_pipe_r` are 0 across every sample of every window, i.e. there was no read
outstanding at any point in these captures, so the coincidence had no opportunity
to occur. N1 remains CODE-PATH READING ONLY, neither supported nor weakened by
this run.

---

## 4. HOW THE CAPTURE WAS OBTAINED (and two traps that bit)

Harness: `imp/hw_gate/ila_raw_probe/ila_run_raw_hreadyout_v3.sh` +
`ila_capture_raw_hreadyout_v3.tcl`, adapted from `imp/hw_gate/ila_run_tl035.sh`
and `ila_capture_tl035.tcl` (originals untouched), with the POR → PL → AFI →
concurrent-bringup sequence from `imp/hw_gate/tl035_ab.sh`.

- **Probe names.** The tl035 scripts glob `dbg_*`-prefixed probes
  (`dbg_ahb_sub_hreadyout`, `dbg_wr_hold_r`, …) which **do not exist** in this
  build; its 34 probes carry their RTL net names under
  `tidelink_design_i/nanosoc_eth_chiplet_0/inst/u_chiplet/u_tidelink/`. All 14
  required probes were confirmed present at arm time before any stimulus.
  Note the glob hazard: `*hreadyout*` matches **both** `dbg_tx_hreadyout` and
  `xhb_sub_hreadyout_raw`, so every glob is anchored on a unique substring, and
  the CSV decoder matches on the exact leaf name, not a substring.
- **TRAP THAT BIT (1): force-capture-only discards the answer.**
  `run_hw_ila -trigger_now` **re-arms** the core, so a window the trigger had
  already captured is destroyed unread. Runs 1 and 2 inherited this and returned
  an idle post-wedge window — VOID, and reading the convenient P2 value. v3
  uploads the triggered window **before** any re-arm, and still force-captures
  afterwards so a held wedge is read faithfully. Both mechanisms delivered.
- **TRAP THAT BIT (2): a status-shaped false positive.** Run 2 tried to detect a
  trigger with `wait_on_hw_ila -timeout 1`, which **returned success on a core
  that had not triggered**; the subsequent upload logged
  `WARNING: [Labtools 27-155/27-157] hw_ila stopped. No data to upload.` and
  wrote a 2-line header-only CSV — and the harness printed "TRIGGER FIRED". v3
  decides "did it fire?" from **CSV content** (file size / sample count), never
  from core status, and issues no JTAG operation at all between arming and the
  capture, so the trigger gets the whole stimulus window.
- `get_property CORE_STATUS` remains guarded and is only read after the CSV is
  safely written (an unguarded read aborts Vivado, Labtoolstcl 44-155).

Rig and provenance, verified in-run:
- die_a `10.22.24.159`: ILA build, deployed md5 **`8045683b6f8cf3d16f7a332c41045e56`**
  verified on the board against the expected value before proceeding.
- die_b `10.22.24.153`: **not reflashed.** Its already-staged
  `td/tl_arm_baseline.bin` (md5 **`13573e46c3b27bb6b03b41b2ce730aa8`**, verified)
  was merely re-loaded into the PL, which a JTAG POR clears.
- `.bin` newer than `.ltx` (21:58:23Z vs 21:31:24Z) — probe file and bitstream
  are from the same build.
- JTAG POR both → PL load both → `kr260_afi.sh fix` with `KR260_AFI_NO_CANARY=1`
  on both (AFI: PASS, both ports 32-bit) → concurrent pair bring-up →
  `fcsm=4` on both dies (`SWI_LANE_STAT 0x05890000`) → 8/8 byte-exact eye canary.
  The first eye roll of run 3 was rejected (`die_a 0x27890000`) and re-rolled.
- Recovery: die_a JTAG-POR'd after the capture and confirmed back up. No bench
  trip; no `reboot`.

## 5. ARTEFACTS

- `imp/hw_gate/ila_raw_probe/run3/ila_capture_trig.csv` — triggered window (onset)
- `imp/hw_gate/ila_raw_probe/run3/ila_capture.csv` — forced window (held wedge)
- `imp/hw_gate/ila_raw_probe/run3/{run.log,summary.txt,analysis_trig.txt,analysis_forced.txt,timeline.txt}`
- `imp/hw_gate/ila_raw_probe/run/`, `run2/` — the two VOID runs, kept as the
  record of what a not-at-the-wedge window looks like
- `imp/hw_gate/ila_raw_probe/analyse_raw_hreadyout.py` — hex-first decoder with
  the vacuity guard printed before any probe value

Note on the decoder: its guard implements "`wr_hold_r` reads 1" as *held across
all samples*, which is stricter than the pre-registered wording. On that strict
reading the triggered (onset) window prints VOID because `wr_hold_r` is a 2-cycle
pulse there. The **forced** window of run 3 passes even that strict reading —
`wr_hold_r` = 1 on all 4096 samples — so the result does not depend on which
reading is taken. Both windows give the same answer for
`xhb_sub_hreadyout_raw`: **0**.

## 6. LEASES

`kr260_01` and `kr260_02` were each acquired alone (never chained with a board
op) and **both released at the end of this campaign; `lease show` confirms
`not leased` for both.**

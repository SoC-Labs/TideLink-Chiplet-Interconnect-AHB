# PRE-REGISTERED: is `xhb_sub_hreadyout_raw` 0 at the TL-042 wedge?

Written BEFORE the ILA build finished and BEFORE any capture. This is the single
measurement that decides whether the TL-042 v2 fix is COMPLETE or merely
NECESSARY-BUT-NOT-SUFFICIENT.

## Why this probe exists

The round-2 ILA never probed `xhb_sub_hreadyout_raw` — the mux FALLTHROUGH. From
it I concluded "rank-5 `wr_hold_r` is the SOLE term driving `ahb_sub_hreadyout`
low", and drew the implication that clearing `wr_hold_r` restores the bus.

That implication is now in doubt by DERIVATION (verified against HEAD RTL):
- `sub_stall_ctr_r` increments ONLY while `sub_ext_stalled` (guard `:1634`)
- `sub_ext_stalled = (sub_stall_fill || sub_stall_busy) && !err1 && !err2` (`:1549`)
- `sub_stall_fill = ext_is_nonseq && !pipe_valid_r` (`:1542`); the capture measured
  `ext_is_nonseq = 0`, so `sub_stall_fill = 0`
- `err1 = err2 = 0` measured
- `sub_stall_busy = !xhb_sub_hreadyout_raw` (`:1543`)
- The capture shows a FULL 0 -> 65536 ramp

=> for the ramp to exist, `sub_stall_busy` must be 1, i.e.
`xhb_sub_hreadyout_raw == 0`. This probe tests that derivation DIRECTLY rather
than by inference.

## PREDICTIONS

**P1 (expected, from the derivation).** `xhb_sub_hreadyout_raw == 0` at the wedge.
- MEANS: XHB500 is stalled INDEPENDENTLY of the wrapper hold. Clearing `wr_hold_r`
  cannot raise `ahb_sub_hreadyout`. **TL-042 v2 is NECESSARY BUT NOT SUFFICIENT**,
  and a v2 bench run would still show a wedge — which must NOT then be misread as
  "another failed fix". The remaining defect is upstream in the bridge, and the
  `ctr != 0` gate on `sub_wr_stuck_fire` becomes the next target, itself blocked
  behind converting `wr_hold_clr`'s `synth_b_pending` term from LEVEL to PULSE.

**P2 (would overturn the derivation).** `xhb_sub_hreadyout_raw == 1` at the wedge.
- MEANS: the derivation above is WRONG somewhere, the mux-priority reading stands,
  and **v2 is a COMPLETE fix** — worth an immediate bench A/B.
- This is the outcome that would make tonight's fix-v2 work directly shippable, so
  it is the one to be most sceptical about. If it appears, re-check that the
  capture is genuinely at the wedge (see vacuity guard) before believing it.

**P3 (bonus, N1 evidence).** `sub_rd_os_r`, `sub_err1_r` and `synth_b_pending` are
probed together. If a capture ever shows `synth_b_pending=1` while `sub_err1_r`
was suppressed and `sub_rd_os_r` cleared, that is direct silicon evidence for the
audit's N1 unrecoverable-hang path — currently CODE-PATH READING ONLY. Absence of
that coincidence is NOT evidence against N1; the errinject stimulus may simply not
produce a coincident stuck read.

## VACUITY GUARD — check this FIRST, before reading any probe

An all-zeros capture is also what a DEAD capture looks like. Before interpreting
`xhb_sub_hreadyout_raw`, confirm the capture is live and genuinely at the wedge:
- `sub_stall_ctr_r` must show a real ramp with many distinct values (round-2 saw a
  full 0..65536 span). A frozen counter means the capture is not at the wedge.
- `wr_hold_r` must read 1 (the wedge state).
- Cross-check at least one known-live signal, as the round-1 capture did with
  `dbg_fcsm_state=4` / `dbg_cr_seen=1`.
If those fail, the run is VOID and reports nothing — record it as such, exactly as
`TL042_RUN1_VOID_2026_08_13.md` did.

## Decode trap (has already caused one fabricated result)

Vivado ILA CSVs encode multi-bit probes as UNPREFIXED QUOTED HEX (`'01600'`).
Parsing base-10-first turns `0x1600` into 1600 and fabricated 100 fake counter
drops on 2026-08-13, on which a complete mechanism argument was briefly built.
**PARSE HEX-FIRST.**

## Build provenance

RTL = HEAD `b75d391b…` + 11 `mark_debug` attributes ONLY (no logic change);
verified still elaborating and passing
`test_write_hold_hreadyout_waits_for_w_beat`. `FPGA_INSERT_DEBUG_CORE=1`,
`TIDELINK_PHY_V2=1`. NOTE: `insert_debug_core.tcl` re-bakes ~96 `DONT_TOUCH` lines
into the target `drc.xdc` on every ILA build — strip them afterwards, and strip
the `mark_debug` attributes before any shipping build.

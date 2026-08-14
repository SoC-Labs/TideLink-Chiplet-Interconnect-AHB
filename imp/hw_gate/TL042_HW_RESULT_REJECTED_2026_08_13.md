# TL-042 candidate fix — REJECTED ON HARDWARE (2026-08-13)

Predictions were pre-registered BEFORE the build finished, in
`PREREG_TL042_HW_2026_08_13.md`. This reports against them verbatim.

## VERDICT: NOT VALIDATED, and CONFOUNDED. Not committed. RTL reverted to HEAD.

The bug (TL-042) is REAL and remains OPEN. The candidate fix is NOT ADOPTED.

⚠ **VERDICT DOWNGRADED 2026-08-13, same evening.** This file originally read "the
fix is HARMFUL". That overshoots the evidence and is retracted. Not committing was
correct; asserting harm was not. Two confounds, both found by re-reading the logs
already in this directory:

1. **die_b's own state differed BEFORE any peer write.** At step 5 — before a
   single byte crosses — die_b reported `SWI_LANE_STATUS=0x27890000` in BOTH
   failing (fix-arm) runs and `0x05890000` in the passing baseline run. die_b's
   bitstream was BYTE-IDENTICAL across all three. A pre-write difference on the
   unchanged die cannot be a consequence of a die_a `wr_hold_r` timeout, so the
   arms were not exchangeable and "die_a's RTL is the only variable" is FALSE as
   stated. (Both status words decode to the same fcsm=4/cal=1/cr/crack fields —
   the difference is in bits [31:24], which this decoder does not print.)
2. **The baseline arm is not reliably 16/16 either.** The 0/16 all-zeros outcome
   is on record for baseline and TL-035 arms in earlier campaigns, and the 08-09
   land-rate was ~1/6. A single baseline pass against two fix failures is far too
   thin to separate a real regression from that variance.

HONEST STATEMENT OF THE RESULT: **the candidate was not validated (n=2 fix vs n=1
baseline, confounded by a pre-existing die_b state difference).** It must not be
committed on this evidence — but neither is it demonstrated harmful. The
mechanism analysis below stands on its own as a REASON FOR CONCERN, independent of
these runs, and is why the approach should be redesigned rather than retried.

## The measurement

Identical protocol per arm (POR -> fpgautil -> mandatory AFI fix -> concurrent
bring-up -> status -> delivery -> errinject). die_b's image was BYTE-IDENTICAL in
every run (`13573e46c3b27bb6b03b41b2ce730aa8`), so die_a's bitstream is the only
variable. Every run below had a HEALTHY bring-up: fcsm=4 both dies,
crack_seen=1 both, both RE-ANCHORED.

| arm | die_a md5 | n | delivery | Region F gate | die_a post |
|-----|-----------|---|----------|---------------|------------|
| baseline | `9eadebb8...` | 1 | **16/16 byte-exact** | **PASS** (`data_exact=True`) | UP |
| TL-042 fix | `0366c344...` | **2** | **0/16** (`got 0x00000000`) | **FAIL** — "mis-delivery/bit-error on the data plane" | DOWN |

Evidence: `control_baseline/`, `retry2/`, `rep_tl042_r3/`.

## Against the pre-registered predictions

- **P1 (no wedge on errinject): NOT CLEANLY TESTED.** Plain delivery already
  failed before any injection, so the errinject result tests an already-broken
  data plane. `die_a_post=DOWN` is additionally confounded: the harness stages a
  JTAG POR on kr260_01 at step 6b when the Region F gate fails.
- **P2 (clean path stays 128/128): REFUTED.** Its stated refutation condition was
  "any drop in the clean-path score", and the drop is 16/16 -> 0/16 at n=2.
- **P3 (no spurious B): NOT SEPARATELY OBSERVABLE.** The Region F sampler
  self-reports DEAD under load (TL-039/TL-040), so its "ALL CLEAN" words carry no
  information either way.

## Root cause of the REGRESSION (mechanism, not speculation)

From `tidelink_top.sv` **as committed at HEAD `d317c98` (file md5 `b75d391b…`, the
reverted state)** — cite these, not the patched-file numbers:

    :1826  wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast) | synth_b_pending;
    :1870  else if (synth_b_pending & s_axi_bready & (sub_wr_os_ctr <= 3'd1)) synth_b_pending <= 1'b0;

(An earlier revision of this document cited `:1838`/`:1939`. Those were line
numbers in the CANDIDATE-PATCHED file, which no longer exists in the tree — the
patch adds ~77 lines above them. Verified against `git show HEAD:` on 2026-08-13.)

`synth_b_pending` is a term of `wr_hold_clr`, so **asserting it DISABLES the
TL-002 peer-write hold for as long as it is high.** The candidate reused
`synth_b_pending` as its hold-release lever. Therefore every time the new arm
fires, the data-phase protection that stops the peer-write payload drop is
defeated — which is precisely the `0x00000000` seen on die_b.

Compounding it: the companion `s_axi_bvalid` suppression (added to avoid
presenting a B for a write XHB500 never issued) removes the very handshake that
`:1939` needs to CLEAR `synth_b_pending`, so it can latch high permanently — at
which point `wr_hold_clr` is permanently asserted and the hold can never engage.

The arming condition is also unsound on its own terms: `wr_hold_stuck =
wr_hold_r && (sub_wr_os_ctr == 0)` can be TRUE during a perfectly normal
bufferable/EWR write, because an early B can return the counter to 0 while
`wr_hold_r` is still validly waiting for its W beat.

## Why sim did not catch it (the process failure worth keeping)

The candidate passed a non-vacuity A/B (pristine FAILs "wr_hold_r STILL HIGH
after 90k hclk"; fixed PASSes, escaping at cycle 65518), plus
`sim_gate_axi_datanode_recovery` and `_gaps`. It still shipped a data-plane
regression, because the test asserted only that the hold ESCAPES. It never
asserted:
1. that `synth_b_pending` subsequently CLEARS, and
2. that a NORMAL write still lands after the arm has fired.

The evidence was actually on screen and went unexamined: the passing test's own
log line reads `synth_b_pending=1 holdclr_only=1` twenty cycles past the escape.
A passing escape test is not a safety test.

## What a correct fix must do

1. NOT key on `sub_wr_os_ctr == 0` alone — prefer "no AW accepted SINCE this hold
   was set", which cannot be satisfied by a live EWR write.
2. NOT release the hold via `synth_b_pending`, because that signal disables the
   hold wholesale. Needs a release path that clears `wr_hold_r` only.
3. Be tested for: hold escapes, `synth_b_pending` returns to 0, AND a subsequent
   normal peer write lands byte-exact.

## Status of the artefacts

- RTL reverted to HEAD (`b75d391b0f659d808ac0a4cb37310643`). Nothing committed.
- Rejected candidate preserved: `tl042_rejected_fix/tl042_fix_REJECTED.patch`.
- `test_wr_hold_stuck_escapes_tl042` kept but marked `skip=True` with the full
  record; `WRITEHOLD_TESTS` reverted so the gate is not newly red.
- Sim gate on the candidate was `SIM_GATE_EXIT=2` (RED): 3 FIFO failures
  (TL-033 x2, plus a stale TB referencing `packet_active_r` after an RTL rename to
  `read_packet_active_r`) — all provably outside the change — and 3 XFAIL
  sentinels unchanged.

## Rig note

The KR260 pair is HEALTHY and delivers 16/16 byte-exact on baseline. The
"degraded rig / reseat the ribbon" narrative remains RETRACTED and was wrongly
repeated once during this session before being corrected. Bring-up did lottery
once (run #1: die_a fcsm=2, VOID — see `TL042_RUN1_VOID_2026_08_13.md`), which is
the known RX-capture placement hold race, and cleared on retry.

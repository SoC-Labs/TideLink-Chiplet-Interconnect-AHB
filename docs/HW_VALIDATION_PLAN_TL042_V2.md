# HW validation plan — TL-042 v2 (no-harm campaign)

RECONSTRUCTED 2026-08-14. The original lived only in a session that a server
reboot killed; it was referenced as `docs/HW_VALIDATION_PLAN_TL042_V2.md` but had
never been written to disk. This is that spec, recovered from the two sessions'
agreed protocol. Written down so it survives the next reboot.

## What is being validated — and what is NOT

**This is a NO-HARM campaign, not a does-it-fix-the-wedge campaign.**

TL-042's v2 patch (`imp/hw_gate/tl042_v2/tl042_v2_proposed.patch`, UNCOMMITTED)
releases a latched `wr_hold_r`. It is sim-proven (3/3, and its test independently
rejects the v1 candidate that hardware rejected) and reviewed sound by two
sessions.

But it is **NECESSARY-BUT-NOT-SUFFICIENT, measured**: the 2026-08-13 ILA capture
read `xhb_sub_hreadyout_raw = 0` on all 4096 samples of the held wedge, and the
onset trace shows `wr_hold_r` asserting for **2 cycles**, clearing, and the stall
then persisting **3582 further cycles with the wrapper hold already released**.
XHB500 stalls independently.

⚠ **THEREFORE: A v2 BENCH RUN WILL STILL WEDGE. THAT IS THE EXPECTED RESULT.**
Do NOT accept or reject v2 on "does die_a survive errinject". Signing off on that
criterion would reject a correct patch; blaming v2 for the wedge would repeat the
v1 postmortem error in the opposite direction.

**Acceptance = v2 delivers byte-exact at the same rate as baseline on
anchor-good runs.** That is the entire claim v2 makes.

## Protocol

1. **INTERLEAVE the arms** — baseline, v2, baseline, v2 … Never block them.
   v1's confound came precisely from n=1 baseline vs n=2 fix run back-to-back.
2. **n >= 6 per arm minimum.** The baseline delivery failure rate is 3/20 (15%),
   so anything smaller cannot separate a regression from it.
3. **STRATIFY ON THE ANCHOR PAIR.** Record `EPOCH_STATUS` bit0 per die per run.
   Runs with `die_a=YES, die_b=NO` deliver 0/16 EVERY TIME (n=20) and must be
   reported separately, excluded from the acceptance comparison.
   **Without this stratification the A/B measures the anchor lottery, not the
   patch.**
4. **Do NOT stratify on the status word.** `SWI_LANE_STATUS` bits 29/25 are
   `llrx_valid` / `is_short_pkt` — free-running RX packet classification, not
   anchor state. `run_06` PASSED while showing the "bad" word at bring-up and all
   three genuine failures showed the "good" word there, so a bring-up-time status
   gate produces false positives. Mask `0x2200_0000` is SECONDARY corroboration
   only, and only if sampled at the same point as the original campaign.
5. Every arm md5-pinned on-board before proceeding; abort on mismatch.

## Instrument prerequisites — do these BEFORE the first arm

- **`EPOCH_STATUS` full-word logging is already landed** (commit `8d71ee2`); the
  bring-up now prints `sr_span_meas` (bits [6:1]) alongside the anchor bit. Use
  it — it is the only quantitative bring-up-quality number the design exposes,
  and it may turn the binary stratifier into one that explains itself.
- **SPACE THE STEP-6C SSH POLLS.** ~25 back-to-back ssh sessions trip sshd's rate
  limiter right before the step-7 FCSM gate needs ssh; the resulting `rc=2` is
  INDISTINGUISHABLE from a wedge. This voided 18 of 20 errinject steps in the
  n=20 campaign. Fix before gathering any wedge statistic.
- **Region F is DEAD** (TL-039/TL-040, confirmed prospectively at n=20). No
  `0xad800000` "ALL CLEAN" word means anything. **Delivery truth is the LOCALMEM
  byte-exact verify.**

## Rig discipline

- `fpgahub lease show <board>` first; `lease acquire <board> --ttl N` as its OWN
  command, never chained with board ops; release with the token at the end.
- Recover an unreachable board with `ssh mapstone-dev "~/bin/kpor kr260-01 --wait"`.
  Never request a bench trip — remote POR works.
- eth-chiplet APB is `0x4_0000_0000 + SoC addr` (`0x2E032xxx`). NEVER probe
  `0x8403_xxxx`, `0x21AC`, `0x21B0`, `0x21B4` — they hang the PS.

## Reporting

Per-run table (arm, md5, anchor pair per die, `sr_span_meas`, delivery n/16,
Region F rc, errinject rc, post-mortem reachability), then the acceptance
comparison over ANCHOR-GOOD runs only, with anchor-bad runs reported separately
and counted. Raw numerators/denominators, not just percentages.

## Related

- `imp/hw_gate/TL042_HW_RESULT_REJECTED_2026_08_13.md` — why v1 was rejected, and
  why "harmful" was later retracted as confounded.
- `imp/hw_gate/ila_raw_probe/` — the `xhb_sub_hreadyout_raw = 0` capture, with two
  VOID runs recorded rather than discarded.
- `imp/hw_gate/overnight/` — the n=20 baseline campaign the rates come from.
- `imp/hw_gate/tl042_v2/DESIGN_NOTE.md` — the patch's own scope limits.

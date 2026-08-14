# PRE-REGISTERED: is die_b's SWI_LANE_STATUS a delivery predictor?

**Written BEFORE the 20-run overnight reliability campaign reported.** That
campaign was already in flight when this was written; its results have NOT been
read. This file exists so the hypothesis cannot be fitted to them afterwards.

## The observation (retrospective, n=15, therefore only a hypothesis)

Across the 2026-08-13 harness runs, die_b's `SWI_LANE_STATUS` (`0x2E032108`), read
at step 5 **before any peer write**, appears to separate the outcome:

- `0x05890000` -> delivery byte-exact (reported 10/10)
- `0x27890000` -> delivery 4/16 or all-zeros (reported 5/5)

Confirmed present in my own three runs: both failing TL-042-arm runs had die_b at
`0x27890000`; the passing baseline run had `0x05890000` on both dies. Both words
decode to the SAME printed fields (`cal=1 fcsm=4 lane_locked=0x00 lane_fault=0x00
cr_seen=1 crack_seen=1`) — the difference lies in bits [31:24], which the status
decoder does not print. `fcsm=4` was true in every one of those runs, so **fcsm is
demonstrably NOT the predictor**.

## Why this matters

1. It is the strongest available confound against the TL-042 candidate's
   rejection: a pre-write difference on the die whose bitstream never changed.
2. If it holds PROSPECTIVELY it is a cheap, software-readable bring-up quality
   signal — which would contradict TL-031's premise that no SW-readable margin
   indicator exists, and would turn the bring-up lottery into a bounded
   retry-until-good-status loop with NO netlist change. That is directly on the
   MVP bar "works most of the time".

## PREDICTIONS (falsifiable, recorded in advance)

**Q1 — SEPARATION.** In the overnight baseline campaign, runs whose die_b step-5
status is `0x05890000` will deliver byte-exact at a materially higher rate than
runs reading `0x27890000`.
- SUPPORTED: clean or near-clean separation, with both status values actually
  occurring (see the vacuity guard below).
- REFUTED: byte-exact deliveries occur under `0x27890000`, or failures occur
  under `0x05890000`, at comparable rates. Then the retrospective n=15 was an
  artifact of run ordering or of arm blocking, and the TL-042 confound argument
  weakens accordingly (though it does not thereby validate the candidate).

**Q2 — VACUITY GUARD (check FIRST).** The campaign is baseline-only. If ALL runs
report the same status value, Q1 is UNTESTABLE by this campaign — not supported.
Say so explicitly rather than reporting a perfect but empty correlation.

**Q3 — DIRECTION OF CAUSATION IS NOT ADDRESSED.** Even a clean separation does not
establish that die_b's status is a *cause*. The link is bilateral, so die_a's
behaviour could produce die_b's status. This campaign cannot separate predictor
from symptom, and no claim that it does may be made from it.

## Known contrary evidence, recorded now

An 08-06 run is reported to have shown the OPPOSITE direction. That has not been
re-derived here. It is recorded so a confirming overnight result is not treated as
settling the question on its own.

---

# RESULT (2026-08-13, n=20 baseline campaign) — Q1 SUPPORTED, BUT CONFOUNDED

**Vacuity guard: PASSED** — both values occurred (17x `0x05890000`, 3x `0x27890000`),
so the prediction was testable.

**Q1: SUPPORTED, complete separation.** `0x05890000` -> 17/17 byte-exact.
`0x27890000` -> 0/3 byte-exact. Zero misclassifications. `fcsm=4` in ALL 20 runs,
so fcsm is confirmed NOT the predictor.

**🔴 BUT THE PREDICTOR IS FULLY CONFOUNDED WITH RE-ANCHOR ASYMMETRY.** The three
failing runs {09, 15, 19} are simultaneously "die_b status = `0x27890000`" AND
"die_a RE-ANCHORED while die_b did NOT". Same three runs, perfectly collinear —
this campaign CANNOT separate them. Cross-tab over all 20:

| anchor die_a / die_b | n | delivery |
|---|---|---|
| YES / YES | 5 | all 16/16 |
| NO / NO | 8 | all 16/16 |
| NO / YES | 4 | all 16/16 |
| **YES / NO** | **3** | **all 0/16** |

Two things this rules out: re-anchoring is NOT required for delivery (NO/NO is
perfect), and asymmetry per se is NOT the issue (NO/YES is perfect). ONLY the
specific direction "die_a anchored, die_b did not" fails.

**THE ANCHOR READING IS THE BETTER HYPOTHESIS**, because it carries a mechanism:
die_a's deskew locked while die_b's did not, so die_b's receive alignment is wrong
and the payload does not land. It also predicts that bits [31:24] of
`SWI_LANE_STATUS` simply ENCODE anchor/epoch state — which would make the status
word the SYMPTOM and the asymmetry the CAUSE. That is testable by decoding those
bits from RTL (still owed, see below).

**Q3 (causation) remains unaddressed**, as pre-registered. Neither reading is
established as causal by a correlational campaign.

**OPERATIONALLY, EITHER READING GIVES THE SAME CHEAP WIN:** both are readable
BEFORE any data is sent, so a bounded retry-until-good gate converts 17/20 (85%)
into effectively ~100% with NO netlist change. Prefer gating on the ANCHOR pair
(mechanistic, already printed by the bring-up script) rather than on an unnamed
status field.

**Sample-size honesty:** n=3 on the failing arm. Three-for-three is suggestive,
not settled.

---

# 🔴 FOLLOW-UP (2026-08-14) — THE DECODE WEAKENS THIS RESULT. READ BEFORE USING IT.

Bits [31:24] have now been decoded from RTL (`imp/hw_gate/status_decode/`). Three
corrections to what is written above:

1. **The bits are NOT anchor/epoch state.** bit 29 = `llrx_valid`
   (`WlinkRxLinkLayer.v:100,946`), bit 25 = `is_short_pkt` (`:97`) — RX packet
   classification. The "status word encodes anchor state" hypothesis is REFUTED.
   They are not independent either: in byte-align state 0 (both measured words
   report `[22:21]=00`), bit 29 is bit 25 delayed one clock. ONE observation.
2. **The word is a FREE-RUNNING SNAPSHOT with no stickiness** (`:1996-2001`), so
   the separation is sample-point-dependent. Re-derived from the campaign logs:
   `run_06` PASSED 16/16 while reading `0x27890000` AT BRING-UP, and all three
   genuine failures read the GOOD word `0x05890000` at bring-up. **A gate polling
   this word at bring-up would have produced a false positive and caught none of
   the real failures.** The 17/17-vs-0/3 separation is real ONLY at the step-5
   sample point.
3. **Q1 "SUPPORTED" above therefore overstates it.** It is supported *at one
   sample point*, which is much weaker than it reads. GATE ON THE ANCHOR PAIR
   (`die_a=YES & die_b=NO`), which is a latched result and clean at either point.
   Use mask `0x2200_0000` as secondary corroboration only.

**Two errors in THIS file, corrected:**
- The "nobody has decoded [31:24]" caveat below was FALSE — the names were already
  in `docs/REGISTER_MAP.md:245-263`. What was missing was the semantics.
- The claim that this refutes TL-031 was based on an inaccurate paraphrase. TL-031
  (`BUG_REGISTRY.yaml:1235-1237`) claims no eye/BER MARGIN metric; binary
  packet-classification bits are not a margin metric. **TL-031 stands.**

**Leading mechanism for the asymmetry (hypothesis, NOT established):**
`autonomy_retire_q` branch 2 (`axi_chiplet_controller.sv:4931`) fires on THIS
die's anchor alone after ~160ms with no peer-anchored term, dropping the
forced-SYNC beacon that the RTL comment at `:4911-4913` says the peer's re-anchor
needs. Branch 1 is mutual; branch 2 — the silicon path — is not. Needs a paired
sim before anything is built on it.

## Decoding still owed (SUPERSEDED — see follow-up above)

Nobody has yet decoded bits [31:24] of `SWI_LANE_STATUS`. Until those bits are
named from RTL, "0x05 good / 0x27 bad" is a correlation over an unnamed field and
must be described that way, never as a mechanism.

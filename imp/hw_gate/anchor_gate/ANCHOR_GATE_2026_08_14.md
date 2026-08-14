# The ANCHOR-PAIR RETRY GATE

Date: 2026-08-14
Branch: `integ/tidelink-consolidated-2026-08-07`
Tree: `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`
Status: **implemented in-tree, retrospectively validated, NOT committed, NOT run on hardware.**

**No hardware was touched to produce this.** Everything below is either static
reading of the repo or replay of logs that already existed
(`imp/hw_gate/overnight/`). The retry loop was exercised end-to-end against a
stub rig, not a KR260.

---

## 1. What it is, in one paragraph

After a concurrent two-die bring-up, read the **pair** of autonomous re-anchor
verdicts (`EPOCH_STATUS` `0x2140` bit0, one per die). If the pair is
**die_a = YES, die_b = NO**, throw the bring-up away and re-roll it — each retry
re-runs winscan, which is a fresh eye. Any other pair proceeds. Bounded retries,
then a clear, logged failure. **No RTL change, no netlist change, no rebuild.**

---

## 2. The measurement it encodes

`imp/hw_gate/overnight/`, n=20 consecutive cold POR → PL-load → bring-up →
delivery cycles on the baseline build, 2026-08-13, harness `tl035_ab.sh baseline`
with **retry switched off** (single-shot bring-up).

Delivery truth = die_b-**local** `VERIFY n/16 byte-exact`, read **before** any
error injection. Both qualifiers are load-bearing: reading back over the link
would let the verifier wedge, and the *post*-inject verify is after a deliberate
fault (runs 10 and 13 legitimately read 13/16 and 12/16 there — they are not
delivery failures).

| anchor die_a / die_b | runs | delivered byte-exact |
|---|---|---|
| YES / YES | 5 | 5/5 |
| NO / NO | 8 | 8/8 |
| NO / YES | 4 | 4/4 |
| **YES / NO** | **3** | **0/3** |

Two things follow, and both matter:

- **Re-anchoring is not required.** 8 runs where *neither* die re-anchored
  delivered perfectly. The old accept test ("both dies RE-ANCHORED") was
  therefore rejecting 15/20 good bring-ups.
- **Asymmetry alone is not the fault.** NO/YES — the mirror image — delivered
  4/4. Only the one direction fails.

`fcsm = 4` and `cal_done = 1` were true on **both dies in all 20 runs**, so the
pre-existing health check is blind to this by construction. That is the gap this
gate fills.

---

## 3. Why this is a retry condition and not a silicon defect

Both anchor bits are readable **before any payload is sent**, and a bring-up is a
**precondition of a measurement, not the measurement itself**. Re-rolling a
precondition until it is sound is ordinary practice; re-rolling until the
*result* looks good would be fraud. This gate only ever touches the former: it
reads state produced by the bring-up sequence, decides the link is not worth
sending payload over, and repeats the bring-up. It never re-runs, re-samples or
re-scores a delivery measurement.

The price of that legitimacy is logging. Every attempt and the final attempt
count are recorded (§6), so a "works ~100%" claim can never be quoted without its
retry cost.

---

## 4. Where the pair is evaluated, and why there

**The pair cannot be evaluated inside `kr260_eth_bringup.py`.** That script runs
*on one board*, mmaps *that die's* TideLink APB through the `eth_ss_0` backdoor,
and by design cannot reach the peer's registers — the two dies are separate
KR260s driven by two independent concurrent ssh invocations. A die knows its own
anchor bit and nothing about its partner's.

So the pair is evaluated **in the orchestrator that already owns both dies**:
`pynq_host/scripts/kr260_eth_bringup_pair.sh`. That script already

- runs both dies' bring-up concurrently (they self-synchronise on `cal_done`),
- collects each die's `RESULT:` verdict from its own log, and
- implements a **`MAX_TRIES=8` retry loop** — the pre-existing orchestrator the
  MVP scope doc points at (`MVP_SCOPE_2026_08_13.md:187`, `:290`).

**This work extends that script rather than competing with it.** The retry loop,
the concurrency, the recipe staging and the `MAX_TRIES` budget are all reused
as-is; what changed is the accept predicate, the logging, and the log plumbing.
`run_categoryA_goodeye.sh` already calls this same orchestrator, so it inherits
the gate with no edit.

The predicate itself lives in **one** file, `pynq_host/scripts/anchor_pair_gate.py`,
because the live orchestrator and the retrospective validator must be running the
*same* code. A gate validated against logs by a second implementation of the
predicate is not validated at all.

---

## 5. The predicate

```
mode = pair   (default)
  no LINK UP on either die           -> REJECT  (bring-up lottery miss, as before)
  die_a = YES and die_b = NO         -> REJECT  (the measured failure pair)
  anything else                      -> ACCEPT
  any input unknown/unparseable      -> UNKNOWN -> treated as REJECT (fail closed)
```

Two other modes are kept deliberately:

| mode | predicate | why it exists |
|---|---|---|
| `pair` | reject YES/NO only | **default.** The measured gate. |
| `both` | require YES/YES | the **legacy** accept test, one env var away. Strictly safe w.r.t. the n=20 evidence but wasteful — see §7. |
| `off` | link-up only | reproduces the 08-13 baseline measurement conditions exactly. **Use this and only this when generating numbers that must be comparable to that campaign.** |

**Fail-closed is not decoration.** An unreadable or self-inconsistent bring-up log
returns `UNKNOWN`, never `ACCEPT`. "We do not know the pair state" must not be
spelled the same way as "we checked and it is good" — that confusion is exactly
how a dead instrument reads as a healthy DUT. The parser also cross-checks the
`RESULT:` line against the full `EPOCH_STATUS` word (present since `8d71ee2`) and
declares `UNKNOWN` if they disagree.

### Explicitly NOT gated on `SWI_LANE_STATUS`

Bits [29]/[25] are `llrx_valid` / `is_short_pkt` — free-running Wlink RX
*packet-classification* samples, not anchor state, and [29] is [25] delayed one
clock (one observation, not two). See
`imp/hw_gate/status_decode/SWI_LANE_STATUS_DECODE_2026_08_14.md`. The
retrospective replay quantifies how bad that candidate was — §6, contrast row.

---

## 6. Retrospective validation — 20 runs, zero rig time

`python3 imp/hw_gate/anchor_gate/validate_anchor_gate.py`

Replays the live predicate over every
`imp/hw_gate/overnight/run_NN/tl035_baseline/`, parsing the two
`04_bringup_{a,b}.log` for anchor verdicts and `00_run.log` for the pre-inject
die_b-local delivery result.

```
run     anchor_a  anchor_b  gate     delivery
run_01  YES       YES       pass     16/16
run_02  YES       YES       pass     16/16
run_03  YES       YES       pass     16/16
run_04  NO        NO        pass     16/16
run_05  NO        YES       pass     16/16
run_06  NO        NO        pass     16/16
run_07  NO        NO        pass     16/16
run_08  YES       YES       pass     16/16
run_09  YES       NO        FLAG      0/16   <<<
run_10  NO        NO        pass     16/16
run_11  NO        NO        pass     16/16
run_12  NO        YES       pass     16/16
run_13  NO        NO        pass     16/16
run_14  NO        NO        pass     16/16
run_15  YES       NO        FLAG      0/16   <<<
run_16  YES       YES       pass     16/16
run_17  NO        NO        pass     16/16
run_18  NO        YES       pass     16/16
run_19  YES       NO        FLAG      0/16   <<<
run_20  NO        YES       pass     16/16
```

### Confusion matrix, mode = `pair` (the shipped default)

|  | delivery FAILED | delivery OK |
|---|---|---|
| **gate FLAGGED** | **3** | **0** |
| **gate passed** | **0** | **17** |

- true positives: `run_09`, `run_15`, `run_19`
- **false positives: none**
- **false negatives: none**

The gate flags exactly runs 09, 15, 19 and nothing else — the pre-registered
acceptance criterion for this validation. The validator exits non-zero if that
ever stops being true.

### The same replay, other modes

| mode | flagged & failed | flagged & OK (wasted retries) | passed & failed (missed) | passed & OK |
|---|---|---|---|---|
| **`pair`** | **3** | **0** | **0** | **17** |
| `both` (legacy) | 3 | **12** | 0 | 5 |
| `off` | 0 | 0 | **3** | 17 |

The legacy `both` test catches the same 3 failures but re-rolls 12 bring-ups that
would have delivered byte-exact — and at the measured p(YES/YES) = 5/20 = 0.25 an
8-try budget still exhausts about 10% of the time. `off` is the 08-13 baseline:
it misses all 3.

### Contrast — the rejected `SWI_LANE_STATUS` candidate

A gate keyed on `0x27890000` appearing in the bring-up log would flag
**run_06, run_17, run_18** — **all three of which delivered 16/16** — and would
catch **none** of 09/15/19. (In the three real failures that word appears only in
the *step-5* status sample, not in the bring-up log: the bits are free-running and
sample-point fragile, exactly as the decode document says.) Three false positives,
zero true positives. That is why it was rejected, and it is a useful reminder that
a plausible-looking correlated word is not a predictor.

---

## 7. Expected cost and expected benefit — with the honest error bars

Per-attempt reject rate, mode `pair`: **p = 3/20 = 0.15**.

- expected attempts per accepted bring-up ≈ 1/(1 − 0.15) ≈ **1.18**
- P(all 8 attempts rejected) = 0.15^8 ≈ 2.6 × 10⁻⁷ — the budget is not the
  binding constraint
- at ~15 s/attempt the mean added cost is ≈ **3 s per bring-up**

**But the "~100%" figure is not established by this data, and must not be quoted
as if it were.** The accepted arm was 17/17. With zero observed failures in 17
samples the rule of three gives a **95% upper bound on the accepted-arm failure
rate of 3/17 ≈ 17.6%**. So what the evidence actually supports is: *"delivery
failure after the gate accepts is below ~18% with 95% confidence"* — which is
consistent with ~100%, and equally consistent with a rate not much better than
the un-gated 15%. Only more accepted-arm runs can narrow that.

---

## 8. Honesty caveats — none of these are optional when quoting this gate

1. **n = 3 on the failing arm.** Three-for-three is suggestive, not settled. The
   entire failure population of the campaign is three runs.
2. **The retrospective matrix is a fit, not a confirmation.** It is scored on the
   same 20 runs that motivated the predicate. It demonstrates self-consistency and
   — the part that actually has content — the *absence of false positives* across
   17 passing runs. It is **not** independent evidence.
3. **The campaign cannot separate predictor from symptom.** The live hypothesis is
   **anchor-as-WITNESS**: `reanchored = 1` with an all-zero `lane_off` is
   bit-identical on the datapath to `reanchored = 0`, so the anchor bit may be
   *reporting* a condition rather than being one. **This gate is a cheap
   mitigation, not a proven mechanism.** It does not close the root cause and
   must not be recorded as having closed it.
4. **Retry cost is part of the result.** Any reliability number produced with the
   gate enabled must be quoted with `attempts_used`. A gated run and an un-gated
   run are different samples and must never be pooled — which is why the mode and
   the attempt count are written into `99_verdict.txt` on every run.
5. **The 08-13 numbers stay valid as-is.** They were measured with retry off;
   `ANCHOR_GATE=0` (or `ANCHOR_GATE_MODE=off`) reproduces those conditions
   byte-for-byte, and nothing in this change rewrites them.

### The load-bearing assumption, stated plainly

The retry loop assumes **re-running bring-up without a POR re-rolls the anchor
lottery**. The pre-existing script asserts this ("each retry re-runs winscan = a
fresh eye") but it was inherited, not demonstrated.

Retrospectively there *is* supporting evidence, found while writing this and
worth recording: in `imp/hw_gate/ila_raw_probe/run/run.log` and `run2/run.log`
there are **4 distinct instances** where the inner pair-script retry — no POR
between them — went `try 1 = NO/NO` → `try 2 = YES/YES`, **4/4**. So the anchor
outcome demonstrably does re-randomise across a no-POR bring-up retry.

**What is still untested: none of those 4 retried a YES/NO pair.** There is no
recorded instance anywhere in the tree of a YES/NO pair being re-rolled. The
gate's central action has never actually been observed to happen.

---

## 9. What rig validation would still be needed before trusting this

In rough priority order. **All of this needs separate authorization; none of it
was done here.**

1. **Observe the gate firing at all.** Run until a YES/NO pair occurs
   (p ≈ 0.15, so ~7 runs expected) and confirm the retry produces a *different*
   pair. This is the one assumption with zero direct evidence (§8). If a YES/NO
   pair is *sticky* across a no-POR retry, the gate must escalate to POR (L2)
   instead of looping, and the current loop would burn its whole budget.
2. **Grow the accepted arm.** The useful claim is bounded by 17 samples
   (§7). ~30 more gated runs would pull the 95% upper bound on the accepted-arm
   failure rate from ~18% down to ~10%.
3. **Confirm no new failure mode is introduced by retrying.** A repeated
   bring-up re-writes `ROLE_CFG`, re-asserts `SWI_TRAINING_MODE`, and re-issues
   the 3-write LL bootstrap on an *already-linked* pair. Check that a re-roll on
   a live link neither wedges the PS nor leaves a die in a state the next attempt
   cannot recover from. **This is the single most likely way this change does
   harm**, and it is the standing lesson that a passing escape test is not a
   safety test: assert that the *normal* path still works after the gate fires,
   not merely that the gate fires.
4. **Prospective, pre-registered scoring.** Write the predicate down first, then
   run n ≥ 20 fresh runs and score them without touching the predicate. Only that
   converts §6 from a fit into a confirmation.
5. **Correlate `sr_span_meas`.** Bits [6:1] of `EPOCH_STATUS` are now logged
   (`8d71ee2`) but no run in the campaign predates that commit, so the column is
   empty in §6. If the span differs systematically between the YES/NO pairs and
   the rest, the binary signal becomes one that explains itself — and that is the
   cheapest available route to separating witness from cause (caveat 3).
6. **Decide on the delivery probe.** `MVP_SCOPE` M2(b) wants the accept test also
   requiring a byte-exact delivery probe, since `reanchored=1` + `fcsm=4` do not
   imply a good eye (TL-031). It is wired as an **optional, default-unset hook**
   (`PAIR_DELIVERY_PROBE`) rather than a default, because putting an unvalidated
   cross-die write into every bring-up is a plausible new wedge source. Validate
   it on the rig before enabling.

---

## 10. Files touched

Nothing is committed. Nothing outside this repository was modified. No file under
`/research/AAA/ip_library/**` or `/research/AAA/phys_ip_library/**` was read from
or written to.

| File | Status | What |
|---|---|---|
| `pynq_host/scripts/anchor_pair_gate.py` | **new** | The predicate + bring-up-log parser. Single source of truth, shared by the orchestrator and the validator. CLI: exit 0 accept / 10 reject / 11 unknown. |
| `pynq_host/scripts/kr260_eth_bringup_pair.sh` | **modified** | Existing `MAX_TRIES=8` orchestrator: accept test now delegates to `anchor_pair_gate.py`; per-attempt logs preserved as `bu_{a,b}.tryN.log`; final attempt copied to the canonical names so all existing parsers keep working; per-die bring-up timeout; `ANCHOR_GATE_SUMMARY` line with `attempts_used`; optional `PAIR_DELIVERY_PROBE` hook. |
| `imp/hw_gate/tl035_ab.sh` | **modified** | Step 4 routed through the orchestrator (`ANCHOR_GATE=1` default; `ANCHOR_GATE=0` restores the exact single-shot path). Gate mode + attempt count recorded in `99_verdict.txt`. Run continues on gate exhaustion, but the log says the delivery result is gate-rejected, not a baseline sample. |
| `imp/hw_gate/anchor_gate/validate_anchor_gate.py` | **new** | Retrospective replay over the 20 runs; confusion matrix; mode comparison; `SWI_LANE_STATUS` contrast. Exits non-zero unless the gate flags exactly 09/15/19. |
| `imp/hw_gate/anchor_gate/ANCHOR_GATE_2026_08_14.md` | **new** | This document. |

### How it was tested

- Retrospective replay over all 20 runs, all three modes — §6.
- Retry loop exercised end-to-end against a **stub rig** (fake
  `kr260_eth_run.sh`, no boards, no network): accept-on-retry, budget exhaustion
  → exit 1, link-down rejection, `both`/`off` modes, delivery-probe re-roll,
  per-try log preservation, canonical final-log placement.
- Parser unit-checked for the post-`8d71ee2` full-word format, missing file,
  truncated log, and a `RESULT`-vs-`EPOCH_STATUS` disagreement — all four
  correctly fail closed to `UNKNOWN` rather than accepting.
- `bash -n` clean on both shell scripts.

# KR260 TideLink pair — overnight reliability campaign, 2026-08-13

**Arm: BASELINE ONLY.** Nothing was built and no experimental bitstream was
deployed. Both dies ran the already-staged baseline images, md5-verified on the
board at the start of every run:

- die_a (kr260_01, 10.22.24.159) `td/tl_arm_baseline.bin` = `9eadebb80470ace022eb2bad769f888b`
- die_b (kr260_02, 10.22.24.153) `td/tl_arm_baseline.bin` = `13573e46c3b27bb6b03b41b2ce730aa8`

Harness: `imp/hw_gate/tl035_ab.sh baseline`, invoked unmodified, `ITERS=128`.
Per run: JTAG POR both dies -> md5-verified PL load -> mandatory AFI width fix ->
concurrent bring-up -> status -> cross-die delivery -> Region F gate -> errinject
-> post-mortem.

Campaign window 2026-08-13 **20:30:58Z -> 22:11:28Z** (100.5 min wall).
Evidence: `imp/hw_gate/overnight/run_NN/tl035_baseline/` (per-run `00_run.log`
plus all step logs). Driver transcript: `imp/hw_gate/overnight/driver.log`.

**n = 20. All 20 runs completed and all 20 parsed; there are no dropped or
unparseable runs.** (A mid-campaign instruction assumed run_20 had not been
started and asked for the report to state n=19. That instruction was based on
stale status: run_20 had already completed at 22:10:43Z and the driver exited at
22:11:28Z, before the instruction arrived. No run was started after it. Recording
"run_20 was not run" would have been false, and run_20 is also the run that
supplies the recovery evidence for run_19's wedge, so it is reported as the
evidence shows.)

---

## Per-run table

`crack` = `crack_seen`. `anchor` = autonomous re-anchor (EPOCH_STATUS bit0) per
die, a/b. `delivery` = die_b LOCALMEM `VERIFY n/16 byte-exact` (step 6e, read
before any error injection) — the delivery truth. `die_b status` = die_b's step-5
`SWI_LANE_STAT 0x2E032108`.

| run | die_a fcsm/crack | die_b fcsm/crack | bring-up | anchor a/b | die_b status | delivery | RegF rc | RegF | errinject_rc | die_a_post | die_b_post |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | 4/1 | 4/1 | PASS | YES/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 02 | 4/1 | 4/1 | PASS | YES/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 03 | 4/1 | 4/1 | PASS | YES/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 04 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 05 | 4/1 | 4/1 | PASS | NO/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 06 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 07 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 08 | 4/1 | 4/1 | PASS | YES/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| **09** | 4/1 | 4/1 | PASS | YES/NO | **0x27890000** | **0/16** | 1 | **FAIL** | 2 (VOID: no inject) | **DOWN** | UP |
| 10 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | **1 (WEDGE — inject ran)** | **DOWN** | UP |
| 11 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 12 | 4/1 | 4/1 | PASS | NO/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 13 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | **1 (WEDGE — inject ran)** | **DOWN** | UP |
| 14 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| **15** | 4/1 | 4/1 | PASS | YES/NO | **0x27890000** | **0/16** | 1 | **FAIL** | 2 (VOID: no inject) | **DOWN** | UP |
| 16 | 4/1 | 4/1 | PASS | YES/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 17 | 4/1 | 4/1 | PASS | NO/NO | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| 18 | 4/1 | 4/1 | PASS | NO/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |
| **19** | 4/1 | 4/1 | PASS | YES/NO | **0x27890000** | **0/16** | 1 | **FAIL** | 2 (VOID: no inject) | **DOWN** | UP |
| 20 | 4/1 | 4/1 | PASS | NO/YES | 0x05890000 | 16/16 | 0 | PASS | 2 (VOID: no inject) | UP | UP |

---

## 1. BRING-UP SUCCESS RATE — the headline MVP number

Bring-up success = **both** dies reach `fcsm=4` at step 5.

> **20 / 20 = 100%**

Every run: `die_a fcsm=4 cal=1 crack_seen=1` and `die_b fcsm=4 cal=1 crack_seen=1`.
`cal_done=1` and `crack_seen=1` on both dies in all 20 runs. Not one bring-up
lottery loss in 20 consecutive cold POR -> PL-load -> bring-up cycles.

This is the number nobody had beyond single-digit samples. On this vehicle
(`kr260-eth-chiplet` baseline, ribbon pair, on the current rig) bring-up is not
the flaky step.

## 2. RE-ANCHOR RATE

Both dies autonomously re-anchored (EPOCH_STATUS bit0=1 within 12 s):

> **5 / 20 = 25%**

Runs 01, 02, 03, 08, 16. Breakdown of all four patterns:

| anchor a/b | runs | count | delivery outcome |
|---|---|---|---|
| YES/YES | 01,02,03,08,16 | 5 | 5/5 byte-exact |
| NO/NO | 04,06,07,10,11,13,14,17 | 8 | 8/8 byte-exact |
| NO/YES | 05,12,18,20 | 4 | 4/4 byte-exact |
| **YES/NO** | **09,15,19** | **3** | **0/3 byte-exact — all three failures** |

**Re-anchor is not required for delivery.** The 8 runs where *neither* die
re-anchored all delivered 16/16 byte-exact. The bring-up script's advice
("Marginal-eye lottery; RETRY the bring-up") is therefore not warranted by
delivery outcome on its own — 12 of the 15 non-YES/YES runs delivered perfectly.

What *does* track failure is the **asymmetric** pattern: die_a re-anchored and
die_b did not. All 3 such runs failed; no other pattern failed.

## 3. DELIVERY SUCCESS RATE

Counted **only over runs that achieved a healthy bring-up** (both dies `fcsm=4`).

- Runs with healthy bring-up (delivery denominator): **20**
- Runs VOID for delivery (link never came up): **0**
- Runs excluded for an unreadable LOCALMEM verify: **0**

> **17 / 20 = 85% byte-exact delivery**

Failures: runs **09, 15, 19** — each `VERIFY 0/16 byte-exact  firstbad=idx0
got0x00000000 exp0xa5a50000`, i.e. nothing landed at all, not a partial or
bit-error landing. The independent Region F per-beat gate agreed on all three
(`rc=1`, `data_exact=False`; run_09's fold detail: `4/16 folded words byte-exact
firstbad off=0x0004 got=0x00000000 exp=0xF1714F9A (PRBS32)`).

Because every run brought up cleanly, the delivery denominator here happens to
equal the run count. The distinction still matters and is preserved: **0 runs
were VOID**, so no failed-link run was silently folded into the data-plane
number.

## 4. RECOVERABILITY — the second MVP bar

Runs that ended with a die unreachable, and whether the **next** run's JTAG POR +
md5-verified PL reload restored it:

| run left DOWN | which die | cause | next run | recovered? |
|---|---|---|---|---|
| 09 | die_a | delivery failure; Region F gate staged a fail-fast JTAG POR on kr260_01 | 10 | **RECOVERED** |
| 10 | die_a | genuine errinject wedge (AW byte0/bit0, rc=1) | 11 | **RECOVERED** |
| 13 | die_a | genuine errinject wedge (AW byte0/bit0, rc=1) | 14 | **RECOVERED** |
| 15 | die_a | delivery failure; gate staged POR | 16 | **RECOVERED** |
| 19 | die_a | delivery failure; gate staged POR | 20 | **RECOVERED** |

> **5 / 5 = 100% recovery. 0 failures. No bench trip at any point.**

"Recovered" is evidenced, not assumed: in each following run the die answered
SSH after POR, its `td/tidelink.bin` re-verified to the expected md5, the PL
reloaded ("BIN FILE loaded through FPGA manager successfully"), the AFI width fix
passed, and the die reached `fcsm=4` again. die_b never went DOWN in any run.

The recovery loop is entirely remote: `~/bin/kpor kr260-01 --wait` from
mapstone-dev, then `fpgautil -f Full`, then `kr260_afi.sh fix`.

## 5. Runs that behaved differently, described rather than averaged away

**Runs 09, 15, 19 — the delivery failures.** All three share an identical
signature, and it is not a partial degradation:
- die_b step-5 `SWI_LANE_STATUS = 0x27890000` (every other run: `0x05890000`)
- anchor pattern YES/NO (die_a re-anchored, die_b did not)
- LOCALMEM 0/16 with `firstbad=idx0 got0x00000000` — nothing landed
- Region F gate `rc=1`, `data_exact=False`
- die_a left DOWN, die_b alive
- runtime ~650 s vs ~140-170 s for a clean run

These three are the same failure, not three different ones. Note they are spread
through the campaign (09, 15, 19), not clustered at the start or end, so this is
not warm-up or thermal drift.

**Runs 10 and 13 — the only two runs where error injection actually executed.**
Both produced `AW byte0/bit0 inject@kr260_01 : FAIL (WEDGE)`, rc=1, die_a down —
the expected TL-035 repro on the baseline arm. Both recovered on the next POR.
2/2 injects wedged.

**18 of 20 runs produced NO error-injection data (rc=2).** This is an instrument
artifact, not a DUT result, and it must not be read as "the inject passed". The
sweep's own FCSM gate aborted before injecting:

```
FCSM gate  die_a(10.22.24.159): ssh: connect to host 10.22.24.159 port 22: Connection reset by peer
FCSM gate  die_b(10.22.24.153): link SWI_LANE_STATUS=0x05890000 fcsm=4 cal=1 -> UP
GATE ABORTED: 2
```
die_a's sshd was rate-limiting. The cause is inside the harness: step 6c fires
`LIVEPOLLS=25` back-to-back ssh sessions at die_a, which trips the limiter
immediately before step 7 needs ssh. Corroboration: in those runs the step-6c
liveness sampler returned only 7 (or 0) of 25 samples and die_a's pre-inject
Region F read came back empty while the die was demonstrably alive (it answered
again seconds later, and `die_a_post=UP`). **The `0x21E0` reads that came back
empty in these runs are rate-limited ssh, not a wedged die.**

**The Region F sampler was dead in all 20 runs.** Every run reported `stall bits
NEVER moved under active write load` -> TL-039/TL-040 confirmed prospectively at
n=20. Consequently every `0xAD800000` "ALL CLEAN" reading in this campaign is
meaningless in both directions and none of the above rests on one; the delivery
conclusions rest on the LOCALMEM byte-exact verify and the gate's folded-word
compare.

---

## Pre-registered hypothesis check: die_b `SWI_LANE_STATUS` as delivery predictor

Tested against `imp/hw_gate/PREREG_DIEB_STATUS_PREDICTOR_2026_08_13.md`,
prospectively — the pre-registration was written while this campaign was in
flight and before any of its results were read.

**Q2 — VACUITY GUARD (checked FIRST): PASSED, the prediction is testable.**
Both status values actually occurred in the baseline-only campaign:
`0x05890000` in 17/20 runs, `0x27890000` in 3/20 runs. This is not a degenerate
single-value column, so Q1 can be evaluated.

**Q1 — SEPARATION: SUPPORTED, with the sample size stated plainly.**
Cross-tab over the 20 healthy-bring-up runs (raw counts):

| die_b step-5 SWI_LANE_STATUS | byte-exact (16/16) | failed (0/16) | total |
|---|---|---|---|
| `0x05890000` | **17** | 0 | 17 |
| `0x27890000` | 0 | **3** | 3 |
| total | 17 | 3 | 20 |

Separation is complete in this sample: 17/17 vs 0/3. The status is read at step 5
**before any peer write**, so it is available in advance of the transfer.

Honest limits on that result, which the pre-registration itself demands:

1. **n=3 on the failing arm.** Three runs is a small numerator. Complete
   separation over 3 events is consistent with a real effect, but the campaign
   cannot bound the false-negative rate of the signal at any useful precision.
2. **The predictor is fully confounded with the anchor asymmetry.** The set
   {09, 15, 19} is *simultaneously* "die_b status = 0x27890000" and "anchor
   YES/NO". They are the same three runs, so this campaign **cannot** tell which
   of the two is the better predictor, nor whether both are downstream of a third
   cause. Any retry-until-good-status loop built on this should gate on both.
3. **Q3 — causation is not addressed and no claim is made.** die_a's behaviour
   could produce die_b's status; the link is bilateral.
4. **Bits [31:24] remain undecoded.** `0x05` vs `0x27` is a correlation over an
   unnamed field. Both words decode to identical printed fields
   (`cal=1 fcsm=4 lane_locked=0x00 lane_fault=0x00 cr_seen=1 crack_seen=1`) —
   which independently re-confirms the pre-registration's point that **`fcsm` is
   not the predictor**: all 20 runs had `fcsm=4` on both dies, including all 3
   failures.
5. The 08-06 contrary evidence recorded in the pre-registration was not
   re-derived here and is not overturned by this campaign.

---

## What the numbers mean against the bar "works most of the time and is recoverable"

**Works most of the time — met on bring-up, met with a caveat on delivery.**

- Bring-up **20/20**. The link comes up every time. The historical "bring-up
  lottery" did not occur once in 20 cold cycles on this baseline.
- End-to-end delivery **17/20 (85%)**. Roughly **1 run in 7** brings the link up
  to a clean `fcsm=4` on both dies and then carries **nothing at all** —
  `0/16`, not a degraded transfer. A user of this MVP would see the link report
  healthy and the data silently not arrive.
- The failure is **detectable in advance, without sending data**: all 3 failures
  are picked out by die_b's pre-write `SWI_LANE_STATUS = 0x27890000` (and
  equivalently by the YES/NO anchor asymmetry). Subject to the n=3 caveat above,
  a bring-up that re-POR'd and retried on that reading would plausibly convert
  85% into something much closer to the 100% bring-up figure — with no netlist
  change. That is worth a targeted follow-up, and it should be validated against
  a larger failure sample before being relied on.

**Recoverable — met, unambiguously.**

- **5/5** wedges recovered on the next JTAG POR + PL reload, 0 failures.
- Both wedge classes recovered: the errinject-induced TL-035 wedge (runs 10, 13)
  and the delivery-failure/gate-POR path (runs 09, 15, 19).
- Recovery is fully remote. **No bench trip was needed or attempted.**
- die_b never went down; only die_a (kr260_01) ever wedged, in all 5 cases.

**The honest gap.** This campaign characterises bring-up, delivery and
recoverability well. It does **not** characterise error-injection robustness:
only 2 of 20 runs actually injected, because the harness rate-limits its own ssh
in step 6c. Both that did inject wedged (2/2). Fixing that self-inflicted rate
limit — spacing or batching the 25 liveness polls — is a prerequisite for any
future campaign that wants an errinject survival rate. It does not affect any
number reported above, all of which are measured before step 6c.

---

## Board leases

| board | token | acquired | released |
|---|---|---|---|
| kr260_01 | `5Cf2QrpBT2W0E7XkN4TCRw` | 20:29:32Z (TTL 10800 s) | yes — see below |
| kr260_02 | `V3-fnZTS50oOTy0QfBNrhA` | 20:29:38Z (TTL 10800 s) | yes — see below |

Both leases were acquired individually before any board access and **both were
released at the end of the campaign**; release is confirmed by `lease show`
reporting `not leased` for both boards. No renewal was needed — the campaign ran
100.5 min inside the 180 min TTL.

Nothing was committed. No file under `/research/AAA/ip_library/**` or
`/research/AAA/phys_ip_library/**` was read from, written to, or otherwise
touched.

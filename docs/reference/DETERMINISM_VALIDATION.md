# Lane-Lock Determinism — Metric & Validation Procedure

**Purpose:** give the supervising session **one objective verdict** for
the question "did this candidate constraint / IDELAY / clock-path change
actually make TideLink GPIO-PHY lane-lock deterministic, or is it still
the current ~1-in-N luck?"

**Tool:** `pynq_host/scripts/determinism_metric.sh` (pure log ingest —
it does **not** build, run Vivado, deploy, or touch a board).

**Background:** identical RTL + different Vivado place&route gives
build-to-build PHY lane-lock nondeterminism (e.g. v5 locked both boards
7/7, v6 left the slave at ~0 at every phase). Root cause is unbounded
per-lane routing skew vs the runtime calibrator's finite
bit-slip(0..7)×phase(0..15) window — see
`/tmp/timing_determinism_investigation_brief.md` and, for the ASIC
target, `docs/reference/ASIC_TIMING_CONSTRAINTS.md`. WNS alone does **not**
capture this; the metric below does.

---

## The metric

For each build *b* (one captured `phase_recal_sweep.sh` stdout log) the
script parses every `(mp,sp)` row's MASTER and SLAVE locked popcount and
derives:

- **`hasBSG[b]`** — is there *any* `(mp,sp)` where both sides fully lock
  (master# ≥ `LOCK_TARGET` **and** slave# ≥ `LOCK_TARGET`, default
  `LOCK_TARGET=8` = all lanes)? "BSG" = both-sides-good. This is the
  thing that actually matters: a common operating point where master
  *and* slave lanes both lock — not master-only or slave-only.
- **`bsgset[b]`** — the *set* of `(mp,sp)` that are BSG in that build.
- **`bestpt[b]`** — the `(mp,sp)` with the highest master#+slave# total
  (recomputed from the table, not trusted from the sweep's footer).

Aggregated across the N builds, the determinism metric is a **triple**:

1. **BSG-yield** = (#builds with `hasBSG`=1) / N
   *Does a both-sides-good operating point reliably exist at all,
   build to build?* The current luck baseline scores ≈ 1/N here.
2. **common-BSG Jaccard** = |∩ bsgset over qualifying builds| / |∪ bsgset|
   *Is it the **same** operating point every build, or does the good
   `(mp,sp)` wander?* 1.0 = every build's good set is identical.
3. **best-pt spread** = number of *distinct* `bestpt` across builds,
   plus the max Chebyshev distance (in grid steps) between any two.
   *How far does the single best operating point move build to build?*

Scalar score for quick comparison:
`D_score = round(100 · BSG-yield · common-BSG-Jaccard)`, floored to 0 if
no build ever had a BSG point. 100 = perfectly deterministic.

### Pass / fail (default thresholds)

A change **PASSES** (exit 0) iff **all three** hold:

| Metric | Threshold (env var) | Default | Meaning |
|---|---|---|---|
| BSG-yield | `YIELD_PASS` | **1.00** | every build has a both-sides-good point |
| common-BSG Jaccard | `JACCARD_PASS` | **0.50** | the good set is majority-stable |
| best-pt distinct count | `BESTPT_PASS` | **1** | the single best `(mp,sp)` is identical every build |

Otherwise it **FAILS** (exit 1).

**Why these thresholds.** The current ~1-in-N luck fails on BSG-yield
alone (yield ≈ 1/N ≪ 1.00) — that is the baseline a real fix must beat.
A fix that merely raises WNS but still has the good point appear in only
some builds, or wandering build-to-build, fails. Requiring `bestpt`
identical every build is deliberately strict: source-sync determinism
*means* the same calibrated operating point recurs, not just "something
locks somewhere". Loosen the thresholds only with explicit justification
recorded alongside the run (e.g. `JACCARD_PASS=0.34 BESTPT_PASS=2` if a
±1-phase-step jitter is argued acceptable for the channel).

---

## Procedure (the supervising session executes this)

1. **N ≥ 5 independent builds.** Five is the minimum to separate
   1-in-N luck from a real fix at the default thresholds; more is
   better. Each build = a clean place&route of the candidate
   RTL/XDC/IDELAY/clock-path change.
2. For each build, deploy the pair and run the existing sweep with a
   fixed phase set, capturing **stdout** to `buildK.log`:

   ```sh
   MP_LIST="0 2" SP_LIST="0 1 2 3 4 5 6 8 10 12" \
       pynq_host/scripts/phase_recal_sweep.sh | tee buildK.log
   ```

   Keep the same `MP_LIST`/`SP_LIST` across all N builds (the metric
   compares like with like; changing the phase set between builds
   invalidates the Jaccard).
3. *(Recommended)* Also capture the Region-8 RO credit-path mirror at
   that build's BEST `(mp,sp)` and save it next to the log as
   `buildK.log.probe`:

   ```sh
   pynq_host/scripts/wlink_probe.sh <BOARD_IP> > buildK.log.probe
   ```

   If present, the script cross-checks the probe's `SWI_LANE_STATUS`
   locked byte, FCSM state and `cr_pkt_seen_rx`: a build whose sweep
   *claimed* a BSG point but whose credit path is wedged (FCSM stuck at
   1, or `cr_pkt_seen_rx`=0, or the probe's lock popcount < target) has
   its BSG **revoked** — lock without a moving credit path is not
   determinism.
4. Run the metric over all N logs:

   ```sh
   pynq_host/scripts/determinism_metric.sh build1.log build2.log ... buildN.log
   # or:
   pynq_host/scripts/determinism_metric.sh -d /path/to/logdir
   ```

### Board access note

The script ingests files **already on disk**; it never touches a board.
If a caller separately needs to pull a fresh probe, board ssh is
`SSH_AUTH_SOCK=/tmp/dam1n19-agent.sock ssh mapstone-dev …`; `scp` is
broken on these hosts — copy with `ssh '<host>' 'cat >dst' <src`. The
metric script itself does none of this.

---

## Reading the verdict

```
================ TideLink lane-lock determinism ================
  builds ingested (N)        : 5
  builds with a BSG point    : 5  (qualifying for stability: 5)
  LOCK_TARGET (per side)     : 8 lanes
  -- metric --
  (1) BSG-yield              : 1.0000   (pass >= 1.00)
  (2) common-BSG Jaccard     : 1.0000   (|inter|=1 / |union|=1; pass >= 0.50)
  (3) best-pt distinct count : 1   (pass <= 1; max Chebyshev=0 steps)
  D_score (0..100)           : 100
  VERDICT: PASS — ...
```

- **PASS (exit 0):** a both-sides-good operating point reliably exists
  *and* is stable across builds. The change improved determinism over
  1-in-N luck. The single recurring good `(mp,sp)` is reported per build
  in the `best=(mp,sp)` column — use it as the calibrator's expected
  operating point.
- **FAIL (exit 1):** determinism not demonstrated. Read which leg
  failed:
  - **BSG-yield < 1.00** → some builds have *no* common operating point
    at all (still luck). The dominant failure; the constraint is not
    bounding skew enough.
  - **Jaccard low** → a good point exists each build but it is a
    *different* point each build (skew spread still large; the
    calibrator is finding it by chance at a different code).
  - **best-pt distinct > 1 / large Chebyshev** → the best point wanders;
    if only ±1 step and the channel argues it's tolerable, re-run with a
    justified looser `BESTPT_PASS`/`JACCARD_PASS` (record why).

### Interpreting per-build lines

```
build  3  b4.log   hasBSG=0  best=(2,2) tot=15  bsgpts=0
build  2  b3.log   hasBSG=0  best=(0,2) tot=16  bsgpts=1 [PROBE REVOKED BSG: fcsm=1 cr_pkt=0 probe_lockpop=8]
```

`hasBSG=0` with `bsgpts=0` = that build never reached both-sides-good
(this is the v6-style failure). `[PROBE REVOKED BSG ...]` = the sweep
claimed lock but the Region-8 RO mirror proved the credit path was
wedged at that point, so it does not count.

---

## What this measures vs WNS

WNS/TNS answers "did STA's (mis)constrained model close?" — which, with
the current async-everything constraints, is *meaningless* for the
pad→capture arc. This metric answers the only question that matters for
this PHY: **across independent builds, does a common master+slave locked
operating point reliably and stably exist?** A constraint/IDELAY/clock
change is only an improvement if this metric says PASS; a WNS
improvement with this metric still FAIL is not a determinism fix. For
the ASIC target the same metric concept applies across PVT corners /
units instead of build seeds — see
`docs/reference/ASIC_TIMING_CONSTRAINTS.md` Part A §1 and the Part B §9 checklist.

# Where verification coverage lives

**Date:** 2026-08-26 · **Status:** design + working prototype; **nothing has been uploaded**
· **Branch:** `rev2/coverage-infra` (worktree `td-bisect/rev2-covinfra`, unpushed)

TideLink has never had a coverage database. That is how a whole arm of the XHB500 bridge
shipped unexercised at every commit: `singles_burst` is gated on `hprot[3]` rather than
`hburst`, so the non-singles path has never executed in any test, and nothing in the flow
was capable of noticing. This document says where coverage data goes so that it is
durable, comparable, and consulted.

Every number below is MEASURED on this tree on 2026-08-26 unless marked INFERRED.
Where something has not been done, it says so in those words.

---

## 0. The five-line summary

| I need to… | Command |
|---|---|
| build one coverage artifact | `make cov_pack` |
| see what publishing it would do | `make cov_publish` (dry run, always) |
| actually publish it | `make cov_publish_real` **[needs credentials]** |
| make it the reference | `make cov_baseline` **[needs credentials + the repo]** |
| see what changed | `make cov_diff BASE=<dir>` |
| prove the tooling offline | `make cov_selftest` |

Two repositories, mirroring `asic-candidate` / `asic-release` exactly:

```
verif-coverage    every gate run.  90-day sweep, newest 10 always kept.
verif-baseline    the reference a delta is measured against.  PROTECTED.
```

---

## 1. The measurements that decide the design

Merging three real TideLink `.vdb` databases with the site `urg` (VCS T-2022.06-SP2):

| thing | raw | `.tar.zst -19` | ratio |
|---|---|---|---|
| merged `.vdb` | 2.7 MB | 2.35 MB | **1.15×** |
| urg text report | 16 MB | 173 KB | **92×** |
| — of which `modinfo.txt` | 9.1 MB | | |
| urg HTML report | ~11 MB, 22 files | not published | regenerable |
| `dashboard.txt` | 1.0 KB | | |
| `hierarchy.txt` | 20 KB | | |

A complete run of the prototype over **eight** real databases produced a **1.57 MB**
artifact: 1.13 MB database, 373 KB `urg.log`, 24.5 KB text report, ~7 KB of JSON.

Three consequences, and they are not the GDS answers:

**A `.vdb` is already internally compressed.** zstd -19 buys 15%. `ARTIFACT_FLOW_PLAN`
§1.2 measured **13.1×** on a GDS and concluded storage was a non-issue for a different
reason. Do not carry that number across — it is about a different kind of file. The
`.tar.zst` is kept anyway, because one archive is one object with one digest instead of
a few hundred files, not because it saves space.

**The HTML report is four times the database it came from.** It is regenerated from the
`.vdb` in seconds. It is never published. Publishing it would quadruple the store cost of
every run to carry something derivable — the same call `ARTIFACT_FLOW_PLAN` §8 makes for
DEF/SPEF.

**Coverage is small.** At 1.6 MB measured (INFERRED 3–8 MB for a full 44-suite gate merge,
because the design database scales with the number of distinct compiled designs and not
with the number of tests), a daily trunk publish is **0.6–3 GB/year raw**, and about
**200 MB–1 GB steady state** under a 90-day window. Storage is not the constraint here
either. §6 covers the one place where it does bite, which is not the one you would guess.

---

## 2. The repository

### 2.1 Layout — and why the depth is not free

```
verif-coverage/tidelink/simgate/covrun-20260826T0013Z-5994cce7/
    merged/cov_merged.vdb.tar.zst          the replayable database
    report/cov_report_text.tar.zst         urg -format text
    report/cov_summary.json                canonical metrics, SMALL, uncompressed
    report/urg.log                         urg stdout+stderr
    unexercised/unexercised_scoped.json    the scoped never-exercised list
    unexercised/unexercised_scoped.txt     the same, for a human in an MR
    manifest/cov_manifest.json             fail-closed identity + every digest
    manifest/SCOPE.txt                     the scope file CONTENT, not its digest
    manifest/vdb_inputs.txt                every database that went into the merge
```

`<project>/<block>/<run_tag>/<kind>/<file>` — **exactly five segments**, because
`artifactory_retention.py` derives the run tag as `path.split("/")[2]` and the delete
target prefix as `"/".join(path.split("/")[:2])`. One level shallower and a sweep derives
the wrong tag; one level deeper and it derives the wrong **delete subtree**, which is a
recursive removal at the wrong node. `cov_publish.py` asserts the segment count before it
uploads anything, so this is checked at publish time rather than discovered by a sweep.

Run tag `covrun-<UTC>-<shortsha>[-dirty]`. Ordinal, not content-derived, for the reason
`ARTIFACT_FLOW_PLAN` §7 gives: content-derived IDs map 1:N onto results when the producing
flow is not deterministic. Digests are attributes (§3). `-dirty` is in the *name* because a
run tag is what appears in a report, and a non-reproducible run should say so where it will
be read.

### 2.2 What one coverage artifact contains, and why each part is there

| part | why it cannot be dropped |
|---|---|
| merged `.vdb` | the only artifact that can answer a NEW question of an OLD run — "which test covered this line?" — without re-running the suite |
| text report | the human record. 173 KB compressed; `modinfo.txt` carries the per-object detail |
| `cov_summary.json` | canonical metrics. **This is the file that gets diffed**, and the one that is also git-tracked (§4) |
| `unexercised_scoped.*` | the point of the exercise. §5 |
| `urg.log` | the *only* place urg's `No source found` warning appears — it goes to stderr and leaves no trace in the report |
| `cov_manifest.json` | §3 |
| `SCOPE.txt` **content** | a coverage number is meaningless without the exclusions it was computed under, and a digest of a file nobody kept is a detector, not a recovery mechanism — the `rzG` power plan lesson, one domain over |
| `vdb_inputs.txt` | which databases were merged. A merge is a claim about *what ran* |

### 2.3 Retention, and the exact change the sweep needs

`artifactory_retention.py`'s scope is a literal:

```python
POLICY    = {"asic-candidate": 90}
PROTECTED = frozenset(("asic-release", "asic-record",
                       "artifactory-build-info", "auto-trashcan"))
```

A repository absent from both is not protected and is not swept — **it grows forever**,
and every one of its blobs is new every day, so it also defeats the `--link-dest`
hardlinking that makes the nightly snapshot cheap. The proposed change, which is one
edit and needs a human to make it (§8):

```python
POLICY = {
    "asic-candidate": 90,
    "verif-coverage": 90,     # coverage candidates
}
PROTECTED = frozenset(("asic-release", "asic-record",
                       "artifactory-build-info", "auto-trashcan",
                       "verif-baseline"))          # <-- added
```

Both halves, in the same commit. Adding the candidate repo without protecting the
baseline is strictly worse than doing neither.

**Reasons to keep**, mapped onto the five the sweep already implements:

| existing | coverage analogue |
|---|---|
| protected repo | `verif-baseline` |
| inside the window | 90 days |
| among the newest 5 | **newest 10** — a gate that runs per-merge produces runs far faster than a tapeout does. ⚠ `KEEP_NEWEST = 5` is currently a **global module constant**, not per-repo: raising it in place would also change `asic-candidate`'s behaviour. It has to become a value in `POLICY` alongside the window, which is a slightly larger patch than it looks |
| a foundry graded it | **it was promoted to `verif-baseline`**, joined by `build.name`/`build.number`, not by path |
| pinned with `retention.keep` | unchanged |

The foundry-grading exemption is the one that does not transfer directly. Its purpose is
"an expensive external verdict describes these exact bytes; deleting the bytes leaves the
verdict describing nothing". For coverage the expensive thing is not external, it is the
*baseline relationship*: a promoted artifact is the thing other runs are measured against,
and it lives in a protected repo, which is a stronger guarantee than an exemption.

**One latent bug in the sweep, worth knowing before a second project ever lands.** The
per-run prefix check (`retention.py` ~line 300) aborts if one run tag appears under two
prefixes, which is correct — but the delete target is still `<prefix>/<tag>`, and the
comment in the file concedes the derivation "works only while the repo holds exactly one
project". Keeping coverage in its own repository sidesteps this entirely, which is one
more reason not to file it under `asic-candidate`.

### 2.4 Backup — no change needed, and that is a measured claim

`artifactory_backup.sh` pulls the **whole** PostgreSQL dump and the **whole**
content-addressed filestore from `srv03335`. It is not repo-scoped. A new repository is
therefore backed up from its first publish with no configuration change at all, to
`/research/dam1n19/artifactory-backup`, on different hardware with an institutional backup
regime underneath, mode 700, `master.key` included, 14 snapshots hardlinked.

The nightly snapshot grows by exactly that day's new blobs. At an INFERRED 3–8 MB per
publish, one publish a day costs **40–110 MB** across the whole 14-snapshot rotation.
Against a first snapshot measured at 601 MB on disk, that is noise.

**Do measure it rather than assume it.** The ops runbook records that `--link-dest` failed
silently for two separate reasons and both were found only because the disk cost was
measured. The script now samples a blob's link count and warns when it is 1. After the
first week of coverage publishing, read that warning.

---

## 3. The provenance contract

The rule this project already got right, in `prov.*` schema 1:

> `# UNVERIFIED:<reason>` means the field could not be measured. It is **NOT a value**:
> any comparison involving one must be refused.

And the rule it got wrong, in the FPGA build manifest, fixed 2026-08-24 in
`fpga/scripts/build_provenance.tcl`: `git_dirty:false` actually meant "could not evaluate
the tree", and one artifact was stamped `source_commit:"unknown"` **and** clean in the same
document. Both failures were fail-*open*: an unmeasurable thing scored as the good value.

`cov_identity.py` implements the same contract for coverage, in four rules, each with an
assertion in `cov_identity_selftest.py` (19 checks, all green).

**R1 — a field is a measured value or `UNVERIFIED:<reason>`.** There is no third state.
`_run()` deliberately has no `default=` parameter, because a default is precisely how
"could not tell" becomes "clean".

**R2 — `tree_state` reads `clean` only when both git calls succeeded and `status` was
empty.** Any other outcome is `UNVERIFIED:<reason>`, never `clean` and never a silent
`dirty` that hides the reason. The selftest asserts the negative directly:

```
rev-parse OK + status rc=128 -> tree_state NOT 'clean'             ok
  ...and the reason is recorded, not discarded                     ok
NEVER: a known commit with an unevaluable tree scored clean        ok
```

That `rc=128` is the real one: `expected submodule path 'deps/...' not to be a symbolic
link`, which is how builds with symlinked `deps/` came to be stamped clean while carrying
uncommitted RTL.

**R3 — any `UNVERIFIED` field sets `promotable:false`, and nothing sets
`publishable:false`.** An imperfectly labelled run still publishes. This programme's
recurring failure is instruments that existed as one untracked file on one host, not
instruments that were labelled too honestly. But such a run can never become the baseline
other runs are measured against.

**R4 — an incomplete closure is not hashed.** `input_closure_id` becomes
`UNVERIFIED:incomplete-closure:<fields>`. Hashing the literal string `UNVERIFIED` would
give two *different* indeterminate runs the *same* id, and they would then compare as a
reproducible replicate of each other. `cov_diff.cell_2x2` enforces the matching half: two
`UNVERIFIED` closures are `UNKNOWN-CLOSURE`, never `same`.

A dirty tree also yields no closure id. A dirty tree is not recoverable from any commit, so
an id that looked reproducible would be a lie.

### The manifest, from a real run

Produced by the prototype against the live worktree — note that it is honest about
itself, which is the whole point:

```
run_tag                covrun-20260825T233241Z-5994cce7-dirty
coverage.commit        5994cce706099ff5e8efee0e65d10f4e095a5fa3
coverage.tree_state    dirty
coverage.closure_id    UNVERIFIED:incomplete-closure:xhb500_digest
coverage.id            56ade3cf6269b828a61403361c05b8e33e1ac428db99f3d172bfdfe6ced7575b
coverage.completeness  complete
coverage.scope_sha256  ca7282a08443486deb1ed383d9a350beecb8ad5ee65ea4cdd413ea3cd4011382
coverage.promotable    false
    - identity has 1 UNVERIFIED field(s)
    - tree_state=dirty
    - UNVERIFIED: xhb500_digest
```

`xhb500_digest` is `UNVERIFIED` because this worktree has no
`scripts/xhb500_tree_digest.sh`. That field exists for the reason the bitstream manifest
records: `deps/xhb500/generated` is **gitignored and not a submodule**, yet four flists
compile 32 files out of it, so `git status` is structurally blind to it. For coverage this
matters more than anywhere else — the unexercised arm this whole repository exists to catch
lives in exactly that tree.

### Two digests, and the 2×2

| | |
|---|---|
| `input_closure_id` | sha256 over commit, tree state, submodule pins, XHB500 tree digest, flist digests, VCS version, scope digest, expected suite list. **The attempt.** |
| `coverage_id` | sha256 over the canonical per-module metric body and the scoped unexercised list, with every date, host, absolute path, tool version and command line stripped. **The result.** |

This is where coverage repays an argument that GDS could not. A `.vdb` is *not*
reproducible — it embeds the urg command line, the wall clock and absolute host paths. But
the coverage **content** should be exactly reproducible for the same RTL and the same
tests. So:

| | coverage same | coverage differs |
|---|---|---|
| **closure same** | `REPLICATE` — the run reproduces | `NONDETERMINISM` — same inputs, different result. A seed, a race, a flaky suite. **A bug report, not a coverage delta.** |
| **closure differs** | `INERT` — the suite cannot see this change | `ORDINARY` — read the table |

`NONDETERMINISM` is the cell that has no equivalent today. A suite that sometimes runs
different stimulus currently shows up as coverage noise that everyone learns to ignore.

Properties are attached **at deploy time as matrix parameters**, all of them, because the
retro-fit `?properties` endpoint is Artifactory Pro only on this instance: an artefact
already in the store cannot acquire a property without being re-deployed. That is exactly
why four hand-published ASIC candidates carry no identity and needed a whole backfill
program. `cov_publish.py` sets `build.name`/`build.number` too — without them a promotion
fails with `Unable to find artifacts of build`, and the build record is decorative.

---

## 4. Trending — a number nobody diffs is decoration

`cov_diff.py`. Exit code **is** the verdict: `0 PASS`, `1 REGRESSED`, `2 REVIEW`,
`3 REFUSED`. 12 self-tests, all green.

### What is compared

* **per-metric totals** and **per-module** metrics;
* **collection loss** — a metric that *was* collected and now is not is a REGRESSION even
  though no percentage moved. That is how a metric silently stops being gathered;
* **modules that vanished** from the report. A module that stopped appearing is not a
  module at 100%; it is a module nothing compiled or nothing instantiated;
* **newly unexercised** entries — the load-bearing half. New coverage is nice; *lost*
  coverage is a bug. A new tier-1 or tier-2 finding in `own` or `shipping-vendor` scope
  blocks regardless of what the percentages did;
* the **2×2 cell**.

### What it refuses

`REFUSED` is a first-class outcome and reports **no number at all**:

* either side is a **partial merge**. A suite that did not run and code that was never
  reached are indistinguishable in the resulting database — and indistinguishable *in the
  flattering direction*, because a suite that failed to launch looks exactly like a clean
  run of a smaller design;
* either side's `coverage_id` is `UNVERIFIED`;
* `cov_summary.json` is missing on either side.

And **a `SCOPE.txt` change can never return `PASS`.** The cheapest way to raise this
metric is not to write a test; it is to add a line to the exclusion file. So the scope
digest is part of the compared identity, a change downgrades the best possible verdict to
`REVIEW`, and the diff prints both digests. Every scope rule carries a mandatory reason
field (§5), which turns that review into a five-second job.

### Where the comparison surfaces

1. **`git diff` on `docs/coverage/`, in the merge request.** `make cov_track` copies the
   three small JSON files — about 10 KB per run — into the tree. This costs nothing, needs
   no store, no network and no credential, and `git log -p docs/coverage/` **is** the
   coverage changelog. It is the same call `ARTIFACT_FLOW_PLAN` §7 item 8 makes for run
   records, and it is the single highest-value line in this document.
2. **CI job `coverage-trend`**, which fetches the baseline and runs the diff.
3. **`make cov_diff BASE=<dir>`** locally, before pushing.

`cov_fetch_baseline.sh` tries the store first and falls back to the newest git-tracked
summary — and **the fallback is not a degraded mode**. Everything the diff needs is in the
summary; the database is needed only to ask a *new* question of an *old* run, which is the
rarer case and the one worth a credential. A trend that only works while a server is up is
a trend nobody consults.

When neither source yields a baseline it **fails loudly**. "No baseline" is a missing
measurement, not a result.

---

## 5. The scoped unexercised list

`SCOPE.txt` classifies every source path as `own` / `shipping-vendor` / `harness` /
`out-of-scope`. Three properties matter:

**An unmatched path defaults to `own` — IN scope.** A classifier that silently drops what
it does not recognise is a classifier that hides new code.

**Every rule carries a mandatory reason.** `cov_report.py` refuses to load a rule without
one. This is the rule that would have mattered: the XHB500 arm lives under
`deps/xhb500/generated`, a **vendor-generated** path that any ordinary "exclude third-party
code from coverage" line would have hidden permanently — and the reason it would have
stayed hidden is that nobody would ever have had to write down why. So there is no
`# vendor` catch-all, and `shipping-vendor` is a first-class class: not written here, but
it goes in the chip, so a zero is a verification gap too.

**Three tiers, because the defect this exists to catch is a tier-2 one.**

| tier | what it finds |
|---|---|
| T1 | module never exercised at all |
| T2 | a metric at 0.00 in a module whose other metrics are not — **a whole arm never executed while the module looks fine** |
| T3 | the individual uncovered lines and branches |

`singles_burst` is a tier-2 signature exactly: its module has real line coverage, and one
branch never went the other way. A module-level dashboard could never have found it, which
is why T2 is computed and reported separately rather than folded into one percentage.

**Two ways this refuses to manufacture confidence.**

*Partial merge.* If any expected suite produced no verdict, every finding downgrades from
`UNCOVERED` to `UNDETERMINED` and the basis is stamped on the report. An unexercised list
read as an absolute claim, generated from a partial merge, invents confidence out of a
missing input.

*Missing sources.* urg prints `Warning-[URG-NSF] No source found ... Annotated line
coverage report will not be generated` **to stderr only** — `modinfo.txt` contains no trace
of it. A checker that greps the report for that warning finds nothing and concludes all is
well. So the measurement is structural instead: a module for which urg collected a line
metric must also have a `Line Coverage for Module :` section, and the answer is
`AVAILABLE` / `PARTIAL:n/m` / `UNAVAILABLE:<reason>`, never a boolean. Separately,
`urg.log` is captured and the count of unopenable source files is reported as an integer
**or `UNVERIFIED:no-urg-log`** — not 0, because a missing log means the question was not
asked.

---

## 6. The publish path

### What is there today, measured

`.gitlab-ci.yml` **does** have a `coverage` stage (`coverage-merge`) and it **does** have a
`sim-gate` job at `allow_failure: false`. The standing note that `make sim_gate` is wired
into no CI hook is **stale** — it was wired in, with an explanatory comment naming the
`a405809` escape it was created to stop.

Three defects in the existing `coverage-merge` job:

1. `expire_in: 30 days` on a GitLab job artifact. A report on one runner that deletes
   itself in a month, cannot be compared against last week, and does not survive the
   `clone` job's own `find ... -mmin +1440 -exec rm -rf` sweep of the workspace. This is
   the "artifact that lives only on one host in a reapable directory" failure with a nicer
   UI.
2. `if [ -z "$VDB_DIRS" ]; then echo "WARNING: No VDB..."; exit 0; fi` — a pipeline in
   which every simulation failed to emit a database produces a **green** coverage job.
3. `urg ... 2>&1 | grep -E 'Note|Error|Warning' || true` — urg's exit status is discarded
   entirely. A failed merge is a green job.

`cov_pack.sh` hard-fails on all three: an empty database list is fatal, urg's exit status
is captured and non-zero refuses to produce an artifact, and a digest mismatch refuses to
publish.

### Where CI actually runs — check this before wiring anything

Measured 2026-08-26:

```
git.soton.ac.uk  soclabs/tidelink                            main = 9092300b
github.com       SoC-Labs/TideLink-Chiplet-Interconnect-AHB  main = 5e8bdb5a
git merge-base --is-ancestor 9092300b 5e8bdb5a               -> TRUE
```

The GitLab trunk is a strict **ancestor** of the GitHub trunk. `.gitlab-ci.yml` only ever
sees commits pushed to GitLab, and the work is not going there. There is no
`.github/workflows` directory at all. **Both new CI jobs are therefore correct and inert
until someone decides which forge runs CI.**

That is why `make cov_pack && make cov_publish` is the primary interface and the CI job is
a *caller* of it, not the other way round. The manual path works today, on a developer
machine or on the gate host, with no CI.

### The jobs, added to `.gitlab-ci.yml` (YAML validated, 44 jobs parse)

`coverage-publish` packs, **always rehearses**, uploads only when a credential is present,
and runs `make cov_track`. `coverage-trend` fetches the baseline and diffs. Both
`allow_failure: true` until a real baseline exists in `verif-baseline` — the same sequence
`sim-gate` used before it was flipped to blocking, and the same sequence recommended here.

---

## 7. What would break in the existing Artifactory setup

Ranked. The first one is not about size, and it is the one that actually bites.

**1. `backup-daily` has `retentionPeriodHours=0` on the source.** Every ~195 MB
Artifactory export is kept **forever**, on the filestore's own volume. The `PATCH` to set
it to 336 h was attempted and blocked by a permission policy; it needs a human. Adding a
repository that publishes daily makes each export larger and the unbounded accumulation
faster. **Fix this before automated coverage publishing starts, not after.** It is the
single change most likely to turn a small repository into a full disk.

**2. Host headroom.** The runbook records that standing up a second Artifactory needs
~8 GB against ~**6 GB free**. A coverage repository at an INFERRED 200 MB–1 GB steady state
is up to a sixth of the remaining headroom on a host that already cannot spare enough space
to test its own restore. Coverage is not the cause, but it is one more claimant. Measure
free space before enabling the cron, and again after the first week.

**3. One identity, and it is admin.** Artifactory OSS here has no permission targets and no
groups — both APIs answer 400 Pro-only, and the users API returns empty. A token scoped to
the only identity **is an admin token**. So a CI runner that can publish coverage can also
delete `asic-candidate`, `asic-record` and the tapeout evidence. **Automating a daily
publisher is the first time a scheduled job will hold that credential.** This needs an
explicit decision (§8), not an assumption.

**4. TLS is half-done.** 8082 is plain HTTP and `curl -n` sends
`Authorization: Basic base64(user:pass)` — an encoding, not encryption. Today that is
occasional manual use. A daily publisher sends the admin credential across the lab LAN
**nine times per run, every day, forever**. The Caddy terminator is built and verified on
the host; it needs the firewall port opened, a persistence unit, and a certificate
decision. Finishing the cutover is a prerequisite for *automated* publishing, though not
for manual use.

**5. Retention does not know the repo exists** — §2.3. Unswept, it grows forever, and
because its blobs are new every day it also defeats the `--link-dest` hardlinking that
makes the nightly snapshot cheap.

**6. The path-depth constraint** — §2.1. Checked at publish time; listed here so nobody
"tidies" the layout later.

**Not a problem:** backup scoping (whole-instance, automatic), storage efficiency
(coverage is small), and the promotion mechanism (built, selftested, unused — and a
baseline is exactly what it was written for).

---

## 8. What needs a human before any of this is real

Nothing in this document has touched the live instance. No credential has been read or
written. In rough dependency order:

| # | What | Who / what is needed |
|---|---|---|
| 1 | **Set `backup-daily` `retentionPeriodHours=336`** on the source instance | admin API call, previously blocked by policy. §7.1 |
| 2 | **Create `verif-coverage` and `verif-baseline`** as generic local repos | Artifactory admin. Empty repos are cargo cult *until something publishes to them*; the publisher exists and is tested, so this one is earned |
| 3 | **Patch `artifactory_retention.py`** — `verif-coverage` into `POLICY`, `verif-baseline` into `PROTECTED`, and make `KEEP_NEWEST` **per-repo** | code review + a `--selftest` run **with `--only-tag`**, in the same commit as #2. An earlier selftest without `--only-tag` deleted a real production candidate |
| 4 | **Decide who holds the publish credential** | §7.3. There is only an admin identity. Options: a minted token in a GitLab file-type variable, manual publishing only, or wait for a permissions model |
| 5 | **Finish the TLS cutover** before any *scheduled* publisher | firewall port 8443, a `systemd --user` unit, a certificate decision, then move `ASIC_ARTIFACT_BASE` and **close 8082** |
| 6 | **Decide which forge runs CI** | §6. Until then the make targets are the interface and the CI jobs are inert |
| 7 | **Run `make cov_pack` on a clean tree** and promote the first baseline | needs #2 and #4. Until `verif-baseline` holds one, `docs/coverage/` is the baseline |
| 8 | **Measure the full-gate artifact size** and the first week's snapshot link-count warning | replaces the INFERRED 3–8 MB with a number |
| 9 | **Decide the `docs/coverage/` commit policy** — per-merge or trunk-only | per-merge is ~10 KB/run of tracked churn; trunk-only is cheaper and still gives `git log -p` as the changelog |

Item 9 is the only one with no obviously right answer.

---

## 9. What was prototyped, and what it proves

All under `scripts/coverage/`, on `rev2/coverage-infra`. `make cov_selftest` runs the
whole offline suite: **40 assertions, all green**, no store, no simulator, no network.

| file | what it does |
|---|---|
| `cov_identity.py` | the fail-closed identity contract |
| `cov_identity_selftest.py` | 19 assertions, several asserting the *negative* |
| `cov_report.py` | urg text → canonical summary + scoped unexercised list |
| `cov_diff.py` | trending; `--selftest` = 12 assertions |
| `cov_pack.sh` | assembles one artifact |
| `cov_publish.py` | publish/promote; **dry run by default**; `--selftest` = 9 assertions |
| `cov_fetch_baseline.sh` | store first, git-tracked fallback, loud failure |
| `SCOPE.txt` | the scope file, every rule with a mandatory reason |
| `coverage.mk` | the make interface, included from the top-level `Makefile` |

**Exercised end to end on real data:** an 8-database merge of live TideLink `.vdb` files
produced a complete 1.57 MB artifact with a manifest that correctly recorded
`tree_state: dirty`, `closure_id: UNVERIFIED:incomplete-closure:xhb500_digest` and
`promotable: false`; the publish dry run printed all 9 PUTs with their properties and
contacted nothing; and a diff against a git-tracked baseline returned `REVIEW` with the
reason `inputs could not be identified on at least one side` — which is the correct
answer, not a failure.

### Shell traps observed, because this project has been bitten by each

`find … | head -1` under `set -o pipefail` kills a script mid-run with the exit code masked
— it bit three times in three different files in the Artifactory tooling. Never
`tar -tzf f | grep -q`. Option lists go in **arrays**, never a `${var:+--opt="$x"}`
expansion that keeps the quotes literal and silently does nothing. `--exclude` must
*precede* the path operand or GNU tar prints "has no effect" and exits non-zero — that one
was hit while writing `cov_pack.sh` and is fixed with a comment saying why.

---

## 10. Open questions

* Should the merged `.vdb` be published for **every** run, or only for runs that become a
  baseline or that regress? Publishing always is simple and costs ~1 GB/year; publishing
  selectively saves little and adds a decision. **Recommend: always.**
* Should `coverage-trend` block a merge? Not until there is a green baseline and a week of
  clean history — the `sim-gate` sequence.
* Tier-3 (per-line) deltas are parsed but not yet diffed object-by-object; today the diff
  is per-module plus the tier-1/tier-2 findings. Object-level diffing needs a run where
  urg could open every source, which has not been produced yet.
* `urg.log` is 373 KB of mostly repeated warnings and is stored uncompressed. Fold it into
  the text archive once the "no source found" population is understood — right now its
  verbosity **is** the finding.

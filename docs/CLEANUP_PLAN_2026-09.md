# Repository cleanup — September 2026

**Status: PLAN. Nothing here has been executed.**
Companion script: [`scripts/maintenance/cleanup_2026_09.sh`](../scripts/maintenance/cleanup_2026_09.sh),
**inert by default** — it prints and changes nothing unless given `--execute`,
and it refuses to run at all on a dirty working tree.

Measured against `origin/main` = `5e8bdb5a` on 2026-09-11. Every count below
was re-derived from the repository on that date; where a figure differs from
the one in the request that commissioned this plan, the difference is called
out rather than quietly reconciled.

---

## How to read this

Each item states four things, in this order:

1. **What it is** — the object and its current state.
2. **Evidence it is safe** — the command whose output makes the claim, and
   what that output was.
3. **What breaks if the evidence is wrong** — the failure mode, so the cost of
   being wrong is visible before the command runs.
4. **The exact command.**

Anything that could not be settled by evidence is in
[Needs a human decision](#needs-a-human-decision) and is **absent from the
script**. The script carries only items proved safe, and re-proves each one at
run time: the lists in it are a plan, not a permission.

### The safety rules the script enforces

| # | Rule | Why |
|---|------|-----|
| 1 | `--execute` required; default prints only | A cleanup script that acts by accident is a data-loss tool |
| 2 | Refuses on a dirty working tree | Uncommitted work beside branch deletion is how work disappears |
| 3 | `git tag archive/2026-09/<name> <sha>` before *every* delete, tag verified to exist and to point at that sha | No tag, no delete |
| 4 | A branch is deleted only if `git merge-base --is-ancestor <branch> origin/main` succeeds **at run time** | The plan may be stale; origin/main is the authority |
| 5 | Never deletes a checked-out branch; never removes a worktree with any uncommitted change; no `--force` anywhere | |
| 6 | Re-fetches `origin` first | "Merged" must mean merged into what is on the server now |

---

## 1. Local branches — 41 (the request said 35; six were created on 2026-09-11 by the parallel review teams)

```
git branch --merged   origin/main     # 32, excluding main
git branch --no-merged origin/main    #  9
```

### 1a. Merged into `origin/main` — 32, safe to tag-and-delete

`analysis/link-survey-2026-08-01`, `confirm/i1-fix-throughput-2026-07-31`,
`docs/bug-registry-2026-08-07`, `experiment/throughput-overnight-2026-07-31`,
`feat/txgen-v1-integration`, `feat/unit-regression-from-ethchiplet`,
`fix/axi-datanode-recovery`, `fix/i1-selfarm-rolelock`,
`fix/tidelink-isolated-write-dataloss`, `fix/txgen-present-asic-tieoff`,
`fix/v2-sync-clock-gate`, `fix/z2-drop-park-hook`, `integ/axirec-on-chiplet`,
`integ/freeze-2026-07-31`, `integ/gate-plan-2026-07-30`,
`integ/i1-fix-2026-07-31`, `integ/tidelink-consolidated-2026-08-07`,
`integ/z2-override-verify-2026-07-31`, the six `rescue/*-2026-08-10`
snapshots, `test/i1-fixe-training-release`, `test/i1-selfarm-regression`,
the three `wip/axirec-*`, `worktree-agent-aa5e31fe26d736e36`, and this
cleanup's own `chore/site-path-hygiene` once it lands.

- **Evidence:** each tip is an ancestor of `origin/main`, so every commit on
  it is already on the server. `git branch -d` (not `-D`) is used, which is
  itself a second, independent ancestry check by git.
- **If wrong:** nothing — the commits remain reachable from `origin/main`. The
  archive tag additionally preserves the *branch name* and the exact tip, so
  "what was on `fix/z2-drop-park-hook`" stays answerable.
- **Command:** phase `branches` of the script; per branch,
  `git tag archive/2026-09/<branch> <sha> && git branch -d <branch>`.

> Nine of these are checked out in a worktree. The script removes worktrees
> (phase 3) before deleting branches (phase 4) for exactly that reason.

### 1b. Unmerged but present on a remote — 3, no action

| branch | tip | also at |
|---|---|---|
| `rev2/land-prep` | `cba9774d` | `origin/rev2/integration` |
| `rev2/signoff-checkers` | `5c5328ef` | `origin/rev2/integration` |
| `wip/fcsm-collision-consolidated-2026-08-17` | `b0c75918` | `origin/wip/fcsm-collision-consolidated-2026-08-17` |

- **Evidence:** `git branch -r --contains <sha>` is non-empty for each.
- **Action:** none. These are live work, not debris. `rev2/land-prep` is the
  in-flight next iteration; deleting it would be a mistake regardless of
  whether its commits are backed up.
- **These tips move.** Within hours of this plan being written,
  `rev2/land-prep` advanced past `cba9774d` to a commit not yet on origin,
  which moved it from this section into §1c. That is why the script derives
  every classification at run time and treats the tables above as a record of
  what was true on 2026-09-11, not as a list to act on.

### 1c. Unmerged AND local-only — MUST BE PUSHED OR TAGGED BEFORE ANY DELETION

The request said there are two. As of 2026-09-11 there are **six**, because
four were created today by the parallel review teams and are still local. The
two that pre-date today — the two the request meant — are:

| branch | tip | date | subject |
|---|---|---|---|
| **`fix/tidechart-dualroot-timeout-tooling`** | **`b32d4b5b`** | 2026-09-02 | `fix(kr260_tidechart): the prep recipe was measured DUAL-ROOT` |
| **`worktree-agent-ac06dd75b70af4bbf`** | **`86c7a0a3`** | 2026-07-29 | `fix(fcsm): I1 — re-point AXI FCSM 0-4 to local_overrides` |

The four from today, listed so nobody mistakes them for debris:
`docs/contributing-land-rules` `9d4ab07e`, `docs/registry-truth-pass`
`741373ed`, `docs/rev2-review-2026-09-09` `17263c83`,
`fix/gate-selfclean-failclosed` `b877f025` (the branch has since advanced —
its worktree is at `9e35099e`).

- **Evidence:** `git branch -r --contains <sha>` is **empty** for all six, and
  `worktree-agent-ac06dd75b70af4bbf` has no upstream at all. The commits exist
  in exactly one repository, on one host.
- **If wrong — that is, if these are deleted:** the work is gone. There is no
  second copy. `worktree-agent-ac06dd75b70af4bbf` is an I1 FCSM re-point whose
  subject matter is still live in the bug registry.
- **Action:** the script **tags these and deletes nothing**, and prints a
  warning that a tag in this repository is *still only in this repository*.
  A tag is not a backup until it leaves the host:
  ```
  git push origin refs/tags/archive/2026-09/fix_tidechart-dualroot-timeout-tooling
  git push origin refs/tags/archive/2026-09/worktree-agent-ac06dd75b70af4bbf
  ```
  Decide afterwards whether to push the branches themselves.

---

## 2. Worktrees — 24 (the request said 18; six were created today)

### 2a. Clean and on a merged branch — 13, removable

`tidelink-i1fix-confirm`, `tidelink-fixe`, `tidelink-freeze`, `tidelink-z2ovr`,
`tidelink-wip-f1`, `tidelink-throughput-overnight`, `tidelink_wt_unitreg`,
`tidelink-link-survey-2026-08-01`, `tidelink-chiplet-integ`,
`tidelink-axirec`, `tidelink-mainmerge`, `tidelink-wip-ecc`,
`tidelink-wip-testrepoint`.

- **Evidence:** `git -C <wt> status --porcelain` is empty **and**
  `git merge-base --is-ancestor <HEAD> origin/main` succeeds, for each.
- **If wrong:** an uncommitted change would be destroyed. This is why the
  script re-runs both checks per worktree at execute time and uses
  `git worktree remove` with **no** `--force`: git itself refuses a dirty tree,
  giving a second independent guard.
- **Command:** `git worktree remove <path>` (phase `worktrees`).

### 2b. Carrying uncommitted work — DO NOT TOUCH (four, including the primary)

| worktree | branch | uncommitted paths |
|---|---|---|
| **`/home/dam1n19/SoCLabs/tidelink`** | `rescue/primary-worktree-2026-08-10` | **26** — the PRIMARY working tree |
| `/home/dam1n19/SoCLabs/td-bisect/wt-rev2-prep` | `rev2/land-prep` | 26 |
| `/home/dam1n19/SoCLabs/tidelink-consolidated` | `wip/fcsm-collision-consolidated-2026-08-17` | 4 (branch also unmerged) |
| `/home/dam1n19/SoCLabs/td-bisect/baseline-5e8bdb5a` | detached `5e8bdb5a` | 3 |

- **If wrong:** the primary worktree's 26 modified paths are the ASIC-flow
  site-path work in progress. Removing it destroys them and the checkout.
- **Action:** none, ever, by this script. The script skips any worktree with a
  non-empty status and says so by name.

### 2c. Review references to keep — 7

The detached checkouts `td-bisect/kr260-hwval-77d9bcbe-2026-08-18` (the
HW-validated `77d9bcbe` tree), `td-bisect/wt-gate-prefix`, and the five
worktrees the 2026-09 review teams are working in
(`wt-contributing`, `wt-docs-review`, `wt-gate-tooling`, `wt-registry`,
`wt-hygiene`, plus `tidechart-dualroot-2026-09-02/tidelink`).

- **Action:** keep. Revisit after the rev-2 review lands.

---

## 3. Remotes

### 3a. `mainclone` — remove (proved safe)

- **What it is:** `git@`-less filesystem URL
  `/home/dam1n19/SoCLabs/tidelink/deps/tidelink-phy` — a path into a
  **submodule working directory** of the primary worktree. It carries two
  refs, `mainclone/main` (`5c76e764`) and `mainclone/fix/calibrator-wrap-stitch`.
- **Evidence, and a trap:** a naive
  `git rev-list --count mainclone/main --not <origin+heads>` says **114 unique
  commits**, which reads as catastrophic. It is not: those are the *GPIO PHY*
  project's commits, unrelated to TideLink's history, fetched into this
  repository's object store. In the submodule itself,
  `git -C deps/tidelink-phy branch -a --contains 5c76e764` lists
  `remotes/origin/main`, and that origin is
  `git@github.com:SoC-Labs/TideLink-Chiplet-GPIO-PHY.git`. The history is on
  GitHub.
- **If wrong:** PHY history reachable only from this repository would become
  unreferenced. The script therefore re-runs the containment proof against the
  submodule's own remote at execute time and **refuses** if it cannot confirm it.
- **Command:** `git remote remove mainclone` (phase `remotes`).

### 3b. `gitlab` — NOT removed by the script; tag first, then remove by hand

- **What it is:** `git@git.soton.ac.uk:soclabs/tidelink.git`, 17
  remote-tracking refs. `gitlab/main` is **293 commits behind** `origin/main`
  with **0** commits of its own — the request's figure, confirmed.
- **The correction that matters:** "behind" is true of `gitlab/main` only.
  Across all 17 refs, **28 commits are reachable from no other ref** — not from
  origin, not from ethclone, not from any local branch:

  | ref | unique commits | last commit |
  |---|---|---|
  | `gitlab/fix/word-window` | 25 | 2026-06-28 |
  | `gitlab/fix/die-b-pad-clk-rx-bufg` | 7 | 2026-06-24 |
  | `gitlab/exp/v1-route-a` | 3 | 2026-06-23 |
  | `gitlab/ci/regression-flow` | 1 | 2026-06-24 |
  | `gitlab/feat/phy-v2-integration` | 1 | 2026-07-05 |
  | `gitlab/infra/hwlib-ctypes-bus-access` | 1 | 2026-07-09 |

  (The per-ref figures overlap; 28 is the distinct total.)
- **If wrong:** `git remote remove gitlab` drops those refs, and 28 commits —
  including a 25-commit `fix/word-window` line — become unreferenced and are
  collected at the next `git gc`. The abandoned server may or may not still be
  reachable to get them back.
- **Action:** the script **tags them in phase 2 and removes nothing**. Push the
  tags, confirm they are on origin, and only then:
  ```
  git push origin 'refs/tags/archive/2026-09/gitlab_*'
  git remote remove gitlab          # by hand, after confirming the push
  ```

### 3c. `ethclone` — keep; fetch and tag first

`ethclone` is a live sibling checkout
(`/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`), not debris.

**Eight** of its branches are ahead of `origin/main` (the request said four):

| branch | ahead of main | commits found nowhere else |
|---|---|---|
| `ethclone/integ/i1-fcsm-on-proven` | +4 | **4** |
| `ethclone/integ/fix-on-selfarm` | +3 | **3** |
| `ethclone/fix/i1-fcsm-bringup-ethchiplet` | +2 | **2** |
| `ethclone/fix/fifo-stale-probe-rename` | +4 | 0 |
| `ethclone/wip/other-dirty-ethclone-2026-08-17` | +6 | 0 |
| `ethclone/wip/tl042-v2-tests-ethclone-2026-08-17` | +5 | 0 |
| `ethclone/wip/fcsm-collision-ethclone-2026-08-17` | +3 | 0 |
| `ethclone/integ/tidelink-consolidated-2026-08-07` | +1 | 0 |

The five with 0 unique commits are all covered by
`origin/evidence/d2d-wedge-captures-2026-08-19` and
`origin/feat/link-clk-divider`.

**Worth knowing while reading this table:** `32d20a98`
*"site: move the PDK layout out of a public repository"* — the fix for the
still-live public-repo exposure on `origin/main` — sits on five of these
ethclone branches and on four origin branches, and
`git merge-base --is-ancestor 32d20a98 origin/main` returns **NO**. It is
backed up; it is simply not on main. That is a landing decision, not a
cleanup one.

- **Action:** phase 2 tags the three branches carrying unique commits. Do not
  remove the remote.

---

## 4. Tracked junk

### 4a. `scratch_resolved/` — 6 files, 95,013 bytes — remove

A frozen 2026-08-10 merge-resolution staging area
(`docs/STAGE4_RESOLUTION_2026_08_10.md`), pre-computed file contents meant to
be copied into place by hand.

- **Evidence:** no build file of any type references any of the six. The four
  `dut_src*.f` copies are **byte-identical** to the live
  `cocotb/tidelink_a2l_replay_cdc/dut_src*.f`, which the Makefile regenerates
  at every parse anyway. The only references are `cp` instructions in two
  Stage-4 markdown files.
- **If wrong:** a merge resolution someone still intends to apply by hand
  becomes harder to find — recoverable from git history and from the archive
  tag, so the cost is minutes.
- **Note, and it is a real one:** `flists__tidelink_fpga_v2.flist` and
  `flists__tidelink_top_full_asic_v2.flist` are **not** identical to the live
  flists of the same name. They were never applied as-is. Whether they were
  superseded or simply dropped is not answerable from the commit alone — but
  it does not change the removal, because nothing consumes them.
- **Command:** `git rm scratch_resolved/*` (phase `junk`).

### 4b. The inactive `.gitattributes` snippet — leave as is

- **What it is:** `.gitattributes.flist-driver-snippet` (2,487 bytes). There is
  **no** file named `.gitattributes` anywhere in the repository, so the
  snippet's two payload lines (`*.flist merge=flist`, `*.f merge=flist`) are
  inert. Its own header says so.
- **Evidence:** `git check-attr merge -- flists/tidelink_fpga_v2.flist` →
  `merge: unspecified`.
- **Action: none.** It is documentation of an opt-in merge driver, correctly
  named so git ignores it. Deleting it removes a deliberate artefact and gains
  2 KB. Its header's counts *are* stale (it claims 37 `.flist` and 7 `.f`;
  today it is 43 and 13) — see "needs a human decision".

### 4c. The 72 KB root campaign log — **do not move it blindly**

- **What it is:** `BRINGUP_REPORT.md`, 71,945 bytes, 816 lines, last touched
  2026-05-14. The largest tracked file in the root after `Makefile`.
- **The reason this is not a `git mv`:** it is cited by **52 lines across 40
  files**, and **7 of those are RTL sources** —
  `src/rtl/tidelink_phy_align_calibrator.sv`,
  `src/rtl/local_overrides/WavD2DGpioRx.v`,
  `src/rtl/local_overrides/WavD2DGpio.v`,
  `src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv`, plus the
  `pad_skid.sv` copies that cite it by section (`§6`, `§8.1`, `§8.4`), the
  specification, and `uvm/tidelink_top_system/tb/top.sv`.
- **If done wrong:** 52 dangling references in comments that are the only
  written explanation of several PHY design decisions.
- **Action:** moving it to `docs/history/` is reasonable **only together with
  a rewrite of all 52 references**, in one commit, verified by
  `git grep -c 'BRINGUP_REPORT'` before and after. That is a change to RTL
  comment text, so it wants a person. Not in the script.

### 4d. Tracked generated HTML under `docs/` — not in the script

- **What it is:** `docs/bug_registry.html` (82,859 B) and
  `docs/build_registry.html` (81,492 B), generated by
  `scripts/gen_bug_registry_html.py` from the two tracked YAML sources.
- **Why it is not simply removed:** the generator ships a `--check` mode that
  exits non-zero when the HTML is stale, and the page itself embeds
  *"Regenerate with python3 scripts/gen_bug_registry_html.py after any edit"*.
  Untracking the HTML makes that checker check nothing. Either both change
  together, or neither does.
- **Action:** see "needs a human decision".

---

## 5. Orphan flists

The request expected nine. Re-derived count: **11 tracked `.f`/`.flist` files
with no consumer**, of which 6 are the `scratch_resolved/` copies already
covered in §4a. That leaves five standalone, of which **two** are proved safe
to remove and **three** are not.

**A trap worth recording, because it manufactures false orphans:** `lint/` and
`cdc/` reach their flists through a variable —
`FLIST = $(TIDELINK_HOME)/flists/$(MODULE).flist`, driven by
`STANDALONE_MODULES` / `CMSDK_MODULES`. Eleven flists have **no literal
reference anywhere** and are nonetheless consumed on every `make lint-each`.
A basename grep would delete all eleven and break lint.

### Safe to remove — 2

| file | evidence |
|---|---|
| `cocotb/tidelink_axi_datanode_recovery/tidelink_fpga_v2_eccoff.flist` (32,278 B) | **Zero** references tree-wide, in any file type. Its two siblings in the same directory *are* consumed (`Makefile:48`, `:55`); this one is not. Blob-identical to `scratch_resolved/flists__tidelink_fpga_v2.flist`. |
| `cocotb/debug/tidelink_peer_aperture/flist.f` (424 B) | Self-declares inertness in its own header: *"This file is informational; the actual flists used at simulation time are passed via COMPILE_ARGS in the Makefile."* The Makefile duplicates its two `-f` lines inline at `:26,30`. Only other mention is the inactive `.gitattributes` snippet. |

- **If wrong:** a bench loses its source list and fails to elaborate —
  immediate, loud, and one `git revert` away. The script re-greps for each
  basename at execute time and refuses if anything now references it.

### NOT removed — 3, with reasons

- **`flists/tidelink_phy_v2.flist`** — comment-only references, but from **ten
  live flists**, each saying *"The deps copy stays pristine and is still used
  by flists/tidelink_phy_v2.flist"*, and `docs_site/parameters.md` states its
  sources "are not included by any live flist". This is dormant-by-design
  shared-PHY L2 plumbing. The repository has a standing rule about not
  deleting intentionally dormant RTL, and deleting it would make ten comments
  lie.
- **`flists/tidelink_generic.flist`** — cited as the integration example in
  `docs/INTEGRATION_GUIDE.md`, `docs_site/architecture.md` and
  `docs_site/integration.md`. Removing it breaks the published integration guide.
- **`cocotb/crc_diag/tidelink_fpga_v2_prefix.flist`** — `docs/CRC_ROOTCAUSE.md`
  documents it as a manual `V2_FLIST=$PWD/... make` override. Dead by default,
  live when a person reproduces that investigation.

### Inverse finding — dangling, not orphaned

`lint/Makefile` names **seven** modules with no matching tracked flist, so
`make lint-each` fails on each: `tidelink_fifo_ctrl` (:22),
`tidelink_fc_adapter` (:25), `tidelink_phy_align_calibrator` (:33),
`tidelink_ptp` (:34), `tidelink_ptp_servo` (:35), `tidelink_addr_translation`
(:37), `tidelink_addr_translator` (:40). This is a bug, not cleanup — see
"needs a human decision".

---

## 6. The over-broad `.gitignore` globals

### The premise needs one correction

The request says these globals "have already silently eaten a tracked
fixture". On `origin/main` that is **not** currently observable:

```
$ git ls-files | grep -cE '\.(rep|log|xml|map|gz)$'
0
```

Zero tracked files match those five extensions. The eaten fixture is **real**
and the evidence is on a different branch: `rev2/signoff-checkers` `5c5328ef`,
2026-08-26, *"fix(signoff): track the LVS fixtures — .gitignore '*.rep' had
silently eaten them"*, which adds four LVS fixtures plus eight `.gitignore`
negation lines:

```
ci/fixtures/lvs-clean/tidelink_top_lvs.rep
ci/fixtures/lvs-empty/tidelink_top_lvs.rep
ci/fixtures/lvs-missing-connection/tidelink_top_lvs.rep
ci/fixtures/lvs-truncated/tidelink_top_lvs.rep
```

So: the hazard is demonstrated, the fix exists, and **it is not on main**. That
changes the priority — this is not a hypothetical to guard against, it is a
known bite whose remedy is sitting on an unmerged branch.

### What IS tracked-but-ignored on main today — 5 files

`git ls-files | git check-ignore -v --no-index --stdin` (the `--no-index` is
essential; without it, check-ignore consults the index and reports nothing for
tracked paths):

| tracked path | ignoring rule |
|---|---|
| `.claude/workflows/sim_gate_regressions.md` | `.gitignore:20:.claude` |
| `.claude/workflows/tidelink-bug-lifecycle.js` | `.gitignore:20:.claude` |
| **`cdc/tidelink_top.prj`** | **`.gitignore:142:cdc/tidelink_top*`** |
| **`cdc/tidelink_top.sgdc`** | **`.gitignore:142:cdc/tidelink_top*`** |
| `cocotb/tidelink_fcsm_silicon_ratio/tidelink_fpga_v2_fcsm_local.flist` | `cocotb/tidelink_fcsm_silicon_ratio/.gitignore:3` |

The two in bold are the live hazard on main: both are **hand-written SpyGlass
inputs** consumed by `cdc/Makefile:28` (`PRJ := $(TIDELINK_HOME)/cdc/tidelink_top.prj`),
and rule 142 — written to catch *workspace directories* like
`cdc/tidelink_top_new/` — swallows them. **Edits to either file are invisible
to `git add` and to `git status`.** That is the same failure mode as the LVS
fixtures, already present on main, and nobody has been bitten by it yet only
because neither file has needed an edit.

### Proposed scoping — NOT executed, gated on the test below

The globals at `.gitignore:121–135` (`*.gz *.pvl *.done *.svf *.rep *.mr
*.ems *_log *.err *.ndm *.misc *.tluplus *.map *.tdm *.attach`) appear
**fully subsumed** by the anchored `syn/asic/**` rules (`work*/ libs*/ logs*/
reports*/ outputs*/`, lines 37–41 and 251–283). Artifacts genuinely covered
only by an unanchored global are:

| artifact | scoped replacement |
|---|---|
| `cocotb/*/sim.log`, `results.xml`, `waves.vcd` (written in the bench dir, not `sim_build/`) | `cocotb/*/*.log`, `cocotb/*/*.xml`, `cocotb/*/*.vcd` |
| `uvm/*/test.log`, `$(TEST).log` | `uvm/*/*.log` |
| `fpga/ci_logs/**` — a CI artifact path with **no** anchored rule | `fpga/ci_logs/` |
| `syn/asic/design-compiler/dc_*.log` (the local rule matches `*_dc.log`, not the `dc_` prefix) | `syn/asic/design-compiler/dc_*.log` |
| `syn/asic/dft/out/*.log`, `*.rep` (DFT writes to `out/`, but has only `logs*/ reports*/` rules) | `syn/asic/dft/out/` |
| root-level `f14a_run.log`, `fc_flow.log`, `vcs_*elab.log`, `lec.log` | `/*.log` (anchored) |

**Sequencing matters.** `.gitignore:243–249` records that this repository is
public and that two prior disclosures came from unignored run directories.
Narrowing the globals therefore goes **after** the anchored coverage is in
place, never before, and never in the same commit.

### The required test — write it before touching `.gitignore`

Add `scripts/ci/tests/test_gitignore_fixtures.sh`, in the shape of
`scripts/ci/tests/test_site_check.sh`:

1. For **every currently tracked path**, assert
   `git check-ignore -q --no-index <path>` returns non-zero — i.e. a fresh
   `git add` would still see it. Today that fails on the five files above;
   land it with those five as a named, shrinking exception list, so the
   list can only get shorter.
2. Assert the reverse for each scoped rule: a representative *generated*
   path (`cocotb/tidelink_top/sim.log`, `fpga/ci_logs/x.log`, …) **is**
   ignored. Without this half the test passes trivially by deleting rules.
3. Prove it can fail: seed a tracked fixture that a rule swallows, and
   assert red. Same reason as case 2 of `test_site_check.sh`.

Only once that test is green on both halves should the globals be narrowed.

---

## Needs a human decision

Everything below is deliberately **not** in the script.

1. **The two local-only unmerged tips** (§1c) — `fix/tidechart-dualroot-timeout-tooling`
   `b32d4b5b` and `worktree-agent-ac06dd75b70af4bbf` `86c7a0a3`. Push the
   branches, push only archive tags, or accept single-host risk? The script
   tags them and stops.
2. **Removing the `gitlab` remote** (§3b) — 28 commits, including a 25-commit
   `fix/word-window` line, exist nowhere else. Are they worth pushing to
   origin as archive tags, or is the abandoned server an acceptable
   last-resort copy?
3. **`BRINGUP_REPORT.md`** (§4c) — moving it means rewriting 52 references in
   40 files, 7 of them RTL sources. Move with the rewrite, or leave it in the
   root?
4. **The tracked registry HTML** (§4d) — untrack it and drop
   `gen_bug_registry_html.py --check` from CI, keep both, or move generation
   into CI and publish the HTML as an artifact? The current state is at least
   self-checking; removing half of it is strictly worse.
5. **The three "orphan" flists that are not orphans** (§5) —
   `flists/tidelink_phy_v2.flist` (dormant by design, ten comments assert it
   is live), `flists/tidelink_generic.flist` (published integration guide),
   `cocotb/crc_diag/tidelink_fpga_v2_prefix.flist` (documented manual
   override). Each needs an owner's call, not a grep.
6. **The seven dangling `lint/Makefile` modules** (§5) — is `make lint-each`
   expected to fail on them, or are seven flists missing? This is a bug
   report, not cleanup.
7. **`cdc/tidelink_top.prj` and `.sgdc` being invisible to `git add`** (§6) —
   a one-line `.gitignore` negation fixes it, but rule 142's intent should be
   confirmed with whoever wrote it before it is narrowed.
8. **Landing `rev2/signoff-checkers`' `.gitignore` negations** (§6) — the LVS
   fixture fix already exists on an unmerged branch. Cherry-pick it to main
   now, or wait for the whole rev-2 line?
9. **Scope of `make site-check`** — it scans tracked *build* files
   (Makefile, `.mk`, `.sh`, `.tcl`, `.py`, `.pl`). Three classes sit outside
   that scope and are worth a decision, because this repository is public:
   - the two YAML registries (`docs/BUILD_REGISTRY.yaml`,
     `docs/BUG_REGISTRY.yaml`) carry 13 absolute `/home/...` paths recording
     where past bitstreams physically lived — historical facts about a past
     run, not settings anything resolves;
   - **nine `fpga/targets/*/pynq_z2_tidelink.xdc` and `ribbon_wiring.md`**
     name a Vivado board-file path (`.../data/boards/pynq-z2/A.0/part0_pins.xml`)
     as pin-mapping provenance. `.xdc` is arguably a build file and could be
     brought into scope cheaply;
   - `docs/reference/DEPENDENCIES.md` and `docs_site/integration.md` still
     spell the Arm release-coded drop name in prose — the same disclosure
     class the Makefiles were cleaned of, in published documentation.
10. **`uvm/tidelink_ptp_chain` and `uvm/tidelink_ptp_stress`** set
    `PHC_DIR ?= $(HOME)/SoCLabs/ptp-hardware-clock-ahb/src/rtl`. `$(HOME)` is
    not a site path, so `site-check` does not flag it, but it does assume one
    sibling-checkout layout. Promote to a `PHC_HOME` site variable, or leave?
11. **Agent scratchpad paths in tracked scripts** — several `imp/hw_gate/*.sh`
    and `pynq_host/scripts/*.sh` hard-code `/tmpdir/claude-*/scratchpad` output
    directories. Harmless, but they are one session's temp path committed to a
    public repository.
12. **The stale counts in `.gitattributes.flist-driver-snippet`** (§4b) — its
    header claims 37 `.flist` and 7 `.f`; today it is 43 and 13. Update, or
    delete the snippet?

---

## What running the dry run actually showed

The dry run was executed against this repository on 2026-09-11 and found two
bugs in the script, both now fixed:

- Phase 6's re-proof grepped for each filename across the tree and matched
  **the script's own list**, so all eight removals were refused. A guard that
  refuses everything is as useless as one that refuses nothing; the grep now
  excludes the script and this document.
- Phase 4's skips read as permanent when they are an artefact of phase 3
  removing nothing in a dry run. It now says so.

It also confirmed the inertness claim rather than asserting it: tag, branch,
worktree and remote counts were `145 / 41 / 24 / 4` before the dry run and
`145 / 41 / 24 / 4` after it. And the phase-6 re-proof was shown to be able
to refuse — a reference to one of the eight was added to a live flist, and
that file was correctly refused while the other seven still cleared.

## Suggested order

1. Land `chore/site-path-hygiene` (site paths + `make site-check`).
2. Write and land `test_gitignore_fixtures.sh` (§6) — red is fine and expected.
3. Fix the two `cdc/tidelink_top.*` ignore rules; watch the test go green.
4. Run `cleanup_2026_09.sh` with **no** flag. Read the output.
5. Run it with `--execute`. Phases 1 and 2 tag; 3 and 4 delete; 5 removes
   `mainclone`; 6 untracks eight files.
   Note when reading the dry run: phase 3 removes no worktrees, so phase 4
   still reports the nine branches checked out in one as skipped. Under
   `--execute` those worktrees are gone by the time phase 4 runs and the
   same branches are tagged and deleted. The script says this in its output.
6. Push the archive tags. Confirm they are on origin.
7. Only then decide items 1–12 above.

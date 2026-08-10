# TideLink Branch Consolidation — Judgement and Definitive Runbook

**Date:** 2026-08-10
**Author:** consolidation strategy review (agent), for David Mapstone
**Status:** PLAN — not executed. Contains steps marked `[DECISION — David]` that must not be run without sign-off.

---

## 0. Verdict in one paragraph

**Adopt Strategy A (promote the consolidated branch, union-first, delete-last), with two grafts from B and three from C.**

The decision is forced by one measured fact: `main @18491ef` is a **strict ancestor** of `integ/tidelink-consolidated-2026-08-07 @1037a63` (0 behind / 95 ahead, verified). Promotion is therefore a **fast-forward**, and `git push origin main` is a **fast-forward too** — `origin/main` is byte-identical to local main. No force-push of a published ref is required anywhere in Strategy A. Strategy B, by contrast, *requires* a force-update of `origin/main` and breaks every downstream SHA pin, in exchange for removing a hazard (`b98b944`) whose blame the project itself formally retracted in `ee15dfd`. That is a bad trade. Strategy C pays Strategy A's costs almost exactly and saves only the per-branch adjudication that the containment audit has already completed — but its blunt mechanical archival is genuinely better than A's selective tagging, and is grafted in.

---

## 1. Scoring the three strategies

Scores are 1–5, higher is better.

| Criterion | A — Promote consolidated | B — Curated rebuild on `f730ab1` | C — Snapshot-and-collapse |
|---|---|---|---|
| **1. Risk of losing work** | **5** | **2** | **4** |
| **2. Effort / wall-clock** | **4** | **1** | **4** |
| **3. History quality for tapeout audit** | **5** | **2** | **3** |
| **4. Discharges the risk register** | **3** | **4** | **1** |
| **5. Speed to unblock one pushable trunk** | **5** | **1** | **4** |
| **Total** | **22** | **10** | **16** |

### 1.1 Risk of losing work

All three plans open with the same replication step, so the differentiator is what happens *after*.

- **A (5).** Every irreversible act is preceded by a replication step. The residue is bounded and measured: exactly **4 branches hold 21 files absent from the trunk** (verified by `git diff --diff-filter=A --name-only`), and none is shipping RTL. Nothing is deleted until it exists in two places.
- **B (2).** ~110 cherry-picks with ~15 conflict resolutions, roughly 30 of them touching the backslash-continued `sim_gate` aggregate in the `Makefile`, where **a dropped suite name is a silent de-gate with no compile error**. This repo has already shipped two false-green bugs in that exact file. B also force-updates `main`, breaking the live eth-chiplet pin `235d758`, which `git branch --contains` shows exists on exactly one branch and no tag. B's loss risk is not the *content* — it is the fidelity of 110 hand-resolutions plus the pin breakage.
- **C (4).** Low content risk for the same reason as A, but the blunt collapse discards branch-level intent wholesale, and its own text concedes the rescue commits are unbisectable.

### 1.2 Effort / wall-clock

- **A (4):** ~2–3 focused engineer-days plus one full `sim_gate` run and two signatures.
- **B (1):** 4–6 focused days *if* the cross-repo pin blocker is fixed first — and B's own risk register concedes the honest comparison: *"That is achievable in one commit on top of a fast-forward, at ~2 hours instead of ~5 days."* B costs roughly two orders of magnitude more than A for zero recovered bytes.
- **C (4):** ~2–3 days. C correctly observes it pays A's Phase 0/1/3 costs and saves only the branch adjudication.

### 1.3 History quality for a tapeout audit trail

This is where B loses decisively and it is worth being explicit, because "linear history is cleaner" is a seductive and wrong instinct here.

- **A (5).** Preserves the three merge commits (`58ea4a6`, `0a427fb`, `1107151`). **Those merges are themselves the evidence that the 2026-07-30 "cherry-pick, do not rebase" discipline was honoured.** A linear trunk cannot show that. Every SHA cited in `docs/BUG_REGISTRY.yaml`, `docs/OVERNIGHT_SUMMARY_2026_08_07.md`, `docs/SIGNOFF_ROADMAP_2026_08_07.md` and `docs/I1_SELFARM_REGRESSION.md` stays reachable from the trunk.
- **B (2).** Every SHA in `main..consolidated` is rewritten. `63222b6` (the TL-006 A1 gating evidence), `43b5845`, `2415766` resolve only through archive tags. `git bisect` across the old line stops working, and because ~15 conflicts were hand-resolved the rebuilt commits are not byte-identical trees, so a bisect result on the old line does not transfer. **A tapeout bug registry whose evidence chain runs through tags rather than reachable branch history is materially weaker**, and B's own "LOSES" section says so.
- **C (3).** Keeps the 95 commits (its author correctly rejects the naive squash), so the fix-level history survives; loses branch intent to tag messages.

### 1.4 How well it discharges the risk register

This is B's **only** genuine win, and it is real.

- **B (4).** B is the only strategy that *forces* re-adjudication of the two netlist-affecting decisions rather than letting them ride in as inherited defaults: the `SOCL_L7_MIN_CRACK_EMITS` 32→8 default, and the FPGA-vs-ASIC flist split.
- **A (3).** Surfaces and pins both but defers them.
- **C (1).** Explicitly freezes both as trunk defaults with nobody's signature. Its own text: *"An auditor asking 'who signed this?' gets the answer 'nobody — it was inherited.'"*

**This is the graft.** B's advantage is obtainable without B's cost: land the two decisions as separate signed commits *on top of the fast-forwarded trunk*. That is Stage 5 below, and it converts A's weakest score into B's strongest at a cost of about two hours.

### 1.5 Speed to unblock

A is a fast-forward: once the prerequisites are met, promotion is one command. B cannot reach a green gate at any checkpoint until the cross-repo pin blocker is fixed, making its inter-stage gating — its central quality claim — aspirational.

### 1.6 Why the "hazard-free base" argument does not save Strategy B

B's entire justification is that rooting at `f730ab1` (verified: `git rev-parse b98b944^` = `f730ab1`) structurally excludes `b98b944`. Three facts defeat it:

1. **The blame was retracted.** `ee15dfd` root-causes `role_locked=0` as *not* the FCSM override. Silicon on 2026-07-31 reached `fcsm=4`, 6/6 byte-exact on both KR260 dies **with** the recovery FCSM in the netlist. The real causes were `SELF_ARM_TRAIN_EN` (bootstrap) and FIX-E (training-release) — both present on the trunk.
2. **The tapeout netlist was never exposed.** Verified on the trunk: `flists/tidelink_top_full_asic_v2.flist` lines 290–295 resolve FCSM 0–4 (and `_5`) to `deps/axi-chiplet-controller/...`; only `WlinkGenericFCSM_6.v` comes from `local_overrides`. `6e3b25d` walked the ASIC half back eleven minutes after `b98b944` landed.
3. **B does not actually remove the live half.** B's own Split B re-lands the FPGA-V2 re-point anyway — the surviving half, on the path eth-chiplet bring-up runs. So B pays five days and a force-push to arrive at the same FPGA exposure the trunk already has.

B is optimising against folklore the project has already overturned. Keep the standing *discipline* (cherry-pick, don't rebase); retire the specific *rule* about `b98b944`.

### 1.7 What is grafted from the runners-up

| From | Graft | Where |
|---|---|---|
| **B** | Land the CRACK-gate and flist-matrix decisions as separate **signed** commits on the trunk, not as inherited defaults | Stage 5 |
| **B** | Pin `TIDECHART_HOME` / `CHIPLET_HOME` as a **prerequisite**, not a stage — the gate cannot go green without it | Stage 5.4 |
| **C** | **Mechanical** tag-everything archival from `git for-each-ref`, no per-branch adjudication, annotated so the tag object carries the provenance the branch name loses | Stage 8.1 |
| **C** | `archive/.../cited/*` tags for SHAs cited by the trunk's own tapeout docs | Stage 8.2 |
| **C** | "Commit, never `git stash`" — the 24 `archive/2026-07-cleanup/stash-NN` tags are the fossil record of what stashing cost last time | Stage 2 |

---

## 2. Verified ground truth

Everything in this table was re-measured in this session. Where it contradicts the task brief or a strategy document, the measurement wins.

| Claim | Verdict | Evidence |
|---|---|---|
| `main` is a strict ancestor of the trunk | **TRUE** | `git merge-base --is-ancestor main <trunk>` → 0; `rev-list --left-right --count` → `0  95` |
| 26 local branches (not 22–24) | **TRUE** | `git for-each-ref refs/heads/ \| wc -l` → 26 |
| 15 worktrees, 7 dirty | **TRUE** | 40 / 24 / 15 / 3 / 3 / 2 / 1 entries |
| Off-repo line `28409f5` exists and is absent here | **TRUE** | `git cat-file -t 28409f5` → *"Not a valid object name"*; the sibling clone is on `integ/tidelink-consolidated-2026-08-09`, **6 ahead / 0 behind** `origin/…-08-07` |
| Trunk's a2l overrides are one fix short | **TRUE** | trunk blob `ecf242a` has **0** `TL-032` hits; theirs `8a1faba` has **3**; `8104b1e` reads `index ecf242a..8a1faba` — our blob is literally the parent |
| Exactly 4 branches hold residue (21 files) | **TRUE** | `--diff-filter=A` sweep: gate-plan 10, i1-selfarm 9, unit-regression 1, sync-clock-gate 1 |
| "137 local-only tags, none pushed" | **FALSE** | origin has **57**, gitlab **104**; **19** tags are absent from *both* — all under `archive/i1/*` and `archive/pad-clockgate/*` |
| `v2026.07.16-chiplet-verified` is unpushed | **FALSE** | present on origin |
| "Nothing pushed in ~2.5 weeks" | **FALSE for origin** | `origin/main` == local main exactly; `origin/…-08-07 @3f037c0`; **only `1037a63` is local-only** |
| Gate is green on the trunk | **FALSE** | 55 status files, **all** stamped `3f037c04e725-dirty`; 50 PASS / 3 XFAIL / **2 FAIL** (`tc_pair_smoke`, `tc_pair_election_datamode`) |
| There are 4 submodules | **FALSE** | `.gitmodules` lists **3**; `deps/xhb500` is mode `040000` (a vendored **tree**). The brief was right; CP-09's "correction" was wrong |
| Submodule dirt is lost work | **FALSE** | `deps/axi-chiplet-controller` pin == HEAD == `efe5623c`; the dirt is one **deleted committed VCD** (`wav-wlink-hw/verif/dump.vcd`, 81,095,238 lines). Benign |
| CRACK-gate asymmetry is real | **TRUE** | trunk: `SOCL_L6_MIN_CR_EMITS = 8'd32` hardcoded, `` `define SOCL_L7_MIN_CRACK_EMITS_VAL 8 `` |
| Checkout of trunk in primary worktree will abort | **TRUE** | 5 colliding untracked paths; 4 byte-identical, 1 **different**: `docs/BUG_REGISTRY.yaml` (local **651** lines vs trunk **1221**) |

### 2.1 One correction that changes Stage 0 in all three strategies

**`git bundle create --all` does NOT capture uncommitted work.** All three strategies open with a bundle and treat it as "the rollback for the entire operation." It is not — it is a rollback for the *object graph only*. At this moment roughly 4,000+ lines of source exist **only** as working-tree state across 7 dirty worktrees, and a bundle taken now would not contain a byte of it.

Stage 0 therefore begins with a **raw filesystem archive**, before any git operation. That is the only step that is agnostic to git state.

---

## 3. The runbook

**Conventions**

- `$TL` = `/home/dam1n19/SoCLabs/tidelink` (primary worktree, hosts the real `.git`)
- `$TRUNK` = `integ/tidelink-consolidated-2026-08-07`
- `$BK` = `/home/dam1n19/backup/tidelink-consolidation-2026-08-10` (create on a **different filesystem** if one is available)
- 🔴 **DESTRUCTIVE / IRREVERSIBLE** — marked inline, and every one is also `[DECISION — David]`
- Each stage ends with a **VERIFY**. **A failed VERIFY means STOP.** Do not proceed, do not improvise, do not delete anything.

---

### STAGE 0 — PRESERVE WHAT IS NOT IN GIT

*Nothing here is destructive. Every step is additive. Do not skip any of it — this is the only stage that converts single-copy state into replicated state.*

**0.1 — Quiesce the concurrent agent fleet.** `[DECISION — David]` A second fleet is writing `docs_site/`, `.readthedocs.yaml`, `docs/BUILD_REGISTRY.yaml` into the primary tree, and the trunk's own worktree is being written too. Stop it, or coordinate a freeze window. Any diff taken mid-flight is a torn read and every subsequent measurement inherits the error.

**0.2 — Confirm the trees are actually still.**

```bash
cd $TL
for w in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
  echo "$(git -C "$w" status --porcelain | wc -l)  $w"
done | sort -rn | tee /tmp/wt-census-1.txt
sleep 60
# ... repeat into /tmp/wt-census-2.txt
diff /tmp/wt-census-1.txt /tmp/wt-census-2.txt
```

**VERIFY:** `diff` is empty. Expected census: `40 / 24 / 15 / 3 / 3 / 2 / 1` and eight zeros. If the counts move, the fleet is still running — return to 0.1.

**0.3 — RAW ARCHIVE FIRST (the step a bundle cannot do).**

```bash
mkdir -p $BK
tar --exclude-vcs-ignores \
    -czf $BK/worktrees-raw-$(date +%F).tar.gz \
    /home/dam1n19/SoCLabs/tidelink \
    /home/dam1n19/SoCLabs/tidelink-consolidated \
    /home/dam1n19/SoCLabs/tidelink-link-survey-2026-08-01 \
    /home/dam1n19/SoCLabs/tidelink-i1fix-confirm \
    /home/dam1n19/SoCLabs/tidelink-throughput-overnight \
    /home/dam1n19/SoCLabs/tidelink-wip-testrepoint \
    /home/dam1n19/SoCLabs/tidelink-fixe
```

Do **not** exclude `.git`. This archive is the only artifact that survives a mistake in Stages 2–3.

**VERIFY:**

```bash
tar -tzf $BK/worktrees-raw-$(date +%F).tar.gz | grep -c 'tidelink-consolidated/fpga/vivado_ip/tidelink_vivado_wrapper.v'  # must be 1
tar -tzf $BK/worktrees-raw-$(date +%F).tar.gz | grep -c 'scripts/gen_bug_registry_html.py'                                   # must be >= 1
```

**0.4 — Record the submodule state explicitly.**

```bash
git submodule status | tee $BK/submodule-pins.txt
git -C deps/axi-chiplet-controller status --porcelain
git -C deps/axi-chiplet-controller diff --stat | tail -3
```

**VERIFY:** the pin equals HEAD for all three (`efe5623c` / `6ee8418b` / `5c76e764`), and the only dirt is `D wav-wlink-hw/verif/dump.vcd`. **Measured today: this is benign** — a deleted committed waveform, not source. If anything *else* appears, STOP: that is uncommitted submodule source, invisible to every branch, and it must be committed inside the submodule before proceeding.

**0.5 — Push the 19 genuinely single-copy tags.** Additive, non-destructive.

```bash
git push origin --tags
```

**VERIFY:**

```bash
comm -23 <(git tag | sort -u) \
         <(git ls-remote --tags origin | grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -u)
```

must be **EMPTY**. The 19 at risk are all `archive/i1/*` (16) and `archive/pad-clockgate/*` (3). Among them `archive/i1/strategy-i1-rolelock → ee15dfd` is the **only** reference keeping `docs/I1_ROLELOCK_ROOTCAUSE_FIX.md` alive — `git branch --contains ee15dfd` is empty — and that is the document refuting the `b98b944` rule. A `git gc --prune` before this push destroys it.

**0.6 — Push the one local-only trunk commit.**

```bash
git push origin $TRUNK
```

**VERIFY:** `git ls-remote origin $TRUNK` → `1037a63b6e8da042f31f62ae1e2950908beeef06`.

---

### STAGE 1 — CAPTURE THE OFF-REPO LINE

*The single largest data-loss exposure in the whole operation, and invisible to any branch-level analysis of this repo.*

**1.1 — Fetch it.**

```bash
git fetch /home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink \
          'refs/heads/*:refs/remotes/ethclone/*'
```

**VERIFY:** `git cat-file -t 28409f5` prints `commit` (it currently **fails**), and
`git rev-list --count 3f037c0..ethclone/integ/tidelink-consolidated-2026-08-09` prints `6`.

**1.2 — Replicate it to origin.**

```bash
git push origin ethclone/integ/tidelink-consolidated-2026-08-09:refs/heads/integ/tidelink-consolidated-2026-08-09
```

**VERIFY:** `git ls-remote origin | grep 2026-08-09` → `28409f5…`. Until this succeeds, ~8,570 lines including the TL-032 a2l port exist on exactly one filesystem, in a clone nobody is watching. **One `git checkout` there destroys them.**

**1.3 — Bundle now that the graph is complete.**

```bash
git bundle create $BK/objects-$(date +%F).bundle --all
git bundle verify $BK/objects-$(date +%F).bundle
```

**VERIFY:** `verify` exits 0 and `git bundle list-heads … | wc -l` ≥ 163.

---

### STAGE 2 — DRAIN THE DIRTY WORKTREES

*Rule for the whole stage: **commit, never `git stash`.** The 24 `archive/2026-07-cleanup/stash-NN` tags are the fossil record of what stashing cost in the 2026-07-24 collapse. Second rule: **stage by name, never `git add -A` on a directory** — a blanket `git add <dir>` swept an unrelated fix in last time.*

**2.1 — Drain the TRUNK's own worktree first (24 entries).** `/home/dam1n19/SoCLabs/tidelink-consolidated`. Commit onto **`$TRUNK` itself**, not a rescue branch, so the promoted commit is what was actually tested there. It holds the **AUTO_ANCHOR_EN wrapper surfacing** — the 08-09 all-zeros root-cause fix — which appears under `fpga/` on **zero** of the 26 branches. Include all four files, not three:

- `fpga/vivado_ip/tidelink_vivado_wrapper.v` (param at :222, pass-down at :583)
- `fpga/targets/kr260-pair-nptp/tidelink_design.tcl` (`CONFIG.AUTO_ANCHOR_EN {1'b1}`)
- `fpga/targets/kr260-pair-flip-nptp/tidelink_design.tcl`
- `fpga/targets/kr260-pair-nptp/kr260_tidelink_timing.xdc` (+60 lines — **easily missed**)

…plus the TL-033 red/green harness, `cocotb/tidelink_autoneg_deadi2c/`, three `a2l_replay_cdc` flists, two `axi_datanode_recovery` flists, `docs/handoff/`.

**2.2 — Resolve the moved `deps/tidelink-phy` gitlink.** `[DECISION — David]` That worktree shows `M deps/tidelink-phy`. Inspect and decide:

```bash
git -C /home/dam1n19/SoCLabs/tidelink-consolidated diff deps/tidelink-phy
git -C deps/tidelink-phy log --oneline 5c76e76..HEAD
```

Either commit the new pin **with a written reason**, or restore it. **Do not promote a trunk with a floating gitlink.**

**VERIFY:** `git ls-tree $TRUNK deps/` shows exactly **3** gitlinks (mode `160000`) plus `deps/xhb500` as mode `040000`.

**2.3 — Drain the primary worktree (40 entries) to a rescue branch.** Capture before judgement:

```bash
git -C $TL checkout -b rescue/primary-worktree-2026-08-10
git -C $TL add -A && git -C $TL commit -m 'rescue: primary worktree snapshot before consolidation'
```

Commit everything unfiltered. This branch is a **capture, never a merge source** — its tracked RTL is *behind* the trunk (`wr_hold_r` appears 7× on the trunk and 0× here; the dirty `dft_wrapper` sets `DEBUG_UNLOCK_DEFAULT=1'b1`, reverting the `749a271` tapeout lock).

**VERIFY** — all must print OK:

```bash
for p in .gitlab-ci.yml uvm/tidelink_top_system/Makefile uvm/tidelink_ptp_chain/Makefile \
         uvm/tidelink_ptp_stress/Makefile uvm/tidelink_top_system/tb/top.sv \
         docs/SIM_GATE_COVERAGE.md docs/VERIFICATION_PLAN.md docs/HANDOVER_Z2_PICKUP_2026_07_30.md \
         pynq_host/throughput_gui/agent/tl_perf_agent.py scripts/gen_bug_registry_html.py \
         scripts/serve_bug_registry.py docs/VERIFICATION_AUDIT_2026_07_30.md; do
  git cat-file -e rescue/primary-worktree-2026-08-10:$p && echo "OK $p" || echo "MISSING $p"
done
```

`uvm/tidelink_top_system/Makefile` is the load-bearing one: 646 lines vs the trunk's 471, and the 244-line delta **is** the UPIMI compile-blocker fix.

**2.4 — Drain the remaining 5, largest first.** `rescue/<worktree>-2026-08-10` each.

| Worktree | Entries | Note |
|---|---|---|
| `tidelink-link-survey-2026-08-01` | 15 | **Sole copy** of `cocotb/tidelink_fifo_concurrent_race/` + 4 modified core datapath RTL files. Its twin at the same tip `376cc50` is clean, so this dirt exists nowhere else. **Tag-and-park — do NOT merge this RTL into the trunk without review;** it bears on the still-unrootcaused concurrent drain corruption. |
| `tidelink-i1fix-confirm` | 3 | 3 untracked throughput tests |
| `tidelink-throughput-overnight` | 3 | byte-duplicated in i1fix-confirm — discardable, but commit anyway; it costs nothing |
| `tidelink-wip-testrepoint` | 2 | 2 modified |
| `tidelink-fixe` | 1 | `deps/xhb500/generated` build residue only — discardable |

**2.5 — STAGE 2 GATE.**

```bash
for w in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
  n=$(git -C "$w" status --porcelain | wc -l)
  [ "$n" -ne 0 ] && echo "STILL DIRTY: $w ($n)"
done
```

**VERIFY:** prints **nothing**. Nothing moves until this is silent.

---

### STAGE 3 — FOLD THE 21-FILE RESIDUE

*Measured, complete, and bounded: exactly 4 branches, 21 files, zero shipping RTL.*

**Methodological rule for this stage:** every decision is gated on `git diff --diff-filter=A --name-only` (paths the branch has that the trunk lacks). **Do not use `git cherry`** — 9 branches read `+` here while carrying zero unique content. And note `--diff-filter=D` lists the *opposite* set; it is the natural mistake.

**3.1 — `integ/gate-plan-2026-07-30` (10 files, 1798 lines, 100% docs).**

```bash
git merge --no-ff integ/gate-plan-2026-07-30
```

`merge-tree` simulates CLEAN. `08_bughunt.md` is the report that found the P1 txgen-in-tapeout defect whose *fix* shipped as `11cada5`/`8a7599e` while the justifying analysis did not.

**3.2 — `feat/unit-regression-from-ethchiplet` (1 file).**

```bash
git cherry-pick 5eff33a
```

`cocotb/tidelink_apb_regs/test_perf_cong_state_decode.py`, 189 lines — the only regression covering the `PERF_CONG_STATE 0x20F8` APB **READ** aperture and field layout. The trunk's `test_perf_region_decode.py:140` covers only the **WRITE**-phase addressing seam. **Wire it into the `sim_gate` suite list.**

**3.3 — `fix/v2-sync-clock-gate` (1 doc).**

```bash
git cherry-pick ac643c8 88e867b
```

`docs/HANDOVER_SYNC_CLOCK_GATE_2026_07_29.md`, 296 lines, recording the empirical **negative** result that the "obvious" unconditional pad clock-gate fix **breaks** Z2 bring-up. **SKIP** `c8d0e5f` and `2415766` — a fix/revert pair, net-zero (`WavD2DGpio_v2.v` is byte-identical to the trunk).

**3.4 — `test/i1-selfarm-regression` (9 files).** `[DECISION — David]` — **resolve before picking.**

The trunk states at `uvm/tidelink_top_system/env/tidelink_top_system_pkg.sv:124-128` that these tests are *"intentionally NOT pulled into this integration branch."* But the trunk **also took the Makefile half** of `9d7992e`: `uvm/tidelink_top_system/Makefile:441` seds the flist to `$(CURDIR)/i1fix_fcsm/`, and `git ls-tree -r $TRUNK uvm/tidelink_top_system/i1fix_fcsm/` is **EMPTY**. So `make FCSM_SRC=fix` today generates a filelist of non-existent files.

The current state is broken either way. Two valid resolutions — pick one, do not leave it half-absorbed:

- **(a)** `git cherry-pick 9d7992e 44b0670` — restores the files and closes the dangling rule. **SKIP** `43b5845` (patch-dup, `git cherry` marks `-`) and `ca495c4` (already byte-identical).
- **(b)** Delete the dangling `dut_fcsm_fix.flist` rule from the trunk's Makefile.

Picking a direction without sign-off substitutes an agent's judgement for a recorded engineering decision.

**3.5 — Salvage the orphan doc.**

```bash
git checkout archive/i1/strategy-i1-rolelock -- docs/I1_ROLELOCK_ROOTCAUSE_FIX.md
git commit -m 'docs(i1): salvage rolelock root-cause from tag-only reachability (ee15dfd)'
```

`ee15dfd` is reachable from **no branch at all**. A tag is not a durable home for the 174-line document that overturns the rule currently gating branch strategy.

**3.6 — STAGE 3 GATE (load-bearing).**

```bash
T=$TRUNK
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  [ "$b" = "$T" ] && continue
  n=$(git diff --diff-filter=A --name-only $T $b | wc -l)
  [ "$n" -gt 0 ] && echo "RESIDUE $b : $n"
done
```

**VERIFY:** prints **NOTHING** (or only the branch deliberately deferred by decision 3.4b, recorded in writing).

---

### STAGE 4 — MERGE THE 08-09 LINE

*Mandatory, not optional: it is both the largest data-loss exposure and a functional correctness fix.*

**4.1 — Size the conflict first.**

```bash
git merge-tree --write-tree --messages $TRUNK ethclone/integ/tidelink-consolidated-2026-08-09
```

**4.2 — Merge.**

```bash
git merge ethclone/integ/tidelink-consolidated-2026-08-09
```

Expected conflict surface: the two flists where both sides independently made the **same** decision (re-point a2l replay nodes `_1/_3/_5` from `deps` to `local_overrides`) — the conflict is textual, not semantic. Their commit `b0e9334` ("lint: explicit widths and signedness across the RTL") is a whole-tree sweep and is the largest surface; because we are **merging** rather than replaying, it resolves once rather than against every RTL commit — this is precisely where Strategy B's cherry-pick discipline would have been actively worse.

**4.3 — Resolve both flists toward THEIRS (the 08-09 side)**, which carries the richer rationale including the tapeout note (*"port-byte-identical to deps → ASIC-safe drop-in, LEC boundary unchanged"*).

**4.4 — VERIFY the functional payoff** (this is *why* the merge is mandatory):

```bash
git show HEAD:src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v | grep -c 'TL-032'   # must be >= 1 (was 0)
grep -c 'local_overrides/WlinkGenericFCReplayV2' flists/tidelink_fpga_v2.flist        # must be 3
grep -c 'local_overrides/WlinkGenericFCReplayV2' flists/tidelink_top_full_asic_v2.flist  # must be 3
```

**Measured today:** the trunk's `_1` blob is `ecf242a` with **0** TL-032 hits; theirs is `8a1faba` with **3**; and `8104b1e` reads `index ecf242a..8a1faba` — our blob is literally the parent of theirs. Without this merge, `1037a63` points the shipping FPGA and ASIC-V2 flists at overrides **one fix short** of what the eth-chiplet is actually running.

**4.5 — Re-bundle and push before gating.**

```bash
git bundle create $BK/merged-$(date +%F).bundle --all
git push origin $TRUNK
```

---

### STAGE 5 — THE TWO SIGNED DECISIONS *(the graft from Strategy B)*

*This is where Strategy A's weakest score becomes Strategy B's strongest, at ~2 hours instead of ~5 days. These are netlist-affecting and must not ride in as inherited defaults.*

**5.1 — `[DECISION — David]` The CRACK gate: `SOCL_L7_MIN_CRACK_EMITS` 32 vs 8.**

Measured on the trunk:

```
localparam [7:0]  SOCL_L6_MIN_CR_EMITS    = 8'd32;     // sibling gate, untouched
`ifndef SOCL_L7_MIN_CRACK_EMITS_VAL
 `define SOCL_L7_MIN_CRACK_EMITS_VAL 8                 // b98b944 lowered 32 -> 8
```

The evidence is genuinely contradictory:

- There is **no `+define+SOCL_L7_MIN_CRACK_EMITS_VAL` anywhere in the build** outside `cocotb/tidelink_fcsm_silicon_ratio/Makefile:64` — so **8 is what every FPGA and ASIC build actually compiles**.
- The bench that justified 8 was subsequently **disowned** (it never modelled the `swi_training_mode` hold and reproduced a different failure from silicon's `cr_seen=0`).
- The one recorded silicon **LINK-UP** is logged at `gate=32`; the `gate=8` build is logged **LINK DOWN**.
- The sibling gate `SOCL_L6_MIN_CR_EMITS` was left at 32, so the two are now inconsistent with **no evidence for the asymmetry**.

Land the decision as its own commit whose message records the contradiction. Keep the `` `ifndef `` hook either way so the bench can still drive 8.

**5.2 — `[DECISION — David]` The FPGA-vs-ASIC flist matrix.**

Measured on the trunk: `flists/tidelink_top_full_asic_v2.flist:290-295` resolves FCSM 0–4 (and `_5`) to `deps/…` (recovery-**stripped**); only `WlinkGenericFCSM_6.v` comes from `local_overrides`. `flists/tidelink_fpga_v2.flist` resolves them to `local_overrides` (recovery present). That is `6e3b25d`'s "hold pending silicon ILA," still in force **12 days** later.

**Every hardware proof this project has** — KR260 bring-up, the 30,500-packet soak, 6/6 byte-exact D2D — is on the **FPGA** netlist. The tapeout netlist is a different design carrying none of it. Produce an explicit 3-column table (`fpga_v2` / `asic` / `asic_v2`) for FCSM 0–4, `WlinkEccSyndrome`, the a2l replay nodes and `WlinkRxLinkLayer`; get a signed decision **per row**; record it in `docs/`, not only in a commit message.

**5.3 — Structural assertions (cheap, exact, each guards a known chip-killer).** Add these to `sim_gate`:

```bash
grep -c 'local_overrides/WlinkGenericFCSM' flists/tidelink_top_full_asic.flist flists/tidelink_top_full_asic_v2.flist
#   -> FCSM 0-4 must remain on deps until the ILA ratifies (6e3b25d's hold)
grep 'DEBUG_UNLOCK_DEFAULT' src/rtl/asic/tidelink_dft_wrapper.sv   # must be 1'b0  (749a271)
grep 'TXGEN_PRESENT'        src/rtl/asic/tidelink_dft_wrapper.sv   # must be 1'b0  (11cada5/8a7599e)
git grep -c SELF_ARM_TRAIN_EN -- src/rtl/tidelink_top.sv                        # must be 3
git grep -c SELF_ARM_TRAIN_EN -- src/rtl/local_overrides/axi_chiplet_controller.sv  # must be 7
```

`DEBUG_UNLOCK_DEFAULT` matters more than it looks: **six branches carry `1'b1`** (APB debug permanently unlocked in the shipping ASIC), and so does the primary worktree's dirty copy. A wrong conflict resolution anywhere downstream silently ships debug unlocked.

**5.4 — PREREQUISITE, not a stage: pin the cross-repo dependencies.** `[DECISION — David]`

The two blocking gate FAILs are **not** a TideLink defect and **not** TL-001. `tc_pair_smoke.log:326` is an elaboration error:

```
Port "device_strap" is not defined in module 'tidechart_controller'
```

…driven by `tidechart_shim.sv:184`. That is unpinned drift between `TIDECHART_HOME` and `CHIPLET_HOME` (`Makefile:883-884`). **Nothing in this repo records which tidechart / eth-chiplet revision the gate expects.** Record the exact revisions and pin them. Attributing these FAILs to "TL-001 FIX 2 (thresh 5→6)" is wrong and would send someone debugging RTL that is fine.

**VERIFY:** both decisions exist as commits with rationale in `docs/`; the 5.3 assertions all pass; `TIDECHART_HOME`/`CHIPLET_HOME` revisions are recorded in-repo.

---

### STAGE 6 — RE-EARN THE GATE

*The existing evidence is invalid and must not be reused.*

**6.1 — 🔴 Invalidate the stale evidence.** `[DECISION — David]` — *destructive to evidence, not to source.* Archive or delete `imp/sim_gate/` so a stale green cannot be mistaken for a fresh one.

**Measured today:** 55 `.status` files, **every one** stamped `3f037c04e725-dirty` — wrong commit (`3f037c0` is 2026-08-08; the tip `1037a63` is the one commit that changes the shipping flists and has **never** been gated) **and** a dirty tree. Verdicts: 50 PASS / 3 XFAIL / **2 FAIL**, both blocking: `tc_pair_smoke`, `tc_pair_election_datamode`. Treating that directory as green reproduces exactly the documented *"imp/sim_gate green can be a DIFFERENT branch's run"* trap.

**6.2 — Run the gate properly.**

```bash
source ./set_env.sh    # DOCUMENTED TRAP: without this EVERY suite FAILs in 4-5s
                       # and perfectly mimics an RTL break. Read one log before theorising.
make sim_gate
make sim_gate_inventory
```

`sim_gate_inventory` is **mandatory, not advisory** — this Makefile has a documented *scored-but-never-invoked* false-green bug, so a diff-clean resolution is not sufficient evidence.

**VERIFY — all four must hold:**

1. Every scored `.status` is stamped with the **tip SHA** and carries **no `-dirty`** suffix.
2. **Zero FAIL** outside the 3 named XFAIL sentinels (`xfail_f14b_datamode_wedge`, `xfail_epoch_shipping_corrector`, `v2_mask_hs_regress`). An **XCHG** is *behaviour changed → investigate*, not a pass.
3. `make sim_gate_inventory` reports every declared suite as both produced **and** invoked.
4. `make hwtest_gate` reports zero registry gaps for TL-001..TL-034.

**A failure here stops the operation. Nothing is deleted on a red gate.**

---

### STAGE 7 — PROMOTE

**7.1 — 🔴 Clear the 5 checkout blockers.** `[DECISION — David]` — *irreversible deletion of untracked files.*

`git checkout` in the primary worktree will **abort** with *"untracked working tree files would be overwritten."* Measured:

| Path | Verdict |
|---|---|
| `cocotb/tidelink_apb_regs/test_mailbox_apb_writeprotect.py` | COLLIDE-**IDENTICAL** → safe to remove |
| `cocotb/tidelink_top_pair_v2/test_v2_mbox_apb_writeprotect.py` | COLLIDE-**IDENTICAL** → safe to remove |
| `cocotb/tidelink_txgen/test_txgen_ext_hijack.py` | COLLIDE-**IDENTICAL** → safe to remove |
| `docs/OVERNIGHT_SUMMARY_2026_08_07.md` | COLLIDE-**IDENTICAL** → safe to remove |
| `docs/BUG_REGISTRY.yaml` | **COLLIDE-DIFFERENT — THE TRAP** |

The fifth is the stale **651-line** copy (TL-001..TL-017), asserting the **refuted** `open_functional_high: 0` and *"WlinkEccSyndrome.v ACTIVE in shipping ASIC."* The trunk's is **1221 lines** (TL-001..TL-034) and explicitly records TL-006 as **REOPENED — bypass ships**. **Delete the local copy. Never union-merge it.** All four identical files are already captured in the Stage 2.3 rescue commit and the Stage 0.3 archive.

Leave the concurrent fleet's in-flight paths alone (`docs_site/`, `.readthedocs.yaml`, `docs/BUILD_REGISTRY.yaml`) — neither commit nor delete; another agent owns them.

**7.2 — Release the trunk's worktree** (safe now: Stage 2.1 committed its dirt).

```bash
git worktree remove /home/dam1n19/SoCLabs/tidelink-consolidated
```

**7.3 — Fast-forward `main`.** `main` is not checked out in any worktree, so this is legal and is a **pure fast-forward**.

```bash
git merge-base --is-ancestor 18491ef $TRUNK && echo FF-OK      # must exit 0
git branch -f main $TRUNK
```

**VERIFY:** `git rev-list --count main..$TRUNK` = `0`.

**7.4 — Move the primary worktree onto the trunk.**

```bash
git -C $TL checkout main
```

**VERIFY:** `git -C $TL status --porcelain` is empty and `git -C $TL rev-parse HEAD` equals the merged tip.

**7.5 — Push `main`. This is a FAST-FORWARD, not a force.**

```bash
git push origin main          # NO --force, NO --force-with-lease
```

`origin/main` is currently `18491ef` — byte-identical to the old local main — and the new tip has it as a strict ancestor. **If this push is rejected as non-fast-forward, STOP.** That means someone else moved `origin/main` and the merge must be redone on top of their work. Never reach for `--force` to make this step succeed.

**VERIFY:** `git ls-remote origin main` matches the local tip.

---

### STAGE 8 — ARCHIVE, THEN RETIRE

*Archive tags are created and **pushed** BEFORE any branch is deleted. Deleting branches against unpushed archive tags makes a later `git gc --prune` a repo-wide data-loss event — the 2026-07-24 precedent proves it.*

#### Tag naming scheme

| Family | Pattern | Purpose |
|---|---|---|
| Branch tips | `archive/2026-08-collapse/branch/<branch-with-/-replaced-by-_>` | Mechanical, all 26, annotated |
| SHA-cited evidence | `archive/2026-08-collapse/cited/<sha>-<slug>` | Keeps the tapeout registry's citations resolvable |
| Rescue commits | `archive/2026-08-collapse/dirty/<worktree-basename>` | The Stage 2 drains |
| Milestones | `archive/2026-08-collapse/milestone/<name>` | Navigational anchors worth keeping |

**8.1 — Tag all 26 branch tips mechanically** *(graft from Strategy C — blunt by design, no per-branch adjudication)*:

```bash
for r in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  git tag -a "archive/2026-08-collapse/branch/${r//\//_}" "$r" \
    -m "$r @$(git rev-parse --short $r) $(git log -1 --format=%ad --date=short $r) — collapsed 2026-08-10"
done
```

Annotated, so the tag object carries the provenance the branch name loses.

**8.2 — Tag the SHA-cited evidence commits.** These are cited **by SHA inside the trunk's own tapeout documentation** and are held by **no** tag. The content is fully on the trunk, so this is not content loss — it is an **evidence-chain break in a tapeout bug registry**, which is worse than it sounds and trivially prevented:

```bash
git tag -a archive/2026-08-collapse/cited/63222b6-tl006-a1 63222b6 \
  -m 'TL-006 A1 gating evidence — cited in BUG_REGISTRY.yaml, OVERNIGHT_SUMMARY_2026_08_07.md, SIGNOFF_ROADMAP_2026_08_07.md'
git tag -a archive/2026-08-collapse/cited/43b5845-i1-selfarm 43b5845 \
  -m 'I1 self-arm fix — cited in docs/I1_SELFARM_REGRESSION.md'
```

(`2415766` is cited in `HANDOVER_Z2_PICKUP_2026_07_30.md` but is already tagged `archive/pad-clockgate/fix-v2-sync-clock-gate` — it survives.)

**8.3 — Tag the rescue commits and the milestones.**

```bash
git tag -a archive/2026-08-collapse/dirty/<basename> <rescue-commit> -m '...'   # one per Stage 2 drain
git tag -a archive/2026-08-collapse/milestone/freeze-2026-07-31 376cc50 -m '46-blocking-suite freeze point'
git tag -a archive/2026-08-collapse/milestone/consolidated-preunion 1037a63 -m 'trunk tip before the 08-09 union'
git tag -a archive/2026-08-collapse/milestone/eth-chiplet-pin 235d758 -m 'live eth-chiplet superproject submodule pin'
```

`235d758` matters: it is the **live** downstream pin and `git branch --contains 235d758` returns exactly one branch. It is a trunk ancestor so it survives regardless, but the tag makes the pin resolvable by name.

**8.4 — 🔴 PUSH THE ARCHIVE BEFORE DELETING ANYTHING.** `[DECISION — David]`

```bash
git push origin 'refs/tags/archive/2026-08-collapse/*'
git push origin --tags
```

**VERIFY:** the Stage 0.5 `comm -23` check returns **EMPTY** again. **This is the hard gate. No branch may be deleted until it passes.**

**8.5 — 🔴 Remove the 13 remaining non-primary worktrees.** `[DECISION — David]` Clean ones first: `tidelink-axirec`, `-chiplet-integ`, `-freeze`, `-mainmerge`, `-wip-ecc`, `-wip-f1`, `-z2ovr`, `tidelink_wt_unitreg`; then the drained ones: `-fixe`, `-i1fix-confirm`, `-link-survey-2026-08-01`, `-throughput-overnight`, `-wip-testrepoint`.

The primary worktree hosts the real `.git` and **cannot be removed, only switched** — it was handled in 7.4.

Also clear the dangling submodule registration that still locks branch `sc14a-i2c-clkstretch`:

```bash
git -C deps/axi-chiplet-controller worktree prune
```

**VERIFY:** `git worktree list | wc -l` = `1`.

**8.6 — 🔴 Delete the retired branches with `-d`, NEVER `-D`.** `[DECISION — David]`

```bash
git branch -d <each retired branch>
```

`git branch -d` refuses anything not merged into the current HEAD — **that refusal is exactly the safety property we want.** Any branch `-d` refuses is a **bug in this plan**: stop, re-run the Stage 3.6 gate, and find out why. Do not reach for `-D`.

Delete the 20 absorbed branches, the 4 folded residue branches, and the 2 `worktree-agent-*` scratch refs.

**8.7 — Record the DO-NOT-RESURRECT note** for `worktree-agent-ac06dd75b70af4bbf @86c7a0a` in the consolidation commit message. It is patch-identical to `b98b944` (shared patch-id `3eca5568a7aa`) **and** carries 28 lines re-pointing the **TAPEOUT** ASIC flists' FCSM 0–4 to `local_overrides` — which `6e3b25d` deliberately reversed, self-labelled *"RATIFY on silicon before tapeout."* A future residue scan would see 28 "orphaned" lines on a doomed branch and might rescue them **straight into the tapeout netlist.**

**8.8 — Clean the remotes.** `[DECISION — David]`

```bash
git remote remove mainclone
```

Its URL is `/home/dam1n19/SoCLabs/tidelink/deps/tidelink-phy` — the superproject has its own submodule registered as a remote, injecting 114 PHY commits into `git log --all` that read as orphaned superproject work in any future audit. Removing it **deletes no submodule history**.

For `gitlab`: it is 72 commits behind on `main`, `git merge-base --is-ancestor gitlab/main main` exits 0, and all 16 `gitlab/*` refs carry zero locally-absent commits — so mirroring is **provably lossless**. Either `git push gitlab --mirror` or retire the remote. **Decide; do not leave it as a false safety net.**

---

### STAGE 9 — POST-CONDITIONS AND ANTI-REFRAGMENTATION

**9.1 — Final assertions.**

```bash
git for-each-ref --format='%(refname:short)' refs/heads/    # -> 'main' and nothing else
git worktree list | wc -l                                   # -> 1
git ls-tree main deps/                                      # -> 3 gitlinks unchanged + xhb500 tree
```

Re-run the Stage 3.6 `--diff-filter=A` sweep against **every archive tag**; it must return empty.

```bash
git bundle create $BK/postconsolidation-$(date +%F).bundle --all
```

**9.2 — Add the invariants that stop this happening a third time.** The repo was already collapsed once (51 branches → 1 on 2026-07-24) and re-fragmented within two weeks. **The collapse itself is not a durable fix — the invariants are.** Add to `sim_gate`:

1. **Submodule-pin assertion** — the 3 gitlinks (`efe5623c` / `6ee8418b` / `5c76e764`). Pin drift is otherwise invisible.
2. **Flist resolution diff** — override-vs-deps across `tidelink_fpga_v2`, `tidelink_top_full_asic`, `tidelink_top_full_asic_v2`, so an FPGA/ASIC divergence cannot reappear silently.
3. **The Stage 5.3 ASIC parameter greps.**
4. **Extend `fpga/scripts/check_wrapper_params.sh`**: every `parameter` on `tidelink_top.sv` must be either declared **and** passed down by each wrapper, or on an explicit allowlist with a written reason. **This is the check that mechanically prevents the next `AUTO_ANCHOR_EN`-class defect** — an RTL parameter that exists but is never surfaced, so the build silently ships the default.
5. **Cross-repo pin assertion** — `TIDECHART_HOME` / `CHIPLET_HOME` revisions, per Stage 5.4.

**9.3 — Branch policy (the human half).** `[DECISION — David]`

- `main` is the only long-lived branch. Everything else is short-lived and **merges back within days, not weeks**.
- Naming: `fix/*`, `feat/*`, `wip/*` for work; **`integ/*` is reserved** and requires a stated end-date.
- **No branch may be created for a worktree without a corresponding cleanup owner.** Both `worktree-agent-*` refs, 15 worktrees and 4 duplicate-tip pairs are what "no owner" looks like after two weeks.
- **Push on creation.** The single largest exposure in this whole operation — the 6-commit 08-09 line on one filesystem — happened because a line was developed in a sibling clone and never pushed.
- Any branch older than 14 days is either merged, tagged-and-deleted, or gets a written justification in `docs/`.

---

## 4. What this plan does NOT close

Consolidation is a **topology** operation. None of the following are topology problems, and **this plan must not be reported as having closed any of them:**

- **The `b98b944` FPGA-side question.** The trunk ships the surviving FPGA half of the commit blamed on 2026-07-30, on the very path eth-chiplet bring-up uses. Only hardware settles it.
- **The CRACK-gate 32↔8 ratification** — surfaced and signed by Stage 5.1, but ratified only by an ILA run.
- **`6e3b25d`'s ASIC-flist hold**, and with it the fact that the tapeout netlist carries **no AXI watchdog recovery**.
- **TL-006** — header-ECC bypass in the shipping ASIC.
- **The V1 ASIC flist** still sourcing the 2026-05-05 blanket-bypass ECC.
- **TL-013 then TL-014**, in that order — 7 flists consume `gpio-phy` and only 3 consume `tidelink-phy`, so retiring the V1 flist must come first or the V1 elaboration gate breaks.
- **The two blocking gate failures** — this plan surfaces and pins the cause but does not fix the tidechart port signature.

---

## 5. If you only do three things

> **1. REPLICATE BEFORE YOU DELETE ANYTHING.**
> `tar` the 7 dirty worktrees to another filesystem **first** — a `git bundle` does **not** capture uncommitted work, and ~4,000 lines of source currently exist only as working-tree state. Then `git push origin --tags` (19 tags are single-copy, including the only reference keeping `ee15dfd` alive), `git push origin $TRUNK` (only `1037a63` is missing), and **`git fetch` the 08-09 line out of `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`** — 6 commits / +8,570 lines that exist on one filesystem and no remote. One `git checkout` in that clone destroys them permanently.
>
> **2. MERGE THE 08-09 LINE, THEN RE-EARN THE GATE. DO NOT PROMOTE ON TODAY'S EVIDENCE.**
> The trunk's a2l override blob `ecf242a` is literally the **parent** of the eth-chiplet's `8a1faba` — commit `1037a63` points the shipping FPGA and ASIC-V2 flists at overrides one TL-032 fix short of what the hardware actually runs. And all 55 `.status` files are stamped `3f037c04e725-dirty` with **2 blocking FAILs** whose cause is unpinned tidechart drift, not a TideLink defect. `source ./set_env.sh` first, then `make sim_gate` **and** `make sim_gate_inventory` on a clean checkout of the merged tip.
>
> **3. PROMOTE BY FAST-FORWARD — AND NEVER FORCE-PUSH `main`.**
> `main` is a strict ancestor of the trunk (0 behind / 95 ahead) and `origin/main` is byte-identical to local `main`, so `git branch -f main $TRUNK && git push origin main` is a **clean fast-forward**. That is the single strongest argument against the rebuild strategy, which requires force-updating a published ref and breaks the live eth-chiplet pin `235d758`. If that push is ever rejected as non-fast-forward, **STOP and re-merge** — do not reach for `--force`. Then, and only then: push the `archive/2026-08-collapse/*` tags, and delete branches with `git branch -d` (never `-D`). A branch `-d` refuses is a bug in this plan, not an obstacle to it.

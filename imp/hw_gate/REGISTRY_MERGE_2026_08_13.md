# BUG_REGISTRY merge record — 2026-08-13

Merged `docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` (untracked) into
`docs/BUG_REGISTRY.yaml`.

**NOT COMMITTED, NOT PUSHED.** The merged file is left modified in the working
tree for human review. `docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` is left in
place untouched — delete it as part of the landing commit, not before review.

---

## 1. Contention check — am I merging onto the current tip?

The additions file's own header states: *"Tip at time of writing: d317c982,
highest allocated id TL-035 (verified)."* Checked before touching anything:

| check | result |
|---|---|
| `git rev-parse --abbrev-ref HEAD` | `integ/tidelink-consolidated-2026-08-07` |
| `git log --oneline -1` | `d317c98 docs: rescue HANDOVER_KR260_FCSM_BRINGUP...` |
| `git log --oneline -5 -- docs/BUG_REGISTRY.yaml` (tip) | `c4f9f9e wip(consolidation): drain the trunk worktree...` |
| `git merge-base --is-ancestor c4f9f9e HEAD` | YES |
| `git status --short docs/BUG_REGISTRY.yaml` (pre-merge) | clean |
| highest id in registry pre-merge | TL-035 |
| remotes | one only (`origin` = GitHub); branch also present as `origin/integ/tidelink-consolidated-2026-08-07` |

**The registry has NOT moved since the additions were written.** Authoring tip
d317c98 == merge-time tip d317c98; the file's last-touching commit c4f9f9e is an
ancestor of HEAD; the working copy was clean. **Nothing had to be re-resolved for
drift.** The re-resolution that *was* required is content-level, not
git-level — the 2026-08-13 hardware results in §5.

---

## 2. Before / after

| | before | after |
|---|---|---|
| entries | **35** | **42** |
| file lines | 1261 | 1912 |
| `git diff --stat` | — | 656 insertions, 5 deletions |

**IDs before (35):**
TL-001 TL-002 TL-003 TL-004 TL-005 TL-006 TL-007 TL-008 TL-009 TL-010 TL-011
TL-012 TL-013 TL-014 TL-015 TL-016 TL-017 TL-018 TL-019 TL-020 TL-021 TL-022
TL-023 TL-024 TL-025 TL-026 TL-027 TL-028 TL-029 TL-030 TL-031 TL-032 TL-033
TL-034 TL-035

**IDs after (42):**
TL-001 TL-002 TL-003 TL-004 TL-005 TL-006 TL-007 TL-008 TL-009 TL-010 TL-011
TL-012 TL-013 TL-014 TL-015 TL-016 TL-017 TL-018 TL-019 TL-020 TL-021 TL-022
TL-023 TL-024 TL-025 TL-026 TL-027 TL-028 TL-029 TL-030 TL-031 TL-032 TL-033
TL-034 TL-035 **TL-036 TL-037 TL-038 TL-039 TL-040 TL-041 TL-042**

All 5 deleted lines are the 5 intended in-place replacements, audited
individually (`git diff -U0 | grep '^-'`):

1. TL-005 caveat — the inherited "physical marginal-eye dominates" line → reissued with a SUPERSEDED marker
2. TL-009 `ground_truth_2026_08_07[0]` — the over-reading → replaced with the softened bullet (original text quoted inline)
3. TL-035 `verification` → renamed to `verification_superseded_2026_08_09`, new block added
4. TL-035 `signoff` → renamed to `signoff_superseded_2026_08_09`, new block added
5. TL-035 `related` → extended `[TL-027, TL-009, TL-029]` → `+ TL-036, TL-039, TL-040`

Nothing else was removed. No entry was reordered.

---

## 3. Duplicate-key check (the bug that already bit this file once)

`yaml.safe_load` is **not** sufficient: it silently applies last-key-wins, which
is how a bare-4-space-indented amendment block was once absorbed into the
preceding list item and shadowed TL-041's `verification` and `signoff`.

Checker written for this merge:
`scratchpad/dupkey_check.py` — walks the raw node graph via `yaml.compose_all`
**before** construction, so repeated keys are reported with line/column, and
separately reports any bug id appearing more than once.

### 3a. Checker self-test (proves it is non-vacuous)

Fed a poison file reproducing the exact historical failure:

```
$ python3 dupkey_check.py poison.yaml
entries: 2
ids: TL-041 TL-041

PROBLEMS (4):
  - DUPLICATE KEY 'verification' at bugs[TL-041]
    first  : line 3 col 5
    repeat : line 5 col 5
  - DUPLICATE KEY 'signoff' at bugs[TL-041]
    first  : line 4 col 5
    repeat : line 6 col 5
  - DUPLICATE BUG IDS: TL-041
  - MISSING REQUIRED FIELDS: ...
rc=1
```

The checker catches the shadowing pattern. A plain `yaml.safe_load` on that same
file returns without error.

### 3b. Result on the merged registry

```
$ python3 dupkey_check.py docs/BUG_REGISTRY.yaml
entries: 42
ids: TL-001 TL-002 ... TL-041 TL-042

OK: no duplicate mapping keys, no duplicate bug ids, no missing core fields.
rc=0
```

Pre-merge baseline was also clean (35 entries) — so the merge introduced no
duplicates, and none pre-existed.

### 3c. TL-041 deep check (the entry that was shadowed before)

```
verification keys : ['hw_tested', 'in_sim_gate', 'sim_test']
signoff keys      : ['approved', 'claude_verdict', 'evidence',
                     'evidence_reverified_2026_08_13', 'merge_note_2026_08_13']
verification.sim_test  starts: 'cocotb/tidelink_ptp_servo/test_tidelink_ptp_servo.py SRV-016'
signoff.claude_verdict starts: 'Fix is correct and independently verified (pre/post hunks re'
TL-035 text leaked into TL-041 signoff? no
```

TL-041 owns both blocks with its own content. The TL-035 replacement blocks are
inside TL-035, where they belong. A `merge_note_2026_08_13` was added to TL-041's
signoff recording the historical shadowing so the next merger knows why the
indentation matters.

### 3d. Field-preservation diff (pre-merge snapshot vs merged)

`scratchpad/field_preservation.py`, comparing every TL-001..TL-035 entry:

```
RESULT: no pre-existing entry lost a field.
        (Renames preserved content byte-identically.)
```

Only these pre-existing entries changed at all, all intentionally:

| id | changed | added |
|---|---|---|
| TL-005 | `verification`, `caveats` | `synth_b_arming_gap_2026_08_13` |
| TL-006 | `verification` | — |
| TL-007 | `verification` | — |
| TL-009 | `ground_truth_2026_08_07` | `physical_eye_claims_retracted_2026_08_13` |
| TL-035 | `verification`, `signoff`, `related` | `verification_superseded_2026_08_09`, `signoff_superseded_2026_08_09`, `localization_2026_08_13`, `ila_capture_2026_08_12_does_not_bear_on_this` |

TL-035's superseded originals were verified **byte-identical** to their pre-merge
values under the renamed keys — the audit trail is preserved, not overwritten.

### 3e. New entries carry their own complete fields

```
TL-036  status=root_caused keys=12 verification=OK signoff=OK
TL-037  status=open        keys=12 verification=OK signoff=OK
TL-038  status=open        keys=12 verification=OK signoff=OK
TL-039  status=root_caused keys=11 verification=OK signoff=OK
TL-040  status=root_caused keys=11 verification=OK signoff=OK
TL-041  status=sim_proven  keys=12 verification=OK signoff=OK
TL-042  status=open        keys=15 verification=OK signoff=OK
```

### 3f. Downstream consumers still parse it

| consumer | result |
|---|---|
| `scripts/ci/registry_coverage.py` | 42 bugs, 0 HARD FAILURES, **RESULT: COVERAGE OK** |
| `scripts/ci/hw_registry_coverage.py` | 42 bugs, 0 HARD FAILURES, **RESULT: HW COVERAGE OK** |
| `scripts/gen_bug_registry_html.py` | wrote 42 bugs, 177,386 bytes, rc=0 |

`registry_coverage.py` now reports **one new coverage gap: TL-041 (sim_proven,
`in_sim_gate` not true)**. That is a correct new signal, not a break — it is
precisely the gating gap TL-041's own `action_items` demand be closed (the servo
suite has 0 references in the Makefile). Pre-existing gaps TL-007 and TL-026 are
unchanged.

---

## 4. What was merged

**New entries, verbatim from the additions file except where §5 applies:**

- **TL-036** (medium, root_caused) — TL-035 watchdog fix does not cover `WlinkGenericFCSM_6` (sideband FC node)
- **TL-037** (high, open) — no AXI firewall / timeout on the cross-die write path; PS hard-hangs, JTAG-POR-only recovery
- **TL-038** (high, open) — `errinject --node B --inj-byte 1` (word_count) still hard-wedges on silicon while passing in sim
- **TL-039** (medium, root_caused) — ILA/obs plane mis-scoped; no probe observes the AXI data nodes
- **TL-040** (medium, root_caused) — `dbg_a2l_wedged` trigger cannot fire for the observed wedge class
- **TL-041** (high, sim_proven) — `servo_locked` behaviour change reached shipping+tapeout RTL inside a "No functional intent" commit
- **TL-042** (high, **open** — see §5) — CLASS: backstops that arm/clear on an intermediate signal the wedge itself suppresses

**Amendments applied to existing entries:**

- **TL-035** — `verification` + `signoff` replaced from the `tl035_replacement_blocks:` wrapper document (originals preserved under `*_superseded_2026_08_09`); `localization_2026_08_13` added; new `ila_capture_2026_08_12_does_not_bear_on_this` recording that the 08-12 capture probes the wrong node (sideband FCSM_6, not the AW/W/B data nodes) and that **Part-B remains BLIND-MERGE-FORBIDDEN** because `auto_tx_out_advance` was never probed; `related` extended.
- **TL-009** — first `ground_truth` bullet softened from *"reads HEALTHY ... => NOT an FC-node wedge"* to *"cannot distinguish a never-driven B from an unsampling instrument, so it neither confirms nor excludes an AXI-node wedge"*, with the `tidelink_axinode_obs.sv:65-90` construction argument and the aw/w-sticky positive-signal guidance. Original wording quoted inline.
- **TL-005 / TL-007** — `hw_scope: "B-node byte-0 single-bit inject ONLY; AW/W and B byte-1 untested/failing"` added to each `verification`, plus an `hw_scope_note` explaining that neither verdict is retracted, only narrowed so they stop reading as general recovery proof.
- **TL-006** — `byte1_coverage_is_sim_only_2026_08_13` added cross-referencing TL-038.
- **TL-005** — `synth_b_arming_gap_2026_08_13` carries the additions file's FIX-DESIGN CONSTRAINT block (see §6 for the modification).
- **`campaign.additions_2026_08_13`** — new rollup sub-block recording provenance, the id lists, the content corrections, and the lint result.

**Structural note:** the additions file's three YAML documents (`---`-separated:
TL-036..TL-041, the `tl035_replacement_blocks:` wrapper, TL-042) were all
consumed. The merged registry is a **single** YAML document; the wrapper key was
unwrapped into TL-035 and does not survive as a top-level key.

**Claims spot-verified against the tree before merging as fact** (I did not take
the additions file's word for these):

| claim | verification |
|---|---|
| TL-036: `_6` lacks the ifdef, `.v/_1.._4` have it | `grep -c TL033_LEGACY_WDOG` = 2,2,2,2,2 for base/_1/_2/_3/_4 and **0** for `_6`; `~socl_l7_real_crc_seen` still present in `_6`. CONFIRMED |
| TL-041: servo suite ungated | `grep -c ptp_servo Makefile` = **0**. CONFIRMED |
| TL-041: commit b0e9334 | exists; header `lint: explicit widths and signedness across the RTL`. CONFIRMED |
| TL-042: `wr_hold_clr` includes `synth_b_pending` | `src/rtl/tidelink_top.sv:1826-1827`. CONFIRMED |
| all cited `imp/hw_gate/` artefacts | `ila_tl035_run/`, `tl035_tl035/`, `control_baseline/`, `retry2/`, `rep_tl042_r3/`, `tl042_rejected_fix/tl042_fix_REJECTED.patch`, both PREREG docs — all present |

Each verified claim is annotated in the entry (`evidence_reverified_2026_08_13`)
rather than silently trusted.

---

## 5. Content corrections applied (hardware results postdating the additions file)

### 5a. TL-042 — candidate fix REJECTED on hardware

The additions file logged TL-042 as `status: root_caused` and proposed a fix
direction. That fix was **built, deployed and rejected on hardware on 2026-08-13**.

Applied:

- **`status: root_caused` → `status: open`**, with an inline comment stating why.
- New **`rejected_candidate_2026_08_13:`** block (9 keys) recording:
  - **verdict** — REJECTED, HARMFUL, not committed, RTL reverted to HEAD.
  - **measurement** — single-variable A/B, die_b image byte-identical in every run (`13573e46...`) so die_a's bitstream was the only variable; **baseline (`9eadebb8...`) n=1 → 16/16 byte-exact, Region F gate PASS, die_a UP**; **fixed (`0366c344...`) n=2 → 0/16 (`0x00000000`), gate FAIL, die_a DOWN**; **healthy bring-up on every reported run** (fcsm=4 both dies, crack_seen=1 both, both re-anchored). P2 refuted on its own stated refutation condition; P1/P3 not cleanly tested.
  - **regression_mechanism** — `wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast) | synth_b_pending`, so `synth_b_pending` is a *term of the clear*: asserting it **disables** the TL-002 hold it was meant to help. The candidate reused it as its hold-release lever. Compounding: the companion `s_axi_bvalid` suppression removes the handshake needed to deassert `synth_b_pending`, so it can latch high permanently. The arming term `wr_hold_r && (sub_wr_os_ctr == 0)` is independently unsound (an early B can zero the counter during a legitimate EWR write).
  - **why_sim_missed_it** — the candidate passed a non-vacuity A/B and two sim_gate targets; the test asserted only that the hold *escapes*, never that `synth_b_pending` clears nor that a normal write still lands. "A passing escape test is not a safety test."
  - **what_a_correct_fix_must_do** — 3 constraints, carried verbatim.
  - **artefacts** — including `imp/hw_gate/TL042_HW_RESULT_REJECTED_2026_08_13.md`, cited as required, and `TL042_RUN1_VOID_2026_08_13.md` flagged as citable for nothing.
- New caveat: **"DO NOT reuse `synth_b_pending` as a hold-release lever."**
- `summary`, `instances[3]`, `verification.hw_tested` and `signoff.claude_verdict` updated so no field still reads as though a fix exists.

**Line-number correction I had to make.** `TL042_HW_RESULT_REJECTED_2026_08_13.md`
cites `:1838` and `:1939`. Those are **candidate-patched** line numbers. On HEAD
RTL — `src/rtl/tidelink_top.sv`, md5 `b75d391b0f659d808ac0a4cb37310643`, which I
verified matches the md5 the result doc reports as the reverted state — the same
statements are at **`:1826-1827`** and **`:1870`**. Both numbers are recorded in
the entry under `line_number_note` so neither reader is misled.

### 5b. The "degraded rig physical eye" claim — retracted, not propagated

The additions file itself **does not** carry a degraded-eye claim (grep for
`eye|ribbon|reseat|degrad` returns only a *critique* of the physical-eye story in
the TL-009 amendment). So nothing had to be stripped from the incoming material.

The claim does exist in **pre-existing** entries, which the instruction to
preserve fields forbids me from deleting. Handled additively:

- **TL-009** — new `physical_eye_claims_retracted_2026_08_13` notice: the rig
  delivered **16/16 byte-exact on baseline** on 2026-08-13 with healthy bring-up,
  and the TL-035 arm delivered 200/200 byte-exact in steady state, on the same rig
  with **no bench trip and no ribbon reseat**; the wedge reproduces on a good eye;
  two instrument defects (TL-039/TL-040 — Region F reads "ALL CLEAN" while dead
  under load) manufactured much of the original impression. Bring-up *does* still
  lottery occasionally (run #1: die_a fcsm=2, VOID), but that is the known
  RX-capture placement **hold race** in `phy/gpio/gpiorx_*` / `u_rmii_to_mii` — a
  build/placement property, not a degraded link. TL-009's 2026-08-07 verdict text
  is **retained verbatim** as the historical record, with the notice attached.
- **TL-005** — its inheriting caveat *"physical marginal-eye wedge (TL-009) still
  dominates"* now carries an inline **SUPERSEDED 2026-08-13** marker pointing at
  the TL-009 notice.
- **TL-042** — new `rig_status_2026_08_13` field stating the rig is healthy and the
  narrative is retracted, so the newest entry cannot be read as re-asserting it.
- **TL-039 / TL-040** — caveats added noting that the "try Region F first, no ILA
  needed" advice is now unsafe on its own, because the sampler has been observed
  dead under load. (TL-039's original caveat is retained; the new one is marked
  `SUPERSEDED IN PART`.)

---

## 6. Deliberately NOT merged

**The head-of-line write-age timer, as a live fix proposal.**

The additions file ends with a `FIX-DESIGN CONSTRAINT` block instructing the
merger to carry a proposed fix for the synth-B arming gap into "TL-005 amendment
or a new id": age the oldest unretired write, reset only when *that* write
retires, do not re-gate the shared counter.

I merged the **defect reading** (the `:1667` second-term analysis is sound and is
TL-042 instance 1) but **not the fix as live guidance**, because the additions
file *contradicts itself*: TL-042's own caveat, written later in the same file,
says —

> "DO NOT build the previously-proposed head-of-line write-age timer: it ages
> writes counted in `sub_wr_os_ctr`, and the stuck write is never counted. It
> would review as correct and do nothing. Killed by the 08-13 ILA."

At the measured wedge `sub_aw_accept=0` and `sub_wr_os_ctr=0`, so a timer that
ages *counted* writes cannot see the stuck one. Merging the proposal unqualified
would have handed the next engineer a fix that reviews as correct and does
nothing — the exact failure mode TL-042 exists to warn about.

It is recorded at **`TL-005.synth_b_arming_gap_2026_08_13`** with the fix section
headed `*** THE PROPOSED FIX IS KILLED — DO NOT BUILD IT. ***`, cross-referenced
to TL-042, and the still-valid parts kept: the probe set, the no-core control-build
requirement, the proven capture modality (`imp/hw_gate/ila_2026_08_12/`), and the
note that XHB500 is read-only vendor IP under `/research/AAA/ip_library/`.

Nothing else from the additions file was dropped. All three YAML documents were
consumed in full.

---

## 7. Honest caveats — read before landing

1. **TL-042 `status: open` contradicts this file's own status legend.** The
   lifecycle at the top defines `open` as *"not yet root-caused"*, and TL-042 *is*
   root-caused as a class. I set `open` as instructed, on the reasoning that the
   more dangerous misreading is "this has a fix". If you prefer legend-consistency,
   `root_caused` with the `rejected_candidate_2026_08_13` block intact carries the
   same information — **your call, one-word change.**

2. **TL-036's "complete coverage of the AXI data plane" describes the WORKING
   TREE, not tip d317c98.** All five `WlinkGenericFCSM{,_1,_2,_3,_4}.v` overrides
   are **modified-uncommitted** in this worktree (the TL-035 Part-A edit is not
   committed — consistent with the additions file's own "source d317c98...-dirty").
   The claim is annotated with this caveat in the entry. If those edits are ever
   discarded, TL-036's premise changes.

3. **Campaign counters are stale and I did not recompute them.**
   `open_rank1_critical: 1`, `open_functional_high: 1`, `open_tapeout_high: 4`
   predate this merge. TL-037/TL-038/TL-042 are new high+open and TL-041 is a new
   high tapeout item. I left them alone deliberately — they are hand-maintained on
   a file that has been contended across sessions, and silently rewriting a rollup
   number is how a bad number gets inherited. A `counter_note` in
   `campaign.additions_2026_08_13` flags them as stale. **Recompute at sign-off.**

4. **Every new entry has `signoff.approved: false`.** Nothing here is signed off,
   and per `signoff_policy` nothing netlist-affecting can be. TL-041 explicitly
   requests David's sign-off as a *functional* change to tapeout RTL.

5. **`imp/` is gitignored** (`.gitignore:98 imp/*`), so this record and all cited
   `imp/hw_gate/` evidence are untracked. That matches how the rest of `hw_gate/`
   is kept, but it means the registry's evidence pointers resolve only on a
   machine that has this working tree.

6. **No conflict was left unresolved.** The only judgement call I made beyond the
   brief is §6 (the killed fix proposal), and it is documented in-file rather than
   silently dropped.

7. **The worktree is live — another session was writing to it during this merge.**
   Three files became modified *while* I worked, and I did not touch them:
   `cocotb/fifo_rx_twin2/test_fifo_rx_twin2.py`,
   `cocotb/tidelink_fifo/test_tidelink_fifo.py`,
   `cocotb/tidelink_fifo/tidelink_fifo_ctrl_noguard.sv`
   (all absent from `git status` at the start of this session, present at the end).
   They do not touch the registry and cannot affect this merge, but they confirm
   the file-contention warning in the additions file's header is still current.
   **Re-run the duplicate-key lint immediately before committing** in case another
   session also edits `docs/BUG_REGISTRY.yaml`:
   `python3 imp/hw_gate/dupkey_check.py docs/BUG_REGISTRY.yaml` — expect
   `entries: 42` and `OK`.

---

## 8. Files touched

| path | state |
|---|---|
| `docs/BUG_REGISTRY.yaml` | **MODIFIED, uncommitted** — the merged deliverable |
| `imp/hw_gate/REGISTRY_MERGE_2026_08_13.md` | new (this file; gitignored) |
| `docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` | untouched, still untracked — delete when landing |
| `imp/hw_gate/dupkey_check.py` | new (gitignored) — the duplicate-key linter, re-runnable |
| `imp/hw_gate/field_preservation.py` | new (gitignored) — the pre/post field-loss diff |
| `imp/hw_gate/BUG_REGISTRY.yaml.premerge_2026_08_13` | new (gitignored) — pre-merge snapshot, so the diff above is reproducible |

No RTL, testbench, flist or script was modified. Nothing under
`/research/AAA/ip_library/**` or `/research/AAA/phys_ip_library/**` was read for
writing or altered.

The two verification scripts and the pre-merge snapshot are kept in
`imp/hw_gate/` (gitignored, alongside the rest of the evidence) so every number in
this record is reproducible:

```
python3 imp/hw_gate/dupkey_check.py docs/BUG_REGISTRY.yaml
python3 imp/hw_gate/field_preservation.py \
        imp/hw_gate/BUG_REGISTRY.yaml.premerge_2026_08_13 docs/BUG_REGISTRY.yaml
```

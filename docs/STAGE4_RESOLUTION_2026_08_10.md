# Stage 4 conflict resolution — trunk ← recovered off-repo line

**Date:** 2026-08-10
**Ours (trunk):** `integ/tidelink-consolidated-2026-08-07` @ `321edbf`
**Theirs (incoming):** `ethclone/integ/tidelink-consolidated-2026-08-09` @ `28409f5` (6 commits)
**Merge base:** `1112d638ddd3bd0d946fff1ba0e12602ad56957d` (`1112d63`)
**`git merge-tree` result tree:** `d7befcd` — 5 conflicts
**Resolved artefacts:** `/home/dam1n19/SoCLabs/tidelink/scratch_resolved/`

This document is the resolution record. It does **not** perform the merge; §4 gives the
exact commands for the operator to run.

---

## 0. The one thing to take away

> **Every conflict in this merge is noise. Every netlist-affecting change in it is
> conflict-free.**

The five conflicts are two cosmetic flist comment collisions and three Makefile-generated
scratch files. Meanwhile the TL-032 RTL fix, a 17-file lint sweep across shipping RTL, a
behaviour change to tapeout PTP-servo RTL and a silent take-theirs on a **fourth**
generated file all arrive with no conflict marker at all. A reviewer who works the conflict
list reviews exactly the files that do not matter.

Two consequences for how this merge is handled:

1. **`cocotb/tidelink_a2l_replay_cdc/dut_src.f` is not in the conflict list and must still
   be fixed by hand** (§2, row 6). Ours == base, theirs changed it, so git resolves it
   silently to an off-repo absolute path.
2. **Sign-off must be driven off the payload, not the conflict list** (§7).

---

## 1. Resolution table

| # | File | Take | Netlist-affecting? | One-line proof |
|---|------|------|--------------------|----------------|
| 1 | `flists/tidelink_fpga_v2.flist` | **theirs, verbatim** | **No** (resolution). File class: shipping-FPGA netlist selector. | Semantic key `e83b9e9bf225ffc0` on ours, theirs **and** the resolved file (base `1eb669e9b862e20c`) — 188 active lines, identical in set *and* order; theirs adds 4 `//` provenance lines and removes none. |
| 2 | `flists/tidelink_top_full_asic_v2.flist` | **synthesized** — theirs' active content, comment rewritten | **No** (resolution). File class: **TAPEOUT netlist selector.** | Semantic key `fb2fb81b55d6ef3a` on ours, theirs **and** the resolved file (base `fbd4c965cc2ff09a`); the only delta vs theirs is 34 `//` lines (`diff … \| grep '^[<>]' \| grep -vc '^[<>] //'` = 0). Theirs' comment asserts the change is *"INERT until … `make asic-flist`"*, which is false: `syn/asic/fusion-compiler/Makefile:20` sets `FLIST` to this exact file and reads it directly. |
| 3 | `cocotb/tidelink_a2l_replay_cdc/dut_src_1.f` | **neither — synthesized** | No | Both sides commit a machine-absolute path (ours `…/tidelink-consolidated/…`, theirs `…/nanosoc-ethernet-chiplet/tidelink/…`); the repo convention in all 40 other tracked flists is `${TIDELINK_HOME}/…`. |
| 4 | `cocotb/tidelink_a2l_replay_cdc/dut_src_3.f` | **neither — synthesized** | No | Same as row 3. |
| 5 | `cocotb/tidelink_a2l_replay_cdc/dut_src_5.f` | **neither — synthesized** | No | Same as row 3 **plus**: theirs names `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_5.v` — a *different directory*, the pristine pre-fix DUT. A naive take-theirs points the B-node suite at the very RTL this merge exists to replace. |
| 6 | `cocotb/tidelink_a2l_replay_cdc/dut_src.f` | **neither — synthesized** ⚠ **NOT A CONFLICT** | No | `dut_src.f` blobs: base `e5969d8` == ours `e5969d8`, theirs `6c4c279` → one-sided, git takes theirs **silently**. Confirmed in the merge tree: `git cat-file -p d7befcd:cocotb/tidelink_a2l_replay_cdc/dut_src.f` → `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/…`. |

**Reading of "netlist-affecting":** the column answers *does this resolution change what
gets compiled?* For rows 1 and 2 the answer is no — both sides select a bit-for-bit
identical source set, so the choice cannot move the netlist. The *files* are netlist
selectors and are treated as netlist-affecting for review purposes; see §7.

**What actually changes the netlist in this merge** (conflict-free, see §7):
`src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v` — ours == base for all three
(`ecf242ae20` / `c823d43919` / `b39f4e0584`), theirs differs (`8a1fabae9e` / `9a4b06344c` /
`fbf008e6e8`), so theirs wins unopposed. Each gains one `else if (link_revert) a2l_link_addr
<= link_revert_addr;` branch (`grep -c 'link_revert)'`: ours 0, theirs 1, per file). Both
shipping flists already point at these files, so this lands on the FPGA **and** tapeout
netlists the moment the merge commits.

---

## 2. Exact resolved content

All six files are in `/home/dam1n19/SoCLabs/tidelink/scratch_resolved/`, named after the
repo path with `/` replaced by `__`:

```
flists__tidelink_fpga_v2.flist                       <- row 1
flists__tidelink_top_full_asic_v2.flist              <- row 2
cocotb__tidelink_a2l_replay_cdc__dut_src_1.f         <- row 3
cocotb__tidelink_a2l_replay_cdc__dut_src_3.f         <- row 4
cocotb__tidelink_a2l_replay_cdc__dut_src_5.f         <- row 5
cocotb__tidelink_a2l_replay_cdc__dut_src.f           <- row 6 (NOT a conflict; included
                                                        deliberately — see §1 note 1)
```

### Row 1 — `flists/tidelink_fpga_v2.flist`

**Rule:** byte-for-byte `git show 28409f5:flists/tidelink_fpga_v2.flist`.
Verified identical (`diff` clean) against the artefact. Theirs is a strict documentation
superset: ours' comment lines are an ordered *subsequence* of theirs', 0 ours-only lines.

### Row 2 — `flists/tidelink_top_full_asic_v2.flist`

**Rule:** theirs' bytes, with the three TL-027 comment blocks replaced. **No active line is
added, removed, reordered or edited.** Three assertions in theirs' comment are false or
dangling and must not be baked into the tapeout netlist selector:

| Theirs' claim | Status |
|---|---|
| *"INERT until `build/chip/flist/tidelink_asic.flist` is regenerated"* | **False.** `syn/asic/fusion-compiler/Makefile:11,19,20` (`MODULE ?= tidelink_top_full`, `ASIC_PHY ?= _v2`, `override FLIST := $(TIDELINK_HOME)/flists/$(MODULE)_asic$(ASIC_PHY).flist`) reads *this file* directly. `syn/asic/formality/scripts/run_lec.tcl:19` reads the same `$FLIST`. `Makefile:1286` (`sim_gate_asicelab_v2`) and `:1316` (`sim_gate_dftelab`) compile it, and both suites are in `SIM_GATE_ALL_SUITES`. |
| *"`make asic-flist`"* | **No such target.** Not in `Makefile`, `fpga/Makefile`, `syn/asic/*.mk` or `syn/asic/*/Makefile`. The only repo-wide hit is `docs/REGRESSION_GATE_ENHANCEMENT_PLAN_2026-07-30.md:23`, describing a command run in the **sibling** `nanosoc-ethernet-chiplet` repo. `build/chip/flist` has zero references anywhere. |
| *"See `docs/TAPEOUT_FOLD_PLAN_2026-08-09.md` item A"* | **Dangling.** Present on neither `321edbf` nor `28409f5`. |

The rewritten `_1` block states the change is live on the FC tapeout flow and on
`sim_gate_asicelab_v2` / `sim_gate_dftelab`, keeps the two claims that *do* check out
(19-line port block byte-identical to the deps copy ⇒ LEC boundary unchanged; FPGA-HW-proven
2026-08-09, 128/128 soak), and cites `cocotb/tidelink_a2l_replay_cdc` as the sim proof. The
`_3` / `_5` blocks defer to it. The fragile `tidelink_fpga_v2.flist (:269/:281/:284)` line
references are dropped — line numbers rot; the filename alone is enough.

*If the operator prefers to restore the fold-plan citation, add
`docs/TAPEOUT_FOLD_PLAN_2026-08-09.md` in the same commit and re-cite it. Do not cite a file
that does not exist.*

### Rows 3–6 — the `dut_src*.f` quartet

**Rule:** exactly one line plus a trailing newline, no comment header:

```
${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v
${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCReplayV2_3.v
${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCReplayV2_5.v
${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v   # dut_src.f
```

Reject **both** sides. Ours bakes `/home/dam1n19/SoCLabs/tidelink-consolidated/…`, theirs
bakes `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/…` (and for `_5`, the deps
pre-fix DUT). `${TIDELINK_HOME}/…` is the unanimous convention of the other 40 tracked
flists; VCS expands `${VAR}` inside `-f` files, which is how all 1529 other
`${TIDELINK_HOME}` entries already work.

No comment header, because the suite Makefile truncates and rewrites the file on every
invocation — any comment is destroyed on first run.

**Two facts that change what "resolved" means here** — read before assuming this is finished:

1. **These are generated artefacts, not hand-authored flists.**
   `cocotb/tidelink_a2l_replay_cdc/Makefile:56` is
   `$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))` — a parse-time shell call that rewrites all
   four files on *every* make invocation, from `TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)`.
   So the committed bytes never reach VCS, and **the `${TIDELINK_HOME}` form written above
   will be clobbered the first time anyone runs the suite**, re-dirtying the tree.
2. Therefore the resolution is only *stable* when paired with the durable fix in §7.1.
   The content above is still the right thing to record — it is what the generator *should*
   emit and it makes the gate green — but on its own it is a snapshot, not a repair.

**Positive check that the chosen content is correct** (run against the trunk worktree):

```
python3 scripts/flist_semantic.py --root /home/dam1n19/SoCLabs/tidelink-consolidated \
  check /home/dam1n19/SoCLabs/tidelink/scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src*.f \
  --no-ratchet
# => flist gate: 4 file(s), 4 entries ... RESULT: PASS
```

All four `${TIDELINK_HOME}` paths resolve to files that exist in the merged tree, and none
trips the absolute-path rule.

---

## 3. Why the two flist conflicts are provably netlist-neutral

Two independent measurements, both reproducible.

**A. Semantic key** (`scripts/flist_semantic.py`, ordered canonical model,
`${TIDELINK_HOME}` expanded to a repo-relative path, all other variables kept symbolic):

| file | base `1112d63` | ours `321edbf` | theirs `28409f5` | **resolved** |
|---|---|---|---|---|
| `flists/tidelink_fpga_v2.flist` | `1eb669e9b862e20c` | `e83b9e9bf225ffc0` | `e83b9e9bf225ffc0` | `e83b9e9bf225ffc0` |
| `flists/tidelink_top_full_asic_v2.flist` | `fbd4c965cc2ff09a` | `fb2fb81b55d6ef3a` | `fb2fb81b55d6ef3a` | `fb2fb81b55d6ef3a` |

**B. Tool-free fallback** — strip comments and blanks, hash the rest. Every version of both
files has exactly **188** active lines:

```
act() { sed -e 's#//.*##' -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' ; }
git show <ref>:<flist> | act | wc -l          # => 188 everywhere
git show <ref>:<flist> | act | sha256sum | cut -c1-16
```

| file | base | ours = theirs = resolved |
|---|---|---|
| `flists/tidelink_fpga_v2.flist` | `3958f9954478618b` | `ca1dd23ea2df2bfd` |
| `flists/tidelink_top_full_asic_v2.flist` | `dff882f207bffffa` | `2e628c7d5cef6289` |

Both sides made the *same* change relative to base: `WlinkGenericFCReplayV2_{1,3,5}`
re-pointed from `deps/axi-chiplet-controller/logical/wlink/` to `src/rtl/local_overrides/`.
Neither flist contains a nested `-f` include, so each resolved set is self-contained; the
one commented-out source path (`WlinkGPIOPHY.v`, FPGA flist line 259) is commented on base,
ours *and* theirs alike, so there is no active/commented asymmetry between the sides.

The `//` comment syntax theirs adds is stripped by every consumer — `fpga/filelist.tcl:187-192`,
`cocotb/flist_deps.mk:33`, `syn/asic/scripts/tidelink.FC.read_design.tcl`,
`syn/asic/formality/scripts/run_lec.tcl:179`, and VCS `-f` natively — including both
tapeout-path parsers.

---

## 4. Performing the merge

Run in the trunk worktree `/home/dam1n19/SoCLabs/tidelink-consolidated`. It has two
unrelated dirty paths (`docs/BILATERAL_ANCHOR_BRINGUP_SCOPE_2026_08_10.md`,
`pynq_host/scripts/kr260_sync_bringup.sh`); neither intersects the incoming payload, so the
merge will start. Commit or set them aside first if you want a clean tree for the gate stamp
(see §7.4).

```bash
cd /home/dam1n19/SoCLabs/tidelink-consolidated
R=/home/dam1n19/SoCLabs/tidelink/scratch_resolved

git merge --no-commit --no-ff ethclone/integ/tidelink-consolidated-2026-08-09
# expect: 5 conflicts (2 content on flists/, 3 add/add on cocotb/…/dut_src_{1,3,5}.f)

# --- the five conflicts -------------------------------------------------------
cp "$R/flists__tidelink_fpga_v2.flist"                     flists/tidelink_fpga_v2.flist
cp "$R/flists__tidelink_top_full_asic_v2.flist"            flists/tidelink_top_full_asic_v2.flist
cp "$R/cocotb__tidelink_a2l_replay_cdc__dut_src_1.f"       cocotb/tidelink_a2l_replay_cdc/dut_src_1.f
cp "$R/cocotb__tidelink_a2l_replay_cdc__dut_src_3.f"       cocotb/tidelink_a2l_replay_cdc/dut_src_3.f
cp "$R/cocotb__tidelink_a2l_replay_cdc__dut_src_5.f"       cocotb/tidelink_a2l_replay_cdc/dut_src_5.f

# --- the file git did NOT flag (row 6) ---------------------------------------
cp "$R/cocotb__tidelink_a2l_replay_cdc__dut_src.f"         cocotb/tidelink_a2l_replay_cdc/dut_src.f

# Stage BY NAME, never `git add <dir>` — a directory add has swept an unrelated
# fix into a commit in this repo before.
git add flists/tidelink_fpga_v2.flist \
        flists/tidelink_top_full_asic_v2.flist \
        cocotb/tidelink_a2l_replay_cdc/dut_src_1.f \
        cocotb/tidelink_a2l_replay_cdc/dut_src_3.f \
        cocotb/tidelink_a2l_replay_cdc/dut_src_5.f \
        cocotb/tidelink_a2l_replay_cdc/dut_src.f

git status --short          # expect: no remaining U* entries
# then run §5 BEFORE committing
```

---

## 5. Verification — run all of this before `git commit`

### 5.1 No conflict debris

```bash
git grep -nE '^(<{7}|={7}|>{7})' -- '*.flist' '*.f'      # => no output
git diff --name-only --diff-filter=U                      # => no output
```

### 5.2 **Resolved-set equality — the merge did not change what gets compiled**

This is the check that matters. It proves both shipping netlist selectors resolve to
exactly the same source list before and after the merge.

*Prerequisite:* `scripts/flist_semantic.py` must be present in the worktree you run this in.
If it has not landed on the trunk yet, point at wherever it lives, e.g.
`python3 /home/dam1n19/SoCLabs/tidelink/scripts/flist_semantic.py --root "$PWD" key …` — the
tool-free fallback below needs nothing but `sed` and `sha256sum`.

```bash
cd /home/dam1n19/SoCLabs/tidelink-consolidated

# (a) semantic key, staged (post-merge) vs ours (pre-merge)
for f in flists/tidelink_fpga_v2.flist flists/tidelink_top_full_asic_v2.flist; do
  git show :"$f" > /tmp/post.$$ ; git show 321edbf:"$f" > /tmp/pre.$$
  echo "$f"
  echo "  pre  $(python3 scripts/flist_semantic.py key /tmp/pre.$$)"
  echo "  post $(python3 scripts/flist_semantic.py key /tmp/post.$$)"
  python3 scripts/flist_semantic.py diff /tmp/pre.$$ /tmp/post.$$ \
    && echo "  SEMANTICALLY IDENTICAL" || echo "  *** CHANGED — STOP ***"
  rm -f /tmp/pre.$$ /tmp/post.$$
done
```

Expected, and these are hard-pinned values — anything else means the resolution was applied
wrongly:

```
flists/tidelink_fpga_v2.flist            pre = post = e83b9e9bf225ffc0
flists/tidelink_top_full_asic_v2.flist   pre = post = fb2fb81b55d6ef3a
```

Tool-free fallback (same conclusion, no dependency on `flist_semantic.py`):

```bash
act() { sed -e 's#//.*##' -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' ; }
for f in flists/tidelink_fpga_v2.flist flists/tidelink_top_full_asic_v2.flist; do
  printf '%-42s pre=%s post=%s\n' "$f" \
    "$(git show 321edbf:"$f" | act | sha256sum | cut -c1-16)" \
    "$(git show :"$f"        | act | sha256sum | cut -c1-16)"
done
# flists/tidelink_fpga_v2.flist            pre=ca1dd23ea2df2bfd post=ca1dd23ea2df2bfd
# flists/tidelink_top_full_asic_v2.flist   pre=2e628c7d5cef6289 post=2e628c7d5cef6289
```

Fully expanded set check (belt and braces — proves the *resolved set* is the same; prints
`188 entries` for both files, counting the `+incdir+`/`+define+` lines alongside the paths.
`source ./set_env.sh` first so `${CMSDK_DIR}` &co. expand — though since both sides expand
in the same environment, the comparison is valid either way):

```bash
for f in flists/tidelink_fpga_v2.flist flists/tidelink_top_full_asic_v2.flist; do
  git show 321edbf:"$f" | act | envsubst | sort -u > /tmp/pre.lst
  git show        :"$f" | act | envsubst | sort -u > /tmp/post.lst
  if diff -q /tmp/pre.lst /tmp/post.lst >/dev/null; then
    echo "$f: IDENTICAL resolved set ($(wc -l < /tmp/pre.lst) entries)"
  else
    echo "$f: *** RESOLVED SET CHANGED — STOP ***"; diff /tmp/pre.lst /tmp/post.lst
  fi
done
rm -f /tmp/pre.lst /tmp/post.lst
```

### 5.3 The payload actually landed

```bash
# theirs' RTL won all three overrides
for n in 1 3 5; do
  printf 'V2_%s staged=%s theirs=%s\n' "$n" \
    "$(git rev-parse --short=10 :src/rtl/local_overrides/WlinkGenericFCReplayV2_$n.v)" \
    "$(git rev-parse --short=10 28409f5:src/rtl/local_overrides/WlinkGenericFCReplayV2_$n.v)"
done
# expect staged == theirs: 8a1fabae9e / 9a4b06344c / fbf008e6e8

# the TL-032 revert-aware rewind is present on all three
for n in 1 3 5; do
  git show :src/rtl/local_overrides/WlinkGenericFCReplayV2_$n.v | grep -c 'link_revert)'
done
# expect 1 1 1   (ours pre-merge was 0 0 0)
```

### 5.4 Absolute-path class is fully closed (all four files)

```bash
git grep -nE '^[[:space:]]*/' -- '*.flist' '*.f'          # => no output
git show :cocotb/tidelink_a2l_replay_cdc/dut_src.f         # => ${TIDELINK_HOME}/…_13.v
```

### 5.5 The flist gate

```bash
source ./set_env.sh
python3 scripts/flist_semantic.py check
```

Baseline at `321edbf` was **5 violations**: 4 × `abs_path` (the `dut_src` quartet) +
1 × `missing_target` (`flists/tidelink_eye_visibility.flist:13` →
`${TIDELINK_HOME}/src/rtl/tidelink_lane_checker.sv`, which exists nowhere in the tree).
After this resolution the four `abs_path` findings are gone. **The `eye_visibility` finding
is pre-existing and this merge neither causes nor fixes it** — see §7.3 for the two ways to
land the gate blocking.

### 5.6 Simulation gate

```bash
source ./set_env.sh
# MANDATORY first: the a2l suites' sim_build is NOT in sim_gate_clean_builds and their
# DUT is not a make prerequisite (§7.2), so a cached simv can PASS against pre-TL-032 RTL.
rm -rf cocotb/tidelink_a2l_replay_cdc/sim_build*
make sim_gate_regressions
```

`sim_gate_a2l_replay_cdc_{1,3,5}` gain one new test each
(`test_<node>_revert_recovery_ack_accepted`) which passes *only* with the TL-032 RTL — fix
and proof arrive in the same commit, so do not split them.

### 5.7 Expected non-failure: `merge_guard.sh`

```bash
bash fpga/scripts/merge_guard.sh     # WILL FAIL — pre-existing, not this merge
```

`fpga/scripts/merge_guard.sh:117` greps `local_overrides/WlinkGenericFCSM(\.|_[0-4]\.)v`
across `flists/` and fails on any hit. `flists/tidelink_fpga_v2.flist` has 5 such hits on
**base, ours and theirs alike** (`git show <ref>:flists/tidelink_fpga_v2.flist | grep -c …`
→ 5 / 5 / 5). Do not "fix" it inside this merge; that entangles two unrelated decisions.
Whether it is a live L7 min-CRACK regression or an intentional V2-FPGA divergence is an open
question for David.

---

## 6. Gate wiring

### 6.1 Makefile — wire `flist_semantic.py check` into `sim_gate`

**Do not apply this until §7.3 is settled**, or `make sim_gate` fails immediately on the
pre-existing `tidelink_eye_visibility` finding.

The check must be a **prerequisite, not a `sim_gate` suite**. Every suite inside the
aggregate runs with `SIM_GATE_NONFATAL=1` and merely records a status line, but a bad flist
invalidates the meaning of *every other suite's* result — it has to abort before any compile
starts. It is also pure Python: no EDA licence, no wall clock.

**Edit 1** — extend the `.PHONY` line at `Makefile:273`:

```make
-.PHONY: sim_gate sim_gate_quick sim_gate_env_check sim_gate_summary sim_gate_apb_preempt sim_gate_fch_wdog sim_gate_zeropoke \
+.PHONY: flist_gate flist_driver_check \
+	sim_gate sim_gate_quick sim_gate_env_check sim_gate_summary sim_gate_apb_preempt sim_gate_fch_wdog sim_gate_zeropoke \
```

**Edit 2** — add the targets next to `sim_gate_registry_coverage` (`Makefile:1544`), so the
two deterministic no-sim gates live together:

```make
# STRUCTURE: no tracked flist may contain a machine-absolute path, and every path a
# tracked flist selects must resolve to a file that exists. A wrong flist silently
# changes the netlist; this repo has shipped that defect twice (AUTO_ANCHOR_EN=1'b0;
# header ECC bypassed because a flist pointed at a deps bypass copy).
# Deterministic, no sim, no EDA licence. FLIST_GATE_ARGS=--allow <file> to allowlist.
flist_gate:
	@python3 $(TIDELINK_HOME)/scripts/flist_semantic.py check $(FLIST_GATE_ARGS)

# ADVISORY: is the semantic merge driver actually registered in THIS clone?
# .gitattributes is committed; merge.flist.driver is per-clone local config. An
# unregistered driver is fail-safe (flist merges just conflict), so this never
# fails the gate — it only tells you the automation is not wired here.
flist_driver_check:
	@bash $(TIDELINK_HOME)/scripts/setup_flist_merge_driver.sh --verify || \
	  echo "flist_gate: merge driver not wired in this clone (advisory, not a failure)"
```

**Edit 3** — make it a prerequisite of both aggregates.
`Makefile:1379`:

```make
-sim_gate: sim_gate_env_check sim_gate_clean_builds
+sim_gate: sim_gate_env_check flist_gate sim_gate_clean_builds
```

`Makefile:1465`:

```make
-sim_gate_quick: sim_gate_env_check sim_gate_clean_builds
+sim_gate_quick: sim_gate_env_check flist_gate sim_gate_clean_builds
```

**Edit 4** — `Makefile:1549`, so the authoritative CI front-end proves structure first:

```make
-sim_gate_regressions: sim_gate_registry_coverage sim_gate
+sim_gate_regressions: sim_gate_registry_coverage flist_gate sim_gate
```

**Environment split.** `flist_semantic.py check` reports unset `${CMSDK_DIR}` /
`${CMSDK_FPGA_SRAM_V}` / `${STDCELL_VERILOG}` / `${MEM_PATH}` (51 entries at `321edbf`) as
`unset_var`. `sim_gate` already requires `source ./set_env.sh`, so the default strict mode is
correct there. For any context that may run without the environment, pass
`FLIST_GATE_ARGS=--lenient-env` — hard-failing on a missing `set_env.sh` reproduces the
documented trap where an env problem mimics an RTL break.

*Path note:* the task specifies `scripts/flist_semantic.py`, which is where the tool
currently sits. Its sibling gate `registry_coverage.py` lives in `scripts/ci/`. If the tool
is moved there, change the path in Edit 2 and in `scripts/setup_flist_merge_driver.sh`.

### 6.2 CI — `.gitlab-ci.yml`

Add to the existing `lint` stage, immediately after the `merge-guard` job (whose header
already describes this exact bug class):

```yaml
flist-gate:
  stage: lint
  needs: [clone, preflight]
  before_script:
    - export TIDELINK_HOME="$WORK_DIR"
  script:
    - cd "$WORK_DIR" && make flist_gate
  allow_failure: false
```

CI clones to a per-pipeline-unique path, so it is the environment in which a committed
absolute path is wrong *by construction* — exactly what this gate exists to catch.

### 6.3 `.gitattributes` and the merge driver

Two halves, deliberately separate:

* **`.gitattributes.flist-driver-snippet`** (committed, inert) — the lines to append to a
  repo-root `.gitattributes`. The repo has none at `321edbf`, so applying it creates the
  file. Apply with:

  ```bash
  sed -n '/^# TideLink flist semantic merge/,$p' \
      .gitattributes.flist-driver-snippet >> .gitattributes
  git add .gitattributes
  git check-attr merge -- flists/tidelink_fpga_v2.flist    # => "merge: flist"
  ```

* **`scripts/setup_flist_merge_driver.sh`** (per-clone, never committed) — registers
  `merge.flist.{name,driver,recursive}`. Idempotent; `--verify` reports without changing
  anything; `--unregister` removes it. It **refuses to register a driver whose
  implementation is absent**, because a registered-but-missing driver adds a failing exec to
  every flist merge, while an *un*registered one is fail-safe.

  ```bash
  bash scripts/setup_flist_merge_driver.sh            # register
  bash scripts/setup_flist_merge_driver.sh --verify   # status only
  ```

  `git config --local` writes the shared repo config, so one run covers all 15 linked
  worktrees.

**Fail-safe property, stated so nobody "improves" it away:** `.gitattributes` committed +
driver unregistered ⇒ Git falls back to the built-in text merge ⇒ the file conflicts. A
missing registration can only cost human work; it can never produce a bad auto-resolution.

**Driver contract** (for whoever implements `scripts/flist_merge_driver.sh`; the tool's
`diff --porcelain` mode exists to feed it). Invoked as `%O %A %B %L %P`, cwd = worktree top,
git 2.43 so **no `%S`/`%X`/`%Y`**. `%A` is both ours and the output file. Exit 0 = resolved,
non-zero = conflicted. Decision order, first match wins:

| # | Rule | Action |
|---|---|---|
| R0 | `%P` is on the never-auto-resolve list (see §7.5) | **refuse** |
| R1 | either side canonicalises to an absolute path | **refuse** — never launder a gate violation into a commit |
| R2 | either side fails to parse | **refuse** |
| R3 | `key(ours) != key(theirs)` | **refuse**, print the record delta |
| R4 | keys equal, one side's comment lines are an ordered *subsequence* of the other's | take the **superset** side's bytes, exit 0 |
| R5 | keys equal, comments fork (neither is a subsequence) | **refuse** — silently discarding provenance is how a HW-proven marker gets lost |

On refusal: rebuild a normal conflicted file with
`git merge-file -L 'ours (HEAD)' -L base -L 'theirs (incoming)' --marker-size=$L "$A" "$O" "$B"`,
report to **stderr**, exit 1.

Applied to this merge, R4 auto-resolves `flists/tidelink_fpga_v2.flist` to theirs (ours'
comments are a 0-line subsequence of theirs'), R0 refuses the ASIC flist, and R1 refuses all
four `dut_src*.f`. That is exactly the disposition in §1.

---

## 7. What this does **not** close

### 7.1 The `dut_src*.f` conflict class will recur, and the resolved content is unstable

`cocotb/tidelink_a2l_replay_cdc/Makefile:56` rewrites all four files with a machine-absolute
path at every make parse. So:

* the first `make -C cocotb/tidelink_a2l_replay_cdc` **overwrites the `${TIDELINK_HOME}`
  form committed here** and re-dirties the tree;
* the same add/add conflict reappears on the next cross-worktree merge, forever.

The durable fix (a separate change, not this merge — it touches a Makefile and the index):

1. Make the generator emit a `${TIDELINK_HOME}`-relative path (`$(patsubst
   $(TIDELINK_HOME)/%,%,$(DUT_SRC))` behind a literal `$${TIDELINK_HOME}/`), so every
   worktree generates byte-identical content and the file can never conflict again.
2. Add `cocotb/tidelink_a2l_replay_cdc/.gitignore` for `dut_src*.f`, copying the header from
   the existing `cocotb/tidelink_cdc_tear/.gitignore` which already solves this for the
   sister suite.
3. `git rm --cached cocotb/tidelink_a2l_replay_cdc/dut_src*.f`.

Doing (2)+(3) *without* (1) makes the `-f` targets in
`flists/tidelink_a2l_replay_cdc{,_1,_3,_5}.flist` absent in a clean tree, which the gate's
missing-target rule will flag — so either do all three, or add four allowlist entries
mirroring the two `cdc_tear` ones.

### 7.2 The a2l gate can pass on a stale `simv` — the fix's own proof is not yet trustworthy

Pre-existing in the trunk, **not** introduced by this merge, but it becomes load-bearing
here because these are the suites that prove TL-032:

* `cocotb/flist_deps.mk:33` builds prerequisites with
  `grep -vhE '^[[:space:]]*(//|\#|[+-])'`, which **drops `-` lines**. The DUT reaches the
  suite only via `-f ${TIDELINK_HOME}/cocotb/tidelink_a2l_replay_cdc/dut_src_N.f`, so
  `WlinkGenericFCReplayV2_N.v` never lands in `CUSTOM_COMPILE_DEPS` (measured: 8 leaf paths,
  0 hits for the DUT).
* `sim_gate_clean_builds` cleans an **enumerated** list of directories;
  `cocotb/tidelink_a2l_replay_cdc` is not in it (0 matches) — despite the target's own
  comment claiming it uses a glob that "cannot rot".

Until one of those is fixed, `rm -rf cocotb/tidelink_a2l_replay_cdc/sim_build*` by hand
(§5.6) — a PASS from those three suites is otherwise not proof.

### 7.3 The flist gate cannot go blocking today

`flists/tidelink_eye_visibility.flist:13` references
`${TIDELINK_HOME}/src/rtl/tidelink_lane_checker.sv`, which has never existed in this tree
(`git ls-files | grep -i lane_checker` → only `flists/tidelink_lane_checker.flist`). It
breaks `cocotb/debug/tidelink_peer_aperture` and
`cocotb/debug/tidelink_phy_align_calibrator`. Land §6.1 only after either fixing/removing
that line, or adding an allowlist entry **with a real `expires` date and a named owner** —
not `expires: never`, which converts a real defect into permanent accepted debt.

### 7.4 The gate stamp is poisoned on a clean checkout

`GATE_SHA`/`GATE_DIRTY`/`GATE_STAMP` (`Makefile:242-244`) are immediate assignments
recomputed on every make *parse*, and the aggregate invokes each suite through a separate
recursive `$(MAKE)`. The first a2l sub-make rewrites the **tracked** `dut_src_N.f`, flipping
`git status --porcelain` from empty to non-empty mid-run: suites before it are stamped
`<sha>-clean`, suites after it `<sha>-dirty`, and `sim_gate_summary` then reports
`STALE / CROSS-BRANCH … refusing to report PASS`. CI hits this by construction (fresh clone
at a per-pipeline path). The trunk worktree hides it only because it is already dirty from
unrelated work. §7.1 step (3) closes it; nothing in this merge does.

### 7.5 The conflict list is not the review surface

Everything below merges **without a marker** and gets zero attention from a conflict-driven
review. None of it is resolved by this document:

| Item | Why it needs sign-off |
|---|---|
| `src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v` | Theirs wins unopposed; +24 lines each, one new `link_revert` rewind branch. Both shipping flists already point here ⇒ FPGA **and** tapeout netlist change. Needs LEC / netlist re-verification *despite producing no conflict*. |
| `src/rtl/tidelink_ptp_servo.sv` (`b0e9334`) | Commit says *"No functional intent"*; the hunk's own comment says **"BEHAVIOUR-CHANGING FIX"**. Lock-detect goes from `$unsigned(offset_r) < thresh` to a bidirectional signed magnitude test. `offset_r` is `logic signed [31:0]`, so `servo_locked` previously could not latch on a servo dithering about zero. Observable output bit (`SERVO_STATUS[0]`), in **both** shipping flists. If you split this hunk out for separate sign-off you must move `SRV-016..018` out of `9622c3d` with it, or CI goes red. |
| `fpga/vivado_ip/nanosoc_eth_chiplet_filelist.tcl` (`9622c3d`) | +40 lines under a commit titled "lint": intercepts `nanosoc_region_imem.v` with a local override (hard `error` if absent) and substitutes a generated `sl_ahb_rom.v` with `` `define RAM_PRELOAD ``. Netlist-affecting for the eth-chiplet FPGA package, and an **unpinned cross-repo dependency** via `$env(NANOSOC_ETH_CHIPLET_DIR)`. |
| `src/rtl/fifo/tidelink_fifo_ahb.sv` (`b0e9334`) | Two previously-floating inputs tied to 0 (`hw_credit_consume_vld/_val`). Correct — `_vld` is used *unmasked* at `tidelink_apb_regs.sv:433`, so an undriven `z` propagated X — but it is a defined-value change, not width hygiene. |
| `src/rtl/tidelink.sv` (same tie-off) | In neither V2 shipping flist, but it **is** in `flists/tidelink_ahb.flist`, which CI runs — so it is CI-visible, not unexercised. |
| `src/rtl/tidelink_top.sv` | Modified by **both** sides yet reports no conflict (non-overlapping hunks auto-merged). A silent dual-side auto-merge of the tapeout top. The individual hunks audit as value-preserving; the *combined* result still needs a human. |
| 17-file `src/rtl` lint sweep (`b0e9334`, `9622c3d`) | +300/−70 across shipping RTL incl. 120 changed lines of `tidelink_ptp_servo.sv`. Merges silently because ours never touched those files. Decide explicitly whether a sweep this size lands on the tapeout trunk unreviewed. |

### 7.6 Boundaries the automation must never cross

Even once the driver is wired, these stay human decisions:

* **`flists/tidelink_top_full_asic_v2.flist` is never auto-resolved**, even when the keys are
  byte-identical. The driver verifies *"these two blobs select the same RTL"*, not *"this
  selection is correct"*. For the FPGA flist a wrong selection is caught by sim and by
  hardware; for the tapeout flist the only local test, `sim_gate_asicelab_v2`, runs bare
  `vcs -f … -top tidelink_top` — it proves the flist **elaborates**, not that it selects the
  right files, so any wrong-but-compilable re-point is green. This repo has already shipped
  that defect: `docs/BUG_REGISTRY.yaml` `asic_flist_gap` records that `1aaed00`, whose
  message said "flists re-pointed" (plural), touched only the FPGA flist and left the
  tapeout netlist on the `WlinkEccSyndrome` blanket bypass with every sim green.
  `signoff_policy.auto_signoff_allowed: false`, approver David Mapstone.
* **Never auto-resolve a file containing an absolute path** (R1), regardless of semantic
  equality.
* **Never auto-resolve a documentation fork** (R5).
* **Never** merge two comment blocks into a union, reorder records to make keys match, drop
  an unresolvable record so keys match, rewrite an absolute path during a merge, or consult
  a sibling repository.

---

## 8. Reproduction

Every number in this document came from read-only commands against the shared object DB:

```bash
cd /home/dam1n19/SoCLabs/tidelink-consolidated
git merge-base 321edbf 28409f5                      # 1112d638ddd3…
git diff 1112d63 321edbf -- flists/tidelink_fpga_v2.flist
git diff 1112d63 28409f5 -- flists/tidelink_top_full_asic_v2.flist
git rev-parse 1112d63:src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v \
              321edbf:src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v \
              28409f5:src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v
git show <ref>:cocotb/tidelink_a2l_replay_cdc/dut_src{,_1,_3,_5}.f
python3 scripts/flist_semantic.py key <file>
python3 scripts/flist_semantic.py check --lenient-env
```

Artefacts written by this record, all new, none overwriting anything:

```
docs/STAGE4_RESOLUTION_2026_08_10.md          (this file)
.gitattributes.flist-driver-snippet           (inert; NOT applied to .gitattributes)
scripts/setup_flist_merge_driver.sh           (per-clone registration, idempotent)
scratch_resolved/                             (6 resolved-content artefacts)
```

The real `.gitattributes` and the real `Makefile` were deliberately **not** modified —
applying §6.1 and §6.3 stays a human step.

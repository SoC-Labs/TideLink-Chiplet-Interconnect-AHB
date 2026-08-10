# Stage 4 conflict evaluation — `integ/tidelink-consolidated-2026-08-09` → trunk

**Date** 2026-08-10 · **Audience** project lead · **Status** evaluation + runbook. **The merge has NOT been performed.**

| | |
|---|---|
| ours (trunk) | `321edbf` `integ/tidelink-consolidated-2026-08-07` |
| theirs (incoming) | `28409f5` `ethclone/integ/tidelink-consolidated-2026-08-09` (6 commits: `8104b1e`, `b0e9334`, `9622c3d`, `2fb0f48`, `5d58c2a`, `28409f5`) |
| merge-base | `1112d63` |
| merge result tree (preview only) | `d7befcd` |

---

## 1. Verdict

**The five conflicts are cosmetic. The merge is not.** All five reported conflicts are netlist-neutral and mechanically resolvable; the two shipping-flist conflicts select a bit-for-bit identical source set on both sides (semantic keys measured equal, §2), and the three `dut_src_*.f` conflicts are Makefile-generated scratch. Every netlist-affecting change in this merge arrives **conflict-free**: the TL-032 RTL fix on three replay nodes (both shipping flists already point at those files), a self-declared *"BEHAVIOUR-CHANGING FIX"* to PTP servo lock detection shipped inside a commit whose header says *"No functional intent"*, two previously-floating inputs tied to 0 in shipping+tapeout RTL, and an eth-chiplet FPGA build change filed under "lint". A sixth artefact of the same class as the three conflicted ones — `cocotb/tidelink_a2l_replay_cdc/dut_src.f` — is **not** flagged, because ours equals base, so git silently takes theirs and records an off-repo absolute path (verified in tree `d7befcd`). Two things therefore lead, and neither is in the conflict list: **theirs' ASIC-flist comment asserts the tapeout change is "INERT", which is false** — `syn/asic/fusion-compiler/Makefile:20` reads that exact file as the tapeout flist — and **a reviewer who works the conflict list reviews the five files that do not matter and none of the ones that do.**

---

## 2. The five conflicts (plus the sixth that is not one)

Semantic keys below are from `scripts/flist_semantic.py key`, computed by me on the actual blobs (§4). Equal key ⇒ identical ordered list of sources, `+incdir+` and `+define+` directives, with `${TIDELINK_HOME}` normalised and all other variables kept symbolic.

| file | ours | theirs | resolution | netlist-affecting | proof |
|---|---|---|---|---|---|
| `flists/tidelink_fpga_v2.flist` | 188 active lines; 3 replay nodes re-pointed to `local_overrides` | same 188 lines **+4 provenance comments** | **take theirs verbatim** | **No** | key ours = theirs = `e83b9e9bf225ffc0`; base `1eb669e9b862e20c`. Identical in set *and* order. Ours' comment lines are an ordered subsequence of theirs' ⇒ nothing lost. |
| `flists/tidelink_top_full_asic_v2.flist` | 188 active lines; same 3 re-points | same 188 lines **+9 comments, three of them false/dangling** | **theirs' content, comment hand-rewritten** (artefact ready, §4) | **No** (content); the comment is the risk | key ours = theirs = `fb2fb81b55d6ef3a`; base `fbd4c965cc2ff09a`. Rewritten artefact reproduces `fb2fb81b55d6ef3a` exactly ⇒ zero active-content drift. |
| `cocotb/…/dut_src_1.f` | `/home/dam1n19/SoCLabs/tidelink-consolidated/…/WlinkGenericFCReplayV2_1.v` | `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/…` | **neither** → `${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCReplayV2_1.v` | No | both sides commit a machine-absolute path; file is rewritten by `cocotb/tidelink_a2l_replay_cdc/Makefile` on every make parse |
| `cocotb/…/dut_src_3.f` | as above, `_3` | as above, `_3` | **neither** → `${TIDELINK_HOME}/…/_3.v` | No | as above |
| `cocotb/…/dut_src_5.f` | `…/src/rtl/local_overrides/…_5.v` | `…/**deps/axi-chiplet-controller/logical/wlink**/…_5.v` | **neither** → `${TIDELINK_HOME}/…/local_overrides/…_5.v` | No | **not a path-root variant — a different file.** Theirs names the **pre-fix** deps DUT, residue of a `USE_DEPS_DUT=1` reproduce run. Taking theirs points the B-node self-heal test at the unfixed RTL. |
| ⚠ `cocotb/…/dut_src.f` — **NOT a conflict** | == base (`/home/dam1n19/SoCLabs/tidelink/…_13.v`) | `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/…_13.v` | **neither** → `${TIDELINK_HOME}/…/_13.v` | No | ours==base ⇒ git resolves silently to theirs. `git cat-file -p d7befcd:cocotb/tidelink_a2l_replay_cdc/dut_src.f` prints the nanosoc path. |

**Correction to the operator's claim (2).** These four `.f` files are not hand-written flists with a latent path bug — they are **build artefacts**. `cocotb/tidelink_a2l_replay_cdc/Makefile` contains `$(shell echo "$(DUT_SRC)" > $(DUT_SRC_F))`, expanded at every make *parse* from `TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)`. So the committed bytes never reach VCS under `make`, and the `${TIDELINK_HOME}` form I recommend is **a correct snapshot, not a repair** — it is clobbered on the next parse. It is still the right resolution (it is what the generator computes, and it is the only form that is not wrong in some checkout), but the durable fix is to make the generator emit the `${TIDELINK_HOME}` form and untrack all four files (§6, D3). The operator's *"neither should win"* is right; the reasoning is not, and the scope was short by one file.

---

## 3. What the merge actually brings

### 3.1 The payload that justifies the merge: TL-032

The trunk **already has TL-027** (the ACK-window guard) and already points both shipping flists at the overrides. What is missing is **revert-awareness**, and the trunk's override copies are *fix-less*: for all three of `src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v`, ours' blob **equals base** (`ecf242ae` / `c823d439` / `b39f4e05`) while theirs differs (`8a1fabae` / `9a4b0634` / `fbf008e6`). One-sided ⇒ clean auto-merge, theirs wins, **no conflict marker**. Today the pointer is correct and the pointee is stale.

Mechanism. TL-027 rejects torn/lap-ahead ACK pointers with `a2l_ack_off_max = fifo_io_rbin_ptr - a2l_link_addr` and a window bound. It is not revert-aware. On a NACK-driven replay the FCSM asserts `link_revert` and rewinds the FIFO read pointer to `link_revert_addr`; `a2l_link_addr` advanced only on `a2l_ack_valid` and was never rewound, so `rbin` dropping below it made `off_max` wrap modulo the pointer width to a value above the bound. Every recovery ACK is then rejected, `a2l_link_addr` freezes, `a2l_full` sticks, `app_ready` stays 0, and the AXI write path (AW=`_1`, W=`_3`, B=`_5`) wedges permanently — taking the PS bus with it. The fix is **two lines of logic per node**: `else if (link_revert) a2l_link_addr <= link_revert_addr;` placed ahead of the ACK-advance branch (+24 lines/file, 22 of them comment).

Safety, checked rather than trusted: `link_revert` and `link_ack_update` are decoded from the same 3-bit tag of one FIFO word in `WlinkGenericFCSM_4.v` (`== 3'h2` ACK vs `== 3'h3` NACK/revert), so they are provably mutually exclusive and prioritising revert cannot drop a live ACK. Widths are node-correct: `_1`/`_5` are 4-bit with bound `4'h8`, `_3` is 6-bit with bound `6'h20`, and `link_revert_addr` is declared at exactly the width of `a2l_link_addr` in each file. The non-revert path is untouched. A/B baselines (`tl027only_*.v`, `USE_PREFIX_DUT=1`; deps pristine, `USE_DEPS_DUT=1`) ship with it, so the reproduce-first claim is testable.

`8104b1e` also adds one new test per node into the three **blocking** gate suites `sim_gate_a2l_replay_cdc_{1,3,5}` (Makefile:555–567, listed in `SIM_GATE_ALL_SUITES` at Makefile:1339). Fix and proof arrive in the same commit — splitting them turns the gate red.

### 3.2 Risk verdict on `b0e9334` ("lint: explicit widths and signedness")

**Twelve of fourteen RTL files are genuinely semantics-preserving.** Every changed functional line was read and cleared individually: sized `(W)'(1'b1)` increments (Verilog already zero-extended), `64'(a)` on a `signed [31:0]` input, `32'(d_fwd_r)` on `signed [30:0]`, `{16'h0, chp_adr_paddr}` on a `[15:0]` input, `32'()` widening of narrow unsigned compare operands, named dead-end nets on IDELAY *outputs*, seven removed localparams verified at zero remaining references, and `eye_force_*` `1'b0`→`32'h0` on wires declared `[31:0]`. **Nothing rises to critical on width/signedness grounds.** Two changes are not lint:

- **🔴 `src/rtl/tidelink_ptp_servo.sv` — a behaviour change to an observable output, in the shipping FPGA *and* tapeout ASIC netlist.** The lock compare goes from `if ($unsigned(offset_r) < servo_step_thresh_r[31:2])` to a bidirectional signed magnitude test. `offset_r` is `logic signed [31:0]`, so `$unsigned()` reinterprets rather than takes magnitude: every negative offset read ≥ 2³¹, the compare could never be true, and the else arm cleared `lock_counter_r`/`servo_locked` — `servo_locked` could only latch on N consecutive *positive* offsets, which a servo dithering about zero never produces. Post-merge it latches. **The commit header says "No functional intent"; the comment inside the hunk is headed "BEHAVIOUR-CHANGING FIX".** The fix is correct and its regression tests (SRV-016..018) come with the merge — but they are in a **different commit** (`9622c3d`), and `cocotb/tidelink_ptp_servo` is **not** in `make sim_gate` (`grep -c ptp_servo Makefile` = 0); it runs only in the `.gitlab-ci.yml` cocotb sweep (:362, :371). *If you split this hunk out for sign-off, SRV-016..018 must move with it or the split commit fails CI.*
- **🟠 `src/rtl/fifo/tidelink_fifo_ahb.sv` — two previously-floating inputs tied to 0.** `.hw_credit_consume_vld`/`.hw_credit_consume_val` were absent from the `tidelink_apb_regs` port map. `_val` is masked by `_vld` at `tidelink_apb_regs.sv:427`, but `_vld` is used **unmasked** at `:433` (`|| hw_credit_consume_vld`), where an undriven `z` propagates X in sim and is tool-dependent in synthesis. A real improvement, in both shipping flists — but a defined-value change, not width hygiene, and it belongs in the functional-change record. The same tie-off in `src/rtl/tidelink.sv` is in neither V2 flist but *is* CI-visible via `flists/tidelink_ahb.flist`.

### 3.3 Other conflict-free risk

- **🟠 `9622c3d` — `fpga/vivado_ip/nanosoc_eth_chiplet_filelist.tcl`, +40 lines, netlist-affecting for the eth-chiplet FPGA package, filed under "lint".** It intercepts `*/nanosoc_region_imem.v` and reads a local override instead (hard `error` if absent), and materialises a `` `define RAM_PRELOAD ``-prefixed copy of `sl_ahb_rom.v` into `build/fpga_gen_rom`, flipping `sl_ahb_rom` from `cmsdk_fpga_rom` to `sl_fpga_rom_word`. The override path resolves against `$env(NANOSOC_ETH_CHIPLET_DIR)` — **a different repository**, unpinned, and unset in this environment. It exists in the sibling checkout, so builds work *here*.
- **Newly-running gate targets: none.** `git diff --name-only 1112d63 28409f5 -- Makefile .gitlab-ci.yml docs/BUG_REGISTRY.yaml` returns zero files. No gate target is added, renamed or removed; `sim_gate_registry_coverage` is unaffected. What newly runs: 3 assertions inside 3 existing blocking a2l suites, and SRV-016..018 in the CI-only servo suite. The incoming `lint/hal.tcl` + 8 verilator targets and 24 `pynq_host` scripts are referenced by **neither** the Makefile nor CI — documented but never invoked; they cannot fail a gate, and they should not be described as coverage.
- **No submodule risk.** `git diff --name-only 1112d63 28409f5 -- deps/` is empty. The `deps/tidelink-phy` bump visible in the two-way diff is an *ours-side* change; the merge does not touch the PHY pin. Likewise the ~34 `D` rows in `git diff HEAD 28409f5` are ours-side additions a merge preserves, not deletions. True incoming payload: 67 files.

---

## 4. The automation

Four new files, all currently **untracked and living in the `/home/dam1n19/SoCLabs/tidelink` worktree, not in the trunk worktree**. No existing repo file, `.gitattributes`, `Makefile` or git config was modified.

| artefact | what it does |
|---|---|
| `scripts/flist_semantic.py` | Semantic model of a flist: strips comments/blanks, classifies each line into an ordered `(kind, value)` record (`src` / `incdir` / `define` / `include` / `abs`), expands **only** `${TIDELINK_HOME}` and keeps `${CMSDK_DIR}` etc. symbolic so equality is machine-independent. Subcommands `normalise`, `key`, `diff`, `check`. Order is preserved and never deduped — `$unit` headers must compile first. Comments are stripped **before** expansion (six ASIC comment lines contain `$unit`). |
| `scripts/git_merge_flist.sh` | The git merge driver (`%O %A %B %L %P`), plus `--preview <ours> <theirs> <base> <paths…>`. Ordered decision procedure: **R0** denylist → REFUSE; **R1** either side contains an absolute path → REFUSE; **R2** parse failure → REFUSE; **R3** semantic keys differ → REFUSE with an index-aligned record delta; **R4** keys equal and one side's comments are an ordered subsequence of the other's → take the superset side; **R5** keys equal but comments forked → REFUSE. On refusal it writes a normal conflict-marked file so your mergetool behaves as usual, and prints the reason to stderr. |
| `scripts/setup_flist_merge_driver.sh` | Idempotent `git config --local merge.flist.{name,driver,recursive}`; `--verify` / `--unregister` / `--force`. Refuses to register a driver whose implementation is absent. |
| `.gitattributes.flist-driver-snippet` | Inert. The two-line block (`*.flist merge=flist`, `*.f merge=flist`) to append to a `.gitattributes` the repo does not yet have. |
| `scratch_resolved/` | Six pre-computed resolved files (both flists + all four `dut_src*.f`), ready to copy in. |

**Measured on the real conflict.** `--preview 321edbf 28409f5 1112d63 <6 paths>` prints:

```
flists/tidelink_fpga_v2.flist                              AUTO(theirs)
flists/tidelink_top_full_asic_v2.flist                     REFUSE(denylist)
cocotb/tidelink_a2l_replay_cdc/dut_src{,_1,_3,_5}.f        REFUSE(denylist)
```

34 negative controls pass. The decisive one is **N2**: `local_overrides/X.v` vs `deps/…/X.v` → `REFUSE(semantic-delta)` — the exact `dut_src_5.f` case the preliminary measurement classified as cosmetic. **N8**: an absolute path refuses even when both sides are byte-identical and not on the denylist. Also covered: order-only change, `+define+` added, `+incdir+` retargeted, a source line commented out on one side, documentation fork, `-y` (exit 2, never a silent skip), `-f` cycle, allowlist reason < 40 chars / expired / stale.

**What it will auto-resolve:** exactly one class — two flist versions whose semantic keys are equal and where one side's comments are an ordered subsequence of the other's, and which are not on the denylist and contain no absolute path. In this merge that is **one file**, `flists/tidelink_fpga_v2.flist`.

**What it will never auto-resolve — the safety boundary:**
1. **`flists/tidelink_top_full_asic_v2.flist` and the other ASIC/netlist flists, unconditionally, even when the keys are identical.** The driver verifies *"these two blobs select the same RTL"*, not *"this selection is correct"*. For the FPGA flist a wrong selection is caught by simulation and hardware; for the ASIC flist there is no local backstop — the only local test, `sim_gate_asicelab_v2` (Makefile:1281), runs bare `vcs -f … -top tidelink_top` and proves the flist *elaborates*, not that it selects the right files. Any wrong-but-compilable re-point is green. This repo has already shipped this exact defect (`docs/BUG_REGISTRY.yaml` `asic_flist_gap`: `1aaed00` said "flists re-pointed", plural, but touched only the FPGA one — leaving the tapeout on the ECC bypass with every sim passing). `signoff_policy.auto_signoff_allowed: false`, approver David Mapstone; an automated resolution of the tapeout flist is an automated sign-off by another name. Cost of the refusal: one line of output, with the correct answer printed.
2. **Any file where either side contains an absolute path** (R1) — automation must not launder a violation of the gate's own invariant into a commit. This is what puts all four `dut_src*.f` in front of a human.
3. **Any file where the two sides' comments fork** (R5) — semantic equality plus documentation divergence means two engineers recorded different provenance; picking one silently destroys evidence.

Out of scope by design: merging comment blocks, reordering records to make keys match, dropping unresolvable records, rewriting an absolute path during a merge, consulting any sibling repo.

**Two integration gaps you must close before the driver can fire (both verified just now):**
- `setup_flist_merge_driver.sh` defaults `FLIST_MERGE_DRIVER` to **`scripts/flist_merge_driver.sh`**, which does not exist; the driver is **`scripts/git_merge_flist.sh`**. Register with `FLIST_MERGE_DRIVER=scripts/git_merge_flist.sh …` or rename. Left unfixed, the setup script refuses to register — fail-safe, but silent.
- In the trunk worktree right now: no `.gitattributes`, no `merge.flist.driver`, and none of the three scripts present. **The driver will not run during this merge.** That is fail-safe (git falls back to text merge and conflicts), and it is why §5 resolves by hand from the pre-computed artefacts and installs the automation as a *separate* follow-up.

---

## 5. The runbook

Run in `/home/dam1n19/SoCLabs/tidelink-consolidated` on `integ/tidelink-consolidated-2026-08-07` @ `321edbf`. `$TL` = the scripts' current home, `/home/dam1n19/SoCLabs/tidelink`. **Every step's verification failing means stop, not proceed.**

**Step 0 — pre-merge preview.**
```
bash $TL/scripts/git_merge_flist.sh --preview 321edbf 28409f5 1112d63 \
  flists/tidelink_fpga_v2.flist flists/tidelink_top_full_asic_v2.flist \
  cocotb/tidelink_a2l_replay_cdc/dut_src.f cocotb/tidelink_a2l_replay_cdc/dut_src_{1,3,5}.f
```
✅ must print exactly `AUTO(theirs)` for the FPGA flist and `REFUSE(...)` for the other five. ❌ Any other decision line ⇒ the branches moved since this evaluation. Stop and re-measure.

**Step 1 — the merge.** `git merge --no-commit --no-ff 28409f5`
✅ `git diff --name-only --diff-filter=U` lists **exactly the five** files from §2. ❌ A sixth conflict, or a missing one, ⇒ stop.

**Step 2 — the two flists.**
```
git show 28409f5:flists/tidelink_fpga_v2.flist > flists/tidelink_fpga_v2.flist
cp $TL/scratch_resolved/flists__tidelink_top_full_asic_v2.flist flists/tidelink_top_full_asic_v2.flist
```
✅ verify **before** staging:
```
python3 $TL/scripts/flist_semantic.py key flists/tidelink_fpga_v2.flist          # e83b9e9bf225ffc0
python3 $TL/scripts/flist_semantic.py key flists/tidelink_top_full_asic_v2.flist # fb2fb81b55d6ef3a
git show 321edbf:flists/tidelink_top_full_asic_v2.flist > /tmp/asic_ours.flist
python3 $TL/scripts/flist_semantic.py diff /tmp/asic_ours.flist flists/tidelink_top_full_asic_v2.flist  # exit 0
grep -c '<<<<<<<\|>>>>>>>' flists/*.flist   # 0
```
❌ Either key differing from the literal above means the resolution changed the netlist selection. **Stop — this is the tapeout flist.**

**Step 3 — all four `dut_src*.f`, including the unflagged one.**
```
for n in "" _1 _3 _5; do cp $TL/scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src$n.f \
  cocotb/tidelink_a2l_replay_cdc/dut_src$n.f; done
```
✅ `grep -h . cocotb/tidelink_a2l_replay_cdc/dut_src*.f` prints four lines, every one beginning `${TIDELINK_HOME}/src/rtl/local_overrides/`, node numbers 13/1/3/5. ❌ Any `deps/` or any leading `/` ⇒ stop; `deps/` in `_5` is the pre-fix DUT.

**Step 4 — confirm the payload landed and nothing else did.**
```
git rev-parse :src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v   # 8a1fabae… 9a4b0634… fbf008e6…
grep -c 'link_revert)' src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v   # 1 each
git diff --stat HEAD -- deps/                                            # empty
python3 $TL/scripts/flist_semantic.py check --lenient-env | tail -3
```
✅ blobs match theirs; one `link_revert` branch per node; `deps/` untouched; the gate check reports **exactly 1 violation** (the pre-existing `flists/tidelink_eye_visibility.flist:13`) — the four `abs_path` findings are gone. ❌ Any `abs_path` surviving ⇒ Step 3 did not take.

**Step 5 — the stale-simv precondition. Mandatory, not optional.**
```
rm -rf cocotb/tidelink_a2l_replay_cdc/sim_build*
```
✅ directory absent. Rationale: the three a2l suites' DUT arrives via `-f …/dut_src_N.f`, and `cocotb/flist_deps.mk:33` filters `^[[:space:]]*(//|\#|[+-])` — it drops the `-f` line, so `WlinkGenericFCReplayV2_N.v` is **not** in `CUSTOM_COMPILE_DEPS` (measured: the filtered flist contains 0 references to it). `sim_gate_clean_builds` does not cover this bench (0 matches), despite its own comment claiming "A glob cannot rot" — it is an enumerated directory list and it has rotted. **Without this `rm`, a PASS from the three suites that exist to prove TL-032 is not evidence.**

**Step 6 — the gate.** `source ./set_env.sh && make sim_gate`
✅ `sim_gate_summary` reports PASS with a stamp equal to the working tree's `<sha>-<clean|dirty>`; `a2l_replay_cdc_{1,3,5}`, `asic_v2_elab`, `dft_wrapper_elab` all PASS. ❌ `RESULT: STALE / CROSS-BRANCH` means the stamp moved mid-run — do not read the suite lines, re-run clean. **This gate has NOT been run for this evaluation.**

**Step 7 — merge_guard, with its known false alarm.** `bash fpga/scripts/merge_guard.sh`
✅ the **only** FAIL is `flists/tidelink_fpga_v2.flist points FCSM 0-4 at local_overrides`. That condition is present identically on base, ours and theirs (5 hits each) — **pre-existing, not caused by this merge, and must not be "fixed" inside it.** ❌ Any other FAIL ⇒ stop.

**Step 8 — commit.** Message must record: takes theirs on the FPGA flist; takes theirs' content with a corrected comment on the ASIC flist; resolves all **four** `dut_src*.f` to `${TIDELINK_HOME}` form including the one git did not flag; and that `src/rtl/tidelink_ptp_servo.sv` carries a behaviour change to `servo_locked` in shipping+tapeout RTL that arrived conflict-free.

**Follow-up (separate commit, not this merge):** copy the three scripts into the trunk, add `.gitattributes` from the snippet, register with `FLIST_MERGE_DRIVER=scripts/git_merge_flist.sh bash scripts/setup_flist_merge_driver.sh`, then verify `git check-attr merge -- flists/tidelink_fpga_v2.flist` prints `merge: flist`. Wire `flist_gate` as a **prerequisite** of `sim_gate` (not a suite — suites run `SIM_GATE_NONFATAL=1` and merely record a line; a bad flist invalidates every other result, and it must abort before any compile).

---

## 6. Residual risk / [DECISION — David]

- **[DECISION] D1 — the PTP servo behaviour change.** `servo_locked` / `SERVO_STATUS[0]` changes value in the shipping FPGA *and* tapeout ASIC netlist, inside a commit declaring "No functional intent". Sign it off as a functional change, or split the hunk out of `b0e9334` **together with** SRV-016..018 from `9622c3d` (they fail without the fix). Note the servo suite is not in `sim_gate`, only in CI.
- **[DECISION] D2 — the ASIC flist comment.** The rewritten artefact is ready and byte-verified to change no active content. Review the wording before it lands: it must say the change is **live** on the FC tapeout flow and on `asic_v2_elab`/`dft_wrapper_elab`, and the `docs/TAPEOUT_FOLD_PLAN_2026-08-09.md` citation must either be added as a real file or dropped. Theirs' three false/dangling assertions: "INERT until `build/chip/flist/tidelink_asic.flist` is regenerated" (`syn/asic/fusion-compiler/Makefile:20` reads this exact file directly; `run_lec.tcl` reads the same `$FLIST`), "`make asic-flist`" (**no such target in this repo** — the only repo-wide hit describes the sibling nanosoc-ethernet-chiplet), and a doc that exists on **neither** branch. `build/chip/flist` has zero references tree-wide.
- **[DECISION] D3 — tracked generated files.** The `${TIDELINK_HOME}` resolution is a snapshot; the next `make` parse overwrites it. Durable fix: make the generator emit the `${TIDELINK_HOME}`-relative form, add `cocotb/tidelink_a2l_replay_cdc/.gitignore` (the sister suite `cocotb/tidelink_cdc_tear` already does exactly this), and `git rm --cached` all four. Do all three or the gate's Rule B starts flagging the now-absent `-f` targets.
- **[DECISION] D4 — the eth-chiplet FPGA build change** (`9622c3d`, `nanosoc_eth_chiplet_filelist.tcl`): accept the unpinned cross-repo dependency on `$NANOSOC_ETH_CHIPLET_DIR`, or pin it. Any eth-chiplet checkout without `src/rtl/local_overrides/nanosoc_region_imem.v` now hard-errors during Vivado packaging.
- **[DECISION] D5 — should the FPGA flist auto-resolve?** As built it does (`AUTO(theirs)`); one review recommended explicit sign-off for it too. Adding it to the denylist is one line.
- **Risk R1 — the 17-file conflict-free sweep gets zero review attention.** `b0e9334` + `9622c3d` touch ~17 `src/rtl` files (including 120 changed lines of `tidelink_ptp_servo.sv`) that ours never touched, so they merge silently. All were read and cleared except the two named above — but they were cleared *by reading*, not by simulation.
- **Risk R2 — `src/rtl/tidelink_top.sv` is a silent dual-side auto-merge of the tapeout top.** Both sides modified it; git merged non-overlapping hunks with no conflict. Theirs' hunks were audited as value no-ops (`1'b0`→`32'h0` on `[31:0]` wires; equal-width `(LOG2+1)'(1'b1)` increments), but the **combined** result has not been reviewed by a human.
- **Risk R3 — day-one gate blocker.** `flist_semantic.py check` finds one genuine pre-existing break: `flists/tidelink_eye_visibility.flist:13` → `src/rtl/tidelink_lane_checker.sv`, which has never existed in this tree (breaks `cocotb/debug/tidelink_peer_aperture` and `cocotb/debug/tidelink_phy_align_calibrator`). Fix it or allowlist it **with a real expiry**, not `never`, before `flist_gate` goes blocking.
- **Risk R4 — env trap.** Without `source ./set_env.sh` the gate check reports 51 `unset_var` findings that mimic a break. Wire `sim_gate` with `--lenient-env` and CI with `--strict-env`.

### Not verified — stated plainly

`make sim_gate` **was not run**, and no VCS elaboration, synthesis, LEC or hardware test was performed for this evaluation. All RTL verdicts are from reading source and diffs. Theirs' "128/128 write+read soak, 2026-08-09" provenance claim is not checkable from this repo. Two independent measurements of the *resolved source-set size* disagree (183 vs 184 files for the FPGA flist); both agree the ours/theirs sets are identical, and I verified semantic-key equality directly, so the count discrepancy is immaterial but unresolved. One earlier review reported 189 active lines in the FPGA flist — **it is 188**, measured on all three refs.

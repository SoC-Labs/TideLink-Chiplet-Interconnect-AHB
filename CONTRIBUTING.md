# Contributing to TideLink

**This file is the authority on how a change lands here.** `docs_site/contributing.md` is
the published website page; where the two differ, this file wins.

TideLink is a tapeout-intent subsystem with live hardware attached. The 2026-09-09 rev-2
review is why these rules are written down: it found nine fixes that had reached hardware
and were later shown non-operative, insufficient or harmful, and roughly 49 diagnostics that
could not report the condition they exist to report. Three of those failed toward "fine". A
false red costs a day; a false green ships.

## 0. Before your first change

```bash
source ./set_env.sh      # source it; never execute it, never pipe it
make sim_gate_inventory  # lists suites and cross-checks wiring; runs nothing
```

`set_env.sh` exports the tool homes and vendor-IP roots, and on first run generates the two
XHB500 bridges into `deps/xhb500/generated/`. Without it **every suite fails in 4-5 seconds**
and looks exactly like RTL breakage — read one `imp/sim_gate/<suite>.log` before theorising
about a break. Most V2 PHY work also needs `export TIDELINK_PHY_V2=1`.

## 1. Scope of a change

- **One concern per branch.** No unrelated tooling, doc or formatting churn in an RTL branch
  — a mixed branch cannot be reverted on red without taking the good work with it.
- Prefixes: `fix/`, `feat/`, `integ/`, `analysis/`, `experiment/`, `confirm/`, `test/`,
  `docs/` (the middle four dated).
- Commits: `type(scope): summary`, referencing `TL-0NN` when moving a tracked bug.
- **Cherry-pick, don't rebase onto a live branch.** A rebase onto `main` was rejected on
  2026-07-30 for silently reintroducing a commit that broke eth-chiplet bring-up.
  Cross-check `HEAD..target` by commit hash first.
- **Diff against your own commit's parent** (`git diff <sha>^ <sha>`), never `HEAD~1` —
  other sessions commit while your simulation runs. Never `git add -A`.

## 2. Four arms per fix

Every RTL fix and every recovery change ships with **four** test arms. Three is not enough;
the review's nine non-operative fixes each had one or two.

| Arm | What it must show |
|---|---|
| **RED** | The pristine design **fails** the new test. Run it before your change, on the same build. |
| **GREEN** | The fix **passes** it. |
| **MUTANT** | Detection kept, action disabled — the GREEN test **must fail**. This proves the fix's *action*, not its mere *presence*, is what passed. |
| **SAFETY** | The protection the change touches still works, the recovery's own state **clears**, and a **normal transaction completes after the mechanism fires**. |

**A passing escape test is not a safety test.** A mechanism that escapes a wedge and leaves
its own state latched has traded one wedge for another — assert the clear, and assert the
normal path afterwards. Show RED→GREEN **in one session, on one build**; an already-red test
that stays red is not evidence.

## 3. A must-fail control per diagnostic

**No sticky bit, script verdict, Makefile score, register field or gate is trusted until
someone has watched it go red on a seeded fault.** Seed the fault it exists to catch and
show the report change. This covers obs bits, `.status` lines, checker exit codes, ILA
triggers and coverage thresholds alike.

Found in a single day, each unable to report what it exists to report: a `git_dirty` flag
that meant "could not tell"; an obs bit whose setter did not exist; a dead `or` term in a
link-up condition; a validation script that relabelled an SSH failure as a data mismatch.

Corollaries. **Verify the instrument before the DUT** — a script reporting zero while data
was landing has cost a full debug cycle more than once. And run the must-be-present control
too: grepping a synthesised netlist for a `wire` is an unconditional zero, because synthesis
collapses combinational names.

## 4. Land-readiness — the gate is the authority

These nine came from one incident: a peer-write burst fix landed, reverted, re-landed, its
guard blamed and then exonerated — four commits to land one change whose RTL was correct
throughout. Every wrong turn traced to one stale simulator binary. The log said `up to date`
and nobody read it.

1. **Clean the directory this bench actually builds into, and prove the clean took.** Check
   with `ls -d` which of `build/` and `sim_build*` exist rather than assuming — it differs
   per bench. Confirm a fresh compile in the log, and treat `up to date` on a simulator
   binary as a **failed clean**, not a convenience: flist RTL is not a make dependency, so
   nothing else will tell you. This is what makes every rule below mean anything.
2. **Not land-ready until the owning integration gate is green on a verified-clean
   rebuild.** Isolated-bench evidence and peer sign-off are necessary, never sufficient. Run
   the whole suite set or you will not see what you broke.
3. **Show red-to-green in one session, on one build** (§2). A stale binary makes
   *everything* look already-red.
4. **A fix and its guard are separate commits, each gated on its own — and the combined
   state gets its own gate run** before either is called done. Two independently-green
   changes are not a green composite.
5. **Declare what your prototype harness forced, and what your fix assumes.** Every `force`
   or tie-off is a premise the integration may not supply. Name the shared signals your
   correctness needs to stay stable, so the next person changing that logic knows what they
   stand on.
6. **Whoever lands, runs the gate.** Not the reviewer, not the prototype's author. Sign-off
   is advisory; the gate is authoritative.
7. **Red means revert**, and the revert message carries the diagnosis — what you ruled out
   and with which command. Before blaming a component, re-derive the red from a build you
   have proven fresh.
8. **Apply RTL additions to both the FPGA and the ASIC flist.** A one-sided edit splits the
   brain: one flow elaborates, the other does not. Recovery proven on the FPGA line does
   **not** transfer to ASIC — the ASIC flist sources a recovery-stripped `deps/` where the
   FPGA flist uses `src/rtl/local_overrides/`.
9. **Comment and doc edits are free; behaviour changes to a script, Makefile or RTL module
   are not** — gate them.

## 5. Provenance — what makes a result evidence

- **Never redirect or pipe `set_env.sh`.** `source x | sed` runs the source in a
  **subshell**, so exports never reach your shell, and `>/dev/null 2>&1` hides a failed
  XHB500 generation. Live in CI today at `.gitlab-ci.yml:350` and `:362`; already recorded
  as finding F9 in `docs/gate_reports/06_gate_infra.md:15`.
- **Parse `.status` files, never an aggregate exit code.** The aggregate gate passes
  `SIM_GATE_NONFATAL=1` to *every* suite (`Makefile:1606` onward) so it can
  record-and-continue; a suite's own non-zero exit is deliberately suppressed (see the
  warning at `Makefile:621`). The `.status` file is the result.
- **One sha, one clean/dirty value, clean tree.** Every `.status` is stamped
  `<sha>-<clean|dirty>` (`GATE_STAMP`, `Makefile:252-254`), and `sim_gate_summary`
  (`Makefile:1717`) **refuses to report PASS** if any scored status carries a different
  stamp. Mismatched stamps are a Frankenstein cohort assembled from several commits, not
  evidence.
- **Never edit gate tooling in a worktree that is running a gate.** `GATE_DIRTY` is
  evaluated at parse time and `sim_gate_summary` re-parses in a sub-make, so a tree that
  goes dirty mid-run makes the summary disagree with the statuses it is scoring and refuses
  PASS on a genuinely good run. Use a separate worktree.
- **Never `make -n sim_gate`.** The runner refuses under `-n` (`Makefile:256-262`) because
  it once fabricated `PASS` files for suites that never ran.

## 6. How to run the gate (accurate 2026-09-11)

```bash
source ./set_env.sh
make sim_gate            # full gate: 55 suites + 3 XFAIL sentinels
make sim_gate_quick      # smoke variant
make sim_gate_inventory  # cross-checks wiring; runs nothing
```

**Nothing runs this automatically.** There is no `.github/` directory in the tree and
`origin` is the GitHub remote, so no pipeline exists on the current forge.
`.gitlab-ci.yml:364` does define a `sim-gate` job with `allow_failure: false`, but it
targets the second, non-current GitLab remote. **The gate is run by whoever remembers.** "CI
was green" is meaningless here — there is no CI.

Suites: `SIM_GATE_ALL_SUITES` (55). Sentinels: `Makefile:1564` (3). Artefacts:
`imp/sim_gate/<suite>.log` and `<suite>.status`.

| Status | Meaning | Blocks? |
|---|---|---|
| `PASS` | Ran and passed. | no |
| `FAIL` | Ran, assertions failed. | **yes** |
| `MISS` | No `.status` — the suite never ran. | **yes** |
| `XFAIL` | Known-defect sentinel: defect present and **unchanged**. Never a pass. | no |
| `XCHG` | Sentinel behaviour changed, either direction. | **yes** |
| `XERR` | The sentinel harness itself broke. | **yes** |

**A trustworthy result:** every `.status` carries the same `<sha>-clean` stamp; that sha is
the commit you are landing; the tree was clean for the whole run; `sim_gate_inventory`
reports every declared suite invoked; and the summary prints `ALL SUITES PASS @ <stamp>`.
Anything else — including `STALE / CROSS-BRANCH` — is not a pass, and a `-dirty` stamp is
not a pass however green the lines above it look.

Other gates: `make farm_gate` (**mandatory before any farm build**), `make -C lint
lint-each`, `make -C cdc cdc MODULE=tidelink_top`, `make sim_synth_mode`, `make xdc_lint`.

## 7. Hardware claims need artefacts

A claim that something was validated on hardware must:

1. **Name the vehicle.** Not interchangeable; a result on one does not transfer to another:
   `kr260-pair-onchip` (two dies, one bitstream), the two-board eth-chiplet pair,
   `kr260-pair-nptp` / `-ptp` / `-flip`, pynq-z2, or ASIC-mirror simulation. `fpga/targets/`
   lists them.
2. **Point at files on disk that must exist if the claim is true** — build manifest
   (`<bin>.manifest.json`), bring-up/autonomy log, soak log, register readback. Paths, not
   impressions.
3. **Be checkable by someone else** re-running `stat` on those paths.

A subagent once fabricated a complete deploy-and-soak pass; no corroborating files existed.
Artefact checking is what caught it. Never relay a hardware-validation claim — yours or an
agent's — without checking the artefact that must exist if it is true.

`make sim_gate` must be green **before any farm build and before any hardware deploy**. A
sim-discoverable bug once burned 75 minutes of farm and deploy time.

## 8. Reachability claims

**A reachability claim finishes at the hop that could refute it, not the hop that confirms
it.** If you claim a path is reachable, walk to the hop that would prove it is not. If you
claim nothing reaches a block, enumerate every initiator and check the enabling term — not
the first one that agrees with you. "Nothing on a shipping path reads cross-die" survived
review until someone enumerated the initiators and found five, plus an enable with no write
term. Two sessions made this error in opposite directions on one day.

## 9. Registry discipline

`docs/BUG_REGISTRY.yaml` is the single source of truth (42 entries; lifecycle `open →
root_caused → fix_built → sim_proven → hw_proven → signed_off`).

- **Do not reuse an ID.** A retired `TL-0NN` stays retired.
- **`sim_proven`** requires the four arms of §2 and a `verification.sim_test` naming a test
  a script can resolve.
- **`hw_proven`** requires an **evidence path a script can `stat`** and a **required vehicle
  field** naming which §7 vehicle produced it. The schema carries no `vehicle` key yet — add
  one to the `verification` block; a status that does not say which vehicle is not
  hardware-proven.
- **`signed_off` is the approver's, never the author's.**
  `signoff_policy.auto_signoff_allowed: false` and `claude_max_status: hw_proven` are set in
  the file. Anything that changes the netlist on the tapeout trunk, pushes to a public
  default branch, or is a rig or architecture decision is a **decision** and is never
  auto-signed.
- **Never write an unverified hypothesis into the repo as if measured.** Mark it
  `UNVERIFIED`; speculation committed as fact returns as circular self-corroboration.

## 10. Board etiquette

- **Lease status first, acquire alone, then work.** Run `status`; run `acquire` as its own
  command; only then operate the board.
- **Never chain a lease acquisition with board operations in one shell call.**
- **Confirm the lease is GRANTED, not queued** — a queued lease looks alive and you will
  flash over someone else's session (`docs/BOARD_DEPLOY_RUNBOOK.md:39`).
- **Never reload the programmable logic on a live link.**
- Remote power-cycle works; never ask for a bench trip.

## 11. Vendor IP is read-only

**Never modify, write, edit, delete, move, copy over, `chmod` or otherwise alter anything
under the shared IP-library trees** (the roots behind `CMSDK_DIR`, `XHB500_IP_DIR` and
`ARM_IP_LIBRARY_PATH`). They hold lab-wide vendor collateral; an edit silently corrupts
builds across the whole lab. Read access is expected and fine. Same for submodules under
`deps/`: never edit in place.

If a fix appears to require a change there:

1. Copy the affected file into `src/rtl/local_overrides/`.
2. Re-point the relevant flist(s) at the local copy — **both** FPGA and ASIC.
3. Document the deviation in the file header, naming the bug it fixes.

If a setup script resolves to a path under those trees, treat the destination as
authoritative and change the project-side wrapper, not the file it points at.

Refer to these locations **by variable, never by absolute path** — a literal path is an
inventory of which PDK and IP this site is licensed for. The same holds for credentials,
board IPs, vendor release-coded drop names, EDA install paths and `/home/<user>` paths: none
belong in a tracked file. Use `site.env.example` as the template for site-local values.

## 12. Definition of done

- [ ] One concern only; no unrelated churn (§1).
- [ ] RED shown on the pristine design, same build (§2).
- [ ] GREEN shown with the fix (§2).
- [ ] MUTANT arm written, and the GREEN test fails under it (§2).
- [ ] SAFETY arm: touched protection still works, recovery state clears, normal transaction
  completes after the mechanism fires (§2).
- [ ] Every new diagnostic has a must-fail control someone watched go red (§3).
- [ ] Build directory cleaned, fresh compile confirmed in the log (§4.1).
- [ ] Fix and guard separate commits; combined state has its own gate run (§4.4).
- [ ] Harness forcings and assumed shared signals declared (§4.5).
- [ ] RTL added to both FPGA and ASIC flists (§4.8).
- [ ] `make sim_gate_inventory` reports every declared suite invoked (§6).
- [ ] `make sim_gate` run by the person landing, on a clean tree; every `.status` carries
  the same `<sha>-clean` stamp (§5, §6).
- [ ] Any hardware claim names its vehicle and cites artefact paths that exist (§7).
- [ ] Any reachability claim taken to the hop that could refute it (§8).
- [ ] Registry updated: no reused ID, evidence path stat-able, vehicle named, sign-off left
  to the approver (§9).
- [ ] No credential, board IP, vendor drop name, EDA/PDK path or `/home/<user>` path added
  to a tracked file (§11).

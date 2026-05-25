# TideLink Branch + Worktree Cleanup Proposal (2026-05-24)

**Author:** Agent L (consolidation pass)
**Status:** PROPOSAL ONLY — nothing deleted yet. User must approve every action.

Snapshot taken on `main @ f6a7d19`. 26 local branches, 21 origin-tracking
branches, 5 worktrees under `/home/dam1n19/SoCLabs/td-bisect/`.

---

## Headline findings (READ FIRST)

1. **TWO worktrees have uncommitted changes that would be LOST if removed.**
   These are real fixes, not stale edits. See §"Uncommitted work in worktrees"
   below. Decide whether to commit, stash, or carry forward before any
   `git worktree remove`.

2. **Seven branches are local-only (no origin remote).** Of these, three
   are recent b19/b23 attempts that may have useful learnings; the rest are
   draft / RC. Decide push-or-delete per branch.

3. **The "b14..b23" failed-RTL band can be archived collectively** — they
   all attempted to fix a hypothesis (Agent A or earlier) that is now
   definitively ruled out by b23. No reason to keep them on origin once
   their lessons are captured in `docs/PHC_PHASE1_DIAGNOSIS_2026_05_24.md`.

---

## Uncommitted work in worktrees (PRESERVE before any worktree removal)

### `/home/dam1n19/SoCLabs/td-bisect/v1-consolidated/` — branch `feat/v1-consolidated`

```
modified:   pynq_host/scripts/phc_ila_capture.tcl  (+15 / -6)
```

**This is the ILA capture pipeline fix that came up on 2026-05-24.** Three
Vivado-2025.2 portability fixes:
- JTAG clock 15 MHz → 6 MHz (avoid Xicom 50-38 vs 25 MHz hclk).
- `CONTROL.MAX_DATA_DEPTH` dropped in 2025.2 (now set at insert-time).
- `wait_on_hw_ila -timeout` not honoured under 2025.2 + cs_server — wall-clock
  sleep + force-trigger fallback.

**RECOMMENDATION:** commit on its own dedicated branch
`feat/phc-ila-capture-vivado2025-fix` off `main`, push, open MR. Do NOT
leave in worktree.

### `/home/dam1n19/SoCLabs/td-bisect/b22-ila/` — branch `feat/phc-ila-submodule-b22`

```
modified:   fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc
modified:   fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_drc.xdc      (+159 / -0)
modified:   fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc   (+30 / -23)
```

**XDC changes supporting the ILA build.** Unclear whether already merged on
b22 tip or whether they're additional WIP. **ACTION:** user to inspect and
decide. If they're the difference between "ILA built clean" and "ILA broke
the design", they're load-bearing for the working ILA pipeline.

---

## Worktrees (`git worktree list`)

| Worktree | Branch | Recommendation |
|---|---|---|
| `/home/dam1n19/SoCLabs/tidelink` | `main` (cur) | **KEEP** — primary tree |
| `/home/dam1n19/SoCLabs/td-bisect/b20-slave-rx` | `feat/phc-slave-rx-fix-b20` | **REMOVE** after branch decision (clean) |
| `/home/dam1n19/SoCLabs/td-bisect/b22-ila` | `feat/phc-ila-submodule-b22` | **HOLD** — has uncommitted XDC changes (above) |
| `/home/dam1n19/SoCLabs/td-bisect/b23-fsm-harden` | `feat/phc-fsm-harden-b23` | **REMOVE** after archiving branch (clean) |
| `/home/dam1n19/SoCLabs/td-bisect/b23-trigger-replicate` | `feat/phc-trigger-replicate-b23` | **REMOVE** after archiving branch (clean) |
| `/home/dam1n19/SoCLabs/td-bisect/v1-consolidated` | `feat/v1-consolidated` | **HOLD** — has uncommitted ILA capture fix (above) |

---

## Branch-by-branch categorisation

Categories: **(a) HISTORICAL FAILED RTL** — delete candidate. **(b) MR-READY** — keep, land on main. **(c) IN-USE WORKTREE** — keep. **(d) INFRASTRUCTURE** — keep (ILA, sim repro, etc.). **(e) UNCLEAR** — flag for user.

### Builds #14–#23 (failed RTL fix attempts for the PHC bug)

| Branch | Origin? | Tip | Category | Recommendation |
|---|---|---|---|---|
| `feat/phc-ila-debug` | yes | `0feef13` mark_debug RX | (a) HISTORICAL | **DELETE both local + origin** after merging the lessons into diagnosis doc (already done). |
| `feat/phc-ila-debug-b15` | yes | `5b5b1fc` WHS -7.94 ns | (a) HISTORICAL | **DELETE** both. |
| `feat/phc-ila-debug-b16` | yes | `5d11e90` trigger replicated | (a) HISTORICAL | **DELETE** both. |
| `feat/phc-trigger-register-b17` | yes | `41c0f24` registered trigger | (a) HISTORICAL | **DELETE** both. |
| `feat/phc-handshake-fix-b18` | yes | `e27827c` handshake + WHS | (a) HISTORICAL | **DELETE** both. |
| `feat/phc-minimal-fix-b19` | local-only | `e5953b4` DCP+timing preservation | (e) UNCLEAR | The DCP+timing preservation in `fpga/build_design` may be infrastructure worth keeping. **REVIEW** — if the preservation tcl is non-trivial, cherry-pick to a `feat/build-design-dcp-preservation` branch off main, then delete. |
| `feat/phc-slave-rx-fix-b20` | yes | `51f53d0` replica defence + Agent T XDC | (e) UNCLEAR | Agent T XDC fix may be load-bearing. **REVIEW** — diff vs main, cherry-pick XDC parts, delete RTL parts. |
| `feat/phc-ila-capture-b20-claimed` | local-only | `2e38d3c` TRIGGER_VALUE for multi-bit FSM | (d) INFRASTRUCTURE | **CHERRY-PICK** the `TIDELINK_TRIGGER_VALUE` env var support into the ILA-capture infrastructure branch, then delete. |
| `feat/phc-manual-replicate-b21` | yes | `7392411` Python 3.6 Protocol fix | (a) HISTORICAL — RTL part. **(b) CHERRY-PICK** the Python 3.6 fix | The Protocol/typing_extensions fix is now on main as `f6a7d19`/`8451260`. Verify, then **DELETE** both. |
| `feat/phc-ila-submodule-b22` | yes | `e8c9b83` submodule bump ae2ca38→8a4fcf5 | (b) MR-READY — submodule bump is the working ILA wiring | **LAND** the submodule bump on main as part of a "PHC ILA infrastructure" MR. After landed, **DELETE** both. (Hold pending uncommitted XDC review — see above.) |
| `feat/phc-fsm-harden-b23` | local-only | `58b7de0` `(* keep *) (* dont_touch *)` on FSM | (a) HISTORICAL — disproven | **DELETE**. Lesson captured in diagnosis doc. |
| `feat/phc-trigger-replicate-b23` | local-only | `e8c9b83` (same tip as b22) | (a) HISTORICAL | **DELETE** — same tip as b22, confusing duplicate. |

### Pre-2026-05-24 failed attempts

| Branch | Origin? | Tip | Category | Recommendation |
|---|---|---|---|---|
| `feat/phc-slave-rx-fix` | yes | `167923a` dont_touch ptp_enable_r (Agent Q) | (a) HISTORICAL — Bug-#3-class disproven | **DELETE** both. |
| `feat/phc-rx-counters` | yes | `154e298` RX_DIAG counters | (e) UNCLEAR — slave wiring broken, but the master-side counters worked | **REVIEW**: if RX_DIAG could be made useful (b24 might benefit from working counters), refactor to fix slave decode and re-MR. Otherwise **DELETE** both. |
| `feat/phc-pair-fpga-models` | yes | `fc5c33e` (merged as `a9b1f21`) | (a) MERGED | **DELETE** both — already on main. |
| `feat/sim-repro-phc-hw-bug` | local-only | `a575616` sim repro of TX-stuck bug | (d) INFRASTRUCTURE — sim repro of HW PHC bug | **KEEP** — may be useful as the b24 fix is validated. After b24 PASS, **MR or delete**. |
| `feat/phc-pair-fpga-models` | yes | (above) | — | — |
| `docs/phc-phase1-rca` | local-only | `b51cd1a` Phase-1 RCA proposal | (a) HISTORICAL — RCA disproven, doc superseded by diagnosis doc | **DELETE**. |

### Infrastructure / not PHC-bug related

| Branch | Origin? | Tip | Category | Recommendation |
|---|---|---|---|---|
| `ci/verilator-lint` | yes | `41ca283` verilator-lint CI + WIDTH fixes | (b) MR-READY | **LAND** on main per `SIGN_OFF_STATUS.md` outstanding-work item 4. |
| `xdc/rx-cap-cells-fix` | yes | `b158e1e` | (e) UNCLEAR — tip is just the raw-observations doc commit | **REVIEW**: looks like a stale branch where docs got committed on the wrong head. Confirm no XDC content is unique to it, then **DELETE** both. |
| `feat/cdc-fix-wip` | yes | `7cb67ee` tl_calibration_cdc + audit | (d) INFRASTRUCTURE — deferred V2 per SIGN_OFF | **KEEP** — flagged as V2-deferred in SIGN_OFF_STATUS.md table. Rename to `wip/cdc-v2` for clarity? |
| `feat/td-combined` | yes | `57c2810` Vivado-msg gate | (b) MR-READY — the fail-fast Vivado msg gate is a CI-hardening win | **LAND** the gate on main, then **DELETE** both. (See note in MEMORY about this branch carrying the consolidated bring-up state.) |
| `feat/v1-consolidated` | yes | `a972870` WHS-7.94 fix + DCP preservation | (c) IN-USE WORKTREE | **HOLD** — see uncommitted-changes section. After committing the ILA capture fix and landing the WHS+DCP changes (if not already on main), **DELETE**. |
| `feat/v1-fixes-bundle` | yes | `fdb65fd` v1 fixes bundle doc | (e) UNCLEAR — likely sibling of `feat/v1-consolidated` | **REVIEW**: probably superseded by v1-consolidated. Diff and delete the loser. |
| `feat/phc-ila-capture` | yes | `434c569` batch-mode HW Manager capture | (d) INFRASTRUCTURE — the ILA capture pipeline itself | **LAND** on main as part of the PHC ILA infrastructure MR. After landed, **DELETE**. (The TCL script lives in main already; this branch is the harness around it.) |

### Releases / tags

| Branch | Origin? | Tip | Recommendation |
|---|---|---|---|
| `release/v1.0-rc1` | yes | `62aaf89` lane-lock root cause + RTL-freeze checklist | **KEEP** — historical release branch. |
| `release/v1.0-rc2` | local-only | `0dac434` v1.0-rc2 bundle | **PUSH or DECIDE** — listed as "user-deferred force-push" in SIGN_OFF. Per user authority. |

---

## Suggested execution order (when user approves)

1. **Preserve uncommitted work** (worktrees `b22-ila` and `v1-consolidated`):
   - Commit `phc_ila_capture.tcl` Vivado-2025.2 fix on a new branch
     `feat/phc-ila-capture-vivado2025-fix` off main.
   - Decide on b22-ila XDC changes (commit on b22 branch, or move to a
     dedicated XDC branch).

2. **Land MR-ready branches** (in order, smallest first):
   - `feat/phc-ila-capture-vivado2025-fix` (just committed in step 1)
   - `ci/verilator-lint`
   - `feat/phc-ila-submodule-b22` submodule bump + ILA wiring (keep the
     ILA pipeline alive on main)
   - `feat/phc-ila-capture` script harness
   - `feat/phc-ila-capture-b20-claimed` (cherry-pick TRIGGER_VALUE env)
   - `feat/td-combined` Vivado-msg fail-fast gate

3. **Cherry-pick useful infrastructure pieces** from otherwise-historical
   branches:
   - `feat/phc-minimal-fix-b19` — DCP+timing preservation tcl (if non-trivial)
   - `feat/phc-slave-rx-fix-b20` — Agent T XDC bits (review)
   - `feat/phc-rx-counters` — if RX_DIAG counter wiring can be fixed

4. **Remove worktrees** (clean ones first):
   - `td-bisect/b20-slave-rx`, `td-bisect/b23-fsm-harden`,
     `td-bisect/b23-trigger-replicate` (all clean).
   - Then `td-bisect/b22-ila` and `td-bisect/v1-consolidated` once their
     uncommitted changes are preserved.

5. **Delete historical PHC-fix-attempt branches** (origin + local):
   ```
   feat/phc-ila-debug
   feat/phc-ila-debug-b15
   feat/phc-ila-debug-b16
   feat/phc-trigger-register-b17
   feat/phc-handshake-fix-b18
   feat/phc-minimal-fix-b19            (post cherry-pick)
   feat/phc-slave-rx-fix-b20           (post cherry-pick)
   feat/phc-ila-capture-b20-claimed    (post cherry-pick)
   feat/phc-manual-replicate-b21
   feat/phc-fsm-harden-b23             (local-only)
   feat/phc-trigger-replicate-b23      (local-only)
   feat/phc-slave-rx-fix
   feat/phc-rx-counters                (post cherry-pick or decline)
   feat/phc-pair-fpga-models           (already merged)
   docs/phc-phase1-rca                 (local-only, superseded)
   ```

6. **Optional rename for clarity:**
   - `feat/cdc-fix-wip` → `wip/cdc-v2`
   - `feat/sim-repro-phc-hw-bug` → `infra/sim-repro-phc` (after b24 PASS)

---

## Branches NOT to touch without explicit user direction

- `main` — primary
- `release/v1.0-rc1` — historical release
- `release/v1.0-rc2` — user-deferred force-push (see SIGN_OFF "Known-deferred")
- `feat/v1-consolidated` — has uncommitted work + listed in MEMORY as carrying state
- Any branch on `axi-chiplet-controller` submodule (separate repo)

---

## Summary

- **2 worktrees with uncommitted changes** — preserve first.
- **~13 PHC-fix-attempt branches** can be deleted after their lessons are
  captured in `docs/PHC_PHASE1_DIAGNOSIS_2026_05_24.md` (done).
- **~5 branches are MR-ready** and should be landed before deletion.
- **~3 branches are infrastructure** worth keeping or renaming.
- **2 release branches** stay as-is unless user directs otherwise.

Awaiting user approval before any `git branch -D`, `git push --delete`, or
`git worktree remove`.

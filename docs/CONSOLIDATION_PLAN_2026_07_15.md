# TideLink — Consolidation & Delivery Plan (2026-07-15, rev 2)

**Goal:** one integration branch, all agents stopped, then a sequenced path to
(1) reliable communication across all nodes and all FC channels, (2) autonomous
zero-poke bring-up, (3) PTP validated on the KR260 pair, (4) ASIC feature-complete.

**rev 2 changes:** hard END STATE defined (ONE worktree, minimal tags/refs);
the **separated-PHY V2** (`deps/tidelink-phy`) is the sole active implementation
line; archive strategy switched from per-branch tags to a single graveyard tag.

Companion docs: `docs/MERGE.md` (convergence contract, 07-06),
`td-bisect/phase2-pblock/docs/STABILITY_PLAN_2026_07_15.md` (P-A/P-B separation).
This doc supersedes both for *sequencing*; they remain the evidence record.

---

## 0. END STATE (the definition of "cleaned up")

| Axis | Now | End state |
|---|---|---|
| Worktrees | **65** (main + td-bisect/* + td-scratch/* + .claude/worktrees/*) | **1** — `~/SoCLabs/tidelink` on the integration branch |
| Branches | ~80 local | ≤5: `main`, `integ/consolidation-2026-07` (until it becomes main), short-lived feature branches only |
| Tags | per-branch archive tags would add ~45 | **1 graveyard tag** (`archive/2026-07-consolidation`) + certified-bitstream tags only |
| Stashes | 24 (mostly May-era) | 0 (folded into the graveyard commit or dropped) |
| PHY | forked submodule, 2 unpushed tips, V1/V2 dual flists | **separated-PHY V2 from `deps/tidelink-phy`, single pushed branch, sole active line.** V1 stays param-quarantined (elab-only legacy gate, per standing rule — not deleted, not built by default) |
| CI | gates `allow_failure: true` | sim_gate + merge_guard + farm_gate **blocking** |

**Tag/ref mechanics (why 1 tag is enough):**
- Branches whose tips are **ancestors of a kept branch need NO tag** — deleting the
  ref loses nothing (commits are retained via ancestry). That covers the ~35
  CONTAINED branches.
- The genuinely-unmerged-but-dropped tips (stale experiments, refuted fixes) are
  preserved by **one octopus "graveyard" commit** whose parents are every dropped
  tip, tagged once: `archive/2026-07-consolidation`. One ref keeps every object
  reachable and fetchable forever; `git log --oneline archive/2026-07-consolidation^@`
  lists the graveyard. Stash entries worth keeping are committed and added as
  parents of the same commit; then `git stash clear`.
- Same treatment inside `deps/tidelink-phy` (its own single graveyard tag).

## 1. Current status (one paragraph per axis)

- **Recipe-mode bring-up:** CERTIFIED 40/40 fresh-POR on Z2 silicon (link + A→B +
  B→A byte-exact + doorbell). The shippable fallback. `merge_guard` asserts its
  ingredients survive every merge.
- **Autonomous (zero-poke) bring-up:** link 10/10, A→B 7/10, doorbell 4/10,
  **B→A 0/10**. Root-caused (P-A): master die_a holds its own RX-commit while
  `autonomy_armed`; fix = *retire autonomy at verified anchor* (`wip/b2a-fix`).
  **Sim is blind to this fix — silicon soak is the only gate.** Deeper cause:
  I2C autoneg NACK hard-codes SLAVE on both dies → role must come from a STRAP.
- **Physical layer (P-B):** lane-7 SYNC failure and the build lottery are the
  **capture-clock tree** (residual LUT, fanout 372): measured ~7 ns clock skew vs
  0.095 ns data skew. Fix = clock-mux hoist + shared BUFGs on `phaseB/attack`.
  Proof = rebuild-variance soak (≥3 independent builds).
- **KR260:** 4 single-die targets + pair-on-chip build clean; EXTREFCLK built;
  **never run on hardware**; inherits the unfixed capture-clock defect, no pblock;
  PTP re-add is one gated commit (`feat/ptp-fpga-readd`). ~395 lines of KR260-pair
  work **uncommitted** in the main worktree.
- **ASIC:** chip-killers known: wrong V2 deskew in ASIC flist + lane mask 0xFF,
  ASIC flow defaults to V1, CI gates `allow_failure`, straps missing
  (`NEGO_CFG_RESET`, `apb_debug_unlock_i`, `mask_hs_bypass_i` tied 1'b1),
  RX-FIFO latent twins. Empty-RX-FIFO phantom pop fixed + gated.

## 2. Repo topology (the consolidation problem)

```
fork b55cb59 (Q1 quiesce)
├── wip/tapeout-candidate @743be78   ← SUPERSET: unified-candidate, autonomous-recon,
│     ASIC fixes (V2 default, FCSM 0-4 flists, a405809 revert), infra/* gates,
│     feat/dieb-clock-fix-wip @2449098, integ, main.           phy pin: bbd094c
├── wip/phase2-pblock @20e778e (+75) ← silicon-proven: RX-FIFO fix f9b94b7,
│     XHB restore, drain guard 0044bef, harnesses.             phy pin: bbd094c
│     └── wip/b2a-fix (P-A) · wip/sim-lottery-instrument · phaseB/attack (P-B)
└── dieb lineage post-2449098 (NOT in tapeout-candidate):
      single-32b bus-access commits → feat/kr260-port → feat/epoch-anchor-ab →
      feat/kr260-extrefclk → feat/kr260-pblock
      + feat/kr260-pair-onchip, + feat/ptp-fpga-readd.         phy pin: 9f4953c
```

**Submodule fork (blocking):** `deps/tidelink-phy` has TWO divergent tips off
9f4953c — `bbd094c` (cal_in_hold, autonomy line) and `655e24d`
(epoch-anchor-selectable, KR260 line) — **all unpushed**. Push + reconcile FIRST;
until then no fresh clone or farm build of either lineage can materialize the PHY.

**PHY policy (rev 2):** the separated-PHY **V2** implementation in
`deps/tidelink-phy` is the single source of truth for all PHY RTL. Consolidation
must (a) merge the phy fork onto one branch, push it, and pin the superproject to
it; (b) remove/redirect any in-tree duplicate PHY sources the flists still reach
(the ASIC-deskew chip-killer is exactly this class of bug); (c) make every default
build path — FPGA packaging, ASIC flist, sim — resolve to submodule V2. V1 remains
param-quarantined with an elab-only gate (standing rule: don't delete
USE_CLKBUF/USE_IDELAY/V1 paths).

## 3. Branch disposition

**MERGE (code lines → the one integration branch):**

| Branch | Carries | Gate before trust |
|---|---|---|
| `wip/tapeout-candidate` | BASE — ASIC fixes nothing else has | merge_guard + sim_gate |
| `wip/phase2-pblock` | silicon-proven fixes | merge_guard (fixes must survive) |
| `wip/b2a-fix` | P-A retire-autonomy fix | **silicon soak N=40** (sim blind) |
| `phaseB/attack` | P-B capture-clock hoist | rebuild-variance soak ≥3 builds |
| `wip/sim-lottery-instrument` | sim repro of beacon/force_always defects | sim only |
| `feat/kr260-pblock` (chain tip) | KR260 port + EPOCH A/B + EXTREFCLK + pblock | KR260 first light |
| `feat/kr260-pair-onchip` | 2-instance single-bitstream pair | its own sim gate |
| `feat/ptp-fpga-readd` | PHC/PTP in -all BD (gated), 1 commit | cherry-pick |
| *uncommitted main-worktree diff* | KR260-pair targets, Makefile+tcl, overlays, kr260_smoke | **commit FIRST** |

**HARVEST (cherry-pick after review, then delete branch+worktree):** agent
worktrees `a19f77e` (V2 doorbell cross test), `a57c905` (autonomous FC data-mode
handoff), `a61fdf3` (Bug-A sticky cal-done), `a69944b` (two-die autonomous I2C
bring-up sim), `aab2468` (**PTP-over-link clock-sync test** — the KR260-PTP
reference), `ad4a959` (UVM byte-exact AHB round-trip); branches
`wip/ci-zeropoke-gate`, `fix/integ-v1-elab`, `feat/xhb-ahb-timeout`,
`wip/deploy-bootpy-guard`, `wip/tool-fixes`, `infra/uvm-ci-reactivation`
(verify vs 2449098), `wip/txoveradvance-simrepro` (review vs merged CDC gate),
`fix/stream-start-loss` (review: silicon status unclear).

**DELETE, no tag (~35 CONTAINED branches — commits retained via ancestry):**
phy-v2 feature stack, merged infra/*, phaseA/*, merge2/merge-dry, zeropoke
branches, a2l-mbox-obs, winscan-stop, exp/epoch-anchor-fix, … (full list =
`git merge-base --is-ancestor` against the kept candidates; re-run before delete).

**GRAVEYARD (single octopus commit + ONE tag `archive/2026-07-consolidation`):**
stale/refuted LIVE tips: `ci/regression-flow`, `exp/v1-route-a`,
`fix/die-b-pad-clk-rx-bufg`, `fix/word-window`, `wip/emio-instrument`,
`wip/iter6-integ`, `wip/iter7-ctrl-extend0`, `wip/diea-merge-claude`,
`wip/apb-arb-onto-integ`, `feat/phy-v2-integration`,
`feat/phy-v2-channels-integration`, `feat/v2-epoch-apb-obs`,
`infra/hwlib-ctypes-bus-access`, `infra/lane-health-preflight` — plus any
stash entries worth keeping (notably `stash@{18}`); then `git stash clear`.

**WORKTREES:** every merge/harvest/graveyard action ends with
`git worktree remove` for that path. Final sweep leaves exactly
`~/SoCLabs/tidelink`; `git worktree prune` + delete `td-bisect/`, `td-scratch/`,
`.claude/worktrees/` directories.

---

## 4. THE PLAN

### Phase 0 — Freeze + unfork the PHY (½ day, no hardware) — DO FIRST
1. Stop all other agents (owner action — done).
2. Commit the uncommitted KR260-pair work + untracked docs on
   `feat/dieb-clock-fix-wip`.
3. **`deps/tidelink-phy`:** push branches for `bbd094c`, `655e24d`, `9f4953c`;
   merge the two tips onto `integ/phy-consolidation-v2` (common parent 9f4953c;
   review deskew/corrector overlap); push. This becomes the ONLY pinned phy ref.
4. Delete the ~35 contained branches + their worktrees (no tags needed).
   **Acceptance:** every remaining branch fetchable + buildable from a fresh
   clone; worktree count ≤ ~15; phy submodule resolves everywhere.

### Phase 1 — One integration branch + collapse (1–2 days, no hardware)
Create `integ/consolidation-2026-07` from `wip/tapeout-candidate`. Merge, in
order, gating each step on `merge_guard` + full `sim_gate` + `farm_gate`:
1. `wip/phase2-pblock` (the one real merge — 75 vs 78 commits, cherry-pick
   twins; resolve toward silicon-proven fixes).
2. KR260 chain tip + `feat/kr260-pair-onchip` + `feat/ptp-fpga-readd` + the
   Phase-0 commit.
3. Harvest list (§3), each a reviewed cherry-pick.
4. Pin `deps/tidelink-phy` → `integ/phy-consolidation-v2`; verify every default
   build path (FPGA package_ip, ASIC flist, sim) resolves PHY RTL from the
   submodule V2 — no in-tree duplicates reachable.
5. **Flip CI to blocking** (sim_gate + merge_guard; land `wip/ci-zeropoke-gate`).
6. **Collapse:** build the graveyard octopus + single tag; delete merged/harvested
   branches; remove all remaining extra worktrees; clear stashes.
**Acceptance:** ONE branch, ONE worktree, ONE archive tag; merge_guard, full
sim_gate, farm_gate, asic_v1_elab + asic_v2_elab green; fresh clone builds.
From here on: short-lived branches off the integration branch only, merged back
within a day, worked in the single checkout.

### Phase 2 — Silicon-prove autonomy P-A on Z2 (1 day, board-bound)
- Adversarial review of retire-autonomy (D2 peer-starvation risk; confirm the
  `ws_anchor_q && ws_verify_q` trigger fires on die_a fresh-POR).
- Include role-from-STRAP (kill the I2C NACK→both-SLAVE trap) and the FC
  data-mode handoff harvest.
- ONE bitstream, zero-poke, **N=40 fresh-POR, all channels**, named md5.
**Acceptance:** B→A 0→passing; A→B + doorbell deterministic; anchor preserved.
The soak becomes a standing silicon gate.

### Phase 3 — Physical determinism P-B (1–2 days, build-bound)
- Build the clock-tree hoist; re-measure lane-7 capture-clock arrival
  (target ≈8 ns sibling arrival, off the LUT/fo-372 route).
- Rebuild-variance soak: ≥3 independent builds, stable autonomous anchor rate.
- Mirror the proven parameter set + pblock into all four `kr260-pair-*` targets.

### Phase 4 — All-nodes / all-FC reliability matrix (overlaps Phase 3)
Build the missing gate: **{die_a, die_b} × {A→B, B→A} × every FC channel
(FCSM 0–4) × doorbell/IRQ**, byte-exact, fresh-POR, autonomous AND recipe, named
bitstream, N=40 on Z2. (FCSM 0–4 flists fixed on the tapeout lineage; no test
exercises them all today. Seed from the doorbell + UVM harvests.) Track
long-burst first-2-words drop + XHB wedge here (xhb-ahb-timeout as backstop).
**Acceptance:** full matrix green N=40, both modes, md5 recorded.

### Phase 5 — KR260 bring-up + PTP (2–3 days, hardware-gated)
Logistics FIRST: KR260s on the rig with fpgahub power-cycle + lease coverage.
1. **First light:** single-die target, `kr260_smoke.py`, manual recipe link.
2. **Pair-on-chip:** zero-poke autonomous on one xck26.
3. **Two-board EXTREFCLK** (mesochronous): recipe then autonomous; Phase-4
   matrix at N≥20.
4. **PTP:** `-ptp` targets; port the PTP-over-link clock-sync sim test to
   hardware; measure offset convergence + servo hold.
**Acceptance:** autonomous bring-up + full channel matrix + PTP offset
convergence on the KR260 pair, both directions, md5 recorded.

### Phase 6 — ASIC feature-complete (1–2 days)
- Chip-killers: single-source V2 deskew from `deps/` in the ASIC flist;
  lane-mask STRAP; `ASIC_PHY ?= _v2` default; straps for `NEGO_CFG_RESET`
  (7'h61), `apb_debug_unlock_i`, `mask_hs_bypass_i`.
- Close RX-FIFO latent twins (held-NONSEQ lock; write-side length-latch).
- sim_gate: flist-resolution equivalence check; fix test_31:601 (enshrines the
  SYNC-clamp bug).
- CDC clean re-run on the consolidated branch.
- **Final certification:** N=40 recipe AND autonomous on the final bitstream +
  ASIC elab/lint/CDC — the tapeout evidence package. Tag the certified
  bitstream (the only new tags this program creates).

## 5. Risks
- P-A fix unprovable in sim → board time is the critical path; serialize board access.
- 29/29 anchor may be a lucky placement → only rebuild-variance settles P-B.
- The phase2↔tapeout merge is the one hard merge → own reviewed step, merge_guard mandatory.
- Deleting refs is destructive → the contained-branch delete list must be re-verified
  (`merge-base --is-ancestor`) immediately before deletion, and the graveyard tag
  pushed before any branch deletion.
- Autonomy % without a named bitstream md5 is meaningless — enforced everywhere.
- KR260 has zero hardware history — budget a full day for first light alone.

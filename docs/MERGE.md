# TideLink V2 convergence contract — autonomy × platform

**Status:** unified candidate proven to merge clean (2026-07-06). Sim-gate in flight.
**Goal:** one branch carrying *both* the autonomy stack (zero-poke bring-up) *and* the
platform improvements (div-2 PHY clock, P1/P2 framer fixes, instruments), so the two
sessions stop re-deriving each other's work.

---

## The two lines (fork = `04db833`, the proven V2 base)

| Line | Ref | Owns | Since fork |
|---|---|---|---|
| **Autonomy** (this session) | `feat/l4-training-exit` @ `788eb7e` | I2C role-lock, training-exit rendezvous, SYNC-detect config, winscan/reanchor, **anchor-verify (R-A)**, **LFSR-decorrelated anchor-retries**, zero-poke harness | 20 commits |
| **Platform** (other session) | `feat/phy-v2-integration` @ `6fb6f53` | div-2 PHY clock, P1 accept-gate, **P2 sync_resync**, fc_adapter locks, GP1 split, beatcap/RXCAP instruments, sim silicon-ratio knob | 13 commits |
| **Reconciliation** (other session, live) | `feat/autonomous-recon` @ `31985ae` | = my Loop-11 (`b55cb59`) + their P2 (`5e46be3`) + their div-2 (`9acd0d9`) + farm hardening | — |

`autonomous-recon` already did 90% of the merge. It was **missing only my Loop-12→14
autonomy fixes** — the anchor-verify and the LFSR retry that just cracked the anchor lottery.

---

## Collision analysis (the merge-difficulty predictor)

Only **9 files** are touched by both lines; **19** come from the platform line cleanly.

| Collision file | Nature | Outcome |
|---|---|---|
| `axi_chiplet_controller.sv` | my +3000-line autonomy stack vs their small obs threading | **clean** — recon carries my `b55cb59` base, my deltas apply on my own work |
| `WlinkRxLinkLayer.v` | theirs P1+P2 (superset of my P1) | take theirs |
| `Wlink.v`, `tidelink_fc_adapter.sv` | additive obs / adapter locks | clean |
| 5× flists / build scripts / `filelist.tcl` | additive entries + shared `094c228` | trivial |

**Predicted-HIGH risk on `axi_chiplet_controller.sv` did not materialize.** Because
`autonomous-recon` already holds my Loop-11 version of that file, my Loop-12→14 deltas
land on top of my own prior work, not against a foreign edit.

---

## Unified candidate — PROVEN CLEAN

```
wip/unified-candidate @ ff98a71
  = feat/autonomous-recon (31985ae)              # their platform: P2 + div-2 + farm
  + cherry-pick b55cb59..788eb7e                 # my Loop-12→14 autonomy
  → 0 conflicts
```

Verified present: LFSR retry (FIX-4), R-A anchor-verify, P2 sync_resync, div-2 PHY clock,
`zeropoke_soak --stats`.

**Co-function PROVEN in sim (2026-07-06):** full 8-suite `make sim_gate` = ALL PASS on the
unified candidate — t30 handoff, t31 training-exit, t32 die-a-first zombie, t33 arm-stagger,
v1_elab, v2 sync-detect, v2 pair-data, v2 winscan-fsm. My autonomy stack and their P2/div-2
platform co-function; the merge is sound at the RTL level, not just the git level.

Reproduce:

```bash
git worktree add -b wip/unified-candidate <dir> 31985ae
cd <dir> && git cherry-pick b55cb59..788eb7e     # applies clean
make sim_gate                                     # co-function proof (running)
```

---

## Why the merge multiplies (not just adds)

div-2 halves the PHY clock → **widens the RX eye** → raises the *per-attempt* anchor-relatch
probability above the current ~50%. The LFSR-decorrelated retries then **compound that higher
base** across 5 independent attempts. Platform and autonomy are not sequential alternatives;
they multiply into the convergence rate. This is why converging is worth the merge cost.

---

## Session split (stop duplicating the die_b wall)

- **Platform session (theirs):** div-2 **die_b flip-target timing closure** — the shared wall
  (`9acd0d9` broke die_b timing; needs de-instrument ~800 LUT + pblock + trim audit). Also BD,
  data-path, XHB window. This is the hard, physical, single-owner task.
- **Autonomy session (mine):** bring-up *behavior* + *verification* — anchor-verify/retry
  tuning, the zero-poke harness (`zeropoke_proof.sh`, `zeropoke_soak.sh --stats`), sim gate,
  and the on-silicon convergence-rate measurement. Deliver autonomy fixes as clean
  cherry-picks onto the platform base (proven possible above).

**Handoff:** my Loop-12→14 fixes are ready to land on `autonomous-recon` verbatim via the
cherry-pick recipe above — no conflict resolution needed by the platform session.

---

## Open items

1. Sim-gate `wip/unified-candidate` green (running) — proves autonomy + P2/div-2 co-function.
2. Loop-14 HW statistics (`zeropoke_soak --stats 12`) on `l4` build → per-die reach rate +
   retry histogram `0x21B8[13:11]`; if >90% and data crosses, **tag zero-poke autonomy**.
3. div-2 die_b timing closure (platform session) — unblocks the eye-widening multiplier.

## Coordination blocker found during the test-merge (ACTION: platform session)

`feat/autonomous-recon` pins **`deps/tidelink-phy` @ `bbd094c`**, which is a **local, unpushed
commit** — it exists only in working-tree submodule clones, not in the submodule's remote.
A fresh `git submodule update --init` on recon FAILS (`upload-pack: not our ref bbd094c`); I
had to fetch it out-of-band from another worktree to sim-gate. **Before any farm build of the
unified branch, the platform session must `git push` the `tidelink-phy` submodule commit
`bbd094c` to its remote.** Otherwise the farm (and any other clone) cannot materialize the phy
RTL. Same caution applies to any other locally-advanced submodule pins on recon.

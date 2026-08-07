# TideLink overnight bug-resolution campaign — 2026-08-06 → 2026-08-07

Autonomous multi-agent triage + resolution loop with hardware testing on the
KR260 eth-chiplet pair. **Primary deliverable: [`docs/BUG_REGISTRY.yaml`](BUG_REGISTRY.yaml)** — a
YAML registry of 17 tracked bugs (TL-001…TL-017) with a status lifecycle and an
explicit sign-off mechanism (Claude advances status to `hw_proven` with evidence;
`signoff.approved: true` is **David's** action; decisions/public-main pushes are
never auto-signed).

## How to sign off
Open `BUG_REGISTRY.yaml`. Each bug has a `signoff` block with `claude_verdict` +
`evidence`. For any bug you accept, set `signoff.approved: true`, `approved_by`,
`approved_date`. `campaign.awaiting_david_signoff` lists the ready ones;
`campaign.david_decisions` lists what needs a call.

---

## Delivered / verified tonight

| Item | State | Where |
|---|---|---|
| **Bug registry + sign-off schema** | done | `docs/BUG_REGISTRY.yaml` (uncommitted — review + commit) |
| **TL-006** W-byte-0 ECC fix was sim-proven but **ungated** | **FIXED**: verified `gaps_ecc` 6/6 PASS, wired into blocking gate | commit **`63222b6`** (integ/axirec-on-chiplet) |
| **TL-004/TL-005** AXI data-node F-1/F-2 | assessment proved **already fixed + gated** on integ line (F-2 HW-proven); not open | 41c4107 / 9b4c40b+e827199+42da64b |
| **TL-001** rank-1 peer-write data-drop | **root-caused + partial fixes, NOT resolved** (see below) | FIX 1 commit **`e5bd29c`** branch `fix/tl001-calibrator-terminal-latch` (submodule) |

Assessment (4 parallel agents) also confirmed the CI findings (TL-012/013/016)
are landed+pushed in `5be494b` and consumed by the eth-chiplet pin `1107151`.

---

## TL-001 (rank-1 data-drop) — honest status: NOT resolved

**Root cause (nuanced):** the calibrator's `calibrated_once_q` latches on *any*
first `S_DONE` — including a **give-up** S_DONE — after which a die stops driving
its training pattern; the peer then sweeps a silent lane and both fall back to the
`(0,0)` framing lottery → cross-die **write** data-drop.

**What was proven on HW (kr260 pair):**
- **FIX 3** (bilateral `swi_training_mode` `0x2100` bit-0 pulse, APB-only, no
  rebuild) actively re-drives both dies' training → **11/11 byte-exact data
  deliveries**. This proves the drop is fixable at the framing/re-lock level — it
  is **not** a physical-eye-only issue. FIX 3 is a working **runtime mitigation**.
- **FIX 1** (gate the latch on `!validation_timed_out` so a give-up die keeps
  re-arming) is **sim-proven** (calibrator regression 3/3) and **committed**
  (`e5bd29c`). But **autonomous HW was inconclusive: 1 land / 2 drops**, and both
  landing *and* dropping bring-ups reached a **genuine** S_DONE (FCSM=4) — so the
  give-up re-arm path wasn't even exercised. **Conclusion: the drop also occurs on
  genuine bring-ups**, which FIX 1 alone does not cure. FIX 1 is correct for the
  give-up failure mode but is **not** a demonstrated autonomous cure.

**Dominant blocker — TL-009 (die_a marginal-eye wedge):** die_a wedges within 1-2
writes every bring-up (physical). This *prevents any robust write-path soak* and
confounds FIX 1's HW evaluation. It is the top sustained-write blocker and a
separate physical PHY workstream.

**Remaining work / David call:** (1) explain + fix the *genuine-bring-up* framing
drop — find the autonomous equivalent of FIX 3's active re-training; (2) resolve
TL-009 (re-pin SRCC / ILA / a2l window) to enable a soak. Or: **accept FIX 3 as a
runtime bring-up step** and treat the eye as its own effort.

---

## Commits made (branches only — no push to public main)

- `e5bd29c` — FIX 1 (calibrator give-up terminal-latch) + `min_lock_dwells=1`, on
  new branch `fix/tl001-calibrator-terminal-latch` in the eth-chiplet **submodule**
  (`nanosoc-ethernet-chiplet/tidelink`). Honest message; sim-proven, HW-inconclusive.
- `63222b6` — TL-006 `gaps_ecc` gate wiring, on `integ/axirec-on-chiplet` (integ worktree).
- `docs/BUG_REGISTRY.yaml` + this summary — **uncommitted** in the main checkout
  (`fix/z2-drop-park-hook`); left for review to avoid disturbing that branch's WIP.

## David decisions (from the registry)
- **TL-001 / TL-009**: pursue eye/framing vs accept FIX 3 runtime step.
- **TL-010 (F13 PTP)**: land+gate `a0a224c`; two-board convergence HW.
- **TL-011 (F19 PHY BIST)**: DFT/BIST harness + first-silicon go/no-go metric (unmitigated tapeout risk).
- **TL-013/014**: retire V1 flist + drop duplicate `gpio-phy` submodule (coupled).
- **TL-015**: push CI/integ fixes to `main` (clean fast-forward: `5be494b` or `1107151`).

## Hardware / process notes
- Boards recovered (clean JTAG POR) and **both leases released**. Rig: kr260-01
  (10.22.24.159) / kr260-02 (10.22.24.153).
- **Rapid *parallel* POR degrades the pair** (die_a goes unreachable). Do PORs
  **sequentially**; a single clean `kpor kr260-01 --wait` recovers a wedged die.
- Reg note: `swi_training_mode` = `0x2100` **bit 0** (level hold), *not* bit 6
  (bit 6 = `SWI_FORCE_RECAL`, which wedges). The calibrator's own `:1491` "bit6"
  comment is stale — the decode is `axi_chiplet_controller.sv:2202 ctrl_reg_wdata[0]`.

---

## Deep-dive continuation — TL-001 resolution attempt (2026-08-07)

Pushed for a full resolution: 3 fresh assessment agents (autonomous-training-cure,
die_a wedge, independent data-path skeptic) + 8 hardware experiments. Result — a
**major reframe of the root cause**, but a genuine instrumentation wall.

**Refuted on hardware (theories that turned out wrong):**
- *Kernel SError / SLVERR panic* (Agent 2) — die_a's kernel log is **silent** at the
  wedge; the HW build already completes stuck writes with **OKAY** synth-B (`tidelink_top.sv:1824`) + Fix K + SOAK-DRAIN. The agents partly assessed the standalone tree, which lacks these.
- *FC-node / AXI-node wedge* — Region F `OBS_AXI_NODES` (0x21E0) reads **HEALTHY** on
  both dies right up to the wedge.
- *Outstanding-write concurrency / pile-up* — **100ms-paced writes (~1 outstanding)
  wedge too**, so the serialize-to-1 fix was refuted *before building it*.
- *Marginal analog eye* — the drop is deterministic `data=0` with the address intact
  and repairs to byte-exact; an analog eye gives random errors and corrupts the address too.

**Established (the reframe):**
- The **cross-die write DATA path WORKS byte-exact when die_a is healthy** — 16/16 in a
  clean single-process soak (die_b `0x2D001000=0xA5A50009` confirms write #9 landed).
- The dominant blocker is a **digital per-write resource LEAK on die_a's OUTBOUND
  write path** (TL-009, reframed from "marginal eye"): die_a's PS goes silently
  unreachable after ~10-20 cross-die writes, **invisible to every available instrument**
  (Region F healthy, kernel silent, pstore empty). Most "data drops" are this wedge
  killing the in-flight write, plus extra drops under per-write process/CAM churn.

**The wall:** the leaked resource is *below* tidelink's AXI-node observability (PS
SmartConnect / XHB500 hazard-list / SoC matrix). Localizing it needs a **PS-PL ILA**
on die_a's PS↔tidelink AXI/AHB write interface — which the project docs
(`VERIFICATION_PLAN` F-4) already state this class of wedge "needed a purpose-built
ILA" to diagnose. I cannot set up a PL ILA autonomously via SSH/APB.

**Candidate fixes for when the ILA localizes the leak** (do NOT build blind):
1. **Posted cross-die write** — generate B locally at the FC node when W enters the
   link TX FIFO, decoupling die_a's PS from link latency (Agent-2 "L3"). Strong lead.
2. Fix the residual B/hazard-accounting leak (Fix K + synth-B reduced but didn't
   eliminate it).

**Branch to pull:** `fix/tl001-calibrator-terminal-latch` @ **`e5bd29c`** in the
eth-chiplet submodule (`nanosoc-ethernet-chiplet/tidelink`) — FIX 1 (calibrator
give-up terminal-latch) + `min_lock_dwells=1`. Sim-proven (3/3 calibrator regression),
low-risk (genuine bring-up provably unchanged), **but NOT the operative fix** for the
die_a wedge. Include it as a correct improvement; the actual resolution awaits the ILA
campaign above. Boards recovered, leases released.

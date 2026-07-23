# Autonomy Fix Campaign — Multi-Agent Plan (2026-07-14)

**Prereqs:** `docs/AUTONOMY_STATUS_2026_07_14.md` (state of play), `docs/AUTONOMOUS_BRINGUP.md`
(mechanism). **Root cause (3-agent converged, 2026-07-14):** the winscan FSM sets a
p³-per-window exam (FINALIZE clear discards the mutual-force scan accumulation; retries
broadcast-clear all 4 lanes; the first-done peer restarts FC and punctures the idle-gated
beacon grid; tol-3 verify destroys tol-5 anchors) that the manual recipe never takes
(unbounded never-cleared window, mutual force_always, no verify). Placement sets the
per-lane detect probability p; the FSM amplifies marginal-p into a lottery. The fixes
below remove the amplification. They do not widen the eye — the physical track
(bus-skew/pblock/clock-tree) continues separately.

**Objective:** zero-poke autonomy ≥90% both-dies-OK on a *frozen, named* bitstream
(the hard requirement), with measurable proof at every phase boundary.

---

## Non-negotiable design rule: fixes must be RUNTIME-selectable

The single biggest provability lesson of this campaign: **a rebuild of identical RTL moved
die_a 15%→35%** — any compile-time A/B is confounded by the placement lottery. Therefore
every fix in this plan is gated by a **runtime enable** (APB cfg bits, POR value from a
wrapper parameter strap, exactly the `NEGO_CFG_RESET` pattern), default **OFF = bit-exact
baseline behaviour**. One bitstream then carries both arms, and the soak interleaves
ON/OFF trials on the SAME binary — placement-free, temporally controlled A/B.

Proposed: a new `WS_FIX_CFG` register (or NEGO_TRAIN_CFG spare bits), one enable per track:
`[0] evd_retain_en` (Track A) `[1] peer_hold_en` (Track B) `[2] vfy_wait_en` (Track A5).
Wrapper parameter `WS_FIX_RESET` sets POR values so zero-poke runs need no poke.

## Standing method rules (all agents)

- Verify the instrument before theorising about the DUT.
- Always run the control; an autonomy % is meaningless without naming the bitstream.
- `zp_arm()` readback-verified arms only; UNARMED = void, not FAIL.
- `rm -rf sim_build` when A/B-ing RTL under cocotb (it only tracks tb_top.sv).
- Sim gate green before any farm build (`farm_gate`); V1 **and** V2 elab must pass.
- Hardware: bridge1 lease first; power-cycle → deploy BOTH → bring up; NEVER reload the
  PL on a live link; only ONE agent touches hardware at a time.
- Soak CSVs must be rsynced back into the repo (`fpga/hw_regression/results/`) — the
  iter5/6/7 raw per-trial data was lost on the run host.

---

## Phase 0 — Instruments + baseline (2 Opus agents, parallel; ~1 day)

### Agent I1 — sim-repro harness (the campaign's key progress instrument)
Build a silicon-faithful **marginal-lane + puncture** sim in `cocotb/tidelink_top_pair_v2/`.
Do NOT start from scratch — the pieces exist: the `eye_fault` per-lane bit-error injector
(`EYE_FAULT=1`, driven by `test_v2_marginal_eye.py`), the FSM-converges test
(`test_v2_winscan_fsm.py`, with its modelled SYNC_DIST idiom), the autonomous arm path
(`test_v2_autonomous_sync_detect.py` / `_fc_handoff.py`), and the designed-in speedup
hooks (`tb_winscan_dwell_short_q`, `tb_ws_anchor_short_q`). Heed the lesson encoded in
test_v2_marginal_eye's header: SUSTAINED whole-bring-up corruption breaks the training
checker (cal_done never asserts) and tests the wrong thing — the faithful marginal model
is corruption targeted at the window under test. Here that window is the FINALIZE
re-confirm: bring up clean through cal + scan, then corrupt a plusarg-set FRACTION of
one lane's beacon grid slots — models marginal p < 1 where it actually bites.
- Arm-skew control (the dies never arm simultaneously on silicon; ~7 s apart in the soak).
- FC-from-POR traffic is already live in the pair tb — that IS the puncture source; verify it.
- N-seed harness (≥40 seeds/config) reporting: reanchored rate, 0x21B8 decode
  (attempts, timeout, vfy bits), per-lane sync_seen at fail.

**Acceptance (proves the instrument):** baseline RTL reproduces the silicon signature —
(a) anchor lottery at intermediate p (healthy at p≈1, lottery at p≈0.3–0.7);
(b) retries correlated, attempts saturate at 5; (c) LATE/heal cases exist;
(d) failures are FAILOPEN ⇔ sync_seen≠mask (the RTL identity). If sim cannot reproduce
the lottery, STOP and report — do not proceed to fixes on an unproven instrument.

### Agent I2 — silicon baseline on the CURRENT tree (hardware; serialized)
Autonomy has NEVER been measured on this branch. **UPDATE 07-14 PM:** fresh pair
bitstreams were built 12:41/12:45 (between b772855 and 1588e19) — they carry every RTL
fix at HEAD (rxfifo f9b94b7, pre-drain f3c5359); the only delta vs HEAD is the IBUF-pin
set_bus_skew attempt, which 1588e19 proved binds NOTHING (18-402) — physically inert.
And b772855 already added the TD_AUTONOMOUS=1 zero-poke mode (no writes, POR-armed,
UNARMED-void denominator, per-die rea) to `proven_method_soak.sh`.
1. ~~Fresh build~~ → **freeze the 12:41/12:45 bits as BASELINE-1**: record md5s,
   structural verify (verify_build.sh — note hardened check (g) will flag the 8 dead
   skew lines in its logs; that is expected and inert, document it). Rebuild ONLY if
   structural verify finds anything else.
2. Harness patches (no RTL): (i) post-fail discriminator — R8=0x1C both dies + one R8
   bit[5] clear pulse + poll 0x2140 (anchors-in-seconds ⇒ policy-bound, eye alive);
   (ii) per-lane 0x215C fill-rate under mutual force (a direct per-build measurement of
   p — the missing instrument from STATUS §6 Q4); (iii) per-trial 0x21B8/0x215C
   classification in the TD_AUTONOMOUS path (or run `zeropoke_soak.sh --stats` as the
   classifier arm); (iv) fix the zeropoke_soak `:201` denominator bug; (v) archive
   per-trial CSVs into the repo.
3. Run N=40 fresh-POR autonomy soak (TD_AUTONOMOUS=1) on BASELINE-1, per-trial
   classified (0x21B8 / 0x215C / NEGO / ROLE), arm-verified.

**Deliverable/gate 0:** BASELINE-1 table (clean-OK, OK+LATE, per-lane misses, discriminator
outcomes) + working sim-repro. The discriminator result is itself a root-cause check: if
failed dies do NOT re-anchor under forced beacons, the physical story dominates and the
fix tracks below must be re-scoped before implementation.

---

## Phase 1 — Design convergence (1 Opus architect agent; ~0.5 day)

The five candidate fixes all land in the WS_FINALIZE/retry region of
`axi_chiplet_controller.sv` — five independent patches would collide. One architect agent
converts them into **two coherent tracks** with a written micro-spec, runtime-enable
mapping, obs-bit allocation (0x21B8 spares), tb test list, and an explicit
anti-poison argument for each retention behaviour:

- **Track A — evidence retention** (`evd_retain_en`, `vfy_wait_en`); fixes #1+#2+#5:
  - A1: FIX-3 retries stop broadcast-clearing confirmed lanes. Prefer the cheap form
    first: retry WITHOUT re-clear while the CDC'd sync_seen vector is nonzero
    (extend-style reload); full clear only from a zero vector or every Nth attempt.
    Full per-lane clear-mask plumbing (acc→gpio→deskew) only if the cheap form
    is insufficient in sim.
  - A2: at FINALIZE entry, sample anchor+verify BEFORE pulsing the clear; if the
    scan-era anchor already verifies at final taps, skip the clear and release
    (the trust FIX-1 catchup already extends).
  - A5: non-destructive verify — anchor high + verify low holds the anchor and waits
    (extend budget); destructive re-clear only on `ws_verify_stuck_q`.
  - Backstop unchanged: the tol-3 cross-lane simultaneous verify still gates release,
    so retained evidence can never ship a bad anchor (same argument as WS_ANCHOR_EXTEND).
- **Track B — peer rendezvous** (`peer_hold_en`); fixes #3+#4 (subsumes slave parity #6):
  - B3: hold `winscan_force_sync` (and the fch quiesce) past local release until the
    peer's done/finalizing is observed (plumbing exists: `ws_finalizing_lvl`, peer
    byte-3 [27] capture), bounded ~10 s timeout, fail-open to today's behaviour.
    Data-safety note: force_always is the word-deleter — the hold is safe ONLY while
    the local fch stays quiesced; the spec must tie the two together.
  - B4: gate `fch_arm`/bootstrap on peer winscan_done observed (or timeout), so the
    first-anchored die does not restart CR-spam into the second die's re-confirm.

Also in scope: stale-comment fixes (WS_FIN_WAITPEER "DORMANT" at acc:3899/1343 is false —
live master-only fallback since 07-07), `snapshot.sh` banned reads (0x21AC/0x1B0/0x1B4).

**Gate 1:** spec reviewed by the two Phase-2 implementers (they ack the interface) + David.

---

## Phase 2 — Implementation (2 Opus agents, parallel, isolated worktrees; 1–2 days)

Agent A (Track A) and Agent B (Track B), each branched off `wip/phase2-pblock` in its own
worktree (`/home/dam1n19/SoCLabs/td-bisect/`, NOT /tmp). Each must prove, in order:
1. **enable=0 ⇒ bit-identical**: full existing sim gate matrix green with the fix
   compiled in but disabled (the WS_ANCHOR_EXTEND=0 pattern).
2. **enable=1 ⇒ sim lottery improvement**: on the Phase-0 sim-repro, quantified
   (seeds passing baseline X/40 → fixed Y/40, at the same p / skew / seeds).
   Track A target: retries compound instead of correlate. Track B target: the
   second-armed die's failure excess vanishes.
3. New targeted cocotb tests (per spec test list) + V1 AND V2 elab clean +
   `sim_gate_fifo` + CDC-tear gate green.
4. No new always-block latches/loops (`farm_gate` lint), obs bits wired to 0x21B8 spares.

Optional Agent C (hygiene, can be a cheaper model): stale comments, snapshot.sh,
soak denominator — zero-risk, unblocks Phase 4 reporting.

**Gate 2:** both tracks pass 1–4 with numbers in their reports.

---

## Phase 3 — Integration + adversarial review (3 Opus agents; ~0.5–1 day)

- Integrator: merge A+B onto `wip/phase2-pblock` (enables default OFF), resolve the
  FINALIZE-region overlap, full gate matrix (sim_gate, sim_gate_fifo, CDC-tear, UVM
  smoke, farm_gate, V1 elab), merge_guard clean (never resolve FCSM/flists toward dieb).
- Two independent adversarial reviewers, prompted to REFUTE, different lenses:
  1. Data-safety + deadlock: word-deleter regressions (R4a history), unbounded holds,
     quiesce/timeout interlocks, zombie-peer traps (`ws_kicked_q` disarm-park class).
  2. Tapeout impact: these are ASIC-relevant FSM changes — POR strap defaults must not
     change chip-default behaviour without sign-off (handover rule: coordinate
     EPOCH/PHY-adjacent changes with the trunks); V1 flist elab; CDC correctness of any
     new cross-domain terms (peer-done capture, per-lane clear if implemented).

**Gate 3:** zero CONFIRMED blockers from both reviewers; all gates green.

---

## Phase 4 — Silicon proof (1 Opus agent driving hardware, sequential; 1–2 days)

One `farm_gate`-gated build of the integrated tree ⇒ **CANDIDATE-1** (md5s recorded).
Because the enables are runtime, ALL arms below run on this single frozen binary,
interleaved per-trial (alternate config each fresh-POR cycle) to kill temporal drift:

| Arm | evd_retain | peer_hold | vfy_wait | Purpose |
|---|---|---|---|---|
| K0 | 0 | 0 | 0 | in-binary baseline (also vs BASELINE-1: placement delta, informational) |
| K-A | 1 | 0 | 1 | Track A effect |
| K-B | 0 | 1 | 0 | Track B effect |
| K-AB | 1 | 1 | 1 | combined |

- N=20 per arm interleaved first (80 fresh-POR cycles ≈ one evening with power-cycle
  discipline); extend the ambiguous arms to n≈40. Predicted effects (25–35% → >80%) are
  resolvable at n=20/arm; a 10 pp effect is NOT — report it as unresolved, don't sell it.
- Score clean-OK AND OK+LATE separately; per-trial 0x21B8/0x215C archived to the repo.
- **Certification run:** best config, N=40 fresh-POR: link + A→B + B→A byte-exact +
  doorbell (the proven_method scoring, autonomous arm instead of rcp). Target ≥90%
  both-dies-OK ⇒ the deliverable. Then linkhold soak ≥1 h on the winner.

**Gate 4:** the interleaved table + certification numbers, per arm, on the named binary.

---

## Phase 5 — Consolidation (~0.5 day)

Merge to the trunk per `docs/MERGE.md` discipline (onto integ; never resolve FCSM_6/
fc_adapter/flists toward dieb), update AUTONOMY_STATUS/AUTONOMOUS_BRINGUP docs, write the
ASIC recommendation (which enables should be POR-default in silicon — needs David's
sign-off, per the do-not-build-into-chip-default handover rule), update memory.

## Progress ledger (what "proving progress" means, per phase)

| Phase | Proof artifact |
|---|---|
| 0 | sim-repro reproduces the silicon lottery signature; BASELINE-1 measured table + discriminator verdict |
| 1 | reviewed micro-spec; enable/obs-bit map |
| 2 | per-track: enable=0 bit-identical matrix + enable=1 sim numbers (X/40→Y/40) |
| 3 | gate matrix + two adversarial verdicts |
| 4 | same-binary interleaved A/B table; certification run ≥90% or an honest miss |
| 5 | merged trunk + updated docs + ASIC recommendation |

Kill criteria: Phase-0 discriminator shows failed dies do NOT re-anchor under forced
beacons (⇒ physical dominates, re-scope); Phase-2 sim shows no lottery improvement at
enable=1 (⇒ the exam model is wrong, back to root-cause); Phase-4 K0 vs K-arm null at
n=40 (⇒ report honestly, keep enables OFF).

---

## Addendum 2026-07-14 PM — impact of commits b772855 / 44b85d4 / 1588e19

- **`set_bus_skew` is RESOLVED-BY-REMOVAL (1588e19), not fixed.** The constraint is
  inexpressible for port→capture-reg paths (no launch register ⇒ 18-402), and would have
  been a no-op anyway (~0.44 ns available setup margin vs a 2 ns ceiling). STATUS doc
  §4b's "Fixed (44b85d4)" + "run this experiment first" is STALE — there is no skew-
  constraint experiment to run ahead of this plan. verify_build check (g) is now
  genuinely protective (fails on 18-402/no-valid-startpoint/endpoint/object; single-log).
- **Consequence for prioritisation:** the physical quick-fix lane is empty again; this
  FSM plan and its instruments are the actionable path. The physical track's live
  candidates are IOB packing, a set_max/min_delay window sized to ~0.44 ns, and
  **IDELAY re-opened for INTER-LANE SKEW EQUALISATION** (the "IDELAY is inert" verdict
  answered UI-positioning; 2.34 ns of range is well-matched to sub-ns lane skew).
  Phase-1 architect: add a spec paragraph on this — the winscan FSM already owns the
  per-lane taps, so a future equalise policy would ride the same machinery. Out of
  scope to implement here.
- **Phase-0 shrinkage:** BASELINE-1 bits already exist (12:41/12:45, RTL = HEAD) and the
  TD_AUTONOMOUS=1 soak mode already exists (b772855, correct UNARMED-void denominator).
  Agent I2's job is now: freeze + verify + classify + run, no build wait.

---

## Addendum 2 (2026-07-14 ~14:30) — 0044bef REPRIORITISES THE WHOLE PLAN

A sibling agent ran the zero-poke soak on the 12:41 bits TODAY: **anchor 20/20** (the
lottery did NOT present on this placement), **channels 0/20** both directions + doorbell
— perfectly bimodal, causally pinned to data-mode-with-beacons (R8 pinned to 0x15 by the
D2 heal; ONE escape-hatch write 0x210C=0 → channels 3/3). Root cause: V2 lost V1's
serialiser-drain guard — beacons fire while the serialiser is still shifting
(idle=1, postcount≠0) and overwrite packet tails. **Fixed in 0044bef** (idle-gated path
only; force_always/scan window deliberately untouched). Sim cannot prove it (the pair TB
does not model beacon substitution densely enough); **proof = rebuild + TD_AUTONOMOUS
all-channel soak, no escape hatch. That is now the critical path**, ahead of every FSM
track in this plan.

Consequences:
- **Phase 0 I2 (BASELINE-1) is effectively DONE** (by the sibling): 20/20 anchor /
  0/20 channels on the named 12:41 bits. The 12:41 bits are now STALE vs HEAD (predate
  0044bef); the next build is the 0044bef proof build.
- **Phase 2 FSM tracks (A/B) DEMOTED to hardening.** The anchor exam did not bind on
  this placement — but the rebuild-variance history says the lottery returns on other
  placements, and the 0044bef proof build IS a new placement roll. Keep the tracks;
  gate starting them on whether the proof build's anchor rate holds (if it drops, the
  lottery is back and the tracks promote again — with the Phase-0 sim instrument ready).
- **Phase 0 I1 PROMOTED and widened**: two instruments now — (A) dense beacon-
  substitution/drain-window sim so the 0044bef defect class is provable in sim (test
  must FAIL with 0044bef reverted, PASS with it); (B) the marginal-p anchor-lottery
  harness (unchanged rationale).
- **Open reconciliation item:** a sibling session's root-cause framing (memory) blames
  the same 0/20 on the R8 clamp + I2C autoneg NACK hard-coding SLAVE on both dies
  (tidelink_autoneg.sv:950 ⇒ no master ⇒ forces SYNC forever) and proposes event-gated
  SYNC-off + role-from-strap; 0044bef instead makes beacons-on data-safe and keeps D2.
  These disagree about the correct end-state (beacons permanently on vs event-gated
  off) and about whether a both-dies-slave autoneg defect exists. Note sim_gate
  test_31:601 asserts insert_en==1 (enshrines beacons-on) — any SYNC-off design will
  fight it. Needs one reconciliation pass before Phase 1.

---

## Addendum 3 (2026-07-14 evening) — SILICON PROOF RESULT: drain guard NECESSARY, NOT SUFFICIENT

The 0044bef proof soak ran (drain-guard bitstream 14:47/15:02, zero-poke autonomous,
NO escape hatch, N=10 fresh-POR; sim_gate 11/12 + the v2_autonomous_sync_detect FAIL
re-ran clean 4/4 — contention with the concurrent farm build, not RTL). Result at 9/10:

| metric | pre-fix | drain-guard build |
|---|---|---|
| anchor/link (rea+fcsm4 both) | 20/20 | **9/9** |
| A→B data | 0/20 | **6/9** |
| doorbell (A→B crossing) | 0/20 | **3/9** |
| B→A data | 0/20 | **0/9 — hard-dead** |

**Reading:** the guard's mechanism is REAL (A→B 0%→~67%) but the prediction
"channels 0/20 → passing" is falsified — at least one more beacon-related corruption
mechanism remains, and it is DIRECTION-ASYMMETRIC: slave→master never delivers;
master→slave is flaky. Beacons-on data mode is still not a proven-safe end-state.

Consequences:
- **Back to root-cause mode on the residual channel defect.** Per the standing rule:
  instrument before fix — the next step is a targeted probe of the B→A path under
  beacons-on (RXCAP/beatcap obs on die_a's RX during a b2a burst, filt counters), and
  a systematic V1-vs-V2 audit of ALL guards on the SYNC insert + RX extract/substitute
  paths (0044bef's class: "V1 had it, V2 lost it" — check for siblings). The sim-
  instrument agent has been redirected to cover both directions and run this audit.
- **The A→B-vs-B→A asymmetry is also a discriminator for the reconciliation item
  above**: a pure TX-drain mechanism should be direction-symmetric (both dies beacon);
  a hard B→A zero looks role- or flip-specific — which keeps the sibling's autoneg/
  role framing alive. Reconcile before writing the next RTL fix.
- Anchor: 29/29 cumulative on the two newest placements — FSM hardening tracks stay
  demoted; the lottery instrument (Deliverable B) drops to second priority.

---

## Addendum 4 (2026-07-14 late) — B→A root-cause diagnostic LIVE; the fix is gated on it

Sim agent (wip/sim-lottery-instrument) delivered: the 0044bef defect is now provable in
sim, AND it reproduced a force_always residual (slave force-beacon deletes B→A payload).
BUT two static reads changed the interpretation — see memory
project_drainguard_necessary_not_sufficient_b2a_residual_2026_07_14:
  1. On silicon the drain guard SUPPRESSES ALL idle beacons (postcount pinned by
     swi_delay_cycles POR=0), so idle beacons are a non-factor here.
  2. ws_serve_active_r is likely DORMANT on good-anchor placements (needs a master
     FINALIZE_GO the master never sends when it anchors cleanly).
=> the LIVE B→A corruptor is unconfirmed. A hardware diagnostic (existing bitstream, no
build) is now running to discriminate:
  - **H1 BEACON**: a force path (slave re-winscan winscan_force_sync / ws_serve / stuck
    insert) is active in data mode and deletes B→A payload. Evidence = tx_sync_ins_cnt
    increments in data mode + RXCAP shows SYNC substitution + 0x210C=0-on-die_b rescues.
  - **H2 CREDIT/FC**: B→A death is the known-fragile credit-return path (die_b
    fe_tx_credit_max=0, no pktnum wrap). Evidence = credit_max=0 + no beacon activity +
    0x210C=0-on-die_b does NOT rescue.

**DECISION TREE (do NOT build until the verdict is in):**
- H1 confirmed → fix = idle-gate (or postcount-guard) the offending force path; the scan
  window is FC-quiesced so postcount==0 there, so guarding force_always likely does NOT
  regress anchor (0044bef's stated risk was for the scan, which has no draining data).
  Candidate sites: WavD2DGpio_v2.v:625-628 (add postcount guard to force_always) or
  axi_chiplet_controller.sv ws_serve/winscan_force OR terms (:5924/5930/5939).
- H2 confirmed → fix is in the credit/FC return path, NOT beacons — the whole drain/
  beacon line is a red herring for B→A. Port/repair the fe_tx_credit_max fix for the
  B→A direction (cf project_a2b_rootcause_fe_tx_credit_max). This would also explain why
  the drain guard (a TX-beacon fix) could never have touched B→A.
- Either way: build the confirmed fix → farm_gate → sim_gate → lease bridge1 → deploy →
  TD_AUTONOMOUS=1 all-channel soak (target: B→A > 0, ideally all channels, anchor held).

User has authorized synth + bridge1 deploy (take a lease first). The loop from here is:
verdict → single fix → build → lease+deploy+soak, no approval stop between steps.

---

## Addendum 5 (2026-07-15) — VERDICT IN: master RX-commit SYNC clamp. Fix underway.

Hardware diagnostic returned a clean single-variable verdict: B→A blocker is NEITHER H1
(slave beacon) NOR H2 (credit) — it is the **MASTER die_a (RECEIVER) armed-autonomy SYNC
clamp gating its own RX-commit**. Disarm die_b → still dead; also disarm die_a → byte-exact.
die_b credit was 0x1f (nonzero) throughout ⇒ H2 out; RXCAP showed no SYNC substitution ⇒
H1 out. This is project_autonomy_rootcause_sync_clamp_2026_07_14 localized to the receiver,
REFINED: post-drain-guard the residual is RX-COMMIT-HOLD, not beacon-substitution.

Mechanism: swi_sync_insert_en_r (R8[2]) re-driven=1 by the D2 heal
(axi_chiplet_controller.sv:2110-2113, last-write-wins over the :1923 APB decode) ⇒ R8
pinned 0x14 ⇒ die_a RX framer captures but never commits. Fix = event-gated autonomous
SYNC-OFF (sticky one-shot) at the verified+held anchor (ws_anchor_q && ws_verify_q), clear
insert_en + sync_cfg_hold_q, keep robust/tol/lane_mask.

STATUS: fix worktree td-bisect/b2a-fix (branch wip/b2a-fix @ 0044bef); implementer agent
running (implement + investigate the die_a/die_b RX-commit asymmetry + invert test_31 +
full sim_gate). GATE BEFORE BUILD: adversarial review of the D2 peer-starvation risk +
anchor-regression + one-shot stickiness. Then: farm_gate → build_farm → verify_build →
lease bridge1 → TD_AUTONOMOUS=1 proven_method_soak. SUCCESS = B→A > 0 (target all channels,
anchor held). Runbook: scratchpad/OVERNIGHT_RUNBOOK.md.

---

## Addendum 6 (2026-07-16) — ✅ DELIVERED

The B→A blocker was NOT the master RX-commit *clamp* as first framed — a free
exclusively-leased bench check (run ×2, reproduced) showed die_a's winscan FSM
**LIVELOCKS**: reaches fcsm=4/rea=1, advances SETTLE→FINALIZE, tears down its own FC
(fcsm 4→0), repeats — perpetually disrupting RX-commit. `winscan_done` never stably sets,
so the first two trigger designs (`winscan_done && fcsm==4`) were INERT. Corrected trigger:
**`reanchored && fcsm==4`** held ~160 ms (« 2.8 s churn), latch → DISARM-PARK the FSM.

Delivered on `wip/b2a-fix` @ cd2db38 (off 0044bef):
- sim_gate 12/12; netlist-verified in the routed bitstream (WINSCAN_CELLS=108,
  RETIRE_CELLS=105 — fix survived synthesis, not optimised out).
- Build: **must `export TIDELINK_PHY_V2=1`** (else V1-flist fix-less bitstream). RETIRE_EN=1
  via module default (F4 tapeout: NOT plumbed to tidelink_top — ASIC to-do).
- Silicon zero-poke autonomous soak: **N=10/10 ALL channels byte-exact**
  (link+A→B+B→A+doorbell), rea_a=rea_b=1 every cycle (no peer-starvation).
- **N=40 CERTIFIED (2026-07-16): 39/39 valid, 100% ALL channels, CP [91.0%, 100%]**
  — link/A→B/B→A/doorbell/ALL-4 each 39/39. Cycle 2 = POR-FAIL (board did not return
  from power-cycle) = infrastructure flake, excluded as non-test. Lower bound clears 90%.
  csv: proven_method_soak_20260716-080333.csv (mapstone-dev:~/td_b2afix_soak/).

Reviewer gates that paid off: the adversarial review flagged trigger-reachability → the
free bench check caught two inert trigger designs BEFORE any build; the netlist cell-count
caught the ifdef/flist silent-V1 risk BEFORE deploy. No build was wasted on a bad trigger.

Remaining: (1) N=40+ certification (running); (2) fold `wip/b2a-fix` into the consolidation
(`CONSOLIDATION_PLAN_2026_07_15.md`, base `wip/tapeout-candidate`) — not in its harvest list
yet, + the deps/tidelink-phy fork reconciliation; (3) tapeout F4 — plumb RETIRE_EN to top.

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

## 0-PRE. STATUS DASHBOARD + ROADMAP TO RTL FREEZE (updated 2026-07-16)

**THIS SECTION IS THE LIVE STATUS.** Everything below it is the standing plan.

### Phase status

| Phase | State | Evidence |
|---|---|---|
| 0 — unfork PHY / freeze | ✅ **DONE** (verified 07-16) | `integ/phy-consolidation-v2` **pushed to origin**; superproject pins `5c76e76` which is ON that pushed branch ⇒ **fresh clone builds**. `bbd094c` (autonomy line) merged in. ⚠️ **`655e24d` (KR260 line) is NOT an ancestor** — but `5c76e76` = *"make the whole-word corrector genuinely selectable (EPOCH vs SYNC_REANCHOR)"* looks like a deliberate **re-implementation** of it (the flagged deskew/corrector overlap). **VERIFY no KR260 phy content was lost** before Phase 5 |
| 1 — one integration branch | ✅ **DONE** | `integ/consolidation-2026-07` (273 ahead of main), sim_gate 14/14, CI blocking, graveyard tag |
| 2 — autonomy P-A on Z2 | ✅ **CERTIFIED** | **N=40: 39/39 valid, 100% ALL channels, CP [91.0%,100%]** on `cd2db38`. ⚠️ role-from-STRAP (Phase-2 scope) **NOT done** |
| 3 — physical determinism P-B | ❌ **NOT STARTED — but UNBLOCKED** | phy fork is resolved (row 0), so **this can start NOW. It is the critical path: the anchor lottery AND the crippled link rate both live here** |
| 4 — all-nodes/all-FC matrix | ⚠️ **PARTIAL** | continual data ✅ (24/24, 4→1024 words, both dirs); **FCSM 0–4 × all-channel matrix NOT built**. *"long-burst drops first 2 words" is RETRACTED — it never existed (was the phantom-pop)* |
| 5 — KR260 + PTP | ❌ **NOT STARTED** | zero hardware history |
| 6 — ASIC feature-complete | ⚠️ **PARTIAL** | 4 chip-killers closed; **RX-FIFO TWIN 2, straps, role-strap open** |

### 🔴 RTL FREEZE GATE — what must be TRUE before freeze

1. **Chip-killers closed.** RX-FIFO **TWIN 2** (`tidelink_fifo_ctrl.sv:189`, write-side
   length-latch corrupts the FC-shared write_ptr) — LIVE, unguarded, needs **one intent
   decision** (is AHB-write-to-RX supported? evidence says no). Plus flist single-sourcing.
2. **Straps decided + plumbed** (silicon cannot be re-strapped): `NEGO_CFG_RESET`=7'h61,
   `apb_debug_unlock_i` & `mask_hs_bypass_i` (both tied `1'b1` today = debug permanently
   unlocked + peer-mask handshake never runs), **role from STRAP not I2C** (the NACK→
   both-dies-SLAVE trap), and **`RETIRE_EN`** (plumbed, default 1 — ASIC must choose).
3. ✅ **THROUGHPUT — SOLVED, NOT freeze-blocking (2026-07-17, MEASURED).** The limiter is a
   **~96 PL-cycle PS→PL store ROUND TRIP per word — not the link (which is ~83% IDLE) and not
   the CPU (0.10% of cost).** MEASURED: 2.343 MHz = 48,864 w/s = 195 kB/s; **25 MHz = 517,465
   w/s = 2.07 MB/s = 10.59×**, byte-exact, md5-named. The rate ladder is **structurally
   confounded** (clk_out1 drives every AXI/AHB block *and* phy_clk_div ⇒ "48 UI/word" ≡ "96
   hclk/word" in every build); the `--busref` control breaks it — a NON-link PS→PL access
   scaled 9.66× too. Two-point solve: **N=95.8 PL cycles constant at both rates.** Root cause:
   `tidelink_fc_adapter.sv` *"one store == one FC word == one packet"* + 1-entry skid +
   BLOCKING AHB write ⇒ zero pipelining. **RETRACTIONS: (a) the "25%/2.1% efficiency" story is
   WRONG; (b) PACKING DEPTH N is worth ~nothing** (header = 0.10% of traffic; N cannot recover
   a per-word cost — no 3.2× lever); **(c) lane width is dead** (8 lanes measured +0.2% with
   framing verified doubled). **Fix = pipelining/burst/DMA in the adapter** (DMA overlaps round
   trips; the CPU is not slow) — but **the FPGA number is NOT ASIC-predictive** (most of the ~80
   non-link cycles is Zynq PS→PL AXI-GP latency absent on-die), so **size on-die before
   building.** See `project_throughput_is_ps_bus_roundtrip_not_the_link_2026_07_17`.
4. **Full channel matrix** green N=40, both modes, named md5: {die_a,die_b} ×
   {A→B,B→A} × FCSM 0–4 × doorbell/IRQ.
5. **Physical determinism (P-B) — PROVEN STATICALLY, needs landing + rebuild-variance.** The
   capture-clock BUFG parent-hoist (`phaseB` `2c32c2b`) takes per-lane skew **1.78/2.11 ns →
   0.24 ns (7–8× tighter, MEASURED on 4 routed DCPs)**. Land it, then ≥3 independent builds to
   prove the lottery is dead (one placement proves nothing). **CORRECTION: the "lane-7 is 7 ns
   late" story is REFUTED** — lane 7 is among the *fastest* lanes; the late lane *moves between
   builds*; it was a per-build artefact, not a lane property. **Do NOT use the one-line
   `USE_CAP_CLKBUF` flip — it inverts the capture edge and KILLS the link** (io_pol=1 =
   deliberate mid-cell sample); use the parent hoist. 25 MHz already runs byte-exact today, so
   the rate is *not* gated at 2.343 MHz — but the ceiling is AXI/hclk (~28 MHz), not the PHY.
6. **Verification integrity — now its own workstream (FIFTEEN instrument failures this
   campaign).** Cheapest high-value fix: **the `PERF_CTRL` off-by-one** (`tidelink_apb_regs.sv:
   536-540` — `perf_reg_region = apb_region[1:0]` ⇒ never `2'b00`, so PERF_CTRL is UNWRITABLE
   and **every perf counter reads 0**; intended `apb_region-5`). Then: `EPOCH_PROFILE=silicon`
   ungated+RED (no real-skew sim coverage); `make -n sim_gate` **writes fake PASS files**;
   `test_v2_fc_contiguous.py` dead (injector never committed); `test_v2_reduced_lane.py` never
   gated; `lane_health_preflight.sh` circular; `td_v2_channels.sh` hardcodes the mask; stale
   XDC/`ribbon_wiring.md` pin tables (bench hazard); `livematch`/`sync_seen` both mislead on
   lane 0 (use raw slices). This compounds — every future measurement depends on it.
7. ASIC elab/lint/CDC clean + N=40 recipe AND autonomous on the final bitstream (evidence
   package), certified-bitstream tag.

### ⚠️ PERFORMANCE — WHAT'S REAL AFTER THE MEASUREMENTS (2026-07-17)
Above-the-pad, the FPGA is limited by the **PS→PL store round trip (~96 PL cycles/word)**, not
the link (item 3). Below the pad, the PHY is **SDR, 1 bit/lane/UI**: 8 lanes × 100 MHz = **800
Mbit/s raw** on the ASIC — which is **below 1000BASE-T before overhead**, so v1 will not beat
gigabit Ethernet on raw bandwidth. **This is fine: v1 is an honest FUNCTIONAL prototype
(zero-poke autonomy, credit flow-control, byte-exact channels), not a performance vehicle —
state it that way.** Production chiplet PHYs (UCIe/BoW) run 4–32 Gbit/s *per lane*; the only
real bandwidth levers here are **DDR at the pad, more lanes, a faster pad clock** — all PHY, all
post-v1. **Do NOT chase protocol/packing/lane-width — all three measured ≈0.**

**Measured wins to bank:** 25 MHz byte-exact = **2.07 MB/s = 10.59×** the shipping rate (build
exists; the ceiling is AXI/hclk ~28 MHz, not the PHY).

**REFUTED board myths (all MEASURED):** the "**4 dead silicon lanes**" claim is **wrong — all 8
balls conduct in both directions** (raw post-deskew slice reads; die_a receives lanes 1/3/4
bit-exact; David continuity-tested the ribbon). They were **untrained, not dead** — the `0xE4`
mask was invented in a sim test, never measured, and was load-bearing for a month. An 8-lane
rebuild trains all 8 byte-exact but yields **+0.2% throughput** (round-trip-bound, above).
*(Historical note: the pynq-z2 lane story below is superseded —*
`LANE_MASK_RESET=8'hE4` exists, `Wlink.v:2425-2442`.)*
*(Lab-MAC caveat: it has **no measured throughput, ever** — `tftp_put_kbps: 410` in
`golden-path-bench.md:95` is a **format placeholder**; the real baseline says `N/A # NOT_RUN`
and `test_udp_echo` is FAIL. It is also **DMA/descriptor-ring**, not PIO — a genuine
architectural advantage over TideLink's PIO test path.)*

### Sequencing to freeze (dependency-ordered)
```
phy fork ✅ DONE ──► P-B clock hoist (Phase 3, UNBLOCKED — START NOW) ──► rebuild-variance ──┐
                                                └► link-rate raise (2.343 MHz → 100 MHz ASIC) ┤
48-UI/word root-cause (NEW, needs PL-side/DMA generator) ─────────────────────────────────────┤──► RTL
TWIN 2 + straps + role-strap (Phase 6) ───────────────────────────────────────────────────────┤   FREEZE
full FCSM 0–4 matrix (Phase 4) ───────────────────────────────────────────────────────────────┤
EPOCH_PROFILE=silicon gate (NEW) ─────────────────────────────────────────────────────────────┘
KR260+PTP (Phase 5) — parallel, not freeze-blocking for the Z2/ASIC line
                      (but first VERIFY 655e24d's content survived the phy re-implementation)
```
**Critical path = P-B clock hoist → rebuild-variance** (the phy blocker is now cleared, so this
starts immediately), with the **48-UI/word root-cause** as the highest-risk unknown — it is the
one open item that can force an architectural change rather than a fix.

### Open tidy-ups (small, mergeable now)
- `wip/b2a-fix` @ `31afd89` — F4 `RETIRE_EN` plumbing, **sim_gate 14/14**; merge has 2
  conflicts (`Makefile`, `tidelink_top.sv`); consolidation lacks the plumbing.
- `wip/sustained-data` — sustained/throughput instruments (`td_tput.c`, `--negctl`),
  credit-clamp RTL fix (A/B: 4106→4096), 2 harness bugs fixed (**`ZP_TX_WORDS` sent 3
  words for a 4-word header ⇒ `zeropoke_proof.sh` was validating an incomplete packet** —
  re-check any claim resting on it).
- Branch/worktree deletion — **deferred to David** (`w3_collapse.sh --execute` ready).

---

## 0-EXEC. STRATEGY TO CLOSE THE HOLES (2026-07-17, code-grounded on `integ/consolidation-2026-07`)

**Principle:** every hole gets a verdict — **CLOSE** (before freeze), **DEFER** (post-v1, in
writing), or **ACCEPT** (documented limitation). The failure mode here has never been leaving
holes open; it is leaving them *undecided* until they resurface as "chip-killers" (the `0xE4`
mask sat undecided for a month). Two standing gates on all of it: **no number without a named
md5**, and **every new oracle must prove it can go RED** (the `--negctl` pattern) — 15 instrument
failures this campaign have cost more than any real bug.

**Three corrections the scoping pass forced (integ is ahead of the prose):** `RETIRE_EN` (F4) is
**already merged** (`31afd89` is an ancestor); the a2l obs taps **are** wired (APB `0x2158`, one
level down in the controller, not `tidelink_top`); and the `validLaneSeq` power-of-2 whitelist
**does not exist** on integ in source or generated form — it is a **regeneration-hygiene note**,
not an open chip-killer (only bites if an *older* upstream `LinkLayer.scala` is used to regen).

### WAVE 0 — instruments first (½ day, no decisions, unblocks everything)
| # | Fix | Site | Why first |
|---|---|---|---|
| 9 | `PERF_CTRL` off-by-one → `apb_region - 4'd5` | `tidelink_apb_regs.sv:540` | **one line, revives EVERY perf counter** — the tools the rest of the campaign needs |
| 12a | guard `sim_gate_run` against `-n` (no fake PASS) | `Makefile:215-223` | a gate that lies is worse than none |
| 12b | gate `test_v2_fc_contiguous` + `test_v2_reduced_lane` (+ verify tb hook) | Makefile | rotted invisibly *because* ungated |
| 12c/d | de-hardcode `0xE4` in `lane_health_preflight.sh` (circular) + `td_v2_channels.sh` | host | part of the #7/#8 cluster |
| 11 | add a **gated** `EPOCH_PROFILE=silicon` suite | Makefile | today: no skew-faithful sim coverage |
All CLOSE, all sim/host-verifiable, all agent-executable. Do this wave before any measurement.

### WAVE 1 — land what's already fixed (½–1 day, merge + gate, no new design)
| # | Land | From | Gate | Note |
|---|---|---|---|---|
| 14 | capture-clock **parent BUFG hoist** | `phaseB/attack` `2c32c2b` | rebuild-variance ≥3 builds | **highest-risk landing — use the hoist, NOT the `USE_CAP_CLKBUF:80` flip (that inverts the capture edge and KILLS the link)** |
| 7 | host `TD_MASK` param + winscan lane-list | `wip/eight-lane` `c9e031d` (large) / `wip/oddlane` `7164ad9` | sim_gate | RTL is *already* mask-generic on integ; this is the host half only |
| — | F4 already merged; 25 MHz rate work | — | — | bank the 25 MHz cert (clean N=40, power-cycle discipline) |

### WAVE 2 — human decisions, then plumb (each is CLOSE once decided)
| # | The decision (David) | Then | Site |
|---|---|---|---|
| 1 | Is AHB-CPU-write-to-RX-FIFO supported? (evidence = no) | gate the write-side latch behind `ENABLE_AHB_WRITE=0` (must not disturb the FC-shared `write_ptr`) | `tidelink_fifo_ctrl.sv:189` |
| 4 | Ship silicon with debug unlocked + mask-handshake bypassed? (almost certainly no) | `HONEST_MASK_HS=1'b1` + strap the two ports | `tidelink_top.sv:141,2270` |
| 5 | Role source on I2C NACK — keep hardcoded-slave (⇒ both dies slave) or derive from strap? | NACK path + `nego_fallback` → `role_strap_i` (plumbing already exists) | `tidelink_autoneg.sv:950` |
| 6 | ASIC autonomy on/off + `RETIRE_EN` default | set `NEGO_CFG_RESET=7'h61` **and plumb it through the DFT wrapper** (today NOT forwarded ⇒ zero-poke cannot fire on the ASIC) | `tidelink_top.sv:123`, `dft:83` |
| 13 | Define "all channels" — which FCSM 0–4 map to which apertures | build the matrix harness | new |

### WAVE 3 — remaining engineering (CLOSE / DEFER split)
- **CLOSE #8** (mask one-shot re-latch, `controller:2096-2126`) — couples to #7; fix both or the
  split stays live from the host side. **CLOSE #2** (credit_max depth-derive, `FCSM_6.v:500`) —
  couples to the A→B fix, so verify the L9b re-anchor in sim (the reason it's hardcoded).
- **DEFER (post-v1, explicit):** the **adapter throughput fix** (`fc_adapter` "one store == one
  packet" + blocking write) — real and chiplet-relevant, but the payoff is unmeasurable on FPGA
  (Zynq PS→PL latency dominates); **size on-die first**. **Packing depth N** and **lane-width** —
  both measured ≈0; DEFER unless a PHY change (DDR/lanes/clock) happens.
- **ACCEPT (document):** v1's 800 Mbit/s raw PHY ceiling (functional prototype, not a performance
  part); the FPGA's ~28 MHz AXI/hclk rate ceiling (not the PHY).

### Ownership at a glance
- **Agents, now:** all of Wave 0; Wave 1 landings + gates; Wave 3 CLOSE items (each with red-first tests).
- **David:** the five Wave-2 decisions (each irreversible in silicon), the ribbon already cleared,
  KR260 board access, and the prototype-vs-performance framing (now easy: link is 83% idle, ceiling is the PHY).
- **Sequence:** Wave 0 → Wave 1 (parallel with decisions being sought) → Wave 2 plumb → Wave 3 → freeze cert.

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
- **Autonomous (zero-poke) bring-up: ✅ FIXED ON SILICON (2026-07-16).** Was link
  10/10, A→B 7/10, doorbell 4/10, **B→A 0/10**. Now **10/10 ALL channels**
  (link + A→B + B→A byte-exact + doorbell), `rea_a=rea_b=1` every cycle (no
  peer-starvation), on `wip/b2a-fix` @ `cd2db38`. **N=40 CERTIFICATION PASSED
  (2026-07-16) — the §3 gate is MET: 39/39 valid cycles, 100% ALL channels, CP 95% CI
  [91.0%, 100%]** (link/A→B/B→A/doorbell/ALL-4 each 39/39; cycle 2 = POR-FAIL, a
  power-cycle infra flake, excluded as non-test). Netlist-verified in the bitstream
  (WINSCAN_CELLS=108, RETIRE_CELLS=105 — not optimised out).
  **ROOT CAUSE — REFINED (the earlier framing was incomplete):** it is not merely
  that die_a "holds its own RX-commit while armed" — die_a's **winscan FSM
  LIVELOCKS**: it reaches a good anchor (fcsm=4, rea=1), then advances
  SETTLE→FINALIZE and **tears down its own FC** (fcsm 4→0), repeating, which
  perpetually disrupts RX-commit. `winscan_done` never stably sets (only blips at
  fail-open) — so a *verified-anchor / winscan_done* trigger is **INERT** (two
  such designs were built and caught by a free bench check BEFORE any build).
  **Working fix = retire autonomy on `reanchored && fcsm==4`** held ~160 ms (« the
  ~2.8 s churn onset) → DISARM-PARKs the churning FSM, replicating the proven
  `0x210C=0` escape hatch. Per-episode re-arm on training rise avoids the
  ws_kicked_q trap. **Sim is blind to the delivery — silicon soak is the only gate.**
  BUILD KNOB: must `export TIDELINK_PHY_V2=1` or the build silently falls back to
  the V1 flist and ships a **fix-less** bitstream (retire block is inside
  `ifdef TIDELINK_PHY_V2`). F4: `RETIRE_EN` not yet plumbed to `tidelink_top`
  (ASIC cannot gate it) — in progress.
  Deeper cause (still open): I2C autoneg NACK hard-codes SLAVE on both dies →
  role should come from a STRAP.
  **NOT closed by this:** continual/sustained data is UNPROVEN (only a single
  4-word packet per direction is tested); the recorded "long-burst drops first
  ~2 words (both dirs)" bug is unfixed and untested since — see §5/§7.
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
| `wip/b2a-fix` @ cd2db38 | P-A retire-autonomy fix (+F4 RETIRE_EN plumbing to top/FPGA-wrapper/ASIC-DFT-wrapper) | ✅ **GATE MET: N=40 silicon soak PASSED 2026-07-16 — 39/39 valid, 100% ALL channels, CP [91.0%,100%].** Build MUST export `TIDELINK_PHY_V2=1` (else V1-flist fix-less bitstream) |
| `wip/sustained-data` (new, off cd2db38) | sustained/continual-data test + long-burst first-2-words bug repro | sim repro, then silicon (boards queued behind N=40) |
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

# Bug C HW historical bisect — 2026-05-30

**Goal**: determine whether S→M doorbell delivery has always been broken on
silicon or whether it appeared at a specific build.

**Lease**: bridge1 (pynq_z2_02 master `.4.101`, pynq_z2_03 slave `.6.101`),
held mapstone-dev/dam1n19 token `aIF22uC2I_…`, released cleanly.

**Bitstreams tested** (all SHA-verified via manifest; no PS-hang risk —
build #6 deliberately skipped per task brief):

| Build | master sha256 (prefix) | slave sha256 (prefix) | branch (per backup ledger) |
|---|---|---|---|
| #3 | `d15adec00517…` | `b02cecc9c66d…` | fix/fcsm-l7-wedge-watchdog era |
| #4 | `a28fd2f560b7…` | `2de40e8527b7…` | build-4-ILA (mark_debug regression) |
| #5 | `e4783985d48a…` | `f77a36ac63ff…` | build5-ila (f10e6fefb…) |

Bringup methodology: each build was deployed via `deploy_pair.sh` (no
`SWI_TRAINING_MODE` writes per task) and then trained with
`bringup_pair_converge.sh` (parallel coordinated recal; 16/16 in 1 iter on
every build/role-combination tested). Doorbell test was the per-direction
APB sequence: clear peer's `DB_RESP` (offset 0x024, R-clears), local writes
`REG_DOORBELL` (0x014) N=100..200 times, settle 1–2 s, re-read peer's
`DB_RESP`.

## 1. Executive summary

**S→M doorbells are broken on every safe historical bitstream (#3, #4,
#5).** The bug has been present continuously from at least build #3 onward —
it is **not** a regression introduced between builds.

The earlier `BUILD5_HW_VALIDATION_2026_05_30.md` claim that M→S worked on
build #5 was a **measurement artefact**: the converge cycle leaves the
slave's `DB_RESP=0x00001000` post-bringup independent of any application
doorbells. That document read `DB_RESP=0x1000` "after ~10 doorbells" and
attributed it to delivery; this bisect proves the 0x1000 is present
BEFORE the first ring (it is converge-cycle residue), and a single
read-clears it back to 0 where it stays even after 50–200 explicit rings
from the peer.

**M→S delivery is ALSO broken** on all three builds once the stale
`DB_RESP` is cleared. The earlier "M→S works on build #5" finding
collapses on this controlled retest. Both directions are dead.

**Role-swap does not unmask delivery.** Build #3 and build #5 were also
tested with `SWAP=1` (z2_03 drives die_a/master, z2_02 drives die_b/slave
— same straight-through wiring, opposite role assignment). Result is
identical: both directions still zero. **The bug follows the protocol /
RTL, not the physical board or role assignment.**

## 2. Per-bitstream results

All rows: post-converge, lane-locked 16/16, `cal_done=1`, both ends FCSM
≥4 (LINK_IDLE). M→S = master rings 100, read slave `DB_RESP`. S→M = slave
rings 100, read master `DB_RESP`. "Pre-clear" = the read used to clear the
stale residue immediately before the ring (excluded from delivery delta).

| Build | Role layout | Pre-clear M / S | M→S delivered | S→M delivered |
|---|---|---|---|---|
| #3 (no converge baseline — invalid, see note) | normal | M=0x1000 S=0x1000 | 0 (0/100) | 0x1000 (residue, see note) |
| #3 | normal (z2_02=die_a, z2_03=die_b) | M=0 S=0 | **0 / 100** | **0 / 100** |
| #3 | **SWAP** (z2_03=die_a, z2_02=die_b) | M=0x1000 S=0x1000 | **0 / 100** | **0 / 100** |
| #4 (lane-lock 0x00 in single-shot, see note) | normal | M=0 S=0 | **0 / 100** | **0 / 100** |
| #4 | normal post-converge | M=0 S=0 | **0 / 100** | **0 / 100** |
| #5 | normal | M=0x1000 S=0x1000 | **0 / 100** | **0 / 100** |
| #5 | normal post-converge (test 2: slow ring 200 with 1 ms gap) | M=0 S=0 | **0 / 200** | **0 / 200** |
| #5 | **SWAP** | M=0x1000 S=0x1000 | **0 / 100** | **0 / 100** |

**Notes on baseline rows**:

- The "build #3 no-converge baseline" S→M = 0x1000 line is a measurement
  artefact: that 0x1000 is converge-cycle residue (or a parallel deploy
  side effect) that was present BEFORE the rings, not delivered traffic.
  The same value appears at the same time on both sides in every other
  post-converge run, regardless of whether any explicit doorbell was rung.
  A double-read confirmed `DB_RESP` is correctly R-clears.
- Build #4 baseline without converge ran with `LANE_STATUS=0x00840000`
  on the master (lane-lock byte = 0x00, fault byte = 0x84 — the known
  `mark_debug` regression on `pair_credit_counter` from build #4). After
  converge build #4 reaches `0xff` locked, but doorbells still don't
  deliver.

Side observables captured on build #5 post-converge with slow rings
(extended probe in transcript):

- Master `STATUS` ticks 0x00 → 0x01 on local rings (sticky/local ack
  path is alive); slave `STATUS` stays 0x00.
- `RELEASED_ACC` (0x020) stays 0 on both sides through all rings — no
  credit-packet acknowledgements crossing the wire either direction.
- `PAIR_CREDIT_COUNTER` (0x028) stays 0 on both sides — the cross-link
  credit accountant never increments. Local `CREDIT_COUNT` (0x00C)
  stays at the reset value 0x1000.

## 3. Role-swap interpretation

Role-swap changes which physical board runs which strap/bitstream:

| Run | z2_02 (.4.101) | z2_03 (.6.101) | M→S | S→M |
|---|---|---|---|---|
| normal | die_a (master, `tidelink.bin`) | die_b (slave, `tidelink-flip.bin`) | 0 | 0 |
| swap   | die_b (slave, `tidelink-flip.bin`) | die_a (master, `tidelink.bin`) | 0 | 0 |

Result is identical. Therefore:

- Asymmetry does **NOT** follow the role assignment (the bug is not
  "the slave-bitstream RX path is dead while master's works").
- Asymmetry does **NOT** follow the physical board (it is not "z2_02 has
  a bad pad / wiring fault").
- The bug is **symmetric**: both directions equally dead on both
  bitstreams in both physical orientations. This is an end-to-end DB
  framing / FC-adapter / RTL-layer pathology, not a wiring/pad/strap
  issue and not a role-cfg asymmetry.

## 4. Implications

### How long has it existed?

**Continuously since at least build #3.** The bisect cannot push earlier
without staged backups — but #3 is the earliest backed-up safe build and
already exhibits the bug, so the regression that introduced this is
**older than build #3** (i.e. either pre-dates the staged-backup window
or is a primordial bug in the doorbell/FC delivery path that has never
worked end-to-end on silicon).

The "S→M wasn't tested earlier" finding from
`BUILD5_REVALIDATED_OA_TEST_2026_05_30` is now upgraded: it isn't just
that S→M was untested — **neither direction has ever worked on
silicon**, the "M→S works" claim across the bring-up arc was driven by a
converge-cycle residue counter that was misread as delivered traffic.

### Bug location — RTL layer, not build-specific

The bug is **build-independent** (identical on #3, #4, #5 — three
different commits across the FCSM-watchdog / mark_debug / fix-and-revert
arc) and **role-independent** (identical normal vs swap). Therefore it
lives in code paths that are not exercised by the lane-locking /
calibrator / IDELAY layers (which all reach 0xff/0xff/cal_done=1 fine)
nor by APB local-bus paths (the local doorbell write hits the local
sticky `STATUS` bit correctly). The candidate layers are:

1. **TideLink FC adapter** (`tl_fc_a2l_*` / `tl_fc_l2a_*` paths) — turning
   a local `doorbell_trigger` pulse into an FC packet for the peer.
2. **Wlink LL_TX → LL_RX of the doorbell-class FC packet** — the FCSM
   that carries non-data control packets across the link.
3. **Peer-side decode** — turning the received doorbell FC packet back
   into a `doorbell_response_acc` increment.

Sim-level dorbell delivery is reported as working in
`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` (per existing
project context); HW does not match sim. The discrepancy is most likely
to live in a path that sim exercises differently (synchronisation /
clocking domain crossing of the doorbell trigger from APB to the FC TX
side, or the `PAIR_BASE_ADDR`-driven target-address generation, or the
returner / fc_adapter glue identified as the bug seat in earlier
`project_tidelink_bug_isolated_2026_05_26` work).

The `PAIR_CRED=0` / `RELEASED_ACC=0` observation across all runs is a
particularly strong fingerprint: those are pure FC-packet-arrival
counters. They tick only when ANY FC packet (credit, doorbell, anything)
is received from the peer. They are zero in every direction in every
build. This strongly suggests no FC packet of any kind is being delivered
end-to-end on this codebase — the lane-lock and calibrator work, but the
FC framing/depacketising stage above the link is silent.

## 5. Recommended next step

**For the fix-implementation agent:**

The hypothesis to fix is **not** "build #N regressed doorbells" — they
were never working. Hand off to the next stage with these constraints:

1. **Re-test sim** — re-run `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`
   (or its current equivalent) WITHOUT any AHB_TX path, just clean
   APB-doorbell-from-master → APB-doorbell_response_acc-on-slave (the
   HW-equivalent reduced setup). Verify sim actually delivers doorbells
   end-to-end in this minimal config. If sim ALSO shows zero delivery
   end-to-end at the FC layer (i.e. `RELEASED_ACC` stays 0, `PAIR_CRED`
   stays 0), then the sim oracle for "doorbell delivery" was looking at
   the wrong signal and the bug is a primordial RTL gap rather than a
   HW-only mismatch.
2. **Add the missing observability**: a small probe on
   `tl_fc_a2l_valid` (FC adapter raising a frame to LL) when
   `doorbell_trigger` pulses, and `tl_fc_l2a_valid` (LL handing a
   received frame to the FC depacketiser) at the slave. These are not
   currently observable from APB on the deployed bitstream; need an ILA
   build or APB shim.
3. **Investigate `PAIR_BASE_ADDR` plumbing** specifically — both sides
   write `0x44032000` and that is the local APB base. If the FC TX
   target-address logic is using `PAIR_BASE_ADDR + 0x024` as the
   destination but the peer's APB shim discards the high bits (or the
   write address never reaches the peer's `acc1_write` decode), the
   doorbell-response counter on the peer side will never tick — exactly
   the symptom we see.

**Constraints honoured**:

- Bridge1 lease acquired/released cleanly (`released pynq_z2_02_pl,
  pynq_z2_03_pl`), no leak.
- Build #6 NEVER deployed.
- `SWI_TRAINING_MODE` (Region-8 0x100 bit[0]) NEVER written by this
  bisect's APB writes.
- Independent of `docs/BUGC_RTL_ANALYSIS_*`, `docs/BUGC_XDC_ANALYSIS_*`,
  `docs/BUGC_SIM_REPRO_*` — none consulted (none in working dir).

## Appendix — raw log locations

Per-run logs on the local dev host:

- `/tmp/bisect_build3_normal.log` — build #3 normal (no converge,
  baseline-only run)
- `/tmp/bisect_build4_normal.log` — build #4 normal (no converge)
- `/tmp/bisect_build5_normal.log` — build #5 normal (no converge)

Post-converge runs (build3/4/5 normal + build3/5 swap) and extended
observability run inline in the session transcript; reproduce with the
`bringup_pair_converge.sh` + `td_db_bisect.py status|ring|read_resp`
sequence used above. Test helper staged at `/tmp/td_db_bisect.py` on
mapstone-dev.

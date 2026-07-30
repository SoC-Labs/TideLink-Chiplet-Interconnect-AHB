# I1 Recovery-FCSM — Resolution Roadmap (workaround + bring-up-safe redesign)

Status: DESIGN / STRATEGY. No RTL edit, no FPGA build, no HW, no push in this branch.
Branch: `strategy/i1-recovery-redesign`. Author role: senior RTL design.
Date: 2026-07-30.

---

## 0. TL;DR

* **Now (workaround):** re-point `flists/tidelink_fpga_v2.flist` lines **292–296**
  (`WlinkGenericFCSM.v`, `_1`, `_2`, `_3`, `_4`) from `src/rtl/local_overrides/` back to
  `deps/axi-chiplet-controller/logical/wlink/` — exactly the config the two ASIC flists already
  ship (`tidelink_top_full_asic.flist:150-155`). **Pure flist edit, zero RTL.** Restores the
  clean cold bootstrap on both the eth-chiplet KR260 pair and the Z2 pair (same flist).
* **Cost:** loses the (never-HW-validated) traffic-wedge recovery, and — importantly — turns the
  **blocking** gate `sim_gate_nack_wedge_recovery` RED, because those two cocotb tests compile
  `tidelink_fpga_v2.flist` and assert the `socl_*` recovery that only the override carries. The
  workaround MUST therefore also de-gate that suite (§4.3). Do not paper over it.
* **Real fix (redesign):** keep the recovery capability but make it **structurally incapable of
  touching the bootstrap** — port `socl_*` into the Chisel source `FC.scala` as a
  default-OFF, LINK_IDLE-gated recovery block that (a) adds no module port, (b) is bit-identical
  to `deps` at the module outputs during states 0–3, and (c) is footprint-fenced out of the
  source-synchronous forwarded-clock capture region. §5.
* **The invariant** (§3): role_lock → training-arm → calibrator-arm → forwarded-clock-enable must
  establish FIRST and must never depend on any FCSM/CR/CRACK/protocol event. The recovery arms
  only after first LINK_IDLE and feeds back into none of those four.

---

## 1. Silicon-confirmed problem (ILA, 07-30)

The I1 change (`b98b944`, in consolidated `main` @ `18491ef`) re-points the five muxed AXI-node
flow-control state machines (`WlinkGenericFCSM.v` + `_1.._4`) from `deps` to hand-edited
`local_overrides` copies carrying the `socl_l6_* / socl_l7_* / socl_reack_*` recovery
(min-CR/CRACK emit gates, ACK-drop re-ack, wedge watchdog). Intent: let the FC SMs self-recover
from a mid-traffic wedge.

It **breaks cold bring-up**. On the instrumented override eth-chiplet pair, both dies read:

```
SWI_LANE_STATUS 0x2E03_2108 = 0x00100000   (cal_done=0, fcsm=0, cr_seen=0)
winscan obs:  cal_state=0  ever_swept=0 (sticky)  training=0  lane_fault=0x00  eye=all-zero
0x2100 = 0  => swi_training_mode_r = 0
0x2084[1] = 0 => role_locked = 0            (despite bring-up writing ROLE_CFG=0x02)
```

The calibrator **never arms**: its arm term is `nego_en & role_locked & swi_training_mode_r`
and two of the three are stuck low. `role_locked` is a **mutual clock enable** — it gates this
die's forwarded `pad_clk_tx`, which IS the peer's `pad_clk_rx`
(`project_role_lock_is_a_mutual_clock_enable_2026_07_24`). With `role_locked=0` the RX clock
domain on the peer is silent, so no winscan runs, nothing aligns, no CR is captured. The failure
is a **control-plane bootstrap deadlock**, not the capture-phase timing miss the earlier
below-RTL/STA analysis converged on.

`deps` FCSM (no recovery) brings up fine on the same boards, proven ≥3×.

---

## 2. What is actually established (structural forensics done in this pass)

Three facts were verified first-hand against current RTL, because the fix must rest on
structure, not on the (already 4×-refuted) emit-gate theories.

### 2.1 The FCSM module boundary is byte-identical deps↔override — 36 ports, no diff
`diff` of the port lists of `deps/.../WlinkGenericFCSM.v` vs
`src/rtl/local_overrides/WlinkGenericFCSM.v` is **empty**: identical 36 ports
`{clock, reset, auto_in_* APB, auto_rx_* packet-in, auto_tx_* packet-out, io_app_* a2l/l2a,
io_tx_clk/rst, io_rx_clk/rst, io_rx_crc_err}`. **None of them is `role_locked`,
`swi_training_mode_r`, the calibrator arm, or the forwarded-clock enable.** The override changed
only internal logic (170 added / 18 removed lines in `FCSM.v`).

**⇒ There is no wire by which the FCSM can logically drive the bootstrap.** A "circular deadlock
role_lock ↔ calibrator ↔ FCSM" as a *netlist* dependency is impossible in the present hierarchy:
the FCSM lives inside `Wlink`, downstream of everything in §2.2.

### 2.2 The entire bootstrap chain is in `axi_chiplet_controller.sv`, upstream of Wlink, and references no FCSM output
Traced in `src/rtl/local_overrides/axi_chiplet_controller.sv`:

| Bootstrap node | Where | Set by | FCSM term? |
|---|---|---|---|
| `wlink_por_reset = ~poresetn \| ~role_locked` | `:2921` | role_locked | no |
| `role_locked = role_lock_reg` | `:639` | — | — |
| `role_lock_reg <= 1` | `:862-868` | `(nego_lock_pending & mask_hs_gate_open) \| (nego_lock_pending & nego_lost)` OR APB `ROLE_CFG[1] & mask_hs_gate_open` | **no** |
| `swi_training_mode_r <= 1` | `:2120-2123`, `:2147` | autoneg `local_training_mode_set_w` / APB `SWI_TRAINING_MODE` | **no** |
| calibrator arm | one-shot on `nego_en & role_locked & swi_training_mode_r` | `:1653`, `:2237-2238` | **no** |

Every set condition is in the apb/ctrl clock domain and is a function of `poresetn`, the nego
FSM, the mask-handshake gate, and APB writes — **not** of FCSM state, CR, CRACK, `cr_seen`, or
any Wlink-internal signal.

### 2.3 Reconciliation — the coupling is NOT a logic wire; it is one of two below-the-netlist paths
Because §2.1 + §2.2 rule out a logical FCSM→bootstrap edge, the mechanism by which the override
drives `role_locked=0 / training=0` on silicon is **one of** (the roadmap is safe against both):

* **(A) Footprint / physical timing.** The FCSM `state` reg and all `socl_*` flops are in the
  `io.tx.clk` domain (`FC.scala:143` — `withClockAndReset(io.tx.clk.asClock, io.tx.reset...)`),
  i.e. the **forwarded source-synchronous launch clock**. The override adds ~65 regs / +7 tx-clk
  flop stages across the 5 muxed nodes; the self-run STA A/B measured +51 flops bunched into the
  `cr_pkt_seen`-capture region and a 40→62 slice spread, on paths that are **unconstrained by
  construction** (runtime-calibrated winscan domain — STA cannot see them). This perturbs the
  capture-clock insertion delay / launch phase and can push the winscan rendezvous out of lock.
  This mechanism explains `cal_done=0` cleanly; it explains `role_locked=0/training=0` only via
  the mutual-clock-enable feedback (a perturbed die never lets its peer's autoneg complete, so
  the peer never latches role_lock, which re-gates the clock — bilateral).
* **(B) Obs-build / control-plane artifact.** The ILA obs image was built on **consolidated main
  `a87eb93`**, not on the minimal I1 isolation `90fe6cc` (the latter's flist lacks
  `tidelink_tx_gen.sv`). `role_lock_reg` needs `mask_hs_gate_open` (`:867`) and, on the nego
  path, a completed handshake (`:862`); `swi_training_mode_r` on the slave is written by the
  master's autoneg over I²C. A stall in mask-hs/nego on that particular build would produce the
  identical `role_locked=0/training=0` **without the FCSM being the cause** — which is why the
  memory flags "override-specific-vs-main-base" as OPEN and calls for a deps+obs reference on the
  same base.

**This fork is unresolved and it is a decision point in the sequencing (§6), because the *shape*
of the "real fix" differs:** (A) ⇒ footprint reduction + physical fence; (B) ⇒ the FCSM override
is (partly) exonerated and the real fix is in the mask-hs/nego bring-up. The redesign in §5 is
constructed to be correct under (A) and to be **inert** (hence harmless) under (B).

---

## 3. THE INVARIANT — what must be true for ANY recovery FCSM to be bring-up-safe

A recovery FCSM is bring-up-safe **iff** all four hold. These are the acceptance criteria for §5
and the checklist for any future change to `WlinkGenericFCSM*.v` / `FC.scala`.

1. **I1 — Module-boundary invariance.** The recovery adds **no port** to `WlinkGenericFCSM*.v`
   that connects to `role_locked`, `swi_training_mode_r`, the calibrator arm, or the
   forwarded-clock enable. (Holds today; §2.1. Must never regress. This is the structural
   guarantee that there can be no logical FCSM→bootstrap deadlock.)

2. **I2 — State-gated inertness (deps-equivalence during 0–3).** Every recovery flop
   (`socl_l6_*`, `socl_l7_*`, `socl_reack_*`) is held in its reset/inert value and must not
   influence any module output (`auto_tx_out_*`, `io_app_a2l_ready`, `io_app_l2a_valid`, `nstate`)
   until the SM has first reached **LINK_IDLE** (`state=4`, `FC.scala:43`). During states
   IDLE/SEND_CREDITS1/SEND_CREDITS2/LINK_EN_WAIT the elaborated recovery-ON netlist must be
   **bit-for-bit identical at the outputs** to the recovery-OFF (`deps`) netlist. This is the
   property that makes cold bring-up deps-identical *by construction*, independent of thresholds.

3. **I3 — Footprint / timing neutrality in the capture region.** The recovery's added `io_tx_clk`
   flops must not be placed or merged into the source-synchronous forwarded-clock CR-capture
   logic (`cr_pkt_seen` / launch flops). Enforce by (a) bounding the added flop count, and
   (b) a physical keep-out / hierarchical fence around the CR launch/capture flops, or by moving
   the recovery bookkeeping to a timing-decoupled clock. The recovery must not shift the RX
   capture-clock insertion delay. (Directly targets mechanism 2.3-A.)

4. **I4 — No new SW/protocol bring-up dependency.** The recovery requires no new APB write, no new
   handshake, and no CR/CRACK/`cal_done` precondition during states 0–3. The exact cold-boot
   recipe that works on `deps` works unchanged.

If a proposed recovery cannot demonstrate I1–I4, it is not deployable, regardless of how good its
wedge-recovery numbers look in sim.

---

## 4. Immediate workaround (proven, pure flist edit)

### 4.1 Exact change — `flists/tidelink_fpga_v2.flist`
Current (I1, override active):

```
292 ${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCSM.v
293 ${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCSM_1.v
294 ${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCSM_2.v
295 ${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCSM_3.v
296 ${TIDELINK_HOME}/src/rtl/local_overrides/WlinkGenericFCSM_4.v
297 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_5.v
```

Workaround (re-point 292–296 to `deps`; leave 297 as-is):

```
292 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v
293 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_1.v
294 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_2.v
295 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_3.v
296 ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_4.v
```

* **Exactly 5 lines change** (292–296). `WlinkGenericFCSM_5.v` (line 297) is already `deps`.
* **`WlinkGenericFCSM_6.v` (line 304) STAYS `local_overrides`** — it is the L6 producer-side
  sideband fix, is present on the deps config too, and is unaffected by I1 (single dedicated node,
  not one of the 5-way mux). `WlinkRxLinkLayer.v` (line 301) stays `local_overrides`.
* Update the header comment block (lines 277–291) to record the revert and reference this doc.
* **This is a pure flist / file-selection edit. No `.v`/`.sv`/`.scala` is modified.** The
  resulting config is identical to the two ASIC flists, which already hold FCSM 0–5 on `deps`
  (`tidelink_top_full_asic.flist:150-156`, `..._v2.flist:270-276`) — i.e. the tapeout netlist was
  never on the override, so this makes FPGA match tapeout.

### 4.2 Why it restores the clean bootstrap
`deps` FCSM has none of the `socl_*` regs, so mechanism 2.3-A (the +51 capture-region flops) is
removed and the source-sync capture returns to the proven timing. Because the FCSM cannot touch
the bootstrap logically (§2.1/2.2), removing the override cannot introduce any *new* bootstrap
risk — it can only restore the historically-proven behavior. This is the same FCSM source the
Z2-proven and KR260-proven images already run.

### 4.3 Sim-gate implications — READ THIS, the workaround is NOT gate-neutral
* **Stale-simv:** the flist re-point is an RTL-set change. Every cocotb suite that compiles
  `tidelink_fpga_v2.flist` must be **recompiled**; `make sim_gate` is staleness-guarded
  (`cocotb/tidelink_top_pair/Makefile:81-88` tracks the flist + its srcs), but ad-hoc runs are
  not. Run `make sim_gate` fresh, do not reuse `imp/sim_gate/`.
* **`sim_gate_nack_wedge_recovery` WILL go RED.** That blocking suite runs
  `test_l7_wedge_repro` + `test_13_ack_drop_recovery` in `cocotb/tidelink_top_pair/` under
  `TIDELINK_PHY_V2=1`, which compiles `tidelink_fpga_v2.flist` (`.../Makefile:40`). Those tests
  assert the `socl_l7 / socl_reack` recovery — **deps FCSM has no such logic**, so they lose their
  DUT capability and fail. **The workaround must therefore also convert
  `sim_gate_nack_wedge_recovery` from blocking to an XFAIL sentinel** (mirroring how
  `sim_gate_xfail_f14b` is handled), with a one-line reason "recovery withdrawn to deps pending
  I1 bring-up-safe redesign — see docs/I1_RECOVERY_REDESIGN.md", and reinstated as blocking when
  §5 lands. **Do not** point only the cocotb suite at an override flist while shipping deps in the
  bitstream — that would make the gate assert a capability absent from the deployable image
  (the exact green-but-blind failure class this whole saga is about).
* **All other suites stay green.** deps FCSM is the config every prior gate-green run and every
  HW-proven image used; the v2 pair suites (`v2_data`, `v2_sustained`, `epoch_silicon`, …) reach
  LINK_DATA on deps. Confirm by running the gate, not by assertion.

### 4.4 Cost
Loses the traffic-wedge recovery (`socl_reack` re-ack, `socl_l7` wedge watchdog). Note this
capability was **never HW-validated** — it only ever passed sim — and the two candidate silicon
fixes for its bring-up side-effect were both refuted, so the net delivered value withdrawn is
"an unproven capability plus a proven bring-up break." The workaround is strictly positive for
deployability.

---

## 5. Bring-up-safe recovery redesign (the real fix)

Goal: keep wedge-recovery, satisfy I1–I4. The design has three parts — where it lives, how it is
gated, and how it is fenced.

### 5.1 Where it lives — Chisel `FC.scala`, not 6 hand-edited netlists
Today the recovery exists **only** as hand-edited generated Verilog, duplicated across 6 drifting
copies (`WlinkGenericFCSM.v` + `_1.._4` = the 5 AXI nodes, `_6` = sideband). That is
unmaintainable and is itself a defect source (the I1 tapeout-merge "accidental swap" and the
2026-07-11 re-resolve both trace to netlist copies drifting). **Port the recovery into the single
Chisel source** `/home/dam1n19/SoCLabs/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`,
gated behind a **default-OFF elaboration parameter** so every generated node is emitted from one
source and the FPGA/ASIC selection is a config bit, not a file swap. `FC.scala` already carries a
rocketchip `Parameters` context (`FC.scala:18`), so a `WlinkFCRecoveryKey`/`fcRecoveryEn: Boolean`
threads the same way `EPOCH_ANCHOR_EN` was threaded through `Wlink`→deskew. Default `false` ⇒
regenerated Verilog is **diff-identical to today's `deps`**, which is the I2 acceptance test in
generated form.

### 5.2 How it is gated — a LINK_IDLE-armed recovery block, not inline edits to the bring-up states
The override's defect is **structural inline-ness**: it weaves recovery into the states cold-boot
must traverse. Concretely, `socl_l7_crack_release` drives the **CR/CRACK emit content and a state
jump** inside `SEND_CREDITS2` (override `WlinkGenericFCSM.v:316-321`, annotated `@[FC.scala
476-486]`) — i.e. it can alter what a node emits and force `nstate:=SEND_CREDITS2/LINK_EN_WAIT`
**during bring-up**, and it is NOT gated on `reached_link_data`. (`socl_l7_bringup_forgive` gates
only `isNotExpPacket_l7`; the emit/state path is ungated.) That is a direct I2 violation and the
most likely logical contributor if any part of the break is logical rather than 2.3-A.

Redesign:

* **Arm latch.** `val reachedLinkIdle = RegInit(false.B); when(state === LINK_IDLE){ reachedLinkIdle := true.B }`
  in the `io.tx.clk` domain. (Equivalent to a correct `socl_l7_reached_link_data`, but authoritative
  and used everywhere.)
* **Single gate, applied to ALL recovery effects.** Every recovery-driven mux — the L6/L7 emit
  gates, `socl_l7_crack_release`, the `socl_reack_*` re-ack, the wedge watchdog — is wrapped so it
  can only alter `nstate`/`*_in`/`auto_tx_out_*` **inside `when(reachedLinkIdle)`** (and only from
  the operational states LINK_IDLE/LINK_DATA/SEND_ACK/SEND_NACK, `FC.scala:43-46`). The bring-up
  arms `when(state===IDLE/SEND_CREDITS1/SEND_CREDITS2/LINK_EN_WAIT)` (`FC.scala:444-499`) are left
  **exactly as deps** — the recovery block is additive and downstream, never editing those `when`
  bodies.
* **Recovery as a peer FSM, not extra transitions on the bring-up FSM.** Prefer a small separate
  recovery sub-FSM (or an orthogonal `recoveryPending` reg + one operational-state hook) reachable
  **only** from LINK_IDLE/LINK_DATA, so the bring-up path has zero added fan-in. This also caps the
  added `io_tx_clk` flop count for I3.

Result: for states 0–3, `reachedLinkIdle=0` ⇒ every recovery mux selects its deps value ⇒ outputs
are deps-identical (I2, and provable by elaboration diff, §6.4). The recovery is physically present
but electrically inert until the link has already come up.

### 5.3 How it is fenced — footprint / timing (I3), the part the emit-gate fix ignored
Because the true silicon coupling is most likely 2.3-A (added flops perturbing the STA-invisible
forwarded-clock capture), gating alone is necessary but **not sufficient** — an inert flop still
occupies the capture region. So:

* **Bound the added `io_tx_clk` flops** (target: single-digit per node, vs the override's ~13/node).
  Push counters/watchdogs that don't need launch-clock timing into a slower housekeeping clock or
  share one recovery block across nodes where the mux structure allows.
* **Physically fence** the CR launch/capture flops: a placement keep-out / hierarchy boundary so
  the synthesizer cannot merge recovery flops into the `cr_pkt_seen` cone. Re-run the STA A/B
  (`report_timing` into `cr_pkt_seen`/`cal_done`, util + slice-spread in the capture region) and
  require the spread to return to the deps baseline (40 slices, not 62).
* **Acceptance:** the redesign is only bring-up-safe once an on-silicon ILA on a recovery-ON build
  shows the calibrator ARMS (`cal_state≠0`, `ever_swept=1`, `role_locked=1`, `training=1`) and
  reaches `cal_done=1` — i.e. it directly clears the §1 signature. STA cannot prove this (the path
  is unconstrained); the board is the only instrument (2.3-A is STA-invisible by construction).

### 5.4 Why the emit-gate fix missed this (silicon-refuted 07-30)
The emit-gate fix held the L6/L7 state-**exit** gates open until first LINK_IDLE. It failed
because:
1. **Wrong signal.** The exit gate is downstream of `cr_seen`, and on silicon `cr_seen` never even
   flickers — the SM never leaves state 0/1, so an exit gate is unreachable. It treated a
   *livelock the sim reproduced* while silicon fails at *bring-up* (`cr_seen=0`).
2. **Ignored I3 entirely.** It changed logic but left the ~65-flop footprint intact, so under
   mechanism 2.3-A it could not possibly help — the perturbation it needed to remove was still
   there. This redesign's I3 clause is precisely the term the emit-gate fix omitted.
3. It also left the `socl_l7_crack_release` inline emit-content edit in the SEND_CREDITS2 body
   untouched (I2 violation preserved).

So this redesign differs by attacking **inertness (I2) + footprint (I3) + boundary (I1)** together,
not the exit gate. Any recovery that only tunes thresholds or exit gates is refuted a priori.

---

## 6. Sequencing, decision points, risk

Order of operations; each step gates the next.

### Step 1 — Land the workaround NOW (low risk)
* Edit `flists/tidelink_fpga_v2.flist` 292–296 → deps (§4.1); convert
  `sim_gate_nack_wedge_recovery` to XFAIL sentinel (§4.3); update flist header + this doc ref.
* `make sim_gate` fresh; confirm all-green except the intentionally-XFAIL recovery sentinel.
* **Decision point:** gate green (minus the sentinel) ⇒ this branch/flist is the deployable base
  for eth-chiplet and Z2. **Risk:** low — it is the ASIC/HW-proven config. Only risk is forgetting
  the stale-simv rebuild or leaving the recovery suite blocking (would false-RED the gate).

### Step 2 — Confirm the root cause A-vs-B (one instrument step) BEFORE building the redesign
* Build a **deps+obs reference on the SAME consolidated-main base** as the ILA override-obs image
  (`a87eb93`-class): does deps arm the calibrator (`role_locked=1`, `training=1`,
  `cal_done=1`) on that base?
  * **deps ARMS ⇒ mechanism (A)** confirmed FCSM-footprint. Redesign per §5 with §5.3 as the
    load-bearing clause.
  * **deps ALSO fails to arm ⇒ mechanism (B)**: the obs build has a bring-up bug independent of
    the FCSM (mask-hs/nego). The FCSM override is (partly) exonerated; the "real fix" moves to the
    control plane, and §5 still stands as the *safe* way to reintroduce recovery but is no longer
    urgent. **Do not skip this — it decides where engineering effort goes.**
* **Risk if skipped:** you could spend a redesign cycle footprint-fencing an innocent FCSM while a
  mask-hs/nego bug ships. Cost of the step: one obs build + one bench read; cheap vs a redesign.

### Step 3 — Redesign in `FC.scala` (default-OFF)
* Implement §5.1–5.3. Thread `fcRecoveryEn` (default false). Regenerate all 6 FCSM Verilogs from
  the one source.
* **Decision point / I2 gate:** `fcRecoveryEn=false` regenerated Verilog must **diff-match today's
  `deps`** (elaboration equivalence). If it doesn't, the parameterization leaked into the OFF path
  — stop and fix before proceeding. **Risk:** medium — Chisel port must reproduce the netlist
  exactly; mitigated by the diff gate.

### Step 4 — Sim-validate (recovery-ON) without regressing bring-up
* New/kept suites, all trust-gated: (a) `nack_wedge_recovery` GREEN with `fcRecoveryEn=true`;
  (b) a **bring-up equivalence** suite proving states 0–3 outputs are deps-identical with recovery
  ON (the I2 sentinel — must stay GREEN); (c) the full v2 pair suite reaches LINK_DATA with
  recovery ON. Re-instate `sim_gate_nack_wedge_recovery` as blocking only when (a)+(b) hold.
* **Risk:** sim is blind to 2.3-A (proven 3× this saga). Passing sim is necessary, NOT sufficient
  — it cannot bless the build for HW. Guard against declaring victory here.

### Step 5 — Footprint STA A/B, then HW-validate (the only sufficient step)
* STA A/B recovery-OFF vs recovery-ON: require capture-region slice-spread back to the deps
  baseline (I3). Then **on-silicon ILA** on a recovery-ON eth-chiplet/Z2 build: require the §5.3
  acceptance (calibrator arms, `cal_done=1`, link up + byte-exact soak) AND a genuine mid-traffic
  wedge-and-recover demonstration.
* **Decision point:** only if HW shows bring-up UP **and** recovery works does `fcRecoveryEn=true`
  become the default / ship. Otherwise keep default OFF (== the workaround) and iterate §5.3.
* **Risk:** highest-cost step (build + 2-board bench). This is why Steps 2 and 4's gates exist — to
  not spend a board cycle on a build that STA/sim already disqualify.

### Risk summary
| Step | Risk | Mitigation |
|---|---|---|
| 1 workaround | low | ASIC/HW-proven config; run gate fresh; de-gate recovery suite honestly |
| 2 A/B root cause | low cost, high leverage | one obs build decides fix shape |
| 3 Chisel port | medium (netlist fidelity) | OFF-path diff-match gate vs deps |
| 4 sim-validate | sim blind to 2.3-A | trust-gate; treat as necessary-not-sufficient |
| 5 STA+HW | high cost | only step that can bless recovery-ON; gated by 3+4 |

---

## 7. One-paragraph answer to "what must be true"
Any recovery FCSM is bring-up-safe **iff** (I1) it adds no module port touching
role_lock/training/calibrator-arm/forwarded-clock-enable — so the bootstrap can never depend on it;
(I2) every recovery flop is inert and output-equivalent to `deps` until first LINK_IDLE — so cold
bring-up is deps-identical by construction; (I3) its added `io_tx_clk` flops are bounded and fenced
out of the source-synchronous CR launch/capture region — so it cannot perturb the STA-invisible
forwarded-clock capture timing; and (I4) it needs no new APB/handshake/CR/CRACK/cal_done
precondition during states 0–3 — so the proven cold-boot recipe works unchanged. role_lock,
training-arm, calibration, and the forwarded-clock enable establish FIRST and depend on none of the
FCSM/CR/CRACK/protocol events; the recovery arms only AFTER the link is already up and feeds back
into none of those four. The emit-gate fix was refuted because it addressed only exit-gate logic
(downstream of the `cr_seen` that never sets) and left I2 and I3 unaddressed.

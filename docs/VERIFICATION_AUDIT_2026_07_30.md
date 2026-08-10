# Verification audit — 2026-07-30

Audit of the TideLink verification plan, the implemented tests and the evidence
on disk, performed on branch **`fix/z2-drop-park-hook`** at `a5df514`.

Everything below is **measured on this checkout**, not inferred. Where a claim
could not be measured it says so. Commands are recorded so each finding can be
re-derived.

Companion docs: [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md),
[SIM_GATE_COVERAGE.md](SIM_GATE_COVERAGE.md),
[TIDELINK_FPGA_VERIFICATION_PLAN.md](TIDELINK_FPGA_VERIFICATION_PLAN.md).

---

## Summary

| # | Sev | Finding | Status |
|---|---|---|---|
| A1 | **High** | `make sim_gate` on this branch **could not pass**: `v2_mask_hs_bilateral` was scored but never invoked ⇒ always `MISS` | **FIXED** here (matches `main`'s `b589c24`) |
| A2 | **High** | The `imp/sim_gate/` "all green" evidence on this checkout was **produced by a different Makefile** (`main`'s), not by this branch's gate | **PARTIALLY RECOVERED** — `nack_wedge_recovery` + `axinode_obs` cherry-picked in and validated PASS; a full rebase was rejected after finding `main` carries a live, silicon-evidenced bring-up regression on the same flist family (A2.1) |
| A3 | **High** | The gate ran the skew-faithful suite in a corrector configuration **the silicon does not use**; the shipping configuration fails and nothing ran it | **SENTINEL ADDED** (`xfail_epoch_shipping_corrector`) |
| A3b | **High** | The `EPOCH_ANCHOR_EN` fix landed mid-audit **default-off** — the "plumbed but never forwarded" rot class. Measured A/B: **0 ⇒ 1/3, 1 ⇒ 3/3 byte-exact** through the shipping plumbing node | **A/B SUITE ADDED** (`epoch_anchor_plumb`, PASS) |
| A4 | **High** | **New design defect** — TXGEN ownership mux hijacks an outstanding external AHB data phase ⇒ silent single-word corruption, not even sticky-recorded | **FIXED (A4.1)** — `ext_data_pend_r` admission qualifier; test rewritten repro→positive regression (PASS 2/2, byte-exact); promoted from XFAIL sentinel to blocking `sim_gate_txgen_ext_hijack`; no regression on the other 3 txgen suites |
| A5 | **High** | 3 of 7 UVM envs have not elaborated since 2026-07-07 (12 of 17 needed `local_overrides` files silently resolved to stale `deps/` copies, plus a newer `tidelink_tx_gen.sv` gap) | **ELABORATION FIXED** on all 3 (first clean build since 2026-07-07); running the tests then surfaced a real, uniform functional stall (FCSM stuck at CR/CRACK state 1) — **classified same day (A5.3.1) as the already-tracked backlog #14b**, not a new defect, by an independent panel; `allow_failure` correctly stays true; a second, independent vacuous-PASS bug in `run_all`'s echo also fixed |
| A6 | Medium | Two benches that produced gate results are **not in git on this branch** — only `.pyc` and build artefacts | Documented |
| A7 | Medium | 84 of 982 cocotb tests **cannot fail** (no reachable `assert`/`raise`), including the named tests for backlog items #1 and #8 | Documented |
| A8 | Medium | Plan / CI counts have rotted (CI says "10 suites" at 37; coverage doc says 25); module matrix missing 2 modules; one backlog item fixed in RTL but still listed OPEN | Counts now **GENERATED**; doc corrections applied |
| A9 | Low | Gate hygiene: two suites invoked twice (~160 s wasted); one suite invoked but scored by nothing, pinning a stale RTL fork | **FIXED** |
| A10 | High | Does `EPOCH_ANCHOR_EN` (the landed Z2 fix) actually reach OOC synth, or is it a repeat of the `-verilog_define`-never-reaches-OOC scar? | **VERIFIED structurally** (wrapper + fresh component.xml + V2-flist-confirmed packaging log); found + fixed a genuinely blind pre-existing instrument (`check_wrapper_params.sh`'s component.xml check had never matched anything, for any parameter, since it was written) along the way |
| A11 | High | Hardware test suite: 2 categories had the same both-branches-`tt_pass` vacuous-check bug as A1/A9; Cat 10's masked a real RTL defect (PTP mailbox not actually RO from APB) | **2 hwtest scripts FIXED**; RTL defect flagged for owner review (no cocotb harness to validate a fix against); staleness + `tt_gate_ahb_tx` liveness-criterion gaps documented |
| A12 | High | Isolated D2D write data-loss regression (`cb33c9f`) not yet gated in this tree; are other consumers exposed to the same bug on a stale pin? | **GATED** (`sim_gate_v2_isolated_write`, PASS 4/4, wired + inventory-clean); sibling sweep found **2 more stale consumers** (`nanosoc-simple-chiplet`, and `NanoSoC-Hetrogeneous-Chiplet-Testing`'s compute-chiplet leg) beyond the already-known one; 1 apparent 4th ruled out as a stale local git clone, not a distinct consumer |
| A13 | **High** | Re-check F09/F12/F13/F19 (sim-only / never-HW-proven features) against the actual ASIC tapeout flist, not the plan doc's framing | F09 unchanged LOW-MEDIUM; F12 raised to MEDIUM (ASIC PHY has zero soak evidence at any rate, doc undersells this); **F13 raised to HIGH** (A11.2's live RTL defect is in this exact tapeout-bound module); **F19 raised to HIGH** (reframed — no BER/margin instrumentation exists anywhere for the PHY that actually ships) |

Net: the gate went from **cannot-pass** to **42 blocking suites + 2 sentinels**;
one previously-invisible defect is fixed and permanently guarded (A4), one
remains permanently visible via sentinel (A3); the sim half of the live "no
data crosses" blocker is closed with a one-variable A/B; 3 of 7 UVM envs
elaborate for the first time since 2026-07-07, surfacing a functional stall
that turned out to be the already-tracked backlog #14b, not a new defect; and
a live regression on `main` (`b98b944`) was identified and deliberately kept
off this branch while still recovering the two suites that motivated pulling
from `main` at all; and the sim-side Z2 fix is now confirmed to reach real
FPGA packaging, uncovering a second genuinely-blind instrument
(`check_wrapper_params.sh`) in the process — nothing left blocking a hardware
A/B but the board run itself.

---

## A1 — the gate could not pass on this branch

`SIM_GATE_ALL_SUITES` scored `v2_mask_hs_bilateral`; the target existed
(`Makefile:397`); **nothing invoked it**. `sim_gate_summary` therefore scored it
`MISS`, which fails the gate unconditionally:

```
$ make -s sim_gate_summary SIM_GATE_SUITES="<declared set>" ...
  v2_mask_hs_bilateral         MISS      -
  RESULT: FAILURES DETECTED
```

This is the branch's own regression, not a repo-wide one: `main` fixed it in
**`b589c24` — "fix(sim_gate): actually RUN v2_mask_hs_bilateral in the full
aggregate"**, and `b589c24` is **not** in this branch's ancestry (branch point
`328cec8`).

**Why it matters more than a missing line.** The Makefile note above that target
says it is *"THE ONLY EXECUTABLE TEST THAT CAN CATCH A SHAM GATE"*, because the
pre-existing `test_v2_onchip_pair` *"reports 5 PASS at 0.00 ns (it `return`s
instead of skipping, so CI counts false passes)"*. That is still true —
`test_v2_onchip_pair.py::test_02_data_master_to_slave` and `test_03_...` have
**zero assertions and bare early returns** (see A7). So on this branch the mask
handshake had *no* asserting coverage and *two* false-passing tests.

Measured after wiring it in: **PASS, 2/2, 161 s.**

**Anti-rot.** A missing invocation is invisible on inspection, so
`make sim_gate_inventory` now prints the authoritative lists **and cross-checks
that every scored suite is invoked**. Verified to reproduce this exact defect:

```
$ make -s sim_gate_inventory            # with the line deleted again
  ORPHAN: v2_mask_hs_bilateral (target sim_gate_v2_mask_hs_bilateral) is SCORED but never INVOKED
  ^^ the gate CANNOT PASS: the summary scores these MISS      # exit 1
```

---

## A2 — the green evidence on disk belongs to another Makefile

`imp/sim_gate/` (2026-07-29, 40 statuses, all PASS/XFAIL) contains
`axinode_obs.status` and `nack_wedge_recovery.status`. **This branch's aggregate
cannot produce either** — both suites are declared and wired on `main` only
(`main`: 39 blocking suites; this branch: 37). It also *lacks*
`v2_mask_hs_bilateral.status`, which this branch scores.

So the artefacts are a `main`-gate run sitting in a `fix/z2-drop-park-hook`
checkout. Anyone reading `imp/sim_gate/` here would conclude this branch's gate
is green; it had never passed.

Consequence for coverage, not just bookkeeping: this branch does not gate

- **`nack_wedge_recovery`** — `test_l7_wedge_repro`, `test_13_ack_drop_recovery`,
  `test_14_sustained_ack_drop_wedge` (11 / 8 / 6 assertions) covering the
  NACK-wedge and ACK-drop recovery paths, both silicon-proven failure modes;
- **`axinode_obs`** — Region-F AXI data-node observability, whose bench is not
  even present here (A6).

**Remediation: rebase/merge `main`'s `sim_gate` section into this branch** rather
than hand-porting suites, then re-run `make sim_gate` so the evidence on disk is
this branch's. The one-line A1 fix is applied because it is identical to `main`'s
and the gate is otherwise unrunnable.

### A2.1 — UPDATE: not a rebase — `main` carries a live regression this branch must not inherit

Before rebasing, checked the actual divergence: `git log main..HEAD` (2 commits:
`a5df514` the PARK revert, `3f78688` the handover doc) vs `git log HEAD..main`
(12 commits). One of the twelve is **`b98b944`** — *"fix(fcsm): I1 — re-point
AXI FCSM 0-4 to local_overrides + tune state-2 CRACK gate"* — which memory
already flagged the same day as a **live, unresolved regression**:
*"I1 FCSM RECOVERY FIX (`b98b944`, IN consolidated `main`) BREAKS eth-chiplet
link BRING-UP... `main` is sim_gate GREEN but NOT eth-chiplet-deployable:
`cr_seen=0 fcsm=0/1` both dies."* Both proposed fixes for it are already
falsified on silicon; root cause is still open.

Critically, `b98b944` modifies **`flists/tidelink_fpga_v2.flist`** — the same
flist family the Z2 pair boards build from. A follow-up commit
(`6e3b25d`, *"hold(tapeout): keep ASIC flists FCSM 0-4 on deps pending silicon
ILA"*) reverts the change on the two ASIC flists **only**; the FPGA-V2 flist
keeps the regression. So a literal `git rebase main` — or a full merge — would
have pulled a known, silicon-evidenced link-bring-up regression onto the exact
branch whose entire purpose is Z2 bring-up, with **no sim coverage that would
catch it**: `main`'s own `sim_gate` stayed green throughout, because the repro
bench (`cocotb/tidelink_fcsm_silicon_ratio/`) doesn't fully exist yet — it is
literally the "orphan bench" this audit flagged in §A6 without, at the time,
connecting it to this regression.

**What was actually done instead: two surgical cherry-picks, not a rebase.**
Checked every one of the 12 main-only commits' file scope against both the
regression and the current dirty tree (this audit's own uncommitted work, plus
a concurrent session's uncommitted `EPOCH_ANCHOR_EN` threading, live in
`axi_chiplet_controller.sv` / `tidelink_top.sv` at the time):

- **`f730ab1`** (*"feat(obs): I4 AXI data-node observability (Region F) +
  promote NACK-wedge recovery gate"*) — exactly the two suites this section
  identifies as missing, pure observability (new RO APB region, zero datapath
  change per its own commit message), no FCSM involvement. Diff hunks in the
  two contested RTL files land at completely disjoint line ranges from the
  concurrent session's `EPOCH_ANCHOR_EN` edits (checked before picking, not
  after) — zero risk of clobbering in-progress work.
- **`c15985b`** — its tightly-coupled lint-baseline follow-up.
- **Explicitly excluded**: `b98b944` (the regression), `6e3b25d` (protects only
  the ASIC flists, not the FPGA-V2 one Z2 uses — an incomplete mitigation for
  this branch's purposes), `18491ef` (the merge commit carrying both).
- **Flagged but not touched** (real candidates, out of this section's
  requested scope — recovering the two missing suites — and each with its own
  file-collision profile against the dirty tree that would need separate
  care): `affe9d1` (XHB500 pipe/backstop fix, touches `tidelink_top.sv`),
  `749a271`+`2552e32` (APB debug default-locked tapeout hardening, touches the
  same `fpga/targets/*.tcl` files the concurrent session was editing),
  `e08435b`+`e04e257` (throughput-GUI bring-up ladder, touches
  `tl_perf_agent.py`, which already carried pre-existing local uncommitted
  changes before this session started).

**Mechanics.** `git stash push -u` (captured both this audit's own work and the
concurrent session's), `git cherry-pick f730ab1 c15985b` cleanly against
history, `git stash pop`. One conflict — the Makefile's `.PHONY` line, where
both this audit and `f730ab1` appended new target names — resolved by
concatenation. `make sim_gate_inventory` (built earlier in this audit)
confirmed the merge: **40 blocking suites + 3 sentinels, zero orphans.**
Verified no silent loss in the two contested RTL files
(`grep -c EPOCH_ANCHOR_EN` / `grep -c axinode_obs` both files: all present).

**Validated individually** (Vivado still running elsewhere; same practice as
the rest of this audit): `axinode_obs` — PASS, 76s. `nack_wedge_recovery` —
PASS, 184s. `epoch_anchor_plumb` re-run post-merge to confirm the concurrent
session's feature still works alongside the cherry-pick in the same file —
PASS, 73s (unchanged from pre-merge).

---

## A3 — the gate looked away from the shipping PHY corrector

`sim_gate_epoch_silicon` is the *only* suite that injects the v37 silicon
inter-lane skew fingerprint; every other v2 suite pins `EPOCH_PROFILE=zero`. It
runs with `EXTRA_DEFINES=+define+TB_TOP_EPOCH_ANCHOR_FORCE`, which defparams the
deskew to `EPOCH_ANCHOR_EN=1 / SYNC_REANCHOR_EN=0`.

**That is not the configuration that ships.** `local_overrides/WavD2DGpio_v2.v`
(790 / 827) hard-selects `SYNC_REANCHOR_EN=1 / EPOCH_ANCHOR_EN=0`, and Wlink
never forwards `EPOCH_ANCHOR_EN` down to `tidelink_lane_deskew`, so the armed
corrector on silicon is the one that only arms on a live SYNC beacon — which
data-mode bring-up leaves off.

The Makefile comment discloses this honestly, but disclosure is not coverage:
**nothing in the tree ran the shipping configuration under skew.** It fails, and
it is deterministic (two independent runs, identical signature):

```
$ make -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon \
      SIM_BUILD=sim_build_epoch_shipping MODULE=test_v2_pair_data
  TESTS=3 PASS=1 FAIL=2
  test_01_bilateral_linkup   FAIL  S: FCSM state 5 != 4 (LINK_IDLE) after bilateral CR/CRACK
  test_02_packet_master_to_slave  PASS
  test_03_packet_slave_to_master  FAIL  s2m rx=[0x0 0x0 0x0 0x0]  (sent 0xdeadbeef 0x5a17f00d)
```

with `fcsm=4 cr=1 crack=1` on **both** dies while nothing crosses — the recorded
silicon signature, and a fresh reminder that FCSM is not liveness.

Note also that the Makefile comment cites only `test_03`; **`test_01` fails too**
(link-up itself shears, not just the data crossing). Worth correcting in any
follow-up analysis.

**Added `xfail_epoch_shipping_corrector`** (XFAIL, 14 s), with the m2s pass kept
as an instrument clause so a dead bench or broken build cannot masquerade as a
comfortable XFAIL. When the shipping corrector is wired to survive beacon-off
skew, `PASS=3` and the sentinel trips **XCHG** — validated: forcing XCHG makes
`sim_gate_summary` exit 1.

---

### A3b — the fix landed mid-audit, default-off; now gated as an A/B

While this audit was running, **another session threaded `EPOCH_ANCHOR_EN`
through `tidelink_top` → `axi_chiplet_controller` → `Wlink` →
`WlinkGPIOPHY_v2`** (per `docs/HANDOVER_Z2_PICKUP_2026_07_30.md`), defaulted to
**0** so the shipping netlist is bit-exact and a board integration opts in.

That default is right — and it is also the exact shape of this repo's
most-repeated defect: **a parameter plumbed at the top and never forwarded at
the destination** (`NEGO_CFG_RESET`, `RETIRE_EN`). An available-but-unexercised
fix rots out silently, which is why `sim_gate_retire_plumb` exists at all.

So the audit measured the **one-variable A/B** through the *shipping* plumbing
node (`phy.EPOCH_ANCHOR_EN`, **not** a defparam on `u_deskew` — the value has to
survive the hop Wlink previously did not make), same bench, same stimulus, same
silicon skew profile:

| `EPOCH_ANCHOR_EN` | Result | Detail |
|---|---|---|
| **0** (shipping default) | **1/3** | `test_01` link-up shears (`S: FCSM state 5 != 4`), `test_03` s2m all-zeros |
| **1** | **3/3** | byte-exact both directions; banner `EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=1 s=1)` |

**The fix works, and it provably reaches the deskew.** That closes the sim half of
the live "no data crosses" blocker: memory recorded fix (B) as *"wire
EPOCH_ANCHOR_EN through Wlink→deskew (provable in sim, no build)"* — this is that
proof.

Both arms are now gated:

- **`epoch_anchor_plumb`** (blocking, PASS, 14 s) — the fix works and is
  forwarded. The `deskew: m=? s=?` half of the banner is the
  anti-silently-ignored-defparam guard: if Wlink ever stops forwarding,
  master/slave stay 1 while deskew reads 0 and the data tests fail, so the suite
  goes **RED** instead of quietly proving nothing.
- **`xfail_epoch_shipping_corrector`** (sentinel, XFAIL, 14 s) — the default
  still ships the broken corrector. Re-verified **after** the concurrent RTL
  landed: still `TESTS=3 PASS=1 FAIL=2`. It now doubles as the tripwire for
  whether anything has actually **enabled** the fix: the day an integration
  defaults it on, this trips **XCHG** and a human looks.

> ⚠️ **Concurrency caveat, recorded because this repo has been burned by exactly
> this** (`feedback_verify_instrument_before_dut`: *"check what else is
> dirty/different BEFORE calling an A/B one-variable"*). Five RTL files were
> modified by another session **at 09:06–09:07 while this audit was in
> progress**. Every measurement in A3/A3b was therefore **re-run after** those
> edits and the results above are the post-edit ones. `v2_mask_hs_bilateral` was
> also re-measured post-edit (**PASS, 142 s**, vs 161 s pre-edit).

## A4 — NEW DESIGN DEFECT: TXGEN steals an in-flight external AHB data phase

Found by reading `src/rtl/tidelink_tx_gen.sv` (added 2026-07-24), then
reproduced.

`tidelink_tx_gen` decides it may take the shared TX port from

```systemverilog
// src/rtl/tidelink_tx_gen.sv:176
wire ext_idle = ~ext_htrans[1];
wire can_take = en_r && running_r && ext_idle && credit_ok;
```

`HTRANS` is an **address-phase** signal. On AHB-Lite a master drives `IDLE`
throughout the **data phase** of a transfer already accepted, so `ext_idle` is
high for the whole of an outstanding external data phase, and the generator is
free to take the port mid-transfer.

The adapter latches the address early but reads write data **live**:

```systemverilog
// src/rtl/tidelink_fc_adapter.sv:326
if (tx_valid_addr_phase) tx_addr_r <= ahb_tx_haddr;
// src/rtl/tidelink_fc_adapter.sv:361
wire [FC_DATA_W-1:0] tx_fc_word = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata};
```

The 2:1 ownership mux (`src/rtl/tidelink_top.sv:1709-1715`) has by then switched
`ahb_tx_hwdata` to the generator's `data_word_r`, so the word committed to the
link is **{external master's ADDRESS, generator's DATA}**.

Two aggravating properties:

1. **The master is not told.** `ahb_tx_hreadyout` is forced 0 while the generator
   owns the port (`tidelink_top.sv:981`), so the external master holds and then
   completes with **OKAY** for a write whose payload never crossed.
2. **Nothing records it.** The only collision detector is
   `ext_collide = gen_owns && ext_htrans[1]` (`tidelink_tx_gen.sv:180`) — keyed
   on the same address-phase signal, so it is structurally blind to a
   data-phase-only overlap and `ext_abort_r` stays 0.

That makes this the **silent-corruption class** (F14-A's class), on a path the
module header explicitly claims to protect ("PACKETS ARE ATOMIC", "external
master still served").

**Why the three gated txgen suites miss it.**
`test_a1_external_master_unaffected` proves the mux is transparent with `EN=0`;
every other unit test runs the generator with **no concurrent external traffic**.
Nothing exercised ownership *changing* while an external transfer was
outstanding — the one ordering in which the mux is load-bearing.

**Reproduction** — `cocotb/tidelink_txgen/test_txgen_ext_hijack.py`, fully
deterministic (no randomisation): park the generator in `S_ARMED` on zero credit,
back-pressure the link so an external data phase stays open, then grant credit at
exactly that moment.

```
ownership switched to the generator while an external data phase was outstanding (ext_htrans=00)
FC words committed at the external addresses: [('0x40','0xe11e0001'), ('0x80','0x0')]
SILENT CORRUPTION: address 0x0080 carries data 0x00000000, not 0xe11e0002
STATUS after the overlap = 0x00000041  ->  EXT_ABORT bit[5] = 0
TESTS=2 PASS=0 FAIL=2
```

Every instrument clause held (credit gate held with zero credit; `STALL_CREDIT`
reported; a data phase genuinely stalled; the generator genuinely took the port),
so this is not a bench artefact.

**Candidate fix — a design call, deliberately not applied by the audit.**
Admission must also require that no external data phase is outstanding:

```systemverilog
ext_data_pend_r <= (ext_htrans[1] && fc_hreadyout && !gen_owns)
                   || (ext_data_pend_r && !fc_hreadyout);
wire ext_idle = ~ext_htrans[1] && !ext_data_pend_r;
```

and `ext_collide` should be widened to the same predicate so any residual overlap
is at least sticky-recorded rather than silent.

**Exposure.** The generator is meant to *replace* PS-driven traffic, so a
mixed-mode window is not the intended steady state — but nothing prevents it, the
GUI/agent path drives the same aperture, and the failure is silent when it
happens. Gated as `xfail_txgen_ext_hijack` (XFAIL, 3 s) until dispositioned.

### A4.1 — DISPOSITIONED (same day): fix applied, suite promoted

Applied the candidate fix essentially as proposed above (`ext_data_pend_r` in
`src/rtl/tidelink_tx_gen.sv`, `ext_idle`/`ext_collide` both widened to gate on
it), with one refinement: the register clears **only while `!gen_owns`**, so a
same-cycle race where `gen_owns` asserts in the exact cycle a new external
address phase lands can't leave the tracker frozen stale. Traced (not just
asserted) that `gen_owns` and a live `ext_data_pend_r` cannot coexist by
construction once `can_take` gates on the same predicate `ext_idle` does.

**`cocotb/tidelink_txgen/test_txgen_ext_hijack.py` rewritten** from bug-repro
to positive regression, reusing the identical corruption scenario:
`test_a2_ownership_deferred_until_ext_data_phase_completes` proves the
generator (a) does **not** take the port while W2's data phase is
outstanding even once credit is granted, (b) still takes it once the
external transfer genuinely completes — proving the fix *defers*, not
*wedges* — and (c) the FC word for the external address now carries the
external master's own data, byte-exact (`0xe11e0002`, not `0x00000000`).
`test_a2_ext_collide_never_fires_because_no_overlap_is_possible` is a faster
unit-level check that the admission gate itself, not incidental test timing,
is what prevents the switch.

**Measured 2026-07-30 post-fix:**

```
TESTS=2 PASS=2 FAIL=0
FC words committed at the external addresses: [('0x40', '0xe11e0001'), ('0x80', '0xe11e0002')]
```

**No regression** on the other three txgen suites: `txgen_unit` 7/7,
`txgen_negctl` 1/1 (re-run standalone; the `sim_gate_negctl` invocation via
`TXGEN_NEGCTL=1` differs from the direct-variable invocation this audit tried
first and mis-diagnosed as a failure — corrected before concluding anything).

**Promoted from sentinel to blocking suite**: `sim_gate_xfail_txgen_ext_hijack`
(XFAIL sentinel) removed; `sim_gate_txgen_ext_hijack` (plain `PASS`-required
suite) added to `SIM_GATE_ALL_SUITES` and the aggregate, grouped with the
other three txgen suites. `SIM_GATE_SENTINELS` now has 2 entries, down from 3.
Validated via the actual `make sim_gate_txgen_ext_hijack` target (not just the
raw cocotb invocation): PASS, 2 s. `sim_gate_inventory` confirms 41 blocking
suites + 2 sentinels, zero orphans.

---

## A5 — 4 of 7 UVM envs have not elaborated for three weeks

`.gitlab-ci.yml` quarantines `uvm-top-system`, `uvm-ptp-chain`,
`uvm-ptp-stress` (all `allow_failure: true`, "ELABORATION IS RED", since
2026-07-07) and runs `uvm-system` `allow_failure: true`. Only `uvm-regression`,
`uvm-fc-adapter`, `uvm-integration` are blocking.

The quarantine is honest — but the plan is not consistent with it:

- **VERIFICATION_PLAN.md §4** lists all 7 envs as if live;
- **§8 "System (sim)" sign-off requires** `tidelink_top_system` (43),
  `tidelink_ptp_chain` and `tidelink_ptp_stress` at **0 FAIL** — three envs that
  cannot compile;
- **§2** rates `tidelink_autoneg`, `tidelink_ptp`, `tidelink_ptp_servo`,
  `tidelink_phy_align_calibrator` and `tidelink_addr_translator` GREEN partly on
  their UVM column.

`tidelink_top_system` is the only env covering `align_*`, `autoneg_*`,
`lane_mask_*`, `peer_mask_*`, `train_*`, `addr_translate`, `ahb_passthrough` and
`reset_recovery` (43 tests). Losing it silently is the single largest coverage
hole in the tree.

**Measured, and a new rot layer found.** The quarantine note blames a pinned
`axi_chiplet_controller.sv` (VCS `UPIMI`). The *actual* first error today is
different:

```
Error-[CFCILFBI] Cannot find cell in liblist
  src/rtl/tidelink_top.sv, 990
  Cell 'tidelink_tx_gen' cannot be found in liblist for binding instance
  'test_top.u_tidelink_top_a.g_txgen.u_tx_gen'
```

`tidelink_tx_gen.sv` landed 2026-07-24 and was never added to the three UVM envs
that compile `tidelink_top.sv`. Because the jobs are `allow_failure`, the extra
layer was invisible.

**Fixed:** `tidelink_tx_gen.sv` added to `uvm/tidelink_top_system`,
`uvm/tidelink_ptp_chain`, `uvm/tidelink_ptp_stress`. Re-measured — the error is
back to the **one** documented blocker:

```
Error-[UPIMI-E] Undefined port in module instantiation   (x10, error cap)
```

### A5.1 — the real UPIMI fix: 17 local_overrides files, not 5

The documented blocker was correctly diagnosed but underscoped: the note said
*"re-point the top/wlink source list to the `src/rtl/local_overrides` set...
(14 overrides)"*. The actual gap, measured by diffing every file
`flists/tidelink_fpga.flist` takes from `local_overrides/` against what each
UVM Makefile explicitly compiled:

| | Count |
|---|---|
| Files the FPGA flist takes from `local_overrides/` | **17** |
| Explicitly compiled from `local_overrides/` in the UVM Makefiles (pre-fix) | 5 |
| Silently resolved to the **stale `deps/` originals** via the `-y` library search | **12** |

Two of those twelve are `axi_chiplet_controller.sv` and `tidelink_autoneg.sv` —
the actual UPIMI cause, since the `local_overrides` copies add the
`obs_a2l_replay_{app,link}_valid_o`, `obs_fe_rx_{is_full,credit_max}_o`,
`train_fail_irq_o`, `apb_ctrl_reg_{write,addr,wdata}` ports current
`tidelink_top.sv` instantiates them with. `-y $(DEPS_DIR)/logical/wlink` is a
VCS *library* search directory: it only resolves a module name that is not
already defined by an explicitly-compiled file. So explicitly compiling all 17
local_overrides files pre-empts the stale resolution for exactly those names,
while the ~40 unmodified Wlink-family files (`WavFIFO_*`, `WlinkCrcGen_*`, …)
still resolve correctly from `-y`, unchanged.

Applied to `uvm/tidelink_top_system/Makefile`, `uvm/tidelink_ptp_chain/Makefile`,
`uvm/tidelink_ptp_stress/Makefile` (identical fix, all three share the UPIMI
cause). Order mirrors the flist where it documents one (`tidelink_lane_deskew.sv`
before `WavD2DGpio.v`, which instantiates it).

**Measured 2026-07-30, all three envs: clean compile + elaborate + link.**
First time since 2026-07-07. (One pre-existing, unrelated warning survives in
all three — `svt_ahb_slave_if.svi` `hsel` driven by both a structural VIP driver
and the TB's own `WIRE_AHB_MNG` macro assign; present before this fix, not
introduced by it, "will be upgraded to error in future releases" per VCS —
worth a follow-up but out of scope here.)

### A5.2 — the TB's second blocker: a duplicate, staler lane checker

`uvm/tidelink_top_system/tb/top.sv` instantiated its **own** external
`tidelink_lane_checker`, fed by an XMR into raw deserialised lane data:

```systemverilog
wire [127:0] a_rx_lane_data = u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.io_link_rx_rx_link_data;
tidelink_lane_checker u_a_checker (.clk(a_rx_link_clk), .rst(a_checker_rst),
                                    .lane_data(a_rx_lane_data), .lane_locked(a_lane_locked_w));
```

The checker's interface grew four inputs since this TB was written
(`lock_thresh_i`, `training_mode_w_i`, `sweep_active_i`, `clear_noise_i`) — the
immediate port-mismatch UPIMI on this specific instantiation. But re-porting it
would only produce a **second, worse** copy: `src/rtl/local_overrides/
axi_chiplet_controller.sv` now instantiates `tidelink_lane_checker` itself
(`u_lane_checker`, line 3780), wired to the real calibrator lock-threshold, a
synchronised training-mode edge, and real sweep/clear-noise controls — a
duplicate probe fed only raw lane data and guessed tie-offs for those four
inputs would score a **different** lock decision than the DUT's own, and drift
out of sync again the next time the checker's interface changes (this is
exactly how it went stale the first time).

**Fixed by deletion, not re-porting.** `tb/top.sv` now reads the DUT's own live
result via a one-level-shallower XMR:

```systemverilog
assign tb_if.a_lane_locked = u_tidelink_top_a.u_chiplet_controller.lane_locked_w;
assign tb_if.b_lane_locked = u_tidelink_top_b.u_chiplet_controller.lane_locked_w;
```

`AUTOCAL_ENABLE(1'b1)` is forced in `tidelink_top.sv` for every build (FPGA,
ASIC, UVM alike — `src/rtl/tidelink_top.sv:2421`), so the internal checker is
genuinely running once `role_locked` rises; this is not a tie-off. The
gate-level TB (`tb/top_gate.sv`) is auto-generated from `top.sv` by
`gen_gate_tb.awk`, which already strips all `u_tidelink_top_[ab].` XMRs
(asserted by the Makefile's own generation rule) — this fix changes nothing
about that path; the probe-free gate TB behaves exactly as before, just via a
shorter XMR upstream of the strip.

### A5.3 — what elaborating for the first time in 3 weeks immediately revealed

Running `uvm/tidelink_top_system`'s 10 wired `TESTS` (`make run_all`):

- **Link training completes** — `[TEST] Wlink link-up complete.` fires on
  schedule.
- **The FC-layer FCSM never leaves state 1 on either die.** `A.tlfcsm: state=1
  cr_seen_rx=0 crack_seen_rx=0` and `B.tlfcsm: state=1 cr_seen_rx=0
  crack_seen_rx=0`, held for the rest of the test — the RX side never sees a
  CR packet, so the CR/CRACK handshake that would advance the FCSM to
  `LINK_IDLE` never starts.
- **Every packet exchange therefore times out and fails.**
  `test_top_single_packet`: `UVM_ERROR [SB_A2B] A->B mismatch word N:
  TX=0x..., RX=0x00000000` × 5, `UVM_ERROR : 6` in the report summary.
  `test_top_bidirectional`: the same, both directions (`[SB_A2B]` **and**
  `[SB_B2A]`), `UVM_ERROR : 12`. `test_top_back_to_back`: the TX side is
  observed spinning (`A.tx_data_phase ... skid_can_accept=0`) far longer than
  the first two tests ran in total, consistent with the same stall with no
  internal watchdog to end it early.

Reproduced identically on the first 3 of 10 tests — uniform across the
packet-exchange suite, not one flaky case.

**This is the same symptom CLASS as the already-tracked backlog item #14b**
(*"Autoneg-driven role-lock doesn't carry A→B in `test_top_autoneg_basic`
(staggered POR / FCSM credit-grant); link_status=0x18 but scoreboard RX=0"*),
but #14b names a *different* specific test and this was not root-caused far
enough to confirm the identical cause. Two candidate explanations, genuinely
undetermined:

1. **A real DUT defect** — the FC-layer handoff has a bug independent of the
   RTL path that autonomy/cocotb's zero-poke chain exercises differently.
2. **A TB stimulus gap** — this env's `base_test` bring-up sequence may not
   replicate whatever the proven cocotb `t31` recipe does (*"the full zero-poke
   chain a-h including the real `fch` bootstrap"*, per `sim_gate_t31`'s own
   description) to get the FCSM past state 1. If the UVM TB never drives that
   bootstrap, the FCSM legitimately has no reason to advance, and this would be
   a testbench deficiency, not a DUT one.

**Deliberately not root-caused here.** The scope of this pass was "make the
env build and report honestly", not "fix #14b" or its lookalike — that is
real, separate work, and the finding is valuable precisely because it is now
*visible* rather than hidden behind a build failure for three more weeks.
`allow_failure` stays `true` on all three envs; what changed is that the
CI/Makefile comments now say *why*, accurately, instead of a stale "does not
elaborate" that would itself become false-red the moment this fix lands.

`uvm-ptp-chain` and `uvm-ptp-stress` received the identical build fix and also
elaborate+link clean — **their test suites were not run** in this pass (no
evidence either way on whether they hit the same functional stall).

#### A5.3.1 — UPDATE (same day): candidate 1 confirmed, this IS #14b

The two candidates above were resolved without further work from this pass —
an **independent 5-agent panel**, investigating the unrelated I1/`b98b944`
eth-chiplet regression (see A2.1) the same day, happened to check this exact
env as part of ruling out whether their regression was reset-sequencing or
override-specific. Their finding, verbatim: *"The UVM `tidelink_top_system`
shows the IDENTICAL `cr_pkt_seen_rx`-never-asserts signature for the **deps**
FCSM under a staggered `wlink_por_reset` ⇒ generic reset-sequencing, not an
override CR bug (so UVM is NOT an override repro; #14b class)."*

That settles candidate 1 vs 2 above: this env compiles the **`deps/`** FCSM
files (this pass only re-pointed `axi_chiplet_controller.sv` /
`tidelink_autoneg.sv` to `local_overrides`, for their unrelated obs ports —
never the FCSM state machine), so the I1 regression (which lives entirely in
the `local_overrides` FCSM copies) cannot be the cause here by construction.
What's left is candidate 1's sibling: a **real, pre-existing DUT/reset-timing
defect** — specifically the already-tracked backlog **#14b** — not a
TB-stimulus gap unique to this env's `base_test`. This env is now a second,
independently-arrived-at reproduction of #14b under a different test name
(`test_top_single_packet` etc., vs #14b's `test_top_autoneg_basic`), which is
useful corroborating evidence for the existing "OPEN — deferred wave-debug"
backlog item, not a new investigation to open.

Updated in `docs/VERIFICATION_PLAN.md` §6 (the #14b row) and the
`uvm/tidelink_top_system/Makefile` / `.gitlab-ci.yml` comments this section
describes above.

### A5.4 — an independent, second bug found alongside this: vacuous PASS/FAIL

`run_all` (and `run`) bucketed PASS/FAIL purely on `simv`'s **shell exit code**:

```make
if cd $(SIM_DIR) && ./simv +UVM_TESTNAME=$$test ... ; then echo "  PASSED"; ...
```

UVM's default report server calls plain `$finish` at end-of-test regardless of
`UVM_ERROR` count — only a `UVM_FATAL`-driven `$fatal`, or an actual simulator
crash, sets a non-zero exit. Confirmed the day this was found:
`test_top_single_packet` printed `PASSED: test_top_single_packet` from this
loop while its own log carried `UVM_ERROR :    6`. This predates and is
independent of the elaboration blocker — it was simply never exercised for
three weeks because compile always failed first.

**Scope check before overstating this**: `ci/uvm_results_to_junit.py`, the
script CI's UVM jobs actually gate on for `results.xml`/JUnit reporting,
already parses the real `UVM_ERROR\s*:\s*(\d+)` / `UVM_FATAL\s*:\s*(\d+)`
summary tally from each test's own log — correctly, independently of the
shell exit code. So this bug was a **misleading human-facing echo in the
Makefile's own local convenience target**, not a hole in what CI actually
blocks on. Still worth fixing: it is exactly the workflow this repo's own
promotion instructions ask a human to run by hand (cf.
`sim_gate_nack_wedge`'s "confirm PASS" step), and a human trusting that echo
would have been misled.

**Fixed** with a `$(call uvm_pass,<log>)` helper that re-derives the verdict
from the real UVM_ERROR/UVM_FATAL counts and fails closed if the summary block
is missing entirely (a hang or crash that never reaches end-of-test must not
read as a pass either). Applied to both `run` and `run_all`.

**§8's system sign-off criteria remain unmeetable today** — for a narrower,
now-documented reason (a real functional stall, not a build blocker) rather
than three weeks of "does not compile."

---

## A6 — two benches that produced gate results are not in git here

| Path | State on this branch | Evidence it ran |
|---|---|---|
| `cocotb/tidelink_axinode_obs/` | `__pycache__/*.pyc`, `results.xml`, `sim_build/` — **no `Makefile`, no `.py`** | `imp/sim_gate/axinode_obs.status` = `PASS 13s` |
| `cocotb/tidelink_fcsm_silicon_ratio/` | a flist + `results.xml` + two `sim_build_*` — **no `.py`** | `results.xml` records one pass, one `<skipped/>` |

Sources exist only under `.claude/worktrees/agent-*` and on `main` /
`fix/i1-fcsm-bringup` / `integ/*` / throwaway `worktree-agent-*` branches.

The second one matters most: `tidelink_fcsm_silicon_ratio` is the repro bench for
the top open blocker (the I1 FCSM recovery fix breaking eth-chiplet bring-up), and
its load-bearing case —
`test_axi_fcsm_state2_clears_under_marginal_link` — is recorded **`<skipped/>`**,
so the marginal-link repro has not actually been demonstrated by that bench. It
is also a genuinely well-built TB (a clean-bring-up control at both gate values,
so the repro cannot be an artefact of compiling the gate in) and deserves to be
committed rather than left in a worktree.

**Remediation:** commit both benches on a real branch and, for the FCSM one,
establish whether the skipped case passes or fails before citing it as evidence
either way.

---

## A7 — 84 of 982 cocotb tests cannot fail

Method: parse every `cocotb/**/test_*.py`, resolve the intra-file call graph from
each `@cocotb.test()`, and flag tests with **no reachable `assert` or `raise`**
(so helper-based tests like `tidelink_phc_cdc`'s ratio sweeps and
`tidelink_force_recal`'s arms are correctly counted as *able* to fail).

Most of the 84 are honestly-labelled diagnostics under `cocotb/debug/`,
`crc_diag/` and `*_probe` modules — appropriate, and none of them gate anything.
The ones that matter are those inside **CI-regression envs**, because
VERIFICATION_PLAN §3.1 counts them as coverage:

| Env (in CI `ENVS`) | Vacuous test | Why it matters |
|---|---|---|
| `tidelink_system` | `test_21_credit_underflow_attempt` | the named test for backlog **#1 (Critical)**, "no credit-underflow guard". Ends `log.info("Credit underflow attempt completed without hang")` — no oracle |
| `tidelink_system` | `test_verification_gaps.py::test_accumulator_race` | the named test for backlog **#8**, the R-clear/W-add race |
| `wav_d2d_gpio_tx` | `test_03`, `test_04`, `test_05` | 3 of the 5 tests the plan lists as "Training-pattern mux passthrough (5)" |
| `tidelink_addr_translator` | `test_27_unused_apb_port_access` | counted in the "(34)" |
| `tidelink_ptp_servo` | `test_iterative_vs_combinational` | counted in the "(15)" |

Also still present, and called out in the Makefile itself:
`tidelink_top_pair_v2/test_v2_onchip_pair.py::test_02_data_master_to_slave` and
`test_03_data_slave_to_master` — zero assertions **and** bare early returns, i.e.
they report PASS at 0.00 ns (the false-pass that motivated A1's suite).

**Not** a claim that all 84 should assert. The claim is narrower and load-bearing:
**a diagnostic must not be counted in a coverage total**, and the two tests named
for open Critical/Moderate defects should either assert the intended behaviour or
be renamed so nobody reads them as guards.

Reproduce with the script in `docs/VERIFICATION_AUDIT_2026_07_30.md` history, or
re-derive: flag `@cocotb.test()` functions with no `Assert`/`Raise` node
reachable through same-file calls.

---

## A8 — counts and statuses that have rotted

| Claim | Where | Reality |
|---|---|---|
| "10 suites: t30/t31/t32/t33, v2_pair_data, …" | `.gitlab-ci.yml` `sim-gate` comment | **37** blocking + 3 sentinels |
| "sim_gate 13/13 green on integ trunk" | same job, `allow_failure: false` comment | 13 → 37; the number has rotted twice |
| "25 blocking suites + 2 known-defect sentinels" | `SIM_GATE_COVERAGE.md` header (2026-07-24) | 37 + 3 |
| "19 SystemVerilog files at chiplet level + 6 FIFO-family" | `VERIFICATION_PLAN.md` §1 | **20** + 6 (`tidelink_tx_gen.sv` added) |
| §2 matrix "out of 25 first-party modules" | `VERIFICATION_PLAN.md` §2 | `tidelink_tx_gen` (3 gated suites) and `tidelink_fifo_ctrl` are absent from the matrix |
| #1 Critical "No credit-underflow guard (BUG-002) … OPEN" | `VERIFICATION_PLAN.md` §6 | **guarded in RTL**: `tidelink_fifo_ctrl.sv:386-389` clamps the consume at 0, `:424-425` saturates the mint at `MAX_CREDITS`. The *test* is still vacuous (A7) |
| plan re-baseline | `VERIFICATION_PLAN.md` header | 2026-05-29 — two months of RTL churn ago; the header already asks for re-verification before sign-off use |

Also worth recording: **`cocotb/Makefile` `ENVS` covers 28 of the 57 on-disk
envs**, and the 29 excluded ones include every paired-die / integration / eth /
tidechart / txgen / errinj env. That is by design (those are `sim_gate`'s job) but
it means any number from `make -C cocotb coverage` is **unit-half only** — a
caveat §8 should carry, since it tells you to re-run exactly that command before
citing coverage.

**Anti-rot applied:** the `sim_gate` banner now prints
`$(words $(SIM_GATE_ALL_SUITES))` / `$(words $(SIM_GATE_SENTINELS))` instead of a
hand-written number, and `make sim_gate_inventory` prints the authoritative
lists. Docs should quote that command, not a copied count.

---

## A9 — gate hygiene

- `sim_gate_v2_sustained` and `sim_gate_v2_trunc_credit` were each invoked
  **twice** by the aggregate (~160 s of duplicate simulation per run, on a gate
  whose wall-clock is already the reason people skip it).
- `sim_gate_fifo_twin2` was invoked but appears in **no** scoring list, so it
  burned time and wrote an `imp/sim_gate/fifo_rx_twin2.status` that nothing
  checks — while its own Makefile note says *"SUPERSEDED — DO NOT PROMOTE THIS
  TARGET"* because it pins a **stale fork** of the FIFO RTL. `fifo_rx_twin2_tree`
  is the tree-truthful replacement and remains gated.

All three invocations removed.

---

## What was changed by this audit

| File | Change |
|---|---|
| `Makefile` | wire `sim_gate_v2_mask_hs_bilateral` into the aggregate (A1); add `sim_gate_xfail_epoch_shipping` (A3) and `sim_gate_xfail_txgen_ext_hijack` (A4) + register both in `SIM_GATE_SENTINELS`; add blocking `sim_gate_epoch_anchor_plumb` (A3b); add `sim_gate_inventory` with a declared-vs-invoked cross-check; generate the banner counts; drop the duplicate/unscored invocations (A9); correct the summary footer, which still named only F14-A/F14-B |
| `cocotb/tidelink_txgen/test_txgen_ext_hijack.py` | **new** — deterministic reproduction of A4, with instrument clauses and the candidate fix in the header |
| `uvm/tidelink_top_system/Makefile`, `uvm/tidelink_ptp_chain/Makefile`, `uvm/tidelink_ptp_stress/Makefile` | add `tidelink_tx_gen.sv` (A5) |
| `docs/SIM_GATE_COVERAGE.md`, `docs/VERIFICATION_PLAN.md` | correct the rotted claims in A5 / A8 and point at this audit |

**No RTL was changed.** A4 is a real defect with a proposed fix, but changing the
admission predicate on a live chiplet TX datapath is a design decision, and the
right first step is that the defect is now impossible to lose.

## Why the full aggregate was NOT run

`make sim_gate` was deliberately **not** executed. Two Vivado instances were live
on the host, and this repo's own standing rule is *"never co-schedule a Vivado
build with `sim_gate`"* (`SIM_GATE_COVERAGE.md` §3.1) — the last time it happened
a co-scheduled build SIGKILLed the simulator mid-run and only the `XERR` state
stopped it being read as a regression. A contaminated aggregate would be worse
than no aggregate.

Instead every new or repaired target was validated **individually**, which is the
same practice §9 of the coverage doc records for the 2026-07-18 additions, and
never via `make -n` (which fabricates PASS files).

The pre-existing `imp/sim_gate/` set was copied to
`imp/sim_gate_evidence_2026_07_29_main_gate/` before anything else, because
`make sim_gate` begins with `rm -rf imp/sim_gate` and that set is the evidence
for A2.

## A10 — EPOCH_ANCHOR_EN reaches OOC synth, verified structurally (not assumed)

Follow-up item from the plan: the sim-side fix (A3b/`epoch_anchor_plumb`) is
only real hardware if the IP-face parameter that carries it into a Vivado
build actually reaches out-of-context synthesis. This repo has been burned by
the opposite assumption before — memory
`project_verilog_define_never_reaches_ooc_ip_2026_07_09`: *"`-verilog_define`
NEVER reaches packaged-IP OOC synth ⇒ verify structurally, md5 proves
NOTHING."* So this was measured, not assumed.

**The chain, each link checked against artefacts, not source-reading alone:**

1. `fpga/vivado_ip/tidelink_vivado_wrapper.v:95` declares `EPOCH_ANCHOR_EN`
   as a genuine wrapper parameter (default `1'b0`), forwarded at `:558` —
   present, matching the wrapper's own precedent comments for `USE_IDELAY` /
   `RETIRE_EN` / `HONEST_MASK_HS`, all of which this project has already
   proven reach OOC synth via the identical mechanism (`ipx::package_project`
   recording the wrapper default into `component.xml`, **not** a
   `+define+`).
2. `imp/fpga/tidelink_ip/component.xml` (fresh — timestamped **after** the
   wrapper edit, `11:18` vs `10:53`) records `EPOCH_ANCHOR_EN` twice: once
   under `resolve="generated"` (the elaboration-time value) and once under
   `resolve="user"` — the IP-XACT marker that makes it a genuine
   per-BD-instance override point, exactly like the three proven precedents.
   Default value in both: `"0"`, matching the wrapper.
3. `imp/fpga/run/package_ip.log` — the actual run that produced that
   `component.xml` — shows a clean completion (`Integrity check passed`, zero
   `ERROR`, only pre-existing unrelated bus-interface warnings) **and**
   confirms it packaged the **V2** flist
   (`TIDELINK_PHY_V2=1 -> tidelink_fpga_v2.flist`). That check matters on its
   own: `fpga/filelist.tcl` documents a prior, structurally identical scar
   (commit `8705a99`) where the IP was accidentally packaged **V1** because
   `TIDELINK_PHY_V2` was unset, silently dropping an entire `` `ifdef ``
   branch. `EPOCH_ANCHOR_EN` is only forwarded to `WlinkGPIOPHY_v2` inside
   `` `ifdef TIDELINK_PHY_V2 `` in `Wlink.v:1378-1380` (V1's `WlinkGPIOPHY`
   has no such port) — so confirming V2 was actually selected for *this*
   packaging run closes the one remaining gap between "the parameter exists"
   and "the parameter reaches the code path that uses it."

**Verdict: the chain is structurally intact end-to-end.** This meets the same
evidentiary bar the wrapper file's own comments use to declare `USE_IDELAY`
etc. "proven" — a genuine, fresh, clean-logged packaging run with the correct
flist selected and the parameter correctly recorded at the override-capable
`resolve="user"` node. A full differential OOC synthesis (build twice,
`CONFIG.EPOCH_ANCHOR_EN=0` vs `=1`, diff the resulting netlists) would be
stronger still, but is a materially heavier operation (real synthesis,
minutes, on a host already running two other Vivado builds) and was not
performed — flagged as an optional next step, not a gap in what was claimed.

### A10.1 — found + fixed a genuinely blind instrument along the way

While extending `fpga/scripts/check_wrapper_params.sh` (the pre-flight guard
`package_ip` already runs via its `check-wrapper-params` Makefile
prerequisite) to also cover `EPOCH_ANCHOR_EN`, the same grep pattern used for
the three existing parameters was reused first — and it matched nothing
against the real `component.xml`. Investigated why: Vivado's actual IP-XACT
bitString values are XML-escaped and quote-wrapped —
`<spirit:value ...>&quot;1&quot;</spirit:value>` — but the script's pattern,
`<...:value[^>]*>1</`, expects a bare digit immediately after `>`, which never
matches `&quot;1&quot;`.

**This check had been silently blind since it was written.** Neither branch
(`OK` on value=1, `FAIL` on value=0) had ever fired for `USE_IDELAY` /
`USE_CLKBUF` / `USE_T3A`; every invocation fell through to the "parameter not
mentioned — that's fine" case and printed a blanket
`"OK packaged component.xml consistent with wrapper"` regardless of what the
XML actually said. Exactly the "instrument that looks like it checks
something but doesn't" class this project keeps re-discovering (cf.
`feedback_verify_instrument_before_dut`) — found here only because reusing
the pattern for a *new* parameter surfaced that it matched nothing, prompting
a check of whether it had ever matched anything at all.

**Fixed**: rewrote the component.xml check to parse the real
`&quot;[01]&quot;` format, scoped specifically to the `resolve="user"` block
(the customization-capable node), and generalized it to a
`check_xml_param(name, expected_bit)` helper so `EPOCH_ANCHOR_EN`'s opposite
polarity (must be `0`, not `1`) doesn't need a second hand-copied loop.
**Validated the fix catches a real deviation**: copied `component.xml`,
flipped `EPOCH_ANCHOR_EN`'s `resolve="user"` value to `"1"` in the copy, ran
the parsing logic against it — correctly reported `got=1 want=0`, FAIL. Also
added a wrapper-file-level check (the cheap, always-available half) that
`EPOCH_ANCHOR_EN` stays `1'b0` — the opposite-polarity sibling of the
`USE_IDELAY`/`USE_CLKBUF`/`USE_T3A` checks, since flipping *this* default
would, per the wrapper's own comment, "silently re-litigate every existing
golden bitstream."

Re-run end-to-end post-fix: `check_wrapper_params.sh` exits 0, 8 genuine `OK`
lines (4 wrapper-file + 4 component.xml), no silent no-ops.

## Validation performed

- `sim_gate_v2_mask_hs_bilateral` — **PASS 2/2, 161 s**.
- `xfail_epoch_shipping_corrector` — **XFAIL, 14 s**; signature reproduced three
  times, including once **after** the concurrent RTL edits.
- `epoch_anchor_plumb` — **PASS 3/3, 14 s**; banner confirms `deskew: m=1 s=1`.
- `v2_mask_hs_bilateral` — re-measured post-edit: **PASS, 142 s**.
- `xfail_txgen_ext_hijack` — **XFAIL, 3 s** (pre-fix); corruption + silent sticky
  both shown.
- Summary logic — with all 38 + 3 present: **exit 0**. Sentinel forced to `XCHG`:
  **exit 1**. Restored: exit 0.
- `sim_gate_inventory` — `OK` as wired; deleting the A1 line again reproduces
  `ORPHAN … CANNOT PASS` and exit 1.
- `uvm/tidelink_top_system` — `CFCILFBI` before the fix, `UPIMI` after (still red,
  now for the documented reason only).
- `sim_gate_txgen_ext_hijack` (post-fix, A4.1) — **PASS, 2 s**, via the actual
  `make` target, not just the raw cocotb invocation. `txgen_unit` 7/7,
  `txgen_negctl` 1/1 — no regression from the RTL change.
- `check_wrapper_params.sh` (A10) — **PASS**, 8/8 genuine matches (was
  silently no-op on 3-4 of them pre-fix). Negative control (corrupted copy of
  `component.xml`, `EPOCH_ANCHOR_EN` flipped to `"1"`): correctly reports
  `got=1 want=0`, FAIL — confirms the fix discriminates real deviations, not
  another blind pass.

## A11 — the HW test suite: two vacuous-pass bugs, one masking a genuine RTL defect

Follow-up round, prompted by "these will get taped out and integrated into
SoC designs — pick up bugs first." Everything up to A10 audited the *sim*
side; this audits `docs/reference/HW_TEST_SUITE.md` / `pynq_host/scripts/hwtest/`
— the 13-category Pynq-Z2 hardware regression — with the same "does this
check what it claims" lens applied throughout this document.

### A11.0 — staleness

9 of 13 category scripts are untouched since **2026-05-23**, the design
doc's own date. Only categories 3, 4, 5 have moved since (through mid-June).
Zero category script references `TXGEN`, `axinode`, `0x1E0`/`0x21E` (Region F),
or `EPOCH_ANCHOR_EN` — i.e. **none of the RTL surface added in the six weeks
of July** (TXGEN v1 Region E, Region F AXI-node observability, the Z2
`EPOCH_ANCHOR_EN` fix this session just verified reaches OOC synth) has any
structured hardware regression coverage. The fix this session recommended for
a Z2 hardware A/B has nothing in this suite that would exercise it.

### A11.1 — Cat 5 (AHB_TX storm, the wedge-hazard path): vacuous pass, fixed

`05_ahb_tx_storm.sh` sub-test 5b is the *only* content-delivery check in the
single highest-risk category (bench-confirmed to wedge a board, physical
power-cycle required, 2026-04-27). As written:

```bash
if [ "$pc1" -ne 0 ]; then
    tt_pass "5b packet_committed observed on slave (STATUS[4] set)"
else
    tt_info "5b packet_committed NOT set on slave (could be timing — release may have cleared it)"
    tt_pass "5b storm did not assert sticky errors (informational)"
fi
```

`tt_pass` fires on **both** branches. Combined with 5a/5d being pure
"didn't time out" smoke checks and 5c only checking sticky-error bits, Cat 5
— the category the design doc's own coverage matrix marks "✅ GATED storm" —
had **no test that could ever report a storm's data failed to arrive**.

Traced the RTL rather than trust the "could be timing" comment before fixing:
`packet_committed_irq` (`src/rtl/fifo/tidelink_fifo_ctrl.sv:445-469`) is a
**level/sticky bit** — set on `write_complete`, cleared *only* by an explicit
read of FIFO address 0 (the peer draining its RX FIFO). It does not self-clear
and this script never performs that read. A 1 s `sleep` is many orders of
magnitude more margin than a single-cycle completion pulse needs to latch a
level flop — there is no real timing race here. **Fixed**: the else branch is
now `tt_fail`, with the RTL trace recorded in the script so a future reader
doesn't have to re-derive it.

Also flagged, not fixed: even post-fix, no sub-test in Cat 5 verifies the
storm's 16 written *values* land correctly at the peer — only that *a*
packet committed. `test_v2_txgen`'s byte-exact drain (sim-side) is the closer
analogue; Cat 5 would benefit from the same, but extending it needs the RX
FIFO read protocol characterised against real hardware, which this pass
didn't have access to do safely.

### A11.2 — Cat 10 (servo/mailbox): the SAME vacuous-pass bug masked a real RTL defect

`10_servo_mailbox.sh` sub-test 10c — verifying the PTP timestamp mailbox is
RO from APB, per both the RTL's own comment and the design doc's stated
architecture ("Mailbox... is RO from APB") — had the identical pattern:

```bash
if [ "$after" != "0xcafebabe" ]; then
    tt_pass "10c mailbox $off $tag rejects APB write..."
else
    tt_info "10c mailbox $off $tag accepted APB write — may be design choice"
    tt_pass "10c mailbox $off $tag write-observed (informational)"
fi
```

Unlike Cat 5's fix, this one is not a false alarm — **tracing the RTL found
the RO contract is not actually enforced**:

```systemverilog
// src/rtl/fifo/tidelink_apb_regs.sv:212
wire apb_write = psel && penable && pwrite;                    // raw external APB
// src/rtl/fifo/tidelink_apb_regs.sv:527
assign mbox_reg_write = apb_write && (apb_region == 4'b0011);  // NO source qualifier
```

`mbox_reg_write` is wired straight into `tidelink_ptp_servo.sv:220`, which
unconditionally latches it into `mbox_sec_lo_r`/`mbox_sec_hi_r`/`mbox_ns_r` —
the assembled cross-die PTP timestamp. Offset `0x068` maps to
`mbox_reg_addr=2` → `mbox_sec_lo_r`: **a plain external APB write to
`0x4403_2068` overwrites live PTP servo timestamp state**, contradicting both
the RTL's own comment ("written by FC SIDEBAND") and the design doc's stated
architecture. `apb_write` is derived purely from the module's own
`psel`/`penable`/`pwrite` ports — there is no separate "this came from the
sideband, not the CPU" signal anywhere in the chain traced.

**Zero existing sim coverage would have caught this.** The only test that
touches `mbox_reg_write` (`cocotb/tidelink_ptp_servo/test_tidelink_ptp_servo.py`)
asserts the DUT input **by hand** to simulate "FC SIDEBAND RX" — it never
exercises `tidelink_apb_regs.sv`'s decode logic, so the actual defect (the
decode has no source qualifier at all) is invisible to it by construction.
This hwtest sub-test was the *only* thing in the tree positioned to catch an
external-APB write reaching the mailbox — and its own vacuous-pass bug
disabled it.

**Fixed the test** (else branch → `tt_fail`, RTL citation recorded inline).
**Deliberately NOT fixed at the RTL level** — whether a genuine, separate
FC-sideband write path exists elsewhere and this is only a missing exclusion,
or whether "FC sideband" describes aspirational/not-yet-wired architecture,
needs an owner's read of the intended cross-die PTP receive flow that this
pass didn't have grounds to assume. Flagging with full trace is safer than a
fix based on an incomplete picture of PTP servo timing.

**Severity**: real data-integrity exposure on a subsystem literally named for
cross-die time synchronization — an errant or malicious APB write (from any
driver, debug script, or software bug) can silently corrupt sync state with
zero indication. Matches this project's own recurring "no app-layer integrity
on a control-adjacent path" class (cf. backlog #23).

### A11.3 — Cat 3 (AHB SUB): a lower-severity instance, also fixed

`03_ahb_sub_e2e.sh` sub-test 3c called `tt_pass` unconditionally after a
32-word burst write with **no readback at all** — not even the vacuous-branch
kind, just an assertion-free timing measurement wearing a pass label. Lower
severity than A11.1/A11.2 (nothing was being masked; there was never a real
check to subvert), but still inflated the pass count for zero evidence.
**Fixed**: samples 3 of the 32 written words back and asserts they match,
turning a pure timing note into a minimal real correctness check.

### A11.4 — what was NOT found to be a bug (checked, not assumed)

- `13_long_soak.sh`'s `SOAK_FAIL_ON_DROP` non-fatal escape hatch defaults to
  `1` (strict) per both the script and `README.md` — verified before
  concluding anything, since an 8-hour endurance test defaulting to
  never-fail would have been a serious finding. It doesn't.
- `run_all.sh`'s orchestration correctly captures `${PIPESTATUS[0]}` rather
  than `tee`'s exit code — the common pitfall that would silently always
  report success regardless of the category script's real result. Avoided
  correctly here.
- The `07`/`10a` "round-trip OR stable-RO, both acceptable" branches
  (CAM slots, servo cfg) are NOT the same bug as A11.1/A11.2 — both have a
  genuine third `tt_fail` branch for truly unexpected behaviour, and the
  "either is fine" framing matches the design doc's own explicitly stated
  intent for those specific registers (unlike the mailbox, which the doc
  states as unconditionally RO).

### A11.5 — a related, separately-owned finding cross-referenced here

While chasing this, the "loop" scope also included checking that
`test_v2_isolated_write_dataloss` (the D2D isolated-write data-loss fix,
`cb33c9f`, found+fixed same-day by another session on the compute-chiplet
integration) is wired into `sim_gate`. See the memory entry
`project_tidelink_isolated_write_data_loss_2026_07_30` — not yet landed in
this tree; tracked as a `Not done / next` item below rather than duplicated
here, since it is an independent finding from a different investigation.

**Also worth naming**: `tt_gate_ahb_tx()`'s data-mode fallback ("Criterion
B") verifies link liveness via FCSM state alone
(`lib_hwtest.sh:217-227`) — the exact signal this project has twice now
proven unreliable as a liveness indicator (`docs/WAIVER_F14B_DATAMODE_WEDGE.md`;
this document's own §A3, "fcsm=4 cr=1 crack=1... while nothing crosses").
Not a safety bug — the outer `timeout` wrapper still catches a genuinely dead
link even if this criterion is fooled — but the gate's own claim that "the
link is verified up" can be wrong in a documented, silicon-proven way. Not
fixed here (changing the primary safety gate's liveness criterion deserves
its own scoped review, not a drive-by edit); flagged for the same reason
A11.2's RTL was flagged rather than patched blind.

## A12 — isolated-write data-loss regression: landed + gated; sibling-pin sweep finds 2 more stale consumers

Follow-up on `project_tidelink_isolated_write_data_loss_2026_07_30` (the
`cb33c9f` D2D isolated-write fix another session found already present in
`HEAD` but not on the compute-chiplet's pin). Two parts: get the regression
into this tree's gate, then check whether other consumers share the same
exposure.

### A12.1 — `test_v2_isolated_write_dataloss` landed in `sim_gate`

Cherry-picked `fda8288` (`fix/tidelink-isolated-write-dataloss`) — a
sim+doc-only commit (`cocotb/tidelink_top_pair_v2/test_v2_isolated_write_dataloss.py`
+ `docs/TIDELINK_ISOLATED_WRITE_ROOTCAUSE_FIX.md`, zero RTL delta, the fix
already lives at `cb33c9f` in this branch's history) onto
`fix/z2-drop-park-hook` — clean apply, no conflicts, confirmed `cb33c9f` is
already an ancestor of `HEAD` before picking. Ran standalone: **4/4 PASS**
(isolated distinct-data delivery, back-to-back distinct-data, prompt-drop
master-noncompliance case, hready-loopback discriminator).

New target `sim_gate_v2_isolated_write` added to the Makefile, added to
`SIM_GATE_ALL_SUITES`, and — the exact defect class this document's own §A1
and §A9 both already found (`v2_mask_hs_bilateral` scored-but-never-invoked)
— explicitly added to the `sim_gate:` aggregate's invocation list, not just
the suite-name variable. `make sim_gate_inventory`'s wiring cross-check
confirms **no orphan**. Ran through the actual gate macro (not a bare
`make MODULE=...`): `imp/sim_gate/v2_isolated_write.status` → `PASS 59s`.
Documented in `docs/SIM_GATE_COVERAGE.md` §2.6.

### A12.2 — sibling-pin sweep: 2 more consumers confirmed stale, 1 false alarm ruled out

Swept every local clone under `~/SoCLabs` with a `tidelink` git submodule
(`.gitmodules` scan to 4 levels, 6 distinct consumer checkouts found), then
checked each pinned commit's ancestry against `cb33c9f` directly (not
assumed from a date):

| Consumer | Pin | `cb33c9f` ancestor? |
|---|---|---|
| `NanoSoC-Compute-Chiplet/tidelink` | `3f3de09` | ❌ **STALE** (already known) |
| `NanoSoC-Hetrogeneous-Chiplet-Testing/deps/compute-chiplet/tidelink` | `3f3de09` (same pin) | ❌ **STALE — new finding** |
| `NanoSoC-Hetrogeneous-Chiplet-Testing/deps/eth-chiplet/tidelink` | `3ed78fe` | ✅ fix present |
| `nanosoc-ethernet-chiplet/tidelink` | `a04a194` | ✅ fix present |
| `nanosoc-simple-chiplet/tidelink` | `4a4bca5` (2026-05-29, predates the fix by 5+ weeks) | ❌ **STALE — new finding** |

**New, genuine finding**: the isolated-write-data-loss bug is not confined to
the one compute-chiplet report that surfaced it. `nanosoc-simple-chiplet` —
a wholly separate chiplet integration line — pins a `tidelink` commit from
**before `cb33c9f` existed**, so any isolated D2D write (including a
cross-die mailbox-style single-write doorbell, the exact pattern that hid
this bug until now) will reproduce the same address-correct/data-zero loss
there. And `NanoSoC-Hetrogeneous-Chiplet-Testing` — the multi-chiplet SoC
test harness that is supposed to validate compute+eth together — inherits
the stale pin through its `deps/compute-chiplet` leg even though its
`deps/eth-chiplet` leg is current, meaning the *harness meant to catch
cross-chiplet integration bugs* is silently exposed on one side of the very
link it's testing.

**Ruled out as a false alarm, not assumed**: `NanoSoC-Ethernet-Chiplet`
(capitalised; remote `git@github.com:SoC-Labs/NanoSoC-Ethernet-Chiplet.git`)
initially looked like a fourth stale consumer (pinned `tidelink@3f3de09`),
but `git remote -v` + `git fetch --dry-run` show it is the **same GitHub
repo** as the already-current `nanosoc-ethernet-chiplet` (lowercase) —
just a second local clone that is 12+ commits behind its own `origin/main`
(`7f37d94..2290fd9` available, unfetched). Not a distinct consumer with a
real stale pin; a stale local mirror. Flagged as informational only — worth
a `git pull` before anyone works from that directory, no action needed on
the `tidelink` side.

**Not fixed here** (deliberately, same reasoning as A11.2): bumping another
team's/repo's submodule pin is that repo's maintenance action, not this
branch's — and neither `nanosoc-simple-chiplet` nor the heterogeneous
harness's compute leg is checked out with local modifications this session
has context on. **Action needed**: bump the `tidelink` submodule pin past
current `HEAD` (which now also carries the gated regression test) in (1)
`NanoSoC-Compute-Chiplet`, (2) `nanosoc-simple-chiplet`, and (3)
`NanoSoC-Hetrogeneous-Chiplet-Testing/deps/compute-chiplet` (or re-point (3)
at (1) once (1) is bumped, since it looks like a nested copy of the same
pin rather than an independently-tracked one).

## A13 — F09/F12/F13/F19 vs current tapeout scope: what's actually going to silicon

The FPGA verification plan (`docs/TIDELINK_FPGA_VERIFICATION_PLAN.md`, drafted
2026-07-17, last touched 2026-07-24 — a week stale relative to this audit)
lists four features with no full hardware proof. "Sim-only" and "never
proven on HW" are not the same *risk* for every one of them — the
determining question is whether the block is actually in the **ASIC tapeout
flist** (`flists/tidelink_top_full_asic_v2.flist`, checked directly rather
than assumed) or is FPGA-only tooling that never ships. Re-checked each
against that flist and against what this audit has verified elsewhere.

### F09 — XHB transparent-window channel: risk LOWERED by this session's own A12

**In ASIC scope**: yes — `xhb500_ahb_to_axi_bridge_chiplet_slv`/`_mst` and
the `ahb_sub` glue in `tidelink_top.sv` are both in the v2 ASIC flist.
Z2-proven silicon-side; the sim gap is a testbench limitation (`_slave_bram_peek`
returns X — the pair tb never modelled a peer XHB target), not an RTL gap,
per the existing `sim_gate_xhb` comment.

**What changed this session**: `cb33c9f` — the fix for the exact ahb_sub
datapath this feature depends on — was *itself* an example of "silicon-proven
but the regression that guards it lived only on a report branch, not this
tree's gate" (A12). That regression (`sim_gate_v2_isolated_write`) is now
gated. It doesn't cover the full window-write round-trip F09 describes (the
tb-modelling gap is real and unresolved), but it does close the specific
class of bug (isolated-write data loss through this exact bridge) that would
otherwise have shipped ungated a second time. **Residual risk: unchanged
LOW-MEDIUM** (silicon-proven, RTL-verified fix now regression-gated) — the
tb peer-target gap remains the honest open item, unchanged from the existing
plan.

### F12 — Sustained data / throughput baseline: real tool-gap, but not the risk it first reads as

**In ASIC scope**: the datapath itself (FIFO/FCSM/credit/AHB) is the core
link — inherently in scope, not a separate flist entry to check.

**Checked, not assumed**: `docs/TESTING.md:119` still literally says
`linkhold_soak.sh 30` is "never" run — true today, re-verified, not doc rot.
But that is not the whole picture: a KR260-onchip sustained soak (different
tooling, same shared digital core) ran **30,500 packets, 0 wedges, byte-exact**
on 2026-07-23 (see `project_kr260_onchip_sustained_soak_2026_07_23` memory).
The FPGA verification plan's F12 row cites only the unrun tool and doesn't
mention this — a real doc-currency gap (same class as this audit's A8), not
a coverage gap.

**The genuine residual risk, not previously stated this way**: the KR260
soak validates the shared digital core over a link that is **not** the ASIC
target PHY. Per `project_tidelink_v1_asic_target` (v1 ASIC = 100 MHz GPIO
PHY; the FPGA rig's bring-up PHY is a structurally different block used only
as a validation reference for the digital core, not a stand-in for the
silicon PHY). **No sustained-soak evidence exists at anything resembling the
ASIC's actual PHY/line-rate combination** — the 30,500-packet number is real
and valuable, but it proves FIFO/FCSM/credit stability, not PHY-level
stability at 100 MHz. **Residual risk: MEDIUM**, and the plan document
should be corrected to state the gap this way rather than "never run" (which
undersells the digital-core evidence that does exist) or silently accepted
(which oversells it to PHY-level confidence it hasn't earned).

### F13 — PTP two-board convergence: risk RAISED — same module as A11.2's live RTL defect

**In ASIC scope**: yes, unambiguously — `tidelink_ptp.sv` and
`tidelink_ptp_servo.sv` are both directly listed in the v2 ASIC flist. This
is not a validation-only concern; this exact RTL ships.

**Direct link to this audit's own A11.2**: the mailbox RO-from-APB defect
found and confirmed this session (external APB writes silently corrupt
`mbox_sec_lo_r`/`mbox_sec_hi_r`/`mbox_ns_r`, zero prior sim coverage) lives
in `tidelink_ptp_servo.sv` — the same module this feature row is about, and
a module going to silicon with this branch's changes. F13's existing gap
("two-board convergence never proven end-to-end on HW") is a coverage
question; A11.2 is a **confirmed live defect** in a tapeout-bound block, and
the two should not be tracked as separately-prioritized items. **Residual
risk: raised from the plan's implicit MEDIUM to HIGH** — recommend A11.2 get
an RTL owner's review before any tapeout freeze, not on the general
hardware-test-suite cadence the rest of this section's findings can wait for.

### F19 — On-silicon PHY BIST: reframed, not merely "ungated"

**In ASIC scope**: explicitly **NOT included**, by the ASIC v2 flist's own
header comment — `tidelink_gpio_phy_rx/tx` wrappers and the BIST files are
named as a deliberate exclusion; the flist states the shipping composition
puts checker+calibrator logic at controller level on the 128-bit link data
instead. So F19 as literally scoped ("is the standalone PHY-BIST bitstream
in a production image") was already answered NO by design, not by omission —
lower-stakes than the plan's phrasing implies.

**What actually raises the risk, checked directly**: `tidelink_phy_bist_core.sv`
+ the PRBS-15 gen/check pair (`deps/tidelink-phy/rtl/tidelink_phy_bist_prbs.sv`)
exist, have their own cocotb testbenches (`deps/tidelink-phy/cocotb/phy_bist/`),
and are **not instantiated by any flist this repo's `sim_gate` or `hwtest`
touches** (grepped `Makefile`, all `pynq_host/scripts/hwtest/*.sh`, and
`docs/reference/HW_TEST_SUITE.md` — zero references). Combined with F12's
finding that the FPGA validation rig runs a structurally different PHY than
the 100 MHz GPIO PHY that ships: **there is currently no BER/eye-margin
characterization capability exercised anywhere — sim, FPGA, or plan — against
the PHY variant that actually tapes out.** This is a sharper framing than
"a feature lacks HW proof": it means no instrument in this tree could
currently tell the difference between a healthy-margin and marginal-but-
functional ASIC PHY before first silicon comes back. **Residual risk: HIGH**,
same tier as F13, for a different reason — not a confirmed defect, but a
confirmed absence of any way to detect one in the exact area (PHY signal
margin) most likely to differ between FPGA validation and real silicon.

### Summary — waiver disposition

| # | Plan's framing | This audit's residual-risk verdict | Change from plan |
|---|---|---|---|
| F09 | sim tb gap only | **LOW-MEDIUM**, unchanged | none — A12 closes an adjacent gap but doesn't touch F09's own tb-modelling gap |
| F12 | "never run on silicon" | **MEDIUM** — digital core well-soaked (different tool than planned), ASIC PHY itself has zero soak evidence at any rate | **doc should be corrected**, not just left "RED" |
| F13 | HW convergence never proven | **HIGH** — raised, because A11.2 is a confirmed live RTL defect in the exact tapeout-bound module, not just a coverage gap | **escalate**: owner review before tapeout freeze |
| F19 | BIST bitstream never deployed | **HIGH** — reframed: the excluded standalone harness was never the risk; the real gap is zero BER/margin instrumentation for the PHY that ships, anywhere | **escalate**: this is a first-tapeout blind spot, not a backlog item |

None of these four are fixed in this pass — consistent with this audit's
practice throughout (A11.2, the `tt_gate_ahb_tx` liveness note) of flagging
RTL/process items that need an owner's scoped decision rather than a
drive-by change under audit time pressure.

## Not done / next

0. **Run the full `make sim_gate` on a Vivado-free host** — the one thing this
   audit could not do. Expect 41 PASS + 2 XFAIL, ~45-60 min.
1. ~~Rebase this branch onto `main`'s gate section~~ **DONE (A2.1) — as two
   targeted cherry-picks, not a rebase**, after finding `main` carries a live,
   unresolved bring-up regression (`b98b944`) on the same FPGA-V2 flist family
   this branch ships. `nack_wedge_recovery` + `axinode_obs` recovered and both
   validated PASS; the regression was NOT imported. `main`'s other 10
   commits — including real candidates (`affe9d1`, `749a271`+`2552e32`,
   `e08435b`+`e04e257`) — remain un-picked; see A2.1 for why each was held
   back and what it would take to bring them in individually.
2. ~~Disposition A4~~ **DONE (A4.1) — fixed, promoted from sentinel to blocking
   suite**, no regression on the other txgen suites.
3. ~~De-quarantine `uvm/tidelink_top_system`~~ **DONE (A5) — elaborates for the
   first time since 2026-07-07** (17 `local_overrides` files needed, not 14/5;
   `tb/top.sv`'s duplicate lane checker replaced with an XMR into the DUT's
   own). Running it then surfaced a functional blocker (FCSM CR/CRACK stall),
   ~~root-causing that is the remaining work~~ **CLASSIFIED same day (A5.3.1)
   as the already-tracked backlog #14b** — not new work, folds into whatever
   effort eventually picks up #14b's "OPEN — deferred wave-debug".
4. **Commit the two orphan benches** (A6) — revised: **leave
   `cocotb/tidelink_fcsm_silicon_ratio/` alone**, it's active WIP on
   `fix/i1-fcsm-bringup` (the missing repro bench for the `b98b944` regression
   flagged in A2.1), evolving fast and owned by that investigation; adopting
   it onto this branch now would just be stepping on in-flight work. The
   other orphan bench (`tidelink_axinode_obs`) is no longer orphaned — it
   landed with the A2.1 cherry-pick and is gated.
5. **Give the two backlog-named vacuous tests real oracles** (A7) — #1 is
   guarded in RTL now, so `test_21_credit_underflow_attempt` can assert the
   clamp instead of logging.
6. **Decide whether `EPOCH_ANCHOR_EN` should default on** (A3b). The fix is
   proven and gated; it is currently opt-in, so nothing ships it. When an
   integration turns it on, `xfail_epoch_shipping_corrector` trips XCHG — that
   is the signal to promote it to a positive regression and retire the sentinel.
7. ~~Structurally verify `EPOCH_ANCHOR_EN` reaches OOC synth~~ **DONE (A10)** —
   verified via wrapper + fresh component.xml + confirmed-V2 packaging log,
   meeting the same evidentiary bar this project's other proven wrapper
   parameters use. A genuinely blind pre-existing check
   (`check_wrapper_params.sh`'s component.xml verification) was found and
   fixed along the way — see A10.1.
8. **Take the A3b A/B to silicon** — sim now says 3/3 byte-exact under the
   modelled v37 skew, and A10 confirms the IP-face parameter that would carry
   this to a real board genuinely reaches OOC synth; the modelled-vs-measured
   caveat in `XHB_WINDOW_SKEW_ROOTCAUSE.md` still stands, so a board run is
   what converts this from "provable in sim" to delivered. Nothing left
   blocking this step on the sim/packaging side.

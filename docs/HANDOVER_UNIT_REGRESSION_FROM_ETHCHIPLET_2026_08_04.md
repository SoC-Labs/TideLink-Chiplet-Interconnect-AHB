# HANDOVER — TideLink unit regression: close the sim[silicon_data] blind spot (2026-08-04)

**From:** eth-chiplet integration session (KR260 nanosoc-ethernet-chiplet)
**To:** the TideLink cocotb/UVM unit-regression owner
**Scope:** the TideLink regression ONLY — `cocotb/` envs, the repo-root `Makefile`
gates (`sim-regression*`, `sim_robust`, `sim_gate*`), and `uvm/`. **Not** the
eth-chiplet SoC-side HW scripts.

---

## (A) TL;DR

Several fixes this session **PASS in the TideLink sim regression yet do not fire,
or fail outright, on the KR260 eth-chiplet silicon.** The regression is blind to
the silicon operating point: the **~40 ns app:link clock ratio**, a **marginal
eye**, **bilateral inter-die skew**, and a **busy link with FC keepalive**. Every
blocking v2 suite runs `EPOCH_PROFILE=zero` (no skew) or *forces the corrector
on*, so the exact all-zeros signature the deployed deskew produces is only a
**non-blocking advisory**.

Three concrete gate holes, all cheap to close:

1. **The silicon-faithful path is non-blocking.** `sim_gate_epoch_silicon`
   (blocking) passes *only because* it compiles `+define+TB_TOP_EPOCH_ANCHOR_FORCE`
   — a datapath the shipping silicon does **not** run. The shipping-default
   behaviour (SYNC_REANCHOR corrector, beacon off) is captured only by the
   tolerated XFAIL sentinel `sim_gate_xfail_epoch_shipping` (token
   `xfail_epoch_shipping_corrector`). That sentinel reproduces the KR260 all-zeros
   S→M signature and is **advisory**. Make the silicon-faithful tier **blocking
   for any FPGA/silicon-bound branch** (§E).

2. **AUTO_ANCHOR is unit-tested only on an idle link.** `test_v2_auto_anchor.py`
   (3/3 PASS) cannot model a sub-`ANCHOR_DWELL` keepalive stream, which is exactly
   the condition under which the fix does **not** latch `reanchored` on HW. Add a
   **busy-link + bilateral-skew** variant that fails on *pause-accumulate* and
   passes only on *quiesce-and-burst* (§B1). Note: `test_v2_auto_anchor.py` is
   **not wired into any `sim_gate` target** today.

3. **Verified tests are sitting un-gated.** `gaps_ecc` (the 6 header-ECC-restore
   tests, incl. the W byte-0 = HW W-node wedge class), `test_v2_force_always_residual`,
   `tidelink_fcsm_silicon_ratio`, `test_v2_marginal_eye`, and the `crc_diag` bench
   all pass but none is in a blocking gate (§C).

**Already resolved + sim-verified (do not re-scope):** the AXI data-node recovery
*logic* — header-ECC restore, synth-B OKAY backstop, Fix G/H, F-1; `gaps_ecc` 6/6,
`gaps_nodes`, `gaps_backstop`, and the recoverable-wedge suite
(`sim_gate_axi_datanode_recovery` / `sim_gate_axi_datanode_gaps`, both blocking).
Link bring-up, bulk A→B, credit, PHY-RX, `tidelink_lane_deskew`, the calibrator,
the FC adapter, and PTP block/servo/chain (`tidelink_ptp`, `tidelink_ptp_servo`,
`uvm/tidelink_ptp_chain`, `uvm/tidelink_ptp_stress`) are strong.

---

## (B) ADD these regression tests

### B1 — `test_auto_anchor_busy_link_reanchor` (busy-link + bilateral-skew AUTO_ANCHOR)

- **Extend:** `cocotb/tidelink_top_pair_v2/test_v2_auto_anchor.py` (add the
  keepalive/backpressure model to `cocotb/tidelink_top_pair_v2/pair_v2_common.py`).
- **Silicon bug it catches:** after bring-up (fcsm=4) the deskew corrector is
  **not** anchored (`EPOCH_STATUS 0x2140 bit0 reanchored=0`, obs
  `AUTO_ANCHOR_OBS 0x21F4 bit21=0`) because the shipping `SYNC_REANCHOR_EN=1`
  corrector re-anchors only on a live SYNC beacon that bring-up leaves off. The
  pause-accumulate fix (`200bce5`) emits the beacon on HW
  (`0x21F4 pulsed_ever=1, dwell_max>=256`) but the peer still does **not** latch
  (`reanchored=0`): the peer needs a **contiguous** SYNC run. A manual contiguous
  ~0.4 s pulse *does* latch and data crosses byte-exact. The current idle-link tb
  cannot see this.
- **Must assert:** with the app→link valid stream toggling **faster than
  `ANCHOR_DWELL` (256)** and a **bilateral inter-die skew** profile applied,
  `reanchored` (0x2140[0] / 0x21F4[21]) latches **only** when the anchor runs as a
  **quiesce-and-burst** (hold off app traffic for the full 4096-cycle burst), and
  the corrupting *pause-accumulate* variant never latches it. Then S→M and M→S
  deliver **byte-exact**.
- **PASS/FAIL:** PASS = `reanchored=1` + byte-exact under quiesce-and-burst;
  the negative control (pause-accumulate under the same keepalive) must **FAIL to
  latch** — that is the non-vacuity, and it is the test that turns the HW-only
  `AUTO_ANCHOR_HW_DIAGNOSTIC_2026_08_04.md` finding into a sim gate.
- **Note:** the `deskew_handoff_lottery` premise is **refuted** (a fixed-offset
  read artifact, not a link bug — see its `README.md`). Do **not** build B1 on a
  "framer-lock lottery" premise; build it on the beacon-contiguity requirement.

### B2 — `test_auto_anchor_sop_gated_no_word_loss` (corruption-race + bilateral skew)

- **Extend:** `test_v2_auto_anchor.py`
  (`test_auto_anchor_no_word_loss_during_burst`) and/or
  `cocotb/tidelink_top_pair_v2/test_v2_force_always_residual.py`.
- **Silicon bug it catches:** `force_always` over live data is a **word-deleter**
  (the R4 / B→A corruptor). `test_v2_force_always_residual.py` already proves the
  `0044bef` drain guard is necessary-but-**insufficient**: the `force_always` OR
  terms (`ws_serve_active_r` SLAVE-only, `winscan_force_sync`) bypass it and
  overwrite s→m payload. The anchor burst must **never straddle app traffic**.
- **Must assert:** with **bilateral skew + live app traffic straddling the
  dwell/burst window**, the anchor burst is gated on `~ll_app.sop` and **every
  word lands byte-exact** — zero deletions. This is the corruption-race variant
  the dev already requested.
- **PASS/FAIL:** PASS = 0 deleted words when SOP-gated; FAIL = any deletion
  (which is what an ungated `force_always` burst produces — already reproduced in
  `test_v2_force_always_residual.py`).

### B3 — `test_recovery_arms_only_with_crc_on` (CRC-on is Fix G's precondition)

- **Extend / promote:** `cocotb/crc_diag/` (`test_crc_enable_probe`,
  `test_crc_mechanism`), tied to the recovery suite
  `cocotb/tidelink_axi_datanode_recovery/`.
- **Silicon bug it catches:** NACK/replay recovery **only arms with CRC on**
  (`SM_CONTROL[16]=0` RMW, per-node FC base `+0x14`). The AXI FC nodes **ship
  CRC-off** (`WlinkGenericFCSM_2.v:713`), so a payload error is silently accepted.
- **Must assert:** (a) with the per-node CRC enabled via the `SM_CONTROL[16]=0`
  RMW, an injected payload error is **detected → NACK → replay → byte-exact**;
  (b) **negative:** with CRC at the shipping default (off), the same error is
  **silently accepted** (no `crc_errors` tick, no NACK). The recovery suite
  already carries `test_axi_b_crc_on_detects_payload` /
  `test_axi_b_crc_off_silent_payload` (blocking, via
  `sim_gate_axi_datanode_recovery`) — B3 **formalizes `crc_diag`** as the
  top-level "recovery requires the CRC-on precondition" assertion so the RMW
  itself is guarded, not just the downstream NACK.
- **PASS/FAIL:** PASS = detect+recover CRC-on AND silent-accept CRC-off (both
  clauses); FAIL = either clause flips.

### B4 — `test_perf_cong_state_field_decode` (integrated PERF_CONG_STATE at 0x20F8)

- **Extend:** a pair env (`tidelink_top_pair_v2`) or the integrated aperture of
  `tidelink_perf_congestion`.
- **Silicon bug it catches:** **no test decodes `PERF_CONG_STATE 0x20F8`** in the
  integrated controller. The only decode that exists is block-level
  (`cocotb/tidelink_perf_congestion/test_tidelink_perf_congestion.py::read_cong_state`,
  Region 7 offset `R7_CONG_STATE` on the `perf_reg_*` port) — it never exercises
  the `0x20F8` APB aperture the silicon telemetry is read through.
- **Must assert:** driving the congestion sideband to known states, read `0x20F8`
  and decode `level [17:16]`, `trend [19:18]`, `starve [20]`, `ewma [12:0]`
  against expected values.
- **PASS/FAIL:** PASS = all four fields decode correctly at `0x20F8`; FAIL = any
  field mis-decodes or reads dead.

### B5 — `test_marginal_eye_40ns_ratio_proxy` (closest proxy for the W byte-0 physical wedge)

- **Extend / promote:** `cocotb/tidelink_fcsm_silicon_ratio/`
  (`make repro` / `make fixed`) + `cocotb/tidelink_top_pair_v2/test_v2_marginal_eye.py`
  (`EYE_FAULT=1`, `eye_fault.sv`).
- **Silicon bug it catches (honestly, a PROXY only):** the **W byte-0
  forward-write intermittent wedge is PHYSICAL** (eye-margin, WNS +0.484 ns) — an
  ILA-class issue, **not** an AXI-logic bug. Sim cannot close it directly. The
  **40 ns app:link ratio + marginal-eye + bilateral-skew** profile is the closest
  reproducible proxy: `tidelink_fcsm_silicon_ratio` already models the marginal /
  retrying link at the slow ratio (gate=32 → all 10 AXI nodes wedge in FCSM
  state-2; gate=8 → clear), and `test_v2_marginal_eye` injects training-exit-edge
  bit errors with the anchor ON.
- **Must assert:** the FCSM state-2 CRACK-emit gate clears at the tuned gate under
  the marginal-link model, and the marginal-eye injection at the training-exit
  edge is *observed* (not silently swallowed). **Do not** claim this closes the
  physical wedge — label it a proxy.
- **PASS/FAIL:** as the env already defines (`make repro` EXPECT FAIL / `make
  fixed` EXPECT PASS).

---

## (C) PROMOTE scratch → gating

| Env / test (real name) | Where it lives | Status today | Promote to | Why |
|---|---|---|---|---|
| `gaps_ecc` (6 tests: `test_ecc_corrects_{w,aw,r,b}_byte0`, `test_ecc_corrects_b_byte1_wordcount`, `test_ecc_persistent_w_byte0_byte_exact`) | `cocotb/tidelink_axi_datanode_recovery` (`GAPS_ECC_TESTS`) | **verified 6/6 but UN-GATED** — `sim_gate_axi_datanode_gaps` runs only `gaps_nodes` + `gaps_backstop`, **not** `gaps_ecc` | fold `gaps_ecc` into `sim_gate_axi_datanode_gaps` | this is the header-ECC restore that turns the W byte-0 silent mis-route into a byte-exact recover — the class closest to the HW W-node wedge, and it can silently regress |
| `test_v2_force_always_residual` (`test_force_always_residual_s2m`) | `cocotb/tidelink_top_pair_v2` | not in any `sim_gate` recipe | new blocking suite `sim_gate_force_always_residual` (SLAVE R8=0x1C, s→m) | guards the direction-asymmetric s→m word-deletion; reproduces with the `0044bef` guard present |
| `test_v2_auto_anchor` (3 tests) | `cocotb/tidelink_top_pair_v2` | not in any `sim_gate` recipe | new blocking suite once B1 lands | the anchor safety + no-word-loss guarantees are otherwise one revert from silently regressing |
| `tidelink_fcsm_silicon_ratio` (`make repro`/`make fixed`) | `cocotb/tidelink_fcsm_silicon_ratio` | not referenced in `Makefile` at all | new suite `sim_gate_fcsm_silicon_ratio` (silicon-bound branches) | the ONLY sim that models the 40 ns-ratio marginal-link FCSM-2 stall |
| `test_v2_marginal_eye` (`EYE_FAULT=1`) | `cocotb/tidelink_top_pair_v2` | not gated | fold into the silicon-faithful tier (§E) | proxy for the physical eye wedge |
| `crc_diag` (`test_crc_enable_probe`, `test_crc_matrix`, `test_crc_mechanism`, `test_crc_rootcause`, `test_crc_beacon_ab`) | `cocotb/crc_diag` | scratch, not gated | formalize as B3 | CRC-on is Fix G's precondition; the RMW must be guarded |

**Do NOT promote `deskew_handoff_lottery`** as a field-bug reproducer — its premise
is **refuted** (measurement artifact). Keep it only as a synthetic whole-word-skew
robustness harness, as its `README.md` already states.

---

## (D) FIX dead / false-confidence assertions

### D1 — `ECCCNT 0x2114` low half is a dead net in the shipping build
- `[31:16] sync_detected` is **live** and legitimately asserted
  (`cocotb/tidelink_top_pair_v2/test_v2_sync_insert_en.py:233,241`;
  `cocotb/tidelink_top_pair_wordskew/test_tidelink_pair_doorbell.py:1548`). Keep
  those.
- `[15:0] ecc_corrupted` is **DEAD** in the shipping/deployed flist: the AXI FC
  nodes resolve to the recovery-stripped `deps/` copies whose
  `WlinkEccSyndrome.v` ties `corrupted=0` (`docs/REGISTER_MAP.md:275`). Only
  `src/rtl/local_overrides/WlinkEccSyndrome.v:318` wires the real
  single-error-correct decode.
- **Action:** never assert on `0x2114[15:0]` in a shipping-flist test (it would be
  testing a dead net), **or** thread the `local_overrides` syndrome through the
  shipping flist so the counter is real. No test asserts on it today — this is a
  guard against a future false-green.

### D2 — `PERF_CONG_STATE 0x20F8` fields are never decoded in the integrated path
- Covered by **B4**. Today the only decode is block-level; the integrated
  `0x20F8` aperture has **zero** coverage.

### D3 — Error-injection DIRECTIONALITY (keep it correct)
- The Wlink injector corrupts a die's **outgoing** packets: forward nodes
  **AW/W/AR** are TX'd by the **initiator**, return nodes **B/R** by the
  **target**. `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py`
  already encodes this correctly (`NODES[...]['tx_side']`: AW/W/AR → `"m"`,
  B/R → `"s"`; the injector arms on `n['tx_side']`, the NACK is generated by the
  receiver). **This is right — keep it.**
- **Action:** treat "inject B/R on the TARGET-side model" as a **documented,
  guarded invariant**. A wrong-side injection is a **vacuous no-op → false PASS**;
  the older `cocotb/tidelink_error_injection` bench predates the `NODES` map, so
  any new B/R injection there must adopt the same `tx_side` discipline (and keep
  the Fix-G-OFF discriminator, as the R-node test does).

### D4 — Persistent-B re-corruption is OUT OF SCOPE by design (negative test, not a recovery claim)
- synth-B is a **timeout OKAY-backstop for a single/transient stuck B**. A
  **persistently-armed** injector re-corrupting every retry is **EXPECTED to
  wedge** — the regression must **not** assert recovery of persistent corruption.
- Already the right shape: `test_axi_b_persistent_eye_bounded` (blocking) and the
  `_arm_injector_persistent` I5 tests assert **bounded** (synth-B fires) / a
  documented wedge, not byte-exact recovery. **Action:** keep it explicitly as the
  **negative** case and never let it drift into a recovery assertion.

---

## (E) MAKE the silicon-faithful tier BLOCKING for FPGA/silicon-bound lineages

The blind spot in one place:

- `sim_gate_epoch_silicon` (in `SIM_GATE_ALL_SUITES`, **blocking**) runs
  `EPOCH_PROFILE=silicon` **with `+define+TB_TOP_EPOCH_ANCHOR_FORCE`** — it
  *forces the EPOCH corrector on*, a datapath the shipping silicon does **not**
  run. It is green by construction (see the CHARACTERISED CAVEAT at
  `Makefile:534-542`).
- `sim_gate_xfail_epoch_shipping` (token `xfail_epoch_shipping_corrector`, in
  `SIM_GATE_SENTINELS`) runs the **shipping-default** corrector and captures the
  exact silicon signature: `test_02 (M→S) passed`, `test_03 (S→M) failed`,
  `rx=[0x00000000...]`, `TESTS=3 PASS=2 FAIL=1`. It is tolerated as **XFAIL**
  (non-blocking).

So the one suite that reproduces the KR260 deskew failure is **advisory**, while
the suite that "passes silicon skew" only does so by disabling the shipping
behaviour.

**Recommendation:** for any **FPGA/silicon-bound branch**, gate the
silicon-faithful tier as **blocking**:
1. Land **B1** (busy-link quiesce-and-burst reanchor) as the *positive* proof that
   the shipping corrector can be made to anchor, then
2. flip `xfail_epoch_shipping_corrector` from a tolerated sentinel to a **blocking
   assertion** on those branches (it stays XFAIL on mainline until the RTL/bring-up
   fix lands), and
3. add `sim_gate_fcsm_silicon_ratio` + `test_v2_marginal_eye` to that same
   silicon-bound tier.

Keep it branch-scoped so mainline CI stays green and fast; the point is that
**nothing FPGA-bound ships while the silicon-faithful S→M path is red-but-ignored.**

---

## (F) TideChart regression gaps (separate regression — noted for completeness)

Existing: `cocotb/tidechart_tidelink_pair/` — `test_tc_pair_smoke` +
`test_tc_pair_election_datamode` (gated as `tc_pair_smoke` /
`tc_pair_election_datamode` in `SIM_GATE_ALL_SUITES`, guarded by
`SIM_GATE_TC_DEP` so they only run when the sibling `tidechart` +
`tidechart_shim.sv` are present). G1 (election-in-data-mode) and G2 (PKT_EXT
crossing) are closed by the datamode test. Remaining gaps:

| Gap | Silicon/RTL symptom | Add |
|---|---|---|
| Root **DFS enum** is "Planned" — never simulated | enumeration/route never exercised over a live link | `enum_start` → assign IDs → read `TC_ROUTE_RD` hop/port over the real TideLink pair |
| **Closed-loop congestion telemetry** broadcast never simulated across two dies | in the smoke run `tc_axis_tx_tvalid` drove **0 cycles**, `rx_bcast_count` stayed 0 (G2 residue) | a closed-loop test: die_a `TC_CONG_CTRL` enable+trigger → assert the stretch broadcast **crosses** to die_b |
| `force_root` **decoded but unconsumed in RTL** | sim passes, silicon dead | a `force_root`-**consumed** test that asserts the forced die actually wins (fails while the RTL leaves it unconsumed) |
| `TC_ERROR[2]` **dual-root flag never asserts** | the smoke test dual-rooted (both `is_root=1`) yet no error flagged | drive the dual-root condition and assert `TC_ERROR[2]` sets |
| Both dies share `DEVICE_CLASS=0x0001` (**G1**) → non-deterministic election | election tie-breaks on `random_id` only; identical class → non-deterministic | a **per-die `DEVICE_CLASS` determinism** test (distinct classes → deterministic single root) |

---

## (G) Silicon finding → regression action → status

| # | Silicon finding (this session) | Regression action | Status |
|---|---|---|---|
| 1 | Deskew re-anchor / AUTO_ANCHOR passes in sim, doesn't latch `reanchored` on silicon; peer needs a **contiguous** SYNC run (quiesce-and-burst, not pause-accumulate) | **B1** busy-link + bilateral-skew reanchor; assert `reanchored` latches only under a contiguous burst | **ADD** (`test_v2_auto_anchor.py` currently idle-link only, un-gated) |
| 2 | `force_always` over live data is a word-deleter (R4 / B→A) | **B2** SOP-gated burst, bilateral skew, zero word deletion | **ADD/PROMOTE** (`test_v2_force_always_residual` exists, un-gated) |
| 3 | Error-injection directionality: B/R on the **target**, AW/W/AR on the **initiator** | **D3** keep the `NODES.tx_side` invariant; apply it to the older errinj bench | **DONE in `test_axi_datanode_gaps.py`; guard** |
| 4 | Persistent-B re-corruption is out of scope by design | **D4** negative test asserts bounded/wedge, never recovery | **COVERED; formalize** |
| 5 | CRC-on is Fix G's precondition (`SM_CONTROL[16]=0` RMW) | **B3** recovery arms only CRC-on + CRC-off silent-accept negative | **PARTIAL** (recovery suite has both; formalize `crc_diag`) |
| 6 | Observability-dead counters (`ECCCNT 0x2114[15:0]`, `PERF_CONG_STATE 0x20F8`) | **D1** never assert the dead ECC half / wire it; **B4** integrated `0x20F8` field-decode | **FIX / ADD** |
| 7 | Silicon-faithful tier is non-blocking (`test_03` / `xfail_epoch_shipping`) | **E** make it blocking for FPGA/silicon-bound branches | **CHANGE GATE** |
| 8 | W byte-0 forward-write wedge is PHYSICAL (eye margin, WNS +0.484 ns) | **B5** 40 ns-ratio + marginal-eye + bilateral-skew proxy (honest: cannot close it) | **PROXY only** |
| 9 | TideChart gaps (DFS enum, closed-loop telemetry, `force_root` unconsumed, `TC_ERROR[2]`, shared `DEVICE_CLASS`) | **F** five TideChart tests | **ADD (separate regression)** |

---

### Source pointers (all under `tidelink/`)
- Gates: `Makefile` — `sim-regression` (:133), `sim-regression-v2` (:156),
  `sim_robust` (:50), `SIM_GATE_ALL_SUITES` (:1242), `SIM_GATE_SENTINELS` (:1262),
  `sim_gate_epoch_silicon` (:544, caveat :534-542),
  `sim_gate_xfail_epoch_shipping` (:1061), `sim_gate_axi_datanode_gaps` (:678),
  `sim_gate_errinj` (:958), `sim_gate_f14a_crc_catch` (:1019).
- Envs: `cocotb/Makefile` (`ENVS`, :7-10); `cocotb/README.md` (scratch/debug
  policy); `cocotb/VERIFICATION_PLAN.md` (FIFO-era only — see its scope note).
- Tests: `cocotb/tidelink_top_pair_v2/{test_v2_auto_anchor,test_v2_force_always_residual,test_v2_marginal_eye}.py`,
  `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py`
  (`NODES`/`GAPS_ECC_TESTS`), `cocotb/tidelink_fcsm_silicon_ratio/`,
  `cocotb/crc_diag/`, `cocotb/tidechart_tidelink_pair/README.md`.
- Session docs: `docs/AUTO_ANCHOR_HW_DIAGNOSTIC_2026_08_04.md`,
  `docs/AXI_DATANODE_*`, `docs/VERIFICATION_REVIEW_AXI_DATANODE_PUSHBACK_2026_08_02.md`,
  `docs/SIM_GATE_COVERAGE.md`, `docs/REGISTER_MAP.md` (0x2114 :223/:275, 0x2140 :31).
</content>

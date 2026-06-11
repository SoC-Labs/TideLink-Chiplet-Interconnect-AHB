# TideLink New-GPIO-PHY Integration — Status Report

**Date:** 2026-06-11
**Branch under review:** `feat/phy-v2-integration` (tidelink) @ `0f9a54e`; S3 swap worktree `feat/s3-phy-swap` @ `6199a2e` (`~/SoCLabs/td-scratch/s3-swap`)
**Plan of record:** `tidelink-gpio-phy-deskew/docs/archive/PLAN_TIDELINK_INTEGRATION.md` (2026-06-10, 5-layer L0–L4 model). Authoritative over the older `INTEGRATION_GUIDE.md`.

---

## 1. Executive summary

The integration is past its two highest-risk gates and is now limited by verification, not discovery. The old (V1) PHY stack was driven to a documented close on 2026-06-10/11: autonomous bilateral link-up, a byte-perfect M→S data crossing on silicon (v33), a partial-success **zero-poke** bring-up with no APB writes at all (v34) that proved the entire L3 autonomy stack (I2C autoneg, role lock, POR-autonomous training) and isolated the single remaining blocker to the old PHY's marginal RX eye — exactly the thing the new PHY replaces. In parallel, the new PHY passed its own silicon gates (autonomous bilateral link_up 3/3, lane-drop root-caused and resolved, 30-minute zero-drop soak = V5), was extracted into a shared, layered component (L0 pristine vendor / L1 owned forks with drift guard / L2 alignment stack behind a versioned contract interface), and is now consumed by tidelink as the `deps/tidelink-phy` submodule with a complete V2 ASIC build variant that elaborates cleanly alongside a bit-identical V1. What remains before hardware validation of V2: finish the calibrator Tier-2 rewrite without breaking contract VERSION=1, bring up the V2 full-stack pair simulation (gate V2 — not yet run), produce a V2 FPGA build, and re-attempt the zero-poke demo (V4) on the new PHY.

---

## 2. Plan vs. actual

### 2.1 Sequence S1–S6

| Item | Plan | Status | Evidence |
|---|---|---|---|
| **S1** | PLAN_LANE_DROP execution (gates V5, P10) | **DONE** | Lane drop RESOLVED via F1 IDELAY-bypass (`USE_IDELAY=0` FPGA / `1` ASIC); H2 refuted in sim; 30-min soak PASSED (`2d9ec30`, `dd09ab3`, `6bab26d`, 2026-06-10) |
| **S2** | Shared-component extraction (L0/L1 split, drift guard) + P1–P6/P8/P9 ports | **DONE (first slice merged & consumed)** | PHY repo `feat/s2-shared-component` @ `3f6e7a0` = L0 vendor layer (`6b3a6f4`) + L1 provenance forks (`a2109c5`) + `check_wav_drift.sh` (`4350a89`) + `tidelink_phy_align_if` VERSION=1 contract (`0475809`); golden 11/11 + drift guard PASS. Consumed in tidelink as `deps/tidelink-phy` submodule pinned to `3f6e7a0` (`42f1cef`, `0f9a54e`) |
| **S3** | P7 simplified-calibrator rewrite (AUDIT 4b) under V0–V3 | **IN FLIGHT** | Tier-2 Stage 1 dead-layer delete bit-identical (`fe8f397`); golden suite migrated to the real always-on FSM (`442f00e`); Stage 2a.2-i/ii deletes (`d842b24`, `f7faf32`); lane-mask-aware autonomous reduced-lane bring-up (`c5b2c7d`). Not complete; must respect contract VERSION=1 (see Risks). *(Team shorthand also uses "S3" for the tidelink-side PHY swap — tracked below as the V2 build variant.)* |
| **S4** | I1 autonomy merge + I2 nego_en POR strap, sim-gated | **DONE** | I1: flist split-brain closed (`7b8b09b`), 42 N-series/I2C cherry-picks, submodule L3 merge (acc `efe5623`), i2c_train protocol doc graduated to `docs/` (`99ad3a6`); all sim gates green. I2: POR reset-skew sweep gate test_24 3/3 PASS with zero APB (`6e22f98`, `464f8f3`); silicon-confirmed by the V4 attempt |
| **S5** | I3 contract adoption + V4 zero-poke demo | **PARTIAL / IN PROGRESS** | V4 first-silicon attempt ran early (see §3, `22f1e2c`): autonomy stack silicon-proven, bilateral link-up blocked by the old PHY eye by design. I3 (training FSM adopting `tidelink_phy_align_if` verbatim) not yet done; the S3-swap worktree wires the V2 calibrator surface behind `TIDELINK_PHY_V2` (`f92c7c1`) as the first step |
| **S6** | V5 long-soak sign-off, tag, ASIC flist refresh | **STARTED** | V2 ASIC flist variant drafted and elab-clean (`9028e56`); integrated long-soak sign-off and tag pending V2 bring-up |

### 2.2 Validation ladder V0–V5

| Gate | Plan | Status | Evidence |
|---|---|---|---|
| **V0** | lint + unit TBs | **PARTIAL — lint RED** | Unit TBs green (golden suite migrated, 11/11). Verilator lint re-run 2026-06-11: 12 PASS / **4 FAIL** (`tidelink_gpio_phy_rx`, `tidelink_phy_align_calibrator`, `tidelink_phy_bist_core`, `tidelink_phy_bist_prbs`) |
| **V1** | golden 11/11 + facet battery (PHY repo) | **PASS** | 11/11 + facet battery green on `feat/phy-refactor`; suite re-based onto the always-on FSM (`442f00e`) |
| **V2** | tidelink wlink_pair full-stack sim, L2 contract exercised by L3 | **NOT RUN** | Only VCS *elaboration* of the V2 build proven (S3 worktree `scratch/elab_v2`, `simv_v2` built; V1 pre/post swap bit-identical at elab). V2 pair simulation is the next major gate |
| **V3** | FPGA PHY-BIST pair: autonomous bilateral link_up 3/3 + 10-min soak | **PASS** | 2026-06-10 HW validation (`0c50180`, basin park `e92902d`, FIX-R-proper `21e53df`) |
| **V4** | tidelink FPGA pair with I2C: zero-poke bring-up | **PARTIAL** | First silicon attempt 2026-06-11 (`22f1e2c`, v34 image): zero APB writes → roles negotiated+locked, both dies cal_done=1, die_a FCSM=4; die_b parked fcsm=2/ck=0 on the old-PHY marginal eye. Re-attempt scheduled after the PHY swap |
| **V5** | 30-min bilateral soak, zero lane drops | **PASS (PHY-BIST context)** | `2d9ec30`, 2026-06-10. Integrated-tidelink V5 repeats at S6 |

### 2.3 Ports P1–P10

| Port | What | Layer | Status |
|---|---|---|---|
| P1 | Glitch-free recovered word clock | L1 | **Landed** (`e853093`); in L1 owned fork with provenance header (`a2109c5`) |
| P2 | FIX-N race-free bit→word handoff | L1 | **Landed** (`c0528fc`; FIX-O TX seam `c65a008`) |
| P3 | FIX-Q IOB TX pad + TX_WORD_SYNC staging | L1 | **Landed** (`4d0e843`) |
| P4 | WORD_PIN_AUTO per-lane comma re-pin | L1 | **Landed** (FIX-R-proper `21e53df`); V2 swap routes the word-pin pair through Wlink (`7b38b76`) |
| P5 | Gray-coded deskew write-pointer CDC | L2 | **Landed** (`c2ab8b6`) |
| P6 | Beacon opt-in + mask-aware exclude | L2 | **Landed** (`21e53df`) |
| P7 | Simplified calibrator (AUDIT 4b rewrite) | L2 | **IN FLIGHT** — Tier-2 stages 1/2a done (`fe8f397`…`f7faf32`), remainder pending; the eye-vis consumer decision is resolved on the tidelink side (eye-regs retired in V2, `6199a2e` + flist `9028e56`) |
| P8 | FIX-P ODDR polarity shim | L4 | **Landed in PHY-repo FPGA targets** (`dc0b9f7`); port to tidelink FPGA targets pending (no V2 FPGA target yet) |
| P9 | word_handoff XDC constraint set | L4 | **Landed in PHY-repo FPGA targets** (`e64e078`, `590f8e8`, `fb4f37d`, counter-CDC fixes `3dda881`/`4ac98ee`); tidelink port pending with the V2 FPGA target |
| P10 | Per-bank IDELAYCTRL redo | L4 | **Superseded** — per-bank IDELAYCTRL reverted (`293c10b`); resolution is F1 IDELAY-bypass per DECISION_F1 (`dd09ab3`, validated `2d9ec30`) |

---

## 3. What landed this week (by date, with commit refs)

### 2026-06-09 (context)
- Serdes/calibrator fix train in the PHY repo: glitch-free word clock (`e853093`), Gray deskew CDC (`c2ab8b6`), FIX-H/J/L/M eyescan ladder (`64e3a2c`, `cf6857d`, `bba0d11`, `fed3c3a`).
- Old-stack calibrator M9 validate-retry fix (`6ce0827`) feeding the v32→v33 build sequence.

### 2026-06-10 — autocal closure + new-PHY silicon gates + I1/I2
- **M→S DATA CROSSED on silicon (v33)**: 4-packet AHB_TX burst landed byte-perfect in the slave RX FIFO (`hdr=0x00240000`, `p0=0xDA7A0000`); stack = M11 `e2fefd4` + deskew pipeline `c5f24b6` + M12 sync_bootstrap `7702f07`. Reproduced same day with `0xc0ffee00/01` readback. Closure ledger + residuals 1–7: `docs/archive/AUTOCAL_CLOSURE_2026_06_10.md`.
- **New PHY silicon-validated**: FIX-N/O/P/Q/R serdes train (`c0528fc`, `c65a008`, `dc0b9f7`, `4d0e843`, `21e53df`), bilateral LINK_UP basin-park (`e92902d`), autonomous bilateral link_up 3/3 (`0c50180`).
- **Lane-drop RESOLVED + V5 soak PASS** (`2d9ec30`); Tier-1 latent bugs incl. the CDC F2 counter-read crossing fixed (`2c930d5`).
- **Integration plan published** (`931ccef`) — the L0–L4 / P1–P10 / V0–V5 / S1–S6 plan this report tracks.
- **I1 autonomy merge** to `feat/phy-v2-integration`: flist split-brain closed (`7b8b09b`), submodule L3 merge (acc `efe5623`), 42 cherry-picks (N-series fixes, POR params, I2C P15/P16 repin), i2c_train doc graduated (`99ad3a6`). All sim gates green.
- **I2 POR autonomy closed**: per-die POR gates in the pair TB (`464f8f3`) + test_24 reset-skew sweep 3/3 PASS with zero APB (`6e22f98`); M11b register-field collision fix (`9a085ab`); criterion-B HW link-up gate (`8ab62f2`).

### 2026-06-11 — V4 first silicon, Bug-A anatomy, S2 extraction, S3 swap
- **V4 zero-poke first silicon — PARTIAL SUCCESS** (`22f1e2c`, `docs/archive/V4_ZERO_POKE_FIRST_SILICON_2026_06_11.md`): v34 flash-only, zero APB writes → I2C arbitration resolved (P15/P16 harness proven live), both dies role_locked + cal_done autonomously, die_a FCSM=4. Gap: die_b never decodes CRACK — the old-PHY marginal-eye residual. test_24's boot-order-beats-strap finding reproduced on silicon.
- **Bug-A wedge mechanism FIXED** (`4c0a51a`): fc_adapter `TX_STALL_TIMEOUT_LOG2=16` converts the PS-deadlocking TX stall into a bounded AHB ERROR; gates buga 8/8 + pair baseline 11/11.
- **Doorbell mystery SOLVED** (`4e8cf05` → `878259f` → `ab14780`): not a sideband fault — it is Bug-A link poisoning. One un-ACKed AHB_TX long packet jams the FC node (master fs=5 + `a2l_lnk=1` + `fe_full=0`) because the NACK/ACK return rides the marginal S→M eye. SW detection signature + swreset recovery documented; `unjam_fc_node.sh` packaged (`f1313a1`). **New residual #7 found**: Wlink replay is NOT idempotent at RX (3–5 duplicate deliveries per ring).
- **Repo consolidation**: ~130 docs → 5-doc product set + curated archive, `flist/`→`flists/` (`9e343cd`, `6a48b04`, `87cb606`, `585c96c`); board deploy runbook field-verified (`7e27eb9`, `docs/BOARD_DEPLOY_RUNBOOK.md`).
- **S2 shared-component extraction (PHY repo)**: L0 pristine vendor layer (`6b3a6f4`), L1 provenance headers on the four owned forks (`a2109c5`), drift guard (`4350a89`), **`tidelink_phy_align_if` VERSION=1 contract interface** (`0475809`), merged at `3f6e7a0` with golden 11/11 + drift PASS.
- **S2 consumption (tidelink)**: `deps/tidelink-phy` submodule (`42f1cef`), `tidelink_phy_v2.flist` staged (`ad0a39c`), `USE_PHY_V2` scaffold (`4a0da60`), pin bump to `3f6e7a0` (`0f9a54e`) — elab-clean, bit-identical V1.
- **Calibrator Tier-2 rewrite (PHY repo, in flight)**: dead-layer delete bit-identical (`fe8f397`), golden suite onto the always-on FSM (`442f00e`), Stage 2a.2 deletes (`d842b24`, `f7faf32`), lane-mask-aware autonomous reduced-lane bring-up (`c5b2c7d`), clean-build fix (`0af1668`).
- **S3 PHY-swap worktree** (`feat/s3-phy-swap` @ `td-scratch/s3-swap`): V2 ASIC build variant `tidelink_top_full_asic_v2.flist` — swaps the serdes/PHY/deskew/calibrator/checker set to `deps/tidelink-phy`, retires `tidelink_eye_regs`, defines `TIDELINK_PHY_V2` (`9028e56`); Wlink word-pin routing + V1-only tx_idle guard (`7b38b76`); V2 calibrator arm behind ifdef with the A2 oracle and BIST CTRL[6] hold semantics preserved (`f92c7c1`); eye-regs slave tied off, Region-10 APB inert (`6199a2e`). **Gates run:** V1 pre/post-swap elab bit-identical; V2 flist elaborates clean (simv built). V2 *simulation* not yet run.

---

## 4. Open risks & blockers

1. **Calibrator Tier-2 rewrite vs. contract VERSION=1 (top integration risk).** The rewrite continues on `feat/phy-refactor` (@`0af1668`) while tidelink pins `deps/tidelink-phy` to `feat/s2-shared-component` @`3f6e7a0`, which carries the frozen VERSION=1 `tidelink_phy_align_if`. The rewrite must either keep the VERSION=1 surface or bump VERSION; `feat/s2-shared-component` must be merged back into `feat/phy-refactor` (disjoint files, no conflict expected) before the pin spread widens.
2. **V2 sim bring-up pending (gate V2).** Only elaboration is proven. Project policy (sim-gate before HW deploy) and history (multiple sim-discoverable bugs burned HW time) make the V2 `tidelink_top_pair` simulation the mandatory next gate before any V2 FPGA build.
3. **Residual #7 — Wlink replay non-idempotency.** Each link-layer replay is re-applied at RX (3–5 duplicate deliveries observed). The new PHY makes replays rare but the debt is architectural (L3): any transient error duplicates delivery into W-add accumulators / RX FIFOs. Needs RX sequence-number dedup or idempotent FC consumers. Independent of the PHY swap; must not be silently closed by it.
4. **Strap-vs-boot-order role assignment.** Silicon (V4) and sim (test_24) both show boot order beating strap preference. Deliberately DEFERRED (system is role-symmetric); designs recorded in `docs/archive/DESIGN_NOTE_STRAP_AUTHORITATIVE_REARB.md`. Becomes a real item only if strap must be authoritative.
5. **Lint red in the PHY repo (gate V0).** Verified 2026-06-11: 4 modules fail verilator lint (`tidelink_gpio_phy_rx`, `tidelink_phy_align_calibrator`, `tidelink_phy_bist_core`, `tidelink_phy_bist_prbs`). The calibrator is being rewritten anyway; the others need a lint pass before S6 sign-off.
6. **Secondary**: `unjam_fc_node.sh` recovery not yet live-validated (the one jammed board deteriorated to a PL-AXI bus error and needed re-flash); z2_02 has a recurring hard-wedge history (JTAG `rst -system` recovery via xsdb on mapstone-dev:3121); the v33/v34 WNS=−1.16 ns is a characterized phantom (PHY RX XDC double-count) but the self-defeating constraint should be cleaned for V2 builds.

---

## 5. Hardware state

- **Rig:** bridge1 = z2_02 (die_a) + z2_03 (die_b), SSH via mapstone-dev ProxyJump; JTAG for all boards on mapstone-dev:3121. End-to-end procedure: `docs/BOARD_DEPLOY_RUNBOOK.md` (field-verified, `7e27eb9`).
- **Boards left in a good state** at end of the 2026-06-11 session: bilateral FCSM=4 after re-flash.
- **v33** (old-PHY autocal stack, `e2fefd4`+M12): the M→S data-crossing image; converge loop 3-for-3 at iteration 1 across the closure sessions.
- **v34** (`v34-i2-autonomy`, `6e22f98`): the V4 zero-poke image; **staged with manifests** at `~/tidelink_artefacts/v34` on mapstone-dev (image canary `0x44032190=0x4F420100`). Deploys can use `--manifest`; remote converge needs `DEPLOY_PAIR_NOVERIFY=1`.
- **Next silicon session should run:** (a) live validation of `unjam_fc_node.sh` against a provoked FC-node jam (signature `fs=5 && a2l_lnk=1 && fe_full=0`); (b) optionally re-characterize doorbell/replay duplication for the residual-#7 ticket; (c) nothing V2 — V2 silicon waits on the sim gate and an FPGA build (§6).

---

## 6. Next milestones to a hardware-validatable V2

| # | Milestone | Gate | Notes |
|---|---|---|---|
| 1 | Merge `feat/s2-shared-component` → `feat/phy-refactor`; finish P7 Tier-2 rewrite keeping (or versioning) the VERSION=1 contract | V0/V1 | Removes the pin spread; lint cleanup rides along |
| 2 | Land the S3 swap commits onto `feat/phy-v2-integration` and fill the remaining `g_phy_v2` wiring; **V2 pair simulation green** (`tidelink_top_pair` with `TIDELINK_PHY_V2`, incl. the autonomy tests 10/18/22/24 and buga suite) | **V2** | The decisive pre-hardware gate; only elab is proven today |
| 3 | V2 FPGA build pair (port P8 ODDR shim + P9 word_handoff XDC into the tidelink FPGA targets; F1 `USE_IDELAY=0`), farm build, deploy per runbook | V3-equivalent | First new-PHY tidelink silicon; expect the marginal-eye residual class (#1/#2) to disappear |
| 4 | **V4 zero-poke re-attempt** on the V2 image: flash-only, zero APB, bilateral FCSM=4 | V4 | The L3 stack is already silicon-proven; this isolates the PHY swap as the only new variable |
| 5 | Integrated 30-min bilateral soak, tag, ASIC flist refresh from the shared component (`tidelink_top_full_asic_v2.flist` already drafted) | V5/S6 | Sign-off; replay-dedup (#7) tracked as a follow-on L3 work item, not a gate |

---

*Sources: `PLAN_TIDELINK_INTEGRATION.md`; `AUTOCAL_CLOSURE_2026_06_10.md`; `V4_ZERO_POKE_FIRST_SILICON_2026_06_11.md`; git history of `tidelink-gpio-phy-deskew` (`feat/phy-refactor`, `feat/s2-*`) and `tidelink` (`feat/phy-v2-integration`, `feat/s3-phy-swap`); verilator lint re-run 2026-06-11.*

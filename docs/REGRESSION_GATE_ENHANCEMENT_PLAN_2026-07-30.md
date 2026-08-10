# TideLink Regression-Gate Enhancement Plan — SoC-integration confidence

**Date:** 2026-07-30 · **Base:** `main` @ `18491ef` (consolidated: GUI/onchip + txgen + Option A + 5 silicon-feedback fixes; full `sim_gate` = ALL SUITES PASS)
**Source:** synthesis of 8 independent read-only analyses (6-dimension fan-out + a bonus oracle audit + a PHC deep-dive). Raw reports in `scratchpad/gate_reports/`.
**Status:** proposal for review. NOTHING here is implemented or pushed. No decisions taken.

---

## 0. Executive summary

The goal was high confidence that embedding TideLink in an SoC won't surprise us. The dominant finding, reached **independently by three agents**, is that **today no gate exercises TideLink inside an SoC at all** — every one of the 49 `sim_gate` suites tests it standalone, and the one real-interconnect harness that *did* catch the recent read-pipe / write-drop bugs (`g2_soc_pair`) lives in a consumer repo, pinned a month behind trunk, wired into no CI.

**Single highest-leverage action:** add an **SoC-integration CI gate** — build+sim TideLink *inside* `nanosoc-ethernet-chiplet` (`make elab` + `g2_soc_pair`) against the TideLink commit under test.

**The recurring failure class** ("green-but-blind"): a gate passes with *and without* the bug because the harness structurally cannot reach the failing operating point, or the assertion is on status (`fcsm`/`cal`) rather than delivered data. This shipped the V2 clock-gate bug and hides Fault 2 today.

**Confidence caveat you should hear first:** the current branch `fix/v2-sync-clock-gate` **must not be shipped or built-embedded** — per its own 2026-07-30 addendum the unconditional clock-gate fix **breaks bring-up** (`cal=0, fcsm=1`), and the guard test is blind to that break. See §5.

---

## 1. TIER 0 — CRITICAL (do first; gate integrity + chip-killers)

**T0.1 — SoC-integration CI gate.** [agents: bus, gate-infra, autonomy] Check out `nanosoc-ethernet-chiplet`, bump its `tidelink` submodule to the SHA under test, run `make elab` + the `g2_soc_pair` two-die cocotb proof, and `make asic-flist`. Trigger on any TideLink RTL/flist/interface change. *This is the only gate that tests TideLink as a component of an SoC.* Rationale: `g2_soc_pair` already caught the I2 read-pipe and write-data-phase bugs; it is in no TideLink CI.

**T0.2 — Byte-exact bidirectional delivery as the SOLE liveness oracle.** [agents: autonomy, multi-inst, bonus-oracle] Retire the `fcsm=4`/`cal`-as-liveness pattern. Fuse `v2_pair_sustained`'s every-word check onto the zero-poke bring-up path; require ≥1 tagged burst **each way** read back byte-exact; assert **nothing** on `fcsm`/`cal`/`link_active`. Promote `fpga/hw_regression/zeropoke_proof.sh` (exit 0 iff data crossed) into a HW gate. Corollary (RTL/integration contract): **`link_active` must be driven by `tl_data_mode_o` (FCSM≥4), not `role_locked`** — the eth-chiplet gates its TX aperture on `link_active`, and role_lock is high before data flows and stays high on a wedged link → TX-into-dead-link → PS hang. Directly closes the hole that makes `zeropoke_por` blind to Fault 2.

**T0.3 — Gate-integrity self-test.** [gate-infra] Before the summary, assert `SIM_GATE_ALL_SUITES` ⇔ the set of invoked targets are identical; fail with a distinct `TALLY/DRIVER DESYNC` message. (`v2_mask_hs_bilateral` was in the tally but never invoked → permanent silent `MISS` — already fixed on main by `aab7f97`, still live on `fix/v2-sync-clock-gate`; this self-test prevents recurrence and catches the `fifo_rx_twin2` uncounted/duplicated drift.)

**T0.4 — Provenance / OOC-param guard exercised in CI.** [addr-map, gate-infra] In CI: `make package_ip TIDELINK_PHY_V2=1`, then (a) assert each shipping `component.xml` param value (not just source-grep — only 3 of ~12 are checked by `check_wrapper_params.sh`), (b) assert `imp/fpga/tidelink_ip/src/*.v` matches `src/rtl` structurally, (c) a post-elaborate reset-value probe that a `CONFIG.*` override constant-folded. Closes the `+define`-never-reaches-OOC / sham-gate class and the stale-checked-in-copy trap.

---

## 2. TIER 1 — HIGH (real holes + weak oracles)

**T1.1 — Restore the DELETED `0x008≡0x208` aliasing test + ratchet an alias golden.** [addr-map, autonomy] The alias is a *real RTL bug* (`Wlink.v:1179-1181` drops `paddr[9:8]`; the 512B map repeats across the 8KB window; `0x008` hits the LL swreset reg; top shim compares full width — decode-width mismatch). Its regression `test_buga_addr_aliasing.py` is **gone (stale `.pyc` only)**. Rebuild it as an exhaustive decode+alias sweep, gate it.

**T1.2 — `ahb_mng` far-slave stall backstop.** [bus] The AHB *master* into the SoC fabric wires far-slave `hready`/`hresp` straight through with **no timeout** (`tidelink_top.sv:2352-64`); a wait-stating/erroring SoC slave wedges the link from the far side with no recoverable bus error. (Addr-map corroborates: the `ext_timeout` watchdog only covers `tl_regs` pready — 1/3 of the aperture.) Needs an RTL backstop **and** a test.

**T1.3 — `tidechart_shim` `device_strap` wiring.** [multi-inst, tidechart-fix] The shim has no `device_strap` port, so the election tiebreak dangles to X → dual-root in every embedding; the one full-SoC election sim passes on *timing asymmetry*, validating the wrong invariant. Add the port (`{7'b0, role_strap_i}`) + a structural "shim drives device_strap" assert + a same-`DEVICE_CLASS` single-root test.

**T1.4 — IRQ-fabric integration test.** [multi-inst] Every SoC TB ties `d2d_irq = 16'h0` — the interrupt fabric is unstimulated above block level. Add a test: each IRQ asserts from a real source, sets the correct NVIC bit, and *drops* after its documented clear; separate the level lines (`released_credits`/`doorbell`, clear-on-read → stuck-high storm risk) from the 1-cycle TideChart edge pulse.

**T1.5 — Promote the ungated CDC/silicon benches + a BLOCKING 40 ns ratio tier.** [clock-cdc, autonomy] `tidelink_cdc_tear`, `tidelink_a2l_replay_cdc` (asymmetric-reset → silicon false-FULL), and `tidelink_fcsm_silicon_ratio` (the 40 ns CRACK stall) are gated in *neither* `sim_gate` nor CI. Also: `epoch_silicon` actually runs at 8 ns (`Makefile:527` omits the ref period) and farm_gate's 40 ns tier is advisory — make one CI job `FARM_GATE_STRESS=1` so a silicon-ratio/eye regression is RED.

**T1.6 — Un-black-box SpyGlass CDC on `axi_chiplet_controller`.** [clock-cdc] `Stop applied` (`CDC-report.rpt:88`) leaves 5/6 boundary crossings (pad clock-gate, RX deskew FIFO, replay-FIFO ACK tear, APB↔LL stretchers, reset crossings) unanalyzed. Remove the stop; add clock edge-lists (`Ac_clockperiod01` currently errors on all 8 clocks).

**T1.7 — Weak-oracle / mutation fixes.** [bonus-oracle] Concrete, cheap: `test_v2_onchip_pair._skip()` registers as PASS (cocotb 1.7.2) → make it a real skip/fail; `test_v2_mask_hs_bilateral::test_01` has no assert; `test_ei_full_sweep` computes SILENT-CORRUPTION but never asserts on it; `fc_adapter test_qos_priority_zero_default` is a vacuous assert. Then formalize the existing red/green scripts into a mutation manifest (revert-the-fix → suite goes RED) run periodically.

---

## 3. TIER 2 — MEDIUM

- **T2.1 PADDR-width elaboration assert** [addr-map]: `tidelink_top.apb_paddr[14:0]` isn't tied to `APB_ADDR_W` — a 12-bit-PADDR consumer silently loses the TideLink + addr-translator register space. Elaboration-time assert.
- **T2.2 PHC/PTP into `sim_gate`** [PHC]: the whole HA1588→servo→PHC hop is ungated (6 suites excluded); promote `eth_ptp_phc_subsystem` (5/5) + a servo-offset convergence check. (Note: `phc_locked` is decorative — tied constant + `PHC_LOCK_GATE_EN=0`; gate on `R_SERVO_OFFSET` as the runbooks already say — memory guidance stands.)
- **T2.3 Reachability manifest** [gate-infra, clock-cdc]: document every silicon operating point × harness (reachable / `Force()`-only / unreachable). Gate: any `Force()` test must cite an entry. Institutionalizes the idle-link lesson.
- **T2.4 RO-write→`pslverr` completeness** [addr-map]: regions 2/3/4/5-7/E accept RO writes with OKAY.
- **T2.5 Reset-sequencing sweep + mutual-clock-enable test** [clock-cdc, autonomy]: stagger the two dies' `poresetn`/`role_lock` deassertion; assert neither die's late-lock silences the peer's RX domain past recovery.
- **T2.6 X-pessimism gate** [gate-infra]: one bring-up suite without `COCOTB_RESOLVE_X=ZEROS`.
- **T2.7 SVA layer** [clock-cdc]: repo has zero SVA; add assertions on the CDC/handshake boundaries.
- **T2.8 Ratchet hardening + consumer flist-provenance gate** [gate-infra, addr-map]: line-independent ratchet keys; assert a consumer's resolved flist matches intended V1/V2 + FPGA/ASIC posture.
- **T2.9 `tc_axis` backpressure, dead-I2C embedded bring-up, re-bring-up-after-drop** [multi-inst, autonomy]: each a distinct light test.

---

## 4. RTL / design findings that are NOT gate work (need David)

These are latent defects/divergences the analysis surfaced — flagged, not fixed:
1. **Two MORE V1→V2 dropped-term divergences** (answer to "find a 3rd") [clock-cdc sub-agent]: deskew-FIFO write-gate dropped `tm_sync1`/`training_mode`; RX word-clock source `~adj_count[3]`→`~count[3]`. Same class as the two already patched. Owed a signoff/parity diff (T-parity gate).
2. **`0x008≡0x208` decode alias** (T1.1) — real bug.
3. **`ahb_mng` no far-slave backstop** (T1.2) — real hole.
4. **PADDR-width not parameterized** (T2.1) — silent-integration trap.
5. **`tidelink_clkfreq_check` is a phantom gate** [clock-cdc] — the freq-mismatch monitor is definition-only, not instantiated in any shipping RTL, yet has a green suite + CI slot. Either instantiate it or delete the gate.
6. **Every chiplet ties `phc_clk=hclk`/`phc_resetn=hresetn`** [clock-cdc] — PHC CDC degenerate today; latent day-1 trap for a TCXO integrator.

---

## 5. DO-NOT-SHIP warning

**`fix/v2-sync-clock-gate`**: the unconditional pad clock-gate fix restores V1 idle-beacon parity **but breaks bring-up** (`cal=0, fcsm=1`, no anchor, two baselines) per that branch's own 2026-07-30 addendum. The `pad_clkgate_idle` guard is green-but-blind to the break (it forces `tx_en=0` and can't reach the calibration window). Do not build embedded images from it. The correct next step there is the two-polarity clock-gate test (idle-beacon liveness **and** a bring-up-quiet guard) before any re-attempt.

---

## 6. Cross-confirmation = confidence

Findings reached by ≥2 independent agents (highest confidence): **no SoC-integration gate** (bus + gate-infra + autonomy); **`link_active` ≠ liveness** (autonomy bus-angle + multi-inst election-angle); **`device_strap` unwired → dual-root** (tidechart-fix + multi-inst); **idle-link structurally unreachable** (clock-cdc + autonomy + the shipped bug). Singletons are ranked lower pending a second look.

## 7. Suggested sequencing
T0.3 (gate-integrity self-test, ~1 hr) → T0.1 (SoC-integration gate — biggest leverage) → T0.2 (delivery oracle) → T0.4 (provenance) → Tier 1. The weak-oracle fixes (T1.7) are cheap and can land alongside anything.

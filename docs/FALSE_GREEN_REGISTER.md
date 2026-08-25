# False-green register — diagnostics that cannot report what they exist to report

**Two independent sweeps, 2026-08-26, merged.** Sweep A covered registers, RTL sticky
bits, sign-off flows and host scripts. Sweep B covered cocotb/UVM pass predicates.
They do not overlap; both are represented here.

**Ranking is by POLARITY first.** A false RED costs time. A **false GREEN ships** —
it is the mechanism by which a real defect reaches silicon while the gate reports
success. Everything in Tier 1 is a false green backing a PASS claim.

Status: **survey only. Nothing here has been fixed.** Do not send anyone to "fix"
an item in the *Unproven* section — a false finding is expensive because it sends
someone to change working code.

---

## Why this document exists

Five broken diagnostics were found by accident over two days. The sweeps that
followed found ~49 more. The pattern is not incidental:

- `git_dirty: false` meant "could not evaluate the tree"
- `TC_ERROR[2] dual_root` has no setter anywhere in the build
- `0x21F8` bit[10] sets on every *healthy* cross-die read
- `kr260_sysval.py` relabelled ssh resets as data mismatches, driving weeks of
  investigation into a defect that did not exist

**Structural fact:** the repo contains **zero SystemVerilog assertions**
(`assert/cover/assume property` returns 0 across `src/ uvm/ cdc/ xprop/ lint/
cocotb/ fpga/ deps/`). Every checker is Makefile scoring, Tcl sign-off, cocotb, or
an RTL sticky bit. There is no formal safety net under any of this.

---

## TIER 1 — FALSE GREEN, backing a PASS claim

### Sign-off flow (would pass a broken chip)

**A1. Calibre reports `LVS INCORRECT` as `LVS CORRECT`.**
`syn/asic/calibre/scripts/run_calibre_lvs.sh:128-131`. `grep -q "CORRECT"` is tested
before `elif grep -q "INCORRECT"`. **"INCORRECT" contains the substring "CORRECT"**,
so the elif is unreachable. *Cannot detect: netlist-to-layout mismatch.*
Verified directly: `echo "LVS INCORRECT" | grep -q "CORRECT"` matches.

**A2. `make fc_drc` cannot fail on DRC violations.**
`syn/asic/fusion-compiler/scripts/7_drc.tcl:357` emits `FC_STAGE_OK: drc`
unconditionally, *after* the `total_violations != 0` branch at `:340-342`. The
Makefile's only gate (`:225-227`) greps for that marker. `gdsii` proceeds.

**A3. DRC sign-off scores a missing or unparseable report as zero violations.**
`7_drc.tcl:121-128` — `grep_count` returns `-1` when the file is absent *or* the
regex misses; `:249-252`, `:262-266`, `:211-212`, `:275-277` coerce `-1 -> 0 -> PASS`.
The fail-closed pattern exists in the same file at `:183-203`, so this is a bug, not
policy. The `pre_timing` block's own comment calls it "THE check that would have
caught the scen_slow zero-uncertainty defect".

**A4. The farm gate's lint ratchet scores a CRASHED lint as "no new findings".**
`fpga/farm_gate.sh:288,300` — `|| true` is correct for exit 1 (findings exist) but
also swallows 2 and 127. `extract_keys` (`:160-162`) parses `path:line: CODE`; a
traceback yields zero keys -> `newf` empty -> pass at `:180`. A *missing baseline* is
handled fail-closed at `:174`; a *crashed* lint is not.

**A5. `verify_build.sh` downgrades unverifiable routed timing to a warning.**
`fpga/scripts/verify_build.sh:443-451`, exits 0 when `NFAIL == 0`. The check exists
because "the 2026-07-16 kr260-pair-ptp build shipped at WNS -2.427 ns (1673 failing
endpoints) and passed verify_build" (`:434-436`). A renamed report restores that.

**A6. Both layers of the Vivado message gate fail open.**
`msg_gate_child_promote.tcl:24,26,28,30,43` — five bare `catch` with no error branch;
a renamed message ID silently installs nothing. Backstop `msg_gate_child_check.tcl:66`
has no `else`; `:86-88` downgrades a `report_drc` failure to a `puts`.

### Verification apparatus

**B1. UVM scoreboards pass on TOTAL PACKET LOSS. CI-gating.**
`uvm/tidelink/env/tidelink_scoreboard.sv:153-157` and
`uvm/tidelink_integration/env/tidelink_integration_scoreboard.sv:144-148`.
Count mismatch is a `uvm_warning`; then `min_size = min(write.size(), read.size())`
and the only `uvm_error` is inside `for (i=0; i<min_size; i++)`. An empty read queue
gives **zero iterations**. Queues are then deleted, so no report_phase backstop can
cover it. CI verdict is `grep -q 'failures="0"'`, which warnings do not trip
(`.gitlab-ci.yml:492`, `:661`).
**The sibling `uvm/tidelink_top_system/.../tidelink_system_scoreboard.sv:203-214`
was fixed on 2026-07-18 and carries a comment explaining this exact bug** — "a
scoreboard that does not fail on packet loss is not a scoreboard". The fix and its
rationale have been in-tree for five weeks and were never applied to these two.

**B2. `tidelink_top_system` scoreboard's unmatched-TX backstop can never fire.**
`:291,293` — `if (a_tx_write_data.size() > 0)` is always false: `report_phase`
(`:263-264`) calls the compare functions, which `.delete()` the queues at `:231/:255`;
their only other exit is an early return taken when the queue is already empty.

**B3. An oracle self-test that cannot go red.** In `sim_gate` twice.
`cocotb/tidelink_top_pair_v2/test_v2_lane_mask_sweep.py:124-140`. The byte-exact
verdict `ok` is never read again. `zeros_ok` compares against `make_packet(...)`, a
compile-time constant with a nonzero header, so it is constant `False` and
`assert not zeros_ok` cannot fire. On the all-zeros RX signature the file itself
names at `:104`, the test PASSES. Docstring: "a suite structurally incapable of
going red would be worthless."

**B4. Five tests bail at 0 ns and report PASS.**
`cocotb/tidelink_top_pair_v2/test_v2_onchip_pair.py`. Both guards are constant-false
for this build: `grep -c s_ref_clk tb_top.sv` = 0 while `TOPLEVEL = tb_top`, and
`TIDELINK_SIM_ONCHIP_MASK_HS` appears nowhere in that Makefile. `_skip()` only logs.
Correct form (`@cocotb.test(skip=...)`) is used in a sibling file.

**B5. `test_v2_mask_hs_bilateral.py:236` — 0 asserts, 0 raises.** Its detection branch
`_log.error("DEAD STUB CONFIRMED ... mask_hs_result_o is hardwired 2'b00")` does not
fail cocotb. Another test points at this module as "the REAL executable guard".

**B6. `make sim_gate` invokes 63 suites and scores 61.**
`Makefile:1779-1780` invokes `sim_gate_a2l_replay_cdc_7/_9`; they are absent from
`SIM_GATE_ALL_SUITES` (`:1665-1677`), which `sim_gate_summary` (`:1849`) iterates.
`SIM_GATE_NONFATAL=1` is passed to every suite so exit codes never propagate.
*Cannot detect: a TL-043-ARR regression on the AR/R nodes — the shipping read path.*
**The commit that introduced this claimed in its message that they were "registered
in SIM_GATE_ALL_SUITES and invoked in the run sequence"; it added them to `.PHONY`
and the invoke list only. The commit whose sole purpose was fixing an unscored-suite
bug reproduced it.**

**B7. `registry_coverage.py` skips its existence check for 7 of 17 gated bugs.**
`scripts/ci/registry_coverage.py:106` — `if files and missing:`. When `sim_test` names
no `.py`, `files == []`, the check is skipped and the bug still counts as covered,
against a docstring promising "must name a resolvable, existing test -> else HARD FAIL".
Affected: TL-020, TL-022, TL-025, TL-027, TL-029, TL-030, TL-034. **TL-027 is the same
family as B6 — the two independent defences fail together on the same defect.**

### Runtime / RTL observability

**C1. `data_nodes_healthy` (0x21E0[23]) cannot latch a wedge while any other channel
is active — and it gates a self-declared P0 BLOCKER.**
`src/rtl/tidelink_axinode_obs.sv:117-127`. The persist counter re-zeroes on **any bit
change anywhere in the 10-bit aggregate** across both faces and all five channels,
but the witness needs 4096 *bit-identical* consecutive cycles. One unrelated handshake
inside any 4096-cycle window resets it. Same aggregate-starvation mechanism already
proven on silicon for the sibling timer (`tidelink_top.sv:1960-1985`: "2035 low / 2
high in 2036 samples"). Its only test stalls one channel with the other nine tied off.
Consumed by `cov_axinode_wedge_gate.py` (P0 gate), `health_snapshot.py`,
`kr260_sysval.py:76`, `kr260_recover_gate.py:113`.

**C2. `LINK_STATUS[4] rx_data_valid` is a hardwired constant, ANDed into the firmware
link-up test.** `src/rtl/local_overrides/Wlink.v:1252` — `out_prepend_5 = {1'h1, ...}`.
Consumer `src/sw/tidelink_chiplet_ctrl.c:99-101` requires TX_ACTIVE && RX_VALID, with
`RX_VALID_Msk` hand-written at `tidelink_chiplet_ctrl.h:135`. **The predicate reduces
to `tx_ready` alone.** Corroborated in-tree by `docs/reference/SHORTCOMINGS.md:169` —
"By every observable register, the link is up. But the test's A->B AHB packet never
reaches B's FIFO." (0x18 = bits [4]|[3].)

**C3. `health_snapshot.py` exits 0 when it could not evaluate.**
`:31-32` — `not present` (0xAD marker absent) makes the whole Region-F term true.
Header claims "Exit 0 if healthy, 1 if a fault bit is set (CI-usable)". The
fail-closed form is in a sibling in the same directory
(`kr260_recover_gate.py:110-111`, "Region-F marker absent (CC-3: not healthy)").

**C4. `kr260_sysval.py` T6_endurance runs its delivery check and discards it.**
`:220-223` — `rc, out = board(B, "verify ...")` then `record("T6_endurance","PASS",...)`
unconditionally. Both are dead at function end (confirmed by AST liveness sweep).
**T6 cannot report a delivery failure at all**, and it writes a JSON verdict artefact.

**C5. `tidelink_clkfreq_check` is a link-safety monitor instantiated in zero design
files.** `src/rtl/tidelink_clkfreq_check.sv:30`; 0 references outside its own file;
present in 1 of 60 flists (its own unit flist). Its green suite protects nothing.
Already recorded as T11 "green-but-blind" in `docs/gate_reports/02_clock_reset_cdc.md:319`.

**C6. The PHC lock interlock is compiled out of every build and its test is unbound.**
`src/rtl/tidelink_ptp.sv:372` gated on `PHC_LOCK_GATE_EN`, which is 0 at every
instantiation site. Only `cocotb/tidelink_ptp/tb_top_gated.sv:70` sets it — and that
file plus `test_tidelink_ptp_lock_gate.py` (6 tests, 16 asserts) are in no flow.
*Cannot detect: HW-SYNC firing before the PHC is locked.* Three documents cite these
tests as coverage.

**C7. A live ECC-corruption counter is skipped because a stale comment calls it dead.**
`pynq_host/scripts/coverage/cov_perf_thresholds.py:311` prints
"SKIP ECCCNT 0x2114 ... DEAD counter (ties 0 in silicon); NOT gated." But
`WlinkEccSyndrome.v:318` now drives a real SEC decode, `Wlink.v:1123-1124` counts it,
and `axi_chiplet_controller.sv:6777` wires it to 0x2114[15:0]. **Both V2 flists pull
the restored file.** The stale belief traces to an RTL annotation at
`axi_chiplet_controller.sv:2920`.

**C8. `stress_lib.py` decodes the SYNC-detected counter as "ECC corrected", and its
unit test locks it in.** `:206-210`. `axi_chiplet_controller.sv:2919` drives
`sync_obs_sync_det_1` there — "Replaces the DEAD ECC-corrected field". On a healthy
link that counter grows and saturates, so **`ecc_corrected_saturated == True` is the
signature of health.** Every other consumer was updated. `tests/test_stress_lib.py:69`
asserts the wrong decode, so the suite is green. Feeds the live stress dashboard.

**C9. `eth_tlapb_poke.py syncdiag` prints lane_fault under the label lane_locked.**
`:68` — RTL is `[15:8] lane_fault`, `[7:0] lane_locked`
(`axi_chiplet_controller.sv:2903-2904`). **The more lanes have failed, the more
"locked" it reads.** `cal_done` is also read from the wrong field.
`throughput_gui/regmap.py:199-219` is the correct reference decoder.

**C10. `xprop/` never runs, and would score PASS with the tool missing.**
`grep -c xprop .gitlab-ci.yml` = 0. `xprop/Makefile:26-31` discards the sub-make exit
code after a pipe and decides by a case-sensitive absence-grep for `FAIL\|ERROR`;
GNU make emits `*** Error 127`, which does not match, so a missing `vc_formal` writes
`PASS`.

**C11. Two host test scripts always exit 0.**
`pynq_host/test_loopback_pair.py`, `test_single_instance.py` — the `failed` counter is
computed and only printed; zero `exit`/`sys.exit` calls in either (AST-verified).
Contrast `test_td_artifact.py:208`.

---

## TIER 2 — proven dead terms, smaller blast radius

Ranked below Tier 1 because a co-located assert or the exit path still catches the
real failure. All mechanically proven.

| # | Location | Mechanism |
|---|---|---|
| T1 | `test_32_die_a_first_zombie_retry.py:264` | `assert ST_TRAIN_DONE in m_states or train_ok_seen` — `:260` already forced `train_ok_seen` truthy, no await between; the named failure is exactly what it cannot detect. Gated. |
| T2 | `test_v2_autonomous_sync_detect.py:433` | `_read_lock_thresh_eff` returns `(w & 0x7)`, so the first disjunct never decides; a lane-0-only override passes. Gated. |
| T3 | `tidelink_fifo/test_tidelink_fifo.py:802` | "Credit underflow!" checks `< 0` on an unsigned `logic [RAM_ADDR_W-2:0]`; a real underflow wraps positive. Gated. |
| T4 | `test_v2_xhb_lostresp_pipe.py:262`, `test_v2_xhb_window_stall.py:84` | Asserts a TB-deposited value on a signal `tb_top.sv:1136-1137` declares with no procedural driver. Gated. |
| T5 | `debug/wlink_pair/test_multi_recal_count_phase.py:167,170` | `x>=5 or x>=4` ≡ `x>=4`; docstring claims it gates on LINK_DATA, so a DUT wedged at LINK_IDLE passes. |
| T6 | `test_18_bug_n7_priority_deadlock.py:286` | `resolved` is the identical expression re-read at the same sim time, no await between. |
| T7 | `debug/phy_align/test_credit_path_observability.py:254,314` | Saturation check tautological — accessors already mask with `0xFFFF`. |
| T8 | `test_best_of_sweep_compare.py:263` | `_lane_field` masks to the asserted range; the code comment concedes it. |
| T9 | `test_wlink_tx_pstate_deadlock.py:203` | `final = trajectory[-1]` makes the real predicate "not low on literally all 1000 cycles". |
| T10 | `tidelink_deskew_bubble/test_deskew_bubble.py:212` | The block labelled "REGRESSION GATE" is implied by asserts at `:195`/`:204`. |
| T11 | `tidelink_lane_deskew/test_lane_deskew.py:894,1403` | `verdict()` only prints; plus literal `assert True` at `:1346,:1433`. |
| T12 | `wav_d2d_gpio_tx/test_wav_tx_training_mux.py:211,262,319` | Three tests, 0 assert / 0 raise; wrong-answer branches are `_log.info`. |
| T13 | `uvm/tidelink_ptp_chain/.../scoreboard.sv:202-208` | One-sided `> threshold` while non-convergence is defined two-sided; negative divergence unreachable. |
| T14 | `pynq_host/overlay.py:365-395` | Docstring's check 2 (`credits == MAX`) is never performed; `_snap()` at `:272-274` is dead code. |
| T15 | `throughput_gui/gates.py` `sample_excursion` | `if fcsm is None: return None`, and None means healthy — a sample missing `fcsm` reads clean. |
| T16 | `crc_diag/crc_common.py:142` | Both branches manufacture the expected value: one re-reads a net already established as 0, the other reads its own `Force(0)`. |
| T17 | `debug/phy_align/test_capture_timing_margin.py:158` | The sole assert of the dead-lane negative control never executes — `mask == 0 -> return`, and the Makefile scopes its only default to a different module. |
| T18 | `tidelink_fc_adapter/test_buga.py:388` | Second disjunct unconditionally true: `tl_fc_a2l_ready` is a TB-driven input set to 0 at `:374` with no write between. |
| T19 | `tidelink_v2_smoke/test_tidelink_v2_smoke.py:101` | `assert not d2d.is_resolvable or int(d2d) in (0,1)` is **inverted** — the X case is exactly what passes. |

### Tier 2 — false RED (costs time, does not ship)

| # | Location | Mechanism |
|---|---|---|
| R1 | `hwtest/lib/lib_hwtest.sh:192` + 3 more sites | 3-bit FCSM field read with a 4-bit mask. RTL: `[19:17]` fcsm, `[20]` `a2l_replay_app_valid`. When bit[20] is set, fcsm decodes 12/13 and `tt_verify_link_up` aborts a healthy link (`exit 3`). 36 other sites use the correct `& 0x7`. Also `stress_lib.py:191`, `wlink_probe.sh:134/150`, `eye_sweep.py:216`. |
| R2 | `stress_lib.py:162` | `link_idle = (fcsm_state == 0)`; LINK_IDLE is state **4**. Feeds the `health_alarm` kill-switch, which fires only on a transition — so an already-wedged link is never flagged (false-green) while bit[20] toggling trips it (false-red). |
| R3 | `kr260_recover_gate.py:118-119` | Consumes the known bit[10] false-red as a PASS criterion; can fail on a healthy recovered link. |
| R4 | `src/rdl/tidelink_regs.rdl:487,490` | `NEGO_TRAIN_CFG` off by one bit on two fields vs `axi_chiplet_controller.sv:3640-3641`. Latent: no generated header is checked in. |

---

## UNPROVEN — do NOT send anyone to fix these

Each carries the one measurement that settles it.

- `WEDGE_LOG2 = 12` vs real cross-die latency (`tidelink_axinode_obs.sv:44`). C1's
  starvation makes the counter almost never reach any threshold, so the two defects
  have **opposite polarity and starvation wins**. *Settles it:* ILA of `stall_live_q`
  during a healthy cross-die read.
- `sim_gate_dftelab` (`Makefile:1655-1657`) — absence-grep with no must-be-present
  control. *Settles it:* grep the produced log for a module known to be instantiated.
- `tidelink_addr_translator.sv:105` — empty `default:` arm. *Settles it:* trace whether
  `i_pslverr_mux` has a default assignment above the case.
- `cocotb/tidelink_fifo/test_tidelink_fifo.py:59-62` — `safe_int` resolves X/Z to 0.
  Safe for non-zero expected words. *Settles it:* whether any expected word is 0.
- `verify_build.sh:229-234`, `:418-421` — both can produce a PASS from an empty parse.
  *Settles it:* a positive control.
- `test_doorbell_with_new_phy.py:154,172` — fallback disjunct has no baseline.
  *Settles it:* log master RESP_ACC before `:150`.
- `test_credit_path_observability.py:245,249` — degenerates to `rd == 0` if no ECC
  errors are injected. *Settles it:* log `raw_corrupt`.
- `tidelink_rxclk_buf/test_rxclk_buf.py:107,144` — under
  `+define+TIDELINK_RXCLK_NO_PRIMITIVE` both generate arms may be identical.
  *Settles it:* read the "child names" line the test already prints.
- `test_bit_order_canary_fail.py:181`, `test_31_autonomous_training_exit.py:515`,
  `test_multi_recal_count_phase.py:133`, `test_hw_regression_gates.py:161`,
  `weekend/campaign_iter.py:277`.
- ASIC-line divergence: `deps/` was unpopulated in the sweep worktree, so the ASIC
  flist's resolved `axi_chiplet_controller.sv` was not diffed against
  `local_overrides/`.

---

## RULED OUT — do not re-flag

`SramContents.verify`, `_check_tap`, `check_present_off` assert internally.
`_obs()`/`_sigint` return `-1` on X/Z, so `>= 0` and `in (0,1)` are genuine
X-detectors. `entered_hold_*` and `wdog_fired_at` are `-1`-sentinelled.
`cov_auto_anchor_verify.py:145-147` fails closed on NO-READ. `kr260_eth_regress.py`
HYGIENE interlocks, `regf_healthy`, `kr260_onchip_autonomy._criteria` are sound.
`tt_summary` returns 1 on any failure. `test_v2_p1_gate_recovery.py` and
`test_v2_sync_midpacket_noloss.py` are `skip=True` — SKIP, not PASS.
Repo-wide AST scan for asserts swallowed by a broad `except`: **zero hits**.
`fifo_rx_twin2` invoked-unscored at `Makefile:1792` is **deliberate** (`:1553`).

---

## NOT COVERED by either sweep

- `.gitlab-ci.yml` (58 KB, 40 jobs) — `allow_failure:`/`when:` semantics unexamined,
  and a plausible home for more of this class. Note `origin` is GitHub-only with no
  `.github/`, so whether those jobs still execute at all is **unknown**.
- UVM sequences, drivers and monitors (only the 7 scoreboards were read).
- Individual `hwtest/*.sh` bodies (~55; the shared lib and its call sites were read).
- SystemVerilog assertion properties in `src/rtl` — moot, there are none.
- No simulation, elaboration or lint was executed. **This is a static audit.**

---

## The rule this register exists to enforce

**Before trusting a diagnostic, prove it can produce the FAILING verdict.**
Arm it against an invented specimen. If you cannot make it go red on demand, it is
not yet a check — it is decoration that reads like one.

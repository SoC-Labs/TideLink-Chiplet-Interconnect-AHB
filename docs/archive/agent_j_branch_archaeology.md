# Agent J — Branch Archaeology for the Calibrator M→S Asymmetry Bug

**Date:** 2026-05-26
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix`
**Branch:** `feat/calibrator-bug-fix`
**Mission:** Catalogue the prior debug context, failed fix attempts and notes
relevant to the `AUTOCAL_ENABLE=1` M→S sideband-stuck bug observed in
`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`. Read-only.

The expected `docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` referenced in the
mission does NOT yet exist in this worktree — likely a placeholder the next
agent is meant to write. The two closest existing handoffs are
`docs/TIDELINK_TOMORROW_SESSION_HANDOFF.md` (2026-05-25, pre-tdif-03 era,
since SUPERSEDED) and `docs/TIDELINK_HANDOFF_2026_05_25.md`.

---

## 1. Calibrator / autocal / asymmetry commits in the last ~8 weeks

Branch annotations:
* **l4-l11** = `feat/td-interface-debug-l*` (this is the layered fix stack
  that converges at `feat/td-interface-debug-l11-byte-align` HEAD on `td-l4-option-c`)
* **sim-pair** = `feat/sim-tidelink-top-pair-regression` (current main of
  this calibrator-fix worktree)
* **i2c** = `feat/i2c-autonomous-lock-integ`
* **phy-audit** = `feat/td-phy-design-audit` (lives under `td-l4-option-c`)
* **phc-*** = the b18-b25 PHC bring-up branch chain (now upstream)

| SHA | Branch | One-line | Status |
|---|---|---|---|
| `0a538de` | sim-pair | cocotb(tidelink_top_pair): fix bringup, add hierarchical probes (autocal-mode test setup) | LIVE — this branch is rooted on `0a538de` via merge `7fa1ea5` |
| `0e92731` | sim-pair | `make sim-regression` paired-die HW-symptom regression target + README | LIVE |
| `7380968` | l4-l11 (td-l4-option-c HEAD path) | td-l11-byte-align: re-arm WavD2DGpioRx T3A + count on training_mode RISING EDGE | LIVE on td-l4-option-c worktree but DEFAULT-OFF |
| `d2a9f8b` | sim-pair (HEAD path via 6d5877c chain) | L11: default `T3A_REARM_ON_TRAIN`=0 — undo tdif-18 HW regression | LIVE — restored baseline |
| `6d5877c` | sim-pair worktree-agent | fix(WavD2DGpioRx L11): EDGE-trigger T3A re-arm (replaces level gate) | LIVE in sim branch |
| `754cc1e` | sim-pair worktree-agent | WavD2DGpioRx L11: add `T3A_REARM_STYLE` selector (edge vs level) for A/B/C sim harness | LIVE in sim branch |
| `992a124` | sim-pair worktree-agent | fix(WavD2DGpioRx L11 EDGE): separate count-hold from FSM-rearm gates | LIVE in sim branch |
| `24681d8` | calibrator-fix (this branch) | L11 EDGE-trigger fix ported from sim branch — tdif-20 target | LIVE in this branch (head-1) |
| `7fa1ea5` | calibrator-fix HEAD | merge: feat/sim-tidelink-top-pair-regression for calibrator debug | LIVE — this branch HEAD |
| `eccd7ea` | l4-l11 | `bringup_pair_converge`: add slot0=0x0 release step (ILA-confirmed root cause) | LIVE — SW fix; necessary not sufficient |
| `8783885` | l4-l11 (L10) | td-l10-credit-bootstrap: clamp `fe_*_credit_max` load to `8'h1f` when CR/CRACK arrives with WC=0 | LIVE in stack — addresses second-CRACK race |
| `a17f694` | l4-l11 (L9) | td-l9-watchdog: time-bounded `bringup_forgive` (4096-cycle watchdog) | LIVE in stack |
| `9bbb4d6` | l4-l11 (L8) | td-l8-link-data-trigger: forgive send_ack_req + SW pump for post-L7 wedge | SUPERSEDED by L8v2 b33ca82 |
| `b33ca82` | l4-l11 (L8v2) | td-l8v2: narrow `send_ack_req` mask — only spurious l2a_raddr_update gated | LIVE in stack |
| `07af0c1` | l4-l11 (L7) | td-l7-nack-recovery: forgive `send_nack_req` during bringup credit window | LIVE |
| `151bdbb` | l4-l11 (L6) | td-l6 producer-side: minimum CR-emit hold in FCSM state==1 | LIVE — closes 12/12 fuzz |
| `d7cde38` | l4-l11 (L5) | td-l5-whitelist: gate `first_short_pkt_seen` on SWI bringup data_id whitelist | LIVE |
| `1353f83` | l4-l11 (tdif-12) | revert L3 `T3A_CONTINUOUS` to 0 (T3A=1 caused HW lane-lock regression on tdif-11) | LIVE — reverted L3 |
| `aa87881` | l4-l11 (tdif-03) | per-lane word-aligned training-mux latch inside WavD2DGpioTx | LIVE — closed bidirectional handshake |
| `5477e60` | td-interface-debug (tdif-02) | word-aligned mux transition for training→FC data (wrapper-level) | LIVE but inferior to per-lane aa87881 |
| `e1af414` | l4-l11 (L4 option (c)) | hold `llrx_reset` for full training window (producer-side gate) | LIVE — superseded prior 92c2ec7 |
| `92c2ec7` | tdif-08-L4-attempt | WlinkRxLinkLayer override with `first_short_pkt_seen` gate | SUPERSEDED by e1af414 (consumer-side approach abandoned) |
| `7a6427d` | tdif-bisect-ll-rx | pinpoint asymmetric bug at slave LL_RX FRAMER | LIVE — diagnostic, no RTL |
| `289bb42` | l4-l11 (L1+L2) | L1=swi_delay_cycles=0 PSTATE fix + L2 swreset cycle | LIVE |
| `b6951d4` | phc-trigger-register-b17 | register `hw_sync_trigger` — fix "master-TX-stuck" | INERT — symptom unchanged on b17 |
| `0221743` / `e27827c` | phc-handshake-fix-b18 | b18 asymmetric handshake fix + WHS hold fix | INERT — symptom unchanged on b18 |
| `cc37dec` | phc-slave-rx-fix-b20-ish | b19 MINIMAL handshake + WHS XDC | INERT — symptom unchanged |
| `51f53d0` | phc-slave-rx-fix-b20 | b20 slave-RX replica defence | INERT |
| `215030f` | phc-manual-replicate-b21 | b21 MANUAL per-consumer FF replication of `ptp_enable_r` | INERT — symptom STILL present, fed Agent J |
| `167923a` | phc-pair-fpga-models / pre-b18 | b13 byte-identical M/S baseline + `dont_touch` ptp_enable_r + `keep` rx_accept | LIVE BASELINE — referenced repeatedly |
| `c6c56c2` | phc-rx-counters (b24) | rx_accept = ptp_sp_rx_valid (decouple from ptp_enable) | INERT — Phase-0 obs proved bug is BELOW PTP |
| `5633c69` | (sub) — calibrator §9.7 | per-lane slip×phase sweep + per-lane phase to PHY | LIVE — this IS the calibrator |
| `0d85843` | sub (now in 17160eb) | calibrator best-of-sweep widest-eye latch (replaces first-match-wins) | LIVE — fixed marginal-lane lock-oscillation |
| `c86f17b` | sub | fix(§9 calibrator): `tb_early_exit_force_q` bypasses S_HOLD in sim | LIVE — restored 3 broken integration tests |
| `0d85843`/`c86f17b`/`5633c69` lineage | sub | calibrator FSM canon ARM→SWEEP→FINISH→HOLD→DONE→CANCEL | LIVE |
| `28f1312` | (sub) | rtl: HAL cosmetics in phy_align_calibrator (Bug #16) | LIVE |
| `a0df658` | (sub) | rtl(calibrator): `unique case`→`case+default` synth-safety | LIVE |
| `65472ff` | calibrator CDC fix | CDC fix in calibrator + addr_trans cleanup | LIVE in main (then REVERTED b7de2d4, then re-applied piecewise — see Note A) |
| `b7de2d4` | revert path | Revert "rtl/lint: CDC fix in calibrator + addr_trans cleanup + docs" | REVERT exists in history; final state depends on which branch |

> Note A — the calibrator CDC change has had a churning history (`7cb67ee` wip → `65472ff` apply → `b7de2d4` revert → `4e693b5` re-apply REFERENCE banner + cocotb lint inclusion). It does NOT touch the calibrator FSM behaviour, only the SpyGlass CDC structure around it.

---

## 2. Failed-fix attempts — postmortems

### 2a. PHC b18-b25 chain (FALSIFIED FAMILY)

Six builds (b18, b19, b20, b21, b22, b23 and b24) each proposed a different
synth-pruning/replica fix for `ptp_enable_r` or `rx_accept`. **All landed on
silicon. All produced the SAME symptom.** Phase 0 obs (2026-05-24) then
proved the bug is BELOW the PTP layer (PAIR_CREDIT_COUNTER=0 on both sides),
so every PHC build in this family was attacking the wrong layer. Memory
`project_tidelink_interface_fcsm_bug_2026_05_24.md` is explicit: "All b18-b25
PTP fixes were chasing a downstream symptom".

Lesson: any fix the calibrator-fix branch proposes MUST first verify
`PAIR_CREDIT_COUNTER ≠ 0` and the slave's `cr_pkt_seen_rx` sticky bit BEFORE
declaring the symptom is gone.

### 2b. tdif-01 "skip bringup_pair_converge.sh" — POR-only path (PARTIAL)

After 2026-05-24 ILA showed POR state has `slave fcsm=4 LINK_IDLE, llrx_valid=1`
already half-handshaked, hypothesis was that bringup script's slot0=0x3 recal
ACTIVELY BREAKS this. Path: deploy, do NOT run convergence script, ring
doorbells. **HW test agent `ab27205e520a41250` / retry `a311bc49ab69159e0`
reported back: doorbells still don't cross.** POR-half-handshake is real but
not sufficient. Falsified the simplest-possible SW-only fix.

### 2c. tdif-02 wrapper-level word-align mux (PARTIAL)

`5477e60` — added a mirror counter at WavD2DGpio level that flips the
training→FC mux only at `count==0`. **HW result: slave LL_RX is now ACTIVE
(`is_short_pkt=1, llrx_valid=1`) but master `cr_seen=0`.** Asymmetry flipped
sides. The wrapper-level mirror counter can't track 8 per-lane counters
independently. PARTIAL — proved the byte-align hypothesis but needed a
per-lane fix.

### 2d. tdif-03 per-lane word-align (CLOSED HANDSHAKE — major step)

`aa87881` — per-lane `io_training_mode_q` latched on the lane's own
`count==4'hf`. **HW result: bidirectional CR/CRACK exchanged, M=4 LINK_IDLE,
S=7 SEND_NACK, BOTH `RETURNER_BUSY=1`, BOTH `rx_data_valid=1` BUT
`PAIR_CREDIT_COUNTER` still 0/0 and doorbells still don't cross.** The PHY
handshake is fixed; the bug retreated up one layer to FCSM/credit.

### 2e. L5 first_short_pkt_seen consumer-side gate (`92c2ec7`)

Consumer-side approach in `WlinkRxLinkLayer`: ignore long-pkt SOPs until
first valid short-pkt seen. 5/12 fuzz scenarios PASS — **superseded** by L4
option (c) producer-side gate `e1af414` (hold `llrx_reset` for full training
window). The consumer-side approach didn't address the failure mode where
slave's framer wedges in state==1 with a fictional long-pkt before any
short-pkt arrives.

### 2f. L8 v1 `send_ack_req` blanket forgive (`9bbb4d6`)

First L8 attempt OR'd a broad `socl_l7_bringup_forgive` mask into
`send_ack_req`. tdif-14 regressed (`{M=2, S=1}` FCSM state). **Self-
defeating-gate class of bug**: forgive depended on `reached_link_data` which
required state 5, which required forgive=0. Superseded by L8v2 (`b33ca82`)
which narrowed the mask to only the spurious `l2a_raddr_update` path.

### 2g. tdif-11 L3 `T3A_CONTINUOUS=1` (`1353f83` revert)

L3 with `T3A_CONTINUOUS=1` ran T3A re-arm in a bounded-DWELL=63 loop. **HW
result: lanes failed to lock 12 re-deploys in a row.** Reverted to 0; the
bilateral leak L3 was trying to address is now solved at higher layers by L5
data_id whitelist + L6 producer-fix. T3A=1 path is now unused.

### 2h. tdif-18 L11 LEVEL-gated `io_train_rearm` (`7380968` then defaulted off)

L11 wired the override's `io_train_rearm` input (Hole #1 of the PHY audit) as
a LEVEL gate from `cal_training_mode`. **HW result:** `dbg_llrx_reset_out=1
for ALL 4096 ILA samples on both dies, fcsm_state=1 (SEND_CREDITS1) stuck,
cal_done=0, lane register 0x00020000`. The level gate forced T3A back to
S_SETTLE EVERY cycle for the entire training window (thousands of cycles),
`count` held at `4'hf`, deserialised data permanently garbage, calibrator
never finds a winning (phase,slip), training_mode permanently high,
Option (c) gate holds `llrx_reset` high forever.

Fix `6d5877c` + `992a124`: convert to edge-triggered single-cycle pulse using
a 3-flop sync. Sim A/B/C in `test_07_lottery_multi_iter`:
- A (L11 OFF baseline): `0/3 stuck_at_link_idle`
- B (L11 ON LEVEL legacy): `0/3 cal_done_timeout` (regression repro)
- C (L11 ON EDGE fix): `0/2 stuck_at_link_idle` — same as A, safe

**EDGE fix `24681d8` is the current top-of-tree on this calibrator-fix branch
and is the tdif-20 candidate** — it has not yet been HW-validated.

### 2i. b21 named `ptp_enable_r` per-consumer replicas (`215030f`)

Manual fix for the synth-pruning class: `ptp_enable_r_tx_consumer` and
`_rx_consumer` with `(* keep *)(* dont_touch *)`. **HW result: symptom STILL
present** — the divergent FF is further down the cone, instantiated by P&R
itself. Proved Agent J's b24 decoupling was the right next step BUT (per
Phase 0) bug is below PTP entirely.

---

## 3. Insights from other worktrees' docs

### `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c/docs/PHY_DESIGN_AUDIT_2026_05_26.md`

This is the load-bearing audit. Authored after 17 FPGA builds and the
tdif-03/tdif-18 cycle.

**Top 5 design holes** (in PHY chain):

1. **Hole #1 — T3A re-arm port is dangling.** Quote:
   > `src/rtl/local_overrides/WavD2DGpioRx.v` declares an input
   > `io_train_rearm` ... **No parent module drives this input.** A `grep`
   > across `src/rtl/` and `fpga/` finds it only in the override file itself.
   > ... the mechanism is inert in every silicon build to date. **The
   > override's `T3A_REARM_ON_TRAIN=0` default also gates the synthesis
   > branch out — so even on FPGA, we are not getting the rearm.**

   This is the structural mechanism behind the Phase-0 §11 "POR-active state
   is broken by bringup_pair_converge.sh" finding.

2. **Hole #2 — T3A `S_LOCKED` is sticky with `T3A_CONTINUOUS=0`.** Even if
   Hole #1 is fixed, FSM only re-arms via async `io_por_reset` on default
   `T3A_CONTINUOUS=0`. Quote: "A level-triggered, training-mode-gated re-arm
   (Hole #1's `io_train_rearm`) is strictly safer than a free-running bounded
   re-arm — both paths deserve to exist, with `io_train_rearm` as the
   primary and bounded continuous as a fallback."

3. **Hole #3 — TX→FC mux flip is word-aligned but FC→training is not.** TX
   per-lane `io_training_mode_q` flops sample on `count==4'hf` (the tdif-03
   fix), but the wrapper-level `effective_training_mode_tx` is raw
   combinational. Each lane has a different mod-16 phase.

4. **Hole #4 — Recovered-clock CDC is undocumented and only partly synced.**
   `io_swi_bit_slip_in / io_swi_phase_offset_in / io_swi_training_mode_in`
   from calibrator (`apb_clk`) to per-lane RX deserialiser (`w_cnt_clk`) are
   NOT synced anywhere. Combinational into RX deserialiser; `_link_data_rep`
   is recomputed combinatorially — **"A glitch on `bit_slip` during a
   `count[3]` edge can cause a 1-cycle wrong-byte output."**

5. **Hole #5 — `count` initial phase is non-deterministic across master/
   slave.** Both TX and RX `count` reset to `4'hf` on async POR through
   separate WavResetSync flops, so master TX's `count` and slave RX's `count`
   start with arbitrary 0..15-cycle phase. T3A corrects this **once**.

**Section §4 plain-English mechanism (9 steps)** explains how the
calibrator's sweep changes `bit_slip`/`phase_offset` non-zero at the moment
training falls, the deserialiser's `count` is still at POR-set phase, and
post-recal byte boundary on the wire has shifted but `count` register
defines a different 16-bit-word boundary. The **training bytes happen to
look identical under any `count` phase** (period-8 within the byte + {P,P}
double-fill), so the misalignment is undetectable during training and
catastrophic during FC data.

**Section §6 robust fix design**:
- Fix-A — wire up `io_train_rearm` (Hole #1). "Highest ROI."
- Fix-B — explicit RX `count` reset on training rise.
- Fix-C — calibrator must hold `bit_slip`/`phase_offset` stable across
  training rise/fall (Hole #4). Add output registers on calibrator outputs;
  latch on `S_FINISH` entry, hold through `S_HOLD`/`S_DONE`.
- Fix-D — explicit 2FF sync on calibrator → PHY signals.
- Fix-E — deterministic `count` startup via APB `PHY_COUNT_SEED[3:0]`.

### `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c/docs/TIDELINK_L9_TIDELINK_FC_ASYM_2026_05_26.md`

The key reinterpretation: `wlink_probe.sh` header comment says `[0x08]` is
"activity bit (1=traffic)" but RTL says it's `a2l_fc_replay.fifo.rempty`.
**Therefore `M[0x08]=0` actually means "master HAS pending app TX queued",
not "master is inactive".** All prior agents read this backwards.

Six hypotheses tabulated; H-1 (master FCSM_6 oscillating 4↔6 due to
re-arming `send_ack_req`) was strongest. Time-bounded forgive (L9 watchdog,
`a17f694`) was the proposed RTL fix — landed but is downstream of the L11
PHY layer issue.

### `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c/docs/TIDELINK_PHASE0_OBS_20260524_2109.md`

§11 root-cause analysis: **ASYMMETRIC slave LL_RX byte-alignment loss** at
training→FC-data mux transition. The per-lane mux at
`deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v:43-45` flips
MID-WORD when `effective_training_mode` falls 1→0. Slave's `llrx/state=iSTATE`
STUCK forever. Master is fine.

§12 tdif-02 result: wrapper-level fix made slave RX active but master RX
went blind (asymmetry flipped). §13 tdif-03 per-lane fix closed the
handshake; remaining blocker moved one layer up to FCSM/credit.

### `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c/docs/TIDELINK_TOMORROW_SESSION_HANDOFF.md`

Pre-tdif-03 handoff — superseded by the PHY audit. Sections "Critical
guardrails" and "Decision tree for next session" still valid in spirit.

### `/home/dam1n19/SoCLabs/td-calibrator-fix/cocotb/tidelink_top_pair/README.md`

Documents the SIX-test deterministic HW-symptom repro:
- test_01-test_03 PASS (lane lock + training drop + CR/CRACK latch)
- **test_04 FAIL** — `PAIR_CREDIT_COUNTER = 0`
- **test_05 FAIL** — M→S doorbell stuck
- test_06 PASS — S→M doorbell crosses (THE asymmetry — sim faithfully
  reproduces HW shape)

`watch_fc_pulses` localises the cut:
- `M.a2l = 0` → master FC adapter never submits the packet
  (returner/credit/skid path bug)
- `M.a2l > 0, S.l2a = 0` → packet dropped on the wire (Wlink TX/RX, lane
  decode)
- `S.l2a > 0, RESP_ACC stays 0` → slave's RX consumer dropping the packet
  (sideband decode → APB regs)

---

## 4. Known dead ends (memory + history explicitly rule these out)

1. **PHC PTP cone-replication (b18-b25)** — bug is BELOW PTP.
2. **Master TX FSM stuck** — Agent A; ILA shows `sp2wl/tx_valid` pulses.
3. **BD address-map asymmetry slave-side** — byte-identical M/S BD audit.
4. **Reset-release race rx-link** — synchroniser audit + multiple reset sweeps changed nothing.
5. **Slave LLRX disabled / config gap** — verified live via APB.
6. **CR/CRACK directional asymmetry as primary cause** — bidirectional CR loopback fine after tdif-03 per-lane fix.
7. **Hardware-specific (board, cable, IDELAY skew)** — symptom tracks role, not board.
8. **`swi_enable=0` transient in `to_data_mode`** — falsified on HW (FIX script `sw_coord_autocal_region8_FIX.sh` didn't fix it).
9. **`WlinkTxPstateCtrl` circular dep deadlock** — proven at unit but FSM never enters state 2 in this scenario.
10. **FCSM TX router stops post-drop** — instrumented sim shows 214 tx_advance pulses post-drop.
11. **`sp2wl dataIdMatch=0` as a second bug** — correct by design; sp2wl is PTP-only.
12. **TideLink FC channel disabled on master (L9 H-4)** — all channels share `swi_enable`.
13. **`fe_rx_credit_max` init race specific to TideLink (L9 H-5)** — same upstream RTL path as AXI; would affect both.
14. **bringup script leaves something untriggered (L9 H-6)** — script orchestration leaves `swi_enable=1 + lltx_enable=1` final.
15. **L11 LEVEL-gated `io_train_rearm`** — caused tdif-18 regression; replaced by EDGE-triggered.
16. **L3 `T3A_CONTINUOUS=1`** — caused tdif-11 lane-lock regression; reverted; no longer needed.
17. **Wrapper-level word-align mirror counter (tdif-02)** — can't track 8 independent per-lane counters; superseded by tdif-03 per-lane fix.
18. **L4 consumer-side gate (92c2ec7)** — superseded by L4 option (c) producer-side hold of `llrx_reset`.
19. **L8 v1 blanket forgive (9bbb4d6)** — self-defeating-gate; superseded by L8v2 narrow mask.
20. **AUTOCAL_ENABLE param propagation** — confirmed (`6071eee`) that `.AUTOCAL_ENABLE(1'b1)` at `tidelink_top.sv:1365` reaches `u_calibrator` on FPGA via instance-level override; calibrator FSM is NOT swept by synth.

---

## 5. What this branch's plan should be informed by

Concrete signal-level intelligence to budget into the calibrator-fix plan:

### 5.1 The bug surface

After the L1-L11 stack and tdif-03's per-lane word-align fix, on real silicon:
- PHY is healthy: 16/16 lane lock, cal_done=1 both sides, ECC counters 0.
- Wlink frame-layer handshake completes (CR + CRACK sticky-set on both).
- FCSMs reach LINK_IDLE (state 4) on both sides.
- `PAIR_CREDIT_COUNTER = 0/0` (load-bearing honest signal).
- M→S doorbells stuck; S→M doorbells WORK (test_06 PASS).
- **Same asymmetric shape now reproduces in cocotb `tidelink_top_pair` —
  6-min iteration vs 50-min FPGA build.**

### 5.2 The cut location is one of three places

Per the `watch_fc_pulses` decoder in the README:

- **A. M.a2l = 0** — master FC adapter never submits packet. Suspects:
  `tidelink_returner.sv`, `tidelink_fc_adapter.sv`, `tidelink_apb_regs.sv`
  `pair_base_addr`, the AHB interconnect between returner and FC adapter.
  Memory `project_tidelink_bug_isolated_2026_05_26.md` proposed that
  `pair_base_addr` APB-init is missing in test (added in `do_role_lock()`)
  — running at memory snapshot time.

- **B. M.a2l > 0, S.l2a = 0** — packet on the wire but slave Wlink RX/lane
  decode drops it. Suspects: L11 byte-align is the most likely culprit
  (still default-OFF on tdif-20-bound `24681d8`); calibrator output glitch
  (Hole #4) is the second-most-likely.

- **C. S.l2a > 0, RESP_ACC=0** — slave RX consumer drops the packet.
  Suspects: sideband decode in `tidelink_fc_adapter.sv`, the returner-side
  AHB write that drives DOORBELL_RESPONSE_ACC update.

### 5.3 What the calibrator-fix branch actually inherits

This branch HEAD is `7fa1ea5` = merge of `feat/sim-tidelink-top-pair-regression`
on top of `24681d8`. That gives:
- L11 EDGE-triggered T3A re-arm (default OFF — `T3A_REARM_ON_TRAIN=0`)
- Lottery harness + stuck-link detector + per-lane skid + fuzz/iter env-var
  hooks
- multi-iter regression target `make sim-regression`

**To investigate the M→S calibrator bug specifically, the most directly-
useful levers already on this branch are:**
1. Set `T3A_REARM_ON_TRAIN=1` and `T3A_REARM_STYLE=0` (EDGE) and check the
   M→S sim with `AUTOCAL_ENABLE=1`. Hole #1 wiring is still missing — that
   wire-up is **the one structural fix** every other agent has landed on but
   nobody has shipped to HW yet in a non-regressing form.
2. Use the `cal_state_name(side)` / `fcsm_state(side)` /
   `watch_fc_pulses(n,label)` probes added in `0a538de` to localise whether
   AUTOCAL=1 vs AUTOCAL=0 changes M.a2l, S.l2a, or RESP_ACC.

### 5.4 Calibrator-output glitch hypothesis (PHY audit Hole #4)

When the calibrator transitions S_FINISH→S_DONE in one apb_clk cycle, the
RX deserialiser sees `bit_slip` change *the same cycle* `training_mode`
falls. Audit §6.3 recommends registering `bit_slip`/`phase_offset` on
`S_FINISH` entry and holding through `S_HOLD`/`S_DONE`. This change is NOT
yet present in the current calibrator RTL (per audit). It is a **directly-
actionable change** for this branch.

### 5.5 The 2026-05-26 "Bug isolated to tidelink_top wrapper" memory

Memory `project_tidelink_bug_isolated_2026_05_26.md` proved by elimination
that `wlink_pair` direct-force experiments PASS bidirectionally with both
sentinels (master→slave `0xDEADBEEFCAFE` and slave→master `0xCAFEDEADBEEF`).
The `Wlink`/`axi_chiplet_controller` layer has NO M↔S asymmetry. The bug is
in something `tidelink_top` adds on top — `tidelink_returner.sv`,
`tidelink_fc_adapter.sv`, the AHB interconnect, or the
`tidelink_apb_regs.sv:pair_base_addr` init.

**This is in apparent tension with the PHY audit's "Hole #1 is the
structural mechanism" finding.** Resolution: both are partial truths.
- The PHY audit is correct in steady-state (a robust HW link needs Hole #1
  fixed for byte-align stability across recals).
- The "wlink_pair pass / tidelink_top fail" sim experiment proves there's an
  ADDITIONAL bug in the tidelink-only glue layer that hides under sim's
  zero-skew deserialiser.

**The calibrator-fix branch should resolve which of these is the immediate
gating bug for sim test_05 by:**
1. Probing M-side returner/FC adapter signals (memory's `next concrete debug
   step`).
2. Running the same sim with `AUTOCAL_ENABLE=0` to see if M→S then PASSES
   in sim — if so, the bug interacts with calibrator output; if not, the
   bug is purely in the tidelink_top wrapper logic.

---

## 6. Files of interest (relative to td-l4-option-c worktree unless noted)

- `docs/PHY_DESIGN_AUDIT_2026_05_26.md` — the audit
- `docs/TIDELINK_PHASE0_OBS_20260524_2109.md` — full HW diagnostic chain
- `docs/TIDELINK_L9_TIDELINK_FC_ASYM_2026_05_26.md` — `[0x08]` reinterp
- `docs/TIDELINK_L6_PRODUCER_FIX_2026_05_26.md` — slave CR-emit min-hold
- `docs/TIDELINK_TOMORROW_SESSION_HANDOFF.md` — superseded handoff
- `cocotb/tidelink_top_pair/README.md` — sim repro user guide (in this worktree too)
- `src/rtl/local_overrides/WavD2DGpio.v` / `WavD2DGpioRx.v` /
  `WavD2DGpioTx.v` — the override stack
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — L6/L7/L8/L10 patches
- `src/rtl/tidelink_phy_align_calibrator.sv` — calibrator FSM
- `src/rtl/tidelink_top.sv:1365` — `.AUTOCAL_ENABLE(1'b1)` instance override
- Memory: `project_tidelink_interface_fcsm_bug_2026_05_24.md`,
  `project_tidelink_sim_repro_2026_05_26.md`,
  `project_tidelink_bug_isolated_2026_05_26.md`,
  `project_phc_phase1_hw_diagnosis_2026_05_24.md`,
  `project_tidelink_idelay_slaveclk.md`,
  `project_tidelink_v1rc1_zerolock_vs_72c280b.md`,
  `project_tidelink_i2c_autonomy.md`

---

*Archaeology by Agent J on `feat/calibrator-bug-fix`, 2026-05-26. Read-only;
no RTL, sim, or submodule files modified.*

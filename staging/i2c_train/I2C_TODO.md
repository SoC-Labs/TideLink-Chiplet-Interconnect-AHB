# I²C Autonomous Lock — Outstanding TODO

State as of 2026-05-20 (late evening, after build #6 bench test).
Branch `feat/i2c-autonomous-lock-integ` @ `d06d495` (pushed), submodule @ `6a757e2` (pushed).

## Headline status

| Capability | Status | Where |
|---|---|---|
| Bug #1 (`nego_driving` gated by `role_locked`) | ✅ Silicon-fixed | sub `467b889` |
| Bug #2 (synth latch on `txn_step_nxt`) | ✅ Silicon-fixed | sub `be5eed2` |
| Bug #3 (missing `default` on `case (state_r)` collapsing mask gate) | ⚠️ Structural fix applied, **partial silicon improvement** but `hs_result=0` still | sub `6a757e2` |
| Autoneg arbitration (roles assigned) | ✅ Silicon-confirmed | bench evidence |
| I²C bus electrically functional on P15/P16 | ✅ Confirmed | slave `i2c_addr=1`, `sda_start_seen=1` |
| Mask phase actually writes `hs_result` over I²C | ❌ Still failing on silicon | bench evidence |
| Link training post-autoneg (rx mask) | ❌ Still `0x0000` | wlink_probe |

---

## Phase A — Complete bug #3 diagnosis (CURRENT PRIORITY)

After structural fix (sub `6a757e2`, build #6):
- Master FSM now visits POLL→DONE quickly with won=1 (good)
- Slave sees `EVER i2c_addr=1` consistently (better than build #5)
- BUT `hs_result=0` on slave → master never wrote it via MASK_RES_TX I²C transaction
- AND `hs_result=0` on master too → master's own hs_result also not updated (Fix B 0x21C sniffer)

Hypotheses:
- (a) FSM enters state 9 briefly but exits to DONE without doing MASK_RES_TX
- (b) FSM enters states 9/10 but MASK_RES_TX itself fails silently
- (c) NEGO_TIMEOUT fires too quickly — kills the mask sequence partway through
- (d) Mask_byte_cnt / mask_retry counters have similar synth issues to the latch bug

Next steps:
- [ ] Re-arm ILA on `state_r==9` after fresh POR + autoneg kick. If it triggers → (a) or (b). If not → structural fix didn't take.
- [ ] Re-arm ILA on `state_r==8` (MASK_RES_TX). If never triggers → (a). If triggers → master DOES attempt MASK_RES_TX but the I²C write doesn't reach slave's hs_result.
- [ ] Read NEGO_STATUS bit 9 (mismatch) post-autoneg on master — if 1, mask comparison failed; if 0, comparison may not have run.
- [ ] Check `mask_byte_cnt_r` / `mask_retry_r` declaration sites — apply same default-pattern hygiene as `txn_step_nxt` to be safe.
- [ ] Trigger ILA on `axl_done_r==1` with pre-window — captures every AXIL completion; counting them tells us how many transactions the autoneg actually issued.

## Phase B — Investigate W9/V7 on-ribbon I²C with bugs #1+#2+#3 all fixed

User raised 2026-05-20: original W9/V7 inert test (2026-05-19) was with all 3 bugs present. The "weak pull" attribution was a partial misdiagnosis. Re-test on the fixed bitstream.

- [x] XDC edited in-place on both pair-all + pair-flip-all: I²C → W9/V7 (SDA/SCL with FPGA `PULLTYPE PULLUP` weak internal pull). **Not yet committed.**
- [ ] Build pair-all + pair-flip-all with W9/V7 XDC (~27 min).
- [ ] Stage + deploy.
- [ ] Reconnect ribbon (currently disconnected for P15/P16 testing), confirm 3-wire I²C jumper between Arduino headers is REMOVED, J13 ribbon back.
- [ ] Bench-test: same `run_i2c_test_fast.sh` flow.
- [ ] Expected outcomes:
  - **Best case**: works as well as P15/P16 → single-ribbon I²C ships, no Arduino harness
  - **Worse case**: bus inert → weak-pull WAS a real electrical issue, revert XDC to P15/P16
- [ ] Either way, commit/document the result. If reverting, restore P15/P16 XDC.
- [ ] If both work, consider making formal target variants (`pynq-z2-pair-w9v7-all` etc.) so we ship two pin options.

## Phase C — Full link bring-up post-autoneg

Even with autoneg complete and role-locked, the wlink RX mask is still 0:
- `LaneMask: tx=0xffff rx=0x0000` on both boards
- `idx0=0x55115500` lane-7 guard hasn't been verified
- Link not "up" in the operational sense

- [ ] Run `bringup_autocal_i2c.sh` after autoneg completes — does the link train?
- [ ] If link trains: full operational success (with caveat that hs_result is still 0).
- [ ] If link doesn't train: investigate why (phase calibration, idelay alignment, etc.). May be orthogonal to I²C — see `project_tidelink_fpga_bringup.md` for the related lane-lock work.

## Phase D — Cocotb regression + sim/HW parity hardening

- [ ] Wire `cocotb/wlink_pair/test_hw_repro_probe_seq.py` (agent #1) and `test_hw_repro_full.py` (agent #3) into the default Makefile + CI.
- [ ] Wire `cocotb/wlink_pair_full/` (agent #4 BD-IP harness + post-synth) into CI as periodic (full BD harness is slow).
- [ ] Add a regression test in cocotb that asserts the autoneg's `case (state_r)` has a default — would have caught bug #3 in sim if the case-coverage were checked.
- [ ] Add a regression test that fails sim if any `always_comb` block has a missing default (catches bug #2-like latches).

## Phase E — Documentation + merge

- [ ] Update `docs/SHORTCOMINGS.md` §14a/§14b — promote from "blocked" to "resolved (bugs #1/#2)" + "partial (bug #3 needs phase A completion)".
- [ ] Update `staging/i2c_train/MERGE_HANDOFF.md` with new commits.
- [ ] Decide deploy-script: vanilla `deploy_pair.sh` is now sufficient (bug #1 fix means strap-lock isn't a blocker); retire `deploy_pair_autoneg.sh` or keep as alternative.
- [ ] Open MR feat/i2c-autonomous-lock-integ → feat/fpga-flow once Phase A complete + Phase B decided.

## Phase F — ASIC-side considerations (v1 release)

Per memory note [v1 ASIC target = 100 MHz GPIO PHY], the chiplet ships on ASIC. The structural bug #3 fix (`default:` on case) is ASIC-portable (no Xilinx attributes), which is the right pattern for v1.

- [ ] Verify the autoneg + mask-phase flow works at 100 MHz ASIC apb_clk (vs 50 MHz on FPGA). I²C prescale needs adjusting.
- [ ] Lint-clean the autoneg + chiplet RTL — agent #2's latch fix and the case-default fix removed two synth warnings; ensure no others remain.

## Reference — branch state

| Item | Location |
|---|---|
| Parent integ branch tip | `feat/i2c-autonomous-lock-integ` @ `d06d495` |
| Submodule tip | `feat/i2c-autonomous-lock` @ `6a757e2` |
| Bench artefacts (build #6, structural fix) | `mapstone:~/tidelink_hwval/` |
| Diagnostic TCL | `staging/i2c_train/ila_diag_capture.tcl` |
| Cocotb regression | 33 tests across 7 suites, all green |
| Other agent's integration | `feat/td-combined` (separate lineage, has structural fix + lane-lock work; see [project_tidelink_consolidated_bringup_branch]) |

## Reference — open uncommitted changes in `/tmp/i2c_wt`

- Both pair-all + pair-flip-all XDCs modified for W9/V7 retest (Phase B item — not yet committed/built/tested)

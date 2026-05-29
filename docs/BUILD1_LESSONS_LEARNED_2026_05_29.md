# Build #1 lessons learned — what carries forward to build #3

**Date:** 2026-05-29
**Builds compared:** #1 (overnight, AUTOCAL=1 + original calibrator) → #3 (AUTOCAL=1 + Fix A2+B)
**Status:** Build #1 bitstream is **gone** (overwritten by build #2 then by build #3). All learnings below are derived from live captures + RTL re-reads.

## 1. Static / observed facts from build #1 HW runs

| Observation | Evidence | Implication |
|---|---|---|
| Link reports 16/16 lane_locked | `td_gpio_phy_apb_read.py` shows 0xFFFF mask after autoneg | Calibrator FSM completes and lock-counter saturates |
| AHB single-word doorbell works only with SW retry | `td_doorbell_test.py` succeeds at attempt 2-4 | L7 handshake exists; L1 raw data has BER |
| PTP HW_SYNC packet never delivered | `bringup_ptp_sync.sh` times out 100% on master→slave | PTP has no retry; one corrupted byte = whole packet lost |
| AHB packet stress N≥4 silently wedges master | `bgoljmvgc.output` (this session) | FC adapter never returns HREADY → SmartConnect hangs PS |

## 2. Why the calibrator picked (slip=0, phase=0)

The lane checker exposes `dwell_min_dist_o` — minimum Hamming distance observed during a dwell window. The intent was for the calibrator to pick `(slip, phase)` with the lowest min-distance.

**Bug (root cause):** `dwell_min_dist_o` resets **only on `clear_noise_i` or `training_mode_w_i` rising edge** — NOT per-dwell-boundary. So the register is monotonically non-increasing across the **entire sweep**. Once a single cycle anywhere in the sweep happens to produce a low Hamming distance (which happens trivially at *some* phase because the lane checker tolerates 3 bit-flips), every subsequent (slip,phase) candidate inherits that low value.

**Consequence:** every candidate looks like a "pass" → calibrator latches the first one (the POR default, (0,0)) trivially.

## 3. User's correction that disambiguated the diagnosis

> "There is only one phase of data that should be valid, all the other phases should have a large hamming distance away from that."

This ruled out my earlier "tolerance window" hypothesis. With min cyclic distance 8 on 0x12EB and matcher threshold T=3, only one phase per slot should ever produce distance ≤3. So a calibrator that picks "any" phase is provably broken; the bug must be in the score predicate or score reset, not in the comparator threshold.

## 4. Fixes carried into build #3 (commit 85f0e48 on `feat/td-gpio-phy-integration`)

| Fix | What it does | Why it works |
|---|---|---|
| **A2** — score predicate `lane_locked[i]` instead of `lane_dist_pass_w[i]` | Reverts to per-cycle binary lock signal which resets on every mismatch | Removes sticky-low pathology; every (slip,phase) gets a fresh score |
| **B** — phase-INNER / slip-OUTER iteration | Original sweep order from §9.11 of the spec | Phase changes are quasi-continuous; sweeping phase inside slip lets us see the eye edge before changing slip and re-decoding |
| **AUTOCAL_ENABLE = 1** | `tidelink_top.sv:1895` (unchanged from build #1) | Build #2 forced 0 as a workaround; that didn't help the new 16-bit aperiodic pattern, so we reverted |

The unused `dwell_min_dist_o` plumbing stays in — it's still useful as an **observability** signal exposed via `noise_max_o` registers (per-lane SWI region 8) so the eye GUI can scan in software. The calibrator just no longer **trusts** it.

## 5. Things to verify on build #3 that build #1 couldn't show

1. **Calibrator-chosen `(slip, phase)` is non-trivial** — read `swi_phase_offset_q` + `swi_bit_slip_q` per lane after autoneg; values should match what the eye GUI showed by manual sweep, not all (0,0).
2. **`noise_max_o` per-lane sweep distinguishes phases** — running the eye GUI should produce a single bright phase per lane with the others dark; the build #1 GUI showed 8/16 lock at most because the matcher kept resetting on every clear.
3. **AHB N=1 RX side receives** — build #1 / #2 had RX=0 for everything; build #3 should at least deliver single words bilaterally.
4. **PTP HW_SYNC converges once** — even a single observed `hw_sync_done` cycle confirms FC channel reliability end-to-end at byte resolution.

## 6. Operational lessons (independent of RTL fixes)

1. **AHB writes N≥2 must be guarded** by either (a) link-up gate before each write, or (b) PS-side timeout wrapper. Wedge recovery cost is ~5 min board reboot.
2. **`bringup_pair_converge.sh` sets training_mode=1 but never clears it** — every successful converge must be followed by `td_clear_train.py` before AHB/PTP traffic.
3. **Per-deploy POR count-skew is non-portable** — manually-found eye phases from one deploy can't be reused after a reboot. Re-sweep every time.
4. **`cal_done=1` pre-flight check is wrong when AUTOCAL=0** — `bringup_ptp_sync.sh` must accept lane_locked mask as the gate when auto-cal is disabled.

## 7. Carry-forward checklist for build #3 testing

- [ ] Read `dwell_min_dist_o` (if still wired to APB) to confirm it varies per (slip,phase) during sweep
- [ ] Compare master vs slave chosen `(slip, phase)` — asymmetry expected because RX skew is asymmetric
- [ ] Run iterative PTP+AHB sandwich (this doc's sibling script) and log per-iteration: lane_locked, cal_done, hw_sync_done, AHB N=1 RX count
- [ ] If sandwich shows AHB-fine / PTP-flakey, scope FC adapter packet boundary handling
- [ ] If sandwich shows both fine, declare integration green and move on to N=4 / N=16 stress with build #3

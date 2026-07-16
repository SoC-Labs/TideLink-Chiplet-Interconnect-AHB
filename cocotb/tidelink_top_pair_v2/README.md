# tidelink_top_pair_v2 — integrated V2 pair sim with whole-word epoch skew

The integrated pre-silicon gate for the v37 defect class
(`docs/V37_FINAL_DIAGNOSIS_2026_06_12.md`): cross-lane word-EPOCH
incoherence on a skewed RX, invisible to per-lane training/BIST oracles.
Two complete `tidelink_top` instances compiled with the V2 stack
(`flists/tidelink_fpga_v2.flist` — deps/tidelink-phy serdes, always-on
calibrator, epoch-anchored deskew @ submodule c332722), cross-wired through
`pad_skid` with per-lane, per-direction delays.

Whole-word epoch offsets = pad delays in multiples of 16 bit-times: framing
and clock phase are untouched (training locks 8/8) while lanes deliver
different word epochs into the 128-bit assembly.

## Running

```
source set_env.sh
cd cocotb/tidelink_top_pair_v2
make v2_gate            # all four stages below, fresh build each (~2 min)
```

| Stage | Invocation | Expectation |
|---|---|---|
| zero-skew bring-up + data | `make EPOCH_PROFILE=zero` | 3/3 PASS |
| epoch staircase 0..7 both dirs | `make EPOCH_PROFILE=staircase` | 3/3 PASS |
| v37 silicon profile (3..7 words, master RX only) | `make EPOCH_PROFILE=silicon` | 3/3 PASS |
| **negative control** (anchor OFF) | `make EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl` | 1/1 PASS (= defect detected) |

`EPOCH_ANCHOR_DIS=1` defparams `WlinkGPIOPHY.EPOCH_ANCHOR_EN=0` on both
dies — the pre-fix occupancy-only deskew. The tb prints the elaborated
value at t=1 ns as a self-check.

## Measured discrimination matrix (2026-06-12, VCS 2022.06-SP2, cocotb 2.0.1)

| Profile | EPOCH_ANCHOR_EN | test_01 link-up | test_02 M→S data | test_03 S→M data |
|---|---|---|---|---|
| zero      | 1 (default) | PASS | PASS | PASS |
| staircase | 1 | PASS | PASS | PASS |
| silicon   | 1 | PASS | PASS | PASS |
| silicon   | 0 | PASS* | PASS (clean dir) | **FAIL** — rx all-zeros |
| staircase | 0 | PASS* | **FAIL** | **FAIL** |

\* link-up (CR/CRACK) survives epoch skew in sim: the FCSM emits
bit-identical CR packets back-to-back, so slices of *different* CR
instances still assemble into a valid CR word (same aliasing class as the
V1 "CR-credit-decode lottery"). On v37 silicon the CR decode did fail
(different inter-packet spacing/background). The unique-payload data
packet is the alias-proof oracle; the negative control asserts the data
signature, not the CR latch.

Exact pre-fix failure signature (silicon profile, anchor off):

```
[s2m] s->m: PKT_LEN=0x0 hdr=0x00000000 (sent 0x00240000)
      rx=[0x00000000, 0x00000000, 0x00000000, 0x00000000]
```

while training stays green bilaterally (cal_done=1, lane_locked=0xFF) and
M→S is byte-perfect — the v37 directional fingerprint.

## MARGINAL-EYE anchor-ON reproduction (silicon condition)

The clean whole-word `pad_skid` skew is *corrected* by `EPOCH_ANCHOR_EN=1` —
the silicon profile PASSES in sim (the anchor latches the right per-lane
offsets). But deployed silicon with the anchor ON STILL loses S→M data. The
ideal sim PHY does not model the missing ingredient: the **marginal eye** —
per-lane bit errors that corrupt the **training-exit content edge** the anchor
keys on.

`eye_fault.sv` (compile with `EYE_FAULT=1`) inserts a cocotb-driven bit-error
injector on the S→M path (post-skid, pre-master-RX). `test_v2_marginal_eye.py`
brings the link up CLEAN (training green, `cal_done=1`, `lane_locked=0xFF`),
then fires a short, lane-targeted error window across the training-exit / data
transition, with the anchor STILL ENABLED, and probes
`tidelink_lane_deskew.sv` internals.

```
make EPOCH_PROFILE=silicon EYE_FAULT=1 MODULE=test_v2_marginal_eye
```

Measured (VCS 2022.06-SP2, cocotb 2.0.1, 2026-06-15):

| Test | Injection (S→M) | Result | Anchor evidence |
|---|---|---|---|
| baseline (eye off) | none | S→M perfect | `lane_off_e=[4,0,2,3,1,4,0,2]` (correct) |
| **1L-b5** | L1, 5-bit burst/word | **garble, no commit** | L1 `ep_anchor_idx 12→9`, `lane_off_e[1] 0→3` |
| **3L-b5** | L1,4,6, 5-bit burst/word | **garble, no commit** | 3 lanes mis-latch early |
| 1L-b4-sp | L1, 4-bit burst /4 words | S→M intact | anchor latches correctly |

Failure signature (1L-b5): training green bilaterally, CR/CRACK OK, but
`hdr=0x5a17f00d (sent 0x00240000)`, `PKT_WORD_LEN=0x5a1` (garbage),
`packet_committed` never fires — the exact silicon S→M loss WITH the anchor
reporting `anchored=1` (it THINKS it won).

**Mechanism (file:line):** `tidelink_lane_deskew.sv:381-389` — the write-side
matcher counts a saturating `ep_streak` of pattern matches and, on the first
NON-match after `ep_streak >= EPOCH_STREAK_MIN(8)`, latches
`ep_anchor_idx <= wr_ptr_l` (line 385). A >3-bit-error burst on a LATE
training word reads as a non-match (`ep_dist > EPOCH_MATCH_THRESH=3`,
line 370) while the streak is still ≥8, so that lane latches its exit index
EARLY. The read side (line 617 `ep_delta`, line 664 `lane_off_e`) then derives
a WRONG per-lane offset from the corrupted index → the assembled 128-bit FC
word mixes epochs → garbled addr → no `write_complete`
(`src/rtl/fifo/tidelink_fifo_ctrl.sv:98,213`). The all-fresh/settle/span gates
(lines 583,603,626) do NOT catch it: a single corrupted edge is internally
self-consistent (one fresh, coherent, in-budget set), so it applies as a
clean one-shot.

## Files

| File | Role |
|---|---|
| `tb_top.sv` | V1 pair tb + per-direction `TB_TOP_EPOCH_{M2S,S2M}_L<n>` word offsets + `TB_TOP_EPOCH_ANCHOR_DIS` defparam hook + optional `TB_TOP_EYE_FAULT` S→M injector insert |
| `pad_skid.sv` | unchanged copy (arbitrary-depth per-lane shift register) |
| `eye_fault.sv` | **(harness)** cocotb-driven per-lane bit-error injector (marginal-eye repro) |
| `pair_v2_common.py` | APB/AHB drivers + V2 bring-up (role_lock W1S → passive autocal w/ `tb_early_exit_force_q` → to_data_mode) |
| `test_v2_pair_data.py` | link-up + M→S + S→M packet delivery (profile-agnostic) |
| `test_v2_pair_epoch_negctl.py` | negative control (run with `EPOCH_ANCHOR_DIS=1`) |
| `test_v2_marginal_eye.py` | **anchor-ON marginal-eye repro** (run with `EYE_FAULT=1`); probes anchor internals, asserts the mis-anchor signature |

Bring-up notes: the V2 calibrator auto-arms on the role_locked rising edge
(`AUTOCAL_ENABLE=1` at tidelink_top); `tb_early_exit_force_q` (the PHY
component's designed-in sim hook, same name as V1) skips the S_HOLD dwell +
the cr_pkt_seen-gated S_VALIDATE (2M link cycles — infeasible in sim).
`lane_locked` drops back to 0 after training release by design — sample it
in phase 1 (the harness returns `m_p1`/`s_p1` for this).

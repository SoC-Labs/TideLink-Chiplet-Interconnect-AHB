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

## Files

| File | Role |
|---|---|
| `tb_top.sv` | V1 pair tb + per-direction `TB_TOP_EPOCH_{M2S,S2M}_L<n>` word offsets + `TB_TOP_EPOCH_ANCHOR_DIS` defparam hook |
| `pad_skid.sv` | unchanged copy (arbitrary-depth per-lane shift register) |
| `pair_v2_common.py` | APB/AHB drivers + V2 bring-up (role_lock W1S → passive autocal w/ `tb_early_exit_force_q` → to_data_mode) |
| `test_v2_pair_data.py` | link-up + M→S + S→M packet delivery (profile-agnostic) |
| `test_v2_pair_epoch_negctl.py` | negative control (run with `EPOCH_ANCHOR_DIS=1`) |

Bring-up notes: the V2 calibrator auto-arms on the role_locked rising edge
(`AUTOCAL_ENABLE=1` at tidelink_top); `tb_early_exit_force_q` (the PHY
component's designed-in sim hook, same name as V1) skips the S_HOLD dwell +
the cr_pkt_seen-gated S_VALIDATE (2M link cycles — infeasible in sim).
`lane_locked` drops back to 0 after training release by design — sample it
in phase 1 (the harness returns `m_p1`/`s_p1` for this).

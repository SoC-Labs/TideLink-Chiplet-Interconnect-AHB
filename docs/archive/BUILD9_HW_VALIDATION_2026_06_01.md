# Build #9 HW Validation — 2026-06-01 03:08-03:25 BST

## Headline

🟢 **PHY converges 16/16 cleanly** at iter 1 in both canonical and skip-recal modes
🔴 **Doorbell delivery still wedges** — master `returner_busy` stuck at 1 after 100 rings, slave `DB_RESP=0`
🟢 **Boards healthy, lease released cleanly, no PS hangs** (L11 watchdog held)

## Build composition

**Branch:** `fix/build9-unified` (commit `da18098`)
**Composition** (off `bc52f88` base):

| Layer | Commit | Sim result | HW result |
|---|---|---|---|
| L11 wedge-break watchdog | `78d4b7f` | 2/2 PASS | No PS hang ✓ |
| L9 pktnum resync | `6df28e2` | (insufficient) | (insufficient) |
| L9b reset-domain fix | `da18098` | 3/3 PASS (was 1/3) | **does NOT clear HW wedge** |
| Bug B PHC saturation | `8935b8e` | 2/2 PASS | Not exercised (no PHC test) |

**Bitstreams:**
- master sha `cf46b4d7be99…` (pynq-z2-pair-all, local build)
- slave sha `515ef01074e4…` (pynq-z2-pair-flip-all, srv04936 farmed)
- Build time: 46m04s parallel, FPGA_INSERT_DEBUG_CORE=1

## HW test results

### Canonical bringup (`bringup_pair_converge.sh`)

```
IT 1 | die_a 0xff/0x00 8 1 fs4 cr1 | die_b 0xff/0x00 8 1 fs4 cr1 | tot/16 16
RESULT: CONVERGED at iteration 1
```

After 100 doorbells M→S:
```
z2_02 (MASTER): REG_STATUS=0x00000001 returner_busy=1 ← WEDGED
z2_03 (SLAVE):  REG_STATUS=0x00000000 returner_busy=0 DB_RESP=0
```

After 100 doorbells S→M (with master already wedged):
```
z2_02 (MASTER): REG_STATUS=0x00000001 returner_busy=1 (still wedged)
z2_03 (SLAVE):  REG_STATUS=0x00000001 returner_busy=1 ← also wedged now
```

Same symmetric wedge as Build #5/#7/#8 — no improvement from L9b.

### SW skip-recal workaround (per memory `★★ TideLink interface FCSM bug 2026-05-24/25`)

Deployed WITHOUT `bringup_pair_converge`'s `slot0=0x3` (train+recal hold) — just `slot0=0x1` (train only).

```
Post-train-only: BOTH lock=0xff, returner_busy=0, DB_RESP=0 (clean)
After M→S 100 rings: master REG_STATUS=0x00000001 (WEDGED), slave DB_RESP=0
After S→M 100 rings: BOTH REG_STATUS=0x00000001 (BOTH wedged)
```

**Skip-recal does NOT fix the wedge.** The memory's "skip-recal works" claim was for an older bitstream / different fix composition.

## What sim PASS does NOT tell us

The cocotb `test_bug_c_doorbell_asymmetry` 3/3 PASS post-L9b. The deep-debug probe `test_bugc_link_layer_probe` showed:
- `s_l2a_fc_replay_app_valid` ticks 639× (was 0)
- `s_send_nack_req_rises = 0` (was 1135)
- No FCSM wedge in sim

But HW shows the wedge. **Sim ≠ HW** for this specific failure mode. Hypotheses why:
- cocotb model lacks the WavD2DGpio mid-word mux flip (memory: WavD2DGpioTx.v:43)
- cocotb model lacks the AUTOCAL=1 M→S asymmetric corruption (memory: tidelink_top.sv:1630)
- HW timing closure / IDELAYE2 sub-UI sampling not modeled in cocotb
- ChipScope ILA insertion changes timing in a way the sim doesn't see

## Remaining open fix candidates (NOT applied — need human review)

From session memory:

1. **`★★★ AUTOCAL=0 HW workaround 2026-05-27`** — set `AUTOCAL_ENABLE(1'b0)` at `tidelink_top.sv:1630`. Memory says this "unblocks the FPGA link bilaterally" but it's a workaround, not a root-cause fix.

2. **`★★★ Calibrator fix 2026-05-27 (S_PROBE bias to (0,0))`** — branch `feat/calibrator-bug-fix @ f900e07`, new S_PROBE state in `tidelink_phy_align_calibrator.sv`. Sim 5/6 PASS at the time. Needs HW validation.

3. **WavD2DGpio word-align mux fix** — memory `★★ TideLink interface FCSM bug 2026-05-24/25 RESOLVED` references "commit 5477e60" but this commit doesn't exist in any local/remote branch of `deps/axi-chiplet-controller`. Either the fix was never committed, or the SHA is wrong, or it's on an unpushed branch.

4. **Deeper Wlink link-layer investigation** — pursue the actual signal that's wedged in HW via fresh ILA capture with mark_debug on `pkt_is_data_pkt`, `valid_rx_pkt_crc_err`, `auto_rx_in_word_count`, `send_nack_req`, etc.

## What DID land cleanly this session

1. **L11 (Bug A liveness)**: PYNQ kernel watchdog auto-recovers SSH within ~60s instead of requiring power-cycle. Build #9 confirms: no SSH disconnect during entire test sequence.
2. **L9b (Bug A correctness in sim)**: reset-domain rebind closes the one-shot trap. Sim regression test_bug_c_doorbell_asymmetry: 1/3 → 3/3 PASS.
3. **Bug B (PHC saturation)**: RTL OR-term + sim regression 7/7 PASS. BD-level `phc_nanoseconds` wiring DEFERRED to Build #10 (separate from link bring-up).
4. **Diagnostic infrastructure**: `cocotb/tidelink_top_pair/test_bugc_link_layer_probe.py` (cycle-by-cycle slave RX trace) is reusable for any future sim debug.

## Boards + lease state

Lease released cleanly. Both boards reachable (`hostname` returns OK). No PS hangs observed. Build #9 bitstreams staged at `mapstone-dev:/tmp/tidelink_deploy_build9/` for further investigation.

## Recommendation

The autonomous loop has reached the limit of what mechanical sim-validate→build→HW iteration can resolve. Each remaining HW iteration costs:
- 50 min build wall-time + parallel host load
- 30 min HW deploy + lease + validation
- High risk of catastrophe class (F-1.5 was a PS-hang requiring physical cycle)

Next steps require human design-review of the remaining fix candidates against current HW symptom:
- **A**: Try AUTOCAL=0 (single-line workaround, ~50min build)
- **B**: Merge `feat/calibrator-bug-fix @ f900e07` into build9-unified, re-build
- **C**: Build #10 with ILA mark_debug on the link-layer signals, capture in HW, then design a targeted fix

If repeating tonight's autonomous loop, recommend **B + C combined**: ship the calibrator fix AND new ILA probes in one build so the next HW cycle either succeeds OR provides ground truth.

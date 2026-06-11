# Bug C — SWAP HW test result: NEGATIVE

**Date:** 2026-05-31 23:30 BST
**Hypothesis:** sim `test_bug_c_doorbell_asymmetry.py::test_03` PASS (role-swap M→S) suggests Bug C is role-asymmetric. SWAP HW config should fix it.
**Result:** FALSIFIED. SWAP does NOT fix Bug C in silicon.

## Test setup

- Build #8 bitstreams (master sha `09e35b9cde35…`, slave sha `18578544b657…`, label `build7-ila-L10`, commit `bc52f88`)
- `SWAP=1` mode in `bringup_pair_converge.sh`:
  - z2_02 (192.168.4.101) ← `die_b` strap → SLAVE role → `tidelink-flip.bin`
  - z2_03 (192.168.6.101) ← `die_a` strap → MASTER role → `tidelink.bin`
- Bringup converged 16/16 at iter 1
- APB ring 100 doorbells from MASTER (z2_03) → check delivery on SLAVE (z2_02)
- Mirror direction also tested (z2_02 → z2_03)

## Result

```
PRE-RING:
  z2_02 (SLAVE, die_b)  DB_RESP=4096  PCC=0  REG_STATUS=0
  z2_03 (MASTER, die_a) DB_RESP=4096  PCC=0  REG_STATUS=0

After ring 100 from z2_03 (MASTER):
  z2_02 (SLAVE)         DB_RESP=0     PCC=0  REG_STATUS=0
  z2_03 (MASTER)        DB_RESP=0     PCC=0  REG_STATUS=1 (returner_busy=1, WEDGED)

After ring 100 from z2_02 (SLAVE) toward MASTER:
  z2_02 (SLAVE)         DB_RESP=0     PCC=0  REG_STATUS=1 (WEDGED)
  z2_03 (MASTER)        DB_RESP=0     PCC=0  REG_STATUS=1 (still wedged)
```

- `DB_RESP=0` on both sides after rings → no doorbell delivery
- `PAIR_CREDIT_COUNTER=0` → FC credit ledger not populated (same as canonical Bug C)
- `returner_busy=1` after first ring → same wedge primitive as canonical

## Implications

1. **Sim ≠ HW for this bug.** `test_bug_c_doorbell_asymmetry.py::test_03` PASS is a **TB artifact**, not a transferable workaround.
2. **Bug C is symmetric** at the HW level — neither role assignment delivers doorbells.
3. **SWAP cannot be used as a v1 ship workaround** — the link is bidirectionally silent.
4. **The forensic agent search space narrows**: the bug is not role-asymmetric initialization; it's something deeper in the FC credit-ledger handover that the cocotb TB happens to model incorrectly for the swapped-instance case.

## What's still informative from sim test 03 PASS

The cocotb test 03 swaps `ROLE_CFG` writes (assigns `u_master←SLAVE_LOCK`, `u_slave←MASTER_LOCK`) but **everything else** stays the same: clocks, resets, APB drivers, AND the pad_skid wirings between the two DUTs. So test 03 PASS proves that **whatever asymmetry exists is not in the RTL role-config path**. The remaining candidates:
- **TB harness asymmetry** (pad_skid model parameters, ref_clk distribution between u_master/u_slave) → sim-only artifact
- OR **u_slave physical instance has a unique fault** (e.g., one direction's drain logic broken) that doesn't follow role assignment

In HW, the SWAP test demonstrates both directions wedge regardless of role. So neither sim-test-03 explanation maps cleanly to HW.

## Next investigation directions

1. Wait for Bug C forensic agent — they'll explore the cr/crack→credit-ledger handover from RTL trace, which is independent of the role-swap hypothesis.
2. Specifically probe: does `PAIR_CREDIT_COUNTER` ever become non-zero in any HW config?
3. Investigate whether the credit-ledger population path requires a SW APB write that's missing from bringup_pair_converge / deploy_pair.sh.

## Lease + safety

Lease released cleanly after test. No PS hangs. Boards healthy. Build #8 L11 watchdog prevented any SSH disconnect.

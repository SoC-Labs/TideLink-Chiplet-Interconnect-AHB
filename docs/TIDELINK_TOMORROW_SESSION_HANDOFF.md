# TideLink Bringup — Resume Point Handoff

**Last updated**: 2026-05-25 ~11:00 UTC (after full diagnostic session 2)
**Status**: Root cause DEFINITIVELY localized; two fix paths in test; one HW test in flight; tdif-02 farm build in flight.

## TL;DR (60 seconds)

**THE EARLIER "TOMORROW PLAN" (top of this doc on first write) WAS WRONG.** The "swi_enable=0 transient" hypothesis was tested on HW with the FIX script and made no difference. The diagnosis has been refined through multiple agent investigations and HW probes. The actual bug:

**ASYMMETRIC slave LL_RX byte-alignment loss** at the training→FC-data mux transition. The per-lane mux at [`deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v:43-45`](../deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v) flips MID-WORD when `effective_training_mode` falls 1→0, producing a hybrid 16-bit word that's not a valid ECC long-packet header. Slave's `llrx/state=iSTATE` (search for SOP) STUCK forever. Master is fine.

**Critical new finding**: at fresh POR, the link is ALREADY half-handshaked with byte alignment intact (slave `fcsm=4 LINK_IDLE, llrx_valid=1`). `bringup_pair_converge.sh`'s slot0=0x3 recal cycle BREAKS this.

**Two fix paths under test 2026-05-25**:
1. **(SW only)** Skip `bringup_pair_converge.sh` entirely. HW test agent in flight as of writing (`ab27205e520a41250` / retry `a311bc49ab69159e0`).
2. **(RTL defensive)** Word-aligned mux transition in WavD2DGpio override. Committed as `5477e60` on `feat/td-interface-debug`. tdif-02 farm build in flight (~11:20 ETA).

Full diagnostic chain documented in [docs/TIDELINK_PHASE0_OBS_20260524_2109.md §11](TIDELINK_PHASE0_OBS_20260524_2109.md).

---

## Decision tree for next session

### Step 1 — Check the POR-only HW test result

The agent `a311bc49ab69159e0` deployed tdif-01 fresh and tested if doorbells cross WITHOUT running `bringup_pair_converge.sh`.

| Outcome | Action |
|---|---|
| **POR works** (doorbells cross at POR, no bringup needed) | The fix is just "don't run bringup". Patch the deploy scripts to skip the recal. No RTL change needed. Victory lap. |
| **POR partial** (FCSM advances but doorbells don't cross) | Still need RTL fix. Use tdif-02 with word-align fix. |
| **POR doesn't work** (FCSM stays at half-handshake) | Need RTL fix. Deploy tdif-02. |

### Step 2 — If RTL fix needed: deploy tdif-02

```bash
# Check farm build status
ls -la /home/dam1n19/SoCLabs/td-bisect/td-interface-debug/imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit
tail -20 /tmp/tdif02_build.log

# If both bitstreams ready, stage to mapstone-dev
cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
SHA=$(git rev-parse --short HEAD)   # should be 5477e60
for T in pynq-z2-pair-all pynq-z2-pair-flip-all; do
    python3 fpga/scripts/bit2bin.py imp/fpga/output/$T/tidelink.bit imp/fpga/output/$T/tidelink.bin
done
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-all/tidelink.bin --label "tdif-02" --commit "$SHA" --target pynq-z2-pair --lock-min 16
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin --label "tdif-02" --commit "$SHA" --target pynq-z2-pair-flip --lock-min 16

# Stage to mapstone-dev:/tmp/tidelink_deploy/tdif-02/ via cat-through-ssh
ssh mapstone-dev "bash --noprofile --norc -c 'mkdir -p /tmp/tidelink_deploy/tdif-02'"
ssh mapstone-dev "bash --noprofile --norc -c 'cat > /tmp/tidelink_deploy/tdif-02/tidelink.bin'" < imp/fpga/output/pynq-z2-pair-all/tidelink.bin
ssh mapstone-dev "bash --noprofile --norc -c 'cat > /tmp/tidelink_deploy/tdif-02/tidelink-flip.bin'" < imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin
# Same for .manifest.json, .hwh, .ltx
```

### Step 3 — Test tdif-02 on HW

```bash
fpgahub pair lease acquire bridge1 --ttl 5400  # capture token

ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && \
  pynq_host/scripts/deploy_pair.sh 192.168.4.101 tdif-02 master /tmp/tidelink_deploy/tdif-02/tidelink.bin --manifest /tmp/tidelink_deploy/tdif-02/tidelink.bin.manifest.json'"
# Same for slave

# Test POR state directly (no bringup), then doorbell:
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && source pynq_host/scripts/hwtest/lib/lib_hwtest.sh && \
  tt_debug_unlock 192.168.4.101; tt_debug_unlock 192.168.6.101; \
  echo M_LANE=\$(tt_devmem_read 192.168.4.101 0x44032108); \
  echo S_LANE=\$(tt_devmem_read 192.168.6.101 0x44032108); \
  _=\$(tt_devmem_read 192.168.6.101 0x44032024); \
  for i in 1 2 3 4 5 6 7 8; do tt_devmem_write 192.168.4.101 0x44032014 0x1; sleep 0.05; done; sleep 1; \
  echo s_DBELL_after_master_rings_8=\$(tt_devmem_read 192.168.6.101 0x44032024)'"
```

**Expected with word-align fix**: slave DOORBELL_RESP_ACC advances by ~8 (doorbells cross).

### Step 4 — If neither path works (escalation)

- ILA capture on tdif-02 to compare to tdif-01's captured behavior
- Per-lane scope probe at the WavD2DGpio output to verify the word-aligned transition is actually happening
- Consider rebuilding without the calibrator/training mode at all (POR-only operation in RTL)

---

## Resource state at handoff

| Asset | Location | Status |
|---|---|---|
| Phase 0 obs doc with full diagnosis | [docs/TIDELINK_PHASE0_OBS_20260524_2109.md](TIDELINK_PHASE0_OBS_20260524_2109.md) §11 | UPDATED 2026-05-25 |
| User guide (Pitfall #1 with RTL fix) | [docs/TIDELINK_BRINGUP_USER_GUIDE.md](TIDELINK_BRINGUP_USER_GUIDE.md) | UPDATED 2026-05-25 |
| Memory entry | `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_interface_fcsm_bug_2026_05_24.md` | UPDATED 2026-05-25 with FINAL DIAGNOSIS |
| Worktree | `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/` branch `feat/td-interface-debug` | HEAD `5477e60` (word-align fix) |
| Local override file | `src/rtl/local_overrides/WavD2DGpio.v` | Has word-align fix |
| tdif-01 bitstream | `/tmp/tidelink_deploy/tdif-01/` on mapstone-dev | Built without fix, has ILA |
| tdif-02 bitstream | `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit` (worktree) | Building (ETA ~11:20) |
| Sim tests | `cocotb/{wlink_pair,wav_d2d_gpio_tx,wlink_tx_pstate_ctrl}/` | All pass for what they test |

## Critical guardrails

1. **DO NOT WRITE `0x4400_0000` (AHB_TX)** — wedge hazard, requires power cycle
2. **DO NOT run `bringup_pair_converge.sh` without first reading POR state** — if POR shows slave at `fcsm=4 llrx_valid=1`, the link is ALIVE; DON'T perturb
3. **DO release the lease** at end with the captured token
4. **DO use `bash --noprofile --norc -c '...'`** for SSH to mapstone-dev (avoids bashrc noise)

## Cross-references

- Plan: [docs/TIDELINK_INTERFACE_DEBUG_PLAN.md](TIDELINK_INTERFACE_DEBUG_PLAN.md) — original 6-phase plan
- Diagnostic chain: [docs/TIDELINK_PHASE0_OBS_20260524_2109.md](TIDELINK_PHASE0_OBS_20260524_2109.md) — §1-11
- User guide: [docs/TIDELINK_BRINGUP_USER_GUIDE.md](TIDELINK_BRINGUP_USER_GUIDE.md) — Pitfall #1 has the full RTL diagnosis
- Earlier PHC handoff (superseded): [docs/PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md)
</content>
</invoke>
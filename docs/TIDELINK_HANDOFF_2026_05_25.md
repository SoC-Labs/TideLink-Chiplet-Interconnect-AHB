# TideLink Debug — Session Handoff 2026-05-25

**Status snapshot**: 2026-05-25 12:30 UTC
**Worktree**: `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/` on `feat/td-interface-debug`
**HEAD**: `aa87881` (tdif-03 per-lane mux fix)
**Last lease**: released cleanly (token `CNyKr577p51WQ4S5nhZXrg`)

---

## 1. TL;DR

After three RTL iterations + many sim + HW probes, the **byte-alignment bug class is RESOLVED**. The link now completes bidirectional CR/CRACK handshake (`cr_seen=1, ck_seen=1` on BOTH sides; `rx_data_valid=1` on BOTH sides). But there is **one more blocker**: FCSM stays at LINK_IDLE (state 4) on master and SEND_NACK (state 7) on slave — never advancing to LINK_DATA (state 5). Therefore PAIR_CREDIT_COUNTER stays at 0 and doorbells/AHB SUB/PHC do not cross.

**PTP does NOT work yet** — but only because the link layer doesn't reach LINK_DATA. The original 7-day PHC debug saga was a downstream symptom of the bug class we've largely resolved. Once tdif-04 closes the LINK_IDLE→LINK_DATA gap, PTP should work without additional PTP-specific fixes.

---

## 2. The full bug story (chronological)

### Original problem
PHC Phase-1: slave PTP_CTRL[2] never sets to 1; doorbells don't cross; AHB SUB peer writes don't cross. 7-day debug chased `rx_accept` consumer-replica fix in `tidelink_ptp.sv:288` (builds b18-b25). All wrong layer.

### Diagnostic discoveries (chronological)
1. **Phase 0 (2026-05-24)**: HW probes confirmed bug is **interconnect-wide**, not PTP-specific. cr_pkt_seen_rx=0 on slave; PAIR_CREDIT=0 both sides.
2. **swi_enable=0 transient hypothesis**: FALSIFIED on HW after applying corrected to_data_mode script.
3. **WlinkTxPstateCtrl deadlock**: PROVEN at unit-test level but FSM never enters the deadlocking state in our scenario.
4. **PHY mux gating identified**: `WavD2DGpioTx.v:43-45` replaces FC data with training pattern when training_mode=1. CONFIRMED via cocotb tests.
5. **POR-only test**: deploying without bringup script — doorbells still don't cross. SW-only fix path RULED OUT.
6. **HW ILA tdif-01**: slave `llrx/state=iSTATE` STUCK, ECC sees bits but no SOP. Master `llrx/valid=1` constantly. Asymmetric.
7. **tdif-02 (wrapper-level word-align)**: asymmetry FLIPPED — master sees, slave blind (master TX went silent post-fix).
8. **tdif-03 (per-lane word-align)**: BOTH sides handshake. Returners busy. Link very alive. But FCSM stuck before LINK_DATA.

### What's RESOLVED
- The "mid-word mux flip destroys byte alignment" bug class — fixed by per-lane latching in `src/rtl/local_overrides/WavD2DGpioTx.v`

### What REMAINS
- FCSM advancement from LINK_IDLE → LINK_DATA
- Why slave reaches SEND_NACK (state 7) instead of LINK_DATA
- PCC=0 despite handshake complete — credit window init issue

---

## 3. Current HW state (after tdif-03 deploy + bringup + to_data_mode)

| Register | Master (0x44030xxx / 0x44032xxx) | Slave |
|---|---|---|
| `SWI_LANE_STATUS @ 0x44032108` | `0x01890000` | `0x018f0000` |
|   → cr_seen | 1 | 1 |
|   → ck_seen | 1 | 1 |
|   → cal_done | 1 | 1 |
|   → FCSM state | 4 (LINK_IDLE) | 7 (SEND_NACK) |
| `PAIR_CREDIT_COUNTER @ 0x44032028` | 0 | 0 |
| `CURRENT_CREDITS @ 0x4403200C` | 4096 | 4096 |
| `STATUS @ 0x44032010` | 0x01 (RETURNER_BUSY) | 0x01 (RETURNER_BUSY) |
| `LinkStatus @ 0x44030234` | 0x10 (rx_data_valid=1) | 0x10 (rx_data_valid=1) |
| `slot0 @ 0x44032100` | 0 | 0 |
| `LL_CTRL @ 0x44030208` | 0x27f07 | 0x27f07 |
| `ECC counters @ 0x44032114` | 0 | 0 |
| `FC CRC errors @ 0x44031720` | 0 | 0 |

Doorbell test post-bringup-and-to_data_mode: 0 → 0 (neither direction).

---

## 4. Worktree state + assets

### Branch: `feat/td-interface-debug` (in worktree `/home/dam1n19/SoCLabs/td-bisect/td-interface-debug/`)

Recent commit history:
```
aa87881 tdif-03-prep: per-lane WavD2DGpioTx word-align mux + disable wrapper-level fix
5477e60 tdif-02: word-aligned mux transition for training→FC data (wrapper-level)
122d193 rtl: tier 2 swi_enable hardening — force HIGH on swreset writes (deferred relevance)
ba59df3 pynq-host: program NEGO_TRAIN_CFG.train_auto_en=1 before NEGO_CFG.nego_en
691916d fix(pynq-host): keep swi_enable=1 during LL swreset cycle (DISPROVEN)
```

### Files of interest
| Path | Role |
|---|---|
| `src/rtl/local_overrides/WavD2DGpioTx.v` | Per-lane word-align fix (the working one) |
| `src/rtl/local_overrides/WavD2DGpio.v` | Wrapper-level fix (deactivated; left for ILA naming continuity) |
| `flist/tidelink_fpga.flist` | Routes both overrides ahead of submodule |
| `cocotb/wav_d2d_gpio_tx/` | Unit test confirming mid-word mux flip |
| `cocotb/wlink_tx_pstate_ctrl/` | Unit test of pstate FSM (theoretical deadlock proven but not the bug) |
| `cocotb/wlink_pair/test_tx_gated_by_training.py` | System sim repro |
| `cocotb/tidelink_top_pair/` | Paired tidelink_top TB (compile-clean, blocks at NEGO_CFG) |
| `docs/TIDELINK_PHASE0_OBS_20260524_2109.md` | §1-13 full diagnostic chain |
| `docs/TIDELINK_BRINGUP_USER_GUIDE.md` | User guide; Pitfall #1 has the actual root cause |
| `docs/TIDELINK_TOMORROW_SESSION_HANDOFF.md` | Older handoff (superseded by this doc) |
| `docs/TIDELINK_INTERFACE_DEBUG_PLAN.md` | Original 6-phase plan |
| `docs/PHC_PHASE1_HANDOFF.md` | Original (incorrect) PTP-specific diagnosis |

### Bitstreams staged on mapstone-dev:/tmp/tidelink_deploy/
| Label | sha256 (main / flip) | Commit | Status |
|---|---|---|---|
| `tdif-01` | `73721ddb / bf7453ac` | 122d193 | Baseline + ILA, no fix |
| `tdif-02` | `335c34db / 5b5b487a` | 5477e60 | Wrapper-level fix |
| `tdif-03` | `485317b8 / 49994885` | aa87881 | Per-lane fix — current best |

All have `.bin / .manifest.json / .hwh / .ltx` (where built). All accessible via `deploy_pair.sh ... --manifest /tmp/tidelink_deploy/tdif-NN/<bin>.manifest.json`. The `parent /tmp/tidelink_deploy/` is currently populated with tdif-03 files (so default `bringup_pair_converge.sh` picks them up).

### Memory entries
| File | Content |
|---|---|
| `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/MEMORY.md` | Index — updated with tdif-03 status |
| `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_interface_fcsm_bug_2026_05_24.md` | Has FINAL DIAGNOSIS section (will need an UPDATE for tdif-03 partial closure + LINK_IDLE blocker) |

### HW infrastructure
- `bridge1` board pair (z2_02 master, z2_03 slave) via `fpgahub pair lease`
- `mapstone-dev` runs `hw_server` on port 3121 for JTAG/ILA
- Vivado 2025.2 at `/tools/Xilinx/2025.2/Vivado/bin/vivado` on mapstone-dev
- ILA capture scripts: `pynq_host/scripts/phc_ila_capture.{sh,tcl}`

---

## 5. The exact reproduction sequence for the remaining bug

To reproduce the current state in any next session:

```bash
# Step 1: acquire lease
fpgahub pair lease acquire bridge1 --ttl 5400
# capture the token

# Step 2: deploy tdif-03
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && \
  pynq_host/scripts/deploy_pair.sh 192.168.4.101 z2_02-tdif-03 die_a /tmp/tidelink_deploy/tdif-03 --manifest /tmp/tidelink_deploy/tdif-03/tidelink.bin.manifest.json'"
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && \
  pynq_host/scripts/deploy_pair.sh 192.168.6.101 z2_03-tdif-03 die_b /tmp/tidelink_deploy/tdif-03 --manifest /tmp/tidelink_deploy/tdif-03/tidelink-flip.bin.manifest.json'"

# Step 3: bringup + to_data_mode
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && timeout 240 pynq_host/scripts/bringup_pair_converge.sh && source pynq_host/scripts/hwtest/lib/lib_hwtest.sh && \
  tt_debug_unlock 192.168.4.101; tt_debug_unlock 192.168.6.101; \
  tt_devmem_write 192.168.4.101 0x44032100 0x0; tt_devmem_write 192.168.6.101 0x44032100 0x0; sleep 0.005; \
  tt_devmem_write 192.168.4.101 0x44030208 0x00027f08; tt_devmem_write 192.168.6.101 0x44030208 0x00027f08; sleep 0.01; \
  tt_devmem_write 192.168.4.101 0x44030208 0x00027f00; tt_devmem_write 192.168.6.101 0x44030208 0x00027f00; sleep 0.01; \
  tt_devmem_write 192.168.4.101 0x44030208 0x00027f07; tt_devmem_write 192.168.6.101 0x44030208 0x00027f07; sleep 1.0'"

# Step 4: verify state matches expected
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && source pynq_host/scripts/hwtest/lib/lib_hwtest.sh && \
  tt_debug_unlock 192.168.4.101; tt_debug_unlock 192.168.6.101; \
  echo M_LANE=\$(tt_devmem_read 192.168.4.101 0x44032108); \
  echo S_LANE=\$(tt_devmem_read 192.168.6.101 0x44032108); \
  echo M_STATUS=\$(tt_devmem_read 192.168.4.101 0x44032010); \
  echo S_STATUS=\$(tt_devmem_read 192.168.6.101 0x44032010)'"

# Expected: M_LANE~0x01890000, S_LANE~0x018f0000, both STATUS=0x01 (RETURNER_BUSY)
# This is the state to debug from.

# Step 5: release lease cleanly
fpgahub pair lease release bridge1 --token <TOKEN>
```

---

## 6. Plan to continue debug — multi-agent strategy

Goal: get FCSM to advance from LINK_IDLE to LINK_DATA so doorbells/AHB SUB/PHC all cross.

### Investigation tracks (run in parallel)

**Track A — RTL: why slave at SEND_NACK?**
Dispatch an Explore agent to:
1. Read `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala` lines around SEND_NACK transition
2. Identify all conditions that cause IDLE → SEND_NACK transition
3. Map what signal/packet would make slave go to SEND_NACK
4. Read `WlinkRxLinkLayer.v` for ECC error handling — does ECC corrupted increment a counter that triggers NACK?
5. Determine: what specific FC packet would slave have rejected to trigger SEND_NACK?

**Track B — RTL: LINK_IDLE → LINK_DATA gate analysis**
Dispatch an Explore agent to:
1. From `FC.scala`: identify all conditions for state 4→5 transition
2. Per earlier audit: requires `a2l_fc_replay.link.valid && ~fe_rx_is_full && !(send_nack_req || send_ack_req || count==0)`
3. Each of these signals — what drives them in our state? Especially `fe_rx_is_full` and `count`
4. Could `fe_rx_is_full` be stuck at 1 because credit init didn't happen?
5. What initializes `fe_tx_credit_max` on each side? Is it always loaded via CR packet?

**Track C — HW: ILA capture FCSM internals on tdif-03**
Dispatch a general-purpose agent to:
1. Deploy tdif-03 + bringup + to_data_mode
2. Capture ILA on master and slave separately
3. Probe: FCSM `state`, `auto_tx_out_advance`, `cr_pkt_seen_tx`, `crack_pkt_seen_tx`, `fe_tx_credit_max`, `fe_rx_credit_max`, `fe_rx_is_full`, `send_nack_req`, `send_ack_req`
4. Specifically capture both sides simultaneously (need 2 separate sessions, or expand ILA probe set)
5. Goal: see exactly which signal is preventing the LINK_IDLE → LINK_DATA transition

**Track D — Sim: extend cocotb to test LINK_IDLE → LINK_DATA**
Dispatch a general-purpose agent to:
1. Look at `cocotb/wlink_pair/test_assert_bringup.py` test_07/08/09 — these PASS, FCSM reaches LINK_DATA in sim
2. Compare: what's the diff between sim's LINK_DATA path and our HW state?
3. The sim TB has `AUTOCAL_ENABLE=0` so calibrator never runs, no training pulse, FCSM bringup straight from POR. HW has training pulse + drop.
4. Modify a test to add the training pulse + drop, then verify FCSM still reaches LINK_DATA in sim
5. If sim FAILS too, we have a sim repro of the LINK_IDLE blocker

**Track E — Try APB-level recovery (no rebuild)**
Dispatch a general-purpose HW agent to:
1. Use the existing tdif-03 deploy
2. Try writing `swi_swreset` (bit[3] of LL_CTRL) again to re-init FCSMs (might clear SEND_NACK)
3. Try FLUSH (CTRL bit[1] at 0x4403201C) to clear sticky errors
4. Try multiple recal+to_data_mode iterations
5. Try writing PAIR_CREDIT_COUNTER directly (might unstick credit init)
6. Try doorbell at varying intervals (maybe needs a particular timing)

### Synthesis + decision

After tracks A-E return:
- Track A+B will tell us WHY slave goes to SEND_NACK and what would unstick it
- Track C will give silicon evidence
- Track D will tell us if it's a sim/HW gap or shared bug
- Track E might find an APB-level workaround that doesn't need RTL change

Based on synthesis:
- If track E succeeds: SW workaround for now, RTL fix as follow-up
- If track A/B identifies the gate: build tdif-04 with that fix
- If sim repros (track D): tight debug loop, iterate sim fix then rebuild

### Tdif-04 candidate fixes (pre-design before agents return)

Possible RTL changes (any of these could be tdif-04):

1. **Force LINK_IDLE → LINK_DATA**: bypass the gating condition. Risky but might work.
2. **Suppress SEND_NACK**: if slave reaches SEND_NACK, force it to recycle to LINK_IDLE. Hides the underlying problem.
3. **Initialize fe_rx_credit_max non-zero on POR**: maybe the credit init is the blocker.
4. **Add an APB-driven "force LINK_DATA" hook**: SW intervention point.

---

## 7. Continuing from this handoff

To start a fresh context and continue:

1. **Read this doc + `docs/TIDELINK_PHASE0_OBS_20260524_2109.md`** (especially §11-13 for the final 3-build trajectory)
2. **Dispatch the 5 parallel tracks** above
3. **Wait for results, synthesize, decide on tdif-04 RTL change**
4. **Build + deploy tdif-04 + verify FCSM reaches LINK_DATA**
5. **If LINK_DATA reached**: run hwtest/03_ahb_sub_e2e + ring doorbell + run PHC sync test (bringup_ptp_sync.sh)
6. **If all 3 pass**: PHC PHASE1 is FULLY RESOLVED. Update memory + propagate fix to mainline + close the saga.

---

## 8. Critical guardrails (inherited)

1. **DO NOT WRITE `0x4400_0000` (AHB_TX)** — wedge hazard, requires power cycle
2. **DO release lease cleanly** with the captured token at end of session
3. **DO use `bash --noprofile --norc -c '...'`** for SSH to mapstone-dev (bashrc emits "Agent pid X" noise)
4. **DO NOT use rsync** to mapstone-dev (bashrc noise breaks rsync protocol) — use `cat`-through-ssh instead
5. **DO NOT run `bringup_pair_converge.sh`** without confirming the bins in `/tmp/tidelink_deploy/` are the bitstream you intended — the script silently picks up parent dir files even with `ARTEFACTS=` arg
6. **DO ALWAYS verify manifest provenance** with `--manifest` flag on `deploy_pair.sh`
7. **DO NOT modify** `deps/axi-chiplet-controller/` submodule — use local overrides in `src/rtl/local_overrides/` + flist redirect

---

## 9. Confidence levels

- **Bug class is correct (mid-word mux flip)**: HIGH — unit test, sim, ILA all confirm
- **Per-lane fix (tdif-03) is right approach**: HIGH — HW shows bidirectional handshake completed for first time in 7+ days of debug
- **LINK_IDLE → LINK_DATA gap is the FINAL blocker**: MEDIUM — could be one more thing or multiple
- **PTP will work once FCSM reaches LINK_DATA**: HIGH — the original PHC bug was a downstream symptom

---

## 10. Estimated effort to closure

- 1 day of focused multi-agent investigation should identify the LINK_IDLE blocker
- 1 build cycle for tdif-04 (~45 min)
- 1 HW session for validation (~30 min)

Realistic: **half a day to one day** of focused work to close the entire bug.

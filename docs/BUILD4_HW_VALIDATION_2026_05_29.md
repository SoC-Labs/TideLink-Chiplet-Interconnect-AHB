# Build #4 (ILA) HW validation — REGRESSION identified

**Date:** 2026-05-29 18:30-19:00 BST
**Build:** #4 (ILA-instrumented, `FPGA_INSERT_DEBUG_CORE=1`, mark_debug per audit §3+§4)
**Build SHAs:** master sha256 `a28fd2f5…81…ec2` md5 `9285846369da4107…`; slave sha256 `2de40e85…4a37ced` md5 `d42aba026009699e…`
**Build commit at launch:** ancestors of `bd9646e` (parent tip when build started 15:57 BST)
**Submodule axi-chiplet:** `9ad2570` (with ShortPacket TX mark_debug)
**Lease:** bridge1 acquired @ 18:33 (7200s TTL)

## Headline

**Build #4 has a functional regression vs build #3.** The PHY layer still converges 16/16, cal_done=1 on both sides. But the application-layer FC path is broken:

- Master returner stays in `returner_busy=1` state after any traffic
- Slave doorbell resp_acc stays at 0 (no doorbell delivery)
- AHB N=1 TX fails with "returner busy before write"
- FCSM state asymmetric: master=7, slave=4 (was 4/4 in build #3)

Build #3 (md5 master `3ee2149d…` slave `ab87ca05…`) re-deployed during this session and **confirmed working** under identical SW flow — slave resp_acc bumped to 4096 after 100 master doorbell rings.

So the regression is **bitstream-specific to build #4**. The only synthesis-affecting deltas vs build #3:

1. ~20 `mark_debug` attributes added to `tidelink_top.sv`, `tidelink_fc_adapter.sv`, `tidelink_ptp.sv`, `src/rtl/fifo/tidelink_apb_regs.sv` (this session, commit `ebbde0e`)
2. 4 `mark_debug` attributes on submodule `ShortPacketToWlink.v` (submodule branch `ila-mark-debug-tx-shortpacket`, commit `9ad2570`)
3. ChipScope debug-core insertion (`FPGA_INSERT_DEBUG_CORE=1`) → 334 marked nets connected to `u_dbg_int`
4. Cleanup commit `59e35e5` deleted shadow RTL files (`src/rtl/tidelink_apb_regs.sv` etc.) that the agent claimed were unreferenced

## Multi-deploy test (2026-05-29 21:07-21:09 BST)

Five fresh deploys of build #4. Sequence per deploy: re-flash both boards via `deploy_pair.sh`, write `SWI_TRAINING_MODE=1`, sleep 2s, sample state, ring 100 master doorbells, sample state again.

| Deploy | Master LANE_STATUS | Master cal_done | Slave LANE_STATUS | Slave cal_done | After ring: master RB | After ring: slave DB_RESP |
|---|---|---|---|---|---|---|
| 1 | 0x018f00ff | 1 | 0x018900ff | 1 | **1** | **0** |
| 2 | 0x018f00ff | 1 | 0x018900ff | 1 | **1** | **0** |
| 3 | 0x000200ff | 0 | 0x000200ff | 0 | **1** | **0** |
| 4 | 0x010e00ff | 0 | 0x008500ff | 1 | **1** | **0** |
| 5 | 0x000200ff | 0 | 0x008500ff | 1 | **1** (master lock dropped to 0xf6) | **0** |

**Findings:**
- Doorbell M→S failure is **100% deterministic** — fails in every deploy regardless of which PHY state is hit by the POR lottery.
- PHY-layer convergence (`cal_done` + `lane_locked`) is unstable on build #4 (was rock-solid iter-1 on build #3): only 2/5 deploys hit a clean `cal_done=1` both sides. Deploy 5 even lost a lane mid-test (0xff → 0xf6).
- Master `REG_STATUS=0x01` (returner_busy=1) appears in 100% of deploys after the 100-ring sequence — independent of whether PHY converged.

The lottery only affects PHY convergence; it does NOT affect the FC application-layer regression. The bug is intrinsic to the bitstream, not seed-dependent.

## Test results table

| Test | Build #3 (re-deployed) | Build #4 (ILA) |
|---|---|---|
| Lane lock both sides | ✅ 0xff / 0xff | ✅ 0xff / 0xff |
| `cal_done` both sides | ✅ 1 / 1 | ✅ 1 / 1 |
| FCSM state (master / slave) | 4 / 4 (LINK_IDLE both) | **7 / 4** (asymmetric) |
| Doorbell M→S (slave resp_acc after 100 rings) | ✅ 4096 | ❌ **0** |
| AHB N=1 TX (master returner_busy at start) | ❌ 1 (stuck after earlier traffic) | ❌ 1 (stuck from POR) |
| AHB N=1 RX at slave FIFO | n/a (TX blocked) | n/a (TX blocked) |
| Slave PTP_STATUS bit[2] = ptp_rx_valid_r (Bug B with CORRECTED reg) | n/a — not tested due to time | ❌ 0 (Bug B confirmed BUT inseparable from build #4 regression) |
| Slave PTP_RX_PAYLOAD | n/a | ❌ 0 |

## Timing (build #4)

Both bitstreams: **clean timing**.

| | Setup WNS | Setup failing | Hold WHS | Hold failing |
|---|---|---|---|---|
| Master | +26.566 ns | 0 | +0.088 ns | 0 |
| Slave | +25.885 ns | 0 | +0.104 ns | 0 |

So timing is NOT the cause of the regression. The cause is a logical-behaviour change introduced by mark_debug or cleanup.

## Diagnostic state captured

**Master, after multiple ops:**
- `REG_STATUS = 0x00000001` (returner_busy=1, all error bits clear)
- `LANE_STATUS = 0x018f00ff` (lock=0xff cal_done=1, bit 19 set)
- `DBELL_RESP_ACC = 4096` (master received doorbells from slave at some point)
- `PAIR_CRED_CTR = 0` (SW-managed, expected)
- FCSM state = **7** (was 4 in build #3 — root anomaly)

**Slave, after same ops:**
- `REG_STATUS = 0x00000004` (fifo_underrun=1 sticky, returner_busy=0)
- `LANE_STATUS = 0x018900ff` (lock=0xff cal_done=1)
- `DBELL_RESP_ACC = 0` (never received a doorbell M→S)
- FCSM state = **4** (LINK_IDLE — correct)

Two sticky bad-state signals:
- Master's returner is stuck `busy`
- Slave's returner has a sticky `fifo_underrun`

Both are typically set when packets are sent without matching credit returns, OR when the FC-link payload framing is wrong.

## Most likely causes — UPDATED after RTL-diff agent + multi-deploy

Full RTL-diff analysis: [docs/BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md](BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md).

**The agent overturned several of my initial hypotheses:**

### Falsified

- **R-1 (mark_debug on pair_credit_counter)**: `pair_credit_counter` mark_debug is in the pclk APB-read domain — physically not on the returner-busy clearing path. The chain `state_r → hready → rtn_hready → skid_can_accept` has zero mark_debug attributes anywhere. R-1 is false.
- **R-3 (cleanup commit deleted a needed file)**: all flists used by the FPGA target resolve to existing files. No shadow path is referenced. R-3 is false.

### New diagnosis: the master FCSM state-7 wedge is documented in-tree

The exact symptom — master FCSM wedged at state 7 (SEND_NACK), slave FCSM at state 4 (LINK_IDLE), no actual CRC errors, returner-busy as downstream symptom — is **described word-for-word** in the header of [src/rtl/local_overrides/WlinkGenericFCSM_6.v:1-66](src/rtl/local_overrides/WlinkGenericFCSM_6.v#L1-L66). This is the "L7 sticky-NACK bringup recovery" override from 2026-05-26 (build tdif-12 era).

The override implements a `socl_l7_bringup_forgive` gate that:
1. Latches `socl_l7_reached_link_data` once FCSM has ever observed state 5 (LINK_DATA) — permanently disarms after first successful bringup.
2. Computes `forgive = !reached_link_data & cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet`.
3. AND-clears `send_nack_req` synchronously in ALL states whenever forgive is asserted.

The override file is **byte-identical between build #3 and build #4** — same logic in both. So the override exists in both builds, but in build #4 the forgive gate fails to activate.

### R-NEW (highest probability): ILA core insertion + 334 mark_debug nets perturbed P&R, breaking the L7-forgive race window

- Build #3 had ZERO marked nets and an EMPTY `pynq_z2_tidelink_drc.xdc` (just constraints, no connect_debug_port).
- Build #4 connects ~334 nets to a fresh `u_dbg_int` core via 190 lines of `connect_debug_port` directives in `pynq_z2_tidelink_drc.xdc`.
- The L7-forgive gate requires a tight bidirectional `cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet` race window — both stickies must assert before the FCSM exits the SEND_NACK trap.
- Placement perturbation around `u_chiplet_controller/u_wlink/llrx/` (where these signals live) plausibly breaks the timing of those demet stickies.
- **Multi-deploy evidence (this session, 5 deploys):** PHY-layer convergence is unstable on build #4 — only 2/5 deploys reach clean cal_done=1 on both sides. Build #3 was iter-1 every time. This PHY-layer instability is independent evidence of placement perturbation.

**Cheapest test:** rebuild commit `573e767` with `FPGA_INSERT_DEBUG_CORE=0` (env var) while keeping mark_debug attributes. This isolates "ILA core insertion" from "mark_debug attrs alone". If the FCSM converges to state 5 without the ILA core, the placement-perturbation hypothesis is confirmed. ~2h rebuild + 5 min validation.

### Other deletions surfaced by the agent (not in my original commit list)

Intermediate commit `e72db73` ("cleanup: verification gap fills + dead-code removal") between `dda0a0e` and my `ebbde0e` stripped 134 lines from `tidelink_top.sv` (removed `dbg_shim_sel` Region-9 mux block), and deleted `tidelink_fcsm_debug.sv` (214 L) + `tidelink_phy_align_regs.sv` (171 L). These are larger surface changes than the original ranking accounted for. They should be re-examined as a secondary hypothesis if the no-ILA build still regresses.

### R-Sub falsified

Submodule bump `c0a69ff → 9ad2570` is **mark_debug attributes only** — 4 attrs on `ShortPacketToWlink.v`, no Scala regeneration, no logic change. Confirmed by the agent.

## Bugs A and B — partial validation

**Bug A** (AHB packet RX at slave) — cannot be tested on build #4 because master's TX is blocked by `returner_busy=1`. On build #3 (working baseline), the bug should still reproduce — but I couldn't re-run cleanly in this session because the master returner is now stuck on build #3 too after the same traffic that broke build #4. Would need a fresh power-cycle to retest.

**Bug B** (PTP HW_SYNC RX at slave) — tested with the corrected slave-RX register (`PTP_STATUS @ 0x03C` bit[2] per `BUG_DIAGNOSES_2026_05_29.md`). Result:

```
master PTP_CTRL=0x0000000d  HW_SYNC_CTRL=0x05  HW_SYNC_STATUS=0x01
master PTP_STATUS=0x00000001 (master's bit 0 — possibly TX-side enable echo)
slave  PTP_CTRL=0x00000001 (note: tried to write 0x05, only bit 0 stuck)
slave  PTP_STATUS=0x00000000 bit[2]=0 ← Bug B
slave  PTP_RX_PAYLOAD=0x00000000  ← Bug B confirmed
slave  HW_SYNC_STATUS=0x00000000 (initiator-side, expected on slave)
```

**Result**: Bug B is real — slave's ptp_rx_valid_r never asserts and PTP_RX_PAYLOAD stays 0 even with master HW_SYNC initiator active. But this is on build #4 where ALL FC traffic is broken, so it does not isolate Bug B from the build #4 regression.

## Recommended next steps

1. **Revert the build #4 mark_debug additions and rebuild** — start with just the `pair_credit_counter` probe removed, then add probes back incrementally to find which one(s) broke the returner.
2. **Re-test on a clean power-cycle of bridge1** to get a clean baseline measurement.
3. **OR**: keep build #4 but accept that returner-busy means we can only ILA-capture link-up + bringup — not application-layer traffic.
4. **Once a working ILA build exists**, run the original audit's 3-trigger ILA capture for Bugs A + B.

## Lease released at end of session.

Lease at 18:30, work complete at 19:00, releasing now to free the rig.

## Operational notes

- Build #4 .bit/.bin/.ltx + manifests are at `imp/fpga/output/pynq-z2-pair-{all,flip-all}/` locally + staged on mapstone-dev under `/tmp/tidelink_deploy/` (current symlinks point at restored build #3; build #4 is at `*.build4-bak`).
- Build #3 was restored on mapstone-dev for the comparison; both versions are recoverable via the `.build3-bak`/`.build4-bak` siblings.
- The `tidelink_design_wrapper.ltx` from build #4 is identical between master and slave (md5 `077c0a42…`) — same probe layout both sides.

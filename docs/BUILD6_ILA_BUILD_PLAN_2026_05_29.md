# Build #6 — Surgical ILA Build Plan (Bug A deeper RX-framer wedge)

**Date:** 2026-05-29
**Branch:** `feat/td-gpio-phy-integration` (or feature branch for build #6 to be decided by parent)
**Baseline:** HEAD of `feat/td-gpio-phy-integration` PLUS the build #5 patch applied (build #5 currently running — wait for verdict).
**Submodule:** `deps/axi-chiplet-controller` @ `9ad2570` (unchanged from build #5)
**Patch:** [BUILD6_ILA_PROBE_PATCH_2026_05_29.patch](BUILD6_ILA_PROBE_PATCH_2026_05_29.patch)
**Predecessor diagnostic:** Build #5 verdict (when available) — surgical R-1 test + Bug-B probes
**Bug A oracle:** V1 diagnosis — slave RX framer NACK-worthy-decodes master's data pkt → latches `send_nack_req` → FCSM bounces back to state 4 (RX FIFO never drains)

---

## 1. Strategy

Build #5 isolated R-1 (the `pair_credit_counter` mark_debug fold) and added the Bug-B PTP probes. Build #6 layers on **only** Bug-A-specific FCSM decode probes inside `WlinkGenericFCSM_6.v` — the exact predicates V1 identified as the next-round needs to distinguish:

1. "Is the master's packet being decoded as a data pkt at all on the slave RX?" → `pkt_is_data_pkt`
2. "After it lands in the rx→tx hand-off FIFO, what does the FCSM classify it as?" → `isExpPacket`, `crcCorruptSeen`, `isNotExpPacket_l7`
3. "Does the L7 forgive gate stay armed or re-disarm?" → `socl_l7_reached_link_data`, `socl_l7_bringup_forgive`
4. "Does the NACK request reg actually latch and push FCSM into state 7?" → `send_nack_req`
5. "Is the byte-counter expiration condition true?" → `_T_54`

**Strict additive policy.** No build #5 probe is touched. No build #4 probe is touched. Build #5's R-1 verdict is preserved cleanly — build #6 cannot regress build #5 because every kept mark_debug is identical to build #5.

If build #6 PASSES (link still functional in steady state, no new master-stuck-at-7 regression) → capture the slave FCSM decode path under doorbell traffic and pinpoint which predicate (data_pkt / exp / nack / forgive) is firing wrong.

If build #6 FAILS the same way build #4 did (returner stuck, FCSM=7/4) → one of the 8 new probes folded with FCSM state. Build #7 then bisects this set in halves.

---

## 2. Probe table — Build #6

### 2.1 Kept from build #5 (no change)

Every mark_debug attribute in the build #5 patch is preserved verbatim. See `docs/BUILD5_ILA_BUILD_PLAN_2026_05_29.md` §2.1 + §2.3 for the full kept set:

- `tl_fc_a2l_*`, `tl_fc_l2a_*`, `tx_router_idle`, `ptp_sp_*`, `fc_rx_fifo_*` (build #4 baseline)
- `rx_state_r`, `rx_pkt_type`, `rx_is_fifo` (build #4 baseline)
- `ptp_enable_r`, `hw_sync_force_en_r`, `hw_seq_num_r`, `tx_pending_r`, ... (PHC Phase-1 baseline)
- `tl2wl_io_obs_fcsm_state`, `cr_pkt_seen_rx`, `crack_pkt_seen_rx`, `pkt_is_cr_pkt`, `pkt_is_crack_pkt` (LL_RX baseline)
- `llrx_io_obs_state`, `is_short_pkt`, `is_long_pkt`, `valid` (LL_RX baseline)
- `swi_training_mode_rxsync_{0,1}`, `dbg_*` (autoneg baseline)
- `hw_sync_state_r`, `phc_time_reached`, `target_ns_r`, `target_seconds_r`, `hw_sync_interval_r`, `tx_state_r` (Bug-B added in build #5)
- `tx_fifo_io_wfull`, `rempty`, `auto_tx_out_sop`, `advance` in `ShortPacketToWlink.v` (submodule, kept)

### 2.2 Removed in build #6

**Nothing.** Build #5 already removed `pair_credit_counter` + `pair_credit_counter_en` (R-1 suspects). If build #5 passes the regression test, those stay removed. If build #5 fails, build #6 should NOT launch as-is — go to build #7 reverting build #5's §2.4 candidates instead (see Risk register).

### 2.3 Added in build #6 (Bug A deeper probes)

| File | Line | Signal | Bits | Clock | Risk | Why |
|---|---|---|---|---|---|---|
| `src/rtl/local_overrides/WlinkGenericFCSM_6.v` | 284 | `pkt_is_data_pkt` | 1 | `io_rx_clk` | low | "Is the master pkt decoded as a data pkt?" Pure combinational wire of `sop & valid & data_id==swi_data_id_1 & ~crc_corrupt`. |
| ↑ | 318 | `isExpPacket` | 1 | `io_tx_clk` | low | FIFO-side: was the packet classified as expected pktnum? Comb wire of `ack_nack_fifo_io_rdata[18:16]==3'h0`. |
| ↑ | 322 | `crcCorruptSeen` | 1 | `io_tx_clk` | low | One of the two drivers that re-arms `send_nack_req` in steady state. |
| ↑ | 366 | `send_nack_req` | 1 | `io_tx_clk` | low | The signal that pushes FCSM→7→4. Same clock domain as `state` (already probed). |
| ↑ | 380 | `socl_l7_reached_link_data` | 1 | `io_tx_clk` | low | L7 sticky witness — latches first time `state==5` is observed. |
| ↑ | 381 | `socl_l7_bringup_forgive` | 1 | `io_tx_clk` | low | Combinational L7 forgive gate; nulls `send_nack_req` when high. |
| ↑ | 387 | `isNotExpPacket_l7` | 1 | `io_tx_clk` | low | The other steady-state `send_nack_req` driver, L7-masked. |
| ↑ | 402 | `_T_54` | 1 | `io_tx_clk` | low | FCSM byte counter == 0; gates LINK_DATA exit back to state 4. |

**Net probe budget delta:** +8 bits added, 0 removed → ~1 extra net group in the ILA macro. Well within the 30-bit headroom and well within debug-core depth.

### 2.4 Risky probes considered but NOT added

- `pkt_is_ack_pkt` / `pkt_is_nack_pkt` (lines 291, 293) — same clock domain, same risk class as `pkt_is_data_pkt`. Useful for context but not on V1's required list. Defer to build #7 if build #6's smoking-gun probe set doesn't isolate.
- `ack_nack_fifo_valid` (line 311) — would tell us whether the FIFO produced any output at all; redundant with isExpPacket since that ANDs with ack_nack_fifo_valid. Skip.
- `last_good_pkt_from_rx` (8 bits, line 367) — useful for diagnosing pktnum mismatch but pushes us toward the 30-bit budget for no immediate benefit. Defer.
- `state` reg directly inside FCSM_6 (line 276, 3 bits) — already exposed via `tl2wl_io_obs_fcsm_state` (Wlink.v:249, already mark_debug'd in build #4). Probing the in-FCSM reg directly would be a duplicate; skipped.

### 2.5 Build #6 → build #7 escalation path (if needed)

If build #6's probe set doesn't fully isolate the wedge, build #7 should add:
- `pkt_is_ack_pkt`, `pkt_is_nack_pkt` (2 bits)
- `last_good_pkt_from_rx[7:0]`, `exp_pkt_num[7:0]` (16 bits, to compare expected vs actual)

That's another +18 bits; total Build #6 + #7 would still fit in the 30-bit envelope.

---

## 3. Build target + command

### 3.1 Target choice

Use `pynq-z2-pair-all` + `pynq-z2-pair-flip-all` with `FPGA_INSERT_DEBUG_CORE=1` — same as builds #4 and #5. Do NOT use `pynq-z2-pair-flip-ila` (different ILA scheme; lane-level BD capture, not mark_debug scrape).

### 3.2 Pre-flight check (parent runs BEFORE build kicks)

```bash
# 0. GATE — wait for build #5 verdict. Build #6 cannot launch until #5
#    is decided because the patches stack.
#    - If build #5 PASSED → proceed below.
#    - If build #5 FAILED (R-1 falsified) → STOP. Build #6 plan does not
#      apply; the correct next step is build #7-style revert of build #5
#      §2.4 candidates (rx_state_r etc), not adding more probes.

cd /home/dam1n19/SoCLabs/tidelink

# 1. Apply build #5 patch first (if not already applied) — build #6
#    layers on top of #5.
git apply --check docs/BUILD5_ILA_PROBE_PATCH_2026_05_29.patch || true
# If clean (no error): git apply docs/BUILD5_ILA_PROBE_PATCH_2026_05_29.patch

# 2. Apply build #6 patch
git apply --check docs/BUILD6_ILA_PROBE_PATCH_2026_05_29.patch
# If header counts bobble: fall back to the manual Edit recipe inside the
# .patch doc (each is a unique-string Edit; the project has a recurring
# @@ header count bug — recipe-fallback is documented in the patch).

git apply docs/BUILD6_ILA_PROBE_PATCH_2026_05_29.patch

# 3. Sim gate (~7 min)
cd cocotb/tidelink_top_pair
timeout 600 make MODULE=test_role_lock_and_cal_done \
    SIM_BUILD=sim_build_b6 TB_TOP_NO_DUMP=1 \
    TESTCASE=test_01_role_lock_and_cal_done
# expect: PASS — same gate as builds #4/#5. The 8 new mark_debug attrs do
# not change RTL behaviour, only synthesis-net visibility, so sim should
# match build #5.

# 4. Lease check
ssh mapstone-dev "fpgahub pair status tidelink_bridge_01"
fpgahub pair up tidelink_bridge_01 --ttl 7200
# Must be GRANTED, not queued (per memory feedback_lease_grant_before_deploy).
```

### 3.3 Build command

```bash
cd /home/dam1n19/SoCLabs/tidelink
source set_env.sh
FPGA_INSERT_DEBUG_CORE=1 make -C fpga build_pair_farmed FARM_HOST=srv04936
```

Serial fallback (if srv04936 not available):
```bash
FPGA_INSERT_DEBUG_CORE=1 make -C fpga build_pair_concurrent
```

### 3.4 Expected wall time

~55 min end-to-end (concurrent farm, master local + slave srv04936).
~70-80 min if serial.

### 3.5 Expected outputs

```
imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,bin,hwh}
imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper.ltx
imp/fpga/output/pynq-z2-pair-flip-all/tidelink.{bit,bin,hwh}
imp/fpga/output/pynq-z2-pair-flip-all/tidelink_design_wrapper.ltx
```

Both `.ltx` files should have identical md5 (same probe set on both halves).

---

## 4. Post-build deploy + ILA capture

### 4.1 Deploy

```bash
ssh mapstone-dev "fpgahub pair status tidelink_bridge_01"   # verify granted
bash pynq_host/scripts/deploy_pair.sh
```

### 4.2 Stage .ltx

```bash
scp imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper.ltx \
    mapstone-dev:/tmp/tidelink_deploy/master.ltx
scp imp/fpga/output/pynq-z2-pair-flip-all/tidelink_design_wrapper.ltx \
    mapstone-dev:/tmp/tidelink_deploy/slave.ltx
```

### 4.3 Live state sample (before triggering)

Sample REG_STATUS on both sides without writing SWI_TRAINING_MODE.

Build #6 baseline-OK signature (no regression vs build #5):
- master REG_STATUS = 0x00 (returner_busy=0, no underrun)
- slave REG_STATUS = 0x00 OR 0x04 (sticky underrun from prior session OK)
- master FCSM (via APB obs) = 4 or 5 — NOT 7 (state 7 = build #4 regression)
- slave FCSM = 4 or 5

### 4.4 Trigger 1 — Bug A deeper probe (PRIMARY)

Goal: prove which decode predicate causes the slave to NACK-bounce.

```bash
# Drive doorbell traffic master→slave (100 rings)
# Slave ILA setup:
#   Trigger condition (compound):
#     - llrx_io_obs_valid rising   (master pkt landed on slave RX)
#     AND
#     - send_nack_req rising       (NACK reg about to latch)
#   Capture window: ≥ 4096 samples post-trigger
#
# Master ILA setup (parallel):
#   Trigger condition:
#     - tl_fc_a2l_valid rising     (FC RX FIFO push from master side)
#   Capture window: ≥ 4096 samples
#
# Decode:
#   - If pkt_is_data_pkt=0 on slave when llrx_io_obs_valid=1 → RX framer
#     decodes the master's pkt as something OTHER than data (wrong data_id
#     or crc_corrupt=1) → look at corrected_ph + ECC signals next round.
#   - If pkt_is_data_pkt=1 but isExpPacket=0 and isNotExpPacket_l7=1 →
#     pktnum mismatch in steady state. L7 forgive gate failed to re-arm
#     after first LINK_DATA → check socl_l7_reached_link_data sticky.
#   - If isExpPacket=1 but send_nack_req=1 → it's the crcCorruptSeen path.
#   - If send_nack_req stays at 1 and never clears → socl_l7_bringup_forgive
#     should be high (steady-state recovery) but isn't.
#   - If _T_54 oscillates fine and state transitions 4→5→4 → byte counter
#     is healthy; problem is elsewhere on the rx framer side.
```

### 4.5 Trigger 2 — Build #5 Bug B capture (orthogonal, kept)

Same as `docs/BUILD5_ILA_BUILD_PLAN_2026_05_29.md` §4.5 — `hw_sync_state_r` trigger on `HW_SYNC_FIRE` (2'b10). Build #6 keeps all those probes.

---

## 5. Risk register

| Risk | Mitigation |
|---|---|
| Build #5 fails before build #6 launches | §3.2 GATE step 0 — do not launch if build #5 fails. Build #6 plan assumes build #5 passed. |
| One of the 8 new mark_debug attrs folds with FCSM `state` reg | All 8 are in the same FCSM scope and same clock domains as already-mark_debug'd siblings (`pkt_is_cr_pkt`, `pkt_is_crack_pkt`, `cr_pkt_seen_rx`). Those built clean in #4. Probability of a fold regression: ~10%. If observed, build #7 bisects the 8 in halves. |
| Wlink.v `tl2wl_io_obs_*` aliases needed to reach FCSM internals | Not needed for build #6. The new probes are attributed directly inside WlinkGenericFCSM_6.v at the wire/reg declaration sites. Vivado tracks mark_debug through the local_overrides flist path. |
| Patch @@ header counts bobble | Manual Edit recipe section embedded inside the .patch doc. Each old_string is unique in the file. |
| Lease not granted at deploy | §3.2 step 4 + memory `feedback_lease_grant_before_deploy.md`. |
| RX-domain probe `pkt_is_data_pkt` doesn't capture cleanly because ILA is hclk-sampled | Existing `llrx_io_obs_valid` is also rx-domain and captures fine on build #4. Same pattern. |

---

## 6. Decision criteria for next step

| Build #6 result | Implication | Next step |
|---|---|---|
| Link still functional + Bug A decode visible in ILA | Probes work; root-cause analysis can proceed | Capture under doorbell traffic, decode per §4.4, propose L9 fix |
| Link functional but Bug A doesn't trigger (no NACK on slave) | Either Bug A is already fixed by L8 (build #5) or the trigger condition needs tuning | Re-trigger with different conditions; possibly Bug A is gone — verify RX FIFO actually drains |
| Returner stuck / FCSM=7/4 (regression) | One of the 8 new attrs folded | Build #7: bisect — first half (lines 284, 318, 322, 366) vs second half (lines 380, 381, 387, 402) |
| Timing fails | Unlikely at +8 bits | Drop the wider RX-domain probe pair (pkt_is_data_pkt) and retry |

---

## 7. Files in this plan

- Patch: [BUILD6_ILA_PROBE_PATCH_2026_05_29.patch](BUILD6_ILA_PROBE_PATCH_2026_05_29.patch)
- This plan: `docs/BUILD6_ILA_BUILD_PLAN_2026_05_29.md`
- Predecessor: [BUILD5_ILA_BUILD_PLAN_2026_05_29.md](BUILD5_ILA_BUILD_PLAN_2026_05_29.md)
- Build #4 regression diagnosis: [BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md](BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md)
- Bug A oracle (V1 diagnosis): [BUG_A_FINAL_SYNTHESIS_2026_05_29_EVENING.md](BUG_A_FINAL_SYNTHESIS_2026_05_29_EVENING.md), [BUG_A_FORCE_EXPERIMENTS_2026_05_29.md](BUG_A_FORCE_EXPERIMENTS_2026_05_29.md)

**Status:** READY for parent to review. Build #5 must be decided before #6 kicks. This plan does not launch the build.

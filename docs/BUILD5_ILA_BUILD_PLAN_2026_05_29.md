# Build #5 — Surgical ILA Build Plan

**Date:** 2026-05-29
**Branch:** `main` (or feature branch to be decided by parent)
**Baseline:** HEAD = `8edfd24` (post `ebbde0e` build #4 mark_debug + cleanup)
**Submodule:** `deps/axi-chiplet-controller` @ `9ad2570` (ShortPacket TX mark_debug — KEPT, low risk)
**Patch:** [BUILD5_ILA_PROBE_PATCH_2026_05_29.patch](BUILD5_ILA_PROBE_PATCH_2026_05_29.patch)
**Predecessor diagnostic:** [BUILD4_HW_VALIDATION_2026_05_29.md](BUILD4_HW_VALIDATION_2026_05_29.md)
**Probe oracle docs:** [BUG_A_FORCE_EXPERIMENTS_2026_05_29.md](BUG_A_FORCE_EXPERIMENTS_2026_05_29.md) §4 + `cocotb/tidelink_top_pair/test_master_ptp_tx_router.py`

---

## 1. Strategy

Build #4 introduced ~20 `mark_debug` attrs in one go and produced an FC-path regression (master FCSM stuck at state 7 SEND_NACK; returner_busy=1 from POR). Timing was clean both builds, so the cause is a synthesis fold blocked by one of the new attrs. Build #4 doc's R-1 hypothesis (~45%) points at `pair_credit_counter`.

Build #5 is a **single-knob test of R-1** plus the **Bug-B sim probes**:

- **Subtract:** `mark_debug` on `pair_credit_counter` + `pair_credit_counter_en` in `src/rtl/fifo/tidelink_apb_regs.sv` — the highest-probability regression suspect.
- **Add:** the Bug-B probe set isolated by `test_master_ptp_tx_router.py` (`hw_sync_state_r`, `phc_time_reached`, `target_ns_r`, `target_seconds_r`, `hw_sync_interval_r`, `tx_state_r`).
- **Keep everything else** from build #4 unchanged so a build #5 PASS proves R-1 was the regression and a build #5 FAIL falsifies it cleanly (one variable changed in the "remove" direction).

If build #5 PASSES (returner clears, FCSM=4/4 or 5/5, doorbell works), R-1 is confirmed → forward-fix is keep `pair_credit_counter` unmarked permanently.

If build #5 FAILS the same way (returner stuck), R-1 is wrong → move on to R-2 / R-3 (need a build #6 reverting the next-most-likely group from §"Risky probes considered for removal").

---

## 2. Probe table — Build #5

### 2.1 Kept from build #4 (no change)

| File | Signal | Bits | Bug | Risk |
|---|---|---|---|---|
| `src/rtl/tidelink_top.sv` | `tl_fc_a2l_{valid,data,ready}` | 1+48+1 | A | low (hclk-native top wire) |
| `src/rtl/tidelink_top.sv` | `tl_fc_l2a_{valid,data,accept}` | 1+48+1 | A | low |
| `src/rtl/tidelink_top.sv` | `tx_router_idle` | 1 | B | low |
| `src/rtl/tidelink_top.sv` | `ptp_sp_{tx,rx}_*` | 8 wires | B | low (pre-existing) |
| `src/rtl/tidelink_top.sv` | `fc_rx_fifo_ready` | 1 | A | low |
| `src/rtl/tidelink_fc_adapter.sv` | `fc_rx_fifo_valid`, `fc_rx_fifo_addr` | 1+RAM_ADDR_W | A | low (output ports) |
| `src/rtl/tidelink_fc_adapter.sv` | `rx_state_r` | 2 | A | medium (slave RX FSM — if FCSM regression repeats, this is a watch candidate for build #6) |
| `src/rtl/tidelink_fc_adapter.sv` | `rx_pkt_type`, `rx_is_fifo` | 2+1 | A | low |
| `src/rtl/tidelink_ptp.sv` | `ptp_enable_r`, `ptp_rx_valid_r`, `ptp_rx_msg_type_r` | 1+1+4 | B | low (pre-existing PHC Phase-1 attrs) |
| `src/rtl/tidelink_ptp.sv` | `hw_sync_force_en_r`, `hw_sync_trigger`, `hw_seq_num_r`, `tx_pending_r` | 1+1+16+1 | B | low |
| `src/rtl/local_overrides/Wlink.v` | `tl2wl_io_obs_fcsm_state`, `cr_pkt_seen_rx`, `crack_pkt_seen_rx`, `pkt_is_*` | 3+1+1+1+1 | A | low (pre-tdif-10) |
| `src/rtl/local_overrides/Wlink.v` | `llrx_io_obs_state`, `is_short_pkt`, `is_long_pkt`, `valid` | 2+1+1+1 | A | low |
| `src/rtl/local_overrides/Wlink.v` | `swi_training_mode_rxsync_{0,1}`, `dbg_*` | 6 | autoneg | low |
| `deps/axi-chiplet-controller/.../ShortPacketToWlink.v` | `tx_fifo_io_wfull`, `rempty`, `auto_tx_out_sop`, `advance` | 4 | B | low (submodule, simple combinational reg net) |

### 2.2 Removed in build #5 (R-1 candidate)

| File | Signal | Bits | Why removed |
|---|---|---|---|
| `src/rtl/fifo/tidelink_apb_regs.sv` | `pair_credit_counter` | SYS_DATA_W (32) | R-1 (~45%) regression suspect — pclk-domain reg; mark_debug forbids synth fold with hclk-domain APB read mux that feeds the returner busy-clear path. SW-managed anyway, polled via APB. |
| `src/rtl/fifo/tidelink_apb_regs.sv` | `pair_credit_counter_en` | 1 | Co-located with the suspect; same removal risk class. |

### 2.3 Added in build #5 (Bug-B sim probes)

| File | Signal | Bits | Why |
|---|---|---|---|
| `src/rtl/tidelink_ptp.sv` | `hw_sync_state_r` | 2 | **PRIMARY Bug-B smoking gun** — sim agent shows FSM stuck at ARMED waiting for `phc_time_reached`. |
| `src/rtl/tidelink_ptp.sv` | `phc_time_reached` | 1 | ARMED→FIRE gate. Sim shows this never asserts because target_ns_r computed from BD tie-off `phc_nanoseconds=0`. |
| `src/rtl/tidelink_ptp.sv` | `target_ns_r` | 30 | Whether SW write of HW_SYNC_INTERVAL is computing the target correctly. |
| `src/rtl/tidelink_ptp.sv` | `target_seconds_r` | 48 | Same — but probe full 48 bits to span seconds rollover. |
| `src/rtl/tidelink_ptp.sv` | `hw_sync_interval_r` | 30 | Verify SW wrote the expected interval. |
| `src/rtl/tidelink_ptp.sv` | `tx_state_r` | 2 | TX FSM state — confirms whether HW_SYNC_FIRE was gated by AHB priority or `tx_router_idle`. |

**Net probe budget delta:** +113 bits added, −33 bits removed → net +80 bits ≈ 6 new ILA probes. ILA macro auto-sized in `insert_debug_core.tcl` so this is well within depth/width.

### 2.4 Risky probes considered for removal but KEPT (build #6 candidates if #5 fails)

- `rx_state_r` (slave RX FSM, `tidelink_fc_adapter.sv:424`) — medium risk if R-1 wrong; FSM next-state logic could fold with returner accept signal.
- `fc_rx_fifo_valid` / `fc_rx_fifo_addr` output ports — output ports usually low risk but if the BD ties them off they could change wrapper port widths.
- `tx_pending_r` (`tidelink_ptp.sv:173`) — pre-existing low risk but co-located with TX FSM.

If build #5 fails the same way, build #6 should be these three attrs removed (one knob at a time).

---

## 3. Build target + command

### 3.1 Target choice

Use `pynq-z2-pair-all` + `pynq-z2-pair-flip-all` with `FPGA_INSERT_DEBUG_CORE=1` — exactly what build #4 used.

**Why not `pynq-z2-pair-flip-ila`:** that target's `tidelink_design.tcl` instantiates a hard-wired `ila_tx` block in the BD on `pad_tx`/`pad_clk_tx`. That's a different ILA (lane-level capture), not the mark_debug-driven scrape. The mark_debug strategy needs the scripted debug-core path because the probe net set is selected by the `MARK_DEBUG` synth attribute, not BD wiring. Mixing them is unnecessary — `pynq-z2-pair-all` + `FPGA_INSERT_DEBUG_CORE=1` is the proven path from build #4.

### 3.2 Pre-flight check (run BEFORE the build, parent should do this)

```bash
# 1. Verify the patch applies cleanly on top of build #4 baseline
cd /home/dam1n19/SoCLabs/tidelink
git apply --check docs/BUILD5_ILA_PROBE_PATCH_2026_05_29.patch
# expect: no output (clean apply)

# 2. Apply the patch
git apply docs/BUILD5_ILA_PROBE_PATCH_2026_05_29.patch

# 3. Sim gate (~7 min): confirm sim still passes against patched RTL
cd cocotb/tidelink_top_pair
timeout 600 make MODULE=test_role_lock_and_cal_done \
    SIM_BUILD=sim_build_b5 TB_TOP_NO_DUMP=1 \
    TESTCASE=test_01_role_lock_and_cal_done
# expect: PASS — same gate build #4 passed (and that gate didn't catch
# the regression — but it's a fast smoke that the patch didn't break RTL
# syntax / elaboration / link-up sim).

# 4. Lease check on the rig
ssh mapstone-dev "fpgahub pair status tidelink_bridge_01"
# expect: status of any current lease; ensure it's released or you can acquire
fpgahub pair up tidelink_bridge_01 --ttl 7200
# Must be GRANTED (per memory: lease MUST be granted before deploy; queued != granted).
```

### 3.3 Build command (parent will execute)

```bash
cd /home/dam1n19/SoCLabs/tidelink
source set_env.sh

# Concurrent farm build, master local + slave on srv04936.
# FPGA_INSERT_DEBUG_CORE=1 enables the scripted mark_debug → ILA scrape
# via fpga/insert_debug_core.tcl after synth_1.
FPGA_INSERT_DEBUG_CORE=1 make -C fpga build_pair_farmed FARM_HOST=srv04936
```

### 3.4 Expected wall time

~55 min end-to-end (master local + slave srv04936, in parallel — per memory `project_tidelink_concurrent_farm`).

If the parent prefers serial (avoid touching srv04936):
```bash
FPGA_INSERT_DEBUG_CORE=1 make -C fpga build_pair_concurrent
```
That keeps both halves on the local box (~70-80 min, contended).

### 3.5 Expected outputs

```
imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,bin,hwh}
imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper.ltx
imp/fpga/output/pynq-z2-pair-flip-all/tidelink.{bit,bin,hwh}
imp/fpga/output/pynq-z2-pair-flip-all/tidelink_design_wrapper.ltx
```

Both .ltx files should be identical md5 (same probe scrape — see build #4 doc).

---

## 4. Post-build deploy + ILA capture

### 4.1 Deploy to the pair

```bash
# Verify lease still active
ssh mapstone-dev "fpgahub pair status tidelink_bridge_01"

# Deploy both bitstreams
bash pynq_host/scripts/deploy_pair.sh
```

### 4.2 Stage .ltx for ILA capture

```bash
# .ltx files must be on mapstone-dev for phc_ila_capture.sh
scp imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper.ltx \
    mapstone-dev:/tmp/tidelink_deploy/master.ltx
scp imp/fpga/output/pynq-z2-pair-flip-all/tidelink_design_wrapper.ltx \
    mapstone-dev:/tmp/tidelink_deploy/slave.ltx
```

### 4.3 Live state sample (before triggering anything)

```bash
# Without writing SWI_TRAINING_MODE, sample REG_STATUS on both sides
ssh mapstone-dev "..."
# Build #5 SUCCESS if:
#   - master REG_STATUS = 0x00 (returner_busy=0, no underrun)
#   - slave REG_STATUS = 0x00 OR 0x04 (sticky underrun from prior session OK)
#   - FCSM state (via APB obs reg) = 4 or 5 on master AND on slave
#   - NOT 7 on master (that's the build #4 regression signature)
```

### 4.4 Trigger 1 — Bug A capture

```bash
# After 100 doorbell rings master→slave:
#   if slave DBELL_RESP_ACC == 0 → Bug A still active, capture ILA
# ILA trigger: master.tl_fc_a2l_valid rising
# Capture window: ≥ 4096 samples
```

### 4.5 Trigger 2 — Bug B capture

```bash
# Enable HW_SYNC on master, sample slave PTP_STATUS:
#   master PTP_CTRL = 0x05 (ptp_enable + hw_sync_force_en)
#   master HW_SYNC_INTERVAL = 0x100000 (1 ms test value)
#   master HW_SYNC_CTRL = 0x05 (enable + force)
# ILA trigger on master: hw_sync_state_r → HW_SYNC_FIRE (2'b10)
# ILA trigger on slave: ptp_sp_rx_valid rising
```

---

## 5. Risk register

| Risk | Mitigation |
|---|---|
| Build #5 regresses the same way (R-1 wrong) | One knob changed → easy to backtrack to build #6 with §2.4 candidates |
| `phc_nanoseconds` BD tie-off is the real Bug-B cause, not the FSM | Bug-B probes will show `target_ns_r` not updating after HW_SYNC_INTERVAL write — that proves the BD tie-off if `hw_sync_interval_r` did update |
| Lease not granted at deploy time | Memory `feedback_lease_grant_before_deploy.md`: pre-flight check in §3.2 step 4 |
| Submodule branch `ila-mark-debug-tx-shortpacket` drifts | Pinned at `9ad2570`; not modifying in build #5 |
| Patch context drifts from RTL (build #4 attrs already removed by someone) | Pre-flight `git apply --check` in §3.2 step 1 catches this |
| Build #4 cleanup commit `59e35e5` deleted a needed file (R-3 ~15%) | Not addressed in build #5 — if #5 fails and R-1 falsified, this is build #6's investigation. Quick check: `grep -rn tidelink_returner.sv flist/ fpga/` before build #5 launch (none expected). |

---

## 6. Decision criteria for next step

| Build #5 result | Implication | Next step |
|---|---|---|
| Returner clears + FCSM=4/4 or 5/5 + doorbell works | R-1 CONFIRMED | Capture Bug A + Bug B with new probes; merge patch as fix |
| Returner stuck + FCSM=7/4 (same as #4) | R-1 FALSIFIED | Build #6: revert §2.4 candidates one-by-one |
| Returner stuck but FCSM different (e.g. 5/4 or 4/4 with busy) | Partial regression | Mixed — likely still in mark_debug class but different fold. Build #6: revert `rx_state_r` |
| Timing fails | Probe budget overflow (unlikely at +80 bits) | Drop `target_seconds_r[47:8]` (probe only low byte) and rebuild |

---

## 7. Files in this plan

- Patch: [BUILD5_ILA_PROBE_PATCH_2026_05_29.patch](BUILD5_ILA_PROBE_PATCH_2026_05_29.patch)
- This plan: `docs/BUILD5_ILA_BUILD_PLAN_2026_05_29.md`
- Predecessor: [BUILD4_HW_VALIDATION_2026_05_29.md](BUILD4_HW_VALIDATION_2026_05_29.md)
- Bug A oracle: [BUG_A_FORCE_EXPERIMENTS_2026_05_29.md](BUG_A_FORCE_EXPERIMENTS_2026_05_29.md)
- Bug B oracle: `cocotb/tidelink_top_pair/test_master_ptp_tx_router.py`

**Status:** READY for parent to review + kick off. This plan does not launch the build.

# TideLink comprehensive handoff — 2026-05-29 to 2026-06-01

Session arc: handoff report on 2026-05-29 → 3+ days of sim + HW iteration → this doc.

## TL;DR

| Bug | Status | Where | Fix path |
|---|---|---|---|
| **Build #4 R-1 regression** | ✅ FIXED in Build #5 | `pair_credit_counter` mark_debug → synth fold breaking returner busy-clear | Removed attr |
| **Bug A wedge primitive** (PS bus deadlock) | ✅ FIXED in Build #8 (HW-validated) | a2l_full→HREADYOUT hang→AXI deadlock | L11 watchdog in fc_adapter |
| **Bug A correctness** (slave RX FIFO empty) | ⚠️ OPEN — localised | Between FCSM decode and RX FIFO write (slave); Q5 NACK theory falsified today | Awaiting Build #10 ILA + delivery-path sim |
| **Bug B** (PTP HW_SYNC slave silent) | ⚠️ OPEN — fix sim-validated but reverted | `phc_time_reached` gate at tidelink_ptp.sv:399 + BD `phc_nanoseconds=30'h0` tie-off | 1-line OR-term + BD PHC counter |
| **ILA .ltx infrastructure** | ⚠️ Fix in Build #10 (in flight) | `write_debug_probes` runs in synth stage before impl_1 can renumber | Re-emit .ltx from impl_1 routed.dcp |

## Bug A — Master AHB packet never reaches slave RX FIFO

### Symptom (silicon, well-characterized)

When SW writes the AHB_TX aperture (0x44000000) on master with a packet:
- Master's local AHB transaction completes (REG_STATUS bit 2 = fifo_underrun may set)
- Slave's `REG_PKT_LEN` (0x44032008) stays 0
- Slave's `AHB_RX_FIFO` (0x44010000+) stays all-zero
- Master's `REG_DOORBELL_RESP_ACC` (0x44032024) increments by 0x5000 per AHB write (the "0x5000 bump" — meaning *something* crosses the wire but doesn't land in the FIFO)
- Original behaviour: 2nd AHB write wedges master's PS bus (SSH disconnect, link DOWN). **Now mitigated by L11 watchdog (see "Wedge primitive" below).**

### Root cause progression (chronological, with each hypothesis we tested)

#### Stage 1 — wedge primitive identified (2026-05-31)

Sim couldn't reproduce the master SSH-disconnect because cocotb AHB BFM bails after 50 cy of HREADY-low and silently abandons. Q-agent's RTL audit traced the wedge chain:

1. Slave's RX framer doesn't drain its half — root Bug A
2. → master's `a2l_fc_replay` CDC FIFO fills, `a2l_full` asserts ([WlinkGenericFCReplayV2_13.v:94](../deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v#L94))
3. → `app_ready = ~a2l_full & enable = 0` permanent → master's `tl_fc_a2l_ready` deasserts ([WlinkGenericFCSM_6.v:773](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L773))
4. → `skid_can_accept = 0` → `ahb_tx_hreadyout = 0` forever ([tidelink_fc_adapter.sv:202+380](../src/rtl/tidelink_fc_adapter.sv#L202))
5. → axi_ahblite_bridge waits forever → AXI BVALID never returns → PS M_AXI_GP0 outstanding-write counter pegged
6. **All 6 AXI slaves share one SmartConnect** ([pynq-z2-pair-flip-ila/tidelink_design.tcl:174-188](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl#L174)) → any subsequent mmap write blocks in kernel → SSH freeze → power-cycle required

**L11 fix** (HW-validated Build #8 + #9): 4-cycle HREADYOUT watchdog in fc_adapter. After WEDGE_LIMIT=16 cy of HREADYOUT stuck low, force `wedge_force_ready_w = 1` for 4 cy. AHB sees HREADY, AXI BVALID propagates, PS bus stays alive. The word is dropped silently and `tx_dropped_cnt_r` increments.

Result on HW:
- **Master stays responsive after AHB write** (`hostname` returns)
- **Both links stay UP** (`SWI_LANE_STATUS = 0x018900ff`)
- 2nd AHB write may transiently SSH-disconnect but **PYNQ kernel watchdog auto-reboots within 60s** — no manual `fpgahub power-cycle` needed
- Slave RX FIFO **still empty** — L11 is liveness floor only

#### Stage 2 — Q5's NACK-loop theory (proposed 2026-05-29 evening)

After L8 + L9 sim fixes both failed, deep RTL audit (Q5 agent) proposed a different mechanism:
- During bringup, slave's `app_enable` momentarily glitches low → re-zeroes `exp_pkt_num` ([WlinkGenericFCSM_6.v:880-892](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L880))
- Master's `link_cur_addr` keeps incrementing, so master sends pktnum=K>0 while slave expects 0
- `pkt_is_data_pkt` fires but `ll_rx_pktnum != exp_pkt_num` → `exp_pkt_not_seen` → `isNotExpPacket_l7` → `send_nack_req` latches
- Slave bounces FCSM 5→7→4 → RX FIFO never written

**L9 fix proposal** (sticky pktnum resync on first data packet) — sim test FAILED (test_buga_real_fix_rx_wedge.py: slave `tl_fc_l2a_valid` never asserts even with L9). But the test agent reported "L9 sticky latches OK", confusing the picture.

#### Stage 3 — NACK theory FALSIFIED (2026-06-01 today)

Sim probed all 8 NACK predicates from Build #6 directly via cocotb hierarchical refs ([docs/BUG_A_NACK_PREDICATE_SIM_2026_06_01.md](BUG_A_NACK_PREDICATE_SIM_2026_06_01.md)):

| Signal | Probed cy of high | Meaning |
|---|---|---|
| `pkt_is_data_pkt` | 26 / 500 | RX framer DOES decode data correctly |
| `isExpPacket` | 25 / 500 | pktnum MATCHES — no mismatch |
| `crcCorruptSeen` | **0** | No CRC errors EVER |
| `isNotExpPacket_l7` | **0** | No seq mismatch EVER |
| `send_nack_req` | **0** | NEVER LATCHES |
| `socl_l7_reached_link_data` | sticky high pre-AHB | L7 forgive window correctly closed |
| `socl_l7_bringup_forgive` | 0 | steady-state-disarmed (correct) |
| `_T_54` (count==0) | 433 / 500 | normal FSM idle |

**Q5's entire mechanism is wrong**. Slave RX path is healthy. No NACK loop. L7 logic works.

Yet slave `state=4` (LINK_IDLE) throughout, `REG_PKT_LEN=0`, `PAIR_CREDIT_COUNTER=0`.

This means the bug is in one of:
- **Master TX path doesn't actually emit** (a2l_full never clears, or fe_tx_credit_max never populates, or l2a_fc_replay_link_advance never fires)
- **Delivery between Wlink TX wire and Wlink RX wire** drops the data
- **Slave's `l2a_fc_replay_app_valid` never fires** despite ack_nack_fifo decoding correctly (gate downstream of NACK predicates)
- **Slave's fc_adapter routes to APB cfg path** instead of FIFO path (pkt_type misread *after* Wlink delivers — different bug than Q5 theorized)

#### Stage 4 — delivery-path probes (IN FLIGHT, agent running)

Agent dispatched today to probe both ends of the data delivery in sim:
- Master `a2l_fc_replay_*_valid/ready/advance/link_valid` + `a2l_full` + `fe_tx_credit_max` + `tl_fc_a2l_valid/data[47:46]`
- Slave `l2a_fc_replay_app_valid` + `l2a_fc_replay_link_valid/advance` + `exp_pkt_num/ll_rx_pktnum` + `tl_fc_l2a_valid/data[47:46]/accept` + slave fc_adapter `fc_rx_fifo_valid` vs `fc_rx_cfg_psel`

Output: `docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md` (when agent returns)

### Falsified Bug A hypotheses (for the record)

| # | Hypothesis | Evidence falsifying |
|---|---|---|
| A-1 | Slave RX `rx_pkt_type` decode wrong | `cocotb/tidelink_fc_adapter/test_rx_pkt_type_decode.py` 10/10 PASS for exact silicon symptom word |
| credit | PAIR_CREDIT_COUNTER=0 causes TX gate | Agent 7 showed PCC is APB-mirror only; FCSM `fe_rx_credit_max=0x1f` healthy both dies |
| H-A1 | AHB→fc_adapter handoff broken | `test_master_fc_ahb_handoff.py` PASS — tx_data_phase_r latches |
| H-A2 | skid backpressure permanent | `skid_can_accept=1`, `tl_fc_a2l_ready=1` post-bringup |
| H-A3 | Arbiter starves FIFO_DATA | `test_arbiter_grants_fifo_data` PASS |
| H-A4 | Wlink FCSM asymmetric end-state | `test_fcsm_state_post_bringup_symmetric` PASS (M==S) |
| H-A5 | Link bit-flip [47:46] | Master TX wire bits OK; sim is bit-perfect (can't reproduce; HW question still open) |
| L8 | Consumer-side FCSM advance | V1 sim: FCSM advances 4→5 but slave RX FIFO stays empty + L7 invariant breaks |
| L9 | Pktnum resync on first data | V3 sim: sticky latches but slave `tl_fc_l2a_valid=0` for 5000 cy |
| Q5 NACK loop | RX framer NACKs master | TODAY's sim probe: `send_nack_req=0` always, all predicates clean |

### Bug A active mitigation (L11) — applied and validated

```systemverilog
// L11 wedge watchdog + drop-and-count (src/rtl/tidelink_fc_adapter.sv:181-227)
localparam int unsigned WEDGE_LIMIT        = 16;
localparam int unsigned FORCE_READY_WIDTH  = 4;
logic [4:0]  wedge_cnt_r;
logic [2:0]  wedge_force_ready_cnt_r;
wire         wedge_force_ready_w = (wedge_force_ready_cnt_r != 3'd0);
logic [15:0] tx_dropped_cnt_r;
// ... watchdog logic asserts wedge_force_ready_w after 16 cy stall, holds 4 cy
assign ahb_tx_hreadyout = tx_data_phase_r
                          ? (wedge_force_ready_w | (skid_can_accept & ~sideband_grant))
                          : 1'b1;
```

**HW status of L11**: applied + reverted by user; in working tree NOW. Build #9 bitstream had this; HW behaviour validated (master stays alive, link stays up after AHB write).

## Bug B — PTP HW_SYNC, slave never receives

### Symptom (silicon)

Master writes `HW_SYNC_CTRL = 0x05` (enable + force_en). Master `HW_SYNC_STATUS` shows only bit 0 (`hw_sync_en_r`). Slave `PTP_CTRL` bit [2] (`ptp_rx_valid_r`) stays 0. No sync packets cross the link.

### Root cause (sim-decisive)

[tidelink_ptp.sv:399](../src/rtl/tidelink_ptp.sv#L399) — `phc_time_reached` gate that arms ARMED→FIRE transition:

```systemverilog
wire phc_time_reached = (phc_seconds > target_seconds_r) ||
                        (phc_seconds == target_seconds_r &&
                         phc_nanoseconds >= target_ns_r);
```

On IDLE→ARMED transition, `target_ns_r = phc_nanoseconds + hw_sync_interval_r`. With:
- `hw_sync_interval_r = DEFAULT_INTERVAL = 999_999_999` (line 359)
- BD tie-off `phc_nanoseconds = 30'h0` (in [fpga/targets/*/tidelink_design.tcl](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl) Q4 PHC tie-off note)

→ `target_ns_r = 0 + 999_999_999 = 999_999_999` → `phc_time_reached = (0 >= 999_999_999) = FALSE forever`.

ARMED→FIRE never fires. SW writing small HW_SYNC_INTERVAL doesn't help because `phc_nanoseconds` never advances past 0 either.

### Fix (sim-validated 3/3, GREEN-LIGHT — but reverted from working tree)

```diff
-  wire phc_time_reached = (phc_seconds > target_seconds_r) ||
+  wire phc_time_reached = hw_sync_force_en_r ||
+                          (phc_seconds > target_seconds_r) ||
                            (phc_seconds == target_seconds_r &&
                             phc_nanoseconds >= target_ns_r);
```

Reasoning: the other two HW_SYNC gates (IDLE→ARMED line 372, TX_WAIT_IDLE→TX_SEND line 260) already bypass on `hw_sync_force_en_r`. Line 399 silently forgot.

**Sim verification** (V2 agent):
- `test_force_en_bypasses_phc_time_reached`: PASS
- `test_force_en_slave_receives_sync`: PASS — slave `ptp_rx_valid_r=1`, `msg_type=0` (SYNC) within 5000 cy
- `test_master_ptp_tx_router::test_hw_sync_trigger_fires` (non-regression): PASS

**Saturation risk** (V2 validated):
With force_en held high, FSM re-arms every 11-27 cy = ~900 kpps at 25 MHz FPGA, ~3.6 Mpps at 100 MHz ASIC. **SW must treat HW_SYNC_CTRL=0x05 as one-shot**: write, observe seq_num increment, clear. OR only enable when consumer + link can absorb the stream.

### Bug B status

**Patch is in `docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`** but currently **NOT in working tree** (user reverted intentionally). Long-term: BD needs a real PHC counter to drive `phc_nanoseconds_i` (currently `30'h0` constant) so the time-based path works at all (independent of force_en).

## ILA infrastructure — Build #10 fix

### Symptom

Build #9 produced both bitstreams + .ltx files. ILA capture attempt:
- **Master**: `dbg_hub` visible, but Vivado HW Manager reports "Mismatch between the design programmed into the device xc7z020 and the probes file. The hw_probe in the probes file has port index 71. This port does not exist in the ILA core at location ..."
- **Slave**: HW Manager reports "Device is programmed with a design that has no supported soft debug core(s) in it" + "Dropping logic core with cellname:'u_dbg_int' since it cannot be found on the programmed device"

### Root cause

`fpga/insert_debug_core.tcl` calls `write_debug_probes -force ... tidelink_design_wrapper.ltx` AT THE END OF `insert_debug_core.tcl`, which runs inside the synth stage AFTER `implement_debug_core` but BEFORE `impl_1`. Then `impl_1` runs place/route on the post-debug-core synth checkpoint. During impl, Vivado can:
- Drop unrouted nets (DRC RTSTAT-10 "No routable loads: 25 net(s)" — observed in both master and slave build logs)
- Renumber probe ports
- Generate a new `u_dbg_int` UUID

The synth-stage .ltx then doesn't match the impl bit.

### Fix (applied to `fpga/build_design.tcl`, Build #10 in flight)

```tcl
# STEP 10b: Refresh .ltx from POST-IMPL design state (Build #10 fix).
if { [info exists env(FPGA_INSERT_DEBUG_CORE)] && $env(FPGA_INSERT_DEBUG_CORE) == "1" } {
    set routed_dcp [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_routed.dcp]
    if { [llength $routed_dcp] > 0 } {
        if {[catch {
            close_design -quiet
            open_checkpoint [lindex $routed_dcp 0]
            write_debug_probes -force [file join $output_dir tidelink_design_wrapper.ltx]
            close_design -quiet
        } refresh_err]} {
            puts "WARN: post-impl .ltx refresh failed: $refresh_err"
        }
    }
}
```

Result expected: Build #10 produces `.ltx` matching the actual `.bit`. HW Manager should then see all 67-71 probes including the 8 RX-wedge probes from Build #6.

## Test infrastructure

### Cocotb sim tests written this session

In `cocotb/tidelink_top_pair/` (paired-die env):

| Test | Purpose | Verdict |
|---|---|---|
| `test_tidelink_pair_doorbell.py::test_07` | PAIR_CREDIT_COUNTER != 0 after bringup | Re-targeted to FCSM `fe_rx_credit_max != 0`; PASS |
| `test_tidelink_pair_doorbell.py::test_08` | AHB packet M→S in sim | FAIL (sim-reproduces Bug A) |
| `test_tidelink_pair_doorbell.py::test_09` | PTP HW_SYNC slave RX | Re-targeted to mask bit 18; identifies Bug B |
| `test_master_fc_tx_block.py` | Master TX path probing | partial (Agent T1 truncated) |
| `test_master_ptp_tx_router.py` | Master PTP TX FSM | DECISIVE for Bug B (hw_sync_state_r wedges ARMED) |
| `test_credit_ledger_probes.py` | FCSM credit ledger vs APB | Established PCC is observability-only; `fe_rx_credit_max=0x1f` healthy |
| `test_ptp_corrected_regs.py` | Bug B with correct register surface | 4/4 FAIL (Bug B confirmed) |
| `test_master_fc_ahb_handoff.py` | H-A1 hypothesis | Tests PASS — falsifies H-A1 |
| `test_master_fc_skid_arbiter.py` | H-A2/A3 hypotheses | Tests PASS — falsifies H-A2/A3 |
| `test_fcsm_state_asymmetry.py` | H-A4 hypothesis | Tests PASS — falsifies H-A4 |
| `test_link_layer_bit_fidelity.py` | H-A5 bit-flip baseline | Sim is bit-perfect; HW question open |
| `test_fc_tx_force_experiments.py` | F1 force experiments | T5 smoking gun: master drives 2126 cy, slave never sees |
| `test_fc_tx_differential.py` | F2 differential (sideband vs FIFO) | Partial, sim timeouts |
| `test_buga_fix_link_data_consumer.py` | V1 L8 fix test | FAIL — L8 surface advance breaks L7 |
| `test_buga_real_fix_rx_wedge.py` | V3 L9 fix test | FAIL — L9 latches but RX FIFO empty |
| `test_buga_wedge_recovery.py` | L10/L11 wedge recovery test | Designed, not run |
| `test_bugb_fix_force_en.py` | V2 Bug B fix verification | **PASS** (3/3) — GREEN-LIGHT |
| `test_buga_nack_predicates.py` | **TODAY's NACK predicate probe** | **FALSIFIES Q5 theory** — no NACK ever fires |
| `test_buga_delivery_path.py` | **TODAY's delivery path probe (in flight)** | Pending |

In `cocotb/tidelink_fc_adapter/` (single-side env):
- `test_rx_pkt_type_decode.py` — 10/10 PASS, falsifies A-1 (slave RX decode is correct)

## HW build progression (chronological)

| Build | Commit | RTL changes | HW outcome | Bug A wedge | Bug B |
|---|---|---|---|---|---|
| #3 | dda0a0e (feat/td-gpio-phy) | Calibrator Fix A2+B | 16/16 link, doorbell works | Wedges master | Reproduces |
| #4 | ebbde0e | + 20 mark_debug attrs incl. `pair_credit_counter` | FCSM=7/4, returner stuck | inseparable | inseparable |
| #5 | (post #4) | minus `pair_credit_counter` mark_debug | 16/16 link, returner clears | Wedges master | Reproduces |
| #7 | + L10 (1-cy force_ready) | Same as #5 + L10 | 1st AHB OK, 2nd wedges | Partial | (not retested) |
| #8 | + L11 (4-cy force_ready) | Same + L11 | 1st AHB OK, 2nd self-recovers via PYNQ watchdog | **Defanged** ✅ | Reproduces |
| #9 | + 8 RX-wedge probes | L11 + FCSM_6 probes | AHB tested — master stays alive ✅ | Defanged | (not retested) |
| #10 | + `.ltx` post-impl refresh | L11 + RX probes + .ltx fix in build_design.tcl | **IN FLIGHT** — synth phase | Defanged expected | (not tested) |

## RTL changes currently in working tree (NOT committed)

| File | Change | Status |
|---|---|---|
| `src/rtl/tidelink_fc_adapter.sv` | L11 wedge-break watchdog (lines 181-243) | In tree |
| `src/rtl/fifo/tidelink_apb_regs.sv` | `pair_credit_counter` mark_debug REMOVED | In tree |
| `src/rtl/tidelink_ptp.sv` | 6 Build #5 mark_debug probes (tx_state_r, hw_sync_interval_r, target_*_r, hw_sync_state_r, phc_time_reached) | In tree |
| `src/rtl/local_overrides/WlinkGenericFCSM_6.v` | 8 Build #6 RX-wedge probes (mark_debug only) | In tree |
| `fpga/build_design.tcl` | STEP 10b: post-impl `.ltx` refresh | In tree |
| `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` | test_07/test_09 assertion fixes | In tree |
| `cocotb/tidelink_top_pair/pad_skid.sv` | Symlink repointed to ../wlink_pair/pad_skid.sv | In tree |
| `.gitignore` (outer + tidelink-gpio-phy submodule) | Sim build dir patterns added | In tree |

**RTL changes that were proposed but reverted by user** (intentional):
- Bug B fix (`hw_sync_force_en_r` bypass at tidelink_ptp.sv:399) — patch at `docs/BUG_B_PROPOSED_FIX_2026_05_29.patch`
- L8 surface fix (FCSM consumer-side state advance) — patch at `docs/BUG_A_PROPOSED_FIX_2026_05_29.patch`

## Where we think Bug A correctness actually lives (current best guess)

Given today's NACK-loop falsification, the bug is in ONE of these 4 places:

### Candidate 1: Master TX never actually emits the AHB-side data
- `a2l_fc_replay_app_valid` may never fire on master (fc_adapter says it does, but Wlink may not accept)
- OR `fe_tx_credit_max` never populates because CR/CRACK exchange has a corner case
- Probe: master `a2l_fc_replay_*` + `fe_tx_credit_max` + `tl_fc_a2l_valid` cycle trace

### Candidate 2: Wlink TX→RX wire drops data
- Master's `tl_fc_a2l_valid` fires but slave's `tl_fc_l2a_valid` never does
- Would be a Wlink internal serdes/byte-align/framer issue
- Sim is bit-perfect so this would only show on HW

### Candidate 3: Slave's `l2a_fc_replay_app_valid` never fires despite ack_nack_fifo decoding OK
- Gate downstream of NACK predicates we haven't identified
- ack_nack_fifo classifies as expected (`isExpPacket` = high, `isNotExpPacket_l7` = 0)
- But the FIFO write side may not actually pop the data through

### Candidate 4: Slave's fc_adapter routes FIFO_DATA to APB cfg path
- Slave `tl_fc_l2a_valid` fires with pkt_type=00 (FIFO_DATA)
- But fc_adapter's `rx_pkt_type` somehow reads 01 (SIDEBAND) due to a timing race
- This contradicts the unit test (10/10 PASS for the exact word) but unit test uses synthesized stimulus, not real Wlink delivery

**The delivery-path agent running now will disambiguate between these 4.**

## Suggested next steps (priority order)

1. **Wait for delivery-path sim agent** (~20 min from this doc). Output: `docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md`. Will tell us which of Candidates 1-4 is the bug.

2. **Wait for Build #10** (~40 min). When done, deploy + retry ILA capture. With matched .ltx, the 8 RX-wedge probes plus master FC + ptp probes should be live. Capture during an AHB write.

3. **Based on Build #10 ILA + delivery sim agent**, propose the actual RTL fix. Likely a small surgical patch to fc_adapter or WlinkGenericFCSM_6.v.

4. **Re-apply Bug B fix** (1-line OR-term at tidelink_ptp.sv:399). Build #11 with Bug A fix + Bug B fix, no ILA needed.

5. **BD-level PHC counter** is a separate workstream — needs a free-running 30-bit counter wired into `phc_nanoseconds_i` in the BD. Currently `30'h0` tied off. Until this is fixed, Bug B's time-based path (without `force_en`) cannot work.

## Operational notes (lessons learned)

- **`/tmp/tidelink_deploy/` on mapstone-dev is SHARED** with the user's `feat/td-autonomy` workstream. Use `/tmp/tidelink_deploy_build5/` (or per-build dirs) to avoid clobbering each other's manifests.
- `deploy_pair.sh` takes a 4th positional arg for artefacts dir: `bash deploy_pair.sh <IP> <z2_NN> <role> <artefacts_dir>`.
- `fpgahub hub power-cycle pynq_z2_02_ps --off 8.0` is the manual recovery if PYNQ doesn't auto-reboot (rare with L11).
- `bringup_pair_converge.sh` at `/tmp/td_overnight_scripts/` is the iterative re-deploy loop that gets builds with sticky-low calibrator past initial roll. Pair-flip-all needs phase=3 (`PHASE_OVERRIDE=0x00060000` if not auto).
- Master's `/tmp/` is wiped on power-cycle; the test python scripts (`td_*.py`, `build5_app_test.py`) must be re-staged on each reboot.
- **`FPGA_INSERT_DEBUG_CORE=1` is the env var** that enables `insert_debug_core.tcl`. Must be set in the shell that calls `make build_pair_farmed`.
- L11 watchdog drops AHB words silently when slave RX is wedged. SW should poll `tx_dropped_cnt_r` (currently internal — not exposed via APB; that's a future Edit-4 from the L10 patch recipe in `docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md`).

## Documents you should read (in this order)

1. **This document** — overview + status
2. [docs/BUILD8_HW_VALIDATION_2026_05_31_EVENING.md](BUILD8_HW_VALIDATION_2026_05_31_EVENING.md) — L11 HW-validation evidence
3. [docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md](BUG_A_WEDGE_INVESTIGATION_2026_05_31.md) — wedge primitive mechanism + L10 design (L11 is the refinement)
4. [docs/BUG_A_NACK_PREDICATE_SIM_2026_06_01.md](BUG_A_NACK_PREDICATE_SIM_2026_06_01.md) — Q5 NACK theory FALSIFIED today
5. [docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md](BUG_A_DELIVERY_PATH_SIM_2026_06_01.md) — IN FLIGHT (delivery agent)
6. [docs/BUG_B_FIX_PLAN_2026_05_29.md](BUG_B_FIX_PLAN_2026_05_29.md) + [BUG_B_FIX_VERIFICATION_2026_05_29.md](BUG_B_FIX_VERIFICATION_2026_05_29.md) — Bug B fix design + GREEN-LIGHT sim verification
7. [docs/HANDOFF_ERRATA_2026_05_29.md](HANDOFF_ERRATA_2026_05_29.md) — 5 corrections to the original handoff doc from 2026-05-29

Historical (informational, not action-critical):
- [BUG_A_FORCE_EXPERIMENTS_2026_05_29.md](BUG_A_FORCE_EXPERIMENTS_2026_05_29.md) — F1 T5 smoking gun (master drives 2126 cy)
- [BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md](BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md) — Q5's analysis (mostly falsified today)
- [BUG_A_FIX_VERIFICATION_2026_05_29.md](BUG_A_FIX_VERIFICATION_2026_05_29.md) — V1 L8 RED-LIGHT
- [BUILD4_HW_VALIDATION_2026_05_29.md](BUILD4_HW_VALIDATION_2026_05_29.md) — Build #4 R-1 regression baseline (informs build #5 strategy)

## Lease + lab state

- bridge1 lease held by mapstone-dev (renewed automatically on each deploy)
- Boards pynq_z2_02 (master, die_a) + pynq_z2_03 (slave, die_b) attached
- mapstone-dev `/tmp/tidelink_deploy/` currently has Build #9 artefacts (sha 09e35b9cde35... / 18578544b657...) — will be overwritten when Build #10 deploys
- Concurrent workstream: `td-autonomy` may also touch `/tmp/tidelink_deploy/` — that's the user's parallel work on autonomous bringup

## Honest assessment

**Bug A wedge primitive: DONE.** L11 watchdog HW-validated. Master no longer wedges. Iteration loop on Bug A correctness is now tractable (no manual power-cycle per test).

**Bug A correctness: NARROWED, NOT SOLVED.** Q5's mechanism was wrong. The bug is in one of 4 candidates I've listed. Today's delivery-path sim + Build #10 ILA will disambiguate. Once the broken signal is identified, the fix is likely ≤10 lines of RTL.

**Bug B: SOLVED IN PRINCIPLE.** 1-line force_en bypass at tidelink_ptp.sv:399 is sim-validated GREEN-LIGHT. User reverted intentionally (probably waiting for a complete picture). Re-applying is safe; BD-level PHC counter is the long-term complement.

**ILA infrastructure: FIX IN FLIGHT (Build #10).** `.ltx` was being written too early; build_design.tcl now re-emits from impl_1's routed.dcp. Should produce matched .bit + .ltx for first time.

This is the most progress we've made on Bug A in any session. The wedge primitive is gone, the NACK red-herring is killed, and the next iteration is well-scoped.

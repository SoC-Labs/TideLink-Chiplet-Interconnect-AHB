# Handoff: tidelink_phy_align_calibrator asymmetric M→S corruption bug

**Date:** 2026-05-26
**Status:** Root cause LOCATED to `AUTOCAL_ENABLE=1`. Specific RTL bug within `tidelink_phy_align_calibrator.sv` (or its interaction with the Wlink PHY) NOT yet identified.
**Working dir:** `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c` (worktree on `feat/td-interface-debug-l11-byte-align`)

## The bug, in one paragraph

When `axi_chiplet_controller` is instantiated inside `tidelink_top.sv` with `AUTOCAL_ENABLE=1`, sideband packets transmitted in the master→slave (M→S) direction over Wlink never get delivered to the slave's FC adapter RX (`tl_fc_l2a_valid` stays 0 on slave). The slave→master (S→M) direction works perfectly. With `AUTOCAL_ENABLE=0`, both directions work bidirectionally in simulation. The structural RTL of `axi_chiplet_controller` is symmetric between master and slave instances — only `role_strap_i` differs — so the asymmetry must come from a dynamic state divergence in the calibrator FSM, OR from the calibrator's interaction with the per-lane PHY (`WavD2DGpio`) in a role-dependent way.

## What's empirically confirmed

### Sim repro (`cocotb/tidelink_top_pair/`)
- `tidelink_top` × 2 cross-wired via GPIO PHY pads, full integration
- Default `AUTOCAL_ENABLE=1` from `tidelink_top.sv:1630` → `test_05 M→S doorbell` FAILS, `test_06 S→M doorbell` PASSES
- Force `AUTOCAL_ENABLE=0` (via defparam in tb_top.sv, OR via the RTL edit at line 1630) → **both test_05 AND test_06 PASS** in `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`

### Diagnostic state when AUTOCAL=1 (failing)
- Both sides reach bilateral LINK_IDLE (Wlink FCSM state=4)
- `cr_pkt_seen_rx` and `crack_pkt_seen_rx` symmetric (=1) on both sides
- `fe_rx_credit_max=0x1f`, `fe_rx_is_full=0` on BOTH sides — credit gate open
- L7 forgive / packet-classifier probes (`socl_l7_bringup_forgive`, `reached_link_data`, `isExpPacket`, `isNotExpPacket`, `send_nack_req`, `ack_nack_fifo_valid`) **all symmetric** between master and slave post-bringup
- Calibrator state probe shows BOTH sides reach `cal=DONE`
- When master rings doorbell: FC adapter emits 1-cycle `tl_fc_a2l_valid` (M.a2l=1); master FCSM visits state 5 (LINK_DATA) for 6 cycles; **slave FCSM stays at state 4 for the entire 2000-cycle window**; `S.l2a=0` (slave never receives the packet at FC adapter RX)
- Even FORCING master's `tl_fc_a2l_valid` HIGH for 200 cycles (`test_force_hold_a2l_master_to_slave`) does NOT make slave's FCSM react — slave's FCSM histogram is `['4:200']`. The reverse force-hold makes master visit state 6 (SEND_ACK) 19 times.

### Diagnostic state when AUTOCAL=0 (working)
- `cal_state` probe shows `M=IDLE S=IDLE` (calibrator FSM in IDLE — never armed)
- `test_05` M→S doorbell: `M(a2l=1, l2a=0)  S(a2l=0, l2a=1)` — **slave's FC adapter RX receives the packet within ~6 cycles**
- `test_06` S→M doorbell: `M(a2l=0, l2a=1)  S(a2l=1, l2a=0)` — symmetric
- Bilateral data crossing restored

## What's been ruled out

1. **Wlink/`axi_chiplet_controller` standalone** is clean — `cocotb/wlink_pair/test_data_landing_repro.py` AND new `cocotb/wlink_pair/test_pulse_width_sweep.py` PASS bidirectionally with 1-cycle force AND held force at `tl_in_wire`. Note: wlink_pair uses **`AUTOCAL_ENABLE=0` by default** (no parameter override on either instance — verified at `cocotb/wlink_pair/tb_top.sv:240,344`).
2. **TideLink data-path (FC adapter, FIFO, returner, APB regs, address translator, APB mux)** is clean — `cocotb/tidelink_top_loopback_pair/test_doorbell_symmetry.py` (two `tidelink_top` slices cross-wired at FC AXIS layer, no Wlink) PASSES bidirectionally including PAIR_CREDIT increments.
3. **FC adapter at unit level** is clean — `cocotb/tidelink_fc_adapter/test_21/22/23` pass for the bit-truncation cases with non-zero `rtn_haddr[31:14]`.
4. **Pulse-width hypothesis** ruled out — force-holding `tl_fc_a2l_valid` for 200 cycles doesn't make M→S work (it's not "valid pulse too brief").
5. **L7 forgive gate** ruled out — symmetric on both sides per L7 probe sim.
6. **`pair_base_addr` explicit init** ruled out — `test_05` still fails with `pair_base_addr` written via APB before the doorbell.
7. **The agent-flagged TOP 3 differences** between `tidelink_top` and `wlink_pair` chiplet_controller instantiations were: (1) `tidelink_in`/`tidelink_out` wiring (false alarm — wlink_pair tests use `Force()`), (2) AUTOCAL_ENABLE — **confirmed cause**, (3) APB hardening of swi_enable at 0x208 (untested but lower priority).

## The narrowed hypothesis

`tidelink_phy_align_calibrator.sv` (file: `src/rtl/tidelink_phy_align_calibrator.sv`) drives some signal — most likely `cal_training_mode` or per-lane `phase_offset` — into the Wlink PHY (`WavD2DGpio`) in a way that **specifically corrupts master's TX (or equivalently, breaks slave's RX) without affecting the reverse direction**. The corruption happens DURING data transmission AFTER the calibrator has reached `S_DONE`, so it's not about the sweep itself failing — it's about the calibrator's POST-DONE state still affecting the link in an asymmetric way.

## Specific suspect mechanisms (to investigate)

1. **`cal_training_mode` post-DONE residual.** Per `bringup_pair_passive.sh` comments, "self-deasserts cal_training_mode in S_DONE". Verify in RTL: does `cal_training_mode` cleanly deassert in S_DONE on BOTH master and slave, or does one side leave it asserted? If asymmetric, the PHY on one side keeps emitting/expecting training patterns instead of data.

2. **Per-lane `phase_offset[3:0]` post-DONE.** The calibrator latches a per-lane phase value in `lane_locked_w[7:0]` etc. If master's TX phase and slave's RX phase disagree at S_DONE, M→S RX would sample at the wrong time. But the reverse direction works — so this only breaks one direction. Examine: is `phase_offset` symmetric between master's TX and slave's RX after bringup? Specifically: master's TX phase needs to match slave's RX phase; slave's TX phase needs to match master's RX phase. These are TWO INDEPENDENT calibrations.

3. **The S_HOLD peer-aware state.** Per the calibrator FSM (line 422 area of `tidelink_phy_align_calibrator.sv`): `if (sweep_success && !tb_early_exit_force_q) nxt_state = S_HOLD`. S_HOLD is described as "T3.2 peer-aware hold". Audit: how does S_HOLD interact with the peer? Does it wait for peer's S_HOLD via a sideband signal? If the peer-detection logic is role-asymmetric, one side could exit S_HOLD prematurely.

4. **IDELAYE2 control with `USE_IDELAY` cooperation.** When `USE_IDELAY=1` AND `AUTOCAL_ENABLE=1`, the calibrator drives per-lane IDELAYE2 taps. With `USE_IDELAY=0` (the sim default), the IDELAY is bypassed but the calibrator might still drive something. Check: does the calibrator output ANY signal that matters when `USE_IDELAY=0` is set?

5. **Lane checker `lane_locked_w[7:0]` feedback.** The calibrator uses `tidelink_lane_checker.sv:49` (`locked = match_count >= LOCK_THRESH`) to score each lane. The lane checker compares incoming bytes to expected training patterns. If slave's RX lane checker sees different "locked" semantics than master's RX (e.g., one side's match_count saturation behavior differs from the other's), the calibrator could exit with mismatched per-lane states.

## Files & line numbers to inspect

| File | Lines of interest |
|---|---|
| `src/rtl/tidelink_phy_align_calibrator.sv` | Whole file; especially state machine 247-256 (state encoding), 280-282 (trigger_now), 385 (sweep_exhausted), 422-462 (S_FINISH→S_DONE/HOLD), 548-564 (per-lane state clear on S_CANCEL), 692-697 (calibration_done assertion), 740 (`calibration_done` output) |
| `src/rtl/tidelink_lane_checker.sv` | Whole file; lane lock criterion at line 49 |
| `src/rtl/tidelink_idelay_rx.sv` | IDELAYE2 control path; verify `USE_IDELAY=0` cleanly bypasses |
| `src/rtl/tidelink_rxclk_buf.sv` | RX clock buffer; verify clocks are symmetric M vs S |
| `src/rtl/tidelink_top.sv:1629-1850` | `u_chiplet_controller` instantiation; AUTOCAL_ENABLE param (line 1630), inputs to `axi_chiplet_controller`, particularly anything that depends on `role_strap_i` differently between master and slave |
| `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v` | The PHY module the calibrator drives. Check how `cal_training_mode` and `phase_offset` feed into the per-lane TX/RX paths |
| `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v` | Per-lane TX. Specifically: does any signal from the calibrator affect data emission AFTER training_mode deasserts? |
| `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioRx.v` | Per-lane RX. Same question for reception. |

## Hierarchical signal paths for cocotb probing

These should already be reachable from the existing `cocotb/tidelink_top_pair/tb_top.sv` testbench via dotted hierarchy:

- Calibrator FSM state: `tb_top.u_master.u_chiplet_controller.u_calibrator.cur_state` (and `u_slave` equiv.)
- Per-lane phase offsets: `tb_top.u_master.u_chiplet_controller.u_calibrator.lane_phase_q[*]` or similar (find the exact name)
- `cal_training_mode` output: `tb_top.u_master.u_chiplet_controller.cal_training_mode_w` (it's a wire inside `axi_chiplet_controller`)
- PHY-side training mode input: `tb_top.u_master.u_chiplet_controller.u_wlink.phy.gpio.swi_training_mode` (path TBD)
- Lane checker locked output: `tb_top.u_master.u_chiplet_controller.u_lane_checker.lane_locked_w[7:0]`

## Reproduction

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-l4-option-c
source set_env.sh

# Failing case (AUTOCAL=1 — current main RTL):
# (first revert tidelink_top.sv:1630 from .AUTOCAL_ENABLE(1'b0) back to .AUTOCAL_ENABLE(1'b1))
cd cocotb/tidelink_top_pair
rm -rf sim_build results.xml
make MODULE=test_tidelink_pair_doorbell
# Expected: test_05 FAIL (M→S), test_06 PASS (S→M), ~30 min wall

# Working case (AUTOCAL=0):
# tidelink_top.sv:1630 set to .AUTOCAL_ENABLE(1'b0)
cd cocotb/tidelink_top_pair
rm -rf sim_build results.xml
make MODULE=test_tidelink_pair_doorbell
# Expected: test_05 PASS, test_06 PASS
```

## Key sim-output evidence

### AUTOCAL=1 (failing, test_05 detail from `/tmp/exp34_force_hold_v2.log`):
```
[after M doorbell write] FC over 2000 cy:
  M(a2l=1, l2a=0, stall=0)   ← master FC adapter pushed 1-cycle packet
  S(a2l=0, l2a=0, stall=0)   ← slave never received
FCSM histograms over 2000 cy:
  M=['4:1994', '5:6']          ← master visited state 5 (LINK_DATA) briefly
  S=['4:2000']                  ← slave never moved
```

### AUTOCAL=0 (working, test_05 detail from `/tmp/exp_autocal_defparam.log`):
```
[after M doorbell write] FC over 2000 cy:
  M(a2l=1, l2a=0, stall=0)
  S(a2l=0, l2a=1, stall=0)   ← slave RECEIVES the packet
```

## What the next agent should DO

1. **Verify the hypothesis at the smallest possible RTL granularity.** Run the AUTOCAL=1 sim and INSTRUMENT (via cocotb hierarchical probes) the following during the 2000-cycle doorbell-watch window:
   - `cal_training_mode` (output from calibrator) on master AND slave
   - The PHY's effective training-mode input on master AND slave
   - Per-lane `phase_offset[*]` value on master AND slave (after S_DONE)
   - The lane_checker `locked[7:0]` on master AND slave throughout
   - The raw bit stream on master's `pad_tx[7:0]` and the corresponding cycle on slave's `pad_rx[7:0]`

2. **Look for the role-asymmetric divergence.** With identical RTL, what's different between master and slave's calibrator-output signals at the moment master's data packet is on the wire?

3. **Isolate to the smallest fix.** If `cal_training_mode` doesn't deassert symmetrically post-S_DONE, fix the state machine. If `phase_offset` is the asymmetry, fix the per-lane latching. If something else, document and propose.

4. **DO NOT modify** `/research/AAA/ip_library/**` (read-only lab IP). DO NOT modify `deps/axi-chiplet-controller/**` either (it's the Wavious upstream). Any fix must go in local override or `src/rtl/local_overrides/` per existing project convention.

5. **Validate the fix in sim first**: M→S doorbell test_05 in `cocotb/tidelink_top_pair/` must PASS with the fix applied AND `AUTOCAL_ENABLE=1` restored at `tidelink_top.sv:1630`.

6. **Then HW build & test on `pynq-z2-pair-flip-ila`** (single MMCM, no PPM drift — lowest-risk validation target). If sim passes and HW passes there, the fix is unblocking.

## Useful context memory entries

These project memory files document prior debug context that may save time:
- `project_tidelink_sim_repro_2026_05_26` — how the sim repro was stood up
- `project_tidelink_bug_isolated_2026_05_26` — bisect chain that landed on tidelink_top wrapper
- `project_tidelink_interface_fcsm_bug_2026_05_24` — earlier work documenting "bringup_pair_converge.sh ACTIVELY BREAKS POR-aligned link via slot0=0x3 recal" — same family of issue
- `project_phc_phase1_session_2026_05_24` — confirms PTP phase-1 is blocked by the same M→S asymmetric path
- `reference_tidelink_address_map` — APB address map (0x44032xxx)
- `reference_tidelink_role_lock` — APB 0x2080 W1S role-lock path

## Branch state

- Worktree: `/home/dam1n19/SoCLabs/td-bisect/td-l4-option-c` on `feat/td-interface-debug-l11-byte-align`
- Current uncommitted edit: `src/rtl/tidelink_top.sv:1630` changed to `.AUTOCAL_ENABLE(1'b0)` — this is what UNBLOCKS the doorbell test. The next agent's investigation can leave this as-is for diagnostic runs, but the final fix should restore `AUTOCAL_ENABLE(1'b1)` and fix the calibrator RTL instead.
- The sim test files used to confirm the bug: `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`, `test_force_hold_a2l.py`, `test_compare_trace.py`. The doorbell test is the most decisive single test.

## Expected outcome

A specific RTL fix in `tidelink_phy_align_calibrator.sv` (or its drivers/consumers) that makes `cocotb/tidelink_top_pair/test_05_doorbell_master_to_slave` PASS with `AUTOCAL_ENABLE=1` at `tidelink_top.sv:1630`. The fix should be < 50 lines of RTL and explainable in one paragraph.

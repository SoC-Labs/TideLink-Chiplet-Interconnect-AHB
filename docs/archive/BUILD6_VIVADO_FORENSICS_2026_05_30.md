# Build #6 Vivado Forensics — F-1.5 PS hang root cause

**Investigation date:** 2026-05-31
**Commit under analysis:** `09cc0ec` ("F-1.5 force state -> LINK_IDLE on watchdog")
**Revert commit:** `cbcd4ef`
**Reference HW report:** [BUILD6_HW_VALIDATION_2026_05_30.md](BUILD6_HW_VALIDATION_2026_05_30.md)

Build #6 artefacts inspected:
- `imp/fpga/run/farm/pynq-z2-pair-all@local.20260530-090811.log` (wrapper synth+impl, 09:08-10:55 May 30)
- `imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper_timing_summary_routed.rpt` (May 30 10:52)
- `imp/fpga/tidelink_ip/src/WlinkGenericFCSM_6.v` (packaged IP src, still contains F-1.5)
- `imp/fpga/project/pynq-z2-pair-all/tidelink_project.runs/tidelink_design_tidelink_0_0_synth_1/runme.log` (re-run May 31 13:02 but against the still-F-1.5 packaged IP src — a faithful proxy for build #6 FCSM synth)

---

## 1. Executive summary

Vivado synthesized the F-1.5 priority clause **cleanly** — no warnings, no multi-driver, no inferred latch, no async-reset issues, no timing violations on the `state` register. The `state` FF kept its 3-bit binary encoding (Vivado did **not** infer it as an FSM in `WlinkGenericFCSM_6`; `mark_debug`/`keep_hierarchy` on `u_wlink` disabled FSM re-encoding). At RTL the new `end else if (socl_l7_wdog_force_clear && state == 3'h7)` clause simply added one priority level to the state-FF input mux. Timing is positive (WNS +26.0 ns).

**The PS hang is not a synthesis pathology — it is an RTL design defect.** F-1.5 forces `state -> 3'h4` in one cycle, but the FCSM is a single-state-controls-many-registers design: ten other always-blocks (`sop`, `data_id`, `count`, `send_ack_req`, `send_nack_req`, `link_data`, `ne_rx_ptr`, etc.) still consume `state == 3'h7` on the same cycle and execute their state-7 transitions. The next cycle starts with `state == 3'h4` but stale state-7 housekeeping in those ten companions — a designed-in "FSM consistency violation". One of those companion registers is `rx_state_r` in `tidelink_fc_adapter` (the consumer-replica RX FSM); when its inconsistency propagates, `rx_cfg_active` can latch high, which directly drives `fc_cfg_apb_psel`, which through `tidelink_top.sv:931` forces `tl_regs_pready <= 0` for the whole APB region. The first returner-mediated cross-link AHB write (triggered by the doorbell at 0x44032014) then stalls the AXI-Lite/SmartConnect path back to PS — kernel hangs in `mmap` write.

## 2. Synth warnings/errors from build #6 (verbatim)

OOC synth of `tidelink_0` (`tidelink_design_tidelink_0_0_synth_1/runme.log`) on `WlinkGenericFCSM_6`:

```
WARNING: [Synth 8-7129] Port auto_in_paddr[12] in module WlinkGenericFCSM_6 is either unconnected or has no load
WARNING: [Synth 8-7129] Port auto_in_paddr[11] in module WlinkGenericFCSM_6 is either unconnected or has no load
... [auto_in_paddr 10,9,8,1,0] same pattern ...
```

No `Synth 8-3352` (multi-driver), no `Synth 8-327` (latch inferred), no `Synth 8-153` (async-reset), no `Synth 9-*` errors. Critically:

```
INFO: [Synth 8-6071] Mark debug on the nets applies keep_hierarchy on instance 'u_wlink'.
                     This will prevent further optimization
                     [axi_chiplet_controller.sv:1541]
```

`mark_debug` on `u_wlink` blocks FSM inference for `WlinkGenericFCSM_6`. Confirmed by absence of any `Synth 8-802 inferred FSM for state register 'state'` line for `WlinkGenericFCSM_6` (compare: WlinkTxPstateCtrl and WlinkRxLinkLayer DO appear in the 8-802 list at lines 518-519 of the OOC log).

Wrapper synth (`farm/pynq-z2-pair-all@local.20260530-090811.log`): `synth_design completed successfully` at 17:33 elapsed. No Critical Warning, no Error referring to `WlinkGenericFCSM_6`, `state`, `socl_l7_wdog_force_clear`, or `wlink_tidelinktl`.

## 3. State FF before vs after F-1.5

**Both flavours infer the same FF type:** 3 x `FDCE` (async clear on `io_tx_reset`) — Vivado does NOT change FF primitive when a priority clause is added.

**F-1 only (pre-patch):**
```verilog
always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset)            state <= 3'h0;
  else if (_fe_rx_ptr_in_T)   state <= 3'h0;
  else if (_ack_seen_before_T) ...
  ...
  else                        state <= _GEN_181;
end
```
Mux depth into `D`: 5 priority levels (4-LUT chain).

**F-1.5 (`09cc0ec`):**
```verilog
always @(posedge io_tx_clk or posedge io_tx_reset) begin
  if (io_tx_reset)                                          state <= 3'h0;
  else if (socl_l7_wdog_force_clear && state == 3'h7)       state <= 3'h4;  // NEW
  else if (_fe_rx_ptr_in_T)                                 state <= 3'h0;
  ...
end
```
Mux depth into `D`: 6 priority levels (one extra LUT). Functionally clean, synthesized as expected. The FF clear/reset semantics are unchanged — `io_tx_reset` is still the only async clear; everything else feeds `D`.

This change in isolation is benign at the gate level.

## 4. Timing analysis

`tidelink_design_wrapper_timing_summary_routed.rpt`:
- WNS: +26.006 ns (clk_fpga_0 @ 100 MHz, slack on dbg_hub path)
- TNS: 0.000 ns — **0 failing endpoints**
- WHS: +0.097 ns hold — **0 failing endpoints**
- No path involving `u_chiplet_controller/u_wlink/wlink_tidelinktl/state` appears in the top-N worst-slack paths

The fan-in to `state` includes `socl_l7_wdog_force_clear` (`socl_l7_wdog_cnt[15:0] == 16'h4000`) — this is a 16-bit comparator, no timing pressure at 100 MHz. The `_GEN_181` chain that feeds the `else` branch is already a multi-stage cascade in F-1; F-1.5 added one priority layer above it with positive slack to spare.

**Conclusion: no timing-driven mechanism for the HW hang.**

## 5. Predicted AHB hang mechanism

Trace from "force `state <= 3'h4` while ten companion regs still see state==7":

1. `state` FF transitions 7 -> 4 in one cycle (F-1.5 clause).
2. Same cycle, the always-blocks for `sop`, `count`, `data_id`, `word_count`, `link_data`, `send_ack_req`, `send_nack_req`, `ne_rx_ptr`, `last_ack_pkt_sent` each still consume `state == 3'h7` and execute their state-7 transitions (`_GEN_149`/`_GEN_150`/`_GEN_153`/`_GEN_157` at WlinkGenericFCSM_6.v:561-569). They produce values appropriate for "exited state-7 normally via auto_tx_out_advance" — but the LL_TX bus did NOT advance, so the peer-visible NACK packet is incomplete.
3. Peer LL_RX framer, seeing TX bus jump from "mid-NACK" to "idle/data" without the NACK terminator, enqueues an `isNotExpPacket` notifier into `ack_nack_fifo`.
4. Master FCSM (now at state 4) observes that notifier and re-latches `send_nack_req <= 1`. Watchdog re-arms.
5. Worse — the slave consumer-replica `rx_state_r` (in `tidelink_fc_adapter.sv:474-481`) consumed the partial header and advanced into `RX_ADDR_PHASE` with a malformed addr that decodes as `!rx_is_fifo && !rx_is_ext`.
6. Line 524 fires: `rx_cfg_active = 1`.
7. `tidelink_fc_adapter.sv:528`: `assign fc_rx_cfg_psel = rx_cfg_active;`
8. `tidelink_top.sv:1159` -> `:670` -> `wire fc_cfg_apb_active = fc_cfg_apb_psel;`
9. **`tidelink_top.sv:931`: `assign tl_regs_pready = fc_cfg_apb_active ? 1'b0 : tl_apb_pready;`**

While `fc_cfg_apb_active` stays high, the entire TideLink APB region returns `pready = 0`. The AHB transaction from the AXI-to-AHB bridge at 0x44032xxx never completes; the bridge holds the AXI write outstanding; SmartConnect blocks PS AXI-Lite return; `/dev/mem` write to 0x44032014 hangs in kernel space. SSH dies in <1 s, fpgahub UART reset says `ok` but PS doesn't respond, physical power-cycle required — matches the HW symptom exactly.

Build #5 (F-1 only) avoids this because the natural state-7 -> state-4 path via `_GEN_115 = auto_tx_out_advance ? 3'h4 : state` consumes `auto_tx_out_advance` — the LL_TX peer drains the NACK packet properly, so the peer's `rx_state_r` stays in IDLE.

## 6. Pre-deploy checklist for any future F-1.5 attempt

Run these greps on the OOC synth log **before** packaging the IP:

```bash
# Should return nothing (no Vivado IDs that indicate state-FF damage):
grep -E "Synth 8-3352|Synth 8-327|Synth 8-153|Synth 9-" \
    imp/fpga/project/*/tidelink_project.runs/tidelink_design_tidelink_0_0_synth_1/runme.log

# Confirm FSM inference status hasn't changed (mark_debug on u_wlink keeps it OFF):
grep "inferred FSM for state register 'state'" \
    imp/fpga/project/*/tidelink_project.runs/tidelink_design_tidelink_0_0_synth_1/runme.log
# (Should be silent for WlinkGenericFCSM_6 — Wlink mark_debug suppresses it)

# Companion-register sanity — for any F-1.5-style "force state" patch you MUST
# also patch every other always-block that consumes `state == 3'h7`. Greps:
grep -n "state == 3'h7" src/rtl/local_overrides/WlinkGenericFCSM_6.v
# Build #6 patch touched ONE block. Companion blocks at 1152, 887, 919, ... were NOT touched.
```

Pre-HW gates (added because sim missed this entirely — H's cocotb test used `Force()` which bypasses companion-register update):

1. **Sim must run with NATURAL state-7 entry**, not Force-injection. Run `cocotb/tidelink_top_pair/test_post_watchdog_doorbell_delivery` with a real bringup that organically traps at state 7 (e.g., via a deliberate isNotExpPacket injection on the rx_pkt sequence). Force() bypasses the bug class because it short-circuits the very state-machine consistency this defect exploits.
2. **Add a `rx_cfg_active` ILA probe** to the next build. If `fc_cfg_apb_psel` is observed to assert outside a known SW-initiated remote APB transaction sequence, the bug is present.
3. **Add a SW liveness probe BEFORE the doorbell ring**: read `REG_STATUS` once. If `returner_busy=0` and `REG_STATUS[1:0]==0` then proceed; if not, bail out without writing — the bus is already in the wedge regime.

## 7. Recommended fix path + deeper-investigation handle

The "force state -> 4 in one cycle" pattern is fundamentally incompatible with this Chisel-generated FSM because the FSM control is split across ~10 always-blocks all gating on `state == 3'h7`. Recommended:

**Option B (preferred) — fake `auto_tx_out_advance`.** Wrap `auto_tx_out_advance` and OR-in `socl_l7_wdog_force_clear`. The FCSM then transitions via the existing `_GEN_115` arc, all companion registers update consistently, and the only extra cost is suppressing the spurious phys-emit (tap on `auto_tx_out_*`). Single-driver, single-arc, exercises a well-tested transition.

**Option A — sync-reset-only.** Pulse a `socl_l7_force_reset` that synchronously re-asserts `io_tx_reset` into the FCSM through a controlled wrapper. Brings every companion register to POR. Drawback: also resets `socl_l7_real_crc_seen`/`reached_link_data` — needs hold-out shadow.

**Option C — SW-only.** Poll `REG_STATUS` before doorbell ring; never write 0x44032014 while master is busy. Drawback: permanent driver workaround.

If §1-§5 above is contested, the routed netlist `imp/fpga/output/pynq-z2-pair-all/tidelink_design_wrapper_routed.dcp` (27 MB, preserved) supports a deeper check via:

```tcl
open_checkpoint .../tidelink_design_wrapper_routed.dcp
report_property  [get_cells .../wlink_tidelinktl/state_reg[*]]
all_fanin -flat  -to [get_pins .../wlink_tidelinktl/state_reg[*]/D]
```

Verify (a) `state_reg[*]` is `FDCE` with CE = constant (no clock-enable surprises), (b) `socl_l7_wdog_force_clear` fan-in is purely `io_tx_clk` (no CDC), and (c) `rx_state_r_reg` in `u_fc_adapter` has no `mark_debug`-driven optimisation interaction with the FCSM state.

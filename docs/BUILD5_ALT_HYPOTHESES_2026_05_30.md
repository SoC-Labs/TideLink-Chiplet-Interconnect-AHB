# BUILD5 — Alternative Root-Cause Hypotheses (independent diagnostic pass)

**Author:** fresh diagnostic engineer (no exposure to prior BUILD4/BUILD5/FCSM_L7 chain)
**Date:** 2026-05-30
**Branch context:** `fix/fcsm-l7-wedge-watchdog` — F-1 watchdog clears `send_nack_req` after a 16 384-cycle timeout in state 7. Lanes lock 8/8, cal_done=1, master FCSM dwells in state 4 — yet master `REG_STATUS[0]` (`returner_busy`) latches HIGH after the first APB doorbell ring and slave `REG_DOORBELL_RESP_ACC` (0x024) stays at zero.

The instruction is: do **not** rederive "FCSM state-7 wedge". Brainstorm fresh angles that explain a one-shot doorbell that wedges the **returner**, given the only build delta vs the known-good build #3 is **24 mark_debug attrs + ILA insertion**.

---

## 1. Summary

The returner busy flag is `state_r != ST_IDLE` in `tidelink_returner.sv:96`. It is wedged because either (a) `rtn_hready` from the FC adapter never asserts, or (b) the `interrupt_*` pending-clear logic never fires. From `tidelink_fc_adapter.sv:245`, `rtn_hready = rtn_pending_r ? skid_can_accept : 1'b1`, and `skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready`. So a stuck returner means **either the skid is full and the Wlink FC TX side is not draining, or the returner FSM left IDLE but its pending bit never clears.**

The slave-side `REG_DOORBELL_RESP_ACC` not bumping is a **separate** consumer-side symptom. The slave only writes that register from the FC adapter's RX config-APB path (`tidelink_fc_adapter.sv:524-529`) when a PKT_SIDEBAND packet (`addr_offset = 14'h024`) actually arrives. So the simplest joint explanation is **the master never gets the sideband packet off the wire** — and we are looking for *what about ILA insertion* broke the master TX or the slave RX of sideband packets while leaving FCSM-level state happy. None of the four hypotheses below rest on the FCSM state-7 wedge.

## 2. Hypothesis Bank (ranked)

### H1 — Slave's FC RX → APB-master write is back-pressured indefinitely by the FC-adapter / APB-mux 2:1 arbiter (35 %)

**Mechanism.** `tidelink_top.sv:670, 682-686` defines a 2:1 APB mux in front of `tidelink_apb_regs`: `fc_cfg_apb_active = fc_cfg_apb_psel` wins priority over the external CPU APB port. The doorbell ring on master is an APB write to `0x44032000 + 0x014` — i.e. it travels CPU→AHB‑bridge→APB‑mux→`apb_sel_tidelink`. **At the same time**, the slave's symmetric returner is firing its own reset-doorbell (channel 2, `PAIR_DOORBELL_ADDR=0x014`, `tidelink_fifo.sv:325`) at POR. With ILA-inserted bitstreams, POR is messier (longer `proc_sys_reset` glitch, plus ILA's BSCAN frame counter pulls clk_wiz from the same MMCM). If the slave's reset-doorbell packet arrives at the master's FC RX exactly when the master CPU is mid-APB-cycle to the doorbell register, `fc_cfg_apb_active` parks the external APB at `pready=0` (`tidelink_top.sv:931`) — the CPU's APB transaction never completes and the FC-adapter sideband path itself can't drain because the local APB write addresses the **same** address that the *external* APB had locked. Net effect: master's APB doorbell never *commits*, so `doorbell_trigger` (`tidelink_apb_regs.sv:210`) never pulses, so the returner channel-1 never fires — but channel 2 (reset doorbell) *did* fire at POR and is now mid-transit through the FC, hence `returner_busy=1`. The slave never sees the *commercial* doorbell, so its `doorbell_response_acc` stays zero.

**Predicted signature.** ILA on `fc_cfg_apb_psel` shows it pulsing at exactly the same `hclk` cycle as `apb_psel` to `0x014`. ILA on the returner sees `state_r = ST_ADDR_PHASE` with `write_addr_r = pair_base + 0x014` (channel-2 selection). The fc_adapter `rtn_pending_r` is high and `skid_can_accept` is low.

**Cheapest experiment (30 min).** Read APB `0x44032000 + 0x024` (master's local `doorbell_response_acc`) — if non-zero, the slave is happily writing its DB_RESP into the *wrong* tidelink, confirming a same-cycle APB collision. Alternatively read `pair_base_addr` register (`tidelink_apb_regs.sv:...`) on both sides and confirm they are non-overlapping. Cheap RTL probe: temporarily comment out channel-2 wire-up in `tidelink_fifo.sv:324` and rebuild.

---

### H2 — Bug-A `mark_debug` of `fc_rx_fifo_ready` changed FIFO back-pressure such that `rx_pending_r` never clears for SIDEBAND, then chokes the FC RX accept (25 %)

**Mechanism.** `tidelink_fc_adapter.sv:607` marks `fc_rx_fifo_ready` for debug. The signal feeds `rx_active_ready` (line 444) which is **only consulted for FIFO_DATA** packets — but the RX FSM (line 462-467) clears `rx_pending_r` based on a compound condition that ORs FIFO-path and SIDEBAND-path completions. The ILA insertion forces `fc_rx_fifo_ready` to be driven from a register-replicated copy whose driver gets P&R'd far from `u_fc_adapter.rx_pending_r`. If `fc_rx_fifo_ready` transiently chatters (X-prop at POR, or a hold-time violation through the long route) it can clear `rx_pending_r` while `rx_state_r` was about to enter ADDR_PHASE for a SIDEBAND word — losing the sideband packet. The FC layer above sees `tl_fc_l2a_accept` deassert, so the Wlink RxLinkLayer queues the next packet behind it — eventually back-pressuring the slave's TX, which back-pressures *its* skid, which is what's wedging `rtn_hready` on the slave. Master sees nothing arrive at 0x024 because slave never re-emits.

**Predicted signature.** ILA on slave: `tl_fc_l2a_valid` high for many cycles, `tl_fc_l2a_accept` only pulsing 1 cycle then dropping. `rx_state_r` stuck in IDLE. `fc_rx_fifo_ready` toggles even when no FIFO_DATA in flight (it should be combinationally tied to `1` when no write — verify against `tidelink_fifo_mem`).

**Cheapest experiment.** Remove the single `mark_debug` on `fc_rx_fifo_ready` in `tidelink_fc_adapter.sv:79` and `tidelink_top.sv:607`, rebuild without `FPGA_INSERT_DEBUG_CORE=1`. If returner clears, the ILA route is the culprit. (Even faster: keep the mark, rebuild with `FPGA_INSERT_DEBUG_CORE=0`. Build #3 baseline.)

---

### H3 — Returner-AHB-master FSM is in `ST_DATA_PHASE` on the **second** doorbell beat, and the FC-adapter's `rtn_pending_r → rtn_hready` handshake stalls because the `skid_can_accept ↔ tl_fc_a2l_ready` loop fights a debug-core-introduced register-replication of `tl_fc_a2l_ready` (20 %)

**Mechanism.** `tidelink_fc_adapter.sv:380` ties `skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready`. `tl_fc_a2l_ready` is mark_debug'd at `tidelink_top.sv:497`. When Vivado inserts the ILA, it inserts a 1-stage `C_INPUT_PIPE_STAGES=1` (`insert_debug_core.tcl:91`) on every probe — but the probe is on the wire, so the *source* wire is replicated/buffered. If P&R lifts `tl_fc_a2l_ready` to a different timing arc than the consumer `skid_can_accept`, a one-cycle stale read on `tl_fc_a2l_ready` makes the skid latch a word the FC layer also took, double-popping the FC TX. The returner thinks its single word never landed (since `rtn_pending_r` clear requires `skid_can_accept` *now* — line 234), so the FSM never returns to IDLE. The first doorbell may transit fine; the second (channel 1 vs channel 2 priority swap inside `tidelink_returner.sv:124-128`) is when the address-latch wins a race condition.

**Predicted signature.** Master ILA: `rtn_pending_r` high, `tl_fc_a2l_valid` and `tl_fc_a2l_ready` both pulsing but offset by one cycle in a pathological way. Returner `pending_1` is **set**, `pending_2` is **clear**.

**Cheapest experiment.** Set `C_INPUT_PIPE_STAGES 0` in `insert_debug_core.tcl:91` and rebuild. If the wedge clears, the input pipe-stage is the offender. Alternatively force `(* keep="true", dont_touch="true" *)` on `tl_fc_a2l_ready` in `tidelink_top.sv:497` so Vivado cannot replicate.

---

### H4 — ILA's `C_DATA_DEPTH 4096` consumes 8 BRAMs that displaced the BD's internal SmartConnect AXI-Stream FIFO into LUTRAM, lengthening its drain and creating a new credit deficit (15 %)

**Mechanism.** `insert_debug_core.tcl:87` requests `C_DATA_DEPTH 4096`. For ~50-bit-equivalent worth of probes that costs roughly 8 × 36K BRAM tiles. The PYNQ-Z2 has only 140 36K-tiles total and the BD already uses BRAMs for FC-node FIFOs, FIFO data path, and the XHB500 outstanding buffer. If Vivado runs out of BRAMs it silently demotes a SmartConnect or AXI4-Stream FIFO into LUTRAM — which now has different write/read latency. The Wlink FC node's CDC FIFO (rx_clk → tx_clk) may now require one extra cycle to drain. The returner reaches DATA_PHASE on its first doorbell and stalls on `hready` because the FC TX skid never drains. The "first doorbell ring" specificity is because the *reset* doorbell at POR may have used a momentarily-empty FIFO and slipped through, but the second-ring (CPU-initiated) hits a steady-state full FIFO.

**Predicted signature.** Vivado utilisation report shows ≥ 95 % BRAM_18K and any "FIFO Generator" with `MEMORY_TYPE = distributed`. ILA on the FC TX: `tl_fc_a2l_valid` is held high for ≥ 3 cycles between `_ready` pulses (vs ~1 cycle in build #3).

**Cheapest experiment.** `cat .../tidelink_project.runs/impl_1/*_utilization_placed.rpt` from the build #5 artefact and compare BRAM_18K counts to build #3 (no edit required). Or rebuild #5 with `C_DATA_DEPTH 1024` (4× smaller) and see if the wedge clears.

---

### H5 — `socl_l7_wdog_force_clear` firing causes a re-ordered ACK to drop a SIDEBAND packet payload mid-flight (10 %)

**Mechanism.** Looking at `src/rtl/local_overrides/WlinkGenericFCSM_6.v` patch: `socl_l7_wdog_force_clear` AND-clears `send_nack_req` in every state. The watchdog fires once per reset cycle, 16 384 cycles after entering state 7. While in state 7, `_GEN_124 = send_nack_req ? out_prepend_swi_nack_id : ...` is driving the TX prepend bus. When the watchdog deasserts `send_nack_req` mid-cycle, the prepend mux flips to whatever `_GEN_56` is. If at that very edge a SIDEBAND packet (PKT_SIDEBAND, addr=0x024) was being emitted, its header may be replaced by `_GEN_56` content — corrupting the addr_offset such that the slave decodes it as a write to a *different* APB register (e.g. flush, or the address translator config). The slave never writes `doorbell_response_acc`. Master's returner is wedged because the FC TX backpressured during the same cycle (the skid was loaded with a corrupt word that the slave RX silently dropped — `rx_pending_r` never clears slave-side).

**Predicted signature.** Slave APB tap-monitor: an extraneous write to a non-doorbell register at exactly the time the watchdog fires (~660 µs after first POR-driven state-7 entry). Master ILA: a single `send_nack_req` glitch falling edge.

**Cheapest experiment.** Bump `SOCL_L7_WDOG_THRESHOLD` from `16'h4000` to `16'hFFFF` and re-run. If wedge moves out to ~16 ms post-bringup, the watchdog itself is the disruptor.

---

### H6 — IDELAY_GROUP attribute interaction with mark_debug-replicated nets (5 %)

**Mechanism.** The pair-flip-all target's `_idelay.xdc` binds `IODELAY_GROUP tl_rx_idly` to per-lane IDELAYE2 cells. When mark_debug is added to a net the IDELAY drives (e.g. `pad_rx_*` cap clock), Vivado replicates the IDELAYE2 output. The replica fan-out may break the IODELAYCTRL ready-handshake to one specific lane, causing intermittent bit errors that the FCSM hides (a transient bit error in a *sideband* word is not necessarily a CRC corruption — the FCSM only checks per-packet CRC). Doorbell packets get silently mis-decoded as flushes / address-translator writes.

**Predicted signature.** Single-lane RX bit-error rate elevated in long captures; only sideband packets affected (FIFO_DATA has different alignment). Build is using `FPGA_USE_IDELAY=1`.

**Cheapest experiment.** Confirm whether the failing target has `FPGA_USE_IDELAY=1`; if no, dismiss this hypothesis cheaply. If yes, build with `mark_debug = "false"` on `pad_rx_*` only.

---

## 3. Cheapest 30-minute HW experiment

**Read master's local `REG_DOORBELL_RESP_ACC` (APB 0x44032000 + 0x024) AND check if `pair_base_addr` is sane.**

This is a pure APB read — no rebuild, no reflash. Two outcomes:

- **Non-zero local DB_RESP** → H1 is confirmed (slave is writing to the wrong tidelink because of a same-cycle APB-mux collision, OR the two boards have swapped/aliased `pair_base_addr`). 30 minutes gives you time to also reset and re-ring to see if DB_RESP accumulates.
- **Zero local DB_RESP** → H1 is falsified. Use the remaining 20 minutes to run the ILA capture already in place: pull a waveform of `rtn_pending_r`, `rtn_hready`, `skid_valid_r`, `tl_fc_a2l_valid`, `tl_fc_a2l_ready`. Whichever signal is the leftmost wedged one points to H2 (rx-side), H3 (skid), or H4 (FC drain stalled).

This experiment is **strictly diagnostic** and disambiguates 3 of 6 hypotheses on one HW lease without re-build.

## 4. What I would NOT do

- **Don't dig deeper into the FCSM internal state for SEND_NACK / cr_pkt / crack_pkt behaviour.** The watchdog patch demonstrably moved master FCSM to state 4 — the FCSM is *not* the symptom site. Spending more cycles on it gives diminishing returns.
- **Don't iterate on the `mark_debug` attributes one-at-a-time.** With 24 attrs, that is 24 builds. Instead, do **one** build with `FPGA_INSERT_DEBUG_CORE=0` (= equivalent to build #3 minus the watchdog) and one with `FPGA_INSERT_DEBUG_CORE=1` + the watchdog. If the no-ILA + watchdog build passes traffic, the ILA itself is the issue — not the RTL. That's a binary signal in 2 builds, not 24.
- **Don't rebuild with `FPGA_ALLOW_CRITICAL_WARNINGS=1`.** The post-impl CW check (`build_design.tcl:283`) is the only thing keeping silent constraint drops out of the bitstream. The lane-lock saga (`build_design.tcl:37-47`) is documented; bypassing the gate to "go faster" is exactly the regression class that's already burned days.
- **Don't trust 3/5 deploys reaching `lane_locked=0xff, cal_done=1` as evidence the link is healthy.** Lane lock is the *physical* layer; doorbell traffic is at L4. The fact that 2/5 deploys land in a transient sub-state suggests the convergence is *marginal*, and ILA insertion may have nudged hold margin on the calibrator state machine — see `tidelink_phy_align_calibrator.sv:472` (existing comment "phase combos reached LINK_IDLE but doorbells didn't cross"). That comment is a smoking gun for **prior, independent observation of exactly this class of partial-link symptom**; the existing diagnosis team may already have it in scope, but if not, the audit of phy_align_calibrator's post-S_PROBE settling should be the H7 added next.
- **Don't add more mark_debug attrs to "see deeper".** Every attr widens the ILA, increases BRAM pressure (H4), and changes P&R (H2, H3). Use Vivado's `report_route_status` + post-route DCP probe on the *existing* nets first.

## 5. Independent-convergence note

The original prompt warns that this hypothesis bank may largely re-derive what the prior team has already considered. Looking at my list:

- **H1 (APB-mux collision)** is suggested by `tidelink_phy_align_calibrator.sv:472`'s self-aware comment but I do not see it called out in the file list; this could be novel.
- **H4 (BRAM displacement)** is purely build-resource — checkable from the existing utilisation report in 5 minutes without a re-build; unlikely to be in the existing chain because that chain focuses on FCSM RTL.
- **H2, H3, H5, H6** are all "the ILA's *physical* insertion broke something downstream of the FCSM". This is the *class* the prior chain seems to be ignoring (their chain is in the RTL diagnostic plane; mine is in the build-tooling plane). That's the value-add.

If the prior team has already covered H1 or H4, please flag — those are the strongest candidates and the cheapest to test.

---

**Word count:** ~1 480.

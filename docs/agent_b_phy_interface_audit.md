# Agent B: Calibrator → PHY interface audit

Scope: static-only RTL audit of the path from `u_calibrator`
(`tidelink_phy_align_calibrator`) outputs into the WavD2DGpio TX / RX modules
inside the `axi_chiplet_controller`, with the AUTOCAL bug "M→S sideband never
reaches the slave FC adapter; S→M works" in mind.

Build path used for `tidelink_top_pair` (cocotb): `flist/tidelink_fpga.flist`.
Confirmed via `cocotb/tidelink_top_pair/Makefile` (`-f $(TIDELINK_HOME)/flist/tidelink_fpga.flist`).
**That flist replaces `WavD2DGpio.v`, `WavD2DGpioRx.v` and `WavD2DGpioTx.v` with
local overrides in `src/rtl/local_overrides/`** (lines 108, 115, 123 of the flist).
The `deps/` copies are NOT in the elaboration set for sim.

`tidelink_top.sv` hardcodes `AUTOCAL_ENABLE(1'b1)` for both M and S
(`tidelink_top.sv:1630`), so the calibrator fires on every `role_locked` rising
edge independent of any cocotb force.

Sim parameter settings (default tb_top, no override):
* `USE_IDELAY = 0` → `tidelink_idelay_rx` is **pass-through**; `phase_offset`
  does NOT affect the IDELAY tap line in sim.
* `USE_CLKBUF = 0` → no BUFG on the recovered RX clock; bit-exact mux chain.
* `USE_T3A    = 0` → `WavD2DGpioRx` comma-hunt FSM gated out.

This narrows the calibrator's effect on the sim to:
1. `swi_phase_offset_in` → `WavD2DGpioRx.io_phase_offset` → `adj_count` →
   RX deserialiser bit-position AND word-clock derivation.
2. `swi_bit_slip_in` → `WavD2DGpioRx.io_bit_slip` → post-capture 16-bit right
   rotation.
3. `swi_training_mode_in` → wrapper `effective_training_mode_{tx_raw,rx}`
   → per-lane `WavD2DGpioTx.io_training_mode` (mux + clock-gate).

`calibration_done` is **NOT** wired to any FCSM gate (verified
`axi_chiplet_controller.sv:1181` — it goes only into the autoneg I²C FSM as
`local_calibration_done_i`, and into APB readback at Region 8). The FCSM gates
on `wlink_por_reset = ~poresetn | ~role_locked` (`axi_chiplet_controller.sv:751`)
— so the FCSM is running concurrently with the calibration sweep, blindly
generating cr_pkts that get overwritten by the per-lane training pattern
whenever `training_mode=1`.

---

## 1. Calibrator → PHY signal map

`u_calibrator` is `tidelink_phy_align_calibrator` instantiated at
`deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1327`.

| Calibrator output | Driven by (calibrator) | Lands at (Wlink/PHY) | Effect after `S_DONE` (training_mode=0) |
|---|---|---|---|
| `bit_slip[23:0]` | `bit_slip_internal` per-lane, latched in `slip[i]` at sweep exhaustion or first lock | `swi_bit_slip_w = cal_bit_slip_w \| swi_bit_slip_lo_r` → Wlink → per-lane `WavD2DGpioRx.io_bit_slip[2:0]` (overrides line 644/658/672/686/700/714/728/742) | **LATCHED**, applies a 16-bit-wide right-rotate of the post-capture word (`io_link_data = _link_data_rep[{2'b00, io_bit_slip} +: 16]`, `WavD2DGpioRx.v:254`). Pure word-rotate, no timing effect. |
| `phase_offset[31:0]` | `phase_offset_internal` per-lane, latched in `phase[i]` at sweep exhaustion or first lock | `swi_phase_offset_w = cal_phase_offset_w \| swi_phase_offset_r` → Wlink → per-lane `WavD2DGpioRx.io_phase_offset[3:0]` (overrides line 643/657/671/685/699/713/727/741). ALSO routed to `tidelink_idelay_rx.phase_tap_i` (passthrough in sim). | **LATCHED**, drives `adj_count = count + io_phase_offset` (`WavD2DGpioRx.v:180`). Affects (a) which `count` value selects each captured bit (`adj_count == 4'hk`) and (b) the divided word clock fed to `link_data_reg`: `io_link_clk_mux_io_i_a = ~adj_count[3]`. Changing `phase_offset` shifts the RX **word clock edge**. |
| `training_mode` | `(cur_state == S_ARM) \|\| (cur_state == S_SWEEP) \|\| (cur_state == S_HOLD)` (`tidelink_phy_align_calibrator.sv:738-739`) | `swi_training_mode_w = cal_training_mode_w \| swi_training_mode_r` → Wlink → `WavD2DGpio.io_swi_training_mode_in` → `input_training_mode_w` → TWO derived signals (see §3) | After `S_DONE` the input falls. The TX mux source `effective_training_mode_tx_raw` (= input, raw) drops IMMEDIATELY. The TX clock-gate driver `effective_training_mode_rx` (= input \| `post_train_hold_ctr_r != 0`) stays HIGH for **POST_TRAIN_HOLD_CYCLES = 64** more link-word cycles. The per-lane `WavD2DGpioTx.io_training_mode_q` register **delays the mux flip** to the next per-lane `count==4'hf` boundary (tdif-03). |
| `calibration_done` | `(cur_state == S_DONE)` | `cal_calibration_done_w` → 2-FF sync → `sync_cal_done_1` → APB Region 8 SWI_LANE_STATUS bit 16 AND autoneg FSM `local_calibration_done_i`. **NOT wired to any Wlink/FCSM gate.** | Status / observation only. |
| `lane_fault[7:0]` | `lane_fault_q` | `cal_lane_fault_w` → Region 8 sync → APB SWI_LANE_STATUS bits[15:8] | Observation only. |
| `state[3:0]` | `cur_state` | `cal_state_w` → Region 8 sync → APB SWI_LANE_STATUS bits[7:4] | Observation only. |

**Key fact:** of the 6 calibrator outputs only THREE (`bit_slip`,
`phase_offset`, `training_mode`) physically modulate TX or RX data; all three
are merged with their Region-8 SW-override twin via an OR (no priority, no
mux), so SW writes can ADD bits but cannot mask the calibrator.

---

## 2. Local override vs deps deltas

Diff vs `deps/axi-chiplet-controller/logical/wlink/` originals
(`tidelink_fpga.flist` excludes the deps copies of these three files):

* `src/rtl/local_overrides/WavD2DGpio.v` (1033 lines vs 888 in deps; +145):
  Adds the **Bug-FC1 post-training hold extension** (POST_TRAIN_HOLD_CYCLES=64,
  `post_train_hold_ctr_r` clocked on `io_link_tx_tx_link_clk`). Splits the
  effective training signal into `_tx_raw` (immediate, drives the per-lane TX
  MUX), and `_rx`/`effective_training_mode` (held, drives `gpiotx_N_io_clk_en`
  for ALL 8 lanes). Also adds `swi_phase_offset` APB reg at PHY-ctrl bits[20:17]
  and an `effective_phase_offset` per-lane OR-merge with `io_swi_phase_offset_in`.
  Inert `mux_align_count_r` / `effective_training_mode_tx_q` placeholders
  retained for ILA continuity (the wrapper-level word-align fix tdif-02 was
  superseded by per-lane tdif-03 inside WavD2DGpioTx).

* `src/rtl/local_overrides/WavD2DGpioTx.v` (275 lines vs ~150 in deps; +125):
  Adds **tdif-03 per-lane word-aligned training-mux**. New parameter
  `WORD_ALIGN_MUX=1` (default ON) gates a `io_training_mode_q` register
  sampled at `count==4'hf` on `io_clk`. The 16-bit replace-with-training-pattern
  mux reads from `io_training_mode_q` instead of the raw input, so the mux
  flip is guaranteed to land between 16-bit words for THIS lane regardless of
  cross-lane phase.

* `src/rtl/local_overrides/WavD2DGpioRx.v` (568 lines vs 463 in deps; +105):
  Adds **tdif-06 bounded continuous re-arm** of the T3A comma-hunt FSM
  (`T3A_CONTINUOUS` parameter, default 0 — disabled in sim/ASIC), and the
  `USE_CLKBUF` BUFG branch (also disabled in sim). With T3A_CONTINUOUS=0 and
  USE_T3A=0 the RX is **bit-exact** with the deps copy — no functional
  divergence in sim.

**Net sim divergence vs deps:** only `WavD2DGpio.v` (post-train hold + per-lane
phase OR-merge) and `WavD2DGpioTx.v` (word-align mux). The RX override is
bit-exact in sim.

---

## 3. Residual training-mode hazard

`WavD2DGpio.v` (override) splits one `input_training_mode_w` into two derived
signals:

```
417:  wire        input_training_mode_w   = io_swi_training_mode_in  | swi_training_mode;
418:  reg  [6:0]  post_train_hold_ctr_r;
419:  always @(posedge io_link_tx_tx_link_clk or posedge por_reset_scan_wrs_io_reset_out) begin
420:    if (por_reset_scan_wrs_io_reset_out) begin
421:      post_train_hold_ctr_r <= 7'd0;
422:    end else if (input_training_mode_w) begin
425:      post_train_hold_ctr_r <= POST_TRAIN_HOLD_CYCLES;
...
438:  wire        effective_training_mode_tx_raw = input_training_mode_w;
439:  wire        effective_training_mode_rx =
440:                input_training_mode_w | (post_train_hold_ctr_r != 7'd0);
441:  wire        effective_training_mode    = effective_training_mode_rx;
```

* `effective_training_mode_tx_raw` (line 438) → per-lane
  `WavD2DGpioTx.io_training_mode` for the **MUX source**. tdif-03 inside
  WavD2DGpioTx then delays the mux flip to its own per-lane `count==4'hf`.
* `effective_training_mode` (= rx, **held**) (line 441) → per-lane
  `gpiotx_N_io_clk_en` (line 782, 789, …, 831) AND the `effective_phase_offset`
  is unrelated to this OR.

`training_mode` is generated by the **calibrator**, which runs on the
**recovered RX clock** (`phy_link_rx_rx_link_clk_w`). For master M, the
calibrator clock is **derived from slave S's TX pad clock**. So **M's
`training_mode` falls on an edge of S's TX clock; S's `training_mode` falls on
an edge of M's TX clock**. The two transitions are NOT simultaneous and are
not in the same clock domain. M's calibrator can drop `training_mode` while
S's calibrator still has it asserted (and vice versa).

Re-armability: from `S_DONE` the calibrator only re-arms on
`role_locked_rise | (swreset_fall & role_locked)`
(`tidelink_phy_align_calibrator.sv:282`). Within `S_HOLD` it watches
`hold_ctr >= HOLD_MAX` (HOLD_CYCLES = 8·128·64 = **65 536** cycles in the
calibrator clock domain) — so `training_mode` stays HIGH for ~65k recovered
RX-clock ticks past sweep success.

**Hazard: asymmetric S_HOLD entry/exit.** Because each calibrator's clock is
its peer's TX clock, the two `S_HOLD` windows are skewed by the
`role_lock`-skew + slip×phase sweep duration. On HW this is many ms; in sim
it's just the bring-up sequence latency. Whichever side leaves S_HOLD first
flips its TX MUX to live FC data (per-lane, at its own `count==4'hf`); the
other side is still emitting training pattern AND its RX lane-checker now sees
FC data on its inbound stream → its `lane_locked` drops.

That drop **does not** re-arm the calibrator (it is sticky on S_HOLD / S_DONE
by design — see calibrator lines 473-480). So one side ends up locked-and-OK
while the other ends up in S_DONE with stale `slip[i] / phase[i]` latched
against a *training pattern* that no longer exists, but driving live FC data.

---

## 4. TOP suspect interactions (post-`S_DONE` corruption candidates)

### Suspect A — `effective_training_mode` (held) drives `gpiotx_N_io_clk_en` but `effective_training_mode_tx_raw` (un-held) drives the MUX source. Asymmetric M vs S because the falling-edge phase is uncorrelated.

**File:** `src/rtl/local_overrides/WavD2DGpio.v:782` (repeated 781-831 for 8 lanes):

```
780:    assign gpiotx_0_io_clk = hsclk_scan_mux_io_o_z;
781:    assign gpiotx_0_io_reset = io_por_reset;
782:    assign gpiotx_0_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode;
783:    assign gpiotx_0_io_link_data = tx_lane_en ? tx_lane_data : 16'h0;
784:    assign gpiotx_1_io_scan_mode = io_scan_mode;
```

The OR-term `effective_training_mode` is the **held** RX-side signal
(POST_TRAIN_HOLD_CYCLES=64 link-word cycles past calibrator `training_mode`
falling edge). But the corresponding MUX input — `gpiotx_N.io_training_mode`
(line 525, 540, … 630) — is fed `effective_training_mode_tx_raw` (un-held).

Inside `WavD2DGpioTx.v` the io_training_mode goes into `io_training_mode_q`
sampled at `count==4'hf`; the **io_clk_en** goes into `clk_en_qual` ALSO
sampled at `count==4'hf` (override line 213-214). So both signals are aligned
to per-lane word boundaries, BUT they're aligned to DIFFERENT inputs:
- The mux drops the training pattern at the FIRST per-lane `count==4'hf` after
  `_tx_raw` falls.
- The clock-gate stays asserted until the FIRST per-lane `count==4'hf` AFTER
  `effective_training_mode` (held) falls — which is at least
  POST_TRAIN_HOLD_CYCLES=64 link-word cycles (= 64·16 = 1024 hsclk cycles)
  later.

During that 1024-hsclk window, the TX serialiser is **clocked but emitting
live FC data**. The peer RX sees the transition. The peer RX deserialiser
captures whatever bits the FC adapter happens to be sending — which during
calibrator bringup is `cr_pkt` words. There is no quiescent idle pattern
between training and FC data; the moment training drops, the peer must already
have its `count` aligned to the FC frame.

**Why M→S asymmetric:** the 64-link-word hold counter is clocked on
`io_link_tx_tx_link_clk = gpiotx_0_io_link_clk = ~count[3]` (line 419).
`count` is in the hsclk domain (line 203). The hold counter starts running
1024 hsclk cycles AFTER the input training_mode rises (it loads
POST_TRAIN_HOLD_CYCLES while training is high — line 425). Because M's and S's
hsclk are independent oscillators (or independent reset arrivals from the same
oscillator) the count phase between them is uncorrelated — so the moment when
M's mux flips to FC data does NOT coincide with the moment S's RX `count`
hits a word boundary.

**Recommended action:** drive `gpiotx_N_io_clk_en` from
`effective_training_mode_tx_raw` (the IMMEDIATE input) for symmetry — both
the mux and the clock-gate then have the same transition reference.
Alternatively unify on the held signal everywhere (and accept the slightly
prolonged training-pattern window post-`S_DONE`).

### Suspect B — `phase_offset` continues to drive the RX `adj_count` after sweep exhaustion in best-of-sweep mode, but `phase[i]` only matches `sweep_phase` AT exhaustion.

**File:** `src/rtl/tidelink_phy_align_calibrator.sv:710-722`:

```
710:    always_comb begin
711:        bit_slip_internal     = 24'h0;
712:        phase_offset_internal = 32'h0;
713:        for (int i = 0; i < 8; i++) begin
714:            if (lane_done[i]) begin
715:                bit_slip_internal[3*i +: 3]     = slip[i];
716:                phase_offset_internal[4*i +: 4] = phase[i];
717:            end else begin
718:                bit_slip_internal[3*i +: 3]     = sweep_slip;
719:                phase_offset_internal[4*i +: 4] = sweep_phase;
720:            end
721:        end
722:    end
```

While `lane_done[i] == 0` (every lane until sweep exhaustion in best-of-sweep
mode), the **live** `(sweep_slip, sweep_phase)` is driven out, including
through the dwell window. After exhaustion, in the same cycle that
`lane_done[i]` becomes 1, `slip[i]/phase[i]` are loaded from
`best_slip/best_phase` *or from `sweep_slip/sweep_phase` if the just-finished
dwell scored above best*. The outputs therefore transition from "live sweep
iterator" to "latched best" in a single combinational cycle.

This is **not** asymmetric per se, BUT: while M is sweeping, M's
`swi_phase_offset_w[3:0]` walks 0→15 → 0→15… driving M's `gpiorx_0.io_phase_offset`,
which changes `adj_count` and **the M-side word clock derivation
(`~adj_count[3]`)**. This is M's LOCAL RX behaviour. It does NOT directly
affect M→S transmission. The same applies symmetrically on S.

The risk is **second-order** — M's RX deserialiser is unstable during M's
sweep; if a downstream consumer of M's `phy_link_rx_rx_link_data_w` (e.g. the
lane checker that feeds back to M's own calibrator, AND the FCSM via Wlink
RX path) latches mid-update it produces glitches in the M-side FCSM and lane
checker. This in turn affects M's `lane_locked` → M's calibrator scoring.

If this race is the bug it would be **symmetric** (M and S both suffer), so
A is the more likely cause of the M→S asymmetry. **B is a stability
risk worth fixing but does not explain the asymmetric symptom.**

### Suspect C — Calibrator clock domain is the **peer's** TX link clock, so calibration_done/training_mode falling-edge phase is uncorrelated between M and S.

**File:** `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1327-1355`:

```
1327:    tidelink_phy_align_calibrator u_calibrator (
1328:        .clk                   (phy_link_rx_rx_link_clk_w),
1329:        .rst                   (~poresetn),
1330:        .role_locked           (calibrator_role_locked),
...
1351:        .training_mode         (cal_training_mode_w),
```

The calibrator clock is the **recovered RX clock**, which is derived from the
PEER's `gpiotx_0_io_link_clk`. So M's `cal_training_mode_w` falling edge is
in S's TX link clock domain (which is `~count[3]` of S's gpiotx_0). That edge
then OR-merges combinatorially with `swi_training_mode_r` (apb_clk domain)
into `swi_training_mode_w`, then crosses combinatorially into M's
`WavD2DGpio.io_swi_training_mode_in`, then into M's `input_training_mode_w`,
then into M's `effective_training_mode_{tx_raw,rx}`, then is sampled by M's
per-lane TX `io_training_mode_q` register at M's own `count==4'hf` on M's
hsclk.

That's **three uncorrelated clock domains** in series (S's link clock → M's
apb_clk-mixed combinatorial → M's hsclk). No CDC synchroniser on any of the
hand-offs. The combinatorial OR with `swi_training_mode_r` makes it worse —
a brief glitch on `cal_training_mode_w` (e.g. caused by metastability when
the calibrator state transition lands near M's hsclk edge that samples
`count==4'hf`) can be captured into `io_training_mode_q` for any subset of the
8 lanes asymmetrically.

**Confirmation route in sim:** force `m_calibrator.training_mode` to remain
HIGH artificially (cocotb `force`) and observe whether M→S sideband recovers.
If yes, this CDC path is the culprit.

---

## 5. Cross-check against memory `project_tidelink_interface_fcsm_bug_2026_05_24`

That memory's claim "asymmetric slave LL_RX byte-align loss at mid-word mux
flip (WavD2DGpioTx.v:43)" was fixed by the **tdif-03 local override** of
`WavD2DGpioTx.v` — confirmed live in the sim build. The mux is now gated by
`io_training_mode_q` (registered at `count==4'hf`), not `io_training_mode`.
So that specific bug is closed in the elaborated sim netlist.

The **residual asymmetry** identified in §3 and Suspect A is a SECOND
symptom of the same root pattern: the wrapper-level `effective_training_mode`
hold counter and the per-lane TX MUX latch run on **different
samplers** (counter on `io_link_tx_tx_link_clk` = /16 word clock of gpiotx_0;
per-lane register on the lane's own hsclk + count==4'hf). On HW these were
"~simultaneous" once the lane was locked, so the bug was masked. With the
calibrator now driving the per-lane phase live and re-introducing
cross-lane phase variability, the mismatch between the held clock-gate and
the un-held mux is exposed.

---

## TOP SUSPECT — one-paragraph

**Suspect A: `effective_training_mode` (held) drives `gpiotx_N_io_clk_en` while
`effective_training_mode_tx_raw` (un-held) drives the MUX source.**
`src/rtl/local_overrides/WavD2DGpio.v:782` ORs the **held** RX-side training
signal into the per-lane TX clock-gate, while line 525 (and equivalents for
lanes 1..7) feeds the **un-held raw** input into the per-lane MUX `io_training_mode`
pin. Inside `WavD2DGpioTx.v` BOTH inputs are re-sampled at `count==4'hf`, but
since their source signals diverge for POST_TRAIN_HOLD_CYCLES=64 link-word
cycles (lines 416-441), the MUX flips to live FC data 1024 hsclk cycles
BEFORE the clock-gate would have permitted a quiescent window for the peer
to re-align. The peer's RX byte alignment is therefore disturbed exactly at
the moment the FC path goes live. The asymmetry M→S vs S→M arises because the
hold counter is clocked on the wrapper's `io_link_tx_tx_link_clk = ~count[3]`
which is the master-side derived word clock, while the calibrator's
`training_mode` arrives in the **peer's** RX clock domain via three
uncorrelated clock hand-offs (Suspect C). M's mux-vs-clkgate skew is sized by
S's word clock; S's by M's. If M's hsclk leads S's by a fraction of a word
period the M→S MUX flip lands inside S's RX `count` cycle, but the S→M flip
lands at a benign offset.

---

## 300-word summary (top suspect)

The audit identifies **`gpiotx_N_io_clk_en` being driven by the HELD RX-side
training signal while the per-lane TX MUX source is the UN-HELD raw input**
as the most likely cause of the M→S asymmetric sideband-loss seen with
`AUTOCAL_ENABLE=1`. In `src/rtl/local_overrides/WavD2DGpio.v`, the
`effective_training_mode_rx`/`effective_training_mode` wire holds for 64
link-word cycles past calibrator `training_mode` falling edge
(POST_TRAIN_HOLD_CYCLES, the Bug-FC1 fix), and that held signal is ORed into
each lane's `io_clk_en` (lines 782, 789, …, 831). The corresponding MUX
control `gpiotx_N.io_training_mode` is fed the raw `effective_training_mode_tx_raw`
signal (lines 525, 540, …, 630) which drops the instant calibrator
`training_mode` falls. Both inputs are then word-aligned inside
`WavD2DGpioTx.v` by sampling at `count==4'hf`, but because the two source
signals diverge for 64 link-word cycles, the per-lane MUX flips to live FC
data immediately at the next word boundary while the clock-gate would have
permitted up to 1024 hsclk cycles more of pattern time. There is **no
quiescent or idle pattern** between training and FC data: the peer's RX,
having byte-aligned to the training byte, sees a hard discontinuity into
arbitrary `cr_pkt` data — exactly the symptom the tdif-02/03 fix history
already attributes to the slave's LL_RX byte-align FSM. The M→S vs S→M
asymmetry follows from Suspect C: the calibrator runs in the **peer's** TX
clock domain, so M's `training_mode` falling edge is timed against S's
`~count[3]` word clock and vice-versa — through three uncorrelated clock
domains with no CDC synchroniser. A small phase skew between M and S
hsclks therefore lands the M→S MUX flip on a different sub-word boundary than
the S→M flip, breaking only one direction. Fix: drive `gpiotx_N_io_clk_en`
from `effective_training_mode_tx_raw` (immediate input) so the gate and mux
share the same edge, OR replace the OR-merge of the held signal with an
explicit synchroniser before consuming it in the hsclk domain.

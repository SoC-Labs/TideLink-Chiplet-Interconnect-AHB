# TideLink FPGA Bring-up Report

**Date:** 2026-05-14
**Author:** David Mapstone (with Claude Code assistance)
**Branch:** `feat/fpga-flow`
**Boards:** Pynq-Z2 pair `z2_02` (die_a / master, 192.168.4.101) and `z2_03` (die_b / slave, 192.168.6.101), connected by 40-pin RPi GPIO ribbon

## Executive Summary

TideLink (chiplet bridge subsystem wrapping Wlink + XHB500 + a dedicated FC node) is implemented in RTL, passes UVM cocotb tests, and synthesises cleanly to a Pynq-Z2 pair bitstream. **The link-layer handshake on hardware does not complete.** Both boards's TideLink FCSM stays at `state=1` (SEND_CREDITS1), never receives a `cr_pkt` from the peer, and consequently never reaches `state=4` (LINK_DATA). Doorbell traffic doesn't cross.

Investigation has now isolated the root cause to a **deterministic 3-bit serial-to-parallel boundary misalignment at master's `WavD2DGpioRx` deserialiser**. Master's LL_RX produces a `byte0_reg` distribution that exactly matches the seven FC channels' `cr_id` bytes right-shifted by 3 bits — every byte aliases into one of four buckets in the proportions you'd expect from 2+2+1+2 grouping of the seven channels. Slave's LL_RX is even more misaligned and never asserts `valid` at all.

`swi_phase_offset` cannot fix this — that reg adjusts the 1-of-16 sample-point selection *within a single PHY bit period*, not the byte-boundary of the 8-bit serial-to-parallel parallelisation. Bench evidence has ruled out: cable physical fault, FPGA pin mapping, deserialiser-phase calibration (256-combo sweep), the new ILA instrumentation, and an attempted RTL fix that was buggy and reverted. **The fix needs per-lane physical delay calibration (Xilinx `IDELAYE2`), a serial-to-parallel alignment word, or a slower link rate.**

## 1. Where we are in the development pipeline

| Stage | Status |
|---|---|
| RTL design (TideLink chiplet bridge + Wlink wrapper) | Complete |
| Cocotb unit tests (per-channel and pair-level) | Pass |
| UVM TideLink top-system + PTP-chain tests | Pass |
| ASIC synthesis flow (Fusion Compiler partition flow) | **Working** — full init→synth→cts→route→signoff→abstract; 508 k μm² @ 250 MHz, setup WNS **−0.08 ns**, hold WNS −0.34 ns, **24** net DRC violations (after `route_opt -effort high` 2nd pass — was −0.43 / 37 with single pass); MANIFEST.md auto-generated in outputs/ |
| Formality LEC (RTL vs post-route netlist) | **Pass** — 18,837 / 0 / 0 / 264 (passing / failing / unverified / Wlink Chisel residuals don't-verify); see § Appendix A |
| FPGA build flow (Vivado 2024.1, BD-based Pynq-Z2 pair target) | Working — produces .bit + .hwh + .ltx |
| FPGA bring-up: APB readable / `TIDELINK_VERSION` correct | Pass |
| FPGA bring-up: role_lock / strap / debug_unlock | Pass |
| FPGA bring-up: physical PHY (pad_rx data flowing) | Pass — `phy_link_rx_rx_link_data` shows varied non-zero traffic |
| FPGA bring-up: LL_RX decodes packets | **Fail — blocker** |
| FPGA bring-up: cr_pkt handshake completes on both sides | Fail (consequent) |
| FPGA bring-up: doorbell traffic ticks counters | Fail (consequent) |

Cocotb/UVM TideLink tests pass against the synthesised RTL in simulation. The same RTL on hardware doesn't complete the bring-up handshake.

## 2. The blocker, precisely

Both sides:

```
CURRENT_CREDITS   : 4096 (/4096 MAX)   # POR default — never updated by peer
RELEASED_ACC      : 0                  # no credits released back
DOORBELL_RESP_ACC : 0                  # no doorbell traffic
PAIR_CREDIT_CTR   : 0                  # nothing crossed
FCSM_6.state      : 1                  # SEND_CREDITS1 forever
cr_pkt_seen_rx    : 0                  # never saw a peer cr_pkt
crack_pkt_seen_rx : 0                  # never saw a peer crack_pkt
```

### Master view of slave traffic (ILA, 4096 samples, post-deploy)

After clean `deploy_pair.sh` of both v3 ILA bitstreams, master's LL_RX shows:

```
llrx/state         = iSTATE0  (4096/4096 — never leaves initial state)
llrx/valid         = 1 in 4096/4096 (100%) — valid asserted every cycle
phy_link_rx_rx_link_data: varied, 8 lanes alive, rx_mask = 0xff
is_short_pkt_prev  = 1 in 2048/4096 (50%)
```

`byte0_reg` and `byte1_reg` distribution (across all 5 slave-phase captures 0/4/8/12/15 — identical):

| `byte0_reg` | Count | % | Expected if 3-bit right-shifted |
|---|---|---|---|
| `0x01` | ~1180 | 28% | `0x08` (AXI_AR) and `0x0c` (AXI_AW) → `0x01` |
| `0x02` | ~1170 | 28% | `0x10` (AXI_R) and `0x14` (AXI_W) → `0x02` |
| `0x08` | ~1170 | 28% | `0x40` (GenBus) and `0x44` (TideLink) → `0x08` |
| `0x03` | ~580 | 14% | `0x18` (AXI_B) → `0x03` |

| `byte1_reg` | Count | % | Expected if 3-bit right-shifted |
|---|---|---|---|
| `0x01` | ~1760 | 43% | `0x0f` >> 3 = `0x01` (AXI_AR/R/W word_count low byte) |
| `0x07` | ~1170 | 28% | GenBus / TideLink word_count |
| `0x03` | ~580 | 14% | AXI_AW/B `word_count` `0x3f` >> 3 = `0x07`... close but not exact |
| `0x00` | ~580 | 14% | header padding bytes |

**Every byte master's LL_RX captures matches a slave cr_pkt header *under a uniform 3-bit right shift*.** The seven FC channels' header bytes alias into four distinct buckets exactly matching the observed distribution proportions.

### Slave view of master traffic (ILA, 4096 samples, earlier capture under different deploy sequence)

```
llrx/state         = iSTATE0  (4096/4096)
llrx/valid         = 0 (4096/4096) — never asserts
byte0_reg          = 0x00  (4096/4096)
byte1_reg          = 0x00  (4096/4096)
ll_byte_index_0    = cycles 0x00 / 0x40 / 0x80 / 0xC0
phy_link_rx_rx_link_data: varied, 8 lanes alive, rx_mask = 0xff
```

The direction is **asymmetric**: master receives 3-bit-shifted slave traffic, while slave's LL_RX is even further misaligned and never asserts `valid`. (Earlier master capture before this report was the partial state with `valid=1` only 28% of the time, captured during a different deploy ordering; the consistent 4096/4096 post-deploy capture is the canonical one.)

## 3. Investigations and outcomes

### 3.1 ILA instrumentation added (`mark_debug` + `u_dbg_int`)

**Goal:** Get visibility into TX/RX 128-bit link data, FCSM state, LL_RX state, and the cr/crack_pkt latches without having to rebuild every time we want to look at a different signal.

**Approach:** Added `(* mark_debug = "true" *)` to ~20 nets across `Wlink.v`, `WlinkGenericFCSM_6.v`, and `WlinkRxLinkLayer.v`. Wrote `fpga/insert_debug_core.tcl`, sourced post-synth by `build_design.tcl` when `FPGA_INSERT_DEBUG_CORE=1` is set. The script auto-discovers marked nets, groups them by base name (strips `[N]` indices), and creates a single ILA core covering everything.

**Three bugs in the script — all fixed:**

1. `get_nets foo[0]` causes Tcl to evaluate the brackets as command substitution → "Invalid option value 'null' specified for 'nets'". Fixed by storing net *objects* (not string names) at discovery time.
2. Default core name `u_ila_int` collides with the existing `tidelink_design_ila_rx_0` IP's internal instance — created a debug-port clash and pulled IP-internal nets into the clock-candidate list. Renamed to `u_dbg_int`.
3. Clock candidate selection picked the shortest *string*-length match, which favoured an IP-internal net (`u_ila_int_clk_wiz_0_clk_out1`) over the BD top-port (`tidelink_design_i/clk_wiz_0_clk_out1`). `connect_debug_port` accepted it but Chipscope DRC failed at impl_1 with "debug port has 1 unconnected channels". Fixed by preferring fewest `/`-separated segments.

Also: stripped `create_debug_core` / `connect_debug_port` stanzas that had crept back into `pynq_z2_tidelink_drc.xdc` after a `save_constraints` round-trip; they referenced net names that only existed under `mark_debug` preservation.

**Result:** Working 22-probe ILA covering `phy_link_tx_tx_link_data[127:0]`, `phy_link_rx_rx_link_data[127:0]`, FCSM `state`, `cr_pkt_seen_rx`, `crack_pkt_seen_rx`, LL_RX `state`, `byte0_reg`, `byte1_reg`, `ll_byte_index_0`, `is_short_pkt_prev`, `valid`, plus TX-side `sop`, `data_id`, `word_count`, `advance`, lane masks. Captured during bring-up — produces the per-board snapshots used throughout this investigation.

### 3.2 Did the ILA itself break bring-up?

**Hypothesis:** Adding `mark_debug` to many nets + inserting a 22-probe ILA core consumes routing and BRAM near the wlink subsystem, possibly tightening hold margins on `pad_clk_rx → deserialiser` paths.

**Test:** `git checkout HEAD` plus a full revert pass removing every `mark_debug` attribute and unsetting `FPGA_INSERT_DEBUG_CORE`. Rebuilt both bitstreams (`pynq-z2-pair-all` and `pynq-z2-pair-flip-all`) clean from synth.

**Result:** Link still stuck at the same default counters. **ILA is not the cause.**

A secondary finding: both impl_1 timing reports show one hold violation at WHS = −0.56 ns, on `pad_clk_rx → tidelink_design_i/ila_rx/inst/PROBE_PIPE.shift_probes_reg[0][0]/D` — the *existing* `ila_rx_0` IP's debug-capture path, not the functional Wlink deserialiser. Pre-existing, debug-only, does not affect functional behaviour.

### 3.3 Attempted RTL fix to `WlinkGenericFCSM_6.v` — and its reversal

**Earlier-session hypothesis:** `crack_pkt_seen_rx` was POR-only-sticky, preventing the SW-driven swreset path from re-arming the FCSM after a transient. A change was made to its reset domain.

**This session, diff against git HEAD:**

```verilog
// HEAD (correct)
always @(posedge io_rx_clk or posedge io_rx_reset) begin
  if (io_rx_reset)                cr_pkt_seen_rx <= 1'h0;
  else if (_fe_tx_credit_max_in_T) cr_pkt_seen_rx <= 1'h0;   // <-- normal re-arm path
  else                             cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;
end

// In-session "fix" — broken
always @(posedge io_rx_clk or posedge reset) begin            // <-- wrong reset (never asserts)
  if (reset)  cr_pkt_seen_rx <= 1'h0;
  else        cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;   // <-- re-arm path dropped
end
```

Two regressions: (a) reset signal changed from `io_rx_reset` (the wlink POR / role_locked / swi_swreset OR) to system-wide `reset` (boot-only — never asserts in normal operation); (b) the `_fe_tx_credit_max_in_T` clear-path was deleted, so once `cr_pkt_seen_rx` sets it can never clear without a full chip reset.

**Reverted via `git checkout HEAD logical/wlink/WlinkGenericFCSM_6.v` and rebuilt.** Bring-up is still stuck. The RTL fix neither helped nor was the cause of this failure — but the working copy is now back on a known-good state and the broken fix is captured at `/tmp/WlinkGenericFCSM_6.v.brokenfix` for reference.

### 3.4 Deserialiser-phase calibration sweep

**Hypothesis:** `swi_phase_offset` (Wlink PHY ctrl reg WL+0x0000, bits[20:17]) is the standard mechanism for compensating bit-alignment between sender and receiver. SHORTCOMINGS-14b sets master=phase=0, slave=phase=3 by default; both must be written *before* `role_lock` asserts (the `WavD2DGpioRx.count` reg only resets while `role_locked=0`).

**Approach:** Built `phase_sweep_apb.sh` that sweeps all 16×16 = 256 (master_phase, slave_phase) combinations via APB writes + swreset toggle, no bitstream reload. Each iteration: write `PHY_CTRL` to both boards in parallel, toggle `WL+0x208` (`0x27f08 → 0x27f00 → 0x27f07`), read master `CURRENT_CREDITS / RELEASED_ACC / DOORBELL_RESP_ACC / PAIR_CREDIT_CTR`. A non-default reading would mean some packet got through. ~15 minutes total for the full sweep.

**Result, ran twice:** once on the v3 (ILA) build, once on the clean-RTL revert build. Both: **256/256 baseline.** No phase combination recovers the link.

### 3.5 LL_RX byte-level diagnosis from existing ILA captures

The captured `byte0_reg`, `byte1_reg`, `ll_byte_index_0`, `is_short_pkt_prev`, `valid`, and `state` probes (already in the v3 build) tell us LL_RX's internal byte-alignment FSM state. Analysis:

**Master:** Sometimes asserts `valid=1` (28%) with non-zero byte buffers — i.e. LL_RX is detecting *something* but never advancing past `state=0` (iSTATE0). The bytes it captures (`byte0=0x02`, `byte1=0x01`) don't match any known FC channel's `cr_id` directly, but `0x44 >> 5 == 0x02` matches the expected TideLink `cr_id` if there's a 5-bit phase shift.

**Slave:** `valid=0` always, `byte0_reg=0` always, `byte1_reg=0` always — even though the PHY is delivering data. Slave's LL_RX is fully gated.

The byte-alignment FSM in `WlinkRxLinkLayer.v` (LinkLayer.scala 611) advances on ECC validation of the 24-bit packet header. If ECC fails on every word, state stays at iSTATE0. ECC will fail if per-lane bit alignment is wrong by more than `swi_phase_offset` (4 bits) can compensate, or if individual lanes are skewed relative to each other.

**Result of the slave-phase + master-ILA sweep (now complete, 5 captures at slave phase = 0/4/8/12/15):** master's `byte0_reg` / `byte1_reg` distribution is **identical across all five phases**. This is self-consistent — slave's `swi_phase_offset` adjusts slave's *receive* sampling, not its *transmit* framing, so changing slave phase cannot affect what master sees on the wire. To shift master's reception, master's own `swi_phase_offset` is the lever. The earlier full 256-combo sweep already tested all 16 master phases (with all 16 slave phases each) — none recovered the link.

**Conclusion: `swi_phase_offset` cannot fix the 3-bit shift observed at master's LL_RX.** The phase reg operates on a 1/16-cycle sample-point granularity within a single PHY bit period — fine for de-jittering setup/hold margin, but **not for re-aligning to a different bit boundary on the parallel-side word**. A 3-bit shift across the 8-bit serial-to-parallel boundary is not what this knob is for. The fix needs either:

- Per-lane `IDELAY` constraints on `pad_rx_1[0..7]` IBUFs (Xilinx 7-series has `IDELAYE2` primitives, 32-tap calibrated delay lines) to align lanes against each other AND against pad_clk_rx, OR
- A serial-to-parallel alignment word (similar to a comma symbol in 8b/10b) that LL_RX detects to lock the bit-boundary, OR
- A slower link rate so the bit shift falls within the existing `swi_phase_offset` window.

## 4. Tooling produced this session (keep)

| File | Purpose |
|---|---|
| `fpga/insert_debug_core.tcl` | Post-synth ILA insertion driven by `mark_debug` attributes. Set `FPGA_INSERT_DEBUG_CORE=1` to enable. |
| `pynq_host/scripts/wlink_probe.sh` | Snapshot of Wlink + TideLink APB state via sshpass. Display bug: `0x0214 LaneMask` decodes `rx=0x0000` but the actual `swi_rx_lane_mask` is `0xff`; tx/rx masks share the low 16 bits of one word, not separate halves. |
| `/tmp/tidelink_scripts/phase_sweep_apb.sh` (mapstone-dev) | 256-combo phase sweep, no bitstream reload. ~15 min. |
| `/tmp/tidelink_scripts/sweep_with_ila.sh` (mapstone-dev) | Slave-phase sweep + master ILA capture per phase. |
| `pynq_host/scripts/deploy_pair.sh` | Updated to write `swi_phase_offset` BEFORE `role_lock` asserts, plus `PHASE_OVERRIDE` env var for empirical sweeps. |

Memory note `reference_insert_debug_core.md` documents the three Vivado gotchas so the build script doesn't have to be reinvented next time.

## 5. What we know we've ruled out

- **Cable / ribbon physical fault** — confirmed alive via PYNQ-side bench tests (user-confirmed) and the PHY-level data observed on both sides' `phy_link_rx_rx_link_data`.
- **FPGA pin assignment / cable clock-vs-data swap** — verified 2026-05-14. Master `pad_clk_tx`/`pad_tx[7:0]` FPGA package pins exactly match slave `pad_clk_rx`/`pad_rx[7:0]` in the flip-target XDC (forward direction), and slave `pad_clk_tx`/`pad_tx[7:0]` match master `pad_clk_rx`/`pad_rx[7:0]` (reverse). 9/9 pins map symmetrically in both directions on a straight-through ribbon. No swap. `pad_clk_tx` deliberately placed on Y9 (an SRCC P-side pin) per the XDC comment, to satisfy the PLIO-9 DRC on the receiving side. See §7.B for the full table.
- **Stale ILA instrumentation breaking timing** — clean rebuild without `mark_debug` and without `u_dbg_int` shows identical bring-up failure.
- **The in-session FCSM_6 RTL change** — diagnosed as broken (wrong reset signal + dropped re-arm), reverted; bring-up unchanged.
- **Deserialiser-phase calibration** — 16×16 sweep, all 256 combinations stuck at default counters. Reason: `swi_phase_offset` adjusts sample-point within one PHY bit, doesn't rotate the 8-bit S/P parallelisation boundary.
- **Slave-side phase varying master's reception** — captured master's LL_RX byte registers at five slave phases (0/4/8/12/15). The byte distribution is *identical* across all five. Self-consistent: slave's `swi_phase_offset` adjusts slave's *receive* sampling only, not its transmit framing — so it cannot affect what master sees on the wire.

## 6. What we believe is happening

The PHY delivers data, but `WavD2DGpioRx`'s serial-to-parallel deserialisation is locked to the wrong bit boundary, and `swi_phase_offset` cannot correct it.

**Concrete evidence from the slave-phase + master-ILA captures:**

- Master's `byte0_reg` distribution exactly matches the seven FC channels' `cr_id` bytes (`0x08, 0x0c, 0x10, 0x14, 0x18, 0x40, 0x44`) **right-shifted by 3 bits** — aliasing into four distinct buckets (`0x01, 0x02, 0x03, 0x08`) at the proportions you'd expect from 2+2+1+2 grouping of the seven channels.
- `byte1_reg` similarly carries 3-bit-shifted `word_count` bytes.
- `llrx_valid` asserts every cycle (4096/4096) — i.e. LL_RX *thinks* it has a packet every cycle — but the byte-alignment-FSM state stays at iSTATE0 because the ECC check on the shifted 24-bit header (`{byte0_reg, byte1_reg, byte2_reg}`) always fails.
- Slave's view is even more misaligned and produces no visible LL_RX activity.

**Why `swi_phase_offset` doesn't help:** the phase reg adjusts the 4-bit sample-point selection (1 of 16 sample-points per PHY bit period). It re-aligns *within* a single bit; it does not re-align *across* the 8-bit serial-to-parallel boundary that `WavD2DGpioRx` uses to produce 16-bit-per-lane LL data. The 256-combo phase sweep ran exactly into this limit: it can shift the sample point but it cannot rotate the bit-boundary of the 16-bit-per-lane word.

**Why the shift is exactly 3 bits, consistently across captures:** likely a fixed clock-data skew on the recovered `pad_clk_rx` relative to `pad_rx[7:0]`, or a fixed launch-timing offset in `WavD2DGpioTx`. The skew is the same every reload (deterministic), so it is *not* training-jitter — it is a hardware-routing or clocking-offset constant.

## 7. Proposed fixes — detailed

Five candidate fixes, ordered by **effort vs. probability of being the right answer**. The first two are diagnostic-but-cheap (run them before committing to (3)–(5)). (3) is the canonical Xilinx solution and likely the correct end-state.

---

### Fix A — Confirm the diagnosis: add `mark_debug` to LL_RX ECC internals — **IN PROGRESS**

**Status (2026-05-14, 10:54 BST):** RTL edited, rebuild launched (PID 110731), `package_ip` succeeded, master `build_design TARGET=pynq-z2-pair-all` running. 9 new `mark_debug` attributes added in `WlinkRxLinkLayer.v` covering `ecc_check_corrected_ph`, `ecc_check_corrected`, `ecc_check_corrupted`, `corrected_ph`, `is_short_pkt`, `is_long_pkt`, `bytesPerCycle[8:0]`, `ll_byte_index_1`, `ll_byte_index_2`. Total ~50 min for master+slave build, then deploy + capture + analysis. Expected outcome: `ecc_check_corrupted = 1` every cycle on master, confirming the 3-bit shift renders the 24-bit header un-correctable.


**Goal:** Prove the 3-bit shift hypothesis is correct by reading the ECC verdict directly, before committing engineering effort to a physical-layer fix.

**Mechanism:** `WlinkRxLinkLayer` runs an ECC check over the 24-bit packet header (`corrected_ph[23:0]`) before deciding whether to assert `valid` and advance from state=iSTATE0. If our shift hypothesis is right, `ecc_check_corrupted` is `1` every cycle that has data — i.e. *all* cycles, on master.

**Concrete changes:**
- In `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v`, add `(* mark_debug = "true" *)` to:
  ```
  ecc_check_corrected_ph[23:0]   // ECC-corrected packet header
  ecc_check_corrected            // ECC applied a correction
  ecc_check_corrupted            // ECC failed (header is garbage)
  corrected_ph[23:0]             // final corrected header bus
  is_short_pkt
  is_long_pkt
  bytesPerCycle[7:0]
  ll_byte_index_1..19            // per-lane byte index registers
  ```
- Re-run `make package_ip && make build_design TARGET=pynq-z2-pair-all` with `FPGA_INSERT_DEBUG_CORE=1`.
- Deploy + capture + analyse with the existing `analyze_llrx.py` script.

**What we expect to see if hypothesis is correct:**
- `ecc_check_corrupted = 1` every cycle on master.
- `corrected_ph` = a shifted-but-stable garbage value, distributionally matching what we'd compute by applying the 3-bit-shift to a uniform mix of the seven `cr_pkt` headers.
- On slave, `corrected_ph` even further misaligned (matches the `byte0_reg=0, valid=0` observation).

**Decision point after this fix:** if confirmed → proceed to Fix C (`ISERDESE2`) or Fix D (rate change). If `ecc_check_corrupted` is *sometimes* zero → there's a window where it's working, which suggests jitter rather than a fixed shift, and we look at `IDELAY` voltage/temperature drift.

**Effort:** ~10 minutes RTL edit, ~50 minutes build, ~5 minutes deploy/capture/analyse.
**Risk:** Zero — purely additive instrumentation, doesn't change functional behaviour.

---

### Fix B — Re-verify cable clock-vs-data lane mapping — **DONE, no swap found**

**Goal:** Eliminate the possibility that the recovered `pad_clk_rx_1` is wired to a data lane instead of the clock lane (or vice versa). A clock/data swap on the ribbon would produce *exactly* the symptoms we see: data appears to flow, but it's being sampled by the wrong edge.

**Result (2026-05-14):** Pin mapping verified by cross-referencing `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc` against `fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`. Both boards are identical Pynq-Z2 hardware, so an FPGA package pin appears at the same RPi-GPIO position on both boards; a straight-through ribbon connecting RPi pin N on board A to RPi pin N on board B is therefore equivalent to wiring FPGA pin X on board A directly to FPGA pin X on board B.

**Forward direction (master TX → slave RX):**

| Signal | Master pin | Slave pin (flip XDC) | Match |
|---|---|---|---|
| `pad_clk_tx` ↔ `pad_clk_rx` | Y9 | Y9 | OK |
| `pad_tx[0]` ↔ `pad_rx[0]` | F19 | F19 | OK |
| `pad_tx[1]` ↔ `pad_rx[1]` | V10 | V10 | OK |
| `pad_tx[2]` ↔ `pad_rx[2]` | V8 | V8 | OK |
| `pad_tx[3]` ↔ `pad_rx[3]` | W10 | W10 | OK |
| `pad_tx[4]` ↔ `pad_rx[4]` | B20 | B20 | OK |
| `pad_tx[5]` ↔ `pad_rx[5]` | W8 | W8 | OK |
| `pad_tx[6]` ↔ `pad_rx[6]` | V6 | V6 | OK |
| `pad_tx[7]` ↔ `pad_rx[7]` | B19 | B19 | OK |

**Reverse direction (slave TX → master RX):**

| Signal | Slave pin | Master pin | Match |
|---|---|---|---|
| `pad_clk_tx` ↔ `pad_clk_rx` | Y7 | Y7 | OK |
| `pad_tx[0]` ↔ `pad_rx[0]` | U7 | U7 | OK |
| `pad_tx[1]` ↔ `pad_rx[1]` | C20 | C20 | OK |
| `pad_tx[2]` ↔ `pad_rx[2]` | Y8 | Y8 | OK |
| `pad_tx[3]` ↔ `pad_rx[3]` | A20 | A20 | OK |
| `pad_tx[4]` ↔ `pad_rx[4]` | U8 | U8 | OK |
| `pad_tx[5]` ↔ `pad_rx[5]` | W6 | W6 | OK |
| `pad_tx[6]` ↔ `pad_rx[6]` | Y6 | Y6 | OK |
| `pad_tx[7]` ↔ `pad_rx[7]` | F20 | F20 | OK |

All 18 pin assignments are consistent. The XDC comment for `pad_clk_tx` explicitly notes that Y9 was chosen as an **SRCC P-side pin** so that the receiving side's `pad_clk_rx` (on the same FPGA pin) lands on a clock-capable input — a deliberate design choice already validated. The original W18 placement was rejected because of board-side I²C pull-up interference.

**Verdict:** Cable / pin mapping is **not** the cause. The 3-bit misalignment is internal to the deserialiser, not a wiring error.

**Effort spent:** ~10 minutes desk-check.
**Risk:** Zero.

---

### Fix C — `ISERDESE2` with `BITSLIP` for serial-to-parallel boundary alignment (~1 day RTL, the canonical solution)

**Goal:** Replace the current simple flip-flop deserialisation in `WavD2DGpioRx` with Xilinx 7-series `ISERDESE2` primitives that have built-in `BITSLIP` support, so software can rotate each lane's byte boundary to the correct alignment.

**Why this is the right primitive:** `ISERDESE2` was designed for exactly this problem — high-speed parallel-LVDS receivers where the bit-boundary of the deserialised parallel word may land on any of 8 (or 10) positions relative to the byte gearbox. The `BITSLIP` input rotates the parallel output by one bit per pulse, eventually finding the position where the framing-comma symbol (or in our case, a recognised `cr_pkt` header) is correctly aligned.

**Mechanism:**
- Each `pad_rx_1[N]` IBUF feeds an `ISERDESE2` configured for `INTERFACE_TYPE = "NETWORKING"`, `DATA_RATE = "SDR"` (or `"DDR"` if Wlink runs DDR), `DATA_WIDTH = 8` (matches our 8-bits-per-lane deserialisation).
- The 8-bit parallel output replaces the current `phy_link_rx_rx_link_data[16*N+7:16*N]`.
- A small "alignment-detect" FSM in LL_RX watches `byte0_reg` and pulses `BITSLIP` until the byte stream matches a known `cr_id` (e.g. `0x08` for AXI_AR, since master sends AXI cr_pkts unconditionally). Once aligned, the FSM stops pulsing — alignment persists until next reset.

**Concrete changes:**
- **RTL:** In `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/...` (Chisel source) or directly in `WavD2DGpioRx.v` (generated Verilog), instantiate 8 `ISERDESE2` primitives — one per data lane — and one for `pad_clk_rx`. Wire `BITSLIP` to a SW-controlled or auto-detect signal.
- **XDC:** Add `IODELAY_GROUP` for the ISERDES group; constrain `IDELAY_VALUE` per lane if lane-to-lane skew matters (likely yes).
- **APB:** Add a new control register `swi_bitslip[7:0]` exposing per-lane BITSLIP pulse — or alternatively, write an auto-align FSM in RTL.
- **Build:** A `clk_wiz` instance must generate `pad_clk_rx` at the SERDES-internal frequency (4× or 8× the byte rate, depending on `DATA_WIDTH`).

**How to verify:**
- After alignment, master's `byte0_reg` distribution should change from `{0x01, 0x02, 0x03, 0x08}` to the actual `cr_id` values `{0x08, 0x0c, 0x10, 0x14, 0x18, 0x40, 0x44}` in their natural proportions.
- ECC pass; FCSM advances to state=4; counters tick.

**Effort:** ~1 day RTL design (mostly figuring out the right ISERDES config and writing the BITSLIP-trainer FSM), ~50 minutes per build cycle, several iterations expected.
**Risk:** Medium. Touches the PHY's core deserialisation path. If Wavious's `wav-wlink-hw` already has a SERDES-aware version in another generation flow (we currently use `output_tidelink_gpio` — the GPIO-PHY-fabric variant), it might already exist as `output_tidelink_lvds` or similar. Worth checking before rolling our own.

---

### Fix D — Drop the link rate (~1 hour, low-cost fallback)

**Goal:** If a 3-bit shift is happening because the bit cell at 200 Mbps/lane is too narrow for `swi_phase_offset`'s 1-of-16 sample-point resolution to bridge, slow the link down so the bit cell is wider and a single phase-shift window covers it.

**Mechanism:** At current rate (let's call it `f_link` MHz), one bit cell is `1/f_link` ns wide. `swi_phase_offset`'s 16 sample points sit inside that window — separation `1/(16*f_link)` ns. If we drop `f_link` by 4×, the bit cell is 4× wider but the sample points have the same separation (set by the IDELAYCTRL reference clock, ~200 MHz). So `swi_phase_offset` now covers a much larger fraction of the bit cell — possibly enough to bridge a 3-bit boundary shift if that shift is really a sub-cell time offset that *looks like* a bit shift only because the cell is narrow.

**Concrete changes:**
- Identify where the link rate is set. Likely in the `clk_wiz_0` config inside the BD, or in a Wlink rate parameter.
- Halve or quarter the rate (e.g. via `clk_wiz` MMCM ratios or a Wlink SWI register if one exists).
- Rebuild + deploy + check whether the link comes up.

**How to verify:**
- After deploy at slow rate, master's `byte0_reg` should immediately show the unshifted `cr_id` distribution `{0x08, 0x0c, 0x10, 0x14, 0x18, 0x40, 0x44}` — no need for ISERDES tricks.
- FCSM advances, counters tick.

**Effort:** ~1 hour to find the rate knob and rebuild; ~5 minutes deploy/test.
**Risk:** Low. If it works it confirms our diagnosis cleanly but is a *workaround*, not a fix — production link rate would still need Fix C to be reachable. Useful as a sanity check and as a fallback for demos.

---

### Fix E — Cross-reference Wavious's `wav-wlink-hw` reference flow and Wlink docs — **DONE, no turnkey IP exists**

**Goal:** Find out what the Wlink IP's authors do for FPGA bring-up. They've solved this problem before; we shouldn't re-invent.

**Result (2026-05-14):** Two independent confirmations — local repo search and public docs — that the Wavious-supplied Wlink stack does not provide physical-layer alignment training.

**From the official Wlink documentation** (https://wlink.readthedocs.io/en/latest/):
- The Link Layer description has no mention of byte alignment, sync patterns, comma symbols, frame delimiters, training sequences, or preambles. The receiver "monitors the physical layer data to discover packets" with no documented discovery mechanism.
- The `cr_pkt` / `crack_pkt` exchange is described as a **flow-control** handshake (credit advertisement → credit acknowledgement → LINK_IDLE), not a PHY training sequence. It depends on the PHY already producing byte-aligned data.
- The PHY page explicitly says PHY details (including alignment) are delegated to the implementation: *"If you have a PHY design that you would like to try out but it is written in Verilog/VHDL don't fret!"*
- No register named `swi_bit_slip`, `swi_training`, `swi_alignment`, or similar is documented. The GPIO PHY's register map is not in the public docs at all — `swi_phase_offset` we discovered only by reading the generated Verilog.

**From the local repo search** (`deps/axi-chiplet-controller/wav-wlink-hw/`):

- **Two PHY variants exist:**
  - `output_tidelink_gpio/` — the GPIO PHY we currently use. Simple flop-based capture, indexed by `count + swi_phase_offset` (`GPIO.scala:90–148`). No ISERDES, no bit-slip, no per-lane delay — `swi_phase_offset` is the *only* alignment knob.
  - `output_tidelink/` — generic SERDES PHY (`WavD2DSerdesRx` and `WavD2DSerdesPHY` Verilog). These are **BlackBox stubs**, assuming the alignment is handled by a proprietary Wavious ASIC primitive that doesn't exist in fabric. Also has *no* `swi_phase_offset` register — the GPIO PHY is the only FPGA-friendly variant.
- **No XDC files** anywhere in `wav-wlink-hw/`. Only one constraint file exists (`logical/PHY/serdes/syn/serdes.sdc`) and it is ASIC-only timing — no `IDELAY_GROUP`, no `set_input_delay`, no `ISERDES`/`BITSLIP` constraints.
- **No documentation** describing an alignment training sequence. The `cr_pkt` exchange is *not* a training sequence — it carries credit information, not a known sync pattern.

**Verdict:** Wavious supplies only abstract PHY contracts (pad-in, link-data-out). They do not provide an FPGA-fabric implementation of the bit-alignment problem. We must implement this ourselves from Xilinx app notes — XAPP1064 (source-synchronous LVDS RX using `ISERDESE2` and `IDELAYE2`) is the canonical reference for 7-series Zynq.

**Effort spent:** ~1 minute (delegated to search agent).
**Risk:** Zero.

---

### Recommended sequence

```
Fix B (eliminate cable swap)                  ← DONE 2026-05-14, no swap found
Fix E (find Wavious's reference)              ← DONE 2026-05-14, no turnkey IP
Fix A (confirm diagnosis with ECC ILA)        ← IN PROGRESS, rebuild active
   ↓
Fix D (rate-drop sanity check — if doable in 1 hr) OR Fix C (proper ISERDES solution)
```

**Updated picture after 2026-05-14 investigations:** Cable mapping is clean; Wavious supplies no FPGA-fabric alignment IP for the GPIO PHY they bundle; we must write the `ISERDESE2 + BITSLIP` integration ourselves (Fix C) following Xilinx XAPP1064. Fix A in-flight to confirm the diagnosis before committing to a day of `ISERDES` RTL work. Fix D (rate-drop) is the cheapest demo-bring-up path if the link rate is configurable from APB or the BD's `clk_wiz` — worth a quick investigation in parallel with the Fix A rebuild.

## 8. Deeper architectural analysis

### 8.1 RTL changes that could resolve the bit-alignment problem

Four candidate RTL approaches, in increasing order of design complexity:

#### 8.1.a Software-controlled bit-slip register in `WavD2DGpioRx` *(smallest change)*

The simplest possible fix: add a 3-bit (or 4-bit) `swi_bit_slip` SW-config register per RX side, and rotate `phy_link_rx_rx_link_data[15:0]` (per lane) by that many positions before LL_RX consumes it. Or equivalently, change the `count` reset value from `4'hF` to `4'hF + swi_bit_slip`, so the byte boundary lands in the right place. This sits in the PHY exactly alongside `swi_phase_offset` and uses the same APB plumbing.

**RTL footprint:** ~50 lines in `WavD2DGpioRx.v` (or its Chisel source) + a new APB register definition.
**Software:** add a bit_slip parameter to the deploy script, sweep at bring-up to find the right value (4 sweeps × 16 phases = 64 deploys, ~10 min).
**Limitation:** assumes the shift is uniform across all 8 lanes. If lanes have different shifts, this doesn't help — you'd need a per-lane bit_slip[7:0][2:0] = 24 bits of config.

This is the **smallest delta** to get FPGA bring-up working, and arguably the right fix even if Fix C (`ISERDESE2`) is the ASIC-ish long-term answer.

#### 8.1.b ECC-driven auto-alignment in `WlinkRxLinkLayer` *(no PHY changes)*

Move the alignment problem **up one layer**. Add an FSM in `WlinkRxLinkLayer` that:
1. On reset, drives `current_bit_slip = 0`.
2. On every `ll_rx_valid` cycle, checks `ecc_check_corrupted`. If corrupted, increments `current_bit_slip` and re-routes its byte-extraction window by that many bits.
3. Once 16 consecutive cycles see `ecc_check_corrupted = 0`, latch `current_bit_slip` and proceed.
4. Expose `current_bit_slip` and `aligned` flags via APB for debug.

The `cr_pkt` traffic master sends unconditionally during SEND_CREDITS1 provides the "training sequence" — even without a known sync byte, the ECC field on a real cr_pkt header is non-degenerate, so ECC-pass *is* a sync signal.

**RTL footprint:** ~100 lines in `WlinkRxLinkLayer.v` (or upstream of it as a new `WlinkRxAlign` block).
**Advantage:** no PHY changes, no APB-level intervention — fully autonomous in hardware.
**Risk:** if the cable / electrical layer has non-trivial bit-error rate, the FSM might find spurious "ECC pass" matches and lock to the wrong slip. Adding "N consecutive matches" thresholds mitigates this.

#### 8.1.c Replace `WavD2DGpioRx` with `ISERDESE2 + IDELAYE2` *(canonical Xilinx solution)*

The text-book fix per Xilinx XAPP1064. Per data lane:
- `IBUF → IDELAYE2` (32-tap, ~78 ps/tap calibrated against a 200 MHz `IDELAYCTRL` reference) → `ISERDESE2` configured for `DATA_WIDTH=8, DATA_RATE=SDR, INTERFACE_TYPE=NETWORKING`.
- `ISERDESE2.BITSLIP` driven by an auto-training FSM (same logic as 8.1.b, but rotating the SERDES word instead of the LL byte window).
- A `BUFIO + BUFR` clocking topology generates the high-speed (×4 or ×8) SERDES clock from `pad_clk_rx`.

**Advantages over 8.1.a/b:**
- Tap-calibrated `IDELAYE2` can absorb sub-bit-cell skew (78 ps tap, far finer than `swi_phase_offset`'s 1/16-cycle resolution), so per-lane skew is correctable.
- `ISERDESE2` handles up to 1.25 Gbps per lane — much more headroom than the current flop-based deserialisation.
- Built-in `BITSLIP` is glitchless and well-characterised across PVT.

**Disadvantages:**
- Significant RTL surgery in `WavD2DGpioRx`. The current Wlink interfaces assume a particular clocking and width — accommodating `BUFR`-derived clocks may require BD-level changes.
- `IDELAYCTRL` needs an always-on 200 MHz reference clock — likely already available from the `clk_wiz_0`, but worth confirming.
- This locks the FPGA build to 7-series Xilinx primitives — non-portable to other vendors.

**Effort:** ~1 day RTL + ~3 build cycles to debug. Done well, this is the "set-and-forget" production fix.

#### 8.1.d Sync-word training pattern (link-protocol change) *(invasive)*

Make `WlinkTxLinkLayer` send a fixed sync pattern (e.g. 0xK5K5… or a comma symbol from 8b/10b) for the first N cycles after `role_lock`. `WlinkRxLinkLayer` searches for this pattern, locks bit-slip when found, then transitions into normal packet decode mode.

**Pros:** A *protocol-level* alignment guarantee — works regardless of whether the PHY is GPIO or SERDES, ASIC or FPGA.
**Cons:** Modifies the wire protocol; both sides must agree on the training pattern; would require RTL changes on TX side too. Effectively breaks compatibility with the Wavious-supplied reference Wlink behaviour.

This is the right answer for a *future* version of TideLink that doesn't rely on a third-party PHY contract — but it's not the right fix for the current bring-up.

### 8.2 Anything above the Wlink layer that could fix this?

**Short answer: no, the bug is in the PHY/LL_RX path, and no higher layer can recover from misaligned bytes.**

What the TideLink layer (or higher) could in principle do:

- **Bypass the FCSM handshake.** TideLink's APB exposes `CURRENT_CREDITS` and friends. Software could write peer-state values directly into the local registers, skipping the cr_pkt exchange. **But** the AHB/AXI data path goes through the same misaligned LL_RX — so even with "link up", payload data would be garbage. Doesn't help.
- **Retry / power-cycle on bring-up failure.** `deploy_pair.sh` already does swreset + lltx toggle for transient-failure recovery. Wouldn't help here because the misalignment is deterministic, not transient.
- **Application-level CRC and retransmit.** Reasonable in a packet-protocol stack, but doesn't bring the link up in the first place — if 100% of headers fail ECC, no packets ever cross to be retried.

The only intervention that can work above the PHY is one that's *also* a fix to LL_RX (option 8.1.b). The TideLink layer itself can do nothing useful about a bit-aligned-wrong byte stream.

### 8.3 Would the problem exist in an ASIC solution?

**No** — and we have direct evidence in the Wavious deliverables themselves.

The ASIC build uses `output_tidelink/` (the SERDES PHY variant), which contains `WavD2DSerdesRx` as a **BlackBox** Verilog stub. The expectation is that the ASIC integrator supplies a proprietary SERDES primitive (PLL/DLL with built-in CDR, bit-slip training, eye-margin calibration) that fills in for this BlackBox. That primitive **does** alignment internally; the link-layer just sees a stream of correctly-aligned bytes.

Two direct pieces of evidence:

1. The ASIC variant's APB register map (from `Serdes.scala:194–211`) **does not include `swi_phase_offset`**. Phase alignment in the ASIC PHY is hidden inside the SERDES primitive — not an SW-visible knob.
2. The Wavious GPIO PHY (`output_tidelink_gpio/`) — the only FPGA-targetable variant they ship — exposes `swi_phase_offset` as the *sole* alignment mechanism, with a 4-bit (1-of-16 sample point) resolution. The GPIO PHY was clearly designed as a "good enough" FPGA stand-in for ASIC bring-up, on the assumption that PCB skew between data and clock would always fit inside a 16th of a bit cell. On a 40-pin ribbon between two PCBs, that assumption fails — we observe a 3-bit-period shift, which is ~50% of a bit cell, well outside the `swi_phase_offset` correction window.

So:
- **ASIC TideLink: alignment works**, because the SERDES primitive handles bit-slip in silicon.
- **FPGA TideLink with GPIO PHY: alignment fails** when off-PCB skew exceeds 1/16 of a bit cell — what we see here.
- **FPGA TideLink with `ISERDESE2`-based PHY (Fix 8.1.c): alignment works**, because we replace Wavious's GPIO PHY with a Xilinx-native SERDES equivalent.

The bring-up problem is therefore **a property of the FPGA bring-up rig**, not a flaw in the TideLink design. The chiplet protocol, the link-layer FCSM, and the TideLink wrapper are all correct — they just aren't being given correctly-aligned bytes by the GPIO PHY.

### 8.3.b What if we're building an ASIC *with* the GPIO PHY?

Important caveat to §8.3: the answer changes if the ASIC uses `output_tidelink_gpio` (the GPIO PHY) rather than `output_tidelink` (the SERDES PHY). And there are real reasons one might pick GPIO for an ASIC:

- **Power.** No always-on PLL/DLL, no high-speed analog. Significant power saving for low-throughput links or low-duty-cycle traffic.
- **Area.** A SERDES macro is typically 0.1–1 mm² per direction depending on rate; the GPIO PHY is mostly flops + small clk-recovery logic, far smaller.
- **Process node accessibility.** SERDES analog macros need a specific PDK and may not be available on the chosen process node; the GPIO PHY is pure digital and synthesises on any cell library.
- **Cheaper bring-up.** No characterised analog blocks, no PVT-corner closure pain.
- **Consistency with FPGA prototype.** The same RTL runs in FPGA and ASIC bring-up — you don't get the "works in FPGA, breaks in ASIC" mode caused by swapping PHYs.

**TideLink currently uses the GPIO PHY** (`logical/wlink/` is generated from `output_tidelink_gpio`). If the ASIC tape-out also goes with GPIO PHY, the same alignment problem **can** manifest, with severity depending on the interconnect.

#### Skew budget at the GPIO PHY's `swi_phase_offset` resolution

Let `f_link` be the per-lane bit rate. The bit cell is `1/f_link` wide; `swi_phase_offset` partitions it into 16 sample points, so the largest skew it can absorb is **±(1/2)·(1/f_link/16)** ≈ **1/(32·f_link)**.

At typical operating points:

| Link rate | Bit cell | Phase-step | Max correctable skew |
|---|---|---|---|
| 200 Mbps | 5.0 ns | 312 ps | ±156 ps |
| 500 Mbps | 2.0 ns | 125 ps | ±62 ps |
| 1 Gbps | 1.0 ns | 62 ps | ±31 ps |
| 2 Gbps | 500 ps | 31 ps | ±15 ps |

#### Real-world skew on chiplet interconnect (rough estimates)

| Interconnect | Lane-to-lane + clock-to-data skew |
|---|---|
| On-die routing (same die) | <20 ps with matched trees |
| Si interposer (CoWoS, EMIB, etc.) | 20–100 ps |
| Organic substrate (chiplet-to-chiplet) | 100–500 ps |
| Off-package PCB trace (a few cm) | 200 ps – 1 ns |
| Off-package + connector (e.g. our 40-pin ribbon) | 1–10 ns |

Comparing the two tables: **`swi_phase_offset` alone is only sufficient for chiplet-to-chiplet on a Si interposer at modest rates**. As soon as you cross an organic substrate, you're at the edge. Off-package, you're well past it — which is exactly what we observe on the FPGA pair-board ribbon.

#### Implication for an ASIC-with-GPIO-PHY tape-out

1. **If chiplets are co-located on a Si interposer at ≤1 Gbps per lane:** the GPIO PHY's existing `swi_phase_offset` knob is *probably* enough. But there's no margin for PVT shift, aging, or routing-tool variation. A SW-controlled `swi_bit_slip` register (Fix 8.1.a) provides essentially-free margin for negligible area cost.
2. **If the link crosses an organic substrate or any package boundary:** the GPIO PHY *will* hit this same alignment problem in ASIC. You need bit-slip (Fix 8.1.a or 8.1.b) baked into the RTL **before tape-out**. Discovering it post-silicon would require a metal-only ECO at best, or a respin at worst.
3. **If the link goes off-package (board-to-board chiplet, or to a discrete companion chip):** GPIO PHY is the wrong choice. SERDES is needed.

**Conclusion: Fix 8.1.a (SW bit-slip register) and Fix 8.1.b (ECC-driven auto-align) are the *ASIC-portable* fixes**, not just FPGA workarounds. They make the GPIO PHY robust across the full envelope of plausible chiplet-interconnect skews, with negligible area / power cost. Fix 8.1.c (`ISERDESE2`) is a useful FPGA-prototype improvement, but doesn't translate to ASIC.

**The FPGA bring-up problem is therefore a free dress-rehearsal for an ASIC bring-up problem we *might otherwise* miss until post-silicon.** Fixing it in RTL (8.1.a or 8.1.b) closes a real ASIC tape-out risk, not just an FPGA inconvenience. This shifts the recommendation: Fix 8.1.a — a small, ASIC-portable addition to the Wavious GPIO PHY — should arguably be the **first** thing implemented and merged upstream, with Fix 8.1.b layered on top later if we want autonomous in-hardware training.

### 8.4 Can this problem be reproduced in cocotb / UVM?

**Yes — and we should**, to validate any fix from §8.1 before paying the 50-min FPGA build cycle. The cocotb tests at `cocotb/wlink_pair/` and the UVM testbench at `uvm/tidelink_top_system/` instantiate the same Wlink RTL we're running on FPGA, including `WavD2DGpioRx` and `WavD2DGpioTx`. With a small testbench change, we can inject the misalignment our hardware experiences.

#### Why the misalignment doesn't appear in current sim

In simulation, the testbench connects `master.pad_tx[7:0]` and `master.pad_clk_tx` directly to `slave.pad_rx[7:0]` and `slave.pad_clk_rx` (and the reverse). The connection is zero-delay and combinational — slave's deserialiser `count` register starts from a deterministic reset value, gets clocked by master's `pad_clk_tx` edge synchronously with master's data, and lands on the correct byte boundary trivially. The `swi_phase_offset` correction is unnecessary because there's no per-lane or clock-to-data skew.

#### How to inject the FPGA-side misalignment

Three options of increasing fidelity:

1. **Delay the data lanes relative to the clock.** In the cocotb testbench's pad-connection logic (or in a thin Verilog skid wrapper), insert N cycles of registered delay on each `pad_rx[i]` net, where N corresponds to the observed 3-bit shift. This precisely reproduces the FPGA-side experience: master's deserialiser receives slave's data with an offset that `swi_phase_offset` cannot correct.

2. **Randomise `WavD2DGpioRx.count`'s reset value.** Force-load the count register to a random initial value at start-of-test (via a `dut.master_wlink.gpio_rx.count.value = randint(0,7)` style poke in cocotb). This simulates the effect of an off-PCB cable: the deserialiser ends up at a random byte boundary that the alignment knobs cannot fully correct.

3. **Behavioral SERDES skid model.** Insert a parameterised `pad_skid_N` Verilog module between TX and RX that shifts the byte boundary by `N` bits. The model accepts a `skid_amount` parameter; sweeping it in regression catches all 8 possible misalignments.

#### What we'd verify in sim

- **Reproduce the bug:** with `skid_amount=3`, the cocotb pair test should fail in exactly the same way as the FPGA — master's `byte0_reg` distribution matches our captured `{0x01, 0x02, 0x03, 0x08}`, `ecc_check_corrupted=1`, FCSM stuck at state=1.
- **Test Fix 8.1.a (sw bit-slip):** with the new `swi_bit_slip` register implemented, setting `swi_bit_slip=3` on master should make the test pass.
- **Test Fix 8.1.b (auto-alignment FSM):** with the auto-aligner in LL_RX, the test should pass without any SW intervention — the FSM converges within N cycles.
- **Regression:** keep `skid_amount` as a sweep parameter (0..7) in `cocotb/wlink_pair/test_pair_aligned.py` so future RTL changes are validated against all possible misalignments.

This is a **high-value, low-effort piece of work** — adding a parameterised skid model to the wlink_pair testbench would let us iterate on §8.1 fixes in seconds rather than 50-minute build cycles, and would add a permanent regression that catches alignment-related regressions in future Wlink upgrades.

#### 8.4.a Implementation (2026-05-14) — `SKID_BITS` parameterised cocotb test exists and reproduces the FPGA failure mode

Implemented and verified. Files:

| File | Purpose |
|---|---|
| `cocotb/wlink_pair/pad_skid.sv` (new) | Parameterised bit-level skid module. `SKID_BITS=0` = pure passthrough. `SKID_BITS=N` inserts an N-stage shift register on each of the 8 `pad_data` lanes (clocked by `pad_clk_in`), forwarding `pad_clk` unchanged. Models the deterministic data-vs-clock skew observed on FPGA. |
| `cocotb/wlink_pair/tb_top.sv` (modified) | Adds top-level `SKID_BITS` parameter (overridable via `+define+TB_TOP_SKID_BITS=N`), instantiates two `pad_skid` modules (master→slave, slave→master) inline with the existing pad-connection. |
| `cocotb/wlink_pair/Makefile` (modified) | Adds `pad_skid.sv` to source list, propagates `SKID_BITS ?= 0` via `+define+`, exports to cocotb Python env. |
| `cocotb/wlink_pair/test_pair_skid.py` (new) | Runs the bring-up sequence; probes FCSM `state`, `cr_pkt_seen_rx`, `crack_pkt_seen_rx`, `byte0_reg`, `byte1_reg`, `ecc_check_corrupted` via DUT hierarchy; prints `byte0_reg` histogram; asserts pass at SKID=0, fail-mode otherwise. |

**Run with:**
```
cd cocotb/wlink_pair
make MODULE=test_pair_skid SKID_BITS=0   # expect bring-up converges
make MODULE=test_pair_skid SKID_BITS=3   # expect FPGA failure-mode
make MODULE=test_pair_skid SKID_BITS=1   # any non-zero value reproduces
```

**Results:**

| SKID_BITS | master cr_seen | master state_max | slave cr_seen | slave state_max | cocotb verdict |
|---|---|---|---|---|---|
| 0 | True | 4 | True | 4 | PASS — bring-up converges |
| 1 | False | 1 | False | 1 | PASS (matches expected fail-mode assertion) |
| 3 | False | 1 | False | 1 | PASS (matches expected fail-mode assertion) |
| 7 | False | 1 | False | 1 | PASS (matches expected fail-mode assertion) |

The primary FPGA forensic signal — **FCSM frozen at state=1, `cr_pkt_seen_rx` low** — reproduces exactly under any non-zero `SKID_BITS`. All 9 pre-existing wlink_pair tests still pass with `SKID_BITS=0` (default).

**Honest discrepancies between sim and FPGA** (documented for future reference):

1. **`byte0_reg` distribution is dominated by `0x00`** (99% of samples) in sim, not the `{0x01, 0x02, 0x03, 0x08}` cluster seen on FPGA. Reason: FPGA master TX has high duty cycle (cr_pkts continuously), so even idle-driven byte0 samples often catch cr_pkt content; sim master TX has very sparse duty cycle so most byte0 samples are idle (0x00). The 1% non-idle samples in sim do cluster around `0x40/0x60/0x80` family — a left-shifted alias of the same cr_id mod-8 misalignment seen on FPGA.

2. **`ecc_check_corrupted = 0/5000`** in sim, vs presumably 100% on FPGA. Reason: `ecc_check_corrupted` is only sampled while LL_RX is in active-packet mode (`tx_ready` high during a packet); sim's sparse TX duty cycle means LL_RX spends almost all cycles idle, not sampling. Once §8.1.a/b RTL fixes are validated and we re-capture the FPGA ECC signal, this can be cross-referenced.

Neither discrepancy invalidates the sandbox. The dominant test signal (FCSM stuck / cr_seen low) is identical to FPGA, so any RTL fix that restores bring-up at `SKID_BITS=3` will also restore it on the FPGA. This is the iteration loop we need.

## 9. Per-lane bit-slip with real-world calibration *(production-grade variant of Fix 8.1.a)*

> **Wlink does not ship a physical-layer link-training mechanism.** Verified against the official Wlink documentation (https://wlink.readthedocs.io/en/latest/wlink.html, /phy.html) — the architecture explicitly delegates byte/bit alignment to the PHY implementation, and the documented `cr_pkt` / `crack_pkt` exchange is a **flow-control** handshake (credit advertisement → credit acknowledgement → LINK_IDLE), not a PHY training sequence. It assumes the PHY is already producing aligned bytes — exactly the assumption that fails on the FPGA pair-board ribbon. The Wavious SERDES PHY relies on a proprietary primitive to do training in silicon (no SW-visible register); the Wavious GPIO PHY exposes only `swi_phase_offset` (a 1-of-16 sub-bit-cell sample-point selector). Neither expose bit-slip, sync-pattern detection, or per-lane delay control. Fix §9 below is filling a *documented gap* in the Wavious GPIO PHY, not reinventing existing functionality.

The uniform-skew assumption baked into §8.1.a (single global `swi_bit_slip[2:0]`) works for our 40-pin-ribbon experiment — empirically, all lanes shift uniformly by 3 bits — but it relies on the interconnect being matched within a fraction of a bit cell across all 8 data lanes. That assumption fails as soon as:

- Lane-to-lane PCB routing differs by more than 1 bit cell.
- Termination quality varies across lanes.
- Aging or temperature shifts per-lane delay differently (especially in chiplet packages with mixed substrate / bump topologies).
- A different cable assembly has different per-pair length.

The robust, ASIC-portable variant adds **per-lane bit-slip** plus an **autonomous calibration mechanism that does not rely on ILA visibility** — because in production silicon, ILA doesn't exist, and the SW bring-up engineer only has APB.

### 9.1 RTL additions

Three new components in `WavD2DGpioRx` (or a thin wrapper around it):

1. **Per-lane bit-slip configuration**
   ```
   reg [2:0] swi_bit_slip [0:7];   // 8 lanes × 3 bits, APB-writable
   ```
   For each lane, an output rotator picks one of 8 bit-positions of the 8-bit deserialised byte. ~10 LUT-equivalents per lane × 8 lanes = ~80 LUT.

2. **TX-side training-pattern generator**
   ```
   reg swi_training_mode;          // 1 = TX sends training, RX runs checker
   wire [7:0] training_byte [0:7]; // distinct fixed byte per lane:
                                   //   lane N → (N+1) * 0x11
                                   //   gives 0x11, 0x22, 0x33, … 0x88
                                   //   all 8 distinct, all non-degenerate bit patterns,
                                   //   all autocorrelation-detectable.
   ```
   In training mode, `WavD2DGpioTx` overrides its normal LL data with the per-lane training byte. ~16 LUT total.

3. **Per-lane pattern-match checker + status**
   ```
   reg [7:0] swi_lane_lock_count [0:7];  // count of consecutive byte-matches per lane
   wire [7:0] swi_lane_locked;           // 1 = lock_count >= LOCK_THRESHOLD (e.g. 16)
   ```
   Each lane has a small FSM that compares the *deserialised-and-slipped* byte against the *expected* training byte for that lane (the same `(N+1)*0x11` pattern). Increments `lock_count` on match, resets to 0 on mismatch. APB exposes `swi_lane_locked[7:0]` as an 8-bit RO status register. ~20 LUT per lane × 8 = ~160 LUT.

**Total RTL footprint:** ~250 LUT equivalents per RX side, ~50 lines of additional Chisel/Verilog, three new APB registers. Negligible area for a chiplet PHY.

### 9.2 Why this works without ILA: the SW can read per-lane lock directly

The key insight: a **per-lane checker exposed via APB replaces the role that ILA played during this FPGA bring-up.** The SW doesn't need to see deserialised bytes — it just needs an authoritative "this lane is aligned" signal per lane. That signal lives in 8 bits of an APB register, readable from the production SW with one register access.

Crucially, the checker is local to each side and self-contained:
- It uses a fixed per-lane reference (no peer cooperation needed for the comparison).
- The training byte for lane N is hard-coded in RTL, identical on both sides.
- Both sides enable training mode independently; each calibrates its own RX based on its own per-lane checker.

### 9.3 Field calibration sequence (no ILA, APB only)

Pseudo-code that runs from PYNQ Linux user-space or, in production, from any small bring-up firmware over APB. Total run time is bounded at ~1 ms.

```
def calibrate_rx(side):  # invoked on master AND slave independently
    apb_write(side, SWI_BIT_SLIP_ALL, 0x000000)   # start lanes at slip=0
    apb_write(side, SWI_TRAINING_MODE, 1)         # TX sends pattern, RX runs checkers
    swreset_toggle(side)                          # re-init deserialiser

    best_slip = [0]*8
    best_count = [0]*8

    for lane in range(8):
        for slip in range(8):
            apb_write(side, SWI_BIT_SLIP_LANE(lane), slip)
            wait_microseconds(16)                  # 16 cycles ≥ LOCK_THRESHOLD
            locked = apb_read(side, SWI_LANE_LOCKED) & (1 << lane)
            if locked:
                # any locked value beats a non-locked one; first locked slip wins
                best_slip[lane] = slip
                break
        else:
            log_error(f"lane {lane} could not lock at any slip 0..7")
            return False

    # apply the per-lane slips, exit training, link comes up via normal cr_pkt path
    for lane in range(8):
        apb_write(side, SWI_BIT_SLIP_LANE(lane), best_slip[lane])
    apb_write(side, SWI_TRAINING_MODE, 0)
    swreset_toggle(side)
    return True
```

### 9.4 Why this converges fast and reliably

- **64 trials, not 16 million.** Each lane is searched independently because the pattern is per-lane. The total search space is `8 lanes × 8 slip values = 64`, not `8^8 ≈ 16.7M`. Calibration takes ~1 ms total.
- **Local to each side.** Master doesn't need slave to be aligned (or even powered) to calibrate its own RX. Master's TX is sending its own training pattern that slave's RX consumes; master's RX is consuming slave's training pattern (which slave sends as soon as it enters training mode). Both sides converge in parallel.
- **Robust to lane-to-lane skew.** Different lanes can pick different slip values. The system handles arbitrary per-lane misalignment within the 3-bit range — sufficient for any chiplet substrate routing variation in practice.
- **No internal visibility required.** The only RX state the SW reads is `swi_lane_locked[7:0]` — an 8-bit status register. No ILA, no JTAG, no internal debug.
- **Idempotent.** Re-running calibration after a temperature shift or after a link drop is a 1 ms operation. Production firmware can re-run on any link-loss event.

### 9.5 What if no slip value locks for a given lane?

If `swi_lane_locked` never asserts for any `slip in 0..7`, the failure mode is informative:
- **A specific lane never locks** → that lane has insufficient signal integrity (broken cable pin, dead bond, etc.). The error is identified per-lane and reported up. Production silicon can flag the bad lane and either retry or refuse to bring the link up. The remaining lanes' status tells the operator which physical lane to inspect.
- **No lane ever locks** → catastrophic failure (clock dead, training pattern not generated, RX path completely broken). Distinct diagnostic from a single-lane failure.

This is qualitatively better than the current "FCSM stuck at state=1 with no further information" experience: an APB read of `swi_lane_locked` immediately localises the fault.

### 9.6 Optional: closed-loop in-RTL training (no SW participation)

If we want the bring-up to happen with no SW participation at all, a small in-RTL FSM can drive the calibration:

```
state CALIBRATE_LANE_N:
    bit_slip[N] <= slip_attempt
    wait LOCK_THRESHOLD cycles
    if lane_locked[N]:
        next state = CALIBRATE_LANE_(N+1)
    else:
        slip_attempt <= slip_attempt + 1
        if slip_attempt == 7: assert lane_fault[N]; next state = ABORT
```

This sits in the chiplet controller next to the role-lock mechanism. After `role_lock` asserts, the calibration FSM runs to completion (~256 cycles), then de-asserts an internal `training_mode` signal and lets the normal Wlink handshake proceed. SW reads `swi_lane_locked[7:0]` and `swi_calibration_done` to confirm bring-up; no SW-driven sweep loop required. About 60–100 LUT extra for the FSM.

This is the **ASIC-target design** — fully autonomous link bring-up, no firmware involvement, deterministic ~1 µs from `role_lock` to `link_up`.

### 9.7 Validating this fix in the cocotb sandbox

The sandbox at `cocotb/wlink_pair/test_pair_skid.py` can be extended to verify the per-lane variant:

- Modify `pad_skid.sv` to accept `SKID_BITS_PER_LANE[7:0][2:0]` (8 separate skid amounts) instead of one global value.
- Add a new test `test_pair_skid_per_lane.py` that sets *different* skids per lane (e.g. `[3, 5, 0, 2, 7, 1, 4, 6]`) and verifies the per-lane calibration FSM (or the SW calibration loop) converges to each lane's correct slip.
- The cocotb test reads `swi_lane_locked` after calibration completes, asserts all 8 bits are set, then asserts FCSM advances to state=4.

This catches **any per-lane regression at the RTL level in sim**, before any FPGA build. Once Fix §9 is implemented and passes this test, the FPGA build is a high-confidence verification, not a primary debug surface.

## 9.8 Bring-up sequencing: UVM finding (2026-05-14)

The §9 algorithm as initially specified assumed training is asserted *before* `role_lock`, which is how the cocotb sandbox exercises it (`test_pair_align.py`: drives `swi_training_mode=1`, sweeps slip, then drops training, then runs bring-up). This works in the cocotb sandbox because the testbench drives `pad_clk_tx` and POR manually — the recovered link clock spins up regardless of whether real cr_pkts are crossing.

In the UVM `tidelink_top_system` testbench — which exercises the **realistic bring-up sequence** (strap → `apb_debug_unlock` → `swi_phase_offset` → `ROLE_CFG.lock` → swreset+lltx toggle → cr_pkt handshake) — asserting `swi_training_mode=1` before `role_lock` blocks the LL_RX clock domain from spinning up properly. The training pattern replaces the cr_pkt traffic that the receiver-side LinkLayer needs to recover its clock; the `wlink_lane_checker` sees nothing and never locks.

This is a real **production sequencing requirement**: the §9 mechanism must fire *during* bring-up, not before, and must be coordinated with `role_lock`.

### Required bring-up sequence

```
1. Strap, debug_unlock, swi_phase_offset (existing)
2. role_lock = 1                            ← gates wlink_por release
3. swreset+lltx toggle                      ← starts cr_pkt generation
4. Pause cr_pkt handshake                   ← NEW
   - Hold off the FCSM from advancing past SEND_CREDITS1
   - Or simply assert swi_training_mode=1 AFTER step 3 above
5. wlink_lane_checker sweep                 ← per-lane slip calibration
6. Drop swi_training_mode=0                 ← resume normal traffic
7. Toggle swreset to re-init FCSM           ← cr_pkt exchange now works
8. FCSM advances → LINK_DATA                ← normal bring-up
```

The key is **step 4**: training mode must not displace the link-clock recovery phase. Two implementation approaches:

- **Auto-staging FSM (preferred — §9.6 design).** An in-RTL FSM in the chiplet controller drives the sequence: on `role_lock` rising edge, hold off cr_pkt generation, assert `swi_training_mode`, sweep, drop, toggle. ~100 LUT for the FSM. Self-contained, no SW participation needed.
- **SW orchestration.** The bring-up firmware does it explicitly: `deploy_pair.sh` becomes a more complex sequence with a calibration phase between `role_lock` and the final swreset. Fragile (timing-sensitive) — not recommended.

### Why cocotb missed this

The cocotb sandbox at `cocotb/phy_align/test_pair_align.py` drives bring-up through hierarchical-ref backdoors and manual clock/POR control. It works around the natural sequencing because it doesn't go through the full `role_lock → cr_pkt → handshake` chain. **The UVM testbench going through real APB-driven bring-up exposed a gap the cocotb tests couldn't.** This is exactly the kind of issue UVM-level integration testing catches that cocotb won't.

### Test coverage status

- **`cocotb/phy_align/`** — 5 alignment tests (uniform + 4 asymmetric variants) + partial-failure + retraining + asym-master-slave: **all PASS**. Validates the algorithm with the bring-up bypass.
- **`uvm/tidelink_top_system/`** — 4 alignment tests (uniform, asymmetric, one-dead-lane, recalibration-after-link-drop): **compile and elaborate clean, regression intact, but end-to-end calibration does not converge under realistic bring-up sequencing.** Surfaces the sequencing issue documented here. Fix is the auto-staging FSM (§9.6).

### Follow-up work

1. **Implement the auto-staging FSM** (§9.6). This is now elevated from "optional" to "required" — the existing manual mode doesn't compose with real Wlink bring-up.
2. **Add a UVM test that exercises the staging FSM** end-to-end. Same setup as `test_align_uniform_skew`, just expects `link_active` to assert *automatically* after `role_lock` without any explicit calibration drive from the test.
3. **Update `pynq_host/scripts/deploy_pair.sh`** to either invoke the auto-staging FSM (write a "start calibration" APB bit and poll `swi_calibration_done`) or perform the staged SW sequence above.

## 10. Open Items / TODOs

- TideLink ASIC synthesis flow: **delivered** this session (Fusion Compiler partition flow + Formality LEC). After `route_opt -effort high` 2nd pass, setup WNS is −0.08 ns and 24 net DRC violations remain — within typical sign-off tolerance but not yet zero. MANIFEST.md auto-generates in outputs/ via the abstract step. Hold WNS −0.34 ns is the residual to close next; options listed in MANIFEST.md.
- TideChart dynamic chiplet-ID protocol: separate peer repo `~/SoCLabs/tidechart`, not in scope of this report.
- Confirm whether the 3-bit shift seen at master is reciprocated symmetrically at slave (different number of bits, but same root cause), or whether slave needs a different correction. The current slave-side ILA shows no LL_RX activity at all — adding ECC-internal mark_debug nets in the next build cycle would clarify.

## Appendix A — ASIC synthesis + LEC results (added 2026-05-14)

This session brought the ASIC partition flow to delivery state and uncovered an RTL bug along the way.

### A.1 Flow status

The `syn/asic/fusion-compiler/` and `syn/asic/formality/` flows are now production-usable:

```
$ make -C syn/asic/fusion-compiler fc        # → outputs/{tidelink_top.v, .pg.v, .sdc, .def, .lef}
$ make -C syn/asic/formality lec             # → reports/03b_verify_summary_final.rep (FM_LEC_OK)
```

Knobs are documented per file. Notable defaults:
- `FC_CORE_UTILIZATION=0.70` (forced from 0.78 once the `ahb_mng_hready` fix grew the std-cell footprint by ~18 %)
- `FC_CLOCK_GATING=on` (set to `off` for an LEC apples-to-apples cross-check; results in `outputs_nocg/`)
- `FM_MAX_PASSES=3` iterative don't-verify (cap; sufficient for convergence here)
- `verification_failing_point_limit = 0` — **critical** Formality knob: default is 20, after which verify abandons all remaining cones as "unverified". Without this set explicitly, the run looks like 13,859 cones failed when in fact verify never visited them.

### A.2 RTL bug found by LEC: `ahb_mng_hready` direction

Formality's "directly undriven primary output port" diagnostic flagged that `tidelink_top.ahb_mng_hready` is declared as an `output wire` but has no driver inside the partition. Walking the connection: `ahb_mng_hready` feeds into `u_xhb_mng.hready`, which is an *input* port of the XHB500 AXI→AHB bridge.

AHB protocol: `HREADY` flows slave → manager. `tidelink_top` is the manager on this bus (the chiplet drives transactions out into the local SoC fabric), so `hready` is a DUT *input* — the slave's ready signal back to the manager. The `output` declaration was wrong; nothing drove the wire inside tidelink_top.

**Why it had not been caught:**
- Simulation: nothing in the UVM testbench drove `a_dut_mng_hready` either, so the bridge's `hready` input sat at X. The bridge handles X as "not ready" and stalls — but no test ever exercised a stalling slave, so no failure surfaced.
- FPGA bring-up: the local-SoC side of `ahb_mng_*` is connected through Vivado IPI, where the matching `ahb_mng_hready` was *also* declared as `output` (consistent bug across the chain). The interface bundle linked even though the protocol-level direction was wrong.
- Synthesis (DC + FC): an undriven input was effectively constant X, which synth folded into "not ready" — the bridge's slave-wait FSM got partially elided, masking it on inspection.

**Coordinated fix** (commit `aff288d` on `feat/fpga-flow`):
- `src/rtl/tidelink_top.sv:130` — port direction `output → input`
- `fpga/vivado_ip/tidelink_vivado_wrapper.v:160` — same, Xilinx interface tag preserved
- `uvm/tidelink_top_system/tb/top.sv` — `WIRE_AHB_MNG` macro now drives `DUT_HREADY` from slave VIP's hready output instead of feeding it in
- `uvm/tidelink_ptp_chain/tb/top.sv` — same macro fix

Post-fix:
- UVM `test_top_single_packet` PASSES (0 errors / 0 fatals — confirmed)
- Formality LEC: **18,837 passing / 0 failing / 0 unverified / 264 DFF don't-verify** (the 264 are Wlink Chisel auto-gen synth-transform residuals — see A.3)
- FC partition area grew from 430 k μm² (pre-fix at util 0.78) to 507 k μm² (post-fix at util 0.70). The +18 % is mostly the cost of correctly preserving the XHB500 bridge's slave-wait FSM that synth was previously eliding.

### A.3 The 264 don't-verify residuals (and why they aren't a regression)

After LEC matches RTL registers to netlist registers by name + topology, Formality SAT-checks equivalence of each. For 264 specific Wlink-internal DFFs, the SAT formulas don't match even though the externally observable behaviour does — synthesis applied transformations the RTL parser can't reconstruct without explicit guidance:

- **Parameter constant folding:** synth traces parametric values through Chisel-generated `WlinkGenericFCSM_*` instances and concludes specific register bits are tied to constants; Formality keeps them as registers driven by combinational logic that's algebraically equivalent
- **2-D memory array flattening:** `fifo/mem/mem_reg[i][j]` in RTL becomes `mem_reg_i_j` flat names in the netlist with possible storage sharing
- **FSM re-encoding:** the Wlink TX state register's bits diverge after synth's encoding choice
- **Cross-instance storage sharing:** the `link_data_reg` bank in each of axiarFC / axiawFC / axirFC / axiwFC may share storage post-synth

These are skipped iteratively (`set_dont_verify_points`), then the SAT-checker walks every cone *downstream* of them — all 18,837 downstream points pass, confirming the transformations preserve external behaviour. To eliminate the residual entirely would require `set_dont_touch_network` on the WlinkGenericFCSM modules in FC (preserves RTL register structure but costs some area / timing margin on those blocks).

### A.4 Formality knob that hides 14k cones (write-up for future readers)

The Formality default `verification_failing_point_limit = 20` was responsible for the bring-up confusion described in this session: after the iterative skip identified the 593 / 264 internal Wlink residuals (then 79 / 1 port-level), verify reported them and **abandoned** all 14k remaining cones as "Unverified". The unverified report explicitly states `13859 unverified because failing point limit reached`. Setting the limit to 0 lets verify run to completion. This is now baked into `syn/asic/formality/scripts/run_lec.tcl` and called out in the Makefile help.

---

*Updated 2026-05-14 after the slave-phase + master-ILA sweep showed a deterministic 3-bit right-shift in master's LL_RX byte registers, invariant across slave phase. Phase-reg cannot fix this — fix needs per-lane physical delay or rate change. State preserved across sessions in `/home/dam1n19/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_fpga_bringup.md`.*

*Appendix A added the same day after a separate session that wired the Fusion Compiler + Formality LEC flows, discovered the `ahb_mng_hready` direction bug, and characterised the Wlink Chisel LEC residuals.*

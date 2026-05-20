# TideLink GPIO PHY — Architecture Reference

Author: SoC Labs (David Mapstone)
Branch:  `feat/td-combined` @ `56a8aca`+ (parent), submodule
         `deps/axi-chiplet-controller` @ `678a9b3`+
Status:  Silicon-validated; one residual (bank-35/bank-13 IDELAYCTRL VT
         asymmetry) tracked in §10.

This document is the single-read entry point to the TideLink chiplet
interconnect GPIO PHY. It describes the vendor PHY core, the SoC Labs
RTL layered on top, every parameter, the per-lane datapath, the
calibration FSM, and the FPGA-only structural fixes added during the
§9 bring-up campaign on the Pynq-Z2 pair.

---

## 1. Overview

The TideLink GPIO PHY is a half-duplex per-direction, **source-synchronous
forwarded-clock parallel** chiplet link. Each direction carries one
forwarded clock and eight LVCMOS33 single-ended data lanes. Lane rate
is **25 Mb/s/lane** (40 ns UI) — the 16-bit Wlink link word is
serialised across 8 lanes × 2 cycles, with the forwarded clock at the
serialiser bit rate (25 MHz). With 8 lanes the aggregate link
payload rate is **200 Mb/s** before link-layer overhead.

The PHY is built on the **WavD2DGpio** Chisel-generated IP (vendor),
extended with SoC Labs alignment + automation patches inside the
generated Verilog and a TideLink calibration FSM in SystemVerilog
sitting above the PHY APB region.

### 1.1 Position in the chiplet stack

```
  ┌────────────────────────────────────────────────────────────────┐
  │ Host SoC fabric (AHB / AXI / APB master)                        │
  └────────────────────────────────────────────────────────────────┘
                │                  │
   AHB sub / tx / fifo / ptp       │   APB config (Region 4/8)
                │                  │
  ┌────────────────────────────────────────────────────────────────┐
  │ tidelink_top                                                    │
  │   ├─ tidelink_ahb / tidelink_fc_adapter / tidelink_fifo        │
  │   ├─ tidelink_apb_regs / tidelink_addr_translator              │
  │   └─ axi_chiplet_controller   (Region 4 / Region 8 status regs) │
  │        ├─ tidelink_lane_checker       (training-byte detector)   │
  │        ├─ tidelink_phy_align_calibrator (FSM)                    │
  │        ├─ tidelink_idelay_rx          (FPGA: IDELAYE2 per lane)  │
  │        ├─ tidelink_rxclk_buf          (FPGA: BUFG boundary)      │
  │        └─ Wlink  (Chisel link-layer)                             │
  │             └─ WlinkGPIOPHY                                      │
  │                  └─ WavD2DGpio                                   │
  │                       ├─ WavD2DGpioTx[7:0]  + clock-forward      │
  │                       └─ WavD2DGpioRx[7:0]  + clock-recover      │
  └────────────────────────────────────────────────────────────────┘
        │ pad_clk_tx │ pad_tx[7:0]      pad_clk_rx │ pad_rx[7:0] │
        ▼            ▼                              ▲             ▲
  ┌────────────────────────────────────────────────────────────────┐
  │ Pynq-Z2 RPi GPIO ribbon (J13)  ── 18-conductor pin map          │
  │  TX side bank 13, RX clock bank 13 (Y7-MRCC), RX data mixed     │
  │  bank-13 / bank-35 (see §7)                                     │
  └────────────────────────────────────────────────────────────────┘
                       │   (passive ribbon cable)
                       ▼
  ┌────────────────────────────────────────────────────────────────┐
  │ Peer Pynq-Z2 — same RTL, opposite role strap                    │
  └────────────────────────────────────────────────────────────────┘
```

There are exactly two physical instances per pair: one master, one
slave. Role is selected by a strap at boot, resolved by a peer-mask /
auto-negotiation phase, and latched into `role_locked`. The PHY is
otherwise symmetric — both directions are present and active on
each instance.

### 1.2 Physical instantiation

* Board:        Pynq-Z2 (XC7Z020-1CLG400C, 7-series)
* Standard:     LVCMOS33, SLEW FAST, DRIVE 8
* TX bank:      13 (all 9 pins, including `pad_clk_tx` Y9 SRCC-P)
* RX bank:      mixed — `pad_clk_rx` Y7 MRCC-P (bank 13), six RX
                lanes bank 13, two RX lanes bank 35 (`pad_rx[1]=C20`,
                `pad_rx[3]=A20`)
* Pin map XDC:  `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc`
                lines 76–109

The pair targets (`pynq-z2-pair-all` and the cable-mirrored
`pynq-z2-pair-flip-all`) are byte-symmetric; the ribbon physically
crosses master TX → slave RX in one direction and the converse in
the other.

---

## 2. The Wav GPIO PHY core (Chisel-generated, vendor IP)

The vendor Chisel emits four files we care about:

| File (`deps/axi-chiplet-controller/logical/wlink/`)        | Role |
|---|---|
| `WavD2DGpioTx.v`        | Per-lane TX serialiser + gated clock-forward |
| `WavD2DGpioRx.v`        | Per-lane RX deserialiser                |
| `WavD2DGpio.v`          | 8× TX + 8× RX + clock-forward + APB ctrl |
| `WlinkGPIOPHY.v`        | PHY-region APB wrapper over `WavD2DGpio` |

Each TX (`WavD2DGpioTx.v`) and RX (`WavD2DGpioRx.v`) is a per-lane
unit. `WavD2DGpio.v` instantiates 8 of each and routes the forwarded
clock through a separate TX block on `pad_clk_tx`/`pad_clk_rx`.

### 2.1 WavD2DGpioTx — per-lane serialiser

`WavD2DGpioTx.v` (174 lines).

```
                    ┌──────────────────────────────────┐
   io_link_data ───►│ {pattern, pattern} OR link_data  │   (15:0)
   io_training_mode►│ (SoC Labs training-mode patch)   │
   io_training_pat►│  (line 43-45)                     │
                    └─────────────┬────────────────────┘
                                  │ _link_data_eff[15:0]
                                  ▼
        count[3:0]  ─►  bit-position MUX  ─►  io_pad
        (free-run +1 mod 16 @ io_clk)        (one bit per io_clk)
                                  │
        io_clk_en  ─►  WavClockGate hs_clk_gated_wcg ─► io_pad_clk
        (qualified at count_in==&)        (combinational fabric clock)

   io_clk: hsclk / N (= pad_clk_tx rate × 16 internally — bit rate is
   the forwarded clock rate)
```

Key signals (line refs in `WavD2DGpioTx.v`):

* `io_clk` (line 6)               — hsclk (the bit-rate clock domain)
* `io_reset` (line 7)             — active-high reset
* `io_clk_en` (line 8)            — TX enable (qualified at word boundary)
* `io_link_data[15:0]` (line 9)   — TX word
* `io_training_mode` (line 16)    — SoC Labs patch: when 1, send
                                    `{pattern, pattern}` instead of
                                    link_data
* `io_training_pattern[7:0]` (line 17) — per-instance training byte;
                                    wired up in `WavD2DGpio.v` to the
                                    same period-8 set the RX expects
                                    (§3.2)
* `io_link_clk` (line 18)         — divided word-clock output
                                    (`~count[3]`) for the link-layer
                                    side
* `io_pad` (line 19)              — serial output to the pad
* `io_pad_clk` (line 20)          — gated forwarded clock to the
                                    `pad_clk_tx` pin

The per-cycle bit selection is the 16-way mux at lines 62–75 plus
line 96 (`io_pad = 4'hf == count ? tx_pad_array_15 : _GEN_14;`).

**Forwarding-clock path (line 82, line 97).** The clock forward is
`hs_clk_gated_wcg` — a `WavClockGate` driven by `io_clk_en` qualifier.
The clock is **combinational fabric** out of the gate cell to the pad;
**there is no ODDR on the TX side**. On FPGA the forwarded clock is
produced through ordinary IOB output logic.

### 2.2 WavD2DGpioRx — per-lane deserialiser

`WavD2DGpioRx.v` (463 lines after SoC Labs patches; original is
~210 lines).

```
       pad_clk_rx                  pad_rx[lane]
            │                          │
        IBUF│                       IBUF│
            ▼                          ▼
     (USE_CLKBUF gen)            io_pad
     pad_clk_scan_mux            (sampled at adj_count==N)
     pad_clk_inv_scan_mux
     pad_clk_inv_scan_mux_1
            │
            ▼  w_cnt_clk  (drives count)
                                          ┌── link_data_pad_clk[15:0]
   count[3:0] ──+──► adj_count = count    │   (one bit captured per
   io_phase_off-┘    + io_phase_offset    │    pad_clk; mux on
                     (4-bit, mod 16)      │    adj_count[3:0])
                                          ▼
                                      ┌───────────────┐
                                      │ link_data_reg │  (rising-edge
                                      │  [15:0]       │   of w_lnk_clk
                                      └──────┬────────┘   = ~adj_count[3])
                                             │
                                _link_data_rep = {x, x}   (32 bits)
                                             │
                                             ▼  right-rotate by
                                       io_bit_slip[2:0]
                                             ▼
                                       io_link_data[15:0]
```

The deserialiser is a `count`-based bit-position selector (lines
107–133). `count` free-runs mod-16 on `w_cnt_clk`. `adj_count =
count + io_phase_offset` (line 112) is the SoC Labs alignment patch
(§3.1). Each comparator at lines 113–130 writes one bit of
`link_data_pad_clk[15:0]` when `adj_count` equals that bit's index.

The 16-bit captured word is re-clocked into `link_data_reg` (line
398) on the divided word-clock `io_link_clk = ~adj_count[3]` (line
206) — i.e. exactly when the deserialiser has completed one
16-cycle round.

**The mux chain (`io_pol`, `io_scan_mode`).** The vendor RTL routes
the recovered clock through three `WavClockMux` cells:
`pad_clk_scan_mux` (line 139), `pad_clk_inv_scan_mux` (line 145), and
`pad_clk_inv_scan_mux_1` (line 151). On synthesis these mux cells are
inferred as plain LUT2s and **drive the clock pin of the capture
flops on general routing** when synthesised on a 7-series FPGA. This
is benign in sim/ASIC where the cells are real (or are bit-exact) but
fails Vivado's `Place 30-568` clock-DRC and produced the
non-deterministic per-lane skew we hunted in §9.5. The `USE_CLKBUF`
generate fix (§5) bypasses the mux chain on FPGA where `io_pol = 0`
and `io_scan_mode = 0` are guaranteed static.

### 2.3 Per-lane training bytes (`WavD2DGpio.v`)

Each `WavD2DGpioRx` instance is parameterised with its own
`TRAINING_BYTE` (`WavD2DGpio.v` lines 491, 505, 519, 533, 547, 561,
575, 589 — one per lane). The values are:

| Lane | TRAINING_BYTE |
|---:|:---:|
| 0  | `0xA3` |
| 1  | `0xB5` |
| 2  | `0xC9` |
| 3  | `0xD3` |
| 4  | `0x65` |
| 5  | `0x4B` |
| 6  | `0x59` |
| 7  | `0x2D` |

These bytes are **aperiodic under cyclic rotation** (period 8): no
byte equals any of its 1..7-bit cyclic rotations, so the 16-bit
`{byte, byte}` deserialised word matches exactly **one** value of
`io_bit_slip[2:0]`. The same byte is wired to the corresponding
`WavD2DGpioTx[lane].io_training_pattern` so a TX in training mode
emits `{P, P}` repeating and the peer's lane checker can lock on it.

The pattern set replaced an earlier `(N+1)*0x11` set whose period-4
aliasing caused multiple slip values to match — see comment in
`src/rtl/tidelink_lane_checker.sv` lines 64–75.

---

## 3. SoC Labs alignment patches (pre-§9 layer)

These are the first generation of SoC Labs patches inside the Wav
RTL. They are software-driven knobs the calibrator (§4) drives
automatically; nothing pre-§9 is FPGA-specific.

### 3.1 `io_phase_offset[3:0]` — coarse word-boundary alignment

`WavD2DGpioRx.v` lines 60–67. A 4-bit per-lane phase offset added to
`count` to form `adj_count` (line 112). Effect: shifts the
deserialiser's sample-cycle by 0..15 cycles within the 16-cycle
word, equivalently shifting the byte boundary by up to one full
serialised word. **Propagates within 16 `pad_clk_rx` cycles** with no
POR required — this matters because the SW-only re-cal path
(`swi_swreset`) does not reach the PHY POR.

The divided word-clock is also re-derived from `adj_count[3]`
(line 206), so the 16-bit `link_data_reg` capture moment shifts in
lock-step.

### 3.2 `io_bit_slip[2:0]` — post-deserialisation bit rotation

`WavD2DGpioRx.v` lines 68–74. After the 16-bit word is captured, a
right-rotation by 0..7 bits is applied:

```
    _link_data_rep = {link_data_reg, link_data_reg};       // 32 bit
    io_link_data   = _link_data_rep[{2'b00, io_bit_slip} +: 16];
                                                            // line 186
```

This corrects **sub-byte rotation** of the recovered word that
`io_phase_offset` cannot fix on its own: `io_phase_offset` is a
sample-cycle selector (it shifts when each bit is captured), while
`io_bit_slip` is a bit-position rotation in the captured 16-bit
window.

### 3.3 Why these two are not sufficient

Each lane has independent IBUF/IOFF chain delay, plus per-lane
routing skew between `pad_clk_rx` and `pad_rx[n]`. The pre-§9 SW
sweep had to find a (`phase_offset`, `bit_slip`) pair per lane every
build, **with no IODELAY centring and no eye visibility**. Every
re-deploy moved the optimum unpredictably; on the slave side the
recovered clock failed to land in any phase-offset value's eye for
>70 % of builds. The §5 IDELAYE2 + BUFG layer turns a placement
lottery into a characterised analogue delay, and §4's automation runs
the sweep at boot.

```
            ┌──────────── one 16-bit deserialised word ────────────┐
            │ bit-position selector: writes bit[N] when adj_count==N│
            ▼
  count: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
  ─────────────────────────────────────────────────────
   phase_offset = 3  ─────►  adj_count: 3  4  5  6 ...  2  (mod 16)
   io_pad     pre-shift slot:        13 14 15  0       12
                                                         ▼
            link_data_reg captures                 link_data_reg[12]
            on falling edge of ~adj_count[3]
            (i.e. when adj_count crosses 8↔7)

  bit_slip = 5 → io_link_data = right-rotate(link_data_reg, 5)
```

---

## 4. The §9 architecture — alignment automation

This layer sits **above** the Wav PHY in the chiplet controller and
runs without firmware involvement. It comprises two new SoC Labs RTL
modules and a Region 8 status / control APB area inside
`axi_chiplet_controller.sv`.

### 4.1 `tidelink_phy_align_calibrator` — search FSM

`src/rtl/tidelink_phy_align_calibrator.sv` (718 lines).

```
                ┌───────────────┐
   role_locked ►│   S_IDLE      │  trigger = role_locked rising OR
                │ (output safe) │              swreset falling while
                └──────┬────────┘              role_locked
                       │ trigger_now
                       ▼
                ┌───────────────┐
                │   S_ARM       │  clear lane_done, score, best_*,
                │ training=1    │  iterator; one-cycle stay
                └──────┬────────┘
                       │
                       ▼
                ┌───────────────┐  walk all 128 (slip,phase) points,
                │   S_SWEEP     │  DWELL_CYCLES per point;
                │ training=1    │  best-of-sweep score capture;
                │ phase/slip    │  legacy early-exit on all_done
                │ live to PHY   │
                └──────┬────────┘
                       │ sweep_exhausted OR
                       │ (early_exit && all_done)
                       ▼
                ┌───────────────┐
                │   S_FINISH    │  decide: success → S_HOLD (HW) or
                │  one cycle    │           S_DONE (sim bypass)
                └──┬──────┬──┬──┘  fault & role_locked → S_ARM
       success │  │      │  │  retry_exhausted → S_DONE
   (HW path)   ▼  │      │  ▼  fault & !role_locked → S_DONE
   ┌──────────────┐     │
   │   S_HOLD     │     │  hold_ctr counts up; release at HOLD_MAX
   │ training=1   │     │  HOLD_CYCLES = 8 × 128 × DWELL_CYCLES
   │ slip/phase   │     │  (≫ 2 sweep periods → peer time to converge)
   │ latched      │     │
   └──────┬───────┘     │
          │             ▼
          │      ┌───────────────┐
          └─────►│   S_DONE      │  calibration_done = 1
                 │ (sticky)      │  training_mode    = 0
                 └──────┬────────┘  re-trigger → S_ARM
                        │
                  swreset rising while in any non-IDLE state:
                  ─────► S_CANCEL ─────► S_ARM on falling edge
```

State encoding (file line 230 — `state_t`):

| State | Value | Outputs while in state |
|---|---|---|
| `S_IDLE`    | 4'd0 | bit_slip/phase = 0, training=0, calibration_done=0 |
| `S_ARM`     | 4'd1 | training=1; one-cycle entry |
| `S_SWEEP`   | 4'd2 | training=1; per-lane outputs follow iterator or latched best |
| `S_FINISH`  | 4'd3 | one-cycle decision |
| `S_DONE`    | 4'd4 | calibration_done=1; latched slip/phase per lane |
| `S_CANCEL`  | 4'd5 | hold latched values; wait for swreset deassert |
| `S_HOLD`    | 4'd6 | training=1; latched slip/phase; counts HOLD_CYCLES then releases |

The state output `state[3:0]` (line 224, line 242) is wired to ILA
and to a debug column not currently surfaced in Region 8.

#### 4.1.1 The shared 128-point sweep

`sweep_slip[2:0]` × `sweep_phase[3:0]` is a single shared iterator
(lines 335–336). Order is **phase-outer, slip-inner**. Per point,
`dwell_ctr` counts to `DWELL_CYCLES - 1` (line 338) and the per-lane
`lane_score[6:0]` (saturating run-length counter) is sampled at
dwell expiry (lines 581–589).

Total worst-case sweep time = 128 × DWELL_CYCLES cycles on the
`phy_link_rx_rx_link_clk_w` domain (the recovered word clock,
`pad_clk_rx`/16). At `DWELL_CYCLES = 64` (the default after §9.9 —
raised from 32) one sweep is **8192 cycles** ≈ 13 ms at 25 Mb/s/lane.

#### 4.1.2 T3 — continuous re-sweep

`MAX_RESWEEPS` (line 178) caps the auto-retry budget; default `0` =
unlimited while `role_locked` is high. `sweep_success` (line 376) is
`~|lane_fault_q` — i.e. **no lane faulted** during this sweep.

When a sweep ends with `sweep_success = 0` and `role_locked = 1`,
the FSM auto-rearms via `S_FINISH → S_ARM`, holding `training_mode`
high throughout (a re-sweep does NOT drop the training pattern).
This is the fix for the per-deploy "first-to-finish abandons the
peer" deadlock seen with SSH-staggered deployment (the master role-
locked >100 ms before the slave; master swept once, finished
faulted, then sat idle while the slave was still locking).

#### 4.1.3 T3.2 — peer-aware S_HOLD

When this node's own sweep is genuinely all-locked, **do not release
immediately**. Enter `S_HOLD` (line 447) and keep `training_mode`
high for `HOLD_CYCLES = 8 × 128 × DWELL_CYCLES` cycles (line 189).
This guarantees the peer — whose role-lock may be skewed by ms-scale
SSH latency — gets a continuous training stream for at least two
full sweep periods, long enough for it to converge.

Sim has a bypass: `tb_early_exit_force_q` (the cocotb hierarchical-
force hook) skips `S_HOLD` and goes straight to `S_DONE`
(line 434–436). Without this every integration test would need a
≥1.5 M `apb_clk` timeout to outlast `HOLD_CYCLES`.

#### 4.1.4 Best-of-N (best-of-sweep) widest-eye latch

`EARLY_EXIT_ON_ALL_LOCKED` (line 201) is the silicon-default toggle:
* `0` (silicon default) — walk the full 128-point space every sweep,
  remember per-lane `best_score`/`best_slip`/`best_phase` (lines
  342–344), latch at sweep exhaustion.
* `1` (legacy / sim compat) — first-match-wins: lane freezes on the
  first dwell with `lane_locked` rising.

`tb_early_exit_force_q` (line 279) is the cocotb hierarchical-force
hook — a `reg` initialised to 0, ORed with the parameter at line
281. The same name controls both the `EARLY_EXIT` policy switch and
the `S_HOLD` bypass.

Score datapath:

```
   per dwell window (DWELL_CYCLES cycles)
   ┌─────────────────────────────────────────────────────────────┐
   │  lane_locked[i] = 1?   yes → lane_score[i]++ (sat 6'h3F)     │
   │                        no  → lane_score[i] := 0              │
   │                                                              │
   │  at dwell expiry (line 573):                                 │
   │     if lane_score[i] > best_score[i]:                        │
   │         best_score[i] = lane_score[i]                        │
   │         best_slip[i]  = sweep_slip                           │
   │         best_phase[i] = sweep_phase                          │
   │     lane_score[i] := 0                                       │
   │                                                              │
   │  at sweep exhaustion (line 597):                             │
   │     if best_score[i] >= LOCK_THRESH:                         │
   │         slip[i]/phase[i] ← best_*[i]                         │
   │     else:                                                    │
   │         lane_fault[i] := 1                                   │
   └─────────────────────────────────────────────────────────────┘
```

This replaces the previous "first eye-edge wins" policy with
"widest sustained lock-run wins". The motivation was marginal
lanes that just cleared `LOCK_THRESH = 16` at an eye edge but
bounced in/out of lock in steady state (`bringup_health_probe`
trajectories oscillating `0xf5`/`0xfd`/`0xd5`/`0xd7`).

### 4.2 `tidelink_lane_checker` — training-pattern lock detector

`src/rtl/tidelink_lane_checker.sv` (90 lines).

```
   lane_data[16i+15 : 16i]                        expected_byte[i]
            │                                            │
            ▼                                            ▼
       word_in  ────►  ( word_in == {byte, byte} ) ◄── expected_word
                              │
                              ▼ is_match
                    ┌─────────────────────┐
                    │  match_count[4:0]   │
                    │  on match: +1 (sat 31)
                    │  on miss : := 0     │
                    └─────────┬───────────┘
                              ▼
                  locked = match_count >= LOCK_THRESH (16)
```

Per-lane `tidelink_lane_checker_single` (line 24) wraps a 5-bit
saturating counter. The wrapper `tidelink_lane_checker` (line 54)
instantiates 8 of them, each parameterised with the matching
period-8 byte (line 72 — same set as `WavD2DGpio.v` per-lane).

Lock criterion: **16 consecutive matching 16-bit words**. Sticky? No
— `locked` falls instantly on the first miss. Calibrator's
`lane_score` is what makes the bring-up decision robust to single
misses (a one-cycle drop does not lose `best_score`).

### 4.3 Region 8 control / status registers

Region 8 lives in `axi_chiplet_controller.sv` at APB offsets
0x100–0x11C (8 slots × 4 B). Address selection is `ctrl_reg_addr[3]`
(line 526). Mapping (read side, line 714):

| Offset | Reg | Fields |
|---|---|---|
| 0x100 (slot 0) | SWI_CTRL       | `[0]` swi_training_mode, `[1]` SWI_RECAL |
| 0x104 (slot 1) | SWI_BIT_SLIP   | `[23:0]` per-lane 3-bit slip override |
| 0x108 (slot 2) | **SWI_LANE_STATUS** | `[7:0]` lane_locked, `[15:8]` lane_fault, `[16]` cal_done, `[20:17]` FCSM state[3:0], `[22:21]` LL_RX state, `[23]` cr_pkt_seen_rx, `[24]` crack_pkt_seen_rx, `[25]` is_short_pkt, `[26]` is_long_pkt, `[27]` pkt_is_cr_pkt, `[28]` pkt_is_crack_pkt, `[29]` LL_RX valid |
| 0x10C (slot 3) | NEGO_TRAIN_CFG | `[15:0]` peer-mask training config |
| 0x110 (slot 4) | TRAIN_STATUS   | various |
| 0x114 (slot 5) | ECC_COUNTERS   | `[31:16]` ECC corrected, `[15:0]` ECC corrupted |
| 0x118 (slot 6) | SWI_PHASE_OFFSET | `[31:0]` per-lane 4-bit phase override |
| 0x11C (slot 7) | PHY_ALIGN_ID   | `0x5041_0100` = "PA" v1.0 |

The chiplet APB region base is `0x4403_2000`, so SWI_LANE_STATUS is
visible at MMIO **`0x4403_2108`**.

The PHY status word is the bring-up oracle. `bringup_health_probe.sh`
polls SWI_LANE_STATUS on both nodes over MMIO and produces a
time-series trajectory; the FCSM bits (20:17) and lane_locked
(7:0) together describe the link state.

---

## 5. The FPGA-only structural fixes (this session)

All five FPGA structural changes are **additive and parameter-gated**.
The default parameter value is 0 (passthrough); the FPGA Vivado IP
wrapper sets each to 1. Each fix is bit-exact on sim/ASIC because the
generate-if prunes the Xilinx primitive branch entirely.

### 5.1 `tidelink_idelay_rx` — per-lane IDELAYE2 RX delay

`fpga/rtl/tidelink_idelay_rx.sv` (213 lines).

```
   pad_rx[7:0]                                  +-- one IDELAYCTRL --+
       │                                        | REFCLK = 200 MHz   |
       ▼                                        | IODELAY_GROUP =    |
   ┌───────────────────────┐                    | "tidelink_rx_idelay"|
   │ generate g_idelay     │ ◄──────────────────+── IODELAY_GROUP ───+
   │ for lane in 0..7:     │                    │                    │
   │   IDELAYE2 #(         │                    │ shared by all 8   │
   │     IDELAY_TYPE=VAR_LOAD                   │ IDELAYE2 cells    │
   │     IDELAY_VALUE=0    │                    │ in this group     │
   │     REFCLK_FREQUENCY=200.0                                     │
   │   ) u_idelaye2 (      │                                        │
   │     .IDATAIN = pad_rx_i[gl]                                    │
   │     .DATAOUT = pad_rx_o[gl]                                    │
   │     .CNTVALUEIN = {phase_tap_i[4gl+:4], 1'b0}  (0..30 of 31)   │
   │     .LD = 1   ← VAR_LOAD continuous-track                      │
   │   )                   │                                        │
   └───────────────────────┘
                                       (USE_IDELAY=0 → pad_rx_o = pad_rx_i)
```

* Parameters (`tidelink_idelay_rx.sv` line 79):
  * `USE_IDELAY` (bit, default 0)        — gate
  * `NUM_LANES` (int, default 8)         — number of RX lanes
  * `IDELAY_GRP` (string, default `"tidelink_rx_idelay"`) — IODELAY_GROUP name (documentary; the attribute uses a string literal — see note at line 87)
  * `REFCLK_MHZ` (real, default 200.0)   — IDELAYCTRL ref clock
* Tap mapping (line 150–151): `lane_tap = {phase_tap_i[4gl +: 4], 1'b0}` — a ×2 scale of the calibrator's 4-bit phase to fill the 5-bit IDELAYE2 tap space monotonically. At 200 MHz ref ≈ 78 ps/tap so the 0..30 range spans ≈ 2.34 ns ≈ 1.5 × one 25 MHz UI (40 ns) — but **the delay we need is sub-UI**: the UI scale is set by the bit rate, and the IDELAY is fixing intra-bit-cell skew between `pad_rx[n]` and the forwarded clock, not whole-bit shifts. The calibrator's higher 4-bit `phase_offset` field does whole-cycle moves.
* LD=1 continuous-track (line 181): `CNTVALUEIN` re-loads every ref-clock; the calibrator dwells many cycles per point so the IDELAYE2 always tracks the live value.

The IDELAYCTRL is instantiated once (`u_idelayctrl`, line 137). Its
RDY is intentionally unconnected (line 138) so a transient
uncalibrated-tap state cannot gate the data path — the calibrator
must continue running through IDELAYCTRL bring-up.

**Opt-out escape hatch (line 125, 186).** `TIDELINK_IDELAY_NO_PRIMITIVE`
defined → the `USE_IDELAY=1` branch falls back to passthrough. Used
only by non-Vivado simulators that lack `unisim` but force
`USE_IDELAY=1` (e.g. cocotb idelay coverage).

### 5.2 `tidelink_rxclk_buf` — recovered-RX-clock boundary BUFG

`fpga/rtl/tidelink_rxclk_buf.sv` (93 lines, faithful idelay-mirror).

```
   pad_clk_rx ──IBUF── clk_i ─────► generate g_bufg ───► clk_o ───►
                                       BUFG u_rxclk_bufg
                                       (USE_CLKBUF=1)
                                       passthrough (USE_CLKBUF=0)
```

* Parameter (line 49): `USE_CLKBUF` (bit, default 0)
* Pattern is byte-for-byte the same as `tidelink_idelay_rx`:
  parameter-gated, generate-if, `TIDELINK_RXCLK_NO_PRIMITIVE` opt-out.
* Effect: forces a global clock buffer **at the IP boundary**,
  before `pad_clk_rx` fans into the Wav PHY. This was the first
  structural step taken when the routed netlist showed
  `IBUF → BUFG → fabric-LUT → BUFG` and per-lane LUTs on the clock pin.

### 5.3 In-PHY clean-clock restructure in `WavD2DGpioRx`

`WavD2DGpioRx.v` lines 209–240. The boundary BUFG (5.2) is necessary
but insufficient: the per-lane `WavClockMux` chain + the
`~adj_count[3]` divided word-clock are **inside** the per-lane RX. So
`WavD2DGpioRx` itself was given a `USE_CLKBUF` parameter (line 21):

```
   USE_CLKBUF = 1 (FPGA):
       BUFG u_cap_bufg  (.I(io_pad_clk),     .O(w_cnt_clk));
       assign w_pad_clk = w_cnt_clk;
       BUFG u_lnk_bufg  (.I(~adj_count[3]),  .O(w_lnk_clk));

       count             ← clocked by w_cnt_clk
       link_data_pad_clk ← clocked by w_pad_clk
       link_data_reg     ← clocked by w_lnk_clk   (= io_link_clk)

   USE_CLKBUF = 0 (sim/ASIC/UVM):
       w_cnt_clk = pad_clk_scan_mux.io_o_z
       w_pad_clk = pad_clk_inv_scan_mux_1.io_o_z
       w_lnk_clk = io_link_clk_mux.io_o_z       (the original muxes)
```

This bypasses the four `WavClockMux` cells (lines 139, 145, 151, 163) on FPGA. Both `io_pol` and `io_scan_mode` are static-0 in the FPGA flow:
* `io_pol` (line 60) — `out_prepend_swi_polarity` reg, never written in the production flow
* `io_scan_mode` (line 55) — DFT scan-mode input, tied 0

So bypassing the muxes is functionally safe, and the generate-if
(line 221) prunes them on FPGA.

### 5.4 `USE_T3A` — self-aligning RX comma-hunt FSM

`WavD2DGpioRx.v` lines 22–53 (parameter + header), lines 242–390
(implementation).

**Problem.** `count` (the bit-position selector) **free-runs from
`io_por_reset`**. Two boards reach `io_por_reset` deassertion at
different times (per-deploy SSH-skewed PCAP load); the relative
byte-boundary between master and slave `count` is random in a
16-cycle window. Calibrator `io_phase_offset`/`io_bit_slip` is a
0..15 + 0..7 search, but it is sub-bit-cell + sub-byte — it can't
re-phase the `count` itself, only the sample-cycle and the
window rotation.

**Fix.** Per-lane comma-hunt FSM that slips `count` exactly once per
POR to align with the peer's training byte. States:

```
       io_por_reset
            │
            ▼
   ┌─────────────────┐  S_SETTLE (64 cycles)
   │  realign_shifter│  - capture 8 most-recent io_pad bits
   │  := {sh[6:0], io_pad}                                              │
   ├─────────────────┤
   │   S_HUNT        │  - compare shifter to 8 rotations of TRAINING_BYTE
   │  (up to 1023    │  - on match: slip count by match_rot; → S_LOCKED
   │   cycles)       │  - on timeout (MAX_HUNT): → S_LOCKED (no slip;
   ├─────────────────┤    legacy free-run; lane still operable via
   │   S_LOCKED      │    phase_offset/bit_slip/IDELAYE2)
   │   (sticky;      │
   │    re-arm on    │
   │    next POR)    │
   └─────────────────┘
```

`TRAINING_BYTE` is per-lane (line 52), defaulting to `8'h00` (which
is safe because every rotation of all-zeros matches — slip=0, no-op).
`WavD2DGpio.v` overrides it to the matching per-lane byte at the 8
`WavD2DGpioRx` instantiations (lines 491, 505, …, 589 — see §2.3).

The `count` slip happens in the always block at line 369:
```
   if (do_slip)
       count <= count + 4'h1 - {1'b0, slip_amt};
   else
       count <= count + 4'h1;
```

The match function is a priority-encoded 8-rotation compare (lines
294–316). `USE_T3A = 0` (sim/ASIC default) — the legacy
free-run always block (line 382) is selected by the generate-if,
**zero extra flops**.

### 5.5 Five-level parameter threading

The FPGA-only gate parameters are threaded explicitly through the
five hierarchy levels rather than relying on synth-time `define`s
(the latter was the failure mode that wasted three weeks — see
`tidelink_idelay_rx.sv` line 46–56 history block).

```
  tidelink_vivado_wrapper                     defaults: USE_IDELAY = 1
   │       (fpga/vivado_ip/tidelink_vivado_wrapper.v lines 63, 67, 73)
   │                                                    USE_CLKBUF = 1
   │                                                    USE_T3A    = 1
   ▼
  tidelink_top                                defaults: USE_IDELAY = 0
   │       (src/rtl/tidelink_top.sv lines 65, 68, 74)    USE_CLKBUF = 0
   │                                                    USE_T3A    = 0
   ▼
  axi_chiplet_controller                      defaults: USE_IDELAY = 0
   │       (deps/.../axi_chiplet_controller.sv         USE_CLKBUF = 0
   │            lines 37, 41, 47)                       USE_T3A    = 0
   ▼
  Wlink (Chisel)                              passes USE_CLKBUF / USE_T3A
   │       (deps/.../wlink/Wlink.v)
   │
   ▼
  WlinkGPIOPHY                                defaults: USE_CLKBUF = 0
   │       (deps/.../wlink/WlinkGPIOPHY.v lines 1–6)    USE_T3A    = 0
   │
   ▼
  WavD2DGpio                                  passes USE_CLKBUF / USE_T3A
   │       (deps/.../wlink/WavD2DGpio.v lines 1–12)
   │       per-lane WavD2DGpioRx instantiation w/ TRAINING_BYTE override
   │       (lines 491, 505, 519, 533, 547, 561, 575, 589)
   ▼
  WavD2DGpioRx[7:0]                           defaults: USE_CLKBUF = 0
          (deps/.../wlink/WavD2DGpioRx.v lines 21, 52, 53)  USE_T3A    = 0
                                                       TRAINING_BYTE = 0x00
```

Carried into Vivado out-of-context (OOC) synthesis via the packaged
IP's `component.xml` — exactly the IP-XACT parameter mechanism that
`tidelink_vivado_wrapper`'s `parameter USE_IDELAY = 1'b1` (line 63)
declares. Critically, **no preprocessor `define` is required**. The
earlier `` `ifdef TIDELINK_USE_IDELAY`` opt-in was unreachable in OOC
synth (the define did not propagate from the packaging project into
the IP's compile units) and was removed — see the long history block
at `tidelink_idelay_rx.sv` lines 46–56.

### 5.6 ASIC bit-exactness

Every Xilinx primitive (`IDELAYE2`, `IDELAYCTRL`, `BUFG`) lives
inside a `generate-if (USE_xxx) begin … end` block. With `USE_xxx = 0`
the entire branch is pruned at elaboration time:
* `tidelink_idelay_rx.sv` line 123 (`generate ... if (USE_IDELAY)`)
* `tidelink_rxclk_buf.sv` line 63
* `WavD2DGpioRx.v` line 221 (`USE_CLKBUF`) and line 278 (`USE_T3A`)

Net effect: `feat/td-combined` synthesises bit-identically to the
pre-§9 RTL when fed through the ASIC flist or any non-FPGA flow
that defaults `USE_xxx = 0`. The cocotb regression `pin
USE_IDELAY=0 passthrough phase-invariance` (commit 5af4801) is the
formal proof for the IDELAY path; equivalent coverage exists for
the BUFG/T3A paths in `cocotb/tidelink_rxclk_buf/`,
`cocotb/wavd2d_gpiorx_clkbuf/`, `cocotb/wavd2d_gpiorx_t3a_off/`.

---

## 6. The link layer training & FCSM

### 6.1 `swi_training_mode` propagation

When `swi_training_mode_w = 1` the TX side of every lane sources
`{pattern, pattern}` from its hard-wired `io_training_pattern` and
**stops emitting Wlink link data**. The patch lives in
`WavD2DGpioTx.v` line 43–45.

`swi_training_mode_w = cal_training_mode_w | swi_training_mode_r`
(`axi_chiplet_controller.sv` line 1372). Two sources:
* `cal_training_mode_w` — driven by the calibrator
  (high in `S_ARM`/`S_SWEEP`/`S_HOLD`).
* `swi_training_mode_r` — Region 8 SW override (`0x4403_2100`
  bit 0). Defaults 0; useful for SW debug.

The OR-merge keeps the calibrator authoritative without disabling
the existing SW debug path the cocotb tests use.

### 6.2 `mask_hs` role-lock gate and SWI_RECAL

`mask_hs_match` (submodule commit `cab2d8f`) gates the role-lock /
training advance until peer-mask negotiation completes. The
`apb_debug_unlock_i` input (line 311 of `tidelink_vivado_wrapper.v`)
allows SW to force the gate open during bring-up debug.

`SWI_RECAL` (submodule commit `d1351f4`, line 551 of
`axi_chiplet_controller.sv`) is a Region 8 slot-0 bit-1 write —
**`mmio_write(0x4403_2100, 0x2)`** drives `swi_recal_r` high, which
maps to the calibrator's `swreset` input (line 1340). Its falling
edge re-triggers a sweep with `role_locked` still high, **without
dropping the role**. This is the SW-driven recovery path used by
`bringup_pair_converge.sh` when the cold-boot sweep finishes with
non-overlapping windows.

### 6.3 FCSM state progression

The Wlink FCSM (Flow-Control State Machine) lives in
`deps/.../wlink/WlinkGenericFCSM_6.v` line 163. It advances on
receipt of `cr` (credit-replenish) packets from the peer:

```
   POR
    │
    ▼
   state = 3'd0   IDLE — link not running; awaits ack
    │  ack_seen
    ▼
   state = 3'd1   waiting for cr (line 217)
    │  cr/crack_pkt_seen_tx
    ▼
   state = 3'd2   credit exchange in progress (line 259)
    │  auto_tx_out_advance + crack_pkt_seen_tx
    ▼
   state = 3'd3   peer ack'd; final settle (line 267)
    │  count == 0 (line 271)
    ▼
   state = 3'd4   RUNNING — link active, FC packets exchanged
```

The 3-bit state is exported via `obs_fcsm_state_o`
(`Wlink.v` line 171, 823 → `axi_chiplet_controller.sv` line 491)
and surfaces at SWI_LANE_STATUS bits [20:17] (line 726).

`cr` is a **SHORT packet, ECC-only, no retry**. A single per-lane
bit error in the cr header is detected by the ECC but **discarded**,
not retried. With marginal lanes (per-deploy 1–2 % bit errors) the
FCSM could miss the cr seed it needed to advance — Agent A's
forensic finding (file `docs/AGENT_BRIEF_FCSM_RX_BUG.md`).

### 6.4 Sticky `cr_pkt_seen_rx`

Submodule commit `0e126b0` made `cr_pkt_seen_rx` / `crack_pkt_seen_rx`
**sticky-latched** on the receive side (the WlinkEccSyndrome path
that gates the FCSM). Once a valid cr is seen, the flag holds until
the FCSM consumes it — defeating the single-error miss mode. The
sticky flags surface at SWI_LANE_STATUS bits [23] and [24] for
observability.

### 6.5 Bring-up sequence timeline

```
   Time (ms-scale)        Master                       Slave
   ─────────────────      ────────────────────────     ────────────────
   t = 0    deploy        PCAP bitstream load          (still booting)
   t = 1    POR rises     poresetn = 1
                          role strap evaluated
                          peer-mask handshake start (I2C sideband)
   t = 5                  mask_hs negotiation         POR rises (skewed)
   t = 8                  mask_hs_match → role_locked  role strap eval
   t = 9                  AUTOCAL trigger → S_ARM
                          training_mode = 1
                          (TX emits {P,P}, link data held off)
   t = 9 + δ              T3a (USE_T3A=1): comma-hunt
                          slips count once → S_LOCKED
   t = 9 + ε                                          mask_hs_match
                                                      role_locked rises
                                                      AUTOCAL → S_ARM
   t = 9 + δ → 9 + δ      sweep_phase 0..15 ×          sweep starts
                          sweep_slip 0..7 ×             (lottery: peer's
                          DWELL_CYCLES = 8192 cycles    training may not
                                                       be live yet)
   t ≈ 22                 sweep_exhausted             sweep_exhausted
                          either succeeds → S_HOLD    if mid-skew: fault
                          (HOLD_CYCLES wait) or       → T3 re-sweep
                          re-sweeps                   (training stays 1)
   t = 22…22 + HOLD       calibration_done = 1        converges within
                          (after S_HOLD finishes)     2 sweeps via T3
   t ≈ 25                 lltx_enable gated by        likewise
                          calibration_done lifted
                          training_mode = 0
   t = 25..30             cr_pkt exchange             cr_pkt exchange
                          FCSM 0 → 1 → 2 → 3 → 4      FCSM 0 → 1 → … → 4
   t = 30+                link_active = 1             link_active = 1
                          AHB / AXI / APB traffic
```

`bringup_pair_converge.sh` orchestrates this — it sequentially
asserts `apb_debug_unlock_i` and `SWI_RECAL` on both nodes to make
T3 re-sweep windows coincide.

---

## 7. Bank-35 vs bank-13 asymmetry (the residual)

This is the **one** open issue after all §9 fixes land. It is a
silicon-runtime VT effect inside the IDELAYCTRL primitives that no
RTL or XDC can sidestep without changing the J13 pin choice.

### 7.1 Mechanism

Vivado places **one IDELAYCTRL per IDELAY column**. The pad-to-column
binding is determined by the pin location, not the RTL or the XDC
IODELAY_GROUP:

| Lane | RX pin | I/O bank | IDELAY column | IDELAYCTRL inst |
|---:|:---:|:---:|:---:|:---:|
| 0 | U7  | 13 | X0 | IDELAYCTRL_X0Y0 |
| 1 | C20 | **35** | **X1** | **IDELAYCTRL_X1Y2** |
| 2 | Y8  | 13 | X0 | IDELAYCTRL_X0Y0 |
| 3 | A20 | **35** | **X1** | **IDELAYCTRL_X1Y2** |
| 4 | U8  | 13 | X0 | IDELAYCTRL_X0Y0 |
| 5 | W6  | 13 | X0 | IDELAYCTRL_X0Y0 |
| 6 | Y6  | 13 | X0 | IDELAYCTRL_X0Y0 |
| 7 | V7  | 13 | X0 | IDELAYCTRL_X0Y0 |

The two IDELAYCTRL instances share the same `tidelink_rx_idelay`
IODELAY_GROUP string in the XDC and the same `idelay_ref_clk` —
**but they are physically distinct cells with independent VT-dependent
tap-time references**. At runtime the bank-35 cells produce taps
that are typically 5–10 % off the bank-13 cells in both magnitude
and centring.

```
   ASCII pin-to-bank map (J13 / RPi GPIO 26-pin header subset):

                          ┌─────────────── BANK 13 ───────────────┐
   pad_tx[]:               W19 Y18 Y19 U18 U19 F19 V10 V8        ┐
                            ▲   ▲   ▲   ▲   ▲   ▲   ▲   ▲        │
   J13 pin idx 1-8 (8 lanes; all bank 13)                         │
                                                                  │
   pad_clk_tx: Y9 (bank 13, SRCC P-side)                          │
   pad_clk_rx: Y7 (bank 13, MRCC P-side; clock-capable)           │
                                                                  │
   pad_rx[0]: U7   bank 13   ──► X0/IDELAYCTRL_X0Y0               │
   pad_rx[2]: Y8   bank 13   ──► X0                               │
   pad_rx[4]: U8   bank 13   ──► X0                               │
   pad_rx[5]: W6   bank 13   ──► X0                               │
   pad_rx[6]: Y6   bank 13   ──► X0                               │
   pad_rx[7]: V7   bank 13   ──► X0   (was F20, remapped)         │
                          └────────────────────────────────────────┘
                          ┌─────────────── BANK 35 ───────────────┐
   pad_rx[1]: C20  bank 35   ──► X1/IDELAYCTRL_X1Y2   (narrow eye) │
   pad_rx[3]: A20  bank 35   ──► X1/IDELAYCTRL_X1Y2   (narrow eye) │
                          └────────────────────────────────────────┘
```

### 7.2 Visible effect

`bringup_health_probe.sh` captures the trajectory of SWI_LANE_STATUS
over time. Marginal lanes (master lane 1 = C20 bank-35, slave lane
0 = F19 — also bank 35 on the mirrored target) show bouncing
lock-state (`0xfd → 0xf5 → 0xfd …`) — their eye width is smaller
than the others'.

This is the mechanism the cocotb behavioural reproducer in
`cocotb/bank_asymmetry/` exercises: it injects a narrower
`lane_locked` pulse window for the bank-35 lanes and proves that
**best-of-sweep widest-eye latch** (the §9.9 fix) recovers a
hit-rate that **first-match-wins** does not.

### 7.3 Why XDC alone can't fix it

The J13 RPi header has 18 pins reachable from the Pynq-Z2 package.
**Six of those 18 are physically bonded to bank 35** (the C/B/A
column on the package side). With the pair-target needing 18 pins
(1 clock + 8 data × 2 directions) two of the eight RX lanes
**must** land on bank 35. No XDC `set_property PACKAGE_PIN` rotation
avoids it — bank 35 is the only place those package pins exist.

The structural fixes (§5) plus best-of-sweep (§4.1.4) plus T3
(§4.1.2) close >95 % of the link reliability gap. The remaining
1–5 % failure rate per bring-up traces to the bank-35 lane VT
spread. The architectural fix is a **per-bank-group calibrator**
(see §10).

---

## 8. Verification environment

### 8.1 cocotb test layout

Each test is a self-contained Makefile + Python testbench. The
RTL → test map is the canonical reference in
`cocotb/PHY_TESTS.md`:

| RTL component                              | Test directory                              | Coverage |
|---|---|---|
| `tidelink_rxclk_buf.sv`                    | `cocotb/tidelink_rxclk_buf/`                | USE_CLKBUF=0 and =1+NO_PRIMITIVE — bit-exact on both corners |
| `WavD2DGpioRx.v` USE_CLKBUF gen            | `cocotb/wavd2d_gpiorx_clkbuf/`              | g_passthru = legacy mux path bit-exact, link_data well-formed |
| `WavD2DGpioRx.v` T3a comma-hunt            | `cocotb/wavd2d_gpiorx_t3a/`                 | 8 lanes × 4 POR-skews per lane, link_data invariant under POR-deassert skew |
| `WavD2DGpioRx.v` T3a — MAX_HUNT            | `cocotb/wavd2d_gpiorx_t3a_timeout/`         | silent-peer fallback to S_LOCKED, no livelock |
| `WavD2DGpioRx.v` T3a — USE_T3A=0           | `cocotb/wavd2d_gpiorx_t3a_off/`             | strict bit-exact passthrough |
| `tidelink_phy_align_calibrator.sv` T3/T3.2 | `cocotb/tidelink_phy_align_calibrator/`     | continuous re-sweep, S_HOLD insensitivity, resweep_ctr |
| `tidelink_idelay_rx.sv`                    | `cocotb/tidelink_idelay_rx/`                | USE_IDELAY=0 passthrough, USE_IDELAY=1+NO_PRIMITIVE escape |
| `tidelink_lane_checker.sv`                 | `cocotb/tidelink_phy_align_calibrator/`     | indirectly via calibrator integration |
| pair-level integration                     | `cocotb/phy_align/test_pair_align.py`       | end-to-end master+slave, FCSM = 4 |

### 8.2 Bank-asymmetry reproducer

`cocotb/bank_asymmetry/` (Makefile + tb_top.sv +
`test_bank_asymmetry.py` + README.md). Behavioural model of the
narrow/shifted-eye effect at the `lane_locked[7:0]` boundary; does
**not** instantiate the Wav PHY. It validates that best-of-sweep
recovers lock on lanes the first-match policy abandoned, providing
unit-level confidence for the silicon trajectory captured by
`bringup_health_probe.sh`.

---

## 9. Bring-up flow + observability

### 9.1 Deploy

`pynq_host/scripts/deploy_pair.sh` (the per-board deploy script):
1. ssh into a Pynq-Z2 host via the ProxyJump topology
   (`mapstone-dev → z2_0X`)
2. rsync bitstream + helper binaries to `/tmp/tidelink_deploy/`
3. `cat bitstream > /dev/xdevcfg` (PCAP load)
4. assert `apb_debug_unlock_i` GPIO (MMIO 0x4404_1000 = 1)
5. optionally write `PHASE_OVERRIDE` to Region 8 SWI_PHASE_OFFSET

### 9.2 Converge

`pynq_host/scripts/bringup_pair_converge.sh` is the closed-loop
sequencer:
1. `deploy_pair.sh` for both boards in parallel
2. Wait `SETTLE` seconds for PCAP + POR
3. Read SWI_LANE_STATUS (lane_locked + FCSM) on each board
4. If not both `link_active`: write `SWI_RECAL=1` to both, then
   `SWI_RECAL=0`, wait, re-read. Up to `MAX_ROUNDS` iterations.

The recal handshake aligns T3 re-sweep windows. Each iteration is
deterministic: the calibrator never abandons the sweep mid-flight
(T3.2 S_HOLD); each round overlaps both boards' `training_mode`
windows for ≥ HOLD_CYCLES.

### 9.3 Probe

`pynq_host/scripts/bringup_health_probe.sh` polls SWI_LANE_STATUS
on a single board (timer-driven) and produces a time-series
showing per-lane lock + FCSM state. The output captures the
marginal-lane bouncing behaviour referenced in §7.2.

### 9.4 HW results captured this session

| Build (bitstream) | Notes | Result |
|---|---|---|
| `b_combined`     | All §9 fixes ON; first-match-wins | 14/16 lanes lock plateau; marginal-lane bounce |
| `b_clkbuf`       | USE_CLKBUF=1, USE_IDELAY=1, USE_T3A=1, first-match | dead RX direction resolved; bouncing reduced |
| `b_inphy`        | + in-PHY clean-clock restructure (§5.3) | 7×Place 30-568 cleared; all lanes consistently exit S_HUNT |
| `b_combined` + best-of-N (§9.9) | Final candidate | bank-35 lanes still ~5 % failure; bank-13 lanes solid |

---

## 10. Open issues and future direction

### 10.1 Lane-masking as a v1 acceptance path

The Wlink lane-mask vector (`link_tx_tx_lane_mask` /
`link_rx_rx_lane_mask`) supports 6/8 or 7/8 lanes operating. With
the two bank-35 lanes masked off, the link runs from 200 Mb/s down
to 150 Mb/s (6 lanes) — a 25 % bandwidth loss for 100 %
reliability. This is the v1 acceptance fallback if the per-bank
calibrator isn't ready.

### 10.2 Per-bank-group calibrator (the right RTL fix)

The §9.9 calibrator searches the (slip, phase) space **with one
shared iterator across all 8 lanes**. The eye-centring fix replaces
the iterator with **N parallel iterators** — one per IDELAYCTRL
group — so the bank-35 lanes can settle to a different point in
the search space than the bank-13 lanes within the same sweep. The
RTL change is small (per-bank score arrays + a per-bank iterator)
but the calibrator's best-of-sweep dwell semantics have to be
preserved across both groups.

### 10.3 Architectural cleanup recommendation

Audit recommendation (file `docs/SHORTCOMINGS.md`): freeze the
Wav vendor files (`WavD2DGpio*.v`) and pull the SoC Labs additions
out into one wrapper module `tidelink_gpio_rx_align.sv` with a
single `USE_FPGA_PRIMITIVES` parameter. The three `USE_CLKBUF`,
`USE_IDELAY`, `USE_T3A` parameters all map to the same FPGA-only
decision; collapsing them avoids the five-level-threading exposure
the current design carries.

### 10.4 v2 PHY

The clean migration when v2 silicon arrives is to replace
`WavD2DGpioRx` with `ISERDESE2`-based capture. The 7-series
`ISERDESE2` provides hard-IP per-bit deserialisation with an
integrated bit-slip (Xilinx UG471) — most of `WavD2DGpioRx`'s
deserialiser becomes redundant. For higher-rate links (≥1 Gb/s) the
target is `GTX` SerDes with embedded clock recovery; the same
calibrator structure (Region 8 status, FSM, lane_checker) carries
over because it talks to the link-layer side not the analogue
side.

---

## Appendix A — Parameter quick reference

| Parameter | Default | Purpose | File |
|---|---|---|---|
| `USE_IDELAY`        | 0 (1 on FPGA) | per-lane IDELAYE2 | `tidelink_idelay_rx.sv:84`, `tidelink_top.sv:65`, `tidelink_vivado_wrapper.v:63` |
| `USE_CLKBUF`        | 0 (1 on FPGA) | boundary BUFG + in-PHY BUFGs | `tidelink_rxclk_buf.sv:53`, `WavD2DGpioRx.v:21`, `WlinkGPIOPHY.v:3`, `tidelink_top.sv:68`, `tidelink_vivado_wrapper.v:67` |
| `USE_T3A`           | 0 (1 on FPGA) | comma-hunt count realign | `WavD2DGpioRx.v:53`, `WlinkGPIOPHY.v:6`, `tidelink_top.sv:74`, `tidelink_vivado_wrapper.v:73` |
| `TRAINING_BYTE`     | 0x00 (per-lane override in `WavD2DGpio.v`) | T3a expected byte | `WavD2DGpioRx.v:52` |
| `NUM_LANES`         | 8 | lanes in IDELAY rx | `tidelink_idelay_rx.sv:86` |
| `IDELAY_GRP`        | "tidelink_rx_idelay" | IODELAY_GROUP name | `tidelink_idelay_rx.sv:96` |
| `REFCLK_MHZ`        | 200.0 | IDELAYCTRL ref | `tidelink_idelay_rx.sv:100` |
| `DWELL_CYCLES`      | 64 | per-point dwell | `tidelink_phy_align_calibrator.sv:167` |
| `LOCK_THRESH`       | 16 | min lock-count for best_score qualify | `tidelink_phy_align_calibrator.sv:170` |
| `NUM_LANES`         | 8 (informational) | calibrator | `tidelink_phy_align_calibrator.sv:172` |
| `MAX_RESWEEPS`      | 0 (unlimited) | T3 retry cap | `tidelink_phy_align_calibrator.sv:179` |
| `HOLD_CYCLES`       | 8 × 128 × DWELL_CYCLES | T3.2 hold window | `tidelink_phy_align_calibrator.sv:189` |
| `EARLY_EXIT_ON_ALL_LOCKED` | 0 | best-of-sweep vs first-match | `tidelink_phy_align_calibrator.sv:201` |
| `AUTOCAL_ENABLE`    | 1 (set by tidelink_top) | calibrator enable | `tidelink_top.sv:1389` |

---

## Appendix B — Cross-references

* SWI_LANE_STATUS MMIO: `0x4403_2108` (chiplet APB base + 0x108)
* Wav PHY hard-coded per-lane training bytes: see §2.3, file
  `WavD2DGpio.v` lines 491, 505, 519, 533, 547, 561, 575, 589
* SWI_RECAL MMIO: `0x4403_2100`, write `0x2` to set bit 1
* `apb_debug_unlock_i`: top-level discrete input, line 311 of
  `tidelink_vivado_wrapper.v`
* Submodule key fixes:
  * `cab2d8f` chiplet-ctrl: apb_debug_unlock_i opens mask_hs gate
  * `d1351f4` chiplet-ctrl: SWI_RECAL bit wires calibrator swreset
  * `0e126b0` FCSM_6: sticky cr/crack_pkt_seen_rx
* Parent commit history (the RTL §9 fixes):
  * `1b2e87e` fix(idelay): gate IDELAYE2 on USE_IDELAY param only
  * `0bfe16b` fix(§9 clock): recovered-RX-clock global BUFG
  * `7011e78` fix(§9 clock B+): in-PHY clean-clock restructure
  * `98946ed` fix(§9 T3a): self-aligning RX comma hunt
  * `0d85843` fix(§9 calibrator): best-of-sweep widest-eye latch
  * `c86f17b` fix(§9 calibrator): tb_early_exit_force_q bypasses S_HOLD
  * `fc6ce69` test(§9): bank-asymmetry behavioural reproducer

This document is intentionally repository-internal; it cites file
lines rather than abstracting them so HW engineers joining the
project can `grep -n` directly without rediscovering the topology.

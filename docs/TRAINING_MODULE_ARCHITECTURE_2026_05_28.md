# TideLink Training Module Architecture (2026-05-28)

Read companion against branches:
- `feat/target-a-oddr` — the bitstream actually loaded on HW today.
- `feat/eye-visibility-v2` — adds eye observability, EYE_LANE_CRC counters, splits S_HOLD/S_VALIDATE, keeps S_VALIDATE on target-a-oddr only.

All file paths below are absolute; line numbers reference `feat/eye-visibility-v2` unless prefixed with `[target-a-oddr]`.

---

## 1. Executive summary

When `training_mode` is asserted, each of the 8 Wlink GPIO lanes stops emitting Link-Layer payload bytes and instead emits a known per-lane bit stream produced by `WavD2DGpioTx`. On the receive side, `WavD2DGpioRx` deserialises that lane into a 16-bit word per `pad_clk_rx/16` tick, with an APB-/calibrator-driven 4-bit `io_phase_offset` rotating which `pad_clk_rx` cycle latches into which bit of the captured word, and a 3-bit `io_bit_slip` right-rotating the resulting 16-bit word once it has crossed into the link clock domain. The per-lane 16-bit word is then handed to `tidelink_lane_checker`, which compares it against the expected per-lane training word and asserts `lane_locked[i]` after `LOCK_THRESH` (default 16) consecutive matches. `tidelink_phy_align_calibrator` is the closed-loop owner: on `role_locked` rising it asserts `training_mode` to the PHY, walks (slip×phase) for all lanes in parallel (single shared iterator, phase-outer slip-inner), scores each lane, latches per-lane `(slip,phase)` at sweep end, and transitions to `S_DONE` where it deasserts `training_mode` and asserts `calibration_done`. The Wlink FCSM (autoneg, FC.scala) is structurally INDEPENDENT of `training_mode` — it advances purely on `cr_pkt_seen_tx`/`crack_pkt_seen_tx` (seen-flag-of-peer-seen-mine). It is gated by `swi_enable` (and POR), not by `training_mode`. The integration choice that ties the two together is `wlink_por_reset = ~poresetn | ~role_locked` (axi_chiplet_controller.sv:778): the Wlink resets until role_lock, which in turn does not latch until SW writes ROLE_CFG[1]=1.

---

## 2. ASCII block diagram (one lane)

```
                                       APB (slot0..slot6 @ 0x44032100..0x4403211C, ctrl_reg_addr[3]=1)
                                       │                       │                  │
            slot0[0]=swi_training_mode  │  slot0[1]=swi_recal   │  slot6=swi_phase_offset_r (8×4b)
            slot1=swi_bit_slip_lo_r     │                       │  PHY_CTRL@APB bits[20:17]
                                       ▼                       ▼                  ▼
                          ┌──────────────────────────────────────────────────────────┐
                          │ axi_chiplet_controller.sv  Region 8 regs                  │
                          │  swi_training_mode_r, swi_recal_r, swi_bit_slip_lo_r,     │
                          │  swi_phase_offset_r (all POR-domain)                      │
                          └────────────┬─────────────┬───────────────┬────────────────┘
                                       │             │               │
                                       ▼  role_locked│               │
                          ┌──────────────────────────┴───────────────┴────────────────┐
                          │ tidelink_phy_align_calibrator  (link_rx_clk dom)          │
                          │  inputs:  role_locked (=role_lock_reg & AUTOCAL_ENABLE),  │
                          │           swreset = swi_recal_r,                          │
                          │           lane_locked[7:0]                                │
                          │  state[3:0]: S_IDLE/S_ARM/S_PROBE*/S_SWEEP/S_FINALIZE*/   │
                          │              S_FINISH/S_HOLD/S_VALIDATE*/S_DONE/S_CANCEL  │
                          │  outputs: bit_slip[23:0], phase_offset[31:0],             │
                          │           training_mode, calibration_done, lane_fault[7:0]│
                          │  (* = target-a-oddr only; eye-visibility-v2 retains S_HOLD│
                          │    but does NOT have S_PROBE / S_FINALIZE / S_VALIDATE.)  │
                          └─┬──────────────────────────────────────────┬──────────────┘
   cal_bit_slip_w (24b)     │ cal_training_mode_w  cal_phase_offset_w  │ calibration_done
   ── OR with swi_bit_slip_lo_r ── OR with swi_training_mode_r ── OR with swi_phase_offset_r
                            │           │                  │
                            ▼           ▼                  ▼
                          swi_bit_slip_in  swi_training_mode_in  swi_phase_offset_in
                                  ↓                                ↓
                  ┌────────────────────────────────────────────────────────────┐
                  │ WavD2DGpio (local_overrides/WavD2DGpio.v)                  │
                  │  effective_bit_slip       = io_swi_bit_slip_in       | swi_bit_slip       (8×3b)
                  │  input_training_mode_w    = io_swi_training_mode_in  | swi_training_mode  (TX-q
                  │     + word-aligned per-lane latch in WavD2DGpioTx)
                  │  effective_phase_offset[N] = io_swi_phase_offset_in[N] | swi_phase_offset
                  └──┬─────────────────────────────────────────────────────┬───┘
        per-lane gpiotx_N                                                  per-lane gpiorx_N
                     │                                                     │
       ┌─────────────▼─────────────┐                              ┌────────▼────────┐
       │ WavD2DGpioTx (local)      │  io_pad (1b/pad_clk)         │ WavD2DGpioRx    │
       │  io_training_pattern[N]   │ ─────────────────────────►   │  TRAINING_BYTE  │
       │  PRBS-7 LFSR ⊕ {tag,tag}  │                              │  io_pad_clk     │
       │  (target-a-oddr)          │                              │  io_phase_offset│
       │  vs {pattern,pattern}     │                              │  io_bit_slip    │
       │  (eye-visibility-v2)      │                              │   count, adj_count
       │  WORD_ALIGN_MUX latch     │                              │   ~adj_count[3] = w_lnk_clk
       │                          │                              │   link_data_pad_clk → link_data_reg
       └───────────────────────────┘                              │   right-rotate by io_bit_slip
                                                                  │   → io_link_data[15:0] (link_clk dom)
                                                                  └────────┬────────┘
                                                                           ▼ rx_link_data[127:0]
                          ┌────────────────────────────────────────────────────────────┐
                          │ tidelink_lane_checker  (clk = link_rx_clk, rst = ~role_locked)
                          │  PATTERNS[0..7]: A3 B5 C9 D3 65 4B 59 2D                    │
                          │  expected_word = {PATTERNS[i], PATTERNS[i]}  (eye-vis-v2)   │
                          │  expected_word = PRBS_lookahead16 ⊕ {tag,tag} (target-a)    │
                          │  is_match → match_count ++ (sat 31)                         │
                          │  mismatch → match_count = 0                                 │
                          │  lane_locked[i] = (match_count >= LOCK_THRESH)              │
                          │  v2: also mismatch_pulse[i] and crc_err_cnt[i][7:0]         │
                          └────────────┬────────────────────────────────────────────────┘
                                       │ lane_locked[7:0]
                                       ▼  (also feeds calibrator above)
              SWI_LANE_STATUS @ slot 0x108 [7:0]   (apb_clk 2-flop synced from rx_link_clk)
                                                              ←-- cr_pkt_seen_rx [23] from WlinkGenericFCSM_6
                                                              ←-- crack_pkt_seen_rx [24]
                                                              ←-- fcsm_state [19:17]
                                                              ←-- calibration_done [16]
                                                              ←-- lane_fault [15:8]
```

Notes on the control wrap-around:
- `role_locked_o` is just `role_lock_reg` (W1S, POR-only clear). It does NOT auto-latch from autoneg — SW must write `ROLE_CFG[1]=1` (APB 0x40020080, alias path described in `~/.claude/projects/.../user_dam1n19`'s role_lock_semantics memory).
- The calibrator's `role_locked` input is `role_lock_reg & autocal_enable_w` (`axi_chiplet_controller.sv:1363-1364`). Disabling AUTOCAL means the calibrator stays in S_IDLE, never asserts `training_mode_o`, so all three OR contributions to `swi_training_mode_w` are zero unless SW writes slot0[0]=1.
- `cr_pkt_seen` / `crack_pkt_seen` are sticky in `rx_link_clk` (FC.scala:185-188) — they CLEAR when `en_ff2_rx==0`, i.e. when peer-synced `swi_enable_rx` drops.

---

## 3. Signal genealogy table

| Signal | Width | Driver | Consumer | SW write to change |
|---|---|---|---|---|
| `swi_training_mode_in` | 1 | axi_chiplet_controller.sv:721 `swi_training_mode_r <= ctrl_reg_wdata[0]` | OR'd in WavD2DGpio.v:417 to drive each WavD2DGpioTx.io_training_mode and the WavD2DGpioRx training-byte hunt enable indirectly | APB write `0x44032100`, pwdata[0]=1 |
| `swi_recal` | 1 | axi_chiplet_controller.sv:722 `swi_recal_r <= ctrl_reg_wdata[1]` | tidelink_phy_align_calibrator.sv:217 `.swreset (swi_recal_r)` — falling edge triggers a fresh sweep | APB write `0x44032100`, pwdata[1] |
| `swi_phase_offset[3:0]` (global, legacy) | 4 | WavD2DGpio.v:305 `reg [3:0] swi_phase_offset` (PHY_CTRL bits[20:17]) | WavD2DGpio.v:513 OR'd per-lane with `io_swi_phase_offset_in[4*N +: 4]` → each lane's WavD2DGpioRx.io_phase_offset | APB write to Wlink's PHY_CTRL reg, pwdata bits[20:17] |
| `swi_phase_offset_r[31:0]` (per-lane, §9.7) | 32 | axi_chiplet_controller.sv:733 slot 0x118 (`ctrl_reg_addr[2:0]==3'h6`) | OR'd with `cal_phase_offset_w` at axi_chiplet_controller.sv:1428 → `swi_phase_offset_in` to Wlink/WavD2DGpio | APB write `0x44032118` |
| `swi_bit_slip_lo_r[23:0]` | 24 | axi_chiplet_controller.sv:724 slot 0x108 (`ctrl_reg_addr[2:0]==3'h1`) | OR'd with `cal_bit_slip_w` at axi_chiplet_controller.sv:1422 → `swi_bit_slip_in` to WavD2DGpio | APB write `0x44032108` |
| `swi_enable` | 1 | Wlink internal reg (default 1), Region-4 0x080 PHY_CTRL bit[0] | gates each FCSM's `en_ff2_tx`/`en_ff2_rx` (FC.scala:207) — when low, FCSM holds at IDLE and `cr_pkt_seen_rx` CLEARS | APB write to PHY_CTRL via tidelink_top swi_enable guard (always forced HIGH on swreset writes, tidelink_top.sv:1729) |
| `cal_done` (calibration_done) | 1 | tidelink_phy_align_calibrator.sv:927 `(cur_state == S_DONE)` | axi_chiplet_controller.sv:668 → SWI_LANE_STATUS[16]; also the integration spec calls for gating swi_lltx_enable with it, but in this RTL it is RO observability only | RO — driven by FSM |
| `cal_in_progress` (≈ `training_mode_o`) | 1 | tidelink_phy_align_calibrator.sv:925 = (S_ARM ∥ S_SWEEP ∥ S_HOLD) on eye-vis-v2; +S_PROBE/S_FINALIZE on target-a-oddr | OR-merge into `swi_training_mode_w` (axi_chiplet_controller.sv:1429) | RO — driven by FSM |
| `lane_locked[7:0]` | 8 | tidelink_lane_checker.sv:124 per-lane | calibrator input + SWI_LANE_STATUS[7:0] | RO |
| `lane_fault[7:0]` | 8 | tidelink_phy_align_calibrator.sv:931 = `lane_fault_q` | SWI_LANE_STATUS[15:8] | RO; cleared by trigger_now (next sweep arm) |
| `cr_pkt_seen_rx` (sticky) | 1 | WlinkGenericFCSM_6.v:870 `cr_pkt_seen_rx <= pkt_is_cr_pkt \| cr_pkt_seen_rx;` (gated by `en_ff2_rx` clearing — local override made it fully sticky on FPGA, see lines 854-870) | SWI_LANE_STATUS[23] via apb_clk sync | RO; clears only on `~en_ff2_rx` (swi_enable→0) or POR |
| `crack_pkt_seen_rx` (sticky) | 1 | WlinkGenericFCSM_6.v:877 | SWI_LANE_STATUS[24] | same as `cr_pkt_seen_rx` |
| `fcsm_state[3:0]` (really [2:0] surfaced) | 3 | FC.scala state register | SWI_LANE_STATUS[19:17] | RO |
| `training_mode_o` (= calibrator output) | 1 | tidelink_phy_align_calibrator.sv:925 | OR-merge into `swi_training_mode_w` (axi_chiplet_controller.sv:1429) — so SW slot0[0] OR'd with calibrator output drives the PHY. The OR-merge is the answer to the "is it OR'd?" prompt question | RO |

---

## 4. The TX path (per lane)

`WavD2DGpio` (the wrapper) instantiates 8 `WavD2DGpioTx` modules at `local_overrides/WavD2DGpio.v:516-635`. Each instance is parameterised with a hard-wired per-lane training byte:

```verilog
// local_overrides/WavD2DGpio.v:516-530 (lane 0)
WavD2DGpioTx gpiotx_0 (
    ...
    .io_link_data        (gpiotx_0_io_link_data),
    .io_training_mode    (effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern (8'hA3),
    ...
);
```

Lanes 0..7 patterns are `A3 B5 C9 D3 65 4B 59 2D` — chosen for period-8 under right-rotation so byte alignment is unambiguous (`local_overrides/WavD2DGpio.v:342-349`). Lane N's data tap is `io_link_tx_tx_link_data[16*N+15 : 16*N]` (lines 258-273); only that 16-bit word is visible per cycle to lane N's serialiser.

Inside `WavD2DGpioTx` (`local_overrides/WavD2DGpioTx.v`), the per-lane training mux operates on a 4-bit free-running `count` clocked by `io_clk` (= internal high-speed clock `hsclk`), reset to `4'hf`:

```verilog
// local_overrides/WavD2DGpioTx.v:124-141
reg io_training_mode_q;
always @(posedge io_clk ...) begin
  if (...) io_training_mode_q <= 1'b0;
  else if (count == 4'hf) io_training_mode_q <= io_training_mode;
end
wire io_training_mode_mux = WORD_ALIGN_MUX ? io_training_mode_q : io_training_mode;
...
// eye-visibility-v2: constant {pattern,pattern}
wire [15:0] _link_data_eff = io_training_mode_mux
                              ? {io_training_pattern, io_training_pattern}
                              : io_link_data;
```

On `feat/target-a-oddr` the same wrapper produces a PRBS-7 ⊕ {tag,tag} stream. The LFSR advances 16 bits per word-period at `count==4'hf`:

```verilog
// [target-a-oddr] local_overrides/WavD2DGpioTx.v ≈ lines 207-238
always @(posedge io_clk ...) begin
  if (reset) prbs_lfsr <= prbs_seed;        // = (pattern>>1)[6:0] | 7'h01
  else if (count == 4'hf) prbs_lfsr <= adv_16;
end
wire [15:0] prbs_word_tagged = prbs_word_raw
                               ^ {io_training_pattern, io_training_pattern};
wire [15:0] training_word = USE_PRBS_TRAINING ? prbs_word_q
                                              : {io_training_pattern, io_training_pattern};
wire [15:0] _link_data_eff = io_training_mode_mux ? training_word : io_link_data;
```

The 16:1 serialiser is just the chain of comparators at lines 158-171 of `WavD2DGpioTx.v` (Chisel-generated `_GEN_*`); `io_pad = 4'hf == count ? tx_pad_array_15 : _GEN_14` walks one bit out per `io_clk`. Therefore for the eye-visibility-v2 branch, the answer to "how is `io_link_data` built — literally `{tag, tag}`?" is YES at the serialiser-input source: `_link_data_eff = {io_training_pattern, io_training_pattern}` during training. For target-a-oddr it is `prbs_word_q = PRBS16 ⊕ {pattern,pattern}` — so the period is no longer 8 cycles; it is 127 PRBS-7 bits / 16 = ~7.94 words, coprime with the word size.

The output `io_pad_clk` is `hs_clk_gated_wcg_io_clk_out` (i.e. `hsclk` gated by `clk_en_qual`, line 193, 211-216). `io_link_clk` is `~count[3]` (line 201).

---

## 5. The RX path (per lane)

`WavD2DGpioRx` (`local_overrides/WavD2DGpioRx.v`) has three clocks the generate block resolves at synth (`w_cnt_clk`, `w_pad_clk`, `w_lnk_clk`, lines 289-308). On FPGA (USE_CLKBUF=1) all three are BUFG-fed from `io_pad_clk` or `~adj_count[3]`; on sim/ASIC they pass through the WavClockMux chain.

`count` is the 4-bit cycle counter, free-running mod-16 on `w_cnt_clk` (= pad_clk path):

```verilog
// local_overrides/WavD2DGpioRx.v:486-492 (T3A_PASSTHRU branch — the FPGA default)
always @(posedge w_cnt_clk or posedge io_por_reset) begin
  if (io_por_reset) count <= 4'hf;
  else              count <= count + 4'h1;
end
```

(USE_T3A=1 branch additionally bit-slips `count` once by the matching rotation of TRAINING_BYTE — lines 400-466. On `feat/target-a-oddr`+`feat/eye-visibility-v2` builds the FPGA wrapper sets USE_T3A=1 with TRAINING_BYTE per lane, but `T3A_CONTINUOUS=0` (line 69) so the realign is one-shot — same as legacy free-run after the initial slip.)

The 4-bit `adj_count = count + io_phase_offset` rotates which `pad_clk_rx` cycle writes which position of the 16-bit captured word. Each bit-position has its own conditional:

```verilog
// local_overrides/WavD2DGpioRx.v:180-201 (lines reproduced for one bit)
wire [3:0] adj_count = count + io_phase_offset;
wire link_data_pad_clk_in_0 = adj_count == 4'h0 ? io_pad : link_data_pad_clk[0];
wire link_data_pad_clk_in_1 = adj_count == 4'h1 ? io_pad : link_data_pad_clk[1];
... (same shape through bit 15)
```

The 16-bit `link_data_pad_clk[15:0]` register is clocked on `w_pad_clk` (the pad clock, lines 495-501):

```verilog
always @(posedge w_pad_clk or posedge io_por_reset) begin
  if (io_por_reset) link_data_pad_clk <= 16'h0;
  else              link_data_pad_clk <= {link_data_pad_clk_hi, link_data_pad_clk_lo};
end
```

The link clock is `~adj_count[3]` (so transitions when `adj_count` rolls through 8 / 0 — twice per 16-cycle word). The crossing into the link domain captures `link_data_pad_clk` into `link_data_reg` (lines 502-508):

```verilog
assign io_link_clk_mux_io_i_a = ~adj_count[3];           // line 274
...
always @(posedge io_link_clk or posedge io_por_reset) begin
  if (io_por_reset) link_data_reg <= 16'h0;
  else              link_data_reg <= link_data_pad_clk;
end
```

The 3-bit `io_bit_slip` right-rotates the captured 16-bit word AFTER `link_data_reg`:

```verilog
// local_overrides/WavD2DGpioRx.v:253-254
wire [31:0] _link_data_rep = {link_data_reg, link_data_reg};
assign io_link_data = _link_data_rep[{2'b00, io_bit_slip} +: 16];
```

So `io_link_data[15:0]` is the slip-rotated, phase-offset-aligned 16-bit recovered word. This is the value the lane_checker sees on `lane_data[16*N +: 16]`.

Important: `io_phase_offset` is a per-lane SAMPLE-POSITION rotation within the 16-bit deserialiser window — NOT a sub-bit-cell timing adjustment. The actual sub-bit timing is governed by `IDELAYE2` taps loaded from the SAME phase value (`tidelink_idelay_rx`, instantiated at axi_chiplet_controller.sv:1449-1462) when USE_IDELAY=1.

---

## 6. The `lane_checker`

### 6.1 eye-visibility-v2 (current branch)

`src/rtl/tidelink_lane_checker.sv:24-72` defines `tidelink_lane_checker_single`. The expected pattern is a constant {tag, tag} 16-bit word:

```systemverilog
// src/rtl/tidelink_lane_checker.sv:42-43
wire [15:0] expected_word = {expected_byte, expected_byte};
wire        is_match      = (word_in == expected_word);
```

The 16-bit-wide compare (rather than byte-wide) is deliberate — see the file's own header at lines 13-16: with right-rotation by 0..7 applied via `io_bit_slip` BEFORE the checker sees the word, only the slip value that exactly inverts the channel's misalignment makes BOTH halves of the 16-bit word read as `tag`.

Lock detection is a saturating consecutive-match counter:

```systemverilog
// src/rtl/tidelink_lane_checker.sv:45-56
always_ff @(posedge clk or posedge rst) begin
  if (rst)            match_count <= 5'd0;
  else if (is_match) begin
    if (match_count < 5'd31) match_count <= match_count + 5'd1;
  end else begin
    match_count <= 5'd0;        // ← any single mismatch drops match_count to 0
  end
end
assign locked         = (match_count >= LOCK_THRESH[4:0]);
assign mismatch_pulse = ~is_match;
```

`lane_locked[i]` is therefore (a) NOT sticky — a single mismatch resets `match_count` to 0 and after one cycle `locked` deasserts (b) gated effectively by `training_mode` only because the expected word is a constant; during live FC traffic `is_match` happens to be true only when the FC data accidentally equals `{tag,tag}`. There is no explicit `training_mode` AND-gate at the checker — the only gates are `clk` and `rst`. The instance's `rst` is `~role_locked` (axi_chiplet_controller.sv:1334), so the checker runs as soon as `role_lock_reg` latches. There is no `cal_running` gating, no `swi_enable` gating, no `cal_done` gating.

The 8-lane wrapper hard-codes the expected per-lane byte:

```systemverilog
// src/rtl/tidelink_lane_checker.sv:109-129
localparam logic [7:0] PATTERNS [0:7] = '{
    8'hA3, 8'hB5, 8'hC9, 8'hD3,
    8'h65, 8'h4B, 8'h59, 8'h2D
};
for (i = 0; i < 8; i++) begin : g_lane
    tidelink_lane_checker_single #(.LOCK_THRESH(LOCK_THRESH)) u_check (
        .clk           (clk),
        .rst           (rst),
        .word_in       (lane_data[16*i +: 16]),
        .expected_byte (PATTERNS[i]),
        .locked        (lane_locked[i]),
        .mismatch_pulse(mismatch_pulse[i]),
        .crc_err_cnt_clr(crc_err_cnt_clr),
        .crc_err_cnt   (crc_err_cnt_w[i])
    );
end
```

`mismatch_pulse[i]` and `crc_err_cnt[i]` (a saturating 8-bit mismatch counter cleared by `crc_err_cnt_clr`) are NEW v2 outputs not present on `feat/target-a-oddr` — they exist for the eye-toolkit. They do NOT change the lock criterion.

### 6.2 target-a-oddr (the bitstream actually loaded)

`[target-a-oddr] src/rtl/tidelink_lane_checker.sv` instead runs a per-lane PRBS-7 sync-by-prediction predictor:

```systemverilog
// [target-a-oddr] tidelink_lane_checker.sv: tidelink_lane_checker_single
tidelink_prbs7_lookahead16 u_la (
    .state_in (prbs_state),
    .word_out (predicted_word),
    .state_out(prbs_next_state)
);
wire [15:0] expected_word = predicted_word ^ LANE_TAG_WORD;
wire        is_match      = (word_in == expected_word);
wire [15:0] word_stripped = word_in ^ LANE_TAG_WORD;
wire [6:0]  reseed_state  = word_stripped[6:0] | 7'h01;

always_ff @(posedge clk or posedge rst) begin
  if (rst)               { prbs_state <= PRBS_SEED_INIT; match_count <= 0; }
  else if (is_match)     { prbs_state <= prbs_next_state; match_count++ (sat 31); }
  else                   { prbs_state <= reseed_state; match_count <= 0; }
end
assign locked = (match_count >= LOCK_THRESH);
```

So on `target-a-oddr` the lock criterion is `match_count >= LOCK_THRESH=16` consecutive predicted-PRBS-word matches. The same single-mismatch-drops-to-0 semantics applies. No `mismatch_pulse`, no `crc_err_cnt`.

---

## 7. The calibrator FSM

### 7.1 States (eye-visibility-v2)

```
typedef enum logic [3:0] {
    S_IDLE   = 4'd0,
    S_ARM    = 4'd1,
    S_SWEEP  = 4'd2,
    S_FINISH = 4'd3,
    S_DONE   = 4'd4,
    S_CANCEL = 4'd5,
    S_HOLD   = 4'd6     // T3.2 peer-aware hold
} state_t;
```

ASCII state diagram:

```
                  trigger_now
        +────────────────────────────────────┐
        │                                    ▼
  S_IDLE ─────── trigger_now ─────►  S_ARM ────► S_SWEEP
   ▲                                  │            │
   │                          swreset │            │ swreset → S_CANCEL
   │                                  ▼            │
   │                            S_CANCEL          (sweep_exhausted OR
   │                              │                early_exit & all_done)
   │                              │ !swreset       │
   │                              ▼                ▼
   │                            S_ARM           S_FINISH
   │                                            │   │
   │                              sweep_success │   │ !sweep_success & retry_exhausted
   │                              & !tb_early   │   │   → S_DONE
   │                                            ▼   ▼
   │                                    S_HOLD            (else !role_locked → S_DONE,
   │                                       │              else role_locked → S_ARM auto-retry)
   │           hold_ctr>=HOLD_MAX           │
   │  ◄──────  or !role_locked              │
   │                                       ▼
   └────────────────── S_DONE ◄── (S_FINISH sweep_success & tb_early_exit_force_q)
                       ▲ trigger_now
                       │
```

Output drivers (`src/rtl/tidelink_phy_align_calibrator.sv:916-929`):

```systemverilog
always_comb begin
    if (apb_override_enable) begin
        bit_slip         = apb_bit_slip_override;
        phase_offset     = 32'h0;
        training_mode    = 1'b0;
        calibration_done = 1'b1;
    end else begin
        bit_slip         = bit_slip_internal;
        phase_offset     = phase_offset_internal;
        training_mode    = (cur_state == S_ARM) || (cur_state == S_SWEEP)
                        || (cur_state == S_HOLD);
        calibration_done = (cur_state == S_DONE);
    end
end
```

| State | `training_mode` | `calibration_done` | `cal_in_progress` (≈ `training_mode`) |
|---|---|---|---|
| S_IDLE | 0 | 0 | 0 |
| S_ARM | 1 | 0 | 1 |
| S_SWEEP | 1 | 0 | 1 |
| S_FINISH | 0 | 0 | 0 |
| S_DONE | 0 | 1 | 0 |
| S_CANCEL | 0 | 0 | 0 |
| S_HOLD | 1 | 0 | 1 |

Only `S_DONE` asserts `calibration_done`. It is reached from `S_FINISH` when `sweep_success && tb_early_exit_force_q` (sim), `retry_exhausted`, or `!role_locked`. The "normal HW production" path is `S_FINISH → S_HOLD → S_DONE` once `hold_ctr` saturates at `HOLD_MAX = 8*128*DWELL_CYCLES - 1` (`HOLD_CYCLES = 8*128*64 = 65536` link_clk cycles at default = ~262 µs at 250 MHz).

`swi_recal` is wired to the FSM's `swreset` input (axi_chiplet_controller.sv:1379). A falling edge while `role_locked` is high re-triggers a sweep via `trigger_now = role_locked_rise | (swreset_fall & role_locked)` (line 315). While `swreset` is high, the FSM moves to `S_CANCEL` from any of S_ARM/S_SWEEP/S_HOLD; `S_CANCEL` then waits for `~swreset` and re-arms to `S_ARM`.

`AUTOCAL_ENABLE` is a parameter on the calibrator's enclosing module (`axi_chiplet_controller.sv:29`). It gates the calibrator's `role_locked` input at axi_chiplet_controller.sv:1364 (`calibrator_role_locked = role_locked & autocal_enable_w`). When disabled, the calibrator stays in S_IDLE and its outputs are constant zeros — `training_mode_o=0`, `calibration_done=0`. tidelink_top.sv:1744 hard-codes `AUTOCAL_ENABLE(1'b1)` so the calibrator is always active in the TideLink integration; the AUTOCAL=0 lift documented in the user's memory (`autocal0_hw_workaround_2026_05_27`) is a *parameter override at the integration scope* — relevant only as a known-good workaround, not the current default.

### 7.2 Additional states on `target-a-oddr`

`feat/target-a-oddr` adds three states:

- `S_PROBE = 4'd7` — dwells DWELL_CYCLES at (slip=0, phase=0), records per-lane `probe_lane_pass_q[i]` as an advisory fallback for S_FINALIZE.
- `S_FINALIZE = 4'd8` — single-cycle eye-centre selection. Latches `slip[i]/phase[i]` to the centre of the best contiguous run of phases that passed `lane_score >= LOCK_THRESH` and was at least `min_lock_dwells_eff` (default 4) phases wide.
- `S_VALIDATE = 4'd9` — entered from S_HOLD after HOLD_CYCLES. `training_mode` is DEASSERTED (per `[target-a-oddr] tidelink_phy_align_calibrator.sv:1162-1167`). Waits for `cr_pkt_seen_i` (a new input added on that branch — fed from the FCSM's `obs_cr_pkt_seen_rx` sync). If `cr_pkt_seen_i` asserts within `VALIDATION_TIMEOUT` → `S_DONE`; otherwise re-arm sweep.

ASCII state diagram (target-a-oddr — additions in CAPS):

```
S_IDLE → S_ARM → S_PROBE → S_SWEEP → S_FINALIZE → S_FINISH → S_HOLD → S_VALIDATE → S_DONE
                                              │           │       │            │
                                              │           │       │       cr_pkt_seen_i = 0
                                              ▼ swreset   ▼       ▼     after VAL_MAX → S_ARM
                                          S_CANCEL    auto-retry  …
```

Training-mode output gating (target-a-oddr): training_mode=1 in **S_ARM, S_PROBE, S_SWEEP, S_FINALIZE, S_HOLD** — and EXPLICITLY 0 in S_VALIDATE. This is the structural difference: target-a-oddr will drop training_mode for the validation window even before reaching S_DONE.

---

## 8. The FCSM (Wlink FC autoneg)

Source of truth: `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala` (the generated Verilog is in `local_overrides/WlinkGenericFCSM_6.v`).

State enum:

```scala
// FC.scala:38-47
object WlinkGenericFCState extends ChiselEnum {
  val IDLE          = Value(0.U)
  val SEND_CREDITS1 = Value(1.U)
  val SEND_CREDITS2 = Value(2.U)
  val LINK_EN_WAIT  = Value(3.U)
  val LINK_IDLE     = Value(4.U)
  val LINK_DATA     = Value(5.U)
  val SEND_ACK      = Value(6.U)
  val SEND_NACK     = Value(7.U)
}
```

Note: this is 3 bits, not 4. There is no SEND_CR_PKT/SEND_CRACK state pair distinct from SEND_CREDITS1/2. The naming convention is "SEND_CREDITS{1,2}" — the first sends CR, the second sends CRACK.

State transitions (FC.scala:444-498):

| Cur | Trigger | Next |
|---|---|---|
| IDLE (0) | `en_ff2_tx` (i.e. peer-synced swi_enable=1) | SEND_CREDITS1 (1) |
| SEND_CREDITS1 (1) | `ll_tx.advance && (crack_pkt_seen_tx \|\| cr_pkt_seen_tx)` | SEND_CREDITS2 (2) |
| SEND_CREDITS2 (2) | `ll_tx.advance && crack_pkt_seen_tx` | LINK_EN_WAIT (3) |
| LINK_EN_WAIT (3) | `count==0` | LINK_IDLE (4) |
| LINK_IDLE (4) | NACK request → SEND_NACK; ACK request → SEND_ACK; data valid → LINK_DATA | … |

**Critical answer to the prompt question: "what makes FCSM advance from SEND_CR_PKT (1) → LINK_IDLE (4)?"**

The transition is NOT direct. It passes through SEND_CREDITS2 and LINK_EN_WAIT:

```scala
// FC.scala:457-498 (paraphrased)
.elsewhen(state === SEND_CREDITS1) {
    when(ll_tx.advance) {
        when(crack_pkt_seen_tx || cr_pkt_seen_tx) {       // (*)
            nstate := SEND_CREDITS2
        }.otherwise {
            // resend cr_pkt
        }
    }
}.elsewhen(state === SEND_CREDITS2) {
    when(ll_tx.advance) {
        when(crack_pkt_seen_tx) {                          // (**)
            nstate := LINK_EN_WAIT
            count_in := link_en_wait
        }.otherwise {
            // resend crack_pkt
        }
    }
}.elsewhen(state === LINK_EN_WAIT) {
    when(count === 0.U) { nstate := LINK_IDLE }
}
```

So:
- (*) **SEND_CREDITS1 → SEND_CREDITS2 requires `cr_pkt_seen_tx || crack_pkt_seen_tx`** — i.e. "I have seen a CR or CRACK from the peer". `cr_pkt_seen_tx` is the TX-domain demet of the RX-domain `cr_pkt_seen_rx` sticky bit (FC.scala:403-404, `WavDemetReset(cr_pkt_seen_rx)`). The sticky reg is set on `pkt_is_cr_pkt` (RX data-id == cr_id, default 0x10) — see FC.scala:185-208 and WlinkGenericFCSM_6.v:854-877.
- (**) **SEND_CREDITS2 → LINK_EN_WAIT requires `crack_pkt_seen_tx`** alone.
- The peer's `cr_pkt_seen` only latches if its RX is correctly decoding our CR pkt bytes — i.e. our TX side is shipping known training pattern AND the peer's RX has been calibrated. This is the structural coupling between training_mode and FCSM advancement: training_mode is NOT a direct gate; instead, calibration via training_mode is what eventually permits CR/CRACK byte decoding, which then propagates through the seen-flags.

**`lane_locked == 8'hFF` is NOT a state transition gate anywhere in FC.scala.** It is *observability only* (SWI_LANE_STATUS[7:0]) and a driver of the calibrator's own sweep — there is no place where the FCSM consults `lane_locked` to decide IDLE→SEND_CREDITS1 or SEND_CREDITS1→…

The Wlink IS, however, held in POR-reset until `role_locked`: `wlink_por_reset = ~poresetn | ~role_locked` (axi_chiplet_controller.sv:778). So nothing in the FCSM starts until role_lock latches.

The FCSM is gated by `swi_enable` (Wlink Region-4 PHY_CTRL bit[0]) — when `swi_enable=0` the en_ff2_tx/en_ff2_rx synchronisers drive 0, holding IDLE and CLEARING `cr_pkt_seen_rx`/`crack_pkt_seen_rx` (see local_overrides/WlinkGenericFCSM_6.v:854-877 — the local override made the seen flags fully sticky except during `en_ff2_rx==0`).

---

## 9. End-to-end "what happens when I write slot0 = …"

### 9.1 SW writes `*0x44032100 = 0x1` (slot0 bit[0] = swi_training_mode = 1)

1. APB write decodes at axi_chiplet_controller.sv:720-723; `swi_training_mode_r <= 1'b1` on the next `apb_clk`.
2. `swi_training_mode_w = cal_training_mode_w | swi_training_mode_r` (line 1429) goes high.
3. Wlink's `swi_training_mode_in` rises; inside `WavD2DGpio` (local_overrides/WavD2DGpio.v:417, 438, 441):
   - `input_training_mode_w = io_swi_training_mode_in | swi_training_mode = 1`
   - `effective_training_mode_tx_raw = 1`
   - `effective_training_mode_tx = 1` (tdif-03 path — per-lane latch is INSIDE WavD2DGpioTx)
4. Within ≤16 `io_clk` cycles each `gpiotx_N.io_training_mode_q` latches at `count==4'hf` and the per-lane mux flips to `{pattern,pattern}` (eye-visibility-v2) or `prbs_word_q` (target-a-oddr). Critically, the flip lands at the word boundary, not mid-word.
5. The peer's `WavD2DGpioRx` sees the new bit stream. Within `LOCK_THRESH = 16` matched 16-bit words, the local `tidelink_lane_checker` for each lane (assuming the channel is already calibrated) asserts `lane_locked[i]`.
6. `SWI_LANE_STATUS@0x4403_2108` reads `lane_locked` 2-flop-synced. SW sees ~2..3 apb_clk delay + the 16 matched words.
7. Calibrator: nothing happens because `cal_calibration_done_w` may already be high (S_DONE). But `cal_training_mode_w = 0` while `swi_training_mode_r = 1` so the `training_mode_w = 1` — i.e. the OR-merge means SW alone CAN drive training mode without help from the calibrator.

NOTE: with the FPGA bring-up calibrator default `AUTOCAL_ENABLE=1`, the calibrator was already in S_DONE before this write; SW asserting `swi_training_mode_r` does NOT trigger a new sweep (the calibrator's trigger is `role_locked_rise | swreset_fall`, neither of which fires on `swi_training_mode_r`).

### 9.2 SW writes `*0x44032100 = 0x3` (slot0[0]=swi_training_mode=1, slot0[1]=swi_recal=1)

Same as 9.1, plus:
1. `swi_recal_r <= 1` (line 722).
2. Drives calibrator's `swreset = 1` (line 1379). On the next link_rx_clk:
   - Edge detect: `swreset_q <= 1`. No edge yet (going high, not falling).
   - `nxt_state`: from S_DONE/S_HOLD, swreset is not the trigger for S_DONE→anything; from S_ARM/S_SWEEP/S_HOLD it forces S_CANCEL.
3. **But** if the calibrator was in S_DONE, swreset rising does NOT move it: S_DONE only transitions on `trigger_now` (line 497). So while `swi_recal_r=1` the calibrator just sits at S_DONE with `training_mode_o=0`. The PHY still sees `training_mode=1` from `swi_training_mode_r`.

### 9.3 Then SW writes `*0x44032100 = 0x1` (drop swi_recal back to 0)

1. `swi_recal_r <= 0`. The calibrator's `swreset` input has a falling edge.
2. `swreset_fall = ~swreset & swreset_q = 1`. `trigger_now = role_locked_rise | (swreset_fall & role_locked) = 1` (since role_locked is still high).
3. From S_DONE, `if (trigger_now) nxt_state = S_ARM` (line 497). The FSM enters S_ARM next cycle → S_SWEEP one cycle after.
4. `cal_training_mode_w` goes 1; `cal_calibration_done_w` goes 0. The PHY still sees `training_mode=1`; `SWI_LANE_STATUS[16]` (cal_done) drops to 0.
5. The sweep runs for `128 × DWELL_CYCLES = 8192` link_rx_clk cycles (~33 µs at 250 MHz). Per-lane `(slip, phase)` are latched at sweep end; the FSM goes S_FINISH → (sweep_success ? S_HOLD : S_ARM auto-retry).
6. If S_HOLD: stays training_mode=1 for HOLD_CYCLES (~262 µs). Then → S_DONE (eye-visibility-v2) or S_VALIDATE → S_DONE (target-a-oddr).
7. On S_DONE: `cal_training_mode_w=0`, `cal_calibration_done_w=1`. PHY training_mode is still 1 if `swi_training_mode_r=1`, else 0.

### 9.4 SW writes `swi_recal` 0→1→0 cycle WITHOUT touching swi_training_mode

Identical to 9.2+9.3 but `swi_training_mode_r` stays at whatever it was; the calibrator drives `cal_training_mode_w` during S_ARM/S_SWEEP/S_HOLD, so training_mode at the PHY rises and falls with the FSM regardless of SW.

---

## 10. Known gotchas / surprises

1. **`{tag, tag}` is period 8 within the word** — but the period of the 8-bit byte itself under right-rotation is also 8 (PATTERNS were chosen aperiodic under rotation in [1..7]). So phase-offset rotation of where bits land inside the 16-bit word produces exactly ONE matching `io_bit_slip` value per lane on `eye-visibility-v2`. *Why this surprises*: a naive period-4 byte (`0x11`, `0x22` etc., as the spec originally proposed) would have aliased two slip values; the PATTERNS are picked specifically to avoid this. On `target-a-oddr` the PRBS-7 substream has period 127 bits ≈ ~8 words, so the period-2 byte alias is gone but byte alignment STILL only locks at exactly one (slip,phase) combo per lane.

2. **`swi_phase_offset` rotates word-position, not sample timing.** The phase offset changes `adj_count = count + io_phase_offset`, which selects WHICH cycle inside the 16-cycle pad-clock window writes to which bit position of `link_data_pad_clk`. It does NOT advance the sampling EDGE on `pad_clk_rx`. To get sub-bit-cell sampling adjustment, USE_IDELAY=1 must also be wired, and `tidelink_idelay_rx` loads the SAME nibble into IDELAYE2 taps at axi_chiplet_controller.sv:1449-1462. *Why this surprises*: on a build with USE_IDELAY=0, "phase" only shifts which captured cycle goes in which bit position — useless on its own to recover a sub-bit-cell-misaligned lane.

3. **`lane_locked` is non-sticky.** `match_count` resets to 0 on a single mismatch (tidelink_lane_checker.sv:51-53). `lane_locked[i]` therefore drops within ~1 link_rx_clk cycle of a single bit error. *Why this surprises*: if the channel is clean for 100 words then has one mismatch then 100 more clean words, `lane_locked[i]` oscillates 1→0→1 (after 16 more matches). The calibrator's per-dwell `lane_score` counter handles this by counting run-lengths, but the SW-visible `SWI_LANE_STATUS[7:0]` is the raw `lane_locked` — it can flicker.

4. **`cr_pkt_seen` sticky-clear requires `swi_enable=0`, which also stops `rx_link_clk`.** `cr_pkt_seen_rx` clears only when `en_ff2_rx==0`. But `en_ff2_rx` is the rx-domain demet of `swi_enable`, and `swi_enable=0` ALSO drops the link layer's clock-enable signals — the `rx_link_clk` is gated. So the only way to clear `cr_pkt_seen` is a window where (a) swi_enable=0 long enough for the seen-flag to clear, and (b) rx_link_clk is still toggling enough to clock it. The tidelink_top.sv:1729-1736 `harden_swi_apply` mechanism forces `swi_enable=1` on any `swreset=1` write — explicitly to AVOID dropping swi_enable and losing seen-flag state. *Why this surprises*: there is effectively no SW path to "clear cr_pkt_seen and stay running"; a full POR is required.

5. **`lane_locked` does NOT gate the FCSM.** No FC.scala state arm consults `lane_locked` or `calibration_done`. The Wlink is gated only by `wlink_por_reset = ~poresetn | ~role_locked`. So if `role_locked` is up and `swi_enable=1`, the FCSM tries to advance regardless of whether lanes are calibrated — it just won't see clean CR pkts until they are. *Why this surprises*: a "training in progress" status bit does NOT mean the FCSM is held — they run in parallel.

6. **`training_mode_o` from the calibrator IS OR'd with `swi_training_mode_r`.** The merge is at axi_chiplet_controller.sv:1429:
   ```verilog
   wire swi_training_mode_w = cal_training_mode_w | swi_training_mode_r;
   ```
   So SW can FORCE training mode high regardless of FSM state, but cannot FORCE it low when the FSM is asserting it. *Why this surprises*: you cannot stop the calibrator's training emission from SW; the FSM owns the deassert via S_FINISH→S_HOLD→S_DONE timing.

7. **AUTOCAL_ENABLE=0 just freezes the calibrator at S_IDLE.** It does NOT disable the lane_checker (which still observes), and does NOT disable the `swi_training_mode_r` SW path. With AUTOCAL=0 and SW slot0[0]=0, the link runs without ANY training emission — i.e. the FCSM sees random FC bytes interpreted as junk. With AUTOCAL=0 and SW slot0[0]=1, SW can drive training_mode forever; `lane_locked` is then meaningful but no automatic `(slip, phase)` selection ever happens — they hold at whatever boot defaults are. *Why this surprises*: the AUTOCAL_ENABLE=0 workaround documented in `project_autocal0_hw_workaround_2026_05_27` worked by accident-of-defaults, not because disabling the calibrator removes a buggy datapath.

8. **`feat/eye-visibility-v2` is missing S_PROBE/S_FINALIZE/S_VALIDATE.** The HW currently loaded (`feat/target-a-oddr`) advances `S_HOLD → S_VALIDATE → S_DONE`, only entering `S_DONE` if `cr_pkt_seen_rx` fires within `VALIDATION_TIMEOUT`. eye-visibility-v2 has the simpler `S_HOLD → S_DONE` and DOES NOT validate against real FC data. *Why this surprises*: if you rebuild HW on the eye-visibility-v2 branch you LOSE the real-data validation step; lanes that pass training but fail FC decode will be silently accepted.

9. **`tidelink_lane_checker_single.rst` is `~role_locked`, not `~training_mode`.** When training_mode drops (S_DONE), the lane_checker is NOT reset; it just starts seeing live FC bytes and immediately mismatches, dropping `lane_locked[i]`. On `target-a-oddr` the PRBS predictor will also reseed every cycle and keep failing to lock. This is *expected* — `lane_locked` after S_DONE is supposed to be 0 in steady state — but it means `SWI_LANE_STATUS[7:0]` showing 0x00 after S_DONE is NOT evidence of broken link.

---

## 11. Open questions / ambiguities

1. **Why does the eye-visibility-v2 branch lack S_VALIDATE?** Git history shows S_HOLD was added before S_VALIDATE (target-a-oddr commits 2026-05-27). The eye-visibility-v2 RTL appears to have forked at a point where only S_HOLD existed. Either it's intentional (eye-tooling needs determinism; S_VALIDATE would re-arm on cr_pkt timeout, polluting the eye buffer) or an accidental omission during merges. Recommend asking the user to confirm intent before any HW build from eye-visibility-v2.

2. **`tdif-06` (T3A_CONTINUOUS) is OFF by default.** local_overrides/WavD2DGpioRx.v:69 `parameter T3A_CONTINUOUS = 1'b0`. The header comment (line 62-68) claims the default was forced back to 1 (bounded dwell) but the actual code keeps it at 0. The FPGA wrapper threading does not explicitly override this. Need to check `src/rtl/fpga/.../tidelink_vivado_wrapper.v` (not read here) to confirm what value reaches the lanes — the docs and the source disagree.

3. **`cr_pkt_seen_i` input to the calibrator (target-a-oddr)** — is this driven by `obs_cr_pkt_seen_rx_w` synced to `link_rx_clk`? The 2-flop sync visible at axi_chiplet_controller.sv:673-674 is into `apb_clk`, not `link_rx_clk`. If the calibrator's `cr_pkt_seen_i` is fed from the apb_clk sync, it crosses BACK into link_rx_clk without an explicit synchroniser — should be checked at the calibrator's port map in the target-a-oddr axi_chiplet_controller.sv.

4. **`io_clk` vs `app_clk` vs `link_clk` vs `link_rx_clk`.** The calibrator and lane_checker live on `phy_link_rx_rx_link_clk_w` (axi_chiplet_controller.sv:1333, 1367). This is the RECOVERED clock derived per-lane as `~adj_count[3]` — divided down ×16 from `pad_clk_rx`. With pad_clk_rx ~12.5 MHz (FPGA) the recovered link_rx_clk is ~12.5 MHz / wait actually `pad_clk_rx` is the high-speed bit clock so ~200 MHz; link_rx_clk is then ~12.5 MHz. The HOLD_CYCLES = 65536 link_rx_clk cycles at 12.5 MHz = ~5.2 ms, not the ~262 µs I quoted in §7 (that was based on 250 MHz). The actual HOLD duration on the FPGA target depends on the bit clock — the docs' 250 MHz reference is for ASIC. Worth re-confirming with the user.

5. **Wlink's `swi_lltx_enable`** — the calibrator's header (lines 64-69) says the integrator MUST wire `swi_lltx_enable & calibration_done`. I could not find a place in axi_chiplet_controller.sv or Wlink.v where `calibration_done` actually gates `swi_lltx_enable`. The wiring appears to be: `wlink_por_reset = ~poresetn | ~role_locked`, with no calibration_done qualifier. So the calibrator's contract documented in its header is NOT enforced at the integration scope. The FCSM can therefore start sending CR pkts BEFORE calibration_done = 1, which (because TX of CR is independent of training_mode at the bit level — the FCSM's link_data path is replaced wholesale by training pattern when training_mode=1) means CR pkts are emitted DURING training and silently overwritten. This may be the structural root of the cr_pkt_seen latching gap during initial bring-up.

---

## Appendix — file/line references quickly

- `src/rtl/tidelink_lane_checker.sv` (eye-visibility-v2): 1-142
- `src/rtl/tidelink_phy_align_calibrator.sv` (eye-visibility-v2): 1-933
- `src/rtl/local_overrides/WavD2DGpio.v`: 305 (swi_phase_offset reg), 350-355 (effective_bit_slip OR), 416-441 (training_mode hold), 516-635 (per-lane TX instantiation), 636-700+ (per-lane RX instantiation)
- `src/rtl/local_overrides/WavD2DGpioRx.v`: 175-201 (adj_count + per-bit mux), 274 (link_clk = ~adj_count[3]), 253-254 (bit_slip rotation), 400-466 (T3A comma hunt FSM), 486-492 (passthru count free-run)
- `src/rtl/local_overrides/WavD2DGpioTx.v`: 124-141 (training_mode_q), 137-141 (training mux on eye-visibility-v2)
- `[target-a-oddr] src/rtl/local_overrides/WavD2DGpioTx.v`: ~155-238 (PRBS-7 LFSR + lane-tag XOR)
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v`: 854-877 (cr/crack sticky); state arms in FC.scala 444-498
- `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`: 38-47 (state enum), 444-498 (autoneg transitions), 185-208 (seen-flag latches)
- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`: 564-595 (Region 8 reg defs), 700-738 (Region 8 write decode), 740-761 (Region 8 read mux), 1332-1349 (lane_checker instantiation), 1366-1407 (calibrator instantiation), 1414-1429 (OR-mux of cal vs SW), 778 (wlink_por_reset)
- `src/rtl/tidelink_top.sv`: 1729-1736 (swi_enable harden), 1743-1750 (AUTOCAL_ENABLE=1), 1992 onwards (eye plumbing)

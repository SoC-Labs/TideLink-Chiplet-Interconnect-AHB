# TideLink Training Module — Rewrite Spec (2026-05-28)

Sister doc to [TRAINING_MODULE_ARCHITECTURE_2026_05_28.md](TRAINING_MODULE_ARCHITECTURE_2026_05_28.md), which describes the EXISTING `feat/eye-visibility-v2` implementation. This spec describes its proposed replacement.

Scope: per-lane training pattern, RX matcher, lock detector, per-lane noise observability, calibrator scoring metric. Does NOT change FCSM, `role_lock` semantics, APB region layout (only adds slots), or RX deserialiser datapath (`io_bit_slip`, `io_phase_offset` rotators remain). It DOES replace [tidelink_lane_checker.sv](../src/rtl/tidelink_lane_checker.sv) end-to-end and changes the calibrator's per-dwell scoring inputs.

---

## 1. Goals

1. Replace brittle exact-match with a noise-tolerant matcher (Hamming distance, ≤3 bit-flips per word survive).
2. Replace byte-periodic `{tag,tag}` training words (which can only resolve phase modulo 8) with full-16-bit aperiodic patterns (one unambiguous phase per 16-bit period).
3. Add a per-lane raw noise-floor metric readable from APB, so the eye-toolkit can see HOW wrong, not just THAT wrong.
4. Add a per-lane SW-writable lock threshold so a degraded link can keep moving data with fewer surviving lanes by relaxing per-lane stringency.
5. Add 3-of-3 majority-vote denoising as a cheap inner code, primarily to act as a structured-vs-random error discriminator.
6. Make calibrator sweep scoring continuous (Hamming distance) instead of binary (exact-match count) — more robust to noise during sweep.

---

## 2. Per-lane training patterns

### 2.1 Why not XOR-tag a single pattern

The earlier suggestion to use `lane[i] = 0x04EB ^ {tag_i, tag_i}` does NOT preserve the matcher guard band. The matcher's correct-phase property is unchanged (any constant XOR commutes through `popcount(rx ^ const)`), but the cyclic autocorrelation property — `popcount(P ^ rot_k(P)) ≥ 8` for k ∈ {1..7, 9..15} — does not survive arbitrary XOR.

Algebra: let `W = P ^ M`. Then `d_k(W) = popcount((P ^ rot_k(P)) ^ (M ^ rot_k(M))) = popcount(A_k ^ B_k)`. For byte-periodic `M = {a,a}`, `rot_8(M) = M` so `d_8(W) = d_8(P) = 14` survives, but for k ∈ {1..7, 9..15}, `B_k ≠ 0` and `d_k(W)` depends on the bit-overlap between `A_k` and `B_k`. Worst case: `B_k = A_k` for some k, giving `d_k(W) = 0` and a false-lock at the wrong phase. Cannot be assumed; would have to be verified per-mask.

### 2.2 Independent per-lane search (recommended)

Run an exhaustive search over all 65536 16-bit patterns under three constraints:

1. **Cyclic guard band:** `min_{k=1..15} popcount(P ^ rot_k(P)) ≥ 8` — unambiguous single phase in 16-bit window.
2. **DC balance:** `weight(P) ∈ [6, 10]`.
3. **Inter-lane separation:** for any two selected patterns `P_i, P_j` and any cyclic shift, `popcount(P_i ^ rot_k(P_j)) ≥ 6` — so a swapped or crossed lane cannot accidentally satisfy the wrong lane's matcher.

Pick the first 8 patterns the search returns that jointly satisfy all three. The result is a constant `PATTERN_W[0..7] : logic [15:0]` baked into the lane checker.

`0x04EB` is one valid pattern by construction (verified by the spec's Python). The search will find others; we want 8.

### 2.3 Alternating P / ~P — cheap neighbour-swap detector

Special case: alternating `PATTERN_W[i] = (i even) ? P : ~P` for a single chosen P (e.g. 0x04EB).

**Cyclic distance properties: identical.** Inversion is `M = 0xFFFF`, the one constant mask for which `rot_k(M) = M` for all k. Therefore `B_k = M ^ rot_k(M) = 0` and `d_k(~P) = d_k(P)` exactly. Min cyclic distance, weight distribution (P=7, ~P=9 — mean 8 across the link, BETTER DC balance than P alone), and the full distance table are preserved.

**Inter-lane separation at correct phase: 16.** `popcount(P ^ ~P) = 16` — maximum possible. Perfect steady-state lane-swap detector at the locked phase.

**Inter-lane separation at rot-8 phase: 2.** `popcount(P ^ rot_8(~P)) = popcount(P ^ ~rot_8(P)) = 16 - d_8(P) = 16 - 14 = 2`. This is INSIDE the matcher's threshold of 3 — a swapped lane would FALSE-LOCK at the rotation-8 phase during sweep. The calibrator must compensate (see §4.1, §7.1).

**Coverage limitation.** Alternating P/~P only detects ODD-distance swaps (1↔2, 3↔4, etc., and 0↔1, 2↔3 etc. depending on parity). Even-distance swaps (0↔2, both = P) are invisible. For full arbitrary-swap detection, the §2.2 independent search is still required.

**When to use which.** The recommendation:
- **Default:** §2.2 independent search (8 distinct patterns). Robust against arbitrary swap.
- **If the search yields <8 patterns at MUTUAL_MIN=6:** fall back to alternating P/~P with §2.2 P for even lanes and ~P for odd, accepting the neighbour-only coverage. Practical PCB and ribbon layouts make neighbour swap the dominant failure mode anyway, so this is a reasonable cost/coverage trade.
- **In either case:** §4.1 dual-distance scoring is mandatory to avoid the rot-8 false-lock.

### 2.4 Bit-order — load-bearing

**Confirmed: orientation matters.** [WavD2DGpioTx.v:158-171](../src/rtl/local_overrides/WavD2DGpioTx.v#L158-L171) serialises `tx_pad_array_15..0` MSB-first under `count[3:0]` (high count first). Therefore bit 15 of `_link_data_eff` is transmitted first on `io_pad`. On the RX side, [WavD2DGpioRx.v:175-201](../src/rtl/local_overrides/WavD2DGpioRx.v#L175-L201) writes incoming bits into `link_data_pad_clk[adj_count]` — the first bit to arrive lands at the highest `adj_count` value. After `link_data_reg <= link_data_pad_clk` (line 502-508) the order in `io_link_data[15:0]` is reconstructed MSB-first.

Therefore the matcher constant must be the pattern AS WRITTEN, `0x04EB` (not bit-reversed `0xD720`). The lane_checker's `expected_word` is `PATTERN_W[i]` directly, no transformation.

Build the search script to verify this on the FPGA before baking by computing per-lane Hamming distance to BOTH `P` and `bit_reverse(P)` for the first 1024 words of training mode and asserting `dist(P) < dist(reversed)`. If the bring-up board ever ships with reversed wiring or a serialiser swap, this assertion fires early.

---

## 3. RX datapath

### 3.1 Capture pipeline (per lane)

Unchanged through `link_data_reg` ([WavD2DGpioRx.v:215-219](../src/rtl/local_overrides/WavD2DGpioRx.v#L215-L219)) and the `io_bit_slip` right-rotation ([lines 253-254](../src/rtl/local_overrides/WavD2DGpioRx.v#L253-L254)). The matcher operates on `io_link_data[15:0]` after slip rotation, exactly where the current checker reads.

### 3.2 48-bit voting capture (NEW)

Inside `tidelink_lane_checker_single`, add a 3-stage shift register on `clk = link_rx_clk`:

```systemverilog
logic [15:0] word_q [0:2];                          // 3 most recent 16-bit words
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        word_q[0] <= '0; word_q[1] <= '0; word_q[2] <= '0;
    end else begin
        word_q[0] <= word_in;
        word_q[1] <= word_q[0];
        word_q[2] <= word_q[1];
    end
end
```

Per-bit 2-of-3 majority vote:

```systemverilog
logic [15:0] voted_word;
genvar b;
generate for (b = 0; b < 16; b++) begin : g_vote
    assign voted_word[b] = (word_q[0][b] & word_q[1][b])
                         | (word_q[0][b] & word_q[2][b])
                         | (word_q[1][b] & word_q[2][b]);
end endgenerate
```

Voting is GATED to training mode. When `training_mode = 0`, the three windows are not the same payload, voting is meaningless, and `voted_word` should not feed the matcher. Use:

```systemverilog
logic [15:0] match_word = training_mode_w ? voted_word : word_in;
```

(The architecture doc §6.1 notes the existing checker is NOT explicitly gated by training_mode and relies on the calibrator's reset. The voted path needs training_mode gating because mid-stream voting on FC payload would corrupt the matcher input. The `training_mode_w` input is already available at the lane_checker's enclosing instance — wire it through.)

### 3.3 Vote alignment

The three captured words `word_q[0..2]` must correspond to three CONSECUTIVE word periods of the same repeating pattern. The training pattern is transmitted continuously back-to-back, and after `lane_locked` the receiver is sampling at the correct phase — so `word_q[0]`, `word_q[1]`, `word_q[2]` are three identical-modulo-noise copies of `PATTERN_W[i]`. No additional alignment logic is needed once initial lock is established. **During the lock-acquisition window**, voting can mix two different phases briefly (3 words ~= 48 bit-clocks); the matcher uses the non-voted `word_in` until lock is reached, then promotes to `voted_word`. Implement as:

```systemverilog
logic vote_enable;
assign vote_enable = locked_pre;       // post-vote lock from previous cycle
logic [15:0] match_word = vote_enable ? voted_word : word_in;
```

The `locked_pre` signal is the lock decision computed last cycle on the non-voted path — a simple one-cycle hysteresis.

---

## 4. Matcher

### 4.1 Dual-distance + inverse-distance computation

```systemverilog
function automatic [4:0] popcount16(input [15:0] x);
    integer i;
    begin
        popcount16 = 5'd0;
        for (i = 0; i < 16; i++) popcount16 = popcount16 + x[i];
    end
endfunction

wire [15:0] err_raw         = word_in    ^ PATTERN_W;            // pre-vote, own pattern
wire [15:0] err_voted       = voted_word ^ PATTERN_W;            // post-vote, own pattern
wire [15:0] err_voted_inv   = voted_word ^ ~PATTERN_W;           // post-vote, INVERSE pattern (free)
wire [4:0]  dist_raw        = popcount16(err_raw);               // 0..16
wire [4:0]  dist_voted      = popcount16(err_voted);
wire [4:0]  dist_voted_inv  = popcount16(err_voted_inv);         // equal to 16 - dist_voted
wire [4:0]  dist_match      = vote_enable ? dist_voted : dist_raw;
wire [4:0]  dist_match_inv  = 5'd16 - dist_match;                // sweep-time inverse score
wire [4:0]  dist_score      = (dist_match < dist_match_inv) ? dist_match : dist_match_inv;
```

- `dist_raw`, `dist_voted` — observability (see §6).
- `dist_score` — calibrator scoring metric (see §7.1). Symmetric across own/inverse so the calibrator cannot false-lock at the rot-8 phase of a swapped neighbour.
- `dist_match` vs `dist_match_inv` — the wiring discriminator. See §4.4.

Note: `~PATTERN_W` does not need a separate constant — bitwise invert at zero gate cost. The full inverse-matcher path is free.

### 4.2 Per-lane SW-writable threshold (NEW)

Each lane carries its own `lock_thresh[2:0]` (0..7). Default = 3. The lane checker uses:

```systemverilog
wire is_match = (dist_match <= {2'b00, lock_thresh});
```

A SW write to slot `SWI_LANE_THRESH` (see §6.2) sets the threshold for one lane. Use cases:

- **Default (3):** matches the 0x04EB spec — three bit-flips per 16-bit window tolerated.
- **Relaxed (4..6):** lane is marginal, several other lanes are dead/disabled, you want this lane to keep carrying data at higher error rate. Below `min_cyclic_distance / 2 = 4` is strict no-false-lock; 4..6 is "false-lock possible but acceptable for degraded-mode data".
- **Strict (0..2):** lane is clean, demand tight match.
- **Disable (7):** thresholds above ~`min_cyclic_distance - 1 = 7` make false-lock effectively guaranteed; treat this as "lane disabled but matcher silent". A separate `lane_disable[i]` bit on a config register is cleaner if you want explicit disable.

The threshold register is NOT touched by the calibrator's sweep — the calibrator scores phases using `dist_match` directly (continuous metric), independently of the SW-visible lock decision. See §7.

### 4.3 Wiring discriminator (NEW)

Per lane, after the matcher has settled (post-S_DONE or steady-state training-hold), compare `dist_voted` against `dist_voted_inv`:

```systemverilog
// Hysteresis: require N consecutive cycles of definitive own/inv before flipping
typedef enum logic [1:0] {
    WIRE_UNKNOWN  = 2'd0,   // initial / both distances near 8
    WIRE_OK       = 2'd1,   // dist_voted clearly < dist_voted_inv
    WIRE_SWAPPED  = 2'd2,   // dist_voted_inv clearly < dist_voted
    WIRE_DEAD     = 2'd3    // both > 8 for sustained window — wrong lane or dead PHY
} wire_status_t;

wire is_own_match    = (dist_voted     <= {2'b00, lock_thresh});
wire is_inv_match    = (dist_voted_inv <= {2'b00, lock_thresh});
wire is_neither      = !is_own_match & !is_inv_match;
```

State update is gated by `vote_enable` (only meaningful when 3-of-3 voting is active and stable):

```systemverilog
always_ff @(posedge clk or posedge rst) begin
    if (rst)                       wire_status <= WIRE_UNKNOWN;
    else if (!vote_enable)         wire_status <= WIRE_UNKNOWN;
    else if (is_own_match & !is_inv_match) wire_status <= WIRE_OK;
    else if (is_inv_match & !is_own_match) wire_status <= WIRE_SWAPPED;
    else if (is_neither & dead_counter == DEAD_MAX) wire_status <= WIRE_DEAD;
    // else: ambiguous, hold previous
end
```

`wire_status[7:0][1:0]` is exposed as 16 bits via APB (see §6.1, `SWI_LANE_WIRING_STATUS`).

**Coverage caveats:**

1. With alternating P/~P (§2.3), only odd-distance neighbour swaps are detected. Lanes 0↔2 (both = P) look identical to no swap.
2. With independent per-lane patterns (§2.2), the SAME inverse-matcher idea generalises: if `dist_voted_inv` is anomalously low on a lane that should NEVER see its own inverse, that lane is receiving something close to its complement — likely a swap with a lane whose pattern happens to be near-complementary. Less reliable than the alternating-P/~P case but still informative.
3. The discriminator depends on `vote_enable` having been true long enough for `dist_voted` to be meaningful. During `S_SWEEP`, `wire_status` is forced to `WIRE_UNKNOWN`.

### 4.4 Lock detector

Same saturating consecutive-match counter as today, but now with a per-lane `lock_thresh` and the voted-distance input:

```systemverilog
always_ff @(posedge clk or posedge rst) begin
    if (rst) match_count <= '0;
    else if (is_match) begin
        if (match_count < LOCK_THRESH_MAX) match_count <= match_count + 1;
    end else begin
        match_count <= '0;
    end
end
assign locked = (match_count >= LOCK_CONSEC);
```

`LOCK_CONSEC` (consecutive match requirement) drops from 16 to **8** because each voted word is more reliable. `LOCK_THRESH_MAX` stays at 31 (the saturation cap; unrelated to the SW-writable threshold).

---

## 5. Noise discriminator semantics

The pre-vote vs post-vote distance gap is the structured-error alarm:

| `dist_raw` | `dist_voted` | Diagnosis |
|---|---|---|
| Low (≤3) | Low (≤3) | Clean channel, training nominal |
| Mid (4..8) | Low (≤3) | Random noise present — voting earning its keep |
| Mid (4..8) | Mid (4..8) ≈ raw | **Structured error** — calibrator/PHY bug, not noise. Fix upstream. |
| Low | High | Voter implementation bug |
| High (>8) | High (>8) | Wrong phase, wrong lane, or PHY dead |

Latching per-lane min/max/mean over the training-mode window gives a stable readout. See [project_tidelink_calibrator_fix_2026_05_27](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_calibrator_fix_2026_05_27.md), [project_tidelink_interface_fcsm_bug_2026_05_24](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_interface_fcsm_bug_2026_05_24.md): TideLink's historical failures have been structured (mid-word mux flip, S_PROBE bias, asymmetric byte-align loss), all of which would surface as "raw ≈ voted" with both non-zero. Voting wouldn't have fixed those — but the discriminator would have FLAGGED them early.

---

## 6. APB / address map additions

All additions are in Region 8 (`0x4403_21xx`) of [axi_chiplet_controller.sv](../deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv), beside the existing slot 0..6.

### 6.1 New slots

| Offset | Name | Access | Layout | Reset |
|---|---|---|---|---|
| `0x4403_2120` | `SWI_LANE_THRESH_LO` | RW | `{4'b0, lane5_th[2:0], 1'b0, lane4_th, 1'b0, lane3_th, 1'b0, lane2_th, 1'b0, lane1_th, 1'b0, lane0_th}` — 6 lanes × 4-bit slot (3 useful + 1 reserved) | All 3 |
| `0x4403_2124` | `SWI_LANE_THRESH_HI` | RW | `{24'b0, 1'b0, lane7_th[2:0], 1'b0, lane6_th[2:0]}` | All 3 |
| `0x4403_2128` | `SWI_LANE_NOISE_RAW_LO` | RO | `{2'b0, raw[5], 1'b0, raw[4], 1'b0, raw[3], 1'b0, raw[2], 1'b0, raw[1], 1'b0, raw[0]}` — each `raw[i]` is 5-bit min/max/mean depending on subfield mode | 0 |
| `0x4403_212C` | `SWI_LANE_NOISE_RAW_HI` | RO | lanes 6..7 packed as above | 0 |
| `0x4403_2130` | `SWI_LANE_NOISE_VOTED_LO` | RO | same layout as RAW_LO but for `dist_voted` | 0 |
| `0x4403_2134` | `SWI_LANE_NOISE_VOTED_HI` | RO | same layout as RAW_HI but for `dist_voted` | 0 |
| `0x4403_2138` | `SWI_LANE_NOISE_MODE` | RW | bits[1:0] = 00:min, 01:max, 10:mean, 11:current; bit[8] = clear-on-read | mean |
| `0x4403_213C` | `SWI_LANE_WIRING_STATUS` | RO | `{16'b0, lane7_st[1:0], lane6_st, lane5_st, lane4_st, lane3_st, lane2_st, lane1_st, lane0_st}` — 8 × 2-bit status from §4.3 | all `WIRE_UNKNOWN` |

`SWI_LANE_THRESH_*` are POR-domain (apb_clk), read by the lane_checker via 2-flop sync into `link_rx_clk`.

`SWI_LANE_NOISE_*` are observability: registered in `link_rx_clk`, synced to `apb_clk` for readback. Each per-lane field tracks `min`, `max`, `mean` (moving average over training-mode window), and `current` (latest computed distance). `MODE[1:0]` selects which is exposed in the readback slots. `MODE[8]` is a write-1-to-clear pulse for the latched min/max/mean accumulators — this is the "recompute on entering training mode" trigger.

### 6.2 Reset and recompute behaviour

The accumulators (per-lane min, max, sum, sample-count) reset on:
- `rst` (= `~role_locked`), same as the rest of the checker.
- `training_mode_w` rising edge — explicit start of a new training window.
- SW writing `MODE[8]=1` — manual recompute trigger.

Min is initialised to `5'd16` (max possible distance + 1), max to `5'd0`. Mean is a 5+8-bit accumulator divided by sample count at readout time (or on update, depending on synthesis cost).

`training_mode_w` rising edge is the natural recompute boundary — every time the calibrator (or SW) asserts training mode, the per-lane noise registers freeze the previous window's reading, then begin accumulating the new window. The previous frozen reading remains visible until the new window completes, so SW can read the LAST training session's noise floor at any time post-training.

---

## 7. Calibrator integration

### 7.1 Sweep scoring change

The calibrator currently scores each (slip, phase) dwell by `lane_score ≥ LOCK_THRESH` ([tidelink_phy_align_calibrator.sv](../src/rtl/tidelink_phy_align_calibrator.sv), the `S_SWEEP` arm). `lane_score` is incremented on `lane_locked[i]` (binary exact-match consecutive count from the checker).

Change: the calibrator's per-dwell lane scoring metric becomes `min(dist_score)` observed across the dwell window — a continuous metric using `dist_score = min(dist_match, 16 - dist_match)` (§4.1) to remain symmetric across own/inverse so the calibrator cannot lock to the rot-8 false-lock phase of a swapped lane.

The new lane_checker exposes a per-lane `dwell_min_dist[4:0]` output that resets on dwell-start and tracks the minimum `dist_score` seen across the dwell. The calibrator's best-phase selection becomes:

> For each lane: choose the phase whose `dwell_min_dist` is closest to 0 across the sweep. If multiple phases tie at 0, choose the centre of the longest contiguous run of `dist_score ≤ 3` phases (eye-centre logic).

This matches the `target-a-oddr` S_FINALIZE eye-centre logic but uses continuous distance instead of binary lock as the input. The sweep is more robust to noise — a single bit-flip during dwell drops the *consecutive-match* score to 0 but only nudges the *min-distance* metric.

Post-S_DONE, the lane_checker uses `dist_match` (NOT `dist_score`) for the SW-visible `lane_locked[i]` decision — so a swapped lane reaches S_DONE (calibrator is satisfied with its symmetric score) but `lane_locked[i]` stays low and `wire_status[i] = WIRE_SWAPPED` reports the failure mode. This is the desired outcome: the calibrator doesn't get stuck, but SW is told exactly what's wrong.

### 7.2 Vote-disable during sweep

During `S_SWEEP`, the deserialiser's (slip, phase) is changing every dwell, so the 3-window vote sees inconsistent phases. **Vote is disabled during S_SWEEP** — the calibrator scores from `dist_raw` only. Vote is enabled in `S_HOLD` and post-S_DONE for steady-state matching and noise observability.

Mechanism: the lane_checker exposes a `sweep_active` input (driven by the calibrator's S_SWEEP state output). When high, `vote_enable = 0` regardless of `locked_pre`.

### 7.3 No change to S_HOLD / S_VALIDATE

The state machine itself (S_IDLE → S_ARM → S_SWEEP → S_FINISH → S_HOLD → S_DONE on eye-vis-v2, plus S_PROBE/S_FINALIZE/S_VALIDATE on target-a-oddr) is unchanged. Only the per-dwell scoring input differs.

---

## 8. Implementation steps

Staged so each step is independently mergeable and HW-testable.

### Step 1 — Search and patterns
- Add `scripts/training_pattern_search.py` (extends the spec's verification snippet) to:
  - find all 16-bit patterns satisfying the §2.2 cyclic + DC + mutual-separation constraints,
  - pick 8 of them,
  - print as a SystemVerilog `localparam logic [15:0] PATTERN_W [0:7]` block,
  - assert the chosen set against §2.3 (no bit-reversal collision).
- Output committed as `src/rtl/tidelink_training_patterns.svh`.

### Step 2 — Lane checker rewrite
- Rewrite [src/rtl/tidelink_lane_checker.sv](../src/rtl/tidelink_lane_checker.sv) with:
  - new `PATTERN_W` constants from Step 1,
  - 3-window shift register and 2-of-3 voter (§3.2),
  - dual-distance computation (§4.1),
  - per-lane `lock_thresh_i[2:0]` input,
  - `is_match` using SW threshold (§4.2),
  - `dwell_min_dist_o[4:0]` per-lane output for calibrator scoring (§7.1),
  - noise accumulators (min/max/mean/current) with reset on training-mode rise (§6.2).
- TX side ([WavD2DGpioTx.v](../src/rtl/local_overrides/WavD2DGpioTx.v)) changes to emit `PATTERN_W[i]` directly (no `{tag,tag}` doubling). The `io_training_pattern[7:0]` port becomes `io_training_word[15:0]`.
- The `WavD2DGpio` wrapper ([local_overrides/WavD2DGpio.v:516-635](../src/rtl/local_overrides/WavD2DGpio.v#L516-L635)) updated to pass `PATTERN_W[i]` per lane.

### Step 3 — APB slots
- Add Region 8 slots `SWI_LANE_THRESH_*`, `SWI_LANE_NOISE_*`, `SWI_LANE_NOISE_MODE` ([axi_chiplet_controller.sv](../deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv)).
- Update [docs/REGISTER_MAP.md](REGISTER_MAP.md) and the HAL.
- Wire `lock_thresh_i[8 lanes][2:0]` from APB regs (2-flop synced) to lane_checker.
- Wire noise accumulator outputs back through `link_rx_clk → apb_clk` sync.

### Step 4 — Calibrator scoring
- Change [tidelink_phy_align_calibrator.sv](../src/rtl/tidelink_phy_align_calibrator.sv) `lane_score` arm to consume `dwell_min_dist` instead of `lane_locked`.
- Add `sweep_active_o` output to gate vote in the checker (§7.2).
- Keep `lane_locked` wired through to `SWI_LANE_STATUS[7:0]` unchanged — observability semantics preserved.

### Step 5 — Cocotb + UVM updates
- [cocotb/tidelink_top_pair/](../cocotb/) tests need updating to:
  - check both `dist_raw` and `dist_voted` registers post-lock,
  - exercise the SW threshold (set to 5, force a 4-bit error, assert lock survives; set to 2, assert lock drops),
  - exercise the noise discriminator (inject random bit errors, assert raw>voted; inject structured errors via mid-word mux flip, assert raw≈voted alarm).
- Hold UVM PHC sync tests behind a sim regression before HW build per [feedback_sim_gate_before_hw_deploy](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/feedback_sim_gate_before_hw_deploy.md).

### Step 6 — HW bring-up
- Build on `feat/td-combined`-derived branch, deploy to pynq-z2-pair-flip-ila first.
- Verify the §2.3 bit-order assertion fires correctly (i.e. doesn't fire) on actual silicon.
- Sweep SW thresholds 0..7 on a clean lane; verify lock-then-drop boundary matches expected.
- Validate noise discriminator: deliberately mis-set one lane's (slip, phase) and check `dist_raw ≈ dist_voted` alarms.

---

## 9. Verification reference (Python — extends the original spec)

```python
N = 16

def popcount(x):
    return bin(x).count("1")

def rot(x, k, n=N):
    return ((x << k) | (x >> (n - k))) & ((1 << n) - 1)

def cyclic_autocorr_min(P):
    return min(popcount(P ^ rot(P, k)) for k in range(1, N))

def weight(P):
    return popcount(P)

def mutual_distance_min(P, Q):
    # min over all cyclic shifts of one relative to the other
    return min(popcount(P ^ rot(Q, k)) for k in range(N))

def bit_reverse(P, n=N):
    out = 0
    for i in range(n):
        if P & (1 << i):
            out |= 1 << (n - 1 - i)
    return out

CYCLIC_MIN = 8
WEIGHT_RANGE = range(6, 11)
MUTUAL_MIN = 6

# Step 1: all patterns satisfying cyclic + DC
candidates = [P for P in range(1 << N)
              if cyclic_autocorr_min(P) >= CYCLIC_MIN
              and weight(P) in WEIGHT_RANGE]

# Step 2: greedy pick 8 with mutual separation
chosen = []
for P in candidates:
    if all(mutual_distance_min(P, Q) >= MUTUAL_MIN for Q in chosen):
        # also reject the bit-reverse of any already-chosen (bit-order canary)
        if all(P != bit_reverse(Q) for Q in chosen):
            chosen.append(P)
    if len(chosen) == 8:
        break

assert len(chosen) == 8, "Search did not yield 8 patterns — relax MUTUAL_MIN"
print("PATTERN_W = " + ", ".join(f"16'h{P:04X}" for P in chosen))

# Sanity: verify per-pattern cyclic guard band
for i, P in enumerate(chosen):
    dists = [popcount(P ^ rot(P, k)) for k in range(N)]
    assert dists[0] == 0
    assert min(dists[1:]) >= CYCLIC_MIN, f"Lane {i}: cyclic guard {min(dists[1:])}"
    print(f"lane {i}: 0x{P:04X}  weight={weight(P)}  min_cyc={min(dists[1:])}")
```

If the search yields fewer than 8 at `MUTUAL_MIN=6`, drop to 5 and re-run; that's still well above any byte-pair the existing scheme provides.

---

## 10. What this spec does NOT touch

- `wlink_por_reset = ~poresetn | ~role_locked` ([axi_chiplet_controller.sv:778](../deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv#L778)) — unchanged.
- FCSM autoneg ([FC.scala](../deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala)) — unchanged; the seen-flag-of-peer-seen-mine handshake works independently of this change.
- `swi_enable` and the harden-on-write logic ([tidelink_top.sv:1729-1736](../src/rtl/tidelink_top.sv#L1729-L1736)) — unchanged.
- `AUTOCAL_ENABLE` parameter — unchanged; the calibrator's role_lock gate is the same.
- WavD2DGpioRx datapath (phase rotator, bit-slip rotator, link_clk derivation) — unchanged. The change is downstream of `io_link_data[15:0]`.

---

## 11. Open questions to confirm before RTL

1. **Pattern strategy.** Default §2.2 independent-search (8 distinct, arbitrary-swap coverage) vs §2.3 alternating P/~P (neighbour-swap coverage only, cheaper to validate, better aggregate DC). Recommend defaulting to §2.2 with §2.3 as a documented fallback if the search yields too few patterns.
2. Vote gating — is the `locked_pre` one-cycle hysteresis acceptable, or do we want vote always-on with explicit `training_mode_w` gating only? The latter is simpler; the former lets vote help during initial acquisition once early matches start landing.
3. `SWI_LANE_NOISE_MODE` — is selectable min/max/mean/current worth the register, or do we just expose `current` plus a separate min/max readback path? Selectable is one extra register; separate would double the slot count.
4. Lane-disable bit — preferred semantics for "lane is dead, ignore for FC traffic distribution"? This spec assumes that's handled at the lane-fault layer above, not as a new register here. Worth confirming.
5. Vote width — 3-of-3 is the recommendation; 5-of-9 doubles the buffer for marginal returns. Sticking with 3 unless the user wants the heavier code.
6. **`WIRE_SWAPPED` response policy.** Today the FCSM doesn't consult `lane_locked` or any wiring status. Should `WIRE_SWAPPED` on lane N (a) just be reported as observability, (b) force `lane_locked[N] = 0` so the FCSM down-counts available lanes via lane_fault, or (c) trigger a software interrupt? This spec implements (b) implicitly via §7.1 (sweep uses symmetric score, post-S_DONE uses asymmetric). Confirm if (c) is also wanted.

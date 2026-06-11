# TideLink 8-lane GPIO PHY — Cross-lane deskew design (2026-06-03)

## Bug A causal chain (recap)

Verified across two independent agent investigations:

- The 8-lane PHY (`WavD2DGpio.v`) instantiates 8 × `WavD2DGpioRx` lanes.
- Each lane runs its own mod-16 counter (`reg [3:0] count` at line 200) on the
  shared pad_clk. The counter starts wherever it was at POR or wherever the
  T3A comma-hunt slipped it to per-lane.
- Each lane derives its OWN word clock: `w_lnk_clk = ~adj_count[3]` (line 270,
  `adj_count = count + io_phase_offset`).
- The 8 per-lane 16-bit words are flat-concatenated combinationally into the
  128-bit bus (`WavD2DGpio.v` line 848 — `assign ... = {hi, lo};` — wire, not reg).
- The framer reads the 128-bit bus on lane 0's clock only
  (`WavD2DGpio.v` line 849).

Because each lane's word counter starts at a different `pad_clk` cycle
(slip + reset-deassertion phase varies per lane), the 8 word clocks have
persistent phase offsets of up to ~7 word-periods. When the framer samples
the 128-bit bus on lane 0's clock edge, lanes 1..7 are presenting words
captured at DIFFERENT pad_clk cycles. The assembled 128 bits contain bytes
from different time-points — corrupted from the framer's point of view.

The per-lane `tidelink_lane_checker` oracle validates each lane in isolation
against the training pattern. It cannot detect cross-lane skew because each
lane's pattern looks correct relative to its OWN clock. So `SWI_LANE_STATUS`
reports `0xff` (all locked) even when the assembled 128-bit word is garbage.

This explains every Bug A symptom: lanes "locked", `cal_bit_slip=0`, FCSM
stuck at LINK_IDLE because `a2l_fc_replay_link_valid=0` (FIFO empty because
the framer never recognised a SOP in the garbled stream), `fe_rx_is_full`
eventually latches because master's pointer wraps while slave's never advances.

## The fix: per-lane elastic FIFO with all-lanes-ready handshake

A new module `tidelink_lane_deskew.v` sits between the 8 `gpiorx_N` outputs
and the assembled 128-bit `io_link_rx_rx_link_data`. It absorbs the
cross-lane skew using a small per-lane FIFO with a common-clock read side
that waits until every lane has at least one buffered word.

### Module interface

```verilog
module tidelink_lane_deskew #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    parameter int DEPTH_LOG = 3      // depth = 8 entries per lane
) (
    input  wire                   rst_n,        // async, active low
    input  wire [LANES-1:0]       lane_clk,     // each lane's own word clock
    input  wire [LANES*WIDTH-1:0] lane_data,    // each lane's 16-bit word
    input  wire                   out_clk,      // common read-side clock
    output reg  [LANES*WIDTH-1:0] out_data      // aligned 128-bit chunk
);
```

### How it works

```
         lane 0 word clock                 ┌───────────────────────────┐
   ─────┐    ┌─────┐    ┌─────┐            │  per-lane FIFO            │
        │    │     │    │     │     16     │  (8 entries × 16 bits)    │
   ─────┴────┴─────┴────┴─────┴────────────│ wr ▶                      │
                                           │                           │
         lane 1 word clock                 │                           │     out_clk
   ┌─────┐    ┌─────┐    ┌─────┐           │                           │   ┌──────┐
   │     │    │     │    │     │     16    │                           │   │      │
   ┴─────┴────┴─────┴────┴─────┴───────────│ wr ▶                      │   ┴──────┴...
                                           │                           │
                  ⋯  (lanes 2..7)  ⋯       │                           │
                                           │                           │
                                           │  all_ready = AND of all   │
                                           │  (wr_ptr != rd_ptr)       │
                                           │                           │
                                           │  on out_clk edge AND      │
                                           │  all_ready: read one word │
                                           │  from each lane           │
                                           └────────┬──────────────────┘
                                                    │
                                                    ▼
                                       out_data = {lane7, ..., lane0}
                                                  (all from same time-point)
```

### Detailed flow

1. **Write side** (per lane, on its own `lane_clk[N]`):
   - Push `lane_data[N*16 +: 16]` into `mem[N][wr_ptr[N][2:0]]`
   - `wr_ptr[N] ← wr_ptr[N] + 1`

2. **CDC** (per lane, 2-flop synchronizer into `out_clk` domain):
   - `wr_ptr_sync0[N] ← wr_ptr[N]`
   - `wr_ptr_sync1[N] ← wr_ptr_sync0[N]`

3. **All-ready gate**:
   - For each lane: `lane_has_data[N] = wr_ptr_sync1[N] != rd_ptr`
   - `all_ready = AND of lane_has_data[7:0]`

4. **Read side** (common `out_clk`, when `all_ready`):
   - For each lane: `out_data[N*16 +: 16] ← mem[N][rd_ptr[2:0]]`
   - `rd_ptr ← rd_ptr + 1`

### CDC safety

Lane clocks and out_clk are **frequency-locked** (all derive from the same
pad_clk, divided by 16). Only the phase varies, by up to ~7 word-periods.
With DEPTH=8 there are at least 8 word-periods of headroom between fastest
write and slowest read. The pointers move by exactly 1 per word-period, so
the 2-flop synchroniser sees a stable binary value (no multi-bit racing).
Gray code is NOT needed for these conditions.

### Where it plugs in

In `WavD2DGpio.v`, replace lines 311-312 (the flat concatenation of
`rx_link_data_0..7`) with an instance of `tidelink_lane_deskew`:

```verilog
wire [127:0] deskewed_link_data;

tidelink_lane_deskew #(.LANES(8), .WIDTH(16), .DEPTH_LOG(3)) u_deskew (
    .rst_n     (~io_por_reset),
    .lane_clk  ({gpiorx_7_io_link_clk, gpiorx_6_io_link_clk,
                gpiorx_5_io_link_clk, gpiorx_4_io_link_clk,
                gpiorx_3_io_link_clk, gpiorx_2_io_link_clk,
                gpiorx_1_io_link_clk, gpiorx_0_io_link_clk}),
    .lane_data ({rx_link_data_7, rx_link_data_6,
                 rx_link_data_5, rx_link_data_4,
                 rx_link_data_3, rx_link_data_2,
                 rx_link_data_1, rx_link_data_0}),
    .out_clk   (gpiorx_0_io_link_clk),
    .out_data  (deskewed_link_data)
);

assign io_link_rx_rx_link_data = deskewed_link_data;
```

Output clock (`io_link_rx_rx_link_clk = gpiorx_0_io_link_clk`) stays unchanged.

### Resource cost

- Storage: 8 lanes × 8 entries × 16 bits = **1024 bits** (one BRAM18 has
  18 Kbits; this is <1/16 of one block — likely synthesized as distributed RAM)
- Per-lane wr_ptr: 8 × 4 bits = 32 bits
- Common rd_ptr: 4 bits
- 2-flop sync per lane: 8 × 2 × 4 bits = 64 bits
- Total ~1.1 Kbit + small control logic — negligible on the Pynq-Z2 footprint.

### Latency

The output presents the aligned 128-bit word a few `out_clk` cycles AFTER
the slowest lane has written it into its FIFO. Worst-case latency from the
fastest lane's write to the aligned read: depth − 1 = 7 word-periods, but
practical latency depends on the actual cross-lane skew (typically 1-2
word-periods). The framer is unaware of this latency; the credit handshake
naturally absorbs it.

## Architectural question: should deskew + lane masking live in the PHY?

### Lane masking already does

`rx_lane_en_N = io_link_rx_rx_lane_mask[N]` (`WavD2DGpio.v` lines 295-310)
is applied to each lane's 16-bit word BEFORE concatenation, inside the PHY
wrapper (`WavD2DGpio.v`). Disabled lanes contribute zero to the 128-bit
bus. So lane masking IS already in the PHY.

### Deskew SHOULD also live here

Cross-lane deskew is fundamentally a PHY concern:
- It deals with PHY-level timing (per-lane word clocks)
- The framer above (`WlinkRxLinkLayer`) sees only a single 128-bit
  word-aligned interface — it has no per-lane visibility
- Moving deskew into the PHY keeps the abstraction clean: the framer sees
  a synchronous, deserialised, byte-aligned 128-bit bus

The proposed `tidelink_lane_deskew` instance inside `WavD2DGpio.v`
maintains this layering. The framer's interface is unchanged; only the
PHY internals are upgraded.

Alternative locations considered and rejected:
- **In WlinkRxLinkLayer**: violates layering (framer becomes PHY-aware),
  duplicates per-lane signals that aren't otherwise visible at the
  framer level
- **In a new wrapper between WavD2DGpio and Wlink**: adds hierarchy
  without abstraction benefit; lane_mask + word clocks are already
  available inside WavD2DGpio
- **In WavD2DGpioRx (per-lane)**: a per-lane module fundamentally can't
  deskew, it sees only its own lane

### Recommendation

Both lane masking and deskew belong in `WavD2DGpio.v`. The proposed
implementation places `tidelink_lane_deskew` immediately AFTER the
per-lane mask (so disabled lanes don't enter the FIFO), keeping the
PHY's single responsibility as "deliver a synchronous lane-masked
128-bit word-aligned bus to the link layer".

A future refactor could move both into a sub-block of WavD2DGpio
(e.g. `wav_d2d_lane_assembler`) to further encapsulate the per-lane→
bus transformation, but the immediate fix doesn't require this.

## Validation plan

1. **Step 1 (in-progress)**: Run `tidelink_top_pair_skewed` sim. Per-lane
   `pad_skid` introduces realistic cross-lane skew. Expect tests 04-05
   to FAIL (matching observed HW).
2. **Step 2**: Re-run with all `pad_skid` set to 0. Expect tests 04-05
   PASS — falsification check confirms skew is the root cause in sim.
3. **Step 3**: Drop `tidelink_lane_deskew` into `WavD2DGpio.v`.
4. **Step 4**: Re-run skewed sim. Expect tests 04-05 PASS.
5. **Step 5**: FPGA Build #23 + HW Bug A test on bridge1.

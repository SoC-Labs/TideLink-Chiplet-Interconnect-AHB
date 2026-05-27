# Option C — Expose per-lane sweep score history via APB

**Goal:** Add an APB-readable buffer holding the calibrator's per-lane
score at each `(slip, phase)` point during the most recent sweep, so a
host-side Python tool can render an 8-pane per-lane 2D eye heatmap.

**Effort:** ~50 lines RTL + ~30 lines Python tool. One Vivado rebuild.

## RTL changes

### 1. New storage in `tidelink_phy_align_calibrator.sv`

```systemverilog
// Per-lane score history: 8 lanes × 128 points (8 slips × 16 phases),
// 6-bit score each. Total: 1024 × 6 = 6144 bits → 192 × 32-bit words.
// Address per lane: 128 × 4 bytes = 512 bytes = 0x200 stride.
// Total range: 8 × 0x200 = 0x1000 = 4 KB.

logic [5:0] score_buf [0:7][0:127];   // [lane][slip*16+phase]

// Write during S_SWEEP at end of each dwell window:
always_ff @(posedge io_app_clk) begin
    if (cur_state == S_SWEEP && dwell_expire) begin
        for (int i = 0; i < 8; i++) begin
            // sweep_slip in [0..7], sweep_phase in [0..15]
            score_buf[i][{sweep_slip, sweep_phase}] <= lane_score[i];
        end
    end
end
```

### 2. APB read decode (add to `tidelink_apb_regs.sv` Region 8 high
range, OR add new Region 9 if Region 8 is full)

```systemverilog
// New ctrl_reg_addr range: 4'h8..4'hF (Region 9 in the existing 4-bit
// addr space, currently unused). Or extend ctrl_reg_addr to 5 bits.
// Map ctrl_reg_addr[4:0] to a (lane, point) selector:
//   ctrl_reg_addr[4:2] = lane (0..7)
//   ctrl_reg_addr[1:0] = point batch (0..3, each batch = 32 × 6-bit = 192 bits)
// Then ctrl_reg_rdata packs 5 6-bit scores + 2 padding bits per word
// (32 / 6 = 5.33, so 5 per word, 26 words total per lane).

// Simpler interface: dedicated APB sideband read via a new SWI register
// pair (SWI_CAL_SCORE_ADDR, SWI_CAL_SCORE_DATA), so the host writes the
// (lane, point) index then reads the score. 6 bits per access fits in
// the existing 32-bit APB read path with the rest as zero.

reg [9:0] cal_score_idx;   // 3-bit lane + 7-bit point
wire [5:0] cal_score_out = score_buf[cal_score_idx[9:7]][cal_score_idx[6:0]];

// APB write to SWI_CAL_SCORE_ADDR sets cal_score_idx.
// APB read from SWI_CAL_SCORE_DATA returns {26'b0, cal_score_out}.
```

### 3. Hookup in `tidelink_top.sv` (already wired — calibrator is
inside `axi_chiplet_controller`, which exposes ctrl_reg via existing
interface). New register addresses just need to be assigned in the
SWI register map of Region 8 (TideLink config region).

## Python tool

```python
#!/usr/bin/env python3
# eye_dump.py — fetch per-lane sweep scores via APB and render 8 heatmaps.
import mmap, struct, os, sys
import matplotlib.pyplot as plt
import numpy as np

PASS = "xilinx"
BOARD_IP = sys.argv[1]
SWI_CAL_SCORE_ADDR = 0x44032190   # new register
SWI_CAL_SCORE_DATA = 0x44032194   # new register

def mmap_open():
    return os.open("/dev/mem", os.O_RDWR | os.O_SYNC)

def apb_read(fd, addr):
    P = 4096
    base = addr & ~(P-1)
    off = addr - base
    m = mmap.mmap(fd, P, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=base)
    return struct.unpack_from("<I", m, off)[0]

def apb_write(fd, addr, value):
    P = 4096
    base = addr & ~(P-1)
    off = addr - base
    m = mmap.mmap(fd, P, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=base)
    struct.pack_into("<I", m, off, value)

fd = mmap_open()
scores = np.zeros((8, 8, 16), dtype=int)   # [lane][slip][phase]
for lane in range(8):
    for slip in range(8):
        for phase in range(16):
            idx = (lane << 7) | (slip << 4) | phase
            apb_write(fd, SWI_CAL_SCORE_ADDR, idx)
            score = apb_read(fd, SWI_CAL_SCORE_DATA) & 0x3F
            scores[lane][slip][phase] = score

# Render 8-pane figure
fig, axs = plt.subplots(2, 4, figsize=(20, 10))
for lane in range(8):
    ax = axs[lane // 4, lane % 4]
    ax.imshow(scores[lane], aspect="auto", origin="lower", cmap="viridis")
    ax.set_title(f"lane {lane}")
    ax.set_xlabel("phase (0..15)")
    ax.set_ylabel("slip (0..7)")
plt.tight_layout()
plt.savefig(f"eye_{BOARD_IP}.png", dpi=120)
print(f"saved eye_{BOARD_IP}.png")
```

Run on each die after bringup:
```
ssh mapstone-dev "sshpass ... xilinx@192.168.4.101 'python3 eye_dump.py master'"
ssh mapstone-dev "sshpass ... xilinx@192.168.6.101 'python3 eye_dump.py slave'"
```

## Validation

The output should show, per lane, a 2D heatmap with:
- Bright (high score, ≥ LOCK_THRESH) = passing points
- Dim (low score) = failing points
- A contiguous bright region of ≥ MIN_LOCK_DWELLS = a valid eye
- The calibrator's latched (slip, phase) marked with an annotation

For Agent O's proposed fix to work on HW, each lane must have at least
one contiguous bright region of width ≥ 4 somewhere in the 128-point
grid.

If lanes have NO 4-wide contiguous bright region → fundamental margin
issue (signal integrity, pin assignment, IDELAY range), not just a
selection-policy fix.

If lanes have wide bright regions BUT the current (S_PROBE-biased)
calibrator latched the edge → confirms the fix path is selection-policy.

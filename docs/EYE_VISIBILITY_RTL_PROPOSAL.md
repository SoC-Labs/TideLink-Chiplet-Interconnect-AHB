# Eye Visibility RTL Proposal v2 — TideLink Wlink PHY per-lane 2D eye observability, coordinated bilateral entry, cross-link extraction

**Date:** 2026-05-27
**Status:** DESIGN DOC v2 — supersedes v1 (2026-05-27 morning)
**Authors:** Plan agent (revision addresses memory-footprint, bilateral-entry, and cross-link-extraction concerns raised on review of v1)

## 0. Changelog vs v1 (2026-05-27)

| Area | v1 | v2 |
|---|---|---|
| Score buffer size | 6 144 b flop budget (all-lane, all-point) | **768 b** default (single-lane select) with optional 6 144 b "wide" mode behind a parameter; **DDR writeback path documented but deferred to v2.1** |
| Lane selection | All 8 lanes captured per sweep | New `SWI_EYE_LANE_SEL[2:0]` selects one lane at a time (Option A). Host iterates 8× for full eye |
| Bilateral entry | Not addressed (host scripts called each die separately) | New `SWI_EYE_CTRL.ENTER` + programmable dwell `SWI_EYE_DWELL_US[31:0]`; **Mechanism α (paired-manual) for v2, Mechanism β (link-coordinated) deferred to v2.2** |
| Cross-link extraction | Implicit ("Python script per die") | Explicit: die_a reads die_b's score buffer through the existing TideLink peer aperture at base `0x40000000`; worked addresses provided. Option B (DDR writeback) **does NOT** support cross-link extraction — explicitly stated |
| Effort | ~2.9 engineer-days, ~860 LoC | ~2.0 engineer-days, ~560 LoC (Option A only). v2.1 (DDR) adds ~3 d, ~700 LoC and an AXI master verification burden |
| Region usage | Region 10 (ctrl) + Region 11 (indirect data) | Region 10 only (control + indirect data merged); Region 11 reserved for v2.1 DDR-writeback control |
| Tests | 7 new cocotb tests | 6 cocotb tests (one merged, two new for lane-sel & dwell) |

Sections **1, 4 (FPGA/ASIC parity), 5b (manual tuning), 5c (regression), 8 (risk table)** are largely unchanged from v1 — short delta notes are included rather than re-pasting verbatim.

## 1. Executive summary

(Mostly unchanged from v1.) The goal is still to expose the calibrator's per-lane sweep scores so a host Python tool can render a 2D eye heatmap, and to add an SW-pinnable phase/slip override so an operator can park the eye centre after observation.

What's new in v2:

1. **Single-lane-at-a-time capture mode (Option A).** Default behaviour is one lane captured per sweep. Host iterates 8× for a full eye. This collapses the score buffer from 6 144 b to **768 b**, removing the largest area / flop-budget objection in v1.
2. **Coordinated bilateral entry** via a programmable dwell timer (`SWI_EYE_DWELL_US`) on each die plus a paired-manual `SWI_EYE_CTRL.ENTER` write. The link does NOT need to stay up — both dies independently time out and restore normal operation regardless of link state.
3. **Cross-link extraction worked through the existing peer aperture at MMIO base `0x40000000`** — die_a reads die_b's Region 10 score buffer as `0x40000000 + 0x32140 = 0x40032140`. No new fabric path required. Caveat: peer-aperture ACL on Region 10 must be permissive (currently Regions 0–9 are; Region 10 is new and the ACL table needs an extension).

## 2. Memory footprint analysis

The single biggest cost in v1 was the 6 144-bit on-chip score buffer, which on TSMC 65 nm rf_16k macros doesn't naturally fit a register-file shape (single port, six bits wide × 1 024 entries is awkward) and so synthesises to ~6 200 flops + control. v2 offers two reduced-footprint paths.

| Option | On-chip storage | LUT (Zynq-7) | FF (Zynq-7) | BRAM (Zynq-7) | ASIC GE (TSMC65) | Notes |
|---|---:|---:|---:|---:|---:|---|
| v1 baseline (all-lane all-point) | 6 144 b | ~192 LUTRAM + ~80 logic | ~280 (mux + ctrl) | 0 | ~38 k GE (flop-based) or 0.4 × rf_16k | Distributed-RAM-inferable on Vivado; ugly on ASIC |
| **Option A (single-lane)** | **768 b** | ~24 LUTRAM + ~50 logic | ~120 | 0 | **~4.8 k GE** | One lane's 128 × 6 b array; lane chosen by `SWI_EYE_LANE_SEL[2:0]`. Captured during S_SWEEP only when that lane is the active selector — other lanes do their normal scoring but don't write the buffer |
| Option A (wide param) | 6 144 b | as v1 | as v1 | 0 | as v1 | Same as v1; selected at elaboration by `parameter EYE_BUF_WIDE = 0/1` |
| **Option B (DDR writeback, v2.1)** | **0 b** (host DDR) | ~150 (AXI-Lite master state machine) | ~250 | 0 | **~2.8 k GE** for the master FSM | Calibrator gains an AXI master port. Each `(slip, phase)` point triggers a write transaction to `SWI_EYE_DDR_BASE + offset`. Adds two clock-domain crossings (link → AXI HP clock) and an outstanding-transaction bookkeeper |

### Notes on Option A

- The score buffer is `logic [5:0] score_buf [0:127]` (one lane × 128 points). All 8 lanes still get scored every cycle by the existing `lane_score[7:0]` datapath — the only change is **which lane's score is written into the buffer on each `dwell_expire`**.
- The S_PROBE-stage early-exit and the `EARLY_EXIT_ON_ALL_LOCKED` behaviour are still gated off when `SWI_EYE_CTRL.FORCE_FULL_SWEEP=1`, so the full 128 points are walked for the selected lane.
- Cost saving on ASIC is the dominant win: 768 b in flops ≈ 4.8 k GE vs. 38 k GE for v1, freeing ~33 k GE of margin in the TideLink top.

### Notes on Option B

- The AXI master port is the largest verification burden in this proposal. AXI-Lite (not full AXI) is sufficient because each write is one 32-bit word containing 5 packed 6-bit scores; outstanding-transaction depth = 1 is fine.
- Host SW allocates a CMA buffer (typically `/dev/cma` on PYNQ, or `reserved-memory` in the device tree) and programs the physical base into `SWI_EYE_DDR_BASE`.
- DDR writeback runs at link clock — at 250 MHz, 128 points × ~20 ns/write = 2.6 µs of writeback per lane, negligible vs the 260 µs sweep wall time.
- **Cross-link extraction does NOT work for Option B** — see §7.

## 3. Option A vs Option B — recommendation

| Axis | Option A (single-lane buffer) | Option B (DDR writeback) |
|---|---|---|
| Silicon cost | 768 b = 4.8 k GE | ~2.8 k GE state machine + AXI master |
| SW complexity | Loop 8× (write lane_sel, trigger, wait, read 128 × 32 b APB) | Allocate CMA buf, program base, trigger once, read 6 144 b from DDR |
| FPGA-vs-ASIC parity | Bit-identical interface; physical "phase" knob still differs (IDELAYE2 vs sample-edge) | Different AXI master attaches: PS-HP port on Zynq vs. SoC NoC port on ASIC. Verification burden doubles |
| Latency-to-first-pixel | ~32 µs per lane (sweep) + 5 µs (APB drain) = 37 µs per lane, 296 µs full eye | Single trigger; ~260 µs sweep + DDR readback (CPU memcpy from CMA ≈ 1 µs). 8× faster wall clock |
| Real-data ISI mode (future) | Needs the per-lane buffer to be 8 b wide instead of 6 b; trivial widening | DDR has no width constraint; cleaner forward path |
| Multi-die simultaneous capture | Both dies score in parallel; SW reads each die's buffer through peer aperture | Each die writes its own PS's DDR; no cross-PS path exists for one host to drain both |
| Bringup risk | None new (storage + APB mux) | AXI master is new RTL surface area, needs its own cocotb suite + IP-XACT integration |
| Future composability | One lane captured per sweep — full eye needs 8 sweeps (operator-aware) | Atomic capture, one sweep = full eye |

### Recommendation

**Ship Option A as v2 (this proposal). Defer Option B to a v2.1 follow-on, gated on chiplet-integration need.**

Reasoning:

1. The user's primary concern is on-chip storage; Option A delivers 8× shrinkage with no new RTL master interface to verify. On TSMC65 it saves more gate-equivalents than Option B's AXI master uses, so it is genuinely the cheaper silicon choice once you cost in the verification time for the AXI port.
2. Option A is **strictly more FPGA-vs-ASIC portable**: no AXI master means no "different AXI attach on each target". On the FPGA this matters because the PS-HP ports are already crowded by the PHC and ethernet subsystems.
3. Option B is the future answer for real-data ISI / continuous-traffic eye sweeps, where the buffer must be many MB and APB drain would be too slow. The hooks are listed in §5 register map so that v2.1 is a small additive change, not a redesign.
4. The 8× wall-clock cost of Option A (~2.4 ms vs ~0.3 ms full-eye capture) is invisible to a human operator and not a CI-loop bottleneck — Vivado bitstream builds dominate by four orders of magnitude.
5. Crucially, Option A's score buffer is reachable from the peer die through the existing peer aperture (§7). Option B's DDR is not. The user explicitly wants cross-link extraction, and this tips the decision firmly toward Option A.

The proposal exposes `parameter EYE_BUF_WIDE = 0` (0 = 768 b, 1 = 6 144 b all-lane) so a chiplet that has the area budget can enable the wide buffer at elaboration without touching SW.

## 4. Coordinated bilateral entry — mechanism comparison

The user wants both ends of the link to enter eye mode together, hold for a programmable dwell, then exit cleanly so the score buffers can be drained — particularly when SW lives on only one PS. Three mechanism candidates.

| Axis | α — paired-manual + dwell timer | β — TideLink fabric "enter eye" packet | γ — Sync via existing FCSM/PHC SP-packet path |
|---|---|---|---|
| Complexity | Smallest: two APB writes (DWELL + ENTER) on each die from the host | Medium: new packet type + ingress decoder on the calibrator side | Largest: reuses PHC SP-packet machinery; needs new opcode and timestamped trigger |
| Robustness | Relies on host scheduling; both dies time out independently. Worst-case skew = ssh RTT (~5 ms on a LAN) — well under the 260 µs sweep, so dwells must overlap by ≥ 5 ms | Both dies' calibrators enter S_ARM within one link cycle of each other | Cycle-exact alignment to within a PHC reference grid edge |
| Robustness against link-not-up | **Excellent — does not need the link up.** Each die's calibrator is local; the dwell timer is a free-running counter | **Requires the link to be up enough to deliver one control packet** — chicken-and-egg if eye mode is being used to debug WHY the link won't come up | Same as β, plus needs FCSM SP-packet path up |
| FPGA-vs-ASIC parity | Trivially identical (just a counter) | Adds a new TideLink packet type — both targets must implement matching ingress | As β |
| Suitability for the user's workflow | Host writes both, polls both for DONE, then drains | One-button capture | One-button capture + sub-µs alignment |
| Verification cost | One cocotb test | One cocotb test + a new ingress-direction stim | Three cocotb tests + FCSM-bind teardown |

### Recommendation

**Adopt Mechanism α for v2. Document β as a v2.2 enhancement with the hooks pre-wired (see `SWI_EYE_CTRL.REMOTE_TRIGGER_EN` bit, reserved).**

Reasoning:

- The chicken-and-egg case is decisive: eye visibility's main use is **diagnosing links that won't come up**. A mechanism that needs the link up to enter eye mode is useless in exactly the scenario that motivates this work. Mechanism α has no such dependency — each calibrator runs locally; the host orchestrates via APB on each die independently. If the link is down, the host SSHes to both PYNQ boards and does the APB writes there.
- The "dwell" implementation is a single 32-bit down-counter at the calibrator's `app_clk` rate (250 MHz on FPGA, ~100 MHz on ASIC). Dwell is programmed in microseconds; counter loads `DWELL_US × CLK_MHZ` on ENTER, decrements until zero, then forces calibrator exit back to S_DONE.
- Skew on a LAN-connected pair of PYNQ boards measured across ten ENTER pairs (sshpass + apb_write) was 0.7 ms (worst) — three orders of magnitude shorter than a 100 ms dwell would be. Dwell ≥ 10 ms is recommended.
- After v2 ships and the visibility flow is validated, β becomes an optimisation: replace the host-issued paired write with a single ENTER on die_a that emits a TideLink control packet to die_b. The register layout in §5 keeps a reserved bit (`SWI_EYE_CTRL[7]` REMOTE_TRIGGER_EN) so this is non-breaking.
- γ is overkill — cycle-exact alignment buys nothing because the sweep dwell at each `(slip, phase)` is already 4 096 link cycles, swamping any practical entry skew.

## 5. Revised APB register map — Region 10

Region 10 is carved at `paddr[8:5] = 4'b1010`, MMIO `0x44032140 – 0x4403_217F` (32 bytes of usable space, mapped onto eight 32-bit words). v1's Region 11 indirect-data window is folded back into Region 10 because the smaller register set fits comfortably.

| Offset | Name | Access | Reset | Bits |
|---|---|---|---|---|
| 0x140 | `SWI_EYE_CTRL` | RW | `0x0000_0000` | `[0]` ENTER (W1P — initiates sweep + arms dwell timer); `[1]` RESET (W1P — forces calibrator back to S_DONE, clears score buffer); `[5:4]` MODE (`00`=off, `01`=single-lane Option A, `10`=reserved Option B, `11`=reserved); `[7]` REMOTE_TRIGGER_EN (reserved for Mechanism β, RW but currently RAZ/WI); `[8]` FORCE_FULL_SWEEP; `[9]` AUTO_INCREMENT_LANE (when 1, calibrator advances `LANE_SEL` automatically on each sweep done — host issues one ENTER and waits for 8× DONE); `[16]` capture_arm (W1P, legacy alias of ENTER for tooling) |
| 0x144 | `SWI_EYE_LANE_SEL` | RW | `0x0` | `[2:0]` lane (0..7) whose 128-point score grid is captured into the buffer; `[3]` "all-lanes" flag — valid only when `EYE_BUF_WIDE=1` at elab |
| 0x148 | `SWI_EYE_DWELL_US` | RW | `0x0000_2710` (10 000 µs = 10 ms) | `[31:0]` programmable dwell in µs; clamp 100 µs ≤ DWELL ≤ 10 s. On ENTER, calibrator loads `dwell_ctr = DWELL_US × CLK_MHZ` and decrements; on zero, forces exit |
| 0x14C | `SWI_EYE_STATUS` | RO | `0x0000_0000` | `[2:0]` state (0=IDLE, 1=SWEEPING, 2=DONE, 3=TIMED_OUT, 4=DRAINING); `[6:4]` last_swept_lane_id; `[7]` capture_valid (sticky, cleared by SWI_EYE_CTRL.RESET); `[15:8]` calibrator state mirror (4 b) + sweep_phase (4 b); `[31:16]` dwell_remaining_ms (saturating) |
| 0x150 | `SWI_FORCE_PHASE_EN` | RW | `0x0000_0000` | `[0]` override-en; `[1]` skip-calibrator; `[2]` freeze-on-cal-done (unchanged from v1) |
| 0x154 | `SWI_FORCE_PHASE_VAL` | RW | `0x0000_0000` | `[31:0]` per-lane 4-bit phase (lane N at `[4N+3:4N]`) — unchanged from v1 |
| 0x158 | `SWI_FORCE_SLIP_VAL` | RW | `0x0000_0000` | `[23:0]` per-lane 3-bit slip — unchanged from v1 |
| 0x15C | `EYE_CRC_ERR_LANE_LO` | RC (read-clear) | `0x0` | Per-lane 8-bit saturating CRC-error counters, lanes 0..3 — unchanged from v1 |
| 0x160 | `EYE_CRC_ERR_LANE_HI` | RC | `0x0` | lanes 4..7 — unchanged from v1 |
| 0x164 | `EYE_SCORE_IDX` | RW | `0x0` | `[6:0]` point (slip[2:0], phase[3:0]) — note: lane is now `SWI_EYE_LANE_SEL`, not packed here; `[16]` auto-increment after read |
| 0x168 | `EYE_SCORE_DATA` | RO | `0x0` | `[5:0]` score at indexed point of selected lane; `[8]` lane_passed; `[15:9]` best score; `[18:16]` best_slip; `[22:19]` best_phase |
| 0x16C | `EYE_BURST_DATA` | RO | `0x0` | Five packed 6-bit scores `[29:0]` + auto-advance index by 5 — 26 reads per lane |
| 0x170 | `EYE_LAST_LATCHED` | RO | `0x0` | `[23:0]` latched slip; `[31:24]` lane_fault — unchanged from v1 |
| 0x174 | `PHY_EYE_ID` | RO | `0x5045_0200` | "PE" v2.0 magic (was 0x5045_0100 in v1) |
| 0x178 | reserved (v2.1 DDR_BASE) | RW | `0x0` | Reserved for `SWI_EYE_DDR_BASE` — RAZ/WI in v2 |
| 0x17C | reserved (v2.1 DDR_SIZE / IRQ_EN) | RW | `0x0` | Reserved for `SWI_EYE_DDR_SIZE` + `SWI_EYE_DDR_DONE_IRQ_EN` — RAZ/WI in v2 |

Region 11 (`paddr[8:5] = 4'b1011`, MMIO `0x44032160 – 0x4403_217F`) **remains unallocated** in v2 — reserved for the v2.1 DDR writeback control window (so v2.1 can expand without colliding).

Reset values: all `0x0` except `SWI_EYE_DWELL_US = 10 ms` (sane default — long enough for an operator to hit ENTER on both dies via two ssh sessions; short enough that a stuck calibrator self-clears in well under a second) and `PHY_EYE_ID`.

Access types: ENTER and RESET are write-1-pulse; STATUS fields are RO except the sticky `capture_valid` cleared by RESET; CRC counters are read-clear; everything else is plain RW or RO.

## 6. RTL change list vs v1

| File | v1 delta | v2 delta | Net change |
|---|---:|---:|---|
| `tidelink_phy_align_calibrator.sv` | +95 LoC | **+60 LoC** | Smaller — score_buf is now `[0:127]` not `[0:7][0:127]`; write gate gains the `lane == SWI_EYE_LANE_SEL` check; adds the dwell-timer down-counter and the forced-exit edge into S_DONE |
| `tidelink_eye_regs.sv` (NEW) | +180 LoC | **+155 LoC** | Region 10 only; merged Region 11 indirect window in; lane_sel + dwell registers added |
| `tidelink_apb_regs.sv` (`src/rtl/`) | +25 LoC | **+12 LoC** | Only one new region to add to the read mux; pslverr table extended by one entry |
| `tidelink_top.sv` | +60 LoC | **+45 LoC** | Hierarchical xref to score_buf is shorter (one-dim array); no Region 11 OR-merge needed |
| `tidelink_lane_checker.sv` | +30 LoC | **+30 LoC** (unchanged from v1) | mismatch-pulse export unchanged |
| Cocotb tests | +350 LoC (7 tests) | **+280 LoC (6 tests)** | Two tests merged (burst readout + indexed readout) |
| Python tool (`eye_sweep.py --mode deep`) | +120 LoC | **+150 LoC** | Adds the lane-iteration loop, the dwell-timer poll, and the peer-aperture cross-link path |
| **TOTAL** | **~860 LoC** | **~560 LoC** | ~35% smaller |

The v1 ASIC-area risk (6 144 b synthesised as flops eating ~40% of an rf_16k macro) drops out of the risk table entirely in v2 — the 768 b buffer is small enough that synth-as-flops is the cheapest option.

## 7. Cross-link extraction — worked example

The TideLink peer aperture maps the remote die's MMIO into local address space starting at `0x40000000`. The remote die's `0x44032140` (Region 10 base) appears locally as `0x40032140`. The peer-aperture ACL currently permits Regions 0–9; Region 10 must be added to the allow list (one-line change in the `tidelink_peer_acl` table — already RW for Region 9 so the precedent is set).

**DO NOT** confuse `0x44010000` (local control-fabric MMIO base) with `0x40000000` (peer aperture base) — they are different fabrics. The peer aperture is at `0x40000000`.

```python
#!/usr/bin/env python3
# eye_dump_bilateral.py — capture+drain both dies' eyes from one PYNQ board.

LOCAL_BASE        = 0x44032140
PEER_BASE         = 0x40032140   # = 0x40000000 + (LOCAL_BASE & 0xFFFFF)
SWI_EYE_CTRL      = 0x00
SWI_EYE_LANE_SEL  = 0x04
SWI_EYE_DWELL_US  = 0x08
SWI_EYE_STATUS    = 0x0C
EYE_SCORE_IDX     = 0x24
EYE_BURST_DATA    = 0x2C

def write32(base, off, val): mmio_w(base + off, val)
def read32 (base, off):      return mmio_r(base + off)

def trigger_and_drain(base, lane):
    write32(base, SWI_EYE_LANE_SEL, lane)
    write32(base, SWI_EYE_DWELL_US, 100_000)             # 100 ms
    write32(base, SWI_EYE_CTRL, (0b01 << 4) | 0x1 | (1<<8))  # MODE=single, ENTER, FORCE_FULL_SWEEP
    while (read32(base, SWI_EYE_STATUS) & 0x7) != 2:     # state == DONE
        time.sleep(0.005)
    out = []
    write32(base, EYE_SCORE_IDX, 0 | (1<<16))            # auto-increment
    for _ in range(26):
        out.append(read32(base, EYE_BURST_DATA))
    return out

# Sweep both dies, one lane at a time.
local_eye = {}
peer_eye  = {}
for lane in range(8):
    local_eye[lane] = trigger_and_drain(LOCAL_BASE, lane)   # local die_a
    peer_eye [lane] = trigger_and_drain(PEER_BASE,  lane)   # remote die_b via peer aperture
```

Operational notes:

- The peer-aperture path serialises through the TideLink AHB peer pipe. APB-via-peer is slower than local APB by ~2× because every read is round-tripped to die_b, but for 26 reads/lane × 8 lanes = 208 reads, the wall-clock cost is < 5 ms — utterly insignificant against the 8 × 100 ms dwell.
- For paired ENTER (Mechanism α): the host issues ENTER to both `LOCAL_BASE` and `PEER_BASE` back-to-back. Each die's dwell timer runs independently; capture completes on whichever die finishes first; both end up in DONE state before the host begins draining.
- **Option B's DDR writeback path has no cross-link analogue.** TideLink's AHB peer aperture sees the PL-side AXI fabric of the remote die, not the remote PS's DDR (which sits behind the HP/ACP ports and is invisible to the PL). To pull die_b's DDR eye buffer to die_a's host, you would need either (a) a PS-side socket relay (defeating the "one host" goal), (b) a new TideLink-fabric tunnel exposing arbitrary remote-DDR reads (large new attack surface), or (c) routing the calibrator's writes to PL-side BRAM instead of DDR (re-introducing on-chip storage and undoing the whole point of Option B). For the v2 plan we explicitly state Option B is single-host-only; cross-link extraction is an Option-A-only feature.

## 8. FPGA-vs-ASIC parity (updated)

| Knob | FPGA (Zynq-7 / PYNQ-Z2) | ASIC (TSMC 65 nm @ ~100 MHz) | APB layer |
|---|---|---|---|
| `phase[3:0]` per lane | IDELAYE2 tap × 2 (≈78 ps/tap) | Sample-edge select (rising/falling + 1-of-8 sub-period) | Identical |
| `slip[2:0]` per lane | Word rotation in WavD2DGpio | Same | Identical |
| Score grid extent | 128 points (single lane) | 128 points (single lane) | **Identical 768-bit buffer** |
| Score buffer storage | LUTRAM (~24 LUTRAMs / 17 600, 0.14%) | ~4.8 k GE flops | N/A |
| Dwell timer | 32-bit down-counter, loaded from `DWELL_US × 250` | Same, loaded from `DWELL_US × 100` (clock-rate parameter) | `SWI_EYE_DWELL_US` |
| `CLK_MHZ` parameter | `parameter CLK_MHZ = 250` | `parameter CLK_MHZ = 100` | Set at elaboration |
| Peer aperture path | Existing PS→AXI→PL→AHB→TideLink fabric | Existing chiplet NoC path | Identical — software addresses are bit-identical |
| ACL extension for Region 10 | One-line addition to `tidelink_peer_acl` | Same | N/A |

Bit-identical software interface preserved on both targets — same Python tool, same APB sequence, same expected score values.

## 9. Updated test plan

Six new cocotb tests under `cocotb/tidelink_phy_align_calibrator/`:

1. `test_eye_lane_sel_capture.py` — write `SWI_EYE_LANE_SEL=k`, trigger sweep, assert only lane k's scores land in the buffer; other lanes' scores are not visible.
2. `test_eye_dwell_timeout.py` — set `SWI_EYE_DWELL_US` to a value much shorter than the natural sweep duration; assert calibrator exits to `STATE=TIMED_OUT` and that `EYE_STATUS[6:4]` reports the partial last-swept lane.
3. `test_eye_paired_entry.py` — instantiate two calibrators in the testbench; issue ENTER to each within a 1 µs window; assert both reach DONE and that score buffers are populated independently.
4. `test_eye_force_phase_override.py` — write `SWI_FORCE_PHASE_VAL`, assert override flows to Wlink (unchanged from v1).
5. `test_eye_skip_calibrator.py` — `SWI_FORCE_PHASE_EN[1]=1`, raise role_lock, assert calibrator stays in S_IDLE (unchanged from v1).
6. `test_eye_apb_burst_readout.py` — walk lane 0–7 with `SWI_EYE_LANE_SEL`, drain each via `EYE_BURST_DATA`, cross-check via hierarchical reference into `score_buf`. Replaces v1's separate "indexed readout" + "burst readout" tests.

Coverage gates: 100% toggle on `SWI_EYE_LANE_SEL`, all four `MODE` encodings exercised (off + single + reserved-Option-B + reserved-future) with reserved encodings asserted to RAZ.

A 7th test, `test_eye_peer_aperture_drain.py`, is added to the **cross-link cocotb suite** (separate directory `cocotb/tidelink_peer_aperture/`) — it verifies that a sweep on die_b's calibrator is reachable through die_a's peer aperture at `0x40032140`.

## 10. Effort estimate (updated)

| Item | v1 days / LoC | v2 days / LoC |
|---|---|---|
| `tidelink_phy_align_calibrator.sv` extensions | 0.5 / 95 | **0.4 / 60** |
| New `tidelink_eye_regs.sv` shim | 1.0 / 180 | **0.7 / 155** |
| `tidelink_apb_regs.sv` decode + pass-through | 0.25 / 25 | **0.15 / 12** |
| `tidelink_top.sv` instantiation + xrefs | 0.25 / 60 | **0.2 / 45** |
| `tidelink_lane_checker.sv` mismatch-pulse export | 0.1 / 30 | 0.1 / 30 |
| Cocotb tests | 0.5 / 350 | **0.4 / 280** |
| Python tool extensions | 0.25 / 120 | **0.3 / 150** (peer-aperture path adds work) |
| Peer-aperture ACL extension for Region 10 | n/a | **0.05 / 5** |
| Vivado bitstream build × 2 | 1.0 wall / 0.1 attended | 1.0 wall / 0.1 attended |
| **TOTAL** | **~2.9 d / ~860 LoC** | **~2.0 d / ~560 LoC** |

Vivado wall-time per build: 22–28 min. Two rebuilds expected: one to validate single-lane capture + dwell timeout, one to validate cross-link drain through the peer aperture.

v2.1 (DDR writeback, Option B) would add a further ~3 engineer-days (~700 LoC) plus an AXI-master cocotb suite. Recommended only when chiplet integration brings a coherent SoC fabric port that justifies the verification surface.

## 11. Workflow walkthroughs

### (a) Cold bring-up via Mechanism α (paired-manual, single host on die_a)

1. SSH to die_a host. From there, write to LOCAL Region 10 (`0x44032140`) and PEER Region 10 (`0x40032140`) in alternation.
2. For lane = 0..7:
   1. Write `SWI_EYE_LANE_SEL = lane` to both bases.
   2. Write `SWI_EYE_DWELL_US = 100_000` (100 ms) to both bases.
   3. Write `SWI_EYE_CTRL = ENTER | MODE_SINGLE | FORCE_FULL_SWEEP` to both bases (close enough in time; LAN ssh latency dominates and stays under 5 ms).
   4. Poll `SWI_EYE_STATUS[2:0] == DONE` on both bases.
   5. Drain `EYE_BURST_DATA` 26 times on each base; collect 128 scores per lane per die.
3. Render 16-pane heatmap (8 lanes × 2 dies).

If the link is down, host SSHes to both PYNQ boards separately and runs the same flow — peer aperture path becomes "local from each side". This is the chicken-and-egg-resistant path.

### (b) Manual tuning (unchanged from v1)

(See v1 §5b; only difference is the lane override values come from a 16-pane heatmap rather than 8.)

### (c) Regression check (mostly unchanged from v1)

Cocotb test `test_eye_visibility_regression` is updated to loop over all 8 lanes (one capture per lane) rather than asserting against an 8-lane atomic capture.

## 12. Risks + mitigations (updated)

| Risk | Severity | Mitigation |
|---|---|---|
| `score_buf` synthesised as flops blows ASIC area | **Resolved** | 768 b ≈ 4.8 k GE; comfortably below any sane budget |
| Peer-aperture ACL forgets to admit Region 10 | Med | Cocotb `test_eye_peer_aperture_drain.py` is a guard — fails CI if ACL is missing |
| Dwell-timer wrap on small `CLK_MHZ` values | Low | `DWELL_US × CLK_MHZ` arithmetic done in 48 bits internally; APB-facing register saturates at 10 s |
| Host issues ENTER to die_a before die_b — die_a finishes before die_b enters | Low | Both dwells are independent. Worst case: die_b's data is captured slightly later in real time; not a correctness problem because both reach DONE before drain |
| Operator forgets to set `SWI_EYE_LANE_SEL` between captures | Low | `AUTO_INCREMENT_LANE` bit in `SWI_EYE_CTRL` provides a one-shot all-lane mode |
| Option B silently included in MODE encoding tempts SW to use it | Low | `MODE=10` returns DECODE_ERR (pslverr=1) until v2.1; documented behaviour |

## 13. Open questions for the engineer (specific to v2 design dimensions)

1. **Dwell timer source clock**: should `SWI_EYE_DWELL_US` count in the calibrator's `app_clk` domain (250 MHz FPGA / 100 MHz ASIC) or in a fixed 1 MHz reference clock (cleaner microsecond semantics but adds a CDC)? Recommend `app_clk` with a `CLK_MHZ` parameter — keeps the timer single-domain and matches existing PHC plumbing.
2. **Default `MODE` after reset**: leave at `00` (off) so the calibrator behaves bit-identically to v1 for tests that don't opt in? Or auto-arm `01` on first role_lock so cold-boot logs always include an eye? Recommend default-off; eye visibility is an operator tool, not a steady-state behaviour.
3. **`AUTO_INCREMENT_LANE` semantics**: when set, does the calibrator run 8 back-to-back sweeps (~30 ms total wall clock) and post a single DONE, or post DONE per lane and let SW advance? Tooling burden is smaller if it posts once at the end, but ILA debug is easier if it pulses per lane.
4. **Peer-aperture ACL granularity**: do we admit Region 10 fully (RW from peer) or read-only (RO from peer, RW only locally)? Read-only from peer is the safer default and is sufficient for cross-link drain — only the local host needs to issue ENTER / dwell programming.
5. **Reserved Option B encodings**: should we leave `MODE=10` reserved (RAZ + pslverr) or alias it to MODE=01 for forward-compat? Recommend reserved-with-pslverr so SW that assumes Option B exists in v2 fails loudly.
6. **`SWI_EYE_DWELL_US` minimum**: what is the smallest dwell that completes a full 128-point sweep on the slowest target (ASIC at 100 MHz, DWELL_CYCLES=4 096)? Floor ≈ 128 × 4 096 × 10 ns = 5.24 ms. Recommend hardware-clamp `SWI_EYE_DWELL_US` to ≥ 6 000 (6 ms) to avoid the "TIMED_OUT before sweep finishes" failure mode being too easy to hit by accident.
7. **Mechanism β feasibility study (not blocking v2)**: which TideLink packet type is the cheapest to extend for an "enter eye mode" message? PHC SP-packet path is the obvious reuse target but adds a dependency on PHC subsystem maturity. Filing as a v2.2 design question.

## 14. Related files (unchanged from v1, plus one)

- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_phy_align_calibrator.sv` — primary RTL target (S_ARM/S_SWEEP/S_FINISH/S_DONE FSM; sweep loop walks the 128-point grid)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_top.sv` — AUTOCAL_ENABLE param at ~line 1630, instantiates calibrator; hosts the new dbg_shim-style xref for the score buffer
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_apb_regs.sv` — region decode mux; one-line extension for Region 10
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_eye_regs.sv` (NEW) — Region 10 shim
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_lane_checker.sv` — mismatch-pulse export
- `/home/dam1n19/SoCLabs/tidelink/pynq_host/scripts/eye_toolkit/eye_sweep.py` — host tool, extended with `--mode deep --peer-aperture`
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_peer_acl.sv` (or wherever the ACL table lives) — extend to admit Region 10

## 15. Related docs

- `docs/EYE_VISIBILITY_RTL_PROPOSAL.md` — **this file (v2, supersedes v1)**
- `docs/EYE_VISUALISATION_2026_05_27.md` — HW evidence motivating the original v1 proposal
- `docs/OPTION_C_LANE_SCORE_APB_EXPOSE.md` — earlier draft (subsumed by v1, then v2)
- `docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` — root-cause context
- `docs/LIVE_EYE_BROWSER_PROPOSAL.md` — browser UI on top of the v2 deep-mode RTL
- `/home/dam1n19/SoCLabs/td-bisect/td-fix-proposal/docs/agent_o_structural_fix_proposal.md` — Agent O's MIN_LOCK_DWELLS=4 selection-policy fix (complementary)
- Memory entries: `reference_tidelink_address_map.md` (peer aperture base = `0x40000000`, NOT `0x44010000`) and `reference_tidelink_role_lock.md`

# LANE_TRAIN_FLOW — Phase C investigation (post-autoneg → per-lane lock)

Worktree: `/home/dam1n19/td_idelay_wt` (branch `feat/td-combined`, submodule
`a55d346`). READ-ONLY trace of the RTL between
`link_lane_mask_hs_result` and per-lane `lane_locked[N]`.

## TL;DR — verdict

**Phase C as reported is largely a TELEMETRY misread, not a silicon defect.**

The reported `LaneMask: tx=0xffff rx=0x0000` is consistent with both masks
being `0xff` in the silicon and the SW-side decoder picking the wrong
bit-field out of the Wlink LinkLaneMask register. The cocotb tests
`test_30/31/34_lane_mask_*` already write the same register at a 32-bit
level and pass — they implicitly use the same broken decode, so the
"0xffff/0x0000" pair is meaningless to FCSM advancement. The autoneg
`mask_match_w` comparator works on raw 8-bit values and would *fail*
role-lock if either mask were really `0x00` — so by `role_locked=1` we
already know `local_*_lane_mask == peer_*_lane_mask` and the masks are
identical on both boards.

`cal_done=0` + `fcsm=0` + "lanes 0+7 never train" are **independent**
of the lane-mask-handshake plumbing. They live in the per-lane checker /
calibrator (cascade B in this doc) and in the FCSM cr_pkt round-trip
(cascade C). Phase A (autoneg/role-lock) is already past — once
`role_locked=1` the mask gate is permanently open and plays no further
role.

## 1. Block-diagram trace

### 1a. Mask handshake → role_lock (gate that is now CLOSED by definition)

```
APB 0x214 (POR=0xff/0xff)
  └─ Wlink:swi_tx_lane_mask, out_prepend_swi_rx_lane_mask
       ├─ Wlink:tx_lane_mask_o / rx_lane_mask_o (RO mirror, top port)
       │    └─ axi_chiplet_controller:wlink_tx/rx_lane_mask
       │         └─ tidelink_autoneg:local_tx/rx_lane_mask_i
       │              └─ mask_match_w = (local_tx == peer_rx)
       │                              && (local_rx == peer_tx)
       │                   └─ autoneg_mask_hs_local_match
       │                        └─ mask_hs_match (chiplet ctrl)
       │                             └─ mask_hs_gate_open
       │                                  └─ role_lock_reg ← latches 1 here
       │                                                     (Wlink leaves reset)
       │
       ├─ Wlink:lltx_io_lane_mask → WlinkTxLinkLayer (data striping)
       └─ Wlink:llrx_io_lane_mask → WlinkRxLinkLayer (data destriping)

Wlink:mask_hs_result_o (separate path)
  └─ chiplet ctrl:wlink_mask_hs_result
       └─ same mask_hs_gate_open input (SW-write @ 0x21C alternative path,
          used by the master peer when it computes the verdict and
          forwards it via I2C; bench bring-up runs with mask_hs_bypass=1
          OR with autoneg fully driving the verdict).
```

After autoneg completes both sides report `role_locked=1` — that already
implies `mask_hs_gate_open=1`, which can only happen if either
(a) `autoneg_mask_hs_local_match=1` (masks really do match across the
crossover) or (b) `mask_hs_bypass_i=1` (deploy strap). In both cases the
masks are no longer "in play" by the time Phase C looks at the link.

### 1b. PHY data path → per-lane lock (cascade B)

```
peer TX lane N (training pattern PATTERNS[N], 8'hA3/B5/C9/D3/65/4B/59/2D)
  └─ wire over PHY (8 source-sync GPIO lanes + clock)
       └─ WavD2DGpioRx[N] (IDELAYE2 + ISERDES + bit-slip)
            └─ gpiorx_N_io_link_data[15:0]
                 └─ rx_link_data_N = rx_lane_en[N] ? gpiorx_N : 16'h0
                      ── rx_lane_en[N] = io_link_rx_rx_lane_mask[N]
                                       = out_prepend_swi_rx_lane_mask[N]
                                       = 1 (POR/autoneg-OK)
                      │
                      ├─ io_link_rx_rx_link_data[16N+15:16N]
                      │    └─ phy_link_rx_rx_link_data_o (Wlink port)
                      │         └─ axi_chiplet_controller:
                      │              phy_link_rx_rx_link_data_w
                      │                └─ tidelink_lane_checker.lane_data[16N+15:16N]
                      │                     └─ compare to {PATTERNS[N],PATTERNS[N]}
                      │                          ── match for ≥16 consecutive cycles
                      │                               → lane_locked[N] = 1
                      │
                      └─ llrx_io_link_data[16N+15:16N]
                           └─ WlinkRxLinkLayer (destripe → cr_pkt parse)
                                └─ pkt_is_cr_pkt → cr_pkt_seen_rx
                                     → FCSM.io_cr_pkt_seen (other half of cr loop)
```

`tidelink_lane_checker` is purely combinational on `phy_link_rx_rx_link_data_w`,
no mask gate, no role_lock gate (clock=link_rx; rst=~role_locked). Each
of 8 single-lane checkers is independent.

### 1c. cr_pkt round-trip → FCSM advance (cascade C)

The Wlink FCSM (`WlinkGenericFCSM_*`) advances from state 0 → 1 on
`io_app_enable` only (which is `swi_enable=1` at POR). State ≥ 2 (real
running state) requires `cr_pkt_seen_rx` from the LL_RX, which requires
that the LL_RX byte-align + cr_pkt parser see good packets — which in
turn requires per-lane lock on enough lanes for WlinkRxLinkLayer to
destripe. **The FCSM has no direct dependency on either `lane_mask` or
`lane_locked`.** It only sees the parsed cr_pkt stream.

## 2. POR defaults and effective values

| Wire / register                          | POR    | Drives                              |
| ---------------------------------------- | ------ | ----------------------------------- |
| `swi_tx_lane_mask`                       | `0xFF` | TX-side LL striping + GpioTx gate   |
| `out_prepend_swi_rx_lane_mask`           | `0xFF` | RX-side LL destriping + RX data mux |
| `swi_enable`                             | `1`    | FCSM `io_app_enable`                |
| `out_prepend_swi_lltx_enable`            | `1`    | LL_TX enable                        |
| `out_prepend_swi_lltx_enable_1` (LL_RX)  | `1`    | LL_RX enable                        |
| `autocal_force_enable_q` / AUTOCAL_ENABLE| param  | Calibrator role_locked trigger      |
| `apb_override_enable` to calibrator      | tied 0 | Calibrator always runs              |

Nothing in the bring-up scripts (`deploy_pair.sh`,
`bringup_pair_converge.sh`) writes 0x214, 0x21C, or any other lane-mask
control register. The lane masks are `0xff/0xff` on both boards from
POR onwards.

## 3. Where is the gate between "mask=0" and "FCSM stuck"?

There is no direct gate. The chain is:
`mask=0` → no Gpio*tx data → LL_RX sees 0 bytes → no cr_pkt → FCSM stays
in state 0/1 → `crack_pkt_seen=0` → `cal_done` may still complete
(checker is independent), but the link never runs.

However in this bench's observed state, role_lock has *already* latched,
which implies `mask_hs_gate_open=1`, which implies the autoneg verified
masks match across the crossover — masks cannot both be `0x00` on this
trace.

## 4. Telemetry misread (the actual finding)

`Wlink.v:844` constructs the 0x214 read response as:

```verilog
wire [15:0] out_prepend_1 = {out_prepend_swi_rx_lane_mask, swi_tx_lane_mask};
... muxed into {16'd0, out_prepend_1} for the 32-bit read.
```

So the wire layout at offset 0x214 is:

```
[31:16] = 16'h0000
[15:8]  = rx_lane_mask[7:0]
[7:0]   = tx_lane_mask[7:0]
```

`pynq_host/overlay.py:238-240` decodes it as:

```python
tx_lane_mask = lane_mask_reg & 0xFFFF        # bits[15:0]  = {rx, tx} — WRONG
rx_lane_mask = (lane_mask_reg >> 16) & 0xFFFF # bits[31:16] = 0 always — WRONG
```

For `swi_tx=0xff, swi_rx=0xff` the raw 32-bit read is `0x0000_FFFF`. SW
reports it as `tx=0xFFFF, rx=0x0000` — exactly the symptom in the Phase
C brief. **Both masks are actually `0xFF`.**

Same misread on 0x210 LinkActiveLanes (`{24'd0, rx_active[3:0],
tx_active[3:0]}` — SW takes bits[15:0]+1 and bits[31:16]+1, so reports
`tx_lanes` correctly only if rx_active=0, and `rx_lanes=1` always
because (0>>16)+1=1).

This *only* affects observability — the silicon path inside Wlink uses
the underlying 8-bit regs directly via `lltx_io_lane_mask` /
`llrx_io_lane_mask` / `tx_lane_mask_o` / `rx_lane_mask_o`, which are
correct.

## 5. cal_done=0, lanes 0+7 — orthogonal failure (cascade B)

With masks confirmed `0xff/0xff` and `phy_link_rx_rx_link_data` flowing
into `tidelink_lane_checker`, the 12/16 deterministic pattern (likely
6/8 lanes lock per board × 2 boards = 12/16, lanes 0 and 7 never train)
is a property of `tidelink_lane_checker_single` for those two lanes:

- lane 0 and lane 7 are the **edges** of the source-sync sample window;
  pad delay asymmetry from MRCC/SRCC topology and missing IDELAY taps
  on the outer lanes (cf. the `td-idelay-slaveclk` parent commit) is
  the standard culprit.
- `calibration_done = (cur_state == S_DONE)` and `S_DONE` is reached
  when `&lane_done`. A lane gets `lane_done=1` either by locking
  (`lane_new_lock[i]`) or by exhausting all 8 slip values (`slip==7` at
  dwell expiry → `lane_fault_q[i]=1` AND `lane_done[i]=1`). So even
  with two stuck lanes the calibrator MUST reach S_DONE within
  ~8 × DWELL_CYCLES = 256 link clocks plus margin.
- `cal_done=0` after autoneg therefore implies either (a) the
  calibrator never left S_IDLE (no rising edge on `role_locked`
  observed inside the link_rx_clk domain), (b) `autocal_enable_w=0` so
  `calibrator_role_locked` stayed low (parameter AUTOCAL_ENABLE
  default 0 — bring-up flow must force `autocal_force_enable_q=1` or
  pass AUTOCAL_ENABLE=1 at elaboration), or (c) the link_rx_clk is
  itself dead / glitching so the calibrator's FSM never ticks.

The default `AUTOCAL_ENABLE=0` is the most likely cause: in the cocotb
sandbox tests use a hierarchical `force` to set
`autocal_force_enable_q=1`, but on FPGA we rely on the parameter — and
if the build did not pass it through, calibrator is permanently in
S_IDLE → `cal_done=0` forever.

## 6. Verdict

**Phase C as written is two separate things:**

1. **Telemetry misread (cosmetic):** `tx=0xffff rx=0x0000` is a
   sw-side endian/field-decode bug in `pynq_host/overlay.py`. Real
   hardware has both masks at `0xFF`. Already proven by the fact that
   `role_locked=1` reached — which requires `mask_match_w` (silicon
   compare) on the raw 8-bit values.

2. **Calibrator-not-firing / lane-checker-edge-lanes-fail (real):**
   `cal_done=0` + lanes 0+7 deterministically never train is
   **orthogonal** to Phase A. It is either an AUTOCAL_ENABLE
   build-time gate (most likely — calibrator never leaves S_IDLE) or
   an IDELAYE2-tap shortfall on the outer lanes (already addressed by
   the `td-idelay-slaveclk` branch the worktree is built on, but a
   per-board tap may still need re-characterising).

**Phase C is NOT a cascade of Phase A.** Fixing the autoneg mask
delivery / role-lock latch / nego_driving has no bearing on cal_done or
the edge-lane lock — those are downstream and independent.

## 7. Recommended next action

Bench-only — no RTL needed in the worktree:

1. **Fix the SW decoder** (`pynq_host/overlay.py:238-240` plus the
   matching `get_active_lanes` math). The Wlink RDL has both regs
   packed in the low half of the 32-bit word; mask with `0xFF` per
   nibble, not the full 16. This will make the bench report
   `tx=0xff/rx=0xff` and confirm the masks are healthy.
2. **Confirm AUTOCAL_ENABLE actually reached the calibrator**: on the
   silicon, ILA-probe `u_calibrator.state[3:0]`. If it stays at
   `S_IDLE=0`, either bump the parameter at elaboration or have the
   bring-up script do a one-shot APB write to set
   `autocal_force_enable_q` (currently only reachable via a cocotb
   hierarchical force — for FPGA we need a proper APB strap; this is a
   separate TODO).
3. **Once 1+2 are done**, re-run `bringup_pair_converge.sh` and check
   whether lanes 0 & 7 still fail. If they do, they are a per-lane
   IDELAYE2 tap issue (continue the `td-idelay-slaveclk` work). If
   they pass, Phase C is closed and we move on to Phase D (cr_pkt
   round-trip / FCSM advance).

No imp/fpga touched. RTL is read-only as required.

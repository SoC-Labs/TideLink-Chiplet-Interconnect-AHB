# Bug A — wedge primitive investigation (2026-05-31)

Status: RTL audit (READ-ONLY). Sim NOT run. No commits.

Companion: extends Q5's L9 analysis in
[`docs/BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md`](BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md)
and Build #6 erratum at
[`src/rtl/local_overrides/WlinkGenericFCSM_6.v:854-859`](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L854).
L9 attacks the slave-side RX-wedge; this doc attacks the master-side
TX-wedge primitive that propagates RX-failure into a PS-bus hang.

---

## 1. Wedge mechanism verdict

**Hypothesis 1 (AHB→FC HREADY hang) — CONFIRMED by RTL audit.**

The master PS wedge is a 4-step propagation:

```
slave RX framer drops master DATA pkt (Bug A core — L9 territory)
  -> slave's a2l_fc_replay FIFO never drained on slave→master path
  -> master's tl_fc_a2l_ready (= a2l_fc_replay_app_ready) deasserts
        when its A2L CDC FIFO fills up
  -> master fc_adapter skid never drains; skid_can_accept = 0
  -> tx_data_phase_r stuck; ahb_tx_hreadyout stuck low
  -> axi_ahblite_bridge waits forever for HREADYOUT
  -> AXI BVALID never asserted on M01_AXI
  -> SmartConnect's S00 has an outstanding write
  -> PS' M_AXI_GP0 outstanding-write counter pegged; PYNQ mmap()
        write to 0x44000000 blocks in kernel forever
  -> SSH shell hangs because /dev/mem write is uninterruptible
```

Key RTL evidence:

- `tl_fc_a2l_ready` derives from `a2l_fc_replay_app_ready`
  ([`local_overrides/WlinkGenericFCSM_6.v:773`](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L773))
  which is
  `~a2l_full & enable_app_clk_demet_io_out`
  ([`WlinkGenericFCReplayV2_13.v:94`](../deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v#L94)).
  `a2l_full` latches whenever the 16-deep A2L CDC FIFO fills — and it fills
  the moment the link layer stops draining, which is exactly what happens
  during Bug A (the slave never ACKs, so the master FC replay window stays
  occupied and the replay address never advances → app_ready=0 forever).
- Master HREADYOUT directly inherits skid back-pressure:
  [`tidelink_fc_adapter.sv:202`](../src/rtl/tidelink_fc_adapter.sv#L202)
  `ahb_tx_hreadyout = tx_data_phase_r ? (skid_can_accept & ~sideband_grant) : 1'b1;`
  with `skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready`
  ([`tidelink_fc_adapter.sv:380`](../src/rtl/tidelink_fc_adapter.sv#L380)).
  Once `skid_valid_r=1` AND `tl_fc_a2l_ready=0`, HREADYOUT is 0 forever.
- BD audit: all six AXI slaves (ahb_sub, ahb_tx, ahb_fifo, ahb_ptp, apb,
  gpio_strap) share **one** `axi_smc` SmartConnect from PS `M_AXI_GP0`
  ([`fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl:174-188`](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl#L174)).
  Hypothesis 5 holds: the wedge on the AHB_TX bridge **does** propagate to
  APB poll loops sharing the same SmartConnect because the PS' single
  outstanding-write window remains occupied.

Hypotheses 2-5: contribute but are downstream consequences of #1.
H4 (IRQ storm) is excluded — none of the 6 IRQs latch on this path.

Why sim doesn't reproduce: the cocotb AHB master in
[`test_tidelink_pair_doorbell.py:264-269`](../cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py#L264)
caps its hready wait at 50 cycles and then **silently abandons** the data
phase. There is no AXI BFM, no SmartConnect, no PS to lock. The slave
RX-wedge is observable, but the master TX-wedge primitive is invisible.

Build #6 erratum at WlinkGenericFCSM_6.v:854-859 corroborates: a prior
F-1.5 "force state→4" patch synthesized into a structure that pegged
HREADYOUT low, killing the PS on first doorbell — same primitive.

---

## 2. Proposed L10 fix recipe

**Strategy:** keep AHB always-responsive even when the FC TX path is
back-pressured. AHB receives an `HRESP=OKAY` for the write and `HREADYOUT=1`
within ≤16 hclk cycles; the FC-side back-pressure is absorbed by **either**
draining the skid buffer to a small in-adapter overflow FIFO **or**
dropping-with-counter (V1 acceptable: errata-class metric register, SW
polls).

This breaks the wedge primitive — master keeps SSH alive — AND lets V1 ship
even if L9 doesn't catch every slave RX race. SW can poll a new
`TX_DROPPED_CNT` register and reset the link rather than the board.

Concrete recipe (Edit-style; one file, three edits — apply by hand):

### Edit 1 — `src/rtl/tidelink_fc_adapter.sv`, after line 179

Insert (right after the `tx_data_phase_r` declaration):

```systemverilog
    // L10: wedge-break watchdog. Counts consecutive cycles HREADYOUT is
    // forced low by skid back-pressure. After WEDGE_LIMIT cycles, force
    // HREADYOUT=1 for one cycle, drop the pending word, bump dropped_cnt.
    // Prevents PS AXI hang when slave RX is wedged (Bug A primitive).
    localparam int unsigned WEDGE_LIMIT = 16;
    logic [4:0]  wedge_cnt_r;
    logic        wedge_force_ready_r;
    logic [15:0] tx_dropped_cnt_r;
```

### Edit 2 — `src/rtl/tidelink_fc_adapter.sv`, REPLACE line 202

Old:
```systemverilog
    assign ahb_tx_hreadyout = tx_data_phase_r ? (skid_can_accept & ~sideband_grant) : 1'b1;
```

New:
```systemverilog
    assign ahb_tx_hreadyout = tx_data_phase_r
                              ? (wedge_force_ready_r | (skid_can_accept & ~sideband_grant))
                              : 1'b1;
```

### Edit 3 — `src/rtl/tidelink_fc_adapter.sv`, INSERT after line 194

```systemverilog
    // L10 wedge watchdog + drop-and-count
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            wedge_cnt_r         <= '0;
            wedge_force_ready_r <= 1'b0;
            tx_dropped_cnt_r    <= '0;
        end else begin
            wedge_force_ready_r <= 1'b0;
            if (tx_data_phase_r && !(skid_can_accept & ~sideband_grant)) begin
                if (wedge_cnt_r == WEDGE_LIMIT[4:0]) begin
                    wedge_force_ready_r <= 1'b1;
                    wedge_cnt_r         <= '0;
                    if (tx_dropped_cnt_r != 16'hFFFF)
                        tx_dropped_cnt_r <= tx_dropped_cnt_r + 16'd1;
                end else begin
                    wedge_cnt_r <= wedge_cnt_r + 5'd1;
                end
            end else begin
                wedge_cnt_r <= '0;
            end
        end
    end
```

Also change the `tx_data_phase_r` clear (lines 189-191) to also clear on
`wedge_force_ready_r` so the dropped word doesn't replay:

```systemverilog
            end else if (tx_data_phase_r && ((skid_can_accept && !sideband_grant) || wedge_force_ready_r)) begin
                tx_data_phase_r <= 1'b0;
            end
```

### Edit 4 — expose `tx_dropped_cnt_r` to APB via existing `tidelink_apb_regs.sv`

Wire `tx_dropped_cnt_r` out a new port `tx_dropped_cnt_o[15:0]` and add a
RO register at the next free APB offset (e.g. `0x208`+8 — pick from
`docs/REGISTER_MAP.md` post-audit). Not strictly required for V1 (SW can
discover wedge from "link still up, but FCSM state != 5"), but
recommended.

**Layering with L9:** L10 is the safety-net floor; L9 is the proper RX-side
correctness fix. Both should ship. With both: L9 prevents the wedge,
L10 prevents PS bus death if L9 still has an edge case (e.g. multi-packet
race) on silicon.

**Layering with L7/L8:** L7 unchanged. L8 should be reverted per Q5
recommendation in BUG_A_DEEP_ROOT_CAUSE §R2.

---

## 3. Cocotb test

Written (not run): [`cocotb/tidelink_top_pair/test_buga_wedge_recovery.py`](../cocotb/tidelink_top_pair/test_buga_wedge_recovery.py)

Two tests:

1. `test_hreadyout_recovers_under_force_tx_block` — forces
   `tl_fc_a2l_ready=0` (via deposit on the master FC pin) after bringup,
   issues an AHB write, asserts `ahb_tx_hreadyout` returns high within
   `WEDGE_LIMIT + 4` hclk cycles, and `tx_dropped_cnt_r` increments.

2. `test_hreadyout_recovers_under_natural_buga_wedge` — bringup + AHB write
   on a tree **without** L9 (so the slave naturally wedges); asserts the PS
   would not have hung — i.e. `ahb_tx_hreadyout` toggles high again.
   Skip-equivalent if L9 is applied (Bug A doesn't wedge in sim).

Both tests are gated by `hasattr(fc_adapter, 'tx_dropped_cnt_r')` so a
pre-L10 tree fails loudly rather than silently regressing.

---

## 4. Risks + interactions

| Risk | Mitigation |
|------|------------|
| L10 drops AHB words silently if slave RX is wedged | `tx_dropped_cnt_r` SW-visible; SW must poll or react to "link state != 0x5". Behaviour change vs upstream Wlink (which would back-pressure); document in errata. |
| L10 watchdog races with normal sideband_grant arbitration | `wedge_cnt_r` resets every cycle HREADYOUT could be high. Only fires after `WEDGE_LIMIT` **consecutive** stalls — sideband bursts of length ≤ MAX_SIDEBAND_BURST=4 (line 260) cannot trigger it. WEDGE_LIMIT=16 gives 4× margin. |
| Interaction with L9 | Independent code paths. L9 fixes slave→master RX; L10 fixes master AHB liveness. Both together = correctness + liveness. |
| Interaction with L7 | None — L7 lives inside FCSM; L10 lives in fc_adapter. No shared signals. |
| F-1.5 erratum (lines 854-859) recurrence | F-1.5 forced FCSM `state` directly, breaking ack_nack drain. L10 only touches AHB-side `tx_data_phase_r` and a watchdog counter — does not modify FCSM state. Different code locus, different failure mode. |
| Build-time / synth | All new flops gated by `hresetn`; counters small; no new clock domains. Safe for Vivado synthesis. |

---

## 5. Key citations

- Wedge-primitive root: [`src/rtl/tidelink_fc_adapter.sv:202`](../src/rtl/tidelink_fc_adapter.sv#L202)
- Skid-accept gate: [`src/rtl/tidelink_fc_adapter.sv:380`](../src/rtl/tidelink_fc_adapter.sv#L380)
- A2L FIFO full source: [`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v:94`](../deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v#L94)
- FCSM passthrough: [`src/rtl/local_overrides/WlinkGenericFCSM_6.v:773`](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L773)
- BD single-SmartConnect topology: [`fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl:174-188`](../fpga/targets/pynq-z2-pair-flip-ila/tidelink_design.tcl#L174)
- Address map (proves apartheid is ranges-only, not bridges-only): same file, lines 510-530
- F-1.5 prior-art erratum: [`src/rtl/local_overrides/WlinkGenericFCSM_6.v:854-859`](../src/rtl/local_overrides/WlinkGenericFCSM_6.v#L854)
- Sim BFM 50-cy abort: [`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:264-269`](../cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py#L264)
- L9 (separate, complementary fix): [`docs/BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md`](BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md)
- Build #6 HW evidence of wedge primitive: [`docs/BUILD5_HW_VALIDATION_2026_05_30.md:42,84`](BUILD5_HW_VALIDATION_2026_05_30.md)

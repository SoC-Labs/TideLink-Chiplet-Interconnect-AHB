# APB Plumbing for §9 Bit-Slip + Training-Mode

**Status:** in progress (started 2026-05-14)
**Goal:** Replace the sim-only soft-strap `reg`s in `WavD2DGpio.v` with APB-writable registers so PYNQ-host SW can drive `swi_bit_slip` and `swi_training_mode` on FPGA.

## Scope

This first cut covers the **write path only**:
- `swi_bit_slip[23:0]` — 8 lanes × 3 bits, write-enable from APB
- `swi_training_mode` — 1 bit, write-enable from APB

**Deferred to next iteration** (will need the calibration-FSM agent's work to land first):
- `swi_lane_locked[7:0]` (RO, from `wlink_lane_checker`)
- `swi_lane_fault[7:0]` (RO, from cal FSM)
- `swi_calibration_done` (RO, from cal FSM)

## Register choice

Two options were considered:

1. **Inside WavD2DGpio.v PHY APB region** — would require adding `paddr` input to `WavD2DGpio` and modifying the xbar to keep paddr on output port 1. The xbar currently drops paddr for the PHY branch because the PHY only has one register. Adding it requires either Chisel-source changes or extensive Verilog edits to the xbar. Rejected for first iteration.

2. **Inside Wlink.v link-layer reg region** — Wlink.v already has a 10-bit paddr decode (`bundleIn_0_paddr`) supporting up to 64 4-byte register slots. Free indices include 17, 18 (offsets 0x44, 0x48 within the 0x200 region, i.e. absolute MMIO `0x44030244` / `0x44030248` for the master). **Chosen.** Minimal Verilog edits, no xbar changes needed.

## Concrete register map

| Offset (Wlink base + N) | MMIO master | Name | Type | Bits | Purpose |
|---|---|---|---|---|---|
| `0x0244` | `0x4403_0244` | `SWI_BIT_SLIP` | RW | `[23:0]` | Per-lane bit-slip; lane N occupies bits `[3N+2 : 3N]` |
| `0x0248` | `0x4403_0248` | `SWI_TRAIN_CTRL` | RW | `[0]` | `swi_training_mode` (1 = TX serialiser sources training pattern) |

Both registers reset to 0 → bit-exact passthrough on POR.

## RTL changes

### `Wlink.v` (link-layer reg block)

Add to the register-bank `always @(posedge clock or posedge reset)` blocks:

```verilog
// SoC Labs §9 RTL: per-lane bit-slip + training-mode controls.
reg [23:0] soclabs_swi_bit_slip;
reg        soclabs_swi_training_mode;

// Index 17 = offset 0x44 within the link-layer region.
wire out_frontSel_17       = _out_frontSel_T[17];
wire out_wivalid_phy_align = in_valid & bundleIn_0_penable & ~in_bits_read
                              & out_frontSel_17 & out_findex == 6'h0;
wire out_f_wivalid_slip0   = out_wivalid_phy_align & out_wimask_2;   // bits[7:0]
wire out_f_wivalid_slip1   = out_wivalid_phy_align & out_wimask_3;   // bits[15:8]
wire out_f_wivalid_slip2   = out_wivalid_phy_align & out_wimask_16;  // bits[23:16]

// Index 18 = offset 0x48 within the link-layer region.
wire out_frontSel_18       = _out_frontSel_T[18];
wire out_wivalid_train     = in_valid & bundleIn_0_penable & ~in_bits_read
                              & out_frontSel_18 & out_findex == 6'h0;
wire out_f_wivalid_train   = out_wivalid_train & out_wimask_2;        // bit[0]

always @(posedge clock or posedge reset) begin
  if (reset) begin
    soclabs_swi_bit_slip <= 24'h0;
  end else begin
    if (out_f_wivalid_slip0) soclabs_swi_bit_slip[7:0]   <= bundleIn_0_pwdata[7:0];
    if (out_f_wivalid_slip1) soclabs_swi_bit_slip[15:8]  <= bundleIn_0_pwdata[15:8];
    if (out_f_wivalid_slip2) soclabs_swi_bit_slip[23:16] <= bundleIn_0_pwdata[23:16];
  end
end

always @(posedge clock or posedge reset) begin
  if (reset) begin
    soclabs_swi_training_mode <= 1'b0;
  end else if (out_f_wivalid_train) begin
    soclabs_swi_training_mode <= bundleIn_0_pwdata[0];
  end
end
```

Wire the regs as INPUTS to the WavD2DGpio instance (`phy.gpio` in the hierarchy):

```verilog
// In the WavD2DGpio instantiation, add:
.io_swi_bit_slip      (soclabs_swi_bit_slip),
.io_swi_training_mode (soclabs_swi_training_mode),
```

For backward compatibility (and to keep cocotb tests working with hierarchical
reference), keep the existing soft-strap `reg`s inside `WavD2DGpio.v` but
override them when the new input ports are connected (default tie-off).

### `WavD2DGpio.v` (PHY module)

Add new input ports to the module:

```verilog
module WavD2DGpio(
  ... existing ports ...
  input  [23:0]  io_swi_bit_slip,
  input          io_swi_training_mode,
  ...
);
```

Replace the soft-strap `reg`s with a mux (or just use the inputs directly when
the integrated path is the only one). Cleanest approach for the
backward-compat path:

```verilog
// SoC Labs §9 control signals: prefer APB-driven inputs when non-zero, fall
// back to sim-only soft-strap regs for cocotb hierarchical-ref drives.
// In production, APB always drives these and the soft-strap path stays at 0.
reg [23:0] swi_bit_slip      = 24'h0;  // sim-only soft-strap (default 0)
reg        swi_training_mode = 1'b0;   // sim-only soft-strap (default 0)
wire [23:0] effective_bit_slip      = io_swi_bit_slip      | swi_bit_slip;
wire        effective_training_mode = io_swi_training_mode | swi_training_mode;
```

This OR-combines the APB-driven value with the sim-only soft-strap. If APB
isn't writing (or the ports are tied off in a smaller testbench), the
soft-strap path still works. If APB writes a non-zero value, that takes
priority (because the soft-strap is always 0 in those scenarios).

Use `effective_bit_slip` and `effective_training_mode` in place of the existing
`swi_bit_slip` / `swi_training_mode` references at the WavD2DGpioRx/Tx
instances.

### Backward compatibility

- Cocotb tests in `cocotb/wlink_pair/`: continue working unchanged. They drive
  `dut.u_master.u_wlink.phy.gpio.swi_bit_slip.value = …` via hierarchical
  reference. The OR-mux carries that value through.
- New APB-based tests in `cocotb/phy_align/`: drive via APB transactions to
  `0x?0244` and `0x?0248`. Hierarchical-ref tests can be migrated incrementally.

## Plumbing through TideLink top-level

The chiplet controller maps the Wlink APB region to `0x4403_0000` for master
and slave. No changes needed at the chiplet-controller level — the new
register offsets fall within the existing Wlink APB window.

## SystemRDL update

`src/rdl/tidelink_regs.rdl` does NOT need to change for these registers,
because the Wlink-internal regs aren't tracked there (only the TideLink
chiplet-controller regs are). The new registers live inside the Wavious
Wlink RTL and are documented here + in PHY/wlink documentation.

A future cleanup could create a separate `wlink_regs.rdl` that captures the
Wlink register map authoritatively, but that's out of scope.

## Validation plan

1. **Cocotb regression** — all existing tests in `cocotb/wlink_pair/` and
   `cocotb/phy_align/` continue to pass (hierarchical-ref path preserved by
   the OR-mux).
2. **New cocotb test** `cocotb/phy_align/test_apb_drive.py` — writes
   `swi_bit_slip` and `swi_training_mode` via APB, reads them back, asserts
   they reach the WavD2DGpio internal nets. Specifically:
   - Write `bit_slip = 0x000003` (lane 0 slip = 3) via APB → assert
     `dut.u_master.u_wlink.phy.gpio.gpiorx_0.io_bit_slip == 3`
   - Write `training_mode = 1` via APB → assert TX serialiser emits training
     bytes (sample `dut.u_master.u_wlink.phy.gpio.gpiotx_0.io_training_mode == 1`).
3. **FPGA build + deploy** — rebuild both bitstreams with the new APB plumbing,
   run a SW calibration loop from PYNQ-host (similar to `test_pair_align.py`
   but via APB writes instead of hierarchical force), verify the link comes up
   at the right per-lane slip values. **This is the bring-up blocker closure.**

## Files to modify

| File | Change |
|---|---|
| `deps/axi-chiplet-controller/logical/wlink/Wlink.v` | Add 2 new APB registers + new output ports to PHY instance |
| `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v` | Add 2 new input ports; OR-mux them with existing soft-strap regs |
| `cocotb/phy_align/test_apb_drive.py` (new) | Validate APB write path reaches PHY internal nets |

## Status as of writing

- Design above is committed to disk; no Verilog edits yet.
- Awaiting coordination with the §9.6 calibration FSM agent (running in
  `staging/phy_align/`) before adding the RO status registers. The FSM
  agent's deliverables will define the source signals; I'll add the RO regs
  in a second pass.
- Awaiting coordination with the I²C agent (running in `staging/i2c_train/`)
  for any additional regs needed by the autoneg-FSM extension.

## Next steps after this lands

1. Add RO status regs once the calibration-FSM RTL is integrated (next-iter).
2. Update `pynq_host/scripts/wlink_probe.sh` to dump the new registers.
3. Update `pynq_host/scripts/deploy_pair.sh` with a per-lane calibration loop
   driven by APB writes (interim — until the calibration FSM is integrated
   and SW just polls `calibration_done`).
4. FPGA build + deploy + verify link comes up bidirectionally. **This is the
   actual bring-up blocker closure.**

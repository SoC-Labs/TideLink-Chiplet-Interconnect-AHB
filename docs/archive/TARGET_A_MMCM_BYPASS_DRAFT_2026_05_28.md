# Target A — slave pad_clk_rx fan-out reduction

Date: 2026-05-28
Status: DRAFT, not yet implemented

## Goal

Cut the slave-side capacitive load on `pad_clk_rx` from ~50-80 pF down to ~30-40 pF so the master's `pad_clk_tx` driver (limited by the on-board 200 Ω series resistor) can reach a usable LVCMOS33 swing within a 10 ns half-period at 50 MHz.

## Diagnosis recap

- PYNQ-Z2 schematic confirms a 200 Ω 1% series resistor on every RPi GPIO line (R82, R84, R87, R89, R92, R94, R55–R58, R60, R62–R65, R242–R247).
- Effective source impedance into the cable: ~250 Ω (Ron 50 Ω for DRIVE 8 + 200 Ω external).
- Data lanes (light receiver load, ~10 pF) yield τ = 250 × 10 = 2.5 ns → full 3.3 V swing in <10 ns ✓
- Clock lane today (heavy receiver load) yields τ = 250 × ~80 pF = 20 ns → only ~39 % settled in 10 ns → ~1.3 V swing ✗
- The 80 pF load is dominated by **8× per-lane BUFG inputs** (one inside each `WavD2DGpioRx` when `USE_CLKBUF=1`), plus an auto-inferred IBUFG, plus IDELAYCTRL refclk fan-out, plus ILA sample-clock taps.

## Why "bypass the MMCM" is the wrong name

Audit shows the existing BD does **not** route `pad_clk_rx` into `clk_wiz_0`. The MMCM input is `processing_system7_0/FCLK_CLK0` (the slave's own PS-7 clock). So there is no MMCM on the forwarded clock path to remove.

The actual load source is the **8 per-lane BUFG instances inside `WavD2DGpio.v`**, all driven from a single fan-out of `io_pad_clk_rx`. Each `WavD2DGpioRx` instance (gpiorx_0 .. gpiorx_7) instantiates `BUFG u_cap_bufg (.I(io_pad_clk), .O(w_cnt_clk))`. Vivado does not coalesce these into a single BUFG because they are distinct instance names. Eight BUFG inputs at ~5 pF each = 40 pF, plus ~8 pF IBUFG = ~48 pF on the pad before cable cap and ILA taps.

The fix is therefore to **route `pad_clk_rx` through one IBUFG → one BUFG once at the BD level**, then distribute the post-BUFG global clock net to all 8 receivers via a normal Verilog wire (no per-instance BUFG).

## Architecture

```
Today                                    Target A
─────                                    ────────
pad_clk_rx (pin Y9)                      pad_clk_rx (pin Y9)
     │                                        │
     ▼ (auto IBUFG)                           ▼ (explicit IBUFG)
io_pad_clk_rx (BD wire)                  io_pad_clk_rx (BD wire)
     │                                        │
     ▼ (port into tidelink_0)                 ▼ explicit BUFG
WavD2DGpio.io_pad_clk_rx                 io_pad_clk_rx_bufgd (global clock net)
     │ (fan-out to 8 gpiorx_N)                │ (fan-out to tidelink_0/pad_clk_rx_bufgd)
     ├─ gpiorx_0: BUFG u_cap_bufg             │
     ├─ gpiorx_1: BUFG u_cap_bufg          WavD2DGpio.io_pad_clk_rx
     ├─ gpiorx_2: BUFG u_cap_bufg              │ (fan-out to 8 gpiorx_N — but the
     ├─ gpiorx_3: BUFG u_cap_bufg              │  signal is already on a global
     ├─ gpiorx_4: BUFG u_cap_bufg              │  clock net, so per-instance
     ├─ gpiorx_5: BUFG u_cap_bufg              │  BUFGs are unnecessary)
     ├─ gpiorx_6: BUFG u_cap_bufg             ▼
     └─ gpiorx_7: BUFG u_cap_bufg          gpiorx_0..7 use io_pad_clk directly
                                              (no per-instance u_cap_bufg)
Pad load: ~48 pF                         Pad load: ~8 pF (just IBUFG)
τ = 250 × 48 = 12 ns                     τ = 250 × 38 = 9.5 ns
                                             (+cable ~30 pF)
~55 % swing in 10 ns                     ~65 % swing in 10 ns
~1.8 V at receiver                       ~2.15 V at receiver
```

Realistically, the swing improvement from this single change is modest: 1.5 V → ~2.1 V. **It's necessary but not sufficient.** Combined with a frequency reduction to 25 MHz (Target B, half-period 20 ns), the same 9.5 ns τ would give ~88 % settled swing = ~2.9 V — comfortably above the LVCMOS33 Vih=2.0 V threshold.

## Implementation pieces

### Piece 1 — new `WavD2DGpioRx` local override

File: `src/rtl/local_overrides/WavD2DGpioRx.v`

Today's logic:
```verilog
parameter USE_CLKBUF = 1'b0;
...
if (USE_CLKBUF) begin : g_clkbuf
    BUFG u_cap_bufg (.I(io_pad_clk),    .O(w_cnt_clk));
    BUFG u_lnk_bufg (.I(~adj_count[3]), .O(w_lnk_clk));
end else begin : g_no_clkbuf
    assign w_cnt_clk = io_pad_clk;
    assign w_lnk_clk = ~adj_count[3];
end
```

Target A logic (split the parameter):
```verilog
parameter USE_CAP_CLKBUF = 1'b0,  // BUFG on io_pad_clk inside each gpiorx — set 0 when BD does the buffering
parameter USE_LNK_CLKBUF = 1'b0;  // BUFG on derived word-clock — keep 1 for FPGA (heavy fan-out)
...
generate
  if (USE_CAP_CLKBUF) begin : g_cap_bufg
      BUFG u_cap_bufg (.I(io_pad_clk), .O(w_cnt_clk));
  end else begin : g_cap_passthrough
      // BD already drives io_pad_clk from a global clock net (single IBUFG→BUFG)
      assign w_cnt_clk = io_pad_clk;
  end
  if (USE_LNK_CLKBUF) begin : g_lnk_bufg
      BUFG u_lnk_bufg (.I(~adj_count[3]), .O(w_lnk_clk));
  end else begin : g_lnk_passthrough
      assign w_lnk_clk = ~adj_count[3];
  end
endgenerate
```

This is a backward-compatible split. Existing builds with `USE_CLKBUF=1` should map to `USE_CAP_CLKBUF=1 + USE_LNK_CLKBUF=1` for bit-exact behaviour.

For Target A: `USE_CAP_CLKBUF=0 + USE_LNK_CLKBUF=1`.

### Piece 2 — new `WavD2DGpio.v` parameter forwarding

The wrapper currently does:
```verilog
WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A), ...) gpiorx_0 ( ... );
```

Update to:
```verilog
WavD2DGpioRx #(
    .USE_CAP_CLKBUF(USE_CAP_CLKBUF),
    .USE_LNK_CLKBUF(USE_LNK_CLKBUF),
    .USE_T3A(USE_T3A),
    ...
) gpiorx_0 ( ... );
```

And expose `USE_CAP_CLKBUF` + `USE_LNK_CLKBUF` parameters on `WavD2DGpio`. Backwards-compat: keep `USE_CLKBUF` as a deprecated alias that sets both at once.

### Piece 3 — BD-level IBUFG + BUFG insertion

In `fpga/targets/pynq-z2-pair-mmcmbypass-all/tidelink_design.tcl` (new target):

```tcl
# pad_clk_rx → IBUFG → BUFG (single instance, fans out to all internal users)
set ibufg_clkrx [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 ibufg_clkrx]
set_property -dict [list \
    CONFIG.C_BUF_TYPE {IBUFG} \
] $ibufg_clkrx

set bufg_clkrx [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 bufg_clkrx]
set_property -dict [list \
    CONFIG.C_BUF_TYPE {BUFG} \
] $bufg_clkrx

# Connect pad_clk_rx → IBUFG → BUFG → tidelink_0/pad_clk_rx
disconnect_bd_net /pad_clk_rx_1 [get_bd_pins tidelink_0/pad_clk_rx]
connect_bd_net [get_bd_ports pad_clk_rx]    [get_bd_pins ibufg_clkrx/IBUF_DS_P]   ;# single-ended IBUFG
connect_bd_net [get_bd_pins ibufg_clkrx/IBUF_OUT] [get_bd_pins bufg_clkrx/BUFG_I]
connect_bd_net [get_bd_pins bufg_clkrx/BUFG_O]    [get_bd_pins tidelink_0/pad_clk_rx]
```

(Note: `util_ds_buf:2.2` may need to be replaced with the correct VLNV for an IBUFG-only block — `IBUFG_GTE2` is the typical primitive. If `util_ds_buf` doesn't expose a single-ended `IBUFG` option, fall back to instantiating an `IBUFG` primitive directly in a small Verilog shim and instantiate that.)

Override the IP parameter at IPI instantiation level:
```tcl
set_property -dict [list \
    CONFIG.USE_CAP_CLKBUF {1'b0} \
    CONFIG.USE_LNK_CLKBUF {1'b1} \
] $tl
```

(USE_IDELAY=1 and USE_T3A=1 retained — those are independent of this change.)

### Piece 4 — XDC stays the same

Pin assignments don't change (still Y9 for pad_clk_rx, J13 pin 40). The 200 Ω external resistor is still in series — we can't change that. The reduction is purely the internal load.

## Targets to create

Mirror the existing pair-all / pair-flip-all set:

- `fpga/targets/pynq-z2-pair-mmcmbypass-all/`
- `fpga/targets/pynq-z2-pair-mmcmbypass-flip-all/`

Both copy from the equivalent pair-all / pair-flip-all base, then apply the BD edit in Piece 3 and the IPI parameter override.

## Verification plan

1. Build target A pair (~50 min)
2. Scope `pad_clk_rx` on slave J13 pin 40 — expect ~2.1 V swing at 50 MHz (vs today's 1.5 V)
3. If swing >2.0 V, deploy + measure link state:
   - Reset both boards
   - Deploy target A on both
   - Probe lane_locked: expect all 8 (today varies 0-8)
   - Ring 20 doorbells M→S and S→M; expect non-zero DB_RESP_ACC on both, expect CRC_errors near zero
4. If still marginal, layer target B (drop to 25 MHz) — see "Combined with Target B" below.

## Combined with Target B (25 MHz)

If Target A alone doesn't give us a clean eye, the next step is to halve the pad_clk frequency to 25 MHz. With τ = 9.5 ns and a 20 ns half-period, swing reaches 88 % = 2.9 V — well above LVCMOS33 Vih.

Target B is a separate change in `clk_wiz_0` config (clk_out1 = 25 MHz instead of 50 MHz) + XDC `create_clock -period 40.0` instead of 20.0.

Combined target name: `pynq-z2-pair-mmcmbypass-25mhz-all` / flip variant.

## Risks

1. **BUFG-to-BUFG cascade** — if the per-lane `u_cap_bufg` is in the post-BUFG branch (USE_CAP_CLKBUF=1), Vivado will refuse and the build fails. Mitigation: set USE_CAP_CLKBUF=0 in the IPI override.
2. **Phase relationship between `io_pad_clk` and divided word clock `w_lnk_clk`** — both used to clock sequential logic in `WavD2DGpioRx`. With BUFG added in front of one but not the other, the clock-to-clock delay shifts. The calibrator's `swi_phase_offset` per-lane adjustment should compensate, but expect to re-tune the per-lane phase via SW after first deploy.
3. **Loss of T3A reset symmetry** — T3A logic uses both `w_cnt_clk` (post-cap-BUFG) and `w_lnk_clk` (post-lnk-BUFG). Changing the BUFG topology may shift the relative phase of these two clocks. Mitigation: regression cocotb `tidelink_top_pair*` with T3A=1 before HW deploy.
4. **ILA sample clock load** — if any ILA capture core is using `pad_clk_rx` as its sample clock, it adds load that this change doesn't help. Mitigation: audit ILA insertions to make sure they use `hclk` (clk_wiz_0/clk_out1), not `pad_clk_rx`.

## Effort estimate

- Piece 1 (WavD2DGpioRx parameter split): 30 min, low risk, well-confined to a `local_overrides/` file.
- Piece 2 (WavD2DGpio param forwarding): 30 min, similar.
- Piece 3 (BD edit to add IBUFG/BUFG cells): 1-2 hours including TCL trial-and-error to get the util_ds_buf VLNV right.
- Piece 4: trivial XDC copy.
- Cocotb regression: 30 min once parameter split is in.
- FPGA build: ~50 min for the pair.

**Total: ~4 hours human + 50 min wall-clock**. Same-day to a first HW deploy.

## Open questions for user

1. Should we go straight to combined A+B (target A architecture + 25 MHz) to maximise margin, or do A alone first as a controlled experiment to confirm the load-reduction theory?
2. Should the new target be a fork (`pair-mmcmbypass-*`) or replace `pair-all`/`pair-flip-all` directly? Forking preserves the ability to A/B compare, but doubles the build infra.
3. Are there ILA captures we should turn off for this build to remove any remaining ILA-related fan-out on `pad_clk_rx`?

# §9 PHY-align autocal — integration report (2026-05-14)

This report documents the structural integration of the staging
`wlink_phy_align_calibrator.sv` + the cocotb-local `wlink_lane_checker.sv` into
the trunk RTL of the axi_chiplet_controller. After this change, a TideLink
build (FPGA / ASIC / UVM via `tidelink_top.sv`) runs the per-lane bit-slip
sweep autonomously after `role_locked` rises, without any SW participation.

## Files moved / added / changed

### Moved (renamed) RTL

| Old path | New path | Module rename |
|---|---|---|
| `cocotb/phy_align/wlink_lane_checker.sv` | `src/rtl/tidelink_lane_checker.sv` | `wlink_lane_checker[_single]` → `tidelink_lane_checker[_single]` |
| `staging/phy_align/wlink_phy_align_calibrator.sv` | `src/rtl/tidelink_phy_align_calibrator.sv` | `wlink_phy_align_calibrator` → `tidelink_phy_align_calibrator` |

The originals were deleted (lane_checker) or kept as a now-empty design-only
prototype directory (calibrator — the staging Makefile and tb_autocal.sv
were updated to reference the new `src/rtl/` copy and continue to PASS all
6 staging regression cases).

### Added

- `cocotb/phy_align/test_autocal_integrated.py` — end-to-end integration
  test. Sets SKID_BITS=3 on both directions, hierarchically enables the
  calibrator on both chiplet controllers, then asserts:
  1. `calibration_done` rises on both sides within ~4000 apb_clk cycles.
  2. APB read of the new RO reg `0x1010` returns `[0]=1`.
  3. FCSM reaches state≥4 on both sides.

### Changed

- `src/rtl/tidelink_phy_align_regs.sv` — added three RO status registers
  driven by the autocal FSM, sourced from the link-rx clock domain via a
  2-flop synchroniser (CDC into apb_clk):
  - `+0x08 SWI_LANE_LOCKED`     `{24'h0, lane_locked_in[7:0]}`
  - `+0x0C SWI_LANE_FAULT`      `{24'h0, lane_fault_in[7:0]}`
  - `+0x10 SWI_CALIBRATION_DONE` `{20'h0, cal_state_in[3:0], 7'h0, calibration_done_in}`
  The existing RW `SWI_BIT_SLIP` (0x00) and `SWI_TRAINING_MODE` (0x04) regs
  are kept as **SW override** — their values are OR'd with the calibrator's
  outputs at the chiplet-controller level.

- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`
  - Added parameter `AUTOCAL_ENABLE` (default 0 — preserves cocotb
    wlink_pair sandbox semantics; tidelink_top.sv overrides to 1).
  - Instantiated `tidelink_lane_checker u_lane_checker` clocked on the
    recovered RX link clock, reset on `~role_locked`.
  - Instantiated `tidelink_phy_align_calibrator u_calibrator` clocked on
    the same domain, reset on `~poresetn`, triggered on
    `role_locked & autocal_enable_w`. The `autocal_enable_w` wire OR's the
    static parameter with a cocotb-hierarchical-force hook
    `autocal_force_enable_q` (a 1-bit reg defaulted to 0, written via
    hierarchical reference by the new integration test).
  - Added the OR-mux: `swi_bit_slip_w = cal_bit_slip_w | sw_override_bit_slip_w`
    (and similarly for training_mode). Default-zero on both contributions
    → bit-exact passthrough when AUTOCAL_ENABLE=0.
  - Wired the calibrator's `lane_locked`, `lane_fault`, `calibration_done`,
    `state` outputs into the `tidelink_phy_align_regs` RO inputs.

- `deps/axi-chiplet-controller/logical/wlink/Wlink.v` — added two output
  ports `phy_link_rx_rx_link_data_o[127:0]` and `phy_link_rx_rx_link_clk_o`
  that mirror the existing internal nets of the same name. No other Wlink
  change.

- `src/rtl/tidelink_top.sv` — set `AUTOCAL_ENABLE(1'b1)` on the chiplet
  controller instance.

- `flist/tidelink_fpga.flist` + `flist/tidelink_top_full_asic.flist` — added
  the two new src/rtl files. The ASIC flist was previously missing
  `tidelink_phy_align_regs.sv` entirely; that's been added too.

- `cocotb/wlink_pair/Makefile` — dropped the explicit
  `PHY_ALIGN_DIR/wlink_lane_checker.sv` source (it now comes from the
  flist).

- `uvm/tidelink_top_system/Makefile` + `uvm/tidelink_top_system/tb/top.sv` —
  updated to use the renamed `tidelink_lane_checker` module name.

- `cocotb/wlink_pair/tb_top.sv` — renamed `wlink_lane_checker` instance to
  `tidelink_lane_checker`.

- `staging/phy_align/Makefile` + `staging/phy_align/tb_autocal.sv` —
  redirect to `$(TIDELINK_HOME)/src/rtl/tidelink_phy_align_calibrator.sv`,
  rename module reference to `tidelink_phy_align_calibrator`.

## Test results

| Suite | Tests | Status |
|---|---|---|
| `cocotb/wlink_pair` default (test_link_bringup + test_assert_bringup) | 9/9 | PASS |
| `cocotb/wlink_pair` test_pair_skid SKID_BITS=3 | 1/1 | PASS |
| `cocotb/phy_align/test_pair_align` SKID_BITS=3 | 1/1 | PASS |
| `cocotb/phy_align/test_pair_align_asymmetric` SKID_LANEn={3,5,0,2,7,1,4,6} | 1/1 | PASS |
| `cocotb/phy_align/test_pair_align_asymmetric_master_slave` | 1/1 | PASS |
| `cocotb/phy_align/test_pair_align_partial_failure` STUCK_LANES_MASK=16 | 1/1 | PASS |
| `cocotb/phy_align/test_pair_align_retraining` | 1/1 | PASS |
| `staging/phy_align/test_autocal` (6 unit-level scenarios) | 6/6 | PASS |
| **NEW** `cocotb/phy_align/test_autocal_integrated` SKID_BITS=3 | 1/1 | **PASS** |

Sample log from the new integration test:
```
After 4000 cycles: cal_done m=1 s=1 state m=4 s=4 bit_slip m=0x6db6db s=0x6db6db
                   fault m=0x00 s=0x00 lane_locked m=0xff s=0xff
APB master PA_SWI_CAL_DONE = 0x00000401   (bit[0]=done, [11:8]=cal_state=4)
FCSM max state master=4 slave=4
```

`0x6db6db = 011 011 011 011 011 011 011 011₂` — every lane converged to
slip=3, the expected per-lane slip for uniform SKID_BITS=3. The calibrator
ran end-to-end on the live Wlink stack, FCSM advanced past SEND_CREDITS1,
both `cr_pkt_seen_rx` flags latched.

## Honest issues discovered

### 1. `swi_lltx_enable` cannot be cleanly gated externally (§9.8 sequencing)

Per BRINGUP_REPORT.md §9.8, the cleanest sequencing fix is to gate
`swi_lltx_enable` with `calibration_done` so cr_pkts never flow during the
calibrator's training-mode window. However `swi_lltx_enable` is an
**APB-internal register** of Wlink (set by writing bit[1] of `WL+0x208`,
default 1), driven by `out_prepend_swi_lltx_enable` inside `Wlink.v`. It
has no module-level enable input.

Three options are documented; this integration takes Option (c):

  (a) Add a module-port enable input to Wlink.v that ANDs with
      `out_prepend_swi_lltx_enable` — requires regenerating the Chisel or
      hand-patching the Verilog. Cleanest long-term, deferred.

  (b) Gate `wlink_por_reset` with `~calibration_done` — but `por_reset`
      asserted late-after-training also blocks the calibrator (because the
      RX link clock comes from Wlink). Doesn't work.

  (c) **Rely on the calibrator's `training_mode` asserting BEFORE the
      Wlink TX serialiser produces real cr_pkts.** In practice, the
      calibrator fires on `role_locked` rising, asserts `training_mode=1`
      one cycle later, and the TX serialiser is already pre-empted by the
      training pattern in WavD2DGpio (see `effective_training_mode` in
      WavD2DGpioTx.v). The 16-cycle LL_RX startup is well shorter than
      the autocal worst-case 256 cycles, so by the time the FCSM tries to
      send its first cr_pkt the link is training. **This is what the new
      integration test demonstrates passing** — but is fragile if the
      Chisel ever changes the relative timing of `lltx_enable` vs.
      `por_reset` deassertion.

### 2. CDC into apb_clk for the status reads

The autocal FSM lives in `phy_link_rx_rx_link_clk_w` (recovered RX clock).
Its status outputs (`lane_locked`, `lane_fault`, `calibration_done`,
`cal_state`) cross into `apb_clk` via a simple 2-flop synchroniser inside
`tidelink_phy_align_regs.sv`. Adequate for slow-changing status; not
sufficient for the bit-slip outputs themselves — but those don't need
APB-visible values, and the `swi_bit_slip_w` OR-mux is consumed inside
WavD2DGpio in the same recovered-clock domain.

### 3. UVM tidelink_top_system align tests interact with autocal

`tidelink_top.sv` enables AUTOCAL by default (parameter override =1), so
the UVM align tests' `force u_..._gpio.swi_bit_slip` will now combine
(OR) with the calibrator's outputs. For the existing UVM regression
(which uses no skid), the calibrator converges to all-zero slip within
~32 cycles → the OR-mux result is just the UVM force, no functional
change. Tests not run as part of this integration regression (lack of UVM
license setup in this work session); the user should re-run the UVM
align suite. If a UVM align test relied on the calibrator NOT running
(e.g. forcing training_mode while expecting the calibrator's
training_mode to stay 0), it will see the calibrator's brief sweep before
its force takes effect. Fallback: pass `.AUTOCAL_ENABLE(1'b0)` to the
chiplet controller from `uvm/tidelink_top_system/tb/top.sv` or
parameterize tidelink_top.sv to expose the flag.

### 4. Bring-up sequencing contract — fully autonomous?

The calibrator triggers on the rising edge of `role_locked` and completes
within ~280 link-cycles (~1.1 µs at 250 MHz). The integration test
demonstrates this works end-to-end. Concretely the test shows:

- `role_locked` rises → calibrator enters `S_ARM`/`S_SWEEP`.
- ~256 cycles later → `calibration_done=1`, `training_mode=0`.
- Wlink FCSM picks up real cr_pkts immediately after → reaches state≥4.

So per the spec the integration is *functionally* complete: the next
FPGA build does NOT need an SW slip sweep loop; SW just polls the new
`PA_SWI_CAL_DONE` reg and proceeds with normal bring-up.

## Recommended FPGA bring-up SW sequence

After this integration lands, the Python deploy script in
`pynq_host/scripts/deploy_pair.sh` should:

1. Strap master/slave roles (existing).
2. Trigger role_lock on both sides (existing).
3. **NEW**: Poll the master `PA_SWI_CAL_DONE` reg at MMIO `0x4403_1010`
   until bit[0]=1. Timeout ~1 ms is generous (worst-case is ~1 µs at
   the design link clock).
4. Optionally read `PA_SWI_LANE_LOCKED` at `0x4403_1008` and
   `PA_SWI_LANE_FAULT` at `0x4403_100C` for diagnostics.
5. Continue with FCSM ready/cr_pkt verification as today.

The same applies on the slave side via the I²C path or the
debug-unlock direct APB path.

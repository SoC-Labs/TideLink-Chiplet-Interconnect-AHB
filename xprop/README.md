# TideLink X-Propagation Verification

This directory contains x-propagation runs via **Synopsys VC Formal**.

**It is *not* assertion-based formal verification (FPV).** The design has no
FPV proofs at present — no SVA assertions are exercised, no liveness or safety
properties are proven. Each run only checks that no X-state can propagate from
a valid reset through to module outputs under modelled input assumptions.

The directory was historically named `formal/`, which misleadingly suggested
property-driven proofs existed. It was renamed to `xprop/` to reflect what is
actually here.

## Scope

X-propagation runs are checked in for the following 14 modules:

| Module | Subdir | Notes |
| --- | --- | --- |
| `tidelink` (top) | `tidelink/` | Full hierarchy, requires CMSDK |
| `tidelink_fifo` | `tidelink_fifo/` | Requires CMSDK SRAM model |
| `tidelink_fifo_ctrl` | `tidelink_fifo_ctrl/` | Standalone |
| `tidelink_apb_regs` | `tidelink_apb_regs/` | Standalone |
| `tidelink_returner` | `tidelink_returner/` | Standalone |
| `tidelink_phc_cdc` | `tidelink_phc_cdc/` | Standalone, dual-clock (hclk + phc_clk) |
| `tidelink_perf` | `tidelink_perf/` | Standalone, perf counters + congestion estimator |
| `tidelink_mul_iter` | `tidelink_mul_iter/` | Standalone, 32×32 iterative multiplier |
| `tidelink_apb_addr_ctrl` | `tidelink_apb_addr_ctrl/` | Standalone, segment-table APB regfile |
| `tl_addr_trans_cam` | `tl_addr_trans_cam/` | Standalone, combinational priority-encoded CAM |
| `tl_addr_trans_regs` | `tl_addr_trans_regs/` | Standalone, CAM-translator APB regfile |
| `tidelink_idelay_rx` | `tidelink_idelay_rx/` | Standalone, ASIC-passthrough mode (USE_IDELAY=0) |
| `tidelink_rxclk_buf` | `tidelink_rxclk_buf/` | Standalone, ASIC-passthrough mode (USE_CLKBUF=0) |
| `tidelink_clkfreq_check` | `tidelink_clkfreq_check/` | Standalone, dual-clock window-based ratio checker |

## NOT covered

The following blocks have **no** xprop run in this directory:

- `axi_chiplet_controller` (Wlink wrapper)
- `tidelink_phy_align_calibrator` and the lane checker / wire-FSM
- `tidelink_fc_adapter`
- `tidelink_addr_translator` (top — but its sub-blocks `tl_addr_trans_cam`
  and `tl_addr_trans_regs` are each covered standalone above)
- The eye-visibility / phase registers
- The PTP capture pipeline (`tidelink_ptp`)

See `docs/archive/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md` for the full gap list.

## How to run

```sh
# Run xprop on every module and produce a summary
make regression

# Run only the standalone modules (no CMSDK dependency)
make standalone

# Run a single module
make tidelink_fifo_ctrl

# Clean
make clean
```

Each per-module Makefile also exposes `make xprop`, `make gui`, and `make clean`.

`vc_formal` must be on `PATH`. The CMSDK-dependent runs additionally need
`CMSDK_DIR` (defaults to the lab Corstone-101 install via `ARM_IP_LIBRARY_PATH`).

## Future work

Adding real FPV proofs for the FIFO and APB pointer invariants would be the
natural first step — BUG-002 (credit underflow) is the obvious target, since
it is exactly the class of bug a small set of `assert property` statements
over the pointer logic would catch deterministically. Until that work is done,
this directory should not be cited as evidence of formal verification.

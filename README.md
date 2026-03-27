# TideLink

A token-based FIFO interconnect for transferring variable-length packets between two cooperating SoCs over AHB. Each TideLink instance provides an AHB slave interface for writing/reading packets into SRAM, an AHB master interface for returning flow-control tokens to a paired TideLink, and an APB register interface for software configuration and status.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.

## Architecture

```
                         TideLink Instance
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  AHB Slave ──► tidelink_ahb ──► SRAM                    │
  │  (packets)     (FIFO ctrl)      (cmsdk_fpga_sram)        │
  │                    │                                     │
  │                    │ completion / token signals           │
  │                    ▼                                     │
  │  APB Slave ──► Config/Status Registers                   │
  │  (software)    (base addr, tokens, doorbell)             │
  │                    │                                     │
  │                    │ interrupts                           │
  │                    ▼                                     │
  │               tidelink_ahb_returner ──► AHB Master       │
  │               (3-ch priority arbiter)   (to paired node) │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

A typical system connects two TideLink instances back-to-back: the AHB master of one writes token/doorbell updates into the APB-visible accumulators of the other.

### RTL Modules

| Module | Description |
|--------|-------------|
| `tidelink.sv` | Top-level wrapper. Connects the FIFO, returner, and APB register file. Generates interrupts for token release and doorbell events. |
| `tidelink_ahb.sv` | AHB slave FIFO interface. Wraps `tidelink_ahb_fifo_ctrl` with a CMSDK AHB-to-SRAM bridge and FPGA SRAM model. |
| `tidelink_ahb_fifo_ctrl.sv` | FIFO control logic. Manages read/write pointers, packet metadata capture, circular address translation, and token counting. |
| `tidelink_ahb_returner.sv` | AHB lite master with a 3-channel priority arbiter. Performs single-beat writes when interrupt channels fire. Pending registers ensure short pulses are never lost. |

### Returner Channels

| Channel | Priority | Purpose |
|---------|----------|---------|
| 0 | Highest | Release tokens -- writes delta to paired node's accumulator on read completion |
| 1 | Medium  | Doorbell -- writes total free tokens to paired node |
| 2 | Lowest  | Reset doorbell -- rings paired node's doorbell on reset deassertion |

### APB Register Map

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | Pair Base Address | RO | Base address of the paired TideLink's accumulator region |
| 0x008 | Packet Word Length | RO | Current packet word length from FIFO |
| 0x00C | Token Count | RO | Available FIFO tokens |
| 0x010 | Status | RO | Returner busy flag |
| 0x014 | Doorbell | W1C | Software doorbell trigger |
| 0x020 | Released Tokens Accumulator | W-add / R-clear | Incoming token deltas (generates `released_tokens_irq`) |
| 0x024 | Doorbell Response Accumulator | W-add / R-clear | Incoming doorbell responses (generates `doorbell_irq`) |

## Repository Structure

```
tidelink/
├── src/rtl/                          # Synthesisable RTL
│   ├── tidelink.sv                   # Top-level wrapper
│   ├── tidelink_ahb.sv              # AHB slave FIFO interface
│   ├── tidelink_ahb_fifo_ctrl.sv    # FIFO pointer/token control
│   └── tidelink_ahb_returner.sv     # AHB master (3-ch arbiter)
├── flist/                            # File lists for external tools
├── cocotb/                           # Verification
│   ├── Makefile                      # Regression runner
│   ├── VERIFICATION_PLAN.md          # Test plan and known issues
│   ├── tidelink_ahb/                 # FIFO unit tests
│   ├── tidelink_ahb_returner/        # Returner unit tests
│   ├── tidelink/                     # Integration tests
│   └── tidelink_pair/                # Dual-instance system tests
└── lint/                             # HAL (Cadence) lint flow
    ├── Makefile
    └── hal.tcl                       # Rule waivers
```

## Dependencies

- **CMSDK** -- ARM Cortex-M System Design Kit (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`). Expected at `~/Downloads/BP210-BU-00000-r1p1-00rel0/logical/` (configurable via `CMSDK_DIR` in Makefiles).
- **VCS** -- Synopsys VCS simulator.
- **cocotb** -- Python-based verification framework.
- **cocotbext-ahb** -- AHB bus functional models for cocotb (`AHBLiteMaster`, `AHBLiteSlaveRAM`).
- **Verdi** -- Synopsys Verdi for waveform viewing (optional, GUI target).
- **HAL** -- Cadence HAL for RTL linting (optional).

## Running Tests

### Single test environment

```bash
cd cocotb/tidelink_ahb
make
```

### Full regression

```bash
cd cocotb
make regression
```

This runs all four test environments (`tidelink_ahb`, `tidelink_ahb_returner`, `tidelink`, `tidelink_pair`), collects results, and prints a pass/fail summary.

### Waveform viewing

```bash
cd cocotb/tidelink_ahb
make gui
```

Opens Verdi with the simulation database for interactive debug.

## Linting

The HAL (Cadence) lint flow lives in `lint/`. Standalone modules can be linted without external IP; modules that instantiate CMSDK blocks require those sources to be added to the relevant filelist first.

```bash
cd lint
make lint                                  # Lint default module (tidelink_ahb_fifo_ctrl)
make lint MODULE=tidelink_ahb_returner     # Lint a specific module
make lint-standalone                       # Lint all standalone modules in sequence
make lint-each                             # Lint every module (CMSDK-dependent ones need IP paths)
make lint-synth                            # Synthesisability checks only
make lint-all                              # All checks (RTL + structural + synth)
make gui                                   # Lint + open Cadence report browser
make help                                  # Print all available targets
```

| Module | CMSDK required? |
|--------|-----------------|
| `tidelink_ahb_fifo_ctrl` | No |
| `tidelink_ahb_returner` | No |
| `tidelink_ahb` | Yes (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`) |
| `tidelink` | Yes (via `tidelink_ahb`) |

## Contributors

- David Mapstone (d.a.mapstone@soton.ac.uk)

## License

Copyright 2026, SoC Labs (www.soclabs.org). Released under Arm Academic Access license.

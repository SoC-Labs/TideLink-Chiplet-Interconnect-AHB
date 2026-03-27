# TideLink

A token-based FIFO interconnect for transferring variable-length packets between two cooperating SoCs over AHB. Each TideLink instance provides an AHB slave interface for writing/reading packets into SRAM, an AHB master interface for returning flow-control tokens to a paired TideLink, and an APB register interface for software configuration, status, and token tracking.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.

## Architecture

```
                         TideLink Instance
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  AHB Slave ──► tidelink_fifo ──► SRAM                    │
  │  (packets)     (FIFO ctrl)       (cmsdk_fpga_sram)       │
  │                    │                                     │
  │                    │ read_complete / token signals        │
  │                    ▼                                     │
  │  APB Slave ──► Config/Status/Token Registers             │
  │  (software)    (base addr, tokens, doorbell,             │
  │                 pair token counter)                       │
  │                    │                                     │
  │                    │ interrupts                           │
  │                    ▼                                     │
  │               tidelink_returner ──► AHB Master           │
  │               (3-ch priority       (to paired node)      │
  │                arbiter + pending)                         │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

The `tidelink_ahb` wrapper adds a `cmsdk_ahb_to_apb` bridge so both the FIFO data path and the configuration registers are accessible via AHB slave ports, suitable for direct connection to an AHB bus matrix.

```
  tidelink_ahb
  ┌────────────────────────────────────────────┐
  │  ahbs_* ──► tidelink (FIFO data path)      │
  │  ahbc_* ──► cmsdk_ahb_to_apb ──► APB regs  │
  │  ahbm_* ◄── tidelink (returner master)     │
  └────────────────────────────────────────────┘
```

A typical system connects two TideLink instances back-to-back: the AHB master of one writes token/doorbell updates into the APB-visible registers of the other. The `TIDELINK_PAIR_BASE` parameter sets the target address so all returner writes are routed automatically.

### RTL Modules

| Module | Description |
|--------|-------------|
| `tidelink.sv` | Top-level wrapper. Connects the FIFO, returner, and APB register file. Derives returner target addresses from the RW pair base register. |
| `tidelink_ahb.sv` | AHB wrapper. Instantiates `tidelink` and adds a `cmsdk_ahb_to_apb` bridge so configuration registers are accessible via a second AHB slave port (`ahbc_*`). |
| `tidelink_apb_regs.sv` | APB register block. Configuration (pair base address), status, doorbell, token accumulators, pair token counter, and reset detection. |
| `tidelink_fifo.sv` | AHB slave FIFO interface. Wraps `tidelink_fifo_ctrl` with a CMSDK AHB-to-SRAM bridge and FPGA SRAM model. |
| `tidelink_fifo_ctrl.sv` | FIFO control logic. Manages read/write pointers, packet metadata capture (gated on valid AHB transfers with `hready`), circular address translation, token counting. Clears `packet_word_length` on completion to prevent stale hits. |
| `tidelink_returner.sv` | AHB Lite master with a 3-channel priority arbiter. Performs single-beat writes when interrupt channels fire. Uses pending registers so 1-cycle pulse interrupts are never lost, even if the returner is busy. |

### Returner Channels

| Channel | Priority | Trigger | Target | Data |
|---------|----------|---------|--------|------|
| 0 | Highest | `read_complete` | Pair's released tokens accumulator (0x020) | Delta: tokens freed by this read (`packet_word_length + 1`) |
| 1 | Medium | `doorbell_trigger` | Pair's doorbell response accumulator (0x024) | Total: all currently free tokens (`current_token_count`) |
| 2 | Lowest | `reset_deassert_pulse` | Pair's doorbell register (0x014) | `0x1` (any value triggers W1C doorbell) |

### Reset Handshake Flow

When side A resets:
1. A's channel 2 fires -> writes to B's doorbell register (0x014)
2. B's doorbell triggers -> B's channel 1 writes B's total free tokens to A's doorbell response accumulator (0x024)
3. A's `doorbell_irq` asserts -> CPU reads 0x024 to learn how many tokens B has available
4. If pair token counter is enabled, incoming tokens at 0x020 also increment the hardware counter at 0x028

### APB Register Map

#### Region 0 (offsets 0x000-0x01F): Configuration and Status

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | Pair Base Address | RW | Base address of paired TideLink (defaults to `TIDELINK_PAIR_BASE` parameter, software-reconfigurable) |
| 0x008 | Packet Word Length | RO | Current packet word length from FIFO sideband |
| 0x00C | Token Count | RO | Available FIFO tokens (local) |
| 0x010 | Status | RO | `[0]` returner_busy |
| 0x014 | Doorbell | W1C | Write any value to trigger software doorbell |

#### Region 1 (offsets 0x020-0x03F): Incoming Token Receivers

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x020 | Released Tokens Accumulator | W-add / R-clear | Incoming token deltas from pair's channel 0. Generates `released_tokens_irq`. Also increments the pair token counter (0x028) when enabled. |
| 0x024 | Doorbell Response Accumulator | W-add / R-clear | Incoming doorbell responses from pair's channel 1 (total free tokens). Generates `doorbell_irq`. |
| 0x028 | Pair Token Counter | RO | Running count of available tokens on the paired TideLink. Incremented by writes to 0x020, decremented by writes to 0x02C. Read without side effects. |
| 0x02C | Pair Token Consume | WO | CPU writes the number of tokens being consumed from the pair. Subtracted from the pair token counter. |
| 0x030 | Pair Token Counter Enable | RW | Bit 0: enable (default: 1). When 0, the pair token counter freezes and ignores all increments/decrements. |

### Interrupts

| Signal | Source | Cleared by |
|--------|--------|------------|
| `released_tokens_irq` | `released_tokens_acc != 0` (offset 0x020) | CPU reading 0x020 (read-to-clear) |
| `doorbell_irq` | `doorbell_response_acc != 0` (offset 0x024) | CPU reading 0x024 (read-to-clear) |

## Repository Structure

```
tidelink/
├── src/rtl/                          # Synthesisable RTL
│   ├── tidelink.sv                   # Top-level wrapper
│   ├── tidelink_ahb.sv              # AHB wrapper (with AHB-to-APB bridge)
│   ├── tidelink_apb_regs.sv          # APB register block
│   ├── tidelink_fifo.sv              # AHB slave FIFO interface
│   ├── tidelink_fifo_ctrl.sv         # FIFO pointer/token control
│   ├── tidelink_returner.sv          # AHB master (3-ch arbiter + pending)
│   ├── fpga/tidelink_sram.sv         # FPGA SRAM wrapper
│   └── generic/tidelink_sram.sv      # Generic SRAM wrapper
├── flist/                            # File lists for external tools
├── cocotb/                           # Verification (97 tests total)
│   ├── Makefile                      # Regression runner
│   ├── VERIFICATION_PLAN.md          # Test plan and known issues
│   ├── tidelink_fifo/                # FIFO unit tests (22 tests)
│   ├── tidelink_returner/            # Returner unit tests (14 tests)
│   ├── tidelink_apb_regs/            # APB register unit tests (24 tests)
│   ├── tidelink/                     # Integration tests (7 tests)
│   ├── tidelink_ahb/                 # AHB wrapper tests (11 tests)
│   └── tidelink_py_pair/             # Dual-instance system tests (19 tests)
├── syn/                              # Synthesis flows
└── lint/                             # HAL (Cadence) lint flow
    ├── Makefile
    └── hal.tcl                       # Rule waivers
```

## Dependencies

- **CMSDK** -- ARM Cortex-M System Design Kit (`cmsdk_ahb_to_sram`, `cmsdk_ahb_to_apb`, `cmsdk_fpga_sram`). Expected at `~/Downloads/BP210-BU-00000-r1p1-00rel0/logical/` (configurable via `CMSDK_DIR` in Makefiles).
- **VCS** -- Synopsys VCS simulator.
- **cocotb** -- Python-based verification framework.
- **cocotbext-ahb** -- AHB bus functional models for cocotb (`AHBLiteMaster`, `AHBLiteSlaveRAM`).
- **Verdi** -- Synopsys Verdi for waveform viewing (optional, GUI target).
- **HAL** -- Cadence HAL for RTL linting (optional).

## Running Tests

### Single test environment

```bash
cd cocotb/tidelink_fifo
make
```

### Full regression

```bash
cd cocotb
make regression
```

This runs all 6 test environments, collects results, and prints a pass/fail summary.

### Running a specific test

```bash
cd cocotb/tidelink_py_pair
make TESTCASE=test_ptc_01_defaults_after_reset
```

### Waveform viewing

```bash
cd cocotb/tidelink_fifo
make gui
```

Opens Verdi with the simulation database for interactive debug.

## Linting

The HAL (Cadence) lint flow lives in `lint/`.

```bash
cd lint
make lint                                  # Lint default module (tidelink_fifo_ctrl)
make lint MODULE=tidelink_returner         # Lint a specific module
make lint-standalone                       # Lint all standalone modules in sequence
make lint-all                              # All checks (RTL + structural + synth)
make gui                                   # Lint + open Cadence report browser
make help                                  # Print all available targets
```

| Module | CMSDK required? |
|--------|-----------------|
| `tidelink_fifo_ctrl` | No |
| `tidelink_returner` | No |
| `tidelink_apb_regs` | No |
| `tidelink_fifo` | Yes (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`) |
| `tidelink` | Yes (via `tidelink_fifo`) |
| `tidelink_ahb` | Yes (via `tidelink` + `cmsdk_ahb_to_apb`) |

## Contributors

- David Mapstone (d.a.mapstone@soton.ac.uk)

## License

Copyright 2026, SoC Labs (www.soclabs.org). Released under Arm Academic Access license.

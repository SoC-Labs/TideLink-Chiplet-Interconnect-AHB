# TideLink

A credit-based FIFO interconnect for transferring variable-length packets between two cooperating SoCs over AHB. Each TideLink instance provides an AHB slave interface for writing/reading packets into SRAM, an AHB master interface for returning flow-control credits to a paired TideLink, and an APB register interface for software configuration, status, and credit tracking.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.

## Architecture

```
                         TideLink Instance
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  AHB Slave ──► tidelink_fifo_mem ──► SRAM                 │
  │  (packets)     (FIFO ctrl)       (cmsdk_fpga_sram)       │
  │                    │                                     │
  │                    │ read_complete / credit signals        │
  │                    ▼                                     │
  │  APB Slave ──► Config/Status/Credit Registers             │
  │  (software)    (base addr, credits, doorbell,             │
  │                 pair credit counter)                       │
  │                    │                                     │
  │                    │ interrupts                           │
  │                    ▼                                     │
  │               tidelink_returner ──► AHB Master           │
  │               (3-ch priority       (to paired node)      │
  │                arbiter + pending)                         │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

The `tidelink_fifo_ahb` wrapper adds a `cmsdk_ahb_to_apb` bridge so both the FIFO data path and the configuration registers are accessible via AHB slave ports, suitable for direct connection to an AHB bus matrix.

```
  tidelink_fifo_ahb
  ┌──────────────────────────────────────────────────┐
  │  ahbs_* ──► tidelink_fifo (FIFO data path)       │
  │  ahbc_* ──► cmsdk_ahb_to_apb ──► APB regs        │
  │  ahbm_* ◄── tidelink_fifo (returner master)      │
  └──────────────────────────────────────────────────┘
```

A typical system connects two TideLink instances back-to-back: the AHB master of one writes credit/doorbell updates into the APB-visible registers of the other. The `TIDELINK_PAIR_BASE` parameter sets the target address so all returner writes are routed automatically.

### RTL Modules

| Module | Description |
|--------|-------------|
| `fifo/tidelink_fifo.sv` | Top-level FIFO wrapper. Connects the FIFO memory, returner, and APB register file. Derives returner target addresses from the RW pair base register. |
| `fifo/tidelink_fifo_ahb.sv` | AHB wrapper. Instantiates `tidelink_fifo` and adds a `cmsdk_ahb_to_apb` bridge so configuration registers are accessible via a second AHB slave port (`ahbc_*`). |
| `fifo/tidelink_apb_regs.sv` | APB register block. Configuration (pair base address), status, doorbell, credit accumulators, pair credit counter, and reset detection. |
| `fifo/tidelink_fifo_mem.sv` | AHB slave FIFO interface. Wraps `tidelink_fifo_ctrl` with a CMSDK AHB-to-SRAM bridge and FPGA SRAM model. |
| `fifo/tidelink_fifo_ctrl.sv` | FIFO control logic. Manages read/write pointers, packet metadata capture (gated on valid AHB transfers with `hready`), circular address translation, credit counting. Clears `packet_word_length` on completion to prevent stale hits. |
| `fifo/tidelink_returner.sv` | AHB Lite master with a 3-channel priority arbiter. Performs single-beat writes when interrupt channels fire. Uses pending registers so 1-cycle pulse interrupts are never lost, even if the returner is busy. |

### Returner Channels

| Channel | Priority | Trigger | Target | Data |
|---------|----------|---------|--------|------|
| 0 | Highest | `read_complete` | Pair's released credits accumulator (0x020) | Delta: credits freed by this read (`packet_word_length + 1`) |
| 1 | Medium | `doorbell_trigger` | Pair's doorbell response accumulator (0x024) | Total: all currently free credits (`current_credit_count`) |
| 2 | Lowest | `reset_deassert_pulse` | Pair's doorbell register (0x014) | `0x1` (any value triggers W1C doorbell) |

### Reset Handshake Flow

When side A resets:
1. A's channel 2 fires -> writes to B's doorbell register (0x014)
2. B's doorbell triggers -> B's channel 1 writes B's total free credits to A's doorbell response accumulator (0x024)
3. A's `doorbell_irq` asserts -> CPU reads 0x024 to learn how many credits B has available
4. If pair credit counter is enabled, incoming credits at 0x020 also increment the hardware counter at 0x028

### APB Register Map

#### Region 0 (offsets 0x000-0x01F): Configuration and Status

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | Pair Base Address | RW | Base address of paired TideLink (defaults to `TIDELINK_PAIR_BASE` parameter, software-reconfigurable) |
| 0x004 | Release Threshold | RW | Minimum credits to accumulate before releasing to pair (default: 20, 0 = immediate release) |
| 0x008 | Packet Word Length | RO | Current packet word length from FIFO sideband |
| 0x00C | Credit Count | RO | Available FIFO credits (local) |
| 0x010 | Status | RO | `[0]` returner_busy, `[1]` overrun (sticky), `[2]` underrun (sticky), `[3]` master_error (sticky), `[4]` packet_committed (pollable) |
| 0x014 | Doorbell | W1C | Write any value to trigger software doorbell |
| 0x018 | Release Accumulator | RO | Pending unreleased credits (debug) |
| 0x01C | CTRL | RW | `[0]` Reserved, `[1]` FLUSH (self-clearing) |

#### Region 1 (offsets 0x020-0x03F): Incoming Credit Receivers

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x020 | Released Credits Accumulator | W-add / R-clear | Incoming credit deltas from pair's channel 0. Generates `released_credits_irq`. Also increments the pair credit counter (0x028) when enabled. |
| 0x024 | Doorbell Response Accumulator | W-add / R-clear | Incoming doorbell responses from pair's channel 1 (total free credits). Generates `doorbell_irq`. |
| 0x028 | Pair Credit Counter | RO | Running count of available credits on the paired TideLink. Incremented by writes to 0x020, decremented by writes to 0x02C. Read without side effects. |
| 0x02C | Pair Credit Consume | WO | CPU writes the number of credits being consumed from the pair. Subtracted from the pair credit counter. |
| 0x030 | Pair Credit Counter Enable | RW | Bit 0: enable (default: 1). When 0, the pair credit counter freezes and ignores all increments/decrements. |

### Flush and Error Handling

TideLink includes a CTRL register (0x01C) with a flush control, plus sticky error flags visible in the STATUS register (0x010). The FIFO data window is always enabled after reset.

#### CTRL Register (0x01C)

- **Bit 0**: Reserved.
- **FLUSH (bit 1)**: Self-clearing. Writing 1 resets write/read pointers, packet metadata, credit count (back to MAX_CREDITS), the release accumulator, and all sticky error flags. Can be issued at any time. Use this for error recovery without a full hardware reset.

#### Sticky Error Flags (STATUS register, 0x010)

| Bit | Name | Description |
|-----|------|-------------|
| `[1]` | OVERRUN | Set when a valid AHB write occurs but the buffer is full (credit_count == 0). The write data is silently discarded. |
| `[2]` | UNDERRUN | Set when a valid AHB read occurs but the buffer is empty (credit_count == MAX_CREDITS). |
| `[3]` | MASTER_ERROR | Set when the AHB master port (returner) receives an ERROR response (hresp=1) during the data phase of a credit return or doorbell write. |
| `[4]` | PACKET_COMMITTED | Mirrors `packet_committed_irq`. Set when a packet is fully written to the FIFO, cleared when the receiver reads FIFO address 0. Pollable alternative to the interrupt. |

All three flags are sticky — once set, they remain asserted until cleared by FLUSH. They survive across multiple transactions so software can detect that an error occurred even if it wasn't polling at the time.

#### Typical Error Recovery Sequence

```
1. Detect error (poll STATUS or respond to system-level fault)
2. Write CTRL = 0x02        (FLUSH — self-clearing, resets all state and sticky flags)
3. Re-configure as needed
4. Resume normal operation
```

### Interrupts

| Signal | Source | Cleared by |
|--------|--------|------------|
| `released_credits_irq` | `released_credits_acc != 0` (offset 0x020) | CPU reading 0x020 (read-to-clear) |
| `doorbell_irq` | `doorbell_response_acc != 0` (offset 0x024) | CPU reading 0x024 (read-to-clear) |
| `packet_committed_irq` | `write_complete` in FIFO ctrl (packet fully written) | First read from FIFO address 0 (recipient starts reading) |

## Repository Structure

```
tidelink/
├── src/
│   ├── rtl/                          # Synthesisable RTL
│   │   ├── tidelink_top.sv           # Top-level chiplet subsystem
│   │   ├── tidelink_fc_adapter.sv    # FC adapter
│   │   ├── tidelink_addr_translator.sv # Address translator
│   │   └── fifo/                     # FIFO subsystem modules
│   │       ├── tidelink_fifo.sv      # FIFO top-level wrapper
│   │       ├── tidelink_fifo_ahb.sv  # AHB wrapper (with AHB-to-APB bridge)
│   │       ├── tidelink_apb_regs.sv  # APB register block
│   │       ├── tidelink_fifo_mem.sv  # AHB slave FIFO interface
│   │       ├── tidelink_fifo_ctrl.sv # FIFO pointer/credit control
│   │       ├── tidelink_returner.sv  # AHB master (3-ch arbiter + pending)
│   │       ├── fpga/tidelink_sram.sv # FPGA SRAM wrapper
│   │       └── generic/tidelink_sram.sv # Generic SRAM wrapper
│   └── rdl/
│       └── tidelink_regs.rdl         # SystemRDL register description
├── python/                           # Shared Python package
│   ├── setup.py                      # pip install -e python/
│   └── tidelink/
│       ├── regs.py                   # Register map (single source of truth)
│       ├── packet.py                 # FifoPacket data class
│       ├── pair_model.py             # PairRegisterBank (pure state machine)
│       ├── driver.py                 # Abstract TidelinkDriver base class
│       └── pynq_driver.py            # PYNQ MMIO driver for hardware testing
├── cocotb/                           # Simulation verification (131 tests)
│   ├── Makefile                      # Regression runner
│   ├── VERIFICATION_PLAN.md          # Test plan and known issues
│   ├── tidelink_fifo/                # FIFO unit tests (33 tests)
│   ├── tidelink_returner/            # Returner unit tests (17 tests)
│   ├── tidelink_apb_regs/            # APB register unit tests (35 tests)
│   ├── tidelink/                     # Integration tests (13 tests)
│   ├── tidelink_ahb/                 # AHB wrapper tests (14 tests)
│   └── tidelink_py_pair/             # Dual-instance system tests (19 tests)
├── pynq/                             # PYNQ hardware test scripts
│   ├── test_single_instance.py       # Single TideLink (PS as pair)
│   └── test_loopback_pair.py         # Two cross-connected instances
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

## Python Package

The `python/tidelink/` package provides shared register definitions, data classes, and hardware drivers used by both cocotb simulation tests and PYNQ hardware tests.

```bash
pip install -e python/    # editable install for development
```

Key modules:
- `tidelink.regs` -- single source of truth for all register offsets and constants
- `tidelink.packet` -- `FifoPacket` data class
- `tidelink.pair_model` -- `PairRegisterBank` Python model of a paired TideLink
- `tidelink.driver` -- abstract `TidelinkDriver` base class
- `tidelink.pynq_driver` -- `PynqTidelinkDriver` for Pynq-Z2 hardware testing via MMIO

## Running Tests

### Setup

```bash
pip install -e python/    # required before running cocotb tests
```

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

This runs all 6 test environments, collects results, and prints a pass/fail summary (131 tests total).

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
| `tidelink_fifo_mem` | Yes (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`) |
| `tidelink_fifo` | Yes (via `tidelink_fifo_mem`) |
| `tidelink_fifo_ahb` | Yes (via `tidelink_fifo` + `cmsdk_ahb_to_apb`) |

## PYNQ Hardware Testing

The `pynq/` directory contains test scripts for running on a Pynq-Z2 board with TideLink synthesised into the FPGA fabric. These reuse `tidelink.regs`, `FifoPacket`, and `PynqTidelinkDriver` from the shared Python package.

- `test_single_instance.py` -- single TideLink instance, PS acts as the pair (register R/W, FIFO write/read, credit tracking, doorbell)
- `test_loopback_pair.py` -- two cross-connected TideLink instances (reset handshake, credit release, threshold batching, pair credit counter)

```python
from tidelink.pynq_driver import PynqTidelinkDriver
from tidelink import regs

tl = PynqTidelinkDriver(fifo_base_addr=0x4000_0000, cfg_base_addr=0x4001_0000)
tl.write_packet([0xDEAD, 0xBEEF])
credits = tl.read_credit_count()
```

Requires a Vivado bitstream with `tidelink_fifo_ahb` connected via `axi_ahblite_bridge` to the Zynq PS AXI GP port. Update the base addresses in the test scripts to match your block design.

## Contributors

- David Mapstone (d.a.mapstone@soton.ac.uk)

## License

Copyright 2026, SoC Labs (www.soclabs.org). Released under Arm Academic Access license.

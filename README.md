# TideLink

TideLink is a **chiplet interconnect subsystem** developed by SoC Labs that enables reliable die-to-die communication between AHB-based SoCs. It wraps a complete chiplet link stack — Wlink (open-source D2D PHY/link layer), XHB500 AHB-to-AXI bridges, an address translator, and a credit-based packet FIFO — into a single integration-ready module (`tidelink_top`).

## Quick-start

**Sim (cocotb regression):**
```sh
cd cocotb
make regression        # runs ENVS list (see cocotb/README.md for the inventory)
```

**Sim (single UVM env):**
```sh
cd uvm/<env>
make run_all           # default 4-test suite for fc_adapter; full_test
                       # is excluded from CI pending scoreboard-race fix
```

**FPGA build (single-board, fastest):**
```sh
source set_env.sh
make -C fpga build_design TARGET=pynq-z2-pair
```

**FPGA build (HW-validated -all pair — recommended for sign-off):**
```sh
source set_env.sh
bash fpga/scripts/build_farm.sh \
    pynq-z2-pair-all@local \
    pynq-z2-pair-flip-all@srv04936
```
Each target ~40-45 min Vivado; runs in parallel. Bitstreams land in
`imp/fpga/output/<TARGET>/tidelink.bit`.

**FPGA HW validation on bridge1 (PYNQ-Z2 pair):**
```sh
# 1. Convert .bit -> .bin, generate provenance manifest, stage
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-all/tidelink.bit ~/td_milestone_stage/tidelink.bin
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit ~/td_milestone_stage/tidelink-flip.bin
cp imp/fpga/output/pynq-z2-pair-all/tidelink.hwh           ~/td_milestone_stage/tidelink.hwh
cp imp/fpga/output/pynq-z2-pair-flip-all/tidelink.hwh      ~/td_milestone_stage/tidelink-flip.hwh
bash pynq_host/scripts/make_bitstream_manifest.sh ~/td_milestone_stage/tidelink.bin      --commit "$(git rev-parse HEAD)" --target pynq-z2-pair      --lock-min 14
bash pynq_host/scripts/make_bitstream_manifest.sh ~/td_milestone_stage/tidelink-flip.bin --commit "$(git rev-parse HEAD)" --target pynq-z2-pair-flip --lock-min 14

# 2. Lease the pair (verify GRANTED, not queued)
fpgahub pair lease acquire bridge1 --ttl 3600

# 3. Push artefacts to mapstone-dev (cat-over-ssh because rsync trips
#    the remote bashrc Agent-pid banner)
for f in tidelink.bin tidelink.hwh tidelink-flip.bin tidelink-flip.hwh \
         tidelink.bin.manifest.json tidelink-flip.bin.manifest.json; do
    cat ~/td_milestone_stage/$f | \
        ssh -o LogLevel=ERROR mapstone-dev "cat > ~/td_milestone_stage/$f"
done

# 4. Converge + lock (auto-uses the manifest; UNVERIFIED deploys now ABORT)
ssh -o LogLevel=ERROR mapstone-dev \
    "cd ~/SoCLabs/tidelink && bash pynq_host/scripts/bringup_pair_converge.sh STABLE=3 MAX_RETRIES=15"
```

Acceptance criterion: `RESULT: CONVERGED — full 16/16 bidirectional
link at iteration N` for some N ≤ MAX_RETRIES.

**Lint flows:**
```sh
make -C lint lint-each            # Cadence HAL — full RTL lint coverage
make -C cdc cdc                   # SpyGlass CDC — see docs/reference/SPYGLASS_CDC_SIGNOFF.md
```

## Documentation map

The product documentation set lives in [`docs/`](docs/) — start at
[`docs/README.md`](docs/README.md):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — component/module map, ports, clock/reset/CDC, bring-up status
- [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) — functional spec (data path, flow control, autoneg, deskew, PTP)
- [`docs/REGISTER_MAP.md`](docs/REGISTER_MAP.md) — the unified APB register map
- [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md) — environment, flists, host-SoC wiring, FPGA/ASIC build & bring-up
- [`docs/VERIFICATION_PLAN.md`](docs/VERIFICATION_PLAN.md) — cocotb/UVM matrices, HW suite, known-issue backlog, sign-off
- [`cocotb/README.md`](cocotb/README.md) — cocotb env inventory + known-excluded list

Point-in-time bring-up, audit, and debug notes are retained under
[`docs/archive/`](docs/archive/) (indexed, not maintained).

---


TideLink solves a fundamental problem: **AHB is a blocking protocol** that cannot issue outstanding transactions, making transparent bridging over high-latency die-to-die links impractical. TideLink provides two parallel communication paths:

- **Path 1 — Transparent AHB bridge**: For control-plane access, configuration writes, and direct memory-mapped reads. Uses XHB500 → AXI → Wlink → AXI → XHB500. Reads block the bus (acceptable for short config accesses).
- **Path 2 — Mailbox packet FIFO**: For bulk data and latency-sensitive traffic. A dedicated Wlink FC node carries packets directly between paired FIFOs, bypassing AXI entirely. The CPU writes a descriptor packet to a local TX aperture and is immediately free — no bus stalling.
- **Path 3 — PTP subsystem**: For precision clock synchronisation between chiplets. A dedicated high-priority FC node (data_id=0xa2, 48-bit) carries two-message PTP exchanges (SYNC + DELAY_REQ) with hardware timestamp capture at the FC handshake boundary. Idle gating of the TX link layer eliminates transmit-side jitter. Integrates a PTP Hardware Clock (PHC) for nanosecond-resolution timekeeping. Includes a **hardware sync initiator** that autonomously generates periodic SYNC messages at configurable intervals (IEEE 1588 logSyncInterval range: 128 Hz to 1/16 Hz), using the PHC time outputs as its timing reference.
- **Path 4 — TideChart AXI-Stream interface**: For extension protocol traffic (`tc_axis_tx_*` / `tc_axis_rx_*`). PKT_EXT packets (FC pkt_type=2'b10) are forwarded between the die-to-die link and an external TideChart controller via standard AXI-Stream valid/ready handshaking. Includes a local PUF SRAM read path for boot-time entropy collection from uninitialized FIFO SRAM.

All four paths share a single GPIO PHY and are independently flow-controlled, so mailbox traffic cannot starve transparent AHB traffic (and vice versa).

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.

## Architecture

```
                     TideLink Top (tidelink_top.sv)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │  AHB Slave 1: Regular AHB subordinate (transparent bridge)           │
  │  ┌─────────────────────────────────────────────────┐                 │
  │  │  XHB500 (AHB→AXI) ──► Wlink AXI channels       │                 │
  │  │  + Address Translator                           │                 │
  │  └─────────────────────────────────────────────────┘                 │
  │                                                                      │
  │  AHB Slave 2: TideLink TX aperture (direct to FC node)              │
  │  ┌─────────────────────────────────────────────────┐                 │
  │  │  tidelink_fc_adapter → TideLink FC node ────────│──► Wlink       │
  │  └─────────────────────────────────────────────────┘     GPIO PHY   │
  │                                                          8 lanes    │
  │  AHB Slave 3: Local RX FIFO (read received packets)     D2D pads   │
  │  ┌─────────────────────────────────────────────────┐                 │
  │  │  tidelink_fifo_ahb (FIFO + APB regs + returner)│                 │
  │  └─────────────────────────────────────────────────┘                 │
  │                                                                      │
  │  AHB Slave 4: PTP subsystem (tidelink_ptp)                           │
  │  ┌─────────────────────────────────────────────────────┐                 │
  │  │  tidelink_ptp → PTP FC node (data_id=0xa2) ────────│──► Wlink       │
  │  │  + PHC (hw_capture + time inputs) + idle gating      │     highest    │
  │  │  + HW sync initiator (auto SYNC at configurable Hz) │     TX prio    │
  │  └─────────────────────────────────────────────────────┘                 │
  │                                                                      │
  │  AHB Master: Incoming from remote (via Wlink → XHB500)              │
  │                                                                      │
  │  AXI-Stream: TideChart interface (PKT_EXT forwarding)               │
  │  ┌─────────────────────────────────────────────────┐                 │
  │  │  tc_axis_tx_tvalid/tdata/tready → TideChart     │                 │
  │  │  tc_axis_rx_tvalid/tdata/tready ← TideChart     │                 │
  │  │  + PUF SRAM local read (subtype 0x0020/0x0021)  │                 │
  │  │  + tl_local_link_state_o[4:0] → TideChart       │                 │
  │  │    (quantised congestion sideband, Phase 1)     │                 │
  │  └─────────────────────────────────────────────────┘                 │
  │                                                                      │
  │  Internal: FC adapter RX → FIFO mux / Config mux                    │
  │  Internal: Returner → FC sideband (credit/doorbell over link)       │
  │  Internal: PTP FC RX → hw_capture + ptp_irq                         │
  └──────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **No TX FIFO** — the CPU writes directly into the remote side's RX FIFO via the FC node. No local buffering needed.
- **Dedicated Wlink FC node** (data_id=0xa1, 48-bit) — bypasses AXI/address translation for FIFO traffic. Independent credit pool from AXI channels.
- **Internal AHB muxes** — FC adapter RX writes share the FIFO and config slave ports with CPU access. FC has priority; CPU is stalled briefly during incoming writes.
- **Credit-based flow control** with configurable release threshold batching. Returner credit/doorbell writes go through FC sideband (not the external AHB bus).
- **GPIO PHY** — 8-lane parallel D2D with single-ended pads. Matches the nanosoc-chiplet-tech reference integration.
- **FIFO always enabled** — no CTRL.EN gate. FLUSH can be issued at any time for error recovery.
- **Generic chiplet controller** — `axi_chiplet_controller` wraps Wlink with runtime master/slave role selection via I2C sideband. Identical silicon on both chiplets; firmware selects role at boot.

## Module Hierarchy

### Top-Level (`tidelink_top.sv`)

| Module | Description |
|--------|-------------|
| `tidelink_top.sv` | Chiplet subsystem wrapper. Integrates all components below. Exposes `tc_axis_*` AXI-Stream ports for TideChart integration. |
| `tidelink_fc_adapter.sv` | AHB ↔ Wlink FC bridge. TX path (AHB slave → FC TX), RX path (FC RX → split AHB masters for FIFO + config), returner interception (AHB master → FC sideband), PKT_EXT routing to/from tc_axis_*, PUF SRAM local read handler. |
| `tidelink_addr_translator.sv` | APB-configurable address remapping for the transparent AHB bridge path. |
| `tidelink_ptp.sv` | PTP subsystem. Idle-gated FC TX/RX, PHC hw_capture generation, AHB slave for software-initiated exchanges. |

### FIFO Subsystem (`src/rtl/fifo/`)

| Module | Description |
|--------|-------------|
| `tidelink_fifo_ahb.sv` | AHB wrapper with `cmsdk_ahb_to_apb` bridge for config registers. |
| `tidelink_fifo.sv` | Core wrapper connecting FIFO memory, returner, and APB register file. |
| `tidelink_fifo_mem.sv` | AHB slave FIFO interface with CMSDK AHB-to-SRAM bridge. 3-way SRAM arbiter (FC writes > AHB > PUF reads). |
| `tidelink_fifo_ctrl.sv` | Pointer management, packet metadata, credit counting, address translation. |
| `tidelink_apb_regs.sv` | Configuration, status, credit accumulators, pair credit counter, doorbell. |
| `tidelink_returner.sv` | 3-channel priority AHB master for autonomous credit return and doorbell signalling. |

### Wlink (in `deps/axi-chiplet-controller/`)

| Component | Description |
|-----------|-------------|
| `axi_chiplet_controller.sv` | Generic wrapper: Wlink + I2C master/slave + role registers + APB mux. |
| Generated Wlink | 7 FC nodes: 5 AXI channels + GeneralBus + TideLink. GPIO PHY, 8 lanes. |
| `TideLink.scala` | Chisel source for the TideLink FC node (48-bit valid/ready streaming). |
| XHB500 | ARM AHB-to-AXI / AXI-to-AHB bridges (licensed IP, not included). |
| I2C cores | `i2c_master_axil`, `i2c_slave_axil_master` + Bluespec AXI/APB bridges. |

## Packet Format (4-word header)

Software writes descriptor packets to the TX aperture. The FIFO protocol frames each packet:

```
FIFO Addr  Content
┌──────────┬───────────────────────────────────────────────────┐
│ 0x0000   │ FIFO Length (N) — number of 32-bit words following │
├──────────┼───────────────────────────────────────────────────┤
│ 0x0004   │ pkt_type[31:28], src_id[27:20], dest_id[19:12],   │
│          │ tag[11:4], status[3:2], burst_type[1:0]            │
├──────────┼───────────────────────────────────────────────────┤
│ 0x0008   │ dest_addr[31:0]                                    │
├──────────┼───────────────────────────────────────────────────┤
│ 0x000C   │ length[15:3], size[2:0]                            │
├──────────┼───────────────────────────────────────────────────┤
│ 0x0010+  │ Data payload (WR_REQ / RD_RSP)                     │
└──────────┴───────────────────────────────────────────────────┘
```

Packet types: `RD_REQ` (0x1), `WR_REQ` (0x2), `RD_RSP` (0x3), `WR_RSP` (0x4), `ERROR` (0xF).

## Repository Structure

```
tidelink/
├── src/rtl/
│   ├── tidelink_top.sv              # Top-level chiplet subsystem
│   ├── tidelink_fc_adapter.sv       # FC adapter (AHB ↔ Wlink FC)
│   ├── tidelink_addr_translator.sv  # Address translator
│   └── fifo/                        # FIFO subsystem
│       ├── tidelink_fifo_ahb.sv     # AHB wrapper
│       ├── tidelink_fifo.sv         # Core wrapper
│       ├── tidelink_fifo_mem.sv     # FIFO memory interface
│       ├── tidelink_fifo_ctrl.sv    # Pointer/credit control
│       ├── tidelink_apb_regs.sv     # APB register block
│       ├── tidelink_returner.sv     # 3-channel AHB master
│       └── {fpga,asic,generic}/tidelink_sram.sv
├── deps/
│   └── axi-chiplet-controller/      # Wlink + XHB500 + address translator deps
│       └── wav-wlink-hw/            # Chisel source + generated Verilog
│           ├── src/main/scala/TideLink.scala
│           └── output_tidelink/     # Generated Wlink with TideLink FC node
├── python/tidelink/                 # Shared Python package
│   ├── regs.py                      # Register map constants
│   ├── packet.py                    # FifoPacket + DescriptorPacket classes
│   ├── pair_model.py                # PairRegisterBank state machine
│   └── pynq_driver.py              # PYNQ hardware driver
├── cocotb/                          # cocotb verification (232+ tests, 10 envs)
│   ├── tidelink_fifo/               # FIFO unit tests (31)
│   ├── tidelink_returner/           # Returner unit tests (17)
│   ├── tidelink_apb_regs/           # APB register tests (35)
│   ├── tidelink/                    # FIFO integration tests (25)
│   ├── tidelink_ahb/                # AHB wrapper tests (14)
│   ├── tidelink_py_pair/            # Paired credit flow tests (19)
│   ├── tidelink_fc_adapter/         # FC adapter unit tests (24)
│   ├── tidelink_top/                # Loopback integration tests (14)
│   ├── tidelink_system/             # Paired system stress tests (25)
│   ├── tidelink_ptp/               # PTP subsystem tests (15)
│   ���── axi_chiplet_controller/     # Controller role selection tests (23)
├── uvm/                             # UVM verification (4 environments)
│   ├── tidelink/                    # FIFO UVM env (4 tests)
│   ├── tidelink_fc_adapter/         # FC adapter UVM env (5 tests)
│   ├── tidelink_integration/        # Loopback UVM env (3 tests)
│   ├── tidelink_system/             # Paired system UVM env (12 tests, vplan)
│   └── tidelink_ptp_stress/         # PTP jitter characterisation UVM env
├── flists/                           # Synopsys file lists per module
├── syn/asic/                        # ASIC synthesis (Design Compiler, RTL Architect)
├── xprop/                           # X-propagation runs via VC Formal (NOT FPV)
├── lint/                            # HAL (Cadence) RTL lint
├── docs/
│   ├── TIDELINK_SPECIFICATION.md    # Full specification and design justification
│   ├── SPECIFICATION.md             # Hardware register specification
│   ├── USER_GUIDE.md                # Integration and operation guide
│   ├── SHORTCOMINGS.md              # Known limitations
│   ├── PTP_PROTOCOL.md             # PTP protocol specification
│   ├── ASIC_TIMING_CONSTRAINTS.md      # Source-sync PHY constraint rationale + listing (ASIC + FPGA)
│   └── DETERMINISM_VALIDATION.md    # Lane-lock determinism metric + validation procedure
└── .gitlab-ci.yml                   # CI pipeline (9 stages, 16 jobs)
```

## Dependencies

| Dependency | Source | Required for |
|------------|--------|-------------|
| ARM CMSDK | Arm Academic Access | `cmsdk_ahb_to_sram`, `cmsdk_ahb_to_apb`, `cmsdk_apb_slave_mux`, `cmsdk_fpga_sram` |
| ARM XHB500 | Arm Academic Access | AHB ↔ AXI bridges (transparent bridge path) |
| Wlink | `deps/axi-chiplet-controller/` | D2D link layer, FC nodes, GPIO PHY |
| PHC | `deps/ptp-hardware-clock-ahb/` | PTP Hardware Clock with hw_capture support |
| VCS | Synopsys | Simulation |
| cocotb + cocotbext-ahb | pip | Verification |

## Running Tests

```bash
pip install -e python/              # Install shared Python package

# Full cocotb regression (204 tests, 9 environments)
cd cocotb && make regression

# Single environment
cd cocotb/tidelink_fc_adapter && make

# Specific test
cd cocotb/tidelink_top && make TESTCASE=test_01_single_fifo_data_word_loopback

# With waveforms
cd cocotb/tidelink_fifo && make gui
```

## CI Pipeline

The GitLab CI pipeline runs 9 stages:

| Stage | Jobs | Tests |
|-------|------|-------|
| Setup | clone, preflight | Tool validation |
| Lint | hal-lint | RTL lint on all modules |
| Regression | cocotb-regression, uvm-regression | 204 cocotb + 4 UVM |
| New Module | cocotb-fc-adapter, cocotb-top, uvm-fc-adapter, uvm-integration | 46 tests |
| System | cocotb-system, uvm-system | 37 paired stress tests |
| Synthesis | synth-fifo, synth-top | Design Compiler: FIFO + FC adapter + tidelink_top |
| Coverage | coverage-merge | VCS coverage report |
| Pages | dashboard | HTML dashboard |

## Wlink FC Node Allocation

| FC Node | Short IDs | Data ID | Width | Protocol |
|---------|-----------|---------|-------|----------|
| AXI (5 channels) | 0x08–0x1b | 0x80–0x84 | 101b | AXI4 AW/W/B/AR/R |
| GeneralBus | 0x40–0x43 | 0xa0 | 32b | Edge-triggered bus |
| **TideLink** | **0x44–0x47** | **0xa1** | **48b** | Streaming valid/ready (FIFO_DATA, SIDEBAND, PKT_EXT) |
| **TideLink PTP** | **0x48–0x4b** | **0xa2** | **48b** | PTP timestamp exchange (highest TX priority) |

**FC Packet Types (pkt_type, bits [47:46] of FC word):**

| Value | Type | Description |
|-------|------|-------------|
| 0b00 | FIFO_DATA | Mailbox FIFO data word |
| 0b01 | SIDEBAND | Credit delta / doorbell return |
| 0b10 | PKT_EXT | Extension protocol (TideChart, PUF) |
| 0b11 | Reserved | Reserved for future use |

## Reference Integration

The reference target is [nanosoc-chiplet-tech](https://git.soton.ac.uk/soclabs/nanosoc-chiplet-tech) — a Cortex-M0 SoC with two chiplet links. TideLink replaces `nanosoc_ss_chiplet_mng` as the chiplet subsystem, providing the same bus matrix interface (AHB slaves + master + APB config) plus the mailbox FIFO capability.

## Contributors

- David Mapstone (d.a.mapstone@soton.ac.uk)

## License

Copyright 2026, SoC Labs (www.soclabs.org). Released under Arm Academic Access license.

# TideLink FPGA Build

Thin scaffold for targeting the TideLink chiplet subsystem to FPGA.
Board-specific block-design TCL, wrapper Verilog, and XDC files live under
`targets/<TARGET>/` (populated by parallel agents B1/B2/B3). Vivado IP
packaging lives under `vivado_ip/` (Agent A3).

## Targets

| `TARGET` | Board | Xilinx Part |
|---|---|---|
| `pynq-z2-single` (default) | Digilent Pynq-Z2 — single node | `xc7z020clg400-1` |
| `pynq-z2-pair` | Digilent Pynq-Z2 — loopback pair | `xc7z020clg400-1` |
| `mps3` | MPS3 / AN552 (Cortex-M55) | `xcku115-flva1517-2-e` *(placeholder — confirm with B3)* |

## Prerequisites

```bash
source set_env.sh          # sets SOCLABS_TIDELINK_DIR, CMSDK_DIR, XHB500_IP_DIR
```

## Build

```bash
# Single Pynq-Z2 (default)
make TARGET=pynq-z2-single build_design

# Loopback pair
make TARGET=pynq-z2-pair build_design

# MPS3
make TARGET=mps3 build_design

# Full flow (package IP then build)
make TARGET=pynq-z2-single all
```

Outputs land in `imp/fpga/output/<TARGET>/`:
- `tidelink.bit` — bitstream
- `tidelink.bin` — byte-swapped binary for Linux fpga_manager
- `tidelink.hwh` — hardware handoff for PYNQ overlay API
- `tidelink_design.xsa` — Vitis hardware platform

## Program via JTAG

```bash
make TARGET=pynq-z2-single program
# MPS3 — pass explicit JTAG device name (confirm with B3):
cd imp/fpga/output/mps3 && \
  vivado -mode batch -source ../../fpga/program_bitstream.tcl \
    -tclargs tidelink.bit xcku115_0
```

## Deploy to PYNQ

```bash
# Via explicit SSH host
make TARGET=pynq-z2-single PYNQ_HOST=xilinx@192.168.1.101 deploy

# Via fpgahub board name
make TARGET=pynq-z2-pair BOARD=fpga1 deploy

# Via fpgahub capability tag
make TARGET=pynq-z2-pair BOARD_TAG=pynq_z2 deploy_via_fpgahub
```

## Board acquisition via fpgahub

The natural way to acquire a matched Pynq-Z2 pair for the loopback target:

```bash
fpgahub pair up tidelink_bridge_01 --ttl 7200
```

This acquires a two-board lease (7200 s / 2 h), sets `BOARD` in the shell
environment, and keeps the lease alive for the duration of subsequent
`make *_via_fpgahub` calls.

## Directory layout

```
fpga/
├── Makefile                    # parameterised by TARGET
├── build_design.tcl            # Vivado project/synth/impl/bitstream driver
├── filelist.tcl                # RTL manifest (reads flists/tidelink_fpga.flist — Agent A2)
├── program_bitstream.tcl       # JTAG programmer, accepts optional device arg
├── scripts/bit2bin.py          # .bit → .bin converter for Linux fpga_manager
├── targets/
│   ├── pynq-z2-single/         # Agent B1: BD TCL, wrapper.v, XDC
│   ├── pynq-z2-pair/           # Agent B2: BD TCL, wrapper.v, XDC
│   └── mps3/                   # Agent B3: BD TCL, wrapper.v, XDC
└── vivado_ip/                  # Agent A3: package_tidelink_ip.tcl
```

## RTL bring-up before FPGA

Run the cocotb verification suite first:

```bash
cd cocotb && make TARGET=tidelink_ahb sim
```

See `cocotb/VERIFICATION_PLAN.md` for the full test inventory.

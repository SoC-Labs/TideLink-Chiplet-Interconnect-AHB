# TideLink MPS3 FPGA Target

This directory contains the Vivado block design, board wrapper, and XDC
constraints for running TideLink on the Arm MPS3 FPGA Prototyping Board
(TRM 100765_0000_04_en). The MPS3 is a bare-PL target — it carries no Zynq
processor, so the JTAG-AXI master IP is used for bring-up MMIO access in
place of the Zynq PS used on the Pynq-Z2 targets.

> **Priority note:** This target is lower-priority than the Pynq-Z2 paths
> (`pynq-z2-single`, `pynq-z2-pair`) and may not be brought to a working
> bitstream before the Z2 flow is fully exercised. The scaffolding here is
> syntactically valid and the build flow will find all required files, but
> several pin assignments and configuration details are marked TODO.

---

## Build command

```sh
make -C fpga TARGET=mps3 build_design
```

This runs `package_ip` then `build_design` (synthesis + implementation +
bitstream). Outputs land in `imp/fpga/output/mps3/`:
- `tidelink.bit` — JTAG-programmable bitstream
- `tidelink.hwh` — hardware handoff (not used on MPS3; PYNQ overlay format)
- `tidelink_design.xsa` — XSA bundle (Vitis-compatible)

To program via JTAG:

```sh
make -C fpga TARGET=mps3 program
```

---

## Bring-up path: JTAG-AXI master + xsdb

The block design contains a `jtag_axi` IP that presents an AXI4-Lite master
over the JTAG scan chain. Once the bitstream is loaded, connect a Xilinx
JTAG cable (e.g. the Platform Cable USB II or the MPS3's built-in JTAG
via the Arm DSTREAM-PT) and drive MMIO accesses from `xsdb`:

```tcl
# xsdb session (run from a terminal after `make program`)
connect
targets -set -filter {name =~ "FPGA*"}
# Write to APB config slave (Wlink reset release)
mwr -force 0x44010000 0x00000001
# Read link status from ahb_sub
mrd -force 0x40000000
# Write TX FIFO aperture
mwr -force 0x44000000 0xDEADBEEF
# Read RX FIFO window
mrd -force 0x44004000
```

Throughput over JTAG-AXI is approximately 1 MB/s — adequate for register
bring-up and single-transaction testing, but not for data-path stress testing.

---

## Address map

| Base address  | Range  | Slave               | Notes                              |
|---------------|--------|---------------------|------------------------------------|
| `0x4000_0000` | 256 MB | `ahb_sub`           | Chiplet access path (full 32-bit)  |
| `0x4400_0000` | 16 KB  | `ahb_tx`            | TX FIFO aperture                   |
| `0x4400_4000` | 16 KB  | `ahb_fifo`          | RX FIFO read window                |
| `0x4400_8000` | 16 B   | `ahb_ptp`           | PTP TX write port                  |
| `0x4401_0000` | 24 KB  | `apb`               | Wlink/TideLink/addr-translator cfg |
| `0x4404_0000` | 4 KB   | strap register      | Reads 0x00000000 (single-node)     |
| `0x4405_0000` | 4 KB   | `ahb_mng` BRAM      | Incoming chiplet write target      |

Same offsets as `pynq-z2-single` and `pynq-z2-pair` — runtime software is
address-map-compatible across all three targets.

---

## TODOs

### FPGA part number (CRITICAL)
The `fpga/Makefile` currently has `xcku115-flva1517-2-e` as the MPS3 part —
this is a **placeholder and is wrong**. The actual MPS3 board (as confirmed
by the `ethernet-subsystem-ahb` bring-up in this SoCLabs tree and the nanoSoC
MPS3 flow) uses:

```
xcku115-flvb1760-1-c
```

The Makefile must be updated (search for `xcku115-flva1517-2-e` in
`fpga/Makefile` and replace). This agent was instructed not to modify the
Makefile; the change is flagged here for the next owner.

### PHY pad pin assignments (CRITICAL)
All 18 TideLink GPIO PHY pins (`pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`,
`pad_rx[7:0]`) in `mps3_tidelink.xdc` are **commented-out placeholders**.
The actual pin numbers depend on which MPS3 expansion connector is used to
attach the TideLink PHY breakout board. To fill these in:

1. Identify the Shield or PMOD connector used by the TideLink PHY breakout.
2. Cross-reference with MPS3 TRM Table A-12 (SH0_IO) / A-13 (SH1_IO) to
   get the FPGA package pin for each connector position.
3. Uncomment and fill in the `set_property` lines in `mps3_tidelink.xdc`.
4. Check for parasitic SH0_IO[16:17] / SH1_IO[16:17] conflicts (TRM §A.2):
   if IO[14:15] are used, the corresponding [16:17] pins must be declared
   Hi-Z inputs with `PULLTYPE NONE`.
5. Uncomment the `create_clock` for `pad_clk_rx` and the corresponding
   `set_clock_groups` in `mps3_tidelink_timing.xdc`.

### I/O voltage standard
PHY pads use `LVCMOS33` (Shield connector with 3V3 IOREF jumper set).
If the TideLink PHY breakout operates at 1.8 V, change to `LVCMOS18` and
update both the XDC and the IOREF jumper configuration.

### Link clock frequency
The design targets 50 MHz (`clk_wiz_0` output from 24 MHz OSCCLK[0]).
50 MHz is achievable on xcku115 from 24 MHz via MMCM; the Clocking Wizard
will find a valid VCO configuration. Clock jitter at the MMCM output is
expected to be < 100 ps RMS, which is within the TideLink PHY timing budget.
Verify with the Vivado timing report after a successful implementation run.

### strap register
The constant at `0x4404_0000` is tied to `0x00000000`. For single-board
MPS3 use (no paired partner), this is correct. The strap register exists
to allow runtime software to detect the paired (`pynq-z2-pair`) vs unpaired
context at the same address across all targets. Whether software actually
reads this on MPS3 depends on the firmware — it is safe to leave as-is.

### ahb_mng master path
The TideLink `ahb_mng` master port (inbound from a remote chiplet) currently
has its `hrdata`/`hresp` inputs tied off. A 4 KB BRAM (`axi_bram_ctrl_mng`)
is present in the SmartConnect address map at `0x4405_0000` but is not yet
wired to the `ahb_mng` AHB master (which would require an `ahblite_axi_bridge`
between the TideLink AHB manager and the AXI SmartConnect). For first
bring-up this is acceptable — incoming chiplet transfers will stall/error
rather than corrupting local state.

### I2C sideband
I2C SCL/SDA are tied off in the block design for first bring-up. If the
TideLink PHY breakout uses I2C for configuration, assign pins in the XDC
and re-enable the BD connections.

### JTAG-AXI vs external CPU
The JTAG-AXI master is the sole bus initiator for MPS3 bring-up. In a
production setup the Corstone-300 Cortex-M55 bitstream (AN552 reference
design) would provide the CPU. Integrating that is out of scope for this
wave.
